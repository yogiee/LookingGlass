import SwiftUI

// Frosted glass shelf at the top/bottom of the chat scroll view.
// Uses SwiftUI's .ultraThinMaterial (backed by NSVisualEffectView with
// .withinWindow blending) — this blurs the actual scroll content beneath it.
// A gradient mask fades the blur smoothly from the edge inward.
struct GlassEdge: View {
    let atTop: Bool

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(
                    stops: atTop
                        ? [
                            .init(color: .black,               location: 0.00),
                            .init(color: .black.opacity(0.80), location: 0.30),
                            .init(color: .black.opacity(0.30), location: 0.70),
                            .init(color: .clear,               location: 1.00)
                          ]
                        : [
                            .init(color: .clear,               location: 0.00),
                            .init(color: .black.opacity(0.30), location: 0.30),
                            .init(color: .black.opacity(0.80), location: 0.70),
                            .init(color: .black,               location: 1.00)
                          ],
                    startPoint: .top,
                    endPoint:   .bottom
                )
            }
    }
}
