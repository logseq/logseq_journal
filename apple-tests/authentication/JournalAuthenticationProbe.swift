import Foundation
import SwiftUI

/// The real presentation and owner run with a local provider; no account is accessed.
@MainActor private struct ProbeAuthentication: JournalAuthenticationAPI {
  struct Failure: LocalizedError {
    var errorDescription: String? { "The verification code is incorrect. Try again." }
  }
  let scenario: String
  func perform(_ command: JournalAuthenticationCommand) async throws -> JournalAuthenticationStep {
    switch command {
    case .signIn:
      try await Task.sleep(for: .milliseconds(300))
      switch scenario {
      case "email":
        return .challenge(.init(title: "Set up email verification", prompt: "Email address", input: .emailAddress))
      case "new-password":
        return .challenge(.init(title: "Choose a new password", prompt: "New password", input: .newPassword))
      case "methods":
        return .challenge(.init(title: "Choose a verification method", prompt: "Method", choices: ["SMS_MFA", "SOFTWARE_TOKEN_MFA"]))
      default:
        return .challenge(.init(title: "Verify your sign-in", prompt: "Verification code", input: .oneTimeCode,
          detail: "Code sent to a***@example.com"))
      }
    case .confirm(let response):
      if scenario == "code" && response != "123456" { throw Failure() }
      return .complete
    case .requestReset: return .resetConfirmation("a***@example.com")
    case .confirmReset, .confirmAccount: return .signIn
    case .resendAccount: return .confirmAccount("a***@example.com")
    }
  }
}

@main struct AuthenticationProbe: App {
  @State private var complete = false
  @State private var presented = true
  private let arguments = ProcessInfo.processInfo.arguments
  private var scenario: String {
    guard let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1) else { return "code" }
    return arguments[index + 1]
  }
  var body: some Scene {
    WindowGroup {
      VStack {
        if complete { Text("Authentication completed").accessibilityIdentifier("probe-complete") }
        else if !presented { Text("Authentication closed").accessibilityIdentifier("probe-closed") }
      }
      .sheet(isPresented: $presented) {
        NavigationStack {
          JournalAuthenticationView(api: ProbeAuthentication(scenario: scenario)) {
            complete = true
            presented = false
          }
            .toolbar {
              ToolbarItem(placement: .cancellationAction) { Button("Close", role: .cancel) { presented = false } }
            }
        }
        .presentationSizing(.form)
        .presentationDetents([.large])
        .frame(idealWidth: 480)
        .environment(\.dynamicTypeSize, arguments.contains("--large-text") ? .accessibility3 : .large)
        .environment(\.layoutDirection, arguments.contains("--rtl") ? .rightToLeft : .leftToRight)
      }
      .preferredColorScheme(arguments.contains("--dark") ? .dark : .light)
    }
  }
}
