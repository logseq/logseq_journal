import LUIAppleBackend
import SwiftUI
import Observation

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
    let token: String
    let target: Target
    let anchor: String?
    let animated: Bool?
  }
  struct Properties: Decodable {
    let style: String
    let sections: [SectionModel]
    let scroll_request: ScrollRequest?
    let track_visible_range: Bool?
    let track_scroll_completion: Bool?
  }

  /// One payload observation belongs to one mounted native list. Child-model
  /// changes do not decode it, and cell lifecycle reads only prepared indices.
  @MainActor final class Snapshot {
    let properties: Properties
    let positions: [String: Int]

    init?(_ json: String) {
      guard let properties = try? JSONDecoder().decode(Properties.self, from: Data(json.utf8))
      else { return nil }
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
    private var context: LUIAppleExtensionViewContext?
    private var instance = UUID()
    private var rowIncarnations: [String: UUID] = [:]
    private var visible: Set<String> = []
    private var delivered: Range<Int>?
    private var payload: String?
    private var refreshTask: Task<Void, Never>?
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
      guard self.context == nil else { scheduleRange(); return }
      self.context = context
      refresh()
    }

    // A navigation destination can be retained while temporarily offscreen.
    // Keep its native List content, visible keys and row identities for Back.
    func suspend() {
      active = false
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
      emitTask?.cancel()
      emitTask = nil
      // Keep List content while a retained navigation destination is offscreen.
      // Binding again refreshes it before delivering any lifecycle work.
      payload = nil
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
        snapshot = nextPayload.flatMap(Snapshot.init)
        let positions = snapshot?.positions ?? [:]
        rowIncarnations = positions.reduce(into: [:]) { result, entry in
          result[entry.key] = rowIncarnations[entry.key] ?? UUID()
        }
        visible = visible.intersection(positions.keys)
      }
      dirty = false
      let pending = queued
      queued.removeAll()
      for (lease, appeared) in pending { _ = receive(lease, appeared: appeared) }
      scheduleRange()
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
        guard let data = try? JSONSerialization.data(withJSONObject:
          ["type": "visible_range", "first": next.lowerBound, "last": next.upperBound],
          options: [.sortedKeys]) else { return }
        if JournalExtensions.emit(context: context, payload: data) {
          self.delivered = next
        }
      }
    }
  }

  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    @StateObject private var prepared: PreparedState
    @State private var handledScrollToken: Int64 = 0
    @State private var scrollProxy: ScrollViewProxy?
    @State private var pendingScroll: (id: String, anchor: UnitPoint)?

    init(context: LUIAppleExtensionViewContext) {
      self.context = context
      _prepared = StateObject(wrappedValue: PreparedState(context: context))
    }

    private var properties: Properties? {
      prepared.snapshot?.properties
    }

    private func emit(_ fields: [String: Any]) {
      guard let data = try? JSONSerialization.data(
        withJSONObject: fields, options: [.sortedKeys])
      else { return }
      JournalExtensions.emit(context: context, payload: data)
    }

    private func rowEvent(action: String, row: String) {
      guard let inner = try? JSONSerialization.data(
        withJSONObject: ["key": action, "row": row], options: [.sortedKeys]),
        let payload = String(data: inner, encoding: .utf8)
      else { return }
      emit(["type": "row_event", "payload": payload])
    }

    private func childContent(_ index: Int) -> AnyView {
      guard index >= 0, index < context.childIDs.count else {
        return AnyView(EmptyView())
      }
      return context.content(for: context.childIDs[index])
    }

    private var positions: [String: Int] { prepared.snapshot?.positions ?? [:] }

    private func completeScroll(_ token: String, _ outcome: String) {
      emit(["type": "scroll_completed", "token": token, "outcome": outcome])
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
      guard let token = Int64(request.token), token > handledScrollToken else {
        return
      }
      handledScrollToken = token
      guard let properties else { return }
      guard let row = resolveTarget(request.target) else {
        completeScroll(request.token, "missing_target")
        return
      }
      // A row hidden by a collapsed ancestor cannot be scrolled to; the OCaml
      // decoder has no hidden_target variant, so report missing_target.
      guard positions[row.key] != nil else {
        completeScroll(request.token, "missing_target")
        return
      }
      let anchor: UnitPoint =
        switch request.anchor {
        case "center": .center
        case "bottom": .bottom
        default: .top
        }
      pendingScroll = (id: row.key, anchor: anchor)
      if properties.track_scroll_completion == true {
        completeScroll(request.token, "succeeded")
      }
    }

    private func performPendingScroll() {
      guard let pending = pendingScroll, let proxy = scrollProxy else { return }
      pendingScroll = nil
      proxy.scrollTo(pending.id, anchor: pending.anchor)
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
      childContent(row.content_index)
        .id(row.key)
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
              emit(["type": "expanded", "key": row.key, "expanded": value])
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
      case "inset": return .inset
      case "inset_grouped": return .insetGrouped
      default: return .plain
      }
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
            .listSectionSeparator(separatorVisibility(section.separator))
          }
        }
        .modifier(ListStyleModifier(style: style))
        .onAppear {
          prepared.bind(context)
          scrollProxy = proxy
          performPendingScroll()
          if let request = properties?.scroll_request { applyScrollRequest(request) }
        }
        .onChange(of: pendingScroll?.id) { _, _ in performPendingScroll() }
      }
      .onDisappear {
        prepared.suspend()
        pendingScroll = nil
        scrollProxy = nil
      }
      .onChange(of: context.nodeID) { _, _ in
        prepared.dispose()
        handledScrollToken = 0
        pendingScroll = nil
        prepared.bind(context)
        if let request = properties?.scroll_request { applyScrollRequest(request) }
      }
      .onChange(of: properties?.scroll_request?.token) { _, _ in
        if let request = properties?.scroll_request { applyScrollRequest(request) }
      }
    }
  }

  private enum ListStyleConfiguration {
    case plain, inset, insetGrouped
  }

  private struct ListStyleModifier: ViewModifier {
    let style: ListStyleConfiguration
    func body(content: Content) -> some SwiftUI.View {
      Group {
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
