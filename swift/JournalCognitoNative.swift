import AuthenticationServices
import Foundation
import Security
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One queue preserves save/clear order and keeps blocking Security calls off the UI actor.
private final class JournalCognitoKeychain: Sendable {
  private let queue = DispatchQueue(label: "com.logseq.journal.oauth-storage")
  private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result(catching: operation)) }
    }
  }
  private static var query: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.logseq.journal.cognito.tokens",
      kSecAttrAccount: "current-session", kSecUseDataProtectionKeychain: true,
      kSecAttrSynchronizable: false]
  }
  private static func clearLegacySession() throws {
    // Exact key from the removed SDK's AWSCognitoAuthCredentialStore. No token decoding/fallback.
    let legacy: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
      kSecAttrService: "com.amplify.awsCognitoAuthPlugin",
      kSecAttrAccount: "amplify.us-east-1_dtagLnju8.session", kSecUseDataProtectionKeychain: true]
    let status = SecItemDelete(legacy as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw JournalCognitoError.storage }
  }
  func load() async throws -> JournalCognitoTokens? {
    try await perform {
      var query = Self.query
      query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = item as? Data, data.count <= 131072
      else { throw JournalCognitoError.storage }
      return try JSONDecoder().decode(JournalCognitoTokens.self, from: data)
    }
  }
  func save(_ tokens: JournalCognitoTokens) async throws {
    try await perform {
      let data = try JSONEncoder().encode(tokens)
      guard data.count <= 131072 else { throw JournalCognitoError.storage }
      let status = SecItemUpdate(Self.query as CFDictionary, [kSecValueData: data] as CFDictionary)
      if status == errSecItemNotFound {
        var query = Self.query
        query[kSecValueData] = data; query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw JournalCognitoError.storage }
      } else if status != errSecSuccess { throw JournalCognitoError.storage }
    }
  }
  func clear() async throws {
    try await perform {
      let status = SecItemDelete(Self.query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw JournalCognitoError.storage }
    }
  }
  func retireLegacy() async throws { try await perform { try Self.clearLegacySession() } }
}

/// Cancels and resumes exactly once, including late callbacks, start failure and task cancellation.
@MainActor final class JournalCognitoWebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var operation: UUID?
  private var session: ASWebAuthenticationSession?
  private var continuation: CheckedContinuation<URL, Error>?
  private var timer: Task<Void, Never>?
  private var anchor: ASPresentationAnchor?
  func authenticate(_ url: URL, scheme: String) async throws -> URL {
    guard operation == nil else { throw JournalCognitoError.unavailable }
    #if os(iOS)
    anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
    #else
    anchor = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
    #endif
    guard anchor != nil else { throw JournalCognitoError.unavailable }
    let id = UUID(); operation = id
    defer { if operation == id { finish(id, .failure(CancellationError()), cancel: true) } }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callback, error in
          Task { @MainActor [weak self] in
            if let callback { self?.finish(id, .success(callback)) }
            else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
              self?.finish(id, .failure(CancellationError()))
            } else { self?.finish(id, .failure(JournalCognitoError.unavailable)) }
          }
        }
        self.session = session
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        timer = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(300)) } catch { return }
          self?.finish(id, .failure(JournalCognitoError.expired), cancel: true)
        }
        if !session.start() { finish(id, .failure(JournalCognitoError.unavailable), cancel: true) }
      }
    } onCancel: { Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError()), cancel: true) } }
  }
  func cancel() {
    if let operation { finish(operation, .failure(CancellationError()), cancel: true) }
  }
  private func finish(_ id: UUID, _ result: Result<URL, Error>, cancel: Bool = false) {
    guard operation == id else { return }
    let waiter = continuation, active = session
    operation = nil; continuation = nil; session = nil; anchor = nil
    timer?.cancel(); timer = nil
    if cancel { active?.cancel() }
    waiter?.resume(with: result)
  }
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor ?? ASPresentationAnchor() }
}

private final class JournalOAuthRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor enum JournalCognitoNative {
  static let shared: JournalCognitoSession = {
    let storage = JournalCognitoKeychain(), browser = JournalCognitoWebSession()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
    let http = URLSession(configuration: configuration, delegate: JournalOAuthRedirectPolicy(), delegateQueue: nil)
    return JournalCognitoSession(configuration: .production,
      storage: JournalCognitoStorage(load: { try await storage.load() },
        save: { try await storage.save($0) }, clear: { try await storage.clear() },
        retireLegacy: { try await storage.retireLegacy() }),
      browser: JournalCognitoBrowser(authenticate: { try await browser.authenticate($0, scheme: $1) }, cancel: { browser.cancel() }),
      transport: { request in
        let (data, response) = try await http.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw JournalCognitoError.request }
        return (data, response)
      })
  }()
}
