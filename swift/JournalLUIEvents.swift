import Foundation
import LUIAppleBackend

// Match LUI's typed native ABI. Journal's C adapter also acquires/releases the
// OCaml runtime lock and delivers an owned patch after releasing it, before
// returning. A backend patch can therefore synchronously dispatch another event.
@_silgen_name("lui_ocaml_appear")
private func luiOCamlAppear(_ node: Int64) -> Int32
@_silgen_name("lui_ocaml_press")
private func luiOCamlPress(_ node: Int64) -> Int32
@_silgen_name("lui_ocaml_long_press")
private func luiOCamlLongPress(_ node: Int64) -> Int32
@_silgen_name("lui_ocaml_text_changed")
private func luiOCamlTextChanged(_ node: Int64, _ text: UnsafePointer<CChar>?) -> Int32
@_silgen_name("lui_ocaml_submit")
private func luiOCamlSubmit(_ node: Int64) -> Int32
@_silgen_name("lui_ocaml_dismiss")
private func luiOCamlDismiss(_ node: Int64) -> Int32
@_silgen_name("lui_ocaml_double_press")
private func luiOCamlDoublePress(_ node: Int64) -> Int32
@_silgen_name("lui_ocaml_toggle_changed")
private func luiOCamlToggleChanged(_ node: Int64, _ checked: Int32) -> Int32
@_silgen_name("lui_ocaml_radio_changed")
private func luiOCamlRadioChanged(_ node: Int64) -> Int32
@_silgen_name("lui_ocaml_slider_changed")
private func luiOCamlSliderChanged(_ node: Int64, _ value: Double) -> Int32
@_silgen_name("lui_ocaml_scroll_completed")
private func luiOCamlScrollCompleted(
  _ node: Int64, _ token: Int64, _ outcome: UnsafePointer<CChar>?
) -> Int32
@_silgen_name("lui_ocaml_visible_range")
private func luiOCamlVisibleRange(_ node: Int64, _ first: Int64, _ last: Int64) -> Int32
@_silgen_name("lui_ocaml_picked")
private func luiOCamlPicked(_ node: Int64, _ payload: UnsafePointer<CChar>?) -> Int32
@_silgen_name("journal_ocaml_extension_event")
private func journalOCamlExtensionEvent(
  _ node: Int64, _ name: UnsafePointer<CChar>?, _ payload: UnsafePointer<CChar>?
) -> Int32

@MainActor enum JournalLUIEvents {
  static func dispatch(_ event: LUIEvent) -> Int32 {
    switch event {
    case .appear(let node): return luiOCamlAppear(Int64(node))
    case .press(let node): return luiOCamlPress(Int64(node))
    case .longPress(let node): return luiOCamlLongPress(Int64(node))
    case .textChanged(let node, let text):
      return text.withCString { luiOCamlTextChanged(Int64(node), $0) }
    case .submit(let node): return luiOCamlSubmit(Int64(node))
    case .dismiss(let node): return luiOCamlDismiss(Int64(node))
    case .doublePress(let node): return luiOCamlDoublePress(Int64(node))
    case .toggleChanged(let node, let checked):
      return luiOCamlToggleChanged(Int64(node), checked ? 1 : 0)
    case .change(let node): return luiOCamlRadioChanged(Int64(node))
    case .valueChanged(let node, let value):
      return luiOCamlSliderChanged(Int64(node), value)
    case .scrollCompleted(let node, let token, let outcome):
      return outcome.withCString { luiOCamlScrollCompleted(Int64(node), Int64(token), $0) }
    case .visibleRange(let node, let first, let last):
      return luiOCamlVisibleRange(Int64(node), Int64(first), Int64(last))
    case .picked(let node, let payload):
      return payload.withCString { luiOCamlPicked(Int64(node), $0) }
    case .extension(let node, _, let name, let values):
      guard let payload = encodeExtensionValues(values) else { return 0 }
      return name.withCString { eventName in
        payload.withCString { journalOCamlExtensionEvent(Int64(node), eventName, $0) }
      }
    }
  }

  private static func encodeExtensionValues(_ values: [String: LUIExtensionValue]) -> String? {
    var object: [String: Any] = [:]
    for (name, value) in values {
      switch value {
      case .string(let string): object[name] = string
      case .bool(let flag): object[name] = flag
      case .int(let number): object[name] = number
      case .double(let number): object[name] = number
      }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}
