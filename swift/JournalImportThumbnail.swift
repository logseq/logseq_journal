import Foundation
import ImageIO

actor JournalImportThumbnailDecoder {
  static let shared = JournalImportThumbnailDecoder()
  private let cache = NSCache<NSString, CGImage>()
  init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 32 }
  func load(_ path: String) -> CGImage? {
    guard !Task.isCancelled else { return nil }
    if let image = cache.object(forKey: path as NSString) { return image }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,
      [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1024,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary), !Task.isCancelled else { return nil }
    cache.setObject(image, forKey: path as NSString, cost: image.bytesPerRow * image.height)
    return image
  }
}

enum JournalImportThumbnail {
  nonisolated static let imageTypes: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
    "avif",
  ]
}
