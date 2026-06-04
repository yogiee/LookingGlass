import SwiftUI

struct ModelSelectorPanel: View {
    @AppStorage("selectedModel") private var selectedModel = ""   // "" = Auto
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @State private var models: [String] = []
    @State private var loading = true
    @EnvironmentObject private var sidecar: SidecarProcess

    private let client = SidecarClient()

    private let modelBadges: [String: String] = [
        "qwen3.5:9b":          "~10s",
        "qwen3.5:9b-mlx":      "~10s",
        "qwen3.5:4b-mlx":      "~6s",
        "qwen3.5:2b-mlx":      "~3s",
        "qwen3.5:27b":         "~40–100s",
        "qwen3.5:27b-mlx":     "~40s",
        "qwen3.6:27b-mlx":     "~40s",
        "gemma4:latest":       "fallback",
        "x/z-image-turbo:latest": "image",
        "x/flux2-klein:9b":    "image",
        "glm-ocr:latest":      "ocr",
        "nomic-embed-text:latest": "embed",
    ]

    private func familyColor(for model: String) -> Color? {
        if model.hasPrefix("qwen") { return .cyan }
        if model.hasPrefix("gemma") { return .green }
        if model.hasPrefix("x/z-image") || model.hasPrefix("x/flux") { return .purple }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Model", character: "cheshire")
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await fetchModels() }
        // Re-fetch when sidecar transitions to running (catches the startup race
        // where the panel opens before the sidecar is healthy)
        .onChange(of: sidecar.status) { _, newStatus in
            if newStatus == .running, models.isEmpty {
                Task { await fetchModels() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if models.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "cpu.trianglebadge.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Ollama not reachable")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Auto = let the sidecar choose: a project's project.toml default,
                    // else the global default. Explicit picks below always override.
                    ModelRow(
                        name: "Auto",
                        badge: nil,
                        tint: .accentColor,
                        isSelected: selectedModel.isEmpty,
                        onTap: { selectedModel = "" }
                    )
                    Divider()
                    ForEach(models, id: \.self) { model in
                        ModelRow(
                            name: model,
                            badge: modelBadges[model],
                            tint: familyColor(for: model),
                            isSelected: model == selectedModel,
                            onTap: { selectedModel = model }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private func fetchModels() async {
        loading = true
        models = await client.fetchModels(ollamaHost: ollamaHost)
        loading = false
        // Only repair a stale *explicit* pick; never clobber Auto ("").
        if !selectedModel.isEmpty, !models.contains(selectedModel), let first = models.first {
            selectedModel = first
        }
    }
}

struct ModelRow: View {
    let name: String
    let badge: String?
    let tint: Color?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle((tint ?? .secondary).opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((tint ?? Color.primary).opacity(0.10))
                        )
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? (tint ?? Color.accentColor).opacity(0.10)
                : (tint ?? Color.clear).opacity(0.04)
        )
    }
}
