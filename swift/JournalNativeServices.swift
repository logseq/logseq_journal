import Foundation
import OSLog

@MainActor enum JournalNativeServices {
  static let managedSyncOrigin = "https://api.logseq.io"

  static func makePlatformServices() -> JournalPlatformServices {
    let storage = JournalNativeAccountStorage()
    return JournalPlatformServices(
      auth: JournalCognitoNative.shared,
      account: JournalAccountStore(
        load: { try await storage.load() },
        save: { try await storage.save($0) },
        clear: { try await storage.clear() }),
      managedSyncOrigin: managedSyncOrigin)
  }

  static func startupPayload() throws -> Data {
    let manager = FileManager.default
    let support = try manager.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    // The existing Apple host uses this directory directly, without a suffix.
    let canonical = support.resolvingSymlinksInPath().path
    return try JournalStartupConfiguration.encode(
      applicationSupportPath: canonical, managedSyncOrigin: managedSyncOrigin)
  }
}

/// Keychain can wait for system authorization. Serialize its blocking calls
/// outside MainActor, including a pending save followed by sign-out cleanup.
private final class JournalNativeAccountStorage: Sendable {
  private let queue = DispatchQueue(label: "com.logseq.journal.account-storage")
  @MainActor private static let access = JournalAccountStoreAccess()
  private struct Recovery: Codable, Sendable {
    let version: Int
    let id: UUID
    let previous: Data?
    let replacement: Data
  }
  // Acceptance is only a cache. Loss of it conservatively undoes the advisory
  // binding on cold access; original bytes remain protected in Keychain.
  @MainActor private static var acceptedRecovery: UUID?

  private func perform<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result(catching: operation)) }
    }
  }

  @MainActor func load() async throws -> JournalLocalAccount? {
    let release = try await Self.access.acquire()
    defer { release() }
    try await repairIfNeeded()
    return try await perform {
      guard let value = try JournalLocalAccountBindingStore.load() else { return nil }
      guard let userID = value["userId"] as? String,
            let origin = value["managedSyncOrigin"] as? String else {
        throw JournalPlatformServices.Failure.invalidBinding
      }
      return JournalLocalAccount(userID: userID, managedSyncOrigin: origin)
    }
  }

  @MainActor func save(_ binding: JournalLocalAccount) async throws -> JournalAccountSave {
    let release = try await Self.access.acquire()
    do {
      try await repairIfNeeded()
      let previous = try await perform { try JournalLocalAccountBindingStore.loadData() }
      try Task.checkCancellation()
      let replacement = try JournalLocalAccountBindingStore.encode(
        userID: binding.userID, managedSyncOrigin: binding.managedSyncOrigin)
      let recovery = Recovery(version: 1, id: UUID(), previous: previous, replacement: replacement)
      let journal = try JSONEncoder().encode(recovery)
      // Persist undo information BEFORE touching the canonical binding.
      try await perform { try JournalLocalAccountBindingStore.writeRecoveryData(journal) }
      try await perform { try JournalLocalAccountBindingStore.writeData(replacement) }
      return JournalAccountSave(commit: {
        Self.acceptedRecovery = recovery.id
        release()
        // Cleanup is not the safety boundary: a crash before it conservatively
        // restores the durable snapshot. Try promptly, without blocking UI.
        Task { @MainActor in
          let done = try await Self.access.acquire(respectCancellation: false)
          defer { done() }
          if Self.acceptedRecovery == recovery.id {
            do { try await self.repairIfNeeded() }
            catch {
              Logger(subsystem: "com.logseq.journal", category: "account")
                .error("Account binding cleanup is pending (account.bindingCleanup.failed)")
            }
          }
        }
      }, rollback: {
        defer { release() }
        try await self.repairIfNeeded()
      })
    } catch {
      release()
      throw error
    }
  }

  @MainActor private func repairIfNeeded() async throws {
    guard let bytes = try await perform({ try JournalLocalAccountBindingStore.loadRecoveryData() }) else {
      Self.acceptedRecovery = nil
      return
    }
    let recovery: Recovery
    do {
      recovery = try JSONDecoder().decode(Recovery.self, from: bytes)
      guard recovery.version == 1 else { throw JournalPlatformServices.Failure.unavailable }
    } catch {
      throw JournalAccountIssue(kind: .unavailable, stage: .bindingWrite)
    }
    let accepted = Self.acceptedRecovery == recovery.id
    try await perform {
      if !accepted {
        let current = try JournalLocalAccountBindingStore.loadData()
        // Preserve a replacement made outside this serialized owner.
        if current == recovery.replacement {
          try JournalLocalAccountBindingStore.restoreData(recovery.previous)
        }
      }
      // Failed undo or cleanup leaves the durable journal intact and fails closed.
      try JournalLocalAccountBindingStore.clearRecoveryData()
    }
    Self.acceptedRecovery = nil
  }

  @MainActor func clear() async throws {
    // Once SDK sign-out succeeded, cleanup must finish even if its caller cancels.
    let release = try await Self.access.acquire(respectCancellation: false)
    defer { release() }
    try await repairIfNeeded()
    try await perform { try JournalLocalAccountBindingStore.clear() }
  }
}
