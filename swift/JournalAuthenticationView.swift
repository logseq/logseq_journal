import SwiftUI

/// This stays visible after browser cancellation or a failed account attempt.
struct JournalAccountRecoveryView: View {
  let issue: JournalAccountIssue?
  let signInAvailable: Bool
  let signIn: () -> Void
  var retry: (() -> Void)? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(issue?.errorDescription ?? "Sign in to connect your account")
        .accessibilityIdentifier("account-recovery-message")
      if let issue {
        Text("Your local graphs and pending changes are retained.")
          .font(.callout).foregroundStyle(.secondary)
        Text(issue.diagnostic).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("account-recovery-diagnostic")
      }
      HStack {
        if signInAvailable {
          Button("Sign in again", action: signIn).buttonStyle(.borderedProminent)
            .accessibilityIdentifier("journal-sign-in")
        }
        if let retry {
          Button("Retry", action: retry).buttonStyle(.bordered)
            .accessibilityIdentifier("account-recovery-retry")
        }
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct JournalAuthenticationView: View {
  @State private var model: JournalAuthentication
  @State private var operation: Task<Void, Never>?
  @State private var automaticStartConsumed = false
  let startsImmediately: Bool
  let cancelled: () -> Void
  let authenticated: () -> Void
  init(api: any JournalAuthenticationAPI, startsImmediately: Bool = false,
    cancelled: @escaping () -> Void = {}, authenticated: @escaping () -> Void) {
    _model = State(initialValue: JournalAuthentication(api: api))
    self.startsImmediately = startsImmediately
    self.cancelled = cancelled
    self.authenticated = authenticated
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Sign in to Logseq").font(.title).bold().accessibilityAddTraits(.isHeader)
        Text("Continue to the secure sign-in page to sign in or recover your account.")
          .foregroundStyle(.secondary)
        if let message = model.message {
          Text(message).foregroundStyle(.red).accessibilityIdentifier("authentication-error")
        }
        Button(action: submit) {
          HStack {
            if model.busy { ProgressView() }
            Text(model.busy ? "Opening sign-in…" : "Continue to sign in")
          }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).disabled(!model.canSubmit)
        .accessibilityIdentifier("authentication-submit")
        if model.busy {
          Button("Cancel", role: .cancel) {
            cancel()
            if startsImmediately { cancelled() }
          }
        }
      }.padding(24).frame(maxWidth: 480, alignment: .leading)
    }
    .task {
      guard startsImmediately && !automaticStartConsumed else { return }
      automaticStartConsumed = true
      submit()
    }
    .onDisappear { cancel() }
  }
  private func submit() {
    guard operation == nil && model.canSubmit else { return }
    operation = Task {
      await model.submit()
      guard !Task.isCancelled else { return }
      operation = nil
      if model.complete { authenticated() }
      else if startsImmediately && model.message == nil { cancelled() }
    }
  }
  private func cancel() { operation?.cancel(); operation = nil; model.cancel() }
}
