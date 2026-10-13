import Foundation

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
  private enum PendingRestore { case binding(previous: Data?, replacement: Data) }
  @MainActor private static var pendingRestore: PendingRestore?

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
      Self.pendingRestore = .binding(previous: previous, replacement: replacement)
      try await perform { try JournalLocalAccountBindingStore.writeData(replacement) }
      return JournalAccountSave(commit: {
        Self.pendingRestore = nil
        release()
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
    guard case let .binding(previous, replacement) = Self.pendingRestore else { return }
    try await perform {
      let current = try JournalLocalAccountBindingStore.loadData()
      // Preserve a replacement made outside this serialized owner.
      if current == replacement { try JournalLocalAccountBindingStore.restoreData(previous) }
    }
    Self.pendingRestore = nil
  }

  @MainActor func clear() async throws {
    // Once SDK sign-out succeeded, cleanup must finish even if its caller cancels.
    let release = try await Self.access.acquire(respectCancellation: false)
    defer { release() }
    try await repairIfNeeded()
    try await perform { try JournalLocalAccountBindingStore.clear() }
  }
}
