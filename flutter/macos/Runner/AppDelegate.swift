import Cocoa
import Darwin
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var terminationPending = false

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
