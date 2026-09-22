import Foundation

@MainActor protocol JournalAuthCapability {
  func currentUserID() async throws -> String?
  func freshIDToken() async throws -> String
  func signOut() async throws
}

struct JournalLocalAccount: Equatable, Sendable {
  let userID: String
  let managedSyncOrigin: String
}

@MainActor struct JournalAccountStore {
  let load: () async throws -> JournalLocalAccount?
  let save: (JournalLocalAccount) async throws -> Void
  let clear: () async throws -> Void
}

/// Native capabilities behind the existing OCaml application protocol.
@MainActor final class JournalPlatformServices {
  enum Failure: Error { case authenticationRequired, unavailable, invalidBinding }
  let auth: any JournalAuthCapability
  let account: JournalAccountStore
  let managedSyncOrigin: String
  private(set) var timelinePresented = false
  private var authenticationGeneration: UInt64 = 0
  private var signingOut = false

  init(auth: any JournalAuthCapability, account: JournalAccountStore,
       managedSyncOrigin: String) {
    self.auth = auth
    self.account = account
    self.managedSyncOrigin = managedSyncOrigin
  }

  func response(for request: JournalPlatformWire.Request) async throws -> JournalPlatformWire.Response {
    switch request {
    case .localAccount:
      let generation = authenticationGeneration
      let binding = try await localAccount()
      try validateCompletion(generation)
      guard let binding else { return .noLocalAccount }
      return .localAccount(userID: binding.userID, origin: binding.managedSyncOrigin)
    case .timelinePresented:
      timelinePresented = true
      return .timelinePresented
    case .authenticatedUser:
      let generation = authenticationGeneration
      try await admitAuthentication(generation)
      let user = try await auth.currentUserID()
      try validateCompletion(generation)
      if let user {
        let response = JournalPlatformWire.Response.authenticatedUser(user)
        _ = try JournalPlatformWire.encodeResponse(response)
        // This advisory binding must not prevent online reconciliation.
        try? await account.save(JournalLocalAccount(userID: user, managedSyncOrigin: managedSyncOrigin))
        try validateCompletion(generation)
        return response
      }
      // Absence of a new SDK session is not an explicit account sign-out.
      let binding = try await localAccount()
      try validateCompletion(generation)
      if binding != nil { throw Failure.authenticationRequired }
      return .authenticatedUser(nil)
    case .idToken(let challenge):
      let generation = authenticationGeneration
      try await admitAuthentication(generation)
      let token = try await auth.freshIDToken()
      try validateCompletion(generation)
      let response = JournalPlatformWire.Response.idToken(challengeID: challenge, token: token)
      _ = try JournalPlatformWire.encodeResponse(response)
      return response
    case .signOut:
      guard !signingOut else { throw Failure.unavailable }
      authenticationGeneration &+= 1
      signingOut = true
      defer { signingOut = false }
      try await auth.signOut()
      // Once native sign-out succeeds, finish its local cleanup even if the
      // requesting runtime has gone away. The bridge fences the eventual reply.
      try await account.clear()
      return .signedOut
    case .terminationReady:
      return .terminationReady
    }
  }

  func invalidateConnection() {
    authenticationGeneration &+= 1
    timelinePresented = false
  }

  private func localAccount() async throws -> JournalLocalAccount? {
    guard let binding = try await account.load() else { return nil }
    guard binding.managedSyncOrigin == managedSyncOrigin else { throw Failure.invalidBinding }
    _ = try JournalPlatformWire.encodeResponse(
      .localAccount(userID: binding.userID, origin: binding.managedSyncOrigin))
    return binding
  }

  private func admitAuthentication(_ generation: UInt64) async throws {
    try Task.checkCancellation()
    guard !signingOut else { throw Failure.unavailable }
    // OCaml owns whether startup can present a graph or needs online recovery.
    // A binding alone cannot establish that a timeline frame will ever arrive.
    _ = try await localAccount()
    try validateCompletion(generation)
  }

  private func validateCompletion(_ generation: UInt64) throws {
    try Task.checkCancellation()
    guard generation == authenticationGeneration, !signingOut else { throw CancellationError() }
  }
}
