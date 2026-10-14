import Foundation
import SwiftUI
import Observation

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

@Observable @MainActor private final class ProbeAccount: JournalAuthCapability, JournalAuthenticationAPI {
  var issue: JournalAccountIssue?
  var bytes = Data(#"{"version":1,"userId":"retained-synthetic-account","managedSyncOrigin":"https://api.logseq.io"}"#.utf8)
  var verified = false
  let scenario: String
  @ObservationIgnored lazy var services = JournalPlatformServices(auth: self,
    account: JournalAccountStore(load: { @MainActor in
      let value = try JournalLocalAccountBindingStore.decode(self.bytes)
      return JournalLocalAccount(userID: value["userId"] as! String,
        managedSyncOrigin: value["managedSyncOrigin"] as! String)
    }, save: { @MainActor binding in
      if self.scenario == "prepare-error" {
        throw JournalAccountIssue(kind: .secureStorageUnavailable, stage: .bindingWrite)
      }
      let previous = self.bytes
      self.bytes = try JournalLocalAccountBindingStore.encode(userID: binding.userID, managedSyncOrigin: binding.managedSyncOrigin)
      return JournalAccountSave(commit: {}, rollback: { self.bytes = previous })
    }, clear: { preconditionFailure("Synthetic recovery must never clear the binding") }),
    managedSyncOrigin: "https://api.logseq.io")
  init() {
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1) {
      scenario = arguments[index + 1]
    } else { scenario = "success" }
  }
  func inspect() async {
    _ = try? await services.response(for: .localAccount)
    issue = services.accountIssue
  }
  func currentUserID() async throws -> String? { verified ? "verified-synthetic-user" : nil }
  func freshIDToken() async throws -> String { "synthetic-token" }
  func signOut() async throws { preconditionFailure("Recovery never signs out") }
  func signIn() async throws {
    try await ProbeAuthentication(scenario: scenario).signIn()
    verified = true
  }
  func cancelSignIn() { services.invalidateConnection() }
  var accountPreparationMessage: String? {
    issue.map { ($0.errorDescription ?? "") + "\n" + $0.diagnostic }
  }
  func prepareAccount() async throws {
    do {
      _ = try await services.response(for: .authenticatedUser)
      issue = services.accountIssue
    } catch { issue = services.accountIssue; throw error }
  }
}

@main struct AuthenticationProbe: App {
  @State private var complete = false
  @State private var presented = false
  @State private var account = ProbeAccount()
  private let arguments = ProcessInfo.processInfo.arguments
  private var scenario: String {
    guard let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1) else { return "code" }
    return arguments[index + 1]
  }
  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading, spacing: 20) {
        if complete {
          Text("Account connected").font(.title).accessibilityIdentifier("probe-complete")
          Text("Current-format binding is ready. Graph selection can continue.")
        } else {
          JournalAccountRecoveryView(issue: account.issue, signInAvailable: true,
            signIn: { presented = true }, retry: { Task { await account.inspect() } })
          Text("Synthetic account preparation failure").foregroundStyle(.secondary)
          Button("Retry") { Task { await account.inspect() } }
        }
      }
      .task { await account.inspect() }
      .sheet(isPresented: $presented) {
        NavigationStack {
          JournalAuthenticationView(api: account) {
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
