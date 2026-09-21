import AppKit
import CoreImage
import CoreVideo
import VideoToolbox

/// Apple's 4× super-resolution (`VTSuperResolutionScaler`, VideoToolbox, macOS 26+). The model is part of
/// macOS — nothing for us to host or download; if it isn't on this Mac yet, Settings → Images asks macOS
/// for it. Tier-1: the Upscale button stays disabled until it's ready and nothing depends on it.
///
/// Chosen over RealPLKSR in the 2026-09-21 bake-off (WORKSPACE/upscale-bakeoff-2026-09-21/): the most
/// faithful of the candidates (colour drift ΔE 0.22, best PSNR/SSIM) and 0.67 s / ~4 GB for a 1024² →
/// 4096² image, where RealPLKSR had become 38 s / ~11 GB on macOS 27. It's a little soft, so the review's
/// Detail slider blends it with a sharpened copy of itself: a light luminance sharpen that brings back
/// detail without looking artificial (tuned on the bake-off's recovery test).
@MainActor
final class SuperResolutionService: ObservableObject {
    static let shared = SuperResolutionService()
    private init() { refresh() }

    enum Status: Equatable { case unsupported, needsDownload, downloading(Double), ready, failed(String) }
    @Published private(set) var status: Status = .needsDownload

    /// The scaler takes at most 1920 px per side (4× → 7680) and at least 16.
    static let maxSide = 1920
    static let minSide = 16
    /// The sharpen that the Detail slider blends toward (`CISharpenLuminance`): the slider's top end.
    /// The default position lands on sharpness 1.6 — see `InlineImageView.detailFraction`.
    nonisolated static let sharpenRadius = 0.75
    nonisolated static let maxSharpness = 3.0

    var isReady: Bool { status == .ready }

    func canUpscale(_ size: CGSize) -> Bool {
        let w = Int(size.width), h = Int(size.height)
        return w >= Self.minSide && h >= Self.minSide && w <= Self.maxSide && h <= Self.maxSide
    }

    /// Re-read the model's state from macOS (it can arrive on its own, via another app, or after an OS update).
    func refresh() {
        guard VTSuperResolutionScalerConfiguration.isSupported else { status = .unsupported; return }
        if case .downloading = status { return }
        guard let config = Self.configuration(width: 1024, height: 1024) else { status = .unsupported; return }
        switch config.configurationModelStatus {
        case .ready: status = .ready
        case .downloading: status = .downloading(Double(config.configurationModelPercentageAvailable))
        default: status = .needsDownload
        }
    }

    /// Ask macOS to fetch the model. Only ever from the user's press in Settings.
    func install() async {
        guard let config = Self.configuration(width: 1024, height: 1024) else { status = .unsupported; return }
        status = .downloading(Double(config.configurationModelPercentageAvailable))
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.status = .downloading(Double(config.configurationModelPercentageAvailable))
            }
        }
        defer { poll.cancel() }
        do {
            try await config.downloadConfigurationModel()
            status = config.configurationModelStatus == .ready ? .ready : .needsDownload
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// 4× the image at `path`, plus the same result with the full Detail sharpen applied — the two ends
    /// the review's Detail slider blends between. Runs off the main actor. nil if not ready, the image is
    /// out of range, or anything fails.
    func upscale(path: String) async -> (plain: CGImage, sharpened: CGImage)? {
        guard isReady else { return nil }
        return await Self.run(path: path)
    }

    // MARK: - Work (off the main actor)

    private nonisolated static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private nonisolated static let context = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])

    private nonisolated static func configuration(width: Int, height: Int) -> VTSuperResolutionScalerConfiguration? {
        VTSuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: 4, inputType: .image, usePrecomputedFlow: false,
            qualityPrioritization: .normal, revision: VTSuperResolutionScalerConfiguration.defaultRevision)
    }

    /// `nonisolated async` runs on the global executor, off the main actor.
    private nonisolated static func run(path: String) async -> (plain: CGImage, sharpened: CGImage)? {
        guard let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let config = configuration(width: src.width, height: src.height),
              let input = pixelBuffer(src.width, src.height, config.sourcePixelBufferAttributes),
              let output = pixelBuffer(src.width * 4, src.height * 4, config.destinationPixelBufferAttributes)
        else { return nil }
        // The scaler takes half-float RGBA; feed it sRGB-encoded values (measurably better than linear light).
        context.render(CIImage(cgImage: src), to: input,
                       bounds: CGRect(x: 0, y: 0, width: src.width, height: src.height), colorSpace: sRGB)
        // One processor per image: a processor whose session has ended can't start another.
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: config)
            defer { processor.endSession() }
            guard let from = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: .zero),
                  let to = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: .zero),
                  let params = VTSuperResolutionScalerParameters(
                    sourceFrame: from, previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil,
                    submissionMode: .random, destinationFrame: to)
            else { return nil }
            _ = try await processor.process(parameters: params)
        } catch {
            print("[upscale] VTSuperResolutionScaler failed: \(error.localizedDescription)")
            return nil
        }
        let extent = CGRect(x: 0, y: 0, width: src.width * 4, height: src.height * 4)
        let result = CIImage(cvPixelBuffer: output, options: [.colorSpace: sRGB])
        guard let plain = context.createCGImage(result, from: extent, format: .RGBA8, colorSpace: sRGB) else { return nil }
        let sharpen = CIFilter(name: "CISharpenLuminance")!
        sharpen.setValue(CIImage(cgImage: plain), forKey: kCIInputImageKey)
        sharpen.setValue(maxSharpness, forKey: kCIInputSharpnessKey)
        sharpen.setValue(sharpenRadius, forKey: kCIInputRadiusKey)
        guard let sharp = sharpen.outputImage,
              let sharpened = context.createCGImage(sharp, from: extent, format: .RGBA8, colorSpace: sRGB)
        else { return nil }
        return (plain, sharpened)
    }

    private nonisolated static func pixelBuffer(_ width: Int, _ height: Int, _ attributes: [String: Any]) -> CVPixelBuffer? {
        let declared = attributes[kCVPixelBufferPixelFormatTypeKey as String]
        guard let format = (declared as? NSNumber) ?? (declared as? [NSNumber])?.first else { return nil }
        var attrs = attributes
        attrs[kCVPixelBufferWidthKey as String] = width
        attrs[kCVPixelBufferHeightKey as String] = height
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format.uint32Value, attrs as CFDictionary, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }
}
