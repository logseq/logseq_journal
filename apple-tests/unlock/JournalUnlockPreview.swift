import SwiftUI

/// Visual acceptance only; no account, graph storage or password submission.
@main struct JournalUnlockPreview: App {
  var body: some Scene {
    WindowGroup("Unlock layout preview") {
      UnlockPreview()
    }
    #if os(macOS)
    .defaultSize(width: 390, height: 700)
    #endif
  }
}

private struct UnlockPreview: View {
  @State private var password = ""
  @State private var failed = false
  @FocusState private var focused: Bool
  private let arguments = ProcessInfo.processInfo.arguments
  private var longContent: Bool { arguments.contains("--long") }

  var body: some View {
    NavigationStack {
      Form {
        Section("Unlock your graph") {
          Image(systemName: "lock.shield")
          Text(longContent ? "Research and personal notes with a long graph name" : "Encrypted graph")
            .textSelection(.enabled)
          Text("Enter your encryption password to access your notes.")
        }
        Section("Encryption password") {
          SecureField("Encryption password", text: $password).focused($focused)
          feedback
          Button("Unlock graph") { failed = true }
            .buttonStyle(.borderedProminent)
            .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Text("Use the encryption password you set up in Logseq.")
          Button("Choose another graph", role: .cancel) { password = ""; failed = false }
        }
      }
      .defaultScrollAnchor(arguments.contains("--bottom") ? .bottom : .top)
      .toolbar {
        ToolbarItem(placement: .secondaryAction) {
          Button("Diagnostics", systemImage: "stethoscope") {}
        }
      }
    }
    .preferredColorScheme(arguments.contains("--dark") ? .dark : .light)
    .environment(\.dynamicTypeSize, arguments.contains("--large") ? .accessibility3 : .large)
    .environment(\.layoutDirection, arguments.contains("--rtl") ? .rightToLeft : .leftToRight)
    .onAppear {
      failed = arguments.contains("--error")
      focused = arguments.contains("--keyboard")
    }
  }

  @ViewBuilder private var feedback: some View {
    if failed {
      Text(longContent
        ? "This password could not unlock your graph. Check the encryption password you set up in Logseq and try again."
        : "Incorrect encryption password. Try again.")
    }
  }
}
