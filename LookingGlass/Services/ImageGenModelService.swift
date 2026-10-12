import Foundation

/// The on-device image model (FLUX.2 [klein] 4B on Core AI) as Settings sees it: installed or not, and the
/// download, from the sidecar's `/imagegen` routes. Generation itself is Alice's `generate_image` tool, run by the
/// sidecar (Invariant #2) — the app only manages the download, like the voice models.
@MainActor
final class ImageGenModelService: ObservableObject {
    static let shared = ImageGenModelService()

    struct Model: Decodable, Equatable {
        let label: String
        let installed: Bool
        let downloadBytes: Int
        let license: String
        let source: String
        let download: NeuralVoiceStatus.Download   // same shape as a voice model's download

        enum CodingKeys: String, CodingKey {
            case label, installed, license, source, download
            case downloadBytes = "download_bytes"
        }
    }

    struct Status: Decodable, Equatable {
        let available: Bool
        let unavailableReason: String?
        let generating: Bool
        let models: [String: Model]

        enum CodingKeys: String, CodingKey {
            case available, generating, models
            case unavailableReason = "unavailable_reason"
        }
    }

    /// The one model today. Keyed so a second (Z-Image, the photoreal lane) can join later.
    static let modelID = "klein"

    @Published private(set) var status: Status?
    private let baseURL = URL(string: "http://127.0.0.1:8765")!
    private var pollTask: Task<Void, Never>?

    var model: Model? { status?.models[Self.modelID] }

    func refresh() async {
        guard let (data, response) = try? await URLSession.shared.data(from: baseURL.appending(path: "/imagegen/status")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Status.self, from: data)
        else { return }
        if decoded != status { status = decoded }
        if decoded.models.values.contains(where: { $0.download.isRunning }) { pollWhileDownloading() }
    }

    func download() async -> String? {
        let error = await post("/imagegen/download")
        await refresh()
        pollWhileDownloading()
        return error
    }

    func cancel() async -> String? {
        let error = await post("/imagegen/download/cancel")
        await refresh()
        return error
    }

    func remove() async -> String? {
        var request = URLRequest(url: baseURL.appending(path: "/imagegen/models/\(Self.modelID)"))
        request.httpMethod = "DELETE"
        let error = await send(request)
        await refresh()
        return error
    }

    private func pollWhileDownloading() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self.refresh()
                if !(self.status?.models.values.contains { $0.download.isRunning } ?? false) {
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    private func post(_ path: String) async -> String? {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": Self.modelID])
        return await send(request)
    }

    /// nil on success, else the sidecar's message (or the transport error).
    private func send(_ request: URLRequest) async -> String? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return nil }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return body?["message"] as? String ?? "HTTP \(http.statusCode)"
        } catch {
            return "Couldn't reach the sidecar: \(error.localizedDescription)"
        }
    }
}
