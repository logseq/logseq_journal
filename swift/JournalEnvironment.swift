import Foundation
import SwiftUI
#if canImport(UIKit)
  import UIKit
#endif

/// Host environment snapshot pushed to OCaml as an LJP2 tag-24 event, field-
/// for-field what `Journal_environment.decode_json` expects (replaces the old
/// bonsai `environment_changed` protocol event).
struct JournalEnvironmentSample: Equatable {
  struct Insets: Equatable {
    var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0
  }
  var viewportWidth = 0.0
  var viewportHeight = 0.0
  var devicePixelRatio = 1.0
  var textScale = 1.0
  var brightness = "light"
  var platform = "ios"
  var locale = "en"
  var safeArea = Insets()
  var keyboardInsets = Insets()
  var accessibleNavigation = false
  var boldText = false
  var invertColors = false
  var disableAnimations = false
  var reducedMotion = false
  var highContrast = false
  var orientation = "portrait"
  var pointerKinds = 0

  func jsonObject() -> [String: Any] {
    [
      "viewportWidth": viewportWidth,
      "viewportHeight": viewportHeight,
      "devicePixelRatio": devicePixelRatio,
      "textScale": textScale,
      "brightness": brightness,
      "platform": platform,
      "locale": locale,
      "safeArea": [
        "left": safeArea.left, "top": safeArea.top,
        "right": safeArea.right, "bottom": safeArea.bottom,
      ],
      "keyboardInsets": [
        "left": keyboardInsets.left, "top": keyboardInsets.top,
        "right": keyboardInsets.right, "bottom": keyboardInsets.bottom,
      ],
      "accessibleNavigation": accessibleNavigation,
      "boldText": boldText,
      "invertColors": invertColors,
      "disableAnimations": disableAnimations,
      "reducedMotion": reducedMotion,
      "highContrast": highContrast,
      "orientation": orientation,
      "pointerKinds": pointerKinds,
    ]
  }
}

/// Observes the application boundary and reports environment samples; the
/// platform deduplicates and pushes them through `journal_ocaml_platform_event`.
struct JournalEnvironmentObserver: View {
  let onSample: (JournalEnvironmentSample) -> Void
  @Environment(\.displayScale) private var displayScale
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.locale) private var locale
  @Environment(\.legibilityWeight) private var legibilityWeight
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.accessibilityInvertColors) private var invertColors
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.layoutDirection) private var direction
  @ScaledMetric(relativeTo: .body) private var bodyScale: Double = 1

  private func sample(size: CGSize, safeArea: JournalEnvironmentSample.Insets)
    -> JournalEnvironmentSample
  {
    #if os(macOS)
      let platform = "macos"
      let pointers = 0x0e
    #else
      let platform = "ios"
      let pointers = 0x0f
    #endif
    return JournalEnvironmentSample(
      viewportWidth: size.width, viewportHeight: size.height,
      devicePixelRatio: displayScale, textScale: bodyScale,
      brightness: colorScheme == .dark ? "dark" : "light", platform: platform,
      locale: locale.identifier(.bcp47), safeArea: safeArea,
      keyboardInsets: .init(), accessibleNavigation: voiceOver,
      boldText: legibilityWeight == .bold, invertColors: invertColors,
      disableAnimations: reduceMotion, reducedMotion: reduceMotion,
      highContrast: contrast == .increased,
      orientation: size.width > size.height ? "landscape" : "portrait",
      // Host capability mask, not an inventory of connected input devices.
      pointerKinds: pointers)
  }

  var body: some View {
    Group {
      #if os(macOS)
        GeometryReader { geometry in
          let insets = geometry.safeAreaInsets
          let value = sample(
            size: geometry.size,
            safeArea: .init(
              left: direction == .leftToRight ? insets.leading : insets.trailing,
              top: insets.top,
              right: direction == .leftToRight ? insets.trailing : insets.leading,
              bottom: insets.bottom))
          Color.clear
            .onAppear { onSample(value) }
            .onChange(of: value) { _, value in onSample(value) }
        }
      #else
        UIKitEnvironmentProbe(preferences: sample(size: .zero, safeArea: .init())) {
          onSample($0)
        }
      #endif
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

#if canImport(UIKit)
  /// A zero-interaction UIView attached to the window that tracks viewport
  /// bounds, safe area, and keyboard occlusion (followsUndockedKeyboard),
  /// matching the bonsai UIKit environment probe.
  private final class JournalWindowGeometryView: UIView {
    struct Geometry {
      let size: CGSize
      let safeArea: JournalEnvironmentSample.Insets
      let keyboard: JournalEnvironmentSample.Insets
    }
    var onChange: ((Geometry) -> Void)?
    private var generation = UUID()
    private var scheduled = false
    private let tracker = UIView()

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      accessibilityElementsHidden = true
      backgroundColor = .clear
      keyboardLayoutGuide.followsUndockedKeyboard = true
      keyboardLayoutGuide.usesBottomSafeArea = false
      tracker.translatesAutoresizingMaskIntoConstraints = false
      addSubview(tracker)
      NSLayoutConstraint.activate([
        tracker.leadingAnchor.constraint(equalTo: keyboardLayoutGuide.leadingAnchor),
        tracker.trailingAnchor.constraint(equalTo: keyboardLayoutGuide.trailingAnchor),
        tracker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        tracker.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
      ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) {
      fatalError("unavailable")
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      schedule()
    }
    override func safeAreaInsetsDidChange() {
      super.safeAreaInsetsDidChange()
      schedule()
    }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      schedule()
    }
    func invalidate() {
      generation = UUID()
      onChange = nil
    }
    func schedule() {
      guard !scheduled, window != nil, onChange != nil else { return }
      scheduled = true
      let generation = self.generation
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == generation else { return }
        self.scheduled = false
        guard let window = self.window, self.window === window else { return }
        let keyboard = Self.keyboardInsets(
          viewport: self.bounds, occlusion: self.keyboardLayoutGuide.layoutFrame)
        let safe = window.safeAreaInsets
        self.onChange?(
          Geometry(
            size: window.bounds.size,
            safeArea: .init(
              left: safe.left, top: safe.top, right: safe.right, bottom: safe.bottom),
            keyboard: keyboard))
      }
    }

    /// Full-edge keyboard occlusion; partial-width keyboards do not count
    /// (same rule as bonsai's NativeKeyboardOcclusion).
    private static func keyboardInsets(viewport: CGRect, occlusion: CGRect)
      -> JournalEnvironmentSample.Insets
    {
      for rectangle in [viewport, occlusion] {
        guard
          [rectangle.origin.x, rectangle.origin.y, rectangle.size.width,
            rectangle.size.height]
            .allSatisfy(\.isFinite),
          rectangle.size.width >= 0, rectangle.size.height >= 0
        else { return .init() }
      }
      guard !viewport.isEmpty, !occlusion.isEmpty else { return .init() }
      let overlap = viewport.intersection(occlusion)
      guard !overlap.isNull, !overlap.isEmpty else { return .init() }
      if overlap.minX == viewport.minX, overlap.maxX == viewport.maxX {
        if overlap.maxY == viewport.maxY { return .init(bottom: overlap.height) }
        if overlap.minY == viewport.minY { return .init(top: overlap.height) }
      }
      if overlap.minY == viewport.minY, overlap.maxY == viewport.maxY {
        if overlap.minX == viewport.minX { return .init(left: overlap.width) }
        if overlap.maxX == viewport.maxX { return .init(right: overlap.width) }
      }
      return .init()
    }
  }

  private final class JournalEnvironmentAttachmentView: UIView {
    private var observer: JournalWindowGeometryView?
    var preferences = JournalEnvironmentSample()
    var onSample: ((JournalEnvironmentSample) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      observer?.invalidate()
      observer = nil
      guard let window else { return }
      let observer = JournalWindowGeometryView(frame: window.bounds)
      self.observer = observer
      observer.onChange = { [weak self] geometry in
        guard let self else { return }
        var sample = self.preferences
        sample.viewportWidth = geometry.size.width
        sample.viewportHeight = geometry.size.height
        sample.orientation =
          geometry.size.width > geometry.size.height ? "landscape" : "portrait"
        sample.safeArea = geometry.safeArea
        sample.keyboardInsets = geometry.keyboard
        self.onSample?(sample)
      }
      window.insertSubview(observer, at: 0)
      observer.setNeedsLayout()
      observer.schedule()
    }
  }

  private struct UIKitEnvironmentProbe: UIViewRepresentable {
    let preferences: JournalEnvironmentSample
    let onSample: (JournalEnvironmentSample) -> Void

    func makeUIView(context: Context) -> JournalEnvironmentAttachmentView {
      let view = JournalEnvironmentAttachmentView()
      view.preferences = preferences
      view.onSample = onSample
      return view
    }
    func updateUIView(_ view: JournalEnvironmentAttachmentView, context: Context) {
      view.preferences = preferences
      view.onSample = onSample
    }
  }
#endif
