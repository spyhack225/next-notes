import Foundation

/// IM-08c — whether a chat is the self channel, as a pure function.
///
/// **A pure function, and the reason is the same as `IMessageClassifier`'s.** The
/// membership decision is the one that decides which conversation is the command
/// channel, and a bug here sends every message to the wrong place or nowhere. So the
/// decision is a function of the chat's participants and the local identity, and the
/// self-test drives both.
///
/// ## The rule
///
/// A chat is the self channel when **its only participant is the local number**. A chat
/// with two participants is not. A group that *was* only the user stays paired after a
/// second handle appears — the pairing rule is frozen at pairing and never re-derived
/// (IM-08's design, §"the pairing rule is frozen").
///
/// ## What is not consulted
///
/// **`chat.chat_identifier` and `display_name` are not read.** Both are guesses about
/// an unmeasured format (§2.2 of the design). The participants join is the only signal.
///
/// ## Fail-closed
///
/// When the participants join is absent, the answer is `.cannotTell` — not `.isSelf`
/// and `.isNotSelf`. A chat whose participants cannot be read is not the self channel,
/// but it is not *not* the self channel either: it is a chat this Mac cannot classify,
/// and the fail-closed answer is to say nothing and advance the watermark.
enum SelfChatMembership: Equatable, Sendable {
    /// The chat's only participant is the local number.
    case isSelf
    /// The chat has two or more participants, or its only participant is not the local number.
    case isNotSelf
    /// The participants join is absent — this Mac cannot tell.
    case cannotTell
}

enum SelfChatMembershipResolver {
    /// The membership decision for one chat.
    ///
    /// - Parameters:
    ///   - participants: the chat's `handle.uncanonicalized_id` values, sorted.
    ///   - localIdentity: the user's own identity in canonical form.
    /// - Returns: `.isSelf` when the only participant is the local number, `.isNotSelf`
    ///   when it is not, `.cannotTell` when the join is absent.
    static func resolve(participants: [String], localIdentity: RemoteIdentity?) -> SelfChatMembership {
        guard !participants.isEmpty else { return .cannotTell }
        guard let local = localIdentity else { return .cannotTell }
        guard participants.count == 1 else { return .isNotSelf }
        return local.matches(handle: participants[0]) ? .isSelf : .isNotSelf
    }

    /// Whether a chat is the self channel, for a chat whose participants are unknown.
    /// Always `.cannotTell` — a chat whose participants cannot be read is not the self
    /// channel, but it is not *not* the self channel either.
    static func resolveUnknown() -> SelfChatMembership {
        .cannotTell
    }
}
