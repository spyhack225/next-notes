import Foundation

/// The one settings file the iMessage feature owns, and every scalar in it.
///
/// **JSON, and the reason is `PersonResolutionStore`'s precedent:** the index is disposable
/// and the user's word is not, so a rebuilt index resolves people the way the user left
/// them. The same applies here — a pairing is a fact about a conversation, and a settings
/// file that cannot be read by a build that predates it is a pairing that is silently lost.
///
/// **Every field is `decodeIfPresent`, and that is the rule rather than a habit.** A
/// settings file is written by more than one build: the one that added a field, the one
/// that removed it, and every one in between. Swift's synthesized `init(from:)` does not
/// use a property's default value as a fallback for a missing key, so a new field makes
/// every existing `imessage-settings.json` fail to decode and the pairing vanishes. The
/// same rule as `AgentTask` and `MemoryEntry`, for the same reason.
struct IMessageConfiguration: Equatable, Sendable, Codable {
    /// Whether the feature is on. Off by default — a person has to ask for it.
    var enabled: Bool = false
    /// The paired chat's `chat.guid`. `nil` until pairing succeeds.
    var pairedChatGUID: String?
    /// When the pairing succeeded, as a Unix timestamp. `nil` until it does.
    var pairedAt: TimeInterval?
    /// The watcher's watermark, persisted so a restart does not replay.
    var lastProcessedRowID: Int64 = 0
    /// The user's own iMessage handle, in the canonical form `RemoteIdentity` defines.
    /// Stored because the trust boundary needs "expected account/service", not only a GUID.
    var localIdentity: String?
    /// The version of the remote policy this build enforces. A build that does not
    /// recognise the version it reads refuses rather than guessing.
    var remotePolicyVersion: Int = 1
    /// IM-09's Apple Events target, resolved once at pairing and cached. A `chat.guid`
    /// is not an address (IM-02), so this is the handle `send` actually takes.
    var chatHandleCache: String?
    /// The last time a remote command was accepted, for the UI's "Last request · 2 min ago".
    var lastInboundCommandAt: TimeInterval?
    /// IM-12 — "stop remote access" latched here. Processing (turns) and tools (the
    /// broker's remote branch) both refuse while set. `decodeIfPresent`, like every
    /// other field: an older file reads as unpaused.
    var remoteAccessSuspended: Bool = false
    /// IM-17e — the canary's 24-hour window: rows considered and rows unreadable.
    /// Updated by the hosted watcher as it reads (IM-16); until then zeros, which
    /// the row renders without a note. Same file, because a second store for
    /// three numbers is the ledger this roadmap refuses to add twice.
    var canarySeen: Int = 0
    var canaryUnreadable: Int = 0
    /// Unix timestamp opening the window the two counts cover. Nil (never opened)
    /// reads as zero counts.
    var canaryWindowStartedAt: TimeInterval?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        pairedChatGUID = try container.decodeIfPresent(String.self, forKey: .pairedChatGUID)
        pairedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .pairedAt)
        lastProcessedRowID = try container.decodeIfPresent(Int64.self, forKey: .lastProcessedRowID) ?? 0
        localIdentity = try container.decodeIfPresent(String.self, forKey: .localIdentity)
        remotePolicyVersion = try container.decodeIfPresent(Int.self, forKey: .remotePolicyVersion) ?? 1
        chatHandleCache = try container.decodeIfPresent(String.self, forKey: .chatHandleCache)
        lastInboundCommandAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastInboundCommandAt)
        remoteAccessSuspended = try container.decodeIfPresent(Bool.self, forKey: .remoteAccessSuspended) ?? false
        canarySeen = try container.decodeIfPresent(Int.self, forKey: .canarySeen) ?? 0
        canaryUnreadable = try container.decodeIfPresent(Int.self, forKey: .canaryUnreadable) ?? 0
        canaryWindowStartedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .canaryWindowStartedAt)
    }

    /// Whether the feature is paired and enabled. Both must be true: an unpaired feature
    /// is off, and a paired feature the person switched off is not a command channel.
    var isPaired: Bool { enabled && pairedChatGUID != nil }

    /// Whether this configuration can be trusted to identify the user's own messages.
    /// Needs both the paired chat and the local identity — a GUID alone cannot resolve
    /// a sender, and an identity alone cannot filter a chat.
    var canResolveSender: Bool { pairedChatGUID != nil && localIdentity != nil }
}
