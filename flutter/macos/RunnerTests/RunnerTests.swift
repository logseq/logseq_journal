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
