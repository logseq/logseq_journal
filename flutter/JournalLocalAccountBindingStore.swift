import Foundation
import Security

enum JournalLocalAccountBindingStore {
  private static let maximumBytes = 4_096

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
    let data = try JSONSerialization.data(
      withJSONObject: [
        "version": 1,
        "userId": userID,
        "managedSyncOrigin": managedSyncOrigin,
      ],
      options: [.sortedKeys]
    )
    guard data.count <= maximumBytes else { throw CocoaError(.fileWriteUnknown) }
    return data
  }

  static func decode(_ data: Data) throws -> [String: Any] {
    guard data.count <= maximumBytes,
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      value.count == 3,
      value["version"] as? Int == 1,
      let userID = value["userId"] as? String,
      let origin = value["managedSyncOrigin"] as? String
    else { throw CocoaError(.fileReadCorruptFile) }
    _ = try encode(userID: userID, managedSyncOrigin: origin)
    return value
  }

  static func load() throws -> [String: Any]? {
    var lookup = query()
    lookup[kSecReturnData] = kCFBooleanTrue
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw CocoaError(.fileReadUnknown)
    }
    return try decode(data)
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
    SecItemDelete(query() as CFDictionary)
    var addition = query()
    addition[kSecValueData] = data
    guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  static func clear() throws {
    let status = SecItemDelete(query() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
