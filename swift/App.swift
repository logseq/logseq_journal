import LUIAppleBackend
import SwiftUI
import OSLog
#if os(macOS)
import AppKit
#endif

@main struct JournalApplication: App {
  @State private var platform = JournalApplicationPlatform(services: JournalNativeServices.makePlatformServices())
  #if os(macOS)
  @NSApplicationDelegateAdaptor(JournalApplicationDelegate.self) private var delegate
  #endif

  var body: some Scene {
    #if os(macOS)
    Window("Logseq Journal", id: "journal") {
      JournalHost(platform: platform)
        .frame(minWidth: 320, minHeight: 360)
        .onAppear { delegate.platform = platform }
    }
    .defaultSize(width: 840, height: 720)
    #else
    WindowGroup("Logseq Journal") { JournalHost(platform: platform) }
    #endif
  }
}

private struct JournalRuntimeSetup {
  let payload: Data
  let extensions: LUIAppleExtensionRegistry
  @MainActor init() throws {
    payload = try JournalNativeServices.startupPayload()
    extensions = try JournalExtensions.registry()
  }
}

private struct JournalHost: View {
  let platform: JournalApplicationPlatform
  @Environment(\.scenePhase) private var scenePhase
  @State private var setup: Result<JournalRuntimeSetup, Error>?
  @State private var retry = 0
  @State private var signInPresented = false

  var body: some View {
    Group {
      switch setup {
      case .none: ProgressView("Opening journal")
      case .failure:
        ContentUnavailableView {
          Label("Unable to open local application storage", systemImage: "exclamationmark.folder")
        } actions: { Button("Retry") { setup = nil; retry += 1 } }
      case .success(let setup):
        JournalRuntimeHost(
          platform: platform, payload: setup.payload, extensions: setup.extensions)
          .font(.body)
          .safeAreaInset(edge: .top, spacing: 0) {
            if platform.authenticationRequired {
              HStack {
                Text("Sign in to connect your account")
                Spacer()
                Button("Sign in") { signInPresented = true }.buttonStyle(.bordered)
              }.padding(12)
            }
          }
      }
    }
    .task(id: retry) { if setup == nil { setup = Result { try JournalRuntimeSetup() } } }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .background { lifecycle(backgrounded: true) }
      else if phase == .active { lifecycle(backgrounded: false) }
    }
    .onChange(of: platform.authenticationRequired) { _, required in
      if required && platform.localAccountAvailable == false { signInPresented = true }
      if !required { signInPresented = false }
    }
    .onChange(of: platform.localAccountAvailable) { _, available in
      if available == false && platform.authenticationRequired { signInPresented = true }
    }
    .sheet(isPresented: $signInPresented) {
      NavigationStack {
        JournalAuthenticationView(api: JournalAmplifyAuthentication()) {
          platform.refreshAuthentication()
          signInPresented = false
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close", role: .cancel) { signInPresented = false }
          }
        }
      }
      .presentationSizing(.form)
      .presentationDetents([.large])
      .frame(idealWidth: 480)
      #if os(macOS)
      .frame(minWidth: 320, minHeight: 360)
      #endif
    }
    #if os(macOS)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in lifecycle(backgrounded: true) }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in lifecycle(backgrounded: false) }
    #endif
  }

  private func lifecycle(backgrounded: Bool) {
    do { try platform.setBackgrounded(backgrounded) }
    catch { Logger(subsystem: "com.logseq.journal", category: "lifecycle").error("Unable to enqueue lifecycle event") }
  }
}

#if os(macOS)
@MainActor final class JournalApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var platform: JournalApplicationPlatform?
  private var terminating = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.activate()
    NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating else { return .terminateLater }
    guard let shutdown = platform?.beginShutdown() else { return .terminateNow }
    terminating = true
    Task {
      _ = await shutdown.result
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
#endif
