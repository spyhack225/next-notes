import Foundation

/// Result of parking on the missing-CLI card. Voice `handle` and the
/// sidebar `handleLive` path share `waitForACPConfirmation`.
enum ACPHandleWait {
    case continueHandle
    case cancelled
    case finished(AgentTurn)
}

/// Live tool path for `RealtimeAgent`. `handle` already calls `perform`;
/// `finish` / `interrupt` stay in the main file.
///
/// Computer inspect → click (and the other multi-step computer paths) go
/// through `AgentToolLoop.run` with `maxRounds` clamped to 4…8. Calendar,
/// mail and a lone click stay local unless the user named a harness.
extension RealtimeAgent {
    /// Confirmation-aware entry for the Agent sidebar. Same wait as voice
    /// `handle` — a missing ACP CLI parks on [Run once] / [Cancel].
    func handleLive(_ utterance: String, source: AgentUtteranceSource) async -> AgentTurn {
        await handle(utterance, source: source)
    }

    /// Voice `handle` parks here when the CLI is missing. Nil-shaped
    /// `.continueHandle` means the turn may run; nothing else starts ACP.
    func waitForACPConfirmation(
        _ choice: AgentHarnessChoice,
        utterance: String,
        source: AgentUtteranceSource
    ) async -> ACPHandleWait {
        let planned = ACPConfirmation.voiceEntryAction(choice)
        guard planned == .awaitConfirmation else { return .continueHandle }
        // `--selftest-realtime` calls `handle` with a named harness and
        // expects a delegated reply. It cannot press the card. ACP confirm
        // tests `voiceEntryAction` + the gate directly instead.
        if SelfTest.isRunning { return .continueHandle }

        let outcome = await ACPConfirmationGate.shared.request(choice, utterance: utterance)
        switch ACPConfirmation.entryAction(choice, outcome: outcome) {
        case .runLocalOnce:
            return .finished(await runWithLocalToolsOnce(utterance, source: source))
        case .cancelled, .awaitConfirmation, .runLocal, .startACP:
            return .cancelled
        }
    }

    func runWithLocalToolsOnce(_ text: String, source: AgentUtteranceSource) async -> AgentTurn {
        let local = AgentHarnessChoice(
            id: .local,
            source: .explicit,
            available: true,
            fallbackToLocal: false,
            note: ""
        )
        let intent = AgentTurnIntent.resolve(text, choice: local)
        AgentSession.shared.recordUser(text)
        switch intent {
        case .calendar, .mail, .files, .drive, .computer:
            let reply = await perform(intent)
            AgentSession.shared.recordAssistant(reply)
            IslandState.shared.showAgentReply(reply)
            return AgentTurn(reply: reply, delegated: false)
        case .capabilities, .reply, .delegate, .unknown:
            if !SelfTest.isRunning {
                AgentTaskManager.shared.submit(
                    objective: text,
                    contextReferences: AgentContext.current.references,
                    meetingID: MeetingContextStore.shared.current?.meetingID,
                    backend: .local,
                    source: source.rawValue
                )
            }
            let reply = "I’ll work on that locally, once."
            AgentSession.shared.recordAssistant(reply)
            IslandState.shared.showAgentReply(reply)
            return AgentTurn(reply: reply, delegated: true)
        }
    }

    func perform(_ intent: AgentTurnIntent) async -> String {
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

    func runTool(
        _ name: String,
        arguments: [String: String],
        progress: String
    ) async -> String {
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

    func performComputer(_ intent: ComputerIntent) async -> String? {
        if !Permissions.hasAccessibility {
            _ = Permissions.promptForAccessibility()
        }
        switch intent {
        case .inspect, .click, .type:
            return await runComputerLoop(intent)
        case .activeApp, .open, .press:
            return await runComputerOnce(intent)
        }
    }

    private func runComputerOnce(_ intent: ComputerIntent) async -> String? {
        do {
            switch intent {
            case .activeApp:
                return try await runComputer("computer.active_app", arguments: [:])
            case .open(let name):
                return try await runComputer("computer.open_app", arguments: ["name": name])
            case .press(let key):
                return try await runComputer("computer.press_key", arguments: ["key": key])
            case .inspect, .click, .type:
                return await runComputerLoop(intent)
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func runComputerLoop(_ intent: ComputerIntent) async -> String? {
        do {
            let outcome = try await AgentToolLoop.run(
                user: ComputerLoopPlanner.utterance(for: intent),
                maxRounds: AgentToolLoop.defaultMaxRounds,
                complete: { user in ComputerLoopPlanner.complete(intent: intent, user: user) },
                execute: { call in await self.executeComputerCall(call) }
            )
            return outcome.reply
        } catch {
            return error.localizedDescription
        }
    }

    private func executeComputerCall(_ call: AgentToolCall) async -> String {
        do {
            return try await runComputer(call.name, arguments: call.arguments)
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

/// Deterministic next tool for a computer turn. There is no second model
/// round — that wait is how mail sat in Thinking… until Stop.
@MainActor
enum ComputerLoopPlanner {
    static func utterance(for intent: ComputerIntent) -> String {
        switch intent {
        case .inspect: "Inspect the focused window."
        case .activeApp: "What app is frontmost?"
        case .open(let name): "Open \(name)"
        case .click(let query): "Click \(query)"
        case .type(let text): "Type \(text)"
        case .press(let key): "Press \(key)"
        }
    }

    static func complete(intent: ComputerIntent, user: String) -> String {
        let lowered = user.lowercased()
        let hasInspect = lowered.contains("computer.inspect_ui returned")
        let hasClick = lowered.contains("computer.click returned")
        let hasType = lowered.contains("computer.type returned")

        if hasClick || hasType {
            return doneReply(for: intent)
        }

        if hasInspect {
            switch intent {
            case .inspect:
                return inspectReply(from: user)
            case .click(let query):
                if let id = AccessibilitySnapshot.id(matching: query) {
                    return emit(name: "computer.click", arguments: ["id": id], rationale: "click")
                }
                return "I couldn’t find “\(query)” in the focused window. Try inspect first."
            case .type(let text):
                var arguments = ["text": text]
                if let id = AccessibilitySnapshot.firstTextFieldID() {
                    arguments["id"] = id
                }
                return emit(name: "computer.type", arguments: arguments, rationale: "type")
            default:
                return doneReply(for: intent)
            }
        }

        switch intent {
        case .inspect, .click:
            return emit(name: "computer.inspect_ui", arguments: [:], rationale: "look")
        case .type(let text):
            return emit(name: "computer.type", arguments: ["text": text], rationale: "type")
        case .activeApp:
            return emit(name: "computer.active_app", arguments: [:], rationale: "look")
        case .open(let name):
            return emit(name: "computer.open_app", arguments: ["name": name], rationale: "open")
        case .press(let key):
            return emit(name: "computer.press_key", arguments: ["key": key], rationale: "press")
        }
    }

    private static func doneReply(for intent: ComputerIntent) -> String {
        switch intent {
        case .click: "Clicked."
        case .type: "Typed."
        case .inspect: "Inspected the focused window."
        case .activeApp: "That’s the frontmost app."
        case .open: "Opened."
        case .press: "Pressed."
        }
    }

    private static func inspectReply(from user: String) -> String {
        let marker = "computer.inspect_ui returned:"
        guard let range = user.range(of: marker) else {
            return "Inspected the focused window."
        }
        let rest = user[range.upperBound...]
        if let end = rest.range(of: "\n\nContinue.") {
            return rest[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func emit(
        name: String,
        arguments: [String: String],
        rationale: String
    ) -> String {
        let object: [String: Any] = [
            "name": name,
            "rationale": rationale,
            "arguments": arguments,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return "<tool_call>\(json)</tool_call>"
    }
}
