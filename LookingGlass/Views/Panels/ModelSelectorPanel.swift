import SwiftUI

struct ModelSelectorPanel: View {
    @AppStorage("selectedModel") private var selectedModel = ""   // "" = Auto
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @State private var models: [String] = []
    @State private var loading = true

    private let client = SidecarClient()

    private let speedHints: [String: String] = [
        "qwen3.5:9b":  "fast · ~10s",
        "qwen3.5:27b": "deep · ~40–100s",
        "gemma4:latest": "fallback · ~7–22s",
    ]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Model")
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await fetchModels() }
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
                        hint: "project default, or qwen3.5:9b",
                        isSelected: selectedModel.isEmpty,
                        onTap: { selectedModel = "" }
                    )
                    Divider().padding(.leading, 14)
                    ForEach(models, id: \.self) { model in
                        ModelRow(
                            name: model,
                            hint: speedHints[model],
                            isSelected: model == selectedModel,
                            onTap: { selectedModel = model }
                        )
                        Divider().padding(.leading, 14)
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
    let hint: String?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    if let hint {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.07) : Color.clear)
    }
}
