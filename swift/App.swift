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
      JournalHost(platform: platform, prepare: {
        JournalRuntimeSetup(payload: try JournalNativeServices.startupPayload(),
          extensions: try JournalExtensions.registry())
      }, authentication: JournalCognitoNative.shared)
        .frame(minWidth: 320, minHeight: 360)
        .onAppear { delegate.platform = platform }
    }
    .defaultSize(width: 840, height: 720)
    #else
    WindowGroup("Logseq Journal") { JournalHost(platform: platform, prepare: {
        JournalRuntimeSetup(payload: try JournalNativeServices.startupPayload(),
          extensions: try JournalExtensions.registry())
      }, authentication: JournalCognitoNative.shared) }
    #endif
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
