import Amplify
import Foundation
import Observation

/// Terminal prepare-to-terminate exchange, mirroring `BonsaiApplicationShutdown`:
/// the host pushes the event, then completes once OCaml's termination-ready
/// request has been answered, the timeout elapses, or the exchange is cancelled.
@MainActor final class JournalApplicationShutdown {
  enum Outcome: Equatable, Sendable {
    case completed, timedOut, cancelled
  }
  private var outcome: Outcome?
  private var waiters: [CheckedContinuation<Outcome, Never>] = []
  private var timer: Task<Void, Never>?

  init(deadline: ContinuousClock.Instant) {
    timer = Task { [weak self] in
      do { try await ContinuousClock().sleep(until: deadline) } catch { return }
      self?.stop(.timedOut)
    }
  }

  var result: Outcome {
    get async {
      await withTaskCancellationHandler {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
      } onCancel: {
        Task { @MainActor [weak self] in self?.stop(.cancelled) }
      }
    }
  }

  func complete() { stop(.completed) }
  func cancel() { stop(.cancelled) }

  private func stop(_ reason: Outcome) {
    guard outcome == nil else { return }
    outcome = reason
    timer?.cancel()
    timer = nil
    for waiter in waiters { waiter.resume(returning: reason) }
    waiters.removeAll()
  }
}

/// Connects native services to one OCaml runtime without owning graph state.
@Observable @MainActor final class JournalApplicationPlatform {
  private(set) var authenticationRequired = false
  private(set) var localAccountAvailable: Bool?
  @ObservationIgnored private let services: JournalPlatformServices
  @ObservationIgnored private weak var runtime: JournalRuntime?
  @ObservationIgnored private var connection = UUID()
  @ObservationIgnored private var refresh: Task<Void, Never>?
  @ObservationIgnored private var pending = JournalPlatformEvents()
  @ObservationIgnored private var authListener: UnsubscribeToken?
  @ObservationIgnored private var shutdown: JournalApplicationShutdown?
  @ObservationIgnored private var lastEnvironment: JournalEnvironmentSample?
  @ObservationIgnored private(set) var connected = false
  @ObservationIgnored let notices = JournalNotices()
  /// Test observation hooks (apple-tests): every decoded LJP2 request and
  /// each connect/disconnect transition, in delivery order on the main actor.
  @ObservationIgnored var requestObserver: ((JournalPlatformWire.Request) -> Void)?
  @ObservationIgnored var connectionObserver: ((Bool) -> Void)?

  init(services: JournalPlatformServices) { self.services = services }

  /// Attaches the platform to a started runtime; mirrors the old bridge's
  /// `connected` closure.
  func connect(to runtime: JournalRuntime) {
    disconnect()
    self.runtime = runtime
    connected = true
    pending.connect()
    notices.setActive(true)
    connectionObserver?(true)
    observeAuthentication()
    // Re-deliver the latest environment sample after a reconnect.
    let environment = lastEnvironment
    lastEnvironment = nil
    if let environment { pushEnvironment(environment) }
    deliverEvents()
  }

  func disconnect() {
    guard connected || runtime != nil else { return }
    if let authListener { Amplify.Hub.removeListener(authListener) }
    authListener = nil
    connection = UUID()
    refresh?.cancel()
    refresh = nil
    shutdown?.cancel()
    shutdown = nil
    pending.disconnect()
    notices.setActive(false)
    notices.cancelAll()
    connectionObserver?(false)
    connected = false
    runtime = nil
    services.invalidateConnection()
  }

  /// Pushes prepare-to-terminate and resolves once the termination-ready
  /// request round-trips, the timeout passes, or the exchange is cancelled.
  func beginShutdown() -> JournalApplicationShutdown? {
    guard connected, let runtime else { return nil }
    refresh?.cancel()
    pending.beginShutdown()
    let exchange = JournalApplicationShutdown(deadline: .now + .seconds(4))
    shutdown = exchange
    runtime.sendPlatformEvent(JournalPlatformWire.prepareToTerminate())
    return exchange
  }

  /// Answers one LJP2 request envelope; `nil` suppresses the response (the
  /// old bridge surfaced these as request failures).
  func request(_ bytes: Data) async -> Data? {
    let request: JournalPlatformWire.Request
    do {
      request = try JournalPlatformWire.decodeRequest(bytes)
    } catch {
      FileHandle.standardError.write(
        Data("logseq_journal: decodeRequest failed bytes=\(bytes.count)\n".utf8))
      return nil
    }
    requestObserver?(request)
    if request == .signOut {
      refresh?.cancel()
      pending.clearAuthentication()
    }
    if pending.terminating, request != .terminationReady { return nil }
    // Notice requests resolve through the presenter, not platform services.
    switch request {
    case .cancelNotice(let token):
      notices.cancel(token: token)
      return nil
    case .showNotice(let token, let message, let actionLabel, let durationMs):
      let close = await notices.show(
        token: token, message: message, actionLabel: actionLabel,
        durationMs: durationMs)
      guard connected else { return nil }
      return try? JournalPlatformWire.encodeResponse(
        .notice(token: token, result: close.result.rawValue))
    default:
      break
    }
    do {
      let response = try await services.response(for: request)
      guard connected else { return nil }
      switch response {
      case .authenticatedUser(let user): authenticationRequired = user == nil
      case .signedOut:
        authenticationRequired = true
        localAccountAvailable = false
      case .localAccount: localAccountAvailable = true
      case .noLocalAccount: localAccountAvailable = false
      default: break
      }
      let encoded = try JournalPlatformWire.encodeResponse(response)
      if request == .timelinePresented { refreshAuthentication() }
      if request == .terminationReady { shutdown?.complete() }
      return encoded
    } catch JournalPlatformServices.Failure.authenticationRequired {
      authenticationRequired = true
      return nil
    } catch {
      return nil
    }
  }

  /// Called after the first local timeline frame or successful native sign-in.
  func refreshAuthentication() {
    guard !pending.terminating else { return }
    refresh?.cancel()
    let identity = connection
    refresh = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await services.response(for: .authenticatedUser)
        try Task.checkCancellation()
        guard connection == identity, connected else { return }
        if case .authenticatedUser(let user) = response { authenticationRequired = user == nil }
        pending.authenticated(try JournalPlatformWire.encodeResponse(response))
        deliverEvents()
      } catch JournalPlatformServices.Failure.authenticationRequired {
        if connection == identity { authenticationRequired = true }
      } catch {
        // A failed online lookup does not invalidate the restored offline graph.
      }
    }
  }

  func setBackgrounded(_ backgrounded: Bool) throws {
    try pending.setBackgrounded(backgrounded)
    deliverEvents()
  }

  /// Pushes the latest host environment sample (LJP2 tag 24) once it changes.
  func pushEnvironment(_ sample: JournalEnvironmentSample) {
    guard connected, sample != lastEnvironment else { return }
    guard let data = try? JournalPlatformWire.environment(sample.jsonObject())
    else { return }
    lastEnvironment = sample
    runtime?.sendPlatformEvent(data)
  }

  /// The lui channel has no backpressure: pending envelopes drain inline in
  /// order, matching the ordering the old bounded send loop maintained.
  private func deliverEvents() {
    guard let runtime else { return }
    while let payload = pending.next {
      runtime.sendPlatformEvent(payload)
      pending.accepted(payload)
    }
  }

  private func observeAuthentication() {
    if let authListener { Amplify.Hub.removeListener(authListener) }
    let identity = connection
    authListener = Amplify.Hub.listen(to: .auth) { @Sendable [weak self] payload in
      guard [HubPayload.EventName.Auth.signedIn, HubPayload.EventName.Auth.signedOut,
             HubPayload.EventName.Auth.sessionExpired, HubPayload.EventName.Auth.userDeleted]
        .contains(payload.eventName) else { return }
      Task { @MainActor [weak self] in
        guard let self, connection == identity else { return }
        refreshAuthentication()
      }
    }
  }
}
