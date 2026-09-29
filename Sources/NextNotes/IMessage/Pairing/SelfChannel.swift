import Foundation

/// IM-07 — the pure pairing decision, as a function of the row and the pairing state.
///
/// **A pure function, and the reason is the same as `IMessageClassifier`'s.** The
/// pairing decision is the one in the whole feature that must be testable without a
/// device, a grant or a live database: it is the gate that decides which conversation
/// becomes the command channel, and a bug here sends every message to the wrong place
/// or nowhere. So the decision is a function, the state is a value, and the self-test
/// drives both.
///
/// ## The filter IM-01's answer chose
///
/// IM-01 measured that a self-message arrives as **two rows** — `is_from_me` 1 and 0,
/// same body, same timestamp. So `is_from_me` cannot identify a self-message, and the
/// filter is **by chat, never by row**. The pairing decision is:
///
/// 1. The row's text is the trigger phrase.
/// 2. The row's `ROWID` is strictly greater than `pairingStartRowID` (the boundary is
///    exclusive — a row that landed before pairing started is not a pairing message).
/// 3. The chat is a **direct** self-conversation, not a group.
///
/// ## What "direct self-conversation" means, structurally
///
/// A `chat.guid` for a direct conversation is `iMessage;-;<address>` — the `-` is the
/// service's own marker for person-to-person. A group is `iMessage;+;<opaque id>`. So
/// the check is on the guid's shape, not on the participant count: IM-01 measured
/// `participants` empty on every chat in the capture, so a participant-count check
/// would refuse every chat including the right one.
enum SelfChannel {
    /// The trigger phrase. A constant rather than a parameter because it is the one
    /// string the whole feature agrees on, and a second copy is a second thing to drift.
    static let triggerPhrase = "Hi Next"

    /// How long the pairing window stays open. Five minutes is long enough for a person
    /// to pick up their phone and send the message, and short enough that a pairing
    /// attempt cannot sit open indefinitely.
    static let pairingWindow: TimeInterval = 300

    /// Whether a chat guid names a direct (1:1) conversation rather than a group.
    ///
    /// The `-` is the service's marker for person-to-person; `+` is a group. This is
    /// the only structural check available: IM-01 measured `participants` empty on
    /// every chat, so a participant-count check would refuse the right chat too.
    static func isDirectChat(_ guid: String) -> Bool {
        guid.contains(";-;")
    }

    /// Whether a row is a matching self-message for pairing.
    ///
    /// - Parameters:
    ///   - text: the row's `text` column, or nil when it is NULL.
    ///   - rowID: the row's `ROWID`.
    ///   - chatGUID: the chat's `guid`.
    ///   - pairingStartRowID: the `ROWID` recorded when pairing mode was entered.
    /// - Returns: `true` when all three conditions hold.
    static func isPairingMessage(text: String?,
                                 rowID: Int64,
                                 chatGUID: String,
                                 pairingStartRowID: Int64) -> Bool {
        guard text == triggerPhrase else { return false }
        guard rowID > pairingStartRowID else { return false }
        return isDirectChat(chatGUID)
    }

    /// Whether a chat guid is a group, which V1 refuses to pair.
    static func isGroupChat(_ guid: String) -> Bool {
        guid.contains(";+;")
    }

    /// The pairing decision for one row, as a value the self-test can assert on.
    enum PairingDecision: Equatable, Sendable {
        /// The row is a matching self-message inside the window.
        case matches
        /// The text is wrong.
        case wrongText
        /// The row is at or before the boundary.
        case outsideWindow
        /// The chat is a group, which V1 refuses.
        case groupChat
        /// The chat is neither direct nor group — an unrecognised shape.
        case unrecognisedChat
    }

    /// The decision, with the reason. Pure, so the self-test can assert on the reason
    /// rather than only on the boolean.
    static func decide(text: String?,
                       rowID: Int64,
                       chatGUID: String,
                       pairingStartRowID: Int64) -> PairingDecision {
        guard text == triggerPhrase else { return .wrongText }
        guard rowID > pairingStartRowID else { return .outsideWindow }
        if isGroupChat(chatGUID) { return .groupChat }
        if isDirectChat(chatGUID) { return .matches }
        return .unrecognisedChat
    }
}
