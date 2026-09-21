// KokoroTTS.swift — Kokoro-82M (StyleTTS2 + iSTFTNet) text-to-speech on Core AI.
//
// Vendored from coreai-kit (BSD-3-Clause, Copyright (c) 2026 Daisuke Majima — full notice in
// CoreAIGraph.swift) and changed for LookingGlass: phoneme-count chunking, per-chunk silence trim with
// chosen gaps, weighted voice blends, an optional custom pronunciation table, and `.cpuOnly` placement
// (see `computeUnits` below). The LIGHT voice tier. Model weights and voices: Apache-2.0
// (hexgrad/Kokoro-82M, Core AI export mlboydaisuke/Kokoro-82M-CoreAI).
//
// Drives the three exported bundles (predictor / prosody / vocoder) through CoreAIKitVision's
// GraphModel on the CPU compute unit (the unrolled bi-LSTMs are ~8 ms on the Core AI CPU vs
// dispatch-bound on the GPU), with the host steps in Swift:
//
//   text -> (KokoroG2P) -> phoneme ids
//     predictor : ids, ref_s, attn_mask -> duration, d, t_en
//     host      : pred_dur = round(duration); one-hot alignment; frame mask
//     prosody   : d, t_en, aln, ref_s, frame_mask -> asr, F0, N
//     host      : har = STFT(SineGen(f0_upsamp(F0)))   — the hn-nsf source
//     vocoder   : asr, F0, N, har, ref_s, frame_mask -> audio
//     host      : trim to the real frames
//
// The host DSP (alignment + compute_har) mirrors conversion/export_kokoro.py exactly; the
// engine-vs-torch gate is spectral corr 0.999 (see the model card). The voice is data — a
// `ref_s` style row indexed by utterance length from a downloaded voice pack.

import Foundation

/// Kokoro-82M text-to-speech: non-autoregressive, 24 kHz, English-first.
final class KokoroTTS: Sendable {
    static let sampleRate = 24000

    /// CPU ONLY, not a CPU *preference*: the graph runner's author found that a preference over the
    /// heterogeneous allowed set can trigger a Core AI placement defect returning silently wrong numerics.
    /// The bi-LSTMs are fastest on the CPU anyway (~8 ms), so pinning it costs nothing.
    static let computeUnits: GraphModel.ComputeUnits = .cpuOnly

    static let TB = 128          // token bucket
    static let LB = 512          // frame bucket
    static let UP = 300          // f0 upsample (prod(upsample_rates)*hop)
    static let NFFT = 20, HOP = 5, FREQ = 11, HARM = 9
    static let SR: Float = 24000

    private let predictor: GraphModel
    private let prosody: GraphModel
    private let vocoder: GraphModel
    private let vocab: [String: Int]
    private let llW: [Float]                    // l_linear weight[9] + bias[1]
    private let voices: [String: [Float]]       // name -> [N*256] style pack
    private let g2p: KokoroG2P

    // STFT DFT basis (cos/sin * periodic Hann), built once.
    private let basisR: [Float]                 // [FREQ*NFFT]
    private let basisI: [Float]

    /// Loads the three graph bundles plus the host glue (vocab, l_linear, lexicons, voices).
    /// `glueDir` is the repo's `kokoro_host_glue/` subtree.
    init(
        predictorAt predictorURL: URL, prosodyAt prosodyURL: URL, vocoderAt vocoderURL: URL,
        glueDir: URL, customPronunciations: URL? = nil
    ) async throws {
        predictor = try await GraphModel(contentsOf: predictorURL, computeUnits: Self.computeUnits)
        prosody = try await GraphModel(contentsOf: prosodyURL, computeUnits: Self.computeUnits)
        vocoder = try await GraphModel(contentsOf: vocoderURL, computeUnits: Self.computeUnits)

        let vocabData = try Data(contentsOf: glueDir.appendingPathComponent("vocab.json"))
        vocab = try JSONDecoder().decode([String: Int].self, from: vocabData)
        llW = Self.readFloats(glueDir.appendingPathComponent("l_linear.bin"))
        let customURL = customPronunciations
            ?? glueDir.appendingPathComponent("pronunciations.json")
        g2p = try KokoroG2P(
            goldURL: glueDir.appendingPathComponent("us_gold.json"),
            silverURL: glueDir.appendingPathComponent("us_silver.json"),
            customURL: FileManager.default.fileExists(atPath: customURL.path) ? customURL : nil)

        let voicesDir = glueDir.appendingPathComponent("voices")
        var voices: [String: [Float]] = [:]
        for file in try FileManager.default.contentsOfDirectory(
            at: voicesDir, includingPropertiesForKeys: nil)
        where file.pathExtension == "bin" {
            voices[file.deletingPathExtension().lastPathComponent] = Self.readFloats(file)
        }
        self.voices = voices

        var basisR = [Float](), basisI = [Float]()
        basisR.reserveCapacity(Self.FREQ * Self.NFFT)
        basisI.reserveCapacity(Self.FREQ * Self.NFFT)
        for k in 0..<Self.FREQ {
            for n in 0..<Self.NFFT {
                let hann = 0.5 - 0.5 * cos(2 * Float.pi * Float(n) / Float(Self.NFFT))
                let a = 2 * Float.pi * Float(k) * Float(n) / Float(Self.NFFT)
                basisR.append(cos(a) * hann)
                basisI.append(-sin(a) * hann)
            }
        }
        self.basisR = basisR
        self.basisI = basisI
    }

    /// Delivery controls applied on top of the model.
    ///
    /// Kokoro's own pacing is slow and gappy: the 09-19 listening test measured 29% of the
    /// rendered audio as silence, with ~1 s rests at sentence ends. `speed` scales the
    /// predicted phoneme durations (the reference implementation's knob); the gap settings
    /// replace the model's trailing rest with one we choose, which is the difference between
    /// "unhurried" and "waiting for something".
    struct Options: Sendable {
        /// Duration divisor. >1 speaks faster. 1.15–1.25 lands near AVSpeech's default rate.
        var speed: Float = 1.0
        /// Silence inserted after a chunk that ended a sentence.
        var sentenceGap: Double = 0.30
        /// Silence inserted after a chunk that ended mid-sentence (clause split).
        var clauseGap: Double = 0.16
        /// Trim the model's own leading/trailing near-silence before applying the gaps.
        var trimSilence: Bool = true

        init(speed: Float = 1.0, sentenceGap: Double = 0.30,
                    clauseGap: Double = 0.16, trimSilence: Bool = true) {
            self.speed = speed
            self.sentenceGap = sentenceGap
            self.clauseGap = clauseGap
            self.trimSilence = trimSilence
        }
    }

    /// The downloaded voice packs, e.g. `["af_heart", "af_bella", …]`.
    var availableVoices: [String] { voices.keys.sorted() }

    /// The misaki phoneme string the model will actually be fed. Diagnostic.
    func phonemes(for text: String) -> String { g2p.phonemize(text) }

    /// Per-word `(phonemes, rule)` for a list of words, where `rule` is `"spelled"` when the
    /// G2P gave up and read the letters out. Diagnostic: it is the one failure the 09-19
    /// listening test could hear.
    func pronunciations(of words: [String]) -> [(word: String, phonemes: String, rule: String)] {
        words.map { let (p, path) = g2p.resolve($0); return ($0, p, path.rawValue) }
    }

    /// How the text will be cut up before synthesis. Diagnostic.
    func chunks(of text: String) -> [String] { chunk(text).map(\.text) }

    /// Free text -> 24 kHz audio. Splits into chunks that fit the token bucket, synthesizes
    /// each, and concatenates with the configured gaps. G2P is on-device.
    ///
    /// `voice` is a pack name, or a blend: `"bf_alice*0.6+bf_emma*0.4"`. A blend averages the
    /// style rows themselves, which is what a Kokoro "voice" is — there is no separate speaker
    /// encoder to fight, so the average is a coherent speaker rather than a crossfade.
    func synthesize(
        _ text: String, voice: String = "af_heart", options: Options = Options()
    ) async throws -> [Float] {
        var audio: [Float] = []
        try await synthesizeByChunk(text, voice: voice, options: options) { audio += $0 }
        return audio
    }

    /// Streaming synthesis: `onChunk` receives one chunk's audio as it synthesizes. The
    /// concatenation equals `synthesize(_:voice:options:)`.
    @discardableResult
    func synthesizeStreaming(
        _ text: String, voice: String = "af_heart", options: Options = Options(),
        onChunk: @Sendable ([Float]) async -> Void
    ) async throws -> [Float] {
        var audio: [Float] = []
        try await synthesizeByChunk(text, voice: voice, options: options) { chunk in
            audio += chunk
            await onChunk(chunk)
        }
        return audio
    }

    private func synthesizeByChunk(
        _ text: String, voice: String, options: Options, emit: ([Float]) async -> Void
    ) async throws {
        let chunks = chunk(text)
        for (index, piece) in chunks.enumerated() {
            // Stop means stop: without this a cancelled reading keeps synthesising the rest of a long
            // report on the CPU, audio nobody will hear.
            try Task.checkCancellation()
            let ids = ids(forText: piece.text)
            guard ids.count > 2 else { continue }                        // skip empty
            guard ids.count <= Self.TB else { throw KokoroError.tooLong(ids.count) }
            var audio = try await synthesize(ids: ids, voice: voice, speed: options.speed)
            if options.trimSilence { audio = Self.trimmingSilence(audio) }
            let isLast = index == chunks.count - 1
            let gap = isLast ? 0 : (piece.endsSentence ? options.sentenceGap : options.clauseGap)
            audio += [Float](repeating: 0, count: Int(gap * Double(Self.sampleRate)))
            await emit(audio)
        }
    }

    /// Strips the model's own leading/trailing rest so the gap we insert is the only gap.
    /// The threshold is deliberately low: this removes digital-quiet tails, not breaths.
    static func trimmingSilence(_ audio: [Float], threshold: Float = 0.004) -> [Float] {
        guard let first = audio.firstIndex(where: { abs($0) > threshold }),
              let last = audio.lastIndex(where: { abs($0) > threshold })
        else { return [] }
        // Keep a 20 ms cushion so consonant onsets and releases survive.
        let pad = sampleRate / 50
        let lo = max(0, first - pad), hi = min(audio.count, last + pad)
        return Array(audio[lo..<hi])
    }

    // MARK: - Chunking

    struct Chunk: Sendable {
        let text: String
        /// True when this chunk ended at a sentence terminator rather than a clause break.
        let endsSentence: Bool
    }

    /// Splits text into pieces that fit the 128-token bucket, preferring sentence ends, then
    /// clause breaks (— ; : ,), then word boundaries. Sized against the real phoneme count
    /// rather than characters, which is what the bucket actually limits.
    func chunk(_ text: String, budget: Int = KokoroTTS.TB - 2) -> [Chunk] {
        var out: [Chunk] = []
        for sentence in Self.splitSentences(KokoroG2P.normalize(text)) {
            let terminal = sentence.last.map { ".!?…".contains($0) } ?? false
            if phonemeCount(sentence) <= budget {
                out.append(Chunk(text: sentence, endsSentence: terminal))
                continue
            }
            let parts = split(sentence, budget: budget)
            for (i, part) in parts.enumerated() {
                out.append(Chunk(text: part, endsSentence: terminal && i == parts.count - 1))
            }
        }
        return out.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Greedily packs clause fragments up to the budget; a fragment still too long is packed
    /// word by word.
    private func split(_ sentence: String, budget: Int) -> [String] {
        var fragments: [String] = []
        var current = ""
        for ch in sentence {
            current.append(ch)
            if ",;:—".contains(ch) {
                fragments.append(current)
                current = ""
            }
        }
        if !current.isEmpty { fragments.append(current) }

        var out: [String] = []
        var buffer = ""
        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
            buffer = ""
        }
        for fragment in fragments {
            if phonemeCount(fragment) > budget {
                flush()
                for word in fragment.split(separator: " ", omittingEmptySubsequences: true) {
                    if phonemeCount(buffer + " " + word) > budget { flush() }
                    buffer += (buffer.isEmpty ? "" : " ") + word
                }
                continue
            }
            if phonemeCount(buffer + fragment) > budget { flush() }
            buffer += fragment
        }
        flush()
        return out
    }

    func phonemeCount(_ text: String) -> Int { ids(forText: text).count }

    /// Phonemes for a chunk -> Kokoro token ids (incl. the [0, …, 0] bounds).
    func ids(forText text: String) -> [Int] {
        let phonemes = g2p.phonemize(text)
        return [0] + phonemes.compactMap { vocab[String($0)] } + [0]
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            // A period between digits is a decimal point, not a sentence end.
            if ch == ".", i + 1 < chars.count, chars[i + 1].isNumber { continue }
            if ch == "." || ch == "!" || ch == "?" {
                let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.isEmpty ? [text] : out
    }

    /// Resolves a voice spec to its style row for an utterance of `length` tokens.
    /// A spec is a pack name, or a weighted blend: `"bf_alice*0.6+bf_emma*0.4"`.
    func refS(for spec: String, length T: Int) throws -> [Float] {
        var terms: [(String, Float)] = []
        for term in spec.split(separator: "+") {
            let parts = term.split(separator: "*", maxSplits: 1)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let weight = parts.count > 1 ? Float(parts[1].trimmingCharacters(in: .whitespaces)) ?? 1 : 1
            terms.append((name, weight))
        }
        let total = terms.reduce(0) { $0 + $1.1 }
        guard total > 0 else { throw KokoroError.noVoice(spec) }

        var row = [Float](repeating: 0, count: 256)
        for (name, weight) in terms {
            guard let pack = voices[name] else { throw KokoroError.noVoice(name) }
            let slice = pack[(T - 1) * 256 ..< T * 256]          // ref_s = pack[len-1]
            let w = weight / total
            for (i, v) in slice.enumerated() { row[i] += v * w }
        }
        return row
    }

    /// Synthesize from already-tokenized phoneme ids (incl. the [0, …, 0] bounds).
    func synthesize(ids rawIds: [Int], voice: String, speed: Float = 1) async throws -> [Float] {
        let T = rawIds.count
        guard T <= Self.TB else { throw KokoroError.tooLong(T) }
        let refS = try refS(for: voice, length: T)

        // pad ids to the token bucket
        let ids = rawIds.map { Int32($0) } + [Int32](repeating: 0, count: Self.TB - T)
        let attn = [Float](repeating: 1, count: T) + [Float](repeating: 0, count: Self.TB - T)

        let o1 = try await predictor.run([
            "input_ids": .int32(ids, shape: [1, Self.TB]),
            "ref_s": .float32(refS, shape: [1, 256]),
            "attn_mask": .float32(attn, shape: [1, Self.TB]),
        ])
        let duration = o1["duration"]!.floats()

        let (aln, frameMask, L) = buildAlignment(duration: Array(duration[0..<T]), T: T, speed: speed)

        let o2 = try await prosody.run([
            "d": o1["d"]!, "t_en": o1["t_en"]!,
            "aln": .float32(aln, shape: [1, Self.TB, Self.LB]),
            "ref_s": .float32(refS, shape: [1, 256]),
            "frame_mask": .float32(frameMask, shape: [1, Self.LB]),
        ])
        let F0 = o2["F0"]!.floats()                              // [2*LB]
        let (har, frames) = computeHar(F0: F0)

        let o3 = try await vocoder.run([
            "asr": o2["asr"]!, "F0": o2["F0"]!, "N": o2["N"]!,
            "har": .float32(har, shape: [1, 2 * Self.FREQ, frames]),
            "ref_s": .float32(refS, shape: [1, 256]),
            "frame_mask": .float32(frameMask, shape: [1, Self.LB]),
        ])
        let audio = o3["audio"]!.floats()
        return Array(audio[0 ..< min(L * 600, audio.count)])     // trim to real frames
    }

    // host step 1: duration -> one-hot alignment + frame mask (bucketed)
    private func buildAlignment(duration: [Float], T: Int, speed: Float) -> ([Float], [Float], Int) {
        var predDur = [Int](repeating: 1, count: T)
        var L = 0
        for i in 0..<T {
            predDur[i] = max(1, Int((duration[i] / max(0.1, speed)).rounded()))
            L += predDur[i]
        }
        var aln = [Float](repeating: 0, count: Self.TB * Self.LB)
        var frame = 0
        for i in 0..<T {
            for _ in 0..<predDur[i] where frame < Self.LB {
                aln[i * Self.LB + frame] = 1                     // aln[token i, frame]
                frame += 1
            }
        }
        var frameMask = [Float](repeating: 0, count: Self.LB)
        for f in 0..<min(L, Self.LB) { frameMask[f] = 1 }
        return (aln, frameMask, L)
    }

    // host step 2: hn-nsf source -> STFT (mag, phase). Mirrors compute_har.
    private func computeHar(F0: [Float]) -> ([Float], Int) {
        let twoL = F0.count                 // 2*LB
        let bigL = twoL * Self.UP
        // f0_upsamp: repeat each value UP times (nearest)
        // SineGen per harmonic: rad -> downsample(1/UP) -> cumsum -> upsample(UP) -> sin
        var harSource = [Float](repeating: 0, count: bigL)
        var radDS = [Float](repeating: 0, count: twoL)
        var phase = [Float](repeating: 0, count: twoL)
        for h in 1...Self.HARM {
            // rad on the bigL grid is f0_up*h/SR; its 1/UP downsample averages each
            // block of UP constant samples -> ~= F0[j]*h/SR (linear interp of a step).
            for j in 0..<twoL { radDS[j] = F0[j] * Float(h) / Self.SR }
            // cumsum * 2pi
            var acc: Float = 0
            for j in 0..<twoL { acc += radDS[j]; phase[j] = acc * 2 * Float.pi }
            // upsample (linear, align_corners=false) of phase*UP back to bigL, then sin
            let weight = llW[h - 1]
            for i in 0..<bigL {
                let s = max(0, min(Float(twoL - 1), (Float(i) + 0.5) * Float(twoL) / Float(bigL) - 0.5))
                let lo = Int(s.rounded(.down)); let hi = min(lo + 1, twoL - 1); let fr = s - Float(lo)
                let ph = (phase[lo] * (1 - fr) + phase[hi] * fr) * Float(Self.UP)
                let f0u = F0[min(twoL - 1, i / Self.UP)]                       // f0_upsamp value
                let uv: Float = f0u > 10 ? 1 : 0
                harSource[i] += sin(ph) * 0.1 * uv * weight                    // sine_amp * uv * l_linear[h-1]
            }
        }
        // l_linear bias + tanh
        let bias = llW[Self.HARM]
        for i in 0..<bigL { harSource[i] = tanh(harSource[i] + bias) }

        // STFT: replicate pad n_fft/2, stride HOP, DFT basis -> mag, phase
        let pad = Self.NFFT / 2
        let total = bigL + 2 * pad
        let frames = (total - Self.NFFT) / Self.HOP + 1
        var har = [Float](repeating: 0, count: 2 * Self.FREQ * frames)
        func sample(_ idx: Int) -> Float {                     // replicate (edge) pad
            if idx < pad { return harSource[0] }
            if idx >= pad + bigL { return harSource[bigL - 1] }
            return harSource[idx - pad]
        }
        for fi in 0..<frames {
            let base = fi * Self.HOP
            for k in 0..<Self.FREQ {
                var re: Float = 0, im: Float = 0
                let bk = k * Self.NFFT
                for n in 0..<Self.NFFT {
                    let v = sample(base + n)
                    re += basisR[bk + n] * v
                    im += basisI[bk + n] * v
                }
                let mag = (re * re + im * im + 1e-14).squareRoot()
                har[k * frames + fi] = mag
                har[(Self.FREQ + k) * frames + fi] = atan2(im, re)
            }
        }
        return (har, frames)
    }

    private static func readFloats(_ url: URL) -> [Float] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Kokoro synthesis errors.
    enum KokoroError: Error {
        /// One sentence phonemized past the 128-token bucket — split the text shorter.
        case tooLong(Int)
        /// The requested voice pack is not among the downloaded `voices/*.bin`.
        case noVoice(String)
    }
}
