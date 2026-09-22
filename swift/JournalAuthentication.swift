import Foundation
import Observation

/// Native authentication presentation only; account and graph decisions stay in OCaml.
enum JournalAuthenticationStep: Equatable {
  struct Challenge: Equatable {
    let title: String
    let prompt: String
    enum Input: Equatable { case text, oneTimeCode, password, newPassword, emailAddress }
    var input = Input.text
    var detail: String? = nil
    var choices: [String] = []
  }
  case signIn, resetRequest, resetConfirmation(String), confirmAccount(String)
  case challenge(Challenge)
  case complete
}

enum JournalAuthenticationCommand: Equatable {
  case signIn(username: String, password: String)
  case confirm(String)
  case requestReset(String)
  case confirmReset(username: String, code: String, password: String)
  case confirmAccount(username: String, code: String)
  case resendAccount(String)
}

@MainActor protocol JournalAuthenticationAPI {
  func perform(_ command: JournalAuthenticationCommand) async throws -> JournalAuthenticationStep
}

@Observable @MainActor final class JournalAuthentication {
  var username = ""
  var password = ""
  var confirmation = ""
  var newPassword = ""
  private(set) var step = JournalAuthenticationStep.signIn
  private(set) var busy = false
  private(set) var message: String?
  @ObservationIgnored private let api: any JournalAuthenticationAPI
  @ObservationIgnored private var revision: UInt64 = 0

  init(api: any JournalAuthenticationAPI) { self.api = api }
  private var user: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

  var canSubmit: Bool {
    guard !busy else { return false }
    switch step {
    case .signIn: return !user.isEmpty && !password.isEmpty
    case .resetRequest: return !user.isEmpty
    case .resetConfirmation: return !user.isEmpty && !confirmation.isEmpty && !newPassword.isEmpty
    case .confirmAccount: return !user.isEmpty && !confirmation.isEmpty
    case .challenge(let challenge):
      return !confirmation.isEmpty && (challenge.choices.isEmpty || challenge.choices.contains(confirmation))
    case .complete: return false
    }
  }

  func submit() async {
    guard canSubmit else { return }
    let command: JournalAuthenticationCommand
    switch step {
    case .signIn: command = .signIn(username: user, password: password)
    case .resetRequest: command = .requestReset(user)
    case .resetConfirmation: command = .confirmReset(username: user, code: confirmation, password: newPassword)
    case .confirmAccount: command = .confirmAccount(username: user, code: confirmation)
    case .challenge: command = .confirm(confirmation)
    case .complete: return
    }
    await perform(command)
  }

  func forgotPassword() {
    guard !busy else { return }
    clearSecrets()
    message = nil
    step = .resetRequest
  }

  func back() {
    guard !busy else { return }
    clearSecrets()
    message = nil
    step = .signIn
  }

  func resend() async {
    guard !busy, case .confirmAccount = step, !user.isEmpty else { return }
    await perform(.resendAccount(user))
  }

  func cancel() {
    revision &+= 1
    clearSecrets()
    message = nil
    step = .signIn
  }

  private func perform(_ command: JournalAuthenticationCommand) async {
    busy = true
    message = nil
    let current = revision
    defer { busy = false }
    do {
      let next = try await api.perform(command)
      try Task.checkCancellation()
      guard revision == current else { return }
      clearSecrets()
      step = next
      if next == .signIn {
        switch command {
        case .confirmReset: message = "Password updated. Sign in with your new password."
        case .confirmAccount: message = "Account confirmed. Sign in to continue."
        default: break
        }
      }
    } catch is CancellationError {
      if revision == current { clearSecrets() }
    } catch {
      if revision == current { message = error.localizedDescription }
    }
  }

  private func clearSecrets() {
    password = ""
    confirmation = ""
    newPassword = ""
  }
}
