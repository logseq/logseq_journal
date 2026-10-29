import LUIAppleBackend
import SwiftUI
import Observation
#if os(iOS)
import UIKit
#endif

struct JournalGraphScrollScope:Equatable {
  let pageID: String
  let records: Bool
}
private struct JournalGraphScrollScopeKey: EnvironmentKey {
  static let defaultValue: JournalGraphScrollScope? = nil
}
private struct JournalGraphPresentationReadyKey: EnvironmentKey {
  static let defaultValue: (@MainActor @Sendable (String) -> Void)? = nil
}
private struct JournalGraphPresentationNonceKey: EnvironmentKey {
  static let defaultValue: UUID? = nil
}
extension EnvironmentValues {
  var journalGraphPresentationNonce: UUID? {
    get { self[JournalGraphPresentationNonceKey.self] }
    set { self[JournalGraphPresentationNonceKey.self] = newValue }
  }
  var journalGraphPresentationReady: (@MainActor @Sendable (String) -> Void)? {
    get { self[JournalGraphPresentationReadyKey.self] }
    set { self[JournalGraphPresentationReadyKey.self] = newValue }
  }
  var journalGraphScrollScope: JournalGraphScrollScope? {
    get { self[JournalGraphScrollScopeKey.self] }
    set { self[JournalGraphScrollScopeKey.self] = newValue }
  }
}

/// Native offsets survive graph view remounts, bounded by live runtime scopes.
/// Retired views cannot repopulate an account or graph after its removal.
@MainActor final class JournalGraphScrollOffsets {
  private var live: Set<String> = []
  private var offsets: [String: [String: CGFloat]] = [:]
  func retain(_ pages: [String]) {
    live = Set(pages)
    offsets = offsets.filter { live.contains($0.key) }
  }
  func read(page: String, list: String) -> CGFloat? { offsets[page]?[list] }
  func write(page: String, list: String, y: CGFloat) {
    guard live.contains(page), y.isFinite else { return }
    offsets[page, default: [:]][list] = max(0, y)
  }
}

private struct JournalGraphScrollOffsetsKey: EnvironmentKey {
  static let defaultValue: JournalGraphScrollOffsets? = nil
}
extension EnvironmentValues {
  var journalGraphScrollOffsets: JournalGraphScrollOffsets? {
    get { self[JournalGraphScrollOffsetsKey.self] }
    set { self[JournalGraphScrollOffsetsKey.self] = newValue }
  }
}

/// SwiftUI host for the `journal-list` extension — the lui replacement for
/// bonsai's `Native_list` family (grouped sections, disclosure rows, scroll
/// position requests, visible-range paging, context actions).
///
/// Rows carry arbitrary content: each row's `content_index` (and each
/// section's `header_index`/`footer_index`) indexes `context.childIDs` and is
/// rendered via `context.content(for:)`. Row activation is handled inside
/// lui (the content mounts `Navigation_link`-style nodes); this view only
/// emits the auxiliary events:
///
///   { "type": "visible_range", "first": <pos>, "last": <pos> }
///   { "type": "scroll_completed", "token": "<int64>", "outcome": "<outcome>" }
///   { "type": "expanded", "key": "<row key>", "expanded": <bool> }
///   { "type": "row_event", "payload": "{\"key\":\"<action>\",\"row\":\"<row>\"}" }
///
/// Positions are flat indices across the displayed rows in payload order
/// (disclosure children count only while the parent is expanded).
@MainActor enum JournalList {
  struct Action: Decodable, Identifiable {
    let key: String
    let enabled: Bool?
    let role: String?
    let symbol: String?
    let title: String
    var id: String { key }
  }
  struct ActionGroup: Decodable { let actions: [Action] }
  struct Row: Decodable, Identifiable {
    let type: String
    let key: String
    let content_index: Int
    let separator: String?
    let test_id: String?
    let context_menu: ActionGroup?
    let expanded: Bool?
    let children: [Row]?
    var id: String { key }
    var isDisclosure: Bool { type == "disclosure" }
  }
  struct SectionModel: Decodable, Identifiable {
    let key: String
    let separator: String?
    let header_index: Int?
    let footer_index: Int?
    let rows: [Row]
    var id: String { key }
  }
  struct ScrollRequest: Decodable {
    struct Target: Decodable {
      let section: String
      let row_path: [String]
    }
    let token: Int64
    let target: Target
    let anchor: String?
    let animated: Bool?
  }
  private struct RowEvent: Encodable { let key: String; let row: String }
  private struct Event: Encodable {
    let type: String
    var first: Int64? = nil
    var last: Int64? = nil
    var token: Int64? = nil
    var outcome: String? = nil
    var key: String? = nil
    var expanded: Bool? = nil
    var payload: String? = nil
  }

  struct Properties: Decodable {
    let style: String
    let sections: [SectionModel]
    let track_visible_range: Bool?
    let track_scroll_completion: Bool?
    let sync_enabled: Bool?
    let retention_key: String?
  }

  /// One payload observation belongs to one mounted native list. Child-model
  /// changes do not decode it, and cell lifecycle reads only prepared indices.
  @MainActor final class Snapshot {
    let properties: Properties
    let positions: [String: Int]

    convenience init?(_ json: String) {
      guard let properties = try? JSONDecoder().decode(Properties.self, from: Data(json.utf8))
      else { return nil }
      self.init(properties: properties)
    }

    init?(properties: Properties) {
      var positions: [String: Int] = [:]
      var keys: Set<String> = []
      var valid = true
      func walk(_ row: Row, displayed: Bool) {
        guard keys.insert(row.key).inserted else { valid = false; return }
        if displayed { positions[row.key] = positions.count }
        for child in row.children ?? [] {
          walk(child, displayed: displayed && row.isDisclosure && row.expanded == true)
        }
      }
      for section in properties.sections {
        for row in section.rows { walk(row, displayed: true) }
      }
      guard valid else { return nil }
      self.properties = properties
      self.positions = positions
    }
  }

  struct RowLease {
    let instance: UUID
    let key: String
    let incarnation: UUID
  }

  @MainActor final class PreparedState: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    private(set) var scrollRequest: ScrollRequest?
    // Commands never publish this content owner. The mounted view subscribes
    // directly; row content is decoded only by its separate payload observer.
    var onScrollRequest: ((ScrollRequest?) -> Void)? {
      didSet {
        if onScrollRequest != nil { commandNeedsDelivery = true }
        deliverScrollRequest()
      }
    }
    private var context: LUIAppleExtensionViewContext?
    private var instance = UUID()
    private var rowIncarnations: [String: UUID] = [:]
    private var visible: Set<String> = []
    private var delivered: Range<Int>?
    private var payload: String?
    private var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var commandPayload: String?
    private var commandObservation = UUID()
    private var commandNeedsDelivery = false
    private var emitTask: Task<Void, Never>?
    private var dirty = false
    private var active = false
    private var queued: [(RowLease, Bool)] = []

    var range: Range<Int>? {
      guard let snapshot else { return nil }
      var first = Int.max
      var last = -1
      for key in visible {
        guard let index = snapshot.positions[key] else { continue }
        first = min(first, index)
        last = max(last, index)
      }
      return last >= 0 ? first..<(last + 1) : nil
    }

    init(context: LUIAppleExtensionViewContext? = nil) {
      if let context { bind(context) }
    }

    func bind(_ context: LUIAppleExtensionViewContext) {
      if let previous = self.context, previous.nodeID != context.nodeID { dispose() }
      active = true
      guard self.context == nil else {
        refreshScrollRequest()
        scheduleRange()
        return
      }
      self.context = context
      refresh()
      refreshScrollRequest()
    }

    // A navigation destination can be retained while temporarily offscreen.
    // Keep its native List content, visible keys and row identities for Back.
    func suspend() {
      active = false
      onScrollRequest = nil
      emitTask?.cancel()
      emitTask = nil
      delivered = nil
      queued.removeAll()
    }

    func dispose() {
      suspend()
      instance = UUID()
      context = nil
      refreshTask?.cancel()
      refreshTask = nil
      commandTask?.cancel()
      commandTask = nil
      commandObservation = UUID()
      commandPayload = nil
      commandNeedsDelivery = false
      emitTask?.cancel()
      emitTask = nil
      // Keep List content while a retained navigation destination is offscreen.
      // Binding again refreshes it before delivering any lifecycle work.
      payload = nil
      scrollRequest = nil
      rowIncarnations.removeAll()
      visible.removeAll()
      queued.removeAll()
      delivered = nil
      dirty = false
    }

    private func refresh() {
      guard let context else { return }
      let observedInstance = instance
      let value = withObservationTracking {
        context.property("payload")
      } onChange: { [weak self] in
        // Extension models are committed on MainActor. Observation fires before
        // the setter completes, so parse on its next turn and fence deliveries.
        MainActor.assumeIsolated {
          guard let self, self.instance == observedInstance, self.context != nil else { return }
          self.dirty = true
          self.emitTask?.cancel()
          self.refreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.instance == observedInstance else { return }
            self.refresh()
          }
        }
      }
      let nextPayload: String?
      if case let .string(json) = value { nextPayload = json } else { nextPayload = nil }
      if nextPayload != payload {
        payload = nextPayload
        snapshot = nextPayload.flatMap { Snapshot($0) }
        if snapshot == nil {
          JournalExtensions.report(context: context, code: "diagnostic.nativePropsDecode.invalidPayload")
        }
        let positions = snapshot?.positions ?? [:]
        rowIncarnations = positions.reduce(into: [:]) { result, entry in
          result[entry.key] = rowIncarnations[entry.key] ?? UUID()
        }
        visible = visible.intersection(positions.keys)
        commandNeedsDelivery = true
      }
      dirty = false
      let pending = queued
      queued.removeAll()
      for (lease, appeared) in pending { _ = receive(lease, appeared: appeared) }
      scheduleRange()
      deliverScrollRequest()
    }

    private func refreshScrollRequest() {
      guard let context else { return }
      let observedInstance = instance
      let observation = UUID()
      commandObservation = observation
      let value = withObservationTracking {
        context.property("scroll_request")
      } onChange: { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.instance == observedInstance,
            self.commandObservation == observation else { return }
          self.commandTask?.cancel()
          self.commandTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.instance == observedInstance else { return }
            self.refreshScrollRequest()
          }
        }
      }
      let next: String?
      if case let .string(json) = value { next = json } else {
        next = nil
        if value != nil { JournalExtensions.report(context:context,code:"diagnostic.nativeScrollDecode.typeMismatch") }
      }
      if next != commandPayload {
        commandPayload = next
        do {
          scrollRequest = try next.flatMap {
            try JournalSafeDiagnostic.decode(ScrollRequest?.self, from: Data($0.utf8))
          }
        } catch {
          scrollRequest = nil
          JournalExtensions.report(context: context, code: "diagnostic.nativeScrollDecode." + JournalSafeDiagnostic.classify(error).rawValue)
        }
        commandNeedsDelivery = true
      }
      deliverScrollRequest()
    }

    private func deliverScrollRequest() {
      guard active, !dirty, commandNeedsDelivery, let onScrollRequest else { return }
      commandNeedsDelivery = false
      onScrollRequest(snapshot == nil ? nil : scrollRequest)
    }

    func lease(for key: String) -> RowLease? {
      guard let incarnation = rowIncarnations[key] else { return nil }
      return RowLease(instance: instance, key: key, incarnation: incarnation)
    }

    @discardableResult func receive(_ lease: RowLease, appeared: Bool) -> Bool {
      guard active, context != nil, lease.instance == instance,
        rowIncarnations[lease.key] == lease.incarnation else { return false }
      if dirty {
        queued.append((lease, appeared))
        return false
      }
      let changed = appeared
        ? visible.insert(lease.key).inserted
        : visible.remove(lease.key) != nil
      if changed { scheduleRange() }
      return changed
    }

    private func scheduleRange() {
      guard active, !dirty, snapshot?.properties.track_visible_range == true,
        let next = range else {
        emitTask?.cancel()
        emitTask = nil
        delivered = nil
        return
      }
      guard delivered != next else { return }
      emitTask?.cancel()
      let emittingInstance = instance
      emitTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard let self, !Task.isCancelled, self.instance == emittingInstance,
          self.active, !self.dirty, let context = self.context,
          self.snapshot?.properties.track_visible_range == true,
          self.range == next else { return }
        guard let data = try? JSONEncoder().encode(Event(type: "visible_range",
          first: Int64(next.lowerBound), last: Int64(next.upperBound))) else { return }
        if JournalExtensions.emit(context: context, payload: data) {
          self.delivered = next
        }
      }
    }
  }

  @MainActor private final class TopScroll: ObservableObject {
    var active = false
    var handledToken: Int64 = 0
    private var userInteracting = false
    var presentationLayout: (() -> Void)?
    private var reportingLayout = false
    private(set) var atTop = false
    #if os(iOS)
    weak var scrollView: UIScrollView?
    weak var cover: UIView?
    private enum Phase { case fadingOut, jumping, waitingForLayout, fadingIn }
    private var phase: Phase?
    private var pending: (id: UUID, token: Int64, complete: (Int64, String) -> Void)?
    private var restoredOffset: (y: CGFloat, complete: (CGFloat) -> Void)?
    func cancelRestore() { restoredOffset = nil }
    func restoreOffset(_ y: CGFloat, complete: @escaping (CGFloat) -> Void) {
      restoredOffset = (y, complete)
      applyRestoredOffset()
    }
    func applyRestoredOffset() {
      guard active, !userInteracting, let request = restoredOffset,
        let scrollView, scrollView.window != nil, scrollView.contentSize.height > 0,
        !scrollView.isTracking, !scrollView.isDragging else { return }
      scrollView.layoutIfNeeded()
      let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom)
      let y = min(maximum, max(0, request.y))
      restoredOffset = nil
      UIView.performWithoutAnimation {
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x,
          y: y - scrollView.adjustedContentInset.top), animated: false)
        scrollView.layoutIfNeeded()
      }
      request.complete(y)
    }
    func reportPresentationLayout() {
      guard active, presentationLayout != nil, restoredOffset == nil, !reportingLayout,
        let scrollView, scrollView.window != nil, scrollView.bounds.height > 0,
        scrollView.contentSize.height > 0 else { return }
      reportingLayout = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.reportingLayout = false
        if self.active, self.restoredOffset == nil { self.presentationLayout?() }
      }
    }
    private var reduced = false
    private var deadline: Task<Void, Never>?
    #endif

    func accept(_ token: Int64) -> Bool {
      guard active, token > handledToken else { return false }
      handledToken = token
      #if os(iOS)
      cancelRestore()
      #endif
      cancel()
      return true
    }

    func interactionChanged(_ interacting: Bool) {
      userInteracting = interacting
      if interacting {
        #if os(iOS)
        cancelRestore()
        #endif
        cancel()
      }
    }

    func geometryChanged(_ top: Bool) {
      atTop = top
      #if os(iOS)
      if top, phase == .waitingForLayout, let id = pending?.id { reveal(id) }
      #endif
    }

    func cancel() {
      #if os(iOS)
      let previous = pending
      pending = nil
      phase = nil
      deadline?.cancel()
      deadline = nil
      cover?.layer.removeAllAnimations()
      UIView.performWithoutAnimation { cover?.alpha = 0 }
      if let previous { previous.complete(previous.token, "cancelled") }
      #endif
    }

    func reduceMotionChanged(_ value: Bool) {
      #if os(iOS)
      reduced = value
      guard value, let id = pending?.id else { return }
      phase = .jumping
      cover?.layer.removeAllAnimations()
      UIView.performWithoutAnimation { cover?.alpha = 0 }
      jump(id)
      #endif
    }

    #if os(iOS)
    func start(token: Int64, reduced: Bool, complete: @escaping (Int64, String) -> Void) {
      guard active, let scrollView, scrollView.window != nil, let cover,
        !userInteracting, !scrollView.isTracking, !scrollView.isDragging else {
        complete(token, "cancelled")
        return
      }
      if scrollView.contentOffset.y + scrollView.adjustedContentInset.top <= 1 {
        complete(token, "succeeded")
        return
      }
      let id = UUID()
      self.reduced = reduced
      pending = (id, token, complete)
      deadline = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, self?.pending?.id == id else { return }
        self?.cancel()
      }
      if reduced { jump(id); return }
      phase = .fadingOut
      UIView.animate(withDuration: 0.09, delay: 0,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
        cover.alpha = 1
      } completion: { [weak self] finished in
        guard let self, self.pending?.id == id, self.phase == .fadingOut else { return }
        if finished { self.jump(id) } else { self.cancel() }
      }
    }

    private func jump(_ id: UUID) {
      guard active, pending?.id == id, let scrollView, scrollView.window != nil,
        !scrollView.isTracking, !scrollView.isDragging else { cancel(); return }
      phase = .jumping
      UIView.performWithoutAnimation {
        scrollView.setContentOffset(
          CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
          animated: false)
        scrollView.layoutIfNeeded()
      }
      phase = .waitingForLayout
      if atTop { reveal(id) }
    }

    private func reveal(_ id: UUID) {
      guard active, pending?.id == id, phase == .waitingForLayout, let cover else { return }
      phase = .fadingIn
      if reduced {
        UIView.performWithoutAnimation { cover.alpha = 0 }
        finish(id)
        return
      }
      UIView.animate(withDuration: 0.15, delay: 0,
        options: [.curveEaseIn, .allowUserInteraction, .beginFromCurrentState]) {
        cover.alpha = 0
      } completion: { [weak self] finished in
        guard let self, self.pending?.id == id, self.phase == .fadingIn else { return }
        if finished { self.finish(id) } else { self.cancel() }
      }
    }

    private func finish(_ id: UUID) {
      guard let previous = pending, previous.id == id else { return }
      pending = nil
      phase = nil
      deadline?.cancel()
      deadline = nil
      previous.complete(previous.token, "succeeded")
    }
    #endif
  }

  #if os(iOS)
  /// Resolve the existing List scroll view once per mount; SwiftUI retains its
  /// delegate, datasource, cells and sizing. The cover never intercepts touches.
  private struct TopScrollAccess: UIViewRepresentable {
    let owner: TopScroll

    final class Anchor: UIView {
      weak var owner: TopScroll?
      private var resolving = false

      override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveIfNeeded()
      }

      override func layoutSubviews() {
        super.layoutSubviews()
        resolveIfNeeded()
      }

      func resolveIfNeeded() {
        owner?.applyRestoredOffset()
        owner?.reportPresentationLayout()
        guard window != nil, owner?.scrollView?.window == nil, !resolving else { return }
        resolving = true
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          defer { self.resolving = false }
          guard self.window != nil, let owner = self.owner,
            owner.scrollView?.window == nil else { return }
          var ancestor = self.superview
          while let candidate = ancestor, candidate !== self.window {
            if let scrollView = self.findScrollView(candidate) {
              owner.scrollView = scrollView
              owner.applyRestoredOffset()
              owner.reportPresentationLayout()
              return
            }
            ancestor = candidate.superview
          }
        }
      }

      private func findScrollView(_ view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for child in view.subviews {
          if let scrollView = findScrollView(child) { return scrollView }
        }
        return nil
      }
    }

    func makeUIView(context: Context) -> Anchor {
      let anchor = Anchor()
      anchor.isUserInteractionEnabled = false
      anchor.accessibilityElementsHidden = true
      anchor.backgroundColor = .systemBackground
      anchor.alpha = 0
      anchor.owner = owner
      owner.cover = anchor
      return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) { anchor.resolveIfNeeded() }
  }
  #endif

  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    @StateObject private var prepared: PreparedState
    @State private var scrollProxy: ScrollViewProxy?
    @State private var pendingScroll: (request: ScrollRequest, id: String, anchor: UnitPoint)?
    @StateObject private var topScroll = TopScroll()
    @State private var pullEligible = false
    @State private var pullHint = 0
    @State private var retainedPosition = ScrollPosition()
    @State private var restoringPosition = true
    @State private var restorationY: CGFloat?
    @State private var scrollMounted = false
    @State private var boundScrollIdentity: String?
    @State private var presentedScrollIdentity: String?
    @Environment(\.journalGraphScrollScope) private var graphScrollScope
    @Environment(\.journalGraphScrollOffsets) private var graphScrollOffsets
    @Environment(\.journalGraphPresentationReady) private var presentationReady
    @Environment(\.journalGraphPresentationNonce) private var presentationNonce
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(context: LUIAppleExtensionViewContext) {
      self.context = context
      _prepared = StateObject(wrappedValue: PreparedState(context: context))
    }

    private var properties: Properties? {
      prepared.snapshot?.properties
    }

    private var scrollIdentity: String? {
      guard let scope = graphScrollScope, let key = properties?.retention_key else { return nil }
      return "\(context.nodeID):\(scope.pageID):\(key)"
    }

    private func restoreScrollPosition() {
      presentedScrollIdentity = nil
      restoringPosition = true
      restorationY = nil
      boundScrollIdentity = scrollIdentity
      retainedPosition = ScrollPosition()
      #if os(iOS)
      topScroll.cancelRestore()
      #endif
      if let scope = graphScrollScope, let key = properties?.retention_key,
        let y = graphScrollOffsets?.read(page: scope.pageID, list: key) {
        restorationY = y
        #if os(iOS)
        // SwiftUI List does not honor ScrollPosition point restoration here.
        // Reuse its existing native scroll view without replacing the List.
        let identity = boundScrollIdentity
        topScroll.restoreOffset(y) { resolved in
          guard scrollMounted, boundScrollIdentity == identity else { return }
          restorationY = resolved
        }
        #else
        retainedPosition.scrollTo(y: y)
        #endif
      } else {
        restoringPosition = false
      }
    }

    private func reportPresentationLayout() {
      guard scrollMounted, presentationNonce != nil,
        let identity = boundScrollIdentity, identity == scrollIdentity,
        presentedScrollIdentity != identity, let scope = graphScrollScope, scope.records,
        properties?.retention_key != nil, let presentationReady else { return }
      #if os(iOS)
      guard let scroll = topScroll.scrollView else { return }
      let offset = scroll.contentOffset.y + scroll.adjustedContentInset.top
      if let expected = restorationY {
        guard abs(offset - expected) <= 1 else { return }
        restorationY = nil
        restoringPosition = false
      }
      #endif
      guard !restoringPosition else { return }
      presentedScrollIdentity = identity
      presentationReady(scope.pageID)
    }

    private func bindPresentationLayout() {
      if presentationNonce != nil {
        topScroll.presentationLayout = { reportPresentationLayout() }
      } else {
        topScroll.presentationLayout = nil
      }
    }

    private func emit(_ event: Event) {
      guard let data = try? JSONEncoder().encode(event) else { return }
      JournalExtensions.emit(context: context, payload: data)
    }

    private func rowEvent(action: String, row: String) {
      guard let inner = try? JSONEncoder().encode(RowEvent(key: action, row: row)),
        let payload = String(data: inner, encoding: .utf8) else { return }
      emit(Event(type: "row_event", payload: payload))
    }

    private func childContent(_ index: Int) -> AnyView {
      guard index >= 0, index < context.childIDs.count else {
        return AnyView(EmptyView())
      }
      return context.content(for: context.childIDs[index])
    }

    private var positions: [String: Int] { prepared.snapshot?.positions ?? [:] }

    private func completeScroll(_ token: Int64, _ outcome: String) {
      emit(Event(type: "scroll_completed", token: token, outcome: outcome))
    }

    private func observeScrollRequests() {
      prepared.onScrollRequest = { request in
        if let request { applyScrollRequest(request) }
        else {
          if pendingScroll != nil { pendingScroll = nil }
          topScroll.cancel()
        }
      }
    }

    /// Walk target.row_path from the section's top-level rows; intermediate
    /// elements descend into disclosure children.
    private func resolveTarget(_ target: ScrollRequest.Target) -> Row? {
      guard let section = properties?.sections.first(where: {
        $0.key == target.section
      }) else { return nil }
      var candidates = section.rows
      var row: Row?
      for (index, key) in target.row_path.enumerated() {
        row = candidates.first(where: { $0.key == key })
        guard let current = row else { return nil }
        if index + 1 < target.row_path.count {
          candidates = current.children ?? []
        }
      }
      return row
    }

    private func applyScrollRequest(_ request: ScrollRequest) {
      guard let properties, topScroll.accept(request.token) else { return }
      restorationY = nil
      restoringPosition = false
      if request.target.row_path.isEmpty {
        guard properties.sections.first?.key == request.target.section else {
          completeScroll(request.token, "missing_target")
          return
        }
        #if os(iOS)
        topScroll.start(token: request.token, reduced: reduceMotion || request.animated != true) { token, outcome in
          completeScroll(token, outcome)
        }
        #else
        withoutAnimation { scrollProxy?.scrollTo(request.target.section, anchor: .top) }
        completeScroll(request.token, "succeeded")
        #endif
        return
      }
      guard let row = resolveTarget(request.target), positions[row.key] != nil else {
        completeScroll(request.token, "missing_target")
        return
      }
      let anchor: UnitPoint = switch request.anchor {
      case "center": .center
      case "bottom": .bottom
      default: .top
      }
      pendingScroll = (request, row.key, anchor)
      // Capture can insert its target in this same content commit. Wait for
      // SwiftUI to render the pending request with those rows before scrolling.
    }

    private func withoutAnimation(_ change: () -> Void) {
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction, change)
    }

    private func performPendingScroll() {
      guard topScroll.active, let pending = pendingScroll,
        pending.request.token == topScroll.handledToken, let proxy = scrollProxy else { return }
      withoutAnimation { proxy.scrollTo(pending.id, anchor: pending.anchor) }
      if !pending.request.target.row_path.isEmpty {
        pendingScroll = nil
        if properties?.track_scroll_completion == true {
          completeScroll(pending.request.token, "succeeded")
        }
      }
    }

    private func separatorVisibility(_ name: String?) -> Visibility {
      switch name {
      case "hidden": .hidden
      case "visible": .visible
      default: .automatic
      }
    }

    private func actionInteractive(_ action: Action) -> Bool {
      action.enabled != false && context.isUserInteractionEnabled
    }

    private func actionLabel(_ action: Action) -> some SwiftUI.View {
      Group {
        if let symbol = action.symbol {
          Label(action.title, systemImage: symbol)
        } else {
          Text(action.title)
        }
      }
    }

    @ViewBuilder private func rowActions(_ row: Row) -> some SwiftUI.View {
      let branchAction = properties?.style == "detail"
        ? row.context_menu?.actions.first(where: { $0.key == "expand" || $0.key == "collapse" })
        : nil
      Group {
        if let branchAction {
          childContent(row.content_index)
            .contentShape(Rectangle())
            .onTapGesture {
              if actionInteractive(branchAction) { rowEvent(action: branchAction.key, row: row.key) }
            }
            .accessibilityHint(branchAction.title)
            .accessibilityAction(named: Text(branchAction.title)) {
              if actionInteractive(branchAction) { rowEvent(action: branchAction.key, row: row.key) }
            }
        } else {
          childContent(row.content_index)
        }
      }
        .id(row.key)
        .listRowInsets(properties?.style == "detail"
          ? EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20) : nil)
        .listRowSeparator(separatorVisibility(row.separator))
        .accessibilityIdentifier(row.test_id ?? row.key)
        .contextMenu {
          ForEach(row.context_menu?.actions ?? []) { action in
            Button(role: action.role == "destructive" ? .destructive : nil) {
              rowEvent(action: action.key, row: row.key)
            } label: {
              actionLabel(action)
            }
            .disabled(!actionInteractive(action))
          }
        }
    }

    // Opaque `some View` can't express the recursive disclosure shape.
    private func rowBody(_ row: Row) -> AnyView {
      let lease = prepared.lease(for: row.key)
      let content = rowActions(row)
        .onAppear {
          if let lease {
            DispatchQueue.main.async { prepared.receive(lease, appeared: true) }
          }
        }
        .onDisappear {
          if let lease {
            DispatchQueue.main.async { prepared.receive(lease, appeared: false) }
          }
        }
      if row.isDisclosure {
        return AnyView(DisclosureGroup(
          isExpanded: Binding(
            get: { row.expanded == true },
            set: { value in
              emit(Event(type: "expanded", key: row.key, expanded: value))
            })
        ) {
          ForEach(row.children ?? []) { child in
            rowBody(child)
          }
        } label: {
          content
        }.listRowSeparator(separatorVisibility(row.separator)))
      }
      return AnyView(content)
    }

    private var style: ListStyleConfiguration {
      switch properties?.style {
      case "detail": return .detail
      case "inset": return .inset
      case "inset_grouped": return .insetGrouped
      default: return .plain
      }
    }

    private func cancelPull() {
      pullEligible = false
      pullHint = 0
    }

    private func scrollPhaseChanged(from previous: ScrollPhase, to phase: ScrollPhase) {
      guard scrollMounted, boundScrollIdentity == scrollIdentity else { return }
      let wasTracking = previous == .tracking || previous == .interacting
      let tracking = phase == .tracking || phase == .interacting
      if tracking && !wasTracking {
        restorationY = nil
        restoringPosition = false
        pullEligible = properties?.sync_enabled == true && topScroll.atTop
        pullHint = 0
      }
      if wasTracking && !tracking {
        var cancelled = false
        #if os(iOS)
        let nativePhase = topScroll.scrollView?.panGestureRecognizer.state
        cancelled = nativePhase == .cancelled || nativePhase == .failed
        #endif
        let trigger = pullEligible && pullHint == 2 && !cancelled
          && (phase == .idle || phase == .decelerating)
          && properties?.sync_enabled == true
        cancelPull()
        if trigger { emit(Event(type: "sync")) }
      }
      // The existing top-scroll owner retains interaction cancellation.
      topScroll.interactionChanged(tracking)
    }

    var body: some SwiftUI.View {
      ScrollViewReader { proxy in
        List {
          ForEach(properties?.sections ?? []) { section in
            Section {
              ForEach(section.rows) { row in
                rowBody(row)
              }
            } header: {
              if let header = section.header_index {
                childContent(header)
              }
            } footer: {
              if let footer = section.footer_index {
                childContent(footer)
              }
            }
            .id(section.key)
            .listSectionSeparator(separatorVisibility(section.separator))
          }
        }
        .modifier(ListStyleModifier(style: style))
        .scrollPosition($retainedPosition)
        #if os(iOS)
        .overlay(TopScrollAccess(owner: topScroll).ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true))
        #endif
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
          geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
          guard scrollMounted, boundScrollIdentity == scrollIdentity else { return }
          topScroll.geometryChanged(offset <= 1)
          if let target = restorationY, abs(offset - target) <= 1 {
            restorationY = nil
            restoringPosition = false
          }
          if !restoringPosition, let scope = graphScrollScope, scope.records, let key = properties?.retention_key {
            graphScrollOffsets?.write(page: scope.pageID, list: key, y: offset)
          }
          if pullEligible {
            // Only the three semantic hint states invalidate the view.
            let hint = offset <= -72 ? 2 : offset <= -20 ? 1 : 0
            if pullHint != hint { pullHint = hint }
          }
        }
        .onScrollPhaseChange { previous, phase in
          scrollPhaseChanged(from: previous, to: phase)
        }
        .overlay(alignment: .top) {
          if pullEligible && pullHint > 0 {
            Image(systemName: pullHint == 2 ? "arrow.clockwise" : "arrow.down")
              .font(.footnote)
              .frame(width: 24, height: 24)
              .foregroundStyle(.secondary)
              .padding(.top, 12)
              .allowsHitTesting(false)
              .accessibilityLabel(pullHint == 2 ? "Release to sync" : "Pull to sync")
              .accessibilityIdentifier("journal-pull-sync-hint")
              .contentTransition(.identity)
              .transaction { $0.animation = nil }
          }
        }
        .accessibilityActions {
          if properties?.sync_enabled == true {
            Button("Sync") { emit(Event(type: "sync")) }
          }
        }
        .onAppear {
          topScroll.active = true
          bindPresentationLayout()
          prepared.bind(context)
          scrollMounted = true
          restoreScrollPosition()
          scrollProxy = proxy
          performPendingScroll()
          observeScrollRequests()
        }
      }
      .onDisappear {
        topScroll.presentationLayout = nil
        presentedScrollIdentity = nil
        scrollMounted = false
        boundScrollIdentity = nil
        restoringPosition = true
        restorationY = nil
        cancelPull()
        topScroll.active = false
        #if os(iOS)
        topScroll.cancelRestore()
        #endif
        topScroll.interactionChanged(false)
        topScroll.cancel()
        pendingScroll = nil
        prepared.suspend()
        scrollProxy = nil
        topScroll.geometryChanged(false)
      }
      .onChange(of: context.nodeID) { _, _ in
        bindPresentationLayout()
        restoringPosition = true
        boundScrollIdentity = nil
        cancelPull()
        topScroll.interactionChanged(false)
        topScroll.cancel()
        pendingScroll = nil
        prepared.dispose()
        topScroll.handledToken = 0
        topScroll.geometryChanged(false)
        prepared.bind(context)
        restoreScrollPosition()
        #if os(iOS)
        topScroll.reportPresentationLayout()
        #endif
        observeScrollRequests()
      }
      .onChange(of: scrollIdentity) { _, _ in
        if scrollMounted && boundScrollIdentity != scrollIdentity {
          bindPresentationLayout()
          restoreScrollPosition()
          #if os(iOS)
          topScroll.reportPresentationLayout()
          #endif
        }
      }
      .onChange(of: reduceMotion) { _, reduced in topScroll.reduceMotionChanged(reduced) }
      .onChange(of: presentationNonce) { _, _ in
        presentedScrollIdentity = nil
        bindPresentationLayout()
        #if os(iOS)
        if scrollMounted { topScroll.reportPresentationLayout() }
        #endif
      }
      .onChange(of: pendingScroll?.request.token) { _, _ in performPendingScroll() }
    }
  }

  private enum ListStyleConfiguration {
    case plain, inset, insetGrouped, detail
  }

  private struct ListStyleModifier: ViewModifier {
    let style: ListStyleConfiguration
    func body(content: Content) -> some SwiftUI.View {
      Group {
        if style == .detail {
          content.listStyle(.plain).environment(\.defaultMinListRowHeight, 0)
        } else {
        #if os(macOS)
        if style == .plain {
          content.listStyle(.plain)
        } else {
          // inset_grouped has no macOS equivalent — the inset style is the
          // closest native presentation.
          content.listStyle(.inset)
        }
        #else
        if style == .plain {
          content.listStyle(.plain)
        } else {
          content.listStyle(.insetGrouped)
        }
        #endif
        }
      }
    }
  }
}
