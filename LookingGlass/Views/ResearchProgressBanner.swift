import SwiftUI

/// Compact status capsule floating above the composer while a Deep Research run is
/// in progress (where the setting chips sit otherwise). Phase is derived from
/// incoming tool_call_start events in ChatViewModel — no sidecar changes required.
struct ResearchProgressBanner: View {
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 14, height: 14)
            Text(status)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .glassEffect(.regular, in: Capsule())
    }
}
