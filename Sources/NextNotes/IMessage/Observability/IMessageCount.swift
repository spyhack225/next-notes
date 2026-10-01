import Foundation

/// IM-17d — the closed vocabulary for iMessage metrics.
///
/// `counts` on a usage row is `[String: Int]`, and a stringly-typed counter is
/// how a typo becomes a second series nobody aggregates. So the permitted keys
/// are an enum: a typo is a compile error and a new fact needs a new case on
/// purpose. `stages` (durations) gets the same treatment.
///
/// The tables are §3.2's, verbatim in structure: which keys each `pass` may
/// carry, and the three stage names the phase file means by "send verification
/// latency" and "sync-to-agent latency".
enum IMessageCount: String, Sendable, CaseIterable {
    // MARK: inbound — a row detected, classified, answered or dropped
    case detected
    case accepted
    case refused
    case unreadable
    case notText
    case noBody
    case notPaired
    case echoMatched
    case loopSuppressed
    case discardedAttributes
    // MARK: outbound — a send dispatched, verified, approved or held
    case sent
    case sendVerified
    case sendUnverified
    case sendingSuppressed
    case approvalGranted
    case approvalDenied
    case localConfirmationRequired
    // MARK: consent — the sheet's own outcomes
    case granted
    case declined
    case dismissed
}

/// The three passes an `imessage.event` row comes from.
enum IMessagePass: String, Sendable, CaseIterable {
    case inbound
    case outbound
    case consent
}

/// Named sub-stage seconds. Only durations — never text, never counts.
enum IMessageStage: String, Sendable, CaseIterable {
    /// Row detected → the agent was handed the turn.
    case syncToAgent
    /// Apple Event sent → the row appeared.
    case dispatchToVerify
    /// Row appeared → `ActionReceipt`.
    case verifyToReceipt
}

extension IMessagePass {
    /// The `counts` keys this pass may carry. Anything else is refused at
    /// construction, which is what keeps a future caller from inventing a
    /// series the report never aggregates.
    var permittedCounts: Set<IMessageCount> {
        switch self {
        case .inbound:
            [.detected, .accepted, .refused, .unreadable, .notText, .noBody,
             .notPaired, .echoMatched, .loopSuppressed, .discardedAttributes]
        case .outbound:
            [.sent, .sendVerified, .sendUnverified, .sendingSuppressed,
             .approvalGranted, .approvalDenied, .localConfirmationRequired]
        case .consent:
            [.granted, .declined, .dismissed]
        }
    }

    /// The pass word the row carries.
    var passWord: String {
        switch self {
        case .inbound: "inbound"
        case .outbound: "outbound"
        case .consent: "consent"
        }
    }
}
