import Foundation

/// Handing "click that", "open Safari", "read the front window" to Codex.
///
/// ## What Codex computer use actually is on a Mac
///
/// Codex ships a separate helper app, `~/.codex/computer-use/Codex Computer Use.app`
/// (`com.openai.sky.CUAService`, shown to people as "ChatGPT Computer Use"). Inside it is a
/// small stdio MCP server — `SkyComputerUseClient mcp` — offering ten tools: `list_apps`,
/// `get_app_state`, `click`, `type_text`, `press_key`, `scroll`, `drag`, `set_value`,
/// `select_text` and `perform_secondary_action`. That server is what does the clicking.
///
/// Next Notes cannot talk to that server directly. It authenticates the process on the other
/// end of the pipe by code signature, not by a token: the binary carries an allow-list of
/// OpenAI bundle identifiers (`com.openai.chat*`, `com.openai.codex*`, `com.openai.atlas*`)
/// under team `2DC432GLL2`, and compares them against the caller's parent and responsible
/// process. A handshake from anything else completes, and then every tool call comes back
/// `Computer Use server error -10000: Sender process is not authenticated`. That is a
/// deliberate gate, and working around it would mean forging or borrowing an identity, so
/// this file does not try.
///
/// What is supported is the front door: the `codex` CLI. It is signed by OpenAI, it loads
/// the bundled `computer-use` plugin, and it is allowed through. `codex exec "<objective>"`
/// therefore does real computer use, and it works when another program starts it — which is
/// the whole reason this route exists rather than a grey dot.
///
/// ## What that costs, said plainly
///
/// Codex runs its own loop once the objective is handed over, so Next Notes cannot sit
/// between Codex and each individual click. The approval it can enforce is the hand-off
/// itself, which is what `approve` below does: one ask, carrying the objective the person
/// will be shown, honouring "Click and type without asking" exactly as the built-in computer
/// tools do. `--sandbox read-only` is passed so the same turn cannot also rewrite files.
enum CodexComputerUse {

    // MARK: - Where the pieces live

    /// Preferred first. OpenAI's own issue tracker has repeated reports of package-manager
    /// builds of the CLI being refused by the helper while the copy inside the Codex app is
    /// accepted, so the app's copy is tried before anything on `PATH`.
    private static let cliCandidates: [String] = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        NSHomeDirectory() + "/.local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex",
    ]

    private static var codexHome: String { NSHomeDirectory() + "/.codex" }

    /// The helper that owns the screen. Present only once computer use has been set up.
    private static var helperPath: String {
        codexHome + "/computer-use/Codex Computer Use.app/Contents/SharedSupport/"
            + "SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
    }

    private static var authPath: String { codexHome + "/auth.json" }
    private static var configPath: String { codexHome + "/config.toml" }

    /// The first CLI on this Mac, or nil. Pure filesystem: no subprocess, and no dependence
    /// on an interactive shell's `PATH`, which a launched app does not inherit.
    static func resolvedCLI() -> String? {
        cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Readiness

    /// Asks this Mac whether the hand-off would work *right now*, without side effects:
    /// nothing is launched, no window appears, no token is read out of the file it is in.
    ///
    /// Every answer but `.ready` carries one sentence naming what is missing and what to do,
    /// because a grey dot with no sentence is the thing this screen exists to prevent.
    static func probe() -> CodexComputerUseReadiness {
        guard resolvedCLI() != nil else { return .codexMissing }
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return .helperMissing
        }
        guard isSignedIn() else { return .notSignedIn }
        guard !isSwitchedOff() else { return .switchedOff }
        return .ready
    }

    /// Signed in when Codex has stored either a ChatGPT session or an API key. Only the
    /// *shape* of the file is inspected — the values are never read into a string, logged or
    /// carried anywhere.
    private static func isSignedIn() -> Bool {
        guard let data = FileManager.default.contents(atPath: authPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty { return true }
        guard let tokens = root["tokens"] as? [String: Any] else { return false }
        return (tokens["access_token"] as? String)?.isEmpty == false
            || (tokens["refresh_token"] as? String)?.isEmpty == false
    }

    /// Codex's bundled computer-use plugins are on unless the person switched them off in
    /// Codex. Absence therefore means on: a config file that never mentions them is the
    /// normal case, and reading it as "off" would grey out a row that works.
    private static func isSwitchedOff() -> Bool {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return false
        }
        let plugins = ["computer-use@openai-bundled", "unified-computer-use@openai-bundled"]
        var sawOne = false
        for plugin in plugins {
            guard let range = text.range(of: "[plugins.\"\(plugin)\"]") else { continue }
            // Just the lines belonging to this table, up to the next one.
            let rest = text[range.upperBound...]
            let body = rest.range(of: "\n[").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            let enabled = !body.contains("enabled = false") && !body.contains("enabled=false")
            if enabled { return false }
            sawOne = true
        }
        return sawOne
    }

    // MARK: - Running one objective

    /// Codex is given one turn and a wall clock. Long enough for a handful of clicks in a
    /// slow app, short enough that a wedged hand-off does not hold a conversation open.
    static let timeout: Duration = .seconds(180)
    private static let maxOutputBytes = 32 * 1024

    enum HandoffError: LocalizedError, Equatable {
        case notReady(CodexComputerUseReadiness)
        case declined
        case timedOut
        case couldNotStart(String)
        case failed(exitCode: Int32, output: String)

        /// Deliberately one sentence each, and never a stack trace: these are read out in a
        /// conversation, next to the thing the person actually asked for.
        var errorDescription: String? {
            switch self {
            case .notReady(let readiness):
                return readiness.note ?? "Codex can’t control this Mac right now."
            case .declined:
                return "I didn’t hand that to Codex."
            case .timedOut:
                return "Codex took too long, so I stopped it."
            case .couldNotStart(let reason):
                return "Codex wouldn’t start: \(reason)"
            case .failed(_, let output):
                let line = output.split(separator: "\n").last.map(String.init) ?? ""
                return line.isEmpty ? "Codex couldn’t finish that." : "Codex stopped: \(line)"
            }
        }
    }

    /// Asks once, then hands the objective over.
    ///
    /// - Parameter taskID: ties progress to the same activity row the ACP route uses, so
    ///   work done by Codex looks like every other piece of background work.
    /// - Returns: what Codex said it did.
    static func run(objective: String, taskID: String) async throws -> String {
        let readiness = probe()
        guard readiness.isReady, let cli = resolvedCLI() else {
            throw HandoffError.notReady(readiness)
        }
        guard await approve(objective: objective, taskID: taskID) else {
            throw HandoffError.declined
        }
        await report(taskID: taskID, title: "Codex is using your Mac", detail: objective)
        let output = try await runProcess(cli: cli, objective: objective, taskID: taskID)
        await report(taskID: taskID, title: "Codex finished", detail: output)
        return output
    }

    /// What a turn should do with this request.
    enum Outcome: Sendable, Equatable {
        /// Codex handled it. This is the answer.
        case done(String)
        /// Codex could not, for the reason in this one sentence. The turn carries on with
        /// the built-in model and says the sentence first.
        case fellBack(String)
    }

    /// The one line a turn asks: is this mine, and how did it go?
    ///
    /// Nil means "not this turn" — either the request was not about the screen, or the
    /// person has this job pointed somewhere else. Everything else is decided by the same
    /// resolution the Settings dot draws, so a green dot and a hand-off cannot disagree.
    @MainActor
    static func route(_ prompt: String) async -> Outcome? {
        guard ModelRoleStore.role(forUtterance: prompt) == .computerUse,
              ModelRoleStore.shared.computerUseHarness == .codex else { return nil }
        let taskID = "codex-computer-" + UUID().uuidString.prefix(8)
        do {
            return .done(try await run(objective: prompt, taskID: String(taskID)))
        } catch HandoffError.declined {
            // A no is an answer, not a reason to do it a different way.
            return .done("I didn’t hand that to Codex.")
        } catch is CancellationError {
            return .done("Stopped.")
        } catch let error as HandoffError {
            return .fellBack(
                (error.errorDescription ?? "Codex couldn’t do that.") + " I’ll do it myself."
            )
        } catch {
            return .fellBack("Codex couldn’t do that, so I’ll do it myself.")
        }
    }

    /// One ask for the whole hand-off, carrying the words the person used.
    ///
    /// Filed as a `.computer`/`.modify` tool on purpose: that is the same class as the
    /// built-in click and type, so "Click and type without asking" in Settings covers this
    /// exactly as it covers those, and nothing stronger runs unasked.
    @MainActor
    private static func approve(objective: String, taskID: String) async -> Bool {
        let tool = AgentTool.native(
            namespace: .computer,
            name: "codex_handoff",
            description: "Let Codex click and type on this Mac to carry out one request",
            risk: .modify,
            executionMode: .task,
            title: "Let Codex use your Mac",
            preview: { arguments in arguments["objective"] }
        )
        let arguments = ["objective": objective]
        let decision = await PermissionBroker.shared.authorize(
            tool, arguments: arguments, policy: PermissionPolicy.fromSettings(),
            scope: .any, taskID: taskID
        )
        switch decision {
        case .allow: return true
        case .deny: return false
        case .ask(let request): return await PermissionGate.shared.ask(request)
        }
    }

    @MainActor
    private static func report(taskID: String, title: String, detail: String) {
        AgentActivityStore.shared.update(
            taskID: taskID, kind: .executing, title: title, detail: detail
        )
        IslandState.shared.showBackgroundAgentWork(title: title)
    }

    /// What Codex is told before the person's own words. Narrow on purpose: this turn exists
    /// to drive the screen, not to open a project and start editing it.
    static func framedObjective(_ objective: String) -> String {
        """
        Use your computer-use tools to do the following on this Mac, then stop and say in one \
        or two plain sentences what you did. Do not edit, create or delete any file. Do not \
        run shell commands. Do not start any long-running process. If you cannot do it, say \
        so in one sentence instead of trying something else.

        \(objective)
        """
    }

    private static func arguments(for objective: String) -> [String] {
        [
            "exec",
            "--skip-git-repo-check",
            // Codex's own file sandbox. The screen is the point of this turn; the disk is not.
            "--sandbox", "read-only",
            framedObjective(objective),
        ]
    }

    // MARK: - The process

    private static func runProcess(
        cli: String, objective: String, taskID: String
    ) async throws -> String {
        let holder = ProcessHolder()
        do {
            return try await withTaskCancellationHandler(operation: {
                do {
                    return try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            try await launch(cli: cli, objective: objective, holder: holder)
                        }
                        group.addTask {
                            try await Task.sleep(for: timeout)
                            // A throwing group waits for its other child before it unwinds,
                            // so the process has to be stopped here for that wait to end.
                            holder.terminate()
                            throw HandoffError.timedOut
                        }
                        guard let first = try await group.next() else {
                            throw HandoffError.couldNotStart("No result.")
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

    private static func launch(
        cli: String, objective: String, holder: ProcessHolder
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments(for: objective)
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // `codex exec` reads an objective from stdin when none is on the command line. One
        // is, so stdin is closed rather than inherited — an inherited one makes it wait.
        process.standardInput = FileHandle.nullDevice
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
            throw HandoffError.couldNotStart(error.localizedDescription)
        }

        let stdoutTask = Task.detached { readBounded(stdoutPipe.fileHandleForReading) }
        let stderrTask = Task.detached { readBounded(stderrPipe.fileHandleForReading) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        let stdout = decode(await stdoutTask.value)
        let stderr = decode(await stderrTask.value)
        guard process.terminationStatus == 0 else {
            throw HandoffError.failed(
                exitCode: process.terminationStatus,
                output: stderr.isEmpty ? stdout : stderr
            )
        }
        return reply(fromTranscript: stdout)
    }

    /// `codex exec` prints a banner, then the transcript of the turn, then a `tokens used`
    /// footer, and last of all the answer on its own. Only that answer is worth reading
    /// back — the rest is Codex talking to its operator, not to the person who asked.
    ///
    /// The footer is the landmark, because the answer also appears *inside* the transcript
    /// above it: walking backwards without one collects the same sentence twice and the
    /// word "codex" with it. Without a footer — a run that died early — the last paragraph
    /// is the next best thing, and is the same answer in the ordinary case.
    static func reply(fromTranscript transcript: String) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func isFooter(_ line: String) -> Bool {
            line == "tokens used" || (!line.isEmpty && line.allSatisfy { $0.isNumber || $0 == "," })
        }
        var tail: [String]
        if let footer = lines.lastIndex(of: "tokens used") {
            tail = Array(lines[lines.index(after: footer)...])
        } else {
            // Back over the trailing blank lines, then take the paragraph above them.
            var end = lines.count
            while end > 0, lines[end - 1].isEmpty { end -= 1 }
            var start = end
            while start > 0, !lines[start - 1].isEmpty { start -= 1 }
            tail = Array(lines[start..<end])
        }
        let reply = tail.filter { !$0.isEmpty && !isFooter($0) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? "Codex finished." : reply
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
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SIGTERM, then SIGKILL for anything that ignores it, so a timeout or a cancelled turn
    /// cannot park this task forever waiting on a child.
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
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
            }
        }

        /// Checks cancellation and publishes the process under one lock, closing the window
        /// where a cancel could land after the check but before `run()`.
        func start(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
    }
}

/// Whether Codex can drive this Mac, and what to say when it cannot.
///
/// Lives beside the probe rather than inside `ModelRoleAvailability` so a self-test can build
/// every case by hand and check the dot against it, without a Codex install.
enum CodexComputerUseReadiness: String, Sendable, Equatable, CaseIterable, Codable {
    /// The app, the helper and a signed-in account are all there.
    case ready
    case codexMissing
    case helperMissing
    case notSignedIn
    case switchedOff

    var isReady: Bool { self == .ready }

    /// One sentence: what is missing, and the smallest thing that fixes it. Nil when ready,
    /// because a row that works has nothing to explain.
    var note: String? {
        switch self {
        case .ready:
            return nil
        case .codexMissing:
            return "Codex isn’t on this Mac, so Next Notes will use its own model. "
                + "Install the Codex app to use this."
        case .helperMissing:
            return "Codex is here but the part that controls your Mac isn’t set up yet — "
                + "open Codex once and switch it on."
        case .notSignedIn:
            return "Codex is installed but not signed in — open Codex once."
        case .switchedOff:
            return "Controlling your Mac is switched off inside Codex — turn it back on there."
        }
    }

    /// The same fact in three or four words, for the line next to the name in the picker.
    var menuDetail: String {
        switch self {
        case .ready: "Ready"
        case .codexMissing: "Not installed"
        case .helperMissing: "Not set up yet"
        case .notSignedIn: "Not signed in"
        case .switchedOff: "Switched off in Codex"
        }
    }
}
