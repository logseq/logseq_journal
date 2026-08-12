import Foundation
import XCTest
@testable import bonsai_flutter_logseq_journal_host

class RunnerTests: XCTestCase {
  func testStartupEnvironmentSnapshotIsTypedAndContentFree() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let payload = JournalPlatformEnvironment.snapshot(
      applicationSupportPath: "/tmp/support",
      now: Date(timeIntervalSince1970: 0),
      locale: Locale(identifier: "en_US"),
      timeZone: calendar.timeZone,
      calendar: calendar
    )

    XCTAssertEqual(payload["applicationSupportPath"] as? String, "/tmp/support")
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
