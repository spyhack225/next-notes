import Foundation
import FoundationModels

/// Cleanup via Apple's on-device LLM (macOS 26 Foundation Models).
///
/// This is the pass that separates dictation from *usable* dictation: it removes fillers,
/// restores punctuation and paragraphing, formats spoken lists, honors mid-sentence
/// corrections like "make that three, actually" — and, when `fixesGrammar` is on, repairs
/// the sentence itself.
///
/// Three properties make it safe to put in the hot path:
/// - **On-device.** Nothing leaves the Mac, so it's viable for anything you'd dictate.
/// - **Bounded.** A timeout falls back to `RuleBasedFormatter`, because a stalled model
///   must never cost you an utterance you already spoke.
/// - **Guarded.** Output is rejected by `CleanupGuard` if it looks like the model answered
///   the text instead of cleaning it — the classic failure when dictation reads as an
///   instruction.
/// What one model call needs to report, in the order it happens: whether a staged session was
/// used (known *before* the call), then the answer.
///
/// Production passes nil and reaches Apple's model through `CleanupSessionWarmer`; only
/// self-tests pass a value, so no test ever wakes the real model. Added by D-01a; D-07,
/// D-08 and D-11 reuse it.
struct CleanupModelCall: Sendable {
    /// True when a staged session was taken for these instructions.
    var takeSession: @Sendable (_ instructions: String) async -> Bool
    var respond: @Sendable (_ user: String) async throws -> String
}

struct FoundationModelFormatter: TextFormatter {
    /// Deterministic fallback used on timeout, unavailability, or a rejected response.
    /// What to return when the model is unavailable, times out, or its output is rejected.
    ///
    /// Injectable because the answer differs by position. Used alone, falling back to rule-based
    /// cleanup is right — the raw transcript has had nothing done to it. Used as the second
    /// stage of a chain, it is wrong: the input has already been cleaned by S1-mini, and running
    /// the rule-based pass over it again would undo work rather than add any. There the fallback
    /// is `KeepAsIsFormatter`.
    private let fallback: any TextFormatter

    private let preferences: CleanupPreferences

    /// Whether the pass also repairs grammar, or only punctuation and fillers.
    ///
    /// It changes two things, and neither of them is a second model call: the instructions
    /// gain a block of grammar rules, and the output guard switches from "no new content
    /// words at all" to "every new word must be traceable to one that was dropped". Same
    /// session, same token budget — which is why grammar is free here rather than a trade
    /// against latency. The timeout grows with the transcript; see `timeout(for:)`.
    /// `--selftest-cleanup` is where that claim is checked.
    private let fixesGrammar: Bool
    /// What the receiving app can render. Plain unless a caller says otherwise.
    private let target: OutputProfile
    /// The names that were visible in that app when the key went down, for resolving a spoken
    /// file reference against something real. `.empty` unless a caller says otherwise, because
    /// no grounding is safer than stale grounding: names harvested for the *previous*
    /// dictation would read to the model as a confident answer about this one.
    private let context: ScreenContext
    /// Per-run record. Every path out of `format` writes exactly one verdict into it, which
    /// is what makes "the model was rejected" distinguishable from "the model changed
    /// nothing" after the fact. Nil everywhere but the live dictation path.
    private let trace: CleanupTrace?

    /// Stands in for `CleanupSessionWarmer.take` + `session.respond` (and for the
    /// `isAvailable` gate). Nil in production; only self-tests set it. (D-01a.)
    var modelCall: CleanupModelCall? = nil
    /// Multiplies the computed timeout. Production leaves it at 1; self-tests scale the
    /// budget down so a timeout case runs in milliseconds. (D-07, §0.7.)
    var timeScale: Double = 1

    init(
        preferences: CleanupPreferences = CleanupPreferences(
            tone: .balanced,
            formatsLists: true,
            context: .general
        ),
        fixesGrammar: Bool = false,
        target: OutputProfile = .plain(bundleID: "", displayName: "the focused app"),
        context: ScreenContext = .empty,
        fallback: any TextFormatter = RuleBasedFormatter(),
        trace: CleanupTrace? = nil
    ) {
        self.target = target
        self.context = context
        self.preferences = preferences
        self.fixesGrammar = fixesGrammar
        self.fallback = fallback
        self.trace = trace
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings."
            case .modelNotReady: return "The on-device model is still downloading."
            @unknown default: return "The on-device model is unavailable."
            }
        @unknown default:
            return "The on-device model is unavailable."
        }
    }

    func format(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        guard modelCall != nil || Self.isAvailable else {
            Log.speech.info("Foundation model unavailable — using rule-based cleanup")
            note(
                .notReached,
                reason: Self.unavailableReason ?? "Apple's on-device model is unavailable",
                seconds: 0
            )
            return await fallback.format(trimmed)
        }

        let began = Date()
        do {
            // D-07: the budget is warmth-aware, and the warmth is only known once the
            // session has been taken. `LanguageModelSession` is not `Sendable`, so the
            // session cannot leave the task that took it: that task takes it, files the
            // prewarm bit, computes the budget and hands that one `Duration` to the task
            // that waits it out. `sessionPrewarmed` is still filed before the answer is
            // awaited (D-01a) — earlier now, before the race starts.
            let instructions = CleanupInstructions.system(
                for: preferences,
                fixesGrammar: fixesGrammar,
                target: target,
                context: context
            )
            let user = CleanupInstructions.user(trimmed, fixesGrammar: fixesGrammar)
            let scale = timeScale
            let seal = CleanupBudgetSeal()
            let trace = trace
            let modelCall = modelCall

            let cleaned = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let stagedSession: LanguageModelSession?
                    let staged: Bool
                    if let modelCall {
                        staged = await modelCall.takeSession(instructions)
                        stagedSession = nil
                    } else {
                        stagedSession = await CleanupSessionWarmer.shared.take(instructions: instructions)
                        staged = stagedSession != nil
                    }
                    trace?.noteSessionPrewarmed(staged)
                    // The same bit for the group this call belongs to, so a chunked pass can
                    // say which of its groups ran prewarmed. (D-08.)
                    if let group = CleanupGroupContext.current {
                        trace?.noteGroupPrewarmed(index: group.index, staged)
                    }
                    // A staged session was staged at key-down and is warm by construction;
                    // otherwise the process is as warm as its last completed Apple-model call.
                    let warmth: Warmth = staged
                        ? .staged
                        : await MainActor.run { AppleModelWarmth.current() }
                    trace?.noteAssumedWarmth(warmth)
                    // A call in a wave of `n` on an engine that answers one call at a time
                    // waits its turn, so its own budget is that many times the solo budget.
                    // The chunker charges the wave the same sum, so the two cannot disagree
                    // about whether a wave was affordable. (D-08.)
                    let queued = max(1, CleanupGroupContext.current?.callsInWave ?? 1)
                    // Nothing between here and `respond` throws, so the seal is always
                    // published and the waiting task can never wait forever.
                    seal.publish(Self.timeout(for: trimmed, warmth: warmth) * scale * queued)
                    return try await Self.respond(
                        user: user,
                        instructions: instructions,
                        stagedSession: stagedSession,
                        modelCall: modelCall
                    )
                }
                group.addTask {
                    try await Task.sleep(for: await seal.budget())
                    throw CleanupError.timedOut
                }
                // Whichever finishes first wins; cancel the loser.
                guard let first = try await group.next() else { throw CleanupError.timedOut }
                group.cancelAll()
                return first
            }

            if let reason = CleanupGuard.rejection(
                original: trimmed,
                cleaned: cleaned,
                mode: CleanupInstructions.mode(fixesGrammar: fixesGrammar)
            ) {
                // Before giving the whole answer up, ask which sentence was the problem.
                // One unexplained word in one sentence used to cost the user every repair
                // in the other five.
                if let salvage = CleanupGuard.salvage(
                    original: trimmed,
                    cleaned: cleaned,
                    mode: CleanupInstructions.mode(fixesGrammar: fixesGrammar)
                ) {
                    Log.speech.info("""
                        Foundation model output partly kept — \(reason, privacy: .public); \
                        \(salvage.rejectedSentences, privacy: .public) of \
                        \(salvage.totalSentences, privacy: .public) sentences left as spoken
                        """)
                    note(
                        .partlyAccepted,
                        reason: salvage.plainReason,
                        seconds: Date().timeIntervalSince(began)
                    )
                    return salvage.text
                }
                Log.speech.info("Foundation model output rejected — \(reason, privacy: .public)")
                note(
                    .rejected,
                    reason: "the tidied version changed too much to trust (\(reason))",
                    seconds: Date().timeIntervalSince(began)
                )
                return await fallback.format(trimmed)
            }
            note(.accepted, reason: nil, seconds: Date().timeIntervalSince(began))
            return cleaned
        } catch {
            Log.speech.info("Foundation model cleanup failed (\(Self.describe(error), privacy: .public)) — falling back")
            note(.notReached, reason: Self.describe(error), seconds: Date().timeIntervalSince(began))
            return await fallback.format(trimmed)
        }
    }

    /// One exit from `format`, filed the same way whether this call cleaned a whole
    /// transcript or one group of a chunked pass: the run-level writers, and beside them the
    /// per-group row when the chunker named the call. (D-08.)
    private func note(_ verdict: CleanupGroupVerdict, reason: String?, seconds: Double) {
        let trace = self.trace
        switch verdict {
        case .accepted:
            trace?.noteModelAccepted(seconds: seconds)
        case .partlyAccepted:
            trace?.noteModelSalvaged(reason: reason ?? "", seconds: seconds)
        case .rejected:
            trace?.noteModelRejected(reason: reason ?? "", seconds: seconds)
        case .notReached:
            trace?.noteModelFailed(reason: reason ?? "", seconds: seconds)
        }
        if let group = CleanupGroupContext.current {
            trace?.noteGroup(index: group.index, verdict: verdict.rawValue, seconds: seconds)
        }
    }

    /// Every failure here degrades to `RuleBasedFormatter` — the user still gets their
    /// words. This exists to make the *reason* legible in the log, because the cases have
    /// very different meanings: `guardrailViolation` and `refusal` are the model declining
    /// content (expected occasionally, not a bug), while `assetsUnavailable` means the
    /// feature is effectively off and the user should be told.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else {
            return error.localizedDescription
        }
        switch error {
        case .exceededContextWindowSize: return "input exceeded the context window"
        case .assetsUnavailable: return "model assets unavailable"
        case .guardrailViolation: return "blocked by safety guardrails"
        case .unsupportedGuide: return "unsupported generation guide"
        case .unsupportedLanguageOrLocale: return "unsupported language"
        case .decodingFailure: return "decoding failure"
        case .rateLimited: return "rate limited"
        case .concurrentRequests: return "concurrent request on one session"
        case .refusal: return "model refused the content"
        @unknown default: return error.localizedDescription
        }
    }

    /// Exposed unguarded so `--selftest-cleanup` can print what the model actually said
    /// next to what the guard let through. Production always goes through `format`.
    static func clean(
        _ text: String,
        preferences: CleanupPreferences,
        fixesGrammar: Bool,
        target: OutputProfile = .plain(bundleID: "", displayName: "the focused app"),
        context: ScreenContext = .empty
    ) async throws -> String {
        try await cleanReporting(
            text,
            preferences: preferences,
            fixesGrammar: fixesGrammar,
            target: target,
            context: context,
            trace: nil,
            modelCall: nil
        ).text
    }

    /// Same as `clean`, plus whether the call ran on a session staged at key-down.
    /// The caller files that bit in the per-run record: the 0.6s-vs-4s spread on
    /// short dictations is a prewarm hit versus a miss until proven otherwise.
    ///
    /// `format` no longer comes through here (D-07): the budget has to be computed
    /// against the warmth the session take reveals, so `format` takes the session itself
    /// and races `respond` directly. This remains the unguarded, untimed call for
    /// `--selftest-cleanup` and the warmth probe.
    static func cleanReporting(
        _ text: String,
        preferences: CleanupPreferences,
        fixesGrammar: Bool,
        target: OutputProfile = .plain(bundleID: "", displayName: "the focused app"),
        context: ScreenContext = .empty,
        trace: CleanupTrace?,
        modelCall: CleanupModelCall?
    ) async throws -> (text: String, prewarmed: Bool) {
        let instructions = CleanupInstructions.system(
            for: preferences,
            fixesGrammar: fixesGrammar,
            target: target,
            context: context
        )
        let user = CleanupInstructions.user(text, fixesGrammar: fixesGrammar)
        if let modelCall {
            // D-01a: the seam stands in for the model. The prewarm is filed before
            // `respond` is awaited, so timed-out, thrown and rejected runs carry it.
            let prewarmed = await modelCall.takeSession(instructions)
            trace?.noteSessionPrewarmed(prewarmed)
            let answer = try await Self.respond(
                user: user,
                instructions: instructions,
                stagedSession: nil,
                modelCall: modelCall
            )
            return (answer, prewarmed)
        }
        // A session staged while the key was still down, if there is one for exactly these
        // instructions. Apple's prewarm is prompt-specific, so a session staged against a
        // different prompt is worth nothing and is not offered.
        let staged = await CleanupSessionWarmer.shared.take(instructions: instructions)
        trace?.noteSessionPrewarmed(staged != nil)          // before the call, always
        let answer = try await Self.respond(
            user: user,
            instructions: instructions,
            stagedSession: staged,
            modelCall: nil
        )
        return (answer, staged != nil)
    }

    /// One model answer, on a session the caller has already taken. Records the
    /// completed answer as Apple-model activity (D-06) — accepted, salvaged and
    /// guard-rejected alike, since the model ran either way.
    private static func respond(
        user: String,
        instructions: String,
        stagedSession: LanguageModelSession?,
        modelCall: CleanupModelCall?
    ) async throws -> String {
        if let modelCall {
            let answer = try await modelCall.respond(user)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { AppleModelWarmth.noteActivity() }
            return answer
        }
        let session = stagedSession ?? LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: user,
            options: GenerationOptions(
                // Near-deterministic: this is a formatting pass, not a creative one.
                temperature: 0.1,
                // Cleanup should never be much longer than the input; this bounds a runaway.
                maximumResponseTokens: 1_200
            )
        )
        await MainActor.run { AppleModelWarmth.noteActivity() }
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How long this transcript is allowed to spend in the model.
    ///
    /// The model writes the transcript back out, so its time grows with every word: about
    /// 1.3 tokens a word at 20–30 tokens a second, on top of reading the instructions. The
    /// first version allowed one extra second per forty words, which is an eighth of that —
    /// on 2026-09-20 an 84-word dictation with grammar on got 5.1s, timed out at 5.07s, and
    /// was typed with "the the the the" in it. Seven hundredths of a second a word, capped
    /// at 14s: `ChunkedFormatter` keeps a call near 120 words, so the cap is rarely met, and
    /// a stalled model still cannot sit on the tail.
    ///
    /// The budget is also warmth-aware (D-07). The warm formulas above assume the process
    /// has already answered on this model; measured on this Mac, the first call in a fresh
    /// process takes **4.69 s** before it writes anything, so the 4.0 s warm floor sat
    /// under the wake-up itself and any dictation of ≤ 10 words landing on a cold model
    /// was guaranteed to time out (I1-01: 6 of 9 timeouts in `runs.jsonl` were exactly
    /// this). A cold call gets a 8.5 s floor — the wake-up's measured cost on top of the
    /// warm floor — capped at 16 s, still bounded well under the 30 s outer limit, so a
    /// genuinely stalled call still ends. A staged session is warm by construction and
    /// keeps the tight budget.
    static func timeout(for text: String, warmth: Warmth) -> Duration {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        // A staged session is warm by construction; a process that has answered here within
        // the warm window is warm as measured. Both keep the budget above. A cold call pays
        // the 4.69 s wake-up first, so its floor is the warm floor plus that measured cost
        // and its cap is two seconds higher — still bounded well under the 30 s outer limit,
        // so a genuinely stalled call still ends.
        let floor: Double
        let cap: Double
        switch warmth {
        case .staged, .warmProcess:
            floor = 4.0
            cap = 14.0
        case .cold:
            floor = 8.5
            cap = 16.0
        }
        let seconds = min(cap, floor + Double(words) * 0.07)
        return .seconds(seconds)
    }

    /// Kept for callers that cannot know the warmth; they get the warm budget, which is
    /// the tight one. Callers that can know pass it.
    static func timeout(for text: String) -> Duration {
        timeout(for: text, warmth: .warmProcess)
    }

    private enum CleanupError: LocalizedError {
        case timedOut
        var errorDescription: String? { "on-device cleanup timed out" }
    }
}

/// Hands the warmth-aware per-call budget from the task that took the session to the task
/// that waits it out.
///
/// The two tasks share nothing else: `LanguageModelSession` is not `Sendable`, so the
/// session is taken and used inside one task, and only the computed `Duration` crosses.
/// Published exactly once, before the answer is awaited (D-07).
private final class CleanupBudgetSeal: @unchecked Sendable {
    private let lock = NSLock()
    private var published: Duration?
    private var waiter: CheckedContinuation<Duration, Never>?

    /// The budget, waiting for the publishing task if it has not got there yet.
    func budget() async -> Duration {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let published {
                lock.unlock()
                continuation.resume(returning: published)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    func publish(_ budget: Duration) {
        lock.lock()
        published = budget
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: budget)
    }
}

/// Wakes the cleanup model while the speaker is still talking.
///
/// ## The measurement
///
/// Apple's on-device model, grammar on, this user's own three-sentence dictation of
/// 2026-09-20T15:48:50Z, measured on this Mac:
///
/// | when the session is built            | time in the model |
/// | ------------------------------------ | ----------------- |
/// | first call in a fresh process        | 4.69 s            |
/// | later calls, a fresh session each    | 1.42 s – 1.58 s   |
/// | session prewarmed one second ahead   | 0.94 s            |
///
/// That user's run took 4.90 s to change one word, and the table says why: the wait was
/// the model waking up, not the model working. It is also why the answer is not a fast
/// path that skips the model for short, tidy transcripts — the model earns its place on
/// those too, and a second of it is not what anyone notices. What they notice is the five.
///
/// ## Why it has to be the key going down
///
/// Prewarming when the transcript arrives is prewarming after the wait has started. The
/// one moment the app knows a cleanup is coming *and* has several seconds of speech to
/// spend is the moment the hold begins, so that is where `stage(instructions:)` belongs —
/// `DictationController`, in the same block that harvests the screen context.
///
/// A staged session is handed out once and then dropped. `LanguageModelSession` refuses
/// concurrent requests on one session, and a stale session held across dictations would be
/// carrying the previous transcript in its own history.
/// ## Why it keeps more than one
///
/// A dictation with formatting on makes two different calls to the same model: the cleanup
/// pass, and the layout pass in `AppleStructurePlanner`. They take different instructions,
/// and Apple's prewarm is prompt-specific, so one staged session can only ever help one of
/// them. The layout pass is the one that had a three-second ceiling and a cold start inside
/// it — `structurePlanSeconds: 3.01`, on this user's 2026-09-20T20:47:25Z dictation — so
/// staging one prompt and not the other was staging the wrong half.
///
/// Keyed by the instructions themselves rather than by an enum of call sites: the key is
/// the thing that has to match for a staged session to be worth anything, so making it the
/// identity removes the possibility of a session staged under the right name and the wrong
/// prompt.
actor CleanupSessionWarmer {
    static let shared = CleanupSessionWarmer()

    /// At most this many prompts staged at once. Two — cleanup and layout — plus room to be
    /// wrong once. A staged session holds model residency, so this is a real bound and not
    /// a formality.
    private static let capacity = 3

    private var staged: [(instructions: String, session: LanguageModelSession)] = []

    /// Build the session the next cleanup will use, and ask the framework to wake the model
    /// behind it. Cheap and safe to call on a hold that never produces a transcript.
    ///
    /// Two sessions may be staged for one prompt, because a chunked pass sends several
    /// sentence groups against the *same* instructions and a session is handed out once:
    /// with one, only the first group of a long dictation ran prewarmed and the rest paid
    /// the wake-up. The total stays `capacity`. (D-08.)
    func stage(instructions: String) {
        guard FoundationModelFormatter.isAvailable else { return }
        guard staged.filter({ $0.instructions == instructions }).count < 2 else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        staged.append((instructions, session))
        if staged.count > Self.capacity { staged.removeFirst() }
    }

    /// The staged session, if one was staged against exactly these instructions. Taken
    /// rather than borrowed: `LanguageModelSession` refuses concurrent requests on one
    /// session, and a session held across dictations would be carrying the previous
    /// transcript in its own history.
    func take(instructions: String) -> LanguageModelSession? {
        guard let index = staged.firstIndex(where: { $0.instructions == instructions })
        else { return nil }
        return staged.remove(at: index).session
    }

    /// Drop every staged session — a hold that was cancelled, or a dictation that produced
    /// nothing.
    func clear() {
        staged.removeAll()
    }

    /// How many prompts are staged. For the self-tests, which have no model to ask.
    var stagedCount: Int { staged.count }
}
