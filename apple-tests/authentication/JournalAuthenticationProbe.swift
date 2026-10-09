import Foundation
import SwiftUI

/// The real presentation and owner run with a local provider; no account is accessed.
@MainActor private struct ProbeAuthentication: JournalAuthenticationAPI {
  let scenario: String
  func signIn() async throws {
    try await Task.sleep(for: .milliseconds(scenario == "busy" ? 15000 : 300))
    if scenario == "cancel" { throw CancellationError() }
    if scenario == "error" { throw URLError(.notConnectedToInternet) }
  }
  func cancelSignIn() { }
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
