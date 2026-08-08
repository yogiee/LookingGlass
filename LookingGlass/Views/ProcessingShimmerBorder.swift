import SwiftUI

/// The shared clock for everything that animates while a turn is running.
///
/// The comet and the voice sweep are drawn by different views, so rather than
/// plumbing a phase between them they both derive from absolute time and the
/// same period. Nothing to keep in sync because there is only one source.
enum ProcessingRhythm {
    /// Seconds for one full lap around the border.
    static let period: Double = 2.8

    /// Where the comet's bright core sits in the gradient (see the stops below).
    private static let headLocation: Double = 0.9

    static func phase(at time: TimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: period) / period
    }

    /// The comet head's angle, degrees clockwise from the right edge.
    private static func headAngle(at time: TimeInterval) -> Double {
        (phase(at: time) * 360 + headLocation * 360).truncatingRemainder(dividingBy: 360)
    }

    /// True while the comet is crossing the **top** border, and so travelling
    /// left to right; false along the bottom, travelling right to left.
    ///
    /// `AngularGradient` runs clockwise from due east in a y-down space, so the
    /// upper half of the loop is 180°–360°.
    static func travellingRight(at time: TimeInterval) -> Bool {
        headAngle(at: time) > 180
    }

    /// The comet's horizontal position across the composer, 0 = left edge,
    /// 1 = right edge.
    ///
    /// Approximates the rounded rect as its two long edges — the short sides
    /// take a negligible slice of a composer-shaped box, and the point is that
    /// the sweep rides *under* the comet rather than merely matching its
    /// direction.
    static func headX(at time: TimeInterval) -> Double {
        let angle = headAngle(at: time)
        return angle > 180 ? (angle - 180) / 180 : 1 - angle / 180
    }
}

/// A soft comet of light that travels around the input bar's border while a turn is
/// running. This is the persistent "Alice is working" signal: the in-bubble thinking
/// label disappears once tool cards or prose start rendering, but a tool-heavy turn
/// can keep processing long after that — the shimmer runs for exactly as long as the
/// STOP button is live.
struct ProcessingShimmerBorder: View {
    var cornerRadius: CGFloat = 16
    var lineWidth: CGFloat = 1.5
    /// The comet's colour. Follows the composer's mode so the border belongs to
    /// the same object as the wash inside it.
    var tint: Color = .accentColor

    var body: some View {
        TimelineView(.animation) { context in
            let phase = ProcessingRhythm.phase(at: context.date.timeIntervalSinceReferenceDate)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.55),
                            .init(color: tint.opacity(0.5), location: 0.8),
                            .init(color: Color.white.opacity(0.85), location: 0.9),
                            .init(color: tint.opacity(0.5), location: 0.97),
                            .init(color: .clear, location: 1),
                        ]),
                        center: .center,
                        angle: .degrees(phase * 360)
                    ),
                    lineWidth: lineWidth
                )
        }
        .allowsHitTesting(false)
    }
}
