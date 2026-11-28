import LUIAppleBackend
import SwiftUI
#if os(iOS)
import UIKit
#endif

private extension EnvironmentValues {
  @Entry var journalTimelineDetails: Binding<Bool>? = nil
}

#if !os(iOS)
private enum JournalFilterAccessibilityTarget: Hashable {
  case trigger, heading
}

private extension EnvironmentValues {
  @Entry var journalFilterAccessibilityFocus: AccessibilityFocusState<JournalFilterAccessibilityTarget?>.Binding? = nil
}

#endif

/// One initial native layout handoff for this GraphPages lifetime, not per graph.
/// Later routes may have no Timeline list; downloads never participate.
struct JournalGraphInitialPresentation {
  let nonce = UUID()
  private var finished = false
  func covers(page: String?, visible: Bool, loading: Bool, cold: Bool) -> Bool {
    return page != nil && visible && !loading && !cold && !finished
  }
  mutating func ready(page: String, nonce: UUID) {
    guard nonce == self.nonce else { return }
    finished = true
  }
  mutating func cancel(page: String?) {
    finished = true
  }
}

#if os(iOS)
/// Fences one gesture and a committed focus request by its original owners.
/// The target page stays mounted while Save may defer the focus publication.
@MainActor final class JournalGraphHandoff: ObservableObject {
  struct Request { let id: UUID; let source: String; let target: String }
  @Published private(set) var request: Request?
  private var gestureID: UUID?
  func startGesture() -> UUID { cancel(); let id=UUID();gestureID=id;return id }
  func acceptsGesture(_ id: UUID) -> Bool { gestureID == id }
  var currentGesture: UUID? { gestureID }
  @discardableResult func begin(source: String, target: String) -> UUID {
    cancel();let id=UUID();request=Request(id:id,source:source,target:target);return id
  }
  func finish(_ id: UUID, page: String, current: String?) -> Bool {
    guard let request,request.id==id,request.target==page,current==page else {return false}
    cancel();return true
  }
  func focusChanged(_ page: String?) {
    guard let request else {cancel();return}
    if page != request.source {cancel()}
  }
  func retain(_ pages:[String]) {
    if let request,!pages.contains(request.source) || !pages.contains(request.target) {cancel()}
  }
  func cancel(){gestureID=nil;request=nil}
}

/// Cold pages are constructed under a real native transition. Warm pages never
/// allocate a snapshot or wait for this layout handshake.
@MainActor final class JournalGraphColdMotion:ObservableObject {
  struct Ticket {let id:UUID;let source:String;let target:String}
  @Published private(set) var ticket:Ticket?
  @Published private(set) var layoutNonce:UUID?
  private final class WeakView {weak var value:UIView?;init(_ value:UIView){self.value=value}}
  final class Surface:UIView {
    let canvas=UIView()
    let image=UIImageView()
    override init(frame:CGRect) {
      super.init(frame:frame)
      backgroundColor = .clear;isUserInteractionEnabled=false;accessibilityElementsHidden=true
      canvas.backgroundColor = .systemBackground;canvas.isUserInteractionEnabled=false
      canvas.accessibilityElementsHidden=true;canvas.isHidden=true
      canvas.frame=bounds;canvas.autoresizingMask=[.flexibleWidth,.flexibleHeight]
      image.frame=canvas.bounds;image.autoresizingMask=[.flexibleWidth,.flexibleHeight]
      image.contentMode = .scaleToFill
      addSubview(canvas);canvas.addSubview(image)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
  }
  private var views:[String:WeakView]=[:]
  private weak var surface:Surface?
  private var moved=false
  private var laidOut=false
  private var revealing=false
  private var reduced=false
  private var fallback:Task<Void,Never>?
  func attach(_ surface:Surface){self.surface=surface}
  func register(_ owner:String,view:UIView){views[owner]=WeakView(view)}
  func unregister(_ owner:String,view:UIView) {
    if views[owner]?.value === view {views.removeValue(forKey:owner)}
    if ticket?.source==owner || ticket?.target==owner {cancel()}
  }
  func retain(_ owners:[String]) {
    views=views.filter{owners.contains($0.key)}
    if let ticket,(!owners.contains(ticket.source) || !owners.contains(ticket.target)){cancel()}
  }
  func begin(source:String,target:String)->Bool {
    guard let view=views[source]?.value,view.window != nil,let surface,
      view.bounds.width>0,view.bounds.height>0 else{return false}
    cancel()
    let format=UIGraphicsImageRendererFormat()
    format.scale=view.window?.screen.scale ?? 1
    var drawn=false
    let image=UIGraphicsImageRenderer(bounds:view.bounds,format:format).image{_ in
      drawn=view.drawHierarchy(in:view.bounds,afterScreenUpdates:false)
    }
    guard drawn else{return false}
    ticket=Ticket(id:UUID(),source:source,target:target)
    moved=false;laidOut=false;revealing=false
    surface.canvas.alpha=1;surface.canvas.isHidden=false
    surface.image.image=image;surface.image.transform = .identity
    return true
  }
  func move(_ x:CGFloat) {
    guard ticket != nil,let surface else{return}
    UIView.performWithoutAnimation{surface.image.transform=CGAffineTransform(translationX:x,y:0)}
  }
  func commit(width:CGFloat,reduced:Bool,prepare:@escaping()->Void,complete:@escaping()->Void,cancelled:@escaping()->Void) {
    guard let ticket,let surface else{return}
    self.reduced=reduced
    UIView.animate(withDuration:reduced ? 0.01 : 0.24,delay:0,
      options:[.curveEaseOut,.allowUserInteraction,.beginFromCurrentState]) {
      surface.image.transform=CGAffineTransform(translationX:width,y:0)
    } completion:{[weak self] finished in
      guard let self,self.ticket?.id==ticket.id else{return}
      guard finished else{self.cancel();cancelled();return}
      self.moved=true;self.laidOut=false;self.layoutNonce=UUID()
      complete();self.revealIfReady()
    }
    // Commit the source-only native motion before constructing the cold page.
    // This is not evidence that preparation itself stopped blocking the CPU.
    CATransaction.flush()
    DispatchQueue.main.async{[weak self] in
      guard self?.ticket?.id==ticket.id else{return};prepare()
    }
  }
  func returnToSource(reduced:Bool,complete:@escaping()->Void) {
    guard let ticket,let surface else{complete();return}
    UIView.animate(withDuration:reduced ? 0.01 : 0.24,delay:0,
      options:[.curveEaseOut,.allowUserInteraction,.beginFromCurrentState]) {
      surface.image.transform = .identity
    } completion:{[weak self] _ in
      guard self?.ticket?.id==ticket.id else{return};self?.cancel();complete()
    }
  }
  func ready(page:String,nonce:UUID) {
    guard let ticket,layoutNonce==nonce,ticket.target==page else{return}
    laidOut=true;revealIfReady()
  }
  func focused(_ page:String?) {
    guard let ticket,ticket.target==page else{return}
    fallback?.cancel()
    fallback=Task{@MainActor [weak self] in
      try? await Task.sleep(for:.seconds(1))
      guard !Task.isCancelled,self?.ticket?.id==ticket.id else{return}
      // Reveal the real focused Loading/error content if it has no List.
      self?.laidOut=true;self?.revealIfReady()
    }
  }
  private func revealIfReady() {
    guard moved,laidOut,!revealing,let ticket,let surface else{return}
    revealing=true;fallback?.cancel();fallback=nil
    if reduced {cancel();return}
    UIView.animate(withDuration:0.15,delay:0,
      options:[.curveEaseIn,.allowUserInteraction,.beginFromCurrentState]) {
      surface.canvas.alpha=0
    } completion:{[weak self] _ in
      guard self?.ticket?.id==ticket.id else{return};self?.cancel()
    }
  }
  func cancel() {
    fallback?.cancel();fallback=nil
    surface?.canvas.layer.removeAllAnimations();surface?.image.layer.removeAllAnimations()
    if let surface {UIView.performWithoutAnimation{
      surface.canvas.isHidden=true;surface.canvas.alpha=1
      surface.image.image=nil;surface.image.transform = .identity
    }}
    moved=false;laidOut=false;revealing=false;layoutNonce=nil;ticket=nil
  }
}
/// The target's own Loading/error body has no List readiness callback.
/// Report only a fresh post-slide native layout, never mere view creation.
private struct JournalGraphLoadingLayout:UIViewRepresentable {
  let nonce:UUID
  let ready:()->Void
  final class Anchor:UIView {
    var nonce:UUID?
    var reported:UUID?
    var ready:(()->Void)?
    override func layoutSubviews() {
      super.layoutSubviews()
      guard let nonce,reported != nonce,window != nil,bounds.width>0,bounds.height>0 else{return}
      reported=nonce
      DispatchQueue.main.async{[weak self] in
        guard let self,self.nonce==nonce,self.window != nil else{return};self.ready?()
      }
    }
  }
  func makeUIView(context:Context)->Anchor {
    let view=Anchor();view.isUserInteractionEnabled=false;view.accessibilityElementsHidden=true;return view
  }
  func updateUIView(_ view:Anchor,context:Context) {
    view.nonce=nonce;view.ready=ready;view.setNeedsLayout()
  }
  static func dismantleUIView(_ view:Anchor,coordinator:()) {view.nonce=nil;view.ready=nil}
}
private struct JournalGraphColdSurface:UIViewRepresentable {
  let owner:JournalGraphColdMotion
  func makeUIView(context:Context)->JournalGraphColdMotion.Surface {
    let view=JournalGraphColdMotion.Surface();owner.attach(view);return view
  }
  func updateUIView(_ view:JournalGraphColdMotion.Surface,context:Context){}
}

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
    case timelineHost = "timeline-host"
    case timelineInteraction = "timeline-interaction"
    case timelineRow = "timeline-row"
    case graphPicker = "graph-picker"
    case toolbarControl = "toolbar-control"
    case bottomBar = "bottom-bar"
    case capturePresentation = "capture-presentation"
    case detailText = "detail-text"
    case boundedText = "bounded-text"
    case filterOverlay = "filter-overlay"
    case filterTrigger = "filter-trigger"
  }

  private struct FilterChoice: Decodable, Identifiable {
    let id: String
    let label: String
    let selected: Bool
  }

  private struct FilterChoices: Decodable {
    let tags: [FilterChoice]
    let statuses: [FilterChoice]
    let times: [FilterChoice]
    let results: [FilterChoice]
  }

  private struct FilterCustom: Decodable {
    let count: String
    let units: [FilterChoice]
  }

  private struct TimelineCreator: Decodable {
    let id: String
    let name: String

    var initials: String {
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let prefixLength = name.range(of: #"^[\p{Latin}\p{N}]"#, options: .regularExpression) == nil ? 1 : 2
      return name.prefix(prefixLength).uppercased()
    }

    var tint: Color {
      let seed = UInt32(id.prefix(8), radix: 16) ?? 0
      return Color(hue: Double(seed % 360) / 360, saturation: 0.48, brightness: 0.85)
    }
  }

  private struct TimelineMetadata: SwiftUI.View {
    let time: String
    let creator: TimelineCreator?
    let tags: [String]

    var body: some SwiftUI.View {
      VStack(alignment: .trailing, spacing: 2) {
        HStack(spacing: 4) {
          if let creator {
            let initials = creator.initials
            Group {
              if initials.isEmpty {
                Image(systemName: "person.fill")
              } else {
                Text(initials).lineLimit(1).minimumScaleFactor(0.75)
              }
            }
              .font(.system(size: 9, weight: .semibold))
              .frame(width: 16, height: 16)
              .background(creator.tint.opacity(0.35), in: Circle())
              .foregroundStyle(.primary)
              .accessibilityLabel(initials.isEmpty ? Text("Block creator") : Text(verbatim: creator.name))
              .accessibilityIdentifier("journal-timeline-creator")
          }
          Text(time)
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(minHeight: 16)
            .accessibilityIdentifier("journal-timeline-created-time")
        }
        if let first = tags.first {
          HStack(spacing: 4) {
            Text("#" + first).lineLimit(1)
            if tags.count > 1 {
              Text("+\(tags.count - 1)").fixedSize()
            }
          }
          .font(.caption2)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text(verbatim: tags.map { "#" + $0 }.joined(separator: ", ")))
          .accessibilityIdentifier("journal-timeline-tags")
        }
      }
      .foregroundStyle(.secondary)
    }
  }

  private struct TimelineRowLayout: Layout {
    var detailProgress: CGFloat

    var animatableData: CGFloat {
      get { detailProgress }
      set { detailProgress = newValue }
    }

    private func widths(for width: CGFloat) -> (body: CGFloat, metadata: CGFloat) {
      let metadata = (width * 0.18).rounded(.down)
      return (max(0, width - metadata - 8), metadata)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
      let widths = widths(for: width)
      // Both presentations use the same row size, including rows with wrapping
      // text or attachments. Switching changes only the native placement.
      let compact = subviews[0].sizeThatFits(.init(width: width, height: nil))
      let detail = subviews[0].sizeThatFits(.init(width: widths.body, height: nil))
      let metadata = subviews[1].sizeThatFits(.init(width: widths.metadata, height: nil))
      return CGSize(width: width, height: max(compact.height, detail.height, metadata.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
      let widths = widths(for: bounds.width)
      let bodyWidth = bounds.width + (widths.body - bounds.width) * detailProgress
      let metadataTrailingOutset: CGFloat = 14
      subviews[0].place(at: bounds.origin, anchor: .topLeading,
                        proposal: .init(width: bodyWidth, height: nil))
      subviews[1].place(at: CGPoint(x: bounds.maxX + metadataTrailingOutset, y: bounds.minY), anchor: .topTrailing,
                        proposal: .init(width: widths.metadata, height: nil))
    }
  }

  private struct Properties: Decodable {
    let mode: Mode
    let title: String?
    let connecting: Bool?
    let controls: Bool?
    let pending: Bool?
    let error: String?
    let text: String?
    let creator: TimelineCreator?
    let tags: [String]?
    let runs: [TitleRun]?
    let maxLines: Int?
    let id: String?
    let level: Int?
    let loading: Bool?
    let initial: Bool?
    let canChoose: Bool?
    let active: Bool?
    let value: Double?
    let message: String?
    let enabled: Bool?
    let pageID: String?
    let targetID: String?
    let targetPageID: String?
    let targetGraphName: String?
    let residentPageIDs: [String]?
    let slotOwners: [String]?
    let loadingPageIDs: [String]?
    let ownerID: String?
    let visible: Bool?
    let sheetEpoch: Int?
    let filterOwner: Int?
    let filterNames: [String]?
    let filterActiveName: String?
    let filterError: String?
    let choices: FilterChoices?
    let custom: FilterCustom?
    let dateRange: [Int]?
  }

  private struct FilterChip: SwiftUI.View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some SwiftUI.View {
      Button(action: action) {
        HStack(spacing: 4) {
          Text(label).lineLimit(1)
          if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(selected ? filterBlue(scheme) : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? filterBlue(scheme).opacity(0.12) : Color.primary.opacity(0.06), in: .capsule)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(selected ? .isSelected : [])
    }
  }

  private struct FilterTriggerButton: SwiftUI.View {
    let count: Int
    let names: [String]
    let activeName: String?
    let action: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var active: Bool { count > 0 }

    private var icon: some SwiftUI.View {
      Image(systemName: "line.3.horizontal.decrease")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(active ? filterBlue(scheme) : Color.primary)
          .frame(width: 44, height: 44)
          .background(active ? filterBlue(scheme).opacity(0.14) : .clear, in: Circle())
          .overlay(alignment: .topTrailing) {
            if active {
              Circle().fill(filterBlue(scheme))
                .frame(width: 6, height: 6)
                .padding(8)
                .accessibilityHidden(true)
            }
          }
          .contentShape(Circle())
    }

    var body: some SwiftUI.View {
      Group {
        if names.isEmpty {
          Button { action("open") } label: { icon }.buttonStyle(.plain)
        } else {
          Menu {
            ForEach(names.map(JournalSavedFilterName.init)) { saved in
              let name = saved.name
              Button { action("select:" + name) } label: {
                if activeName?.utf8.elementsEqual(name.utf8) == true { Label(name, systemImage: "checkmark") }
                else { Text(name) }
              }
            }
            Divider()
            Button("Clear filter") { action("clear") }
            Button("Configure filters") { action("open") }
          } label: { icon }
          .menuOrder(.fixed)
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
        }
      }
      #if os(iOS)
      .background {
        if reduceTransparency { Circle().fill(Color(uiColor: .secondarySystemBackground)) }
      }
      .glassEffect(reduceTransparency ? .identity : .regular.interactive(), in: Circle())
      #else
      .background(Color.primary.opacity(0.06), in: Circle())
      #endif
      .accessibilityLabel("Filters")
      .accessibilityValue(count == 0 ? "No active filters" : count == 1 ? "1 active filter" : "\(count) active filters")
      .accessibilityIdentifier("journal-filters")
    }
  }

  private static func filterBlue(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(red: 0.59, green: 0.74, blue: 1) : Color(red: 0.12, green: 0.31, blue: 0.63)
  }

  private struct FilterChipRows: Layout {
    private func arrange(width: CGFloat, subviews: Subviews) -> ([CGRect], CGFloat) {
      var x: CGFloat = 0
      var y: CGFloat = 0
      var rowHeight: CGFloat = 0
      var frames: [CGRect] = []
      for view in subviews {
        let ideal = view.sizeThatFits(.unspecified)
        let size = view.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
        if x > 0 && x + size.width > width {
          x = 0
          y += rowHeight
          rowHeight = 0
        }
        frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
        x += size.width + 6
        rowHeight = max(rowHeight, size.height)
      }
      return (frames, y + rowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + 6 }
      return CGSize(width: width, height: arrange(width: width, subviews: subviews).1)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
      for (view, frame) in zip(subviews, arrange(width: bounds.width, subviews: subviews).0) {
        view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                   anchor: .topLeading, proposal: ProposedViewSize(frame.size))
      }
    }
  }

  private struct FilterPanel: SwiftUI.View {
    let properties: Properties
    let choices: FilterChoices
    let send: (String) -> Void
    #if !os(iOS)
    let accessibilityFocus: AccessibilityFocusState<JournalFilterAccessibilityTarget?>.Binding
    #endif
    @State private var showsTags = false
    @State private var managesSavedFilters = false
    @State private var confirmingDeletion = false
    @State private var deletionName: String?
    @State private var naming = false
    @State private var filterName = ""
    @FocusState private var editing: Field?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Field: Hashable { case tags, count }

    private var surface: Color {
      #if os(iOS)
      Color(uiColor: .systemBackground)
      #else
      Color(nsColor: .windowBackgroundColor)
      #endif
    }

    private func action(_ id: String, _ title: String) -> some SwiftUI.View {
      Button { send(id) } label: { actionLabel(title) }
        .buttonStyle(.plain)
        .keyboardShortcut(id == "cancel" ? .cancelAction : nil)
        .accessibilityIdentifier("journal-filter-\(id)")
    }

    private func actionLabel(_ title: String) -> some SwiftUI.View {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(filterBlue(scheme))
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }

    private func heading(_ title: String) -> some SwiftUI.View {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }

    private func chip(_ choice: FilterChoice) -> some SwiftUI.View {
      FilterChip(label: choice.label, selected: choice.selected) { send(choice.id) }
        .accessibilityIdentifier("journal-filter-\(choice.id)")
    }

    private func changeCount(_ count: String, by delta: Int) {
      guard let value = Int(count) else { send("count:1"); return }
      let (next, overflow) = value.addingReportingOverflow(delta)
      if !overflow && next > 0 { send("count:\(next)") }
    }

    private func customControls(_ custom: FilterCustom) -> some SwiftUI.View {
      let past = Text("Past").font(.subheadline.weight(.semibold))
      let stepper = HStack(spacing: 0) {
        Button { changeCount(custom.count, by: -1) } label: {
          Image(systemName: "minus").frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Decrease count")
        .disabled((Int(custom.count) ?? 0) <= 1)
        TextField("Count", text: Binding(get: { custom.count }, set: { send("count:" + $0) }))
          .textFieldStyle(.plain)
          .multilineTextAlignment(.center)
          .monospacedDigit()
          .frame(minWidth: 44, idealWidth: 44, maxWidth: 64, minHeight: 44)
          .focused($editing, equals: .count)
          .accessibilityIdentifier("journal-filter-count")
          #if os(iOS)
          .keyboardType(.numberPad)
          #endif
        Button { changeCount(custom.count, by: 1) } label: {
          Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Increase count")
      }
      .buttonStyle(.plain)
      .background(surface, in: .rect(cornerRadius: 9))
      let units = Menu {
        ForEach(custom.units) { unit in
          Button { send(unit.id) } label: {
            if unit.selected { Label(unit.label, systemImage: "checkmark") }
            else { Text(unit.label) }
          }
          .accessibilityIdentifier("journal-filter-\(unit.id)")
        }
      } label: {
        Text(custom.units.first(where: \.selected)?.label ?? "Units")
          .font(.subheadline.weight(.semibold))
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
      .tint(filterBlue(scheme))
      .accessibilityIdentifier("journal-filter-unit")
      return ViewThatFits(in: .horizontal) {
        if !typeSize.isAccessibilitySize {
          HStack(spacing: 8) {
            past.fixedSize()
            Spacer(minLength: 0)
            stepper
            Spacer(minLength: 0)
            units.fixedSize()
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          past
          stepper
          units
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 13))
    }

    private var datePreview: String? {
      guard let range = properties.dateRange, range.count == 2 else { return nil }
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = .gmt
      let dates = range.compactMap { day in
        calendar.date(from: DateComponents(year: day / 10000, month: day / 100 % 100, day: day % 100))
      }
      guard dates.count == 2 else { return nil }
      let formatter = DateIntervalFormatter()
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      formatter.dateTemplate = range[0] / 10000 == range[1] / 10000 ? "MMMd" : "yMMMd"
      return formatter.string(from: dates[0], to: dates[1]) + " · Includes today"
    }

    private func savedFilterManagement(_ names: [String]) -> some SwiftUI.View {
      DisclosureGroup("Manage saved filters", isExpanded: $managesSavedFilters) {
        ForEach(names.map(JournalSavedFilterName.init)) { saved in
          let name = saved.name
          HStack {
            Text(verbatim: name)
            Spacer()
            Button(role: .destructive) {
              editing = nil
              deletionName = name
              confirmingDeletion = true
            } label: {
              Image(systemName: "trash")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Delete \(name)")
          }
        }
      }
      .font(.subheadline)
      .tint(filterBlue(scheme))
      .alert("Delete saved filter?", isPresented: $confirmingDeletion, presenting: deletionName) { name in
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) { send("delete:" + name) }
      } message: { name in
        Text("Delete ‘\(name)’ from saved filters?")
      }
    }

    private var fields: some SwiftUI.View {
      VStack(alignment: .leading, spacing: 6) {
        if let names = properties.filterNames, !names.isEmpty {
          savedFilterManagement(names)
          Divider().padding(.vertical, 4)
        }
        heading("TAG · MATCH ANY")
        FilterChipRows {
          ForEach(choices.tags) { chip($0) }
          FilterChip(label: showsTags ? "Hide tags" : "+ Tags", selected: false) { showsTags.toggle() }
            .accessibilityIdentifier("journal-filter-add-tags")
        }
        if showsTags {
          TextField("Search tags", text: Binding(get: { properties.text ?? "" }, set: { send("search:" + $0) }))
            .textFieldStyle(.roundedBorder)
            .focused($editing, equals: .tags)
            .accessibilityIdentifier("journal-filter-tag-input")
          if let message = properties.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
          FilterChipRows { ForEach(choices.results) { chip($0) } }
        }
        heading("STATUS · MATCH ANY")
        FilterChipRows { ForEach(choices.statuses) { chip($0) } }
        Text("Matches any selected tag or status.").font(.footnote).foregroundStyle(.secondary)
        Divider().padding(.vertical, 4)
        heading("RELATIVE TIME")
        FilterChipRows { ForEach(choices.times) { chip($0) } }
        if let custom = properties.custom {
          customControls(custom).fixedSize(horizontal: false, vertical: true)
            .id("filter-custom-controls")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footerButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some SwiftUI.View {
      Button(action: action) {
        Text(title).font(.headline)
          .foregroundStyle(primary ? Color.white : filterBlue(scheme))
          .frame(maxWidth: .infinity, minHeight: 46)
          .background(primary ? Color(red: 0.12, green: 0.31, blue: 0.63) : Color.primary.opacity(0.08), in: .capsule)
          .contentShape(.capsule)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(primary ? "journal-filter-apply" : "journal-filter-save")
    }

    private var scrollableFields: some SwiftUI.View {
      ScrollViewReader { scroll in
        ScrollView { fields }
          .scrollBounceBehavior(.basedOnSize)
          .scrollDismissesKeyboard(.interactively)
          .onChange(of: properties.custom != nil, initial: true) { _, isCustom in
            if isCustom { scroll.scrollTo("filter-custom-controls", anchor: .bottom) }
          }
      }
    }

    var body: some SwiftUI.View {
      VStack(spacing: 8) {
        #if !os(iOS)
        Capsule().fill(.secondary.opacity(0.32)).frame(width: 34, height: 4)
          .accessibilityHidden(true)
        #endif
        let heading = Text("Filters").font(.headline).accessibilityAddTraits(.isHeader)
        #if os(iOS)
        let title = heading
        #else
        let title = heading.accessibilityFocused(accessibilityFocus, equals: .heading)
        #endif
        #if os(iOS)
        ViewThatFits(in: .horizontal) {
          HStack {
            action("cancel", "Cancel")
            Spacer()
            title
            Spacer()
            action("reset", "Reset")
          }
          VStack(spacing: 0) {
            title
            HStack { action("cancel", "Cancel"); Spacer(); action("reset", "Reset") }
          }
        }
        scrollableFields
        #else
        if typeSize.isAccessibilitySize {
          VStack(spacing: 0) {
            title
            HStack { action("cancel", "Cancel"); Spacer(); action("reset", "Reset") }
          }
        } else {
          ZStack {
            title
            HStack { action("cancel", "Cancel"); Spacer(); action("reset", "Reset") }
          }
        }
        ViewThatFits(in: .vertical) {
          if !showsTags {
            fields.fixedSize(horizontal: false, vertical: true)
          }
          scrollableFields.frame(maxHeight: 330)
        }
        #endif
        VStack(spacing: 8) {
          if let datePreview {
            Text(datePreview).font(.footnote).foregroundStyle(.secondary)
              .accessibilityIdentifier("journal-filter-date-preview")
          } else if properties.custom != nil && properties.enabled != true {
            Text("Enter a positive whole number within the supported range.")
              .font(.footnote).foregroundStyle(.secondary)
          }
          if !naming, let error = properties.filterError {
            Text(error).font(.footnote).foregroundStyle(.red)
          }
          let apply = HStack(spacing: 12) {
            footerButton("Save", primary: false) {
              editing = nil
              filterName = ""
              send("name")
              naming = true
            }
            footerButton("Apply", primary: true) { send("apply") }
          }
          .disabled(properties.enabled != true)
          .opacity(properties.enabled == true ? 1 : 0.45)
          .sheet(isPresented: $naming) {
            NavigationStack {
              Form {
                TextField("Name", text: $filterName)
                  .accessibilityIdentifier("journal-filter-name")
                if let error = properties.filterError {
                  Text(error).foregroundStyle(.red)
                }
              }
              .navigationTitle("Save filter")
              .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                  Button("Cancel") { naming = false; send("name") }
                }
                ToolbarItem(placement: .confirmationAction) {
                  Button("Save") { send("save:" + filterName) }
                }
              }
            }
            .presentationDetents([.medium])
          }
          #if os(iOS)
          if editing == .count {
            HStack(spacing: 12) {
              Button { editing = nil } label: { actionLabel("Done").fixedSize() }
                .buttonStyle(.plain)
                .accessibilityIdentifier("journal-filter-count-done")
              apply
            }
          } else {
            apply
          }
          #else
          apply
          #endif
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
      }
      .padding(.horizontal, 16)
      .padding(.top, 9)
      .padding(.bottom, 15)
      .frame(maxWidth: 540)
      #if os(iOS)
      .frame(maxWidth: .infinity)
      #else
      .background(surface, in: .rect(cornerRadius: 24))
      .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.12)) }
      #endif
      .accessibilityElement(children: .contain)
      #if !os(iOS)
      .accessibilityAddTraits(.isModal)
      #endif
      .accessibilityIdentifier("journal-filter-panel")
      .accessibilityAction(.escape) { send("cancel") }
      #if !os(iOS)
      .padding(.bottom, 64)
      #endif
    }

  }

  /// Syntax and reference resolution belong to OCaml; this maps presentation data.
  #if os(iOS)
  private struct TimelineLeftPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let toggle: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
          if let scrollView = current as? UIScrollView {
            // The Timeline List may share its pan. A nested asset strip owns
            // touches that start inside it, even when its content fits.
            return scrollView is UICollectionView || scrollView is UITableView
          }
          view = current.superview
        }
        return true
      }

      func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: pan.view)
        return -velocity.x > abs(velocity.y) * 1.4
      }

      func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
      ) -> Bool {
        // Keep the native list pan available for vertical scrolling.
        guard let scrollView = other.view as? UIScrollView else { return false }
        return other === scrollView.panGestureRecognizer
      }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
      let pan = UIPanGestureRecognizer()
      pan.maximumNumberOfTouches = 1
      pan.delegate = context.coordinator
      pan.isEnabled = enabled
      return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
      recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
      guard recognizer.state == .ended, enabled else { return }
      let translation = recognizer.translation(in: recognizer.view)
      let distance = -translation.x
      guard distance > abs(translation.y) * 1.4 else { return }
      let speed = -recognizer.velocity(in: recognizer.view).x
      if distance >= 48 || (distance >= 24 && speed > 500) { toggle() }
    }
  }

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
    let context:LUIAppleExtensionViewContext
    let properties:Properties
    @State private var translation:CGFloat=0
    @State private var dragging=false
    @State private var settling=false
    @State private var committing=false
    @State private var source:String?
    @State private var target:String?
    @State private var graphName = JournalGraphNameFeedback()
    @Environment(\.journalContainerTopInset) private var containerTopInset
    @Environment(\.journalStartupContainerFrame) private var startupContainerFrame
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var handoff=JournalGraphHandoff()
    @StateObject private var coldMotion=JournalGraphColdMotion()
    @Environment(\.journalStartupClock) private var startupClock
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.journalGraphScrollOffsets) private var graphScrollOffsets
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A native containment boundary keeps each retained NavigationStack's
    /// UIKit accessibility tree and hit testing isolated without disabled tint.
    private struct Pane:UIViewControllerRepresentable {
      let context:LUIAppleExtensionViewContext
      let owner:String
      let node:Int
      let records:Bool
      let shown:Bool
      let interactive:Bool
      let coldMotion:JournalGraphColdMotion
      let coldNonce:UUID?
      let initialNonce:UUID?
      let initialReady:@MainActor @Sendable (String,UUID)->Void
      let loading:Bool
      private var presentationReady:(@MainActor @Sendable (String)->Void)? {
        guard coldNonce != nil || initialNonce != nil else{return nil}
        return {page in
          if let coldNonce {coldMotion.ready(page:page,nonce:coldNonce)}
          if let initialNonce {initialReady(page,initialNonce)}
        }
      }

      struct Style:Equatable {
        let scene:ScenePhase
        let scheme:ColorScheme
        let contrast:ColorSchemeContrast
        let scale:CGFloat
        let size:DynamicTypeSize
        let direction:LayoutDirection
        let reduceMotion:Bool
        let locale:Locale
        let timeZone:TimeZone
        let inset:CGFloat?
        let frame:CGRect?
        init(_ environment:EnvironmentValues) {
          scene=environment.scenePhase;scheme=environment.colorScheme
          contrast=environment.colorSchemeContrast;scale=environment.displayScale
          size=environment.dynamicTypeSize
          direction=environment.layoutDirection;reduceMotion=environment.accessibilityReduceMotion
          locale=environment.locale;timeZone=environment.timeZone
          inset=environment.journalContainerTopInset
          frame=environment.journalStartupContainerFrame
        }
        nonisolated static func ==(a:Self,b:Self)->Bool {
          a.scene==b.scene && a.scheme==b.scheme && a.contrast==b.contrast && a.scale==b.scale
            && a.size==b.size && a.direction==b.direction
            && a.reduceMotion==b.reduceMotion && a.locale==b.locale && a.timeZone==b.timeZone
            && a.inset==b.inset && a.frame==b.frame
        }
      }
      @MainActor final class LoadingGate {
        var token=UUID()
        var enabled=false
        var owner:String?
        var nonce:UUID?
        weak var motion:JournalGraphColdMotion?
        func ready(token:UUID,owner:String,nonce:UUID) {
          guard self.token==token,enabled,self.owner==owner,self.nonce==nonce else{return}
          motion?.ready(page:owner,nonce:nonce)
        }
      }
      final class Controller:UIViewController {
        let host:UIHostingController<AnyView>
        let loadingGate:LoadingGate
        var records=false
        var interactive=false
        var node = -1
        var style:Style?
        var coldNonce:UUID?
        var initialNonce:UUID?
        var loading=false
        var owner:String?
        weak var coldMotion:JournalGraphColdMotion?
        init(rootView:AnyView,loadingGate:LoadingGate) {
          self.loadingGate=loadingGate
          host=UIHostingController(rootView:rootView)
          super.init(nibName:nil,bundle:nil)
        }
        required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
        override func viewDidLoad() {
          super.viewDidLoad()
          view.backgroundColor = .clear
          view.isOpaque=false
          view.isAccessibilityElement=false
          addChild(host)
          host.view.backgroundColor = .clear
          host.view.isOpaque=false
          host.view.translatesAutoresizingMaskIntoConstraints=false
          view.addSubview(host.view)
          NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo:view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo:view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
          host.didMove(toParent:self)
        }
        func setRole(shown:Bool,interactive:Bool) {
          // The child is not the view managed by SwiftUI's representable, so
          // parent visibility updates cannot overwrite this UIKit boundary.
          host.view.isHidden = !shown
          view.accessibilityElements = interactive ? nil : []
          view.accessibilityElementsHidden = !interactive
          view.isUserInteractionEnabled=interactive
          host.view.accessibilityElementsHidden = !interactive
          host.view.isUserInteractionEnabled=interactive
        }
        func detach() {
          host.willMove(toParent:nil)
          host.view.removeFromSuperview()
          host.removeFromParent()
        }
      }
      private func content(_ environment:EnvironmentValues,gate:LoadingGate)->AnyView {
        let loadingToken=gate.token
        return AnyView(context.content(for:node)
          .environment(\.colorScheme,environment.colorScheme)
          .environment(\.dynamicTypeSize,environment.dynamicTypeSize)
          .environment(\.layoutDirection,environment.layoutDirection)
          .environment(\.locale,environment.locale)
          .environment(\.timeZone,environment.timeZone)
          .environment(\.displayScale,environment.displayScale)
          .environment(\.scenePhase,environment.scenePhase)
          .environment(\.journalContainerTopInset,environment.journalContainerTopInset)
          .environment(\.journalStartupContainerFrame,environment.journalStartupContainerFrame)
          .environment(\.journalStartupClock,environment.journalStartupClock)
          .environment(\.journalGraphScrollOffsets,environment.journalGraphScrollOffsets)
          .environment(\.journalGraphScrollScope,JournalGraphScrollScope(pageID:owner,records:records))
          .environment(\.journalGraphPresentationNonce,coldNonce ?? initialNonce)
          .environment(\.journalGraphPresentationReady,presentationReady)
          .accessibilityHidden(!interactive)
          .background {
            if loading,let coldNonce {
              JournalGraphLoadingLayout(nonce:loadingToken) {gate.ready(token:loadingToken,owner:owner,nonce:coldNonce)}
            }
          })
      }
      func makeUIViewController(context:Context)->Controller {
        let gate=LoadingGate();gate.enabled=loading;gate.owner=owner;gate.nonce=coldNonce;gate.motion=coldMotion
        let controller=Controller(rootView:content(context.environment,gate:gate),loadingGate:gate)
        controller.records=records;controller.interactive=interactive;controller.node=node;controller.style=Style(context.environment)
        controller.coldNonce=coldNonce;controller.initialNonce=initialNonce;controller.loading=loading;controller.owner=owner;controller.coldMotion=coldMotion
        controller.setRole(shown:shown,interactive:interactive)
        coldMotion.register(owner,view:controller.view)
        return controller
      }
      func updateUIViewController(_ controller:Controller,context:Context) {
        let style=Style(context.environment)
        if controller.node != node || controller.records != records || controller.interactive != interactive || controller.style != style || controller.coldNonce != coldNonce || controller.initialNonce != initialNonce || controller.loading != loading {
          controller.loadingGate.token=UUID();controller.loadingGate.enabled=loading
          controller.loadingGate.owner=owner;controller.loadingGate.nonce=coldNonce
          controller.node=node;controller.records=records;controller.interactive=interactive;controller.style=style;controller.coldNonce=coldNonce;controller.initialNonce=initialNonce;controller.loading=loading
          withTransaction(Transaction(animation:nil)) {controller.host.rootView=content(context.environment,gate:controller.loadingGate)}
        }
        controller.setRole(shown:shown,interactive:interactive)
      }
      static func dismantleUIViewController(_ controller:Controller,coordinator:()) {
        controller.loadingGate.enabled=false;controller.loadingGate.token=UUID();controller.loadingGate.nonce=nil
        controller.view.accessibilityElementsHidden=true
        controller.view.isUserInteractionEnabled=false
        if let owner=controller.owner {controller.coldMotion?.unregister(owner,view:controller.view)}
        controller.detach()
      }
    }
    private var slots:[(owner:String,node:Int)] {
      let owners=properties.slotOwners ?? []
      return owners.enumerated().compactMap { index,owner in
        index<context.childIDs.count ? (owner,context.childIDs[index]) : nil
      }
    }
    private var initialCover:Bool {
      startupClock?.phase != .finished && startupClock?.layout.covers(page:properties.pageID,visible:properties.visible==true,
        loading:(properties.loadingPageIDs ?? []).contains(properties.pageID ?? ""),
        cold:coldMotion.ticket != nil) == true
    }
    private func emit(_ action:String,source:String?=nil,target:String?=nil) {
      guard let source=source ?? properties.pageID else {return}
      var value=["action":action,"source":source]
      if let target=target ?? self.target ?? properties.targetPageID {value["target"]=target}
      guard let data=try? JSONEncoder().encode(value) else {return}
      JournalExtensions.emit(context:context,payload:data)
    }
    private func reset(notify:Bool,preserveCold:Bool=false,preserveName:Bool=false) {
      if notify,source==properties.pageID {emit("cancel",source:source,target:target)}
      handoff.cancel()
      if !preserveCold {coldMotion.cancel()}
      withTransaction(Transaction(animation:nil)) {
        translation=0;dragging=false;settling=false;committing=false;source=nil;target=nil
      }
      if !preserveName {
        withAnimation(reduceMotion ? nil : .easeOut(duration:0.16)) { graphName.cancel() }
      }
    }
    private func acknowledge() {
      if properties.visible == true, properties.pageID != nil, scenePhase == .active,
        startupClock?.phase == .pickerRequested {
        startupClock?.deliverPicker { emit("choose-graph") }
        return
      }
      if !initialCover, scenePhase == .active, properties.visible==true,coldMotion.ticket?.target != properties.pageID,
        slots.contains(where:{$0.owner==properties.pageID}) {
        if !(properties.loadingPageIDs ?? []).contains(properties.pageID ?? ""), !settling, !committing {
          startupClock?.finish()
        }
        emit("presented")
      }
    }
    private func handle(_ pan:UIPanGestureRecognizer,width:CGFloat) {
      switch pan.state {
      case .began:
        guard properties.enabled==true,!settling,coldMotion.ticket==nil,
          let from=properties.pageID,let to=properties.targetPageID,
          from != to,(properties.residentPageIDs ?? []).contains(to) else {return}
        _=handoff.startGesture();source=from;target=to;dragging=true
        withAnimation(reduceMotion ? nil : .easeOut(duration:0.12)) {
          graphName.show(source:from,target:to,name:properties.targetGraphName)
        }
        let cold = !slots.contains(where:{$0.owner==to}) && coldMotion.begin(source:from,target:to)
        if !cold {emit("prepare",source:from,target:to)}
        translation=min(width,max(0,pan.translation(in:pan.view).x))
        coldMotion.move(translation)
      case .changed where dragging:
        translation=min(width,max(0,pan.translation(in:pan.view).x))
        coldMotion.move(translation)
      case .ended where dragging:
        guard properties.enabled==true,let gesture=handoff.currentGesture,source==properties.pageID,
          target==properties.targetPageID else {reset(notify:true);return}
        dragging=false
        let distance=pan.translation(in:pan.view).x,velocity=pan.velocity(in:pan.view).x
        let commit=distance>width*0.3 || (distance>30 && velocity>650)
        settling=true;committing=commit
        if commit,let source,let target { graphName.commit(source:source,target:target) }
        if coldMotion.ticket != nil {
          if commit {
            withTransaction(Transaction(animation:nil)){translation=width}
            coldMotion.commit(width:width,reduced:reduceMotion,
              prepare:{emit("prepare",source:source,target:target)},complete:{
                guard properties.enabled==true,handoff.acceptsGesture(gesture),let source,let target,
                  source==properties.pageID,target==properties.targetPageID else{return}
                _=handoff.begin(source:source,target:target)
                emit("commit",source:source,target:target)
              },cancelled:{reset(notify:true)})
          } else {
            withTransaction(Transaction(animation:nil)){translation=0}
            coldMotion.returnToSource(reduced:reduceMotion){reset(notify:true)}
          }
          return
        }
        withAnimation(reduceMotion ? .linear(duration:0.01) : .smooth(duration:0.24),completionCriteria:.removed) {
          translation=commit ? width : 0
        } completion: {
          guard properties.enabled==true,handoff.acceptsGesture(gesture),let source,let target,
            source==properties.pageID,target==properties.targetPageID else {return}
          if commit {
            _=handoff.begin(source:source,target:target)
            emit("commit",source:source,target:target)
          } else {reset(notify:true)}
        }
      case .cancelled,.failed:reset(notify:true)
      default:break
      }
    }
    private var graphCanvas: some SwiftUI.View {
      GeometryReader { bounds in
        ZStack(alignment:.topLeading) {
          ForEach(slots,id:\.owner) { slot in
            let current=slot.owner==properties.pageID
            let ownsMotion=source==properties.pageID
            let incoming=ownsMotion && slot.owner==target && (dragging || settling)
            let shown=properties.visible==true && (current || incoming)
            let covered=coldMotion.ticket?.target==slot.owner
            let coldNonce=covered ? coldMotion.layoutNonce : nil
            Pane(context:context,owner:slot.owner,node:slot.node,
              records:current && properties.visible==true && !(settling && committing) && !covered,
              shown:shown,
              interactive:current && properties.visible==true && !(settling && committing) && !covered && !initialCover,
              coldMotion:coldMotion,coldNonce:coldNonce,
              initialNonce:(current && initialCover) || covered ? startupClock?.layout.nonce : nil,
              initialReady:{page,nonce in startupClock?.ready(page:page,nonce:nonce)},loading:(properties.loadingPageIDs ?? []).contains(slot.owner))
              .frame(width:bounds.size.width,height:bounds.size.height)
              .offset(x:current ? (ownsMotion ? translation : 0) : incoming ? translation-bounds.size.width : -bounds.size.width)
              .opacity(shown ? 1 : 0)
              .zIndex(current ? 1 : incoming ? 0 : -1)
          }
        }
        .background(Color(uiColor:.systemBackground))
        .clipped()
        .overlay{JournalGraphColdSurface(owner:coldMotion).allowsHitTesting(false).accessibilityHidden(true)}
        .overlay {
          if initialCover {
            ZStack(alignment:.topLeading) {
              Color(uiColor:.systemBackground)
              initialLoadingSurface()
                .frame(width:bounds.size.width,
                  height:startupContainerFrame?.height ?? bounds.size.height)
                .offset(y:startupContainerFrame.map {
                  $0.minY - bounds.frame(in:.global).minY
                } ?? 0)
            }
            .accessibilityIdentifier("journal-initial-layout-cover")
          }
        }
        .overlay(alignment:.top) {
          if let name = graphName.presentation?.name {
            nameCapsule(name)
              // Reserve the full 44pt menu + progress + spacing on either side.
              .frame(maxWidth:min(240,max(0,bounds.size.width-192)))
              .padding(.top,containerTopInset+4)
              .transition(.opacity)
              .allowsHitTesting(false)
          }
        }
        .gesture(RightGraphPan(enabled:properties.enabled==true && !settling && coldMotion.ticket==nil && !initialCover) {handle($0,width:bounds.size.width)})
        .onChange(of:bounds.size) { _,_ in reset(notify:true) }
      }
    }
    private var residentCanvas: some SwiftUI.View {
      graphCanvas
      // Each native hosting root owns the same window-sized canvas as the
      // original app root; its own UIKit safe area is applied exactly once.
      .ignoresSafeArea(.container)
      .onAppear {graphScrollOffsets?.retain(properties.residentPageIDs ?? []);acknowledge()}
      .onChange(of:initialCover) { _,covered in if !covered {acknowledge()} }
      .onChange(of:properties.slotOwners) { _,_ in acknowledge() }
      .onChange(of:coldMotion.ticket?.id) { _,id in if id==nil {acknowledge()} }
      .onChange(of:properties.residentPageIDs) { _,ids in
        graphName.retain(ids ?? [])
        coldMotion.retain(ids ?? [])
        graphScrollOffsets?.retain(ids ?? [])
        if let source,let target,!(ids ?? []).contains(source) || !(ids ?? []).contains(target) {reset(notify:false)}
      }
      .onChange(of:properties.pageID) { previous,page in
        // Initial nil -> owner is admission. Replacing that owner interrupts
        // startup; a retained Favorites/Detail route need not own a List handshake.
        if previous != nil {startupClock?.invalidateLayout()}
        graphName.focusChanged(page)
        let keepName = graphName.presentation?.phase == .confirmed
        let keepCold=committing && coldMotion.ticket?.target==page
        if let request=handoff.request,page==request.target {
          _=handoff.finish(request.id,page:request.target,current:page)
        } else {handoff.focusChanged(page)}
        reset(notify:false,preserveCold:keepCold,preserveName:keepName)
        if keepCold {coldMotion.focused(page)}
        acknowledge()
      }
    }
    var body: some SwiftUI.View {
      residentCanvas
      .onChange(of:properties.targetGraphName) { _,name in
        graphName.updateName(target:properties.targetPageID,name:name)
      }
      .onChange(of:properties.targetPageID) { _,next in
        if source==properties.pageID,let target,target != next {reset(notify:true)}
      }
      .onChange(of:properties.enabled) { _,enabled in
        if enabled != true && handoff.request == nil && coldMotion.ticket?.target != properties.pageID {
          reset(notify:true,preserveName:graphName.presentation?.phase == .confirmed)
        }
      }
      .onChange(of:properties.targetID) { _,prepared in
        if prepared == nil && source==properties.pageID && (dragging || settling) {reset(notify:false)}
      }
      .onChange(of:properties.visible) { _,visible in
        if visible != true {startupClock?.invalidateLayout();reset(notify:true)} else {acknowledge()}
      }
      .onChange(of:scenePhase) { _,phase in if phase != .active {startupClock?.invalidateLayout();reset(notify:true)} else {acknowledge()} }
      .onDisappear {startupClock?.invalidateLayout();reset(notify:false)}
      .task(id:graphName.presentation?.id) {
        guard let name = graphName.presentation,name.phase == .confirmed else { return }
        if UIAccessibility.isVoiceOverRunning {
          UIAccessibility.post(notification:.announcement,argument:name.name)
        }
        do { try await Task.sleep(for:.milliseconds(1100)) } catch { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration:0.2)) { graphName.dismiss(name.id) }
      }
    }

    private func initialLoadingSurface() -> JournalStartupLoadingSurface {
      let choose = SwiftUI.Button("Choose other graph") {
        startupClock?.requestPicker()
        startupClock?.deliverPicker { emit("choose-graph") }
      }
        .buttonStyle(.bordered).accessibilityIdentifier("graph-picker-choose")
      return JournalStartupLoadingSurface(loading:false,initial:true,active:scenePhase == .active,
        action:AnyView(choose))
    }

    private func nameLabel(_ name:String,font:Font) -> some SwiftUI.View {
      HStack(spacing:6) {
        Image(systemName:"square.stack").font(.system(size:12)).accessibilityHidden(true)
        Text(name).font(font).lineLimit(1).truncationMode(.tail)
          .accessibilityIdentifier("graph-switch-name")
      }
      .padding(.horizontal,12).padding(.vertical,5)
      .fixedSize(horizontal:false,vertical:true)
    }

    @ViewBuilder private func nameCapsule(_ name:String) -> some SwiftUI.View {
      // This transient HUD shares the fixed gap above the date. Native fitting
      // preserves that slot at accessibility sizes; VoiceOver retains the full name.
      let label = ViewThatFits(in:.vertical) {
        nameLabel(name,font:.subheadline.weight(.semibold))
        nameLabel(name,font:.system(size:17,weight:.semibold))
      }.frame(height:32)
      if reduceTransparency {
        label.background(Color(uiColor:.secondarySystemBackground),in:Capsule())
      } else {
        label.glassEffect(.regular,in:.capsule)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var controlsSize = CGSize.zero

    private var usesSeparateControlsRow: Bool {
      properties.mode == .page && properties.title == nil && dynamicTypeSize.isAccessibilitySize
    }

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
          .environment(\.journalControlsSize, usesSeparateControlsRow ? .zero : controlsSize)
          #if os(iOS)
          // Retaining the native bar host across Detail returns avoids the
          // reproduced soft scroll-edge flash during the pop transition.
          .toolbar(.visible, for: .navigationBar)
          .toolbarBackground(.hidden, for: .navigationBar)
          #endif
          .overlay(alignment: .topTrailing) {
            if properties.title == nil && properties.message == nil && !usesSeparateControlsRow {
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
            } else if properties.message != nil ||
                        (usesSeparateControlsRow && (properties.controls == true || properties.connecting == true)) {
              HStack {
                Spacer(minLength: 0)
                controls
              }
              .padding(.horizontal, 16)
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
      let date = Text(verbatim: title).font(.title2.weight(.semibold))
      HStack(spacing: 0) {
        Group {
          if let relativeLabel {
            let relative = Text(verbatim: relativeLabel).font(.subheadline).foregroundStyle(Color.secondary)
            ViewThatFits(in: .horizontal) {
              Text("\(date) \(relative)").fixedSize(horizontal: true, vertical: false)
              VStack(alignment: .leading, spacing: 2) {
                date.fixedSize(horizontal: false, vertical: true)
                relative.fixedSize(horizontal: false, vertical: true)
              }
            }
          } else {
            date.fixedSize(horizontal: false, vertical: true)
          }
        }
        .foregroundStyle(.primary)
        .monospacedDigit()
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        Spacer(minLength: controlsSize.width > 0 ? controlsSize.width + 16 : 0)
      }
    }
  }

  #if os(iOS)
  private struct BottomBar: SwiftUI.View {
    let favorites: Bool
    let captureEnabled: Bool
    let send: (String) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.journalContainerBottomInset) private var containerBottomInset
    @ScaledMetric(relativeTo: .body) private var captureIcon = 28.0
    private let height: CGFloat = 60.7
    private let controlScale: CGFloat = 0.9
    private let captureLift: CGFloat = 22

    private struct NativeTabs: UIViewControllerRepresentable {
      enum Destination: Int, CaseIterable {
        case journals, favorites

        var action: String { self == .journals ? "journals" : "favorites" }
        var label: String { self == .journals ? "Journals" : "Favorites" }
        var symbol: String { self == .journals ? "calendar" : "star" }
      }

      let selection: Destination
      let send: (String) -> Void

      func makeCoordinator() -> Coordinator { Coordinator(tabs: self) }

      func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        controller.viewControllers = Destination.allCases.map { destination in
          let child = UIViewController()
          child.view.backgroundColor = .clear
          child.view.isOpaque = false
          child.tabBarItem = UITabBarItem(title: destination.label,
            image: UIImage(systemName: destination.symbol), selectedImage: nil)
          child.tabBarItem.accessibilityLabel = destination.label
          return child
        }
        controller.tabBar.tintColor = .label
        controller.selectedIndex = selection.rawValue
        controller.delegate = context.coordinator
        return controller
      }

      func updateUIViewController(_ controller: UITabBarController, context: Context) {
        context.coordinator.tabs = self
        if controller.selectedIndex != selection.rawValue {
          controller.selectedIndex = selection.rawValue
        }
      }

      final class Coordinator: NSObject, UITabBarControllerDelegate {
        var tabs: NativeTabs

        init(tabs: NativeTabs) { self.tabs = tabs }

        func tabBarController(_ controller: UITabBarController, didSelect viewController: UIViewController) {
          guard let destination = Destination(rawValue: controller.selectedIndex),
            destination != tabs.selection else { return }
          tabs.send(destination.action)
        }
      }
    }

    var body: some SwiftUI.View {
      HStack(spacing: 0) {
        NativeTabs(selection: favorites ? .favorites : .journals, send: send)
          .frame(width: 190, height: height)
          .scaleEffect(controlScale, anchor: UnitPoint(x: 0, y: (height - captureLift) / height))
        Spacer(minLength: 0)
        if !favorites {
          Button { send("capture") } label: {
            Image(systemName: "square.and.pencil")
              .font(.system(size: min(captureIcon, 42)))
              .frame(width: height, height: height)
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .background {
            if reduceTransparency { Circle().fill(Color(uiColor: .secondarySystemBackground)) }
          }
          .glassEffect(reduceTransparency ? .identity : .regular.interactive(), in: Circle())
          .disabled(!captureEnabled)
          .accessibilityLabel("Capture")
          .accessibilityIdentifier("journal-capture-open")
          .scaleEffect(controlScale, anchor: .bottomTrailing)
          .offset(y: -captureLift)
        }
      }
      .foregroundStyle(Color.primary)
      .offset(y: min(29, containerBottomInset - 3))
    }
  }
  #endif

  #if os(iOS)
  private struct FilterSheetPresenter: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    let properties: Properties?
    @State private var active: Presentation?
    @State private var isPresented = false
    @State private var cancelledEpoch: Int?

    private struct PresentationChange: Equatable {
      let requestedEpoch: Int?
      let activeEpoch: Int?
    }

    private struct Presentation {
      let properties: Properties
      let choices: FilterChoices
      let epoch: Int
    }

    private var requested: Presentation? {
      guard let properties, let choices = properties.choices, let epoch = properties.sheetEpoch
      else { return nil }
      return Presentation(properties: properties, choices: choices, epoch: epoch)
    }

    private func reconcilePresentation() {
      let requested = self.requested
      if let active {
        if requested?.epoch != active.epoch { isPresented = false }
      } else if let requested, requested.epoch != cancelledEpoch {
        active = requested
        isPresented = true
      }
    }

    private func send(_ action: String, epoch: Int) {
      guard isPresented, active?.epoch == epoch, cancelledEpoch != epoch,
        let requested, requested.epoch == epoch else { return }
      if action == "apply", requested.properties.enabled != true { return }
      if JournalExtensions.emit(context: context, id: epoch,
                                payload: Data(action.utf8)), action == "cancel" {
        cancelledEpoch = epoch
        isPresented = false
      }
    }

    var body: some SwiftUI.View {
      let epoch = active?.epoch
      Color.clear.frame(width: 0, height: 0)
        .task(id: PresentationChange(requestedEpoch: requested?.epoch, activeEpoch: epoch)) {
          guard !Task.isCancelled else { return }
          reconcilePresentation()
        }
        .sheet(isPresented: Binding(
          get: { isPresented },
          set: { if !$0, let epoch { send("cancel", epoch: epoch) } }
        ), onDismiss: {
          active = nil
        }) {
          if let active {
            let presentation = requested?.epoch == active.epoch ? requested ?? active : active
            FilterPanel(properties: presentation.properties, choices: presentation.choices,
                        send: { send($0, epoch: presentation.epoch) })
              .padding(.top, 16)
              .presentationDetents([.large])
              .presentationDragIndicator(.visible)
              .presentationBackgroundInteraction(.disabled)
          }
        }
    }
  }
  #endif

  struct View: SwiftUI.View {
    let context: LUIAppleExtensionViewContext
    @Environment(\.journalTimelineDetails) private var timelineDetails
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsTimelineDetails = false
    #if os(iOS)
    @Environment(\.journalStartupClock) private var startupClock
    #endif
    @Environment(\.journalStartupContainerFrame) private var startupContainerFrame
    #if !os(iOS)
    @Environment(\.journalFilterAccessibilityFocus) private var filterAccessibilityFocus
    @AccessibilityFocusState private var filterFocus: JournalFilterAccessibilityTarget?
    @State private var presentedFilter = false
    #endif

    private var properties: Properties? {
      JournalExtensions.decode(Properties.self, context: context)
    }

    private var timelineModeAnimation: Animation? {
      reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    private func child(_ index: Int) -> AnyView {
      guard context.childIDs.count > index else { return AnyView(EmptyView()) }
      return context.content(for: context.childIDs[index])
    }

    var body: some SwiftUI.View {
      let properties = self.properties
      switch properties?.mode {
      case .graphPages:
        if let properties {
          #if os(iOS)
          GraphPages(context:context,properties:properties)
          #else
          ZStack {
            ForEach(Array((properties.slotOwners ?? []).enumerated()),id:\.element) { index,owner in
              child(index)
                .environment(\.journalGraphScrollScope,JournalGraphScrollScope(pageID:owner,
                  records:owner==properties.pageID && properties.visible==true))
                .opacity(owner==properties.pageID && properties.visible==true ? 1 : 0)
                .allowsHitTesting(owner==properties.pageID && properties.visible==true)
                .accessibilityHidden(owner != properties.pageID || properties.visible != true)
            }
          }
          #endif
        }
      case .timelineHost:
        if context.childIDs.count == 1 {
          child(0).environment(\.journalTimelineDetails, $showsTimelineDetails)
        }
      case .timelineInteraction:
        if let details = timelineDetails, context.childIDs.count == 1 {
          let enabled = context.isUserInteractionEnabled
          child(0)
            #if os(iOS)
            .gesture(TimelineLeftPan(enabled: enabled) { details.wrappedValue.toggle() })
            #endif
            .accessibilityActions {
              if enabled {
                Button(details.wrappedValue ? "Hide block metadata" : "Show block metadata") {
                  details.wrappedValue.toggle()
                }
              }
            }
        } else {
          child(0)
        }
      case .timelineRow:
        if let details = timelineDetails, let time = properties?.text, context.childIDs.count == 1 {
          let detailed = details.wrappedValue
          TimelineRowLayout(detailProgress: detailed ? 1 : 0) {
            child(0)
            TimelineMetadata(time: time, creator: properties?.creator, tags: properties?.tags ?? [])
              // Reveal the portion of the rail that the body has made room for.
              .mask {
                Rectangle().scaleEffect(x: detailed ? 1 : 0, y: 1, anchor: .trailing)
              }
              .opacity(detailed ? 1 : 0)
              .accessibilityHidden(!detailed)
              .allowsHitTesting(false)
          }
          .animation(timelineModeAnimation, value: detailed)
        } else {
          child(0)
        }
      case .filterOverlay:
        #if os(iOS)
        child(0).background {
          FilterSheetPresenter(context: context, properties: properties)
        }
        #else
        let isPresented = properties?.choices != nil
        child(0)
          .environment(\.journalFilterAccessibilityFocus, $filterFocus)
          .accessibilityHidden(isPresented)
          .allowsHitTesting(!isPresented)
          .overlay(alignment: .bottom) {
            if let properties, let choices = properties.choices, let epoch = properties.sheetEpoch {
              ZStack(alignment: .bottom) {
                Color.clear.contentShape(Rectangle())
                  .onTapGesture { JournalExtensions.emit(context: context, id: epoch, payload: Data("cancel".utf8)) }
                  .accessibilityHidden(true)
                FilterPanel(properties: properties, choices: choices, send: { action in
                  JournalExtensions.emit(context: context, id: epoch,
                                         payload: Data(action.utf8))
                }, accessibilityFocus: $filterFocus)
                .padding(.horizontal, 4)
                .padding(.top, 8)
              }
            }
          }
          .task(id: isPresented) {
            guard isPresented || presentedFilter else { return }
            if isPresented { presentedFilter = true }
            await Task.yield()
            guard !Task.isCancelled else { return }
            presentedFilter = isPresented
            filterFocus = isPresented ? .heading : .trigger
          }
        #endif
      case .filterTrigger:
        if let properties {
          let count = properties.level ?? 0
          let trigger = FilterTriggerButton(count: count, names: properties.filterNames ?? [],
            activeName: properties.filterActiveName) { action in
            guard let owner = properties.filterOwner else { return }
            JournalExtensions.emit(context: context, id: owner, payload: Data(action.utf8))
          }
          .disabled(properties.enabled != true)
          #if os(iOS)
          trigger
          #else
          if let filterAccessibilityFocus {
            trigger.accessibilityFocused(filterAccessibilityFocus, equals: .trigger)
          } else {
            trigger
          }
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
            #if os(iOS)
            .onAppear {
              if startupClock?.phase == .pickerRequested { startupClock?.finish() }
            }
            #endif
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
          #if os(iOS)
          .onChange(of: properties.canChoose == true && properties.active == true && context.isUserInteractionEnabled && startupClock?.phase == .pickerRequested, initial: true) { _, eligible in
            if eligible { startupClock?.deliverManagerPicker {
              JournalExtensions.emit(context: context, payload: Data("choose-graph".utf8))
            } }
          }
          #endif
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
      case .bottomBar:
        #if os(iOS)
        if let favorites = properties?.active, let captureEnabled = properties?.controls {
          BottomBar(favorites: favorites, captureEnabled: captureEnabled) { action in
            JournalExtensions.emit(context: context, payload: Data(action.utf8))
          }
        }
        #endif
      case .capturePresentation:
        #if os(iOS)
        JournalCapturePresentation(content: child(0), interactive: context.isUserInteractionEnabled)
        #else
        child(0)
        #endif
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
          #if os(iOS)
          .listSectionSpacing(16)
          #endif
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

private struct JournalContainerBottomInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
  var journalContainerBottomInset: CGFloat {
    get { self[JournalContainerBottomInsetKey.self] }
    set { self[JournalContainerBottomInsetKey.self] = newValue }
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
