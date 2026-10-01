import SwiftUI

private let logoColor = Color(red: 0x85 / 255, green: 0xC8 / 255, blue: 0xC8 / 255)
private let backgroundColor = Color(red: 0xF6 / 255, green: 0xF7 / 255, blue: 0xF8 / 255)

private struct JournalLogoShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    for oval in JournalLoadingGeometry.ovals {
      let ellipse = Path(
        ellipseIn: CGRect(
          x: -oval.rx, y: -oval.ry,
          width: oval.rx * 2, height: oval.ry * 2))
      let local = ellipse.applying(oval.transform)
      path.addPath(
        local.applying(
          CGAffineTransform(
            a: rect.width / 21, b: 0, c: 0,
            d: rect.height / 21, tx: rect.minX, ty: rect.minY)))
    }
    return path
  }
}

/// A separate screen-sized layer preserves the largest oval's original center.
struct JournalExpansionShape: Shape {
  var scale: CGFloat
  var animatableData: CGFloat {
    get { scale }
    set { scale = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let oval = JournalLoadingGeometry.ovals[2]
    let matrix = oval.transform
    let center = JournalLoadingGeometry.expansionCenter(in: rect.size)
    let unit = JournalLoadingGeometry.unit * scale
    let ellipse = Path(
      ellipseIn: CGRect(
        x: -oval.rx, y: -oval.ry,
        width: oval.rx * 2, height: oval.ry * 2))
    return ellipse.applying(
      CGAffineTransform(
        a: matrix.a * unit, b: matrix.b * unit,
        c: matrix.c * unit, d: matrix.d * unit,
        tx: center.x, ty: center.y))
  }
}

struct JournalLoadingOverlay: View {
  let signal: JournalLoadingSignal
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var transition = JournalLoadingTransition()
  @State private var scale: CGFloat = 1
  @State private var opacity: Double = 1
  @State private var sweepStart = Date()

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack(alignment: .topLeading) {
        backgroundColor
        if transition.stage != .complete {
          logo
            .frame(width: 78, height: 78)
            .position(x: size.width * 0.5, y: size.height * 0.47)
        }
        if transition.stage == .expanding || transition.stage == .holding
          || (transition.stage == .fading && !reduceMotion && scale > 1)
        {
          JournalExpansionShape(scale: scale)
            .fill(logoColor)
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
        }
      }
      .frame(width: size.width, height: size.height)
      .opacity(opacity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Opening journal")
      .accessibilityAddTraits(.updatesFrequently)
      .onChange(of: size, initial: true) { _, next in
        if transition.stage == .expanding || transition.stage == .holding
          || transition.stage == .fading
        {
          scale = JournalLoadingGeometry.coverScale(in: next)
        }
      }
      .task(id: transition.generation) {
        let generation = transition.generation
        if transition.stage == .expanding {
          withAnimation(.timingCurve(0.58, 0, 0.24, 1, duration: 1.1)) {
            scale = JournalLoadingGeometry.coverScale(in: size)
          }
          try? await Task.sleep(for: .milliseconds(1100))
          guard !Task.isCancelled,
            transition.advance(to: .holding, generation: generation)
          else { return }
          try? await Task.sleep(for: .milliseconds(90))
          guard !Task.isCancelled,
            transition.advance(to: .fading, generation: generation)
          else { return }
        } else if transition.stage != .fading {
          return
        }
        let duration = signal == .ready && !reduceMotion ? 0.36 : 0.18
        withAnimation(.linear(duration: duration)) { opacity = 0 }
        try? await Task.sleep(for: .seconds(duration))
        guard !Task.isCancelled else { return }
        _ = transition.advance(to: .complete, generation: generation)
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(transition.stage != .complete)
    .onAppear { receive(signal) }
    .onChange(of: signal) { _, next in receive(next) }
    .onDisappear {
      _ = transition.receive(.loading, reduceMotion: reduceMotion)
      scale = 1
      opacity = 1
    }
  }

  private func receive(_ next: JournalLoadingSignal) {
    let previous = transition.stage
    _ = transition.receive(next, reduceMotion: reduceMotion)
    if next == .loading && previous != .loading {
      scale = 1
      opacity = 1
      sweepStart = Date()
    }
  }

  private var logo: some View {
    ZStack {
      JournalLogoShape().fill(logoColor)
      if !reduceMotion && transition.stage == .loading {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
          sweep(at: context.date)
        }
      }
    }
  }

  private func sweep(at date: Date) -> some View {
    let fraction = date.timeIntervalSince(sweepStart).truncatingRemainder(dividingBy: 2) / 2
    let x: Double
    if fraction <= 0.1 {
      x = -4
    } else if fraction >= 0.94 {
      x = 34
    } else {
      x = -4 + 38 * Self.ease((fraction - 0.1) / 0.84)
    }
    let alpha: Double
    if fraction < 0.1 {
      alpha = 0
    } else if fraction < 0.22 {
      alpha = (fraction - 0.1) / 0.12
    } else if fraction < 0.78 {
      alpha = 1
    } else if fraction < 0.94 {
      alpha = (0.94 - fraction) / 0.16
    } else {
      alpha = 0
    }
    return LinearGradient(
      colors: [
        .clear,
        Color(
          red: 0xE9 / 255, green: 1,
          blue: 0xF9 / 255
        ).opacity(0.95 * alpha), .clear,
      ],
      startPoint: .leading, endPoint: .trailing
    )
    .frame(
      width: 9 * JournalLoadingGeometry.unit,
      height: 28 * JournalLoadingGeometry.unit
    )
    .offset(
      x: CGFloat(-8 + x) * JournalLoadingGeometry.unit,
      y: -3 * JournalLoadingGeometry.unit
    )
    .frame(width: 78, height: 78, alignment: .topLeading)
    .mask(JournalLogoShape())
  }

  /// CSS cubic-bezier(.4, 0, .2, 1), solved for x.
  private static func ease(_ progress: Double) -> Double {
    var t = progress
    for _ in 0..<6 {
      let x =
        3 * 0.4 * t * (1 - t) * (1 - t)
        + 3 * 0.2 * t * t * (1 - t) + t * t * t
      let slope =
        3 * 0.4 * (1 - t) * (1 - 3 * t)
        + 3 * 0.2 * t * (2 - 3 * t) + 3 * t * t
      if abs(slope) > 0.0001 { t = min(1, max(0, t - (x - progress) / slope)) }
    }
    return 3 * t * t * (1 - t) + t * t * t
  }
}
