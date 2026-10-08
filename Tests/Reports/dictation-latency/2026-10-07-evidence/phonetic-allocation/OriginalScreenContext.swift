import Foundation
struct OriginalScreenContext: Sendable, Hashable {
    /// Why a harvest is not the whole tree. Several can be true at once, which is why this
    /// is a set: a Cursor sidebar can hit the node cap *and* the clock.
    struct Truncation: OptionSet, Sendable, Hashable {
        let rawValue: UInt8

        static let nodeCap      = Truncation(rawValue: 1 << 0)
        static let depthCap     = Truncation(rawValue: 1 << 1)
        static let timeBudget   = Truncation(rawValue: 1 << 2)
        static let candidateCap = Truncation(rawValue: 1 << 3)
        /// The app answered, but with a stub tree — the Electron symptom that means
        /// "editor.accessibilitySupport": "on" has not been set.
        static let stubTree     = Truncation(rawValue: 1 << 4)
        static let noAdapter    = Truncation(rawValue: 1 << 5)
        static let denied       = Truncation(rawValue: 1 << 6)

        /// For the log line and the Settings row. A raw bitfield in a log is a number nobody
        /// decodes a week later, and the whole reason these are recorded rather than retried
        /// is so somebody can read them.
        var reasons: [String] {
            var names: [String] = []
            if contains(.nodeCap) { names.append("node cap") }
            if contains(.depthCap) { names.append("depth cap") }
            if contains(.timeBudget) { names.append("time budget") }
            if contains(.candidateCap) { names.append("candidate cap") }
            if contains(.stubTree) { names.append("stub tree") }
            if contains(.noAdapter) { names.append("no adapter") }
            if contains(.denied) { names.append("denied") }
            return names
        }
    }

    let bundleID: String
    let appName: String
    /// Sorted by `rank`, then `text` ascending. Sorted rather than "as found" because
    /// truncation happens by prefix everywhere downstream, and an unsorted prefix is a
    /// random sample.
    let candidates: [CandidateName]
    /// The project or window root when the tree named one, for turning a bare name into a
    /// relative path. Never an absolute filesystem path we went and resolved — this is
    /// whatever the app displayed.
    let projectRoot: String?
    let truncation: Truncation
    /// Wall time the walk actually took. Kept because the budget is the whole safety
    /// argument for doing this at key-down, and a number in the log is the only way anyone
    /// will notice it stopped being true.
    let elapsed: Duration
    /// How many of `candidates` the transcript plausibly names, as scored by
    /// `narrowed(toMentionsIn:)`. Zero on every other value, including a harvest that was
    /// never narrowed.
    ///
    /// Kept because the narrowed list is not itself the answer: it is padded to its limit by
    /// rank, so "the list has names in it" says nothing about whether the user said one. The
    /// cleanup router needs exactly that fact — a short, tidy-looking command that names a
    /// file is the one sentence rules cannot finish, because only a model writes the reference.
    let mentionCount: Int

    init(
        bundleID: String,
        appName: String,
        candidates: [CandidateName],
        projectRoot: String?,
        truncation: Truncation,
        elapsed: Duration
    ) {
        // Sorting here rather than asking every caller to remember: the harvester finds
        // names in tree order, which is the order Electron happens to lay its DOM out in,
        // and nothing downstream is allowed to depend on that.
        self.init(
            bundleID: bundleID,
            appName: appName,
            ordered: candidates.sorted {
                $0.rank == $1.rank ? $0.text < $1.text : $0.rank < $1.rank
            },
            projectRoot: projectRoot,
            truncation: truncation,
            elapsed: elapsed,
            mentionCount: 0
        )
    }

    /// Takes the candidate order as given, which only `narrowed(toMentionsIn:)` and
    /// `rankLimited(to:)` are entitled to do — see the note on the first about why score order
    /// has to survive, and the second is already in rank order by construction.
    private init(
        bundleID: String,
        appName: String,
        ordered candidates: [CandidateName],
        projectRoot: String?,
        truncation: Truncation,
        elapsed: Duration,
        mentionCount: Int = 0
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.candidates = candidates
        self.projectRoot = projectRoot
        self.truncation = truncation
        self.elapsed = elapsed
        self.mentionCount = mentionCount
    }

    static let empty = OriginalScreenContext(
        bundleID: "",
        appName: "",
        candidates: [],
        projectRoot: nil,
        truncation: [],
        elapsed: .zero
    )

    var isEmpty: Bool { candidates.isEmpty }

    /// Names for the ASR bias slice: the highest-ranked candidates that `OriginalSpokenForms` thinks
    /// are worth priming an engine with, at most `limit` of them.
    ///
    /// The phrases are what `OriginalSpokenForms.biasPhrase(for:)` returns, not the names themselves —
    /// the spoken stem, "login handler" rather than "loginHandler.tsx". That is the form the
    /// acoustic model can actually be primed with, and it is also why the deduplication
    /// happens on the phrase: two candidates in one project routinely reduce to the same
    /// spoken words, and paying twice for them out of a budget this small is the one mistake
    /// this method exists to avoid.
    ///
    /// `limit` defaults to `OriginalSpokenForms.harvestedBiasShare` rather than to a number of its
    /// own, because the ceiling that matters is `DictionaryCorrector.biasLimit` and it is
    /// shared with the user's own dictionary entries. This list is the part that gives way.
    func biasPhrases(limit: Int = OriginalSpokenForms.harvestedBiasShare) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var phrases: [String] = []
        for candidate in candidates {
            guard let phrase = OriginalSpokenForms.biasPhrase(for: candidate.reference),
                  seen.insert(phrase.lowercased()).inserted
            else { continue }
            phrases.append(phrase)
            if phrases.count == limit { break }
        }
        return phrases
    }

    /// The cleanup prompt's list, narrowed to what the transcript plausibly mentions.
    ///
    /// This is the one place the harvest and the transcript meet. Every candidate is scored
    /// against the transcript with `OriginalSpokenForms.bestMatch`; those at or above
    /// `OriginalSpokenForms.plausibleScore` are kept in score order, and any remaining room is
    /// filled by rank. Filling by rank matters as much as the scoring does: an unused
    /// candidate in an editing prompt is inert, so the cost of keeping a name that was not
    /// said is nothing, while the cost of having dropped the one that was is the feature.
    func narrowed(toMentionsIn transcript: String, limit: Int = Self.promptNameLimit) -> OriginalScreenContext {
        guard limit > 0 else {
            return OriginalScreenContext(
                bundleID: bundleID,
                appName: appName,
                ordered: [],
                projectRoot: projectRoot,
                truncation: truncation.union(candidates.isEmpty ? [] : .candidateCap),
                elapsed: elapsed
            )
        }

        var plausible: [(candidate: CandidateName, score: Double)] = []
        var rest: [CandidateName] = []
        // Tokenized once. Two hundred candidates against one transcript is two hundred
        // identical passes over the same paragraph otherwise, and the phonetic key of every
        // word in it — the most expensive step in a score — recomputed with each of them.
        let heard = OriginalSpokenForms.Heard(transcript)
        for candidate in candidates {
            let match = OriginalSpokenForms.bestMatch(of: candidate.reference, in: heard)
            // `namedOtherExtension` demotes rather than drops. The user said "the login CSS
            // file" and this candidate is login.ts, so it is not the one they meant and has no
            // business at the head of the list — but the sibling that *is* login.css may not
            // have been harvested at all, and a name kept by rank costs nothing while a name
            // deleted outright cannot be recovered by the model.
            if match.isPlausible, !match.namedOtherExtension {
                plausible.append((candidate, match.score))
            } else {
                rest.append(candidate)
            }
        }

        // Rank breaks a score tie, because two names that match the transcript equally well
        // are separated by nothing except which one the user is looking at.
        plausible.sort {
            $0.score == $1.score ? $0.candidate.rank < $1.candidate.rank : $0.score > $1.score
        }

        var kept = plausible.prefix(limit).map(\.candidate)
        if kept.count < limit {
            // `rest` is already in rank order, because `candidates` is.
            kept.append(contentsOf: rest.prefix(limit - kept.count))
        }

        // Deliberately *not* re-sorted by rank. Whoever renders this list truncates it by
        // prefix if the prompt runs long, and after scoring the least valuable thing to lose
        // is the name least like anything the user said — not the name lowest in a sidebar.
        return OriginalScreenContext(
            bundleID: bundleID,
            appName: appName,
            ordered: kept,
            projectRoot: projectRoot,
            truncation: truncation.union(kept.count < candidates.count ? .candidateCap : []),
            elapsed: elapsed,
            mentionCount: min(plausible.count, limit)
        )
    }

    /// The first `limit` candidates in rank order, for a caller that could not afford to
    /// score them.
    ///
    /// `DictationController` uses this when narrowing overruns its bound. Rank order is what
    /// the ASR slice already spends its much smaller budget on, so the fallback is the same
    /// judgement made with less information — the active tab and the top of the sidebar first —
    /// rather than an arbitrary prefix of a hash table.
    func rankLimited(to limit: Int = Self.promptNameLimit) -> OriginalScreenContext {
        let kept = Array(candidates.prefix(max(0, limit)))
        return OriginalScreenContext(
            bundleID: bundleID,
            appName: appName,
            ordered: kept,
            projectRoot: projectRoot,
            truncation: truncation.union(kept.count < candidates.count ? .candidateCap : []),
            elapsed: elapsed
        )
    }

    /// ~120. The cleanup pass is editing existing text rather than transcribing audio, so
    /// the drift failure recorded above `DictionaryCorrector.biasLimit` does not apply here;
    /// this cap is about prompt size, not about hallucination.
    static let promptNameLimit = 120
}
