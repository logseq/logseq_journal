import Foundation
import LUIAppleBackend
import Observation
import OSLog

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

/// Owns the native connection for the SwiftUI host's structural lifetime.
/// A system fullscreen preview can hide the host without removing this owner.
@Observable @MainActor final class JournalRuntimeLifetime {
  var runtime: JournalRuntime?
  var startingRuntime: JournalRuntime?

  isolated deinit {
    runtime?.stop()
    startingRuntime?.stop()
  }
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
private typealias FilterCommitCallback = @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32
@_silgen_name("journal_ocaml_set_filter_commit_callback")
private func journalOCamlSetFilterCommitCallback(_ callback: FilterCommitCallback?)

private let filterCommit: FilterCommitCallback = { data, length in
  guard Thread.isMainThread, let data, length > 0 else { return 0 }
  let request = Data(bytes: data, count: Int(length))
  return MainActor.assumeIsolated {
    guard activeRuntime != nil else { return 0 }
    return JournalTimelineFilterPreferences(defaults: .standard).handleCommit(request) ? 1 : 0
  }
}

private let platformRequestIngress = JournalPlatformRequestIngress()
private let platformRequest: PlatformRequestCallback = { data, length in
  guard let data, length > 0 else { return }
  let request = Data(bytes: data, count: Int(length))
  platformRequestIngress.submit(request)
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
      "Journal could not complete a native operation (\(rawValue))."
    }
  }
  /// Finite startup cause codes supplied by Journal_bridge. Never native text.
  enum StartupCause: Int, Sendable {
    case unknown = 0, startupPayloadTruncated, startupPayloadTooLarge, startupMagicInvalid
    case startupLengthInvalid, startupLengthMismatch, startupJSONInvalid
    case supportDirectoryInvalid, responseBudgetInvalid, pageSizeInvalid, syncOriginInvalid
    case configurationInvalid, exceptionFailure, invalidArgument, systemError
    case permissionDenied, missingFile, noSpace, busy, ioError, unixError
    case outOfMemory, stackOverflow, endOfFile, matchFailure, assertionFailure, notFound
    case mountRejected, workerStopped, workerTerminal, workerAlreadyAttached, workerDidNotStart
    var diagnostic: String { String(describing: self) }
  }
  struct FailureDetail: Error, LocalizedError {
    let operation: Failure
    let reason: JournalSafeDiagnostic
    var cause: StartupCause? = nil
    var errorDescription:String? {
      "Journal could not complete a native operation (\(operation.rawValue) · \(reason.rawValue)\(cause.map { " · cause.\($0.diagnostic)" } ?? "")). \(reason.errorDescription!)"
    }
  }
  private(set) var failureReason: JournalSafeDiagnostic?
  private(set) var failureCause: StartupCause?
  var failureDescription:String? {
    failure.map { FailureDetail(operation:$0,reason:failureReason ?? .unknown,cause:failureCause).errorDescription! }
  }
  static func safeReason(_ error:Error) -> JournalSafeDiagnostic {
    if case JournalPlatformWire.Failure.invalidPacket = error { return .invalidPayload }
    if case let LUIBackendError.invalidBatch(source) = error { return .backendBatch(source) }
    return .classify(error)
  }
  static func safeDescription(_ error:Error, operation:String) -> String {
    if let error = error as? FailureDetail { return error.errorDescription! }
    let reason = safeReason(error)
    return "Journal could not finish (\(operation) · \(reason.rawValue)). \(reason.errorDescription!)"
  }
  private func record(_ operation:Failure, _ reason:JournalSafeDiagnostic) {
    failure = operation; failureReason = reason; failureCause = nil
  }
  private func recordBridge(_ failure: Failure, _ operation: Int32) {
    let code = journalOCamlFailureReason(operation)
    let reason: JournalSafeDiagnostic
    switch code {
    case 1: reason = .missingHandler
    case 2: reason = .callbackFailed
    case 3: reason = .allocationFailed
    case 4: reason = .invalidInput
    case 5, 500...531: reason = .startupDecodeFailed
    case 6, 600...631: reason = .startupWorkerFailed
    case 7: reason = .startupMountFailed
    case 700...731: reason = .startupInitializeFailed
    default: reason = .unknown
    }
    record(failure, reason)
    if (500...531).contains(code) || (600...631).contains(code) || (700...731).contains(code) {
      failureCause = StartupCause(rawValue: Int(code % 100))
    }
  }

  private var reportedFailure:FailureDetail? {
    failure.map { FailureDetail(operation:$0,reason:failureReason ?? .unknown,cause:failureCause) }
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

  @ObservationIgnored private var startUptime: TimeInterval = 0
  @ObservationIgnored private var startupTimelinePresented = false
  @ObservationIgnored private var startupContentReady = false
  @ObservationIgnored private var startupContentContinuations: [CheckedContinuation<Void, Never>] = []
  private static let startupLogger = Logger(subsystem: "com.logseq.journal", category: "startup")

  private static func platformRequestKind(_ bytes: Data) -> String {
    guard let decoded = try? JournalPlatformWire.decodeRequest(bytes) else { return "unknown" }
    switch decoded {
    case .authenticatedUser: return "authenticatedUser"
    case .signOut: return "signOut"
    case .terminationReady: return "terminationReady"
    case .localAccount: return "localAccount"
    case .timelinePresented: return "timelinePresented"
    case .onlineRequested: return "onlineRequested"
    case .onlineCancelled: return "onlineCancelled"
    case .idToken: return "idToken"
    case .copyText: return "copyText"
    }
  }

  /// Boots the OCaml runtime; the LDB1 startup payload rides inside
  /// `lui_ocaml_start` so init receives it before the worker session begins.
  /// The platform event stream attaches afterwards.
  func start() throws {
    if let reportedFailure { throw reportedFailure }
    guard !started else { return }
    let t0 = ProcessInfo.processInfo.systemUptime
    startUptime = t0
    startupTimelinePresented = false
    startupContentReady = false
    resumeStartupContentWaiters()
    generation = UUID()
    let identity = generation
    platformRequestIngress.begin(identity)
    defer { if !started { platformRequestIngress.close(identity) } }
    journalOCamlSetWakeupCallback(wakeup)
    journalOCamlSetPlatformRequestCallback(platformRequest)
    journalOCamlSetFilterCommitCallback(filterCommit)
    activeRuntime = self
    #if os(macOS)
    let operatingSystem: Int32 = 1
    #else
    let operatingSystem: Int32 = 2
    #endif
    let payload = JournalTimelineFilterPreferences(defaults: .standard).wrapStartup(startupPayload)
    let accepted = payload.withUnsafeBytes { bytes in
      luiOCamlStart(
        receivePatch,
        operatingSystem,
        2,
        bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
        Int32(bytes.count))
    }
    guard generation == identity else { throw CancellationError() }
    guard accepted == 1 else {
      recordBridge(.start,1)
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
    let tOcaml = ProcessInfo.processInfo.systemUptime
    Self.startupLogger.info("journal-startup stage=runtime.ocaml_start.done elapsed_ms=\(Int(((tOcaml - t0) * 1000).rounded()), privacy: .public) initial_patches=\(self.appliedPatches, privacy: .public)")
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
    let tActivate = ProcessInfo.processInfo.systemUptime
    Self.startupLogger.info("journal-startup stage=runtime.platform_ingress.activated elapsed_ms=\(Int(((tActivate - tOcaml) * 1000).rounded()), privacy: .public) initial_requests=\(requests.count, privacy: .public)")
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

  /// Waits briefly for the initial timeline tree to land in the backend before
  /// mounting `LUISwiftUIRoot` so SwiftUI does not starve `@MainActor` worker
  /// pumps while laying out an intermediate loading surface.
  func waitForStartupContent(timeoutMilliseconds: Int = 200) async throws {
    if startupContentReady { return }
    let identity = generation
    let timeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
      guard let self, self.generation == identity else { return }
      self.resumeStartupContentWaiters()
    }
    defer { timeoutTask.cancel() }
    try await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if startupContentReady || !started || generation != identity {
          continuation.resume()
        } else {
          startupContentContinuations.append(continuation)
        }
      }
      try Task.checkCancellation()
      guard started, generation == identity else { throw CancellationError() }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, self.generation == identity else { return }
        self.resumeStartupContentWaiters()
      }
    }
  }

  private func resumeStartupContentWaiters() {
    let waiters = startupContentContinuations
    startupContentContinuations = []
    for waiter in waiters { waiter.resume() }
  }

  @discardableResult func stop() -> Bool {
    guard started || stopPending else { return true }
    platformRequestIngress.close(generation)
    generation = UUID()
    resumeStartupContentWaiters()
    for task in initialPlatformTasks { task.cancel() }
    initialPlatformTasks = []
    platform.disconnect()
    started = false
    activeRuntime = nil
    stopPending = luiOCamlStop() != 1
    if stopPending { recordBridge(.stop,2) }
    return !stopPending
  }

  func apply(json: String) {
    let identity = generation
    let t0 = ProcessInfo.processInfo.systemUptime
    do {
      try backend.apply(json: json)
      guard generation == identity else { return }
      rootID = backend.rootIDs.first
      appliedPatches += 1
      if !startupContentReady && appliedPatches >= 2 && json.contains("\"journal-list\"") {
        startupContentReady = true
        resumeStartupContentWaiters()
      }
      let t1 = ProcessInfo.processInfo.systemUptime
      let elapsedMs = Int(((t1 - t0) * 1000).rounded())
      if !startupTimelinePresented && (elapsedMs >= 2 || json.utf8.count >= 4096) {
        let sinceStartMs = Int(((t1 - startUptime) * 1000).rounded())
        Self.startupLogger.info("journal-startup stage=runtime.apply_patch patch=\(self.appliedPatches, privacy: .public) bytes=\(json.utf8.count, privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public) since_start_ms=\(sinceStartMs, privacy: .public)")
      }
    } catch {
      guard generation == identity else { return }
      record(.patch,Self.safeReason(error))
    }
  }

  func pump() {
    guard started else { return }
    let t0 = ProcessInfo.processInfo.systemUptime
    let identity = generation, accepted = journalOCamlPump()
    let t1 = ProcessInfo.processInfo.systemUptime
    let elapsedMs = Int(((t1 - t0) * 1000).rounded())
    if !startupTimelinePresented && elapsedMs >= 2 {
      let sinceStartMs = Int(((t1 - startUptime) * 1000).rounded())
      Self.startupLogger.info("journal-startup stage=runtime.pump elapsed_ms=\(elapsedMs, privacy: .public) since_start_ms=\(sinceStartMs, privacy: .public)")
    }
    if generation == identity, started, accepted != 1 { recordBridge(.pump,3) }
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
    let kind = Self.platformRequestKind(bytes)
    let reqStart = ProcessInfo.processInfo.systemUptime
    let response = await platform.request(bytes)
    let reqEnd = ProcessInfo.processInfo.systemUptime
    let elapsedMs = Int(((reqEnd - reqStart) * 1000).rounded())
    if !startupTimelinePresented || elapsedMs >= 20 {
      let sinceStartMs = Int(((reqEnd - startUptime) * 1000).rounded())
      Self.startupLogger.info("journal-startup stage=runtime.platform_request kind=\(kind, privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public) since_start_ms=\(sinceStartMs, privacy: .public)")
    }
    if kind == "timelinePresented" { startupTimelinePresented = true }
    guard started, ownsRequest(), !Task.isCancelled else { return }
    // nil belongs to retired/suppressed work. Current cancellation is an LJF1
    // result and still completes the original continuation without a ledger row.
    guard let response else { return }
    if response.prefix(4) == Data("LJF1".utf8) {
      let accepted = response.withUnsafeBytes { buffer in
        journalOCamlPlatformFailure(buffer.baseAddress?.assumingMemoryBound(to:CChar.self),Int32(buffer.count))
      }
      if generation == identity, started, accepted != 1 { recordBridge(.platformFailure,6) }
      return
    }
    let accepted = response.withUnsafeBytes { buffer in
      journalOCamlPlatformResponse(
        buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
        Int32(buffer.count))
    }
    if generation == identity, started, accepted != 1 { recordBridge(.platformResponse,5) }
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
    if generation == identity, started, accepted != 1 { recordBridge(.platformEvent,4) }
  }

  private func handle(_ event: LUIEvent) {
    guard started else { return }
    let identity = generation, accepted = JournalLUIEvents.dispatch(event)
    if generation == identity, started, accepted != 1 { recordBridge(.event,7) }
  }
}
