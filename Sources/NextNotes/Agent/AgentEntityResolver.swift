import Foundation

/// Matching what the user *said* against what is actually on this Mac.
///
/// Speech recognition does not produce the name of a folder; it produces a plausible English
/// phrase that sounds like it. On 2026-09-20 the user asked for the "Next Notes" folder
/// twice and the recogniser wrote "next project" and then "next note". The agent took both
/// at face value — "I cannot open the 'next project' folder", then "I see. You're referring
/// to the four days labeled 'next note'" — and asked for an exact name, which is the one
/// thing a person speaking cannot supply.
///
/// So the exact name is never required. The index is searched by each word in turn, and the
/// hits are ranked by how close the *sound* of their name is to the phrase. "next note"
/// scores 0.83 against "Next Notes"; "next project" scores 0.50, which is still the best
/// thing on the Mac and worth offering by name rather than refusing.
enum AgentEntityResolver {
    struct Match: Equatable, Sendable {
        var hit: FileHit
        var score: Double
    }

    /// Below this nothing is offered: a wrong folder named confidently is worse than "I
    /// looked and did not find it".
    static let offerThreshold = 0.42
    /// At or above this a single match is acted on without asking which one.
    static let confidentThreshold = 0.72

    // MARK: - Resolving a spoken name against the index

    /// Ranked candidates for a spoken name, best first.
    ///
    /// - Parameter wantsFolder: folders are preferred, not required — "open my next notes"
    ///   should still find the folder when the words never said "folder".
    @MainActor
    static func resolve(
        spoken: String,
        wantsFolder: Bool,
        files: any FileRetrieving = LiveFileRetrieval(),
        limit: Int = 3
    ) -> [Match] {
        guard files.isAvailable else { return [] }
        let corrected = dictionaryCorrected(spoken)
        let tokens = Self.tokens(corrected)
        guard !tokens.isEmpty else { return [] }

        var seen = Set<String>()
        var candidates: [FileHit] = []
        // The whole phrase first, then each word: an index search is a prefix match on
        // names, so "next project" finds nothing while "next" finds the folder.
        for query in [corrected] + tokens.sorted(by: { $0.count > $1.count }) {
            guard let hits = try? files.find(query: query, category: nil, folder: nil,
                                             modifiedAfter: nil, limit: 40) else { continue }
            for hit in hits where seen.insert(hit.path).inserted {
                candidates.append(hit)
            }
            if candidates.count > 240 { break }
        }

        return candidates
            .map { Match(hit: $0, score: score($0, tokens: tokens, wantsFolder: wantsFolder)) }
            .filter { $0.score >= offerThreshold }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                // A shallower path is the one a person means by a bare name.
                if $0.hit.depth != $1.hit.depth { return $0.hit.depth < $1.hit.depth }
                return $0.hit.path < $1.hit.path
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The user's own dictionary, applied to the agent's ear as well as to dictation.
    ///
    /// `dictionary.txt` already maps "Quentin 2.5" to "Gemma 4" and "Sergeant William Kedu"
    /// to "Serge William Kadjo" for inserted text. The Agent heard the uncorrected words.
    @MainActor
    static func dictionaryCorrected(_ text: String) -> String {
        let corrector = DictionaryStore.shared.corrector
        guard !corrector.isEmpty else { return text }
        return corrector.apply(to: text).text
    }

    static func score(_ hit: FileHit, tokens: [String], wantsFolder: Bool) -> Double {
        let candidate = Self.tokens(hit.name)
        guard !candidate.isEmpty else { return 0 }
        var total = 0.0
        var anchored = false
        for token in tokens {
            let best = candidate.map { similarity(token, $0) }.max() ?? 0
            if best >= 0.8 { anchored = true }
            total += best
        }
        guard anchored else { return 0 }
        var score = total / Double(tokens.count)
        if wantsFolder { score += hit.isDirectory ? 0.08 : -0.12 }
        return min(1, max(0, score))
    }

    // MARK: - Sound-alike comparison

    /// Two spoken words, compared as sound rather than spelling.
    ///
    /// Three measures, the largest wins, because each catches a different way the
    /// recogniser goes wrong:
    ///
    /// - **Prefix.** "note" against "Notes" — a dropped inflection, which is what a
    ///   microphone does to a final consonant. Trigram overlap alone scores this 0.57, low
    ///   enough that the right folder would only ever have been offered, never opened.
    /// - **Trigrams.** Letters in the wrong order, or one extra syllable.
    /// - **Consonant skeleton.** A vowel the recogniser invented: "gemma"/"gemen".
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        let prefixed = shorter.count >= 3 && longer.hasPrefix(shorter) ? 0.82 : 0
        let trigrams = jaccard(Self.trigrams(lhs), Self.trigrams(rhs))
        let left = skeleton(lhs)
        let right = skeleton(rhs)
        let skeletal = !left.isEmpty && left == right ? 0.78 : 0
        return max(prefixed, max(trigrams, skeletal))
    }

    static func tokens(_ text: String) -> [String] {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let letters = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return letters
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
            .filter { $0.count > 1 }
    }

    private static func trigrams(_ word: String) -> Set<String> {
        let padded = Array("  " + word + " ")
        guard padded.count >= 3 else { return [String(padded)] }
        return Set((0...(padded.count - 3)).map { String(padded[$0..<($0 + 3)]) })
    }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union)
    }

    /// Consonants only, doubles collapsed: what survives a vowel the recogniser invented.
    private static func skeleton(_ word: String) -> String {
        var result = ""
        for character in word.lowercased() where character.isLetter {
            guard !"aeiouy".contains(character) else { continue }
            if result.last != character { result.append(character) }
        }
        return result
    }

    // MARK: - Corrections and low-confidence turns

    /// The phrasings a person uses when the assistant misheard them.
    private static let correctionOpeners = [
        "no it's", "no its", "no the", "no i said", "no i meant", "not", "i said",
        "i meant", "it's called", "its called", "it is called", "the folder is called",
        "the file is called", "actually", "i mean",
    ]

    /// The name a correction is pointing at, or nil when the turn is not a correction.
    ///
    /// "no, the folder is called Next Notes" is not a new request and must not be answered
    /// as one; it re-aims the request already running.
    static func correctionTarget(in utterance: String) -> String? {
        let text = AgentDirectIntent.normalize(utterance)
        guard correctionOpeners.contains(where: { text == $0 || text.hasPrefix($0 + " ") })
        else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let name = AgentDirectIntent.locateQuery(words)
        return name.isEmpty ? nil : name
    }

    /// The name in a turn that exists to supply one — "…called X", "…named X".
    ///
    /// This is the form a correction survives in after the recogniser has had it. The user
    /// said "no, the folder is called Next Notes" and the transcript reads "note the four
    /// days called next note": the opener is gone, "Notes" has lost its s, but "called
    /// <name>" is intact, and the turn before it had just asked for a name. That is enough
    /// to know this turn is an answer and not a new subject.
    static func namingTarget(in utterance: String) -> String? {
        let text = AgentDirectIntent.normalize(utterance)
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        // A correction is short and is not itself a request. "Create a document called Q4
        // plan" contains the same "called X" and is an instruction, not an answer.
        guard words.count <= 9, AgentDirectIntent.parse(utterance) == nil,
              !words.contains(where: namingVerbs.contains) else { return nil }
        guard words.contains("called") || words.contains("named") else { return nil }
        guard let marker = ["called", "named"].compactMap({ words.lastIndex(of: $0) }).max(),
              marker + 1 < words.count else { return nil }
        let name = AgentDirectIntent.locateQuery(Array(words[(marker + 1)...]))
        return name.isEmpty ? nil : name
    }

    /// Verbs that make "…called X" an instruction rather than an answer.
    private static let namingVerbs: Set<String> = [
        "create", "make", "write", "draft", "send", "add", "remind", "schedule", "save",
        "start", "set", "title", "email", "delete", "remove", "rename",
    ]

    /// Whether the previous reply was a request for a name. A turn that supplies one only
    /// counts as an answer when something asked.
    static func askedForAName(_ reply: String) -> Bool {
        let text = reply.lowercased()
        return ["exact name", "which one", "what is it called", "tell me the name",
                "found nothing", "don't know which", "do not know which",
                "name of the project", "name of the file"].contains { text.contains($0) }
    }

    /// Whether the latest turn is too far from the conversation to answer literally.
    ///
    /// The test is not confidence — the recogniser reports none here — but agreement: a
    /// short turn that shares no word with what is being discussed, yet *sounds* like
    /// something in it, is a misrecognition of that thing rather than a new subject.
    /// "note the four days called next note" against a conversation about the Next Notes
    /// folder is the shape this catches.
    static func soundsLike(_ utterance: String, knownEntities: [String]) -> String? {
        let spoken = tokens(utterance)
        guard !spoken.isEmpty, spoken.count <= 8 else { return nil }
        var best: (name: String, score: Double)?
        for entity in knownEntities {
            let candidate = tokens(entity)
            guard !candidate.isEmpty else { continue }
            var total = 0.0
            var exact = 0
            for token in spoken {
                let match = candidate.map { similarity(token, $0) }.max() ?? 0
                if match == 1 { exact += 1 }
                total += match
            }
            let score = total / Double(spoken.count)
            // Every word already matching means the user simply named it; nothing to fix.
            guard exact < spoken.count, score >= 0.55 else { continue }
            if score > (best?.score ?? 0) { best = (entity, score) }
        }
        return best?.name
    }
}
