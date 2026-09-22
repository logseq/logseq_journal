import Amplify
import BonsaiSwiftUI
import Foundation
import Observation

/// Connects native services to one OCaml runtime without owning graph state.
@Observable @MainActor final class JournalApplicationPlatform {
  private(set) var authenticationRequired = false
  private(set) var localAccountAvailable: Bool?
  @ObservationIgnored private let services: JournalPlatformServices
  @ObservationIgnored private var events: BonsaiApplicationEvents?
  @ObservationIgnored private var connection = UUID()
  @ObservationIgnored private var refresh: Task<Void, Never>?
  @ObservationIgnored private var delivery: Task<Void, Never>?
  @ObservationIgnored private var pending = JournalPlatformEvents()
  @ObservationIgnored private var authListener: UnsubscribeToken?

  init(services: JournalPlatformServices) { self.services = services }

  var bridge: BonsaiApplicationBridge {
    BonsaiApplicationBridge(
      request: { [self] bytes in try await request(bytes) },
      connected: { [self] sender in
        events = sender
        pending.connect()
        observeAuthentication()
        deliverEvents()
      },
      disconnected: { [self] in disconnect() })
  }

  func beginShutdown() throws -> BonsaiApplicationShutdown? {
    guard let events else { return nil }
    refresh?.cancel()
    delivery?.cancel()
    pending.beginShutdown()
    return try events.beginShutdown(
      event: JournalPlatformWire.prepareToTerminate(), timeout: .seconds(4),
      accepting: { (try? JournalPlatformWire.decodeRequest($0)) == .terminationReady },
      request: { _ in .finish(try JournalPlatformWire.encodeResponse(.terminationReady)) })
  }

  private func request(_ bytes: Data) async throws -> Data {
    let request = try JournalPlatformWire.decodeRequest(bytes)
    if request == .signOut {
      refresh?.cancel()
      pending.clearAuthentication()
    }
    do {
      let response = try await services.response(for: request)
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
      return encoded
    } catch JournalPlatformServices.Failure.authenticationRequired {
      authenticationRequired = true
      throw BonsaiApplicationError.unavailable
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
        guard connection == identity, events != nil else { return }
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

  private func deliverEvents() {
    guard delivery == nil else { return }
    let identity = connection
    delivery = Task { [weak self] in
      guard let self else { return }
      defer { if connection == identity { delivery = nil } }
      while connection == identity, !Task.isCancelled,
            let sender = events, let payload = pending.next {
        do {
          try sender.send(payload)
          pending.accepted(payload)
        } catch BonsaiApplicationEvents.SendError.backpressure {
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        } catch {
          pending.disconnect()
          return
        }
      }
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

  private func disconnect() {
    if let authListener { Amplify.Hub.removeListener(authListener) }
    authListener = nil
    connection = UUID()
    refresh?.cancel()
    delivery?.cancel()
    refresh = nil
    delivery = nil
    pending.disconnect()
    events = nil
    services.invalidateConnection()
  }
}
