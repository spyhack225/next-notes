import Foundation
import AppKit

/// The source of an action. Dictation deliberately has no case here: it is a one-way text
/// pipeline and must never enter the action runtime.
enum ActionSource: String, Codable, Sendable, CaseIterable {
    case meeting
    case agent
    case system
    case background
}

/// Who supplied the authority for an action. Audio from another participant is evidence,
/// never authority, even when a model labels it as an instruction.
enum ActionAuthority: String, Codable, Sendable, CaseIterable {
    case user
    case otherParticipant
    case systemDerived
    case background
    /// The background memory review (Part 2). Authority for `memory.*` writes only.
    case memoryReview
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
    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("action-receipts.json")
    }

    private init() { receipts = Self.load() }

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
            try data.write(to: Self.fileURL, options: .atomic)
            return true
        } catch {
            Log.agent.error("Could not persist action receipt: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func load() -> [ActionReceipt] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([ActionReceipt].self, from: data)) ?? []
    }
}

/// Shared Judge → Verify → Prepare → Permission → Fire → Verify Result runtime. Executors
/// provide only the already prepared fire closure; they cannot expand the approved plan.
@MainActor
final class ActionOrchestrator {
    static let shared = ActionOrchestrator()

    private init() {}

    /// Backends with a nested protocol (ACP) can attach permission/update events to the
    /// already persisted prepared action without inventing a second receipt format.
    func appendExternalEvent(actionID: UUID, stage: ActionReceiptStatus, detail: String) {
        guard var receipt = ActionReceiptStore.shared.receipt(for: actionID) else { return }
        receipt.status = stage
        receipt.events.append(ActionReceiptEvent(stage: stage, detail: detail))
        _ = ActionReceiptStore.shared.record(receipt)
    }

    func execute(
        intent: ActionIntent,
        tool: AgentTool,
        title: String,
        preparedContent: PreparedContent? = nil,
        routing: ActionRouting,
        steps: [String] = [],
        policy: PermissionPolicy,
        promptIfNeeded: Bool,
        permissionAlreadyGranted: Bool = false,
        allowUnverifiedResult: Bool = false,
        isStillValid: (@MainActor @Sendable () async -> Bool)? = nil,
        fire: @escaping @MainActor (PreparedAction) async throws -> AgentToolResult
    ) async throws -> AgentToolResult {
        let preparedID = UUID()
        var receipt = ActionReceipt(
            actionID: preparedID, intent: intent, source: intent.source,
            authority: intent.authority, toolID: tool.id, meetingID: routing.meetingID,
            taskID: routing.taskID
        )
        @discardableResult
        func add(_ stage: ActionReceiptStatus, _ detail: String) -> Bool {
            // ACP can append nested permission events while `fire` is suspended. Merge
            // them before writing the next stage so the outer receipt does not erase
            // evidence of what the coding agent asked the user to approve.
            if let stored = ActionReceiptStore.shared.receipt(for: receipt.actionID) {
                let known = Set(receipt.events.map(\.id))
                receipt.events.append(contentsOf: stored.events.filter { !known.contains($0.id) })
            }
            receipt.status = stage
            receipt.events.append(ActionReceiptEvent(stage: stage, detail: detail))
            return ActionReceiptStore.shared.record(receipt)
        }
        add(.judged, "\(intent.source.rawValue) intent for \(tool.id)")

        do {
            guard intent.confidence >= 0, intent.confidence <= 1 else {
                throw AgentError.permissionDenied("The action confidence was invalid.")
            }
            guard intent.risk == tool.risk else {
                throw AgentError.permissionDenied("The action risk changed before execution.")
            }
            let memoryReviewWrite = tool.namespace == .memory && intent.authority == .memoryReview
            if tool.risk >= .modify, intent.authority != .user, !memoryReviewWrite {
                add(.denied, "Only the user's microphone or explicit approval can authorize a mutation.")
                throw AgentError.permissionDenied("Only the user can authorize this action.")
            }
            add(.verified, "Target and authority verified")

            let prepared = PreparedAction(
                id: preparedID, intentID: intent.id, title: title,
                preparedContent: preparedContent, routing: routing,
                executionPlan: ActionExecutionPlan(toolID: tool.id, arguments: intent.arguments, steps: steps),
                evidence: intent.evidence, risk: tool.risk, status: .prepared
            )
            receipt.preparedAction = prepared
            if !add(.prepared, title), !SelfTest.isRunning {
                throw AgentError.backendUnavailable("Could not save the prepared action; it was not run.")
            }

            let decision = await PermissionBroker.shared.authorize(
                tool, arguments: intent.arguments, policy: policy,
                scope: await PermissionScopeResolver.inferredAsync(tool: tool, arguments: intent.arguments),
                meetingID: routing.meetingID, taskID: routing.taskID,
                authority: intent.authority
            )
            switch decision {
            case .deny(let reason):
                add(.denied, reason)
                throw AgentError.permissionDenied(reason)
            case .ask(let request):
                guard permissionAlreadyGranted || promptIfNeeded else {
                    add(.waitingPermission, request.title)
                    throw AgentError.needsPermission(request.title)
                }
                if !permissionAlreadyGranted {
                    guard await PermissionGate.shared.ask(request) else {
                        add(.denied, "Permission dismissed")
                        throw AgentError.permissionDenied("You dismissed \(request.title).")
                    }
                }
                guard add(.approved, permissionAlreadyGranted ? "Approved by action card" : "Approved by user") else {
                    throw AgentError.backendUnavailable("Could not save action approval; it was not run.")
                }
            case .allow:
                guard add(.approved, "Existing permission policy") else {
                    throw AgentError.backendUnavailable("Could not save action permission; it was not run.")
                }
            }

            // A timed-out tool loop cancels its child without waiting for it to unwind. Do
            // this check after every permission await so a late approval cannot fire a stale
            // prepared action after the caller has moved on.
            try Task.checkCancellation()
            if let isStillValid, !(await isStillValid()) { throw CancellationError() }
            try Task.checkCancellation()
            guard add(.fired, title) else {
                throw AgentError.backendUnavailable("Could not save action execution; it was not run.")
            }
            let result = try await fire(prepared)
            guard let verification = await Self.verifyResult(
                tool: tool, arguments: prepared.executionPlan.arguments, result: result
            ) else {
                add(.couldNotVerify, "The executor returned no evidence that the side effect completed")
                if allowUnverifiedResult {
                    receipt.result = result.summary
                    if let reference = result.reference { receipt.artifacts.append(reference) }
                    if let link = result.link?.absoluteString { receipt.artifacts.append(link) }
                    receipt.verification = "Unverified; inspect the target before retrying"
                    receipt.completedAt = Date()
                    _ = ActionReceiptStore.shared.record(receipt)
                    return AgentToolResult(
                        summary: result.summary + "\nNext Notes could not independently verify the effect. Inspect the target before retrying.",
                        reference: result.reference,
                        link: result.link
                    )
                }
                throw AgentError.backendUnavailable("The action ran, but its result could not be verified.")
            }
            receipt.result = result.summary
            if let reference = result.reference { receipt.artifacts.append(reference) }
            if let link = result.link?.absoluteString { receipt.artifacts.append(link) }
            receipt.verification = verification
            receipt.completedAt = Date()
            add(.completed, receipt.verification ?? "Verified")
            return result
        } catch let error as AgentError {
            switch error {
            case .needsPermission:
                break
            default:
                if receipt.status != .denied && receipt.status != .couldNotVerify {
                    add(.failed, error.localizedDescription)
                }
            }
            throw error
        } catch {
            add(.failed, error.localizedDescription)
            throw error
        }
    }

    /// A success sentence is not proof that a mutation happened. Read-only tools can be
    /// verified by their returned content; consequential tools need a resource reference or
    /// link supplied by the integration. Unknown mutation results fail closed.
    private static func verifyResult(
        tool: AgentTool, arguments: [String: String], result: AgentToolResult
    ) async -> String? {
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        // ACP confirms a protocol session, but exposes no provider resource or diff. Keep
        // that distinction explicit so a successful reply cannot be mistaken for proof that
        // a coding side effect landed.
        if tool.id == "mcp.acp_session" { return result.verification }
        if tool.risk <= .read { return "Read result returned" }
        // Memory writes read the entry back from the store before returning.
        if tool.namespace == .memory { return result.verification }

        if tool.namespace == .filesystem {
            if tool.name == "delete" {
                guard let path = arguments["path"].map({ ($0 as NSString).expandingTildeInPath }) else {
                    return nil
                }
                return FileManager.default.fileExists(atPath: path)
                    ? nil : "Source file is absent after moving it to the Trash"
            }
            guard let path = result.reference,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            if tool.name == "move" {
                guard let source = arguments["from"].map({ ($0 as NSString).expandingTildeInPath }),
                      !FileManager.default.fileExists(atPath: source) else { return nil }
            }
            return "Filesystem readback found \(path)"
        }

        if tool.namespace == .shell, tool.name == "run" {
            guard result.reference != nil, summary.contains("status: completed"),
                  summary.contains("exit: 0") else { return nil }
            return "Shell completed with exit code 0"
        }

        if tool.namespace == .browser {
            let observedURL: String?
            if arguments["_browserBackend"] == "cdp" {
                observedURL = await BrowserCDPClient.targetURL(for: tool, arguments: arguments)
            } else {
                observedURL = BrowserToolExecutor.currentURL()
            }
            if tool.risk <= .read {
                return observedURL == nil ? nil : "Browser target read back"
            }
            if tool.name == "navigate" || tool.name == "download",
               let requested = arguments["url"], let observedURL,
               let expected = URLComponents(string: requested),
               let observed = URLComponents(string: observedURL),
               expected.scheme == observed.scheme,
               expected.host == observed.host,
               expected.path == observed.path,
               expected.query == observed.query {
                return "Browser destination read back"
            }
            // The browser executor compares a post-action DOM/URL to its pre-action
            // snapshot, or reads the exact value of a filled control. An unchanged page
            // is inconclusive even when Runtime.evaluate reported success.
            return result.verification
        }

        if tool.namespace == .computer {
            // A generic successful AX press or a nonempty later tree proves nothing.
            // set_text reads the target value; click compares the window state.
            if tool.name == "focus" || tool.name == "open_app",
               let name = arguments["name"], !name.isEmpty {
                for attempt in 0..<4 {
                    if attempt > 0 { try? await Task.sleep(for: .milliseconds(200)) }
                    let matched: Bool
                    if tool.name == "focus" {
                        matched = NSWorkspace.shared.frontmostApplication.map {
                            $0.localizedName?.localizedCaseInsensitiveContains(name) == true
                                || $0.bundleIdentifier?.localizedCaseInsensitiveContains(name) == true
                        } ?? false
                    } else {
                        matched = NSWorkspace.shared.runningApplications.contains {
                            $0.localizedName?.localizedCaseInsensitiveContains(name) == true
                                || $0.bundleIdentifier?.localizedCaseInsensitiveContains(name) == true
                        }
                    }
                    if matched {
                        return tool.name == "focus"
                            ? "Requested application is frontmost"
                            : "Requested application is running"
                    }
                }
            }
            return result.verification
        }

        if tool.namespace == .workspace {
            guard let reference = result.reference, !reference.isEmpty else { return nil }
            // The runner uses the same approved account to read back the exact
            // message, event, file or document after the write.
            return result.verification
        }

        if result.reference != nil || result.link != nil {
            return "Integration returned a resource reference"
        }
        return nil
    }

    @MainActor
    @discardableResult
    static func runSelfTest() async -> Bool {
        let meeting = UUID()
        let intent = ActionIntent(
            source: .meeting, authority: .otherParticipant, verb: "send_file",
            target: "Sarah", arguments: ["file": "Enclosure_v17.step"],
            evidence: [ActionContextReference(kind: "transcript", value: "Sarah asked")],
            risk: .send, confidence: 1
        )
        let tool = AgentTool.native(namespace: .workspace, name: "selftest.send", description: "test", risk: .send)
        let routing = ActionRouting(integration: "test", meetingID: meeting)
        let probe = ActionOrchestrator()
        var deniedFireCalled = false
        let denied: Bool
        do {
            _ = try await probe.execute(
                intent: intent,
                tool: tool,
                title: "Send Enclosure_v17.step to Sarah",
                routing: routing,
                policy: .denyMutations,
                promptIfNeeded: false,
                fire: { _ in
                    deniedFireCalled = true
                    return AgentToolResult(summary: "must not fire", reference: "unexpected")
                }
            )
            denied = false
        } catch let error as AgentError {
            if case .permissionDenied = error {
                denied = true
            } else {
                denied = false
            }
        } catch {
            denied = false
        }
        let readTool = AgentTool.native(
            namespace: .meeting, name: "selftest.read", description: "test", risk: .read
        )
        let readIntent = ActionIntent(
            source: .agent, authority: .user, verb: readTool.id, risk: .read, confidence: 1
        )
        var firedPlan: PreparedAction?
        let completed: Bool
        do {
            let result = try await probe.execute(
                intent: readIntent,
                tool: readTool,
                title: "Read meeting context",
                routing: ActionRouting(taskID: "selftest"),
                policy: .selfTest,
                promptIfNeeded: false,
                fire: { prepared in
                    firedPlan = prepared
                    return AgentToolResult(summary: "context read")
                }
            )
            completed = result.summary == "context read"
        } catch {
            completed = false
        }
        let frozenPlan = firedPlan?.executionPlan.toolID == readTool.id
            && firedPlan?.executionPlan.arguments.isEmpty == true
        let mutationTool = AgentTool.native(
            namespace: .filesystem, name: "selftest.mutation", description: "test", risk: .modify
        )
        let mutationIntent = ActionIntent(
            source: .agent, authority: .user, verb: mutationTool.id,
            arguments: ["path": "/tmp/action-runtime-selftest"], risk: .modify, confidence: 1
        )
        var mutationFired = false
        let mutationReturned: Bool
        do {
            _ = try await probe.execute(
                intent: mutationIntent,
                tool: mutationTool,
                title: "Unverifiable mutation",
                routing: ActionRouting(taskID: "selftest"),
                policy: .selfTest,
                promptIfNeeded: false,
                permissionAlreadyGranted: true,
                allowUnverifiedResult: true,
                fire: { _ in
                    mutationFired = true
                    return AgentToolResult(summary: "mutation completed")
                }
            )
            mutationReturned = true
        } catch {
            mutationReturned = false
        }
        let mutationReceipt = ActionReceiptStore.shared.receipt(forIntent: mutationIntent.id)
        let workspaceWrite = AgentTool.native(
            namespace: .workspace, name: "create_event", description: "test", risk: .write
        )
        let unverifiedWorkspace = await Self.verifyResult(
            tool: workspaceWrite, arguments: [:],
            result: AgentToolResult(summary: "Created event", reference: "event-1")
        )
        let verifiedWorkspace = await Self.verifyResult(
            tool: workspaceWrite, arguments: [:],
            result: AgentToolResult(
                summary: "Created event", reference: "event-1",
                verification: "Read back the event title and scheduled time"
            )
        )
        let computerClick = AgentTool.native(
            namespace: .computer, name: "click", description: "test", risk: .modify
        )
        let unverifiedClick = await Self.verifyResult(
            tool: computerClick, arguments: ["id": "1.2"],
            result: AgentToolResult(summary: "Clicked element 1.2")
        )
        let acpTool = AgentTool.native(
            namespace: .mcp, name: "acp_session", description: "test", risk: .privileged
        )
        let unverifiedACP = await Self.verifyResult(
            tool: acpTool, arguments: [:],
            result: AgentToolResult(summary: "ACP completed", reference: "file.swift")
        )
        let island = IslandState.shared
        island.apply(.agentListening(transcript: "foreground", level: 0))
        island.showBackgroundAgentWork(title: "background task")
        let backgroundPreservedForeground: Bool
        if case .agentListening(let transcript, _) = island.kind {
            backgroundPreservedForeground = transcript == "foreground"
        } else {
            backgroundPreservedForeground = false
        }
        island.apply(.hidden)
        let finalOK = denied && !deniedFireCalled && completed && frozenPlan
            && mutationReturned && mutationFired && mutationReceipt?.status == .couldNotVerify
            && unverifiedWorkspace == nil && verifiedWorkspace != nil
            && unverifiedClick == nil && unverifiedACP == nil
            && ACPWorkspaceVerification.runSelfTest()
            && backgroundPreservedForeground
            && intent.authority != .user && routing.meetingID == meeting && tool.risk == .send
        return finalOK
    }
}

/// Background work may report progress, but must not steal the island from a foreground
/// voice turn. This lives beside the action runtime so every background backend uses one
/// policy rather than each ACP/local implementation making its own UI decision.
extension IslandState {
    @MainActor
    var hasForegroundVoiceActivity: Bool {
        switch kind {
        case .agentListening, .agentWorking, .agentReply: true
        default: false
        }
    }

    @MainActor
    func showBackgroundAgentWork(title: String) {
        guard !hasForegroundVoiceActivity, PermissionGate.shared.pending == nil else { return }
        showAgentWork(title: title)
    }

    @MainActor
    func showBackgroundAgentReply(_ text: String) {
        guard !hasForegroundVoiceActivity, PermissionGate.shared.pending == nil else { return }
        showAgentReply(text)
    }
}
