import Foundation

/// Controlled CLI execution. Not an unrestricted "run whatever the model typed" tool —
/// privileged commands are refused, output is capped, and a long run is cancellable.
enum ShellExecutor {
    private static let outputCap = 8_000
    private static let privilegedPrefixes = ["sudo", "su ", "osascript", "installer", "rm -rf /"]

    @MainActor
    static func run(_ tool: AgentTool, arguments: [String: String]) async throws -> AgentToolResult {
        switch tool.name {
        case "run":
            return try await launch(command: arguments["command"] ?? "", directory: arguments["directory"])
        case "status":
            return status(id: arguments["id"] ?? "")
        case "cancel":
            return try cancel(id: arguments["id"] ?? "")
        default:
            throw AgentError.unknownTool(tool.id)
        }
    }

    @MainActor
    private static func launch(command: String, directory: String?) async throws -> AgentToolResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentError.missingArgument(name: "command", tool: "shell.run")
        }
        if privilegedPrefixes.contains(where: { trimmed.lowercased().hasPrefix($0) }) {
            throw AgentError.permissionDenied("Privileged shell commands are not run from the agent.")
        }
        let process = ShellProcess.start(command: trimmed, directory: directory)
        let finished = await process.wait()
        return AgentToolResult(
            summary: finished.summary,
            reference: finished.id
        )
    }

    @MainActor
    private static func status(id: String) -> AgentToolResult {
        guard let process = ShellProcessStore.shared.process(id: id) else {
            return AgentToolResult(summary: "No shell process \(id).")
        }
        return AgentToolResult(summary: process.snapshot.summary, reference: id)
    }

    @MainActor
    private static func cancel(id: String) throws -> AgentToolResult {
        guard let process = ShellProcessStore.shared.process(id: id) else {
            throw AgentError.unknownTool("No shell process \(id).")
        }
        process.cancel()
        return AgentToolResult(summary: "Cancelled \(id).", reference: id)
    }
}

struct ShellProcessSnapshot: Sendable {
    var id: String
    var command: String
    var workingDirectory: String
    var status: String
    var stdout: String
    var stderr: String
    var exitCode: Int32?
    var startedAt: Date
    var completedAt: Date?

    var summary: String {
        var lines = [
            "command: \(command)",
            "directory: \(workingDirectory)",
            "status: \(status)",
        ]
        if let exitCode { lines.append("exit: \(exitCode)") }
        if !stdout.isEmpty { lines.append("stdout:\n\(stdout)") }
        if !stderr.isEmpty { lines.append("stderr:\n\(stderr)") }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class ShellProcess {
    let id: String
    let command: String
    let workingDirectory: String
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdout = ""
    private var stderr = ""
    private var startedAt = Date()
    private var completedAt: Date?
    private var exitCode: Int32?
    private var continuation: CheckedContinuation<ShellProcessSnapshot, Never>?

    private init(id: String, command: String, directory: String?) {
        self.id = id
        self.command = command
        workingDirectory = directory ?? FileManager.default.currentDirectoryPath
    }

    static func start(command: String, directory: String?) -> ShellProcess {
        let process = ShellProcess(id: UUID().uuidString, command: command, directory: directory)
        ShellProcessStore.shared.add(process)
        process.launch()
        return process
    }

    var snapshot: ShellProcessSnapshot {
        ShellProcessSnapshot(
            id: id,
            command: command,
            workingDirectory: workingDirectory,
            status: completedAt == nil ? "running" : (exitCode == 0 ? "completed" : "failed"),
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    func wait() async -> ShellProcessSnapshot {
        if completedAt != nil { return snapshot }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func launch() {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        startedAt = Date()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.stdout.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.stderr.append(chunk) }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.finish(code: finished.terminationStatus) }
        }
        do {
            try process.run()
        } catch {
            finish(code: 1, extraError: error.localizedDescription)
        }
    }

    private func finish(code: Int32, extraError: String? = nil) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        exitCode = code
        completedAt = Date()
        if let extraError { stderr.append(extraError) }
        if stdout.count > 8_000 { stdout = String(stdout.prefix(8_000)) + "\n…" }
        if stderr.count > 8_000 { stderr = String(stderr.prefix(8_000)) + "\n…" }
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

@MainActor
final class ShellProcessStore {
    static let shared = ShellProcessStore()
    private var processes: [String: ShellProcess] = [:]

    func add(_ process: ShellProcess) { processes[process.id] = process }
    func process(id: String) -> ShellProcess? { processes[id] }
}
