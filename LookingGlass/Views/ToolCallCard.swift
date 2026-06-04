import SwiftUI

struct ToolCallCard: View {
    let call: ToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().padding(.horizontal, 12)
                detail
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                Text(titleText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                statusView

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusView: some View {
        if !call.isComplete {
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        } else {
            HStack(spacing: 5) {
                if call.latencyMs > 0 {
                    Text(latencyText)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Image(systemName: call.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(call.success ? Color.green : Color.red)
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !call.argsJSON.isEmpty && call.argsJSON != "{}" {
                detailSection(label: call.isThink ? "Thought" : "Arguments", text: call.argsJSON)
            }
            if call.isComplete && !call.result.isEmpty {
                detailSection(label: "Result", text: call.result)
            }
        }
        .padding(12)
    }

    private func detailSection(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: Presentation helpers

    private var titleText: String {
        if call.isThink { return "Thinking" }
        return call.tool
    }

    private var latencyText: String {
        call.latencyMs >= 1000
            ? String(format: "%.1fs", Double(call.latencyMs) / 1000)
            : "\(call.latencyMs)ms"
    }

    private var iconName: String {
        switch call.tool {
        case "think":         return "lightbulb"
        case "web_search":    return "magnifyingglass"
        case "file_read":     return "doc.text"
        case "file_write":    return "square.and.pencil"
        case "apply_patch":   return "bandage"
        case "shell_exec":    return "terminal"
        case "http_request":  return "network"
        case "calculator":    return "function"
        case "pdf_extract":   return "doc.richtext"
        default:              return "wrench.and.screwdriver"
        }
    }

    private var iconColor: Color {
        call.isThink ? .orange : .accentColor
    }
}
