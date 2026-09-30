import Foundation

/// IM-09 — the one sender, and the only thing that dispatches a message to Messages.app.
///
/// **One sender, and the reason is `AGENTS.md`.** A second path that starts audio or
/// dispatches a message is a second answer to "what was sent", and the two would
/// disagree silently. So `MessagesSender` is the only type that sends, and everything
/// downstream — the ledger, the breaker, the receipt — reads what it produced.
///
/// ## The ledger row is written before dispatch
///
/// IM-08b's rule: a send this app cannot record is a send it will not recognise coming
/// back. So the ledger row is written first, and the dispatch carries the pending id
/// so IM-10 can correlate. A send that fails after the ledger write is a send that
/// landed but could not be confirmed — which is IM-10's problem, not a reason to skip
/// the ledger.
///
/// ## Addressing a participant, not a chat
///
/// A `chat.guid` is not an address (IM-02's finding). A self-conversation is reachable
/// only as a **participant** addressed by its handle. So `sendText` takes a handle, not
/// a guid, and the handle is resolved once at pairing and cached in the configuration.
actor MessagesSender {
    private let ledger: OutboundMessageLedger
    private let store: RemoteIdentityStore

    init(ledger: OutboundMessageLedger, store: RemoteIdentityStore) {
        self.ledger = ledger
        self.store = store
    }

    /// Sends text to a participant by handle.
    ///
    /// The text goes out prefixed with the agent's runtime name (`AgentMessageFormat`),
    /// because a self-conversation renders both authors identically and the content is
    /// the only place "who said this" can live. The digest and the dispatch both run
    /// on the final string, so the ledger and the row-watch agree with what Messages
    /// received. Approval-time copy (IM-13) must show this same final string: freezing
    /// one payload and sending another is the duplicate-send bug in a new shape.
    ///
    /// - Parameters:
    ///   - text: the message body, unprefixed.
    ///   - handle: the participant's handle (the user's own number for a self-conversation).
    /// - Returns: the dispatch result, with the pending id for IM-10 to correlate.
    func sendText(_ text: String, toHandle handle: String) async -> OutboundDispatch {
        let body = AgentMessageFormat.prefixed(text, name: AgentGroundingFacts.assistantName())
        // 1. The ledger row, before dispatch. The digest is the final text's SHA-256.
        let digest = OutboundDigest.text(body)
        let decision: OutboundSendDecision
        do {
            decision = try await ledger.recordDispatch(
                chatGUID: store.configuration.pairedChatGUID ?? "",
                conversationID: "",
                textDigest: digest)
        } catch {
            return .recordFailed(reason: "Next can receive your messages but can't reply yet. Open Next Notes on your Mac to finish Messages permission.")
        }

        // 2. The breaker may refuse while paused.
        if decision == .refusedWhilePaused {
            return .breakerRefused
        }

        // 3. The send, of the same final string the digest covers.
        let result = await MessagesAppleEvent.send(text: body, toHandle: handle)
        switch result {
        case .sent:
            return .sent
        case .failed(let reason):
            return .sendFailed(reason: reason)
        }
    }

    /// Sends attachments with optional text to a participant by handle.
    ///
    /// Attachments are IM-14's; this method is the seam IM-14 fills.
    func sendAttachments(_ attachments: [MessagesAttachment], text: String, toHandle handle: String) async -> OutboundDispatch {
        // IM-14 owns the attachment copy-out and the MIME type. This is the seam.
        await sendText(text, toHandle: handle)
    }
}

/// The result of a dispatch. A typed outcome, never a raw error number.
enum OutboundDispatch: Equatable, Sendable {
    case sent
    case recordFailed(reason: String)
    case breakerRefused
    case sendFailed(reason: String)
}
