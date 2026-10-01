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
@_silgen_name("journal_ocaml_pump")
private func journalOCamlPump() -> Int32
@_silgen_name("journal_ocaml_platform_event")
private func journalOCamlPlatformEvent(_ data: UnsafePointer<CChar>?, _ length: Int32)
@_silgen_name("journal_ocaml_platform_response")
private func journalOCamlPlatformResponse(_ data: UnsafePointer<CChar>?, _ length: Int32)
@_silgen_name("journal_ocaml_platform_failure")
private func journalOCamlPlatformFailure(_ data: UnsafePointer<CChar>?, _ length: Int32)
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
  /// envelope back through the C entry. A nil response (decode or service
  /// failure) reports the request as failed so OCaml resolves its pending
  /// continuation instead of waiting forever.
  func deliverPlatformRequest(_ bytes: Data) async {
    guard started else { return }
    guard let response = await platform.request(bytes) else {
      bytes.withUnsafeBytes { buffer in
        journalOCamlPlatformFailure(
          buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
          Int32(buffer.count))
      }
      return
    }
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
    _ = JournalLUIEvents.dispatch(event)
  }
}
