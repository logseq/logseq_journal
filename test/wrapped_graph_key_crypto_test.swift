import Darwin
import Foundation
import Security
import OSLog

private enum HarnessError: Error {
  case failed(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw HarnessError.failed(message) }
}

private func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
  do {
    try operation()
  } catch {
    return
  }
  throw HarnessError.failed(message)
}

private func hex(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

private func makeFixture() throws -> (privateKey: Data, wrapped: String) {
  let attributes: [CFString: Any] = [
    kSecAttrKeyType: kSecAttrKeyTypeRSA,
    kSecAttrKeySizeInBits: 4096,
  ]
  var keyError: Unmanaged<CFError>?
  guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError),
        let publicKey = SecKeyCopyPublicKey(privateKey),
        let external = SecKeyCopyExternalRepresentation(privateKey, &keyError) as Data?
  else { throw HarnessError.failed("failed to create a synthetic RSA fixture") }
  let graphKey = Data(repeating: 0x5a, count: 32)
  guard
    let ciphertext = SecKeyCreateEncryptedData(
      publicKey,
      .rsaEncryptionOAEPSHA256,
      graphKey as CFData,
      &keyError
    ) as Data?
  else { throw HarnessError.failed("failed to wrap the synthetic graph key") }
  let encoded = try JSONEncoder().encode(["~#'", "~b\(ciphertext.base64EncodedString())"])
  guard let wrapped = String(data: encoded, encoding: .utf8) else {
    throw HarnessError.failed("failed to encode the wrapped graph key")
  }
  return (external, wrapped)
}

private func rsaFormatTest() throws {
  func der(_ tag: UInt8, _ contents: Data) -> Data {
    let count = contents.count
    let length: [UInt8] = count < 128 ? [UInt8(count)]
      : count < 256 ? [0x81, UInt8(count)]
      : [0x82, UInt8(count >> 8), UInt8(count & 255)]
    return Data([tag] + length) + contents
  }
  let fixture = try makeFixture()
  let version = Data([0x02, 0x01, 0x00])
  let rsaAlgorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
    0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
  let pkcs8 = der(0x30, version + rsaAlgorithm + der(0x04, fixture.privateKey))
  func verify(_ key: Data) throws {
    _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
      operation: "installTestPrivateKey", origin: "https://example.invalid",
      userId: "rsa-format-synthetic", privateKey: hex(key)))
    _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
      operation: "verifyAndSaveWrappedGraphKey", origin: "https://example.invalid",
      userId: "rsa-format-synthetic", graphId: "10000000-0000-4000-8000-000000000002",
      encryptedGraphKey: fixture.wrapped))
  }
  try verify(fixture.privateKey)
  let started = Date()
  try verify(pkcs8)
  Thread.sleep(forTimeInterval: 2)
  let store = try OSLogStore(scope: .currentProcessIdentifier)
  let entries = try store.getEntries(at: store.position(date: started))
  let errors = entries.compactMap { $0 as? OSLogEntryLog }.filter {
    $0.level == .error && ($0.subsystem.contains("security") || $0.composedMessage.contains("SecKey"))
  }
  print("synthetic-pkcs8 Security E count=\(errors.count)")
  try require(errors.isEmpty, "valid PKCS8 emitted a Security error")
  try verify(der(0x30, version + rsaAlgorithm + der(0x04, fixture.privateKey) + Data([0xa0, 0])))
  try verify(der(0x30, version + der(0x30, Data(rsaAlgorithm.dropFirst(2).dropLast(2)))
    + der(0x04, fixture.privateKey)))
  let attributeOID = Data([0x06, 0x02, 0x2a, 0x03])
  let attribute = der(0x30, attributeOID + der(0x31, der(0x0c, Data("synthetic".utf8))))
  func withAttributes(_ attributes: Data) -> Data {
    der(0x30, version + rsaAlgorithm + der(0x04, fixture.privateKey) + der(0xa0, attributes))
  }
  try verify(withAttributes(attribute))
  var nested = der(0x05, Data())
  for _ in 0..<20 { nested = der(0x30, nested) }
  let invalidAttributes = [
    Data([0x30]),
    der(0x30, attributeOID),
    der(0x30, der(0x05, Data()) + der(0x31, der(0x05, Data()))),
    der(0x30, Data([0x06, 0x01, 0x80]) + der(0x31, der(0x05, Data()))),
    der(0x30, attributeOID + der(0x31, Data([0x30]))),
    der(0x30, attributeOID + der(0x31, Data([0x0c, 0x81, 0x01, 0x61]))),
    der(0x30, attributeOID + der(0x31, nested)),
    attribute + Data([0]),
  ]
  for attributes in invalidAttributes {
    do {
      try verify(withAttributes(attributes))
      throw HarnessError.failed("malformed attributes accepted: \(hex(attributes))")
    } catch let error as JournalE2EECryptoError {
      try require(journalCryptoFailureCode(error) == "cryptoInvalidPrivateKey",
        "malformed attributes lost their typed cause")
    }
  }
  print("synthetic attributes: nonempty accepted; malformed rejected=\(invalidAttributes.count)")
  var otherAlgorithm = rsaAlgorithm
  otherAlgorithm[12] = 0x02
  let cases: [(Data, String)] = [
    (pkcs8 + Data([0]), "cryptoInvalidPrivateKey"),
    (Data(pkcs8.dropLast()), "cryptoInvalidPrivateKey"),
    (Data([0x30, 0x88, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), "cryptoInvalidPrivateKey"),
    (der(0x30, version + otherAlgorithm + der(0x04, fixture.privateKey)), "cryptoUnsupportedPrivateKey"),
    (der(0x30, Data([0x02, 0x01, 0x01]) + rsaAlgorithm + der(0x04, fixture.privateKey)), "cryptoUnsupportedPrivateKey"),
    (der(0x30, version + rsaAlgorithm + der(0x04, Data([0x30, 0]))), "cryptoInvalidPrivateKey"),
  ]
  for (key, expected) in cases {
    do {
      try verify(key)
      throw HarnessError.failed("malformed or unsupported RSA input was accepted")
    } catch let error as JournalE2EECryptoError {
      try require(journalCryptoFailureCode(error) == expected, "RSA format failure lost its typed cause")
    }
  }
}

private func unlockLogTest() throws {
  let capture = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("journal-unlock-log-\(UUID().uuidString)")
  FileManager.default.createFile(atPath: capture.path, contents: nil)
  let output = try FileHandle(forWritingTo: capture)
  let previous = dup(STDERR_FILENO)
  fflush(stderr)
  dup2(output.fileDescriptor, STDERR_FILENO)
  defer {
    fflush(stderr)
    dup2(previous, STDERR_FILENO)
    close(previous)
    try? output.close()
    try? FileManager.default.removeItem(at: capture)
    unsetenv("JOURNAL_UNLOCK_DIAGNOSTICS")
  }
  @discardableResult
  func invoke(_ object: [String: Any]) throws -> JournalCryptoResponse {
    let data = try JSONSerialization.data(withJSONObject: object)
    let response = String(decoding: data, as: UTF8.self).withCString {
      logseqJournalCryptoJSON($0)
    }
    guard let response else { throw HarnessError.failed("missing crypto response") }
    defer { free(response) }
    return try JSONDecoder().decode(
      JournalCryptoResponse.self, from: Data(String(cString: response).utf8))
  }
  let secrets = ["LOG_SECRET_PASSWORD", "LOG_SECRET_USER", "LOG_SECRET_KEY",
    "LOG_SECRET_GRAPH", "LOG_SECRET_BODY", "LOG_SECRET_OPERATION"]
  let request: [String: Any] = [
    "operation": "unlockPrivateKey", "origin": "https://example.invalid",
    "userId": secrets[1], "password": secrets[0], "graphId": secrets[3],
    "privateKey": secrets[2], "encryptedGraphKey": secrets[4],
    "iterations": 600_000, "salt": "00", "iv": "000000000000000000000000",
    "ciphertext": "00000000000000000000000000000000", "diagnosticOperation": "109",
  ]
  unsetenv("JOURNAL_UNLOCK_DIAGNOSTICS")
  try invoke(request)
  let disabledLogs = try Data(contentsOf: capture)
  try require(disabledLogs.isEmpty, "diagnostics must be opt-in")
  setenv("JOURNAL_UNLOCK_DIAGNOSTICS", "1", 1)
  let authenticationFailure = try invoke(request)
  var logs = try String(contentsOf: capture, encoding: .utf8)
  try require(logs.contains("source=crypto op=109 request=unlockPrivateKey phase=begin"),
    "native request must preserve the numeric runner operation ID")
  try require(logs.contains("stage=derive-private-key") && logs.contains("stage=open-private-key"),
    "native crypto must expose the actual failing stage")
  try require(!authenticationFailure.ok
      && authenticationFailure.error == "cryptoAuthenticationFailed",
    "native crypto must return the precise authentication failure")
  let terminalRecords = logs.split(separator: "\n").map { $0.split(separator: " ") }
    .filter { $0.contains("source=crypto") && $0.contains("op=109")
      && $0.contains("request=unlockPrivateKey") && $0.contains("phase=end") }
  try require(terminalRecords.count == 1,
    "native crypto must record exactly one terminal result for the request")
  let terminal = terminalRecords[0]
  try require(terminal.contains("result=cryptoAuthenticationFailed")
      && terminal.contains("stage=open-private-key"),
    "native crypto terminal result must preserve the response cause and failing stage")
  let elapsed = terminal.first { $0.hasPrefix("elapsed_ms=") }?.dropFirst("elapsed_ms=".count)
  try require(elapsed.map { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
      && (Int($0).map { $0 >= 0 } ?? false) } ?? false,
    "native crypto terminal duration must be a nonnegative integer")
  try invoke(["operation": "loadAndVerifyWrappedGraphKey", "origin": "https://example.invalid",
    "userId": secrets[1], "graphId": "10000000-0000-4000-8000-000000000999",
    "diagnosticOperation": "110"])
  logs = try String(contentsOf: capture, encoding: .utf8)
  try require(logs.contains("result=wrapped-key-unavailable"), "missing cached wrapped key is distinct")
  for _ in 0..<300 {
    try invoke(["operation": secrets[5], "origin": "https://example.invalid",
      "userId": secrets[1], "diagnosticOperation": secrets[4]])
  }
  logs = try String(contentsOf: capture, encoding: .utf8)
  for secret in secrets {
    try require(!logs.contains(secret), "native diagnostics leaked a sensitive marker")
  }
  try require(logs.contains("source=crypto limit=reached"), "native diagnostics must cap output")
  try require(logs.split(separator: "\n").count <= 257, "native diagnostics exceeded the cap")
}

@main
private enum WrappedGraphKeyCryptoTest {
  static func main() throws {
    let origin = "https://api.logseq.io"
    let userID = "synthetic-user"
    let graphID = "10000000-0000-4000-8000-000000000001"
    setenv("LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE", "memory", 1)
    setenv("LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE", "memory", 1)
    defer {
      unsetenv("LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE")
      unsetenv("LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE")
      JournalE2EECrypto.resetTestMemoryPrivateKeys()
    }

    try rsaFormatTest()
    try unlockLogTest()

    let malformed = "{\"operation\":\"deleteAccountSecrets\",\"origin\":\"\(origin)\",\"userId\":\"\(userID)\",\"iterations\":\"600000\"}"
    let malformedResponse = malformed.withCString { logseqJournalCryptoJSON($0) }
    guard let malformedResponse else { throw HarnessError.failed("missing malformed response") }
    defer { free(malformedResponse) }
    let malformedObject = try JSONSerialization.jsonObject(
      with: Data(String(cString: malformedResponse).utf8)) as? [String: Any]
    try require(malformedObject?["ok"] as? Bool == false,
      "generated crypto decoder ignored an invalid typed field")

    let fixture = try makeFixture()
    let query = try JournalE2EECrypto.wrappedGraphKeyQuery(
      origin: origin,
      userID: userID,
      graphID: graphID
    )
    try require(
      query[kSecAttrService] as? String == "com.logseq.journal.e2ee.wrapped-graph-key",
      "wrapped key used the wrong Keychain service"
    )
    try require((query[kSecAttrAccount] as? String)?.count == 64, "graph digest is invalid")
    try require((query[kSecAttrGeneric] as? Data)?.count == 32, "account digest is invalid")
    try require(
      query[kSecAttrAccessible] == nil,
      "accessibility belongs to the add attributes, not an exact lookup query"
    )

    _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
      operation: "installTestPrivateKey",
      origin: origin,
      userId: userID,
      privateKey: hex(fixture.privateKey)
    ))
    _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
      operation: "verifyAndSaveWrappedGraphKey",
      origin: origin,
      userId: userID,
      graphId: graphID,
      encryptedGraphKey: fixture.wrapped
    ))
    let loaded = try JournalE2EECrypto.handle(JournalCryptoRequest(
      operation: "loadAndVerifyWrappedGraphKey",
      origin: origin,
      userId: userID,
      graphId: graphID
    ))
    try require(loaded.value == fixture.wrapped, "wrapped key did not round trip")
    try JournalE2EECrypto.removeTestMemoryPrivateKey(origin: origin, userID: userID)
    do {
      _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
        operation: "loadAndVerifyWrappedGraphKey",
        origin: origin,
        userId: userID,
        graphId: graphID
      ))
      throw HarnessError.failed("missing private key loaded the wrapped graph key")
    } catch JournalE2EECryptoError.localPrivateKeyUnavailable {
      // Expected: the serialized worker can report a distinct recovery reason.
    }
    _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
      operation: "installTestPrivateKey",
      origin: origin,
      userId: userID,
      privateKey: hex(fixture.privateKey)
    ))
    _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
      operation: "verifyAndSaveWrappedGraphKey",
      origin: origin,
      userId: userID,
      graphId: graphID,
      encryptedGraphKey: fixture.wrapped
    ))
    let transit = try JSONDecoder().decode([String].self, from: Data(fixture.wrapped.utf8))
    let encodedCiphertext = transit[1].dropFirst(2)
    guard let ciphertext = Data(base64Encoded: String(encodedCiphertext))
    else { throw HarnessError.failed("wrapped-key fixture could not be decoded") }
    let unwrapped = try JournalE2EECrypto.handle(JournalCryptoRequest(
      operation: "unwrapGraphKeyForEngine",
      origin: origin,
      userId: userID,
      ciphertext: hex(ciphertext)
    ))
    try require(
      unwrapped.value == String(repeating: "5a", count: 32),
      "Engine unwrap did not return the synthetic graph key"
    )
    try expectFailure("obsolete plaintext-returning operation remained callable") {
      _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
        operation: "decryptGraphKeyForUser",
        origin: origin,
        userId: userID,
        ciphertext: hex(ciphertext)
      ))
    }

    try expectFailure("another user loaded the wrapped key") {
      _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
        operation: "loadAndVerifyWrappedGraphKey",
        origin: origin,
        userId: "another-user",
        graphId: graphID
      ))
    }
    try expectFailure("an invalid origin was accepted") {
      _ = try JournalE2EECrypto.wrappedGraphKeyQuery(
        origin: "http://api.logseq.io",
        userID: userID,
        graphID: graphID
      )
    }
    try expectFailure("a noncanonical graph UUID was accepted") {
      _ = try JournalE2EECrypto.wrappedGraphKeyQuery(
        origin: origin,
        userID: userID,
        graphID: "10000000-0000-4000-8000-00000000000A"
      )
    }

    _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
      operation: "deleteAccountSecrets",
      origin: origin,
      userId: userID
    ))
    try expectFailure("account cleanup retained the wrapped graph key") {
      _ = try JournalE2EECrypto.handle(JournalCryptoRequest(
        operation: "loadAndVerifyWrappedGraphKey",
        origin: origin,
        userId: userID,
        graphId: graphID
      ))
    }
  }
}
