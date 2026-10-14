import XCTest

/// Run only against the disposable rich-titles fixture in the isolated probe.
final class JournalMldocTitleAcceptance: XCTestCase {
  private let rootID = "detail-block:80000000-0000-4000-a000-000000000001"
  private var app: XCUIApplication!

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication(bundleIdentifier: "org.logseq.journal.mldoc-probe")
    app.launchEnvironment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
      "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory",
    ]
    app.launchArguments = ["--fixture", "rich-titles.json", "--support-root", "support-rich", "--application-only", "--light-appearance"]
    app.launch()
    XCTAssertTrue(text("Mldoc fixture:").waitForExistence(timeout: 30))
  }

  private func text(_ prefix: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    print("MLDOC_AX_\(name)\n\(app.debugDescription)")
  }

  func testTimelineAndDetailLayout() {
    let root = text("Mldoc fixture:")
    XCTAssertLessThanOrEqual(root.frame.height, 92)
    XCTAssertLessThanOrEqual(text("Child labels:").frame.height, 44)
    XCTAssertTrue(text("Child resolved:").exists)
    XCTAssertTrue(text("Child missing:").exists)
    XCTAssertFalse(text("Native child 04").exists)
    XCTAssertTrue(text("Missing:").exists)
    XCTAssertTrue(text("Cycle:").exists)
    screenshot("timeline-rich-titles")
    root.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.08)).tap()
    let detail = app.staticTexts.matching(identifier: rootID).firstMatch
    XCTAssertTrue(detail.waitForExistence(timeout: 10))
    XCTAssertGreaterThan(detail.frame.height, 180)
    screenshot("detail-rich-root")
    app.swipeUp()
    app.swipeUp()
    XCTAssertTrue(text("Child labels:").waitForExistence(timeout: 5))
    XCTAssertTrue(text("Child labels:").label.contains("THIRD LINE hidden in Timeline"))
    screenshot("detail-rich-children")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(text("Mldoc fixture:").waitForExistence(timeout: 5))
    app.swipeUp()
    XCTAssertLessThanOrEqual(text("中文长文").frame.height, 92)
    screenshot("timeline-long-cjk")
  }

  func testMissingAndCyclicReferencesKeepRowNavigation() {
    XCTAssertEqual(app.links.matching(NSPredicate(format: "label CONTAINS %@", "000000000099")).count, 0)
    text("Missing:").tap()
    XCTAssertTrue(app.staticTexts.matching(identifier: "detail-block:80000000-0000-4000-a000-000000000003").firstMatch.waitForExistence(timeout: 10))
    screenshot("detail-missing-reference")
    app.navigationBars.buttons.firstMatch.tap()
    text("Cycle:").tap()
    XCTAssertTrue(app.staticTexts.matching(identifier: "detail-block:80000000-0000-4000-a000-000000000004").firstMatch.waitForExistence(timeout: 10))
    screenshot("detail-cyclic-reference")
  }

  func testLinksAndReferenceNavigation() {
    screenshot("links-before-taps")
    print("MLDOC_LINKS\n\(app.links.debugDescription)")
    let reference = app.links.matching(NSPredicate(format: "label CONTAINS %@", "Referenced")).firstMatch
    XCTAssertTrue(reference.waitForExistence(timeout: 5))
    reference.tap()
    XCTAssertTrue(app.staticTexts.matching(identifier: "detail-block:82000000-0000-4000-a000-000000000001").firstMatch.waitForExistence(timeout: 10))
    screenshot("reference-target-detail")
    app.navigationBars.buttons.firstMatch.tap()
    let labeled = app.links["标签链接"].firstMatch
    XCTAssertTrue(labeled.waitForExistence(timeout: 5))
    labeled.tap()
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "labeled-url-safari"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.activate()
    let plain = app.links.matching(NSPredicate(format: "label CONTAINS %@", "example.com/plain")).firstMatch
    XCTAssertTrue(plain.waitForExistence(timeout: 5))
    plain.tap()
    XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
    let plainShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    plainShot.name = "plain-url-safari"
    plainShot.lifetime = .keepAlways
    add(plainShot)
  }
}
