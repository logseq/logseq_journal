import Foundation
@MainActor private final class API: JournalAuthenticationAPI {
  var calls = 0, cancellations = 0
  var failure: Error?
  var hold: CheckedContinuation<Void, Error>?
  var suspended = false
  var preparations = 0
  var preparationFailure: Error?
  var preparationHold: CheckedContinuation<Void, Error>?
  var suspendPreparation = false
  var accountPreparationMessage: String? = "Secure account storage is unavailable. Unlock your device, then retry."
  func signIn() async throws {
    calls += 1
    if suspended { try await withCheckedThrowingContinuation { hold = $0 } }
    if let failure { throw failure }
  }
  func cancelSignIn() { cancellations += 1 }
  func prepareAccount() async throws {
    preparations += 1
    if suspendPreparation { try await withCheckedThrowingContinuation { preparationHold = $0 } }
    if let preparationFailure { throw preparationFailure }
  }
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
    precondition(api.preparations == 1, "A successful browser sign-in must finish account preparation")
    let preparing = API()
    preparing.preparationFailure = URLError(.notConnectedToInternet)
    let preparation = JournalAuthentication(api: preparing)
    await preparation.submit()
    precondition(!preparation.complete && preparation.canSubmit && preparation.message != nil,
      "Preparation failure must keep the sign-in retry available")
    preparing.preparationFailure = NSError(domain: "synthetic-storage", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "SECRET"])
    await preparation.submit()
    precondition(preparation.message == preparing.accountPreparationMessage,
      "Preparation failure must display the owner's safe recovery instructions")
    preparing.preparationFailure = nil; preparing.suspendPreparation = true
    let pendingPreparation = Task { await preparation.submit() }
    for _ in 0..<1000 { if preparing.preparationHold != nil { break }; await Task.yield() }
    precondition(preparing.preparationHold != nil, "Account preparation must be awaited")
    await preparation.submit()
    precondition(preparing.calls == 3 && preparation.busy, "Repeated submit cannot repeat account preparation")
    preparation.cancel()
    preparing.preparationHold!.resume()
    await pendingPreparation.value
    precondition(!preparation.complete && preparation.canSubmit, "Retired account preparation cannot finish sign-in")
    preparing.suspendPreparation = false
    await preparation.submit()
    precondition(preparation.complete, "Retry after canceled preparation must succeed")
    let privateFailure = API()
    privateFailure.failure = NSError(domain: "fixture", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "token=SECRET password=SECRET binding=SECRET"])
    let failed = JournalAuthentication(api: privateFailure)
    await failed.submit()
    precondition(failed.canSubmit && failed.message != nil && !failed.message!.contains("SECRET"),
      "Authentication errors must be sanitized and retryable")
    print("PASS credential-free presentation, error retry, cancel, duplicate and retired completion")
  }
}
