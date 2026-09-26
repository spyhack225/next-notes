import Foundation

/// The part of a dictation that was already tidied while the key was still down. (D-12.)
///
/// Cleanup is local to a sentence — the premise `ChunkedFormatter` is built on — and
/// Parakeet already produces a partial transcript roughly every second while the key is
/// held. So the sentences that have stopped changing can be sent to the model *during* the
/// hold, and the key-up pass only has to clean what came after them.
///
/// `rawPrefix` is those sentences as the deterministic rules pass left them, and
/// `stageA` is the same text one group at a time; `cleaned` is each group's model call,
/// already running. `CleanupRouter` checks its own Stage-A output against `rawPrefix`
/// before it uses any of this: a later partial revising an earlier sentence leaves the
/// prefix mismatched, and the whole transcript is cleaned the way it always was.
///
/// A `Task` per group rather than a value per group because the point of the work is that
/// it is already in flight by the time the key comes up.
struct CleanupHead: Sendable {
    /// The closed groups' Stage-A text, concatenated — the prefix of the final transcript's
    /// own Stage-A output when nothing was revised.
    let rawPrefix: String
    /// One model call per closed group, in transcript order.
    let cleaned: [Task<String, Never>]
    /// Each closed group's Stage-A text, in the same order. What the key-up pass types for
    /// a group whose call has not landed inside its grace, which is what the same call
    /// returns on its own timeout.
    let stageA: [String]

    init(rawPrefix: String, cleaned: [Task<String, Never>], stageA: [String]) {
        self.rawPrefix = rawPrefix
        self.cleaned = cleaned
        // Padded and truncated to the calls rather than trusted: a group whose text went
        // missing has to be typed as spoken, and this is the array the router indexes.
        var texts = stageA
        if texts.count < cleaned.count {
            texts += Array(repeating: "", count: cleaned.count - texts.count)
        }
        self.stageA = Array(texts.prefix(cleaned.count))
    }
}

/// Tidies the finished sentences of a dictation while the key is still held.
///
/// ## What counts as finished
///
/// A sentence of the partial transcript is **stable** when it is not the last sentence and
/// it is identical in two consecutive partials. Both halves are needed: the last sentence
/// of a partial is the one still being revised, and two identical partials are what "no
/// longer being revised" looks like from outside the recogniser.
///
/// ## What happens to one
///
/// Stable sentences are grouped greedily at `maxWords`, with exactly the rule
/// `SentenceChunker.chunks` uses — the next sentence that would overflow a group closes it
/// — plus one addition: a group is also closed as soon as it holds `minClose` words and
/// ends a stable sentence, so a 37-word dictation closes one group rather than none. Each
/// closed group is tidied in the background, one at a time, and the results are what the
/// key-up pass waits for.
///
/// ## Why one at a time
///
/// Apple's on-device model answers one request at a time (`ChunkedFormatter.serialisesCalls`),
/// and a pre-clean is competing with the live transcript for the same machine while the user
/// is still speaking. A second pre-clean would queue behind the first anyway; running it
/// concurrently would only take memory the recogniser wants.
actor IncrementalCleanupSession {
    private let semantic: any TextFormatter
    private let rules: @Sendable (String) -> String
    private let maxWords: Int
    private let minClose: Int

    /// Sentences of the last partial, after Stage A. The comparison that decides stability.
    private var previous: [String] = []
    /// How many of them have been put into a group, so a sentence is never counted twice.
    private var consumed = 0
    /// The group being built from stable sentences, and its word count so far.
    private var open: [String] = []
    private var openWords = 0
    /// One entry per closed group, in transcript order.
    private var groups: [(stageA: String, task: Task<String, Never>)] = []
    private var rawPrefix = ""
    /// A hold that failed or was cancelled: no more work, and nothing queued waits.
    /// A locked box rather than a stored property because a group's task reads it from
    /// outside the actor, and capturing the session there would make the session own the
    /// task that owns the session.
    private let cancelled = LockedBox(false)
    /// The width-1 lane. A task is created per group the moment it closes; this is what
    /// keeps two of them out of the model at once.
    private let lane = PrecleanLane()

    init(
        semantic: any TextFormatter,
        rules: @escaping @Sendable (String) -> String,
        maxWords: Int = 120,
        minClose: Int = 15
    ) {
        self.semantic = semantic
        self.rules = rules
        self.maxWords = maxWords
        self.minClose = minClose
    }

    /// One partial transcript from the recogniser, newest overwrites oldest.
    func notePartial(_ text: String) {
        guard !cancelled.value, !text.isEmpty else { return }
        // The same Stage A the key-up pass runs first, so a group and the slice of the
        // final transcript it will be matched against are written by the same code.
        let sentences = SentenceChunker.sentences(in: rules(text))
        var common = 0
        while common < previous.count, common < sentences.count,
              previous[common] == sentences[common] {
            common += 1
        }
        // Never the last sentence: that is the one the recogniser is still writing.
        let stable = min(common, max(0, sentences.count - 1))
        if stable > consumed {
            for index in consumed..<stable { admit(sentences[index]) }
            consumed = stable
        }
        previous = sentences
    }

    /// What the key-up pass gets. Cheap: the calls are already running and are handed over
    /// as they are, never awaited here.
    func head() -> CleanupHead {
        CleanupHead(
            rawPrefix: rawPrefix,
            cleaned: groups.map(\.task),
            stageA: groups.map(\.stageA)
        )
    }

    /// The hold is over and its transcript is not going to be injected — an error card, or a
    /// cancel. Nothing new starts, and a group still waiting for the lane gives up its turn
    /// and returns its text as spoken rather than sitting in the queue.
    func cancel() {
        cancelled.value = true
    }

    // MARK: - Grouping

    private func admit(_ sentence: String) {
        let words = SentenceChunker.wordCount(sentence)
        if !open.isEmpty, openWords + words > maxWords { close() }
        open.append(sentence)
        openWords += words
        if openWords >= minClose { close() }
    }

    /// Close the group being built and start tidying it, in the same order `chunks` would.
    private func close() {
        guard !open.isEmpty else { return }
        let group = CleanedText.joined(open)
        open = []
        openWords = 0
        guard !group.isEmpty else { return }
        let semantic = self.semantic
        let task = Task(priority: .utility) { [lane, cancelled] in
            await lane.run {
                if cancelled.value { return group }
                return await semantic.format(group)
            }
        }
        groups.append((stageA: group, task: task))
        rawPrefix = CleanedText.joined([rawPrefix, group])
    }
}

/// One model call at a time, and the only thing that enforces it.
///
/// A queue rather than a flag, because a task is created for each group the moment it
/// closes: a group can be waiting for the lane while the previous one is still in the
/// model, and "at most one in the model" is a property of who is *inside* rather than of
/// who has been handed a task to wait on.
private actor PrecleanLane {
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run(_ body: @Sendable () async -> String) async -> String {
        if held {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            held = true
        }
        let answer = await body()
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
        return answer
    }
}

/// How the pieces of a partly-tidied pass are put back together.
///
/// One answer, shared by the chunker and by the key-up pass, because the self-test compares
/// their output byte for byte: if the two joined the same transcript differently, "the
/// text is what a single pass would have produced" would be untestable rather than true.
/// A paragraph break the speaker asked for survives the seam, which is what the newline
/// case is.
enum CleanedText {
    static func joined(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces {
            if piece.isEmpty { continue }
            if out.isEmpty {
                out = piece
            } else if out.hasSuffix("\n") {
                out += piece
            } else {
                out += " " + piece
            }
        }
        return out
    }
}

/// One hold's cleanup, assembled by whoever owns the hold's settings. (D-12.)
///
/// Two halves because there are two moments: the sentences that stopped changing are
/// tidied while the key is down, and everything is tidied at key-up. Production builds
/// both from `Settings`; a self-test hands in one fake for the two of them so it can tell
/// what each did.
struct CleanupPieces: Sendable {
    /// Stage B for one group that closed while the key was down. Never chunked: a group is
    /// already one call, and the width-1 lane is what keeps the model to one at a time.
    var preclean: any TextFormatter
    /// The whole chain for the pass at key-up, handed the head the hold collected. A head
    /// it cannot use is simply cleaned whole, which is what `CleanupRouter` does with one.
    var pass: @Sendable (CleanupHead?) -> any TextFormatter
}
