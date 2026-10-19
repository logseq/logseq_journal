import Foundation

/// Only bounded diagnostic metadata crosses the native account boundary.
struct JournalAccountIssue: Error, Equatable, Sendable, LocalizedError {
  enum Kind: String { case unsupportedFormat, corruptBinding, secureStorageUnavailable, network, signInRequired, accountChangeBlocked, unavailable }
  enum Stage: String { case bindingRead, bindingWrite, identityLookup }
  let kind: Kind
  let stage: Stage
  var formatVersion: Int? = nil
  var rejectsBinding: Bool { kind == .unsupportedFormat || kind == .corruptBinding }
  var offersSignIn: Bool { rejectsBinding || kind == .signInRequired || kind == .accountChangeBlocked || kind == .unavailable }
  var diagnostic: String {
    "account.\(stage.rawValue).\(kind.rawValue)"
      + (formatVersion.map { " · format \($0)" } ?? "")
  }
  var errorDescription: String? {
    switch kind {
    case .unsupportedFormat: "This app cannot read the saved account format. Sign in again to reconnect your account."
    case .corruptBinding: "The saved account connection cannot be read. Sign in again to reconnect your account."
    case .secureStorageUnavailable: "Secure account storage is unavailable. Unlock your device, then retry."
    case .network: "Unable to connect to your account. Check your connection, then retry."
    case .signInRequired: "Sign in again to connect your account."
    case .accountChangeBlocked: "This session has a local graph open. Sign in to the original account to finish pending work before changing accounts."
    case .unavailable: "Unable to prepare your account. Retry, or reopen sign-in."
    }
  }
  static func classify(_ error: Error, stage: Stage) -> Self {
    if let issue = error as? Self { return issue }
    if case JournalPlatformServices.Failure.invalidBinding = error {
      return Self(kind: .corruptBinding, stage: stage)
    }
    if error is URLError { return Self(kind: .network, stage: stage) }
    let native = error as NSError
    if native.domain == NSOSStatusErrorDomain {
      return Self(kind: .secureStorageUnavailable, stage: stage)
    }
    return Self(kind: .unavailable, stage: stage)
  }
}

@MainActor protocol JournalAuthCapability {
  func currentUserID() async throws -> String?
  func freshIDToken() async throws -> String
  func signOut() async throws
  func cancelNetworkOperations()
}

extension JournalAuthCapability {
  func cancelNetworkOperations() {}
}

struct JournalLocalAccount: Equatable, Sendable {
  let userID: String
  let managedSyncOrigin: String
}

@MainActor struct JournalAccountStore {
  let load: () async throws -> JournalLocalAccount?
  // Isolate the proposal from reads/other writes until its decision. Rejection
  // restores the exact previous record; failed restoration must fail closed.
  let save: (JournalLocalAccount) async throws -> JournalAccountSave
  let clear: () async throws -> Void
}

/// A proposed write remains isolated until the account owner accepts or undoes it.
@MainActor final class JournalAccountSave {
  private var commit: (() -> Void)?
  private var rollback: (() async throws -> Void)?
  init(commit: @escaping () -> Void, rollback: @escaping () async throws -> Void) {
    self.commit = commit; self.rollback = rollback
  }
  func accept() {
    let action = commit
    commit = nil; rollback = nil
    action?()
  }
  func reject() async throws {
    let action = rollback
    commit = nil; rollback = nil
    try await action?()
  }
}

/// Serializes complete proposals, including their admission/undo, without parking UI.
@MainActor final class JournalAccountStoreAccess {
  @MainActor private final class Lease {
    var released = false
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
      if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
  }
  private var tail: Task<Void, Never>?
  func acquire(respectCancellation: Bool = true) async throws -> () -> Void {
    let previous = tail, lease = Lease()
    tail = Task { if let previous { await previous.value }; await lease.wait() }
    if let previous { await previous.value }
    do { if respectCancellation { try Task.checkCancellation() } }
    catch { lease.release(); throw error }
    return { lease.release() }
  }
}

/// Native capabilities behind the existing OCaml application protocol.
@MainActor final class JournalPlatformServices {
  enum Failure: Error { case authenticationRequired, unavailable, invalidBinding }
  let auth: any JournalAuthCapability
  let account: JournalAccountStore
  let managedSyncOrigin: String
  private(set) var timelinePresented = false
  private(set) var onlineAllowed = false
  private var authenticationGeneration: UInt64 = 0
  private var signingOut = false
  private(set) var accountIssue: JournalAccountIssue?
  private var preparedUserID: String?

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
      let binding: JournalLocalAccount?
      do { binding = try await localAccount() }
      catch {
        try validateCompletion(generation)
        accountIssue = .classify(error, stage: .bindingRead)
        throw error
      }
      try validateCompletion(generation)
      if accountIssue?.stage == .bindingRead { accountIssue = nil }
      guard let binding else { return .noLocalAccount }
      preparedUserID = binding.userID
      return .localAccount(userID: binding.userID, origin: binding.managedSyncOrigin)
    case .onlineRequested:
      onlineAllowed = true
      return .onlineRequested
    case .onlineCancelled:
      if onlineAllowed { authenticationGeneration &+= 1; auth.cancelNetworkOperations() }
      onlineAllowed = false
      return .onlineCancelled
    case .timelinePresented:
      onlineAllowed = true
      timelinePresented = true
      return .timelinePresented
    case .authenticatedUser:
      let generation = authenticationGeneration
      try await admitAuthentication(generation)
      var binding: JournalLocalAccount?
      var bindingFailure: Error?
      do { binding = try await localAccount() }
      catch { bindingFailure = error }
      try validateCompletion(generation)
      if let failure = bindingFailure { accountIssue = .classify(failure, stage: .bindingRead) }
      // A rejected advisory record is never an identity authority. OAuth still
      // verifies the current account; inaccessible storage is never overwritten.
      let user: String?
      do { user = try await auth.currentUserID() }
      catch {
        try validateCompletion(generation)
        if !(error is CancellationError) {
          if case Failure.authenticationRequired = error {
            if accountIssue?.rejectsBinding != true {
              accountIssue = JournalAccountIssue(kind: .signInRequired, stage: .identityLookup)
            }
          } else { accountIssue = .classify(error, stage: .identityLookup) }
        }
        throw error
      }
      try validateCompletion(generation)
      if let failure = bindingFailure,
         !JournalAccountIssue.classify(failure, stage: .bindingRead).rejectsBinding { throw failure }
      if let user {
        try validateGraphAccount(user)
        let response = JournalPlatformWire.Response.authenticatedUser(user)
        _ = try JournalPlatformWire.encodeResponse(response)
        let proposal: JournalAccountSave?
        do {
          proposal = try await account.save(JournalLocalAccount(userID: user, managedSyncOrigin: managedSyncOrigin))
        } catch {
          try validateCompletion(generation)
          accountIssue = .classify(error, stage: .bindingWrite)
          // A rebuild must commit before recovery is reported complete. Existing
          // valid bindings remain advisory and preserve normal online behavior.
          if bindingFailure != nil { throw error }
          proposal = nil
        }
        do {
          try validateCompletion(generation)
          try validateGraphAccount(user)
        } catch {
          // Keep the proposal isolated until its exact previous bytes are restored.
          // Never publish this identity or clear an error from a newer generation.
          do { try await proposal?.reject() }
          catch {
            try validateCompletion(generation)
            accountIssue = .classify(error, stage: .bindingWrite)
            throw error
          }
          throw error
        }
        proposal?.accept()
        if proposal != nil { accountIssue = nil }
        preparedUserID = user
        return response
      }
      // Absence of a new SDK session is not an explicit account sign-out.
      if binding != nil || bindingFailure != nil || preparedUserID != nil || timelinePresented {
        if bindingFailure == nil { accountIssue = JournalAccountIssue(kind: .signInRequired, stage: .identityLookup) }
        throw Failure.authenticationRequired
      }
      accountIssue = nil
      return .authenticatedUser(nil)
    case .idToken(let challenge):
      let generation = authenticationGeneration
      try await admitAuthentication(generation)
      if timelinePresented {
        let user = try await auth.currentUserID()
        try validateCompletion(generation)
        guard let user else { throw Failure.authenticationRequired }
        try validateGraphAccount(user)
      }
      let token = try await auth.freshIDToken()
      try validateCompletion(generation)
      // Startup can present its retained graph while token retrieval suspends.
      // Admit the latest graph account before releasing this token to the worker.
      if timelinePresented {
        let user = try await auth.currentUserID()
        try validateCompletion(generation)
        guard let user else { throw Failure.authenticationRequired }
        try validateGraphAccount(user)
      }
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
      timelinePresented = false
      onlineAllowed = false
      preparedUserID = nil
      accountIssue = nil
      return .signedOut
    case .terminationReady:
      return .terminationReady
    case .copyText:
      // Clipboard requests are intercepted by JournalApplicationPlatform before
      // reaching services.
      throw Failure.unavailable
    }
  }

  func invalidateConnection() {
    auth.cancelNetworkOperations()
    authenticationGeneration &+= 1
    timelinePresented = false
    onlineAllowed = false
    preparedUserID = nil
  }
  func cancelAuthenticationPreparation() {
    auth.cancelNetworkOperations()
    authenticationGeneration &+= 1
    onlineAllowed = false
  }

  private func validateGraphAccount(_ user: String) throws {
    if timelinePresented, let current = preparedUserID, current != user {
      let issue = JournalAccountIssue(kind: .accountChangeBlocked, stage: .identityLookup)
      accountIssue = issue
      throw issue
    }
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
    guard onlineAllowed else { throw Failure.unavailable }
    // Account binding is advisory; native credentials remain independently usable.
    try validateCompletion(generation)
  }

  private func validateCompletion(_ generation: UInt64) throws {
    try Task.checkCancellation()
    guard generation == authenticationGeneration, !signingOut else { throw CancellationError() }
  }
}
