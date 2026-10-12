import XCTest
import UIKit

/// Exercises the production loading surface and extension factory through a
/// disposable native fixture. The defect is SwiftUI layout, not OCaml state:
/// the fixture uses accepted public patches and never starts a graph/runtime.
final class JournalStartupLayoutTests: XCTestCase {
  let bundle = "org.logseq.journal.startup-layout-20261012"

  @MainActor private func record(_ phase: String, _ app: XCUIApplication) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = phase
    image.lifetime = .keepAlways
    add(image)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = phase + " AX"
    tree.lifetime = .keepAlways
    add(tree)
  }

  @MainActor private func loadingFrame(_ app: XCUIApplication) -> CGRect {
    let label = app.staticTexts["Loading journal"].firstMatch
    XCTAssertTrue(label.waitForExistence(timeout: 5))
    return label.frame
  }

  @MainActor private func assertSameFrame(_ actual: CGRect, _ expected: CGRect) {
    XCTAssertEqual(actual.midX, expected.midX, accuracy: 1)
    XCTAssertEqual(actual.midY, expected.midY, accuracy: 1)
    XCTAssertEqual(actual.width, expected.width, accuracy: 1)
    XCTAssertEqual(actual.height, expected.height, accuracy: 1)
  }

  @MainActor private func probe(width: Int, font: String) {
    continueAfterFailure = true
    let app = XCUIApplication(bundleIdentifier: bundle)
    app.launchEnvironment = ["STARTUP_LAYOUT_WIDTH": String(width),
      "STARTUP_LAYOUT_FONT": font]
    app.launch()
    defer { app.terminate() }
    let original = loadingFrame(app)
    XCTAssertGreaterThan(original.height, 0)
    XCTAssertLessThanOrEqual(original.width, CGFloat(width - 48) + 1)
    record("Native preparation \(width) \(font)", app)

    app.buttons["qa-runtime"].tap()
    XCTAssertTrue(app.staticTexts["qa-runtime-state"].waitForExistence(timeout: 5))
    assertSameFrame(loadingFrame(app), original)
    record("LUI takeover \(width) \(font)", app)

    app.buttons["qa-action"].tap()
    let recovery = app.buttons["Choose another graph"].firstMatch
    XCTAssertTrue(recovery.waitForExistence(timeout: 5))
    XCTAssertTrue(recovery.isEnabled)
    XCTAssertTrue(recovery.isHittable)
    assertSameFrame(loadingFrame(app), original)
    record("Recovery action visible \(width) \(font)", app)
    recovery.tap()
    XCTAssertTrue(app.staticTexts["qa-recovery-invoked"].waitForExistence(timeout: 5))

    app.buttons["qa-action"].tap()
    XCTAssertFalse(recovery.exists)
    assertSameFrame(loadingFrame(app), original)
    record("Recovery action removed \(width) \(font)", app)
  }

  @MainActor func testHandoffAt390() { probe(width: 390, font: "large") }
  @MainActor func testHandoffAt320() { probe(width: 320, font: "large") }
  @MainActor func testNarrowHandoffAtAccessibility3() {
    probe(width: 320, font: "accessibility3")
  }

  @MainActor func testHandoffAtAccessibility3() {
    probe(width: 390, font: "accessibility3")
  }
}
