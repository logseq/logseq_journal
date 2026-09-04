import Cocoa
import Darwin
import Foundation
import Security
import XCTest

@testable import bonsai_flutter_logseq_journal_host

class RunnerTests: XCTestCase {
  func testApplicationLaunchCallbackCompletesOnCurrentFlutterHost() {
    let delegate = AppDelegate()

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )
  }

  func testStartupActivatesApplicationAndMakesMainWindowKey() {
    let target = ApplicationActivationTargetSpy()

    JournalApplicationStartup.activate(target)

    XCTAssertTrue(target.didActivateIgnoringOtherApps)
    XCTAssertTrue(target.didMakeMainWindowKeyAndVisible)
  }

  func testMacOSHostIsNotSandboxedForFixedGraphDirectory() throws {
    let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
    let sandboxValue =
      SecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.app-sandbox" as CFString,
        nil
      ) as? Bool

    XCTAssertNotEqual(sandboxValue, true)
  }

  func testCurrentEnvironmentUsesTheUnixAccountHomeOutsideTheSandboxContainer() throws {
    let account = try XCTUnwrap(getpwuid(getuid()))
    let expectedHome = String(cString: try XCTUnwrap(account.pointee.pw_dir))
    let payload = try JournalPlatformEnvironment.current()

    XCTAssertEqual(payload["homeDirectoryPath"] as? String, expectedHome)
    XCTAssertFalse(
      try XCTUnwrap(payload["homeDirectoryPath"] as? String)
        .contains("/Library/Containers/")
    )
  }

  func testE2EEPrivateKeyUsesTheDataProtectionKeychainAndAccountScope() throws {
    let query = try JournalE2EECrypto.privateKeyQuery(
      origin: "https://api.logseq.io",
      userID: "test-user"
    )

    XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
    XCTAssertEqual(query[kSecAttrService] as? String, "com.logseq.journal.e2ee.private-key")
    XCTAssertEqual((query[kSecAttrAccount] as? String)?.count, 64)
    XCTAssertNotEqual(query[kSecAttrAccount] as? String, "test-user")
  }

  func testWrappedGraphKeyQueryUsesExactDeviceOnlyAccountAndGraphScope() throws {
    let graphID = "10000000-0000-4000-8000-000000000001"
    let query = try JournalE2EECrypto.wrappedGraphKeyQuery(
      origin: "https://api.logseq.io",
      userID: "test-user",
      graphID: graphID
    )

    XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
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
    XCTAssertThrowsError(
      try JournalE2EECrypto.wrappedGraphKeyQuery(
        origin: "http://api.logseq.io",
        userID: "test-user",
        graphID: graphID
      )
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
    let loaded = try JournalE2EECrypto.handle([
      "operation": "loadAndVerifyWrappedGraphKey",
      "origin": origin,
      "userId": userID,
      "graphId": graphID,
    ])
    XCTAssertEqual(loaded["value"] as? String, transit)
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

  func testDebugFixtureInstallationSeedsOnlyTheRequestedEncryptedGraphScope() throws {
    let origin = "https://api.logseq.io"
    let userID = "compiled-runtime-user-\(UUID().uuidString)"
    let graphID = UUID().uuidString.lowercased()
    setenv("LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE", "memory", 1)
    setenv("LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE", "memory", 1)
    JournalE2EECrypto.resetTestMemoryPrivateKeys()
    defer {
      unsetenv("LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE")
      unsetenv("LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE")
      JournalE2EECrypto.resetTestMemoryPrivateKeys()
    }

    let installed = try JournalE2EECrypto.handle([
      "operation": "installTestWrappedGraphKeyFixture",
      "origin": origin,
      "userId": userID,
      "graphId": graphID,
    ])
    XCTAssertEqual(installed["ok"] as? Bool, true)
    XCTAssertNotNil(installed["encryptedGraphKey"] as? String)

    let loaded = try JournalE2EECrypto.handle([
      "operation": "loadAndVerifyWrappedGraphKey",
      "origin": origin,
      "userId": userID,
      "graphId": graphID,
    ])
    XCTAssertEqual(
      loaded["value"] as? String,
      installed["encryptedGraphKey"] as? String
    )
    let unwrapped = try JournalE2EECrypto.handle([
      "operation": "unwrapGraphKeyForEngine",
      "origin": origin,
      "userId": userID,
      "ciphertext": try XCTUnwrap(installed["ciphertext"] as? String),
    ])
    XCTAssertEqual((unwrapped["value"] as? String)?.count, 64)

    _ = try JournalE2EECrypto.handle([
      "operation": "deleteWrappedGraphKey",
      "origin": origin,
      "userId": userID,
      "graphId": graphID,
    ])
    XCTAssertThrowsError(
      try JournalE2EECrypto.handle([
        "operation": "loadAndVerifyWrappedGraphKey",
        "origin": origin,
        "userId": userID,
        "graphId": graphID,
      ])
    )
  }

  func testDebugFixtureInstallationRequiresBothMemorySecretStores() {
    XCTAssertFalse(
      JournalE2EECrypto.testFixtureStorageIsIsolated(environment: [:])
    )
    XCTAssertFalse(
      JournalE2EECrypto.testFixtureStorageIsIsolated(
        environment: [
          "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory"
        ]
      )
    )
    XCTAssertTrue(
      JournalE2EECrypto.testFixtureStorageIsIsolated(
        environment: [
          "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
          "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory",
        ]
      )
    )
  }

  func testLocalAccountBindingUsesDeviceOnlyApplicationKeychainStorage() throws {
    let query = JournalLocalAccountBindingStore.query()

    XCTAssertNil(query[kSecUseDataProtectionKeychain])
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
      try JournalLocalAccountBindingStore.decode(encoded)["userId"] as? String,
      "cognito-user-1"
    )
    XCTAssertThrowsError(
      try JournalLocalAccountBindingStore.decode(Data(repeating: 0, count: 4097)))
  }

  func testE2EETestMemoryPrivateKeyStorageIsUserScopedAndAvoidsKeychain() throws {
    let environment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory"
    ]
    let userID = "test-memory-\(UUID().uuidString)"
    let privateKey = Data([0x01, 0x02, 0x03])
    JournalE2EECrypto.resetTestMemoryPrivateKeys()
    defer { JournalE2EECrypto.resetTestMemoryPrivateKeys() }

    try JournalE2EECrypto.savePrivateKey(
      origin: "https://api.logseq.io",
      userID: userID,
      key: privateKey,
      environment: environment
    )

    XCTAssertEqual(
      try JournalE2EECrypto.loadPrivateKey(
        origin: "https://api.logseq.io",
        userID: userID,
        environment: environment
      ),
      privateKey
    )
    XCTAssertNil(
      try JournalE2EECrypto.loadPrivateKey(
        origin: "https://api.logseq.io",
        userID: "different-\(userID)",
        environment: environment
      )
    )
    var keychainResult: CFTypeRef?
    XCTAssertEqual(
      SecItemCopyMatching(
        try JournalE2EECrypto.privateKeyQuery(
          origin: "https://api.logseq.io",
          userID: userID
        ) as CFDictionary,
        &keychainResult
      ),
      errSecItemNotFound
    )
  }

  func testE2EETestMemoryPrivateKeyStorageReplacesTheSameUsersKey() throws {
    let environment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory"
    ]
    let userID = "test-memory-\(UUID().uuidString)"
    JournalE2EECrypto.resetTestMemoryPrivateKeys()
    defer { JournalE2EECrypto.resetTestMemoryPrivateKeys() }

    try JournalE2EECrypto.savePrivateKey(
      origin: "https://api.logseq.io",
      userID: userID,
      key: Data([0x01]),
      environment: environment
    )
    try JournalE2EECrypto.savePrivateKey(
      origin: "https://api.logseq.io",
      userID: userID,
      key: Data([0x02]),
      environment: environment
    )

    XCTAssertEqual(
      try JournalE2EECrypto.loadPrivateKey(
        origin: "https://api.logseq.io",
        userID: userID,
        environment: environment
      ),
      Data([0x02])
    )
  }

  func testStartupEnvironmentSnapshotIsTypedAndContentFree() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let payload = JournalPlatformEnvironment.snapshot(
      applicationSupportPath: "/tmp/support",
      homeDirectoryPath: "/Users/test",
      now: Date(timeIntervalSince1970: 0),
      locale: Locale(identifier: "en_US"),
      timeZone: calendar.timeZone,
      calendar: calendar
    )

    XCTAssertEqual(payload["applicationSupportPath"] as? String, "/tmp/support")
    XCTAssertEqual(payload["platform"] as? String, "desktop")
    XCTAssertEqual(payload["homeDirectoryPath"] as? String, "/Users/test")
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

private final class ApplicationActivationTargetSpy: JournalApplicationActivationTarget {
  private(set) var didActivateIgnoringOtherApps = false
  private(set) var didMakeMainWindowKeyAndVisible = false

  func activateIgnoringOtherApps() {
    didActivateIgnoringOtherApps = true
  }

  func makeMainWindowKeyAndVisible() {
    didMakeMainWindowKeyAndVisible = true
  }
}
