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
        promptIfNeeded: Bool = false,
        authority: ActionAuthority? = nil,
        permissionAlreadyGranted: Bool = false,
        isStillValid: (@MainActor @Sendable () async -> Bool)? = nil
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

        var authorizedArguments = arguments
        authorizedArguments.removeValue(forKey: "_browserBackend")
        authorizedArguments.removeValue(forKey: "_authorizedPageURL")
        if tool.namespace == .browser {
            if await BrowserCDPClient.isReachable() {
                guard let targetID = await BrowserCDPClient.targetID(
                    for: tool, arguments: authorizedArguments
                ) else {
                    throw AgentError.backendUnavailable("The active browser tab could not be identified. Choose a targetId and try again.")
                }
                // Keep the target and backend selected for authorization fixed
                // through a permission prompt and the eventual action.
                authorizedArguments["targetId"] = targetID
                authorizedArguments["_browserBackend"] = "cdp"
                if tool.name != "navigate" && tool.name != "download" {
                    guard let pageURL = await BrowserCDPClient.targetURL(
                        for: tool, arguments: authorizedArguments
                    ), !pageURL.isEmpty else {
                        throw AgentError.backendUnavailable(
                            "The selected browser tab URL could not be identified. Snapshot again."
                        )
                    }
                    authorizedArguments["_authorizedPageURL"] = pageURL
                }
            } else {
                guard authorizedArguments["targetId"] == nil else {
                    throw AgentError.backendUnavailable("The selected browser target is no longer available. Snapshot again.")
                }
                authorizedArguments["_browserBackend"] = "accessibility"
                if tool.name != "navigate" && tool.name != "download" {
                    guard let pageURL = BrowserToolExecutor.currentURL() else {
                        throw AgentError.backendUnavailable("The focused browser document URL could not be identified.")
                    }
                    authorizedArguments["_authorizedPageURL"] = pageURL
                }
            }
        }
        let scope = await PermissionScopeResolver.inferredAsync(tool: tool, arguments: authorizedArguments)
        if scope.kind == .unresolved {
            throw AgentError.permissionDenied(
                "The active browser tab could not be identified, so \(tool.id) was not run."
            )
        }
        let publicTitle = AgentActivityProjector.title(for: tool, arguments: authorizedArguments)
        // A meeting-origin call is derived context unless the caller explicitly passes the
        // user's approval. This prevents a future meeting mutation from inheriting authority
        // merely because it used the generic executor API.
        let actionAuthority = authority ?? (meetingID == nil ? .user : .systemDerived)
        let source: ActionSource = actionAuthority.isScheduled ? .scheduled : meetingID == nil ? .agent : .meeting
        // Runs cannot create schedules — not even a read of them is in a run's ceiling, and a
        // write would be a job making jobs.
        if actionAuthority.isScheduled, tool.namespace == .schedule {
            throw AgentError.permissionDenied("A routine run cannot use \(tool.id).")
        }
        // The one auto-allowed write needs both halves: the authority the runtime checks, and
        // the provenance the code running the turn bound — never the model's arguments.
        if tool.namespace == .memory, tool.risk > .read {
            let provenance = MemoryProvenance.current
            guard meetingID == nil, let provenance, provenance.requiredAuthority == actionAuthority else {
                throw MemoryWriteError.provenance(
                    "memory can only be saved from what you say in a conversation with the Agent.")
            }
        }
        // A reminder skips the card only with the user's checked yes behind it; otherwise
        // the card, whose preview is the sentence, is the confirmation.
        effective.confirmedScheduleWrite = false
        if tool.namespace == .schedule, tool.risk > .read {
            let problem = meetingID == nil && actionAuthority == .user
                ? ScheduleConfirmation.problem(
                    toolID: tool.id, arguments: authorizedArguments, provenance: MemoryProvenance.current)
                : "not the user's own request."
            effective.confirmedScheduleWrite = problem == nil
            if let problem {
                Log.agent.info("\(tool.id, privacy: .public) asks for permission: \(problem, privacy: .public)")
            }
        }
        let intent = ActionIntent(
            source: source,
            authority: actionAuthority,
            verb: tool.id,
            target: scope.value.isEmpty ? nil : scope.value,
            arguments: authorizedArguments,
            evidence: [],
            risk: tool.risk,
            confidence: 1
        )
        return try await ActionOrchestrator.shared.execute(
            intent: intent,
            tool: tool,
            title: publicTitle,
            preparedContent: PreparedContent(title: publicTitle, visiblePlan: tool.preview(for: authorizedArguments)),
            routing: ActionRouting(
                resource: scope.value.isEmpty ? nil : scope.value,
                taskID: taskID,
                meetingID: meetingID
            ),
            steps: [tool.id],
            policy: effective,
            // Nobody is there to answer a card for a scheduled run.
            promptIfNeeded: promptIfNeeded && !actionAuthority.isScheduled,
            permissionAlreadyGranted: permissionAlreadyGranted && !actionAuthority.isScheduled,
            allowUnverifiedResult: (tool.namespace == .browser
                                    || tool.namespace == .computer
                                    || tool.namespace == .workspace)
                && tool.risk > .read,
            isStillValid: isStillValid,
            fire: { prepared in
                // A denied or waiting action must not appear as executed activity. These
                // projections happen only after the orchestrator has received permission.
                AgentActivityStore.shared.update(
                    taskID: taskID ?? "",
                    kind: AgentActivityProjector.kind(for: tool),
                    title: publicTitle
                )
                if taskID == nil {
                    IslandState.shared.showAgentWork(title: publicTitle)
                } else {
                    IslandState.shared.showBackgroundAgentWork(title: publicTitle)
                }
                AgentAuditLog.shared.record(
                    kind: .tool,
                    title: publicTitle,
                    detail: tool.id,
                    toolID: tool.id,
                    taskID: taskID,
                    meetingID: meetingID
                )
                return try await perform(tool, arguments: prepared.executionPlan.arguments)
            }
        )
    }

    /// The Workspace runner, kept as the implementation for the eleven existing tools.
    @MainActor
    static func run(
        _ proposal: AgentProposal,
        policy: PermissionPolicy? = nil,
        cli: GoogleWorkspaceCLI = .shared,
        approvedByUser: Bool = false
    ) async throws -> AgentToolResult {
        // A persisted proposal is evidence of model intent, never approval. The only
        // caller allowed to set this bit is the UI approval path; read lookups continue
        // through the broker and may auto-run according to policy.
        if proposal.risk >= .modify && !approvedByUser {
            throw AgentError.permissionDenied("This action needs your approval before it can run.")
        }
        if let tool = AgentToolRegistry.shared.tool(named: proposal.tool),
           tool.namespace != .workspace {
            return try await run(
                proposal.tool,
                arguments: proposal.arguments,
                policy: policy ?? .fromSettings(),
                meetingID: proposal.meetingID,
                autoApproveReads: false,
                authority: approvedByUser ? .user : .systemDerived,
                permissionAlreadyGranted: approvedByUser
            )
        }
        guard let definition = proposal.definition else {
            throw AgentError.unknownTool(proposal.tool)
        }
        guard definition.risk == proposal.risk else {
            throw AgentError.permissionDenied("The proposal risk no longer matches the Workspace tool catalogue.")
        }
        let workspaceTool = AgentTool.workspace(proposal.definition ?? WorkspaceTool(
            name: proposal.tool,
            summary: proposal.rationale,
            risk: proposal.risk,
            parameters: [],
            titleBuilder: { _ in proposal.tool },
            previewBuilder: nil
        ))
        let intent = ActionIntent(
            source: .meeting,
            authority: approvedByUser ? .user : .systemDerived,
            verb: workspaceTool.id,
            target: proposal.arguments["to"] ?? proposal.arguments["path"],
            arguments: proposal.arguments,
            risk: workspaceTool.risk,
            confidence: 1
        )
        return try await ActionOrchestrator.shared.execute(
            intent: intent,
            tool: workspaceTool,
            title: proposal.title,
            preparedContent: PreparedContent(
                title: proposal.title,
                body: proposal.messagePreview,
                visiblePlan: proposal.reviewPreview
            ),
            routing: ActionRouting(
                integration: "Google Workspace",
                resource: proposal.arguments["to"] ?? proposal.arguments["calendarId"],
                meetingID: proposal.meetingID
            ),
            steps: [workspaceTool.id],
            policy: policy ?? .fromSettings(),
            promptIfNeeded: false,
            permissionAlreadyGranted: approvedByUser,
            allowUnverifiedResult: workspaceTool.risk > .read,
            fire: { prepared in
                var frozen = proposal
                frozen.arguments = prepared.executionPlan.arguments
                return try await WorkspaceToolRunner.run(frozen, cli: cli)
            }
        )
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
        case .memory:
            return try MemoryToolExecutor.run(tool, arguments: arguments, provenance: MemoryProvenance.current)
        case .schedule:
            return try await ScheduleToolExecutor.run(
                tool, arguments: arguments, sessionID: AgentSession.shared.sessionID)
        case .browser:
            let result = try await BrowserExecutor.run(tool, arguments: arguments)
            if tool.risk > .read {
                let noAction = ["No snapshot", "Snapshot id", "Snapshot no longer", "Browser is not", "not a browser"]
                if noAction.contains(where: { result.summary.localizedCaseInsensitiveContains($0) }) {
                    throw AgentError.backendUnavailable(result.summary)
                }
            }
            return result
        case .github, .notion, .slack, .mcp:
            throw AgentError.noIntegration(tool.id)
        }
    }
}
