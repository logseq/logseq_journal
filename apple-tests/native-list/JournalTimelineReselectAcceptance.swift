import XCTest

/// Run only on the isolated scroll-top probe with synthetic long/image fixtures.
final class JournalTimelineReselectAcceptance: XCTestCase {
  @MainActor private func launch(reduceMotion: Bool = false) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "org.logseq.journal.scroll-top-probe")
    if reduceMotion { app.launchArguments = ["--reduce-motion"] }
    app.launch()
    XCTAssertTrue(control(app, "Journals").waitForExistence(timeout: 15))
    return app
  }

  @MainActor private func control(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  @MainActor private func first(_ app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Scroll row 0001")).firstMatch
  }

  @MainActor private func record(_ name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name; image.lifetime = .keepAlways; add(image)
  }

  @MainActor func testLongAttachmentsAndRepeatedTopRequests() {
    let app = launch()
    let top = first(app)
    XCTAssertTrue(top.waitForExistence(timeout: 10))
    let initialY = top.frame.minY
    control(app, "Journals").tap()
    XCTAssertEqual(top.frame.minY, initialY, accuracy: 2)
    for _ in 0..<8 { app.collectionViews.firstMatch.swipeUp(velocity: .fast) }
    record("Long list with image attachments before top")
    control(app, "Journals").tap()
    control(app, "Journals").tap()
    control(app, "Journals").tap()
    XCTAssertTrue(top.waitForExistence(timeout: 5))
    let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: top)
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
    XCTAssertEqual(top.frame.minY, initialY, accuracy: 2)
    record("Repeated Timeline taps return to true top")
  }

  @MainActor func testNavigationRetentionAndTopAfterScroll() {
    let app = launch()
    for _ in 0..<4 { app.collectionViews.firstMatch.swipeUp(velocity: .fast) }
    let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Scroll row"))
      .allElementsBoundByIndex.filter { $0.isHittable && $0.frame.midY > 250 && $0.frame.midY < 650 }
    XCTAssertFalse(rows.isEmpty)
    let row = rows[0], label = row.label, y = row.frame.minY
    row.tap()
    XCTAssertTrue(app.navigationBars.buttons["Back"].waitForExistence(timeout: 5))
    app.navigationBars.buttons["Back"].tap()
    let returned = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    XCTAssertTrue(returned.waitForExistence(timeout: 5))
    XCTAssertEqual(returned.frame.minY, y, accuracy: 2)
    control(app, "Favorites").tap()
    control(app, "Journals").tap()
    // Switching root destinations retains the existing navigation semantics;
    // the pure owner separately verifies this switch emits no top command.
    XCTAssertTrue(first(app).waitForExistence(timeout: 5))
    app.collectionViews.firstMatch.swipeUp(velocity: .fast)
    control(app, "Journals").tap()
    let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: first(app))
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
    record("Timeline tap returns to top after navigation")
  }

  @MainActor func testReduceMotionTop() {
    // A fixture-only Reduce Motion getter override, not a system preference change.
    let app = launch(reduceMotion: true)
    let initialY = first(app).frame.minY
    for _ in 0..<4 { app.collectionViews.firstMatch.swipeUp(velocity: .fast) }
    control(app, "Journals").tap()
    XCTAssertTrue(first(app).waitForExistence(timeout: 5))
    XCTAssertEqual(first(app).frame.minY, initialY, accuracy: 2)
    record("Reduce Motion top")
  }
}
