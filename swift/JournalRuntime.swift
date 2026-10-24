import Foundation
import LUIAppleBackend
import Observation

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
@_silgen_name("journal_ocaml_failure_reason")
private func journalOCamlFailureReason(_ operation:Int32) -> Int32
@_silgen_name("lui_ocaml_stop")
private func luiOCamlStop() -> Int32
@_silgen_name("journal_ocaml_pump")
private func journalOCamlPump() -> Int32
@_silgen_name("journal_ocaml_platform_event")
private func journalOCamlPlatformEvent(_ data: UnsafePointer<CChar>?, _ length: Int32) -> Int32
@_silgen_name("journal_ocaml_platform_response")
private func journalOCamlPlatformResponse(_ data: UnsafePointer<CChar>?, _ length: Int32) -> Int32
@_silgen_name("journal_ocaml_platform_failure")
private func journalOCamlPlatformFailure(_ data: UnsafePointer<CChar>?, _ length: Int32) -> Int32
@_silgen_name("journal_ocaml_set_wakeup_callback")
private func journalOCamlSetWakeupCallback(_ callback: WakeupCallback?)
@_silgen_name("journal_ocaml_set_platform_request_callback")
private func journalOCamlSetPlatformRequestCallback(_ callback: PlatformRequestCallback?)

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

/// One bridge session owns both buffered startup requests and later deliveries.
/// A callback copies its payload before returning; it never enters OCaml again.
private final class JournalPlatformRequestIngress: @unchecked Sendable {
  private let lock = NSLock()
  private var owner: UUID?
  struct Request: Sendable {
    let bytes:Data
    let ticket:UUID
    let tag:UInt8?
  }
  private var latest:[UInt8:UUID] = [:]
  private var pending: [Request] = []
  private var receiver: (@Sendable (Request) -> Void)?
  func begin(_ identity: UUID) {
    lock.lock(); defer { lock.unlock() }
    owner = identity; pending = []; latest = [:]; receiver = nil
  }
  func submit(_ request: Data) {
    lock.lock()
    guard owner != nil else { lock.unlock(); return }
    let tag:UInt8? = request.count >= 8 && request.prefix(6) == Data([76,74,80,50,2,0])
      && request[7] == 0 && [6,8,10,13,20,22,28,30,32].contains(request[6]) ? request[6] : nil
    let receipt=Request(bytes:request,ticket:UUID(),tag:tag)
    if let tag { latest[tag] = receipt.ticket }
    let deliver = receiver
    if deliver == nil { pending.append(receipt) }
    lock.unlock()
    deliver?(receipt)
  }
  func activate(_ identity: UUID, receiver: @escaping @Sendable (Request) -> Void) -> [Request] {
    lock.lock(); defer { lock.unlock() }
    guard owner == identity else { return [] }
    self.receiver = receiver
    let requests = pending; pending = []
    return requests
  }
  func owns(_ identity:UUID, _ request:Request) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard owner == identity else { return false }
    return request.tag.map { latest[$0] == request.ticket } ?? true
  }
  func close(_ identity: UUID) {
    lock.lock(); defer { lock.unlock() }
    guard owner == identity else { return }
    owner = nil; receiver = nil; pending = []; latest = [:]
  }
}
private let platformRequestIngress = JournalPlatformRequestIngress()
private let platformRequest: PlatformRequestCallback = { data, length in
  guard let data, length > 0 else { return }
  platformRequestIngress.submit(Data(bytes: data, count: Int(length)))
}

/// Owns the lui backend, the OCaml runtime, and the platform bridge for one
/// journal session. Replaces `BonsaiApplicationView` + `BonsaiApplicationBridge`.
@Observable @MainActor final class JournalRuntime {
  enum Failure: String, Error, LocalizedError {
    case start = "runtime.start.failed"
    case patch = "runtime.patch.failed"
    case pump = "runtime.pump.failed"
    case event = "runtime.event.failed"
    case platformEvent = "runtime.platformEvent.failed"
    case platformResponse = "runtime.platformResponse.failed"
    case platformFailure = "runtime.platformFailure.failed"
    case stop = "runtime.stop.failed"
    var errorDescription: String? {
      "Journal could not complete a native operation (\(rawValue)). Retry opening Journal."
    }
  }
  struct FailureDetail: Error, LocalizedError {
    let operation: Failure
    let reason: JournalSafeDiagnostic
    var errorDescription:String? {
      "Journal could not complete a native operation (\(operation.rawValue) · \(reason.rawValue)). \(reason.errorDescription!)"
    }
  }
  private(set) var failureReason: JournalSafeDiagnostic?
  var failureDescription:String? {
    failure.map { FailureDetail(operation:$0,reason:failureReason ?? .unknown).errorDescription! }
  }
  static func safeReason(_ error:Error) -> JournalSafeDiagnostic {
    if case let LUIBackendError.invalidBatch(source) = error { return .backendBatch(source) }
    return .classify(error)
  }
  static func safeDescription(_ error:Error, operation:String) -> String {
    if let error = error as? FailureDetail { return error.errorDescription! }
    let reason = safeReason(error)
    return "Journal could not finish (\(operation) · \(reason.rawValue)). \(reason.errorDescription!)"
  }
  private func record(_ operation:Failure, _ reason:JournalSafeDiagnostic) {
    failure = operation; failureReason = reason
  }
  private func bridgeReason(_ operation:Int32) -> JournalSafeDiagnostic {
    switch journalOCamlFailureReason(operation) {
    case 1: .missingHandler
    case 2: .callbackFailed
    case 3: .allocationFailed
    case 4: .invalidInput
    case 5: .startupDecodeFailed
    case 6: .startupWorkerFailed
    case 7: .startupMountFailed
    default: .unknown
    }
  }
  private var reportedFailure:FailureDetail? {
    failure.map { FailureDetail(operation:$0,reason:failureReason ?? .unknown) }
  }
  let backend: LUIAppleBackend
  let platform: JournalApplicationPlatform
  private let startupPayload: Data
  private(set) var rootID: Int?
  /// Count of patch batches applied from the OCaml runtime (test visibility).
  private(set) var appliedPatches = 0
  private(set) var failure: Failure?
  private var started = false
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var initialPlatformTasks: [Task<Void, Never>] = []
  private var stopPending = false

  init(
    platform: JournalApplicationPlatform,
    startupPayload: Data,
    extensionRegistry: LUIAppleExtensionRegistry
  ) throws {
    self.platform = platform
    self.startupPayload = startupPayload
    do {
      backend = try LUIAppleBackend(appIcons: journalAppIcons, extensionRegistry: extensionRegistry)
    } catch { throw FailureDetail(operation:.start,reason:Self.safeReason(error)) }
    backend.onEvent = { [weak self] event in self?.handle(event) }
  }

  /// Boots the OCaml runtime; the LDB1 startup payload rides inside
  /// `lui_ocaml_start` so init receives it before the worker session begins.
  /// The platform event stream attaches afterwards.
  func start() throws {
    if let reportedFailure { throw reportedFailure }
    guard !started else { return }
    generation = UUID()
    let identity = generation
    platformRequestIngress.begin(identity)
    defer { if !started { platformRequestIngress.close(identity) } }
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
    guard generation == identity else { throw CancellationError() }
    guard accepted == 1 else {
      record(.start,bridgeReason(1))
      let reported = reportedFailure!
      _ = luiOCamlStop()
      activeRuntime = nil
      throw reported
    }
    if let reportedFailure {
      _ = luiOCamlStop()
      activeRuntime = nil
      throw reportedFailure
    }
    guard rootID != nil else {
      _ = luiOCamlStop()
      activeRuntime = nil
      record(.start,.missingRoot)
      throw reportedFailure!
    }
    started = true
    platform.connect(to: self)
    let requests = platformRequestIngress.activate(identity) { [weak self] request in
      Task { @MainActor [weak self] in
        guard let self, self.generation == identity else { return }
        await self.deliverPlatformRequest(request.bytes,receipt:request)
      }
    }
    initialPlatformTasks = requests.map { request in
      Task { @MainActor [weak self] in
        guard let self, self.generation == identity else { return }
        await self.deliverPlatformRequest(request.bytes,receipt:request)
      }
    }
  }

  /// Waits for requests emitted during admission, after native start/connect.
  /// Mounting the root afterwards lets local initialization precede UI work.
  func waitForInitialPlatformRequests() async throws {
    let identity = generation, tasks = initialPlatformTasks
    try await withTaskCancellationHandler {
      for task in tasks { await task.value }
      try Task.checkCancellation()
      guard started, generation == identity else { throw CancellationError() }
      initialPlatformTasks = []
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, self.generation == identity else { return }
        self.stop()
      }
    }
  }

  @discardableResult func stop() -> Bool {
    guard started || stopPending else { return true }
    platformRequestIngress.close(generation)
    generation = UUID()
    for task in initialPlatformTasks { task.cancel() }
    initialPlatformTasks = []
    platform.disconnect()
    started = false
    activeRuntime = nil
    stopPending = luiOCamlStop() != 1
    if stopPending { record(.stop,bridgeReason(2)) }
    return !stopPending
  }

  func apply(json: String) {
    let identity = generation
    do {
      try backend.apply(json: json)
      guard generation == identity else { return }
      rootID = backend.rootIDs.first
      appliedPatches += 1
    } catch {
      guard generation == identity else { return }
      record(.patch,Self.safeReason(error))
    }
  }

  func pump() {
    guard started else { return }
    let identity = generation, accepted = journalOCamlPump()
    if generation == identity, started, accepted != 1 { record(.pump,bridgeReason(3)) }
  }

  /// Marshals one LJP2 request onto the platform actor and ships its response
  /// envelope back through the C entry. Current failure/cancellation completes
  /// the owned continuation via LJF1; nil belongs to retired/suppressed work.
  func deliverPlatformRequest(_ bytes: Data) async {
    await deliverPlatformRequest(bytes,receipt:nil)
  }
  private func deliverPlatformRequest(_ bytes:Data, receipt:JournalPlatformRequestIngress.Request?) async {
    guard started else { return }
    let identity = generation
    func ownsRequest() -> Bool {
      generation == identity && (receipt.map { platformRequestIngress.owns(identity,$0) } ?? true)
    }
    guard ownsRequest() else { return }
    let response = await platform.request(bytes)
    guard started, ownsRequest(), !Task.isCancelled else { return }
    // nil belongs to retired/suppressed work. Current cancellation is an LJF1
    // result and still completes the original continuation without a ledger row.
    guard let response else { return }
    if response.prefix(4) == Data("LJF1".utf8) {
      let accepted = response.withUnsafeBytes { buffer in
        journalOCamlPlatformFailure(buffer.baseAddress?.assumingMemoryBound(to:CChar.self),Int32(buffer.count))
      }
      if generation == identity, started, accepted != 1 { record(.platformFailure,bridgeReason(6)) }
      return
    }
    let accepted = response.withUnsafeBytes { buffer in
      journalOCamlPlatformResponse(
        buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
        Int32(buffer.count))
    }
    if generation == identity, started, accepted != 1 { record(.platformResponse,bridgeReason(5)) }
  }

  /// Pushes one host-originated LJP2 event envelope to OCaml.
  func sendPlatformEvent(_ bytes: Data) {
    guard started else { return }
    let identity = generation
    let accepted = bytes.withUnsafeBytes { buffer in
      journalOCamlPlatformEvent(
        buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
        Int32(buffer.count))
    }
    if generation == identity, started, accepted != 1 { record(.platformEvent,bridgeReason(4)) }
  }

  private func handle(_ event: LUIEvent) {
    guard started else { return }
    let identity = generation, accepted = JournalLUIEvents.dispatch(event)
    if generation == identity, started, accepted != 1 { record(.event,bridgeReason(7)) }
  }
}
