import Foundation

/// Dictation cleanup through the notes model — Qwen3.5-4B on the GPU.
///
/// The same 2.7 GB general instruction-following model that writes meeting notes, pointed
/// at one or two sentences instead of an hour of them. It is here because it is the only
/// model on this Mac that can be *told* what to do in prose, which is what open-ended
/// grammar repair needs; S1-mini cannot be told anything (see `S1MiniFormatter`) and
/// Apple's model is smaller.
///
/// It is not the default, and the reason is latency rather than quality. Two costs land on
/// a person holding a key:
///
/// - **Cold start.** The weights unload after ten idle minutes (`NotesModelRuntime`), so
///   the first dictation after a quiet stretch pays a multi-second load. Dictation is
///   bursty and quiet stretches are the normal case.
/// - **Generation.** Cleanup regenerates the whole utterance, so the cost scales with what
///   was said, at this model's tokens-per-second rather than a 0.6B's.
///
/// Both are bounded by `timeout`, after which the rule-based output is used — a person who
/// released the key three seconds ago needs text, not a better sentence. Every number
/// behind this paragraph comes from `--selftest-cleanup qwen`.
struct QwenCleanupFormatter: TextFormatter {
    private let fallback = RuleBasedFormatter()
    private let preferences: CleanupPreferences
    private let fixesGrammar: Bool
    /// Longer than Apple's four seconds because this model is slower and the user opted
    /// into that, but still a bound: dictation stops being interactive somewhere around
    /// here, and past it the raw words beat a better sentence.
    private let timeout: Duration

    init(
        preferences: CleanupPreferences,
        fixesGrammar: Bool = true,
        timeout: Duration = .seconds(8)
    ) {
        self.preferences = preferences
        self.fixesGrammar = fixesGrammar
        self.timeout = timeout
    }

    static var isAvailable: Bool { NotesModels.isDownloaded }

    static var unavailableReason: String? {
        NotesModels.isDownloaded
            ? nil
            : "\(NotesModels.spec.displayName) isn\u{2019}t downloaded (\(NotesModels.spec.displaySize))."
    }

    func format(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard Self.isAvailable else {
            Log.speech.info("Qwen cleanup unavailable — using rule-based cleanup")
            return await fallback.format(trimmed)
        }

        do {
            let cleaned = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await Self.generate(
                        trimmed,
                        preferences: preferences,
                        fixesGrammar: fixesGrammar
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CleanupError.timedOut
                }
                guard let first = try await group.next() else { throw CleanupError.timedOut }
                // Cancels the generation loop, which checks for it once per token.
                group.cancelAll()
                return first
            }

            if let reason = CleanupGuard.rejection(
                original: trimmed,
                cleaned: cleaned,
                mode: CleanupInstructions.mode(fixesGrammar: fixesGrammar)
            ) {
                Log.speech.info("Qwen cleanup rejected — \(reason, privacy: .public)")
                return await fallback.format(trimmed)
            }
            return cleaned
        } catch {
            Log.speech.info("Qwen cleanup failed (\(error.localizedDescription, privacy: .public)) — falling back")
            return await fallback.format(trimmed)
        }
    }

    /// Deliberately does NOT announce itself to `LlamaBackend`'s cleanup gate.
    ///
    /// It did, by analogy with `S1MiniRuntime.normalize`, and it deadlocked on the first
    /// call — the process sat for three hours on 2 seconds of CPU, holding 29 MB against a
    /// 2.74 GB model it never loaded.
    ///
    /// The gate is one-directional by design: the notes model waits for dictation cleanup to
    /// finish before loading, so two different sets of weights never load at once on a 16 GB
    /// machine. `NotesModelRuntime.loadIfNeeded` calls `awaitCleanupIdle()`. So calling
    /// `beginCleanup()` here and then asking that same runtime to complete closed the cycle:
    /// the load waited for a cleanup count that only `endCleanup()` clears, and `endCleanup()`
    /// runs after the load returns.
    ///
    /// There is nothing for the gate to protect here anyway. It exists to keep *two different
    /// models* off the memory bus simultaneously, and this cleanup is the notes model — the
    /// same weights, behind the same actor, which already serialises them.
    static func generate(
        _ text: String,
        preferences: CleanupPreferences,
        fixesGrammar: Bool
    ) async throws -> String {
        let completion = try await NotesModelRuntime.shared.complete(
            system: CleanupInstructions.system(for: preferences, fixesGrammar: fixesGrammar),
            user: CleanupInstructions.user(text, fixesGrammar: fixesGrammar),
            // Cleanup is never much longer than what was said. Budgeted from the input
            // rather than fixed, so a five-word utterance can't spend a thousand tokens
            // wandering — and clamped, because the guard's length rule would throw away
            // anything that ran that far anyway.
            maxTokens: maxTokens(for: text)
        )
        return completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Roughly two tokens per spoken word, doubled for headroom, floor 64, ceiling 1200.
    static func maxTokens(for text: String) -> Int {
        let words = text.split { $0 == " " || $0 == "\n" }.count
        return min(1_200, max(64, words * 4))
    }

    private enum CleanupError: LocalizedError {
        case timedOut
        var errorDescription: String? { "Qwen cleanup timed out" }
    }
}
