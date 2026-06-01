import SwiftUI
import AppKit

/// Onboarding modal for a new project (Phase 3, Step 2). v1 fields: Name,
/// Description, Folder, optional guidelines. Model-map editing / tool selection /
/// knowledge upload are deferred (doc §11).
struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// (name, description, folder, guidelines)
    let onCreate: (String, String, URL, String) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var folderURL: URL?
    @State private var guidelines = ""

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && folderURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Project")
                .font(.title2.weight(.semibold))

            field("Name") {
                TextField("Thesis Lit Review", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            field("Description") {
                TextField("Optional — what this project is about", text: $description)
                    .textFieldStyle(.roundedBorder)
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

            field("Guidelines") {
                TextEditor(text: $guidelines)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 84)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
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
                        guidelines
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
