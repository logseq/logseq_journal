import Foundation
import Darwin
import Security
import XCTest
@testable import bonsai_flutter_logseq_journal_host

class RunnerTests: XCTestCase {
  func testMacOSHostIsNotSandboxedForFixedGraphDirectory() throws {
    let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
    let sandboxValue = SecTaskCopyValueForEntitlement(
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

  func testE2EEPrivateKeyUsesTheAvailableMacOSKeychain() {
    let query = JournalE2EECrypto.keychainQuery(userID: "test-user")

    XCTAssertNil(query[kSecUseDataProtectionKeychain])
    XCTAssertEqual(query[kSecAttrService] as? String, "com.logseq.journal.e2ee.private-key")
    XCTAssertEqual(query[kSecAttrAccount] as? String, "test-user")
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
      userID: userID,
      key: privateKey,
      environment: environment
    )

    XCTAssertEqual(
      try JournalE2EECrypto.loadPrivateKey(
        userID: userID,
        environment: environment
      ),
      privateKey
    )
    XCTAssertNil(
      try JournalE2EECrypto.loadPrivateKey(
        userID: "different-\(userID)",
        environment: environment
      )
    )
    var keychainResult: CFTypeRef?
    XCTAssertEqual(
      SecItemCopyMatching(
        JournalE2EECrypto.keychainQuery(userID: userID) as CFDictionary,
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
      userID: userID,
      key: Data([0x01]),
      environment: environment
    )
    try JournalE2EECrypto.savePrivateKey(
      userID: userID,
      key: Data([0x02]),
      environment: environment
    )

    XCTAssertEqual(
      try JournalE2EECrypto.loadPrivateKey(
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
    XCTAssertEqual(payload["localDay"] as? Int, 19700101)
    XCTAssertEqual(payload["locale"] as? String, "en_US")
    XCTAssertEqual(payload["timeZoneId"] as? String, calendar.timeZone.identifier)
    XCTAssertEqual(payload["utcOffsetSeconds"] as? Int, 0)
    XCTAssertEqual(payload["generation"] as? Int64, 1)
    XCTAssertNil(payload["content"])
  }

  func testJournalDayFormattingUsesACompactLocalizedTemplate() throws {
    let english = try JournalPlatformEnvironment.formatJournalDays(
      arguments: [
        "days": [20260807],
        "locale": "en_US",
        "timeZoneId": "UTC",
      ]
    )
    XCTAssertEqual(english.count, 1)
    XCTAssertEqual(english[0]["day"] as? Int, 20260807)
    XCTAssertEqual(english[0]["heading"] as? String, "Fri, Aug 7")

    let chinese = try JournalPlatformEnvironment.formatJournalDays(
      arguments: [
        "days": [20260807],
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
