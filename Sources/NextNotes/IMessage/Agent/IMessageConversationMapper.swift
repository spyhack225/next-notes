import Foundation

/// IM-11 — which session a remote turn joins.
///
/// One session, several transports: a turn that starts by voice and continues by
/// text is the same task, not two. So every turn on a chat resolves to the
/// session that chat was last seen in — and when that session has ended (the
/// session id moved on), the chat rebinds to the current one rather than
/// addressing a session that is over.
///
/// A value, not a store: the bindings live in the adapter that owns this mapper,
/// die with the process, and are rebuilt from the live session. Nothing is
/// persisted, because a persisted chat→session map is a second conversation
/// model, and the task forbids one.
///
/// Only chat guids and session ids are kept — opaque handles, never text — and
/// at most `bindingLimit` of them, so a machine that never quits does not keep
/// a row per conversation forever.
struct IMessageConversationMapper: Sendable {
    /// How many chats stay bound. Far above V1's one paired chat, bounded so the
    /// memory is bounded.
    static let bindingLimit = 32

    /// Most recently seen first.
    private var bindings: [(chatGUID: String, session: UUID)] = []

    /// Resolves a chat to its session: the bound one while it is current, the
    /// current one otherwise (rebinding as it does).
    mutating func resolve(chatGUID: String, currentSession: UUID) -> UUID {
        if let index = bindings.firstIndex(where: { $0.chatGUID == chatGUID }) {
            let bound = bindings.remove(at: index)
            bindings.insert(bound, at: 0)
            if bound.session == currentSession { return bound.session }
        }
        bindings.insert((chatGUID, currentSession), at: 0)
        while bindings.count > Self.bindingLimit { bindings.removeLast() }
        return currentSession
    }
}
