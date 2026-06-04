import SwiftUI

// Frosted-glass shelf at the top/bottom of the chat scroll view.
// Gradient mask fades the .ultraThinMaterial from the edge inward.
// Actual content blur is handled via .scrollTransition on MessageBubble.
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
                            .init(color: .black.opacity(0.90), location: 0.35),
                            .init(color: .black.opacity(0.40), location: 0.72),
                            .init(color: .clear,               location: 1.00)
                          ]
                        : [
                            .init(color: .clear,               location: 0.00),
                            .init(color: .black.opacity(0.40), location: 0.28),
                            .init(color: .black.opacity(0.90), location: 0.65),
                            .init(color: .black,               location: 1.00)
                          ],
                    startPoint: .top,
                    endPoint:   .bottom
                )
            }
    }
}
