import Foundation

// This boundary owns the continuation. The public events queue alone cannot
// reproduce it; replace only the runtime delivery port, keeping native owners real.
@MainActor final class JournalRuntime {
  var events: [Data] = []
  func sendPlatformEvent(_ data: Data) { events.append(data) }
}
enum JournalCognitoSession { static let changed = Notification.Name("journal.tests.auth.changed") }
struct JournalEnvironmentSample: Equatable, Codable {}
@MainActor final class PlatformTestAuth: JournalAuthCapability {
  var identityFailure: Error?
  func currentUserID() async throws -> String? {
    if let identityFailure { throw identityFailure }
    return "fixture-user"
  }
  var signOutStarted = false
  var signOutCompletion: CheckedContinuation<Void, Never>?
  var holdSignOut = false
  func freshIDToken() async throws -> String { "fixture-token" }
  var signOutFailure: Error?
  func signOut() async throws {
    signOutStarted = true
    NotificationCenter.default.post(name: JournalCognitoSession.changed, object: self)
    if holdSignOut { await withCheckedContinuation { signOutCompletion = $0 } }
    if let signOutFailure { throw signOutFailure }
  }
}
@main struct JournalApplicationPlatformTests {
  @MainActor static func main() async throws {
    func packet(_ tag: UInt8) -> Data {
      var bytes = Data("LJP2".utf8); bytes.append(contentsOf: [2,0,tag,0]); bytes.append(Data(repeating:0,count:24)); return bytes
    }
    for failSignOut in [false, true] {
      let auth = PlatformTestAuth()
      auth.holdSignOut = true
      if failSignOut { auth.signOutFailure = NSError(domain: "test.signout", code: 9) }
      var cleared = false
      let owner = JournalPlatformServices(auth: auth, account: JournalAccountStore(
        load: { nil }, save: { _ in JournalAccountSave(commit: {}, rollback: {}) },
        clear: { cleared = true }), managedSyncOrigin: "https://api.logseq.io")
      let bridge = JournalApplicationPlatform(services: owner)
      let port = JournalRuntime()
      bridge.connect(to: port)
      _ = try await owner.response(for: .timelinePresented)
      let (notificationCompletions, notificationCompletion) = AsyncStream<Void>.makeStream(
        bufferingPolicy: .bufferingNewest(1))
      bridge.authenticationNotificationCompletionObserver = { notificationCompletion.yield(()) }
      let logout = Task { await bridge.request(packet(10)) }
      var notifications = notificationCompletions.makeAsyncIterator()
      let notificationCompleted: Void? = await notifications.next()
      precondition(notificationCompleted != nil)
      bridge.authenticationNotificationCompletionObserver = nil
      notificationCompletion.finish()
      precondition(auth.signOutStarted && auth.signOutCompletion != nil,
        "Notification refresh must complete while native sign-out is suspended")
      let notificationIssue = bridge.accountIssue
      auth.signOutCompletion?.resume()
      let result = await logout.value
      precondition(notificationIssue == nil,
        "Sign-out notification must not publish identityLookup.unavailable while native revocation is pending")
      if failSignOut {
        precondition(result?.prefix(4) == Data("LJF1".utf8) && !cleared,
          "Real native sign-out failure must still complete as failure without clearing the binding")
        auth.identityFailure = NSError(domain: "test.identity", code: 7)
        let refresh = bridge.refreshAuthentication()
        precondition(refresh != nil)
        await refresh?.value
        precondition(bridge.accountIssue?.kind == .unavailable,
          "Real current identity lookup errors after failed sign-out must remain visible")
      } else {
        precondition(result?.prefix(4) == Data("LJP2".utf8) && cleared,
          "Successful sign-out must acknowledge native and local cleanup")
        precondition(bridge.authenticationRequired && bridge.localAccountAvailable == false
          && bridge.accountIssue == nil && !owner.onlineAllowed,
          "Completed sign-out must remain a clean signed-out state")
      }
      bridge.disconnect()
    }
    let faultAuth = PlatformTestAuth()
    faultAuth.signOutFailure = NSError(domain:"SECRET token path",code:1)
    let faultServices = JournalPlatformServices(auth:faultAuth, account:JournalAccountStore(
      load:{nil},save:{_ in JournalAccountSave(commit:{},rollback:{})},clear:{}),managedSyncOrigin:"https://api.logseq.io")
    let fault = JournalApplicationPlatform(services:faultServices)
    let faultRuntime = JournalRuntime(); fault.connect(to:faultRuntime)
    let failure = await fault.request(packet(10))
    precondition(failure == (Data([76,74,70,49,10,0,6,0])+Data(repeating:0,count:16)), "current failure needs safe LJF1 reason and original request tag")
    faultAuth.signOutFailure = CancellationError()
    let cancellation = await fault.request(packet(10))
    precondition(cancellation == (Data([76,74,70,49,10,0,1,0])+Data(repeating:0,count:16)), "current cancellation must finish its pending continuation")
    let malformed = await fault.request(Data([1,2]))
    precondition(malformed == (Data([76,74,70,49,0,0,2,0])+Data(repeating:0,count:16)), "malformed request needs bounded decode reason without copying bytes")
    fault.disconnect()
    let retired = await fault.request(packet(10))
    precondition(retired == nil, "retired requests must remain silent")
    let services = JournalPlatformServices(auth: PlatformTestAuth(), account: JournalAccountStore(
      load: { nil }, save: { _ in JournalAccountSave(commit: {}, rollback: {}) }, clear: {}),
      managedSyncOrigin: "https://api.logseq.io")
    let runtime = JournalRuntime()
    let platform = JournalApplicationPlatform(services: services)
    platform.connect(to: runtime)
    let first = Task { @MainActor in try? await platform.beginOnline() }
    for _ in 0..<50 { await Task.yield() }
    precondition(runtime.events.count == 1)
    platform.cancelAccountPreparation()
    await first.value
    let count = runtime.events.count
    var retryFinished = false
    let retry = Task { @MainActor in
      defer { retryFinished = true }
      do { try await platform.beginOnline() } catch {}
    }
    for _ in 0..<100 { await Task.yield() }
    let rejectedPromptly = retryFinished
    precondition(runtime.events.count == count, "Revoked retry replaced the cancellation barrier")
    retry.cancel()
    await retry.value
    // A new presentation acknowledges cancellation and permits a fresh attempt.
    let next = JournalPlatformWire.StartupScope(accountGeneration: 0, presentationGeneration: 1)
    var acknowledgement = JournalPlatformWire.onlineCancelled(next)
    acknowledgement[6] = 32
    let acknowledged = await platform.request(acknowledgement)
    precondition(acknowledged != nil)
    var nextFinished = false
    let nextAttempt = Task { @MainActor in
      defer { nextFinished = true }
      try? await platform.beginOnline()
    }
    for _ in 0..<1000 {
      if runtime.events.last.flatMap({ try? JournalPlatformWire.startupScope($0) }) == next { break }
      await Task.yield()
    }
    precondition(runtime.events.last?[6] == 34
      && runtime.events.last.flatMap({ try? JournalPlatformWire.startupScope($0) }) == next,
      "A fresh presentation must request its own online permission")
    var permission = JournalPlatformWire.onlineRequested(next)
    permission[6] = 30
    let granted = await platform.request(permission)
    precondition(granted != nil)
    await nextAttempt.value
    precondition(nextFinished && services.onlineAllowed)
    platform.disconnect()
    precondition(rejectedPromptly, "Same-scope retry hung on an event that was rejected")
    // Native continuation/scope ownership is outside the OCaml pure reducer.
    // Drive the existing public owner, using only the isolated runtime port.
    func makePlatform() -> (JournalApplicationPlatform, JournalRuntime) {
      let services = JournalPlatformServices(auth: PlatformTestAuth(), account: JournalAccountStore(
        load: { nil }, save: { _ in JournalAccountSave(commit: {}, rollback: {}) }, clear: {}),
        managedSyncOrigin: "https://api.logseq.io")
      let runtime = JournalRuntime()
      let platform = JournalApplicationPlatform(services: services)
      platform.connect(to: runtime)
      return (platform, runtime)
    }
    let (retryFailure, retryRuntime) = makePlatform()
    let held = Task { @MainActor in try? await retryFailure.beginOnline() }
    while retryRuntime.events.isEmpty { await Task.yield() }
    retryFailure.cancelAccountPreparation()
    await held.value
    retryFailure.retryOnline()
    for _ in 0..<100 { await Task.yield() }
    precondition(retryFailure.accountIssue?.kind == .unavailable,
      "Current non-cancellation retry failure must remain visible")
    retryFailure.disconnect()

    let (cancelledRetry, cancelledRuntime) = makePlatform()
    cancelledRetry.retryOnline()
    while cancelledRuntime.events.isEmpty { await Task.yield() }
    cancelledRetry.disconnect()
    for _ in 0..<100 { await Task.yield() }
    precondition(cancelledRetry.accountIssue == nil,
      "Cancelled retry must not become an account failure")

    let (reconnectedRetry, reconnectedRuntime) = makePlatform()
    reconnectedRetry.retryOnline()
    reconnectedRetry.disconnect()
    reconnectedRetry.connect(to: reconnectedRuntime)
    for _ in 0..<100 { await Task.yield() }
    precondition(reconnectedRuntime.events.isEmpty && reconnectedRetry.accountIssue == nil,
      "Retry scheduled by a retired connection cannot admit work into its replacement")
    reconnectedRetry.disconnect()

    let (replacedRetry, replacedRuntime) = makePlatform()
    replacedRetry.retryOnline()
    var newerScope = JournalPlatformWire.onlineCancelled(next)
    newerScope[6] = 32
    let scopeAccepted = await replacedRetry.request(newerScope)
    precondition(scopeAccepted != nil)
    for _ in 0..<100 { await Task.yield() }
    precondition(replacedRuntime.events.isEmpty && replacedRetry.accountIssue == nil,
      "Retry scheduled by an older startup scope cannot admit work into its replacement")
    replacedRetry.disconnect()
    print("PASS: revoked retry terminates promptly; new presentation retry succeeds")
  }
}
