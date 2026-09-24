import Foundation
import NextNotesDictionary

/// One correction the user's own edit implies: they heard X written, and made it Y.
struct LearnedCorrection: Identifiable, Hashable, Sendable {
    let hear: String
    let write: String

    var id: String { "\(hear.lowercased())→\(write.lowercased())" }

    var entry: DictionaryEntry { .correction(hear: hear, write: write) }
}

/// Turns "what we wrote" and "what you changed it to" into dictionary candidates.
///
/// This is the whole learning pipeline, and it is deliberately a pure function of two
/// strings. The alternative — watching the text field in the app the dictation landed in —
/// was measured and abandoned: `--selftest-axreadback` reports zero readable text elements
/// in Cursor, Chrome, Terminal, Messages and every other Electron app, which is to say in
/// almost everywhere anyone dictates. Reading a run back out of our own history works
/// everywhere, needs no accessibility tree, and watches nothing.
///
/// The hard part is not the diff. It is refusing most of what the diff finds: a person
/// editing a transcript is usually rewriting it, and a dictionary that learns "I think" →
/// "we should" is worse than one that learns nothing, because it will then apply that to
/// every future transcript.
enum CorrectionLearner {

    /// The most candidates one edit may produce.
    ///
    /// A wholesale rewrite produces dozens of "substitutions" that are really just a
    /// different sentence. Past a handful, the honest reading is that this was not a
    /// correction at all, so the edit is treated as one and nothing is proposed.
    private static let maxCandidates = 5

    /// How alike a pair must be to read as a mis-hearing rather than a rewrite.
    ///
    /// "Kajo" → "Kadjo" is 0.8. "cloud code" → "Claude Code" is 0.73. "I think" → "we
    /// should" is 0.15, and is exactly what this exists to reject. The threshold is low
    /// enough to keep real homophones ("their" → "there" is 0.6) and high enough that
    /// unrelated words do not survive.
    private static let minimumSimilarity = 0.45

    /// Words too common to be worth a dictionary rule on their own.
    ///
    /// Not a general stop-word list: these are here because a rule on any of them fires on
    /// nearly every future transcript, so the cost of a wrong one is unbounded.
    private static let tooCommon: Set<String> = [
        "a", "an", "and", "as", "at", "be", "but", "by", "do", "for", "from", "have", "i",
        "if", "in", "is", "it", "its", "me", "my", "no", "not", "of", "on", "or", "so",
        "that", "the", "then", "there", "they", "this", "to", "up", "was", "we", "what",
        "when", "will", "with", "you", "your",
    ]

    static func candidates(from original: String, to edited: String) -> [LearnedCorrection] {
        let before = tokenize(original)
        let after = tokenize(edited)
        guard !before.isEmpty, !after.isEmpty, before != after else { return [] }

        var found: [LearnedCorrection] = []
        for (removed, added) in replacements(from: before, to: after) {
            // One to three words a side. A longer span is a rephrasing, and a dictionary
            // rule spanning a clause would only ever fire on that exact clause again.
            guard (1...3).contains(removed.count), (1...3).contains(added.count) else { continue }

            let hear = removed.joined(separator: " ").trimmed()
            let write = added.joined(separator: " ").trimmed()
            guard !hear.isEmpty, !write.isEmpty, hear != write else { continue }

            // A single very common word is never worth a rule, however similar the pair.
            if removed.count == 1, tooCommon.contains(hear.lowercased()) { continue }

            guard accepts(removed: removed, added: added) else { continue }

            let candidate = LearnedCorrection(hear: hear, write: write)
            if !found.contains(where: { $0.id == candidate.id }) { found.append(candidate) }
        }

        return found.count > maxCandidates ? [] : found
    }

    // MARK: - D-10: learner safety

    /// How alike one changed token pair must be on its own.
    ///
    /// Higher than `minimumSimilarity` on purpose: a whole span gets partial credit
    /// for its unchanged words, while a single pair stands alone.
    private static let tokenSimilarity = 0.5

    /// Whether one replacement block reads as a mis-hearing rather than a rewrite.
    ///
    /// A whole-span check cannot tell "cloud code → Claude Code" from "of a product →
    /// for ProductFlo" (0.73 vs 0.57, both above 0.45), because the unchanged words
    /// carry the bad pair over the line. So multi-word blocks are aligned token by
    /// token instead: every changed pair must be a case-only change or similar on its
    /// own, and at least one changed pair must leave an uncommon word — a swap of two
    /// words that appear everywhere would fire on nearly every future transcript.
    /// When the sides have different lengths, no common word may be substituted or
    /// dropped: every common word on one side must also appear on the other.
    static func accepts(removed: [String], added: [String]) -> Bool {
        if removed.count == added.count {
            var sawChange = false
            for (a, b) in zip(removed, added) {
                guard a != b else { continue }
                sawChange = true
                if a.lowercased() == b.lowercased() { continue }
                guard similarity(a.lowercased(), b.lowercased()) >= tokenSimilarity else {
                    return false
                }
            }
            return sawChange && zip(removed, added).contains {
                $0 != $1
                    && !(tooCommon.contains($0.lowercased())
                        && tooCommon.contains($1.lowercased()))
            }
        }
        let removedCommon = Set(removed.map { $0.lowercased() }.filter { tooCommon.contains($0) })
        let addedCommon = Set(added.map { $0.lowercased() }.filter { tooCommon.contains($0) })
        guard removedCommon == addedCommon else { return false }
        guard removed.contains(where: { !tooCommon.contains($0.lowercased()) }),
            added.contains(where: { !tooCommon.contains($0.lowercased()) })
        else { return false }
        return similarity(
            removed.joined(separator: " ").lowercased(),
            added.joined(separator: " ").lowercased()
        ) >= minimumSimilarity
    }

    /// Whether an accepted candidate may be filed without asking in `.automatic` mode.
    ///
    /// Only single-token changes and multi-token case-only changes: anything longer
    /// that is not just capitalisation goes to the "Learn this correction?" sheet,
    /// even in automatic mode. A silent multi-word rule is exactly how
    /// `of a product -> for ProductFlo` got filed.
    static func isAutoAddable(_ candidate: LearnedCorrection) -> Bool {
        let hearTokens = candidate.hear.split(whereSeparator: \.isWhitespace)
        let writeTokens = candidate.write.split(whereSeparator: \.isWhitespace)
        if hearTokens.count == 1, writeTokens.count == 1 { return true }
        return candidate.hear.lowercased() == candidate.write.lowercased()
    }

    /// What a re-save teaches that the previous save did not already teach.
    ///
    /// The diff base stays the original transcript, because that is what a rule has
    /// to fire on — but what the previous edit already filed is subtracted, so
    /// re-saving an edit re-learns nothing and `add` is never asked twice.
    static func newCandidates(
        original: String,
        previousEdit: String?,
        edited: String
    ) -> [LearnedCorrection] {
        let fresh = candidates(from: original, to: edited)
        guard let previousEdit, !previousEdit.isEmpty else { return fresh }
        let already = Set(candidates(from: original, to: previousEdit).map(\.id))
        return fresh.filter { !already.contains($0.id) }
    }

    /// Whether the learner, as it stands, would file this stored rule.
    ///
    /// The Dictionary screen offers the ones it would refuse for review. Tokenised
    /// through the same `accepts` every new candidate goes through.
    static func wouldLearn(hear: String, write: String) -> Bool {
        let removed = tokenize(hear)
        let added = tokenize(write)
        guard !removed.isEmpty, !added.isEmpty else { return false }
        return accepts(removed: removed, added: added)
    }

    // MARK: - Diff

    /// Words, with surrounding punctuation stripped.
    ///
    /// The punctuation goes because cleanup owns it: a transcript that gains a comma is not
    /// evidence about a word, and "thursday." → "Thursday" would otherwise be learned as a
    /// rule that writes a full stop into the middle of sentences.
    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Aligned blocks that differ: each is (what was there, what replaced it).
    ///
    /// A longest-common-subsequence walk. Pure insertions and deletions produce an empty
    /// side and are dropped by the caller's `1...3` guard — deliberately, because a word the
    /// user simply removed says nothing about what was misheard.
    private static func replacements(
        from before: [String], to after: [String]
    ) -> [(removed: [String], added: [String])] {
        let n = before.count, m = after.count
        // Compared exactly, not case-insensitively. Case *is* the correction most of the
        // time — "vercel" → "Vercel", "claude code" → "Claude Code" — and treating those
        // tokens as already equal made proper nouns, the single most useful thing a personal
        // dictionary holds, the one thing this could never learn. Sentence-case noise from
        // the cleanup pass ("the" → "The") is caught by `tooCommon` instead.
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = before[i] == after[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var blocks: [(removed: [String], added: [String])] = []
        var i = 0, j = 0
        var removed: [String] = [], added: [String] = []

        func flush() {
            if !removed.isEmpty || !added.isEmpty {
                blocks.append((removed, added))
                removed = []; added = []
            }
        }

        while i < n && j < m {
            if before[i] == after[j] {
                flush()
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                removed.append(before[i]); i += 1
            } else {
                added.append(after[j]); j += 1
            }
        }
        while i < n { removed.append(before[i]); i += 1 }
        while j < m { added.append(after[j]); j += 1 }
        flush()
        return blocks
    }

    // MARK: - Similarity

    /// 1 minus normalised Levenshtein distance: 1.0 identical, 0.0 nothing in common.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(Array(a), Array(b))) / Double(longest)
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
