import Foundation

/// Writes the on-disk skeleton of a project folder (Phase 3, Step 2). Swift
/// *creates* the folder; the sidecar will *interpret* it later (Step 3). The
/// folder is the contract between the two processes — see
/// WORKSPACE/phase3-projects-and-persistence.md §5–6.
///
/// Layout:
///   <folder>/project.toml      — [project] + [models] task→model map
///   <folder>/guidelines.md     — optional system-prompt addendum (only if provided)
///   <folder>/memory-bank/      — portable MD knowledge (MEMORY.md index stub)
enum ProjectScaffold {
    static func scaffold(projectID: UUID, name: String, description: String, folder: URL, guidelines: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)

            let tomlURL = folder.appendingPathComponent("project.toml")
            try projectTOML(name: name, id: projectID, description: description).write(to: tomlURL, atomically: true, encoding: .utf8)

            let trimmedGuidelines = guidelines.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedGuidelines.isEmpty {
                let guidelinesURL = folder.appendingPathComponent("guidelines.md")
                try trimmedGuidelines.write(to: guidelinesURL, atomically: true, encoding: .utf8)
            }

            let memoryBank = folder.appendingPathComponent("memory-bank", isDirectory: true)
            try fm.createDirectory(at: memoryBank, withIntermediateDirectories: true)
            let indexURL = memoryBank.appendingPathComponent("MEMORY.md")
            if !fm.fileExists(atPath: indexURL.path) {
                try "# Memory Index\n\n_Looking Glass memory-bank for **\(name)**._\n"
                    .write(to: indexURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[scaffold] failed for \(folder.path): \(error)")
        }
    }

    /// Sensible default task→model map. v1 ships these defaults; editing the map
    /// is a deferred onboarding field (doc §11). The sidecar reads this in Step 3.
    /// `description` is written into `[project]` so the sidecar (which only sees the
    /// folder, never the conversation DB) can make Alice aware of what the project
    /// is — the project path itself is NOT stored here; the sidecar injects that at
    /// runtime from the live working dir so it can't drift from the actual scope.
    private static func projectTOML(name: String, id: UUID, description: String) -> String {
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descLine = trimmedDesc.isEmpty ? "" : "\ndescription = \"\(escape(trimmedDesc))\""
        return """
        [project]
        name = "\(escape(name))"
        id   = "\(id.uuidString)"\(descLine)

        [models]
        default  = "qwen3.5:9b"
        coding   = "gemma4:latest"
        research = "qwen3.5:27b"
        """
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
