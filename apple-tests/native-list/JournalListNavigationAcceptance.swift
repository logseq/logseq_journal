import XCTest

/// Run only against the isolated 500-root encrypted navigation fixture.
final class JournalListNavigationAcceptance: XCTestCase {
  @MainActor private func launch(favorites: Bool = false) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "org.logseq.journal.warm-start-probe")
    app.launchEnvironment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
      "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory",
    ]
    app.launchArguments = favorites
      ? ["--fixture", "batch42-favorites-v2.json", "--support-root", "batch42-favorites-support-v2"]
      : ["--fixture", "batch41-performance.json", "--support-root", "batch41-support"]
    app.launch()
    XCTAssertTrue(app.buttons["Capture"].waitForExistence(timeout: 15))
    return app
  }

  @MainActor private func record(_ name: String, _ app: XCUIApplication) {
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name; tree.lifetime = .keepAlways; add(tree)
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name; image.lifetime = .keepAlways; add(image)
  }

  @MainActor private func middleRow(_ app: XCUIApplication) -> XCUIElement {
    let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Native row"))
      .allElementsBoundByIndex.filter { $0.isHittable && $0.frame.midY > 250 && $0.frame.midY < 650 }
    XCTAssertFalse(rows.isEmpty)
    return rows[rows.count / 2]
  }

  @MainActor private func returnFromDetail(_ row: XCUIElement, _ app: XCUIApplication) {
    let label = row.label
    let frame = row.frame
    record("Before detail", app)
    row.tap()
    XCTAssertTrue(app.buttons["Append"].waitForExistence(timeout: 5))
    app.buttons["BackButton"].tap()
    record("After detail Back", app)
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.waitForExistence(timeout: 5))
    let returned = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    XCTAssertTrue(returned.isHittable, "Detail Back lost the visible Journal row")
    XCTAssertEqual(returned.frame.minY, frame.minY, accuracy: 2, "Back moved the original row")
  }

  @MainActor private func openFromTrailingSpace(favorites: Bool) {
    let app = launch(favorites: favorites)
    if favorites { app.buttons["Favorites"].tap() }
    for _ in 0..<3 { app.collectionViews.firstMatch.swipeUp(velocity: .fast) }
    let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Native row"))
      .allElementsBoundByIndex.filter { $0.isHittable && $0.frame.midY > 510 && $0.frame.midY < 640 }
    XCTAssertFalse(rows.isEmpty)
    let row = rows[0]
    record("Before trailing-space tap", app)
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.5)).tap()
    XCTAssertTrue(app.buttons["Append"].waitForExistence(timeout: 5), "The visible row's trailing space did not open detail")
    app.buttons["BackButton"].tap()
    XCTAssertTrue(row.isHittable)
  }

  @MainActor func testJournalTrailingSpaceOpensDetail() { openFromTrailingSpace(favorites: false) }
  @MainActor func testFavoritesTrailingSpaceOpensDetail() { openFromTrailingSpace(favorites: true) }

  @MainActor func testMiddleRowSurvivesRepeatedDetailReturn() {
    let app = launch()
    for _ in 0..<5 { app.collectionViews.firstMatch.swipeUp(velocity: .fast) }
    let row = middleRow(app)
    let label = row.label
    returnFromDetail(row, app)
    returnFromDetail(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch, app)
  }

  @MainActor func testFavoritesRetainsPositionAfterDetailReturn() {
    let app = launch(favorites: true)
    app.buttons["Favorites"].tap()
    record("Favorites selected", app)
    XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 15))
    for _ in 0..<3 { app.collectionViews.firstMatch.swipeUp(velocity: .fast) }
    returnFromDetail(middleRow(app), app)
  }

  @MainActor func testFinalRootSurvivesDetailReturn() {
    let app = launch()
    let last = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Native row 0500")).firstMatch
    for _ in 0..<130 {
      if last.exists && last.isHittable { break }
      app.collectionViews.firstMatch.swipeUp(velocity: .fast)
    }
    XCTAssertTrue(last.isHittable)
    returnFromDetail(last, app)
  }

  @MainActor func testCaptureAndLifecycleRetainPositionAndSaveReturnsToTop() {
    let app = launch()
    for _ in 0..<3 { app.collectionViews.firstMatch.swipeUp(velocity: .fast) }
    let label = middleRow(app).label
    app.buttons["Capture"].tap()
    XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
    app.buttons["Close"].tap()
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.isHittable)
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
    app.activate()
    let activeScene = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Active"),
      object: app.staticTexts["warm-start-status"])
    XCTAssertEqual(XCTWaiter.wait(for: [activeScene], timeout: 5), .completed,
      "The fixture scene did not become active after foregrounding")
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.isHittable)
    app.buttons["Capture"].tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    let marker = "Navigation capture " + UUID().uuidString
    editor.tap(); editor.typeText(marker)
    app.buttons["Save"].tap()
    let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Graph 1 — Encrypted offline Journal")).firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 15))
    XCTAssertTrue(first.isHittable, "Explicit Capture save did not return the Journal to its top")
    record("Capture save returns Journal to top", app)
  }
}
