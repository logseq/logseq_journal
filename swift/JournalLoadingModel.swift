import CoreGraphics

enum JournalLoadingSignal: Int32 {
  case loading = 0
  case ready = 1
  case intervention = 2
}
enum JournalLoadingStage { case loading, expanding, holding, fading, complete }

/// A new loading cycle invalidates delayed completions from the previous one.
struct JournalLoadingTransition {
  private(set) var stage: JournalLoadingStage = .loading
  private(set) var generation = 0

  @discardableResult mutating func receive(
    _ signal: JournalLoadingSignal, reduceMotion: Bool
  ) -> Bool {
    switch signal {
    case .loading:
      guard stage != .loading else { return false }
      generation += 1
      stage = .loading
      return false
    case .ready, .intervention:
      guard stage == .loading else { return false }
      generation += 1
      stage = signal == .intervention || reduceMotion ? .fading : .expanding
      return true
    }
  }

  @discardableResult mutating func advance(
    to next: JournalLoadingStage, generation expected: Int
  ) -> Bool {
    guard generation == expected else { return false }
    let valid =
      switch (stage, next) {
      case (.expanding, .holding), (.holding, .fading), (.fading, .complete): true
      default: false
      }
    guard valid else { return false }
    stage = next
    return true
  }
}

/// Official 21×21 logo geometry. Only the third oval is copied for expansion.
enum JournalLoadingGeometry {
  static let logoSide: CGFloat = 78
  static let sourceSide: CGFloat = 21
  static let unit = logoSide / sourceSide

  struct Oval {
    let rx: CGFloat
    let ry: CGFloat
    let transform: CGAffineTransform
  }

  static let ovals: [Oval] = [
    Oval(
      rx: 3.29236, ry: 2.04373,
      transform: CGAffineTransform(
        a: 0.987073, b: 0.160274,
        c: -0.239143, d: 0.970984,
        tx: 11.7346, ty: 2.59206)),
    Oval(
      rx: 2.95326, ry: 3.37606,
      transform: CGAffineTransform(
        a: -0.495846, b: 0.868411,
        c: -0.825718, d: -0.564084,
        tx: 3.97209, ty: 5.54515)),
    Oval(
      rx: 7.78547, ry: 6.13006,
      transform: CGAffineTransform(
        a: 0.987073, b: 0.160274,
        c: -0.239143, d: 0.970984,
        tx: 13.0843, ty: 14.72)),
  ]

  static func logoOrigin(in size: CGSize) -> CGPoint {
    CGPoint(
      x: size.width * 0.5 - logoSide * 0.5,
      y: size.height * 0.47 - logoSide * 0.5)
  }

  static func expansionCenter(in size: CGSize) -> CGPoint {
    let origin = logoOrigin(in: size)
    let oval = ovals[2]
    return CGPoint(
      x: origin.x + oval.transform.tx * unit,
      y: origin.y + oval.transform.ty * unit)
  }

  /// Inverse-transform screen corners into the oval's local coordinates.
  static func coverScale(in size: CGSize) -> CGFloat {
    let corners = [
      CGPoint.zero, CGPoint(x: size.width, y: 0),
      CGPoint(x: 0, y: size.height),
      CGPoint(x: size.width, y: size.height),
    ]
    let radius = corners.map { normalizedRadius($0, in: size) }.max() ?? 1
    return max(1, radius * 1.01)
  }

  static func largestEllipseContains(
    _ point: CGPoint, in size: CGSize, scale: CGFloat
  ) -> Bool { normalizedRadius(point, in: size) <= scale + 0.0001 }

  private static func normalizedRadius(_ point: CGPoint, in size: CGSize) -> CGFloat {
    let oval = ovals[2]
    let matrix = oval.transform
    let center = expansionCenter(in: size)
    let dx = (point.x - center.x) / unit
    let dy = (point.y - center.y) / unit
    let determinant = matrix.a * matrix.d - matrix.b * matrix.c
    let x = (matrix.d * dx - matrix.c * dy) / determinant / oval.rx
    let y = (-matrix.b * dx + matrix.a * dy) / determinant / oval.ry
    return sqrt(x * x + y * y)
  }
}
