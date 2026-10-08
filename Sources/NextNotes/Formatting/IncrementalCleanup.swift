import Foundation

/// The part of a dictation that was already tidied while the key was still down. (D-12.)
///
/// Cleanup is local to a sentence — the premise `ChunkedFormatter` is built on — and
/// Parakeet freezes the text of each pause-committed segment while the key is held. So the
/// sentences that can no longer change can be sent to the model *during* the hold, and the
/// key-up pass only has to clean what came after them.
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
    /// Completion from the same group task. Lets the router retain work that finishes
    /// during tail polishing after its head grace, without another wait or model pass.
    let completed: [LockedBox<String?>]

    init(rawPrefix: String, cleaned: [Task<String, Never>], stageA: [String],
         completed: [LockedBox<String?>] = []) {
        self.rawPrefix = rawPrefix
        self.cleaned = cleaned
        // Padded and truncated to the calls rather than trusted: a group whose text went
        // missing has to be typed as spoken, and this is the array the router indexes.
        var texts = stageA
        if texts.count < cleaned.count {
            texts += Array(repeating: "", count: cleaned.count - texts.count)
        }
        self.stageA = Array(texts.prefix(cleaned.count))
        self.completed = Array(completed.prefix(cleaned.count))
    }
}

/// Tidies the finished sentences of a dictation while the key is still held.
///
/// ## What counts as finished
///
/// When the engine says which prefix it has frozen (`TranscriptionChunk.committedText`,
/// Parakeet's pause-committed segments), every terminated sentence of that prefix is
/// finished by construction, and a group closes at each committed boundary once it holds
/// `minFragment` words — one model call per spoken segment, never a two-word fragment on
/// its own. A trailing sentence the segment cut before its full stop waits for the next
/// segment to finish it.
///
/// For an engine that may revise any word (no committed prefix), a sentence of the partial
/// transcript is **stable** when it is not the last sentence and it is identical in two
/// consecutive partials. Both halves are needed: the last sentence of a partial is the one
/// still being revised, and two identical partials are what "no longer being revised" looks
/// like from outside the recogniser. Before segments existed this was the only rule, and
/// because every partial re-decoded the whole hold, earlier sentences were reworded often
/// enough that 3 heads in 78 cleanups survived the key-up prefix check.
///
/// Either way `CleanupRouter` still checks the head against the final transcript at key-up.
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
    private let minFragment: Int

    /// Sentences of the last partial, after Stage A. The comparison that decides stability.
    private var previous: [String] = []
    /// How many of them have been put into a group, so a sentence is never counted twice.
    private var consumed = 0
    /// The group being built from stable sentences, and its word count so far.
    private var open: [String] = []
    private var openWords = 0
    /// One entry per closed group, in transcript order.
    private var groups: [(stageA: String, task: Task<String, Never>, completed: LockedBox<String?>)] = []
    private var rawPrefix = ""
    private var previousCommitted: String?
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
        minClose: Int = 15,
        minFragment: Int = 5
    ) {
        self.semantic = semantic
        self.rules = rules
        self.maxWords = maxWords
        self.minClose = minClose
        self.minFragment = minFragment
    }

    /// One partial transcript, with the prefix the engine has frozen when it has one.
    /// nil falls back to the two-identical-partials rule of `notePartial(_:)`.
    func notePartial(_ text: String, committed: String?) {
        guard let committed else {
            notePartial(text)
            return
        }
        guard !cancelled.value, !committed.isEmpty else { return }
        // The open tail revises every partial; this prefix only changes at a commit.
        // Avoid rerunning the full rules and sentence split over an unchanged head.
        guard committed != previousCommitted else { return }
        previousCommitted = committed
        let sentences = SentenceChunker.sentences(in: rules(committed))
        // Frozen text cannot be revised, but a segment cut at a pause may end mid-sentence:
        // that sentence is finished by the next segment, not by this one.
        var finished = sentences.count
        if let last = sentences.last, !Self.isTerminated(last) { finished -= 1 }
        if finished > consumed {
            for index in consumed..<finished { admit(sentences[index], closeAt: maxWords + 1) }
            consumed = finished
        }
        // The committed boundary is the natural end of a group.
        if openWords >= minFragment { close() }
    }

    private static func isTerminated(_ sentence: String) -> Bool {
        guard let last = sentence.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?\n".contains(last)
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
            stageA: groups.map(\.stageA),
            completed: groups.map(\.completed)
        )
    }

    /// The hold is over and its transcript is not going to be injected — an error card, or a
    /// cancel. Nothing new starts, and a group still waiting for the lane gives up its turn
    /// and returns its text as spoken rather than sitting in the queue.
    func cancel() {
        cancelled.value = true
        for group in groups { group.task.cancel() }
    }

    // MARK: - Grouping

    private func admit(_ sentence: String) {
        admit(sentence, closeAt: minClose)
    }

    private func admit(_ sentence: String, closeAt: Int) {
        let words = SentenceChunker.wordCount(sentence)
        if !open.isEmpty, openWords + words > maxWords { close() }
        open.append(sentence)
        openWords += words
        if openWords >= closeAt { close() }
    }

    /// Close the group being built and start tidying it, in the same order `chunks` would.
    private func close() {
        guard !open.isEmpty else { return }
        let group = CleanedText.joined(open)
        open = []
        openWords = 0
        guard !group.isEmpty else { return }
        let semantic = self.semantic
        let completed = LockedBox<String?>(nil)
        let task = Task(priority: .utility) { [lane, cancelled] in
            let answer = await lane.run {
                if cancelled.value || Task.isCancelled { return group }
                return await semantic.format(group)
            } ?? group
            completed.value = answer
            return answer
        }
        groups.append((stageA: group, task: task, completed: completed))
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
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    func run(_ body: @Sendable () async -> String) async -> String? {
        guard !Task.isCancelled else { return nil }
        if held {
            let id = UUID()
            let acquired = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                    } else {
                        waiting.append((id, continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
            guard acquired else { return nil }
        } else {
            held = true
        }
        let answer = await body()
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
        return answer
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
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


// Maintained producer/consumer cancellation regression; no microphone/model/store.
extension IncrementalCleanupSession {
private actor Hold {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}
private struct HeldSemantic: TextFormatter {
    let gate: Hold
    let calls: LockedBox<[String]>
    func format(_ raw: String) async -> String {
        calls.value.append(raw)
        await gate.wait()
        return raw.uppercased()
    }
}

    private func waitingGroupsForTesting() async -> Int { await lane.waitingCountForTesting() }
    private static func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        let limit = ContinuousClock.now + .milliseconds(150)
        while ContinuousClock.now < limit {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
    static func cancelledLaneFailures() async -> [String] {
        guard SelfTest.isRunning else { return ["pre-clean cancellation fixture requires SelfTest"] }
        var failures: [String] = []
        let gate = Hold()
        let calls = LockedBox<[String]>([])
        let session = IncrementalCleanupSession(semantic: HeldSemantic(gate: gate, calls: calls), rules: { $0 })
        let first = "The first group is waiting."
        let second = "The second group must be cancelled."
        let full = first + " " + second
        await session.notePartial(first, committed: first)
        if !(await waitUntil { calls.value.count == 1 }) { failures.append("first producer never entered semantic") }
        await session.notePartial(full, committed: full)
        if !(await waitUntil { await session.waitingGroupsForTesting() == 1 }) { failures.append("second producer never parked") }
        let head = await session.head()
        guard head.cleaned.count == 2 else {
            await gate.release()
            for task in head.cleaned { _ = await task.value }
            return failures + ["pre-clean cancellation fixture produced wrong group count"]
        }
        let done = LockedBox(false)
        let firstDone = LockedBox(false)
        let secondResult = LockedBox<String?>(nil)
        let firstJoin = Task { _ = await head.cleaned[0].value; firstDone.value = true }
        let secondJoin = Task { secondResult.value = await head.cleaned[1].value; done.value = true }
        let began = ContinuousClock.now
        await session.cancel()
        let joinedWhileFirstHeld = await waitUntil { done.value }
        let delay = ContinuousClock.now - began
        if !joinedWhileFirstHeld { failures.append("cancelled second task still waits behind held first task") }
        if head.completed[1].value != second { failures.append("cancelled second completion is not available as exact raw group") }
        if firstDone.value { failures.append("cancelling waiter prematurely released the first semantic owner") }
        if calls.value != [first] { failures.append("cancelled second group entered semantic") }
        if head.rawPrefix != full || head.stageA != [first, second] { failures.append("original grouping or prefix changed") }
        await gate.release()
        await firstJoin.value
        await secondJoin.value
        if secondResult.value != second || calls.value != [first] { failures.append("final cancellation changed content or called semantic again") }
        if await session.waitingGroupsForTesting() != 0 { failures.append("waiter leaked after owner release") }
        // Normal ownership stays serial, and both original groups are cleaned.
        let ordinaryGate = Hold()
        let ordinaryCalls = LockedBox<[String]>([])
        let ordinary = IncrementalCleanupSession(semantic: HeldSemantic(gate: ordinaryGate, calls: ordinaryCalls), rules: { $0 })
        await ordinary.notePartial(first, committed: first)
        _ = await waitUntil { ordinaryCalls.value.count == 1 }
        await ordinary.notePartial(full, committed: full)
        _ = await waitUntil { await ordinary.waitingGroupsForTesting() == 1 }
        if ordinaryCalls.value != [first] { failures.append("normal lane admitted overlapping second semantic") }
        let ordinaryHead = await ordinary.head()
        await ordinaryGate.release()
        var ordinaryResults: [String] = []
        for task in ordinaryHead.cleaned { ordinaryResults.append(await task.value) }
        if ordinaryResults != [first.uppercased(), second.uppercased()] || ordinaryCalls.value != [first, second] { failures.append("normal lane lost original cleanup/order") }
        // Cancel and owner release are exercised in either order through the real session.
        for index in 0..<20 {
            let raceGate = Hold()
            let raceCalls = LockedBox<[String]>([])
            let raceSession = IncrementalCleanupSession(semantic: HeldSemantic(gate: raceGate, calls: raceCalls), rules: { $0 })
            await raceSession.notePartial(first, committed: first)
            _ = await waitUntil { raceCalls.value.count == 1 }
            await raceSession.notePartial(full, committed: full)
            _ = await waitUntil { await raceSession.waitingGroupsForTesting() == 1 }
            let raceHead = await raceSession.head()
            if index.isMultiple(of: 2) {
                await raceSession.cancel(); await raceGate.release()
            } else {
                async let cancellation: Void = raceSession.cancel()
                await raceGate.release()
                await cancellation
            }
            for task in raceHead.cleaned { _ = await task.value }
            if await raceSession.waitingGroupsForTesting() != 0 { failures.append("race \(index) leaked waiter") }
            if raceCalls.value.count > 2 || raceHead.rawPrefix != full { failures.append("race \(index) duplicated or lost group") }
        }
        print("PRECLEAN_MEASURE: joinedWhileFirstHeld=\(joinedWhileFirstHeld) wait=\(delay) semanticCalls=\(calls.value.count)")
        return failures
    }
}

extension PrecleanLane {
    func waitingCountForTesting() -> Int { waiting.count }
}
