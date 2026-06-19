import SwiftUI

/// The Cheshire "Model" side panel — the full browser. Sets the **global default**
/// (`selectedModel`; "" = Auto). Per-chat overrides live in the input-bar switcher and
/// take precedence for their chat. Reads the shared `ModelCatalog` (registry-enriched).
struct ModelSelectorPanel: View {
    @AppStorage("selectedModel") private var selectedModel = ""   // "" = Auto
    @AppStorage("ollamaHost") private var ollamaHost = "http://localhost:11434"
    @EnvironmentObject private var catalog: ModelCatalog
    @EnvironmentObject private var sidecar: SidecarProcess

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
        .task { await catalog.refresh(ollamaHost: ollamaHost) }
        .onChange(of: sidecar.status) { _, newStatus in
            if newStatus == .running, catalog.models.isEmpty {
                Task { await catalog.refresh(ollamaHost: ollamaHost) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !catalog.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if catalog.models.isEmpty {
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
                    // Auto = let the sidecar choose (project default, else global default).
                    ModelRow(
                        name: "Auto",
                        subtitle: "Let Alice pick the right model",
                        badge: nil,
                        tint: .accentColor,
                        recommended: false,
                        untested: false,
                        isSelected: selectedModel.isEmpty,
                        onTap: { selectedModel = "" }
                    )
                    Divider()
                    // Recommended first, then the rest in registry/install order.
                    ForEach(sortedModels) { model in
                        ModelRow(
                            name: model.name,
                            subtitle: model.note,
                            badge: badge(for: model),
                            tint: familyColor(for: model.name),
                            recommended: model.recommended,
                            untested: model.untested,
                            isSelected: model.name == selectedModel,
                            onTap: { selectedModel = model.name }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private var sortedModels: [ModelInfo] {
        catalog.models.sorted { a, b in
            if a.recommended != b.recommended { return a.recommended }
            return false   // stable otherwise (keep install order)
        }
    }

    /// Cloud marker takes priority (it's a privacy-relevant fact); else measured speed.
    private func badge(for model: ModelInfo) -> String? {
        if model.isCloud { return "☁ cloud" }
        if let s = model.speedBadge { return s }
        return nil
    }
}

struct ModelRow: View {
    let name: String
    var subtitle: String? = nil
    let badge: String?
    let tint: Color?
    var recommended: Bool = false
    var untested: Bool = false
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        if recommended {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                                .help("Recommended")
                        }
                        if untested {
                            Text("untested")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle((tint ?? .secondary).opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((tint ?? Color.primary).opacity(0.10)))
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .padding(.vertical, 6)
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
