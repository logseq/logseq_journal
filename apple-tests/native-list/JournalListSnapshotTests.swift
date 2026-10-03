import Foundation
import SwiftUI
@testable import LUIAppleBackend

// Native payload parsing/lifecycle ownership is not reachable through an OCaml
// reducer. This executable drives the real backend and native prepared owner.
@MainActor @main struct JournalListSnapshotTests {
  static var failures = 0
  static func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { failures += 1; FileHandle.standardOutput.write(Data(("FAIL: " + message + "\n").utf8)) }
  }
  static func payload(_ keys: [String], expanded: Bool? = nil, track: Bool = true,
                      token: String? = nil, title: String = "Status") -> String {
    var rows: [[String: Any]] = keys.enumerated().map { index, key in
      ["type": "row", "key": key, "content_index": index,
       "context_menu": ["actions": [["key": "status", "title": title]]]]
    }
    if let expanded, !rows.isEmpty {
      rows[0]["type"] = "disclosure"
      rows[0]["expanded"] = expanded
      rows[0]["children"] = [["type": "row", "key": "child", "content_index": 0]]
    }
    var object: [String: Any] = ["style": "plain", "track_visible_range": track,
      "track_scroll_completion": true, "sections": [["key": "day", "rows": rows]]]
    if let token { object["scroll_request"] = ["token": token,
      "target": ["section": "day", "row_path": [keys.first ?? "missing"]]] }
    return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
  }
  static func patch(_ backend: LUIAppleBackend, _ payload: String) throws {
    let object: [String: Any] = ["generation": backend.generation + 1, "ops": [["op": "set-extension-prop",
      "id": 1, "property": "payload", "value": payload]]]
    try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
  }
  static func settle() async { for _ in 0..<10 { await Task.yield() } }
  static func main() async throws {
    var captured: LUIAppleExtensionViewContext?
    let registry = LUIAppleExtensionRegistry()
    try registry.register(LUIAppleExtension(identifier: "journal-list", fingerprint: "snapshot-test",
      acceptsStandardChildren: true, properties: [.init(name: "payload", kind: .string, isRequired: true)],
      events: [.init(name: "event", fields: [.init(name: "id", kind: .int, isRequired: true),
        .init(name: "payload", kind: .string, isRequired: true)])]) { context in
      captured = context; return AnyView(EmptyView())
    })
    let backend = try LUIAppleBackend(extensionRegistry: registry)
    var emitted: [[String: Any]] = []
    backend.onEvent = { event in
      if case let .extension(_, _, _, values) = event,
        case let .string(json) = values["payload"],
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
        emitted.append(object)
      }
    }
    let initial: [String: Any] = ["generation": 1, "ops": [
      ["op": "create-extension", "id": 1, "identifier": "journal-list", "fingerprint": "snapshot-test"],
      ["op": "set-extension-prop", "id": 1, "property": "payload", "value": payload(["a", "b", "c"])]]]
    try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: initial), as: UTF8.self))
    _ = backend.extensionView(nodeID: 1)
    let context = captured!
    let owner = JournalList.PreparedState()
    owner.bind(context)
    let first = owner.snapshot
    for _ in 0..<200 { _ = owner.snapshot?.properties; _ = owner.snapshot?.positions["b"] }
    check(owner.snapshot === first, "repeated reads must retain the prepared snapshot")
    #if NATIVE_LIST_DIAGNOSTICS
    check(NativeListDiagnostics.decodes == 1, "scroll-time reads must decode once, not per read")
    #endif
    let a = owner.lease(for: "a")!, b = owner.lease(for: "b")!, c = owner.lease(for: "c")!
    check(!owner.receive(a, appeared: false), "unseen disappearance is a no-op")
    check(owner.receive(b, appeared: true), "first appear changes visibility")
    check(owner.receive(b, appeared: false), "first disappearance changes visibility")
    check(!owner.receive(b, appeared: false), "duplicate disappearance is a no-op")
    check(owner.receive(b, appeared: true), "reappearance changes visibility")
    check(!owner.receive(b, appeared: true), "duplicate appear is a no-op")
    check(owner.range == 1..<2, "initial position")
    try await Task.sleep(nanoseconds: 120_000_000)
    check(emitted.count == 1 && emitted[0]["first"] as? Int == 1,
      "duplicate lifecycle emits exactly one settled range")
    let childOnly: [String: Any] = ["generation": backend.generation + 1, "ops": [
      ["op": "create-node", "id": 7, "kind": "text"],
      ["op": "set-prop", "id": 7, "property": "text", "value": "Edited child/tag/media"],
      ["op": "insert-child", "parent": 1, "child": 7, "index": 0]]]
    try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: childOnly), as: UTF8.self))
    await settle()
    check(owner.snapshot === first, "child-only content revision must not decode payload")
    owner.suspend()
    check(!owner.receive(c, appeared: true), "offscreen retained list rejects queued callback")
    check(owner.snapshot === first && owner.range == 1..<2, "navigation suspension retains content and visibility")
    owner.bind(context)
    check(!owner.receive(b, appeared: true), "navigation return reuses live row identity")
    try patch(backend, payload(["x", "a", "b", "c", "d"]))
    await settle()
    check(owner.range == 2..<3, "append/prepend remaps surviving visible keys")
    check(owner.receive(c, appeared: true), "same-lease old callback remaps by key")
    check(owner.range == 2..<4, "old callback never inserts obsolete index")
    try patch(backend, payload(["c", "a", "b"]))
    await settle()
    check(owner.range == 0..<3, "reorder uses current order")
    try patch(backend, payload(["a", "c"]))
    await settle()
    check(owner.range == 1..<2 && !owner.receive(b, appeared: true), "delete prunes visibility and rejects removed callback")
    try patch(backend, payload(["a", "b", "c"]))
    await settle()
    check(!owner.receive(b, appeared: true), "restore does not revive old row incarnation")
    check(owner.receive(owner.lease(for: "b")!, appeared: true), "restored row has fresh lease")
    try patch(backend, payload(["a", "b", "c"], title: "Edited/status changed"))
    await settle()
    check(owner.snapshot?.properties.sections[0].rows[0].context_menu?.actions[0].title == "Edited/status changed", "same order/count refreshes row actions")
    check(owner.range == 1..<3, "content/status refresh preserves visible keys")
    try patch(backend, payload(["a", "b"], expanded: true))
    await settle()
    let child = owner.lease(for: "child")!
    check(owner.receive(child, appeared: true), "expanded descendant appears")
    try patch(backend, payload(["a", "b"], expanded: false))
    await settle()
    check(owner.snapshot?.positions["child"] == nil && !owner.receive(child, appeared: true), "collapse rejects stale descendant callback")
    try patch(backend, payload(["a", "b"], expanded: true))
    await settle()
    check(!owner.receive(child, appeared: true), "re-expansion does not revive collapsed incarnation")
    try patch(backend, payload(["a", "b"], expanded: true, track: false, token: "17"))
    await settle()
    check(owner.snapshot?.properties.track_visible_range == false && owner.snapshot?.properties.scroll_request?.token == "17", "track flags and scroll tokens invalidate snapshot")
    let beforeNoop = owner.snapshot
    try patch(backend, payload(["a", "b"], expanded: true, track: false, token: "17"))
    await settle()
    check(owner.snapshot === beforeNoop, "identical backend payload does not replace snapshot")
    try patch(backend, "malformed")
    await settle()
    check(owner.snapshot == nil && owner.range == nil, "invalid payload does not retain last-valid content")
    try patch(backend, payload(["a", "a"]))
    await settle()
    check(owner.snapshot == nil, "duplicate row keys cannot create ambiguous positions")
    owner.dispose()
    owner.bind(context)
    check(!owner.receive(a, appeared: true), "runtime/list replacement rejects old instance callback")
    try patch(backend, payload(["a", "b"]))
    await settle()
    let current = owner.lease(for: "a")!
    // Callback queued during a payload commit is remapped after refresh.
    try patch(backend, payload(["z", "a", "b"]))
    _ = owner.receive(current, appeared: true)
    await settle()
    check(owner.range == 1..<2, "queued callback observes committed positions")
    try await Task.sleep(nanoseconds: 120_000_000)
    check(emitted.last?["first"] as? Int == 1 && emitted.last?["last"] as? Int == 2,
      "settled emission uses committed positions")
    let deliveredCount = emitted.count
    _ = owner.receive(owner.lease(for: "b")!, appeared: true)
    owner.dispose()
    check(!owner.receive(current, appeared: false), "disposed owner rejects queued disappearance")
    try await Task.sleep(nanoseconds: 120_000_000)
    check(emitted.count == deliveredCount, "disposed owner cancels queued range emission")
    owner.bind(context)
    let previousLease = owner.lease(for: "a")!
    let replacement: [String: Any] = ["generation": backend.generation + 1, "ops": [
      ["op": "create-extension", "id": 99, "identifier": "journal-list", "fingerprint": "snapshot-test"],
      ["op": "set-extension-prop", "id": 99, "property": "payload", "value": payload(["replacement"])]]]
    try backend.apply(json: String(decoding: JSONSerialization.data(withJSONObject: replacement), as: UTF8.self))
    _ = backend.extensionView(nodeID: 99)
    owner.bind(captured!)
    check(owner.snapshot?.positions["replacement"] == 0 && owner.range == nil,
      "new extension context replaces cached payload and visible keys")
    check(!owner.receive(previousLease, appeared: true), "node replacement rejects former owner lease")
    owner.dispose()
    if failures > 0 { exit(Int32(failures)) }
    print("PASS: native owner snapshot reuse, remapping, actions, disclosure, flags, invalid payload, disposal and queued callbacks")
  }
}
