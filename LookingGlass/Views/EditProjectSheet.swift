import SwiftUI

struct EditProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: ProjectListItem
    let onUpdate: (String, String, ProjectColor) -> Void

    @State private var name: String
    @State private var description: String
    @State private var selectedColor: ProjectColor

    init(project: ProjectListItem, onUpdate: @escaping (String, String, ProjectColor) -> Void) {
        self.project = project
        self.onUpdate = onUpdate
        _name = State(initialValue: project.name)
        _description = State(initialValue: project.description)
        _selectedColor = State(initialValue: project.color)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Project")
                .font(.title2.weight(.semibold))

            field("Name") {
                FocusedTextField("Project name", text: $name)
            }

            field("Description") {
                FocusedTextField("Optional — what this project is about", text: $description)
            }

            field("Color") {
                ColorSwatchPicker(selected: $selectedColor)
            }

            field("Folder") {
                HStack(spacing: 6) {
                    Text(project.folderPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: project.folderPath))
                    }
                    .font(.system(size: 12))
                }
                Text("Folder path is locked. Edit guidelines.md directly in the project folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard canSave else { return }
                    onUpdate(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        description.trimmingCharacters(in: .whitespacesAndNewlines),
                        selectedColor
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
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
}
