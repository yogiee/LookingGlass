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
        let models = monitor.ollamaModels
        let valueText: String = {
            if monitor.ollamaStatus == "Offline" { return "Offline" }
            if monitor.ollamaVRAMGB > 0 { return String(format: "%.1f GB VRAM", monitor.ollamaVRAMGB) }
            return monitor.ollamaStatus
        }()
        // One model → show its name (as before). Multiple → "N models running",
        // with the per-model breakdown listed below the bar.
        let subtitleText: String? = {
            if models.count > 1 { return "\(models.count) models running" }
            return monitor.ollamaModel
        }()
        return MonitorCard(
            icon: "ollama-logo",
            isCustomIcon: true,
            label: "Ollama",
            subtitle: subtitleText,
            value: valueText,
            fill: vramFill
        ) {
            if models.count > 1 {
                VStack(spacing: 4) {
                    ForEach(models) { m in
                        HStack(spacing: 8) {
                            Text(m.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(String(format: "%.1f GB", m.vramGB))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
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

struct MonitorCard<Footer: View>: View {
    let icon: String
    var isCustomIcon: Bool = false
    let label: String
    var subtitle: String?
    let value: String
    let fill: Double
    /// Optional extra rows rendered below the dot-matrix bar (e.g. the Ollama
    /// card's per-model RAM breakdown). Defaults to nothing for the other cards.
    let footer: () -> Footer

    init(icon: String, isCustomIcon: Bool = false, label: String, subtitle: String? = nil,
         value: String, fill: Double, @ViewBuilder footer: @escaping () -> Footer) {
        self.icon = icon
        self.isCustomIcon = isCustomIcon
        self.label = label
        self.subtitle = subtitle
        self.value = value
        self.fill = fill
        self.footer = footer
    }

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
            footer()
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

// Footer-less convenience init for the cards that don't need a breakdown
// (CPU/GPU/RAM) — lets them omit the trailing closure and infer Footer == EmptyView.
extension MonitorCard where Footer == EmptyView {
    init(icon: String, isCustomIcon: Bool = false, label: String, subtitle: String? = nil,
         value: String, fill: Double) {
        self.init(icon: icon, isCustomIcon: isCustomIcon, label: label, subtitle: subtitle,
                  value: value, fill: fill, footer: { EmptyView() })
    }
}
