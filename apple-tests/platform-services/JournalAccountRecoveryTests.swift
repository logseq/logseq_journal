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
  func currentUserID() async throws -> String? {
    calls += 1
    if suspended { return try await withCheckedThrowingContinuation { held = $0 } }
    if let failure { throw failure }
    return user
  }
  func freshIDToken() async throws -> String { "synthetic-token" }
  func signOut() async throws { user = nil }
}

@MainActor private final class RecoveryStore {
  var bytes: Data?
  var loadFailure: Error?
  var saveFailure: Error?
  var writes = 0
  var clears = 0
  init(_ bytes: Data?) { self.bytes = bytes }
  var capability: JournalAccountStore {
    JournalAccountStore(load: {
      if let failure = self.loadFailure { throw failure }
      guard let bytes = self.bytes else { return nil }
      let value = try JournalLocalAccountBindingStore.decode(bytes)
      return JournalLocalAccount(userID: value["userId"] as! String,
        managedSyncOrigin: value["managedSyncOrigin"] as! String)
    }, save: {
      if let failure = self.saveFailure { throw failure }
      self.bytes = try JournalLocalAccountBindingStore.encode(userID: $0.userID,
        managedSyncOrigin: $0.managedSyncOrigin)
      self.writes += 1
    }, clear: { self.bytes = nil; self.clears += 1 })
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
    for _ in 0..<1000 { if auth.held != nil { break }; await Task.yield() }
    if let held = auth.held {
      services.invalidateConnection(); held.resume(returning: "retired-account")
      do { _ = try await stale.value; failures.append("stale identity committed") }
      catch is CancellationError { }
      catch { failures.append("stale completion classification") }
    } else { _ = try? await stale.value; failures.append("stale case never reached identity lookup") }
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
    if !failures.isEmpty {
      for failure in failures { print("FAIL: " + failure) }
      exit(1)
    }
    print("PASS rejected binding rebuild, sign-in, retry, temporary storage, network and stale completion")
  }
}
