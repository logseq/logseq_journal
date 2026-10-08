import Foundation

@MainActor struct JournalCognitoStorage {
  let load: () async throws -> JournalCognitoTokens?
  let save: (JournalCognitoTokens) async throws -> Void
  let clear: () async throws -> Void
  var retireLegacy: () async throws -> Void = { }
}
@MainActor struct JournalCognitoBrowser {
  let authenticate: (URL, String) async throws -> URL
  let cancel: () -> Void
}

/// Sole OAuth session owner. Graph/account/E2EE policy remains behind JournalPlatformServices.
@MainActor final class JournalCognitoSession: JournalAuthCapability, JournalAuthenticationAPI {
  static let changed = Notification.Name("com.logseq.journal.authentication-changed")
  private let configuration: JournalCognitoConfiguration
  private let storage: JournalCognitoStorage
  private let browser: JournalCognitoBrowser
  private let transport: (URLRequest) async throws -> (Data, HTTPURLResponse)
  private let now: () -> Date
  private var tokens: JournalCognitoTokens?
  private var loaded = false
  private var generation: UInt64 = 0
  private var signInID: UUID?
  private var refresh: (id: UUID, task: Task<JournalCognitoTokens, Error>)?
  private var signingOut = false

  init(configuration: JournalCognitoConfiguration, storage: JournalCognitoStorage,
       browser: JournalCognitoBrowser, transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse),
       now: @escaping () -> Date = Date.init) {
    self.configuration = configuration; self.storage = storage
    self.browser = browser; self.transport = transport; self.now = now
  }
  private func check(_ version: UInt64) throws {
    try Task.checkCancellation()
    guard generation == version, !signingOut else { throw CancellationError() }
  }
  private func restore() async throws {
    guard !loaded else { return }
    let version = generation, value = try await storage.load()
    try check(version)
    if let value {
      guard value.issuer == configuration.issuer, value.clientID == configuration.clientID,
        !value.userID.isEmpty, !value.idToken.isEmpty, !value.accessToken.isEmpty, !value.refreshToken.isEmpty
      else { throw JournalCognitoError.invalidToken }
    }
    // A concurrent restore may have completed a refresh or sign-in already.
    if !loaded { tokens = value; loaded = true }
  }
  func currentUserID() async throws -> String? {
    try await restore()
    guard tokens != nil else { return nil }
    _ = try await freshIDToken()
    return tokens?.userID
  }
  func freshIDToken() async throws -> String {
    try await restore()
    guard !signingOut, let current = tokens else { throw JournalPlatformServices.Failure.authenticationRequired }
    guard current.expiresAt.timeIntervalSince(now()) <= 60 else { return current.idToken }
    let version = generation
    let operation: (id: UUID, task: Task<JournalCognitoTokens, Error>)
    if let refresh { operation = refresh }
    else {
      let id = UUID()
      let task = Task { [self] in
        do {
          let response = try await requestTokens(["grant_type": "refresh_token", "client_id": configuration.clientID,
            "refresh_token": current.refreshToken])
          try check(version)
          let updated = try await validate(response, nonce: nil, previous: current)
          try check(version)
          try await storage.save(updated)
          try check(version)
          tokens = updated
          return updated
        } catch JournalCognitoError.invalidGrant {
          try check(version)
          tokens = nil; loaded = true
          try await storage.clear()
          try check(version)
          NotificationCenter.default.post(name: Self.changed, object: self)
          throw JournalPlatformServices.Failure.authenticationRequired
        }
      }
      operation = (id, task); refresh = operation
    }
    defer { if refresh?.id == operation.id { refresh = nil } }
    let result = try await operation.task.value
    try check(version)
    return result.idToken
  }
  func signIn() async throws {
    guard signInID == nil, !signingOut else { throw JournalCognitoError.unavailable }
    let version = generation, id = UUID(), started = now()
    signInID = id
    defer { if signInID == id { signInID = nil } }
    try await restore()
    try check(version)
    guard signInID == id else { throw CancellationError() }
    let state = try JournalCognitoOAuth.random(), verifier = try JournalCognitoOAuth.random(), nonce = try JournalCognitoOAuth.random()
    let url = try JournalCognitoOAuth.authorization(configuration, state: state, verifier: verifier, nonce: nonce)
    func admitted() throws {
      try check(version)
      guard signInID == id else { throw CancellationError() }
      guard now().timeIntervalSince(started) <= 300 else { throw JournalCognitoError.expired }
    }
    let callback = try await browser.authenticate(url, "logseqjournal")
    try admitted()
    let code = try JournalCognitoOAuth.code(callback, configuration: configuration, state: state)
    let response = try await requestTokens(["grant_type": "authorization_code", "client_id": configuration.clientID,
      "redirect_uri": configuration.redirectURI, "code": code, "code_verifier": verifier])
    try admitted()
    let updated = try await validate(response, nonce: nonce, previous: nil)
    try admitted()
    // Retire any refresh of the preceding account before persisting the replacement.
    let previous = tokens
    generation &+= 1; refresh?.task.cancel(); refresh = nil
    let savingVersion = generation
    try await storage.save(updated)
    if generation == savingVersion && (signInID != id || Task.isCancelled) {
      // Storage is serialized. Undo only this cancelled write; never overwrite a
      // newer sign-in or explicit sign-out that has advanced the generation.
      if let previous { try await storage.save(previous) }
      else { try await storage.clear() }
      throw CancellationError()
    }
    try check(savingVersion)
    guard signInID == id else { throw CancellationError() }
    tokens = updated; loaded = true
    signInID = nil
    try? await storage.retireLegacy()
    try check(savingVersion)
    NotificationCenter.default.post(name: Self.changed, object: self)
  }
  func cancelSignIn() {
    guard signInID != nil else { return }
    signInID = nil; browser.cancel()
  }
  func signOut() async throws {
    guard !signingOut else { throw JournalCognitoError.unavailable }
    generation &+= 1; signingOut = true
    cancelSignIn(); refresh?.task.cancel(); refresh = nil
    defer { signingOut = false }
    var previous = tokens
    if previous == nil { previous = try? await storage.load() }
    tokens = nil; loaded = true
    try await storage.clear()
    try await storage.retireLegacy()
    NotificationCenter.default.post(name: Self.changed, object: self)
    if let previous {
      // Local cleanup succeeds offline. Revocation is bounded and best effort.
      _ = try? await transport(request(path: "/oauth2/revoke", values: ["client_id": configuration.clientID,
        "token": previous.refreshToken]))
    }
  }
  private func request(path: String, values: [String: String]) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://\(configuration.domain)\(path)")!)
    request.httpMethod = "POST"; request.timeoutInterval = 15
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = JournalCognitoOAuth.form(values)
    return request
  }
  private func requestTokens(_ values: [String: String]) async throws -> JournalCognitoTokenResponse {
    let request = request(path: "/oauth2/token", values: values)
    let (data, response) = try await transport(request)
    guard response.url == request.url, data.count <= 131072 else { throw JournalCognitoError.request }
    guard response.statusCode == 200 else {
      let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
      if response.statusCode == 400, error == "invalid_grant" { throw JournalCognitoError.invalidGrant }
      throw JournalCognitoError.request
    }
    do { return try JSONDecoder().decode(JournalCognitoTokenResponse.self, from: data) }
    catch { throw JournalCognitoError.invalidToken }
  }
  private func validate(_ response: JournalCognitoTokenResponse, nonce: String?, previous: JournalCognitoTokens?) async throws -> JournalCognitoTokens {
    var request = URLRequest(url: URL(string: configuration.issuer + "/.well-known/jwks.json")!)
    request.timeoutInterval = 15
    let (data, http) = try await transport(request)
    guard http.statusCode == 200, http.url == request.url else { throw JournalCognitoError.request }
    return try JournalCognitoTokenValidator(jwks: data).validate(response, configuration: configuration,
      nonce: nonce, previous: previous, now: now())
  }
}
