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
/// Ordinary mail, calendar and computer requests stay on deterministic routes.
/// Explicit “ask the local model” answers a question without tools; explicit
/// “use tools to” runs a bounded, read-only model tool plan.
@MainActor
@Observable
final class RealtimeAgent {
    static let shared = RealtimeAgent()

    enum Limits {
        /// Workspace and file reads. A second path used to add 50 s of model time
        /// on top of this; that is gone.
        static let tool: Duration = .seconds(20)
        static let localModel: Duration = .seconds(90)
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
    /// The model answer owns a child task so barge-in cancels llama / provider work even
    /// while the VAD task remains free to endpoint the next utterance.
    private var localModelTask: Task<AgentTurn, Never>?
    /// Injectable only for the production-routing self-test. Normal turns always resolve
    /// the configured local provider and never use this seam.
    var localModelProviderForTesting: (any LLMProvider)?
    var localModelLimitForTesting: Duration?
    /// Only the production-route tool-loop self-test shortens the planner deadline.
    var toolLoopLimitForTesting: Duration?

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
        Log.agent.info("realtime · heard \(text, privacy: .public)")
        // Utterance arrives already transcribed; clock transcript → first reply text.
        let replyTrace = LatencyTrace.start(.agentTranscriptToFirstToken)

        let choice = AgentHarnessRouter.shared.choose(for: text)
        switch await waitForACPConfirmation(choice, utterance: text, source: source) {
        case .continueHandle:
            break
        case .cancelled:
            guard isCurrent(mine) else {
                replyTrace.end(note: "superseded")
                return AgentTurn(reply: lastReply, delegated: false)
            }
            AgentSession.shared.recordUser(text)
            replyTrace.end(note: "acp-cancel")
            return conclude(mine, "Cancelled.", route: "acp-cancel")
        case .finished(let turn):
            // `runWithLocalToolsOnce` already wrote the session + island card.
            // Voice still needs lastReply, capture note and TTS — without a
            // second `recordAssistant` from `finish`.
            guard isCurrent(mine) else {
                replyTrace.end(note: "superseded")
                return AgentTurn(reply: lastReply, delegated: false)
            }
            replyTrace.end(note: "acp-once")
            lastReply = turn.reply
            isThinking = false
            progressTitle = ""
            Log.agent.info("realtime · acp-once")
            AgentAuditLog.shared.record(kind: .reply, title: turn.reply)
            AgentCaptureController.shared.noteAssistantReply(turn.reply)
            if AgentCaptureController.shared.isSessionActive {
                let tts = LatencyTrace.start(.agentFirstTokenToFirstTTS)
                // No live token stream on this path — feed through the buffer seam.
                RealtimeAudioSession.shared.speak(turn.reply)
                tts.end(note: "acp-once")
                ActivationController.shared.markListening()
                IslandState.shared.showAgentListening(transcript: "", level: 0)
            }
            return turn
        }

        AgentSession.shared.recordUser(text)
        let intent = AgentTurnIntent.resolve(text, choice: choice)

        switch intent {
        case .capabilities:
            replyTrace.end(note: "capabilities")
            return conclude(mine, Self.capabilitiesReply(for: text) ?? Self.unknownReply, route: "capabilities")
        case .reply(let answer):
            replyTrace.end(note: "context")
            return conclude(mine, answer, route: "context")
        case .localModel(let prompt):
            beginWork(title: intent.progressTitle)
            let task = Task { @MainActor [weak self] in
                guard let self else { return AgentTurn(reply: "", delegated: false) }
                return await self.answerLocally(prompt, generation: mine, replyTrace: replyTrace)
            }
            localModelTask = task
            let turn = await withBoundedWait(localModelLimitForTesting ?? Limits.localModel) {
                await task.value
            }
            if generation == mine { localModelTask = nil }
            if let turn { return turn }
            task.cancel()
            guard isCurrent(mine) else {
                return AgentTurn(reply: lastReply, delegated: false)
            }
            // Invalidate the suspended producer before changing the visible reply.
            // It may still unwind after a blocking model load returns.
            generation += 1
            RealtimeAudioSession.shared.noteUserSpeech()
            let reply = "The local model took too long, so I stopped waiting."
            finish(reply)
            return AgentTurn(reply: reply, delegated: false)
        case .unknown:
            replyTrace.end(note: "unknown")
            return conclude(mine, Self.unknownReply, route: "unknown")
        case .delegate:
            applyHarness(choice)
            replyTrace.end(note: "task")
            return conclude(
                mine,
                delegate(text, source: source, choice: choice),
                delegated: true,
                route: "task"
            )
        case .calendar, .mail, .files, .drive, .computer, .toolLoop:
            beginWork(title: intent.progressTitle)
            let toolTrace = LatencyTrace.start(.agentToolCallToResult)
            let boxed = await withBoundedWait(Limits.tool) {
                await RealtimeAgent.shared.perform(intent)
            }
            toolTrace.end(note: boxed == nil ? "timeout" : intent.progressTitle)
            if !isCurrent(mine) {
                // Superseded — do not leave an open transcript→token span.
                replyTrace.end(note: "superseded")
                return AgentTurn(reply: lastReply, delegated: false)
            }
            if let reply = boxed {
                replyTrace.end(note: "tool")
                return conclude(mine, reply, route: "tool")
            }
            Log.agent.error("realtime · tool timed out")
            replyTrace.end(note: "timeout")
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
        localModelTask?.cancel()
        localModelTask = nil
        PermissionGate.shared.cancelPending()
        Log.agent.info("realtime · stopped")
        finish("Stopped.")
    }

    /// Barge-in: drop the in-flight tool so the new speech can become the next turn.
    /// Always leaves a line — silent interrupt is how three user messages stacked
    /// with no reply. TTS stops even when nothing is thinking, so a spoken reply
    /// can be cut off the moment the user starts talking.
    func interrupt() {
        RealtimeAudioSession.shared.noteUserSpeech()
        if let seconds = RealtimeAudioSession.shared.lastBargeInStopSeconds {
            LatencyTrace.record(.agentBargeInToTTSStopped, seconds: seconds)
        }
        guard isThinking else { return }
        generation += 1
        localModelTask?.cancel()
        localModelTask = nil
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
            • Answer a question on-device when you say “ask the local model …”
            • Plan several read-only checks when you say “use tools to …”

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

    private static let localModelSystem = """
        You are the local, on-device answer model for Next Notes. Answer the user's question
        clearly and briefly in natural language. Use only information in the user's prompt.
        Do not emit URLs, source code, shell commands, tool calls, file listings, markdown
        fences, or long structured output. If the prompt does not contain enough information,
        say that plainly. Keep the answer to a few short sentences suitable for speech.
        """

    private func answerLocally(
        _ prompt: String,
        generation mine: Int,
        replyTrace: LatencyTrace
    ) async -> AgentTurn {
        var replyTraceEnded = false
        func endReplyTrace(_ note: String) {
            guard !replyTraceEnded else { return }
            replyTrace.end(note: note)
            replyTraceEnded = true
        }
        guard isCurrent(mine) else {
            endReplyTrace("superseded")
            return AgentTurn(reply: lastReply, delegated: false)
        }

        let provider: (any LLMProvider)?
        if let localModelProviderForTesting {
            provider = localModelProviderForTesting
        } else {
            provider = await LLMProviders.resolve(preferring: Settings.shared.notesProvider)
        }
        // Provider discovery can suspend while a new voice turn starts. The old
        // turn must not reset the new turn's speech buffer after that await.
        guard isCurrent(mine), !Task.isCancelled else {
            endReplyTrace("superseded")
            return AgentTurn(reply: lastReply, delegated: false)
        }
        guard let provider else {
            endReplyTrace("local-model-unavailable")
            let reason = (await LLMProviders.make(Settings.shared.notesProvider).unavailableReason)
                ?? "no local model is available"
            return conclude(
                mine,
                "I can’t answer locally right now: \(reason)",
                route: "local-model-unavailable"
            )
        }

        let startedStreaming = AgentCaptureController.shared.isSessionActive
        if startedStreaming { RealtimeAudioSession.shared.beginSpokenReply() }
        var answer = ""
        do {
            let chunks = await provider.stream(
                system: Self.localModelSystem,
                user: prompt,
                maxTokens: 256
            )
            for try await chunk in chunks {
                try Task.checkCancellation()
                guard isCurrent(mine) else {
                    endReplyTrace("superseded")
                    return AgentTurn(reply: lastReply, delegated: false)
                }
                if !chunk.isEmpty { endReplyTrace("local-model") }
                answer += chunk
                lastReply = answer
                AgentCaptureController.shared.noteAssistantReply(answer)
                if AgentCaptureController.shared.isSessionActive {
                    RealtimeAudioSession.shared.appendSpokenReply(chunk)
                } else {
                    IslandState.shared.showAgentReply(answer)
                }
            }
            try Task.checkCancellation()
            guard isCurrent(mine) else {
                endReplyTrace("superseded")
                return AgentTurn(reply: lastReply, delegated: false)
            }
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                endReplyTrace("local-model-empty")
                if startedStreaming { RealtimeAudioSession.shared.finalizeSpokenReply() }
                return conclude(mine, "The local model returned no answer.", route: "local-model-empty")
            }
            if startedStreaming {
                RealtimeAudioSession.shared.finalizeSpokenReply()
            }
            return concludeStreamed(mine, answer, route: "local-model")
        } catch is CancellationError {
            endReplyTrace("cancelled")
            return AgentTurn(reply: lastReply, delegated: false)
        } catch {
            guard isCurrent(mine) else {
                endReplyTrace("superseded")
                return AgentTurn(reply: lastReply, delegated: false)
            }
            endReplyTrace("local-model-error")
            if startedStreaming { RealtimeAudioSession.shared.noteUserSpeech() }
            return conclude(
                mine,
                "I couldn’t get an answer from the local model. \(error.localizedDescription)",
                route: "local-model-error"
            )
        }
    }

    private func concludeStreamed(_ mine: Int, _ reply: String, route: String) -> AgentTurn {
        guard isCurrent(mine) else { return AgentTurn(reply: lastReply, delegated: false) }
        Log.agent.info("realtime · \(route, privacy: .public)")
        // The speech bridge already consumed the chunks. Recording through `finish` is
        // still needed, but speaking the completed answer again would duplicate TTS.
        finish(reply, speak: false)
        return AgentTurn(reply: reply, delegated: false)
    }

    private func finish(_ reply: String, speak: Bool = true) {
        lastReply = reply
        isThinking = false
        progressTitle = ""
        AgentSession.shared.recordAssistant(reply)
        AgentAuditLog.shared.record(kind: .reply, title: reply)
        AgentCaptureController.shared.noteAssistantReply(reply)
        if AgentCaptureController.shared.isSessionActive {
            // Speak-replies is on for the open session only. Wave 2 can make this
            // a Settings toggle. The agent loop does not wait for the utterance.
            //
            // One-shot replies use `speak`; the explicit local-model path calls
            // `appendSpokenReply` as chunks arrive. `speak` feeds the finished string through
            // begin → append → finalize so clause TTS is ready for a stream.
            if speak {
                let tts = LatencyTrace.start(.agentFirstTokenToFirstTTS)
                RealtimeAudioSession.shared.speak(reply)
                tts.end()
            }
            ActivationController.shared.markListening()
            IslandState.shared.showAgentListening(transcript: "", level: 0)
        } else {
            IslandState.shared.showAgentReply(reply)
            ActivationController.shared.finishAgent()
        }
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
