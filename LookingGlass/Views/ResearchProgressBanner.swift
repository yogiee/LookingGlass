import SwiftUI

/// Compact status strip shown below the message list while a Deep Research
/// run is in progress. Phase is derived from incoming tool_call_start events
/// in ChatViewModel — no sidecar changes required.
struct ResearchProgressBanner: View {
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 14, height: 14)
            Text(status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }
}
