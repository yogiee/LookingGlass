import Foundation

@MainActor
class SidecarProcess: ObservableObject {
    @Published var status: Status = .stopped

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private let client = SidecarClient()

    func start() {
        guard process == nil else { return }
        status = .starting

        let sidecarDir = resolveSidecarDir()
        let python = resolvePython(sidecarDir: sidecarDir)

        guard FileManager.default.fileExists(atPath: sidecarDir + "/main.py") else {
            status = .failed("sidecar/main.py not found at \(sidecarDir)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["main.py"]
        proc.currentDirectoryURL = URL(fileURLWithPath: sidecarDir)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                print("[sidecar]", str, terminator: "")
            }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.process = nil
                if self?.status == .running || self?.status == .starting {
                    self?.status = .stopped
                }
            }
        }

        do {
            try proc.run()
            process = proc
            pollHealthUntilReady()
        } catch {
            status = .failed("Launch failed: \(error.localizedDescription)")
        }
    }

    /// Stop the sidecar cleanly. SIGTERM lets uvicorn shut down gracefully; if it
    /// hasn't exited within a short window we SIGKILL so we never leave an orphan
    /// (macOS reparents orphaned children to launchd rather than killing them, and
    /// a stale sidecar would still hold port 8765 on the next launch).
    ///
    /// Note: stopping the sidecar does NOT unload the Ollama model — that lives in
    /// the Ollama daemon and is released by its own keep_alive timer (see
    /// config.toml). This only reaps our own Python process.
    func stop() {
        healthTask?.cancel()
        healthTask = nil

        guard let proc = process else {
            status = .stopped
            return
        }
        process = nil

        if proc.isRunning {
            proc.terminate()  // SIGTERM
            // Brief synchronous wait — we're almost always inside app termination,
            // so blocking the main thread for up to ~2s here is acceptable.
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        status = .stopped
    }

    private func pollHealthUntilReady() {
        healthTask = Task {
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if await client.health() {
                    status = .running
                    return
                }
            }
            status = .failed("Sidecar did not become healthy after 30s")
        }
    }

    private func resolveSidecarDir() -> String {
        // 1. Shipped .app: sidecar is embedded at Contents/Resources/sidecar
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = resourcePath + "/sidecar"
            if FileManager.default.fileExists(atPath: bundled + "/main.py") {
                return bundled
            }
        }
        // 2. Development (`swift run`): working dir is the project root
        let cwd = FileManager.default.currentDirectoryPath
        let cwdCandidate = cwd + "/sidecar"
        if FileManager.default.fileExists(atPath: cwdCandidate + "/main.py") {
            return cwdCandidate
        }
        // 3. Fallback: adjacent to the .app bundle
        return Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("sidecar")
            .path
    }

    private func resolvePython(sidecarDir: String) -> String {
        // Prefer virtual environment
        let venvPython = sidecarDir + "/.venv/bin/python3"
        if FileManager.default.fileExists(atPath: venvPython) {
            return venvPython
        }
        // Apple Silicon Homebrew
        let brewPython = "/opt/homebrew/bin/python3"
        if FileManager.default.fileExists(atPath: brewPython) {
            return brewPython
        }
        return "/usr/bin/python3"
    }
}
