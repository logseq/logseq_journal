import XCTest

final class JournalIPhoneAcceptance: XCTestCase {
  private let bundleID = "org.logseq.journal.warm-start-probe"
  private let captureMarker = "iPhone isolated Capture 32"
  private let appendMarker = "iPhone isolated Append 32"

  @MainActor private func application(relaunch: Bool = false) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: bundleID)
    app.launchEnvironment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
      "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory",
    ]
    app.launchArguments = ["--fixture", "valid.json", "--support-root", "support-valid"]
    if relaunch { app.terminate(); app.launch() } else { app.activate() }
    return app
  }

  @MainActor private func record(_ title: String, _ app: XCUIApplication) {
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = title + " accessibility"
    tree.lifetime = .keepAlways
    add(tree)
    let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screen.name = title
    screen.lifetime = .keepAlways
    add(screen)
  }

  @MainActor private func row(_ marker: String, in app: XCUIApplication) -> XCUIElement {
    app.collectionViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
  }

  @MainActor func testCaptureSaveAndStatus() {
    continueAfterFailure = false
    let app = application(relaunch: true)
    XCTAssertTrue(app.buttons["Capture"].waitForExistence(timeout: 25))
    XCTAssertTrue(app.staticTexts["warm-start-status"].label.hasPrefix("PASS"))
    record("Isolated encrypted iPhone timeline", app)
    app.buttons["Capture"].tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    XCTAssertEqual(editor.value as? String, "")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    editor.typeText(captureMarker)
    XCTAssertEqual(editor.value as? String, captureMarker)
    if app.buttons["Task"].value as? String != "1" { app.buttons["Task"].tap() }
    app.buttons["Save"].tap()
    let saved = row(captureMarker, in: app)
    for _ in 0..<150 {
      if saved.exists && saved.isHittable { break }
      app.collectionViews.firstMatch.swipeUp(velocity: .fast)
    }
    record("Capture after timeline paging", app)
    XCTAssertTrue(saved.isHittable)
    XCTAssertTrue(saved.label.contains("Todo"))
    record("Saved iPhone Capture", app)
    app.buttons["Capture"].tap()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "")
    app.buttons["Close"].firstMatch.tap()
    saved.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Change status"].waitForExistence(timeout: 5))
    app.buttons["Change status"].tap()
    XCTAssertTrue(app.navigationBars["Set status"].waitForExistence(timeout: 5))
    for _ in 0..<6 {
      if app.buttons["Done"].exists && app.buttons["Done"].isHittable { break }
      app.collectionViews.element(boundBy: app.collectionViews.count - 1).swipeUp()
    }
    XCTAssertTrue(app.buttons["Done"].isHittable)
    app.buttons["Done"].tap()
    let done = app.collectionViews.buttons.matching(NSPredicate(format:
      "label CONTAINS %@ AND label CONTAINS %@", captureMarker, "Done")).firstMatch
    XCTAssertTrue(done.waitForExistence(timeout: 10))
    record("Saved iPhone Done status", app)
  }

  @MainActor func testAppendAfterPartialChildren() {
    continueAfterFailure = false
    let app = application(relaunch: true)
    let parent = row("Graph 1 — Encrypted offline Journal", in: app)
    XCTAssertTrue(parent.waitForExistence(timeout: 25))
    parent.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Graph 1 — Encrypted offline Journal")).firstMatch.tap()
    XCTAssertTrue(app.buttons["Append"].waitForExistence(timeout: 10))
    app.buttons["Append"].tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.typeText(appendMarker)
    XCTAssertEqual(editor.value as? String, appendMarker)
    app.buttons["Save"].tap()
    XCTAssertTrue(app.navigationBars["Block"].waitForExistence(timeout: 10))
    record("Append saved before pagination", app)
    for step in 0..<60 {
      let more = app.buttons["Load more"]
      if more.exists && more.isHittable { more.tap() }
      if app.staticTexts["Native child 135 — nested content"].exists && app.staticTexts[appendMarker].exists { break }
      app.collectionViews.firstMatch.swipeUp(velocity: .fast)
      if step % 10 == 0 { print("APPEND_PAGING_STEP=\(step)") }
      XCTAssertFalse(app.buttons["Retry loading children"].exists)
    }
    XCTAssertTrue(app.staticTexts["Native child 135 — nested content"].exists)
    XCTAssertTrue(app.staticTexts[appendMarker].exists)
    XCTAssertFalse(app.buttons["Load more"].exists)
    record("All children after partial-page Append", app)
  }

  @MainActor func testChildDeleteUndoAndPersistence() {
    continueAfterFailure = false
    let app = application(relaunch: true)
    let parent = row("Graph 1 — Encrypted offline Journal", in: app)
    XCTAssertTrue(parent.waitForExistence(timeout: 25))
    parent.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Graph 1 — Encrypted offline Journal")).firstMatch.tap()
    let first = app.staticTexts["Native child 01 — nested content"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    first.swipeLeft()
    XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
    app.buttons["Delete"].tap()
    XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
    app.buttons["Undo"].tap()
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    record("Child deletion canceled by timed Undo", app)
    let second = app.staticTexts["Native child 02 — nested content"]
    XCTAssertTrue(second.exists)
    second.swipeLeft()
    XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
    app.buttons["Delete"].tap()
    XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
    let expired = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["Undo"])
    wait(for: [expired], timeout: 12)
    XCTAssertTrue(first.exists)
    XCTAssertFalse(second.exists)
    record("Only second child deleted", app)
    app.terminate()
    app.launch()
    XCTAssertTrue(parent.waitForExistence(timeout: 25))
    parent.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Graph 1 — Encrypted offline Journal")).firstMatch.tap()
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertFalse(second.exists)
    XCTAssertTrue(app.staticTexts["Native child 03 — nested content"].exists)
    record("Child deletion survives restart", app)
  }

  @MainActor func testInspectNativeOutline() {
    continueAfterFailure = false
    let app = application(relaunch: true)
    let parent = row("Graph 1 — Encrypted offline Journal", in: app)
    XCTAssertTrue(parent.waitForExistence(timeout: 10))
    let title = parent.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Graph 1 — Encrypted offline Journal")).firstMatch
    XCTAssertTrue(title.isHittable)
    title.tap()
    XCTAssertTrue(app.navigationBars["Block"].waitForExistence(timeout: 10))
    record("Isolated native iPhone outline", app)
  }
}
