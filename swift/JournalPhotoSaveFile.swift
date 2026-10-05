import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An exact, operation-owned copy; no image decoding/re-encoding or resizing.
enum JournalPhotoSaveFile {
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
    catch { try? manager.removeItem(at: directory); throw error }
    return JournalPhotoSave.FileLease(url: staged) { try? manager.removeItem(at: directory) }
  }
}
