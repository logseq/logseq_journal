import XCTest

/// The native gesture/overlay lifetime is not observable at the OCaml reducer.
/// Run against an isolated three-resident offline warm-start fixture, not an account.
final class JournalGraphNameAcceptance: XCTestCase {
  @MainActor private func host(dark: Bool = false, longName: Bool = false, accessibility: Bool = false) -> XCUIApplication {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    let app = XCUIApplication(bundleIdentifier: env["JOURNAL_GRAPH_NAME_APP"] ?? "org.logseq.journal.graph-name-probe")
    app.launchEnvironment = ["LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
      "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory"]
    app.launchArguments = ["--fixture", longName ? "long.json" : "valid.json", "--support-root", longName ? "support-long" : "support-valid", "--application-only",
      dark ? "--dark-appearance" : "--light-appearance"]
    if accessibility { app.launchArguments.append("--accessibility-size") }
    app.launch()
    XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 30))
    // Restore the start through public gestures; last-graph persistence and
    // virtualization of picker rows must not make test ordering significant.
    for _ in 0..<3 {
      if title(1, app).exists && title(1, app).isHittable { break }
      swipe(app)
    }
    XCTAssertTrue(title(1, app).waitForExistence(timeout: 20))
    gone(app)
    return app
  }
  @MainActor private func title(_ graph: Int, _ app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Graph \(graph) —")).firstMatch
  }
  @MainActor private func capsule(_ app: XCUIApplication) -> XCUIElement {
    app.staticTexts["graph-switch-name"]
  }
  @MainActor private func swipe(_ app: XCUIApplication, short: Bool = false) {
    // The list's top blank region avoids rows and the existing floating controls.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset:
        CGVector(dx: short ? 0.29 : 0.78, dy: 0.15)), withVelocity: .slow, thenHoldForDuration: 0)
  }
  @MainActor private func record(_ name: String, _ app: XCUIApplication) {
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name + " accessibility"; tree.lifetime = .keepAlways; add(tree)
  }
  @MainActor private func gone(_ app: XCUIApplication) {
    let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: capsule(app))
    XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 2), .completed)
  }
  @MainActor func testNameCommitAndFade() {
    let app = host()
    XCTAssertTrue(title(1, app).waitForExistence(timeout: 20))
    XCTAssertFalse(capsule(app).exists)
    swipe(app)
    XCTAssertTrue(capsule(app).waitForExistence(timeout: 0.5), "A right swipe must identify its target")
    XCTAssertEqual(capsule(app).label, "Native encrypted graph 2")
    XCTAssertTrue(title(2, app).waitForExistence(timeout: 5))
    record("Graph 2 name after real native commit", app)
    gone(app)
    record("Name fades after commit", app)
  }
  @MainActor func testCancellationAndContinuousCycle() {
    let app = host()
    XCTAssertTrue(title(1, app).waitForExistence(timeout: 20))
    swipe(app, short: true)
    gone(app)
    XCTAssertTrue(title(1, app).isHittable)
    for graph in [2, 3, 1] {
      swipe(app)
      XCTAssertTrue(capsule(app).waitForExistence(timeout: 0.5))
      XCTAssertEqual(capsule(app).label, "Native encrypted graph \(graph)")
      XCTAssertTrue(title(graph, app).waitForExistence(timeout: 5))
      record("Consecutive graph \(graph)", app)
    }
    gone(app)
  }
  @MainActor func testDarkAppearanceAndTouchThrough() {
    let app = host(dark: true)
    XCTAssertTrue(title(1, app).waitForExistence(timeout: 20))
    swipe(app)
    XCTAssertTrue(capsule(app).waitForExistence(timeout: 0.5))
    XCTAssertEqual(capsule(app).label, "Native encrypted graph 2")
    record("Dark capsule", app)
    // The overlay must not consume touches destined for the production page.
    app.buttons["Options"].firstMatch.tap()
    XCTAssertTrue(app.buttons["Switch graph"].waitForExistence(timeout: 3))
    record("Menu works while name is visible", app)
  }
  @MainActor func testLongNameStaysClearOfMenu() {
    let app = host(longName: true)
    XCTAssertTrue(title(1, app).waitForExistence(timeout: 20))
    swipe(app)
    XCTAssertTrue(capsule(app).waitForExistence(timeout: 0.5))
    XCTAssertEqual(capsule(app).label, "Reading & Research — 工作笔记 and long-term notes")
    XCTAssertLessThan(capsule(app).frame.maxX, app.buttons["Options"].firstMatch.frame.minX - 4)
    XCTAssertGreaterThan(capsule(app).frame.minX, app.frame.minX + 16)
    let progress = app.activityIndicators.firstMatch
    if progress.exists {
      XCTAssertLessThanOrEqual(capsule(app).frame.maxX + 16, progress.frame.minX)
    }
    record("Long name preserves full accessibility text", app)
    gone(app)
  }

  @MainActor func testAccessibilitySizePreservesDateClearance() {
    let app = host(accessibility: true)
    swipe(app)
    XCTAssertTrue(capsule(app).waitForExistence(timeout: 0.5))
    // Native List's date accessibility frame includes top padding rather than
    // tight glyph bounds. Verify the HUD stays in the existing control band;
    // the retained screenshot supplies the date-ink clearance check.
    let controls = app.buttons["Options"].firstMatch.frame
    XCTAssertGreaterThanOrEqual(capsule(app).frame.minY, controls.minY)
    XCTAssertLessThanOrEqual(capsule(app).frame.maxY, controls.maxY)
    record("Accessibility size keeps date clear", app)
  }

}
