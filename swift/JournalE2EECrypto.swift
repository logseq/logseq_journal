import CryptoKit
import Foundation
import Security

private final class JournalUnlockLogState: @unchecked Sendable {
  let lock = NSLock()
  var count = 0
  var operation = 0
}

// Only fixed vocabulary and numeric IDs/status codes reach this opt-in channel.
private final class JournalUnlockTrace: NSObject {
  private static let state = JournalUnlockLogState()
  private static let threadKey = "com.logseq.journal.unlock-diagnostic"
  let operation: String
  let request: String
  let began = ProcessInfo.processInfo.systemUptime
  var stage = "decode-request"
  var failureReason: String?
  var cleanupPending = false

  static var current: JournalUnlockTrace? {
    get { Thread.current.threadDictionary[threadKey] as? JournalUnlockTrace }
    set { Thread.current.threadDictionary[threadKey] = newValue }
  }

  init(_ decoded: JournalCryptoRequest?) {
    Self.state.lock.lock()
    Self.state.operation += 1
    let nativeID = Self.state.operation
    Self.state.lock.unlock()
    if let id = decoded?.diagnosticOperation, !id.isEmpty, id.utf8.count <= 20,
       id.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
      operation = id
    } else {
      operation = "native-\(nativeID)"
    }
    switch decoded?.operation {
    case "unlockPrivateKey", "loadAndVerifyWrappedGraphKey", "verifyAndSaveWrappedGraphKey",
         "unwrapGraphKeyForEngine": request = decoded!.operation
    case nil: request = "decode-request"
    default: request = "unsupported"
    }
    super.init()
    write("phase=begin")
  }

  private func write(_ fields: String) {
    guard ProcessInfo.processInfo.environment["JOURNAL_UNLOCK_DIAGNOSTICS"] == "1" else { return }
    Self.state.lock.lock()
    defer { Self.state.lock.unlock() }
    let count = Self.state.count
    Self.state.count += 1
    let line: String
    if count < 256 {
      line = "[journal-unlock] source=crypto op=\(operation) request=\(request) \(fields)\n"
    } else if count == 256 {
      line = "[journal-unlock] source=crypto limit=reached\n"
    } else { return }
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
  }

  static func mark(_ stage: String) {
    guard let trace = current else { return }
    trace.stage = stage
    trace.write("phase=stage stage=\(stage)")
  }

  static func keychain(_ stage: String, _ status: OSStatus) {
    guard let trace = current else { return }
    trace.stage = stage
    trace.write("phase=keychain stage=\(stage) osstatus=\(status)")
  }

  func finish(_ result: String) {
    let elapsed = max(0, (ProcessInfo.processInfo.systemUptime - began) * 1000)
    write("phase=end result=\(result) stage=\(stage) elapsed_ms=\(Int(elapsed))")
  }
}

// Swift's compiler synthesizes the native counterpart of the OCaml PPX DTOs.
struct JournalCryptoRequest: Codable {
  var operation: String
  var diagnosticOperation: String? = nil
  var origin: String
  var userId: String
  var graphId: String? = nil
  var password: String? = nil
  var iterations: Int? = nil
  var salt: String? = nil
  var iv: String? = nil
  var ciphertext: String? = nil
  var encryptedGraphKey: String? = nil
  var privateKey: String? = nil
}

struct JournalCryptoResponse: Codable {
  var ok: Bool
  var error: String? = nil
  var reason: String? = nil
  var cleanupPending: Bool? = nil
  var value: String? = nil
  var wrappedKeysDeleted: Bool? = nil
  var privateKeyDeleted: Bool? = nil
  var encryptedGraphKey: String? = nil
  var ciphertext: String? = nil
}

enum JournalE2EECryptoError: Error {
  case invalidRequest
  case operationFailed
  case keyStoreFailure(OSStatus)
  case keyStoreInvalidType
  case invalidPrivateKey
  case rsaDecryptionFailed
  case invalidGraphKeyLength
  case invalidAESInput
  case enginePrivateKeyUnavailable
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
  // All accesses are protected by testMemorySecretsLock, including resets.
  nonisolated(unsafe) private static var testMemoryPrivateKeys: [String: Data] = [:]
  nonisolated(unsafe) private static var testMemoryWrappedGraphKeys: [String: Data] = [:]
#endif
#if DEBUG && os(macOS)
  private static let testFileKeychainsLock = NSLock()
  // The test-only cache is accessed under testFileKeychainsLock.
  nonisolated(unsafe) private static var testFileKeychains: [String: SecKeychain] = [:]
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

  private static func identity(_ request: JournalCryptoRequest, includeGraph: Bool) throws
    -> SecretIdentity
  {
    SecretIdentity(
      origin: try normalizedOrigin(request.origin),
      userID: try boundedUserID(request.userId),
      graphID: includeGraph ? try canonicalGraphID(request.graphId) : nil
    )
  }

  private static func wrappedCiphertext(_ encryptedGraphKey: String) throws -> Data {
    guard
      !encryptedGraphKey.isEmpty,
      encryptedGraphKey.utf8.count <= 65_536,
      !encryptedGraphKey.contains("\0"),
      let data = encryptedGraphKey.data(using: .utf8),
      let value = try? JSONDecoder().decode([String].self, from: data),
      value.count == 2,
      value[0] == "~#'",
      value[1].hasPrefix("~b"),
      let ciphertext = Data(base64Encoded: String(value[1].dropFirst(2))),
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

  private static func hexNibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: return byte - 48
    case 65...70: return byte - 65 + 10
    case 97...102: return byte - 97 + 10
    default: return nil
    }
  }

  private static func hexData(_ value: Any?, maximumBytes: Int = 131_072) throws -> Data {
    guard let text = value as? String else { throw JournalE2EECryptoError.invalidRequest }
    let bytes = text.utf8
    guard bytes.count.isMultiple(of: 2), bytes.count <= maximumBytes * 2 else {
      throw JournalE2EECryptoError.invalidRequest
    }
    var result = Data(capacity: bytes.count / 2)
    var iterator = bytes.makeIterator()
    while let high = iterator.next() {
      guard let low = iterator.next(), let a = hexNibble(high), let b = hexNibble(low) else {
        throw JournalE2EECryptoError.invalidRequest
      }
      result.append((a << 4) | b)
    }
    return result
  }

  private static func hex(_ data: Data) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var bytes = [UInt8]()
    bytes.reserveCapacity(data.count * 2)
    for byte in data {
      bytes.append(digits[Int(byte >> 4)])
      bytes.append(digits[Int(byte & 15)])
    }
    return String(decoding: bytes, as: UTF8.self)
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
      throw JournalE2EECryptoError.invalidAESInput
    }
    let box = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: iv),
      ciphertext: ciphertextAndTag.dropLast(16),
      tag: ciphertextAndTag.suffix(16)
    )
    return try AES.GCM.open(box, using: SymmetricKey(data: key))
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
      let pkcs1: Data
      do { pkcs1 = try unwrapPKCS8(privateKeyData) }
      catch { throw JournalE2EECryptoError.invalidPrivateKey }
      key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error)
    }
    guard let key else { throw JournalE2EECryptoError.invalidPrivateKey }
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
    ) else { throw JournalE2EECryptoError.rsaDecryptionFailed }
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
      JournalCryptoRequest(operation: "", origin: origin, userId: userID, graphId: graphID),
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
      JournalCryptoRequest(operation: "", origin: origin, userId: userID),
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
      JournalCryptoRequest(operation: "", origin: origin, userId: userID, graphId: graphID),
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
      throw JournalE2EECryptoError.keyStoreFailure(status)
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
      JournalCryptoRequest(operation: "", origin: origin, userId: userID),
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
    JournalUnlockTrace.keychain("private-key-update", status)
    if status == errSecItemNotFound {
      query = try privateKeyQuery(origin: origin, userID: userID)
      try additionQuery(&query, storage: storage)
      query[kSecValueData] = key
      query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      JournalUnlockTrace.keychain("private-key-add", addStatus)
      guard addStatus == errSecSuccess else {
        throw JournalE2EECryptoError.keyStoreFailure(addStatus)
      }
    } else if status != errSecSuccess {
      throw JournalE2EECryptoError.keyStoreFailure(status)
    }
  }

  // Keychain query result decoding owns no storage operation and never logs its value.
  static func decodeKeyStoreData(status: OSStatus, result: CFTypeRef?) throws -> Data? {
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw JournalE2EECryptoError.keyStoreFailure(status)
    }
    guard let data = result as? Data else {
      throw JournalE2EECryptoError.keyStoreInvalidType
    }
    return data
  }

  static func loadPrivateKey(
    origin: String,
    userID: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> Data? {
    let identity = try self.identity(
      JournalCryptoRequest(operation: "", origin: origin, userId: userID),
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
    JournalUnlockTrace.keychain("private-key-copy", status)
    return try decodeKeyStoreData(status: status, result: result)
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
    JournalUnlockTrace.keychain("wrapped-key-update", status)
    if status == errSecItemNotFound {
      query = try wrappedGraphKeyQuery(
        origin: identity.origin,
        userID: identity.userID,
        graphID: graphID
      )
      try additionQuery(&query, storage: storage)
      query[kSecValueData] = encoded
      query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      JournalUnlockTrace.keychain("wrapped-key-add", addStatus)
      guard addStatus == errSecSuccess else {
        throw JournalE2EECryptoError.keyStoreFailure(addStatus)
      }
    } else if status != errSecSuccess {
      throw JournalE2EECryptoError.keyStoreFailure(status)
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
      throw JournalE2EECryptoError.keyStoreFailure(status)
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
      JournalUnlockTrace.keychain("wrapped-key-copy", status)
      return try decodeKeyStoreData(status: status, result: result)
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
      JournalUnlockTrace.current?.failureReason = "wrapped-key-cache-invalid"
      do { try deleteWrappedGraphKey(identity: identity, environment: environment) }
      catch {
        JournalUnlockTrace.current?.cleanupPending = true
        JournalUnlockTrace.mark("wrapped-key-cleanup-failed")
      }
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
        throw JournalE2EECryptoError.keyStoreFailure(status)
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
        throw JournalE2EECryptoError.keyStoreFailure(status)
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
      JournalCryptoRequest(operation: "", origin: origin, userId: userID),
      includeGraph: false
    )
    testMemorySecretsLock.lock()
    defer { testMemorySecretsLock.unlock() }
    testMemoryPrivateKeys.removeValue(forKey: identity.accountDigestHex)
  }

#endif

  private static func decryptedGraphKey(_ request: JournalCryptoRequest) throws -> Data {
    JournalUnlockTrace.mark("load-private-key")
    let identity = try self.identity(request, includeGraph: false)
    guard
      let privateKey = try loadPrivateKey(
        origin: identity.origin,
        userID: identity.userID
      )
    else {
      throw JournalE2EECryptoError.enginePrivateKeyUnavailable
    }
    JournalUnlockTrace.mark("unwrap-graph-key")
    let graphKey = try rsaOAEPDecrypt(
      privateKeyData: privateKey,
      ciphertext: try hexData(request.ciphertext)
    )
    guard graphKey.count == 32 else { throw JournalE2EECryptoError.invalidGraphKeyLength }
    return graphKey
  }

  private static func verifyWrappedGraphKey(
    identity: SecretIdentity,
    encryptedGraphKey: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    JournalUnlockTrace.mark("load-private-key")
    guard
      let privateKey = try loadPrivateKey(
        origin: identity.origin,
        userID: identity.userID,
        environment: environment
      )
    else { throw JournalE2EECryptoError.localPrivateKeyUnavailable }
    JournalUnlockTrace.mark("verify-wrapped-graph-key")
    let graphKey = try rsaOAEPDecrypt(
      privateKeyData: privateKey,
      ciphertext: try wrappedCiphertext(encryptedGraphKey)
    )
    guard graphKey.count == 32 else { throw JournalE2EECryptoError.invalidGraphKeyLength }
  }

  static func handle(_ request: JournalCryptoRequest) throws -> JournalCryptoResponse {
    switch request.operation {
    case "unlockPrivateKey":
      JournalUnlockTrace.mark("validate-private-key-request")
      let identity = try self.identity(request, includeGraph: false)
      guard
        let password = request.password,
        !password.isEmpty,
        password.utf8.count <= 4096,
        let iterations = request.iterations
      else { throw JournalE2EECryptoError.invalidRequest }
      JournalUnlockTrace.mark("derive-private-key")
      let key = try pbkdf2SHA256(
        password: Data(password.utf8),
        salt: try hexData(request.salt),
        iterations: iterations
      )
      JournalUnlockTrace.mark("open-private-key")
      let privateKey = try aesOpen(
        key: key,
        iv: try hexData(request.iv),
        ciphertextAndTag: try hexData(request.ciphertext)
      )
      JournalUnlockTrace.mark("validate-private-key")
      _ = try rsaPrivateKey(privateKey)
      JournalUnlockTrace.mark("save-private-key")
      try savePrivateKey(origin: identity.origin, userID: identity.userID, key: privateKey)
      return JournalCryptoResponse(ok: true)

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
          data: try JSONEncoder().encode(["~#'", "~b\(ciphertext.base64EncodedString())"]),
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
      return JournalCryptoResponse(ok: true, encryptedGraphKey: transit,
        ciphertext: hex(ciphertext))

    case "installTestPrivateKey":
      let identity = try self.identity(request, includeGraph: false)
      try savePrivateKey(
        origin: identity.origin,
        userID: identity.userID,
        key: try hexData(request.privateKey)
      )
      return JournalCryptoResponse(ok: true)
#endif

    case "loadAndVerifyWrappedGraphKey":
      let identity = try self.identity(request, includeGraph: true)
      guard
        let encryptedGraphKey = try loadWrappedGraphKey(
          identity: identity,
          environment: ProcessInfo.processInfo.environment
        )
      else {
        JournalUnlockTrace.current?.failureReason = "wrapped-key-absent"
        throw JournalE2EECryptoError.wrappedGraphKeyUnavailable
      }
      do {
        try verifyWrappedGraphKey(identity: identity, encryptedGraphKey: encryptedGraphKey)
      } catch JournalE2EECryptoError.localPrivateKeyUnavailable {
        do {
          try deleteWrappedGraphKey(identity: identity, environment: ProcessInfo.processInfo.environment)
        } catch {
          JournalUnlockTrace.current?.cleanupPending = true
          JournalUnlockTrace.mark("wrapped-key-cleanup-failed")
        }
        throw JournalE2EECryptoError.localPrivateKeyUnavailable
      } catch {
        JournalUnlockTrace.current?.failureReason = "wrapped-key-verification-failed:" + journalCryptoFailureCode(error)
        do {
          try deleteWrappedGraphKey(identity: identity, environment: ProcessInfo.processInfo.environment)
        } catch {
          JournalUnlockTrace.current?.cleanupPending = true
          JournalUnlockTrace.mark("wrapped-key-cleanup-failed")
        }
        throw JournalE2EECryptoError.wrappedGraphKeyUnavailable
      }
      return JournalCryptoResponse(ok: true, value: encryptedGraphKey)

    case "verifyAndSaveWrappedGraphKey":
      let identity = try self.identity(request, includeGraph: true)
      guard let encryptedGraphKey = request.encryptedGraphKey else {
        throw JournalE2EECryptoError.invalidRequest
      }
      try verifyWrappedGraphKey(identity: identity, encryptedGraphKey: encryptedGraphKey)
      try saveWrappedGraphKey(
        identity: identity,
        encryptedGraphKey: encryptedGraphKey,
        environment: ProcessInfo.processInfo.environment
      )
      return JournalCryptoResponse(ok: true)

    case "deleteWrappedGraphKey":
      let identity = try self.identity(request, includeGraph: true)
      try deleteWrappedGraphKey(
        identity: identity,
        environment: ProcessInfo.processInfo.environment
      )
      return JournalCryptoResponse(ok: true)

    case "deleteAccountSecrets":
      let identity = try self.identity(request, includeGraph: false)
      try deleteAccountSecrets(
        identity: identity,
        environment: ProcessInfo.processInfo.environment
      )
      return JournalCryptoResponse(ok: true, wrappedKeysDeleted: true, privateKeyDeleted: true)

    case "unwrapGraphKeyForEngine":
      return JournalCryptoResponse(ok: true, value: hex(try decryptedGraphKey(request)))

    default:
      throw JournalE2EECryptoError.invalidRequest
    }
  }
}

// Never serialize descriptions/userInfo: crypto errors can contain key material.
func journalCryptoFailureCode(_ error: any Error) -> String {
  if error is DecodingError { return "cryptoInvalidRequest" }
  if let crypto = error as? CryptoKitError, case .authenticationFailure = crypto {
    return "cryptoAuthenticationFailed"
  }
  switch error as? JournalE2EECryptoError {
  case .invalidRequest: return "cryptoInvalidRequest"
  case .invalidPrivateKey: return "cryptoInvalidPrivateKey"
  case .rsaDecryptionFailed: return "cryptoRSADecryptionFailed"
  case .invalidGraphKeyLength: return "cryptoInvalidGraphKeyLength"
  case .invalidAESInput: return "cryptoInvalidAESInput"
  case .enginePrivateKeyUnavailable: return "cryptoEnginePrivateKeyUnavailable"
  case .keyStoreInvalidType: return "cryptoKeyStoreInvalidType"
  case .keyStoreFailure(let status):
    switch status {
    case errSecInteractionNotAllowed: return "cryptoKeyStoreLocked"
    case errSecAuthFailed, errSecMissingEntitlement: return "cryptoKeyStorePermissionDenied"
    case errSecNotAvailable: return "cryptoKeyStoreUnavailable"
    case errSecDecode: return "cryptoKeyStoreDecodeFailed"
    default: return "cryptoKeyStoreFailed"
    }
  default: return "cryptoOperationFailed"
  }
}

@_cdecl("logseq_journal_crypto_json")
public func logseqJournalCryptoJSON(
  _ requestPointer: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
  return autoreleasepool { () -> UnsafeMutablePointer<CChar>? in
    let response: JournalCryptoResponse
    var trace: JournalUnlockTrace?
    let previousTrace = JournalUnlockTrace.current
    defer { JournalUnlockTrace.current = previousTrace }
    var diagnosticResult = "ok"
    do {
      guard
        let requestPointer,
        let data = String(cString: requestPointer).data(using: .utf8)
      else { throw JournalE2EECryptoError.invalidRequest }
      let request = try JSONDecoder().decode(JournalCryptoRequest.self, from: data)
      trace = JournalUnlockTrace(request)
      JournalUnlockTrace.current = trace
      response = try JournalE2EECrypto.handle(request)
    } catch JournalE2EECryptoError.localPrivateKeyUnavailable {
      diagnosticResult = "local-private-key-unavailable"
      response = JournalCryptoResponse(ok: false, error: "localPrivateKeyUnavailable", cleanupPending: trace?.cleanupPending == true ? true : nil)
    } catch JournalE2EECryptoError.wrappedGraphKeyUnavailable {
      diagnosticResult = "wrapped-key-unavailable"
      response = JournalCryptoResponse(ok: false, error: "wrappedGraphKeyUnavailable", reason: trace?.failureReason, cleanupPending: trace?.cleanupPending == true ? true : nil)
    } catch {
      let reason = journalCryptoFailureCode(error)
      diagnosticResult = reason
      response = JournalCryptoResponse(ok: false, error: reason, reason: trace?.failureReason, cleanupPending: trace?.cleanupPending == true ? true : nil)
    }
    if ProcessInfo.processInfo.environment["JOURNAL_UNLOCK_DIAGNOSTICS"] == "1" {
      if trace == nil { trace = JournalUnlockTrace(nil) }
      trace?.finish(diagnosticResult)
    }
    guard
      let data = try? JSONEncoder().encode(response),
      let string = String(data: data, encoding: .utf8)
    else { return nil }
    return strdup(string)
  }
}

// This synchronous ABI borrows stable C buffers and returns malloc-owned bytes.
// Only key management uses the JSON bridge; payloads stay binary end to end.
@_cdecl("logseq_journal_crypto_binary")
public func logseqJournalCryptoBinary(
  _ sealing: Int32,
  _ key: UnsafePointer<UInt8>?, _ keyLength: Int,
  _ iv: UnsafePointer<UInt8>?, _ ivLength: Int,
  _ input: UnsafePointer<UInt8>?, _ inputLength: Int,
  _ outputLength: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UInt8>? {
  autoreleasepool {
    // Negative lengths are finite failure sentinels consumed only when returning nil.
    outputLength?.pointee = -1
    guard let key, let input, let outputLength,
      keyLength == 32, inputLength >= 0,
      (sealing == 1 && ivLength == 0 && inputLength <= 8 * 1024 * 1024)
        || (sealing == 0 && ivLength == 12 && inputLength >= 16
          && inputLength <= 8 * 1024 * 1024 + 16)
    else { return nil }
    outputLength.pointee = -4
    do {
      let symmetricKey = SymmetricKey(data: Data(bytes: key, count: keyLength))
      let data = Data(bytes: input, count: inputLength)
      let result: Data
      if sealing == 1 {
        guard let combined = try AES.GCM.seal(data, using: symmetricKey).combined
        else { return nil }
        result = combined
      } else {
        guard let iv else { outputLength.pointee = -1; return nil }
        let box = try AES.GCM.SealedBox(
          nonce: AES.GCM.Nonce(data: Data(bytes: iv, count: ivLength)),
          ciphertext: data.dropLast(16), tag: data.suffix(16))
        result = try AES.GCM.open(box, using: symmetricKey)
      }
      guard let allocation = malloc(max(1, result.count)) else {
        outputLength.pointee = -3
        return nil
      }
      let output = allocation.assumingMemoryBound(to: UInt8.self)
      result.copyBytes(to: output, count: result.count)
      outputLength.pointee = result.count
      return output
    } catch {
      if let crypto = error as? CryptoKitError, case .authenticationFailure = crypto {
        outputLength.pointee = -2
      }
      return nil
    }
  }
}
