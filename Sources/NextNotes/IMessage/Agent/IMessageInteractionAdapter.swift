import Foundation

/// IM-11 — the adapter: the bridge's candidate becomes an agent turn.
///
/// The chain is `IMessageBridge` → here → `RealtimeAgent.handle(_:source:
/// .iMessage)`. The agent does not care that the turn came through SQLite, and
/// the bridge does not know the agent exists: this actor is the only thing that
/// knows both, which is what makes it the seam a future `TaskBridge` owns
/// without moving any other line.
///
/// One adoption is exactly three things, in this order: the memory row
/// (`recordUser`, once per accepted command and never for an echo — echoes never
/// reach this type, they die in the bridge), the session resolution, and the
/// turn performed as `.iMessage`. The turn's source is `.iMessage` by
/// construction (`RemoteAgentTurn.source` is computed), so no path through here
/// can ask for speech: every voice gate in `handle` reads `source == .voice`.
///
/// Both seams are injected so the loop suite can pin the ordering without a
/// model, a session or a grant. `live()` binds the production pair.
actor IMessageInteractionAdapter {
    private let record: @Sendable (String) async -> Void
    private let perform: @Sendable (RemoteAgentTurn) async -> AgentTurn
    /// Whether remote processing is suspended ("stop remote access"). Read live on
    /// every adoption, so a suspension lands mid-conversation, not next launch.
    private let isSuspended: @Sendable () -> Bool
    private var mapper = IMessageConversationMapper()

    init(record: @escaping @Sendable (String) async -> Void,
         perform: @escaping @Sendable (RemoteAgentTurn) async -> AgentTurn,
         isSuspended: @escaping @Sendable () -> Bool = { false }) {
        self.record = record
        self.perform = perform
        self.isSuspended = isSuspended
    }

    /// Adopts one bridge candidate into the session's turn. A suspended feature
    /// answers with the paused sentence and nothing else: no memory row, no turn,
    /// no model — suspension stops processing, not just tools.
    func adopt(_ candidate: RemoteCandidate, chatGUID: String, currentSession: UUID) async -> AgentTurn {
        guard !isSuspended() else {
            return AgentTurn(reply: Self.suspendedReply, delegated: false)
        }
        await record(candidate.text)
        let session = mapper.resolve(chatGUID: chatGUID, currentSession: currentSession)
        return await perform(RemoteAgentTurn(text: candidate.text, chatGUID: chatGUID, sessionID: session))
    }

    /// Plain words, names the Mac path. The same sentence the broker denies tools
    /// with, so pausing reads as one state everywhere.
    static let suspendedReply = "Remote access is paused. Turn it back on in Settings on your Mac."

    /// The production pair: the one session's memory row and the one entry point.
    /// Suspension is re-read from disk on every adoption (a fresh store, not a
    /// cached one), so pausing takes effect while the process is still running.
    static func live() -> IMessageInteractionAdapter {
        IMessageInteractionAdapter(
            record: { await AgentSession.shared.recordUser($0, source: .iMessage) },
            perform: { await RealtimeAgent.shared.handle($0.text, source: $0.source) },
            isSuspended: {
                RemoteIdentityStore(directory: AppIdentity.applicationSupportDirectory)
                    .configuration.remoteAccessSuspended
            })
    }
}
