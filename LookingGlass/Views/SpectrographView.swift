import SwiftUI

/// What the voice display is doing.
enum SpectrographState: Equatable {
    /// Mic open, drawing what it hears.
    case live
    /// Alice is thinking. The mic is deaf, so there is nothing real to draw —
    /// a travelling wave says "working" without pretending to be your voice.
    case processing
    /// Alice is speaking. Mic deaf again; the bars fall to rest.
    case speaking
}

/// The live voice display that replaces the text field in voice mode.
///
/// Follows the bar reference rather than the flowing-ribbon one: discrete bars
/// stay legible at composer height and cost almost nothing, where ribbons need
/// vertical room this strip doesn't have.
///
/// Drawn in a single `Canvas` pass. Forty individually-animated views redrawing
/// ~20×/second is exactly the kind of per-frame view churn that has bitten this
/// app before — the smoothing lives in `AudioLevelMeter`'s ballistics instead,
/// so there is nothing here for SwiftUI to interpolate.
struct SpectrographView: View {
    /// Band energies, low → high frequency, each 0...1.
    var levels: [Float]
    var tint: Color
    var state: SpectrographState = .live

    var body: some View {
        Group {
            if state == .processing {
                // Self-animating: the wave is a function of time, so it needs a
                // clock rather than state changes. Only runs while processing,
                // which is bounded by the turn.
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(in: &context, size: size,
                             at: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                Canvas { context, size in
                    draw(in: &context, size: size, at: nil)
                }
            }
        }
        .frame(height: 34)
        .opacity(state == .live ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.25), value: state)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .live: return "Listening"
        case .processing: return "Alice is thinking"
        case .speaking: return "Alice is speaking"
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, at time: TimeInterval?) {
        let perSide = max(levels.count, AudioLevelMeter.bandCount)
        let total = perSide * 2
        let slot = size.width / CGFloat(total)
        // Capped, not just proportional: on a wide composer a pure ratio grows
        // the bars into slabs. A hard ceiling keeps them slender however much
        // room there is, with the gap taking up the slack.
        let barWidth = min(4.5, max(1.5, slot * 0.5))
        let midY = size.height / 2
        let maxBar = size.height

        for index in 0..<total {
            // Distance from centre, 0 at the middle, 1 at either edge.
            let fromCentre = abs(CGFloat(index) - CGFloat(total - 1) / 2) / (CGFloat(total) / 2)
            // Taper toward the edges so the ends read as a fade rather than a
            // hard stop, and the display has a centre of gravity.
            let envelope = pow(1 - fromCentre, 0.85)

            let level: CGFloat
            if let time {
                level = sweep(index: index, total: total, time: time)
            } else if index < levels.count * 2 {
                let band = index < levels.count ? (levels.count - 1 - index) : (index - levels.count)
                level = CGFloat(levels[min(band, levels.count - 1)])
            } else {
                level = 0
            }

            let height = max(barWidth, level * maxBar * envelope)
            let x = CGFloat(index) * slot + (slot - barWidth) / 2
            let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
            let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2)

            // Brightest where there is energy; the resting dots stay faint so a
            // silent mic looks calm instead of busy.
            let intensity = 0.30 + 0.70 * min(1, level * envelope * 1.4)
            context.fill(bar, with: .color(tint.opacity(intensity)))
        }
    }

    /// A soft hump that rides directly under the border comet — same clock, same
    /// position, so it sweeps left to right while the comet crosses the top and
    /// reverses when the comet turns back along the bottom.
    ///
    /// Deliberately smooth, unlike the spiky symmetric shape of real speech, so
    /// a glance never confuses "working" with "hearing you". It doesn't wrap:
    /// the comet reverses at the corners, so the wave reverses too.
    private func sweep(index: Int, total: Int, time: TimeInterval) -> CGFloat {
        let position = Double(index) / Double(max(total - 1, 1))
        let head = ProcessingRhythm.headX(at: time)
        let crest = exp(-pow((position - head) / 0.16, 2))

        // A broader companion trailing the head, so the sweep has some body.
        // Offset against the direction of travel rather than run at its own
        // speed — a second speed would drift out of step with the comet.
        let lag = head - (ProcessingRhythm.travellingRight(at: time) ? 0.17 : -0.17)
        let trail = exp(-pow((position - lag) / 0.28, 2)) * 0.4

        return CGFloat(min(1, crest + trail) * 0.62)
    }
}
