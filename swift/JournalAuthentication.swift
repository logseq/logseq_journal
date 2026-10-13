import Foundation
import Observation

@MainActor protocol JournalAuthenticationAPI {
  func signIn() async throws
  func cancelSignIn()
  func prepareAccount() async throws
  var accountPreparationMessage: String? { get }
}
extension JournalAuthenticationAPI {
  func prepareAccount() async throws { }
  var accountPreparationMessage: String? { nil }
}

/// Connects browser authentication to account preparation without owning graphs.
@MainActor struct JournalPreparedAuthentication: JournalAuthenticationAPI {
  let api: any JournalAuthenticationAPI
  let prepare: () async throws -> Void
  var cancelPreparation: () -> Void = { }
  var preparationMessage: () -> String? = { nil }
  var accountPreparationMessage: String? { preparationMessage() }
  func signIn() async throws { try await api.signIn() }
  func cancelSignIn() { api.cancelSignIn(); cancelPreparation() }
  func prepareAccount() async throws { try await prepare() }
}
@Observable @MainActor final class JournalAuthentication {
  private(set) var complete = false
  private(set) var busy = false
  private(set) var message: String?
  @ObservationIgnored private let api: any JournalAuthenticationAPI
  @ObservationIgnored private var revision: UInt64 = 0
  init(api: any JournalAuthenticationAPI) { self.api = api }
  var canSubmit: Bool { !busy && !complete }
  func submit() async {
    guard canSubmit else { return }
    let version = revision
    var preparing = false
    busy = true; message = nil
    defer { if revision == version { busy = false } }
    do {
      try await api.signIn()
      try Task.checkCancellation()
      guard revision == version else { return }
      preparing = true
      try await api.prepareAccount()
      try Task.checkCancellation()
      if revision == version { complete = true }
    } catch is CancellationError { }
    catch {
      if revision == version {
        let fallback = error is URLError
          ? "Unable to connect to sign-in. Please try again."
          : "Unable to complete your account connection. Please try again."
        message = preparing ? (api.accountPreparationMessage ?? fallback) : fallback
      }
    }
  }
  func cancel() {
    revision &+= 1
    if busy { api.cancelSignIn() }
    busy = false; message = nil; complete = false
  }
}
