import CoreGraphics
import Foundation

@main struct JournalLoadingTests {
  static func main() {
    let portrait = CGSize(width: 393, height: 852)
    let landscape = CGSize(width: 852, height: 393)
    let logo = JournalLoadingGeometry.logoOrigin(in: portrait)
    assert(close(logo.x, 393 * 0.5 - 39))
    assert(close(logo.y, 852 * 0.47 - 39))
    let center = JournalLoadingGeometry.expansionCenter(in: portrait)
    assert(close(center.x, logo.x + 13.0843 * 78 / 21))
    assert(close(center.y, logo.y + 14.72 * 78 / 21))
    for size in [portrait, landscape, CGSize(width: 320, height: 900)] {
      let scale = JournalLoadingGeometry.coverScale(in: size)
      assert(scale >= 1)
      for point in [
        CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
        CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height),
      ] {
        assert(
          JournalLoadingGeometry.largestEllipseContains(point, in: size, scale: scale),
          "expanded ellipse misses \(point) in \(size)")
      }
    }

    var loading = JournalLoadingTransition()
    assert(loading.stage == .loading)
    assert(!loading.receive(.loading, reduceMotion: false))
    assert(loading.receive(.ready, reduceMotion: false))
    assert(loading.stage == .expanding)
    let firstGeneration = loading.generation
    assert(!loading.receive(.ready, reduceMotion: false))
    assert(loading.generation == firstGeneration)
    assert(loading.advance(to: .holding, generation: firstGeneration))
    assert(loading.advance(to: .fading, generation: firstGeneration))
    assert(loading.advance(to: .complete, generation: firstGeneration))
    assert(!loading.receive(.ready, reduceMotion: false))
    assert(loading.receive(.loading, reduceMotion: false) == false)
    assert(loading.stage == .loading && loading.generation != firstGeneration)
    assert(!loading.advance(to: .fading, generation: firstGeneration))
    assert(loading.stage == .loading)
    assert(loading.receive(.ready, reduceMotion: true))
    assert(loading.stage == .fading)
    let reducedGeneration = loading.generation
    assert(loading.advance(to: .complete, generation: reducedGeneration))
    assert(!loading.receive(.ready, reduceMotion: true))

    var intervention = JournalLoadingTransition()
    assert(intervention.receive(.intervention, reduceMotion: false))
    assert(intervention.stage == .fading)
    print("Journal loading geometry and transitions passed")
  }

  static func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) < 0.001 }
}
