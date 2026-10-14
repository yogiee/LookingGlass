import Foundation

/// What the sidecar reports about Alice's neural voice (`GET /tts/status`).
///
/// Decoded with explicit `CodingKeys`, not `.convertFromSnakeCase`: that strategy also rewrites
/// DICTIONARY keys, which would silently turn the `"quality_plus"` tier key into `"qualityPlus"`.
struct NeuralVoiceStatus: Decodable, Equatable, Sendable {
    struct Reference: Decodable, Equatable, Sendable {
        let present: Bool
        /// Whether the clip has a transcript. With one, cloning copies delivery and accent; without,
        /// only the speaker's timbre.
        let transcript: Bool
        let audio: String
        let text: String
    }

    struct Download: Decodable, Equatable, Sendable {
        let state: String            // idle | waiting (on the voice engine) | running | done | error | cancelled
        let phase: String?           // the engine's install step: resolving | downloading | installing
        let doneBytes: Int
        let totalBytes: Int
        let error: String?

        enum CodingKeys: String, CodingKey {
            case state, error, phase
            case doneBytes = "done_bytes"
            case totalBytes = "total_bytes"
        }

        var isRunning: Bool { state == "running" }
        /// A QUALITY download held until the voice engine it needs has installed.
        var isWaiting: Bool { state == "waiting" }
        /// Running or waiting: something is still in flight, so keep polling.
        var isActive: Bool { isRunning || isWaiting }
        /// Stopped part-way (cancelled, or failed) with bytes on disk: downloading again resumes.
        var isResumable: Bool { (state == "cancelled" || state == "error") && doneBytes > 0 }
        var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
    }

    struct Tier: Decodable, Equatable, Sendable {
        let label: String
        let engine: String           // "mlx" (sidecar voice) | "coreai" (in-app voice, download only)
        let installed: Bool
        let downloadBytes: Int
        let residentGB: Double
        let peakGB: Double
        let download: Download

        enum CodingKeys: String, CodingKey {
            case label, engine, installed, download
            case downloadBytes = "download_bytes"
            case residentGB = "resident_gb"
            case peakGB = "peak_gb"
        }
    }

    /// The voice engine (mlx-audio + friends) the QUALITY tiers run on — a download, not part of the app.
    struct Engine: Decodable, Equatable, Sendable {
        let builtin: Bool            // a dev build with mlx-audio in the bundle: nothing to download
        let installed: Bool
        let outdated: Bool           // installed for an older app; QUALITY needs the update
        let downloadBytes: Int
        let installedBytes: Int
        let download: Download

        enum CodingKeys: String, CodingKey {
            case builtin, installed, outdated, download
            case downloadBytes = "download_bytes"
            case installedBytes = "installed_bytes"
        }
    }

    let available: Bool
    let unavailableReason: String?
    let engine: Engine?
    let reference: Reference
    let loadedTier: String?
    let residentGB: Double
    let sampleRate: Int
    let tiers: [String: Tier]

    enum CodingKeys: String, CodingKey {
        case available, reference, tiers, engine
        case unavailableReason = "unavailable_reason"
        case loadedTier = "loaded_tier"
        case residentGB = "resident_gb"
        case sampleRate = "sample_rate"
    }

    func tier(_ tier: VoiceTier) -> Tier? { tier.modelID.flatMap { tiers[$0] } }
}

/// A failure the sidecar explained (`{"code": …, "message": …}`), or a transport failure.
struct NeuralVoiceError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Thin client for the sidecar's `/tts` routes. Owns no state; `SpeechOutputService` does.
struct NeuralVoiceClient: Sendable {
    let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!) {
        self.baseURL = baseURL
    }

    func status() async -> NeuralVoiceStatus? {
        guard let (data, response) = try? await URLSession.shared.data(from: baseURL.appending(path: "/tts/status")),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(NeuralVoiceStatus.self, from: data)
    }

    /// The sidecar's default chat model (`/health`'s `model`) — what runs when the user hasn't picked one.
    func defaultChatModel() async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: baseURL.appending(path: "/health")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["model"] as? String
    }

    /// Load and warm a tier. Returns nil on success, or the sidecar's explanation.
    @discardableResult
    func prepare(_ tier: VoiceTier) async -> NeuralVoiceError? {
        await post("/tts/prepare", ["tier": tier.sidecarID ?? ""])
    }

    func unload() async {
        _ = await post("/tts/unload", [:])
    }

    @discardableResult
    func startDownload(_ tier: VoiceTier) async -> NeuralVoiceError? {
        await post("/tts/download", ["tier": tier.modelID ?? ""])
    }

    /// The voice engine shares the tiers' download routes under the id "engine".
    static let engineID = "engine"

    @discardableResult
    func startEngineDownload() async -> NeuralVoiceError? {
        await post("/tts/download", ["tier": Self.engineID])
    }

    @discardableResult
    func cancelEngineDownload() async -> NeuralVoiceError? {
        await post("/tts/download/cancel", ["tier": Self.engineID])
    }

    @discardableResult
    func removeEngine() async -> NeuralVoiceError? {
        var request = URLRequest(url: baseURL.appending(path: "/tts/models/\(Self.engineID)"))
        request.httpMethod = "DELETE"
        return await send(request)
    }

    /// Stop a running download. Its partial files stay, so the next `startDownload` resumes.
    @discardableResult
    func cancelDownload(_ tier: VoiceTier) async -> NeuralVoiceError? {
        await post("/tts/download/cancel", ["tier": tier.modelID ?? ""])
    }

    @discardableResult
    func delete(_ tier: VoiceTier) async -> NeuralVoiceError? {
        guard let id = tier.modelID else { return nil }
        var request = URLRequest(url: baseURL.appending(path: "/tts/models/\(id)"))
        request.httpMethod = "DELETE"
        return await send(request)
    }

    /// Open the audio stream for `text`. Throws `NeuralVoiceError` if the sidecar refuses (not installed,
    /// no reference clip…) — the sidecar loads the model BEFORE its first byte, so a load failure arrives
    /// here as an error rather than as an empty stream.
    func speak(_ text: String, tier: VoiceTier) async throws -> (URLSession.AsyncBytes, sampleRate: Double) {
        var request = URLRequest(url: baseURL.appending(path: "/tts/speak"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "tier": tier.sidecarID ?? ""])
        // The stream lasts as long as the reading. This is the idle gap between packets, which only a
        // cold model load can stretch (a few seconds at worst).
        request.timeoutInterval = 60
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw Self.decodeError(body, status: http?.statusCode ?? 0)
        }
        let rate = Double(http?.value(forHTTPHeaderField: "X-Sample-Rate") ?? "") ?? 24_000
        return (bytes, rate)
    }

    // MARK: - Helpers

    private func post(_ path: String, _ body: [String: String]) async -> NeuralVoiceError? {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Prepare can include a cold model load plus a warm-up generation.
        request.timeoutInterval = 120
        return await send(request)
    }

    private func send(_ request: URLRequest) async -> NeuralVoiceError? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status) ? nil : Self.decodeError(data, status: status)
        } catch {
            return NeuralVoiceError(code: "transport", message: error.localizedDescription)
        }
    }

    private static func decodeError(_ data: Data, status: Int) -> NeuralVoiceError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return NeuralVoiceError(code: json["code"] as? String ?? "http_\(status)", message: message)
        }
        return NeuralVoiceError(code: "http_\(status)", message: "The voice engine returned HTTP \(status).")
    }
}

/// How big the chat model is that will sit beside the voice — the input AUTO subtracts from the budget.
///
/// Uses Ollama's `/api/tags` size. For the MLX chat models this equals the resident weights (gemma4:26b-mlx:
/// 18.3 GB in `/api/tags` and 18.3 GB VRAM in `/api/ps`, measured 2026-09-21). Deliberately NOT `/api/ps`:
/// Ollama unloads idle models, so measuring whatever happens to be loaded would see an empty GPU during a
/// lull, pick a voice that's too big, and collide when the chat model comes back.
enum PrimaryModelProbe {
    static func footprintGB(model: String, ollamaHost: String) async -> Double? {
        guard let url = URL(string: "\(ollamaHost)/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return nil }
        let wanted = model.contains(":") ? model : "\(model):latest"
        guard let entry = models.first(where: { ($0["name"] as? String) == wanted || ($0["model"] as? String) == wanted }),
              let size = entry["size"] as? Double ?? (entry["size"] as? Int).map(Double.init)
        else { return nil }
        return size / 1e9
    }
}
