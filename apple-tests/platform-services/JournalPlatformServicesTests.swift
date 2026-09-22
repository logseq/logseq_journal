import Foundation

@MainActor private final class Auth: JournalAuthCapability {
  var user: String? = nil
  var token = "fixture-token"
  var failSignOut = false
  var userCalls = 0
  var tokenCalls = 0
  var signOutCalls = 0
  var holdUser = false
  var heldUser: CheckedContinuation<String?, Error>?
  var holdSignOut = false
  var heldSignOut: CheckedContinuation<Void, Never>?
  func currentUserID() async throws -> String? {
    userCalls += 1
    if holdUser { return try await withCheckedThrowingContinuation { heldUser = $0 } }
    return user
  }
  func freshIDToken() async throws -> String { tokenCalls += 1; return token }
  func signOut() async throws {
    signOutCalls += 1
    if failSignOut { throw CocoaError(.userCancelled) }
    if holdSignOut { await withCheckedContinuation { heldSignOut = $0 } }
    user = nil
  }
}

@MainActor private final class Store {
  var value: JournalLocalAccount?
  var writes = 0
  var clears = 0
  var failSave = false
  init(_ value: JournalLocalAccount?) { self.value = value }
  var capability: JournalAccountStore {
    JournalAccountStore(load: { self.value }, save: {
      if self.failSave { throw CocoaError(.fileWriteUnknown) }
      self.writes += 1; self.value = $0
    }, clear: { self.clears += 1; self.value = nil })
  }
}

@main struct JournalPlatformServicesTests {
  static func require(_ condition: Bool) { precondition(condition) }
  @MainActor static func main() async throws {
    let origin = "https://api.logseq.io"
    let old = JournalLocalAccount(userID: "offline-user", managedSyncOrigin: origin)
    let auth = Auth()
    let store = Store(old)
    let platform = JournalPlatformServices(auth: auth, account: store.capability,
      managedSyncOrigin: origin)
    let pickerAuth = Auth()
    pickerAuth.user = "offline-user"
    let picker = JournalPlatformServices(auth: pickerAuth, account: store.capability,
      managedSyncOrigin: origin)
    do {
      let response = try await picker.response(for: .authenticatedUser)
      precondition(response == .authenticatedUser("offline-user"))
    } catch {
      fatalError("An account without a presented graph must still reconcile: \(error)")
    }
    require(try await picker.response(for: .idToken(challengeID: "picker")) ==
      .idToken(challengeID: "picker", token: "fixture-token"))
    store.writes = 0
    do {
      let response = try await platform.response(for: .localAccount)
      precondition(response == .localAccount(userID: old.userID, origin: origin))
    } catch { fatalError("Local account must be available before authentication: \(error)") }
    precondition(auth.userCalls == 0 && auth.tokenCalls == 0)
    do {
      _ = try await platform.response(for: .authenticatedUser)
      fatalError("First Swift session absence must not sign out the account")
    } catch JournalPlatformServices.Failure.authenticationRequired {}
    precondition(auth.userCalls == 1 && store.value == old)
    require(try await platform.response(for: .timelinePresented) == .timelinePresented)
    precondition(platform.timelinePresented)
    do {
      _ = try await platform.response(for: .authenticatedUser)
      fatalError("A missing Swift session must not sign out an offline account")
    } catch JournalPlatformServices.Failure.authenticationRequired {}
    precondition(store.value == old && store.clears == 0 && store.writes == 0)

    auth.user = "online-user"
    require(try await platform.response(for: .authenticatedUser) == .authenticatedUser("online-user"))
    precondition(store.value?.userID == "online-user")
    store.failSave = true
    require(try await platform.response(for: .authenticatedUser) == .authenticatedUser("online-user"))
    store.failSave = false
    let writes = store.writes
    auth.user = ""
    do {
      _ = try await platform.response(for: .authenticatedUser)
      fatalError("Invalid user must not be persisted")
    } catch JournalPlatformWire.Failure.invalidPacket {}
    precondition(store.writes == writes)
    auth.user = "online-user"

    for challenge in ["a", "b"] {
      require(try await platform.response(for: .idToken(challengeID: challenge)) ==
        .idToken(challengeID: challenge, token: "fixture-token"))
    }
    auth.token = ""
    do {
      _ = try await platform.response(for: .idToken(challengeID: "invalid"))
      fatalError("Invalid token must not reach OCaml")
    } catch JournalPlatformWire.Failure.invalidPacket {}
    precondition(store.clears == 0)
    auth.failSignOut = true
    do {
      _ = try await platform.response(for: .signOut)
      fatalError("Failed native sign-out must not report success")
    } catch is CocoaError {}
    precondition(store.clears == 0 && store.value?.userID == "online-user")
    auth.failSignOut = false
    auth.holdUser = true
    let pending = Task { try await platform.response(for: .authenticatedUser) }
    while auth.heldUser == nil { await Task.yield() }
    require(try await platform.response(for: .signOut) == .signedOut)
    precondition(store.value == nil && store.clears == 1)
    auth.heldUser?.resume(returning: "stale-user")
    do {
      _ = try await pending.value
      fatalError("A stale authentication result restored an account after sign-out")
    } catch is CancellationError {}
    precondition(store.value == nil)
    auth.holdUser = false
    require(try await platform.response(for: .authenticatedUser) == .authenticatedUser(nil))

    store.value = old
    auth.holdUser = true
    auth.heldUser = nil
    let disconnectedLookup = Task { try await platform.response(for: .authenticatedUser) }
    while auth.heldUser == nil { await Task.yield() }
    platform.invalidateConnection()
    precondition(!platform.timelinePresented, "Replacement runtime needs its own presentation acknowledgment")
    auth.heldUser?.resume(returning: "retired-runtime-user")
    do {
      _ = try await disconnectedLookup.value
      fatalError("Retired runtime persisted an authentication result")
    } catch is CancellationError {}
    precondition(store.value == old)
    auth.holdUser = false
    _ = try await platform.response(for: .timelinePresented)

    store.value = JournalLocalAccount(userID: "other", managedSyncOrigin: "https://other.example")
    do {
      _ = try await platform.response(for: .localAccount)
      fatalError("Binding origin mismatch was accepted")
    } catch JournalPlatformServices.Failure.invalidBinding {}
    store.value = old
    auth.holdSignOut = true
    let cancelledSignOut = Task { try await platform.response(for: .signOut) }
    while auth.heldSignOut == nil { await Task.yield() }
    do {
      _ = try await platform.response(for: .authenticatedUser)
      fatalError("Lookup was admitted during sign-out")
    } catch JournalPlatformServices.Failure.unavailable {}
    cancelledSignOut.cancel()
    auth.heldSignOut?.resume()
    _ = try? await cancelledSignOut.value
    precondition(store.value == nil, "Confirmed SDK sign-out must clear binding even if its caller disappears")
    require(try await platform.response(for: .terminationReady) == .terminationReady)
    print("PASS native platform ordering, offline binding, token correlation and sign-out fencing")
  }
}
