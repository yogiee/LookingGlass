import SwiftUI
import AppKit

/// Onboarding modal for a new project (Phase 3, Step 2). v1 fields: Name,
/// Description, Folder, optional guidelines. Model-map editing / tool selection /
/// knowledge upload are deferred (doc §11).
struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// (name, description, folder, guidelines, color)
    let onCreate: (String, String, URL, String, ProjectColor) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var folderURL: URL?
    @State private var guidelines = ""
    @State private var selectedColor: ProjectColor = .defaultBlue

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && folderURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Project")
                .font(.title2.weight(.semibold))

            field("Name") {
                FocusedTextField("Thesis Lit Review", text: $name)
            }

            field("Description") {
                FocusedTextField("Optional — what this project is about", text: $description)
            }

            field("Folder") {
                HStack(spacing: 8) {
                    Text(folderURL?.path ?? "No folder chosen")
                        .font(.system(size: 12))
                        .foregroundStyle(folderURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseFolder() }
                }
                Text("Where this project's files, images, and research land.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            field("Color") {
                ColorSwatchPicker(selected: $selectedColor)
            }

            field("Guidelines") {
                FocusedTextEditor(
                    text: $guidelines,
                    font: .system(size: 12, design: .monospaced),
                    minHeight: 84,
                    placeholder: "Optional — extra instructions appended to Alice's prompt."
                )
                Text("Optional — extra instructions appended to Alice's prompt in this project.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Project") {
                    guard let folderURL, canCreate else { return }
                    onCreate(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        description.trimmingCharacters(in: .whitespacesAndNewlines),
                        folderURL,
                        guidelines,
                        selectedColor
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose or create a folder for this project"
        if panel.runModal() == .OK, let url = panel.url {
            folderURL = url
        }
    }
}

// MARK: - Shared color swatch picker

struct ColorSwatchPicker: View {
    @Binding var selected: ProjectColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProjectColor.allCases, id: \.rawValue) { color in
                colorSwatch(color)
            }
        }
    }

    private func colorSwatch(_ color: ProjectColor) -> some View {
        let isSelected = selected == color
        return Circle()
            .fill(color.color)
            .frame(width: 24, height: 24)
            .overlay(
                Circle()
                    .strokeBorder(Color.primary.opacity(isSelected ? 0.5 : 0), lineWidth: 2)
                    .padding(-3)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isSelected ? 1 : 0)
            )
            .onTapGesture { selected = color }
            .animation(.easeInOut(duration: 0.12), value: isSelected)
    }
}
