import Foundation
import Observation

@MainActor protocol JournalAuthenticationAPI {
  func signIn() async throws
  func cancelSignIn()
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
    busy = true; message = nil
    defer { if revision == version { busy = false } }
    do {
      try await api.signIn()
      try Task.checkCancellation()
      if revision == version { complete = true }
    } catch is CancellationError { }
    catch is URLError {
      if revision == version { message = "Unable to connect to sign-in. Please try again." }
    }
    catch { if revision == version { message = error.localizedDescription } }
  }
  func cancel() {
    revision &+= 1; api.cancelSignIn()
    busy = false; message = nil; complete = false
  }
}
