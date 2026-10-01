import Foundation

/// IM-13 — approval over iMessage: one exact action, once, payload frozen.
///
/// The mechanism `Phone-Calls` reuses, so it is built once and generically: the
/// payload is `Data` plus a kind, never a specialisation per action. What the
/// person saw on the offer is what fires — a later recomputation never
/// substitutes, an approval never widens, and an expired or ambiguous reply
/// clarifies rather than fires.
///
/// A restart clears pending offers (they live in this actor, never on disk): a
/// reply after a restart meets no offer and clarifies. That is the safe default —
/// firing from a stale file would be approval outliving its payload, which the
/// task forbids.
enum RemoteActionKind: Sendable, Equatable, Codable {
    /// A message through `MessagesSender` (the only kind with a firer today).
    case sendMessage
    /// A mail through the Workspace path (IM-14+).
    case email
    /// A calendar write through the Workspace path (IM-14+).
    case calendarEvent
    /// Declared but not used: owned by the Phone-Calls roadmap.
    case phoneCall(PhoneCallRequest)

    private enum Code: String, Codable {
        case sendMessage, email, calendarEvent, phoneCall
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Code.self, forKey: .kind) {
        case .sendMessage: self = .sendMessage
        case .email: self = .email
        case .calendarEvent: self = .calendarEvent
        case .phoneCall:
            self = .phoneCall(try container.decode(PhoneCallRequest.self, forKey: .phoneCall))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sendMessage: try container.encode(Code.sendMessage, forKey: .kind)
        case .email: try container.encode(Code.email, forKey: .kind)
        case .calendarEvent: try container.encode(Code.calendarEvent, forKey: .kind)
        case .phoneCall(let request):
            try container.encode(Code.phoneCall, forKey: .kind)
            try container.encode(request, forKey: .phoneCall)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, phoneCall
    }
}

/// The phone call a `.phoneCall` action would place. Declared here so the kind
/// exists; the shape belongs to the Phone-Calls roadmap.
struct PhoneCallRequest: Sendable, Equatable, Codable {
    var recipient: String
    var topic: String?
}

/// The frozen bytes of a `.sendMessage` offer: the exact text that fires.
struct RemoteSendMessagePayload: Sendable, Equatable, Codable {
    var text: String
}

/// Where an offer was made: the chat, and the message that carried it. Opaque
/// handles, never logged.
struct RemoteOffer: Sendable, Equatable, Codable {
    var chatGUID: String
    var messageGUID: String
}

/// What the owner said to an offer.
enum RemoteDecision: String, Sendable, Equatable, Codable {
    case approve
    case cancel
}

/// One exact action awaiting exactly one answer.
struct RemotePreparedAction: Sendable, Equatable, Codable {
    /// UUID string. Links the offer, the reply and the receipt.
    var actionID: String
    var kind: RemoteActionKind
    /// "Ready to send to Sarah" — what the person reads first.
    var title: String
    /// The frozen payload. What fires, byte for byte; never recomputed.
    var payload: Data
    /// Recipient, subject, attachment names — what a person reads second.
    var payloadSummary: [String]
    /// The chat and message the offer went out on. Only that chat can answer.
    var offeredOn: RemoteOffer
    var expiresAt: Date
    var decidedAt: Date?
    var decision: RemoteDecision?
}

/// What a reply means. `none` is not a refusal: ordinary text is a normal turn,
/// and a keyword from a stranger's chat is ignored entirely rather than answered.
enum RemoteApprovalAnswer: Equatable, Sendable {
    case approved(RemotePreparedAction)
    case cancelled(RemotePreparedAction)
    case clarify(String)
    case none
}

/// Holds pending offers and matches replies. An actor because offers arrive from
/// the turn pipeline while replies arrive from the watcher.
actor RemoteApprovalMatcher {
    /// How long an offer stays answerable. Ten minutes: long enough to read a
    /// card, short enough that an approval cannot outlive its payload.
    static let approvalTTL: TimeInterval = 600

    /// Exact, lowercased, whole-message keywords. No prefixes, no contains: "ok
    /// thanks" is a sentence, not an approval.
    static let approveWords = ["send", "yes", "approve", "ok"]
    static let cancelWords = ["cancel", "no"]

    private var pending: [RemotePreparedAction] = []

    /// Offers an action. Replaces any offer with the same id: re-offering is an
    /// update, never a duplicate.
    func offer(_ action: RemotePreparedAction) {
        pending.removeAll { $0.actionID == action.actionID }
        pending.append(action)
    }

    /// Pending offers, oldest first. For the report and the suite.
    var outstanding: [RemotePreparedAction] { pending }

    /// Matches a reply. `pairedChatGUID` is the channel; anything else is `.none`.
    /// `now` is injected so expiry pins without waiting.
    func decide(reply text: String, chatGUID: String,
                pairedChatGUID: String?, now: Date = Date()) -> RemoteApprovalAnswer {
        guard let paired = pairedChatGUID, !paired.isEmpty, chatGUID == paired else {
            return .none
        }
        pending.removeAll { $0.expiresAt <= now }
        let mine = pending.filter { $0.offeredOn.chatGUID == chatGUID }
        guard let keyword = keyword(text) else { return .none }
        guard !mine.isEmpty else {
            return .clarify(keyword == .approve
                ? "There's nothing waiting for approval — tell me what to do and I'll propose it."
                : "There's nothing waiting to cancel.")
        }
        guard mine.count == 1 else {
            return .clarify("There are \(mine.count) things waiting — answer one at a time so I approve the right one.")
        }
        var decided = mine[0]
        decided.decision = keyword == .approve ? .approve : .cancel
        decided.decidedAt = now
        pending.removeAll { $0.actionID == decided.actionID }
        return keyword == .approve ? .approved(decided) : .cancelled(decided)
    }

    private enum Keyword { case approve, cancel }

    private func keyword(_ text: String) -> Keyword? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.approveWords.contains(word) { return .approve }
        if Self.cancelWords.contains(word) { return .cancel }
        return nil
    }
}

/// Fires an approved action. The payload that fires is the payload that was
/// offered — this type never recomputes, re-renders or substitutes.
///
/// Delivery is injected: `.sendMessage` hands its frozen bytes to `deliver` and
/// reports what came back; every other kind answers `.unsupported`, which is the
/// honest shape until its firer exists (IM-14+, Phone-Calls). A test fake proves
/// the bytes are equal; production binds the verified send path when the live
/// host lands.
enum RemoteActionFirer {
    enum FireResult: Equatable, Sendable {
        case fired(Data)
        case failed(String)
        case unsupported(RemoteActionKind)
    }

    static func fire(_ approved: RemotePreparedAction,
                     deliver: (Data) async -> Bool) async -> FireResult {
        guard approved.decision == .approve else {
            return .failed("the action was not approved")
        }
        switch approved.kind {
        case .sendMessage:
            return await deliver(approved.payload) ? .fired(approved.payload) : .failed("delivery refused the payload")
        case .email, .calendarEvent, .phoneCall:
            return .unsupported(approved.kind)
        }
    }
}

/// The offer card's text: title, summary, and the exact reply words. Prefixed
/// with the runtime name like every other agent reply, so the offer is visibly
/// the agent's — never a hardcoded name.
enum RemoteApprovalOffer {
    static func text(for action: RemotePreparedAction, agentName: String) -> String {
        var lines = [action.title]
        lines.append(contentsOf: action.payloadSummary)
        lines.append("Reply send to approve, cancel to stop.")
        return AgentMessageFormat.prefixed(lines.joined(separator: "\n"), name: agentName)
    }
}
