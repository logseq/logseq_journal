import Foundation
import LUIAppleBackend
import Observation
#if os(iOS) && targetEnvironment(simulator)
import UIKit
import CryptoKit
#endif

/// C bridge entries exported by app/journal_lui_bridge.c (see also
/// platform/native/lui_ocaml_bridge.c in the lui repository). Every entry that
/// produces a patch copies it into owned bytes and releases the OCaml runtime
/// before invoking the synchronous patch callback. All entries run on the main
/// actor; applying a patch may synchronously reenter an event entry.
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

@_silgen_name("journal_ocaml_read_acceptance")
private func journalOCamlReadAcceptance(_ request: UnsafePointer<CChar>?, _ length: Int32,
                                      _ callback: PatchCallback?) -> Int32
nonisolated(unsafe) private var identityReply: String?
private let receiveIdentity: PatchCallback = { pointer in
  let reply = pointer.map { String(cString: $0) }
  MainActor.assumeIsolated { identityReply = reply }
}

nonisolated(unsafe) private var activeRuntime: JournalRuntime?

/// The C bridge invokes this on the main actor after releasing the runtime.
/// The copied bytes remain valid until the callback returns, including reentry.
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
  #if os(iOS) && targetEnvironment(simulator)
  @ObservationIgnored private var acceptanceServer: JournalAcceptanceServer?
  @ObservationIgnored private var acceptanceLifecycle: [NSObjectProtocol] = []
  @ObservationIgnored private var acceptanceInstance = UUID().uuidString
  @ObservationIgnored private var acceptanceNativeEpoch: Int?
  @ObservationIgnored private var acceptanceGeneration = 0
  @ObservationIgnored private var acceptanceMounted = false
  @ObservationIgnored private var acceptanceHealthy = true
  #endif

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
    startAcceptanceIdentity()
    syncAcceptanceIdentity()
  }

  func stop() {
    guard started else { return }
    stopAcceptanceIdentity()
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
      #if os(iOS) && targetEnvironment(simulator)
      acceptanceHealthy = false
      #endif
      assertionFailure("Invalid LUI patch: \(error)")
    }
  }

  func pump() {
    guard started else { return }
    _ = journalOCamlPump()
    syncAcceptanceIdentity()
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
    syncAcceptanceIdentity()
  }
}

private struct JournalNativeIdentity: Decodable, Equatable {
  let status: String
  let epoch: Int?
  let graph_id: String?
  let worker_generation: Int?
  let root_node: Int?
}

extension JournalRuntime {
  private func nativeIdentity(_ request: String) -> JournalNativeIdentity? {
    identityReply = nil
    guard request.withCString({ journalOCamlReadAcceptance($0, Int32(request.utf8.count), receiveIdentity) }) == 1,
          let value = identityReply, let data = value.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JournalNativeIdentity.self, from: data)
  }

  func setAcceptanceRootMounted(_ mounted: Bool) {
    #if os(iOS) && targetEnvironment(simulator)
    if acceptanceMounted != mounted { acceptanceGeneration += 1 }
    acceptanceMounted = mounted
    #endif
  }

  private func syncAcceptanceIdentity() {
    #if os(iOS) && targetEnvironment(simulator)
    guard started, ProcessInfo.processInfo.environment["JOURNAL_ACCEPTANCE"] == "1",
          let epoch = nativeIdentity("snapshot")?.epoch else { return }
    if epoch != acceptanceNativeEpoch { acceptanceGeneration += 1 }
    acceptanceNativeEpoch = epoch
    #endif
  }

  private func stopAcceptanceIdentity() {
    #if os(iOS) && targetEnvironment(simulator)
    acceptanceServer?.stop(); acceptanceServer = nil
    for observer in acceptanceLifecycle { NotificationCenter.default.removeObserver(observer) }
    acceptanceLifecycle.removeAll()
    acceptanceMounted = false
    acceptanceGeneration += 1
    #endif
  }

  private func startAcceptanceIdentity() {
    #if os(iOS) && targetEnvironment(simulator)
    let environment = ProcessInfo.processInfo.environment
    guard let endpoint = JournalAcceptanceServer.endpoint(environment: environment),
          let executable = Bundle.main.executableURL,
          let source = Bundle.main.object(forInfoDictionaryKey: "JournalSourceRevision") as? String,
          let bundle = Bundle.main.bundleIdentifier,
          let udid = environment["SIMULATOR_UDID"] else { return }
    acceptanceInstance = UUID().uuidString
    for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
      acceptanceLifecycle.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.acceptanceGeneration += 1 }
      })
    }
    let instance = acceptanceInstance
    Task { [weak self] in
      let hash = await Task.detached(priority: .utility) { () -> String? in
        guard let stream = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? stream.close() }
        var digest = SHA256()
        do {
          while let data = try stream.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
          return digest.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
      }.value
      guard let self, self.started, self.acceptanceInstance == instance, let hash else { return }
      let server = JournalAcceptanceServer(path: endpoint) { [weak self] challenge in
        await self?.acceptanceIdentity(challenge: challenge, source: source, bundle: bundle, udid: udid, hash: hash)
      }
      do { try server.start(); self.acceptanceServer = server }
      catch { self.acceptanceServer = nil }
    }
    #endif
  }

  #if os(iOS) && targetEnvironment(simulator)
  private var acceptanceForeground: Bool {
    UIApplication.shared.applicationState == .active &&
      UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
  }

  private func freshIdentity() async -> JournalNativeIdentity? {
    let request = UUID().uuidString
    for _ in 0..<50 {
      guard started else { return nil }
      guard let response = nativeIdentity(request) else { return nil }
      if response.status != "pending" { return response.status == "ready" ? response : nil }
      do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
    }
    return nil
  }

  private func acceptanceIdentity(challenge: String, source: String, bundle: String,
                                  udid: String, hash: String) async -> Data? {
    guard started, acceptanceMounted, acceptanceHealthy, acceptanceForeground,
          let mountedRoot = rootID, mountedRoot > 0 else { return nil }
    let generation = acceptanceGeneration
    guard let before = await freshIdentity(), let epoch = before.epoch, epoch >= 0,
          epoch == acceptanceNativeEpoch, before.root_node == mountedRoot, let graph = before.graph_id,
          await JournalAcceptanceDisplayBarrier.wait(),
          let after = await freshIdentity(), before == after,
          after.epoch == acceptanceNativeEpoch, after.root_node == mountedRoot, rootID == mountedRoot,
          generation == acceptanceGeneration, started, acceptanceMounted,
          acceptanceHealthy, acceptanceForeground else { return nil }
    return try? JSONSerialization.data(withJSONObject: [
      "schema_version": 1, "challenge": challenge, "udid": udid, "bundle_id": bundle,
      "executable_sha256": hash, "source_sha": source, "graph_id": graph,
      "graph_generation": generation, "presentation_generation": generation,
      "phase": "open", "foreground": true, "pid": ProcessInfo.processInfo.processIdentifier,
      "process_instance": acceptanceInstance])
  }
  #endif
}
