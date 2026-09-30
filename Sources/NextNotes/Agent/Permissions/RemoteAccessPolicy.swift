import Foundation

/// IM-12 — how the phone gets in: the transport a turn arrived on.
///
/// A turn's *authority* (`.user`, `.scheduled`…) says who answered for it; the
/// transport says where it came from. The two travel together
/// (`ActionOriginContext`) because "the user said so" means something different
/// from a keyboard than from a phone: same authority, smaller budget.
enum AgentTransport: String, Codable, Sendable, Hashable, CaseIterable {
    /// Spoken to the Mac. The full local budget.
    case voice
    /// Typed into the app. The full local budget.
    case appUI
    /// Arrived over the paired self-channel. The four-band budget below.
    case iMessage
    /// Ran while nobody was present. Its own budget, unchanged by anything here.
    case scheduled
}

/// IM-12 — the context beside `ActionAuthority`.
///
/// Deliberately **not** a new authority case: the six cases persist in
/// `action-receipts.json` with a hand-written `Codable` pair, and a seventh is a
/// decode-compatibility event across files on disk for no gain. A remote turn
/// carries the same `.user` authority as a local one; what changes is how much
/// the app will do on it, decided by the broker from this context.
///
/// Every field is `decodeIfPresent`, for the same reason as every other persisted
/// vocabulary in this tree: a file written by one build is read by the next.
struct ActionOriginContext: Codable, Sendable, Hashable {
    /// Where the turn came from.
    var transport: AgentTransport
    /// The paired identity, when the transport is `.iMessage`. Nil everywhere else.
    var remoteIdentity: RemoteIdentity?
    /// The `chat.guid` the turn arrived in. An opaque handle, never logged.
    var chatGUID: String?
    /// The `message.guid` that started the turn. An opaque handle, never logged.
    var messageGUID: String?
    /// Whether the row landed while the Mac was asleep (IM-16 owns the clock that
    /// answers this; until then it is false, never guessed).
    var receivedWhileMacWasAsleep: Bool

    init(transport: AgentTransport,
         remoteIdentity: RemoteIdentity? = nil,
         chatGUID: String? = nil,
         messageGUID: String? = nil,
         receivedWhileMacWasAsleep: Bool = false) {
        self.transport = transport
        self.remoteIdentity = remoteIdentity
        self.chatGUID = chatGUID
        self.messageGUID = messageGUID
        self.receivedWhileMacWasAsleep = receivedWhileMacWasAsleep
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decodeIfPresent(AgentTransport.self, forKey: .transport) ?? .appUI
        remoteIdentity = try container.decodeIfPresent(RemoteIdentity.self, forKey: .remoteIdentity)
        chatGUID = try container.decodeIfPresent(String.self, forKey: .chatGUID)
        messageGUID = try container.decodeIfPresent(String.self, forKey: .messageGUID)
        receivedWhileMacWasAsleep = try container.decodeIfPresent(Bool.self, forKey: .receivedWhileMacWasAsleep) ?? false
    }

    /// Whether this origin is the phone. Anything else is local policy as before.
    var isRemote: Bool { transport == .iMessage }
}

/// IM-12 — the four bands: what a remote turn may do, decided by the broker and
/// never by the prompt.
///
/// A remote origin may **only lower** what policy permits, never raise it: the
/// bands replace the local auto-run answers with narrower ones, and a standing
/// grant still applies because it is the user's own standing answer. The denied
/// band is checked before grants, because a grant names a tool and never a
/// command — "always allow shell" cannot bless `sudo`.
enum RemoteAccessBand: Sendable, Equatable {
    /// Reads and observations, under the same switches as local turns.
    case autoAllow
    /// Reversible writes and sends, confirmed where the turn is (IM-13's card).
    case confirmInChannel
    /// Anything irreversible or money-shaped: the Mac's own card, never an
    /// iMessage approval. IM-13 must not satisfy these from the phone.
    case requireLocalMac
    /// Never from the phone, under any confirmation.
    case deny
}

/// The band table and the two gates. Pure, so the authority suite pins it without
/// a broker, a grant or a turn.
enum RemoteAccessPolicy {
    /// Which band a tool falls in on a remote turn, from its risk and namespace.
    ///
    /// | risk | band | why |
    /// |---|---|---|
    /// | observe, read | autoAllow | band 1: reads under the usual switches |
    /// | modify, write, send | confirmInChannel | band 2: reversible, confirmed |
    /// | purchase, destructive | requireLocalMac | band 3: money and ruin need the Mac |
    /// | privileged | deny | root and installers are never phone business |
    ///
    /// Two refinements the table alone cannot carry: a `shell` command starting
    /// with `sudo` is denied (the executor refuses sudo everywhere; the broker
    /// says so remotely with a plain sentence), and there is deliberately no
    /// credential/keychain/policy tool in the catalogue to place — if one is
    /// added it lands in `deny` (keychain, policy) or `requireLocalMac`
    /// (credentials) by explicit id, never by falling through.
    static func band(for tool: AgentTool, arguments: [String: String]) -> RemoteAccessBand {
        if tool.namespace == .shell, isSudoCommand(arguments["command"] ?? "") {
            return .deny
        }
        switch tool.risk {
        case .observe, .read:
            return .autoAllow
        case .modify, .write, .send:
            return .confirmInChannel
        case .purchase, .destructive:
            return .requireLocalMac
        case .privileged:
            return .deny
        }
    }

    /// Whether a shell command asks for root: its first token is `sudo`.
    /// Mirrors the executor's own refusal so the broker denies remotely what
    /// execution refuses everywhere.
    static func isSudoCommand(_ command: String) -> Bool {
        let first = command.split(separator: " ", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return first == "sudo" || first.hasSuffix("/sudo")
    }

    /// Whether pairing mode may be entered from an origin. Pairing is a local
    /// act: a remote turn must not be able to widen its own authority, and
    /// re-pairing without local approval is the load-bearing case. A nil origin
    /// is a local process (today: `--imessage-pair-now`).
    static func mayEnterPairing(origin: ActionOriginContext?) -> Bool {
        guard let origin else { return true }
        return !origin.isRemote && origin.transport != .scheduled
    }

    /// Copy for a denied sudo. Plain words, names the Mac path, never a number.
    static let sudoDenied = "That command needs administrator privileges, which this app never takes from a message. Run it on your Mac."
    /// Copy for a denied privileged tool.
    static let privilegedDenied = "That action needs your Mac. Ask for it there."
    /// Copy for a suspended feature.
    static let suspendedDenied = "Remote access is paused. Turn it back on in Settings on your Mac."
    /// Copy for an authority a remote turn may not carry.
    static let authorityDenied = "That needs your Mac. Ask for it there."
}
