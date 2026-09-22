import Foundation

@MainActor enum JournalNativeServices {
  static let managedSyncOrigin = "https://api.logseq.io"

  static func makePlatformServices() -> JournalPlatformServices {
    let storage = JournalNativeAccountStorage()
    return JournalPlatformServices(
      auth: JournalAmplifySession(),
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

  private func perform<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result(catching: operation)) }
    }
  }

  func load() async throws -> JournalLocalAccount? {
    try await perform {
      guard let value = try JournalLocalAccountBindingStore.load() else { return nil }
      guard let userID = value["userId"] as? String,
            let origin = value["managedSyncOrigin"] as? String else {
        throw JournalPlatformServices.Failure.invalidBinding
      }
      return JournalLocalAccount(userID: userID, managedSyncOrigin: origin)
    }
  }

  func save(_ binding: JournalLocalAccount) async throws {
    try await perform {
      try JournalLocalAccountBindingStore.save(arguments: [
        "version": 1, "userId": binding.userID,
        "managedSyncOrigin": binding.managedSyncOrigin,
      ])
    }
  }

  func clear() async throws {
    try await perform { try JournalLocalAccountBindingStore.clear() }
  }
}
