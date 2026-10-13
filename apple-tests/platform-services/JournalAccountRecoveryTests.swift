import Foundation
import Security

// A native decode failure cannot originate in the OCaml reducer. Exercise the
// owning public services with real codecs and synthetic storage/authentication.
@MainActor private final class RecoveryAuth: JournalAuthCapability {
  var user: String? = "verified-user"
  var failure: Error?
  var calls = 0
  var held: CheckedContinuation<String?, Error>?
  var suspended = false
  var suspendedToken = false
  var heldToken: CheckedContinuation<String, Error>?
  func currentUserID() async throws -> String? {
    calls += 1
    try Task.checkCancellation()
    if suspended { return try await withCheckedThrowingContinuation { held = $0 } }
    if let failure { throw failure }
    return user
  }
  func freshIDToken() async throws -> String {
    if suspendedToken { return try await withCheckedThrowingContinuation { heldToken = $0 } }
    return "synthetic-token"
  }
  func signOut() async throws { user = nil }
}

@MainActor private final class RecoveryStore {
  var bytes: Data?
  var loadFailure: Error?
  var saveFailure: Error?
  var writes = 0
  var clears = 0
  var suspendSave = false
  var heldSave: CheckedContinuation<Void, Never>?
  let access = JournalAccountStoreAccess()
  init(_ bytes: Data?) { self.bytes = bytes }
  var capability: JournalAccountStore {
    JournalAccountStore(load: {
      let release = try await self.access.acquire()
      defer { release() }
      if let failure = self.loadFailure { throw failure }
      guard let bytes = self.bytes else { return nil }
      let value = try JournalLocalAccountBindingStore.decode(bytes)
      return JournalLocalAccount(userID: value["userId"] as! String,
        managedSyncOrigin: value["managedSyncOrigin"] as! String)
    }, save: {
      let release = try await self.access.acquire()
      do {
        if let failure = self.saveFailure { throw failure }
        let previous = self.bytes
        if self.suspendSave { await withCheckedContinuation { self.heldSave = $0 } }
        self.bytes = try JournalLocalAccountBindingStore.encode(userID: $0.userID,
          managedSyncOrigin: $0.managedSyncOrigin)
        self.writes += 1
        return JournalAccountSave(commit: { release() }, rollback: { self.bytes = previous; release() })
      } catch { release(); throw error }
    }, clear: {
      let release = try await self.access.acquire(respectCancellation: false)
      defer { release() }
      self.bytes = nil; self.clears += 1
    })
  }
}

@main struct JournalAccountRecoveryTests {
  @MainActor static func main() async throws {
    let origin = "https://api.logseq.io"
    let legacy = Data(#"{"version":1,"userId":"previous-account","managedSyncOrigin":"https://api.logseq.io"}"#.utf8)
    let corrupt = Data("not-json-sensitive-content".utf8)
    var failures: [String] = []
    func check(_ condition: Bool, _ label: String) { if !condition { failures.append(label) } }
    for (name, bytes) in [("legacy", legacy), ("corrupt", corrupt)] {
      let auth = RecoveryAuth(), store = RecoveryStore(bytes)
      let services = JournalPlatformServices(auth: auth, account: store.capability, managedSyncOrigin: origin)
      do {
        let response = try await services.response(for: .authenticatedUser)
        check(response == .authenticatedUser("verified-user"), name + ": verified identity returned")
      } catch { failures.append(name + ": valid OAuth blocked by invalid binding") }
      check(auth.calls == 1, name + ": identity lookup runs")
      check(store.writes == 1 && store.clears == 0, name + ": rebuild without clearing")
      if let rebuilt = store.bytes, let value = try? JournalLocalAccountBindingStore.decode(rebuilt) {
        check(value["userId"] as? String == "verified-user", name + ": never reuse previous identity")
      } else { failures.append(name + ": current binding decodes") }
      store.bytes = bytes; store.writes = 0; auth.user = nil
      do { _ = try await services.response(for: .authenticatedUser); failures.append(name + ": missing identity must require sign-in") }
      catch JournalPlatformServices.Failure.authenticationRequired { }
      catch { failures.append(name + ": missing identity must reach sign-in instead of decode failure") }
      check(store.bytes == bytes && store.writes == 0 && store.clears == 0, name + ": retain record until verified sign-in")
      auth.user = "verified-user" // A verified identity after the user's browser sign-in.
      do { _ = try await services.response(for: .authenticatedUser) }
      catch { failures.append(name + ": successful sign-in cannot rebuild") }
      check(store.writes == 1, name + ": successful sign-in commits binding")
      store.bytes = bytes; store.writes = 0
      store.saveFailure = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecNotAvailable))
      do { _ = try await services.response(for: .authenticatedUser); failures.append(name + ": failed rebuild must remain retryable") }
      catch { }
      check(store.bytes == bytes && store.writes == 0, name + ": failed save retains original record")
      store.saveFailure = nil
      do { _ = try await services.response(for: .authenticatedUser) }
      catch { failures.append(name + ": retry after failed save") }
    }
    for code in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed] {
      let auth = RecoveryAuth(), store = RecoveryStore(legacy)
      store.loadFailure = NSError(domain: NSOSStatusErrorDomain, code: Int(code))
      let services = JournalPlatformServices(auth: auth, account: store.capability, managedSyncOrigin: origin)
      do { _ = try await services.response(for: .authenticatedUser); failures.append("temporary storage failure accepted") }
      catch { }
      check(auth.calls == 1 && store.writes == 0 && store.clears == 0 && store.bytes == legacy,
        "temporary storage failure must query identity but never replace inaccessible binding")
    }
    let auth = RecoveryAuth(), store = RecoveryStore(legacy)
    let services = JournalPlatformServices(auth: auth, account: store.capability, managedSyncOrigin: origin)
    auth.failure = URLError(.notConnectedToInternet)
    do { _ = try await services.response(for: .authenticatedUser); failures.append("offline request accepted") }
    catch is URLError { }
    catch { failures.append("network failure hidden by old binding") }
    check(store.bytes == legacy && store.writes == 0 && store.clears == 0, "network failure preserves record")
    auth.failure = nil; auth.suspended = true
    let stale = Task { try await services.response(for: .authenticatedUser) }
    let staleDeadline = ContinuousClock.now + .seconds(3)
    while auth.held == nil && ContinuousClock.now < staleDeadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    if let held = auth.held {
      services.invalidateConnection(); held.resume(returning: "retired-account")
      do { _ = try await stale.value; failures.append("stale identity committed") }
      catch is CancellationError { }
      catch { failures.append("stale completion classification") }
    } else { stale.cancel(); _ = try? await stale.value; failures.append("stale case never reached identity lookup") }
    check(store.bytes == legacy && store.writes == 0, "retired completion retains old record")
    auth.held = nil
    let retiredFailure = Task { try await services.response(for: .authenticatedUser) }
    while auth.held == nil { await Task.yield() }
    services.invalidateConnection()
    auth.held!.resume(throwing: URLError(.notConnectedToInternet))
    do { _ = try await retiredFailure.value; failures.append("retired failure accepted") }
    catch is CancellationError { }
    catch { failures.append("retired network failure must not replace current recovery state") }
    // Existing graph-session publication clears private UI drafts on an account
    // boundary. A replacement identity must be stopped before that publication.
    auth.suspended = false; auth.user = "original-user"
    store.bytes = try JournalLocalAccountBindingStore.encode(userID: "original-user", managedSyncOrigin: origin)
    _ = try await services.response(for: .localAccount)
    _ = try await services.response(for: .authenticatedUser)
    _ = try await services.response(for: .timelinePresented)
    let retained = store.bytes, previousWrites = store.writes
    auth.user = "different-user"
    do { _ = try await services.response(for: .authenticatedUser); failures.append("active graph account was replaced") }
    catch { }
    check(store.bytes == retained && store.writes == previousWrites && store.clears == 0,
      "different identity must leave active graph account and pending work intact")
    services.cancelAuthenticationPreparation()
    do { _ = try await services.response(for: .idToken(challengeID: "retained-graph")); failures.append("foreign account token released to active graph") }
    catch { }
    check(store.bytes == retained && store.writes == previousWrites,
      "cancel cannot remove active graph identity protection")
    auth.user = "original-user"
    do { _ = try await services.response(for: .authenticatedUser) }
    catch { failures.append("original account cannot recover the active graph session") }
    store.bytes = nil; auth.user = nil
    do { _ = try await services.response(for: .authenticatedUser); failures.append("missing advisory record signed out an active graph") }
    catch JournalPlatformServices.Failure.authenticationRequired { }
    catch { failures.append("missing active account must offer reconnection") }
    check(store.clears == 0, "missing session must not clear a presented account")
    for retired in [false, true] {
      let delayedAuth = RecoveryAuth()
      let original = try JournalLocalAccountBindingStore.encode(userID: "original-user", managedSyncOrigin: origin)
      let delayedStore = RecoveryStore(original)
      let owner = JournalPlatformServices(auth: delayedAuth, account: delayedStore.capability, managedSyncOrigin: origin)
      _ = try await owner.response(for: .localAccount)
      delayedAuth.user = "replacement-user"
      delayedStore.suspendSave = true
      let lookup = Task { try await owner.response(for: .authenticatedUser) }
      while delayedStore.heldSave == nil { await Task.yield() }
      _ = try await owner.response(for: .timelinePresented)
      if retired {
        owner.cancelAuthenticationPreparation()
        do { _ = try await owner.response(for: .idToken(challengeID: "newer-error")); failures.append("newer foreign token accepted") }
        catch { }
        check(owner.accountIssue?.kind == .accountChangeBlocked, "newer error recorded before old save completes")
      }
      delayedStore.heldSave!.resume()
      do { _ = try await lookup.value; failures.append("delayed replacement published after original graph presented") }
      catch is CancellationError { check(retired, "live account mismatch must be explained") }
      catch let issue as JournalAccountIssue {
        check(!retired && issue.kind == .accountChangeBlocked, "post-save account admission")
      }
      catch { failures.append("unexpected delayed-save outcome") }
      check(delayedStore.bytes == original, "unaccepted binding write must restore the original record")
      check(owner.accountIssue?.kind == .accountChangeBlocked, "old save completion must not clear current error")
    }
    for user: String? in ["different-user", nil] {
      let delayedAuth = RecoveryAuth()
      let original = try JournalLocalAccountBindingStore.encode(userID: "original-user", managedSyncOrigin: origin)
      let delayedStore = RecoveryStore(original)
      let owner = JournalPlatformServices(auth: delayedAuth, account: delayedStore.capability, managedSyncOrigin: origin)
      _ = try await owner.response(for: .localAccount)
      delayedAuth.user = user
      delayedAuth.suspendedToken = true
      let lookup = Task { try await owner.response(for: .idToken(challengeID: "graph-presented-during-token")) }
      let deadline = ContinuousClock.now + .seconds(3)
      while delayedAuth.heldToken == nil && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
      }
      guard let held = delayedAuth.heldToken else {
        lookup.cancel(); _ = try? await lookup.value
        failures.append("token race never reached suspended token lookup")
        continue
      }
      _ = try await owner.response(for: .timelinePresented)
      held.resume(returning: "different-account-token")
      do { _ = try await lookup.value; failures.append("late presented graph received an unverified account token") }
      catch JournalPlatformServices.Failure.authenticationRequired { check(user == nil, "missing identity classification") }
      catch let issue as JournalAccountIssue { check(user != nil && issue.kind == .accountChangeBlocked, "late token account classification") }
      catch { failures.append("unexpected late token outcome") }
      check(delayedStore.bytes == original && delayedStore.clears == 0 && delayedStore.writes == 0,
        "late token rejection retains graph account binding")
    }
    let logoutAuth = RecoveryAuth()
    let logoutStore = RecoveryStore(try JournalLocalAccountBindingStore.encode(userID: "original-user", managedSyncOrigin: origin))
    let logoutOwner = JournalPlatformServices(auth: logoutAuth, account: logoutStore.capability, managedSyncOrigin: origin)
    _ = try await logoutOwner.response(for: .localAccount)
    _ = try await logoutOwner.response(for: .timelinePresented)
    logoutAuth.user = "different-user"
    do { _ = try await logoutOwner.response(for: .authenticatedUser); failures.append("logout fixture never rejected foreign account") }
    catch { }
    check(logoutOwner.accountIssue?.kind == .accountChangeBlocked, "logout fixture has prior recovery issue")
    check(try await logoutOwner.response(for: .signOut) == .signedOut, "explicit synthetic sign-out completes")
    check(logoutOwner.accountIssue == nil, "successful sign-out clears stale recovery issue")
    check(!logoutOwner.timelinePresented && logoutStore.bytes == nil && logoutStore.clears == 1, "successful sign-out resets account session")
    if !failures.isEmpty {
      for failure in failures { print("FAIL: " + failure) }
      exit(1)
    }
    print("PASS rejected binding rebuild, sign-in, retry, temporary storage, network and stale completion")
  }
}
