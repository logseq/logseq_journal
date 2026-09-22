import SwiftUI

struct JournalAuthenticationView: View {
  @State private var model: JournalAuthentication
  @State private var operation: Task<Void, Never>?
  private enum Field: Hashable { case username, password, confirmation, newPassword }
  @FocusState private var focusedField: Field?
  let authenticated: () -> Void

  init(api: any JournalAuthenticationAPI, authenticated: @escaping () -> Void) {
    _model = State(initialValue: JournalAuthentication(api: api))
    self.authenticated = authenticated
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text(title)
          .font(.title).bold()
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        fields
        if let message = model.message {
          Text(message).foregroundStyle(.primary).accessibilityIdentifier("authentication-message")
        }
        if model.busy {
          ProgressView("Please wait…").accessibilityIdentifier("authentication-progress")
        }
        Button(submitLabel) { submit() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canSubmit)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("authentication-submit")
        if model.step == .signIn {
          Button("Forgot password?") { model.forgotPassword() }
            .buttonStyle(.bordered).disabled(model.busy)
        } else if model.step != .complete {
          Button("Back to sign in") { model.back() }
            .buttonStyle(.bordered).disabled(model.busy)
        }
      }
      .textFieldStyle(.roundedBorder)
      .frame(maxWidth: 440, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity)
      .tint(.primary)
      .disabled(model.busy)
    }
    .navigationTitle("Account")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task(id: model.step) { focusFirstField() }
    .onDisappear { operation?.cancel(); model.cancel() }
    .onChange(of: model.step) { _, step in
      if step == .complete { authenticated() }
    }
  }

  @ViewBuilder private var fields: some View {
    switch model.step {
    case .signIn:
      usernameField.submitLabel(.next).onSubmit { focusedField = .password }
      SecureField("Password", text: $model.password).textContentType(.password)
        .focused($focusedField, equals: .password)
        .submitLabel(.go).onSubmit { submit() }
        .accessibilityIdentifier("authentication-password")
    case .resetRequest:
      usernameField.submitLabel(.go).onSubmit { submit() }
    case .resetConfirmation(let destination):
      Text("Enter the code sent to \(destination).")
      codeField("Verification code").submitLabel(.next)
        .focused($focusedField, equals: .confirmation)
        .onSubmit { focusedField = .newPassword }
      SecureField("New password", text: $model.newPassword).textContentType(.newPassword)
        .focused($focusedField, equals: .newPassword)
        .submitLabel(.go).onSubmit { submit() }
    case .confirmAccount(let destination):
      Text("Enter the confirmation code sent to \(destination).")
      codeField("Confirmation code").submitLabel(.go).onSubmit { submit() }
        .focused($focusedField, equals: .confirmation)
      Button("Resend code") { operation = Task { await model.resend() } }
        .buttonStyle(.bordered).disabled(model.busy)
    case .challenge(let challenge):
      if let detail = challenge.detail { Text(detail).textSelection(.enabled) }
      if !challenge.choices.isEmpty {
        Picker(challenge.prompt, selection: $model.confirmation) {
          Text("Choose a method").tag("")
          ForEach(challenge.choices, id: \.self) { value in Text(Self.methodName(value)).tag(value) }
        }
      } else {
        challengeField(challenge)
          .focused($focusedField, equals: .confirmation)
          .submitLabel(.go).onSubmit { submit() }
          .accessibilityIdentifier("authentication-challenge")
      }
    case .complete: ProgressView("Opening your account")
    }
  }

  @ViewBuilder private func challengeField(_ challenge: JournalAuthenticationStep.Challenge) -> some View {
    switch challenge.input {
    case .password, .newPassword:
      SecureField(challenge.prompt, text: $model.confirmation)
        .textContentType(challenge.input == .newPassword ? .newPassword : .password)
    case .oneTimeCode:
      codeField(challenge.prompt)
    case .emailAddress:
      TextField(challenge.prompt, text: $model.confirmation)
        .textContentType(.emailAddress)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never).keyboardType(.emailAddress)
        #endif
    case .text:
      TextField(challenge.prompt, text: $model.confirmation)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }
  }

  private var usernameField: some View {
    TextField("Username", text: $model.username).textContentType(.username)
      .autocorrectionDisabled().focused($focusedField, equals: .username)
      .accessibilityIdentifier("authentication-username")
      #if os(iOS)
      .textInputAutocapitalization(.never)
      #endif
  }

  private func codeField(_ title: String) -> some View {
    TextField(title, text: $model.confirmation).textContentType(.oneTimeCode)
      .autocorrectionDisabled()
      #if os(iOS)
      .textInputAutocapitalization(.never).keyboardType(.asciiCapable)
      #endif
  }

  private func focusFirstField() {
    switch model.step {
    case .signIn: focusedField = model.username.isEmpty ? .username : .password
    case .resetRequest: focusedField = .username
    case .resetConfirmation, .confirmAccount: focusedField = .confirmation
    case .challenge(let challenge): focusedField = challenge.choices.isEmpty ? .confirmation : nil
    case .complete: focusedField = nil
    }
  }

  private var title: String {
    switch model.step {
    case .signIn: return "Sign in to Logseq"
    case .resetRequest, .resetConfirmation: return "Reset your password"
    case .confirmAccount: return "Confirm your account"
    case .challenge(let challenge): return challenge.title
    case .complete: return "Signed in"
    }
  }

  private var submitLabel: String {
    switch model.step {
    case .signIn: return "Sign in"
    case .resetRequest: return "Send reset code"
    case .resetConfirmation: return "Update password"
    default: return "Continue"
    }
  }

  private func submit() {
    guard model.canSubmit else { return }
    operation = Task { await model.submit() }
  }

  private static func methodName(_ value: String) -> String {
    switch value {
    case "SMS_MFA", "SMS_OTP": return "Text message"
    case "SOFTWARE_TOKEN_MFA": return "Authenticator app"
    case "EMAIL_OTP": return "Email"
    case "PASSWORD", "PASSWORD_SRP": return "Password"
    case "WEB_AUTHN": return "Passkey"
    default: return "Verification"
    }
  }
}
