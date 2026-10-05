import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct Tests {
  @MainActor static func main() {
    var authorization = JournalPhotoSave.Authorization.notDetermined
    var permission: ((JournalPhotoSave.Authorization) -> Void)?
    var completion: ((Bool) -> Void)?
    var staged: [URL] = []
    var written: [URL] = []
    var released = 0
    var feedback: [JournalPhotoSave.Feedback] = []
    func owner() -> JournalPhotoSave {
      JournalPhotoSave(dependencies: .init(
        authorization: { authorization },
        requestAuthorization: { permission = $0 },
        stage: { url in
          staged.append(url)
          return JournalPhotoSave.FileLease(url: url) { released += 1 }
        },
        write: { url, done in written.append(url); completion = done },
        feedback: { feedback.append($0) }))
    }
    let a = URL(fileURLWithPath: "/synthetic/selected-a.png")
    let b = URL(fileURLWithPath: "/synthetic/selected-b.png")
    let pending = owner()
    pending.save(a)
    pending.save(b)
    precondition(staged == [a] && pending.busy && written.isEmpty)
    let grant = permission!
    grant(.authorized)
    grant(.authorized)
    precondition(written == [a])
    let firstCompletion = completion!
    firstCompletion(true)
    firstCompletion(false)
    precondition(released == 1 && feedback == [.saved] && !pending.busy)
    authorization = .authorized
    pending.save(b)
    grant(.authorized)
    firstCompletion(false)
    precondition(staged == [a,b] && written == [a,b] && released == 1 && pending.busy)
    completion!(false)
    precondition(feedback.last == .failed && released == 2)
    for status in [JournalPhotoSave.Authorization.denied, .restricted] {
      authorization = status
      let blocked = owner()
      let count = staged.count
      blocked.save(a)
      precondition(staged.count == count && !blocked.busy)
      precondition(feedback.last == (status == .denied ? .denied : .restricted))
    }
    authorization = .notDetermined
    let closing = owner()
    closing.save(a)
    let lateGrant = permission!
    closing.close()
    let writeCount = written.count
    lateGrant(.authorized)
    precondition(written.count == writeCount && released == 3 && !closing.busy)
    closing.save(b)
    precondition(staged.count == 3)
    authorization = .authorized
    var writing: JournalPhotoSave? = owner()
    writing!.save(b)
    let done = completion!
    let feedbackCount = feedback.count
    writing!.close()
    writing = nil
    precondition(released == 3)
    done(true)
    done(true)
    precondition(released == 4 && feedback.count == feedbackCount)
    let invalid = JournalPhotoSave(dependencies: .init(
      authorization: { .authorized }, requestAuthorization: { _ in },
      stage: { _ in throw JournalPhotoSave.StageError.notImage },
      write: { _, _ in preconditionFailure("invalid image written") },
      feedback: { feedback.append($0) }))
    invalid.save(a)
    precondition(feedback.last == .notImage && !invalid.busy)
    let missing = JournalPhotoSave(dependencies: .init(
      authorization: { .authorized }, requestAuthorization: { _ in },
      stage: { _ in throw CocoaError(.fileReadNoSuchFile) },
      write: { _, _ in preconditionFailure("missing image written") },
      feedback: { feedback.append($0) }))
    missing.save(a)
    precondition(feedback.last == .failed && !missing.busy)
    authorization = .notDetermined
    let refusal = owner()
    refusal.save(a)
    permission!(.denied)
    precondition(!refusal.busy && released == 5 && feedback.last == .denied)
    staging()
    print("PASS: save authorization, selected source, duplicate/stale callbacks, failures and close/file lifetime")
  }
  @MainActor static func staging() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original.cache")
    let width = 37, height = 19
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    let bytes = try! Data(contentsOf: source)
    let file = try! JournalPhotoSaveFile.stage(source)
    precondition(file.url.pathExtension == "png")
    try! FileManager.default.removeItem(at: source)
    precondition(try! Data(contentsOf: file.url) == bytes)
    let image = CGImageSourceCreateWithURL(file.url as CFURL, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as! [CFString: Any]
    precondition((properties[kCGImagePropertyPixelWidth] as! NSNumber).intValue == width)
    precondition((properties[kCGImagePropertyPixelHeight] as! NSNumber).intValue == height)
    let temporary = file.url
    file.close()
    file.close()
    precondition(!FileManager.default.fileExists(atPath: temporary.path))
    let fake = directory.appendingPathComponent("document.png")
    try! Data("%PDF-1.4 synthetic document".utf8).write(to: fake)
    do { _ = try JournalPhotoSaveFile.stage(fake); preconditionFailure("nonimage accepted") }
    catch JournalPhotoSave.StageError.notImage {} catch { preconditionFailure("unexpected error") }
    do { _ = try JournalPhotoSaveFile.stage(URL(string: "https://example.com/synthetic.png")!); preconditionFailure("external URL accepted") }
    catch JournalPhotoSave.StageError.notImage {} catch { preconditionFailure("unexpected error") }
    do { _ = try JournalPhotoSaveFile.stage(source); preconditionFailure("missing source accepted") }
    catch JournalPhotoSave.StageError.notImage { preconditionFailure("missing file classified as an image") }
    catch {}
    print("PASS: exact bytes/dimensions, detected image format, source retirement, cleanup and document rejection")
  }
}
