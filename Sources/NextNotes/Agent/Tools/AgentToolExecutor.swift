import Foundation

/// The only place a tool actually runs. Every path — meeting review, realtime turn, task
/// backend, MCP — comes through here so the broker cannot be skipped.
enum AgentToolExecutor {
    @MainActor
    static func run(
        _ name: String,
        arguments: [String: String],
        policy: PermissionPolicy,
        meetingID: UUID? = nil,
        taskID: String? = nil,
        autoApproveReads: Bool = false,
        promptIfNeeded: Bool = false
    ) async throws -> AgentToolResult {
        guard let tool = AgentToolRegistry.shared.tool(named: name) else {
            throw AgentError.unknownTool(name)
        }
        for parameter in tool.parameters where parameter.isRequired {
            let value = arguments[parameter.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else {
                throw AgentError.missingArgument(name: parameter.name, tool: tool.id)
            }
        }

        var effective = policy
        if autoApproveReads, tool.risk <= .read {
            effective.autoRead = true
            effective.autoObserve = true
        }

        let decision = await PermissionBroker.shared.authorize(
            tool,
            arguments: arguments,
            policy: effective,
            meetingID: meetingID,
            taskID: taskID
        )
        switch decision {
        case .deny(let reason):
            throw AgentError.permissionDenied(reason)
        case .ask(let request):
            if promptIfNeeded {
                let approved = await PermissionGate.shared.ask(request)
                if !approved {
                    throw AgentError.permissionDenied("You dismissed \(request.title).")
                }
            } else {
                throw AgentError.needsPermission(request.title)
            }
        case .allow:
            break
        }

        let publicTitle = AgentActivityProjector.title(for: tool, arguments: arguments)
        AgentActivityStore.shared.update(
            taskID: taskID ?? "",
            kind: AgentActivityProjector.kind(for: tool),
            title: publicTitle
        )
        IslandState.shared.showAgentWork(title: publicTitle)
        AgentAuditLog.shared.record(
            kind: .tool,
            title: publicTitle,
            detail: tool.id,
            toolID: tool.id,
            taskID: taskID,
            meetingID: meetingID
        )

        return try await perform(tool, arguments: arguments)
    }

    /// The Workspace runner, kept as the implementation for the eleven existing tools.
    @MainActor
    static func run(
        _ proposal: AgentProposal,
        policy: PermissionPolicy? = nil,
        cli: GoogleWorkspaceCLI = .shared
    ) async throws -> AgentToolResult {
        if let tool = AgentToolRegistry.shared.tool(named: proposal.tool),
           tool.namespace != .workspace {
            return try await run(
                proposal.tool,
                arguments: proposal.arguments,
                policy: policy ?? .fromSettings(),
                meetingID: proposal.meetingID,
                autoApproveReads: false
            )
        }
        let decision = await PermissionBroker.shared.authorize(
            AgentTool.workspace(proposal.definition ?? WorkspaceTool(
                name: proposal.tool,
                summary: proposal.rationale,
                risk: proposal.risk,
                parameters: [],
                titleBuilder: { _ in proposal.tool },
                previewBuilder: nil
            )),
            arguments: proposal.arguments,
            policy: policy ?? .fromSettings(),
            meetingID: proposal.meetingID
        )
        switch decision {
        case .deny(let reason):
            throw AgentError.permissionDenied(reason)
        case .ask:
            // An approved proposal *is* the person's yes. The broker still ran so a
            // mutating tool cannot sneak through a path that never asked.
            break
        case .allow:
            break
        }
        return try await WorkspaceToolRunner.run(proposal, cli: cli)
    }

    @MainActor
    private static func perform(
        _ tool: AgentTool,
        arguments: [String: String]
    ) async throws -> AgentToolResult {
        switch tool.source {
        case .mcp, .composio:
            return try await MCPClientStore.shared.call(tool: tool, arguments: arguments)
        case .acp:
            throw AgentError.backendUnavailable("ACP tools run as tasks, not as immediate calls.")
        case .native:
            break
        }

        switch tool.namespace {
        case .workspace:
            let proposal = AgentProposal(
                meetingID: UUID(),
                tool: tool.name,
                arguments: arguments,
                rationale: ""
            )
            return try await WorkspaceToolRunner.run(proposal)
        case .meeting:
            return try MeetingToolExecutor.run(tool, arguments: arguments)
        case .computer:
            return try ComputerToolExecutor.run(tool, arguments: arguments)
        case .filesystem:
            return try FilesystemExecutor.run(tool, arguments: arguments)
        case .shell:
            return try await ShellExecutor.run(tool, arguments: arguments)
        case .browser:
            return try BrowserToolExecutor.run(tool, arguments: arguments)
        case .github, .notion, .slack, .mcp:
            throw AgentError.noIntegration(tool.id)
        }
    }
}
