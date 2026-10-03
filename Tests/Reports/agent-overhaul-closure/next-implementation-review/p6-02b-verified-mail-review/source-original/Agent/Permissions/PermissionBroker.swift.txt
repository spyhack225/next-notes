import Foundation
import Observation

/// Sits above every executor. MCP annotations, Composio metadata and an ACP backend's own
/// permission prompt are not enforcement — this is.
///
/// The rule is the one in the roadmap: no tool bypasses the broker merely because it came
/// from MCP. Unknown tools resolve to `.send` on the proposal, and to `.deny` here if they
/// have no catalogue entry at all.
actor PermissionBroker {
    static let shared = PermissionBroker()

    func authorize(
        _ tool: AgentTool,
        arguments: [String: String],
        policy: PermissionPolicy,
        scope: PermissionScope = .any,
        meetingID: UUID? = nil,
        taskID: String? = nil,
        authority: ActionAuthority? = nil,
        trigger: ToolCallTrigger = .unattributed,
        origin: ActionOriginContext? = nil,
        remoteAccessSuspended: Bool = false
    ) -> PermissionDecision {
        // IM-12: a remote turn is the same authority under a smaller budget. The
        // denied band runs before grants, because a grant names a tool and never a
        // command — "always allow shell" cannot bless `sudo`.
        if let origin = origin, origin.isRemote {
            return authorizeRemote(tool, arguments: arguments, policy: policy, scope: scope,
                                   meetingID: meetingID, taskID: taskID, authority: authority,
                                   trigger: trigger, suspended: remoteAccessSuspended)
        }

        if let grant = policy.existingGrant(
            for: tool.id,
            scope: scope,
            meetingID: meetingID,
            taskID: taskID
        ) {
            Log.agent.info("permission grant \(grant.duration.rawValue, privacy: .public) for \(tool.id, privacy: .public)")
            return .allow
        }

        if policy.allowsAutomatically(tool, authority: authority) {
            return .allow
        }

        if !tool.risk.mayAutoRun {
            return .ask(makeRequest(tool: tool, arguments: arguments, scope: scope,
                                    meetingID: meetingID, taskID: taskID, trigger: trigger))
        }

        return .deny("\(tool.id) is not allowed to run by itself.")
    }

    /// IM-12 — the remote branch. Same `.user` authority, four narrower answers.
    /// Nothing here can widen what a local turn may do: every arm either denies,
    /// asks, or defers to the same `allowsAutomatically` a local turn gets.
    /// Standing grants are deliberately not consulted: a grant given at the Mac
    /// must not silently execute from the phone, so every remote write confirms
    /// at its band. Switches (`autoRead` and friends) still apply — they are
    /// policy, not permission.
    private func authorizeRemote(
        _ tool: AgentTool,
        arguments: [String: String],
        policy: PermissionPolicy,
        scope: PermissionScope,
        meetingID: UUID?,
        taskID: String?,
        authority: ActionAuthority?,
        trigger: ToolCallTrigger,
        suspended: Bool
    ) -> PermissionDecision {
        if suspended {
            return .deny(RemoteAccessPolicy.suspendedDenied)
        }
        // A remote turn may not carry review or unattended authority: neither is the
        // user at the phone.
        if authority == .memoryReview || authority?.isScheduled == true {
            return .deny(RemoteAccessPolicy.authorityDenied)
        }
        switch RemoteAccessPolicy.band(for: tool, arguments: arguments) {
        case .deny:
            if tool.namespace == .shell {
                return .deny(RemoteAccessPolicy.sudoDenied)
            }
            return .deny(RemoteAccessPolicy.privilegedDenied)
        case .requireLocalMac:
            return .askLocal(makeRequest(tool: tool, arguments: arguments, scope: scope,
                                         meetingID: meetingID, taskID: taskID, trigger: trigger))
        case .confirmInChannel:
            return .ask(makeRequest(tool: tool, arguments: arguments, scope: scope,
                                    meetingID: meetingID, taskID: taskID, trigger: trigger))
        case .autoAllow:
            if policy.allowsAutomatically(tool, authority: authority) {
                return .allow
            }
            return .ask(makeRequest(tool: tool, arguments: arguments, scope: scope,
                                    meetingID: meetingID, taskID: taskID, trigger: trigger))
        }
    }

    private func makeRequest(
        tool: AgentTool,
        arguments: [String: String],
        scope: PermissionScope,
        meetingID: UUID?,
        taskID: String?,
        trigger: ToolCallTrigger
    ) -> PermissionRequest {
        PermissionRequest(
            toolID: tool.id,
            title: tool.title(for: arguments),
            detail: tool.preview(for: arguments) ?? tool.description,
            risk: tool.risk,
            arguments: arguments,
            scope: scope,
            meetingID: meetingID,
            taskID: taskID,
            trigger: trigger
        )
    }
}

/// Grants that outlive one process — "always allow this action" and "for this meeting".
@MainActor
@Observable
final class PermissionGrantStore {
    static let shared = PermissionGrantStore()

    private(set) var grants: [PermissionGrant] = []

    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("permission-grants.json")
    }

    /// A self-test neither reads nor writes the user's standing grants.
    private init() {
        grants = SelfTest.isRunning ? [] : Self.load()
    }

    func add(_ grant: PermissionGrant) {
        // Once is a one-shot on the in-memory policy, not a standing answer.
        guard grant.duration != .once else { return }
        grants.removeAll {
            $0.toolID == grant.toolID
                && $0.duration == grant.duration
                && $0.scope == grant.scope
        }
        grants.append(grant)
        save()
    }

    func revoke(id: String) {
        grants.removeAll { $0.id == id }
        save()
    }

    func revokeAll() {
        grants = []
        save()
    }

    private func save() {
        guard !SelfTest.isRunning else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(grants) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static func load() -> [PermissionGrant] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([PermissionGrant].self, from: data)) ?? []
    }
}
