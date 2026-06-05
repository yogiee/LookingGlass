import SwiftUI

struct SystemMonitorPanel: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "System", character: "rabbit")
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    MonitorCard(
                        icon: "cpu",
                        label: "CPU",
                        subtitle: monitor.cpuSubtitle.isEmpty ? nil : monitor.cpuSubtitle,
                        value: String(format: "%.0f%%", monitor.cpuPercent),
                        fill: monitor.cpuPercent / 100.0
                    )
                    MonitorCard(
                        icon: "circle.hexagongrid.circle",
                        label: "GPU",
                        subtitle: monitor.gpuSubtitle.isEmpty ? nil : monitor.gpuSubtitle,
                        value: monitor.gpuPercent.map { String(format: "%.0f%%", $0) } ?? "N/A",
                        fill: (monitor.gpuPercent ?? 0) / 100.0
                    )
                    MonitorCard(
                        icon: "memorychip",
                        label: "Memory",
                        subtitle: nil,
                        value: String(format: "%.1f / %.0f GB", monitor.ramUsedGB, monitor.ramTotalGB),
                        fill: monitor.ramTotalGB > 0 ? monitor.ramUsedGB / monitor.ramTotalGB : 0
                    )
                    ollamaCard
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { monitor.ollamaHost = ollamaHost }
    }

    private var ollamaCard: some View {
        let vramFill = monitor.ramTotalGB > 0 ? monitor.ollamaVRAMGB / monitor.ramTotalGB : 0
        let valueText: String = {
            if monitor.ollamaStatus == "Offline" { return "Offline" }
            if monitor.ollamaVRAMGB > 0 { return String(format: "%.1f GB VRAM", monitor.ollamaVRAMGB) }
            return monitor.ollamaStatus
        }()
        return MonitorCard(
            icon: "ollama-logo",
            isCustomIcon: true,
            label: "Ollama",
            subtitle: monitor.ollamaModel,
            value: valueText,
            fill: vramFill
        )
    }
}

// MARK: - Dot Matrix Bar

struct DotMatrixBar: View {
    var fill: Double        // 0...1
    var color: Color = .accentColor

    private let rows    = 5
    private let dotSize: CGFloat = 3
    private let gap:     CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme

    private var emptyColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
    }

    var body: some View {
        Canvas { ctx, size in
            let unit   = dotSize + gap
            let cols   = Int((size.width + gap) / unit)
            let dotH   = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let filled = max(0, min(cols, Int((fill * Double(cols)).rounded())))

            for row in 0..<rows {
                for col in 0..<cols {
                    let x = CGFloat(col) * unit
                    let y = CGFloat(row) * (dotH + gap)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: dotSize, height: dotH)),
                        with: .color(col < filled ? color : emptyColor)
                    )
                }
            }
        }
        .frame(height: dotSize * CGFloat(rows) + gap * CGFloat(rows - 1))
    }
}

// MARK: - Monitor Card

struct MonitorCard: View {
    let icon: String
    var isCustomIcon: Bool = false
    let label: String
    var subtitle: String?
    let value: String
    let fill: Double

    @Environment(\.colorScheme) private var colorScheme

    private var iconColor: Color {
        colorScheme == .dark ? .white : .black
    }

    @ViewBuilder
    private var iconView: some View {
        if isCustomIcon {
            Asset.image(icon)
                .scaledToFit()
                .frame(width: 32, height: 32)
                .colorMultiply(iconColor)
                .frame(width: 42, alignment: .center)
        } else {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 42, alignment: .center)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                iconView
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            DotMatrixBar(fill: fill, color: barColor)
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var barColor: Color {
        if fill > 0.85 { return .red }
        if fill > 0.65 { return .orange }
        return Color.accentColor
    }

    private var cardBackground: some View {
        Group {
            if colorScheme == .dark {
                Color.white.opacity(0.08)
            } else {
                Color.black.opacity(0.05)
            }
        }
    }
}
