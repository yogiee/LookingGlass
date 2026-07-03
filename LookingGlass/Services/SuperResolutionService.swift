import AppKit
import CoreML
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Real-ESRGAN 4× super-resolution (Core ML, ANE). The 66.9 MB model is downloaded on first use
/// (Settings → Images) into Application Support and compiled on-device — kept out of the app bundle
/// so the DMG stays small (Invariant #7). Tier-1: the Upscale button stays disabled until it's ready
/// and nothing depends on it. Fixed 512→2048 shape → tile the image into 512 blocks, 4× each, stitch.
/// See WORKSPACE/apple-native/01-imaging-and-vision.md §C. BSD-3 model (xinntao/Real-ESRGAN).
@MainActor
final class SuperResolutionService: ObservableObject {
    static let shared = SuperResolutionService()
    private init() { refresh() }

    enum Status: Equatable { case notInstalled, downloading(Double), compiling, ready, failed(String) }
    @Published private(set) var status: Status = .notInstalled

    private let assetURL = URL(string: "https://github.com/yogiee/LookingGlass/releases/download/models-v1/RealESRGAN4x.mlmodel")!
    private let tileIn = 512
    private let factor = 4
    private var downloader: ModelDownloader?

    private var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LookingGlass/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var mlmodelURL: URL { modelsDir.appendingPathComponent("RealESRGAN4x.mlmodel") }
    private var compiledURL: URL { modelsDir.appendingPathComponent("RealESRGAN4x.mlmodelc") }

    var isReady: Bool { FileManager.default.fileExists(atPath: compiledURL.path) }

    func refresh() { if isReady, status != .ready { status = .ready } else if !isReady { status = .notInstalled } }

    /// Download + compile the model if it isn't installed yet. Safe to call repeatedly.
    func install() async {
        guard !isReady else { status = .ready; return }
        let dst = mlmodelURL, compiled = compiledURL
        do {
            status = .downloading(0)
            let dl = ModelDownloader(); downloader = dl
            try await dl.download(from: assetURL, to: dst) { p in
                Task { @MainActor in self.status = .downloading(p) }
            }
            status = .compiling
            let tmp = try await Task.detached(priority: .userInitiated) { try MLModel.compileModel(at: dst) }.value
            if FileManager.default.fileExists(atPath: compiled.path) { try? FileManager.default.removeItem(at: compiled) }
            try FileManager.default.moveItem(at: tmp, to: compiled)
            status = .ready
        } catch {
            try? FileManager.default.removeItem(at: dst)
            status = .failed(error.localizedDescription)
        }
        downloader = nil
    }

    /// Remove the installed model (frees ~67 MB).
    func remove() {
        try? FileManager.default.removeItem(at: mlmodelURL)
        try? FileManager.default.removeItem(at: compiledURL)
        status = .notInstalled
    }

    /// 4× upscale of the image at `path`, returned as PNG data (Sendable-safe across the actor
    /// boundary). Runs off the main thread. nil on failure / not ready.
    func upscale(path: String) async -> Data? {
        guard isReady else { return nil }
        let compiled = compiledURL, tile = tileIn, factor = self.factor
        return await Task.detached(priority: .userInitiated) {
            Self.run(path: path, compiledURL: compiled, tile: tile, factor: factor)
        }.value
    }

    /// Tile → Core ML inference → stitch, then encode PNG. Non-overlapping 512 tiles (edge tiles are
    /// clamped to a full 512 block so the fixed-shape model always gets 512×512); output cropped to
    /// exactly width×factor.
    private nonisolated static func run(path: String, compiledURL: URL, tile: Int, factor: Int) -> Data? {
        guard let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              src.width >= tile, src.height >= tile,
              let ml = try? MLModel(contentsOf: compiledURL),
              let vn = try? VNCoreMLModel(for: ml) else { return nil }
        let w = src.width, h = src.height, outW = w * factor, outH = h * factor, outTile = tile * factor
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let ciCtx = CIContext()
        let cols = Int(ceil(Double(w) / Double(tile))), rows = Int(ceil(Double(h) / Double(tile)))
        for r in 0..<rows {
            for c in 0..<cols {
                let sx = min(c * tile, w - tile), sy = min(r * tile, h - tile)
                guard let t = src.cropping(to: CGRect(x: sx, y: sy, width: tile, height: tile)) else { continue }
                let req = VNCoreMLRequest(model: vn); req.imageCropAndScaleOption = .scaleFill
                guard (try? VNImageRequestHandler(cgImage: t).perform([req])) != nil,
                      let obs = req.results?.first as? VNPixelBufferObservation,
                      let up = ciCtx.createCGImage(CIImage(cvPixelBuffer: obs.pixelBuffer),
                                                   from: CGRect(x: 0, y: 0, width: outTile, height: outTile))
                else { continue }
                // CGContext origin is bottom-left; source (sx,sy) is top-left.
                ctx.draw(up, in: CGRect(x: sx * factor, y: outH - sy * factor - outTile, width: outTile, height: outTile))
            }
        }
        guard let out = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

/// Thin URLSessionDownloadDelegate wrapper: download a file to `destination` with progress.
private final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var progress: ((Double) -> Void)?
    private var dest: URL!
    private var cont: CheckedContinuation<Void, Error>?

    func download(from url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        self.progress = progress; self.dest = destination
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.cont = c
            session.downloadTask(with: url).resume()
        }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            cont?.resume(); cont = nil
        } catch { cont?.resume(throwing: error); cont = nil }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { cont?.resume(throwing: error); cont = nil }
    }
}
