#if os(iOS)
import GameController
import SwiftUI
import UIKit

struct JournalCapturePresentation: UIViewControllerRepresentable {
  let content: AnyView
  let interactive: Bool

  func makeUIViewController(context: Context) -> Host {
    Host(content: content, interactive: interactive)
  }

  func updateUIViewController(_ controller: Host, context: Context) {
    controller.rootView = content
    if !interactive { controller.reveal() }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Host, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    let size = uiViewController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: size.height)
  }

  static func dismantleUIViewController(_ controller: Host, coordinator: ()) {
    controller.stopMonitoring()
  }

  final class Host: UIHostingController<AnyView> {
    private var waiting: Bool
    private var pendingKeyboardFrame: (screen: UIScreen, frame: CGRect)?
    private var keyboardOpening = false
    private var displayLink: CADisplayLink?
    private var loadedAt: ContinuousClock.Instant?
    private var editingDeadline: ContinuousClock.Instant?

    init(content: AnyView, interactive: Bool) {
      waiting = interactive
      super.init(rootView: content)
    }

    @MainActor required dynamic init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .clear
      guard waiting else { return }
      guard !shouldBypass else { waiting = false; return }
      setPaint(visible: false)
      loadedAt = .now

      let center = NotificationCenter.default
      center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                         name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
      for name in [UITextView.textDidBeginEditingNotification, UITextField.textDidBeginEditingNotification] {
        center.addObserver(self, selector: #selector(editingBegan(_:)), name: name, object: nil)
      }
      for name in [UITextView.textDidChangeNotification, UITextField.textDidChangeNotification] {
        center.addObserver(self, selector: #selector(textChanged(_:)), name: name, object: nil)
      }
      let link = CADisplayLink(target: self, selector: #selector(sampleLift))
      link.add(to: .main, forMode: .common)
      displayLink = link
    }

    private var shouldBypass: Bool {
      UIAccessibility.isVoiceOverRunning || UIAccessibility.isReduceMotionEnabled
        || GCKeyboard.coalesced != nil
    }

    private func ownsEditor(_ notification: Notification) -> Bool {
      guard let editor = notification.object as? UIView else { return false }
      return editor.isDescendant(of: view)
    }

    @objc private func editingBegan(_ notification: Notification) {
      guard waiting, editingDeadline == nil, ownsEditor(notification) else { return }
      editingDeadline = ContinuousClock.now + .milliseconds(150)
    }

    @objc private func textChanged(_ notification: Notification) {
      guard waiting, !keyboardOpening, pendingKeyboardFrame == nil, ownsEditor(notification) else { return }
      reveal()
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
      guard waiting, let screen = notification.object as? UIScreen,
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
      else { return }
      guard let window = view.window, window.isKeyWindow else {
        if view.window == nil || view.window?.screen === screen {
          pendingKeyboardFrame = (screen, frame)
        }
        return
      }
      guard screen === window.screen else { return }
      pendingKeyboardFrame = nil
      applyKeyboardFrame(frame, in: window)
    }

    private func applyKeyboardFrame(_ frame: CGRect, in window: UIWindow) {
      let overlap = window.bounds.intersection(window.convert(frame, from: window.screen.coordinateSpace))
      let docked = !overlap.isNull && overlap.height > window.safeAreaInsets.bottom + 1
        && overlap.maxY >= window.bounds.maxY - 1
      if docked {
        keyboardOpening = true
      } else {
        reveal()
      }
    }

    @objc private func sampleLift() {
      guard waiting else { return }
      if shouldBypass { reveal(); return }
      if let window = view.window, window.isKeyWindow, let pending = pendingKeyboardFrame {
        pendingKeyboardFrame = nil
        if pending.screen === window.screen { applyKeyboardFrame(pending.frame, in: window) }
      }
      guard waiting, let loadedAt else { return }
      let limit = loadedAt + .milliseconds(keyboardOpening ? 300 : 240)
      let deadline = keyboardOpening ? limit : min(limit, editingDeadline ?? limit)
      if ContinuousClock.now >= deadline { reveal(); return }
      guard keyboardOpening, let window = view.window, window.isKeyWindow,
            let presented = view.layer.presentation(), !presented.bounds.isEmpty,
            let target = window.layer.presentation()
      else { return }
      let bottom = presented.convert(presented.bounds, to: target).maxY
      let restBottom = window.bounds.maxY - window.safeAreaInsets.bottom
      if bottom < restBottom - 0.25 { reveal() }
    }

    func reveal() {
      guard waiting else { return }
      waiting = false
      if isViewLoaded { setPaint(visible: true) }
      stopMonitoring()
    }

    private func setPaint(visible: Bool) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      view.layer.opacity = visible ? 1 : 0
      CATransaction.commit()
      view.accessibilityElementsHidden = !visible
      view.isUserInteractionEnabled = visible
    }

    func stopMonitoring() {
      pendingKeyboardFrame = nil
      displayLink?.invalidate()
      displayLink = nil
      loadedAt = nil
      editingDeadline = nil
      NotificationCenter.default.removeObserver(self)
    }
  }
}
#endif
