import SwiftUI

struct SettingsMCPTab: View {
    @EnvironmentObject private var sidecar: SidecarProcess

    @State private var servers: [MCPServerItem] = []
    @State private var status: [String: String] = [:]
    @State private var loading = true
    @State private var showingAddSheet = false
    @State private var restartPending = false
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            if loading {
                Spacer()
                ProgressView("Loading…").padding()
                Spacer()
            } else if servers.isEmpty {
                emptyState
            } else {
                serverList
            }
            if restartPending || sidecar.status == .stopped {
                restartBanner
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showingAddSheet) {
            AddMCPServerSheet { name, command, args, env in
                Task { await addServer(name: name, command: command, args: args, env: env) }
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack {
            Text("MCP servers extend Alice with external tools.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingAddSheet = true
            } label: {
                Label("Add Server…", systemImage: "plus")
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
            Image(systemName: "network")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No MCP servers configured")
                .font(.system(size: 13, weight: .medium))
            Text("Add a server to give Alice access to external tools and data sources.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Server list

    private var serverList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(servers) { server in
                    serverRow(server)
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private func serverRow(_ server: MCPServerItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            // Status dot
            Circle()
                .fill(statusColor(for: server.name))
                .frame(width: 7, height: 7)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.system(size: 15, weight: .medium))
                    if server.source == "config" {
                        Text("config")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(([server.command] + server.args).joined(separator: " "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Only user-added servers can be deleted via UI
            if server.source == "user" {
                Button {
                    Task { await deleteServer(server) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Remove server")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Restart banner

    private var restartBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("Restart required to apply changes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Restart Now") {
                restartPending = false
                errorMessage = nil
                sidecar.restart()
                // Reload after restart settles
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    await reload()
                }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
            .tint(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: Actions

    @MainActor
    private func addServer(name: String, command: String, args: [String], env: [String: String]) async {
        errorMessage = nil
        let ok = await client.addMCPServer(name: name, command: command, args: args, env: env)
        if ok {
            restartPending = true
            await reload()
        } else {
            errorMessage = "Failed to add server — is the sidecar running?"
        }
    }

    @MainActor
    private func deleteServer(_ server: MCPServerItem) async {
        errorMessage = nil
        let ok = await client.deleteMCPServer(name: server.name)
        if ok {
            restartPending = true
            await reload()
        } else {
            errorMessage = "Failed to remove server — is the sidecar running?"
        }
    }

    @MainActor
    private func reload() async {
        loading = true
        async let s = client.fetchMCPServers()
        async let st = client.fetchMCPStatus()
        (servers, status) = await (s, st)
        loading = false
    }

    private func statusColor(for name: String) -> Color {
        switch status[name] {
        case "connected": return .green
        case "failed":    return .red
        default:          return .secondary.opacity(0.5)
        }
    }
}

// MARK: - Add MCP Server Sheet

struct AddMCPServerSheet: View {
    let onAdd: (String, String, [String], [String: String]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var command = ""
    @State private var argsText = ""     // one arg per line
    @State private var envText = ""      // KEY=VALUE, one per line

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add MCP Server")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Name", hint: "e.g. memory") {
                        FocusedTextField("identifier", text: $name,
                                         font: .system(size: 12, design: .monospaced))
                    }

                    field("Command", hint: "Executable path or command") {
                        FocusedTextField("/usr/bin/env node server.js", text: $command,
                                         font: .system(size: 12, design: .monospaced))
                    }

                    field("Arguments", hint: "One per line (optional)") {
                        FocusedTextEditor(text: $argsText,
                                          font: .system(size: 12, design: .monospaced),
                                          minHeight: 60)
                    }

                    field("Environment", hint: "KEY=VALUE, one per line (optional)") {
                        FocusedTextEditor(text: $envText,
                                          font: .system(size: 12, design: .monospaced),
                                          minHeight: 60)
                    }

                    Text("Changes take effect after restarting the sidecar.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Server") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
            .padding(16)
        }
        .frame(width: 420, height: 440)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            content()
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func submit() {
        let trimName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimCmd  = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimName.isEmpty, !trimCmd.isEmpty else { return }

        let args = argsText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var env: [String: String] = [:]
        for line in envText.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if let eq = s.firstIndex(of: "=") {
                let key = String(s[s.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                let val = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { env[key] = val }
            }
        }

        onAdd(trimName, trimCmd, args, env)
        dismiss()
    }
}
