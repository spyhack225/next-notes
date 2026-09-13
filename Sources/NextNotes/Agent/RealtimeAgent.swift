import Foundation
import Observation

enum AgentUtteranceSource: String, Sendable {
    case voice
    case text
    case meeting
}

struct AgentTurn: Sendable {
    var reply: String
    var delegated: Bool
}

/// Persistent conversational agent. One resolve, one action, always a visible reply.
///
/// There is no second “ask the model to invent a tool call” path. That wait is how
/// mail sat in Thinking… until the user pressed Stop. Open-ended chat is an honest
/// “ask me to do a thing”, not a 50-second hang.
@MainActor
@Observable
final class RealtimeAgent {
    static let shared = RealtimeAgent()

    enum Limits {
        /// Workspace and file reads. A second path used to add 50 s of model time
        /// on top of this; that is gone.
        static let tool: Duration = .seconds(20)
        static let captureFinish: Duration = .seconds(8)
    }

    static let bargeInReply = "Still listening."
    static let unknownReply =
        "Say what to do: check mail, the calendar, this window, or find a file."
    private(set) var lastReply = ""
    private(set) var isThinking = false
    private(set) var progressTitle = "Thinking…"
    private(set) var harnessLine = ""
    /// Same job as `DictationController.session`: a late tool must not write over a
    /// turn the user already stopped or barged in on.
    private var generation = 0

    private init() {}

    func handle(_ utterance: String, source: AgentUtteranceSource) async -> AgentTurn {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let reply = "I didn’t catch that."
            finish(reply)
            return AgentTurn(reply: reply, delegated: false)
        }

        generation += 1
        let mine = generation
        AgentSession.shared.recordUser(text)
        Log.agent.info("realtime · heard \(text, privacy: .public)")

        let choice = AgentHarnessRouter.shared.choose(for: text)
        let intent = AgentTurnIntent.resolve(text, choice: choice)

        switch intent {
        case .capabilities:
            return conclude(mine, Self.capabilitiesReply(for: text) ?? Self.unknownReply, route: "capabilities")
        case .reply(let answer):
            return conclude(mine, answer, route: "context")
        case .unknown:
            return conclude(mine, Self.unknownReply, route: "unknown")
        case .delegate:
            applyHarness(choice)
            return conclude(
                mine,
                delegate(text, source: source, choice: choice),
                delegated: true,
                route: "task"
            )
        case .calendar, .mail, .files, .drive, .computer:
            beginWork(title: intent.progressTitle)
            let boxed = await withBoundedWait(Limits.tool) {
                await RealtimeAgent.shared.perform(intent)
            }
            if !isCurrent(mine) {
                return AgentTurn(reply: lastReply, delegated: false)
            }
            if let reply = boxed {
                return conclude(mine, reply, route: "tool")
            }
            Log.agent.error("realtime · tool timed out")
            return conclude(
                mine,
                "That took too long, so I stopped waiting. Ask again, or ask “what can you do”.",
                route: "timeout"
            )
        }
    }

    /// Island Stop when there is no open session: cancel and leave a visible line.
    func cancel() {
        guard isThinking || ActivationController.shared.mode == .agentWorking else { return }
        generation += 1
        PermissionGate.shared.cancelPending()
        Log.agent.info("realtime · stopped")
        finish("Stopped.")
    }

    /// Barge-in: drop the in-flight tool so the new speech can become the next turn.
    /// Always leaves a line — silent interrupt is how three user messages stacked
    /// with no reply.
    func interrupt() {
        guard isThinking else { return }
        generation += 1
        PermissionGate.shared.cancelPending()
        Log.agent.info("realtime · barge-in")
        finish(Self.bargeInReply)
    }

    /// Capability / help questions must not wait on a 7 GB download.
    static func capabilitiesReply(for text: String) -> String? {
        let lowered = text.lowercased()
        let marks = [
            "what can you do", "what do you do", "what can you help",
            "what are you", "who are you", "capabilities",
            "what can i ask", "how do you work",
        ]
        let isHelp = lowered == "help" || lowered == "help me" || lowered.hasPrefix("help ")
        guard isHelp || marks.contains(where: { lowered.contains($0) }) else { return nil }
        return """
            I can:
            • Answer from this meeting — action items, decisions, who is on the call
            • Check your calendar
            • Inspect, click and type in the frontmost window
            • Search files and run a shell command, after you approve
            • Wake from sleep when you say “Hey Next”
            • Draft Gmail, Calendar, Drive and Docs actions if Workspace is connected

            Ask something specific — mail, calendar, this window, or a file.
            """
    }

    private func applyHarness(_ choice: AgentHarnessChoice) {
        harnessLine = choice.usingLine
        progressTitle = choice.usingLine
        IslandState.shared.showAgentWork(title: choice.usingLine)
    }

    private func delegate(
        _ text: String,
        source: AgentUtteranceSource,
        choice: AgentHarnessChoice
    ) -> String {
        let intent = AgentHarnessRouter.intent(for: text)
        let backend = choice.backend
        if !SelfTest.isRunning {
            let task = AgentTaskManager.shared.submit(
                objective: text,
                contextReferences: AgentContext.current.references,
                meetingID: MeetingContextStore.shared.current?.meetingID,
                backend: backend,
                acpCLI: choice.acpCLI,
                source: source.rawValue
            )
            AgentAuditLog.shared.record(kind: .task, title: task.objective, taskID: task.id)
        }
        AgentHarnessRouter.shared.record(choice, snippet: text, intent: intent)
        var reply = "I’ll work on that in the background. \(choice.usingLine)."
        if !choice.note.isEmpty {
            reply = choice.note + " " + reply
        }
        return reply
    }

    private func beginWork(title: String) {
        isThinking = true
        progressTitle = title.isEmpty ? "Working…" : title
        ActivationController.shared.markWorking()
        IslandState.shared.showAgentWork(title: progressTitle)
    }

    private func isCurrent(_ mine: Int) -> Bool {
        generation == mine && !Task.isCancelled
    }

    private func conclude(
        _ mine: Int,
        _ reply: String,
        delegated: Bool = false,
        route: String
    ) -> AgentTurn {
        guard isCurrent(mine) else {
            return AgentTurn(reply: lastReply, delegated: false)
        }
        Log.agent.info("realtime · \(route, privacy: .public)")
        finish(reply)
        return AgentTurn(reply: reply, delegated: delegated)
    }

    private func finish(_ reply: String) {
        lastReply = reply
        isThinking = false
        progressTitle = ""
        AgentSession.shared.recordAssistant(reply)
        AgentAuditLog.shared.record(kind: .reply, title: reply)
        AgentCaptureController.shared.noteAssistantReply(reply)
        if AgentCaptureController.shared.isSessionActive {
            ActivationController.shared.markListening()
            IslandState.shared.showAgentListening(transcript: "", level: 0)
        } else {
            IslandState.shared.showAgentReply(reply)
            ActivationController.shared.finishAgent()
        }
    }

    private func perform(_ intent: AgentTurnIntent) async -> String {
        switch intent {
        case .calendar(let date):
            return await runTool(
                "get_agenda",
                arguments: ["date": date],
                progress: intent.progressTitle
            )
        case .mail(let query):
            return await runTool(
                "search_email",
                arguments: ["query": query],
                progress: intent.progressTitle
            )
        case .files(let query):
            return await runTool(
                "filesystem.search",
                arguments: ["query": query],
                progress: intent.progressTitle
            )
        case .drive(let query):
            return await runTool(
                "find_drive_files",
                arguments: ["query": query],
                progress: intent.progressTitle
            )
        case .computer(let computer):
            return await performComputer(computer) ?? "I couldn’t do that."
        case .capabilities, .reply, .delegate, .unknown:
            return Self.unknownReply
        }
    }

    /// A failed read is still an answer. Returning `nil` used to fall through to a
    /// model that never named the tool.
    private func runTool(
        _ name: String,
        arguments: [String: String],
        progress: String
    ) async -> String {
        progressTitle = progress
        IslandState.shared.showAgentWork(title: progress)
        do {
            let result = try await AgentToolExecutor.run(
                name,
                arguments: arguments,
                policy: .fromSettings(),
                autoApproveReads: true
            )
            return result.summary
        } catch {
            return error.localizedDescription
        }
    }

    private func performComputer(_ intent: ComputerIntent) async -> String? {
        if !Permissions.hasAccessibility {
            _ = Permissions.promptForAccessibility()
        }
        do {
            switch intent {
            case .activeApp:
                return try await runComputer("computer.active_app", arguments: [:])
            case .inspect:
                return try await runComputer("computer.inspect_ui", arguments: [:])
            case .open(let name):
                return try await runComputer("computer.open_app", arguments: ["name": name])
            case .click(let query):
                _ = try await runComputer("computer.inspect_ui", arguments: [:])
                if let id = AccessibilitySnapshot.id(matching: query) {
                    return try await runComputer("computer.click", arguments: ["id": id])
                }
                return "I couldn’t find “\(query)” in the focused window. Try inspect first."
            case .type(let text):
                return try await runComputer("computer.type", arguments: ["text": text])
            case .press(let key):
                return try await runComputer("computer.press_key", arguments: ["key": key])
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func runComputer(_ name: String, arguments: [String: String]) async throws -> String {
        let result = try await AgentToolExecutor.run(
            name,
            arguments: arguments,
            policy: .fromSettings(),
            autoApproveReads: true,
            promptIfNeeded: true
        )
        return result.summary
    }
}

/// One in-memory conversation the Agent sidebar can show.
@MainActor
@Observable
final class AgentSession {
    static let shared = AgentSession()

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: String
        let text: String
        let at = Date()
    }

    private(set) var messages: [Message] = []

    func recordUser(_ text: String) {
        messages.append(Message(role: "user", text: text))
    }

    func recordAssistant(_ text: String) {
        messages.append(Message(role: "assistant", text: text))
    }
}
