import UIKit
import XCTest

/// Public UI inputs against the isolated real Application. No business events or native offsets are injected.
final class TopEdgeEffectAcceptance: XCTestCase {
  @MainActor private func app() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "org.logseq.journal.pr47-application-fixture")
    app.launchEnvironment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
      "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory",
    ]
    app.launchArguments = ["--fixture", "timeline-images.json", "--support-root", "support-timeline-images", "--application-only", "--light-appearance"]
    app.launch()
    XCTAssertTrue(title(app).waitForExistence(timeout: 40))
    XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 15))
    Thread.sleep(forTimeInterval: 1)
    record("Root at top", app)
    return app
  }
  @MainActor private func title(_ app: XCUIApplication) -> XCUIElement {
    let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Timeline gallery fixture")).firstMatch
    return text.exists ? text : app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Timeline gallery fixture")).firstMatch
  }
  @MainActor private func record(_ name: String, _ app: XCUIApplication) {
    print("TOP_EDGE_AX \(name) \(app.debugDescription)")
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name + " AX"; tree.lifetime = .keepAlways; add(tree)
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name; image.lifetime = .keepAlways; add(image)
    print("TOP_EDGE_MARK \(name) uptime=\(ProcessInfo.processInfo.systemUptime)")
  }
  @MainActor private func point(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
  }
  @MainActor private func scroll(_ app: XCUIApplication, by delta: CGFloat) {
    point(app,195,760).press(forDuration: 0.05,
      thenDragTo: point(app,195,760-delta), withVelocity: .slow, thenHoldForDuration: 0.5)
    Thread.sleep(forTimeInterval: 1)
  }
  @MainActor private func open(_ app: XCUIApplication) {
    point(app,370,560).tap()
    XCTAssertTrue(app.navigationBars["Block"].waitForExistence(timeout: 10))
    Thread.sleep(forTimeInterval: 0.7)
  }
  @MainActor private func back(_ app: XCUIApplication, _ index: Int) {
    record("Detail before Back \(index)",app)
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Block"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(title(app).waitForExistence(timeout: 10))
    XCTAssertTrue(app.collectionViews.firstMatch.isHittable)
    Thread.sleep(forTimeInterval: 1)
    record("Root after Back \(index)",app)
  }
  @MainActor func testTextBack() {
    let app = app()
    scroll(app,by:703)
    record("Text scrolled baseline",app)
    for index in 1...2 { open(app); back(app,index) }
  }
  @MainActor func testRotatedControls() {
    let app = app()
    defer { XCUIDevice.shared.orientation = .portrait }
    XCUIDevice.shared.orientation = .landscapeLeft
    let account=app.buttons["Account menu"]
    let ready=XCTNSPredicateExpectation(predicate:NSPredicate(format:"isHittable == true"),object:account)
    XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:10),.completed)
    account.tap()
    XCTAssertTrue(app.buttons["Diagnostics"].waitForExistence(timeout:5))
    record("Landscape account menu really opened",app)
    app.coordinate(withNormalizedOffset:CGVector(dx:0.02,dy:0.5)).tap()
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(account.waitForExistence(timeout:10))
    XCTAssertTrue(account.isHittable)
    XCTAssertEqual(account.frame.minY,47,accuracy:1)
    record("Portrait geometry restored",app)
  }
  @MainActor func testFloatingControls() {
    let app = app()
    let account = app.buttons["Account menu"]
    XCTAssertTrue(account.isHittable)
    XCTAssertEqual(account.frame.minY,47,accuracy:1)
    account.tap()
    XCTAssertTrue(app.buttons["Diagnostics"].waitForExistence(timeout:5))
    record("Account menu really opened",app)
    point(app,10,400).tap()
    XCTAssertTrue(app.buttons["Diagnostics"].waitForNonExistence(timeout:5))
    point(app,81,790).tap()
    let favorites=app.staticTexts["favorites-header-title"]
    XCTAssertTrue(favorites.waitForExistence(timeout:10))
    XCTAssertTrue(favorites.isHittable)
    let favoriteAccount=app.buttons["Account menu"]
    XCTAssertTrue(favoriteAccount.isHittable)
    favoriteAccount.tap()
    XCTAssertTrue(app.buttons["Diagnostics"].waitForExistence(timeout:5))
    record("Favorites account menu really opened",app)
    point(app,10,400).tap()
    point(app,38,790).tap()
    XCTAssertTrue(title(app).waitForExistence(timeout:10))
    XCTAssertEqual(account.frame.minY,47,accuracy:1)
    record("Timeline controls restored",app)
  }
  @MainActor func testCaptureKeyboard() {
    let app=app()
    scroll(app,by:703)
    record("Keyboard root baseline",app)
    point(app,350,790).tap()
    let editor=app.textFields["field.composer"]
    XCTAssertTrue(editor.waitForExistence(timeout:10))
    editor.tap();editor.typeText("Soft safe-area keyboard probe")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:10))
    XCTAssertTrue(editor.isHittable)
    record("Capture keyboard and actions visible",app)
    let discard=app.buttons["trash"]
    let send=app.otherElements["button.send"].buttons.firstMatch
    XCTAssertTrue(discard.isHittable)
    XCTAssertTrue(send.isHittable)
    XCTAssertLessThan(send.frame.maxY,app.keyboards.firstMatch.frame.minY)
    discard.tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout:10))
    XCTAssertTrue(app.collectionViews.firstMatch.isHittable)
    XCTAssertEqual(app.buttons["Account menu"].frame.minY,47,accuracy:1)
    record("Keyboard closed restores root",app)
  }
  @MainActor func testTopBack() {
    let app = app()
    record("Top baseline",app)
    for index in 1...2 { open(app); back(app,index) }
  }
  @MainActor func testImageBack() {
    let app = app()
    let strip=app.scrollViews.firstMatch
    XCTAssertTrue(strip.waitForExistence(timeout:10))
    let delta=strip.frame.minY-35
    XCTAssertGreaterThan(delta,0); XCTAssertLessThan(delta,700)
    scroll(app,by:delta)
    record("Image under glass baseline",app)
    for index in 1...2 { open(app); back(app,index) }
  }
  @MainActor func testInteractiveReturn() {
    let app = app()
    scroll(app,by:703)
    record("Interactive root baseline",app)
    open(app)
    point(app,1,350).press(forDuration:0.05,thenDragTo:point(app,125,350),withVelocity:.slow,thenHoldForDuration:0.8)
    Thread.sleep(forTimeInterval:1)
    XCTAssertTrue(app.navigationBars["Block"].exists,"Short edge drag did not cancel back")
    record("Interactive cancel remains Detail",app)
    point(app,1,350).press(forDuration:0.05,thenDragTo:point(app,360,350),withVelocity:.slow,thenHoldForDuration:0.8)
    Thread.sleep(forTimeInterval:1)
    XCTAssertFalse(app.navigationBars["Block"].exists,"Long edge drag did not complete back")
    XCTAssertTrue(title(app).exists)
    record("Interactive complete returns root",app)
  }
}
