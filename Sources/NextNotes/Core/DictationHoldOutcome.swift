import Foundation

/// How one hold ended. The fixed vocabulary D-01b files exactly one `dictation.hold`
/// row with — `errorClass` nil for the two successes, one of the fixed strings
/// otherwise, so the stats script can group outcomes without parsing anything.
enum DictationHoldResult: Equatable, Sendable {
    case inserted
    /// The setting asked for the clipboard, so it is a success.
    case copied
    /// Command Mode's normal end.
    case command
    /// Compare mode's normal end.
    case compare
    case cancelled
    /// No speech and no words — the quiet end (D-03's silence half).
    case empty
    /// Speech energy but no words (D-03): the hold says so instead of going quiet.
    case emptySpeech
    /// Released within 0.3 s of key-down, or fewer than 4,800 samples captured.
    case tap
    /// Released in `.starting` and the hold was lost. D-02 transcribes the pre-roll
    /// instead, so no production path reaches this today; the class stays in the
    /// vocabulary the stats script groups by.
    case lostAtStartup
    case failed(Cause)

    /// The causes `fail` takes explicitly at every call site — never parsed out of
    /// the message (D-01b's rule: the message is written for the user, the cause is
    /// decided where the failure is known).
    enum Cause: String, Sendable {
        case micPermission, startup, startupTimeout, subscribe, noAudio
        case engine, transcribeTimeout, couldNotReturn
    }

    /// nil for the two successes; the error class otherwise.
    var errorClass: String? {
        switch self {
        case .inserted, .copied: nil
        case .command: "command"
        case .compare: "compare"
        case .cancelled: "cancelled"
        case .empty: "empty"
        case .emptySpeech: "emptySpeech"
        case .tap: "tap"
        case .lostAtStartup: "lostAtStartup"
        case .failed(let cause): "failed:\(cause.rawValue)"
        }
    }
}

/// One hold's outcome, as the controller's `outcome:` sink receives it (D-01b).
///
/// No transcript text, no app name, no clipboard content rides on this — the counts
/// are numbers and the result is an enum, which is what keeps the row private by
/// construction rather than by discipline.
struct DictationHoldOutcome: Sendable, Equatable {
    /// Minted at key-down. The tail mints its run id from this same id, so one id
    /// joins `runs.jsonl`, the P0-20c rows and this row.
    var holdID: UUID
    var result: DictationHoldResult
    /// Key-up → outcome. nil where there was no key-up to measure from: the
    /// `lostAtStartup` and `cancelled` classes, and a hold failed while the key
    /// was still down.
    var keyUpToOutcome: Duration?
    var counts: [String: Int]
    /// The engine that ran — or was armed to run — this hold.
    var engine: SpeechEngineChoice
}

extension DictationHoldOutcome {
    /// The one mapping onto P0-20a's row. Field names follow P0-20a; adapted here only.
    func usageRecord(now: Date = Date()) -> UsageRecord {
        UsageRecord(
            v: 1,
            id: UUID(),
            ts: now,
            feature: UsageFeature.dictationHold.rawValue,
            pass: "hold",
            provider: engine == .apple
                ? UsageProvider.appleSpeech.rawValue
                : UsageProvider.parakeet.rawValue,
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
            totalMs: keyUpToOutcome.map(Self.milliseconds) ?? 0,
            tokensPerSec: nil,
            finishReason: nil,
            truncated: nil,
            toolsProposed: nil,
            toolsExecuted: nil,
            errorClass: result.errorClass,
            errorMessage: nil,
            audioSeconds: nil,
            realtimeFactor: nil,
            stages: nil,
            counts: counts.isEmpty ? nil : counts,
            turnID: nil,
            conversationID: nil,
            workID: nil,
            revision: nil,
            meetingID: nil,
            dictationRunID: holdID,
            scheduleID: nil
        )
    }

    /// The one row a refused press writes (`feature = "dictation.press_refused"`):
    /// `errorClass` is the state the press hit — `starting`, `listening` or
    /// `finishing` (D-05 made `.error` startable) — and `counts` carries
    /// `sinceKeyUpMs` for `.finishing`. The row joins the hold it was refused
    /// against through the same correlation id.
    static func pressRefusedRecord(
        state: String,
        counts: [String: Int],
        engine: SpeechEngineChoice,
        holdID: UUID,
        now: Date = Date()
    ) -> UsageRecord {
        UsageRecord(
            v: 1,
            id: UUID(),
            ts: now,
            feature: UsageFeature.dictationPressRefused.rawValue,
            pass: "press",
            provider: engine == .apple
                ? UsageProvider.appleSpeech.rawValue
                : UsageProvider.parakeet.rawValue,
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
            totalMs: 0,
            tokensPerSec: nil,
            finishReason: nil,
            truncated: nil,
            toolsProposed: nil,
            toolsExecuted: nil,
            errorClass: state,
            errorMessage: nil,
            audioSeconds: nil,
            realtimeFactor: nil,
            stages: nil,
            counts: counts.isEmpty ? nil : counts,
            turnID: nil,
            conversationID: nil,
            workID: nil,
            revision: nil,
            meetingID: nil,
            dictationRunID: holdID,
            scheduleID: nil
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return max(0, Int((Double(seconds) * 1_000 + Double(attoseconds) / 1e15).rounded()))
    }
}