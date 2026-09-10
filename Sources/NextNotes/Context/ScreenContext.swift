import Foundation
import NextNotesDictionary

/// Where a name was found, which is the only evidence we have about whether it is the name
/// the user is about to say.
///
/// Rank is not a confidence score, it is a position. Nothing in an accessibility tree says
/// which file the user means; what the tree does say is that the active tab is the file they
/// are looking at and a sidebar row forty items down is one they scrolled past. `baseRank`
/// is that ordering written down, and it is what decides which ten names of two hundred get
/// to spend ASR bias budget.
enum CandidateKind: String, Sendable, Hashable, CaseIterable, Codable {
    case activeTab
    case windowTitle
    case breadcrumb
    case inactiveTab
    case editorSymbol
    case sidebarFile
    case sidebarFolder
    case editorText

    /// Gaps of ten between the kinds because the element's own sibling position is added on
    /// top: tab 1 has to outrank tab 7 without either of them crossing into the next kind.
    var baseRank: Int {
        switch self {
        case .activeTab: 0
        // Often carries the project name too, which is why it sits this high despite being
        // one string for a whole window.
        case .windowTitle: 10
        // The path strip above the editor, and the best source of paths in the tree — it is
        // the one place an editor displays the folders it would otherwise only imply.
        case .breadcrumb: 20
        case .inactiveTab: 30
        case .editorSymbol: 50
        case .sidebarFile: 60
        case .sidebarFolder: 70
        // Identifiers scraped from the visible pane; last resort.
        case .editorText: 90
        }
    }

    var isFolder: Bool { self == .sidebarFolder }
}

/// One name that was visible on screen.
struct CandidateName: Sendable, Hashable, Identifiable {
    /// As displayed, verbatim: "login.ts", "AuthProvider.tsx", "src".
    let text: String
    /// The project-relative path when the tree actually gave one — an AXDocument URL, a
    /// breadcrumb strip, a sidebar row with its disclosure ancestry. Nil is the normal case,
    /// and nil is why mention syntax has to degrade to the bare name.
    let path: String?
    let kind: CandidateKind
    /// Lower is more likely to be spoken. `kind.baseRank` plus the element's own position
    /// among its siblings, so tab 1 outranks tab 7 and the top of the sidebar outranks the
    /// bottom of it.
    let rank: Int

    var id: String { path ?? text }

    /// A file rather than a folder: has an extension, or came from a file-ish kind.
    ///
    /// Only `sidebarFile` counts as file-ish by construction. A tab is *not* on that list
    /// even though tabs are usually files, because "Settings" and "Welcome" are tabs too and
    /// calling them files would put them in the prompt as things a path could be built from.
    /// Everything else has to show an extension to claim it.
    var isFile: Bool {
        guard !kind.isFolder else { return false }
        return kind == .sidebarFile || CandidateName.hasFileExtension(text)
    }

    /// What a mention would resolve to: `path` when there is one, `text` otherwise.
    var reference: String { path ?? text }

    /// Whether the last dot in a name is plausibly an extension rather than prose.
    ///
    /// Deliberately strict about what follows the dot — one to eight letters or digits, and
    /// nothing else. Loosening it to "contains a dot" makes "version 1.2 notes" a file and
    /// "src" not one, and the prompt then offers the model a path it can only invent.
    static func hasFileExtension(_ text: String) -> Bool {
        let name = text.split(separator: "/").last.map(String.init) ?? text
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        guard (1...8).contains(ext.count) else { return false }
        return ext.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

/// What one harvest found, and what it had to give up to stay inside its budget.
struct ScreenContext: Sendable, Hashable {
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
            elapsed: elapsed
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
        elapsed: Duration
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.candidates = candidates
        self.projectRoot = projectRoot
        self.truncation = truncation
        self.elapsed = elapsed
    }

    static let empty = ScreenContext(
        bundleID: "",
        appName: "",
        candidates: [],
        projectRoot: nil,
        truncation: [],
        elapsed: .zero
    )

    var isEmpty: Bool { candidates.isEmpty }

    /// Names for the ASR bias slice: the highest-ranked candidates that `SpokenForms` thinks
    /// are worth priming an engine with, at most `limit` of them.
    ///
    /// The phrases are what `SpokenForms.biasPhrase(for:)` returns, not the names themselves —
    /// the spoken stem, "login handler" rather than "loginHandler.tsx". That is the form the
    /// acoustic model can actually be primed with, and it is also why the deduplication
    /// happens on the phrase: two candidates in one project routinely reduce to the same
    /// spoken words, and paying twice for them out of a budget this small is the one mistake
    /// this method exists to avoid.
    ///
    /// `limit` defaults to `SpokenForms.harvestedBiasShare` rather than to a number of its
    /// own, because the ceiling that matters is `DictionaryCorrector.biasLimit` and it is
    /// shared with the user's own dictionary entries. This list is the part that gives way.
    func biasPhrases(limit: Int = SpokenForms.harvestedBiasShare) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var phrases: [String] = []
        for candidate in candidates {
            guard let phrase = SpokenForms.biasPhrase(for: candidate.reference),
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
    /// against the transcript with `SpokenForms.bestMatch`; those at or above
    /// `SpokenForms.plausibleScore` are kept in score order, and any remaining room is
    /// filled by rank. Filling by rank matters as much as the scoring does: an unused
    /// candidate in an editing prompt is inert, so the cost of keeping a name that was not
    /// said is nothing, while the cost of having dropped the one that was is the feature.
    func narrowed(toMentionsIn transcript: String, limit: Int = Self.promptNameLimit) -> ScreenContext {
        guard limit > 0 else {
            return ScreenContext(
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
        let heard = SpokenForms.Heard(transcript)
        for candidate in candidates {
            let match = SpokenForms.bestMatch(of: candidate.reference, in: heard)
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
        return ScreenContext(
            bundleID: bundleID,
            appName: appName,
            ordered: kept,
            projectRoot: projectRoot,
            truncation: truncation.union(kept.count < candidates.count ? .candidateCap : []),
            elapsed: elapsed
        )
    }

    /// The first `limit` candidates in rank order, for a caller that could not afford to
    /// score them.
    ///
    /// `DictationController` uses this when narrowing overruns its bound. Rank order is what
    /// the ASR slice already spends its much smaller budget on, so the fallback is the same
    /// judgement made with less information — the active tab and the top of the sidebar first —
    /// rather than an arbitrary prefix of a hash table.
    func rankLimited(to limit: Int = Self.promptNameLimit) -> ScreenContext {
        let kept = Array(candidates.prefix(max(0, limit)))
        return ScreenContext(
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
