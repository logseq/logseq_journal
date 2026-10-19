import Foundation
import Synchronization

// Replace only blocking storage and remote authentication. Exercise the actual
// native factory, platform service, async admission and cleanup implementation.
enum JournalLocalAccountBindingStore {
  struct State {
    var value: [String: String]? = [
      "userId": "fixture-user", "managedSyncOrigin": "https://api.logseq.io",
    ]
    var operations: [String] = []
    var held: String?
    var gate: DispatchSemaphore?
    var failRestore = false
    var recovery: Data?
  }
  static let state = Mutex(State())

  static func operation(_ name: String) {
    precondition(!Thread.isMainThread, "Blocking account storage ran on the UI thread")
    let gate = state.withLock { state in
      state.operations.append(name)
      guard state.held == name else { return nil as DispatchSemaphore? }
      state.held = nil
      return state.gate
    }
    if let gate {
      precondition(gate.wait(timeout: .now() + 10) == .success, "Storage gate was not released")
    }
  }

  static func hold(_ operation: String) -> DispatchSemaphore {
    let gate = DispatchSemaphore(value: 0)
    state.withLock { $0.operations = []; $0.held = operation; $0.gate = gate }
    return gate
  }

  static func load() throws -> [String: Any]? {
    operation("load")
    return state.withLock { $0.value }
  }
  static func save(arguments: Any?) throws {
    operation("save")
    let arguments = arguments as! [String: Any]
    state.withLock {
      $0.value = ["userId": arguments["userId"] as! String,
                  "managedSyncOrigin": arguments["managedSyncOrigin"] as! String]
    }
  }
  static func encode(userID: String, managedSyncOrigin: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["userId": userID, "managedSyncOrigin": managedSyncOrigin], options: .sortedKeys)
  }
  static func loadData() throws -> Data? {
    operation("snapshot")
    return try state.withLock { state in
      try state.value.map { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
    }
  }
  static func writeData(_ data: Data) throws {
    operation("save")
    let value = try JSONSerialization.jsonObject(with: data) as! [String: String]
    state.withLock { $0.value = value }
  }
  static func restoreData(_ data: Data?) throws {
    operation("restore")
    if state.withLock({ $0.failRestore }) {
      throw JournalAccountIssue(kind: .secureStorageUnavailable, stage: .bindingWrite)
    }
    let value = try data.map { try JSONSerialization.jsonObject(with: $0) as! [String: String] }
    state.withLock { $0.value = value }
  }
  static func clear() throws {
    operation("clear")
    state.withLock { $0.value = nil }
  }
  static func loadRecoveryData() throws -> Data? { state.withLock { $0.recovery } }
  static func writeRecoveryData(_ data: Data) throws { state.withLock { $0.recovery = data } }
  static func clearRecoveryData() throws { state.withLock { $0.recovery = nil } }
}

@MainActor final class JournalCognitoSession: JournalAuthCapability {
  static var signOutCalls = 0
  static var userCalls = 0
  static var userID = "fixture-user"
  func currentUserID() async throws -> String? { Self.userCalls += 1; return Self.userID }
  func freshIDToken() async throws -> String { "fixture-token" }
  func signOut() async throws { Self.signOutCalls += 1 }
}

@MainActor enum JournalCognitoNative { static let shared = JournalCognitoSession() }

@main struct JournalAccountThreadingTests {
  @MainActor static func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
      precondition(ContinuousClock.now < deadline, "Native account operation did not start")
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  @MainActor static func canceled(_ task: Task<JournalPlatformWire.Response, Error>) async throws {
    do {
      _ = try await task.value
      preconditionFailure("Retired account request returned a result")
    } catch is CancellationError {}
  }

  @MainActor static func main() async throws {
    let platform = JournalNativeServices.makePlatformServices()
    let initial = try await platform.response(for: .localAccount)
    precondition(initial == .localAccount(userID: "fixture-user", origin: "https://api.logseq.io"))

    let lookupGate = JournalLocalAccountBindingStore.hold("load")
    let lookup = Task { try await platform.response(for: .localAccount) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations == ["load"] } }
    // This completes on MainActor while the storage call remains blocked.
    let ready = try await platform.response(for: .terminationReady)
    precondition(ready == .terminationReady)
    platform.invalidateConnection()
    lookupGate.signal()
    try await canceled(lookup)

    let authGate = JournalLocalAccountBindingStore.hold("load")
    let authentication = Task { try await platform.explicitOnlineResponse(for: .authenticatedUser) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations == ["load"] } }
    let signOut = Task { try await platform.response(for: .signOut) }
    try await waitFor { JournalCognitoSession.signOutCalls == 1 }
    authGate.signal()
    try await canceled(authentication)
    let signedOut = try await signOut.value
    precondition(signedOut == .signedOut && JournalCognitoSession.userCalls == 0)
    precondition(JournalLocalAccountBindingStore.state.withLock { $0.value == nil })

    let saveGate = JournalLocalAccountBindingStore.hold("save")
    let saving = Task { try await platform.explicitOnlineResponse(for: .authenticatedUser) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations.contains("save") } }
    let cleanup = Task { try await platform.response(for: .signOut) }
    try await waitFor { JournalCognitoSession.signOutCalls == 2 }
    // Cancellation must not undo cleanup after the provider has confirmed sign-out.
    cleanup.cancel()
    let responsive = try await platform.response(for: .terminationReady)
    precondition(responsive == .terminationReady)
    saveGate.signal()
    try await canceled(saving)
    _ = try await cleanup.value
    precondition(JournalLocalAccountBindingStore.state.withLock {
      $0.operations == ["load", "snapshot", "save", "snapshot", "restore", "clear"] && $0.value == nil
    }, "Pending save was not serialized before sign-out cleanup")

    let cancellationGate = JournalLocalAccountBindingStore.hold("load")
    let abandoned = Task { try await platform.response(for: .localAccount) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations == ["load"] } }
    abandoned.cancel()
    cancellationGate.signal()
    try await canceled(abandoned)

    // Run the real native factory/store owner with only Security I/O replaced.
    JournalLocalAccountBindingStore.state.withLock {
      $0.value = ["userId": "fixture-user", "managedSyncOrigin": "https://api.logseq.io"]
      $0.operations = []
    }
    let recovering = JournalNativeServices.makePlatformServices()
    _ = try await recovering.response(for: .localAccount)
    JournalCognitoSession.userID = "replacement-user"
    let delayedSave = JournalLocalAccountBindingStore.hold("save")
    let replacement = Task { try await recovering.explicitOnlineResponse(for: .authenticatedUser) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations.contains("save") } }
    _ = try await recovering.response(for: .timelinePresented)
    let otherWindow = JournalNativeServices.makePlatformServices()
    var readCompleted = false
    let isolatedRead = Task {
      defer { readCompleted = true }
      return try await otherWindow.response(for: .localAccount)
    }
    for _ in 0..<20 { await Task.yield() }
    precondition(!readCompleted, "Another store must not read a proposed binding")
    JournalLocalAccountBindingStore.state.withLock { $0.failRestore = true }
    delayedSave.signal()
    do { _ = try await replacement.value; preconditionFailure("Unadmitted replacement succeeded") }
    catch let issue as JournalAccountIssue { precondition(issue.kind == .secureStorageUnavailable) }
    precondition(recovering.accountIssue?.kind == .secureStorageUnavailable,
      "Failed undo must explain the safe recovery stage")
    do { _ = try await isolatedRead.value; preconditionFailure("Pending failed undo exposed a new account") }
    catch let issue as JournalAccountIssue { precondition(issue.kind == .secureStorageUnavailable) }
    JournalLocalAccountBindingStore.state.withLock { $0.failRestore = false }
    let restored = try await otherWindow.response(for: .localAccount)
    precondition(restored == .localAccount(userID: "fixture-user", origin: "https://api.logseq.io"),
      "Retry must repair the original bytes before exposing account metadata")
    JournalCognitoSession.userID = "fixture-user"
    _ = try await recovering.explicitOnlineResponse(for: .authenticatedUser)
    precondition(recovering.accountIssue == nil)

    JournalLocalAccountBindingStore.state.withLock { $0.value = nil }
    let creating = JournalNativeServices.makePlatformServices()
    let createdSaveGate = JournalLocalAccountBindingStore.hold("save")
    let created = Task { try await creating.explicitOnlineResponse(for: .authenticatedUser) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations.contains("save") } }
    creating.cancelAuthenticationPreparation()
    createdSaveGate.signal()
    try await canceled(created)
    precondition(JournalLocalAccountBindingStore.state.withLock { $0.value == nil },
      "Rejecting a new proposal must restore absence, never retain its new account")

    JournalLocalAccountBindingStore.state.withLock {
      $0.value = ["userId": "fixture-user", "managedSyncOrigin": "https://api.logseq.io"]
    }
    let ordered = JournalNativeServices.makePlatformServices()
    _ = try await ordered.response(for: .localAccount)
    JournalCognitoSession.userID = "replacement-user"
    let oldSaveGate = JournalLocalAccountBindingStore.hold("save")
    let oldSave = Task { try await ordered.explicitOnlineResponse(for: .authenticatedUser) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations.contains("save") } }
    _ = try await ordered.response(for: .timelinePresented)
    ordered.cancelAuthenticationPreparation()
    JournalCognitoSession.userID = "fixture-user"
    let newerSave = Task { try await ordered.explicitOnlineResponse(for: .authenticatedUser) }
    oldSaveGate.signal()
    try await canceled(oldSave)
    let newResult = try await newerSave.value
    precondition(newResult == .authenticatedUser("fixture-user"))
    precondition(JournalLocalAccountBindingStore.state.withLock { $0.value?["userId"] == "fixture-user" },
      "Old undo must complete before a newer accepted write")
    print("PASS background account storage, responsive UI, ordered cleanup and stale-result fencing")
  }
}

// The existing storage/undo scenarios exercise user-authorized online recovery.
@MainActor private extension JournalPlatformServices {
  func explicitOnlineResponse(for request:JournalPlatformWire.Request) async throws -> JournalPlatformWire.Response {
    _ = try await response(for:.onlineRequested)
    return try await response(for:request)
  }
}
