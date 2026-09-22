import Amplify
import AWSCognitoAuthPlugin
import Foundation

@MainActor struct JournalAmplifyAuthentication: JournalAuthenticationAPI {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  func perform(_ command: JournalAuthenticationCommand) async throws -> JournalAuthenticationStep {
    do {
      try JournalAmplifySession.configure()
      switch command {
      case .signIn(let username, let password):
        return try Self.step(await Amplify.Auth.signIn(username: username, password: password).nextStep)
      case .confirm(let response):
        return try Self.step(await Amplify.Auth.confirmSignIn(challengeResponse: response).nextStep)
      case .requestReset(let username):
        let result = try await Amplify.Auth.resetPassword(for: username)
        switch result.nextStep {
        case .confirmResetPasswordWithCode(let delivery, _): return .resetConfirmation(Self.destination(delivery))
        case .done: return .signIn
        }
      case .confirmReset(let username, let code, let password):
        try await Amplify.Auth.confirmResetPassword(for: username, with: password, confirmationCode: code)
        return .signIn
      case .confirmAccount(let username, let code):
        let result = try await Amplify.Auth.confirmSignUp(for: username, confirmationCode: code)
        switch result.nextStep {
        case .done, .completeAutoSignIn: return .signIn
        case .confirmUser(let delivery, _, _): return .confirmAccount(delivery.map(Self.destination) ?? "your email or phone")
        }
      case .resendAccount(let username):
        return .confirmAccount(Self.destination(try await Amplify.Auth.resendSignUpCode(for: username)))
      }
    } catch let error as AuthError {
      throw Failure(message: error.errorDescription)
    }
  }

  static func step(_ step: AuthSignInStep) throws -> JournalAuthenticationStep {
    typealias Challenge = JournalAuthenticationStep.Challenge
    switch step {
    case .done: return .complete
    case .resetPassword: return .resetRequest
    case .confirmSignUp: return .confirmAccount("your email or phone")
    case .confirmSignInWithSMSMFACode(let delivery, _), .confirmSignInWithOTP(let delivery):
      return .challenge(Challenge(title: "Verify your sign-in", prompt: "Verification code", input: .oneTimeCode, detail: "Code sent to \(destination(delivery))"))
    case .confirmSignInWithTOTPCode:
      return .challenge(Challenge(title: "Verify your sign-in", prompt: "Authenticator code", input: .oneTimeCode))
    case .confirmSignInWithNewPassword:
      return .challenge(Challenge(title: "Choose a new password", prompt: "New password", input: .newPassword))
    case .confirmSignInWithPassword:
      return .challenge(Challenge(title: "Enter your password", prompt: "Password", input: .password))
    case .confirmSignInWithCustomChallenge(let info):
      return .challenge(Challenge(title: "Verify your sign-in", prompt: info?["prompt"] ?? "Verification response"))
    case .continueSignInWithTOTPSetup(let details):
      return .challenge(Challenge(title: "Set up an authenticator", prompt: "Authenticator code", input: .oneTimeCode,
        detail: "Add this setup key to your authenticator, then enter its code: \(details.sharedSecret)"))
    case .continueSignInWithEmailMFASetup:
      return .challenge(Challenge(title: "Set up email verification", prompt: "Email address", input: .emailAddress))
    case .continueSignInWithMFASelection(let choices), .continueSignInWithMFASetupSelection(let choices):
      return .challenge(Challenge(title: "Choose a verification method", prompt: "Method", choices: choices.map(\.challengeResponse).sorted()))
    case .continueSignInWithFirstFactorSelection(let choices):
      return .challenge(Challenge(title: "Choose a sign-in method", prompt: "Method", choices: choices.map(\.challengeResponse).sorted()))
    }
  }

  static func destination(_ details: AuthCodeDeliveryDetails) -> String {
    switch details.destination {
    case .email(let value): return value ?? "your email"
    case .phone(let value), .sms(let value): return value ?? "your phone"
    case .unknown(let value): return value ?? "your account contact"
    }
  }
}
