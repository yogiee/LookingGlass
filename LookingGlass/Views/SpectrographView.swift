import SwiftUI

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
    /// Dimmed while Alice is speaking — the mic is muted then, and a dead flat
    /// line should look deliberate rather than broken.
    var isMuted: Bool = false

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            draw(in: &context, size: size)
        }
        .frame(height: 34)
        .opacity(isMuted ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.2), value: isMuted)
        .accessibilityLabel(isMuted ? "Alice is speaking" : "Listening")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Mirrored around the centre: low frequencies inboard, high outboard.
        // That puts the energy of speech in the middle and lets the extremes
        // fall away to dots, which is what gives the reference its shape.
        let perSide = levels.count
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
            let band = index < perSide ? (perSide - 1 - index) : (index - perSide)
            let level = CGFloat(levels[min(band, perSide - 1)])

            // Taper toward the edges so the ends read as a fade rather than a
            // hard stop, and the display has a centre of gravity.
            let envelope = pow(1 - fromCentre, 0.85)
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
}
