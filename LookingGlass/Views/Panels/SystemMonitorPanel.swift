import SwiftUI

struct SystemMonitorPanel: View {
    @StateObject private var monitor = SystemMonitor()
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "System", character: "queen")
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    MonitorCard(
                        icon: "cpu",
                        label: "CPU",
                        value: String(format: "%.0f%%", monitor.cpuPercent),
                        fill: monitor.cpuPercent / 100.0
                    )
                    if let gpu = monitor.gpuPercent {
                        MonitorCard(
                            icon: "memorychip",
                            label: "GPU",
                            value: String(format: "%.0f%%", gpu),
                            fill: gpu / 100.0
                        )
                    } else {
                        MonitorCard(
                            icon: "memorychip",
                            label: "GPU",
                            value: "N/A",
                            fill: 0
                        )
                    }
                    MonitorCard(
                        icon: "memorychip.fill",
                        label: "Memory",
                        value: String(format: "%.1f / %.0f GB", monitor.ramUsedGB, monitor.ramTotalGB),
                        fill: monitor.ramTotalGB > 0 ? monitor.ramUsedGB / monitor.ramTotalGB : 0
                    )
                    MonitorCard(
                        icon: "bolt.circle",
                        label: "Ollama",
                        value: monitor.ollamaStatus,
                        fill: monitor.ollamaStatus == "Running" ? 1.0 : 0,
                        isStatus: true
                    )
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { monitor.ollamaHost = ollamaHost; monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

struct MonitorCard: View {
    let icon: String
    let label: String
    let value: String
    let fill: Double
    var isStatus: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(barColor)
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            if !isStatus {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.1))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor)
                            .frame(width: geo.size.width * max(0, min(fill, 1)), height: 4)
                    }
                }
                .frame(height: 4)
            }
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
