import LUIAppleBackend
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

  private struct FloatingChrome: SwiftUI.View {
    let content: AnyView
    let account: AnyView
    let error: AnyView
    let progress: AnyView
    let properties: Properties
    @State private var controlsSize = CGSize.zero

    var body: some SwiftUI.View {
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

  private struct SectionDate: SwiftUI.View {
    let title: String
    @Environment(\.journalControlsSize) private var controlsSize

    var body: some SwiftUI.View {
      HStack(spacing: 0) {
        Text(title)
          .font(.title2.weight(.semibold))
          .foregroundStyle(Color(.label))
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

    private var properties: Properties? {
      JournalExtensions.decode(Properties.self, context: context)
    }

    private func child(_ index: Int) -> AnyView {
      guard context.childIDs.count > index else { return AnyView(EmptyView()) }
      return context.content(for: context.childIDs[index])
    }

    var body: some SwiftUI.View {
      switch properties?.mode {
      case .feedback:
        if let properties, context.childIDs.count == 3,
          properties.top != nil, properties.visible != nil {
          GeometryReader { bounds in
            child(0).frame(width: bounds.size.width, height: bounds.size.height)
          }
          .safeAreaInset(edge: properties.top! ? .top : .bottom, spacing: 0) {
            if properties.visible! {
              ViewThatFits(in: .horizontal) {
                child(1)
                child(2)
              }
              .frame(maxWidth: .infinity)
              .background(.bar)
            }
          }
        }
      case .journal:
        if let properties, context.childIDs.count == 4,
          properties.connecting != nil, properties.account != nil,
          properties.error != nil {
          FloatingChrome(content: child(0), account: child(1),
            error: child(2), progress: child(3), properties: properties)
        }
      case .header:
        if let properties, context.childIDs.isEmpty, let title = properties.title {
          SectionDate(title: title)
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
