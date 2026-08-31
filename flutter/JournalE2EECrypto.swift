import CryptoKit
import Foundation
import Security

enum JournalE2EECryptoError: Error {
  case invalidRequest
  case operationFailed
  case wrappedGraphKeyUnavailable
  case localPrivateKeyUnavailable
}

#if DEBUG && os(macOS)
@_silgen_name("SecKeychainCreate")
private func JournalSecKeychainCreate(
  _ pathName: UnsafePointer<CChar>,
  _ passwordLength: UInt32,
  _ password: UnsafeRawPointer,
  _ promptUser: Bool,
  _ initialAccess: SecAccess?,
  _ keychain: UnsafeMutablePointer<SecKeychain?>
) -> OSStatus
#endif

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
  private static let privateKeyService = "com.logseq.journal.e2ee.private-key"
  private static let wrappedGraphKeyService = "com.logseq.journal.e2ee.wrapped-graph-key"
  private static let passwordIterations = 600_000
  private static let maximumWrappedGraphKeyBytes = 131_072
  private static let testPrivateKeyStorageEnvironment =
    "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE"
  private static let testWrappedKeyStorageEnvironment =
    "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE"
  private static let testFileKeychainEnvironment =
    "LOGSEQ_JOURNAL_E2EE_TEST_FILE_KEYCHAIN"

  private enum SecretStorage {
    case keychain
#if DEBUG && os(macOS)
    case testFileKeychain(SecKeychain)
#endif
#if DEBUG
    case testMemory
#endif
  }

#if DEBUG
  private static let testMemorySecretsLock = NSLock()
  private static var testMemoryPrivateKeys: [String: Data] = [:]
  private static var testMemoryWrappedGraphKeys: [String: Data] = [:]
#endif
#if DEBUG && os(macOS)
  private static let testFileKeychainsLock = NSLock()
  private static var testFileKeychains: [String: SecKeychain] = [:]
#endif

  private struct SecretIdentity: Equatable {
    let origin: String
    let userID: String
    let graphID: String?

    var accountDigest: Data {
      Data(SHA256.hash(data: canonicalData(includeGraph: false)))
    }

    var accountDigestHex: String { JournalE2EECrypto.hex(accountDigest) }

    var graphDigestHex: String {
      precondition(graphID != nil)
      return JournalE2EECrypto.hex(
        Data(SHA256.hash(data: canonicalData(includeGraph: true)))
      )
    }

    private func canonicalData(includeGraph: Bool) -> Data {
      var data = Data([1])
      JournalE2EECrypto.appendLengthDelimited(origin, to: &data)
      JournalE2EECrypto.appendLengthDelimited(userID, to: &data)
      if includeGraph, let graphID {
        JournalE2EECrypto.appendLengthDelimited(graphID, to: &data)
      }
      return data
    }
  }

  private static func appendLengthDelimited(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    var length = UInt32(bytes.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(bytes)
  }

  private static func readLengthDelimited(_ data: Data, offset: inout Int) throws -> String {
    guard offset + 4 <= data.count else { throw JournalE2EECryptoError.invalidRequest }
    let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    offset += 4
    guard length <= UInt32(maximumWrappedGraphKeyBytes) else {
      throw JournalE2EECryptoError.invalidRequest
    }
    let end = offset + Int(length)
    guard end <= data.count, let value = String(data: data[offset..<end], encoding: .utf8) else {
      throw JournalE2EECryptoError.invalidRequest
    }
    offset = end
    return value
  }

  private static func normalizedOrigin(_ value: Any?) throws -> String {
    guard
      let value = value as? String,
      !value.isEmpty,
      value.utf8.count <= 2_048,
      !value.contains("\0"),
      let components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(),
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else { throw JournalE2EECryptoError.invalidRequest }
    var normalized = URLComponents()
    normalized.scheme = "https"
    normalized.host = host
    if components.port != 443 { normalized.port = components.port }
    guard let result = normalized.string else { throw JournalE2EECryptoError.invalidRequest }
    return result
  }

  private static func canonicalGraphID(_ value: Any?) throws -> String {
    guard let value = value as? String, let uuid = UUID(uuidString: value) else {
      throw JournalE2EECryptoError.invalidRequest
    }
    let canonical = uuid.uuidString.lowercased()
    guard value == canonical else { throw JournalE2EECryptoError.invalidRequest }
    return canonical
  }

  private static func identity(_ request: [String: Any], includeGraph: Bool) throws
    -> SecretIdentity
  {
    SecretIdentity(
      origin: try normalizedOrigin(request["origin"]),
      userID: try boundedUserID(request["userId"]),
      graphID: includeGraph ? try canonicalGraphID(request["graphId"]) : nil
    )
  }

  private static func wrappedCiphertext(_ encryptedGraphKey: String) throws -> Data {
    guard
      !encryptedGraphKey.isEmpty,
      encryptedGraphKey.utf8.count <= 65_536,
      !encryptedGraphKey.contains("\0"),
      let data = encryptedGraphKey.data(using: .utf8),
      let value = try JSONSerialization.jsonObject(with: data) as? [Any],
      value.count == 2,
      value[0] as? String == "~#'",
      let encoded = value[1] as? String,
      encoded.hasPrefix("~b"),
      let ciphertext = Data(base64Encoded: String(encoded.dropFirst(2))),
      !ciphertext.isEmpty,
      ciphertext.count <= 65_536
    else { throw JournalE2EECryptoError.invalidRequest }
    return ciphertext
  }

  private static func encodeWrappedGraphKey(
    identity: SecretIdentity,
    encryptedGraphKey: String
  ) throws -> Data {
    guard let graphID = identity.graphID else { throw JournalE2EECryptoError.invalidRequest }
    var data = Data([1])
    appendLengthDelimited(identity.origin, to: &data)
    appendLengthDelimited(identity.userID, to: &data)
    appendLengthDelimited(graphID, to: &data)
    appendLengthDelimited(encryptedGraphKey, to: &data)
    guard data.count <= maximumWrappedGraphKeyBytes else {
      throw JournalE2EECryptoError.invalidRequest
    }
    return data
  }

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

  private static func decodeWrappedGraphKey(_ data: Data) throws
    -> (identity: SecretIdentity, encryptedGraphKey: String)
  {
    guard data.count <= maximumWrappedGraphKeyBytes, data.first == 1 else {
      throw JournalE2EECryptoError.invalidRequest
    }
    var offset = 1
    let origin = try readLengthDelimited(data, offset: &offset)
    let userID = try readLengthDelimited(data, offset: &offset)
    let graphID = try readLengthDelimited(data, offset: &offset)
    let encryptedGraphKey = try readLengthDelimited(data, offset: &offset)
    guard offset == data.count else { throw JournalE2EECryptoError.invalidRequest }
    let identity = try self.identity(
      ["origin": origin, "userId": userID, "graphId": graphID],
      includeGraph: true
    )
    _ = try wrappedCiphertext(encryptedGraphKey)
    return (identity, encryptedGraphKey)
  }

  private static func dataProtectionQuery(_ query: inout [CFString: Any]) {
#if os(macOS)
    query[kSecUseDataProtectionKeychain] = true
#endif
  }

  static func privateKeyQuery(origin: String, userID: String) throws -> [CFString: Any] {
    let identity = try self.identity(
      ["origin": origin, "userId": userID],
      includeGraph: false
    )
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: privateKeyService,
      kSecAttrAccount: identity.accountDigestHex,
    ]
    dataProtectionQuery(&query)
    return query
  }

  static func wrappedGraphKeyQuery(
    origin: String,
    userID: String,
    graphID: String
  ) throws -> [CFString: Any] {
    let identity = try self.identity(
      ["origin": origin, "userId": userID, "graphId": graphID],
      includeGraph: true
    )
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: wrappedGraphKeyService,
      kSecAttrAccount: identity.graphDigestHex,
      kSecAttrGeneric: identity.accountDigest,
      kSecAttrSynchronizable: false,
    ]
    dataProtectionQuery(&query)
    return query
  }

  private static func secretStorage(
    environmentVariable: String,
    environment: [String: String]
  ) throws -> SecretStorage {
    let configured = environment[environmentVariable]
    let testFileKeychainPath = environment[testFileKeychainEnvironment]
    guard configured == nil || testFileKeychainPath == nil else {
      throw JournalE2EECryptoError.invalidRequest
    }
#if DEBUG && os(macOS)
    if let path = testFileKeychainPath {
      return .testFileKeychain(try testFileKeychain(path: path))
    }
#else
    if testFileKeychainPath != nil {
      throw JournalE2EECryptoError.invalidRequest
    }
#endif
    guard let configured else {
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

#if DEBUG && os(macOS)
  private static func testFileKeychain(path: String) throws -> SecKeychain {
    guard
      path.hasPrefix("/"),
      !path.contains("\0"),
      !path.isEmpty,
      path.utf8.count <= 4_096
    else { throw JournalE2EECryptoError.invalidRequest }
    testFileKeychainsLock.lock()
    defer { testFileKeychainsLock.unlock() }
    if let keychain = testFileKeychains[path] { return keychain }
    guard !FileManager.default.fileExists(atPath: path) else {
      throw JournalE2EECryptoError.invalidRequest
    }
    let password = UUID().uuidString
    var keychain: SecKeychain?
    let status = password.withCString { passwordPointer in
      JournalSecKeychainCreate(
        path,
        UInt32(strlen(passwordPointer)),
        passwordPointer,
        false,
        nil,
        &keychain
      )
    }
    guard status == errSecSuccess, let keychain else {
      throw JournalE2EECryptoError.operationFailed
    }
    testFileKeychains[path] = keychain
    return keychain
  }
#endif

  private static func searchQuery(
    _ query: inout [CFString: Any],
    storage: SecretStorage
  ) throws {
    switch storage {
    case .keychain:
      break
#if DEBUG && os(macOS)
    case .testFileKeychain(let keychain):
      query.removeValue(forKey: kSecUseDataProtectionKeychain)
      query[kSecMatchSearchList] = [keychain]
#endif
#if DEBUG
    case .testMemory:
      throw JournalE2EECryptoError.invalidRequest
#endif
    }
  }

  private static func additionQuery(
    _ query: inout [CFString: Any],
    storage: SecretStorage
  ) throws {
    switch storage {
    case .keychain:
      break
#if DEBUG && os(macOS)
    case .testFileKeychain(let keychain):
      query.removeValue(forKey: kSecUseDataProtectionKeychain)
      query[kSecUseKeychain] = keychain
#endif
#if DEBUG
    case .testMemory:
      throw JournalE2EECryptoError.invalidRequest
#endif
    }
  }

  static func savePrivateKey(
    origin: String,
    userID: String,
    key: Data,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    let identity = try self.identity(
      ["origin": origin, "userId": userID],
      includeGraph: false
    )
    let storage = try secretStorage(
      environmentVariable: testPrivateKeyStorageEnvironment,
      environment: environment
    )
    switch storage {
#if DEBUG
    case .testMemory:
      testMemorySecretsLock.lock()
      defer { testMemorySecretsLock.unlock() }
      testMemoryPrivateKeys[identity.accountDigestHex] = key
      return
#endif
#if DEBUG && os(macOS)
    case .testFileKeychain:
      break
#endif
    case .keychain:
      break
    }
    var query = try privateKeyQuery(origin: origin, userID: userID)
    try searchQuery(&query, storage: storage)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData: key] as CFDictionary)
    if status == errSecItemNotFound {
      query = try privateKeyQuery(origin: origin, userID: userID)
      try additionQuery(&query, storage: storage)
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
    origin: String,
    userID: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Data? {
    let identity = try self.identity(
      ["origin": origin, "userId": userID],
      includeGraph: false
    )
    let storage = try secretStorage(
      environmentVariable: testPrivateKeyStorageEnvironment,
      environment: environment
    )
    switch storage {
#if DEBUG
    case .testMemory:
      testMemorySecretsLock.lock()
      defer { testMemorySecretsLock.unlock() }
      return testMemoryPrivateKeys[identity.accountDigestHex]
#endif
#if DEBUG && os(macOS)
    case .testFileKeychain:
      break
#endif
    case .keychain:
      break
    }
    var query = try privateKeyQuery(origin: origin, userID: userID)
    try searchQuery(&query, storage: storage)
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

  private static func saveWrappedGraphKey(
    identity: SecretIdentity,
    encryptedGraphKey: String,
    environment: [String: String]
  ) throws {
    let encoded = try encodeWrappedGraphKey(
      identity: identity,
      encryptedGraphKey: encryptedGraphKey
    )
    let storage = try secretStorage(
      environmentVariable: testWrappedKeyStorageEnvironment,
      environment: environment
    )
    switch storage {
#if DEBUG
    case .testMemory:
      testMemorySecretsLock.lock()
      defer { testMemorySecretsLock.unlock() }
      testMemoryWrappedGraphKeys[identity.graphDigestHex] = encoded
      return
#endif
#if DEBUG && os(macOS)
    case .testFileKeychain:
      break
#endif
    case .keychain:
      break
    }
    guard let graphID = identity.graphID else { throw JournalE2EECryptoError.invalidRequest }
    var query = try wrappedGraphKeyQuery(
      origin: identity.origin,
      userID: identity.userID,
      graphID: graphID
    )
    try searchQuery(&query, storage: storage)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData: encoded] as CFDictionary)
    if status == errSecItemNotFound {
      query = try wrappedGraphKeyQuery(
        origin: identity.origin,
        userID: identity.userID,
        graphID: graphID
      )
      try additionQuery(&query, storage: storage)
      query[kSecValueData] = encoded
      query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
        throw JournalE2EECryptoError.operationFailed
      }
    } else if status != errSecSuccess {
      throw JournalE2EECryptoError.operationFailed
    }
  }

  private static func deleteWrappedGraphKey(
    identity: SecretIdentity,
    environment: [String: String]
  ) throws {
    let storage = try secretStorage(
      environmentVariable: testWrappedKeyStorageEnvironment,
      environment: environment
    )
    switch storage {
#if DEBUG
    case .testMemory:
      testMemorySecretsLock.lock()
      defer { testMemorySecretsLock.unlock() }
      testMemoryWrappedGraphKeys.removeValue(forKey: identity.graphDigestHex)
      return
#endif
#if DEBUG && os(macOS)
    case .testFileKeychain:
      break
#endif
    case .keychain:
      break
    }
    guard let graphID = identity.graphID else { throw JournalE2EECryptoError.invalidRequest }
    var query = try wrappedGraphKeyQuery(
      origin: identity.origin,
      userID: identity.userID,
      graphID: graphID
    )
    try searchQuery(&query, storage: storage)
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw JournalE2EECryptoError.operationFailed
    }
  }

  private static func loadWrappedGraphKey(
    identity: SecretIdentity,
    environment: [String: String]
  ) throws -> String? {
    let storage = try secretStorage(
      environmentVariable: testWrappedKeyStorageEnvironment,
      environment: environment
    )
    func loadFromKeychain() throws -> Data? {
      guard let graphID = identity.graphID else {
        throw JournalE2EECryptoError.invalidRequest
      }
      var query = try wrappedGraphKeyQuery(
        origin: identity.origin,
        userID: identity.userID,
        graphID: graphID
      )
      try searchQuery(&query, storage: storage)
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
    let encoded: Data?
    switch storage {
#if DEBUG
    case .testMemory:
      testMemorySecretsLock.lock()
      encoded = testMemoryWrappedGraphKeys[identity.graphDigestHex]
      testMemorySecretsLock.unlock()
#endif
#if DEBUG && os(macOS)
    case .testFileKeychain:
      encoded = try loadFromKeychain()
#endif
    case .keychain:
      encoded = try loadFromKeychain()
    }
    guard let encoded else { return nil }
    do {
      let decoded = try decodeWrappedGraphKey(encoded)
      guard decoded.identity == identity else { throw JournalE2EECryptoError.invalidRequest }
      return decoded.encryptedGraphKey
    } catch {
      try? deleteWrappedGraphKey(identity: identity, environment: environment)
      throw JournalE2EECryptoError.operationFailed
    }
  }

  private static func deleteAccountSecrets(
    identity: SecretIdentity,
    environment: [String: String]
  ) throws {
    func deleteWrappedFromKeychain(_ storage: SecretStorage) throws {
      var query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: wrappedGraphKeyService,
        kSecAttrGeneric: identity.accountDigest,
      ]
      dataProtectionQuery(&query)
      try searchQuery(&query, storage: storage)
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw JournalE2EECryptoError.operationFailed
      }
    }
    let wrappedStorage = try secretStorage(
      environmentVariable: testWrappedKeyStorageEnvironment,
      environment: environment
    )
    switch wrappedStorage {
#if DEBUG
    case .testMemory:
      testMemorySecretsLock.lock()
      testMemoryWrappedGraphKeys = testMemoryWrappedGraphKeys.filter { _, value in
        guard let decoded = try? decodeWrappedGraphKey(value) else { return false }
        return decoded.identity.accountDigest != identity.accountDigest
      }
      testMemorySecretsLock.unlock()
#endif
#if DEBUG && os(macOS)
    case .testFileKeychain:
      try deleteWrappedFromKeychain(wrappedStorage)
#endif
    case .keychain:
      try deleteWrappedFromKeychain(wrappedStorage)
    }
    func deletePrivateFromKeychain(_ storage: SecretStorage) throws {
      var query = try privateKeyQuery(origin: identity.origin, userID: identity.userID)
      try searchQuery(&query, storage: storage)
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw JournalE2EECryptoError.operationFailed
      }
    }
    let privateStorage = try secretStorage(
      environmentVariable: testPrivateKeyStorageEnvironment,
      environment: environment
    )
    switch privateStorage {
#if DEBUG
    case .testMemory:
      testMemorySecretsLock.lock()
      testMemoryPrivateKeys.removeValue(forKey: identity.accountDigestHex)
      testMemorySecretsLock.unlock()
#endif
#if DEBUG && os(macOS)
    case .testFileKeychain:
      try deletePrivateFromKeychain(privateStorage)
#endif
    case .keychain:
      try deletePrivateFromKeychain(privateStorage)
    }
  }

#if DEBUG
  static func testFixtureStorageIsIsolated(environment: [String: String]) -> Bool {
    environment[testPrivateKeyStorageEnvironment] == "memory"
      && environment[testWrappedKeyStorageEnvironment] == "memory"
  }

  static func resetTestMemoryPrivateKeys() {
    testMemorySecretsLock.lock()
    defer { testMemorySecretsLock.unlock() }
    testMemoryPrivateKeys.removeAll(keepingCapacity: false)
    testMemoryWrappedGraphKeys.removeAll(keepingCapacity: false)
  }

  static func removeTestMemoryPrivateKey(origin: String, userID: String) throws {
    let identity = try self.identity(
      ["origin": origin, "userId": userID],
      includeGraph: false
    )
    testMemorySecretsLock.lock()
    defer { testMemorySecretsLock.unlock() }
    testMemoryPrivateKeys.removeValue(forKey: identity.accountDigestHex)
  }

  static func probeIsolatedRealWrappedKeychainItem(
    origin: String,
    userID: String,
    graphID: String
  ) throws -> [CFString: Any] {
    var item = try wrappedGraphKeyQuery(
      origin: origin,
      userID: userID,
      graphID: graphID
    )
    let service = "\(wrappedGraphKeyService).test.\(UUID().uuidString.lowercased())"
    item[kSecAttrService] = service
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecValueData] = Data([1, 0, 0, 0, 0])
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw JournalE2EECryptoError.operationFailed
    }

    var lookup = try wrappedGraphKeyQuery(
      origin: origin,
      userID: userID,
      graphID: graphID
    )
    lookup[kSecAttrService] = service
    let deletionQuery = lookup
    lookup[kSecReturnAttributes] = true
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let readStatus = SecItemCopyMatching(lookup as CFDictionary, &result)
    let deleteStatus = SecItemDelete(deletionQuery as CFDictionary)
    var deletedResult: CFTypeRef?
    let deletedReadStatus = SecItemCopyMatching(lookup as CFDictionary, &deletedResult)
    guard
      readStatus == errSecSuccess,
      let attributes = result as? [CFString: Any],
      deleteStatus == errSecSuccess,
      deletedReadStatus == errSecItemNotFound
    else {
      _ = SecItemDelete(deletionQuery as CFDictionary)
      throw JournalE2EECryptoError.operationFailed
    }
    return attributes
  }
#endif

  private static func decryptedGraphKey(_ request: [String: Any]) throws -> Data {
    let identity = try self.identity(request, includeGraph: false)
    guard
      let privateKey = try loadPrivateKey(
        origin: identity.origin,
        userID: identity.userID
      )
    else {
      throw JournalE2EECryptoError.operationFailed
    }
    let graphKey = try rsaOAEPDecrypt(
      privateKeyData: privateKey,
      ciphertext: try hexData(request["ciphertext"])
    )
    guard graphKey.count == 32 else { throw JournalE2EECryptoError.operationFailed }
    return graphKey
  }

  private static func verifyWrappedGraphKey(
    identity: SecretIdentity,
    encryptedGraphKey: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    guard
      let privateKey = try loadPrivateKey(
        origin: identity.origin,
        userID: identity.userID,
        environment: environment
      )
    else { throw JournalE2EECryptoError.localPrivateKeyUnavailable }
    let graphKey = try rsaOAEPDecrypt(
      privateKeyData: privateKey,
      ciphertext: try wrappedCiphertext(encryptedGraphKey)
    )
    guard graphKey.count == 32 else { throw JournalE2EECryptoError.operationFailed }
  }

  static func handle(_ request: [String: Any]) throws -> [String: Any] {
    guard let operation = request["operation"] as? String else {
      throw JournalE2EECryptoError.invalidRequest
    }
    switch operation {
    case "hasPrivateKey":
      let identity = try self.identity(request, includeGraph: false)
      return [
        "ok": true,
        "value": try loadPrivateKey(origin: identity.origin, userID: identity.userID) != nil,
      ]

    case "unlockPrivateKey":
      let identity = try self.identity(request, includeGraph: false)
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
      try savePrivateKey(origin: identity.origin, userID: identity.userID, key: privateKey)
      return ["ok": true]

#if DEBUG
    case "installTestWrappedGraphKeyFixture":
      guard testFixtureStorageIsIsolated(environment: ProcessInfo.processInfo.environment) else {
        throw JournalE2EECryptoError.invalidRequest
      }
      let identity = try self.identity(request, includeGraph: true)
      let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits: 4096,
      ]
      var keyError: Unmanaged<CFError>?
      guard
        let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError),
        let publicKey = SecKeyCopyPublicKey(privateKey),
        let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &keyError) as Data?,
        let ciphertext = SecKeyCreateEncryptedData(
          publicKey,
          .rsaEncryptionOAEPSHA256,
          Data(repeating: 0x5a, count: 32) as CFData,
          &keyError
        ) as Data?,
        let transit = String(
          data: try JSONSerialization.data(
            withJSONObject: ["~#'", "~b\(ciphertext.base64EncodedString())"]
          ),
          encoding: .utf8
        )
      else { throw JournalE2EECryptoError.operationFailed }
      try savePrivateKey(
        origin: identity.origin,
        userID: identity.userID,
        key: privateKeyData
      )
      try verifyWrappedGraphKey(identity: identity, encryptedGraphKey: transit)
      try saveWrappedGraphKey(
        identity: identity,
        encryptedGraphKey: transit,
        environment: ProcessInfo.processInfo.environment
      )
      return [
        "ok": true,
        "encryptedGraphKey": transit,
        "ciphertext": hex(ciphertext),
      ]

    case "installTestPrivateKey":
      let identity = try self.identity(request, includeGraph: false)
      try savePrivateKey(
        origin: identity.origin,
        userID: identity.userID,
        key: try hexData(request["privateKey"])
      )
      return ["ok": true]
#endif

    case "loadAndVerifyWrappedGraphKey":
      let identity = try self.identity(request, includeGraph: true)
      guard
        let encryptedGraphKey = try loadWrappedGraphKey(
          identity: identity,
          environment: ProcessInfo.processInfo.environment
        )
      else { throw JournalE2EECryptoError.wrappedGraphKeyUnavailable }
      do {
        try verifyWrappedGraphKey(identity: identity, encryptedGraphKey: encryptedGraphKey)
      } catch JournalE2EECryptoError.localPrivateKeyUnavailable {
        try? deleteWrappedGraphKey(
          identity: identity,
          environment: ProcessInfo.processInfo.environment
        )
        throw JournalE2EECryptoError.localPrivateKeyUnavailable
      } catch {
        try? deleteWrappedGraphKey(
          identity: identity,
          environment: ProcessInfo.processInfo.environment
        )
        throw JournalE2EECryptoError.wrappedGraphKeyUnavailable
      }
      return ["ok": true, "value": encryptedGraphKey]

    case "verifyAndSaveWrappedGraphKey":
      let identity = try self.identity(request, includeGraph: true)
      guard let encryptedGraphKey = request["encryptedGraphKey"] as? String else {
        throw JournalE2EECryptoError.invalidRequest
      }
      try verifyWrappedGraphKey(identity: identity, encryptedGraphKey: encryptedGraphKey)
      try saveWrappedGraphKey(
        identity: identity,
        encryptedGraphKey: encryptedGraphKey,
        environment: ProcessInfo.processInfo.environment
      )
      return ["ok": true]

    case "deleteWrappedGraphKey":
      let identity = try self.identity(request, includeGraph: true)
      try deleteWrappedGraphKey(
        identity: identity,
        environment: ProcessInfo.processInfo.environment
      )
      return ["ok": true]

    case "deleteAccountSecrets":
      let identity = try self.identity(request, includeGraph: false)
      try deleteAccountSecrets(
        identity: identity,
        environment: ProcessInfo.processInfo.environment
      )
      return ["ok": true, "wrappedKeysDeleted": true, "privateKeyDeleted": true]

    case "unwrapGraphKeyForEngine":
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
  } catch JournalE2EECryptoError.localPrivateKeyUnavailable {
    response = ["ok": false, "error": "localPrivateKeyUnavailable"]
  } catch JournalE2EECryptoError.wrappedGraphKeyUnavailable {
    response = ["ok": false, "error": "wrappedGraphKeyUnavailable"]
  } catch {
    response = ["ok": false, "error": "cryptoOperationFailed"]
  }
  guard
    let data = try? JSONSerialization.data(withJSONObject: response),
    let string = String(data: data, encoding: .utf8)
  else { return strdup("{\"ok\":false,\"error\":\"crypto operation failed\"}") }
  return strdup(string)
}
