import BonsaiSwiftUI
import SwiftUI

/// Native chrome layout only. List sections own all date scrolling and pinning.
@MainActor enum JournalChrome {
  private enum Mode: String, Decodable { case feedback, journal, header }

  private struct Properties: Decodable {
    let mode: Mode
    let top: Bool?
    let visible: Bool?
    let title: String?
    let connecting: Bool?
    let account: Bool?
    let error: Bool?
  }

  fileprivate struct ControlsSizeKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
  }

  private struct FloatingChrome: View {
    let content: AnyView
    let account: AnyView
    let error: AnyView
    let progress: AnyView
    let properties: Properties
    @State private var controlsSize = CGSize.zero

    var body: some View {
      GeometryReader { bounds in
        content.frame(width: bounds.size.width, height: bounds.size.height)
          .scrollContentBackground(.hidden)
          #if os(iOS)
          .environment(\.journalControlsSize, controlsSize)
          .toolbar(.hidden, for: .navigationBar)
          .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
              if properties.connecting! { progress.controlSize(.small).fixedSize() }
              if properties.error! { error.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()) }
              if properties.account! { account.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle()) }
            }
            .labelStyle(.iconOnly)
            .controlSize(.regular)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { controlsSize = $0 }
            .padding(.trailing, 16)
          }
          #else
          .toolbar {
            if properties.connecting! {
              ToolbarItem(placement: .primaryAction) { progress }
            }
          }
          #endif
      }
    }
  }

  private struct SectionDate: View {
    let title: String
    @Environment(\.journalControlsSize) private var controlsSize

    var body: some View {
      HStack(spacing: 0) {
        Text(title)
          .font(.title2.weight(.semibold))
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

  static func register(in registry: inout BonsaiNativeViews) throws {
    try registry.register(kind: 2103, version: 2, capabilities: [.stateful, .semantics],
      decode: { try JSONDecoder().decode(Properties.self, from: $0) },
      validateChildren: { properties, count in
        switch properties.mode {
        case .feedback:
          guard count == 3, properties.top != nil, properties.visible != nil else {
            throw BonsaiNativeViewError.invalidRegistration
          }
        case .journal:
          guard count == 4, properties.connecting != nil, properties.account != nil,
            properties.error != nil else { throw BonsaiNativeViewError.invalidRegistration }
        case .header:
          guard count == 0, properties.title != nil else {
            throw BonsaiNativeViewError.invalidRegistration
          }
        }
      },
      encodeEvent: { (event: Never) -> BonsaiNativeEvent in switch event {} },
      makeResource: { () }, dispose: { _ in },
      content: { context in
        switch context.properties.mode {
        case .feedback:
          GeometryReader { bounds in
            context.children[0].frame(width: bounds.size.width, height: bounds.size.height)
          }
          .safeAreaInset(edge: context.properties.top! ? .top : .bottom, spacing: 0) {
            if context.properties.visible! {
              ViewThatFits(in: .horizontal) {
                context.children[1]
                context.children[2]
              }
              .frame(maxWidth: .infinity)
              .background(.bar)
            }
          }
        case .journal:
          FloatingChrome(content: AnyView(context.children[0]), account: AnyView(context.children[1]),
            error: AnyView(context.children[2]), progress: AnyView(context.children[3]), properties: context.properties)
        case .header:
          SectionDate(title: context.properties.title!)
        }
      })
  }
}

private extension EnvironmentValues {
  var journalControlsSize: CGSize {
    get { self[JournalChrome.ControlsSizeKey.self] }
    set { self[JournalChrome.ControlsSizeKey.self] = newValue }
  }
}
