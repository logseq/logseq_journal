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
  func currentUserID() async throws -> String? { "fixture-user" }
  func freshIDToken() async throws -> String { "fixture-token" }
  func signOut() async throws {}
}
@main struct JournalApplicationPlatformTests {
  @MainActor static func main() async throws {
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
    for _ in 0..<50 { await Task.yield() }
    precondition(runtime.events.last == JournalPlatformWire.onlineRequested(next))
    var permission = JournalPlatformWire.onlineRequested(next)
    permission[6] = 30
    let granted = await platform.request(permission)
    precondition(granted != nil)
    await nextAttempt.value
    precondition(nextFinished && services.onlineAllowed)
    platform.disconnect()
    precondition(rejectedPromptly, "Same-scope retry hung on an event that was rejected")
    print("PASS: revoked retry terminates promptly; new presentation retry succeeds")
  }
}
