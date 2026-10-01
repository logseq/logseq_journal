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

nonisolated(unsafe) private var patches: [String] = []
private let receivePatch: PatchCallback = { source in
  if let source { patches.append(String(cString: source)) }
}

@MainActor @main struct JournalLUIEventsTests {
  static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: message, code: 1) }
  }

  static func main() throws {
    try check("{}".withCString { start(receivePatch, 2, 2, $0, 2) } == 1, "runtime failed to start")
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
    }
    patches.removeAll()
    try check(picked(Int64(node), nil) == 0 && patches.isEmpty, "null payload produced an event")
    try check(
      JournalLUIEvents.dispatch(.textChanged(node: node, text: "raise")) == 0,
      "OCaml exception reported success")
    try check(patches.isEmpty, "OCaml exception emitted a patch")
    try check(
      JournalLUIEvents.dispatch(.press(node: node)) == 1 && patches.count == 1,
      "runtime did not recover after an exception")
    print(
      "PASS: \(cases.count) Swift → C → OCaml events, synchronous patches, null rejection and exception recovery"
    )
  }
}
