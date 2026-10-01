import AppKit
import SwiftUI

@main @MainActor struct JournalLoadingRenderTests {
  static func main() {
    for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
      let teal = Color(red: 0x85 / 255, green: 0xC8 / 255, blue: 0xC8 / 255)
      let background = Color(red: 0xF6 / 255, green: 0xF7 / 255, blue: 0xF8 / 255)
      let content = ZStack {
        background
        JournalExpansionShape(scale: JournalLoadingGeometry.coverScale(in: size))
          .fill(teal)
      }
      .frame(width: size.width, height: size.height)
      let renderer = ImageRenderer(content: content)
      renderer.proposedSize = ProposedViewSize(size)
      guard let data = renderer.nsImage?.tiffRepresentation,
        let image = NSBitmapImageRep(data: data)
      else {
        fatalError("Offscreen expansion render failed")
      }
      for (x, y) in [
        (0, 0), (image.pixelsWide - 1, 0),
        (0, image.pixelsHigh - 1), (image.pixelsWide - 1, image.pixelsHigh - 1),
      ] {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          fatalError("Missing corner pixel")
        }
        assert(
          color.redComponent < 0.7 && color.greenComponent > 0.7,
          "Expanded layer does not cover corner \(x),\(y): \(color)")
      }
    }
    print("Journal expansion renders through all corners")
  }
}
