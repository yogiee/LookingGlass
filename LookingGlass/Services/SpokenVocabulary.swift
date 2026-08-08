import AppKit
import Foundation
import NaturalLanguage

/// Mines the words Yogi actually uses out of his own chat history, so the
/// recogniser can be biased toward them.
///
/// Motivated by the first STT run: general accuracy was good at ~3ft on the
/// built-in mic, and the only consistent miss was **regional place names**.
/// Those are exactly what `AnalysisContext.contextualStrings` is for — it nudges
/// recognition toward a supplied list without retraining anything.
///
/// Three passes, because the obvious two weren't enough. Measured against the
/// real history (187 user messages) the casing heuristic alone returned ~40%
/// junk — `Alright`, `Extremely`, `Returns`, `Interesting` — ordinary words that
/// survived only because a small corpus rarely contains them mid-sentence. The
/// dictionary pass removed **18 of 18** such words while keeping **11 of 12**
/// genuine proper nouns.
enum SpokenVocabulary {

    /// Candidates split by how much we trust them.
    struct Harvest: Sendable {
        /// Positively identified by `NLTagger` — kept without further filtering,
        /// which is how in-dictionary proper nouns (`Riddler`, `Mumbai`) survive
        /// the dictionary pass below.
        var tagged: [String: Int] = [:]
        /// Inferred from capitalisation — needs the dictionary check.
        var cased: [String: Int] = [:]
    }

    // MARK: - Pass 1+2: counting and name tagging (pure, runs off the main actor)

    static func harvest(from corpus: [String]) -> Harvest {
        var capitalCount: [String: Int] = [:]
        var lowerCount: [String: Int] = [:]
        var canonical: [String: String] = [:]

        for text in corpus {
            for token in tokens(in: text) {
                guard token.count >= 3, let first = token.first else { continue }
                let key = token.lowercased()
                if first.isUppercase {
                    capitalCount[key, default: 0] += 1
                    if canonical[key] == nil { canonical[key] = token }
                } else {
                    lowerCount[key, default: 0] += 1
                }
            }
        }

        var result = Harvest()

        for (key, seen) in capitalCount {
            // Once is noise — a typo, a one-off.
            guard seen >= 2 else { continue }
            // A word that also shows up lowercase is usually a sentence opener
            // that happened to be capitalised.
            guard seen > (lowerCount[key] ?? 0) * 2 else { continue }
            guard !openers.contains(key) else { continue }
            result.cased[canonical[key] ?? key] = seen
        }

        // Worth more than frequency alone — a positive identification rather
        // than an inference from casing. Also keeps multi-word names together
        // ("New Delhi"), which the token scan would otherwise split.
        for name in taggedNames(in: corpus) {
            result.tagged[name, default: 0] += 3
        }

        return result
    }

    // MARK: - Pass 3: dictionary filter (AppKit, so main actor)

    /// Drop capitalisation-derived candidates that are ordinary English words.
    ///
    /// ⚠ The check must be run on the **lowercased** form. `NSSpellChecker`
    /// exempts capitalised words as presumed proper nouns and accepts
    /// everything — verified empirically, it returned "in dictionary" for
    /// `Ghatkopar` and `Extremely` alike. Lowercasing removes the exemption and
    /// the discrimination becomes near-perfect.
    @MainActor
    static func refine(_ harvest: Harvest, limit: Int = 150) -> [String] {
        var scored = harvest.tagged
        let checker = NSSpellChecker.shared

        for (word, count) in harvest.cased {
            // Acronyms earn an exemption: "API" and "JPEG" are dictionary words
            // and would be dropped, but they're exactly the kind of term worth
            // biasing toward. All-caps is a reliable enough signal.
            let isAcronym = word == word.uppercased()
            guard isAcronym || !isDictionaryWord(word, checker) else { continue }
            scored[word, default: 0] += count
        }

        return scored
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
    }

    @MainActor
    private static func isDictionaryWord(_ word: String, _ checker: NSSpellChecker) -> Bool {
        var count = 0
        // Language pinned rather than inherited: the result must not shift with
        // whatever the user last typed in another app.
        let misspelled = checker.checkSpelling(
            of: word.lowercased(), startingAt: 0, language: "en",
            wrap: false, inSpellDocumentWithTag: 0, wordCount: &count
        )
        return misspelled.location == NSNotFound
    }

    // MARK: - Learning from corrections

    /// What changed between a dictation and the version actually sent.
    ///
    /// Both halves matter, and the second is the one that was missing: words
    /// that *disappeared* are the recogniser's mistakes, and unless they're
    /// actively suppressed they stay in the corpus out-voting their own
    /// corrections. Measured on real history — "Nasik" appeared 3 times to
    /// "Nashik" once, so frequency alone would have entrenched the error.
    ///
    /// Both sides get the same filter: ordinary dictionary words are ignored,
    /// because rephrasing a sentence shouldn't teach the recogniser that
    /// "actually" is special, nor un-teach it a common word.
    @MainActor
    static func differences(from original: String, to corrected: String)
        -> (learned: [String], suppressed: [String]) {
        let before = tokens(in: original)
        let after = tokens(in: corrected)
        let beforeKeys = Set(before.map { $0.lowercased() })
        let afterKeys = Set(after.map { $0.lowercased() })
        let checker = NSSpellChecker.shared

        func notable(_ tokens: [String], missingFrom other: Set<String>) -> [String] {
            var out: [String] = []
            for token in tokens {
                guard token.count >= 3, !other.contains(token.lowercased()) else { continue }
                guard isNotable(token, checker), !out.contains(token) else { continue }
                out.append(token)
            }
            return out
        }

        return (notable(after, missingFrom: beforeKeys), notable(before, missingFrom: afterKeys))
    }

    /// Corrections Yogi states in plain chat rather than by editing — "Nasik =
    /// Nashik", "Igadpuri -> Igatpuri".
    ///
    /// This is how he actually corrected things unprompted, with the explicit
    /// expectation that it would stick ("just noting it down... so you get them
    /// right next time"). Nothing honoured that before, and it's the strongest
    /// signal available: a deliberate, unambiguous statement rather than a diff
    /// we have to interpret. One occurrence is enough — corrections get stated
    /// once, while the errors they fix repeat.
    @MainActor
    static func statedCorrections(in text: String) -> [(wrong: String, right: String)] {
        // ⚠ "should be" was tried and removed: it is ordinary English, not
        // correction syntax, so prose like "the filename should be fixed" parsed
        // as a correction and polluted both lists with common words. Only
        // explicit equivalence markers survive.
        let pattern = #"\b([\p{L}][\p{L}'’-]{2,})\s*(?:=|→|->|=>)\s*([\p{L}][\p{L}'’-]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        let checker = NSSpellChecker.shared
        var pairs: [(wrong: String, right: String)] = []

        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3 else { continue }
            let wrong = ns.substring(with: match.range(at: 1))
            let right = ns.substring(with: match.range(at: 2))
            // "x = x" is a definition, not a correction.
            guard wrong.lowercased() != right.lowercased() else { continue }
            // Only the *right* side is constrained — the term being learned must
            // be worth biasing toward. Testing the left side too was tried and
            // was wrong: Apple's dictionary contains "Nasik" (the misspelling)
            // but not "Nashik" (the correction), so it is no oracle for which
            // spelling is right, and requiring both rejected the exact pair this
            // exists to capture. Suppressing an ordinary word is harmless anyway
            // — the dictionary pass keeps those out of the vocabulary regardless.
            //
            // Stricter than the diff path deliberately: this is a regex over
            // arbitrary prose, so `=` also matches code. Allowing capitalised
            // dictionary words here let Python's "filename = None" through.
            // A diff earns the looser rule because Yogi retyped it himself.
            guard isDistinctive(right, checker) else { continue }
            pairs.append((wrong, right))
        }
        return pairs
    }

    /// Is this term worth carrying in the recogniser's vocabulary?
    ///
    /// The dictionary test alone loses place names that collide with ordinary
    /// English — "Pen" the town in Maharashtra was corrected by hand and then
    /// silently dropped, because `pen` is a word. Capitalisation recovers it:
    /// a word deliberately capitalised while correcting a transcript is a proper
    /// noun. Openers are still excluded so a "than → Then" grammar fix doesn't
    /// register as vocabulary.
    @MainActor
    private static func isNotable(_ word: String, _ checker: NSSpellChecker) -> Bool {
        if isDistinctive(word, checker) { return true }
        guard let first = word.first, first.isUppercase else { return false }
        return !openers.contains(word.lowercased())
    }

    /// The strict test: unmistakably not an ordinary English word. Used where
    /// the evidence is weaker than a hand-made correction.
    @MainActor
    private static func isDistinctive(_ word: String, _ checker: NSSpellChecker) -> Bool {
        word == word.uppercased() || !isDictionaryWord(word, checker)
    }

    // MARK: - Tokenising

    /// Letter runs only. Apostrophes and hyphens are dropped rather than kept:
    /// the recogniser wants the bare word, and "Yogi's" would otherwise compete
    /// with "Yogi" for frequency.
    private static func tokens(in text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init)
    }

    private static func taggedNames(in corpus: [String]) -> [String] {
        var found: [String] = []
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]

        for text in corpus where !text.isEmpty {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex,
                unit: .word,
                scheme: .nameType,
                options: [.omitPunctuation, .omitWhitespace, .joinNames]
            ) { tag, range in
                if let tag, wanted.contains(tag) {
                    let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.count >= 3 { found.append(name) }
                }
                return true
            }
        }
        return found
    }

    /// Cheap pre-filter so the dictionary pass isn't asked about words we
    /// already know are common sentence openers.
    private static let openers: Set<String> = [
        "the", "this", "that", "these", "those", "there", "then", "they", "their",
        "what", "when", "where", "which", "while", "who", "whom", "why", "how",
        "and", "but", "for", "nor", "yet", "not", "now", "just", "also", "still",
        "yes", "yeah", "okay", "sure", "well", "maybe", "please", "thanks",
        "can", "could", "did", "does", "done", "have", "has", "had", "will",
        "would", "should", "shall", "may", "might", "must", "need", "want",
        "let", "like", "make", "made", "see", "look", "give", "get", "got",
        "was", "were", "are", "been", "being", "its", "you", "your",
        "our", "his", "her", "hers", "them", "some", "any", "all", "one", "two",
        "here", "hey", "hello", "with", "without", "about", "after", "before",
        "from", "into", "over", "under", "than", "too", "very", "only", "even",
        "same", "such", "each", "both", "more", "most", "less", "least",
    ]
}
