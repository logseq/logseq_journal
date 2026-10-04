import Foundation
import LUIAppleBackend

private typealias PatchCallback = @convention(c) (UnsafePointer<CChar>?) -> Void
@_silgen_name("lui_ocaml_start")
private func start(
  _ callback: PatchCallback?, _ platform: Int32, _ host: Int32,
  _ payload: UnsafePointer<CChar>?, _ length: Int32
) -> Int32
@_silgen_name("lui_ocaml_picked")
private func picked(_ node: Int64, _ payload: UnsafePointer<CChar>?) -> Int32
@_silgen_name("lui_ocaml_root_node")
private func rootNode() -> Int64
@_silgen_name("journal_ocaml_pump")
private func pump() -> Int32
@_silgen_name("lui_ocaml_stop")
private func stop() -> Int32
@_silgen_name("journal_ocaml_extension_event")
private func extensionEvent(
  _ node: Int64, _ name: UnsafePointer<CChar>?, _ payload: UnsafePointer<CChar>?
) -> Int32
@_silgen_name("journal_ocaml_platform_event")
private func platformEvent(_ bytes: UnsafePointer<UInt8>?, _ length: Int32)
@_silgen_name("journal_ocaml_platform_response")
private func platformResponse(_ bytes: UnsafePointer<UInt8>?, _ length: Int32)
@_silgen_name("journal_ocaml_platform_failure")
private func platformFailure(_ bytes: UnsafePointer<UInt8>?, _ length: Int32)

nonisolated(unsafe) private var patches: [String] = []
nonisolated(unsafe) private var callbackFailure: String?
nonisolated(unsafe) private var reenter = false
private let receivePatch: PatchCallback = { source in
  guard let source else { return }
  let before = String(cString: source)
  patches.append(before)
  // Applying a real backend patch synchronously delivers deferred UI events.
  // Even a read-only bridge call must be able to reacquire the OCaml runtime.
  if rootNode() != 42 { callbackFailure = "callback could not query the runtime" }
  if reenter {
    reenter = false
    if MainActor.assumeIsolated({
      JournalLUIEvents.dispatch(.textChanged(node: 42, text: "nested 日记"))
    }) != 1 {
      callbackFailure = "nested dispatch failed"
    }
    if MainActor.assumeIsolated({ JournalLUIEvents.dispatch(.dismiss(node: 42)) }) != 1 {
      callbackFailure = "second nested dispatch failed"
    }
  }
  // The nested call forces major GC; the outer bytes must still be owned by C.
  if String(cString: source) != before { callbackFailure = "patch bytes changed during reentry" }
}

@MainActor @main struct JournalLUIEventsTests {
  static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: message, code: 1) }
  }

  static func main() throws {
    try check("{}".withCString { start(receivePatch, 2, 2, $0, 2) } == 1, "runtime failed to start")
    try check(patches.count == 1 && callbackFailure == nil, "startup callback failed")
    let node = (1 << 40) + 7
    let payload = "{\"token\":11,\"files\":[{\"name\":\"日记📓.md\"}]}"
    let cases: [(LUIEvent, String)] = [
      (.appear(node: node), "appear"),
      (.press(node: node), "press"),
      (.longPress(node: node), "longPress"),
      (.textChanged(node: node, text: "日记\n\"draft\""), "textChanged:日记\n\"draft\""),
      (.submit(node: node), "submit"),
      (.dismiss(node: node), "dismiss"),
      (.doublePress(node: node), "doublePress"),
      (.toggleChanged(node: node, checked: true), "toggleChanged:true"),
      (.toggleChanged(node: node, checked: false), "toggleChanged:false"),
      (.change(node: node), "change"),
      (.valueChanged(node: node, value: 0.25), "valueChanged:0.25"),
      (
        .scrollCompleted(node: node, token: node + 1, outcome: "unavailable"),
        "scrollCompleted:\(node + 1):unavailable"
      ),
      (
        .scrollCompleted(node: node, token: 42, outcome: "succeeded"),
        "scrollCompleted:42:succeeded"
      ),
      (.visibleRange(node: node, first: 0, last: 14), "visibleRange:0:14"),
      (.visibleRange(node: node, first: -1, last: -1), "visibleRange:-1:-1"),
      (.picked(node: node, payload: payload), "picked:" + payload),
      (
        .extension(
          node: node, identifier: "fixture", name: "changed", values: ["text": .string("日记")]),
        "extension:changed:{\"text\":\"日记\"}"
      ),
    ]
    for (event, expected) in cases {
      patches.removeAll()
      try check(JournalLUIEvents.dispatch(event) == 1, "event rejected: \(event)")
      // This assertion executes immediately after the production adapter returns.
      try check(patches.count == 1, "patch was not delivered synchronously: \(event)")
      let object = try JSONSerialization.jsonObject(with: Data(patches[0].utf8)) as? [String: Any]
      let ops = object?["ops"] as? [[String: Any]]
      try check((ops?.first?["id"] as? NSNumber)?.int64Value == Int64(node), "node was truncated")
      try check(ops?.first?["value"] as? String == expected, "event payload changed: \(event)")
      try check(callbackFailure == nil, "callback reentry failed: \(event)")
    }
    patches.removeAll()
    try check(picked(Int64(node), nil) == 0 && patches.isEmpty, "null payload produced an event")
    try check(extensionEvent(Int64(node), nil, nil) == 0, "null extension accepted")
    try check(
      JournalLUIEvents.dispatch(.textChanged(node: node, text: "raise")) == 0,
      "OCaml exception reported success")
    try check(patches.isEmpty, "OCaml exception emitted a patch")
    try check(
      JournalLUIEvents.dispatch(.press(node: node)) == 1 && patches.count == 1,
      "runtime did not recover after an exception")
    patches.removeAll()
    reenter = true
    try check(JournalLUIEvents.dispatch(.press(node: node)) == 1, "outer dispatch failed")
    try check(patches.count == 3 && callbackFailure == nil, "nested patches lost or reordered")
    let values = try patches.map { json -> String? in
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
      return (object?["ops"] as? [[String: Any]])?.first?["value"] as? String
    }
    try check(values == ["press", "textChanged:nested 日记", "dismiss"], "patch delivery order changed")
    patches.removeAll()
    try check(pump() == 1 && patches.count == 1, "pump callback failed")
    let bytes: [UInt8] = [65, 0, 66]
    for deliver in [platformEvent, platformResponse, platformFailure] {
      patches.removeAll()
      bytes.withUnsafeBufferPointer { deliver($0.baseAddress, Int32($0.count)) }
      try check(patches.isEmpty, "platform envelope unexpectedly applied a patch")
      try check(pump() == 1 && patches.count == 1, "platform completion could not pump")
      let object = try JSONSerialization.jsonObject(with: Data(patches[0].utf8)) as? [String: Any]
      let value = (object?["ops"] as? [[String: Any]])?.first?["value"] as? String
      try check(value == "platform:410042", "binary platform envelope changed")
    }
    for _ in 0..<100 {
      patches.removeAll()
      reenter = true
      try check(JournalLUIEvents.dispatch(.press(node: node)) == 1, "repeated dispatch failed")
      try check(patches.count == 3 && callbackFailure == nil, "repeated reentry failed")
    }
    patches.removeAll()
    try check(stop() == 1 && patches.count == 1 && callbackFailure == nil, "dispose callback failed")
    patches.removeAll()
    try check("{}".withCString { start(receivePatch, 2, 2, $0, 2) } == 1, "restart failed")
    try check(patches.count == 1 && callbackFailure == nil, "restart callback failed")
    try check(stop() == 1, "second dispose failed")
    print(
      "PASS: \(cases.count) Swift → C → OCaml events, startup/pump/dispose/restart, synchronous reentry, owned patches, null rejection and exception recovery"
    )
  }
}
