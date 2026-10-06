import UIKit
import XCTest

/// Runs against the isolated full Application, with local red/blue/green assets.
/// Native presentation lifecycle is not owned by the pure OCaml media reducer.
final class JournalTimelineImagePreviewAcceptance: XCTestCase {
  @MainActor private func application() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "org.logseq.journal.pr47-application-fixture")
    app.launchEnvironment = [
      "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE": "memory",
      "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE": "memory",
    ]
    app.launchArguments = [
      "--fixture", "timeline-images.json", "--support-root", "support-timeline-images",
      "--application-only",
    ]
    app.launch()
    XCTAssertTrue(title(app).waitForExistence(timeout: 40))
    XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 15))
    return app
  }

  @MainActor private func title(_ app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Timeline gallery fixture"))
      .firstMatch
  }

  @MainActor private func record(_ name: String, _ app: XCUIApplication) {
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name + " accessibility"
    tree.lifetime = .keepAlways
    add(tree)
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor private func openBlue(_ app: XCUIApplication) -> XCUIElement {
    let strip = app.scrollViews.firstMatch
    XCTAssertGreaterThan(strip.frame.width, 250)
    XCTAssertGreaterThan(strip.frame.minY, 100)
    XCTAssertLessThan(strip.frame.maxY, 800)
    // The composite native block row groups its descendants for accessibility.
    // This point lies in the visible second thumbnail; no native events are injected.
    strip.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5)).tap()
    let gallery = app.otherElements["journal-image-gallery"].firstMatch
    if !gallery.waitForExistence(timeout: 10) { record("Timeline thumbnail failed to open", app) }
    XCTAssertTrue(gallery.exists)
    XCTAssertTrue(app.buttons["journal-save-current-image"].exists)
    return gallery
  }

  @MainActor private func checkImage(_ rgb: [Int], _ name: String, _ app: XCUIApplication) {
    let image = app.images.matching(NSPredicate(format: "label MATCHES %@", "[0-9a-f]{64}"))
      .firstMatch
    XCTAssertTrue(image.waitForExistence(timeout: 5))
    record(name, app)
    let cg = UIImage(data: XCUIScreen.main.screenshot().pngRepresentation)!.cgImage!
    var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    pixels.withUnsafeMutableBytes { bytes in
      let context = CGContext(
        data: bytes.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
        bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    }
    let offset = 4 * (Int(Double(cg.height) * 0.52) * cg.width + Int(Double(cg.width) * 0.6))
    let actual = (0..<3).map { Int(pixels[offset + $0]) }
    print("TIMELINE_IMAGE \(name) RGB=\(actual) expected=\(rgb)")
    for channel in 0..<3 { XCTAssertLessThan(abs(actual[channel] - rgb[channel]), 28, name) }
  }

  @MainActor private func page(_ gallery: XCUIElement, right: Bool) {
    gallery.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.3 : 0.7, dy: 0.5))
      .press(
        forDuration: 0.05,
        thenDragTo: gallery.coordinate(
          withNormalizedOffset: CGVector(dx: right ? 0.7 : 0.3, dy: 0.5)))
    Thread.sleep(forTimeInterval: 0.7)
  }

  @MainActor private func close(_ app: XCUIApplication, baseline: CGRect) {
    app.navigationBars.buttons["Done"].firstMatch.tap()
    XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
    XCTAssertFalse(app.otherElements["journal-image-gallery"].exists)
    XCTAssertTrue(app.buttons["square.and.pencil"].exists)
    XCTAssertEqual(title(app).frame.minY, baseline.minY, accuracy: 4)
    XCTAssertEqual(title(app).frame.height, baseline.height, accuracy: 4)
  }

  @MainActor func testTimelineEntryPagingZoomAndReturn() {
    let app = application()
    let baseline = title(app).frame
    record("Actual Timeline before image entry", app)
    let gallery = openBlue(app)
    checkImage([40, 80, 210], "Clicked middle blue index 1", app)
    page(gallery, right: true)
    checkImage([202, 44, 44], "First red index 0", app)
    page(gallery, right: true)
    checkImage([202, 44, 44], "First boundary", app)
    page(gallery, right: false)
    checkImage([40, 80, 210], "Middle blue", app)
    page(gallery, right: false)
    checkImage([36, 160, 80], "Last green index 2", app)
    page(gallery, right: false)
    checkImage([36, 160, 80], "Last boundary", app)
    let zoom = app.scrollViews["journal-image-zoom"].firstMatch
    let green = app.images.matching(NSPredicate(format: "label MATCHES %@", "[0-9a-f]{64}"))
      .firstMatch
    let fittedWidth = green.frame.width
    zoom.pinch(withScale: 2, velocity: 1)
    XCTAssertGreaterThan(green.frame.width, fittedWidth * 1.2)
    checkImage([36, 160, 80], "Current green zoomed", app)
    zoom.pinch(withScale: 0.5, velocity: -1)
    XCTAssertEqual(green.frame.width, fittedWidth, accuracy: 4)
    checkImage([36, 160, 80], "Current green zoom reset", app)
    let sharedImage = green.label
    app.buttons["Share"].firstMatch.tap()
    XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.otherElements["LP.CaptionBar.TopCaption"].label, sharedImage)
    record("Share current green", app)
    app.otherElements["PopoverDismissRegion"].tap()
    close(app, baseline: baseline)
    record("Timeline layout after close", app)
    _ = openBlue(app)
    checkImage([40, 80, 210], "Same blue reopens", app)
    close(app, baseline: baseline)
    title(app).tap()
    XCTAssertTrue(app.navigationBars["Block"].waitForExistence(timeout: 10))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(title(app).frame.minY, baseline.minY, accuracy: 4)
    record("Interactive Timeline after Detail Back", app)
  }

  @MainActor func testScrolledRapidCloseAndRouteReturn() {
    let app = application()
    let beforeScroll = title(app).frame
    let list = app.collectionViews["journal-root-navigation"].firstMatch
    list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(
      forDuration: 0.05,
      thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.61)),
      withVelocity: .slow, thenHoldForDuration: 0.4)
    Thread.sleep(forTimeInterval: 0.8)
    let baseline = title(app).frame
    XCTAssertGreaterThan(abs(baseline.minY - beforeScroll.minY), 10)
    record("Scrolled Timeline before repeated entry", app)
    for iteration in 0..<3 {
      _ = openBlue(app)
      // Close immediately after the native gallery becomes available.
      close(app, baseline: baseline)
      record("Rapid close \(iteration)", app)
    }
    _ = openBlue(app)
    checkImage([40, 80, 210], "Blue usable after rapid closes", app)
    close(app, baseline: baseline)
    title(app).tap()
    XCTAssertTrue(app.navigationBars["Block"].waitForExistence(timeout: 10))
    app.navigationBars.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
    _ = openBlue(app)
    checkImage([40, 80, 210], "Blue usable after route return", app)
    close(app, baseline: baseline)
    record("Repeated session cleanly closed on scrolled Timeline", app)
  }
}
