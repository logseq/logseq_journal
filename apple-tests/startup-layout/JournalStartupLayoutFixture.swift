import LUIAppleBackend
import Observation
import SwiftUI

@MainActor @Observable final class LayoutFixtureState {
  let backend: LUIAppleBackend
  var embedded = false
  var actionShown = false
  var recovered = false
  private var generation = 1

  init() {
    backend = try! LUIAppleBackend(extensionRegistry: JournalExtensions.registry())
    let data = try! Data(contentsOf: Bundle.main.url(forResource: "startup-patch", withExtension: "json")!)
    var patch = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    var ops = patch["ops"] as! [[String: Any]]
    for i in ops.indices where ops[i]["op"] as? String == "set-extension-prop"
      && ops[i]["id"] as? Int == 25 {
      ops[i]["value"] = "{\"mode\":\"startup\",\"loading\":true,\"initial\":false,\"active\":true,\"message\":\"\"}"
    }
    patch["ops"] = ops
    let encoded = try! JSONSerialization.data(withJSONObject: patch)
    try! backend.apply(json: String(decoding: encoded, as: UTF8.self))
    backend.onEvent = { [weak self] event in
      if case .press(node: 3000) = event { self?.recovered = true }
    }
  }

  func toggleAction() {
    let ops: [[String: Any]]
    if actionShown {
      ops = [["op": "remove-child", "parent": 26, "child": 3000],
        ["op": "detach-subtree", "id": 3000]]
    } else {
      ops = [["op": "create-node", "id": 3000, "kind": "button"],
        ["op": "set-prop", "id": 3000, "property": "text", "value": "Choose another graph"],
        ["op": "set-prop", "id": 3000, "property": "accessibility-identifier", "value": "qa-choose-graph"],
        ["op": "insert-child", "parent": 26, "child": 3000, "index": 0]]
    }
    generation += 1
    let data = try! JSONSerialization.data(withJSONObject: ["generation": generation, "ops": ops])
    try! backend.apply(json: String(decoding: data, as: UTF8.self))
    actionShown.toggle()
  }
}

@MainActor struct LayoutFixtureRoot: View {
  @State private var state = LayoutFixtureState()
  private let width = CGFloat(Int(ProcessInfo.processInfo.environment["STARTUP_LAYOUT_WIDTH"] ?? "390")!)
  private let font: DynamicTypeSize = ProcessInfo.processInfo.environment["STARTUP_LAYOUT_FONT"] == "accessibility3" ? .accessibility3 : .large

  var body: some View {
    ZStack {
      GeometryReader { container in
        Group {
          if state.embedded {
            LUISwiftUIRoot(backend: state.backend, rootID: 1)
              .environment(\.journalContainerTopInset, container.safeAreaInsets.top)
              .environment(\.journalStartupContainerFrame, container.frame(in: .global))
          } else {
            JournalStartupLoadingSurface(loading: true, initial: false, active: true)
          }
        }
      }.frame(width: width)
    }
    .font(.body)
    .environment(\.dynamicTypeSize, font)
    .overlay(alignment: .topLeading) {
      VStack(alignment: .leading) {
        HStack {
          Button("Runtime") { state.embedded = true }.accessibilityIdentifier("qa-runtime")
          Button("Action") { state.toggleAction() }.accessibilityIdentifier("qa-action")
        }.buttonStyle(.bordered).controlSize(.small)
        if state.embedded { Text("Runtime active").accessibilityIdentifier("qa-runtime-state") }
        if state.recovered { Text("Recovery invoked").accessibilityIdentifier("qa-recovery-invoked") }
      }.padding(4)
    }
  }
}

@main struct StartupLayoutFixture: App {
  var body: some Scene { WindowGroup { LayoutFixtureRoot() } }
}
