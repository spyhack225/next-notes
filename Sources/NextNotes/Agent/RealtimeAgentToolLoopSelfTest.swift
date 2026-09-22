import Foundation

/// Exercises the normal `RealtimeAgent.handle` route used by voice input. The fake
/// provider only controls planning; `computer.active_app` still goes through the real
/// registry, permission policy, and executor.
enum RealtimeAgentToolLoopSelfTest {
    /// What every prompt path must carry, and what must never be said while it carries it.
    ///
    /// No model runs here. These are the checks that would have caught the 2026-09-20
    /// session before it happened: three of the five speaking paths assembled a prompt with
    /// no name, no folder list and no tool roster, and the model said so out loud.
    /// `--selftest-tool-awareness` and `--selftest-voice-grounding` both run this first, so
    /// the regression fails in half a second on a machine with no model installed.
    @MainActor
    static func runGroundingChecks() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // A fixture rather than the live index: the assertion is about what the assembler
        // does with the facts, not about what happens to be on this Mac today.
        let fixture = AgentGrounding(
            assistantName: "Will", userFullName: "Serge Kadjo",
            folders: ["Desktop", "Documents", "Downloads"], indexedItems: 8_796,
            surfaces: AgentGrounding.surfaces(for: RealtimeToolSelection.allowedIDs)
        )

        for path in AgentPromptPath.userFacingPaths {
            let system = AgentPromptContext
                .assemble(path, rules: "Rules.", grounding: fixture).system
            check("\(path.rawValue) carries no grounding header", system.contains(AgentGrounding.header))
            check("\(path.rawValue) never names the user", system.contains("Serge Kadjo"))
            check("\(path.rawValue) never says what it can reach",
                  system.contains(AgentGrounding.reachPrefix))
            check("\(path.rawValue) omits the indexed folders", system.contains("Documents"))
            check("\(path.rawValue) omits the never-deny rule",
                  system.contains("never say you cannot reach their files"))
        }
        // Routing decides an operation and speaks to nobody; ACP is an external process.
        for path in [AgentPromptPath.voiceRoute, .acpAgent] {
            let system = AgentPromptContext
                .assemble(path, rules: "Rules.", grounding: fixture).system
            check("\(path.rawValue) leaked the user's identity", !system.contains("Serge Kadjo"))
        }

        // The Apple model has 4,096 tokens for the whole turn. The compact form carries the
        // same facts without the tool ids.
        let compact = fixture.text(compact: true)
        check("the compact grounding lost the user's name", compact.contains("Serge"))
        check("the compact grounding lost the folders", compact.contains("Documents"))
        check("the compact grounding lost the file count", compact.contains("8,796"))
        // The Apple path has no planner and cannot call a tool, so the ids are dead weight
        // in the one context that cannot spare any.
        check("the compact grounding carried tool ids the Apple path cannot use",
              !compact.contains(FileToolCatalogue.findID))
        check("the compact grounding is over its share of a 4K context (\(compact.count))",
              compact.count < 900)

        // Every tool id the reach sentence advertises must be one the planner may call —
        // the same rule `FileIndexer.promptSummary` is held to, and for the same reason: a
        // name the allow-list rejects does not lose one call, it abandons the whole plan.
        let advertised = FileIndexer.advertisedToolNames(in: fixture.text(compact: false))
        let unallowed = advertised.filter { name in
            !RealtimeToolSelection.allowedIDs.contains(name) && !name.hasSuffix(".")
        }
        check("the reach sentence advertises tools the planner cannot call: \(unallowed.joined(separator: ", "))",
              unallowed.isEmpty)

        // The two nonisolated copies of the identity store's constants.
        check("AgentGroundingFacts drifted from AgentIdentityStore",
              AgentGroundingFacts.identityFileName == AgentIdentityStore.fileName
                  && AgentGroundingFacts.defaultAssistantName == AgentIdentityStore.defaultName)

        // The live grounding, on this Mac, for the on-device reader.
        RealtimeAgent.publishGrounding()
        let live = KnowledgeGraphScope.$reader.withValue(.gemma4E4B) { AgentGrounding.current() }
        check("the live grounding does not know who is using this Mac", live.hasUser)
        check("the live grounding names no reachable surface", !live.surfaces.isEmpty)
        print("GROUNDING_LIVE: \(live.assistantName) / \(live.userFullName) / "
            + "folders=\(live.folders.joined(separator: ",")) items=\(live.indexedItems) "
            + "surfaces=\(live.surfaces.count)")

        // What each prompt costs before it has decided anything. Prefill is the whole
        // latency bill on this machine — 3,634 prompt tokens took 44.78 s on
        // 2026-09-20T20:45 — and prompt size is the only part of it this code controls.
        let roster = RealtimeToolSelection.allowedIDs
        let liveTools = RealtimeAgent.plannableTools()
        let planner = RealtimeAgent.plannerSystem(
            tools: liveTools, voice: true, request: "open my next notes folder")
        let firstPass = RealtimeAgent.voiceRoutingSystem(voice: true)
        let spoken = LocalVoiceSplitResponse.answerInstructions
        print("PROMPT_SIZE: planner=\(planner.count) chars over \(liveTools.count) tools, "
            + "first-pass=\(firstPass.count), spoken-answer=\(spoken.count)")
        check("the tool planner's prompt grew past its measured budget (\(planner.count) chars)",
              planner.count < 15_000)
        check("the conversational first pass picked up the tool roster (\(firstPass.count) chars)",
              firstPass.count < 4_500)

        // The roster the Apple voice path is shown. Its budget truncates from the end, so
        // the categories that matter most to the reported complaints are checked by name.
        let inventory = VoiceCapabilitySnapshot.make(tools: liveTools)
        print("PROMPT_SIZE: voice-capability-inventory=\(inventory.promptText.count) chars")
        for category in ["Local files", "Frontmost Mac UI", "Browser pages"] {
            check("the voice capability inventory dropped \(category)",
                  inventory.promptText.contains(category))
        }
        for id in [FileToolCatalogue.findID, FileToolCatalogue.treeID, "filesystem.reveal",
                   "computer.open_app", "browser.navigate"] {
            check("\(id) is not in the realtime allow-list", roster.contains(id))
            check("\(id) is not in the live planner roster", liveTools.contains { $0.id == id })
        }

        for (name, reply) in [
            ("FILES", "I don't know what you are working on. I need to check your files and history to find out."),
            ("FOLDER", "I cannot open the \"next project\" folder yet because your spoken request was incomplete."),
            ("NOTE", "I cannot open a new note. I do not have the tool to create new Google Docs or Notes."),
            ("CALENDAR", "I don't have access to your calendar."),
        ] {
            check("a false refusal about \(name) was not caught",
                  AgentRefusalGuard.rebuttal(for: reply, toolIDs: roster) != nil)
        }
        for (name, reply) in [
            ("HONEST_EVIDENCE", "The transcript does not say who owns that action item."),
            ("HONEST_RESULT", "Nothing in Desktop, Documents and Downloads matches that."),
            ("PLAIN", "Opened youtube.com in Google Chrome."),
        ] {
            check("an honest reply about \(name) was overridden",
                  AgentRefusalGuard.rebuttal(for: reply, toolIDs: roster) == nil)
        }
        check("a denial was spoken before it could be judged",
              AgentRefusalGuard.mayBeDenial("I cannot")
                  && !AgentRefusalGuard.mayBeDenial("Opened youtube.com"))

        // The utterances from 2026-09-20T20:45–20:46Z, verbatim from agent-audit.jsonl.
        let parsed = AgentDirectIntent.parse("You open Google Chrome and go to youtube.com.")
        check("the 20:45:00 request still needs a 45-second planner round",
              parsed == .openURL(url: "https://youtube.com", app: "Google Chrome"))
        check("\"hey next can you open youtube on google chrome\" was not understood",
              AgentDirectIntent.parse("hey next can you open youtube on google chrome")
                  == .openURL(url: "https://www.youtube.com", app: "Google Chrome"))
        check("a bare app request was not understood",
              AgentDirectIntent.parse("open Safari") == .openApp("Safari"))
        if case .locate(let query, let wantsFolder)? = AgentDirectIntent.parse(
            "can you also nothing get to my folder to my document folder in open next project"
        ) {
            check("the 20:45:41 folder request lost its name (\(query))", query == "next project")
            check("the 20:45:41 folder request lost that it wanted a folder", wantsFolder)
        } else {
            failures.append("the 20:45:41 folder request was not recognised as a file request")
        }
        check("an ordinary question was hijacked by the planner shortcut",
              AgentDirectIntent.parse("what did we decide in the DIKAB meeting?") == nil)
        check("a destructive request was treated as a shortcut",
              AgentDirectIntent.parse("delete the Next Notes folder") == nil)

        // Sound, not spelling. Both numbers are the reason the refusals were wrong.
        let noteScore = AgentEntityResolver.similarity("note", "notes")
        let projectScore = AgentEntityResolver.similarity("project", "notes")
        print("GROUNDING_SIMILARITY: note/notes=\(String(format: "%.2f", noteScore)) "
            + "project/notes=\(String(format: "%.2f", projectScore))")
        check("\"note\" no longer sounds like \"notes\"", noteScore >= 0.8)
        check("\"project\" was treated as a match for \"notes\"", projectScore < 0.4)
        let folder = FileHit(path: "/Users/x/Documents/Claude/Projects/Next Notes", name: "Next Notes",
                             isDirectory: true, category: .other, size: nil, modifiedAt: nil,
                             accessedAt: nil, root: "/Users/x/Documents", depth: 3)
        let misheard = AgentEntityResolver.score(
            folder, tokens: AgentEntityResolver.tokens("next note"), wantsFolder: true)
        check("\"next note\" would not be acted on as \"Next Notes\" (\(String(format: "%.2f", misheard)))",
              misheard >= AgentEntityResolver.confidentThreshold)
        let looser = AgentEntityResolver.score(
            folder, tokens: AgentEntityResolver.tokens("next project"), wantsFolder: true)
        check("\"next project\" would not even be offered (\(String(format: "%.2f", looser)))",
              looser >= AgentEntityResolver.offerThreshold
                  && looser < AgentEntityResolver.confidentThreshold)

        // The correction turn, as the recogniser wrote it.
        check("a turn that supplies a name was read as a new subject",
              AgentEntityResolver.namingTarget(in: "note the four days called next note") == "next note")
        check("an ordinary sentence was mistaken for a correction",
              AgentEntityResolver.namingTarget(in: "open youtube on chrome") == nil)
        check("an instruction that happens to name something was taken as a correction",
              AgentEntityResolver.namingTarget(in: "create a document called Q4 plan") == nil)
        check("a long sentence that names something was taken as a correction",
              AgentEntityResolver.namingTarget(
                in: "I was thinking about the thing we discussed in the meeting called standup") == nil)
        check("the previous reply's request for a name was not recognised",
              AgentEntityResolver.askedForAName(
                "Please tell me the exact name of the project or file you want to open."))

        for failure in failures { print("GROUNDING_WRONG: \(failure)") }
        print(failures.isEmpty ? "GROUNDING_OK" : "GROUNDING_FAILED")
        return failures
    }

    /// Ask the installed on-device model for routing decisions without executing
    /// tools or recording these fixtures in the user's conversation.
    @MainActor
    static func runToolAwareness() async -> Bool {
        let grounding = runGroundingChecks()
        let provider = LlamaLLMProvider()
        if let reason = await provider.unavailableReason {
            print("TOOL_AWARENESS_FAILED: \(reason)")
            return false
        }
        let system = RealtimeAgent.voiceRoutingSystem(voice: true)
        let probes: [(name: String, messages: [LLMChatMessage], expected: String)] = [
            ("CALENDAR", [.init(role: .user, content: "What is on my calendar for today?")],
             "<use_tools/>"),
            ("PRIOR_DENIAL", [
                .init(role: .user, content: "What is on my calendar today?"),
                .init(role: .assistant, content: "I don't have access to your calendar."),
                .init(role: .user, content: "Please check my calendar for today.")
            ], "<use_tools/>"),
            ("MEETING_ACTIONS", [
                .init(role: .user, content: "What action items came from my last meeting?")
            ], "<use_tools/>"),
            ("CAPABILITIES", [.init(role: .user, content: "Can you check your tools?")],
             "<answer/>"),
            ("MY_TODO", [.init(role: .user, content: "What is on my to-do list for today?")],
             "<use_tools/>"),
            ("YOUR_TODO", [.init(role: .user, content: "What is on your to-do list for today?")],
             "<answer/>"),
            // 2026-09-20T20:43:15Z. This answered "<answer/>I don't know what you are
            // working on. I need to check your files and history to find out." with 8,796
            // files indexed. Asking about the user's own work is a lookup, not a guess.
            ("MY_PROJECTS", [.init(role: .user, content: "What are the projects I am working on?")],
             "<use_tools/>"),
            ("MY_FOLDER", [.init(role: .user, content: "Open my Next Notes folder.")],
             "<use_tools/>"),
        ]
        var failures: [String] = grounding
        for probe in probes {
            let response: String? = await withBoundedWait(.seconds(90)) {
                do {
                    var answer = ""
                    let stream = await provider.streamConversation(
                        system: system, messages: probe.messages, maxTokens: 112
                    )
                    for try await chunk in stream {
                        answer += chunk
                        if VoiceResponseEnvelope.parse(answer) == .tools { return "<use_tools/>" }
                    }
                    if case .answer(let text) = VoiceResponseEnvelope.parse(answer), !text.isEmpty {
                        return "<answer/>"
                    }
                    return answer.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    return "ERROR: \(error.localizedDescription)"
                }
            }
            let answer = response ?? ""
            print("TOOL_AWARENESS_\(probe.name): \(String(answer.prefix(240)))")
            if answer != probe.expected {
                failures.append("\(probe.name): expected \(probe.expected), got \(answer)")
            }
        }
        for failure in failures { print("TOOL_AWARENESS_WRONG: \(failure)") }
        print(failures.isEmpty ? "TOOL_AWARENESS_OK" : "TOOL_AWARENESS_FAILED")
        return failures.isEmpty
    }

    /// Real on-device probe for the 09:48 recording. This only asks a question of
    /// the local model; it does not add a row to the user's Agent conversation.
    @MainActor
    static func runVoiceGrounding() async -> Bool {
        let groundingFailures = runGroundingChecks()
        // The prompt the voice path actually hears, not a copy of it.
        let voiceAnswer = LocalVoiceSplitResponse.answerInstructions
        var promptFailures: [String] = groundingFailures
        if !voiceAnswer.contains(AgentGrounding.header) {
            promptFailures.append("the spoken-answer prompt carries no identity block")
        }
        if !voiceAnswer.contains(AgentGrounding.reachPrefix) {
            promptFailures.append("the spoken-answer prompt never says what it can reach")
        }
        // Apple's model has 4,096 tokens for instructions, capability inventory, the
        // conversation and the turn. Roughly four characters to the token.
        if voiceAnswer.count > 4_000 {
            promptFailures.append("the spoken-answer prompt grew to \(voiceAnswer.count) characters")
        }
        for failure in promptFailures { print("VOICE_GROUNDING_WRONG: \(failure)") }
        let provider = LlamaLLMProvider()
        if let reason = await provider.unavailableReason {
            print("VOICE_GROUNDING_FAILED: \(reason)")
            return false
        }
        let response: String? = await withBoundedWait(.seconds(90)) {
            do {
                var answer = ""
                let stream = await provider.streamConversation(
                    system: RealtimeAgent.modelTurnSystem(voice: true),
                    messages: [.init(role: .user, content: "Can you hear me?")],
                    maxTokens: 96
                )
                for try await chunk in stream { answer += chunk }
                return answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }
        }
        let answer = response ?? ""
        let lowered = answer.lowercased()
        let correct = !answer.isEmpty && !lowered.hasPrefix("error:")
            && !lowered.contains("can't hear") && !lowered.contains("cannot hear")
            && !lowered.contains("don't have ears") && !lowered.contains("do not have ears")
            && !lowered.contains("typed") && !lowered.contains("type")
            && !answer.contains("<use_tools")
        print("VOICE_GROUNDING_RESPONSE: \(String(answer.prefix(240)))")
        let followUp: String? = await withBoundedWait(.seconds(90)) {
            do {
                var answer = ""
                let stream = await provider.streamConversation(
                    system: RealtimeAgent.modelTurnSystem(voice: true),
                    messages: [
                        .init(role: .user, content: "Can you hear me?"),
                        .init(role: .assistant, content: "Yes, I received your spoken words."),
                        .init(role: .user, content: "Your voice keeps breaking mid-answer."),
                        .init(role: .user, content: "Why is he choppy?")
                    ],
                    maxTokens: 96
                )
                for try await chunk in stream { answer += chunk }
                return answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }
        }
        let followUpAnswer = followUp ?? ""
        let followUpLower = followUpAnswer.lowercased()
        let understandsReferent = !followUpAnswer.isEmpty && !followUpLower.hasPrefix("error:")
            && !followUpLower.contains("who he") && !followUpLower.contains("who 'he'")
            && !followUpLower.contains("who \"he\"")
            && !followUpLower.contains("clarify who")
            && !followUpLower.contains("don't know who")
            && !followUpLower.contains("his voice")
            && !followUpLower.contains("not his")
            && (followUpLower.contains("my voice") || followUpLower.contains("my speech")
                || followUpLower.contains("my spoken") || followUpLower.contains("my output"))
            && !followUpLower.contains("audio connection")
            && !followUpLower.contains("network connection")
            && !followUpLower.contains("network issue")
            && !followUpLower.contains("connection issue")
            && !followUpLower.contains("connection stability")
            && !followUpLower.contains("audio settings")
            && !followUpLower.contains("your device")
            && !followUpLower.contains("microphone issue")
            && !followUpLower.contains("restarting your device")
        print("VOICE_FOLLOWUP_RESPONSE: \(String(followUpAnswer.prefix(240)))")
        // September 14 recording: the previous answer about tools was repeated
        // when the user changed the subject to the earlier model timeout.
        let timeoutFollowUp: String? = await withBoundedWait(.seconds(90)) {
            do {
                var answer = ""
                let stream = await provider.streamConversation(
                    system: RealtimeAgent.modelTurnSystem(voice: true),
                    messages: [
                        .init(role: .user, content: "Can you hear me?"),
                        .init(role: .assistant, content: "The model took too long to answer."),
                        .init(role: .user, content: "Why did you use a tool? It was a simple question."),
                        .init(role: .assistant, content: "I didn't use any tools; I answered directly."),
                        .init(role: .user, content: "Why did it say the model took too long to answer?")
                    ],
                    maxTokens: 96
                )
                for try await chunk in stream { answer += chunk }
                return answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }
        }
        let timeoutAnswer = timeoutFollowUp ?? ""
        let timeoutLower = timeoutAnswer.lowercased()
        let addressesTimeout = !timeoutAnswer.isEmpty
            && !timeoutLower.hasPrefix("error:")
            && !timeoutAnswer.contains("<use_tools")
            && (timeoutLower.contains("model") || timeoutLower.contains("timeout")
                || timeoutLower.contains("timed out")
                || (timeoutLower.contains("response generation")
                    && timeoutLower.contains("longer")))
            && !timeoutLower.contains("i didn't use any tools")
            && !timeoutLower.contains("no delay")
        print("VOICE_TIMEOUT_FOLLOWUP_RESPONSE: \(String(timeoutAnswer.prefix(240)))")

        // 2026-09-20T20:43:15Z, on the path that speaks: the user asked who they were and
        // what they were working on. One answer came from the persona and one was a
        // denial. Both questions are answered by the block every path now carries.
        let identity: String? = await withBoundedWait(.seconds(90)) {
            do {
                var answer = ""
                let stream = await provider.streamConversation(
                    system: RealtimeAgent.modelTurnSystem(voice: true),
                    messages: [.init(role: .user, content: "Who am I, and what can you reach on this Mac?")],
                    maxTokens: 96
                )
                for try await chunk in stream { answer += chunk }
                return answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { return "ERROR: \(error.localizedDescription)" }
        }
        let identityAnswer = identity ?? ""
        let identityLower = identityAnswer.lowercased()
        let live = KnowledgeGraphScope.$reader.withValue(.gemma4E4B) { AgentGrounding.current() }
        let knowsUser = !identityAnswer.isEmpty && !identityLower.hasPrefix("error:")
            && (live.userShortName.isEmpty || identityLower.contains(live.userShortName.lowercased()))
            && !identityLower.contains("i don't know who")
            && !identityLower.contains("i do not know who")
            && !identityLower.contains("don't have access to your files")
            && !identityLower.contains("do not have access to your files")
        print("VOICE_IDENTITY_RESPONSE: \(String(identityAnswer.prefix(240)))")
        if !knowsUser { print("VOICE_GROUNDING_WRONG: the speaking path still does not know the user") }

        let passed = correct && understandsReferent && addressesTimeout && knowsUser
            && promptFailures.isEmpty
        print(passed ? "VOICE_GROUNDING_OK" : "VOICE_GROUNDING_FAILED")
        return passed
    }

    @MainActor
    @discardableResult
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let agent = RealtimeAgent.shared
        let providerState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(state: providerState)
        defer {
            agent.localModelProviderForTesting = nil
            agent.localModelLimitForTesting = nil
            agent.toolLoopLimitForTesting = nil
        }

        let turn = await agent.handle(
            "tell me which app is frontmost",
            source: .text
        )
        let rounds = await providerState.rounds
        let sawResult = await providerState.sawToolResult
        let schemaCharacters = await providerState.lastSystemCharacters

        check(
            "ordinary request did not select the model tool route",
            AgentTurnIntent.resolve(
                "tell me which app is frontmost",
                choice: AgentHarnessChoice(
                    id: .local,
                    source: .settings,
                    available: true,
                    fallbackToLocal: false,
                    note: ""
                )
            ) == .toolLoop(prompt: "tell me which app is frontmost")
        )
        check("tool request did not enter the separate planner", rounds >= 3)
        check("tool planner did not receive a real tool result", sawResult)
        // Measured without the persona, which has its own budget (`--selftest-persona`).
        let plannerPersona = PersonaStore.shared.fullPersona().count
        check("tool catalogue crowded out the 4K model context (\(schemaCharacters) chars, persona \(plannerPersona))",
              schemaCharacters - plannerPersona < 8_000)
        check("tool loop returned no final answer", !turn.reply.isEmpty)
        check("tool loop leaked a tool tag to the user", !turn.reply.contains("<tool_call>"))

        // A conversational answer streams in its routing pass. No second
        // model prefill, and no full tool schema on the speech path.
        let directState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: directState, firstCall: ""
        )
        let direct = await agent.handle("Can you hear me?", source: .text)
        check("conversation did not answer directly", direct.reply == "First answer. Second answer.")
        let directRounds = await directState.rounds
        let firstPromptCharacters = await directState.firstSystemCharacters
        check("conversation entered tool planning (\(directRounds) rounds)", directRounds == 1)
        let firstPrompt = RealtimeAgent.voiceRoutingSystem(voice: false)
        check("first pass omitted the model tool decision", firstPrompt.contains("<use_tools/>"))
        // The persona is the user's own text and is budgeted separately
        // (`--selftest-persona`); this ceiling is about the tool roster.
        let personaCharacters = PersonaStore.shared.fullPersona().count
        check("conversation prompt still carries the full tool roster (\(firstPromptCharacters) chars, persona \(personaCharacters))",
              firstPromptCharacters - personaCharacters < 1_500)


        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let knownDay = utc.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        let today = AgentToolLoop.groundedArguments(
            for: "get_agenda", proposed: ["date": "2023-10-27"],
            request: "What's on my calendar for today?", now: knownDay, calendar: utc
        )
        check("the model's stale calendar date was not grounded", today["date"] == "2026-09-14")
        let historical = AgentToolLoop.groundedArguments(
            for: "get_agenda", proposed: ["date": "2023-10-27"],
            request: "What was booked on 2023-10-27?", now: knownDay, calendar: utc
        )
        check("an explicit historical calendar date was overwritten", historical["date"] == "2023-10-27")

        // A successful read is a usable answer even when a second model pass
        // runs past the turn's deadline. This was the missing calendar reply.
        let fallbackState = ToolLoopTestState()
        agent.toolLoopLimitForTesting = .seconds(2)
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: fallbackState, secondRoundDelay: .seconds(4)
        )
        let fallback = await agent.handle("which app is frontmost?", source: .text)
        check("a completed read was thrown away on model timeout",
              fallback.reply.contains("Remaining steps are unfinished.")
                  && fallback.reply.components(separatedBy: "\n").first?.isEmpty == false)
        check("the second model pass was never exercised", (await fallbackState.rounds) >= 2)

        // Mutations are available to the planner, but a malformed request must
        // fail at the executor before prompting or changing the user's UI.
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), firstCall: "computer.type"
        )
        let forbidden = await agent.handle("type a secret", source: .text)
        check("malformed model mutation bypassed argument validation", forbidden.reply.contains("did not run"))

        // A stalled model is bounded and cannot produce a late visible answer.
        agent.toolLoopLimitForTesting = .milliseconds(80)
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), delay: .milliseconds(400)
        )
        let timedOut = await agent.handle("inspect this", source: .text)
        check("tool planner timeout was not visible", timedOut.reply.contains("too long"))

        // An ordinary answer, with no tool tag, must begin speaking from the
        // first complete streamed clause. Barge-in must suppress later chunks.
        agent.toolLoopLimitForTesting = nil
        let recorder = RecordingSpeechBacking()
        AgentSpeechSynthesizer.shared.useTestingBacking(recorder)
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), firstCall: ""
        )
        await AgentCaptureController.shared.beginSession(captureAudio: false)
        _ = await agent.handle("Explain this briefly", source: .text)
        check("typed turn spoke while a voice session was open", recorder.spoken.isEmpty)
        await AgentCaptureController.shared.endSession(source: .done)
        let voiceState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: voiceState,
            finalAnswer: "- /private/one\n- /private/two\n- /private/three\n- /private/four"
        )
        await AgentCaptureController.shared.beginSession(captureAudio: false)
        let voiceTurn = await agent.handle("tell me which app is frontmost", source: .voice)
        try? await Task.sleep(for: .milliseconds(100))
        check("unspeakable tool listing was read aloud", recorder.spoken.allSatisfy {
            !$0.contains("/private/")
        })
        check("verified tool result produced no voice fallback", !recorder.spoken.isEmpty)
        check("voice turn lost the full text result", voiceTurn.reply.contains("/private/"))
        check("voice summary added an extra model round", (await voiceState.rounds) == 3)
        await AgentCaptureController.shared.endSession(source: .done)
        recorder.reset()
        let answerState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: answerState, firstCall: "", delay: .milliseconds(400)
        )
        await AgentCaptureController.shared.beginSession(captureAudio: false)
        let spokenTurn = Task { @MainActor in
            await agent.handle("Explain this briefly", source: .voice)
        }
        try? await Task.sleep(for: .milliseconds(100))
        check("plain model answer waited for all tokens before speaking",
              recorder.spoken == ["First answer."])
        check("model answer finished before its first clause was audible",
              !(await answerState.completed))
        agent.interrupt()
        _ = await spokenTurn.value
        check("interrupted answer spoke a later clause",
              !recorder.spoken.contains("Second answer."))
        await AgentCaptureController.shared.endSession(source: .done)
        AgentSpeechSynthesizer.shared.restoreSystemBacking()

        for failure in failures { print("  TOOLLOOP_PRODUCTION_WRONG: \(failure)") }
        print(failures.isEmpty ? "TOOLLOOP_PRODUCTION_OK" : "TOOLLOOP_PRODUCTION_FAILED")
        return failures.isEmpty
    }
}

private actor ToolLoopTestState {
    var rounds = 0
    var sawToolResult = false
    var completed = false
    var lastSystemCharacters = 0
    var firstSystemCharacters = 0

    func next(user: String, system: String) -> Int {
        rounds += 1
        if rounds == 1 { firstSystemCharacters = system.count }
        lastSystemCharacters = system.count
        if user.contains("computer.active_app returned") { sawToolResult = true }
        return rounds
    }

    func markCompleted() { completed = true }
}

private struct ToolLoopTestProvider: LLMProvider {
    let id = LLMProviderID.gemma4E4B
    let state: ToolLoopTestState
    let firstCall: String
    let delay: Duration
    let secondRoundDelay: Duration
    let finalAnswer: String
    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }

    init(state: ToolLoopTestState, firstCall: String = "computer.active_app",
         delay: Duration = .zero, secondRoundDelay: Duration = .zero,
         finalAnswer: String = "The frontmost application is the one reported by the system.") {
        self.state = state
        self.firstCall = firstCall
        self.delay = delay
        self.secondRoundDelay = secondRoundDelay
        self.finalAnswer = finalAnswer
    }

    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        _ = await state.next(user: user, system: system)
        let choosing = system.contains("<use_tools/>")
        let afterTool = user.contains("computer.active_app returned")
        let wait = afterTool ? secondRoundDelay : (choosing ? delay : .zero)
        if wait > .zero { try await Task.sleep(for: wait) }
        let text: String
        if choosing {
            text = "<use_tools/>"
        } else if !afterTool {
            text = "<tool_call>{\"name\":\"" + firstCall + "\",\"arguments\":{},\"rationale\":\"test\"}</tool_call>"
        } else {
            text = finalAnswer
        }
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if firstCall.isEmpty {
                        _ = await state.next(user: user, system: system)
                        continuation.yield("<answer/>First answer.")
                        try await Task.sleep(for: delay)
                        continuation.yield(" Second answer.")
                    } else {
                        let response = try await complete(system: system, user: user, maxTokens: maxTokens)
                        continuation.yield(response.text)
                    }
                    await state.markCompleted()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
