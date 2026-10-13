// KokoroG2P.swift — dictionary + morphology English G2P for Kokoro-82M.
//
// Vendored from coreai-kit (BSD-3-Clause, Copyright (c) 2026 Daisuke Majima — full notice in
// CoreAIGraph.swift), rewritten for LookingGlass on 2026-09-21: the morphology port and extra rules below
// are ours. Lexicons: misaki (Apache-2.0, hexgrad/misaki).
//
// Kokoro consumes misaki phonemes (hexgrad/misaki, Apache-2.0). The full misaki stack is a
// Python pipeline (spaCy POS pass, morphology rules, and an espeak-ng fallback for whatever
// is left); the established Swift port (MisakiSwift) carries an MLX dependency — too heavy a
// transitive dependency for the kit. This is misaki's dictionary + morphology core: the US
// gold/silver lexicons (~184k entries, grown with case variants exactly as misaki does),
// the -s / -ed / -ing stem rules from misaki's `Lexicon`, integer→words expansion, and
// letter-name spelling as the last resort.
//
// WHY THE MORPHOLOGY MATTERS: the lexicons are lemma-heavy. "locate", "dimension" and "what"
// are all present; "located", "dimensions" and "what's" are not. A dictionary-only G2P spells
// those out loud — "l-o-c-a-t-e-d" — which is what the 2026-09-19 listening test caught.
// Measured over 18.6k words of real assistant replies, the spelling fallback fires on 4.0% of
// tokens with the lexicons alone, 1.5% with misaki's stem rules, and 1.2% with the extra rules
// below. Excluding acronyms (where spelling is the CORRECT reading), that is 3.7% → 1.0%.
//
// Homographs take the lexicon's DEFAULT reading (there is no POS pass). Punctuation rides
// through: the Kokoro vocab maps it and the model uses it for prosody.

import Foundation

struct KokoroG2P: Sendable {
    private let lexicon: [String: String]
    private let gold: Set<String>
    /// Hand-written phonemes that win over everything. The residual the morphology rules cannot
    /// reach is proper nouns — product names and places — and a lookup table is the only thing
    /// that fixes those. Loaded from an optional `pronunciations.json` beside the lexicons.
    private let custom: [String: String]

    /// Symbols misaki reads as words rather than punctuation.
    private static let symbols = ["%": "percent", "&": "and", "+": "plus", "@": "at"]

    private static let primaryStress: Character = "ˈ"
    private static let secondaryStress: Character = "ˌ"
    private static let stresses = Set<Character>("ˌˈ")
    private static let vowels = Set<Character>("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
    /// US flapping environment: /t/ becomes a tap after these.
    private static let usTaus = Set<Character>("AIOWYiuæɑəɛɪɹʊʌ")

    /// Loads the misaki lexicons. Silver loads first so gold wins on shared keys.
    init(goldURL: URL, silverURL: URL, customURL: URL? = nil) throws {
        var lexicon: [String: String] = [:]
        var goldKeys = Set<String>()
        for (url, isGold) in [(silverURL, false), (goldURL, true)] {
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let entries = raw as? [String: Any] else { continue }
            var flat: [String: String] = [:]
            for (word, value) in entries {
                if let phonemes = value as? String {
                    flat[word] = phonemes
                } else if let variants = value as? [String: Any] {
                    // Homograph entry: {"DEFAULT": "...", "NOUN": ...}. Take DEFAULT, else the
                    // first non-null reading.
                    if let phonemes = variants["DEFAULT"] as? String {
                        flat[word] = phonemes
                    } else if let phonemes = variants.values.compactMap({ $0 as? String }).first {
                        flat[word] = phonemes
                    }
                }
            }
            flat = Self.growDictionary(flat)
            lexicon.merge(flat) { _, new in new }
            if isGold { goldKeys = Set(flat.keys) }
        }
        self.lexicon = lexicon
        self.gold = goldKeys
        if let customURL, let data = try? Data(contentsOf: customURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            custom = Dictionary(uniqueKeysWithValues: map.map { ($0.key.lowercased(), $0.value) })
        } else {
            custom = [:]
        }
    }

    /// misaki's `Lexicon.grow_dictionary`: a lowercase entry also answers for its capitalized
    /// form and vice versa. Original entries win.
    private static func growDictionary(_ d: [String: String]) -> [String: String] {
        var grown: [String: String] = [:]
        for (k, v) in d where k.count >= 2 {
            if k == k.lowercased() {
                let cap = capitalized(k)
                if k != cap { grown[cap] = v }
            } else if k == capitalized(k.lowercased()) {
                grown[k.lowercased()] = v
            }
        }
        return grown.merging(d) { _, original in original }
    }

    /// Python `str.capitalize()`: first character upper, the rest lower.
    private static func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst().lowercased()
    }

    /// Text → misaki phoneme string. Words become phoneme runs separated by spaces;
    /// punctuation stays in place (unknown characters are dropped later at vocab mapping).
    func phonemize(_ text: String) -> String {
        var out = ""
        var word = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            if !out.isEmpty, out.last != " " { out += " " }
            out += pronounce(word)
            word = ""
        }

        for ch in Self.normalize(text) {
            if ch.isLetter || ch.isNumber || ch == "'" {
                word.append(ch)
            } else if ch.isWhitespace {
                flushWord()
                if !out.isEmpty, out.last != " " { out += " " }
            } else {
                // Word-internal hyphen splits the word; other punctuation attaches to the
                // phoneme stream directly (".", ",", "!", "?", ";", ":", "…", "—" are vocab
                // tokens and drive prosody).
                flushWord()
                if ch != "-" { out.append(ch) }
                else if !out.isEmpty, out.last != " " { out += " " }
            }
        }
        flushWord()
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Punctuation normalisation done BEFORE tokenising.
    ///
    /// The ellipsis is the important one. "..." is three separate "." vocab tokens, which the
    /// model reads as three sentence ends and renders as the breathy "um um" / "huf huf" noise
    /// heard in the 09-19 test. "…" is a single vocab token (id 10) that Kokoro was trained on
    /// as a trailing-off pause, which is what the text actually means.
    static func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: "‘", with: "'")
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")
        // Longest first so "....." collapses to one ellipsis rather than an ellipsis + dot.
        for dots in ["......", ".....", "....", "..."] {
            s = s.replacingOccurrences(of: dots, with: "…")
        }
        s = s.replacingOccurrences(of: "–", with: "—")      // en dash → em dash (vocab token)
        s = s.replacingOccurrences(of: " - ", with: " — ")
        return s
    }

    // MARK: - Word resolution

    /// How a word reached its phonemes. Exposed for the probe's coverage report.
    enum Path: String, Sendable {
        case custom, lexicon, symbol, possessive, stemS = "-s", stemED = "-ed", stemING = "-ing"
        case stemIED = "-ied", comparative = "-er/-est", prefix, compound, unit, number, spelled
    }

    private func pronounce(_ word: String) -> String { resolve(word).0 }

    /// Phonemes plus the rule that produced them.
    func resolve(_ word: String) -> (String, Path) {
        if let hit = custom[word.lowercased()] { return (hit, .custom) }
        if let expansion = Self.symbols[word], let hit = lookup(expansion) { return (hit, .symbol) }
        if let hit = lookup(word) { return (hit, .lexicon) }

        // Possessive forms misaki resolves before the stem rules.
        if word.hasSuffix("s'"), let hit = lookup(String(word.dropLast(2)) + "'s") {
            return (hit, .possessive)
        }
        if word.hasSuffix("'"), let hit = lookup(String(word.dropLast())) {
            return (hit, .possessive)
        }

        // Mixed alphanumerics ("mp3", "iPhone17"): split into letter/digit runs.
        if word.contains(where: \.isNumber), word.contains(where: \.isLetter) {
            var runs: [String] = []
            var current = ""
            for ch in word {
                if let last = current.last, last.isNumber != ch.isNumber {
                    runs.append(current)
                    current = ""
                }
                current.append(ch)
            }
            if !current.isEmpty { runs.append(current) }
            return (runs.map(pronounce).joined(separator: " "), .number)
        }

        // Numbers: integers → words ("42" → "forty two"), anything longer than 12 digits
        // digit-by-digit.
        if word.allSatisfy(\.isNumber) { return (pronounceNumber(word), .number) }

        // misaki's morphology, in its order.
        if let hit = stemS(word) { return (hit, .stemS) }
        if let hit = stemED(word) { return (hit, .stemED) }
        if let hit = stemING(word) { return (hit, .stemING) }

        // Beyond misaki. Upstream leans on espeak-ng for everything past this point; we have no
        // such fallback, and spelling a word out loud is far worse than a slightly-off guess,
        // so these four rules buy back the largest remaining classes.
        if let hit = stemIED(word) { return (hit, .stemIED) }
        if let hit = comparative(word) { return (hit, .comparative) }
        if let hit = Self.units[word.lowercased()].flatMap({ phonemizeWords($0) }) { return (hit, .unit) }
        if let hit = compound(word) { return (hit, .compound) }
        if let hit = strippedPrefix(word) { return (hit, .prefix) }

        // Last resort: spell it. This is the RIGHT reading for acronyms (API, MCP, HTML) and
        // the wrong one for everything else — which in practice means proper nouns.
        return (spell(word), .spelled)
    }

    private func lookup(_ word: String) -> String? {
        lexicon[word] ?? lexicon[word.lowercased()]
    }

    /// misaki's `is_known`: in the lexicon, a single letter, or an all-caps acronym.
    private func isKnown(_ word: String) -> Bool {
        if lexicon[word] != nil || Self.symbols[word] != nil { return true }
        guard word.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        if word.count == 1 { return true }
        if word == word.uppercased(), gold.contains(word.lowercased()) { return true }
        let tail = String(word.dropFirst())
        return tail == tail.uppercased()
    }

    /// misaki's `apply_stress`. Only the cases the tagless pipeline can reach are exercised;
    /// the rest are kept so the port stays readable against the original.
    private static func applyStress(_ ps: String, _ stress: Double?) -> String {
        func restress(_ ps: String) -> String {
            let chars = Array(ps)
            var keyed: [(Double, Character)] = chars.enumerated().map { (Double($0.offset), $0.element) }
            for (i, ch) in chars.enumerated() where stresses.contains(ch) {
                guard let j = chars[i...].firstIndex(where: { vowels.contains($0) }) else { continue }
                keyed[i] = (Double(j) - 0.5, ch)
            }
            return String(keyed.sorted { $0.0 < $1.0 }.map(\.1))
        }
        guard let stress else { return ps }
        if stress < -1 {
            return ps.filter { !stresses.contains($0) }
        }
        if stress == -1 || ((stress == 0 || stress == -0.5) && ps.contains(primaryStress)) {
            return String(ps.compactMap { $0 == secondaryStress ? nil : ($0 == primaryStress ? secondaryStress : $0) })
        }
        if [0, 0.5, 1].contains(stress), !ps.contains(where: { stresses.contains($0) }) {
            guard ps.contains(where: { vowels.contains($0) }) else { return ps }
            return restress(String(secondaryStress) + ps)
        }
        if stress >= 1, !ps.contains(primaryStress), ps.contains(secondaryStress) {
            return String(ps.map { $0 == secondaryStress ? primaryStress : $0 })
        }
        if stress > 1, !ps.contains(where: { stresses.contains($0) }) {
            guard ps.contains(where: { vowels.contains($0) }) else { return ps }
            return restress(String(primaryStress) + ps)
        }
        return ps
    }

    // MARK: - Morphology (misaki parity)

    /// https://en.wiktionary.org/wiki/-s
    private func suffixS(_ stem: String) -> String? {
        guard let last = stem.last else { return nil }
        if "ptkfθ".contains(last) { return stem + "s" }
        if "szʃʒʧʤ".contains(last) { return stem + "ᵻz" }
        return stem + "z"
    }

    private func stemS(_ word: String) -> String? {
        var stem: String
        if word.count > 2, word.hasSuffix("s"), !word.hasSuffix("ss"),
           isKnown(String(word.dropLast())) {
            stem = String(word.dropLast())
        } else if (word.hasSuffix("'s") || (word.count > 4 && word.hasSuffix("es"))),
                  isKnown(String(word.dropLast(2))) {
            stem = String(word.dropLast(2))
        } else if word.count > 4, word.hasSuffix("ies"), isKnown(String(word.dropLast(3)) + "y") {
            stem = String(word.dropLast(3)) + "y"
        } else {
            return nil
        }
        return lookup(stem).flatMap(suffixS)
    }

    /// https://en.wiktionary.org/wiki/-ed
    private func suffixED(_ stem: String) -> String? {
        guard let last = stem.last else { return nil }
        if "pkfθʃsʧ".contains(last) { return stem + "t" }
        if last == "d" { return stem + "ᵻd" }
        if last != "t" { return stem + "d" }
        if stem.count < 2 { return stem + "ɪd" }
        let penult = stem[stem.index(stem.endIndex, offsetBy: -2)]
        if Self.usTaus.contains(penult) { return String(stem.dropLast()) + "ɾᵻd" }
        return stem + "ᵻd"
    }

    private func stemED(_ word: String) -> String? {
        var stem: String
        if word.hasSuffix("d"), !word.hasSuffix("dd"), isKnown(String(word.dropLast())) {
            stem = String(word.dropLast())
        } else if word.hasSuffix("ed"), !word.hasSuffix("eed"), isKnown(String(word.dropLast(2))) {
            stem = String(word.dropLast(2))
        } else {
            return nil
        }
        return lookup(stem).flatMap(suffixED)
    }

    /// https://en.wiktionary.org/wiki/-ing
    private func suffixING(_ stem: String) -> String? {
        guard let last = stem.last else { return nil }
        if stem.count > 1, last == "t",
           Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) {
            return String(stem.dropLast()) + "ɾɪŋ"
        }
        return stem + "ɪŋ"
    }

    private func stemING(_ word: String) -> String? {
        var stem: String
        if word.hasSuffix("ing"), isKnown(String(word.dropLast(3))) {
            stem = String(word.dropLast(3))
        } else if word.hasSuffix("ing"), isKnown(String(word.dropLast(3)) + "e") {
            stem = String(word.dropLast(3)) + "e"
        } else if Self.doubledConsonantING(word), isKnown(String(word.dropLast(4))) {
            stem = String(word.dropLast(4))
        } else {
            return nil
        }
        // misaki passes stress 0.5 here, which adds a secondary stress to an unstressed stem.
        return lookup(stem).map { Self.applyStress($0, 0.5) }.flatMap(suffixING)
    }

    /// misaki's `([bcdgklmnprstvxz])\1ing$|cking$` — "running", "trekking".
    private static func doubledConsonantING(_ word: String) -> Bool {
        guard word.hasSuffix("ing"), word.count >= 5 else { return false }
        let chars = Array(word)
        let i = chars.count - 4
        if word.hasSuffix("cking") { return true }
        return "bcdgklmnprstvxz".contains(chars[i]) && chars[i] == chars[i - 1]
    }

    // MARK: - Beyond misaki

    /// "verified" → verify + -ed. misaki has no -ied rule; espeak covers it upstream.
    private func stemIED(_ word: String) -> String? {
        guard word.count > 4, word.hasSuffix("ied"), isKnown(String(word.dropLast(3)) + "y")
        else { return nil }
        return lookup(String(word.dropLast(3)) + "y").flatMap(suffixED)
    }

    /// "tighter", "smartest".
    private func comparative(_ word: String) -> String? {
        for (suffix, tail) in [("est", "ᵻst"), ("er", "ɜɹ")] {
            guard word.hasSuffix(suffix), word.count > suffix.count + 2 else { continue }
            let base = String(word.dropLast(suffix.count))
            for candidate in [base, base + "e", String(base.dropLast())]
            where !candidate.isEmpty && isKnown(candidate) {
                if let ps = lookup(candidate) { return ps + tail }
            }
        }
        return nil
    }

    /// "jumpstart" → jump + start, "backticks" → back + ticks, "LookingGlass" → Looking + Glass.
    private func compound(_ word: String) -> String? {
        guard word.count >= 6, word.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        let chars = Array(word)
        for i in 3...(chars.count - 3) {
            let a = String(chars[..<i]), b = String(chars[i...])
            guard isKnown(a), isKnown(b), let pa = lookup(a) else { continue }
            // The tail may itself need morphology ("backticks" -> "ticks").
            let (pb, path) = resolve(b)
            guard path != .spelled else { continue }
            return pa + pb
        }
        return nil
    }

    private static let prefixes: [(String, String)] = [
        ("non", "nˌɑn"), ("over", "ˌOvɜɹ"), ("under", "ˌʌndɜɹ"), ("mis", "mˌɪs"),
        ("pre", "pɹi"), ("sub", "sˌʌb"), ("re", "ɹi"), ("un", "ʌn"),
    ]

    /// "mispredicted", "non-obvious" written solid, "resynthesize".
    private func strippedPrefix(_ word: String) -> String? {
        for (prefix, ps) in Self.prefixes where word.lowercased().hasPrefix(prefix) {
            guard word.count > prefix.count + 2 else { continue }
            let rest = String(word.dropFirst(prefix.count))
            let (tail, path) = resolve(rest)
            if path != .spelled { return ps + tail }
        }
        return nil
    }

    /// Unit abbreviations a research assistant actually emits. Spelling these is always wrong.
    private static let units: [String: String] = [
        "km": "kilometers", "kms": "kilometers", "cm": "centimeters", "mm": "millimeters",
        "kg": "kilograms", "ft": "feet", "mph": "miles per hour", "kmh": "kilometers per hour",
        "gb": "gigabytes", "mb": "megabytes", "kb": "kilobytes", "tb": "terabytes",
        "ms": "milliseconds", "hz": "hertz", "khz": "kilohertz", "ghz": "gigahertz",
    ]

    /// Resolves an expansion phrase through the full pipeline, so "kilometers" can reach the
    /// lexicon's "kilometer" via the -s rule. Fails if any word would be spelled out.
    private func phonemizeWords(_ phrase: String) -> String? {
        var parts: [String] = []
        for word in phrase.split(separator: " ") {
            let (ps, path) = resolve(String(word))
            guard path != .spelled else { return nil }
            parts.append(ps)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Spelling fallback

    /// misaki's `get_NNP`: letter names, all destressed, with the LAST letter carrying primary
    /// stress — "A-P-I" rather than a flat run.
    private func spell(_ word: String) -> String {
        let letters = word.filter(\.isLetter).compactMap { lookup(String($0).uppercased()) }
        guard !letters.isEmpty else { return "" }
        var joined = Self.applyStress(letters.joined(), 0)
        if let last = joined.lastIndex(of: Self.secondaryStress) {
            joined.replaceSubrange(last...last, with: String(Self.primaryStress))
        }
        return joined
    }

    // MARK: - Numbers

    private func pronounceNumber(_ digits: String) -> String {
        if digits.count <= 12, let value = Int(digits) {
            return spellOut(value).compactMap { lookup($0) }.joined(separator: " ")
        }
        return digits.compactMap { lookup(digitName($0)) }.joined(separator: " ")
    }

    private func digitName(_ ch: Character) -> String {
        ["0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five",
         "6": "six", "7": "seven", "8": "eight", "9": "nine"][String(ch), default: ""]
    }

    /// 1234 → ["one", "thousand", "two", "hundred", "thirty", "four"].
    private func spellOut(_ value: Int) -> [String] {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                    "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
                    "eighty", "ninety"]
        if value < 20 { return [ones[value]] }
        if value < 100 {
            let rest = value % 10
            return [tens[value / 10]] + (rest > 0 ? [ones[rest]] : [])
        }
        if value < 1_000 {
            let rest = value % 100
            return [ones[value / 100], "hundred"] + (rest > 0 ? spellOut(rest) : [])
        }
        for (limit, name) in [(1_000_000_000_000, "billion"), (1_000_000_000, "million"),
                              (1_000_000, "thousand")] where value >= limit / 1_000 {
            let scale = limit / 1_000
            let rest = value % scale
            return spellOut(value / scale) + [name] + (rest > 0 ? spellOut(rest) : [])
        }
        return [ones.indices.contains(value) ? ones[value] : ""]
    }
}
