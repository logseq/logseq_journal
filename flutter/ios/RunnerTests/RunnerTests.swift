import Darwin
import Foundation
import Security
import XCTest

@testable import Runner

class RunnerTests: XCTestCase {
  func testWrappedGraphKeyQueryUsesExactDeviceOnlyAccountAndGraphScope() throws {
    let graphID = "10000000-0000-4000-8000-000000000001"
    let query = try JournalE2EECrypto.wrappedGraphKeyQuery(
      origin: "https://api.logseq.io",
      userID: "test-user",
      graphID: graphID
    )

    XCTAssertNil(query[kSecUseDataProtectionKeychain])
    XCTAssertEqual(
      query[kSecAttrService] as? String,
      "com.logseq.journal.e2ee.wrapped-graph-key"
    )
    XCTAssertEqual((query[kSecAttrAccount] as? String)?.count, 64)
    XCTAssertEqual((query[kSecAttrGeneric] as? Data)?.count, 32)
    XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
    XCTAssertNotEqual(
      query[kSecAttrAccount] as? String,
      try JournalE2EECrypto.wrappedGraphKeyQuery(
        origin: "https://api.logseq.io",
        userID: "test-user",
        graphID: "10000000-0000-4000-8000-000000000002"
      )[kSecAttrAccount] as? String
    )
  }

  func testOptInSignedRealKeychainUsesAnIsolatedDeviceOnlyItem() throws {
    guard ProcessInfo.processInfo.environment["LOGSEQ_JOURNAL_RUN_REAL_KEYCHAIN_TESTS"] == "1"
    else {
      throw XCTSkip("Set LOGSEQ_JOURNAL_RUN_REAL_KEYCHAIN_TESTS=1 for the signed Keychain lane")
    }
    let attributes = try JournalE2EECrypto.probeIsolatedRealWrappedKeychainItem(
      origin: "https://api.logseq.io",
      userID: "signed-test-\(UUID().uuidString)",
      graphID: UUID().uuidString.lowercased()
    )
    XCTAssertTrue(
      try XCTUnwrap(attributes[kSecAttrService] as? String)
        .hasPrefix("com.logseq.journal.e2ee.wrapped-graph-key.test.")
    )
    XCTAssertEqual(
      attributes[kSecAttrAccessible] as? String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
    XCTAssertNotEqual(attributes[kSecAttrSynchronizable] as? Bool, true)
  }

  func testWrappedGraphKeyCacheIsScopedVerifiedAndDeletedWithAccountSecrets() throws {
    let privateKeyAttributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits: 4096,
    ]
    var keyError: Unmanaged<CFError>?
    let privateKey = try XCTUnwrap(
      SecKeyCreateRandomKey(privateKeyAttributes as CFDictionary, &keyError)
    )
    let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
    let graphKey = Data(repeating: 0x5a, count: 32)
    let wrapped = try XCTUnwrap(
      SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, graphKey as CFData, nil)
        as Data?
    )
    let transit = try XCTUnwrap(
      String(
        data: JSONSerialization.data(
          withJSONObject: ["~#'", "~b\(wrapped.base64EncodedString())"]
        ),
        encoding: .utf8
      )
    )
    let origin = "https://api.logseq.io"
    let userID = "wrapped-cache-user-\(UUID().uuidString)"
    let graphID = UUID().uuidString.lowercased()
    setenv("LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE", "memory", 1)
    setenv("LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE", "memory", 1)
    defer {
      unsetenv("LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE")
      unsetenv("LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE")
      JournalE2EECrypto.resetTestMemoryPrivateKeys()
    }

    XCTAssertTrue(
      try XCTUnwrap(
        JournalE2EECrypto.handle([
          "operation": "installTestPrivateKey",
          "origin": origin,
          "userId": userID,
          "privateKey": Data(
            try XCTUnwrap(SecKeyCopyExternalRepresentation(privateKey, nil)) as Data
          ).map { String(format: "%02x", $0) }.joined(),
        ])["ok"] as? Bool
      )
    )
    XCTAssertTrue(
      try XCTUnwrap(
        JournalE2EECrypto.handle([
          "operation": "verifyAndSaveWrappedGraphKey",
          "origin": origin,
          "userId": userID,
          "graphId": graphID,
          "encryptedGraphKey": transit,
        ])["ok"] as? Bool
      )
    )
    XCTAssertEqual(
      try JournalE2EECrypto.handle([
        "operation": "loadAndVerifyWrappedGraphKey",
        "origin": origin,
        "userId": userID,
        "graphId": graphID,
      ])["value"] as? String,
      transit
    )
    XCTAssertThrowsError(
      try JournalE2EECrypto.handle([
        "operation": "loadAndVerifyWrappedGraphKey",
        "origin": origin,
        "userId": "different-\(userID)",
        "graphId": graphID,
      ])
    )
    XCTAssertTrue(
      try XCTUnwrap(
        JournalE2EECrypto.handle([
          "operation": "deleteAccountSecrets",
          "origin": origin,
          "userId": userID,
        ])["ok"] as? Bool
      )
    )
    XCTAssertThrowsError(
      try JournalE2EECrypto.handle([
        "operation": "loadAndVerifyWrappedGraphKey",
        "origin": origin,
        "userId": userID,
        "graphId": graphID,
      ])
    )
  }

  func testLocalAccountBindingUsesDeviceOnlyApplicationKeychainStorage() throws {
    let query = JournalLocalAccountBindingStore.query()

    XCTAssertEqual(
      query[kSecAttrService] as? String,
      "com.logseq.journal.local-account-binding"
    )
    XCTAssertEqual(
      query[kSecAttrAccount] as? String,
      "current-managed-sync-account"
    )
    XCTAssertEqual(
      query[kSecAttrAccessible] as? String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
    let encoded = try JournalLocalAccountBindingStore.encode(
      userID: "cognito-user-1",
      managedSyncOrigin: "https://api.logseq.io"
    )
    XCTAssertEqual(
      try JournalLocalAccountBindingStore.decode(encoded)["managedSyncOrigin"] as? String,
      "https://api.logseq.io"
    )
  }

  func testStartupEnvironmentSnapshotIsTypedAndContentFree() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let payload = JournalPlatformEnvironment.snapshot(
      applicationSupportPath: "/tmp/support",
      applicationDataPath: "/tmp/app-data",
      now: Date(timeIntervalSince1970: 0),
      locale: Locale(identifier: "en_US"),
      timeZone: calendar.timeZone,
      calendar: calendar
    )

    XCTAssertEqual(payload["applicationSupportPath"] as? String, "/tmp/support")
    XCTAssertEqual(payload["platform"] as? String, "ios")
    XCTAssertEqual(payload["applicationDataPath"] as? String, "/tmp/app-data")
    XCTAssertEqual(payload["graphName"] as? String, "logseq_journal")
    XCTAssertEqual(payload["instantUnixMilliseconds"] as? Int64, 0)
    XCTAssertEqual(payload["localDay"] as? Int, 19_700_101)
    XCTAssertEqual(payload["locale"] as? String, "en_US")
    XCTAssertEqual(payload["timeZoneId"] as? String, calendar.timeZone.identifier)
    XCTAssertEqual(payload["utcOffsetSeconds"] as? Int, 0)
    XCTAssertEqual(payload["generation"] as? Int64, 1)
    XCTAssertNil(payload["content"])
  }

  func testJournalDayFormattingUsesACompactLocalizedTemplate() throws {
    let english = try JournalPlatformEnvironment.formatJournalDays(
      arguments: [
        "days": [20_260_807],
        "locale": "en_US",
        "timeZoneId": "UTC",
      ]
    )
    XCTAssertEqual(english.count, 1)
    XCTAssertEqual(english[0]["day"] as? Int, 20_260_807)
    XCTAssertEqual(english[0]["heading"] as? String, "Fri, Aug 7")

    let chinese = try JournalPlatformEnvironment.formatJournalDays(
      arguments: [
        "days": [20_260_807],
        "locale": "zh_CN",
        "timeZoneId": "Asia/Shanghai",
      ]
    )
    let reordered = try XCTUnwrap(chinese[0]["heading"] as? String)
    XCTAssertTrue(reordered.contains("8月7日"))
    XCTAssertTrue(reordered.contains("周五"))
    XCTAssertFalse(reordered.contains("2026"))
  }
}
