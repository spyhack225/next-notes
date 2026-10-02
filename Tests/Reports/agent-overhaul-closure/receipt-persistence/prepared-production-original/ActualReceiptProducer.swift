import Foundation
import AppKit

/// The source of an action. Dictation deliberately has no case here: it is a one-way text
/// pipeline and must never enter the action runtime.
enum ActionSource: String, Codable, Sendable, CaseIterable {
    case meeting
    case agent
    case system
    case background
    /// A routine run with nobody present (Part 3).
    case scheduled
}

/// Who supplied the authority for an action. Audio from another participant is evidence,
/// never authority, even when a model labels it as an instruction.
///
/// Stored as a string — `"user"`, or `"scheduled:<uuid>"` — so receipts written before
/// `.scheduled` existed still decode as the same thing.
enum ActionAuthority: Codable, Sendable, Hashable {
    case user
    case otherParticipant
    case systemDerived
    case background
    /// The background memory review (Part 2). Authority for `memory.*` writes only.
    case memoryReview
    /// A routine running unattended (Part 3). Not `.user` and not `.background`: it may run
    /// the observe and read tools its schedule was confirmed with, and nothing else. Writes
    /// become drafts the user approves; `ActionOrchestrator` refuses them outright.
    case scheduled(UUID)

    static let scheduledPrefix = "scheduled:"

    var rawValue: String {
        switch self {
        case .user: "user"
        case .otherParticipant: "otherParticipant"
        case .systemDerived: "systemDerived"
        case .background: "background"
        case .memoryReview: "memoryReview"
        case .scheduled(let id): Self.scheduledPrefix + id.uuidString
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "user": self = .user
        case "otherParticipant": self = .otherParticipant
        case "systemDerived": self = .systemDerived
        case "background": self = .background
        case "memoryReview": self = .memoryReview
        default:
            guard rawValue.hasPrefix(Self.scheduledPrefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(Self.scheduledPrefix.count)))
            else { return nil }
            self = .scheduled(id)
        }
    }

    /// The schedule behind a `.scheduled` authority.
    var scheduleID: UUID? {
        if case .scheduled(let id) = self { return id }
        return nil
    }

    var isScheduled: Bool { scheduleID != nil }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown authority \(raw)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ActionContextReference: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: String
    var value: String

    init(id: String = UUID().uuidString, kind: String, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
    }
}

/// A proposed operation before its target has been verified and its exact execution plan
/// has been prepared.
struct ActionIntent: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var source: ActionSource
    var authority: ActionAuthority
    var verb: String
    var target: String?
    var arguments: [String: String]
    var evidence: [ActionContextReference]
    var risk: AgentRisk
    var confidence: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        source: ActionSource,
        authority: ActionAuthority,
        verb: String,
        target: String? = nil,
        arguments: [String: String] = [:],
        evidence: [ActionContextReference] = [],
        risk: AgentRisk,
        confidence: Double = 1,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.authority = authority
        self.verb = verb
        self.target = target
        self.arguments = arguments
        self.evidence = evidence
        self.risk = risk
        self.confidence = confidence
        self.createdAt = createdAt
    }
}

/// A passive meeting observation. It can be displayed and later refined, but it cannot
/// authorize execution when its authority is `.otherParticipant` or `.systemDerived`.
struct CandidateAction: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var meetingID: UUID?
    var action: String
    var object: String?
    var recipient: String?
    var speaker: String?
    var evidence: String
    var confidence: Double
    var authority: ActionAuthority

    init(
        id: UUID = UUID(), meetingID: UUID? = nil, action: String, object: String? = nil,
        recipient: String? = nil, speaker: String? = nil, evidence: String,
        confidence: Double = 0, authority: ActionAuthority
    ) {
        self.id = id
        self.meetingID = meetingID
        self.action = action
        self.object = object
        self.recipient = recipient
        self.speaker = speaker
        self.evidence = evidence
        self.confidence = confidence
        self.authority = authority
    }
}

struct PreparedContent: Codable, Equatable, Sendable {
    var title: String?
    var subject: String?
    var body: String?
    var visiblePlan: String?

    init(title: String? = nil, subject: String? = nil, body: String? = nil, visiblePlan: String? = nil) {
        self.title = title
        self.subject = subject
        self.body = body
        self.visiblePlan = visiblePlan
    }
}

struct ActionRouting: Codable, Equatable, Sendable {
    var integration: String?
    var resource: String?
    var application: String?
    var domain: String?
    var path: String?
    var taskID: String?
    var meetingID: UUID?

    init(
        integration: String? = nil, resource: String? = nil, application: String? = nil,
        domain: String? = nil, path: String? = nil, taskID: String? = nil, meetingID: UUID? = nil
    ) {
        self.integration = integration
        self.resource = resource
        self.application = application
        self.domain = domain
        self.path = path
        self.taskID = taskID
        self.meetingID = meetingID
    }
}

struct ActionExecutionPlan: Codable, Equatable, Sendable {
    var toolID: String
    var arguments: [String: String]
    var steps: [String]

    init(toolID: String, arguments: [String: String], steps: [String] = []) {
        self.toolID = toolID
        self.arguments = arguments
        self.steps = steps
    }
}

enum PreparedActionStatus: String, Codable, Sendable, CaseIterable {
    case prepared
    case awaitingPermission
    case approved
    case firing
    case completed
    case failed
    case denied
    case needsVerification
}

/// The exact thing shown for approval. Its content, routing and execution plan are frozen
/// before PermissionBroker is asked; Fire never reparses the original request.
struct PreparedAction: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var intentID: UUID
    var title: String
    var preparedContent: PreparedContent?
    var routing: ActionRouting
    var executionPlan: ActionExecutionPlan
    var evidence: [ActionContextReference]
    var risk: AgentRisk
    var status: PreparedActionStatus

    init(
        id: UUID = UUID(), intentID: UUID, title: String, preparedContent: PreparedContent? = nil,
        routing: ActionRouting, executionPlan: ActionExecutionPlan,
        evidence: [ActionContextReference] = [], risk: AgentRisk,
        status: PreparedActionStatus = .prepared
    ) {
        self.id = id
        self.intentID = intentID
        self.title = title
        self.preparedContent = preparedContent
        self.routing = routing
        self.executionPlan = executionPlan
        self.evidence = evidence
        self.risk = risk
        self.status = status
    }
}

enum ActionReceiptStatus: String, Codable, Sendable, CaseIterable {
    case judged
    case verified
    case prepared
    case waitingPermission
    case approved
    case fired
    case completed
    case denied
    case failed
    case couldNotVerify
    case cancelled
    /// P1-21: the write left the Mac and nothing came back. **Not a failure.** `gws` runs with a
    /// 60 s timeout and is terminated when it expires, and a Google write that takes longer than
    /// that — or that exits after the request left with something unreadable on stdout — produced
    /// a receipt that said `failed`, a card that said it failed, and a person who pressed it
    /// again. That is how the app sends the same email twice, and it is live today rather than a
    /// recovery-after-restart problem.
    ///
    /// Distinct from `failed` in the only direction that matters: `failed` means the app knows
    /// nothing was sent, and this means the app does not know. Distinct from `couldNotVerify`,
    /// which is a *read* that could not confirm a result we already had.
    case outcomeUnknown

    /// P1-21: an unrecognised stored value decodes as `couldNotVerify` rather than throwing.
    ///
    /// Hand-written for one reason, and it is the reason this enum is dangerous at all: a new
    /// case makes every receipts file written by another build — an older one after a
    /// downgrade, or a newer one read by this build — fail to decode, and `load()` used to answer
    /// a decode failure with an **empty list**, which the next `record` then overwrote the file
    /// with. A status nobody recognises is a record about a step this build does not have a word
    /// for; `couldNotVerify` is the honest reading, and the row stays.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActionReceiptStatus(rawValue: raw) ?? .couldNotVerify
    }
}

struct ActionReceiptEvent: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var stage: ActionReceiptStatus
    var detail: String
    var at: Date

    init(id: String = UUID().uuidString, stage: ActionReceiptStatus, detail: String, at: Date = Date()) {
        self.id = id
        self.stage = stage
        self.detail = detail
        self.at = at
    }
}

/// Durable audit evidence for one action. Events preserve the lifecycle while the final
/// status provides a compact query for the Actions screen and support tooling.
struct ActionReceipt: Codable, Equatable, Sendable, Identifiable {
    var id: UUID { actionID }
    var actionID: UUID
    var intentID: UUID
    /// Frozen input retained with the receipt so a review after relaunch has the same
    /// authority, arguments and evidence that were judged originally.
    var intent: ActionIntent
    /// Present once preparation completes, including when permission is still pending.
    var preparedAction: PreparedAction?
    var status: ActionReceiptStatus
    var result: String
    var artifacts: [String]
    var verification: String?
    var startedAt: Date
    var completedAt: Date?
    var events: [ActionReceiptEvent]
    var source: ActionSource
    var authority: ActionAuthority
    var toolID: String
    var meetingID: UUID?
    var taskID: String?

    init(actionID: UUID, intent: ActionIntent, source: ActionSource, authority: ActionAuthority,
         toolID: String, meetingID: UUID? = nil, taskID: String? = nil, startedAt: Date = Date()) {
        self.actionID = actionID
        self.intentID = intent.id
        self.intent = intent
        self.preparedAction = nil
        self.status = .judged
        self.result = ""
        self.artifacts = []
        self.verification = nil
        self.startedAt = startedAt
        self.completedAt = nil
        self.events = []
        self.source = source
        self.authority = authority
        self.toolID = toolID
        self.meetingID = meetingID
        self.taskID = taskID
    }
}

@MainActor
final class ActionReceiptStore {
    static let shared = ActionReceiptStore()

    private(set) var receipts: [ActionReceipt]
    /// The file this store owns. An instance rather than a static constant, so a self-test can
    /// have a store of its own — case G writes real bytes and reads them back, and the only way
    /// to do that honestly is a store pointed at a temporary file. `MeetingStore.isolated()` is
    /// the same seam.
    private let fileURL: URL
    static var defaultFileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("action-receipts.json")
    }

    /// A self-test starts empty: it must never read the user's receipts either.
    private init() {
        fileURL = Self.defaultFileURL
        receipts = SelfTest.isRunning ? [] : Self.load(from: fileURL)
    }

    /// A store over its own file. The only way to construct one outside `shared`, and it never
    /// reads or writes the user's receipts whatever the harness is doing.
    init(fileURL: URL) {
        self.fileURL = fileURL
        receipts = SelfTest.isRunning ? Self.load(from: fileURL) : Self.load(from: fileURL)
    }

    /// How many receipts this store holds. For a self-test that has just written a file.
    var count: Int { receipts.count }

    @discardableResult
    func record(_ receipt: ActionReceipt) -> Bool {
        if let index = receipts.firstIndex(where: { $0.actionID == receipt.actionID }) {
            receipts[index] = receipt
        } else {
            receipts.insert(receipt, at: 0)
        }
        if receipts.count > 500 { receipts = Array(receipts.prefix(500)) }
        // Self-tests may inspect the in-memory lifecycle, but must never write an audit
        // record into the user's support directory.
        return SelfTest.isRunning ? true : save()
    }

    func receipt(for id: UUID) -> ActionReceipt? { receipts.first { $0.actionID == id } }

    func receipt(forIntent id: UUID) -> ActionReceipt? { receipts.first { $0.intentID == id } }

    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(receipts) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            Log.agent.error("Could not persist action receipt: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// **One undecodable record must not empty the file.** P1-21.
    ///
    /// This used to be `decode([ActionReceipt].self) ?? []`, and the two halves of that were the
    /// bug: a single record this build cannot read took every record with it, and the next
    /// `record` → `save()` then wrote that empty list back over the file. The audit trail is the
    /// one store that must never be silently emptied, and it was the one store that could be
    /// emptied by a version difference alone.
    ///
    /// So each record is decoded on its own, the ones that decode are kept, and the rest are
    /// counted in the log rather than dropped without word. A file that is not a JSON array at
    /// all is a different failure and still reads as empty — there is nothing in it to keep.
    private static func load(from fileURL: URL) -> [ActionReceipt] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let rows = try? decoder.decode([AnyReceiptRow].self, from: data) else { return [] }
        var kept: [ActionReceipt] = []
        var unreadable = 0
        for row in rows {
            if let receipt = row.receipt {
                kept.append(receipt)
            } else {
                // A row with a field this build does not have, rather than a row with a status
                // it does not: `ActionReceiptStatus.init(from:)` already absorbs the latter.
                unreadable += 1
            }
        }
        if unreadable > 0 {
            Log.agent.error("""
                action receipts: kept \(kept.count) of \(rows.count) \
                (\(unreadable) unreadable by this build, left on disk)
                """)
        }
        return kept
    }

    /// One element of the stored array, decoded on its own so a failure is a nil rather than a
    /// whole-array throw.
    ///
    /// **Not** `Data`: `JSONDecoder` cannot decode a JSON object into `Data`, and an array of
    /// them fails the same way — which is a decode failure that looks exactly like the bug this
    /// replaced, because the result is still an empty store. A one-field struct is what actually
    /// works, and `receipt` is the whole of it.
    private struct AnyReceiptRow: Decodable {
        let receipt: ActionReceipt?
        init(from decoder: Decoder) throws {
            receipt = try? ActionReceipt(from: decoder)
        }
    }
}

