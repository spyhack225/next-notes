import Foundation
import CryptoKit

/// Hands sustained coding work to an ACP stdio session (Claude Code, Codex, Qwen Code,
/// OpenCode). Next Notes stays the voice, context and permission layer.
///
/// A CLI that never answers `initialize` is not ACP — we do not call that a session or
/// silently reinterpret it as an opaque prompt command.
struct ACPAgentBackend: AgentBackend {
    /// The provider names are stable app settings. The process behind each name is
    /// resolved here so selecting Codex or Claude can never accidentally launch their
    /// ordinary, non-ACP CLIs. The adapter versions are pinned in the install guidance
    /// because a moving package would make a release's protocol contract change beneath
    /// the user.
    static let codexAdapterPackage = "@agentclientprotocol/codex-acp@1.11.0"
    static let claudeAdapterPackage = "@agentclientprotocol/claude-agent-acp@0.76.0"

    struct Invocation: Equatable, Sendable {
        let command: String
        let arguments: [String]
        let summary: String
    }

    /// Why a scheduled task may not start a coding session, or nil for any other task.
    static func scheduledRefusal(for task: AgentTask) async -> String? {
        guard task.source == AgentTask.scheduledSource || task.scheduleID != nil else { return nil }
        guard let scheduleID = task.scheduleID else {
            return "A scheduled coding task without its routine was refused."
        }
        let allowed = await MainActor.run { ScheduleStore.shared.schedule(id: scheduleID)?.allowedTools ?? [] }
        let harness = task.acpCLI.isEmpty ? "acp" : "acp.\(task.acpCLI)"
        guard allowed.contains(harness) || allowed.contains("acp") else {
            return "A routine cannot start a coding agent unless it was set up to use one; nothing was run."
        }
        return nil
    }

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
        if let found = Self.installedCLI(preferring: preferred),
           let invocation = Self.invocation(for: found) {
            return "ready (\(found) · \(invocation.summary))"
        }
        return "unavailable — \(Self.installationGuidance(for: preferred))"
    }

    func submit(_ task: AgentTask) async throws -> AgentTaskOutcome {
        // Before anything launches, fixture or not: a scheduled coding session is refused
        // unless its routine explicitly allows this harness — and even then it gets no
        // auto-approved permissions, so the orchestrator refuses its privileged session
        // under `.scheduled` authority rather than waiting on a person who is not there.
        if let refusal = await Self.scheduledRefusal(for: task) {
            throw AgentError.permissionDenied(refusal)
        }
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
                Self.installationGuidance(for: preferred)
            )
        }
        guard let invocation = Self.invocation(for: cli) else {
            throw AgentError.backendUnavailable(Self.installationGuidance(for: cli))
        }
        let directory = task.contextReferences.first(where: { $0.hasPrefix("project://") })
            .map { String($0.dropFirst("project://".count)) }

        do {
            return try await runSessionWithReceipt(
                command: invocation.command,
                arguments: invocation.arguments,
                directory: directory,
                task: task,
                approvePermissions: false,
                compatibilityCLI: cli
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
        // An explicit setting is a choice, not a hint. Falling through to another
        // provider would hide a missing adapter and could run the wrong account.
        let candidates = preferred.isEmpty
            ? ["claude", "codex", "qwen", "opencode", "kimi"]
            : [preferred]
        for name in candidates where !name.isEmpty {
            if invocation(for: name) != nil { return name }
        }
        return nil
    }

    static func isOnPATH(_ name: String) -> Bool {
        !name.isEmpty && invocation(for: name) != nil
    }

    /// Resolve a provider name into an ACP-speaking process. A configured path or
    /// executable name remains a direct custom ACP command; only the built-in names
    /// receive provider-specific adapter arguments.
    static func invocation(for name: String) -> Invocation? {
        guard !name.isEmpty else { return nil }
        switch name {
        case "codex":
            if let adapter = which("codex-acp") {
                return Invocation(
                    command: "/usr/bin/env", arguments: [adapter],
                    summary: "codex-acp"
                )
            }
            return nil
        case "claude":
            if let adapter = which("claude-agent-acp") {
                return Invocation(
                    command: "/usr/bin/env", arguments: [adapter],
                    summary: "claude-agent-acp"
                )
            }
            return nil
        case "qwen":
            guard let qwen = which("qwen") else { return nil }
            return Invocation(
                command: "/usr/bin/env", arguments: [qwen, "--acp"],
                summary: "qwen --acp"
            )
        case "opencode":
            guard let opencode = which("opencode") else { return nil }
            return Invocation(
                command: "/usr/bin/env", arguments: [opencode, "acp"],
                summary: "opencode acp"
            )
        default:
            guard let path = resolvedCLIPath(name) else { return nil }
            return Invocation(
                command: "/usr/bin/env", arguments: [path],
                summary: path
            )
        }
    }

    static func installationGuidance(for name: String) -> String {
        switch name {
        case "codex":
            return "Codex ACP is unavailable. Install \(codexAdapterPackage) globally, then retry."
        case "claude":
            return "Claude ACP is unavailable. Install \(claudeAdapterPackage) globally, then retry."
        case "qwen":
            return "Qwen Code is unavailable. Install Qwen Code with its --acp mode, then retry."
        case "opencode":
            return "OpenCode ACP is unavailable. Install OpenCode with its acp subcommand, then retry."
        case "":
            return "Install an ACP adapter for Claude Code or Codex, then pick it in Settings ▸ Agent."
        default:
            return "The configured ACP command \(name) is unavailable. Install it or choose another in Settings ▸ Agent."
        }
    }

    static func statusText(for preferred: String) -> String {
        guard let provider = installedCLI(preferring: preferred),
              let invocation = invocation(for: provider) else {
            return installationGuidance(for: preferred)
        }
        return "Ready · \(provider) via \(invocation.summary)"
    }

    /// Returns a compact, deterministic contract check for the built-in provider map.
    /// It runs in the live ACP selftest without downloading packages.
    static func resolutionSelfTest() -> [String] {
        var failures: [String] = []
        if let invocation = invocation(for: "codex"),
           URL(fileURLWithPath: invocation.arguments.last ?? "").lastPathComponent != "codex-acp" {
            failures.append("Codex does not resolve to the codex-acp executable")
        }
        if let invocation = invocation(for: "claude"),
           URL(fileURLWithPath: invocation.arguments.last ?? "").lastPathComponent != "claude-agent-acp" {
            failures.append("Claude does not resolve to the claude-agent-acp executable")
        }
        if let qwen = invocation(for: "qwen"),
           qwen.arguments.count != 2 || !qwen.arguments.contains("--acp") {
            failures.append("Qwen resolution omitted --acp")
        }
        if let opencode = invocation(for: "opencode"),
           opencode.arguments.count != 2 || !opencode.arguments.contains("acp") {
            failures.append("OpenCode resolution omitted acp")
        }
        return failures
    }

    /// Live provider smoke test for support and release acceptance. It uses a temporary
    /// directory and a no-tool prompt; if no official adapter can be resolved, it fails
    /// instead of passing through the ordinary provider CLI.
    static func runLiveProviderSelfTest() async -> [String] {
        let providers = ["codex", "claude"]
        var failures: [String] = []
        var exercised = 0
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-acp-live-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for provider in providers {
                guard let invocation = invocation(for: provider) else { continue }
                exercised += 1
                let session = ACPSession()
                do {
                    try await session.start(
                        command: invocation.command,
                        arguments: invocation.arguments,
                        directory: root.path,
                        taskID: "selftest-acp-live-\(provider)",
                        approvePermissions: false
                    )
                    let reply = try await session.prompt(
                        "Reply exactly NEXTNOTES_ACP_\(provider.uppercased())_OK. "
                            + "Do not use tools, edit files, or access the network."
                    )
                    let initialized = await session.didInitialize
                    let sessionID = await session.sessionID ?? ""
                    if !initialized || sessionID.isEmpty || !reply.contains("NEXTNOTES_ACP_\(provider.uppercased())_OK") {
                        failures.append("\(provider) adapter completed without a valid ACP reply")
                    }
                } catch {
                    failures.append("\(provider) adapter: \(error.localizedDescription)")
                }
                await session.close()
            }
        } catch {
            failures.append("could not create isolated ACP directory: \(error.localizedDescription)")
        }
        if exercised == 0 {
            failures.append("no official Codex or Claude ACP adapter is available")
        }
        return failures
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
    /// `couldNotVerify` after a successful protocol reply unless the checkout's contents
    /// changed. A protocol success sentence alone cannot prove an edit landed.
    private func runSessionWithReceipt(
        command: String,
        arguments: [String],
        directory: String? = nil,
        task: AgentTask,
        approvePermissions: Bool,
        compatibilityCLI: String? = nil
    ) async throws -> AgentTaskOutcome {
        let tool = AgentTool.native(
            namespace: .mcp,
            name: "acp_session",
            description: "Run one sustained ACP coding session",
            risk: .privileged,
            executionMode: .task,
            title: "Run ACP coding task"
        )
        let authority: ActionAuthority = if let scheduleID = task.scheduleID {
            .scheduled(scheduleID)
        } else if task.isUserInitiated {
            .user
        } else {
            .systemDerived
        }
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
                // Creating an ACP task is already an explicit user action — but only a task
                // the user started. Meeting-origin and scheduled tasks retain the broker
                // boundary and cannot self-authorize; this used to infer approval from any
                // source that was not "meeting".
                permissionAlreadyGranted: task.scheduleID == nil && (approvePermissions || task.isUserInitiated),
                allowUnverifiedResult: true,
                fire: { [self] prepared in
                    try Task.checkCancellation()
                    let before = directory.flatMap(ACPWorkspaceVerification.capture)
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
                                cli: compatibilityCLI ?? arguments.last ?? "",
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
                        reference: outcome.artifacts.first,
                        verification: directory.flatMap { path in
                            guard let before,
                                  let after = ACPWorkspaceVerification.capture(path),
                                  before != after else { return nil }
                            return "ACP checkout content changed; review the edited files"
                        }
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
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        // LaunchServices does not inherit the interactive shell's PATH. Homebrew's
        // global npm prefix is therefore searched explicitly so the installed official
        // adapters work when Next Notes is launched from Finder or `open`.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(home)/.local/bin", "\(home)/Library/pnpm", "\(home)/.opencode/bin",
        ]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Raised only when ACP failed before `initialize` completed. Prompt/session failures do
/// not offer compatibility mode because the ACP permission and progress contract existed.
private struct ACPHandshakeUnavailable: Error {}

/// Snapshot the approved checkout's tracked diff and untracked file contents. Capturing
/// both sides of the ACP session detects an actual edit even when a file was already dirty
/// before the session began. A non-Git directory stays unverified.
enum ACPWorkspaceVerification {
    static func runSelfTest() -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-acp-verification-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("example.txt")
            try "before".write(to: file, atomically: true, encoding: .utf8)
            guard git(["init", "-q"], in: directory.path) != nil,
                  git(["add", "example.txt"], in: directory.path) != nil,
                  git(["-c", "user.name=Next Notes Test", "-c", "user.email=test@nextnotes.invalid",
                       "commit", "-qm", "baseline"], in: directory.path) != nil,
                  let before = capture(directory.path) else { return false }
            try "after".write(to: file, atomically: true, encoding: .utf8)
            guard let after = capture(directory.path), after != before else { return false }
            return capture(directory.path) == after
        } catch { return false }
    }

    static func capture(_ directory: String) -> String? {
        guard let head = git(["rev-parse", "HEAD"], in: directory),
              let diff = git(["diff", "--binary", "HEAD", "--"], in: directory),
              let untracked = git(["ls-files", "--others", "--exclude-standard", "-z"], in: directory)
        else { return nil }
        var digest = SHA256()
        digest.update(data: head)
        digest.update(data: diff)
        for name in untracked.split(separator: 0) {
            guard let path = String(data: Data(name), encoding: .utf8) else { continue }
            digest.update(data: Data(name))
            let url = URL(fileURLWithPath: directory).appendingPathComponent(path)
            if let content = try? Data(contentsOf: url) { digest.update(data: content) }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func git(_ arguments: [String], in directory: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
