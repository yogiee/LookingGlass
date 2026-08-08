import Accelerate
import AVFoundation
import Foundation

/// Turns raw microphone buffers into the band levels the composer's
/// spectrograph draws.
///
/// A real FFT rather than one overall level shaped into a curve: with a single
/// amplitude every bar moves together, which reads as decoration. Per-band
/// energy responds to the *character* of speech — vowels light the low bands,
/// sibilants the high ones — and that is what makes it feel like your voice
/// rather than an animation that happens while you talk.
///
/// Not an actor and not `@MainActor`: this runs inside the audio tap on a
/// realtime thread, where hopping isolation is exactly what you must not do.
/// It allocates once and mutates only its own buffers, and the tap is serial.
final class AudioLevelMeter: @unchecked Sendable {

    /// Bars the view draws. Mirrored on screen, so the visible count is double.
    ///
    /// 20 was too coarse: 40 bars across a ~900pt composer put each one at 12pt
    /// wide, which read as slabs rather than a spectrum.
    static let bandCount = 32

    private let fftSize = 1024
    private let halfSize = 512
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]

    /// Smoothed output, held between buffers so meter ballistics work.
    private var smoothed = [Float](repeating: 0, count: bandCount)

    /// Log-spaced bin ranges. Linear spacing would spend most of the display on
    /// frequencies speech barely uses — hearing is roughly logarithmic, so the
    /// bands are too.
    private let bandRanges: [Range<Int>]

    init?() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup

        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: halfSize)
        imaginary = [Float](repeating: 0, count: halfSize)
        magnitudes = [Float](repeating: 0, count: halfSize)

        // Stop well short of Nyquist. Spreading the bands to the top of the
        // spectrum left the highest three covering 8–24kHz, which speech barely
        // occupies — measured, an 8kHz tone peaked at band 16 of 20, so a
        // seventh of the display was permanently dark. 0.42 of Nyquist is about
        // 10kHz at 48k and scales with whatever rate the tap hands us.
        var ranges: [Range<Int>] = []
        let lowest = 2.0
        let highest = Double(halfSize) * 0.42
        for band in 0..<Self.bandCount {
            let t0 = Double(band) / Double(Self.bandCount)
            let t1 = Double(band + 1) / Double(Self.bandCount)
            let start = Int(lowest * pow(highest / lowest, t0))
            let end = max(start + 1, Int(lowest * pow(highest / lowest, t1)))
            ranges.append(start..<min(end, halfSize))
        }
        bandRanges = ranges
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Analyse one buffer. Returns nil when there isn't enough audio to fill a
    /// window, which happens on the first tap or a short final buffer.
    func bands(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0],
              buffer.frameLength >= AVAudioFrameCount(fftSize) else { return nil }

        vDSP_vmul(channel, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { packed in
                        vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { output in
                    vDSP_zvmags(&split, 1, output.baseAddress!, 1, vDSP_Length(halfSize))
                }
            }
        }

        for (index, range) in bandRanges.enumerated() {
            var sum: Float = 0
            for bin in range { sum += magnitudes[bin] }
            let mean = sum / Float(range.count)

            // Power to dB, then mapped across the range that actually carries
            // speech. Linear magnitude would leave the display almost flat:
            // quiet detail and loud peaks differ by orders of magnitude.
            // ⚠ vDSP returns UNNORMALISED magnitudes — scaled by the transform
            // size, so raw values run positive (~+49dB for a loud tone) and any
            // sane-looking dBFS window saturates every band to full height.
            // Dividing by halfSize² puts full scale at ~0dB, which is what the
            // floor and ceiling below are expressed in.
            let decibels = 10 * log10(mean / Self.fftScale + 1e-12)
            let normalized = min(max((decibels - Self.floorDB) / (Self.ceilingDB - Self.floorDB), 0), 1)

            // Meter ballistics: jump to a peak, fall away slowly. Symmetric
            // smoothing would either lag the attack or make the decay twitch.
            smoothed[index] = normalized > smoothed[index]
                ? normalized
                : smoothed[index] * Self.release + normalized * (1 - Self.release)
        }
        return smoothed
    }

    /// Let the display fall to rest without a jump — used when the mic pauses
    /// (Alice speaking) rather than stops.
    func decay() -> [Float] {
        for index in smoothed.indices { smoothed[index] *= Self.release }
        return smoothed
    }

    func reset() {
        for index in smoothed.indices { smoothed[index] = 0 }
    }

    /// 512² — the scaling `vDSP_fft_zrip` + `vDSP_zvmags` leave in the output.
    private static let fftScale: Float = 512 * 512

    /// Measured against synthesised speech-like signals once the scaling above
    /// was corrected: amplitude 0.2 (loud) lands near −13dB, 0.03 (conversational)
    /// near −30dB, 0.003 (barely audible) near −50dB. This window spans that
    /// range without pinning at the top or dying at the bottom.
    private static let floorDB: Float = -62
    private static let ceilingDB: Float = -10
    private static let release: Float = 0.78
}
