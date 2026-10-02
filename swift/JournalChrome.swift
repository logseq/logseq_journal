import LUIAppleBackend
import SwiftUI

/// Native chrome layout only. List sections own all date scrolling and pinning.
@MainActor enum JournalChrome {
  private enum Mode: String, Decodable {
    case feedback, page, header, detail
    case bottomControls = "bottom-controls"
  }

  private struct Properties: Decodable {
    let mode: Mode
    let top: Bool?
    let visible: Bool?
    let title: String?
    let connecting: Bool?
    let controls: Bool?
  }

  fileprivate struct ControlsSizeKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
  }

  private struct FloatingChrome: SwiftUI.View {
    let content: AnyView
    let cluster: AnyView
    let progress: AnyView
    let properties: Properties
    @State private var controlsSize = CGSize.zero

    var body: some SwiftUI.View {
      GeometryReader { bounds in
        content.frame(width: bounds.size.width, height: bounds.size.height)
          .scrollContentBackground(.hidden)
          #if os(iOS)
          .scrollEdgeEffectHidden(true, for: .bottom)
          #endif
          .environment(\.journalControlsSize, controlsSize)
          #if os(iOS)
          .toolbar(.hidden, for: .navigationBar)
          #endif
          .overlay(alignment: .topTrailing) {
            if properties.title == nil {
              controls.padding(.trailing, 16)
            }
          }
          .safeAreaInset(edge: .top, spacing: 0) {
            if let title = properties.title {
              ZStack {
                Text(title)
                  .font(.headline)
                  .accessibilityAddTraits(.isHeader)
                  .accessibilityIdentifier("favorites-header-title")
                HStack {
                  Spacer()
                  controls
                }
              }
              .frame(minHeight: 44)
              .padding(.horizontal, 16)
            }
          }
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
    @Environment(\.journalControlsSize) private var controlsSize

    var body: some SwiftUI.View {
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
      case .page:
        if let properties, context.childIDs.count == 3,
          properties.connecting != nil, properties.controls != nil {
          FloatingChrome(content: child(0), cluster: child(1),
            progress: child(2), properties: properties)
        }
      case .header:
        if let properties, context.childIDs.isEmpty, let title = properties.title {
          SectionDate(title: title)
        }
      case .detail:
        if let title = properties?.title, context.childIDs.count == 3 {
          GeometryReader { bounds in
            child(0).frame(width: bounds.size.width, height: bounds.size.height)
          }
          #if os(iOS)
          .toolbar(.hidden, for: .navigationBar)
          #endif
          .safeAreaInset(edge: .top, spacing: 0) {
            ZStack {
              Text(title).font(.headline).accessibilityAddTraits(.isHeader)
              HStack {
                child(1).fixedSize()
                Spacer()
                child(2).fixedSize()
              }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
          }
        }
      case .bottomControls:
        if context.childIDs.count == 2 {
          GeometryReader { bounds in
            child(0).frame(width: bounds.size.width, height: bounds.size.height)
          }
          .safeAreaInset(edge: .bottom, spacing: 0) {
            child(1)
              .frame(maxWidth: .infinity)
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
          }
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
