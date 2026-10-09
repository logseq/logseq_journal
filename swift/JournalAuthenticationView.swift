import SwiftUI

struct JournalAuthenticationView: View {
  @State private var model: JournalAuthentication
  @State private var operation: Task<Void, Never>?
  let authenticated: () -> Void
  init(api: any JournalAuthenticationAPI, authenticated: @escaping () -> Void) {
    _model = State(initialValue: JournalAuthentication(api: api))
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
        Button {
          operation = Task {
            await model.submit()
            if model.complete && !Task.isCancelled { authenticated() }
          }
        } label: {
          HStack {
            if model.busy { ProgressView() }
            Text(model.busy ? "Opening sign-in…" : "Continue to sign in")
          }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).disabled(!model.canSubmit)
        .accessibilityIdentifier("authentication-submit")
        if model.busy {
          Button("Cancel", role: .cancel) { cancel() }
        }
      }.padding(24).frame(maxWidth: 480, alignment: .leading)
    }
    .onDisappear { cancel() }
  }
  private func cancel() { operation?.cancel(); operation = nil; model.cancel() }
}
