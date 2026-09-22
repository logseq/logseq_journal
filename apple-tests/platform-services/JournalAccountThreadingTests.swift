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
  static func clear() throws {
    operation("clear")
    state.withLock { $0.value = nil }
  }
}

@MainActor final class JournalAmplifySession: JournalAuthCapability {
  static var signOutCalls = 0
  static var userCalls = 0
  func currentUserID() async throws -> String? { Self.userCalls += 1; return "fixture-user" }
  func freshIDToken() async throws -> String { "fixture-token" }
  func signOut() async throws { Self.signOutCalls += 1 }
}

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
    let authentication = Task { try await platform.response(for: .authenticatedUser) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations == ["load"] } }
    let signOut = Task { try await platform.response(for: .signOut) }
    try await waitFor { JournalAmplifySession.signOutCalls == 1 }
    authGate.signal()
    try await canceled(authentication)
    let signedOut = try await signOut.value
    precondition(signedOut == .signedOut && JournalAmplifySession.userCalls == 0)
    precondition(JournalLocalAccountBindingStore.state.withLock { $0.value == nil })

    let saveGate = JournalLocalAccountBindingStore.hold("save")
    let saving = Task { try await platform.response(for: .authenticatedUser) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations.contains("save") } }
    let cleanup = Task { try await platform.response(for: .signOut) }
    try await waitFor { JournalAmplifySession.signOutCalls == 2 }
    // Cancellation must not undo cleanup after the SDK has confirmed sign-out.
    cleanup.cancel()
    let responsive = try await platform.response(for: .terminationReady)
    precondition(responsive == .terminationReady)
    saveGate.signal()
    try await canceled(saving)
    _ = try await cleanup.value
    precondition(JournalLocalAccountBindingStore.state.withLock {
      $0.operations == ["load", "save", "clear"] && $0.value == nil
    }, "Pending save was not serialized before sign-out cleanup")

    let cancellationGate = JournalLocalAccountBindingStore.hold("load")
    let abandoned = Task { try await platform.response(for: .localAccount) }
    try await waitFor { JournalLocalAccountBindingStore.state.withLock { $0.operations == ["load"] } }
    abandoned.cancel()
    cancellationGate.signal()
    try await canceled(abandoned)
    print("PASS background account storage, responsive UI, ordered cleanup and stale-result fencing")
  }
}
