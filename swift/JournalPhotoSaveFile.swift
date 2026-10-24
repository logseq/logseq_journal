import Foundation
import OSLog
import ImageIO
import UniformTypeIdentifiers

/// An exact, operation-owned copy; no image decoding/re-encoding or resizing.
enum JournalPhotoSaveFile {
  private static func discard(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch let error as CocoaError where error.code == .fileNoSuchFile { } // Idempotent cleanup.
    catch {
      let reason = JournalAssetDiagnostic.classify(error, stage: .cleanup)
      Logger(subsystem: "com.logseq.journal", category: "cleanup")
        .error("Temporary photo cleanup could not finish (photoSave.cleanup.failed; \(reason.description, privacy: .public))")
    }
  }

  static func stage(_ source: URL) throws -> JournalPhotoSave.FileLease {
    guard source.isFileURL else { throw JournalPhotoSave.StageError.notImage }
    guard try source.checkResourceIsReachable() else { throw CocoaError(.fileReadNoSuchFile) }
    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
          let identifier = CGImageSourceGetType(image),
          let type = UTType(identifier as String), type.conforms(to: .image),
          CGImageSourceGetCount(image) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          width.intValue > 0, height.intValue > 0 else {
      throw JournalPhotoSave.StageError.notImage
    }
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("journal-photo-save-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false)
    // Prefer the detected format to a cache filename's arbitrary extension.
    let staged = directory.appendingPathComponent("image").appendingPathExtension(type.preferredFilenameExtension ?? source.pathExtension)
    do { try manager.copyItem(at: source, to: staged) }
    catch { discard(directory); throw error }
    return JournalPhotoSave.FileLease(url: staged) { discard(directory) }
  }
}
