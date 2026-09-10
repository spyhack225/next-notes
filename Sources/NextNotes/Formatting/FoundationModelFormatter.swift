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

    /// Past this, taking the raw text beats making the user wait.
    private let timeout: Duration = .seconds(4)
    private let preferences: CleanupPreferences

    /// Whether the pass also repairs grammar, or only punctuation and fillers.
    ///
    /// It changes two things, and neither of them is a second model call: the instructions
    /// gain a block of grammar rules, and the output guard switches from "no new content
    /// words at all" to "every new word must be traceable to one that was dropped". Same
    /// session, same token budget, same timeout — which is why grammar is free here rather
    /// than a trade against latency. `--selftest-cleanup` is where that claim is checked.
    private let fixesGrammar: Bool
    /// What the receiving app can render. Plain unless a caller says otherwise.
    private let target: OutputProfile

    init(
        preferences: CleanupPreferences = CleanupPreferences(
            tone: .balanced,
            formatsLists: true,
            context: .general
        ),
        fixesGrammar: Bool = false,
        target: OutputProfile = .plain(bundleID: "", displayName: "the focused app"),
        fallback: any TextFormatter = RuleBasedFormatter()
    ) {
        self.target = target
        self.preferences = preferences
        self.fixesGrammar = fixesGrammar
        self.fallback = fallback
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
            return await fallback.format(trimmed)
        }

        do {
            let cleaned = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await Self.clean(
                        trimmed,
                        preferences: preferences,
                        fixesGrammar: fixesGrammar,
                        target: target
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
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
                Log.speech.info("Foundation model output rejected — \(reason, privacy: .public)")
                return await fallback.format(trimmed)
            }
            return cleaned
        } catch {
            Log.speech.info("Foundation model cleanup failed (\(Self.describe(error), privacy: .public)) — falling back")
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
        target: OutputProfile = .plain(bundleID: "", displayName: "the focused app")
    ) async throws -> String {
        let session = LanguageModelSession(
            instructions: CleanupInstructions.system(
                for: preferences,
                fixesGrammar: fixesGrammar,
                target: target
            )
        )

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

    private enum CleanupError: LocalizedError {
        case timedOut
        var errorDescription: String? { "on-device cleanup timed out" }
    }
}
