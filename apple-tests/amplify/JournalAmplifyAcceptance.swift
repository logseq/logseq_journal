import Amplify
import AWSCognitoAuthPlugin
import BonsaiSwiftUI
import SwiftUI

@MainActor private final class HubAcceptanceAuth: JournalAuthCapability {
  var lookups = 0
  func currentUserID() async throws -> String? { lookups += 1; return nil }
  func freshIDToken() async throws -> String { throw CancellationError() }
  func signOut() async throws { throw CancellationError() }
}

struct JournalAmplifyAcceptance: View {
  @State private var result = "Waiting for configuration"
  @State private var platform: JournalApplicationPlatform
  private let auth: HubAcceptanceAuth

  init() {
    let auth = HubAcceptanceAuth()
    self.auth = auth
    _platform = State(initialValue: JournalApplicationPlatform(services: JournalPlatformServices(
      auth: auth, account: JournalAccountStore(load: { nil }, save: { _ in }, clear: {}),
      managedSyncOrigin: "https://example.invalid")))
  }

  var body: some View {
    VStack {
      Text(result).padding()
      Button("Test SDK Hub callbacks") { Task { await testHubCallbacks() } }
      BonsaiApplicationView(entrypoint: "journal_gate", applicationBridge: platform.bridge)
        .environment(\.scenePhase, .active)
        .frame(height: 80)
    }.task {
      do {
        // No user lookup, token retrieval or credential mutation is requested.
        try JournalAmplifySession.configure()
        try JournalAmplifySession.configure()
        guard try Amplify.Auth.getPlugin(for: "awsCognitoAuthPlugin") is AWSCognitoAuthPlugin else {
          result = "FAIL: Cognito plugin is unavailable"
          return
        }
        result = "PASS: Real Cognito plugin configured; repeated configuration is safe"
      } catch {
        result = "FAIL: Configuration failed"
      }
    }
  }

  @MainActor private func testHubCallbacks() async {
    for name in [HubPayload.EventName.Auth.signedIn, HubPayload.EventName.Auth.signedOut,
                 HubPayload.EventName.Auth.sessionExpired, HubPayload.EventName.Auth.userDeleted] {
      let before = auth.lookups
      await Task.detached {
        Amplify.Hub.dispatch(to: .auth, payload: HubPayload(eventName: name))
      }.value
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while auth.lookups == before && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
      guard auth.lookups > before, platform.authenticationRequired else {
        result = "FAIL: SDK Hub callback did not reach the native auth owner"
        return
      }
    }
    result = "PASS: All four SDK Hub callbacks safely refresh native authentication"
  }
}
