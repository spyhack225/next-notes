import Foundation

/// Hands sustained coding work to an ACP stdio session (Claude Code, Codex, Qwen Code,
/// OpenCode). Next Notes stays the voice, context and permission layer.
///
/// A CLI that never answers `initialize` is not ACP — we do not call that a session.
/// `cli -p` remains a last-resort execute seam and is labelled as such.
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
            return try await runSession(
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
            return try await runSession(
                command: "/usr/bin/env",
                arguments: [cli],
                directory: directory,
                task: task,
                approvePermissions: false
            )
        } catch {
            Log.agent.error("ACP session failed: \(error.localizedDescription, privacy: .public)")
            return try promptFallback(cli: cli, directory: directory, task: task)
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
        approvePermissions: Bool
    ) async throws -> AgentTaskOutcome {
        let session = ACPSession()
        let token = await session.subscribe { event in
            Task { @MainActor in
                if event.kind == "activity" {
                    AgentActivityStore.shared.update(
                        taskID: task.id,
                        kind: .executing,
                        title: event.title,
                        detail: event.detail
                    )
                    IslandState.shared.showAgentWork(title: event.title)
                }
            }
        }
        do {
            try await session.start(
                command: command,
                arguments: arguments,
                directory: directory,
                taskID: task.id,
                approvePermissions: approvePermissions
            )
            let reply = try await session.prompt(task.objective)
            let sessionID = await session.sessionID ?? ""
            let initialized = await session.didInitialize
            await session.unsubscribe(token)
            await session.close()
            guard initialized, !sessionID.isEmpty else {
                throw JSONRPCError(message: "ACP never started a session.")
            }
            return .completed(reply)
        } catch {
            await session.unsubscribe(token)
            await session.close()
            throw error
        }
    }

    private func promptFallback(
        cli: String,
        directory: String?,
        task: AgentTask
    ) throws -> AgentTaskOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [cli, "-p", task.objective]
        if let directory, !directory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AgentError.backendUnavailable(error.localizedDescription)
        }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let note = "\(cli) did not start an ACP session, so this ran as \(cli) -p."
        if process.terminationStatus != 0 {
            return .failed(err.isEmpty ? "\(note) Exit \(process.terminationStatus)." : "\(note) \(err)")
        }
        return .completed(output.isEmpty ? note : "\(note)\n\(output)")
    }

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
