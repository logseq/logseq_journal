import XCTest
import CoreGraphics
/// Run only against the isolated four-catalog / three-resident synthetic host.
/// Native pixel offset is owned by List; the public reducer cannot reproduce it.
final class JournalResidentGraphAcceptance: XCTestCase {
  @MainActor private func host(delay: Bool = false) -> XCUIApplication {
    let app=XCUIApplication(bundleIdentifier:"org.logseq.journal.resident-sync-probe")
    app.launchEnvironment=["LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE":"memory","LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE":"memory","JOURNAL_SYNTHETIC_TLS_SHA256":ProcessInfo.processInfo.environment["JOURNAL_SYNTHETIC_TLS_SHA256"] ?? ""]
    if delay { app.launchEnvironment["JOURNAL_SYNTHETIC_CAPTURE_DELAY_SECONDS"] = "8" }
    app.launchArguments=["--fixture",ProcessInfo.processInfo.environment["JOURNAL_SYNTHETIC_FIXTURE"] ?? "authoritative-v2/fixture.json","--support-root",ProcessInfo.processInfo.environment["JOURNAL_SYNTHETIC_SUPPORT_ROOT"] ?? "authoritative-v2/resident-sync-support","--application-only"]
    app.launch(); _ = app.collectionViews.firstMatch.waitForExistence(timeout:25)
    Thread.sleep(forTimeInterval:5)
    picker(app)
    let initialGraph=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Native encrypted graph 1")).firstMatch
    XCTAssertTrue(initialGraph.waitForExistence(timeout:15));initialGraph.tap()
    _ = title(1,app).waitForExistence(timeout:20)
    return app
  }
  @MainActor private func title(_ graph:Int,_ app:XCUIApplication)->XCUIElement {
    app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Graph \(graph) —")).firstMatch
  }
  @MainActor private func record(_ name:String,_ app:XCUIApplication) {
    let ax=XCTAttachment(string:app.debugDescription);ax.name=name+" AX";ax.lifetime = .keepAlways;add(ax)
    let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name=name;shot.lifetime = .keepAlways;add(shot)
  }
  @MainActor private func right(_ app:XCUIApplication) {
    let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.53))
    let end=app.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.53))
    start.press(forDuration:0.05,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:0.2)
    Thread.sleep(forTimeInterval:0.6)
  }
  @MainActor func testSmokeRightCycle() {
    continueAfterFailure=false
    let app=host();XCTAssertTrue(title(1,app).waitForExistence(timeout:25));record("Synthetic graph1 before real native swipe",app)
    for graph in [2,3,1] {
      right(app);XCTAssertTrue(title(graph,app).waitForExistence(timeout:10));XCTAssertTrue(title(graph,app).isHittable);record("Native right swipe graph\(graph)",app)
    }
  }
  @MainActor func test21SavingFocusWaitPreservesLandedTarget() {
    continueAfterFailure = false
    let app = host(delay: true)
    tapID("journal-capture-open", app)
    let editor = app.textFields["field.composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap(); editor.typeText("Handoff queued focus " + UUID().uuidString)
    tapID("button.send", app)
    XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Saving")).firstMatch.exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    drag(app, 0.15, 0.85)
    Thread.sleep(forTimeInterval: 2.2)
    XCTAssertFalse(title(1, app).isHittable,
      "Queued focus must keep the landed target rather than uncovering the source after 2s")
    record("Landed target while Save delays focus", app)
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: title(2, app))
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
    record("Queued focus commits to the restored target", app)
  }
  /// Requires the synthetic image-blocks fixture and its blue graph-B PNGs.
  @MainActor func test22PreviewImageColorAndHitBarrier() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["JOURNAL_SYNTHETIC_FIXTURE"]?.contains("image-blocks") == true,
      "Select the isolated image-blocks fixture for this acceptance")
    continueAfterFailure = true
    let app = host(delay: true)
    picker(app); tapID("graph-picker:" + gid(2), app)
    XCTAssertTrue(title(2, app).waitForExistence(timeout: 20))
    let slot = app.otherElements["journal-image-slot:92000002-0000-4000-8000-000000000001"].firstMatch
    let image = slot.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journal-media:")).firstMatch
    XCTAssertTrue(image.waitForExistence(timeout: 15))
    tapID("journal-capture-open", app)
    let field = app.textFields["field.composer"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let marker = "B preview draft " + UUID().uuidString
    field.tap(); field.typeText(marker)
    let draft = field.value as? String
    XCTAssertTrue(draft?.contains(marker) == true)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    picker(app); tapID("graph-picker:" + gid(1), app)
    XCTAssertTrue(title(1, app).waitForExistence(timeout: 20))
    tapID("journal-capture-open", app)
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap(); field.typeText("Image preview barrier " + UUID().uuidString)
    tapID("button.send", app)
    XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Saving")).firstMatch.exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.75)).press(forDuration: 0.05,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.75)),
      withVelocity: .slow, thenHoldForDuration: 0.2)
    record("Image preview landed while focus is queued", app)
    let preview = imagePixel(XCUIScreen.main.screenshot().image.cgImage!)
    // Same already-loaded PNG must keep its normal color while input is fenced.
    XCTAssertEqual(Double(preview[0]), 50, accuracy: 18)
    XCTAssertEqual(Double(preview[1]), 102, accuracy: 18)
    XCTAssertEqual(Double(preview[2]), 199, accuracy: 18)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.735, dy: 0.257)).tap()
    XCTAssertFalse(app.otherElements["journal-image-gallery"].exists,
      "A visible preview must not open its image gallery")
    XCTAssertFalse(app.staticTexts["detail-block:80000000-0000-4000-a000-000000000001"].exists)
    record("Preview image tap is rejected", app)
    // Probe a real action: native AX may report preview text as hittable.
    // Only the focused graph can actually open its composer with B's draft.
    for _ in 0..<14 {
      if field.exists { break }
      let open = app.descendants(matching: .any).matching(identifier: "journal-capture-open").firstMatch
      if open.exists && open.isEnabled && open.isHittable { open.tap() }
      if field.waitForExistence(timeout: 1) { break }
    }
    XCTAssertTrue(field.exists); XCTAssertEqual(field.value as? String, draft)
    record("Focused B draft matches its inert preview", app)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 3))
    let focused = imagePixel(XCUIScreen.main.screenshot().image.cgImage!)
    for channel in 0..<3 { XCTAssertEqual(Double(preview[channel]), Double(focused[channel]), accuracy: 16) }
    record("Focused B color matches its inert preview", app)
  }

  @MainActor private func imagePixel(_ image: CGImage) -> [UInt8] {
    let point = CGRect(x: Double(image.width) * 0.735, y: Double(image.height) * 0.257, width: 6, height: 6)
    guard let crop = image.cropping(to: point) else { XCTFail("Missing image sample"); return [0, 0, 0] }
    var rgba = [UInt8](repeating: 0, count: 4)
    let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
    }
    XCTAssertTrue(drawn); return Array(rgba.prefix(3))
  }
  @MainActor private func drag(_ app:XCUIApplication,_ from:CGFloat,_ to:CGFloat) {
    app.coordinate(withNormalizedOffset:CGVector(dx:from,dy:0.53)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:to,dy:0.53)),withVelocity:.slow,thenHoldForDuration:0.2)
  }
  @MainActor private func tapID(_ id:String,_ app:XCUIApplication) {
    if id.hasPrefix("graph-resident-remove:"), let n=id.last {app.otherElements.matching(NSPredicate(format:"label == %@","Close Native encrypted graph \(n)")).firstMatch.tap();return}
    if id.hasPrefix("graph-resident-up:"), let n=id.last {app.otherElements.matching(NSPredicate(format:"label == %@","Move Native encrypted graph \(n) earlier")).firstMatch.tap();return}
    if id.hasPrefix("graph-picker:"), let n=id.last {app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","Native encrypted graph \(n)")).firstMatch.tap();return}
    if id.hasPrefix("graph-resident-replace:") {app.buttons.matching(NSPredicate(format:"label == %@","Replace")).element(boundBy:2).tap();return}
    let target=app.descendants(matching:.any).matching(identifier:id).firstMatch
    XCTAssertTrue(target.waitForExistence(timeout:10));target.tap()
  }
  @MainActor func test04CancellationVerticalAndScroll() {
    continueAfterFailure=false
    let app=host();XCTAssertTrue(title(1,app).waitForExistence(timeout:20))
    let initialY=title(1,app).frame.minY
    title(1,app).tap();XCTAssertTrue(app.staticTexts["detail-block:80000000-0000-4000-a000-000000000001"].waitForExistence(timeout:10));record("A native detail",app)
    right(app);XCTAssertTrue(title(1,app).isHittable);record("Detail right drag keeps graph1 and allows native back",app)
    if app.staticTexts["detail-block:80000000-0000-4000-a000-000000000001"].exists {app.navigationBars.buttons["Back"].firstMatch.tap()};XCTAssertTrue(title(1,app).waitForExistence(timeout:10));XCTAssertEqual(title(1,app).frame.minY,initialY,accuracy:4)
    drag(app,0.85,0.15);XCTAssertTrue(title(1,app).isHittable);record("Left drag stays on graph1",app)
    drag(app,0.15,0.27);XCTAssertTrue(title(1,app).isHittable);XCTAssertTrue(title(1,app).isHittable);record("Short right drag cancels",app)
    XCTAssertEqual(app.pageIndicators.count,0)
    app.collectionViews.firstMatch.swipeUp(velocity:.slow)
    let anchor=app.staticTexts["Native row 0008 — readable content"].firstMatch
    XCTAssertTrue(anchor.isHittable);let y=anchor.frame.minY
    XCTAssertFalse(title(1,app).isHittable);record("A vertical scroll before graph change",app)
    right(app);XCTAssertTrue(title(2,app).isHittable);record("B independent initial scroll",app)
    right(app);XCTAssertTrue(title(3,app).isHittable)
    right(app);XCTAssertTrue(anchor.isHittable);record("A scroll after full graph cycle",app)
    XCTAssertEqual(anchor.frame.minY,y,accuracy:4,"Each graph must keep its own native scroll position")
  }

  @MainActor private func picker(_ app:XCUIApplication) {
    let header=app.staticTexts["Resident graphs · up to 3"]
    for _ in 0..<2 {
      if header.exists {return}
      XCTAssertFalse(app.staticTexts["Unable to open journal"].exists)
      app.buttons["Options"].firstMatch.tap();app.buttons["Switch graph"].firstMatch.tap()
      if header.waitForExistence(timeout:8) {return}
      record("Menu selection before picker admission",app)
    }
    XCTAssertTrue(header.exists)
  }
  @MainActor private func gid(_ n:Int)->String {"60000000-0000-4000-8000-00000000000\(n)"}
  @MainActor func test06ResidentManagement() {
    continueAfterFailure=false;let app=host();XCTAssertTrue(title(1,app).waitForExistence(timeout:20));picker(app);record("Three resident slots in Switch graph",app)
    for n in [2,3] {tapID("graph-resident-remove:"+gid(n),app)}
    record("Only graph1 resident",app);tapID("graph-picker-close",app);right(app);XCTAssertTrue(title(1,app).isHittable);record("One graph right drag stays",app)
    picker(app);tapID("graph-picker:"+gid(2),app);XCTAssertTrue(title(2,app).waitForExistence(timeout:20));right(app);XCTAssertTrue(title(1,app).isHittable);right(app);XCTAssertTrue(title(2,app).isHittable);record("Two graph right wrap",app)
    picker(app);tapID("graph-picker:"+gid(3),app);XCTAssertTrue(title(3,app).waitForExistence(timeout:20));picker(app)
    tapID("graph-resident-up:"+gid(3),app);record("Configured order A C B",app)
    tapID("graph-picker:"+gid(4),app);XCTAssertTrue(app.staticTexts["Choose a slot to replace with Native encrypted graph 4"].waitForExistence(timeout:10));record("Full set requires explicit replacement",app)
    tapID("graph-resident-replace:"+gid(2),app);XCTAssertTrue(title(4,app).waitForExistence(timeout:20));record("Explicit replacement opens D",app)
    picker(app);tapID("graph-resident-remove:"+gid(4),app);record("D closed without deleting local copy",app);picker(app);tapID("graph-picker:"+gid(4),app);XCTAssertTrue(title(4,app).waitForExistence(timeout:20));record("Reopen D local copy",app)
    app.terminate();app.launch();XCTAssertTrue(title(4,app).waitForExistence(timeout:20));record("Resident selection after process restart",app)
    for n in [1,3,4] {right(app);XCTAssertTrue(title(n,app).isHittable);record("Persisted cycle graph\(n)",app)}
  }

}
