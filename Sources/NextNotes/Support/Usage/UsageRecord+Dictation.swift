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
        cleanupTimedOut: Bool,
        /// Seconds `start()` waited for the shared `.realtimeASR` lane (F-01), 0 when it did
        /// not wait. Defaulted so P0-20c's own call sites — and any row assembled before this
        /// existed — keep compiling and read 0.
        laneWait: Double = 0
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
                    // F-01: the queueing time, same meaning as a meeting window's laneWait.
                    "laneWait": laneWait,
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
            let answered = cleanupAnswerer(cleanup)
            let localAnswered = cleanup.enginesUsed == ["miniCPM"]
            // The last local attempt's phases ride beside the answerer's row under `local*`
            // keys, so a MiniCPM pass that handed off to Apple still says where it stood.
            let local = cleanup.localAttempts?.last
            rows.append(
                UsageRecord(
                    v: 1,
                    id: UUID(),
                    ts: now,
                    feature: UsageFeature.dictationCleanup.rawValue,
                    pass: "cleanup",
                    round: nil,
                    provider: answered.provider.rawValue,
                    modelID: answered.modelID,
                    locality: "local",
                    requestedRole: nil,
                    requestedModel: nil,
                    fallbackReason: cleanupFallback(cleanup.fallbackReason)?.rawValue,
                    // Apple's staged session for an Apple pass; the local model's
                    // residency when MiniCPM answered — never one standing in for the other.
                    warm: localAnswered ? cleanup.cleanupModelResident : cleanup.sessionPrewarmed,
                    loadMs: nil,
                    promptTokens: cleanup.promptTokens,
                    cachedTokens: cleanup.cachedTokens,
                    completionTokens: cleanup.completionTokens,
                    reasoningTokens: nil,
                    countsEstimated: nil,
                    ttftMs: localAnswered ? local?.firstTokenMs : nil,
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
                    stages: local.map(localStages),
                    counts: cleanupCounts(cleanup, local: local),
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

    /// Seconds per phase of the last local cleanup attempt (absent phases omitted).
    private static func localStages(_ local: CleanupLocalAttempt) -> [String: Double] {
        var stages: [String: Double] = ["localTotal": Double(local.totalMs) / 1_000]
        func put(_ key: String, _ ms: Int?) { if let ms { stages[key] = Double(ms) / 1_000 } }
        put("localAdmission", local.admissionMs)
        put("localPrefill", local.prefillMs)
        put("localParked", local.parkedMs)
        put("localFirstToken", local.firstTokenMs)
        put("localDecode", local.decodeMs)
        return stages
    }

    /// `chunks`, plus the last local attempt's counts. Numbers only: the outcome and phase
    /// words stay in `runs.jsonl`; here they are flags a report can sum.
    private static func cleanupCounts(
        _ cleanup: CleanupRecord, local: CleanupLocalAttempt?
    ) -> [String: Int]? {
        var counts: [String: Int] = [:]
        if let chunks = cleanup.chunks { counts["chunks"] = chunks }
        if let local {
            counts["localAttempts"] = cleanup.localAttempts?.count ?? 0
            counts["localTimedOut"] = local.outcome == "timedOut" ? 1 : 0
            counts["localPagedOut"] = local.outcome == "pagedOut" ? 1 : 0
            counts["localRefused"] = local.outcome == "refused" ? 1 : 0
            if let value = local.weightsResidentPermille { counts["localWeightsResidentPermille"] = value }
            if let value = local.promptTokens { counts["localPromptTokens"] = value }
            if let value = local.reusedTokens { counts["localReusedTokens"] = value }
            if let value = local.prefilledTokens { counts["localPrefilledTokens"] = value }
            if let value = local.generatedTokens { counts["localGeneratedTokens"] = value }
            if let value = local.contextRebuilt { counts["localContextRebuilt"] = value ? 1 : 0 }
        }
        return counts.isEmpty ? nil : counts
    }

    /// `CleanupRecord.engine`'s spellings, mapped to the provider vocabulary. `appLLM`'s
    /// legacy `qwen` spelling and a nil engine (a record with no formatter named yet) both
    /// land on the deterministic rules pass, which is what actually touched the text.
    private static func cleanupProvider(_ engine: String?) -> UsageProvider {
        switch engine {
        case "apple": .appleFM
        case "s1Mini": .s1mini
        case "appLLM", "qwen", "miniCPM": .llama
        default: .rules
        }
    }

    /// What actually answered, not what Settings chose: a rules-route run is `rules`
    /// whatever the engine setting says, and a MiniCPM pass that handed off to Apple is
    /// filed as Apple. Mixed chunked runs name every engine in `modelID`.
    private static func cleanupAnswerer(
        _ cleanup: CleanupRecord
    ) -> (provider: UsageProvider, modelID: String) {
        if cleanup.route == "rules" { return (.rules, UsageProvider.rules.rawValue) }
        if let used = cleanup.enginesUsed, let first = used.first {
            return (cleanupProvider(used.count == 1 ? first : cleanup.engine),
                    used.joined(separator: "+"))
        }
        return (cleanupProvider(cleanup.engine), cleanup.engine ?? UsageProvider.rules.rawValue)
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
