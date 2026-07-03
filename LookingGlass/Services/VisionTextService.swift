import AppKit
import Vision

/// On-device text recognition (OCR) via Vision.framework — ANE-accelerated, free, zero-token.
///
/// The image-paste **OCR fast-path**: when a pasted image is really just text (a screenshot,
/// a document scan), we read it locally and drop the text into the input instead of round-tripping
/// the image through the `describe_image` VLM. Tier-1 utility in the same silent-fallback spirit as
/// `AppleIntelligenceService`: any failure returns `nil` and the caller falls back to the VLM path.
/// See `WORKSPACE/apple-native/01-imaging-and-vision.md` §A.
///
/// Uses the modern Swift Vision API (`RecognizeTextRequest`, async `perform(on:)`), current-best on
/// macOS 26 — struct-based, async-native, no completion handler.
enum VisionTextService {
    struct OCRResult {
        let text: String
        let charCount: Int
        let meanConfidence: Double
    }

    // Heuristic thresholds for "this image is really text" → take the OCR path. Conservative on
    // purpose: ambiguous images (a photo with an incidental sign) fall through to the VLM. Tunable.
    private static let minChars = 60
    private static let minConfidence = 0.5

    /// True when the result looks like a genuine text document (dense + confident), so the caller
    /// should inject the text and skip the VLM. Anything below the bar → let `describe_image` run.
    static func isTextDense(_ r: OCRResult) -> Bool {
        r.charCount >= minChars && r.meanConfidence >= minConfidence
    }

    /// Recognize text in a pasted image with `.accurate` recognition. Returns `nil` on any failure
    /// (no CGImage, a thrown error, or no recognized text).
    static func recognizeText(in image: NSImage) async -> OCRResult? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: cgImage) else { return nil }

        var lines: [String] = []
        var confidences: [Double] = []
        for observation in observations {
            guard let top = observation.topCandidates(1).first else { continue }
            lines.append(top.string)
            confidences.append(Double(top.confidence))
        }
        guard !lines.isEmpty else { return nil }

        let text = lines.joined(separator: "\n")
        let mean = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        return OCRResult(text: text, charCount: text.count, meanConfidence: mean)
    }
}
