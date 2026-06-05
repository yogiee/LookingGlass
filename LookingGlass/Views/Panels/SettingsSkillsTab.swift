import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsSkillsTab: View {
    @State private var skills: [SkillItem] = []
    @State private var loading = true
    @State private var expandedSkill: String? = nil     // id of skill showing when_to_use
    @State private var confirmDelete: SkillItem? = nil
    @State private var errorMessage: String? = nil

    private let client = SidecarClient()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            if loading {
                Spacer()
                ProgressView("Loading skills…").padding()
                Spacer()
            } else if skills.isEmpty {
                emptyState
            } else {
                skillList
            }
        }
        .task { await reload() }
        .confirmationDialog(
            "Delete \"\(confirmDelete?.name ?? "")\"?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let skill = confirmDelete { Task { await deleteSkill(skill) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the skill folder from disk. Alice will stop seeing it immediately.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack {
            Text("Skills are playbooks Alice follows for multi-step tasks.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                importSkill()
            } label: {
                Label("Import Skill…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "list.star")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No skills installed")
                .font(.system(size: 13, weight: .medium))
            Text("Import a SKILL.md file to give Alice step-by-step playbooks for complex tasks.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private var skillList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(skills) { skill in
                    skillRow(skill)
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private func skillRow(_ skill: SkillItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "list.star")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, alignment: .top)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name)
                        .font(.system(size: 15, weight: .medium))
                    Text(skill.description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 4) {
                    if !skill.whenToUse.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expandedSkill = expandedSkill == skill.id ? nil : skill.id
                            }
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("When to use")
                    }
                    Button {
                        confirmDelete = skill
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Delete skill")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expandedSkill == skill.id, !skill.whenToUse.isEmpty {
                Text(skill.whenToUse)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Actions

    private func importSkill() {
        let panel = NSOpenPanel()
        panel.title = "Import Skill"
        panel.message = "Select a SKILL.md file to import"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await performImport(url: url) }
        }
    }

    @MainActor
    private func performImport(url: URL) async {
        errorMessage = nil
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "Could not read file."
            return
        }
        // Derive skill name: prefer frontmatter `name:`, fallback to filename
        let folderName = extractSkillName(from: content, filename: url.deletingPathExtension().lastPathComponent)
        let ok = await client.importSkill(folderName: folderName, content: content)
        if ok {
            await reload()
        } else {
            errorMessage = "Import failed — is the sidecar running?"
        }
    }

    @MainActor
    private func deleteSkill(_ skill: SkillItem) async {
        errorMessage = nil
        confirmDelete = nil
        let ok = await client.deleteSkill(folderName: skill.folder)
        if ok {
            await reload()
        } else {
            errorMessage = "Delete failed — is the sidecar running?"
        }
    }

    @MainActor
    private func reload() async {
        loading = true
        skills = await client.fetchSkills()
        loading = false
    }

    private func extractSkillName(from content: String, filename: String) -> String {
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("name:") {
                let val = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !val.isEmpty { return val }
            }
        }
        return filename.isEmpty ? "unnamed" : filename
    }
}
