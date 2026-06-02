import SwiftUI

/// Elevation / contrast tokens — a SwiftUI port of the MemoryCentral dashboard's
/// surface system. The principle that makes elements legible on the frosted-glass
/// backdrop *without* touching the palette:
///   • a card reads as a **lighter surface** than its background,
///   • carries a **1px hairline ring** (adapts: light-on-dark / dark-on-light),
///   • casts a **soft shadow** + faint top highlight.
/// Recessed controls (search/input) invert it: a subtly *darker* fill + ring,
/// no shadow, so they read as inset wells.
extension View {
    /// Raised surface for message bubbles, tool cards, popovers.
    func elevatedSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(ElevatedSurface(cornerRadius: cornerRadius))
    }

    /// Recessed surface for search / input fields.
    func insetField(cornerRadius: CGFloat = 8) -> some View {
        modifier(InsetField(cornerRadius: cornerRadius))
    }
}

private struct ElevatedSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(fill))
            // Faint top highlight, then the hairline ring — the inset-light + ring
            // pairing is what separates the card edge from the glass.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.10 : 0.0), ring],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .clipShape(shape)
            .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.06), radius: 3, x: 0, y: 1)
    }

    private var fill: Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.66)
    }
    private var ring: Color { Color.primary.opacity(scheme == .dark ? 0.13 : 0.10) }
}

private struct InsetField: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05)))
            .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.13 : 0.10), lineWidth: 1))
            .clipShape(shape)
    }
}
