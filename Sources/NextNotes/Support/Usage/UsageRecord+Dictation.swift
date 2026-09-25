import Foundation

/// P0-20c's pure dictation rows, as an extension of `UsageRecord`.
///
/// One finished dictation files one `dictation.asr` row (the speech engine and the tail
/// split) and, when a cleanup pass ran, one `dictation.cleanup` row. The builder is pure so
/// `--selftest-usage-log` can check the shape without a microphone; `DictationController`
/// calls it once per run and records the rows against the same `DictationRun.id` that
/// `runs.jsonl` files.
///
/// The stage numbers are the tail's own (`drain`, `transcribe`, `names`, `cleanup`,
/// `inject` — the same values the `dictation tail ·` info line prints), never a second
/// clock. `totalMs` for the engine row is drain + transcribe, the wait the user actually
/// paid before the cleanup pass. Nothing here carries the dictated text, the raw
/// transcript, the target app or the cleanup's free-text reason: the cleanup row's
/// `fallbackReason` is a `UsageFallback` class or nil, never the reason itself.
extension UsageRecord {
    /// The two rows one finished dictation writes. `cleanup` nil means no cleanup pass ran,
    /// so no cleanup row is produced.
    ///
    /// - `drained`, `transcribedAt`, `narrowedAt` and `cleanedAt` are cumulative seconds
    ///   from the tail's start; the row's stages are the differences between them.
    /// - `transcribed` false means the engine hit its deadline: the row says
    ///   `finishReason: "timeout"` and `truncated: true`.
    /// - `cleanupTimedOut` sets the cleanup row's `finishReason` the same way.
    static func dictationRows(
        runID: UUID,
        engine: SpeechEngineChoice,
        audioSeconds: Double,
        drained: Double,
        transcribedAt: Double,
        narrowedAt: Double,
        cleanedAt: Double,
        injectSeconds: Double,
        transcribed: Bool,
        cleanup: CleanupRecord?,
        cleanupTimedOut: Bool
    ) -> [UsageRecord] {
        let now = Date()
        var rows: [UsageRecord] = []
        rows.append(
            UsageRecord(
                v: 1,
                id: UUID(),
                ts: now,
                feature: UsageFeature.dictationASR.rawValue,
                pass: "engine",
                round: nil,
                provider: engineProvider(engine).rawValue,
                modelID: engine.rawValue,
                locality: "local",
                requestedRole: nil,
                requestedModel: nil,
                fallbackReason: nil,
                warm: nil,
                loadMs: nil,
                promptTokens: nil,
                cachedTokens: nil,
                completionTokens: nil,
                reasoningTokens: nil,
                countsEstimated: nil,
                ttftMs: nil,
                totalMs: milliseconds(transcribedAt),
                tokensPerSec: nil,
                finishReason: transcribed ? "stop" : "timeout",
                truncated: !transcribed,
                toolsProposed: nil,
                toolsExecuted: nil,
                errorClass: transcribed ? nil : UsageErrorClass.timeout.rawValue,
                errorMessage: nil,
                audioSeconds: audioSeconds,
                realtimeFactor: nil,
                stages: [
                    "drain": drained,
                    "transcribe": transcribedAt - drained,
                    "names": narrowedAt - transcribedAt,
                    "cleanup": cleanedAt - narrowedAt,
                    "inject": injectSeconds,
                ],
                counts: nil,
                turnID: nil,
                conversationID: nil,
                workID: nil,
                revision: nil,
                meetingID: nil,
                dictationRunID: runID,
                scheduleID: nil
            )
        )
        if let cleanup {
            rows.append(
                UsageRecord(
                    v: 1,
                    id: UUID(),
                    ts: now,
                    feature: UsageFeature.dictationCleanup.rawValue,
                    pass: "cleanup",
                    round: nil,
                    provider: cleanupProvider(cleanup.engine).rawValue,
                    modelID: cleanup.engine ?? UsageProvider.rules.rawValue,
                    locality: "local",
                    requestedRole: nil,
                    requestedModel: nil,
                    fallbackReason: cleanupFallback(cleanup.fallbackReason)?.rawValue,
                    warm: cleanup.sessionPrewarmed,
                    loadMs: nil,
                    promptTokens: nil,
                    cachedTokens: nil,
                    completionTokens: nil,
                    reasoningTokens: nil,
                    countsEstimated: nil,
                    ttftMs: nil,
                    totalMs: milliseconds(cleanedAt - narrowedAt),
                    tokensPerSec: nil,
                    finishReason: cleanupTimedOut ? "timeout" : "stop",
                    truncated: cleanupTimedOut,
                    toolsProposed: nil,
                    toolsExecuted: nil,
                    errorClass: cleanupTimedOut ? UsageErrorClass.timeout.rawValue : nil,
                    errorMessage: nil,
                    audioSeconds: nil,
                    realtimeFactor: nil,
                    stages: nil,
                    counts: cleanup.chunks.map { ["chunks": $0] },
                    turnID: nil,
                    conversationID: nil,
                    workID: nil,
                    revision: nil,
                    meetingID: nil,
                    dictationRunID: runID,
                    scheduleID: nil
                )
            )
        }
        return rows
    }

    /// `CleanupRecord.engine`'s spellings, mapped to the provider vocabulary. `appLLM`'s
    /// legacy `qwen` spelling and a nil engine (a record with no formatter named yet) both
    /// land on the deterministic rules pass, which is what actually touched the text.
    private static func cleanupProvider(_ engine: String?) -> UsageProvider {
        switch engine {
        case "apple": .appleFM
        case "s1Mini": .s1mini
        case "appLLM", "qwen": .llama
        default: .rules
        }
    }

    private static func engineProvider(_ engine: SpeechEngineChoice) -> UsageProvider {
        switch engine {
        case .apple: .appleSpeech
        case .parakeet: .parakeet
        }
    }

    /// A `CleanupRecord.fallbackReason` is free text written for the person reading the
    /// Dictation row. Only the reasons that name a class the usage vocabulary already has
    /// are carried; a guard rejection that matches none stays nil rather than being
    /// mislabelled, and `finishReason` carries the timeout.
    private static func cleanupFallback(_ reason: String?) -> UsageFallback? {
        guard let reason = reason?.lowercased() else { return nil }
        if reason.contains("not downloaded") || reason.contains("unavailable")
            || reason.contains("no model") {
            return .modelUnavailable
        }
        if reason.contains("could not load") || reason.contains("failed to load")
            || reason.contains("would not load") {
            return .loadFailed
        }
        if reason.contains("consent") { return .consent }
        if reason.contains("busy") { return .busy }
        if reason.contains("no key") || reason.contains("api key") { return .noKey }
        return nil
    }

    private static func milliseconds(_ seconds: Double) -> Int {
        max(0, Int((seconds * 1_000).rounded()))
    }
}
