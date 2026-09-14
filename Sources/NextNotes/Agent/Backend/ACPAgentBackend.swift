import Foundation

/// Hands sustained coding work to an ACP stdio session (Claude Code, Codex, Qwen Code,
/// OpenCode). Next Notes stays the voice, context and permission layer.
///
/// A CLI that never answers `initialize` is not ACP — we do not call that a session or
/// silently reinterpret it as an opaque prompt command.
struct ACPAgentBackend: AgentBackend {
    func describe() async -> AgentBackendDescription {
        AgentBackendDescription(
            id: AgentBackendKind.acp.rawValue,
            displayName: AgentBackendKind.acp.displayName,
            capabilities: ["submit", "cancel", "subscribe", "permission"]
        )
    }

    func start() async throws {}

    func health() async -> String {
        let preferred = await MainActor.run { Settings.shared.acpBackendID }
        if let found = Self.installedCLI(preferring: preferred) {
            return "ready (\(found))"
        }
        return "unavailable — no ACP agent is installed"
    }

    func submit(_ task: AgentTask) async throws -> AgentTaskOutcome {
        if let fixture = task.arguments["acpFixture"] {
            return try await runSessionWithReceipt(
                command: AgentStdioFixtures.python,
                arguments: [fixture],
                task: task,
                approvePermissions: SelfTest.isRunning
            )
        }

        let preferred = await MainActor.run {
            task.acpCLI.isEmpty ? Settings.shared.acpBackendID : task.acpCLI
        }
        guard let cli = Self.installedCLI(preferring: preferred) else {
            throw AgentError.backendUnavailable(
                "No ACP coding agent is installed. Install Claude Code, Codex or Qwen Code, "
                    + "then pick it in Settings ▸ Agent."
            )
        }
        let directory = task.contextReferences.first(where: { $0.hasPrefix("project://") })
            .map { String($0.dropFirst("project://".count)) }

        do {
            return try await runSessionWithReceipt(
                command: "/usr/bin/env",
                arguments: [cli],
                directory: directory,
                task: task,
                approvePermissions: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentError {
            if case .acpHandshakeUnavailable = error { throw error }
            Log.agent.error("ACP session failed: \(error.localizedDescription, privacy: .public)")
            throw error
        } catch is ACPHandshakeUnavailable {
            throw AgentError.acpHandshakeUnavailable(Self.compatibilityRequest(
                task: task, cli: cli, directory: Self.workingDirectory(for: task)
            ))
        } catch {
            Log.agent.error("ACP session failed: \(error.localizedDescription, privacy: .public)")
            // ACP remains the authority boundary. A prompt failure after a successful
            // handshake is not eligible for compatibility mode and stays an explicit error.
            throw AgentError.backendUnavailable(
                "ACP session failed for \(cli): \(error.localizedDescription)"
            )
        }
    }

    func status(taskID: String) async -> AgentTaskStatus? {
        await MainActor.run { AgentTaskManager.shared.task(id: taskID)?.status }
    }

    func cancel(taskID: String) async {
        await MainActor.run { AgentTaskManager.shared.cancel(taskID) }
    }

    func respondPermission(taskID: String, approved: Bool) async {
        await MainActor.run { AgentTaskManager.shared.respondPermission(taskID: taskID, approved: approved) }
    }

    func respondInput(taskID: String, text: String) async {
        await MainActor.run { AgentTaskManager.shared.respondInput(taskID: taskID, text: text) }
    }

    static func installedCLI(preferring preferred: String = "") -> String? {
        let candidates = [preferred, "claude", "codex", "qwen", "opencode", "kimi"]
        for name in candidates where !name.isEmpty {
            if which(name) != nil { return name }
        }
        return nil
    }

    static func isOnPATH(_ name: String) -> Bool {
        !name.isEmpty && which(name) != nil
    }

    private func runSession(
        command: String,
        arguments: [String],
        directory: String? = nil,
        task: AgentTask,
        approvePermissions: Bool,
        actionID: UUID? = nil
    ) async throws -> AgentTaskOutcome {
        let session = ACPSession()
        let token = await session.subscribe { event in
            Task { @MainActor in
                guard let current = AgentTaskManager.shared.task(id: task.id),
                      current.status == .running else { return }
                if event.kind == "permission", let actionID {
                    ActionOrchestrator.shared.appendExternalEvent(
                        actionID: actionID,
                        stage: .waitingPermission,
                        detail: event.detail
                    )
                }
                if event.kind == "activity" {
                    AgentActivityStore.shared.update(
                        taskID: task.id,
                        kind: .executing,
                        title: event.title,
                        detail: event.detail
                    )
                    IslandState.shared.showBackgroundAgentWork(title: event.title)
                }
            }
        }
        do {
            try Task.checkCancellation()
            try await session.start(
                command: command,
                arguments: arguments,
                directory: directory,
                taskID: task.id,
                approvePermissions: approvePermissions
            )
            try Task.checkCancellation()
            let reply = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await session.prompt(task.objective)
            }, onCancel: {
                Task { await session.cancel() }
            })
            try Task.checkCancellation()
            let sessionID = await session.sessionID ?? ""
            let initialized = await session.didInitialize
            await session.unsubscribe(token)
            await session.close()
            guard initialized, !sessionID.isEmpty else {
                throw JSONRPCError(message: "ACP never started a session.")
            }
            // ACP gives us a stable session identifier, useful for audit and support. It
            // does not provide a resource id or diff proving what the coding agent changed.
            return .completed(reply, artifacts: [sessionID])
        } catch is CancellationError {
            await session.unsubscribe(token)
            await session.close()
            throw CancellationError()
        } catch {
            let initialized = await session.didInitialize
            await session.unsubscribe(token)
            await session.close()
            if !initialized {
                throw ACPHandshakeUnavailable()
            }
            throw error
        }
    }

    /// ACP has its own fine-grained permission requests, but the task submission itself must
    /// still enter the shared action lifecycle. The receipt deliberately remains
    /// `couldNotVerify` after a successful protocol reply: without a provider diff, retrying
    /// the same objective could duplicate an already-applied edit.
    private func runSessionWithReceipt(
        command: String,
        arguments: [String],
        directory: String? = nil,
        task: AgentTask,
        approvePermissions: Bool
    ) async throws -> AgentTaskOutcome {
        let tool = AgentTool.native(
            namespace: .mcp,
            name: "acp_session",
            description: "Run one sustained ACP coding session",
            risk: .privileged,
            executionMode: .task,
            title: "Run ACP coding task"
        )
        let authority: ActionAuthority = task.source == "meeting" ? .systemDerived : .user
        let intent = ActionIntent(
            source: .background,
            authority: authority,
            verb: tool.id,
            target: directory,
            arguments: [
                "objective": task.objective,
                "command": command,
                "arguments": arguments.joined(separator: " ")
            ],
            evidence: [ActionContextReference(kind: "task", value: task.id)],
            risk: tool.risk,
            confidence: 1
        )
        let result = try await ActionOrchestrator.shared.execute(
                intent: intent,
                tool: tool,
                title: task.objective,
                preparedContent: PreparedContent(
                    title: task.objective,
                    visiblePlan: "ACP session (command)"
                ),
                routing: ActionRouting(
                    integration: "ACP",
                    resource: directory,
                    taskID: task.id
                ),
                steps: ["initialize", "session/new", "session/prompt"],
                policy: .fromSettings(),
                promptIfNeeded: false,
                // Creating an ACP task is already an explicit user action. Meeting-origin
                // tasks retain the broker boundary and cannot self-authorize mutations.
                permissionAlreadyGranted: approvePermissions || task.source != "meeting",
                allowUnverifiedResult: true,
                fire: { [self] prepared in
                    try Task.checkCancellation()
                    let outcome: AgentTaskOutcome
                    do {
                        outcome = try await self.runSession(
                            command: command,
                            arguments: arguments,
                            directory: directory,
                            task: task,
                            approvePermissions: approvePermissions,
                            actionID: prepared.id
                        )
                    } catch is ACPHandshakeUnavailable {
                        throw AgentError.acpHandshakeUnavailable(
                            Self.compatibilityRequest(
                                task: task,
                                cli: arguments.last ?? "",
                                directory: directory
                            )
                        )
                    }
                    guard outcome.status == .completed else {
                        throw AgentError.backendUnavailable(
                            outcome.failure ?? "ACP session did not complete."
                        )
                    }
                    return AgentToolResult(
                        summary: outcome.result ?? "ACP session completed.",
                        reference: outcome.artifacts.first
                    )
                }
        )
        return .completed(result.summary, artifacts: result.reference.map { [$0] } ?? [])
    }

    static func compatibilityPrompt(cli: String) -> String {
        "ACP unavailable for \(cli); no compatibility CLI run was started."
    }

    static func workingDirectory(for task: AgentTask) -> String? {
        task.contextReferences.first(where: { $0.hasPrefix("project://") })
            .map { String($0.dropFirst("project://".count)) }
    }

    static func compatibilityRequest(
        task: AgentTask, cli: String, directory: String?
    ) -> ACPCompatibilityRequest {
        let frozenCLI = resolvedCLIPath(cli) ?? cli
        return ACPCompatibilityRequest(
            cli: frozenCLI,
            objective: task.objective,
            directory: directory,
            command: ACPCompatibilityCLIBackend.commandLine(
                cli: frozenCLI, objective: task.objective
            )
        )
    }

    static func resolvedCLIPath(_ name: String) -> String? { which(name) }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

/// Raised only when ACP failed before `initialize` completed. Prompt/session failures do
/// not offer compatibility mode because the ACP permission and progress contract existed.
private struct ACPHandshakeUnavailable: Error {}
