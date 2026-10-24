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
    // The native presentation owner owns this failure mapping. These public
    // submit/cancel paths cannot be reproduced by the OCaml graph reducer.
    let known: [JournalCognitoError] = [.configuration, .callback, .expired,
      .invalidToken, .storage, .unavailable, .request, .invalidGrant]
    for reason in known {
      let knownAPI = API()
      knownAPI.failure = reason
      let knownModel = JournalAuthentication(api: knownAPI)
      await knownModel.submit()
      precondition(knownModel.message == reason.errorDescription && knownModel.canSubmit,
        "Known browser failure must retain its fixed recovery reason")
      knownAPI.failure = nil
      knownAPI.preparationFailure = reason
      await knownModel.submit()
      precondition(knownModel.message == reason.errorDescription && knownModel.canSubmit,
        "Known preparation failure must retain its fixed recovery reason")
    }
    let detailedAPI = API()
    let detailed = JournalCognitoFailure(category: .request,
      detail: .init(source: .token, reason: .httpStatus, httpStatus: 401, oauth: .invalid_client))
    detailedAPI.failure = detailed
    let detailedModel = JournalAuthentication(api: detailedAPI)
    await detailedModel.submit()
    precondition(detailedModel.message == detailed.errorDescription
      && detailedModel.message!.contains("token.httpStatus")
      && detailedModel.message!.contains("http 401")
      && detailedModel.canSubmit && !detailedModel.complete,
      "Known safe upstream detail must survive direct sign-in presentation")
    detailedAPI.failure = nil
    detailedAPI.preparationFailure = detailed
    await detailedModel.submit()
    precondition(detailedModel.message == detailed.errorDescription && detailedModel.canSubmit,
      "Known safe upstream detail must survive preparation presentation")
    let kinds: [JournalAccountIssue.Kind] = [.unsupportedFormat, .corruptBinding,
      .secureStorageUnavailable, .network, .signInRequired, .accountChangeBlocked, .unavailable]
    for kind in kinds {
      let issue = JournalAccountIssue(kind: kind, stage: .identityLookup)
      let issueAPI = API()
      issueAPI.failure = issue
      let issueModel = JournalAuthentication(api: issueAPI)
      await issueModel.submit()
      precondition(issueModel.message == issue.errorDescription,
        "Known account issue must retain its fixed recovery reason")
      issueAPI.failure = nil
      issueAPI.preparationFailure = issue
      await issueModel.submit()
      precondition(issueModel.message == issue.errorDescription,
        "Known account preparation issue must retain its fixed recovery reason")
    }
    let cancelledAPI = API()
    cancelledAPI.suspended = true
    let cancelledModel = JournalAuthentication(api: cancelledAPI)
    let cancelledSubmit = Task { await cancelledModel.submit() }
    while cancelledAPI.hold == nil { await Task.yield() }
    cancelledModel.cancel()
    cancelledAPI.hold!.resume(throwing: JournalCognitoError.storage)
    await cancelledSubmit.value
    precondition(cancelledModel.message == nil && !cancelledModel.complete && !cancelledModel.busy,
      "Retired known error cannot overwrite a cancelled presentation")
    let unknownPreparation = API()
    unknownPreparation.accountPreparationMessage = nil
    unknownPreparation.preparationFailure = NSError(domain: "fixture", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "token=SECRET password=SECRET"])
    let unknownModel = JournalAuthentication(api: unknownPreparation)
    await unknownModel.submit()
    precondition(unknownModel.message == "Unable to complete your account connection. Please try again.",
      "Unknown preparation error must keep the safe fallback")
    print("PASS credential-free presentation, error retry, cancel, duplicate and retired completion")
  }
}
