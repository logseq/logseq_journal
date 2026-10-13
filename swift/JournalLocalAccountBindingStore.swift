import CoreData
import Foundation
import Security

enum JournalLocalAccountBindingStore {
  private static let maximumBytes = 4_096

  private struct Binding: Codable { let version: Int; let userId: String; let managedSyncOrigin: String }
  private struct Format: Decodable { let version: Int }

  static func query() -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "com.logseq.journal.local-account-binding",
      kSecAttrAccount: "current-managed-sync-account",
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable: kCFBooleanFalse as Any,
    ]
  }

  static func encode(userID: String, managedSyncOrigin: String) throws -> Data {
    guard
      !userID.isEmpty,
      userID.utf8.count <= 512,
      !userID.contains("\0"),
      managedSyncOrigin.utf8.count <= 2_048,
      let origin = URL(string: managedSyncOrigin),
      origin.scheme == "https",
      origin.host != nil
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    let data = try JSONEncoder().encode(Binding(version: 2, userId: userID, managedSyncOrigin: managedSyncOrigin))
    guard data.count <= maximumBytes else { throw CocoaError(.fileWriteUnknown) }
    return data
  }

  static func decode(_ data: Data) throws -> [String: Any] {
    guard data.count <= maximumBytes else {
      throw JournalAccountIssue(kind: .corruptBinding, stage: .bindingRead)
    }
    let version: Int
    do { version = try JSONDecoder().decode(Format.self, from: data).version }
    catch { throw JournalAccountIssue(kind: .corruptBinding, stage: .bindingRead) }
    guard version == 2 else {
      throw JournalAccountIssue(kind: .unsupportedFormat, stage: .bindingRead, formatVersion: version)
    }
    let binding: Binding
    do {
      binding = try JSONDecoder().decode(Binding.self, from: data)
      _ = try encode(userID: binding.userId, managedSyncOrigin: binding.managedSyncOrigin)
    } catch {
      throw JournalAccountIssue(kind: .corruptBinding, stage: .bindingRead, formatVersion: version)
    }
    // The key-management bridge accepts domain arguments, separate from the
    // Keychain file's generated Codable representation.
    return ["version": 1, "userId": binding.userId, "managedSyncOrigin": binding.managedSyncOrigin]
  }

  static func load() throws -> [String: Any]? {
    guard let data = try loadData() else { return nil }
    return try decode(data)
  }

  // Opaque snapshots are used only to undo this app's unaccepted write, never
  // to migrate, authorize or expose a rejected account record.
  static func loadData() throws -> Data? {
    var lookup = query()
    lookup[kSecReturnData] = kCFBooleanTrue
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw JournalAccountIssue(kind: .secureStorageUnavailable, stage: .bindingRead)
    }
    return data
  }

  static func save(arguments: Any?) throws {
    guard
      let value = arguments as? [String: Any],
      value.count == 3,
      value["version"] as? Int == 1,
      let userID = value["userId"] as? String,
      let origin = value["managedSyncOrigin"] as? String
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    let data = try encode(userID: userID, managedSyncOrigin: origin)
    try writeData(data)
  }

  static func writeData(_ data: Data) throws {
    // Keep the existing record if a replacement cannot be saved securely.
    var status = SecItemUpdate(query() as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecItemNotFound {
      var addition = query()
      addition[kSecValueData] = data
      status = SecItemAdd(addition as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw JournalAccountIssue(kind: .secureStorageUnavailable, stage: .bindingWrite)
    }
  }

  static func restoreData(_ data: Data?) throws {
    if let data { try writeData(data) }
    else {
      // Remove only the newly proposed item when no item existed beforehand.
      let status = SecItemDelete(query() as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw JournalAccountIssue(kind: .secureStorageUnavailable, stage: .bindingWrite)
      }
    }
  }

  static func clear() throws {
    let status = SecItemDelete(query() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
