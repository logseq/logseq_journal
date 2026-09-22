import XCTest

/// Geometry acceptance for the public List; use only the disposable fixture host.
final class JournalListViewportTests: XCTestCase {
  @MainActor func testVisibleIdentitySurvivesReturnAndCaptureScroll() {
    let app = XCUIApplication(bundleIdentifier: "org.logseq.journal.warm-start-probe")
    continueAfterFailure = false
    app.launchEnvironment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
      "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory",
    ]
    app.launchArguments = ["--fixture", "batch41-performance.json", "--support-root", "batch41-support"]
    app.launch()
    XCTAssertTrue(app.buttons["Capture"].waitForExistence(timeout: 15))
    let list = app.collectionViews.firstMatch
    XCTAssertTrue(list.waitForExistence(timeout: 10))
    list.swipeUp()
    let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Native row"))
      .allElementsBoundByIndex.filter { $0.isHittable }
    XCTAssertFalse(rows.isEmpty)
    let row = rows[rows.count / 2]
    let label = row.label
    let position = row.frame.midY
    row.tap()
    XCTAssertTrue(app.buttons["Append"].waitForExistence(timeout: 5))
    app.buttons["BackButton"].tap()
    let returned = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    XCTAssertTrue(returned.waitForExistence(timeout: 5))
    XCTAssertEqual(returned.frame.midY, position, accuracy: 3)
    app.buttons["Capture"].tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    let inserted = "Viewport acceptance " + UUID().uuidString
    editor.tap()
    editor.typeText(inserted)
    app.buttons["Save"].tap()
    let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Graph 1 — Encrypted offline Journal")).firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertTrue(first.isHittable, "accepted Capture did not return to the first Journal row")
  }
}
