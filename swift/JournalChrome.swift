import LUIAppleBackend
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The form sheet's native card transform still leaves at least a 44pt target.
struct JournalSheetDismissButton: SwiftUI.View {
  var label: LocalizedStringKey = "Close"
  let action: () -> Void

  var body: some SwiftUI.View {
    Button(action: action) {
      Image(systemName: "xmark")
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .accessibilityLabel(Text(label))
  }
}

/// Native chrome layout only. List sections own all date scrolling and pinning.
@MainActor enum JournalChrome {
  private enum Mode: String, Decodable {
    case page, header, detail, unlock, startup
    case graphPages = "graph-pages"
    case graphPicker = "graph-picker"
    case toolbarControl = "toolbar-control"
    case detailText = "detail-text"
    case boundedText = "bounded-text"
  }

  private struct Properties: Decodable {
    let mode: Mode
    let title: String?
    let connecting: Bool?
    let controls: Bool?
    let pending: Bool?
    let error: String?
    let text: String?
    let runs: [TitleRun]?
    let maxLines: Int?
    let id: String?
    let level: Int?
    let loading: Bool?
    let initial: Bool?
    let active: Bool?
    let value: Double?
    let message: String?
    let enabled: Bool?
    let pageID: String?
    let targetID: String?
    let targetPageID: String?
    let residentPageIDs: [String]?
  }

  /// Syntax and reference resolution belong to OCaml; this maps presentation data.
  #if os(iOS)
  /// Native direction admission fails before vertical List scrolling is claimed.
  private struct RightGraphPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let changed: (UIPanGestureRecognizer) -> Void
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      var enabled = false
      func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard enabled, let pan = recognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: pan.view)
        return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.4
      }
      func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
          if current is UIControl || current is UITextView || current is UITextField { return false }
          view = current.superview
        }
        return enabled
      }
    }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
      let pan = UIPanGestureRecognizer()
      pan.maximumNumberOfTouches = 1
      pan.delegate = context.coordinator
      context.coordinator.enabled = enabled
      return pan
    }
    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
      context.coordinator.enabled = enabled
      // Do not cancel a gesture merely because its preview is being populated.
      if recognizer.state == .possible { recognizer.isEnabled = enabled }
    }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
      changed(recognizer)
    }
  }
  private struct GraphPages: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    let properties: Properties
    let current: AnyView
    let preview: AnyView
    @State private var translation: CGFloat = 0
    @State private var dragging = false
    @State private var settling = false
    @Environment(\.journalGraphScrollOffsets) private var graphScrollOffsets
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func emit(_ action: String) {
      JournalExtensions.emit(context: context, payload: Data(action.utf8))
    }
    private func handle(_ pan: UIPanGestureRecognizer, width: CGFloat) {
      switch pan.state {
      case .began:
        guard properties.enabled == true, !settling else { return }
        dragging = true
        emit("prepare")
        translation = min(width, max(0, pan.translation(in: pan.view).x))
      case .changed where dragging:
        translation = min(width, max(0, pan.translation(in: pan.view).x))
      case .ended where dragging:
        dragging = false
        let distance = pan.translation(in: pan.view).x
        let velocity = pan.velocity(in: pan.view).x
        let commit = distance > width * 0.3 || (distance > 30 && velocity > 650)
        settling = true
        withAnimation(reduceMotion ? .linear(duration: 0.01) : .smooth(duration: 0.24), completionCriteria: .logicallyComplete) {
          translation = commit ? width : 0
        } completion: {
          emit(commit ? "commit" : "cancel")
          if !commit { settling = false }
        }
      case .cancelled, .failed:
        guard dragging else { return }
        dragging = false
        withAnimation(.smooth(duration: 0.2)) { translation = 0 }
        emit("cancel")
      default: break
      }
    }
    var body: some SwiftUI.View {
      GeometryReader { bounds in
        ZStack(alignment: .topLeading) {
          preview
            .environment(\.journalGraphScrollScope, properties.targetPageID.map { JournalGraphScrollScope(pageID: $0, records: false) })
            .frame(width: bounds.size.width, height: bounds.size.height)
            .offset(x: translation - bounds.size.width)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
          current
            .environment(\.journalGraphScrollScope, properties.pageID.map { JournalGraphScrollScope(pageID: $0, records: true) })
            .frame(width: bounds.size.width, height: bounds.size.height)
            .offset(x: translation)
        }
        .clipped()
        .gesture(RightGraphPan(enabled: properties.enabled == true && !settling) {
          handle($0, width: bounds.size.width)
        })
      }
      .onAppear { graphScrollOffsets?.retain(properties.residentPageIDs ?? []) }
      .onChange(of: properties.residentPageIDs) { _, ids in graphScrollOffsets?.retain(ids ?? []) }
      .onChange(of: properties.pageID) { _, _ in
        translation = 0; dragging = false; settling = false
      }
      .onChange(of: properties.targetID) { _, target in
        if target == nil && !dragging { translation = 0; settling = false }
      }
      .onChange(of: properties.enabled) { _, enabled in
        if enabled != true && dragging {
          dragging = false
          withAnimation(.smooth(duration: 0.2)) { translation = 0 }
          emit("cancel")
        }
      }
    }
  }
  #endif

  private struct TitleRun: Decodable {
    let text: String
    let styles: [String]
    let url: String?
  }

  private static func attributed(_ runs: [TitleRun]?, fallback: String) -> AttributedString {
    guard let runs else { return AttributedString(fallback) }
    var result = AttributedString()
    for run in runs {
      var fragment = AttributedString(run.text)
      var intent: InlinePresentationIntent = []
      if run.styles.contains("bold") { intent.insert(.stronglyEmphasized) }
      if run.styles.contains("italic") { intent.insert(.emphasized) }
      if run.styles.contains("code") { intent.insert(.code) }
      fragment.inlinePresentationIntent = intent
      if run.styles.contains("underline") { fragment.underlineStyle = .single }
      if run.styles.contains("strike") { fragment.strikethroughStyle = .single }
      if run.styles.contains("highlight") { fragment.backgroundColor = .yellow.opacity(0.25) }
      if let target = run.url.flatMap(URL.init(string:)) {
        fragment.link = target
      }
      result.append(fragment)
    }
    return result
  }

  private struct DetailText: SwiftUI.View {
    let text: AttributedString
    let id: String
    let level: Int
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var targetLineHeight: CGFloat = 27

    init(text: AttributedString, id: String, level: Int) {
      self.text = text
      self.id = id
      let tier = min(2, max(0, level))
      self.level = tier
      _size = ScaledMetric(wrappedValue: [28, 19, 17][tier], relativeTo: .body)
      _targetLineHeight = ScaledMetric(wrappedValue: [35, 26, 25][tier], relativeTo: .body)
    }

    private var lineSpacing: CGFloat {
      #if os(iOS)
      max(0, targetLineHeight - UIFont.systemFont(ofSize: size).lineHeight)
      #else
      max(0, targetLineHeight - size * 1.2)
      #endif
    }

    var body: some SwiftUI.View {
      Text(text)
        .font(.system(size: size, weight: level == 0 ? .bold : level == 1 ? .semibold : .regular))
        .foregroundStyle(.primary)
        .lineSpacing(lineSpacing)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(id)
    }
  }

  fileprivate struct ControlsSizeKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
  }

  private struct FloatingChrome: SwiftUI.View {
    let content: AnyView
    let cluster: AnyView
    let progress: AnyView
    let properties: Properties
    var leading: AnyView? = nil
    @Environment(\.journalContainerTopInset) private var containerTopInset
    @State private var controlsSize = CGSize.zero

    var body: some SwiftUI.View {
      GeometryReader { bounds in
        scrollingContent.frame(width: bounds.size.width, height: bounds.size.height)
          .scrollContentBackground(.hidden)
          #if os(iOS)
          // Journals has no section title; named sections retain native indicators.
          .scrollIndicators(properties.title == nil ? .hidden : .automatic)
          .scrollEdgeEffectHidden(true, for: .bottom)
          .scrollEdgeEffectStyle(.soft, for: .top)
          #endif
          .environment(\.journalControlsSize, controlsSize)
          #if os(iOS)
          // Retaining the native bar host across Detail returns avoids the
          // reproduced soft scroll-edge flash during the pop transition.
          .toolbar(.visible, for: .navigationBar)
          .toolbarBackground(.hidden, for: .navigationBar)
          #endif
          .overlay(alignment: .topTrailing) {
            if properties.title == nil {
              controls.padding(.trailing, 16)
            }
          }
          .overlay(alignment: .topLeading) {
            if let leading {
              leading.glassEffect(.regular, in: .capsule).padding(.leading, 16)
            }
          }
          .safeAreaBar(edge: .top, spacing: 0) {
            if let title = properties.title {
              HStack(alignment: .center, spacing: 12) {
                Text(title)
                  .font(.headline)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .accessibilityAddTraits(.isHeader)
                  .accessibilityIdentifier("favorites-header-title")
                controls
              }
              .frame(minHeight: 44)
              .padding(.horizontal, 16)
              // The native bar participates in the soft scroll edge, keeping
              // content visible beneath the title without another material.
            }
          }
      }
      #if os(iOS)
      // Use the outer container safe area, so the empty retained bar does not
      // move the native List section headers or account controls down.
      .safeAreaPadding(.top, containerTopInset)
      .ignoresSafeArea(.container, edges: .top)
      #endif
    }

    @ViewBuilder private var scrollingContent: some SwiftUI.View {
      if properties.mode == .graphPicker {
        content.contentMargins(.top, 52, for: .scrollContent)
      } else {
        content
      }
    }

    private var controls: some SwiftUI.View {
      HStack(spacing: 8) {
        if properties.connecting! { progress.controlSize(.small).fixedSize() }
        if properties.controls! { cluster }
      }
      .fixedSize()
      .onGeometryChange(for: CGSize.self) { $0.size } action: { controlsSize = $0 }
    }
  }

  private struct SectionDate: SwiftUI.View {
    let title: String
    let relativeLabel: String?
    @Environment(\.journalControlsSize) private var controlsSize

    var body: some SwiftUI.View {
      HStack(spacing: 0) {
        Text("\(Text(verbatim: title).font(.title2.weight(.semibold)))\(Text(verbatim: relativeLabel.map { "\u{2002}" + $0 } ?? "").font(.subheadline.weight(.regular)).foregroundStyle(Color.secondary))")
          .foregroundStyle(.primary)
          .monospacedDigit()
          .textCase(nil)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: controlsSize.width > 0 ? controlsSize.width + 16 : 0)
      }
    }
  }

  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    @Environment(\.journalStartupContainerFrame) private var startupContainerFrame

    private var properties: Properties? {
      JournalExtensions.decode(Properties.self, context: context)
    }

    private func child(_ index: Int) -> AnyView {
      guard context.childIDs.count > index else { return AnyView(EmptyView()) }
      return context.content(for: context.childIDs[index])
    }

    var body: some SwiftUI.View {
      let properties = self.properties
      switch properties?.mode {
      case .graphPages:
        if let properties, context.childIDs.count == 2 {
          #if os(iOS)
          GraphPages(context: context, properties: properties, current: child(0), preview: child(1))
          #else
          child(0)
          #endif
        }
      case .page:
        if let properties, context.childIDs.count == 3,
          properties.connecting != nil, properties.controls != nil {
          FloatingChrome(content: child(0), cluster: child(1),
            progress: child(2), properties: properties)
        }
      case .graphPicker:
        if let properties, context.childIDs.count == 4,
          properties.connecting != nil, properties.controls != nil {
          FloatingChrome(content: child(0), cluster: child(1),
            progress: child(2), properties: properties, leading: child(3))
        }
      case .startup:
        if let properties, context.childIDs.count == 1 {
          GeometryReader { bounds in
            JournalStartupLoadingSurface(loading: properties.loading == true,
              initial: properties.initial == true, active: properties.active != false,
              value: properties.value, message: properties.message ?? "", action: child(0))
              // Ancestor columns have already consumed the navigation inset.
              // Keep the same safe-area canvas as native preparation instead.
              .frame(width: bounds.size.width,
                height: startupContainerFrame?.height ?? bounds.size.height)
              .offset(y: startupContainerFrame.map {
                $0.minY - bounds.frame(in: .global).minY
              } ?? 0)
          }
        }
      case .header:
        if let properties, context.childIDs.isEmpty, let title = properties.title {
          SectionDate(title: title, relativeLabel: properties.text)
        }
      case .detail:
        if let title = properties?.title, context.childIDs.count == 2 {
          GeometryReader { bounds in
            child(0).frame(width: bounds.size.width, height: bounds.size.height)
          }
          #if os(iOS)
          .toolbar(.visible, for: .navigationBar)
          .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
              child(1).menuStyle(.button).buttonStyle(.plain)
            }
            .sharedBackgroundVisibility(.hidden)
          }
          #else
          .toolbar { ToolbarItem { child(1) } }
          #endif
          .navigationTitle(title)
        }
      case .boundedText:
        if let text = properties?.text, let maxLines = properties?.maxLines,
          maxLines > 0, context.childIDs.isEmpty {
          Text(JournalChrome.attributed(properties?.runs, fallback: text))
            .font(properties?.level == 1 ? .subheadline : .body)
            .foregroundStyle(properties?.level == 1 ? .secondary : .primary)
            .multilineTextAlignment(.leading)
            .lineLimit(maxLines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .detailText:
        if let properties, let text = properties.text, let id = properties.id,
          let level = properties.level, context.childIDs.isEmpty {
          DetailText(text: JournalChrome.attributed(properties.runs, fallback: text), id: id, level: level)
        }
      case .toolbarControl:
        if context.childIDs.count == 1 {
          child(0).fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(properties?.title ?? "Close"))
            .accessibilityAddTraits(.isButton)
        }
      case .unlock:
        if let properties, let title = properties.title, context.childIDs.count == 4 {
          Form {
            Section {
              VStack(alignment: .leading, spacing: 8) {
                Label("Unlock your graph", systemImage: "lock.shield")
                  .font(.title2.weight(.semibold))
                  .accessibilityAddTraits(.isHeader)
                Text(title).font(.headline).textSelection(.enabled)
                Text("Enter the encryption password you set up in Logseq to access your notes.")
                  .font(.subheadline).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.vertical, 4)
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
            }
            Section {
              child(0)
                .accessibilityLabel("Encryption password")
                .accessibilityHint("Use the encryption password for this graph.")
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                #endif
            } header: {
              Text("Encryption password").textCase(nil)
            }
            Section {
              if properties.pending == true {
                HStack {
                  ProgressView()
                  Text("Unlocking your graph…")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("e2ee-password-loading")
              } else if let error = properties.error {
                VStack(alignment: .leading, spacing: 4) {
                  Label("Couldn't unlock graph", systemImage: "exclamationmark.circle")
                    .font(.headline)
                  Text(error).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("e2ee-password-error")
              }
              child(1).frame(maxWidth: .infinity)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
              child(2).frame(maxWidth: .infinity)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            } footer: {
              child(3).font(.footnote).frame(maxWidth: .infinity)
            }
          }
          .listSectionSpacing(16)
          .scrollDismissesKeyboard(.interactively)
          #if os(iOS)
          .toolbar(.hidden, for: .navigationBar)
          #endif
        }
      case .none:
        EmptyView()
      }
    }
  }
}

private extension EnvironmentValues {
  var journalControlsSize: CGSize {
    get { self[JournalChrome.ControlsSizeKey.self] }
    set { self[JournalChrome.ControlsSizeKey.self] = newValue }
  }
}

private struct JournalContainerTopInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
  var journalContainerTopInset: CGFloat {
    get { self[JournalContainerTopInsetKey.self] }
    set { self[JournalContainerTopInsetKey.self] = newValue }
  }
}

private struct JournalStartupContainerFrameKey: EnvironmentKey {
  static let defaultValue: CGRect? = nil
}
extension EnvironmentValues {
  var journalStartupContainerFrame: CGRect? {
    get { self[JournalStartupContainerFrameKey.self] }
    set { self[JournalStartupContainerFrameKey.self] = newValue }
  }
}
