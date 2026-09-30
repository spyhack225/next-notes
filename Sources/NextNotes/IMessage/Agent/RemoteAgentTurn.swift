import Foundation

/// IM-11 — one remote turn, as the adapter hands it to the agent.
///
/// The bridge outputs a `RemoteCandidate`; the adapter resolves its session and
/// performs it through `RealtimeAgent.handle`. This is the value between them:
/// the sender's text, the chat it arrived in, and the session it joins.
///
/// `source` is a computed `.iMessage`, not a stored field, so no call site can
/// construct a remote turn that routes as voice. A remote turn answered by text
/// and never spoken aloud is then a property of the type, not a convention the
/// next caller has to remember.
struct RemoteAgentTurn: Equatable, Sendable {
    /// The sender's own words.
    var text: String
    /// The `chat.guid` the turn arrived in. An opaque handle, never logged.
    var chatGUID: String
    /// The session this turn joins, resolved by `IMessageConversationMapper`.
    var sessionID: UUID
    /// Always `.iMessage`.
    var source: AgentUtteranceSource { .iMessage }
}
