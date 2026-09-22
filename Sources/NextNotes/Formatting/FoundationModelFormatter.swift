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

        guard Self.isAvailable else {
            Log.speech.info("Foundation model unavailable — using rule-based cleanup")
            trace?.noteModelFailed(
                reason: Self.unavailableReason ?? "Apple's on-device model is unavailable",
                seconds: 0
            )
            return await fallback.format(trimmed)
        }

        let began = Date()
        do {
            let budget = Self.timeout(for: trimmed)
            let cleaned = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await Self.clean(
                        trimmed,
                        preferences: preferences,
                        fixesGrammar: fixesGrammar,
                        target: target,
                        context: context
                    )
                }
                group.addTask {
                    try await Task.sleep(for: budget)
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
                    trace?.noteModelSalvaged(
                        reason: salvage.plainReason,
                        seconds: Date().timeIntervalSince(began)
                    )
                    return salvage.text
                }
                Log.speech.info("Foundation model output rejected — \(reason, privacy: .public)")
                trace?.noteModelRejected(
                    reason: "the tidied version changed too much to trust (\(reason))",
                    seconds: Date().timeIntervalSince(began)
                )
                return await fallback.format(trimmed)
            }
            trace?.noteModelAccepted(seconds: Date().timeIntervalSince(began))
            return cleaned
        } catch {
            Log.speech.info("Foundation model cleanup failed (\(Self.describe(error), privacy: .public)) — falling back")
            trace?.noteModelFailed(
                reason: Self.describe(error),
                seconds: Date().timeIntervalSince(began)
            )
            return await fallback.format(trimmed)
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
        let instructions = CleanupInstructions.system(
            for: preferences,
            fixesGrammar: fixesGrammar,
            target: target,
            context: context
        )
        // A session staged while the key was still down, if there is one for exactly these
        // instructions. Apple's prewarm is prompt-specific, so a session staged against a
        // different prompt is worth nothing and is not offered.
        let session = await CleanupSessionWarmer.shared.take(instructions: instructions)
            ?? LanguageModelSession(instructions: instructions)

        let response = try await session.respond(
            to: CleanupInstructions.user(text, fixesGrammar: fixesGrammar),
            options: GenerationOptions(
                // Near-deterministic: this is a formatting pass, not a creative one.
                temperature: 0.1,
                // Cleanup should never be much longer than the input; this bounds a runaway.
                maximumResponseTokens: 1_200
            )
        )

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
    static func timeout(for text: String) -> Duration {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let seconds = min(14.0, 4.0 + Double(words) * 0.07)
        return .seconds(seconds)
    }

    private enum CleanupError: LocalizedError {
        case timedOut
        var errorDescription: String? { "on-device cleanup timed out" }
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
    func stage(instructions: String) {
        guard FoundationModelFormatter.isAvailable else { return }
        guard !staged.contains(where: { $0.instructions == instructions }) else { return }
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
