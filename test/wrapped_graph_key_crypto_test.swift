import Darwin
import Foundation
import Security

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
  let encoded = try JSONSerialization.data(
    withJSONObject: ["~#'", "~b\(ciphertext.base64EncodedString())"]
  )
  guard let wrapped = String(data: encoded, encoding: .utf8) else {
    throw HarnessError.failed("failed to encode the wrapped graph key")
  }
  return (external, wrapped)
}

@main
private enum WrappedGraphKeyCryptoTest {
  static func main() throws {
    let origin = "https://api.logseq.io"
    let userID = "synthetic-user"
    let graphID = "10000000-0000-4000-8000-000000000001"
    let fixture = try makeFixture()
    setenv("LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE", "memory", 1)
    setenv("LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE", "memory", 1)
    defer {
      unsetenv("LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE")
      unsetenv("LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE")
      JournalE2EECrypto.resetTestMemoryPrivateKeys()
    }

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

    _ = try JournalE2EECrypto.handle([
      "operation": "installTestPrivateKey",
      "origin": origin,
      "userId": userID,
      "privateKey": hex(fixture.privateKey),
    ])
    _ = try JournalE2EECrypto.handle([
      "operation": "verifyAndSaveWrappedGraphKey",
      "origin": origin,
      "userId": userID,
      "graphId": graphID,
      "encryptedGraphKey": fixture.wrapped,
    ])
    let loaded = try JournalE2EECrypto.handle([
      "operation": "loadAndVerifyWrappedGraphKey",
      "origin": origin,
      "userId": userID,
      "graphId": graphID,
    ])
    try require(loaded["value"] as? String == fixture.wrapped, "wrapped key did not round trip")
    try JournalE2EECrypto.removeTestMemoryPrivateKey(origin: origin, userID: userID)
    do {
      _ = try JournalE2EECrypto.handle([
        "operation": "loadAndVerifyWrappedGraphKey",
        "origin": origin,
        "userId": userID,
        "graphId": graphID,
      ])
      throw HarnessError.failed("missing private key loaded the wrapped graph key")
    } catch JournalE2EECryptoError.localPrivateKeyUnavailable {
      // Expected: the serialized worker can report a distinct recovery reason.
    }
    _ = try JournalE2EECrypto.handle([
      "operation": "installTestPrivateKey",
      "origin": origin,
      "userId": userID,
      "privateKey": hex(fixture.privateKey),
    ])
    _ = try JournalE2EECrypto.handle([
      "operation": "verifyAndSaveWrappedGraphKey",
      "origin": origin,
      "userId": userID,
      "graphId": graphID,
      "encryptedGraphKey": fixture.wrapped,
    ])
    let transit = try JSONSerialization.jsonObject(with: Data(fixture.wrapped.utf8)) as? [String]
    guard let encodedCiphertext = transit?[1].dropFirst(2),
          let ciphertext = Data(base64Encoded: String(encodedCiphertext))
    else { throw HarnessError.failed("wrapped-key fixture could not be decoded") }
    let unwrapped = try JournalE2EECrypto.handle([
      "operation": "unwrapGraphKeyForEngine",
      "origin": origin,
      "userId": userID,
      "ciphertext": hex(ciphertext),
    ])
    try require(
      unwrapped["value"] as? String == String(repeating: "5a", count: 32),
      "Engine unwrap did not return the synthetic graph key"
    )
    try expectFailure("obsolete plaintext-returning operation remained callable") {
      _ = try JournalE2EECrypto.handle([
        "operation": "decryptGraphKeyForUser",
        "origin": origin,
        "userId": userID,
        "ciphertext": hex(ciphertext),
      ])
    }

    try expectFailure("another user loaded the wrapped key") {
      _ = try JournalE2EECrypto.handle([
        "operation": "loadAndVerifyWrappedGraphKey",
        "origin": origin,
        "userId": "another-user",
        "graphId": graphID,
      ])
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

    _ = try JournalE2EECrypto.handle([
      "operation": "deleteAccountSecrets",
      "origin": origin,
      "userId": userID,
    ])
    try expectFailure("account cleanup retained the wrapped graph key") {
      _ = try JournalE2EECrypto.handle([
        "operation": "loadAndVerifyWrappedGraphKey",
        "origin": origin,
        "userId": userID,
        "graphId": graphID,
      ])
    }
  }
}
