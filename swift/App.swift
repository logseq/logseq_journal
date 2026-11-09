import LUIAppleBackend
import SwiftUI
import OSLog
#if os(macOS)
import AppKit
#endif

@main enum JournalApplicationEntry {
  @MainActor static func main() {
    JournalStartupDiagnostics.mark("main_enter")
    JournalApplication.main()
  }
}

struct JournalApplication: App {
  @State private var platform: JournalApplicationPlatform
  #if os(macOS)
  @NSApplicationDelegateAdaptor(JournalApplicationDelegate.self) private var delegate
  #endif

  init() {
    let began = JournalStartupDiagnostics.begin("app_init")
    defer { JournalStartupDiagnostics.end("app_init", since: began) }
    _platform = State(initialValue: JournalStartupDiagnostics.measure("native_services") {
      JournalApplicationPlatform(services: JournalNativeServices.makePlatformServices())
    })
  }

  var body: some Scene {
    let _ = JournalStartupDiagnostics.mark("app_body")
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
