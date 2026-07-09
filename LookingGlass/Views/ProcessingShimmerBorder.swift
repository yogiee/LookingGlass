import SwiftUI

/// A soft comet of light that travels around the input bar's border while a turn is
/// running. This is the persistent "Alice is working" signal: the in-bubble thinking
/// label disappears once tool cards or prose start rendering, but a tool-heavy turn
/// can keep processing long after that — the shimmer runs for exactly as long as the
/// STOP button is live.
struct ProcessingShimmerBorder: View {
    var cornerRadius: CGFloat = 16
    var lineWidth: CGFloat = 1.5
    /// Seconds for one full lap around the border.
    var period: Double = 2.8

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: period) / period
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.55),
                            .init(color: Color.accentColor.opacity(0.5), location: 0.8),
                            .init(color: Color.white.opacity(0.85), location: 0.9),
                            .init(color: Color.accentColor.opacity(0.5), location: 0.97),
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
