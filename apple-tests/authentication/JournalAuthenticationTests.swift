import Foundation

@MainActor private final class API: JournalAuthenticationAPI {
  var commands: [JournalAuthenticationCommand] = []
  var next = JournalAuthenticationStep.complete
  var fail = false
  var hold = false
  var continuation: CheckedContinuation<JournalAuthenticationStep, Error>?
  func perform(_ command: JournalAuthenticationCommand) async throws -> JournalAuthenticationStep {
    commands.append(command)
    if hold { return try await withCheckedThrowingContinuation { continuation = $0 } }
    if fail { throw NSError(domain: "Authentication failed", code: 1) }
    return next
  }
}

@main struct JournalAuthenticationTests {
  static func check(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: message, code: 1) }
  }
  @MainActor static func main() async throws {
    let api = API()
    let model = JournalAuthentication(api: api)
    try check(!model.canSubmit, "empty sign-in accepted")
    await model.submit()
    try check(api.commands.isEmpty, "empty form reached provider")
    model.username = " alice "
    model.password = "secret"
    try check(model.canSubmit, "valid sign-in disabled")
    api.fail = true
    await model.submit()
    try check(model.step == .signIn && model.password == "secret" && model.message != nil && !model.busy,
      "sign-in failure lost retry state")
    api.fail = false
    let challenge = JournalAuthenticationStep.challenge(.init(title: "Verification", prompt: "Code"))
    api.next = challenge
    await model.submit()
    try check(api.commands.last == .signIn(username: "alice", password: "secret"), "credentials changed")
    try check(model.step == challenge && model.password.isEmpty && !model.canSubmit, "challenge transition retained password")
    model.confirmation = "123456"
    api.next = .complete
    await model.submit()
    try check(api.commands.last == .confirm("123456") && model.step == .complete && model.confirmation.isEmpty,
      "challenge did not finish or retained its code")
    print("PASS sign-in, failure retry, challenge and secret cleanup")

    model.back()
    model.username = "alice"
    model.forgotPassword()
    try check(model.step == .resetRequest && model.canSubmit, "reset request inaccessible")
    api.next = .resetConfirmation("a***@example.com")
    await model.submit()
    try check(api.commands.last == .requestReset("alice") && !model.canSubmit, "reset request changed")
    model.confirmation = "654321"
    model.newPassword = "replacement"
    api.next = .signIn
    await model.submit()
    try check(api.commands.last == .confirmReset(username: "alice", code: "654321", password: "replacement"), "reset values lost")
    try check(model.step == .signIn && model.newPassword.isEmpty && model.confirmation.isEmpty, "reset did not clear secrets")
    print("PASS password reset")

    model.password = "secret"
    api.next = .confirmAccount("email")
    await model.submit()
    await model.resend()
    try check(api.commands.last == .resendAccount("alice"), "account code resend unavailable")
    model.confirmation = "123456"
    api.next = .signIn
    await model.submit()
    try check(api.commands.last == .confirmAccount(username: "alice", code: "123456"), "account confirmation changed")
    print("PASS account confirmation and resend")

    model.password = "secret"
    api.hold = true
    let pending = Task { await model.submit() }
    while api.continuation == nil { await Task.yield() }
    let count = api.commands.count
    await model.submit()
    model.forgotPassword()
    try check(api.commands.count == count && model.busy && model.step == .signIn, "busy form launched concurrent auth")
    model.cancel()
    api.continuation?.resume(returning: .complete)
    await pending.value
    try check(model.step == .signIn && !model.busy && model.password.isEmpty, "retired auth completion changed the form")
    print("PASS duplicate submission and retired completion fencing")
  }
}
