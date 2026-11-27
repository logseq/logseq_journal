import LUIAppleBackend
import SwiftUI
import OSLog
#if os(macOS)
import AppKit
#endif

@main struct JournalApplication: App {
  @State private var platform: JournalApplicationPlatform
  @State private var initialSetup: Result<JournalRuntimeSetup, Error>
  #if os(macOS)
  @NSApplicationDelegateAdaptor(JournalApplicationDelegate.self) private var delegate
  #endif

  #if os(iOS)
  private let startupClock = JournalStartupClock()
  #endif

  init() {
    #if os(iOS)
    startupClock.begin()
    #endif
    let platform = JournalApplicationPlatform(services: JournalNativeServices.makePlatformServices())
    _platform = State(initialValue: platform)
    let prepared: Result<JournalRuntimeSetup, Error> = Result {
      let payload = try JournalNativeServices.startupPayload()
      let extensions = try JournalExtensions.registry()
      var setup = JournalRuntimeSetup(payload: payload, extensions: extensions)
      // Overlap OCaml boot, local DB open, and initial feed loading with UIKit/AppKit window creation.
      if let runtime = try? JournalRuntime(
        platform: platform,
        startupPayload: payload,
        extensionRegistry: extensions) {
        if (try? runtime.start()) != nil {
          setup.prestartedRuntime = runtime
        } else {
          runtime.stop()
        }
      }
      return setup
    }
    _initialSetup = State(initialValue: prepared)
  }

  var body: some Scene {
    #if os(macOS)
    Window("Logseq Journal", id: "journal") {
      JournalHost(platform: platform, prepare: {
        JournalRuntimeSetup(payload: try JournalNativeServices.startupPayload(),
          extensions: try JournalExtensions.registry())
      }, authentication: JournalCognitoNative.shared, initialSetup: initialSetup)
        .frame(minWidth: 320, minHeight: 360)
        .onAppear { delegate.platform = platform }
    }
    .defaultSize(width: 840, height: 720)
    #else
    WindowGroup("Logseq Journal") { JournalHost(platform: platform, prepare: {
        JournalRuntimeSetup(payload: try JournalNativeServices.startupPayload(),
          extensions: try JournalExtensions.registry())
      }, authentication: JournalCognitoNative.shared, initialSetup: initialSetup, startupClock: startupClock) }
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
