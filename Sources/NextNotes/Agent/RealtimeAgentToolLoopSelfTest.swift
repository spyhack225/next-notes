import Foundation
import FoundationModels

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
    static func runGroundingChecks() async -> [String] {
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
        let live = KnowledgeGraphScope.$reader.withValue(.appLLM) { AgentGrounding.current() }
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

        // P0-2: the relevance filter is add-only over the core set, capped, and keeps
        // the browser tool for the 20:45 utterance. The core survives every gate combo;
        // otherwise the planner falls back to core-only rather than to a list without it.
        let allTools = RealtimeAgent.plannableTools()
        let allOff = RealtimeAgent.plannableTools(knowledgeTools: false)
        for (label, roster) in [("on", allTools), ("off", allOff)] {
            let ids = Set(roster.map(\.id))
            let missing = RealtimeAgent.coreToolIDs.subtracting(ids)
            check("core tools missing with knowledge tools \(label): \(missing.sorted().joined(separator: ", "))",
                  missing.isEmpty)
        }
        let youtubeRequest = "open Chrome and go to youtube.com"
        let filtered = RealtimeAgent.relevantTools(for: youtubeRequest, all: allTools)
        let filteredIDs = Set(filtered.map(\.id))
        check("core tools dropped by the relevance filter",
              RealtimeAgent.coreToolIDs.isSubset(of: filteredIDs))
        check("relevance filter grew past its cap (\(filtered.count))",
              filtered.count <= RealtimeAgent.relevantToolCap)
        check("browser.navigate lost with the filter on", filteredIDs.contains("browser.navigate"))
        if let nav = filtered.firstIndex(where: { $0.id == "browser.navigate" }),
           let doc = filtered.firstIndex(where: { $0.id == "append_doc" }) {
            check("append_doc outranked browser.navigate for a navigation request", nav < doc)
        }
        // Token budget for a 12-tool roster. Prefill is the whole latency bill, so the
        // planner prompt is counted with the provider's own tokenizer.
        let twelve = Array(filtered.prefix(12))
        let twelveSystem = RealtimeAgent.plannerSystem(
            tools: twelve, voice: true, request: youtubeRequest)
        do {
            let counter = ToolLoopTestProvider(state: ToolLoopTestState())
            let tokens = try await counter.countTokens(twelveSystem)
            print("PROMPT_TOKENS: \(tokens) for \(twelve.count) tools")
            check("planner prompt too large: \(tokens) tokens for 12 tools (budget 900)",
                  tokens < 900)
        } catch {
            failures.append("countTokens threw for a 12-tool roster: \(error.localizedDescription)")
        }

        for failure in failures { print("GROUNDING_WRONG: \(failure)") }
        print(failures.isEmpty ? "GROUNDING_OK" : "GROUNDING_FAILED")
        return failures
    }

    /// Ask the installed on-device model for routing decisions without executing
    /// tools or recording these fixtures in the user's conversation.
    @MainActor
    static func runToolAwareness() async -> Bool {
        let grounding = await runGroundingChecks()
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
        let groundingFailures = await runGroundingChecks()
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
        let live = KnowledgeGraphScope.$reader.withValue(.appLLM) { AgentGrounding.current() }
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
            agent.answerDepthForTesting = nil
            agent.setTypedPendingForTesting(nil)
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
        check("tool request did not enter the separate planner", rounds >= 2)
        check("tool planner did not receive a real tool result", sawResult)
        // Measured without the persona, which has its own budget (`--selftest-persona`).
        let plannerPersona = PersonaStore.shared.fullPersona().count
        check("tool catalogue crowded out the 4K model context (\(schemaCharacters) chars, persona \(plannerPersona))",
              schemaCharacters - plannerPersona < 8_000)
        check("tool loop returned no final answer", !turn.reply.isEmpty)
        check("tool loop leaked a tool tag to the user", !turn.reply.contains("<tool_call>"))

        // P1-02: the typed path makes exactly one model call now — the planner's — so a
        // conversational answer is the planner's own first round rather than a header pass
        // followed by a refusal guard. The voice branch keeps its header pass (P3-01).
        let directState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: directState, firstCall: ""
        )
        let direct = await agent.handle("Can you hear me?", source: .text)
        check("conversation did not answer directly", direct.reply == "First answer. Second answer.")
        let directRounds = await directState.rounds
        let firstPromptCharacters = await directState.firstSystemCharacters
        check("conversation entered tool planning (\(directRounds) rounds)", directRounds == 1)
        check("typed turn used the response-header pass",
              !(await directState.sawHeaderPass))
        check("typed turn did not reach the planner prompt", await directState.sawToolCatalogue)
        check("typed conversation asked for \(await directState.lastMaxTokens.map(String.init) ?? "-") "
            + "tokens, expected at least 1,024", (await directState.lastMaxTokens ?? 0) >= 1_024)
        // The persona is the user's own text and is budgeted separately
        // (`--selftest-persona`); this ceiling is about the tool roster, and it is the
        // planner's own prompt that a typed conversation now pays for. The 1,500 the
        // speech path keeps is below it — the speech path is a header prompt with no
        // catalogue at all. 8,000 is the same bound the tool-request planner prompt is
        // held to above; the *sized* assertion is `PROMPT_TOKENS < 900` for 12 tools,
        // which is P1-03's to shrink. Measured 2026-09-25: 6,316 with the full roster.
        let personaCharacters = PersonaStore.shared.fullPersona().count
        print("CONVERSATION_PROMPT_CHARS: \(firstPromptCharacters) persona \(personaCharacters) "
            + "roster \(firstPromptCharacters - personaCharacters)")
        check("the tool planner's prompt left its measured budget (\(firstPromptCharacters) chars, persona \(personaCharacters))",
              firstPromptCharacters - personaCharacters < 8_000)


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
        // P0-5: the timeout names what actually ran, with its step count.
        check("timeout sentence did not name the last tool",
              fallback.reply.contains("computer.active_app"))
        check("timeout sentence lost its step count",
              fallback.reply.range(of: #"step \d+/\d+"#,
                                   options: .regularExpression) != nil)

        // P0-2 token budget, on the live loop too: a 12-tool planner prompt stays
        // under 900 tokens by the provider's own count.
        do {
            let liveAll = RealtimeAgent.plannableTools()
            let liveFiltered = RealtimeAgent.relevantTools(
                for: "open Chrome and go to youtube.com", all: liveAll)
            check("browser.navigate lost with the filter on (live loop)",
                  liveFiltered.contains { $0.id == "browser.navigate" })
            let liveTwelve = Array(liveFiltered.prefix(12))
            let liveSystem = RealtimeAgent.plannerSystem(
                tools: liveTwelve, voice: true, request: "open Chrome and go to youtube.com")
            let counter = ToolLoopTestProvider(state: ToolLoopTestState())
            let tokens = try await counter.countTokens(liveSystem)
            print("PROMPT_TOKENS: \(tokens) for \(liveTwelve.count) tools (live loop)")
            check("planner prompt too large in the live loop: \(tokens) tokens for 12 tools",
                  tokens < 900)
        } catch {
            failures.append("countTokens threw in the live loop: \(error.localizedDescription)")
        }

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
        // The speech path's own first pass, which P1-02 leaves alone: it must not pick up
        // the tool roster. The persona is the user's own text, budgeted separately.
        let voiceFirstPass = await voiceState.firstSystemCharacters
        check("conversation prompt still carries the full tool roster (\(voiceFirstPass) chars, persona \(personaCharacters))",
              voiceFirstPass - personaCharacters < 1_500)
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

        // P0-05 + P1-02 step 6: the budget a typed pass asks for comes from the reader's
        // window and the persona depth, never a literal — and after P1-02 that pass is the
        // planner round, whose cap used to be the 256 that truncated tool calls (H1 #3).
        // The depth rule itself is pinned in the table below, where `wanted` lives.
        agent.toolLoopLimitForTesting = nil
        let deepState = ToolLoopTestState()
        agent.answerDepthForTesting = .deep
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: deepState, firstCall: "", window: 32_768, firstPassAnswer: "4.")
        _ = await agent.runModelTurn("What's 2+2?", voice: false)
        let deepMax = await deepState.lastMaxTokens
        check("typed planner round asked for \(deepMax ?? -1), expected 1,024", deepMax == 1_024)

        let fastState = ToolLoopTestState()
        agent.answerDepthForTesting = .fast
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: fastState, firstCall: "", window: 32_768, firstPassAnswer: "4.")
        _ = await agent.runModelTurn("What's 2+2?", voice: false)
        let fastMax = await fastState.lastMaxTokens
        check("fast typed planner round asked for \(fastMax ?? -1), expected 1,024", fastMax == 1_024)

        // A small window: the depth budget is clamped to the room left after the prompt.
        let smallState = ToolLoopTestState()
        agent.answerDepthForTesting = .deep
        let pad = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
        AgentSession.shared.recordUser(pad, source: .text)
        AgentSession.shared.recordAssistant(pad)
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: smallState, firstCall: "", window: 1_536, firstPassAnswer: "4.")
        _ = await agent.runModelTurn("What's 2+2?", voice: false)
        let smallMax = await smallState.lastMaxTokens
        let smallPrompt = await smallState.lastPromptTokens
        let smallExpected = smallPrompt.map { max(64, min(1_024, 1_536 - $0 - 256)) }
        print("ANSWER_BUDGET: deep=\(deepMax ?? -1) fast=\(fastMax ?? -1) "
            + "small=\(smallMax ?? -1) prompt=\(smallPrompt ?? -1)")
        check("small-window planner round asked for \(smallMax ?? -1), expected "
            + "\(smallExpected ?? -1) from a \(smallPrompt ?? -1)-token prompt",
              smallMax != nil && smallMax == smallExpected)

        // The pure table, independent of any provider. `.typedAnswer` is the `.localModel`
        // answer now that the typed first pass is gone, and its depth sensitivity is
        // pinned here: a planner round's wanted value is floored at 1,024.
        let table: [(String, AgentAnswerBudget.Kind, AgentResponsiveness, Int, Int, Int)] = [
            ("typedAnswer/deep/262144", .typedAnswer, .deep, 262_144, 2_000, 500),
            ("typedAnswer/fast/32768", .typedAnswer, .fast, 32_768, 2_000, 128),
            ("typedAnswer/deep/1536-clamped", .typedAnswer, .deep, 1_536, 1_000, 280),
            ("plannerRound/deep/32768", .plannerRound(background: false), .deep, 32_768, 2_000, 1_024),
            ("plannerRound/fast/32768", .plannerRound(background: false), .fast, 32_768, 2_000, 1_024),
            ("plannerRound(background)/fast/8192", .plannerRound(background: true), .fast, 8_192, 2_000, 768),
            ("finalAnswer/balanced/4096", .finalAnswer, .balanced, 4_096, 3_900, 64),
        ]
        for (name, kind, depth, window, prompt, expected) in table {
            let asked = AgentAnswerBudget.tokens(
                kind: kind, contextTokens: window, promptTokens: prompt, depth: depth)
            check("budget table \(name) asked for \(asked), expected \(expected)", asked == expected)
        }
        agent.answerDepthForTesting = nil

        // P0-17 e. A reasoning model that spent its whole answer budget thinking and wrote
        // nothing says exactly that — it is not an "incomplete response" and it is not
        // prefixed as a model failure.
        agent.toolLoopLimitForTesting = nil
        MultiStepNotices.resetForTesting()
        agent.localModelProviderForTesting = CutOffTestProvider(visible: nil, cutOffVisible: false)
        let thoughtOnly = await agent.runModelTurn("What can you do?", voice: false)
        let thoughtOnlySentence = "The model spent its whole answer thinking and wrote nothing. "
            + "Try again, or pick a model without the Reasoning label in Settings ▸ Agent."
        // A typed turn now reaches the planner, and the planner is where P0-22's once-per-
        // session online notice is prefixed. That sentence is not what this case is about,
        // so it resets the notice and then asks whether the cut-off sentence is the ending.
        check("a cut-off with no text answered \"\(thoughtOnly.reply)\"",
              thoughtOnly.reply.hasSuffix(thoughtOnlySentence))
        check("a cut-off with no text kept the incomplete-response sentence",
              !thoughtOnly.reply.contains("incomplete response"))
        check("a cut-off with no text was prefixed as a model failure",
              !thoughtOnly.reply.hasPrefix("The model could not answer:"))

        // P0-17 f. A cut-off after visible text keeps the answer and ends with the cut-off
        // note, rather than replacing both with the failure sentence. P1-02 removed the
        // typed header pass, so the note is now added by the planner's own round — the
        // provider yields the text and then reports the cut-off, exactly as a reasoning
        // model does when its visible budget runs out.
        MultiStepNotices.resetForTesting()
        agent.localModelProviderForTesting = CutOffTestProvider(
            visible: "Hello the", cutOffVisible: true)
        let truncated = await agent.runModelTurn("Say hello.", voice: false)
        check("a cut-off after visible text lost the answer: \"\(truncated.reply)\"",
              truncated.reply.contains("Hello the"))
        check("a cut-off after visible text did not say it was cut off: \"\(truncated.reply)\"",
              truncated.reply.hasSuffix("(The answer was cut off.)"))
        check("a cut-off after visible text was prefixed as a model failure",
              !truncated.reply.hasPrefix("The model could not answer:"))

        // P1-02. Four cases, each written before the fix and each failing on the header
        // pass: a typed "hi" that cost two model round trips and could not hold a tool
        // call's arguments, and a "yes" that re-derived its own action.
        agent.toolLoopLimitForTesting = nil
        agent.answerDepthForTesting = .deep

        // Case 1: one typed "hi" is one model call, on the planner's own prompt, with a cap
        // big enough to hold a tool call and its arguments.
        let hiLog = PlannerScriptLog()
        agent.localModelProviderForTesting = PlannerScriptProvider(
            id: .localServer, window: 4_096, promptTokens: 2_000,
            script: ["Hi. What would you like to do?"], log: hiLog)
        let hi = await agent.handle("hi", source: .text)
        let hiCalls = hiLog.calls
        check("a typed \"hi\" made \(hiCalls.count) model call(s), expected exactly 1",
              hiCalls.count == 1)
        check("the typed \"hi\" did not use the planner prompt",
              hiCalls.first?.system.contains("Available tools:") == true)
        check("a typed turn used the response-header prompt",
              !hiCalls.contains { $0.system.contains("<use_tools/>") })
        check("a typed \"hi\" asked for \(hiCalls.first?.maxTokens ?? -1) tokens, expected at "
            + "least 1,024", (hiCalls.first?.maxTokens ?? 0) >= 1_024)
        check("a typed \"hi\" answered \"\(hi.reply)\"", !hi.reply.isEmpty)

        // Case 1b: the same turn against a nearly full window. 4,096 − (4,096 − 400) − 256
        // = 144: the room rule clamps, `contextTokens / 4` would not. The budget log line
        // is an `os.Logger` write, so what is pinned here is the label it carries.
        let tightLog = PlannerScriptLog()
        agent.localModelProviderForTesting = PlannerScriptProvider(
            id: .localServer, window: 4_096, promptTokens: 4_096 - 400,
            script: ["Hi."], log: tightLog)
        _ = await agent.handle("hi", source: .text)
        let tightMax = tightLog.calls.first?.maxTokens ?? -1
        check("a nearly full window asked for \(tightMax) tokens, expected 144 (room-clamped)",
              tightMax == 144)
        check("the planner round's budget log line is not labelled \(AgentAnswerBudget.Kind.plannerRound(background: false).label)",
              AgentAnswerBudget.Kind.plannerRound(background: false).label == "plannerRound")

        // Case 2: the offer, then "yes". The confirmation must reach the planner carrying
        // the earlier request, and the plan must run the tool the user already agreed to.
        let toolLog = ScriptedToolLog()
        AgentToolExecutor.fakeForTesting = { tool, _ in
            toolLog.record(tool.id)
            return AgentToolResult(summary: "1) Marcus Lee · Pricing sheet v3\n2) Ana Ruiz · Deck")
        }
        defer { AgentToolExecutor.fakeForTesting = nil }
        let emailLog = PlannerScriptLog()
        agent.localModelProviderForTesting = PlannerScriptProvider(
            id: .localServer, window: 4_096, promptTokens: 2_000,
            script: [
                "I can look through your inbox. Would you like me to do that?",
                "<tool_call>{\"name\":\"search_email\",\"arguments\":{\"query\":\"in:inbox\"},"
                    + "\"rationale\":\"read the inbox\"}</tool_call>",
                "You have two new messages: a pricing sheet and a deck for Friday.",
            ], log: emailLog)
        agent.setTypedPendingForTesting(nil)
        let offer = await agent.handle("Summarize my last emails", source: .text)
        check("the offer did not end in a question: \"\(offer.reply)\"",
              offer.reply.hasSuffix("?"))
        check("an offer that asks a question kept no pending action (\(agent.typedPending == nil))",
              agent.typedPending != nil)
        let confirmed = await agent.handle("yes", source: .text)
        let emailCalls = emailLog.calls
        check("a confirmation reached the model as \"\(String((emailCalls.last?.user ?? "").suffix(60)))\"",
              emailCalls.last?.user.contains("The user answered: yes") == true)
        check("a confirmation lost the earlier request",
              emailCalls.last?.user.contains("Summarize my last emails") == true)
        check("a confirmation ran no tool: \(toolLog.toolIDs)", toolLog.toolIDs == ["search_email"])
        check("the confirmed turn did not answer: \"\(confirmed.reply)\"",
              confirmed.reply.contains("pricing"))

        // Case 3: the same offer, declined. One sentence, and no model call at all.
        let declineLog = PlannerScriptLog()
        agent.localModelProviderForTesting = PlannerScriptProvider(
            id: .localServer, window: 4_096, promptTokens: 2_000,
            script: ["Shall I check the pricing sheet for you?"], log: declineLog)
        agent.setTypedPendingForTesting(nil)
        _ = await agent.handle("Summarize my last emails", source: .text)
        let beforeDecline = declineLog.calls.count
        let declined = await agent.handle("no", source: .text)
        check("a decline answered \"\(declined.reply)\"", declined.reply == "Okay, I won't.")
        check("a decline made \(declineLog.calls.count - beforeDecline) model call(s), expected 0",
              declineLog.calls.count == beforeDecline)
        check("a decline left a pending action behind", agent.typedPending == nil)

        // Case 4: the offer, then the conversation is cleared. The pending action dies with
        // its session, so "yes" is a new request and the model sees it alone.
        let orphanLog = PlannerScriptLog()
        agent.localModelProviderForTesting = PlannerScriptProvider(
            id: .localServer, window: 4_096, promptTokens: 2_000,
            script: ["Would you like me to read that message?"], log: orphanLog)
        agent.setTypedPendingForTesting(nil)
        _ = await agent.handle("Read my latest email", source: .text)
        check("the second offer kept no pending action (\(agent.typedPending == nil))",
              agent.typedPending != nil)
        AgentSession.shared.clear()
        let orphan = await agent.handle("yes", source: .text)
        let orphanUser = orphanLog.calls.last?.user ?? ""
        check("a cleared conversation carried the confirmation into the new request: "
            + "\"\(String(orphanUser.suffix(40)))\"",
              !orphanUser.contains("The user answered: yes"))
        check("the new request carried the confirmation prompt",
              orphanUser.contains("Current user request:\nyes"))

        agent.setTypedPendingForTesting(nil)
        agent.answerDepthForTesting = nil

        // P1-10a step 0 (landed in M-12): the Apple provider reads the framework's own
        // window, not the old 4,096 constant. Apple FM only; ABSENT elsewhere.
        if FoundationModelFormatter.unavailableReason == nil {
            let appleContext = SystemLanguageModel.default.contextSize
            let apple = FoundationModelLLMProvider()
            print("APPLE_FM_CONTEXT=\(apple.contextTokens)")
            check("FoundationModelLLMProvider.contextTokens answered \(apple.contextTokens), "
                + "not SystemLanguageModel.default.contextSize (\(appleContext))",
                  apple.contextTokens == appleContext)
        }

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
    /// P1-02: the evidence that a typed turn is one model call. `sawHeaderPass` is the
    /// defect itself — the response-header prompt (`<use_tools/>`) reaching a typed turn at
    /// all — and `sawToolCatalogue` is the fix, the planner's own "Available tools:" block.
    var sawHeaderPass = false
    var sawToolCatalogue = false
    /// P0-05 / P1-02: what the last model call asked for, and the prompt the provider
    /// counted for that same system + user. After P1-02 the typed pass is a planner round.
    var lastMaxTokens: Int?
    var lastPromptTokens: Int?

    func recordCall(maxTokens: Int, promptTokens: Int?) {
        lastMaxTokens = maxTokens
        lastPromptTokens = promptTokens
    }

    func next(user: String, system: String) -> Int {
        rounds += 1
        if rounds == 1 { firstSystemCharacters = system.count }
        lastSystemCharacters = system.count
        if system.contains("<use_tools/>") { sawHeaderPass = true }
        if system.contains("Available tools:") { sawToolCatalogue = true }
        if user.contains("computer.active_app returned") { sawToolResult = true }
        return rounds
    }

    func markCompleted() { completed = true }
}

private struct ToolLoopTestProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let state: ToolLoopTestState
    let firstCall: String
    let delay: Duration
    let secondRoundDelay: Duration
    let finalAnswer: String
    /// The window this provider reports. P0-05 varies it so the budget's room rule can be
    /// exercised without a small model installed.
    let window: Int
    /// A canned answer for a pass that makes no tool call; nil keeps the older script.
    let firstPassAnswer: String?
    var contextTokens: Int { window }
    var unavailableReason: String? { get async { nil } }

    init(state: ToolLoopTestState, firstCall: String = "computer.active_app",
         delay: Duration = .zero, secondRoundDelay: Duration = .zero,
         finalAnswer: String = "The frontmost application is the one reported by the system.",
         window: Int = 4_096, firstPassAnswer: String? = nil) {
        self.state = state
        self.firstCall = firstCall
        self.delay = delay
        self.secondRoundDelay = secondRoundDelay
        self.finalAnswer = finalAnswer
        self.window = window
        self.firstPassAnswer = firstPassAnswer
    }

    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    /// The protocol's default forwards to `stream`; this one also keeps the budget
    /// evidence for the voice branch's header pass (P0-05).
    func streamConversation(
        system: String, messages: [LLMChatMessage], maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        let user = messages.map { "\($0.role.rawValue.capitalized): \($0.content)" }
            .joined(separator: "\n\n")
        return await stream(system: system, user: user, maxTokens: maxTokens)
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        _ = await state.next(user: user, system: system)
        // The response-header prompt is the *voice* branch's, and it is the only system
        // that mentions `<use_tools/>`: a typed turn reaches the planner instead, so the
        // planner answers the request on its first round (P1-02).
        let choosing = system.contains("<use_tools/>")
        let afterTool = user.contains("computer.active_app returned")
        // `delay` is "this model stalls", not "this model stalls on the header prompt":
        // since P1-02 a typed turn has no header prompt, and a timeout case that only
        // stalled there would test nothing.
        let wait = afterTool ? secondRoundDelay : delay
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
        // Counted exactly as the planner round counts it, so a self-test can predict the
        // cap the room rule produces.
        let promptTokens = try? await countTokens(system + "\n" + user)
        await state.recordCall(maxTokens: maxTokens, promptTokens: promptTokens)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if firstCall.isEmpty {
                        _ = await state.next(user: user, system: system)
                        if let firstPassAnswer {
                            continuation.yield(firstPassAnswer)
                        } else if system.contains("<use_tools/>") {
                            // The voice header pass still answers with a header (P3-01
                            // moves the remaining callers onto the coordinator).
                            continuation.yield("<answer/>First answer.")
                            try await Task.sleep(for: delay)
                            continuation.yield(" Second answer.")
                        } else {
                            // A planner round answers in plain prose: there is no header to
                            // emit, because there is no header pass (P1-02).
                            continuation.yield("First answer.")
                            try await Task.sleep(for: delay)
                            continuation.yield(" Second answer.")
                        }
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

/// P1-02's scripted planner. One canned completion per call, in order, and the exact
/// `(system, user, maxTokens)` of every call — the evidence that a typed turn is one model
/// round trip carrying the planner's own prompt.
private final class PlannerScriptLog: @unchecked Sendable {
    struct Call: Sendable {
        let system: String
        let user: String
        let maxTokens: Int
    }

    private let lock = NSLock()
    private var storage: [Call] = []

    func record(_ call: Call) {
        lock.lock()
        storage.append(call)
        lock.unlock()
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// `countTokens` is pinned here rather than estimated, so the budget's room rule
/// (`contextTokens − promptTokens − 256`) is exercised exactly, with no model installed.
/// Not `.appLLM`: `AgentAnswerBudget.readerContextTokens` reads the resident runtime's real
/// window for that provider, and a self-test must not depend on what happens to be loaded.
private struct PlannerScriptProvider: LLMProvider {
    let id: LLMProviderID
    let window: Int
    let promptTokens: Int
    let script: [String]
    let log: PlannerScriptLog
    var contextTokens: Int { window }
    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { promptTokens }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = await next(system: system, user: user, maxTokens: maxTokens)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let text = await next(system: system, user: user, maxTokens: maxTokens)
                continuation.yield(text)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func streamConversation(
        system: String, messages: [LLMChatMessage], maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        let user = messages.map { "\($0.role.rawValue.capitalized): \($0.content)" }
            .joined(separator: "\n\n")
        return await stream(system: system, user: user, maxTokens: maxTokens)
    }

    private func next(system: String, user: String, maxTokens: Int) async -> String {
        let index = log.calls.count
        log.record(.init(system: system, user: user, maxTokens: maxTokens))
        return index < script.count ? script[index] : "There is nothing more to add."
    }
}

/// The tool answers the P1-02 cases see. The P1-01 seam (`AgentToolExecutor.fakeForTesting`)
/// answers every tool, so no real mail is read and no approval card is drawn.
private final class ScriptedToolLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ toolID: String) {
        lock.lock()
        storage.append(toolID)
        lock.unlock()
    }

    var toolIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// P0-17: a provider that ends a pass the way a reasoning model does when the visible
/// budget is spent thinking — G turn O5 (105 of 112 tokens thinking, `finish_reason:
/// "length"`). `visible` is the text (if any) written before the cut-off.
private struct CutOffTestProvider: LLMProvider {
    let id = LLMProviderID.openRouter
    let visible: String?
    let cutOffVisible: Bool
    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        throw OpenRouterError.cutOff(visibleText: cutOffVisible)
    }

    /// Both shapes a typed pass takes. P1-02 removed the header pass, so the planner
    /// round's `stream` has to cut off the same way the header pass's did.
    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if let visible { continuation.yield(visible) }
            continuation.finish(throwing: OpenRouterError.cutOff(visibleText: cutOffVisible))
        }
    }

    func streamConversation(
        system: String, messages: [LLMChatMessage], maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if let visible { continuation.yield(visible) }
            continuation.finish(throwing: OpenRouterError.cutOff(visibleText: cutOffVisible))
        }
    }
}
