import Foundation

/// IM-17d — the only writer of iMessage metrics rows.
///
/// `usage.jsonl` never leaves the Mac, and still no row may hold a prompt, a
/// reply, a transcript, dictated text, a tool argument, a file name, an
/// address, a subject or a URL — and, for this feature specifically, no
/// character count, no text hash, no attachment name, and never a
/// `chatGUID` or `messageGUID` (Apple's ids; `sanitise` would not save them).
/// Enforcement is at construction, because at sanitisation it is already too
/// late: this builder takes **no text parameter at all** — its only
/// failure-related inputs are a `UsageErrorClass` and the decode-failure case
/// the report prints, never a string. `errorMessage` is absent on every row it
/// builds, and there is no parameter that could put a GUID, a count of
/// characters or a filename into one, because the parameters do not include
/// one. A third party's promotional offer survives `sanitise` untouched, which
/// is why the offer has nowhere to enter here.
enum IMessageUsage {
    /// Builds one `imessage.event` row: a transport event that ran no model.
    /// Provider `rules`, model `none`, every token field `nil`; `totalMs` is
    /// the event's own duration.
    ///
    /// - Parameters:
    ///   - pass: which table the counts come from; keys outside it are refused.
    ///   - counts: event counters, keyed by the closed vocabulary.
    ///   - stages: sub-stage durations, if measured.
    ///   - turnID/conversationID/workID: this app's own ids, for joining a row
    ///     to a job. Apple's ids have no parameter and cannot be written.
    ///   - totalMs: the event's own duration.
    ///   - errorClass: `.parse` for an undecodable body and friends, never prose.
    /// - Returns: nil when a count key does not belong to the pass. A refused
    ///   row is never half-written: callers treat nil as "do not record".
    static func event(pass: IMessagePass,
                      counts: [IMessageCount: Int],
                      stages: [IMessageStage: Double]? = nil,
                      turnID: UUID? = nil,
                      conversationID: UUID? = nil,
                      workID: UUID? = nil,
                      totalMs: Int,
                      errorClass: UsageErrorClass? = nil) -> UsageRecord? {
        guard counts.keys.allSatisfy({ pass.permittedCounts.contains($0) }) else {
            return nil
        }
        return UsageRecord(
            v: 1,
            id: UUID(),
            ts: Date(),
            feature: UsageFeature.imessageEvent.rawValue,
            pass: pass.passWord,
            round: nil,
            provider: UsageProvider.rules.rawValue,
            modelID: "none",
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
            totalMs: totalMs,
            tokensPerSec: nil,
            finishReason: nil,
            truncated: nil,
            toolsProposed: nil,
            toolsExecuted: nil,
            errorClass: errorClass?.rawValue,
            errorMessage: nil,
            audioSeconds: nil,
            realtimeFactor: nil,
            stages: stages.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) },
            counts: Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }),
            turnID: turnID,
            conversationID: conversationID,
            workID: workID,
            revision: nil,
            meetingID: nil,
            dictationRunID: nil,
            scheduleID: nil
        )
    }
}
