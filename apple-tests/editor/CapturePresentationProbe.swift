import GameController
import SwiftUI
import UIKit

@main final class CapturePresentationProbe: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    let root = UIViewController()
    window.rootViewController = root
    self.window = window
    window.makeKeyAndVisible()
    Task { await run(root: root, window: window) }
    return true
  }

  private func run(root: UIViewController, window: UIWindow) async {
    let getter = class_getClassMethod(GCKeyboard.self, #selector(getter: GCKeyboard.coalesced))!
    let disconnected: @convention(block) (AnyObject) -> GCKeyboard? = { _ in nil }
    let replacement = imp_implementationWithBlock(disconnected)
    let original = method_setImplementation(getter, replacement)
    defer {
      method_setImplementation(getter, original)
      imp_removeBlock(replacement)
    }
    precondition(!UIAccessibility.isReduceMotionEnabled && !UIAccessibility.isVoiceOverRunning)
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
      if !condition { failures += 1 }
      NSLog("CAPTURE TEST %@: %@", condition ? "PASS" : "FAIL", message)
    }
    for scenario in ["unclassified", "docked", "early input", "missing editing"] {
      let host = JournalCapturePresentation.Host(content: AnyView(Text("Draft")), interactive: true)
      root.addChild(host)
      host.view.frame = CGRect(x: 0, y: window.bounds.maxY - window.safeAreaInsets.bottom - 100, width: window.bounds.width, height: 100)
      root.view.addSubview(host.view)
      host.didMove(toParent: root)
      let editor = UITextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
      host.view.addSubview(editor)
      expect(host.view.layer.opacity == 0, "\(scenario) starts hidden")
      if scenario != "missing editing" {
        NotificationCenter.default.post(name: UITextView.textDidBeginEditingNotification, object: editor)
      }
      if scenario == "early input" {
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: editor)
        expect(host.view.layer.opacity == 1, "text input reveals synchronously")
      } else if scenario == "docked" {
        try? await Task.sleep(for: .milliseconds(115))
        let frame = CGRect(x: 0, y: window.bounds.maxY - 300, width: window.bounds.width, height: 300)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: window.screen,
          userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: window.convert(frame, to: window.screen.coordinateSpace))])
        try? await Task.sleep(for: .milliseconds(65))
        expect(host.view.layer.opacity == 0, "docked keyboard at rest stays hidden past the editing window")
        host.view.frame.origin.y -= 75
        try? await Task.sleep(for: .milliseconds(50))
        expect(host.view.layer.opacity == 1, "docked keyboard reveals on lift")
      } else {
        try? await Task.sleep(for: .milliseconds(scenario == "unclassified" ? 190 : 270))
        expect(host.view.layer.opacity == 1, "\(scenario) fails open before the old watchdog")
      }
      host.stopMonitoring()
      host.willMove(toParent: nil)
      host.view.removeFromSuperview()
      host.removeFromParent()
    }
    NSLog("CAPTURE TEST END failures=%d", failures)
  }
}
