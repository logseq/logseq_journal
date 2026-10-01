import Foundation

private typealias Patch = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias Loading = @convention(c) (Int32) -> Void

@_silgen_name("lui_ocaml_start")
private func start(
  _ patch: Patch?, _ platform: Int32, _ host: Int32,
  _ payload: UnsafePointer<CChar>?, _ length: Int32
) -> Int32
@_silgen_name("journal_ocaml_pump") private func pump() -> Int32
@_silgen_name("lui_ocaml_stop") private func stop() -> Int32
@_silgen_name("journal_ocaml_set_loading_callback")
private func setLoading(_ callback: Loading?)

nonisolated(unsafe) private var events: [String] = []
private let patch: Patch = { value in
  events.append("patch:" + (value.map(String.init(cString:)) ?? "nil"))
}
private let loading: Loading = { signal in events.append("loading:\(signal)") }

@main struct JournalLoadingBridgeTests {
  static func main() {
    setLoading(loading)
    assert(start(patch, 2, 2, nil, 0) == 1)
    assert(events == ["patch:initial-patch", "loading:0"], "initial forwarding: \(events)")
    assert(pump() == 1)
    assert(
      events == ["patch:initial-patch", "loading:0", "patch:ready-patch", "loading:1"],
      "ready forwarding/order: \(events)")
    setLoading(nil)
    _ = stop()
    print("Journal native loading bridge passed")
  }
}
