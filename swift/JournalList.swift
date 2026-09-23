import LUIAppleBackend
import SwiftUI

/// SwiftUI host for the `journal-list` extension — the lui replacement for
/// bonsai's `Native_list` family (grouped sections, disclosure rows, scroll
/// position requests, visible-range paging, swipe + context actions).
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
    let side: String?
    let title: String
    let background: String?
    var id: String { key }
  }
  struct ActionGroup: Decodable { let actions: [Action] }
  struct Row: Decodable, Identifiable {
    let type: String
    let key: String
    let content_index: Int
    let separator: String?
    let test_id: String?
    let swipe: ActionGroup?
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

  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    @State private var visible: Set<Int> = []
    @State private var delivered: (first: Int, last: Int)?
    @State private var handledScrollToken: Int64 = 0
    @State private var scrollProxy: ScrollViewProxy?
    @State private var pendingScroll: (id: String, anchor: UnitPoint)?
    @State private var visibleEmitTask: Task<Void, Never>?

    private var properties: Properties? {
      JournalExtensions.decode(Properties.self, context: context)
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

    /// Rows displayed in payload order; disclosure children appear only while
    /// their parent row is expanded. The OCaml side maps these positions to
    /// its own row indices.
    private var positions: [String: Int] {
      guard let properties else { return [:] }
      var map: [String: Int] = [:]
      var index = 0
      func walk(_ row: Row) {
        map[row.key] = index
        index += 1
        if row.isDisclosure, row.expanded == true {
          (row.children ?? []).forEach(walk)
        }
      }
      for section in properties.sections {
        section.rows.forEach(walk)
      }
      return map
    }

    private func updateVisibleRange() {
      guard let properties, properties.track_visible_range == true else { return }
      let ordered = visible.sorted()
      guard let first = ordered.first, let last = ordered.last else {
        delivered = nil
        return
      }
      let range = (first, last + 1)
      guard delivered?.first != range.0 || delivered?.last != range.1 else { return }
      delivered = range
      // Cells flicker in/out while the collection re-layouts; emit only the
      // settled range so an oscillating boundary row cannot flood the bridge.
      visibleEmitTask?.cancel()
      visibleEmitTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled else { return }
        emit(["type": "visible_range", "first": range.0, "last": range.1])
      }
    }

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

    private static func actionTint(_ background: String?) -> Color? {
      guard let background, background != "transparent" else { return nil }
      var hex = background
      if hex.hasPrefix("#") { hex.removeFirst() }
      guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
      return Color(
        red: Double((value >> 16) & 0xff) / 255,
        green: Double((value >> 8) & 0xff) / 255,
        blue: Double(value & 0xff) / 255)
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
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
          ForEach(row.swipe?.actions.filter { $0.side == "start" } ?? []) { action in
            Button { rowEvent(action: action.key, row: row.key) } label: {
              actionLabel(action)
            }
            .disabled(!actionInteractive(action))
            .tint(Self.actionTint(action.background))
          }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          ForEach(row.swipe?.actions.filter { $0.side != "start" } ?? []) { action in
            Button(role: action.role == "destructive" ? .destructive : nil) {
              rowEvent(action: action.key, row: row.key)
            } label: {
              actionLabel(action)
            }
            .disabled(!actionInteractive(action))
            .tint(Self.actionTint(action.background))
          }
        }
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
      let content = rowActions(row)
        .onAppear {
          if let position = positions[row.key] {
            DispatchQueue.main.async {
              visible.insert(position)
              updateVisibleRange()
            }
          }
        }
        .onDisappear {
          if let position = positions[row.key] {
            DispatchQueue.main.async {
              visible.remove(position)
              updateVisibleRange()
            }
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
        })
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
          scrollProxy = proxy
          performPendingScroll()
          if let request = properties?.scroll_request { applyScrollRequest(request) }
        }
        .onChange(of: pendingScroll?.id) { _, _ in performPendingScroll() }
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
