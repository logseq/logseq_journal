import Foundation
@MainActor private final class API: JournalAuthenticationAPI {
  var calls = 0, cancellations = 0
  var failure: Error?
  var hold: CheckedContinuation<Void, Error>?
  var suspended = false
  func signIn() async throws {
    calls += 1
    if suspended { try await withCheckedThrowingContinuation { hold = $0 } }
    if let failure { throw failure }
  }
  func cancelSignIn() { cancellations += 1 }
}
@main struct JournalAuthenticationTests {
  @MainActor static func main() async throws {
    let api = API(), owner = JournalAuthentication(api: API())
    precondition(owner.canSubmit, "No credentials required")
    let model = JournalAuthentication(api: api)
    api.failure = URLError(.notConnectedToInternet); await model.submit()
    precondition(model.message != nil && model.canSubmit && !model.complete)
    api.failure = CancellationError(); await model.submit()
    precondition(model.message == nil && model.canSubmit && !model.complete)
    api.failure = nil; api.suspended = true
    let old = Task { await model.submit() }
    while api.hold == nil { await Task.yield() }
    await model.submit(); precondition(api.calls == 3 && model.busy)
    model.cancel(); api.hold!.resume(); await old.value
    precondition(!model.complete && !model.busy && api.cancellations == 1)
    api.suspended = false; await model.submit()
    precondition(model.complete && !model.canSubmit)
    print("PASS credential-free presentation, error retry, cancel, duplicate and retired completion")
  }
}
