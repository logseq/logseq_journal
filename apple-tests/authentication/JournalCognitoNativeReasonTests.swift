import Synchronization

// Native owner fixture: the runner replaces only OS entry points/type names at
// compile time. No Keychain, window, browser, auth session or credentials exist.
private enum FixtureSecurity {
  struct State: Sendable {
    var status: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var data: Data? = nil
    var calls: [String] = []
  }
  static let state = Mutex(State())
  static func copy(_ query: CFDictionary, _ item: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    state.withLock { value in
      value.calls.append("load")
      if let data = value.data { item?.pointee = data as CFData }
      else { item?.pointee = "private-token-sentinel" as CFString }
      return value.status
    }
  }
  static func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    state.withLock { $0.calls.append("update"); return $0.updateStatus }
  }
  static func add(_ query: CFDictionary, _ item: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    state.withLock { $0.calls.append("add"); return $0.status }
  }
  static func delete(_ query: CFDictionary) -> OSStatus {
    state.withLock { $0.calls.append("delete"); return $0.status }
  }
}
@MainActor final class FixtureAnchor {}
@MainActor protocol FixturePresentationContext: AnyObject {
  func presentationAnchor(for session: FixtureWebAuthenticationSession) -> FixtureAnchor
}
@MainActor final class FixtureWebAuthenticationSession {
  var presentationContextProvider: (any FixturePresentationContext)?
  var prefersEphemeralWebBrowserSession = false
  let callback: (URL?, Error?) -> Void
  init(url: URL, callbackURLScheme: String?, completionHandler: @escaping (URL?, Error?) -> Void) {
    callback = completionHandler
  }
  func start() -> Bool {
    if FixtureBrowserState.started, let error = FixtureBrowserState.error { callback(nil, error) }
    return FixtureBrowserState.started
  }
  func cancel() {}
}
@MainActor private enum FixtureBrowserState {
  static var anchor: FixtureAnchor? = FixtureAnchor()
  static var started = false
  static var error: Error?
}
@main private struct JournalCognitoNativeReasonTests {
  @MainActor static func rejected(_ expected: [String], _ operation: () async throws -> Void) async throws {
    do { try await operation(); preconditionFailure("expected native rejection") }
    catch {
      let issue = JournalAccountIssue.classify(error, stage: .identityLookup)
      precondition(issue.kind == .unavailable && issue.offersSignIn)
      for part in expected { precondition(issue.diagnostic.contains(part), "missing native cause \(part): \(issue.diagnostic)") }
      precondition(!issue.diagnostic.contains("private-") && !issue.diagnostic.contains("https://"))
    }
  }
  @MainActor static func main() async throws {
    // The advisory binding store has its own error policy. Enrich it without
    // turning a transient storage failure into a rejected/cleared binding.
    FixtureSecurity.state.withLock { $0.status = -25308; $0.updateStatus = -25308 }
    let bindingOperations: [(String, JournalAccountIssue.Kind, () throws -> Void)] = [
      ("bindingLoad.status", .secureStorageUnavailable, { _ = try JournalLocalAccountBindingStore.loadData() }),
      ("bindingWrite.status", .secureStorageUnavailable, { try JournalLocalAccountBindingStore.writeData(Data()) }),
      ("recoveryClear.status", .secureStorageUnavailable, { try JournalLocalAccountBindingStore.clearRecoveryData() }),
      ("bindingRestore.status", .secureStorageUnavailable, { try JournalLocalAccountBindingStore.restoreData(nil) }),
      ("bindingClear.status", .unavailable, { try JournalLocalAccountBindingStore.clear() })]
    for (expected, kind, operation) in bindingOperations {
      do { try operation(); preconditionFailure("Expected binding storage rejection") }
      catch {
        let issue = JournalAccountIssue.classify(error, stage: .bindingWrite)
        precondition(issue.kind == kind && !issue.rejectsBinding)
        precondition(issue.diagnostic.contains(expected) && issue.diagnostic.contains("osstatus -25308"),
          "binding storage lost safe cause: \(issue.diagnostic)")
      }
    }
    FixtureSecurity.state.withLock { $0.status = errSecSuccess; $0.updateStatus = errSecSuccess; $0.data = nil }
    do { _ = try JournalLocalAccountBindingStore.loadData(); preconditionFailure("wrong native type accepted") }
    catch {
      let issue = JournalAccountIssue.classify(error, stage: .bindingRead)
      precondition(issue.diagnostic.contains("bindingLoad.wrongType") && !issue.rejectsBinding)
    }
    FixtureSecurity.state.withLock { $0.status = errSecSuccess }
    let storage = JournalCognitoKeychain()
    let tokens = JournalCognitoTokens(idToken: "synthetic", accessToken: "synthetic", refreshToken: "synthetic",
      userID: "synthetic", issuer: "synthetic", clientID: "synthetic", expiresAt: Date())
    FixtureSecurity.state.withLock { $0.status = -25308 }
    try await rejected(["keychainLoad.status", "osstatus -25308"]) { _ = try await storage.load() }
    FixtureSecurity.state.withLock { $0.status = errSecSuccess }
    try await rejected(["keychainLoad.wrongType"]) { _ = try await storage.load() }
    FixtureSecurity.state.withLock { $0.data = Data(repeating: 65, count: 131073) }
    try await rejected(["keychainLoad.responseTooLarge"]) { _ = try await storage.load() }
    FixtureSecurity.state.withLock { $0.data = Data("private-token-sentinel".utf8) }
    try await rejected(["keychainLoad.invalidRecord"]) { _ = try await storage.load() }
    FixtureSecurity.state.withLock { $0.updateStatus = -25308 }
    try await rejected(["keychainSave.status", "osstatus -25308"]) { try await storage.save(tokens) }
    FixtureSecurity.state.withLock { $0.updateStatus = errSecItemNotFound; $0.status = -25299 }
    try await rejected(["keychainAdd.status", "osstatus -25299"]) { try await storage.save(tokens) }
    FixtureSecurity.state.withLock { $0.status = -25308 }
    try await rejected(["keychainClear.status", "osstatus -25308"]) { try await storage.clear() }
    try await rejected(["legacyClear.status", "osstatus -25308"]) { try await storage.retireLegacy() }
    let oversized = JournalCognitoTokens(idToken: String(repeating: "a", count: 131073), accessToken: "synthetic",
      refreshToken: "synthetic", userID: "synthetic", issuer: "synthetic", clientID: "synthetic", expiresAt: Date())
    try await rejected(["keychainSave.responseTooLarge"]) { try await storage.save(oversized) }
    FixtureSecurity.state.withLock { $0.status = errSecItemNotFound }
    let missing = try await storage.load(); precondition(missing == nil)
    try await storage.clear(); try await storage.retireLegacy()
    FixtureSecurity.state.withLock { $0.status = errSecSuccess; $0.data = try! JSONEncoder().encode(tokens) }
    let restored = try await storage.load(); precondition(restored?.idToken == tokens.idToken)
    print("PASS native Keychain load/save/add/clear/legacy, status/type/size/record, missing/success without Security I/O")

    let browser = JournalCognitoWebSession(), url = URL(string: "https://example.invalid")!
    FixtureBrowserState.anchor = nil
    try await rejected(["browser.missingAnchor"]) { _ = try await browser.authenticate(url, scheme: "synthetic") }
    FixtureBrowserState.anchor = FixtureAnchor()
    try await rejected(["browser.startRejected"]) { _ = try await browser.authenticate(url, scheme: "synthetic") }
    FixtureBrowserState.started = true
    FixtureBrowserState.error = NSError(domain: "private-token-sentinel", code: 77,
      userInfo: [NSLocalizedDescriptionKey: "private-token-sentinel"])
    try await rejected(["browser.browserFailed"]) { _ = try await browser.authenticate(url, scheme: "synthetic") }
    FixtureBrowserState.error = ASWebAuthenticationSessionError(.canceledLogin)
    do { _ = try await browser.authenticate(url, scheme: "synthetic"); preconditionFailure("cancel returned success") }
    catch is CancellationError {}
    FixtureBrowserState.error = nil
    let first = Task { try await browser.authenticate(url, scheme: "synthetic") }
    for _ in 0..<30 { await Task.yield() }
    try await rejected(["browser.operationInProgress"]) { _ = try await browser.authenticate(url, scheme: "synthetic") }
    browser.cancel()
    do { _ = try await first.value; preconditionFailure("cancel returned success") }
    catch is CancellationError {}
    print("PASS native browser missing-anchor/start-rejected/failed/overlap and cancellation without GUI")
  }
}
