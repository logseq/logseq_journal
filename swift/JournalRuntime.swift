import Foundation
import LUIAppleBackend
import Observation

/// C bridge entries exported by app/journal_lui_bridge.c (see also
/// platform/native/lui_ocaml_bridge.c in the lui repository). Every entry that
/// produces a patch emits it synchronously through the patch callback installed
/// at start; all entries are invoked on the main actor, which owns the OCaml
/// runtime started by `lui_ocaml_start` on this thread.
private typealias PatchCallback = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias WakeupCallback = @convention(c) () -> Void
private typealias PlatformRequestCallback =
  @convention(c) (UnsafePointer<CChar>?, Int32) -> Void

@_silgen_name("lui_ocaml_start")
private func luiOCamlStart(
  _ callback: PatchCallback?,
  _ platform: Int32,
  _ host: Int32,
  _ payload: UnsafePointer<CChar>?,
  _ payloadLength: Int32
) -> Int32
@_silgen_name("lui_ocaml_stop")
private func luiOCamlStop() -> Int32
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
@_silgen_name("journal_ocaml_extension_event")
private func journalOCamlExtensionEvent(
  _ node: Int64,
  _ name: UnsafePointer<CChar>?,
  _ payload: UnsafePointer<CChar>?
) -> Int32
@_silgen_name("journal_ocaml_pump")
private func journalOCamlPump() -> Int32
@_silgen_name("journal_ocaml_platform_event")
private func journalOCamlPlatformEvent(_ data: UnsafePointer<CChar>?, _ length: Int32)
@_silgen_name("journal_ocaml_platform_response")
private func journalOCamlPlatformResponse(_ data: UnsafePointer<CChar>?, _ length: Int32)
@_silgen_name("journal_ocaml_set_wakeup_callback")
private func journalOCamlSetWakeupCallback(_ callback: WakeupCallback?)
@_silgen_name("journal_ocaml_set_platform_request_callback")
private func journalOCamlSetPlatformRequestCallback(_ callback: PlatformRequestCallback?)

nonisolated(unsafe) private var activeRuntime: JournalRuntime?

/// OCaml only invokes the patch callback from entries the host runs on the main
/// actor, so `assumeIsolated` holds by construction.
private let receivePatch: PatchCallback = { source in
  guard let source else { return }
  let json = String(cString: source)
  MainActor.assumeIsolated {
    activeRuntime?.apply(json: json)
  }
}

/// Fired on whichever OCaml worker thread enqueued cross-thread work; hop to
/// the main actor before draining the pump queue.
private let wakeup: WakeupCallback = {
  Task { @MainActor in
    activeRuntime?.pump()
  }
}

/// OCaml calls this synchronously on its worker thread with an LJP2 request
/// envelope. The callback returns immediately; the platform answers later via
/// `journal_ocaml_platform_response` on the main actor.
private let platformRequest: PlatformRequestCallback = { data, length in
  guard let data, length > 0 else { return }
  let bytes = Data(bytes: data, count: Int(length))
  Task { @MainActor in
    await activeRuntime?.deliverPlatformRequest(bytes)
  }
}

/// Owns the lui backend, the OCaml runtime, and the platform bridge for one
/// journal session. Replaces `BonsaiApplicationView` + `BonsaiApplicationBridge`.
@Observable @MainActor final class JournalRuntime {
  let backend: LUIAppleBackend
  let platform: JournalApplicationPlatform
  private let startupPayload: Data
  private(set) var rootID: Int?
  /// Count of patch batches applied from the OCaml runtime (test visibility).
  private(set) var appliedPatches = 0
  private var started = false

  init(
    platform: JournalApplicationPlatform,
    startupPayload: Data,
    extensionRegistry: LUIAppleExtensionRegistry
  ) throws {
    self.platform = platform
    self.startupPayload = startupPayload
    backend = try LUIAppleBackend(
      appIcons: journalAppIcons,
      extensionRegistry: extensionRegistry
    )
    backend.onEvent = { [weak self] event in self?.handle(event) }
  }

  /// Boots the OCaml runtime; the LDB1 startup payload rides inside
  /// `lui_ocaml_start` so init receives it before the worker session begins.
  /// The platform event stream attaches afterwards.
  func start() {
    guard !started else { return }
    journalOCamlSetWakeupCallback(wakeup)
    journalOCamlSetPlatformRequestCallback(platformRequest)
    activeRuntime = self
    #if os(macOS)
    let operatingSystem: Int32 = 1
    #else
    let operatingSystem: Int32 = 2
    #endif
    let accepted = startupPayload.withUnsafeBytes { bytes in
      luiOCamlStart(
        receivePatch,
        operatingSystem,
        2,
        bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
        Int32(bytes.count))
    }
    guard accepted == 1 else {
      activeRuntime = nil
      return
    }
    started = true
    platform.connect(to: self)
  }

  func stop() {
    guard started else { return }
    platform.disconnect()
    _ = luiOCamlStop()
    started = false
    activeRuntime = nil
  }

  func apply(json: String) {
    do {
      try backend.apply(json: json)
      rootID = backend.rootIDs.first
      appliedPatches += 1
    } catch {
      assertionFailure("Invalid LUI patch: \(error)")
    }
  }

  func pump() {
    guard started else { return }
    _ = journalOCamlPump()
  }

  /// Marshals one LJP2 request onto the platform actor and ships its response
  /// envelope back through the C entry. Errors drop the response; OCaml owns
  /// request timeouts (matching the old bridge error path).
  func deliverPlatformRequest(_ bytes: Data) async {
    guard started, let response = await platform.request(bytes) else { return }
    response.withUnsafeBytes { buffer in
      journalOCamlPlatformResponse(
        buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
        Int32(buffer.count))
    }
  }

  /// Pushes one host-originated LJP2 event envelope to OCaml.
  func sendPlatformEvent(_ bytes: Data) {
    guard started else { return }
    bytes.withUnsafeBytes { buffer in
      journalOCamlPlatformEvent(
        buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
        Int32(buffer.count))
    }
  }

  private func handle(_ event: LUIEvent) {
    guard started else { return }
    switch event {
    case let .appear(node): _ = luiOCamlAppear(Int64(node))
    case let .press(node): _ = luiOCamlPress(Int64(node))
    case let .longPress(node): _ = luiOCamlLongPress(Int64(node))
    case let .textChanged(node, text):
      text.withCString { _ = luiOCamlTextChanged(Int64(node), $0) }
    case let .submit(node): _ = luiOCamlSubmit(Int64(node))
    case let .dismiss(node): _ = luiOCamlDismiss(Int64(node))
    case let .doublePress(node): _ = luiOCamlDoublePress(Int64(node))
    case let .toggleChanged(node, checked):
      _ = luiOCamlToggleChanged(Int64(node), checked ? 1 : 0)
    case let .change(node): _ = luiOCamlRadioChanged(Int64(node))
    case let .valueChanged(node, value):
      _ = luiOCamlSliderChanged(Int64(node), value)
    case let .extension(node, _, name, values):
      guard let payload = Self.encodeExtensionValues(values) else { return }
      name.withCString { eventName in
        payload.withCString { json in
          _ = journalOCamlExtensionEvent(Int64(node), eventName, json)
        }
      }
    }
  }

  /// Serializes extension event fields as the bare-scalar JSON object the
  /// OCaml `extension_event` hook decodes into wire values.
  private static func encodeExtensionValues(
    _ values: [String: LUIExtensionValue]
  ) -> String? {
    var object: [String: Any] = [:]
    for (name, value) in values {
      switch value {
      case let .string(string): object[name] = string
      case let .bool(flag): object[name] = flag
      case let .int(number): object[name] = number
      case let .double(number): object[name] = number
      }
    }
    guard let data = try? JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}
