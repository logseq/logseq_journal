import Amplify
import AWSCognitoAuthPlugin
import Foundation

@MainActor final class JournalAmplifySession: JournalAuthCapability {
  private static var configuration: Result<Void, Error>?

  static func configure() throws {
    if let configuration { return try configuration.get() }
    let result = Result {
      let value = try JSONDecoder().decode(AmplifyConfiguration.self, from: Data(#"""
        {
          "auth": {
            "plugins": {
              "awsCognitoAuthPlugin": {
                "CognitoUserPool": {
                  "Default": {
                    "PoolId": "us-east-1_dtagLnju8",
                    "AppClientId": "69cs1lgme7p8kbgld8n5kseii6",
                    "Region": "us-east-1"
                  }
                },
                "Auth": {
                  "Default": { "authenticationFlowType": "USER_SRP_AUTH" }
                }
              }
            }
          }
        }
        """#.utf8))
      try Amplify.add(plugin: AWSCognitoAuthPlugin())
      try Amplify.configure(value)
    }
    configuration = result
    try result.get()
  }

  func currentUserID() async throws -> String? {
    try Self.configure()
    do {
      let session = try await Amplify.Auth.fetchAuthSession()
      guard session.isSignedIn else { return nil }
      return try await Amplify.Auth.getCurrentUser().userId
    } catch AuthError.signedOut {
      return nil
    }
  }

  func freshIDToken() async throws -> String {
    try Self.configure()
    do {
      let session = try await Amplify.Auth.fetchAuthSession()
      guard session.isSignedIn else { throw JournalPlatformServices.Failure.authenticationRequired }
      guard let cognito = session as? AWSAuthCognitoSession else {
        throw JournalPlatformServices.Failure.unavailable
      }
      return try cognito.getCognitoTokens().get().idToken
    } catch AuthError.signedOut {
      throw JournalPlatformServices.Failure.authenticationRequired
    }
  }

  func signOut() async throws {
    try Self.configure()
    guard let result = await Amplify.Auth.signOut() as? AWSCognitoSignOutResult else {
      throw JournalPlatformServices.Failure.unavailable
    }
    switch result {
    case .complete, .partial: return
    case .failed(let error): throw error
    }
  }
}
