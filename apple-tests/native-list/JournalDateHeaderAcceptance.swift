import XCTest

/// Physical section layout only; run against a disposable multi-day warm-start graph.
final class JournalDateHeaderAcceptance: XCTestCase {
  @MainActor private func record(_ name: String, _ app: XCUIApplication) {
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name + " accessibility"
    tree.lifetime = .keepAlways
    add(tree)
    let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screen.name = name
    screen.lifetime = .keepAlways
    add(screen)
  }

  private func dateTitle(daysAgo: Int) -> String {
    let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy.MM.dd"
    return formatter.string(from: date).uppercased()
  }

  @MainActor private func launch(largeText: Bool, authFailure: Bool = false) -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication(bundleIdentifier: "org.logseq.journal.warm-start-probe")
    app.launchEnvironment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
      "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory",
    ]
    app.launchArguments = ["--fixture", "date-headers-final.json", "--support-root", "date-headers-final-support", "--application-only"]
    if authFailure { app.launchArguments.append("--auth-failure") }
    if largeText { app.launchArguments += ["--accessibility-size", "--dark-appearance"] }
    else { app.launchArguments.append("--light-appearance") }
    app.launch()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let wirelessPermission = springboard.alerts["允许“Logseq Journal”使用无线数据？"]
    if wirelessPermission.waitForExistence(timeout: 5) {
      wirelessPermission.buttons["不允许"].tap()
      XCTAssertTrue(wirelessPermission.waitForNonExistence(timeout: 5))
    }
    XCTAssertTrue(app.staticTexts[dateTitle(daysAgo: 0)].waitForExistence(timeout: 20))
    let topDate = app.staticTexts[dateTitle(daysAgo: 0)]
    let account = app.buttons["Account menu"]
    XCTAssertTrue(account.exists)
    XCTAssertTrue(app.navigationBars.allElementsBoundByIndex.allSatisfy { !$0.isHittable })
    XCTAssertGreaterThanOrEqual(account.frame.minY, 40)
    XCTAssertLessThan(topDate.frame.minY, 110)
    // Native List exposes the entire section header as the date AX frame.
    // Inspect retained screenshots for glyph/control overlap; that frame is full-width.
    record(largeText ? "Large header clearance" : "Header clearance", app)
    // The first section has native initial top spacing; alignment is checked once pinned.
    XCTAssertFalse(app.descendants(matching: .any)["journal-header-title"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["journal-header-weekday"].exists)
    return app
  }

  @MainActor private func visibleDate(_ title: String, in app: XCUIApplication) -> XCUIElement {
    app.collectionViews.staticTexts[title].firstMatch
  }

  @MainActor private func drag(_ list: XCUIElement, by points: CGFloat) {
    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7))
    let end = start.withOffset(CGVector(dx: 0, dy: -points))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
  }

  @MainActor func testDatesPinAndReplaceInBothDirections() {
    let app = launch(largeText: false)
    let list = app.collectionViews.firstMatch
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    var today: XCUIElement { visibleDate(dateTitle(daysAgo: 0), in: app) }
    var yesterday: XCUIElement { visibleDate(dateTitle(daysAgo: 1), in: app) }
    record("Date headers initial", app)
    drag(list, by: 40)
    let original = today.frame
    XCTAssertEqual(original.midY, app.buttons["Account menu"].frame.midY, accuracy: 12)
    record("Today at native pin line", app)
    var displaced = false
    for step in 0..<40 {
      if yesterday.exists && yesterday.frame.minY <= original.minY + 2 { break }
      let distance = yesterday.exists ? yesterday.frame.minY - original.minY : 100
      print("DATE_GEOMETRY before step \(step) today=\(today.exists ? today.frame.debugDescription : "absent") yesterday=\(yesterday.exists ? yesterday.frame.debugDescription : "absent")")
      drag(list, by: distance > 300 ? min(320, distance - 150) : (distance < 100 ? 20 : 40))
      XCTAssertFalse(app.navigationBars["Block"].exists, "A scroll gesture activated a row")
      if today.exists && today.frame.minY < original.minY - 1 { displaced = true }
      if distance < 100 { record("Date push-off step \(step)", app) }
    }
    XCTAssertTrue(yesterday.isHittable)
    XCTAssertEqual(yesterday.frame.minY, original.minY, accuracy: 3)
    XCTAssertEqual(yesterday.frame.minX, original.minX, accuracy: 1)
    XCTAssertEqual(yesterday.frame.height, original.height, accuracy: 1)
    XCTAssertTrue(displaced, "The incoming section must physically displace the outgoing date")
    record("Yesterday pinned", app)
    for _ in 0..<12 {
      drag(list, by: -30)
      if today.exists && abs(today.frame.minY - original.minY) < 3 { break }
    }
    XCTAssertTrue(today.isHittable)
    XCTAssertEqual(today.frame.minY, original.minY, accuracy: 3)
    record("Today restored by reverse scrolling", app)
    for _ in 0..<4 { list.swipeUp(velocity: .fast) }
    record("Fast history scrolling", app)
    for _ in 0..<5 { list.swipeDown(velocity: .fast) }
    XCTAssertTrue(today.isHittable)
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(today.waitForExistence(timeout: 5))
    record("Landscape date and toolbar", app)
    XCUIDevice.shared.orientation = .portrait
    record("Portrait restored", app)
  }

  @MainActor func testNativeNavigationActionsCaptureAndRefresh() {
    let app = launch(largeText: false)
    let list = app.collectionViews.firstMatch
    list.swipeUp(velocity: .slow)
    let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "History"))
      .allElementsBoundByIndex.filter { $0.isHittable && $0.frame.minY > 230 && $0.frame.maxY < 650 }
    XCTAssertFalse(rows.isEmpty)
    let row = rows[rows.count / 2]
    let label = row.label
    let before = row.frame
    record("Before historical detail", app)
    row.tap()
    XCTAssertTrue(app.buttons["Append"].waitForExistence(timeout: 5))
    app.buttons["BackButton"].tap()
    let returned = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    XCTAssertTrue(returned.waitForExistence(timeout: 5))
    XCTAssertTrue(returned.isHittable)
    XCTAssertEqual(returned.frame.minY, before.minY, accuracy: 3)
    record("Historical detail returned", app)
    returned.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Change status"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Delete block and descendants"].exists)
    app.buttons["Change status"].tap()
    XCTAssertTrue(app.navigationBars["Set status"].waitForExistence(timeout: 5))
    app.buttons["Close"].tap()
    app.buttons["Capture"].tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText("Unified date device Capture " + UUID().uuidString)
    app.buttons["Save"].tap()
    let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Graph 1 — Encrypted offline Journal")).firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertTrue(first.isHittable)
    XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", dateTitle(daysAgo: 0))).count, 1)
    record("Capture retains Today date", app)
    list.swipeDown(velocity: .slow)
    XCTAssertTrue(first.isHittable)
    XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", dateTitle(daysAgo: 0))).count, 1)
    record("Pull to refresh retains a single date", app)
  }

  @MainActor func testErrorDetailsAndFavoritesChrome() {
    let app = launch(largeText: true, authFailure: true)
    let error = app.buttons["Error info"]
    XCTAssertTrue(error.waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["Account menu"].isHittable)
    record("Floating sync error controls", app)
    error.tap()
    XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
    record("Sync error details", app)
    app.buttons["Close"].tap()
    XCTAssertTrue(app.buttons["Close"].waitForNonExistence(timeout: 5))
    XCUIDevice.shared.orientation = .landscapeLeft
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["Error info"])
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    XCTAssertTrue(app.buttons["Account menu"].isHittable)
    record("Landscape floating sync error controls", app)
    XCUIDevice.shared.orientation = .portrait
    app.buttons["Favorites"].tap()
    XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    record("Favorites retains navigation chrome", app)
    app.buttons["Journals"].tap()
    XCTAssertTrue(app.buttons["Account menu"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars.allElementsBoundByIndex.allSatisfy { !$0.isHittable })
  }

  @MainActor func testLargeTextDatesRemainSingleLine() {
    let app = launch(largeText: true)
    let list = app.collectionViews.firstMatch
    record("Accessibility size initial", app)
    list.swipeUp(velocity: .slow)
    record("Accessibility size scrolling", app)
    let account = app.buttons["Account menu"]
    XCTAssertTrue(account.isHittable)
    account.tap()
    XCTAssertTrue(app.buttons["Diagnostics"].waitForExistence(timeout: 5))
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.2)).tap()
    XCUIDevice.shared.orientation = .landscapeLeft
    record("Accessibility size landscape", app)
    XCTAssertTrue(app.buttons["Account menu"].isHittable)
    XCUIDevice.shared.orientation = .portrait
  }
}

/// Identical gestures for native Instruments comparisons; elapsed XCTest time is not a metric.
final class JournalScrollPerformance: XCTestCase {
  @MainActor func testRepeatableScroll() {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication(bundleIdentifier: "org.logseq.journal.warm-start-probe")
    app.launchEnvironment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
      "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory",
    ]
    app.launchArguments = ["--fixture", "date-headers-final.json", "--support-root", "date-headers-final-support", "--application-only", "--light-appearance"]
    app.launch()
    let list = app.collectionViews.firstMatch
    XCTAssertTrue(list.waitForExistence(timeout: 20))
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                      XCTHitchMetric(application: app)], options: options) {
    for _ in 0..<3 {
      let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.65))
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -100)), withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    for _ in 0..<5 { list.swipeUp(velocity: .slow) }
    for _ in 0..<5 { list.swipeDown(velocity: .slow) }
    }
  }
}
