import Foundation

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
        meetingID: UUID? = nil,
        taskID: String? = nil
    ) -> PermissionDecision {
        if let grant = policy.existingGrant(for: tool.id, meetingID: meetingID, taskID: taskID) {
            Log.agent.info("permission grant \(grant.duration.rawValue, privacy: .public) for \(tool.id, privacy: .public)")
            return .allow
        }

        if policy.allowsAutomatically(tool) {
            return .allow
        }

        if !tool.risk.mayAutoRun {
            let request = PermissionRequest(
                toolID: tool.id,
                title: tool.title(for: arguments),
                detail: tool.preview(for: arguments) ?? tool.description,
                risk: tool.risk,
                arguments: arguments,
                meetingID: meetingID,
                taskID: taskID
            )
            return .ask(request)
        }

        return .deny("\(tool.id) is not allowed to run by itself.")
    }
}

/// Grants that outlive one process — "always allow this action" and "for this meeting".
@MainActor
final class PermissionGrantStore {
    static let shared = PermissionGrantStore()

    private(set) var grants: [PermissionGrant] = []

    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("permission-grants.json")
    }

    private init() {
        grants = Self.load()
    }

    func add(_ grant: PermissionGrant) {
        // Once is a one-shot on the in-memory policy, not a standing answer.
        guard grant.duration != .once else { return }
        grants.removeAll { $0.toolID == grant.toolID && $0.duration == grant.duration }
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
