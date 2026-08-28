import Cocoa
import Darwin
import FlutterMacOS

protocol JournalApplicationActivationTarget {
  func activateIgnoringOtherApps()
  func makeMainWindowKeyAndVisible()
}

struct JournalCocoaApplicationActivationTarget: JournalApplicationActivationTarget {
  let application: NSApplication

  func activateIgnoringOtherApps() {
    application.activate(ignoringOtherApps: true)
  }

  func makeMainWindowKeyAndVisible() {
    application.windows
      .compactMap { $0 as? MainFlutterWindow }
      .first?
      .makeKeyAndOrderFront(nil)
  }
}

enum JournalApplicationStartup {
  static func activate(_ target: JournalApplicationActivationTarget) {
    target.activateIgnoringOtherApps()
    target.makeMainWindowKeyAndVisible()
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private var terminationPending = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    JournalApplicationStartup.activate(
      JournalCocoaApplicationActivationTarget(application: NSApplication.shared)
    )
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationPending else { return .terminateLater }
    guard let window = sender.windows.compactMap({ $0 as? MainFlutterWindow }).first else {
      return .terminateNow
    }
    terminationPending = true
    let watchdog = DispatchWorkItem {
      Darwin.exit(EXIT_SUCCESS)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: watchdog)
    window.prepareToTerminate {
      DispatchQueue.main.async {
        watchdog.cancel()
        sender.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
