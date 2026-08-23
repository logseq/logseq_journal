import CryptoKit
import Foundation
import Security

enum JournalE2EECryptoError: Error {
  case invalidRequest
  case operationFailed
}

private struct JournalDERReader {
  let bytes: [UInt8]
  var offset = 0

  mutating func element(tag expectedTag: UInt8) throws -> Data {
    guard offset < bytes.count, bytes[offset] == expectedTag else {
      throw JournalE2EECryptoError.operationFailed
    }
    offset += 1
    let length = try readLength()
    guard length >= 0, offset + length <= bytes.count else {
      throw JournalE2EECryptoError.operationFailed
    }
    let result = Data(bytes[offset..<(offset + length)])
    offset += length
    return result
  }

  private mutating func readLength() throws -> Int {
    guard offset < bytes.count else { throw JournalE2EECryptoError.operationFailed }
    let first = bytes[offset]
    offset += 1
    if first & 0x80 == 0 { return Int(first) }
    let count = Int(first & 0x7f)
    guard count > 0, count <= MemoryLayout<Int>.size, offset + count <= bytes.count else {
      throw JournalE2EECryptoError.operationFailed
    }
    var result = 0
    for _ in 0..<count {
      result = (result << 8) | Int(bytes[offset])
      offset += 1
    }
    return result
  }
}

enum JournalE2EECrypto {
  private static let keychainService = "com.logseq.journal.e2ee.private-key"
  private static let passwordIterations = 600_000
  private static let testPrivateKeyStorageEnvironment =
    "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE"

  private enum PrivateKeyStorage {
    case keychain
#if DEBUG
    case testMemory
#endif
  }

#if DEBUG
  private static let testMemoryPrivateKeysLock = NSLock()
  private static var testMemoryPrivateKeys: [String: Data] = [:]
#endif

  private static func boundedUserID(_ value: Any?) throws -> String {
    guard
      let value = value as? String,
      !value.isEmpty,
      value.utf8.count <= 512,
      !value.contains("\0")
    else { throw JournalE2EECryptoError.invalidRequest }
    return value
  }

  private static func hexData(_ value: Any?) throws -> Data {
    guard let text = value as? String, text.count.isMultiple(of: 2), text.count <= 262_144 else {
      throw JournalE2EECryptoError.invalidRequest
    }
    var result = Data(capacity: text.count / 2)
    var index = text.startIndex
    while index < text.endIndex {
      let end = text.index(index, offsetBy: 2)
      guard let byte = UInt8(text[index..<end], radix: 16) else {
        throw JournalE2EECryptoError.invalidRequest
      }
      result.append(byte)
      index = end
    }
    return result
  }

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int) throws -> Data {
    guard iterations == passwordIterations else { throw JournalE2EECryptoError.invalidRequest }
    let key = SymmetricKey(data: password)
    var firstInput = Data(salt)
    firstInput.append(contentsOf: [0, 0, 0, 1])
    var previous = Data(HMAC<SHA256>.authenticationCode(for: firstInput, using: key))
    var result = [UInt8](previous)
    for _ in 2...iterations {
      previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: key))
      for index in result.indices { result[index] ^= previous[index] }
    }
    return Data(result)
  }

  private static func aesOpen(key: Data, iv: Data, ciphertextAndTag: Data) throws -> Data {
    guard key.count == 32, iv.count == 12, ciphertextAndTag.count >= 16 else {
      throw JournalE2EECryptoError.operationFailed
    }
    let box = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: iv),
      ciphertext: ciphertextAndTag.dropLast(16),
      tag: ciphertextAndTag.suffix(16)
    )
    return try AES.GCM.open(box, using: SymmetricKey(data: key))
  }

  private static func aesSeal(key: Data, plaintext: Data) throws -> (Data, Data) {
    guard key.count == 32 else { throw JournalE2EECryptoError.operationFailed }
    let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
    let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
    return (nonce, sealed.ciphertext + sealed.tag)
  }

  private static func unwrapPKCS8(_ data: Data) throws -> Data {
    var outer = JournalDERReader(bytes: [UInt8](data))
    let sequence = try outer.element(tag: 0x30)
    var contents = JournalDERReader(bytes: [UInt8](sequence))
    _ = try contents.element(tag: 0x02)
    _ = try contents.element(tag: 0x30)
    return try contents.element(tag: 0x04)
  }

  private static func rsaPrivateKey(_ privateKeyData: Data) throws -> SecKey {
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrKeySizeInBits: 4096,
    ]
    var error: Unmanaged<CFError>?
    var key = SecKeyCreateWithData(privateKeyData as CFData, attributes as CFDictionary, &error)
    if key == nil {
      error = nil
      let pkcs1 = try unwrapPKCS8(privateKeyData)
      key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error)
    }
    guard let key else { throw JournalE2EECryptoError.operationFailed }
    return key
  }

  private static func rsaOAEPDecrypt(privateKeyData: Data, ciphertext: Data) throws -> Data {
    let key = try rsaPrivateKey(privateKeyData)
    var error: Unmanaged<CFError>?
    error = nil
    guard let plaintext = SecKeyCreateDecryptedData(
      key,
      .rsaEncryptionOAEPSHA256,
      ciphertext as CFData,
      &error
    ) else { throw JournalE2EECryptoError.operationFailed }
    return plaintext as Data
  }

  static func keychainQuery(userID: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: keychainService,
      kSecAttrAccount: userID,
    ]
  }

  private static func privateKeyStorage(
    environment: [String: String]
  ) throws -> PrivateKeyStorage {
    guard let configured = environment[testPrivateKeyStorageEnvironment] else {
      return .keychain
    }
#if DEBUG
    guard configured == "memory" else {
      throw JournalE2EECryptoError.invalidRequest
    }
    return .testMemory
#else
    _ = configured
    throw JournalE2EECryptoError.invalidRequest
#endif
  }

  static func savePrivateKey(
    userID: String,
    key: Data,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    switch try privateKeyStorage(environment: environment) {
#if DEBUG
    case .testMemory:
      testMemoryPrivateKeysLock.lock()
      defer { testMemoryPrivateKeysLock.unlock() }
      testMemoryPrivateKeys[userID] = key
      return
#endif
    case .keychain:
      break
    }
    var query = keychainQuery(userID: userID)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData: key] as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData] = key
      query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
        throw JournalE2EECryptoError.operationFailed
      }
    } else if status != errSecSuccess {
      throw JournalE2EECryptoError.operationFailed
    }
  }

  static func loadPrivateKey(
    userID: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Data? {
    switch try privateKeyStorage(environment: environment) {
#if DEBUG
    case .testMemory:
      testMemoryPrivateKeysLock.lock()
      defer { testMemoryPrivateKeysLock.unlock() }
      return testMemoryPrivateKeys[userID]
#endif
    case .keychain:
      break
    }
    var query = keychainQuery(userID: userID)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw JournalE2EECryptoError.operationFailed
    }
    return data
  }

#if DEBUG
  static func resetTestMemoryPrivateKeys() {
    testMemoryPrivateKeysLock.lock()
    defer { testMemoryPrivateKeysLock.unlock() }
    testMemoryPrivateKeys.removeAll(keepingCapacity: false)
  }
#endif

  private static func decryptedGraphKey(_ request: [String: Any]) throws -> Data {
    let userID = try boundedUserID(request["userId"])
    guard let privateKey = try loadPrivateKey(userID: userID) else {
      throw JournalE2EECryptoError.operationFailed
    }
    let graphKey = try rsaOAEPDecrypt(
      privateKeyData: privateKey,
      ciphertext: try hexData(request["ciphertext"])
    )
    guard graphKey.count == 32 else { throw JournalE2EECryptoError.operationFailed }
    return graphKey
  }

  static func handle(_ request: [String: Any]) throws -> [String: Any] {
    guard let operation = request["operation"] as? String else {
      throw JournalE2EECryptoError.invalidRequest
    }
    switch operation {
    case "hasPrivateKey":
      let userID = try boundedUserID(request["userId"])
      return ["ok": true, "value": try loadPrivateKey(userID: userID) != nil]

    case "unlockPrivateKey":
      let userID = try boundedUserID(request["userId"])
      guard
        let password = request["password"] as? String,
        !password.isEmpty,
        password.utf8.count <= 4096,
        let iterations = request["iterations"] as? Int
      else { throw JournalE2EECryptoError.invalidRequest }
      let key = try pbkdf2SHA256(
        password: Data(password.utf8),
        salt: try hexData(request["salt"]),
        iterations: iterations
      )
      let privateKey = try aesOpen(
        key: key,
        iv: try hexData(request["iv"]),
        ciphertextAndTag: try hexData(request["ciphertext"])
      )
      _ = try rsaPrivateKey(privateKey)
      try savePrivateKey(userID: userID, key: privateKey)
      return ["ok": true]

    case "verifyGraphKey":
      _ = try decryptedGraphKey(request)
      return ["ok": true]

    case "decryptGraphKeyForUser":
      return ["ok": true, "value": hex(try decryptedGraphKey(request))]

    case "encryptAES":
      let (iv, ciphertext) = try aesSeal(
        key: try hexData(request["key"]),
        plaintext: try hexData(request["plaintext"])
      )
      return ["ok": true, "iv": hex(iv), "ciphertext": hex(ciphertext)]

    case "decryptAES":
      let plaintext = try aesOpen(
        key: try hexData(request["key"]),
        iv: try hexData(request["iv"]),
        ciphertextAndTag: try hexData(request["ciphertext"])
      )
      return ["ok": true, "value": hex(plaintext)]

    default:
      throw JournalE2EECryptoError.invalidRequest
    }
  }
}

@_cdecl("logseq_journal_crypto_json")
public func logseqJournalCryptoJSON(
  _ requestPointer: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
  let response: [String: Any]
  do {
    guard
      let requestPointer,
      let data = String(cString: requestPointer).data(using: .utf8),
      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw JournalE2EECryptoError.invalidRequest }
    response = try JournalE2EECrypto.handle(request)
  } catch {
    response = ["ok": false, "error": "crypto operation failed"]
  }
  guard
    let data = try? JSONSerialization.data(withJSONObject: response),
    let string = String(data: data, encoding: .utf8)
  else { return strdup("{\"ok\":false,\"error\":\"crypto operation failed\"}") }
  return strdup(string)
}
