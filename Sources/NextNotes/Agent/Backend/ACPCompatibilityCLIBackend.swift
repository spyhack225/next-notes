import Foundation
import Darwin

/// The frozen inputs for the one-shot compatibility path. Keeping this separate from
/// `AgentTask` makes it impossible for a later settings change to alter an already
/// reviewable command.
struct ACPCompatibilityRequest: Equatable, Sendable {
    let cli: String
    let objective: String
    let directory: String?
    let command: String

    var failureMessage: String {
        "ACP unavailable. \(command) has not been run. Choose “Run once in compatibility CLI mode” to continue; compatibility mode has weaker progress and permission guarantees."
    }
}

enum CompatibilityCLIError: LocalizedError, Sendable {
    case timedOut
    case failed(exitCode: Int32, output: String)
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Compatibility CLI timed out. No standing permission was created."
        case .failed(let exitCode, let output):
            let detail = output.isEmpty ? "No output." : output
            return "Compatibility CLI exited with \(exitCode). \(detail)"
        case .couldNotStart(let reason):
            return "Compatibility CLI could not start: \(reason)"
        }
    }
}

/// Executes the deliberately weaker CLI contract only after the task manager consumed
/// the user's one-shot approval. It never participates in harness selection and is never
/// called by `ACPAgentBackend.submit`.
enum ACPCompatibilityCLIBackend {
    static let maxOutputBytes = 32 * 1024
    static let timeout: Duration = .seconds(120)

    static func request(for task: AgentTask) -> ACPCompatibilityRequest? {
        let cli = (task.compatibilityCLI ?? task.acpCLI)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cli.isEmpty, !task.objective.isEmpty else { return nil }
        let contextDirectory = task.contextReferences.first(where: { $0.hasPrefix("project://") })
            .map { String($0.dropFirst("project://".count)) }
        // A parked task is reviewed against frozen command and directory values. If its
        // persisted inputs no longer match those values, fail closed instead of executing
        // something different from what the person approved.
        let computedCommand = commandLine(cli: cli, objective: task.objective)
        if let frozenCommand = task.compatibilityCommand, frozenCommand != computedCommand {
            return nil
        }
        if let frozenDirectory = task.compatibilityDirectory, frozenDirectory != contextDirectory {
            return nil
        }
        let directory = task.compatibilityDirectory ?? contextDirectory
        return ACPCompatibilityRequest(
            cli: cli,
            objective: task.objective,
            directory: directory,
            command: task.compatibilityCommand ?? computedCommand
        )
    }

    static func commandLine(cli: String, objective: String) -> String {
        "\(shellQuote(cli)) -p \(shellQuote(objective))"
    }

    /// This entry point is intentionally approval-bearing. Callers must pass the token
    /// consumed by `AgentTaskManager`; a direct backend call cannot silently execute.
    @MainActor
    static func submit(_ task: AgentTask, explicitApproval: Bool) async throws -> AgentTaskOutcome {
        // Weaker permissions than ACP, so never for a routine, allowed harness or not.
        if task.scheduleID != nil || task.source == AgentTask.scheduledSource {
            throw AgentError.permissionDenied("A routine cannot run the compatibility CLI; nothing was run.")
        }
        guard canRun(explicitApproval: explicitApproval), let request = request(for: task) else {
            throw AgentError.permissionDenied(
                "Compatibility CLI mode requires an explicit one-shot approval."
            )
        }

        let tool = AgentTool.native(
            namespace: .mcp,
            name: "acp_compatibility_cli",
            description: "Run one coding task through a compatibility CLI prompt",
            risk: .privileged,
            executionMode: .task,
            title: "Run once in compatibility CLI mode",
            preview: { _ in request.command }
        )
        let intent = ActionIntent(
            source: .agent,
            authority: .user,
            verb: tool.id,
            target: request.directory,
            arguments: [
                "command": request.command,
                "objective": request.objective,
                "workingDirectory": request.directory ?? FileManager.default.currentDirectoryPath,
            ],
            evidence: [ActionContextReference(kind: "task", value: task.id)],
            risk: tool.risk,
            confidence: 1
        )

        do {
            let result = try await ActionOrchestrator.shared.execute(
                intent: intent,
                tool: tool,
                title: "Run once in compatibility CLI mode",
                preparedContent: PreparedContent(
                    title: "Compatibility CLI",
                    visiblePlan: "\(request.command)\nWorking directory: \(request.directory ?? FileManager.default.currentDirectoryPath)\nProgress and permissions are weaker than ACP."
                ),
                routing: ActionRouting(
                    integration: "ACP compatibility CLI",
                    resource: request.directory,
                    taskID: task.id
                ),
                steps: ["launch", "bounded stdout/stderr", "exit"],
                policy: .fromSettings(),
                promptIfNeeded: false,
                // The task card is the explicit approval. This does not create a grant;
                // the privileged tool is still judged and receipted by the broker.
                permissionAlreadyGranted: true,
                allowUnverifiedResult: true,
                fire: { _ in
                    try Task.checkCancellation()
                    let output = try await runProcess(request)
                    return AgentToolResult(
                        summary: output.summary
                    )
                }
            )
            return .completed(result.summary)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CompatibilityCLIError {
            throw AgentError.backendUnavailable(error.localizedDescription)
        }
    }

    /// Pure guard self-test used by the app's existing ACP confirmation flag. It
    /// intentionally never launches a process: the important property is that the
    /// unapproved path is rejected before `ActionOrchestrator` or `Process` is reached.
    @MainActor
    static func runSelfTest() -> Bool { runGuardSelfTest() }

    /// Synchronous companion for the existing ACP confirmation self-test. It checks both
    /// sides of the gate without touching the filesystem or spawning a process.
    static func runGuardSelfTest() -> Bool {
        let task = AgentTask(
            objective: "self-test compatibility command",
            backend: AgentBackendKind.acp.rawValue,
            acpCLI: "claude"
        )
        guard request(for: task) != nil else { return false }
        let reviewedCommand = commandLine(cli: "/usr/bin/true", objective: task.objective)
        let frozen = AgentTask(
            objective: task.objective,
            backend: AgentBackendKind.acp.rawValue,
            compatibilityCommand: reviewedCommand,
            compatibilityCLI: "/usr/bin/true"
        )
        let tampered = AgentTask(
            objective: task.objective,
            backend: AgentBackendKind.acp.rawValue,
            compatibilityCommand: "'/usr/bin/false' -p 'different objective'",
            compatibilityCLI: "/usr/bin/true"
        )
        return !canRun(explicitApproval: false)
            && canRun(explicitApproval: true)
            && request(for: frozen) != nil
            && request(for: tampered) == nil
    }

    static func canRun(explicitApproval: Bool) -> Bool { explicitApproval }

    private struct ProcessOutput: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var summary: String {
            var parts = ["Compatibility CLI completed with exit code \(exitCode) (progress and permissions are weaker than ACP)."]
            if !stdout.isEmpty { parts.append("stdout:\n\(stdout)") }
            if !stderr.isEmpty { parts.append("stderr:\n\(stderr)") }
            return parts.joined(separator: "\n")
        }
    }

    private final class ProcessHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func set(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            self.process = process
        }

        func terminate() {
            lock.lock()
            cancelled = true
            let process = self.process
            let isRunning = process?.isRunning == true
            lock.unlock()
            guard let process, isRunning else { return }
            process.terminate()
            // A compatibility CLI is outside ACP's cancellation protocol. Reap a
            // process that ignores SIGTERM so timeout/cancellation cannot park the task
            // forever while the task group waits for its process child.
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
            }
        }

        /// Atomically checks cancellation with publication of the Process. This closes
        /// the tiny window where cancellation could otherwise arrive after a caller's
        /// check but before `Process.run()`.
        func start(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
    }

    private static func runProcess(_ request: ACPCompatibilityRequest) async throws -> ProcessOutput {
        let holder = ProcessHolder()
        do {
            return try await withTaskCancellationHandler(operation: {
                do {
                    return try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
                        group.addTask {
                            try await launchProcess(request, holder: holder)
                        }
                        group.addTask {
                            try await Task.sleep(for: timeout)
                            // A throwing task group waits for its other child before
                            // unwinding. Stop the process here so that wait can finish.
                            holder.terminate()
                            throw CompatibilityCLIError.timedOut
                        }
                        guard let first = try await group.next() else {
                            throw CompatibilityCLIError.couldNotStart("No process result.")
                        }
                        group.cancelAll()
                        return first
                    }
                } catch {
                    holder.terminate()
                    throw error
                }
            }, onCancel: {
                holder.terminate()
            })
        } catch is CancellationError {
            holder.terminate()
            throw CancellationError()
        }
    }

    private static func launchProcess(
        _ request: ACPCompatibilityRequest,
        holder: ProcessHolder
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.cli)
        process.arguments = ["-p", request.objective]
        if let directory = request.directory, !directory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        holder.set(process)
        do {
            try Task.checkCancellation()
            try holder.start(process)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CompatibilityCLIError.couldNotStart(error.localizedDescription)
        }

        let stdoutTask = Task.detached {
            readBounded(stdoutPipe.fileHandleForReading)
        }
        let stderrTask = Task.detached {
            readBounded(stderrPipe.fileHandleForReading)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        let output = ProcessOutput(
            exitCode: process.terminationStatus,
            stdout: decode(stdout),
            stderr: decode(stderr)
        )
        guard output.exitCode == 0 else {
            throw CompatibilityCLIError.failed(
                exitCode: output.exitCode,
                output: output.summary
            )
        }
        return output
    }

    private static func readBounded(_ handle: FileHandle) -> Data {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 4 * 1024), !chunk.isEmpty {
            if data.count < maxOutputBytes {
                data.append(chunk.prefix(maxOutputBytes - data.count))
            }
        }
        return data
    }

    private static func decode(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return data.count >= maxOutputBytes ? text + "\n[output truncated at 32 KiB]" : text
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
