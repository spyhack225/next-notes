import Foundation

/// IM-08d — the bridge: the one actor that turns a watcher delivery into exactly one of
/// a candidate, a ledger match, a count or a card.
///
/// **The one actor, and the reason is `AGENTS.md`.** A second consumer of the watcher's
/// deliveries would be a second answer to "what happened to this message", and the two
/// would disagree silently. So the bridge is the only thing that subscribes to the
/// watcher, and everything downstream — IM-11's adapter, IM-17f's status row, the report —
/// reads what the bridge produced.
///
/// ## What it does not do
///
/// **It does not call `RealtimeAgent` and it does not own a conversation.** The adapter
/// is IM-11's, the session is the one session, and the bridge hands over a value. A
/// finished feature with no call site looks exactly like a working one, and the seam
/// here is deliberately thin enough that IM-11 has something to attach to.
///
/// ## The command fingerprint
///
/// IM-01 measured that a self-message arrives as two rows. The watcher's guid cache
/// collapses them when they arrive together, but a relaunch between the two copies
/// leaves the cache empty and the second copy is a second command. The bridge keeps a
/// bounded in-memory set of recent command fingerprints — a digest of the text, never
/// the text — and a row whose fingerprint is already in the set is not a second turn.
/// This is not a second mechanism for the guid cache; it is the one place the collapse
/// is not allowed to be the only defence.
actor IMessageBridge {
    private let ledger: OutboundMessageLedger
    private let store: RemoteIdentityStore
    private let onCandidate: @Sendable (RemoteCandidate) async -> Void
    private let onCard: @Sendable (IMessageLocalNotice) async -> Void
    /// IM-15 — voice notes: `(messageROWID, chatGUID) -> transcript`, or nil when
    /// unwired. Consulted only for `.notText` rows, after the ledger check: a
    /// transcript re-enters below as the row's words, and a nil/empty answer
    /// leaves the row on the refusal path it already had. Nil by default, so
    /// every existing construction — and every existing case — behaves exactly
    /// as before until a host binds the reader, the copier and the transcriber.
    private let voiceNoteText: (@Sendable (Int64, String) async -> String?)?

    /// Recent command fingerprints, bounded so a machine that never quits does not keep
    /// a set per message forever. A digest of the text, never the text itself.
    private var recentFingerprints: [Data] = []
    private let fingerprintLimit = 64

    /// Foreign rows seen since the last card, for the "forty rows in a row yield one
    /// card and a count of forty" rule.
    private var foreignCount = 0

    init(ledger: OutboundMessageLedger,
          store: RemoteIdentityStore,
          onCandidate: @escaping @Sendable (RemoteCandidate) async -> Void,
          onCard: @escaping @Sendable (IMessageLocalNotice) async -> Void,
          voiceNoteText: (@Sendable (Int64, String) async -> String?)? = nil) {
        self.ledger = ledger
        self.store = store
        self.onCandidate = onCandidate
        self.onCard = onCard
        self.voiceNoteText = voiceNoteText
    }

    /// Handles one watcher delivery. The one entry point, and the only place a delivery
    /// is turned into something.
    func handle(delivery: MessagesWatcherDelivery) async {
        let envelope = delivery.envelope
        let config = store.configuration

        // 1. The ledger, first and alone. A matched echo is ours whatever the body says.
        let candidate = OutboundEchoCandidate(
            rowID: envelope.rowID,
            messageGUID: envelope.guid,
            chatGUID: delivery.chatGUID,
            textDigest: OutboundDigest.text(envelope.text ?? ""),
            attachmentDigests: [],
            date: envelope.date ?? 0)
        let echo = try? await ledger.verdict(for: candidate)
        if echo == .ownEcho {
            return
        }

        // 2. The body. A voice note re-enters here as its transcript: the row's
        // own words, read through the injected path, take the place of a body
        // Messages never wrote as text. Anything else keeps the decoded body.
        var body = envelope.body
        if case .notText = body,
           let voiceText = await voiceNoteText?(envelope.rowID, delivery.chatGUID),
           !voiceText.isEmpty {
            body = .text(voiceText, discardedBytes: 0)
        }
        let text = bodyText(body)

        // 3. The classifier. Needs the body, the column, the resolved sender and the
        //    ledger's answer — and nothing else.
        let sender = IMessageDirectionResolver.resolve(
            senderHandle: delivery.senderHandle,
            localIdentity: config.localIdentity.flatMap { RemoteIdentity(raw: $0) })
        let classification = IMessageClassifier.classify(
            body: body,
            isFromMe: envelope.isFromMe,
            sender: sender,
            echo: echo ?? .notOurEcho)

        // 4. The class decides what happens next.
        switch classification.messageClass {
        case .userCommand:
            // The command fingerprint: a row whose text is already in the set is not a
            // second turn. This is the two-row measurement's second defence.
            let fingerprint = OutboundDigest.text(text)
            if recentFingerprints.contains(fingerprint) { return }
            recentFingerprints.append(fingerprint)
            if recentFingerprints.count > fingerprintLimit {
                recentFingerprints.removeFirst(fingerprintLimit)
            }
            // A user command resumes the breaker and is the only thing that does.
            await ledger.noteUserCommand()
            // The "Last request" line's clock: stamped when a command is
            // accepted, never on echoes, refusals or foreign rows.
            try? store.update { $0.lastInboundCommandAt = Date().timeIntervalSince1970 }
            await onCandidate(RemoteCandidate(
                text: text,
                classification: classification,
                envelope: envelope))

        case .fromSomebodyElse:
            // Forty foreign rows in a row yield one card and a count of forty.
            foreignCount += 1
            if foreignCount == 1 {
                await onCard(classification.directionEvidence == DirectionEvidence.unresolved
                             ? .senderUnresolved : .notFromYou)
            foreignCount += 1
            }

        case .userSentSomethingElse, .couldNotRead, .nothingToRead, .ownEcho:
            // Nothing on either side. A refusal says nothing on the remote side and
            // everything on the local side, and these are not a stranger's row.
            return
        }
    }

    /// The number of foreign rows seen since the last card. For the report.
    var foreignRowCount: Int { foreignCount }

    /// The row's words: the transcript when a voice note re-entered, otherwise
    /// whatever the decoder read. One place, so the fingerprint and the candidate
    /// can never disagree about which string they carry.
    private func bodyText(_ body: MessageBody) -> String {
        if case .text(let value, _) = body { return value }
        return ""
    }

    /// Resets the foreign row count. Called after a card is shown.
    func resetForeignCount() { foreignCount = 0 }
}

/// One remote turn, handed to IM-11's adapter. The bridge's output, and the only thing
/// IM-11 needs to attach to.
struct RemoteCandidate: Equatable, Sendable {
    /// The sender's own words. The only text in the candidate, and the only thing the
    /// adapter needs to start a turn.
    var text: String
    /// What the classifier decided. The adapter reads this to know what it has.
    var classification: IMessageClassification
    /// The envelope, for the adapter to read the body, the source and the attachments.
    var envelope: IMessageEnvelope
}
