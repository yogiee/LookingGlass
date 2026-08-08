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
