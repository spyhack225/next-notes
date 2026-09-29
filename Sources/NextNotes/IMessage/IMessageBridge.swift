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
         onCard: @escaping @Sendable (IMessageLocalNotice) async -> Void) {
        self.ledger = ledger
        self.store = store
        self.onCandidate = onCandidate
        self.onCard = onCard
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

        // 2. The classifier. Needs the body, the column, the resolved sender and the
        //    ledger's answer — and nothing else.
        let sender = IMessageDirectionResolver.resolve(
            senderHandle: delivery.senderHandle,
            localIdentity: config.localIdentity.flatMap { RemoteIdentity(raw: $0) })
        let classification = IMessageClassifier.classify(
            body: envelope.body,
            isFromMe: envelope.isFromMe,
            sender: sender,
            echo: echo ?? .notOurEcho)

        // 3. The class decides what happens next.
        switch classification.messageClass {
        case .userCommand:
            // The command fingerprint: a row whose text is already in the set is not a
            // second turn. This is the two-row measurement's second defence.
            let fingerprint = OutboundDigest.text(envelope.text ?? "")
            if recentFingerprints.contains(fingerprint) { return }
            recentFingerprints.append(fingerprint)
            if recentFingerprints.count > fingerprintLimit {
                recentFingerprints.removeFirst(recentFingerprints.count - fingerprintLimit)
            }
            // A user command resumes the breaker and is the only thing that does.
            await ledger.noteUserCommand()
            await onCandidate(RemoteCandidate(
                text: envelope.text ?? "",
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
