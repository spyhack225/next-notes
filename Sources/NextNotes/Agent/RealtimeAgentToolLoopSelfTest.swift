import Foundation
import FoundationModels

/// Exercises the normal `RealtimeAgent.handle` route used by voice input. The fake
/// provider only controls planning; `computer.active_app` still goes through the real
/// registry, permission policy, and executor.
enum RealtimeAgentToolLoopSelfTest {
    /// **The conversational first pass's own budget, in characters, and the only one.**
    ///
    /// It was `4_500` at the `PROMPT_SIZE` check and `1_500` at the voice-turn check two hundred
    /// lines later, on the same prompt. That is not a tight bound and a loose one, it is one
    /// prompt with two answers, and the stricter one was failing a 4,229-character pass that the
    /// looser one passed — which is the worst way for a budget to disagree with itself, because
    /// the red said *"the roster leaked"* and the roster was never there. **One constant, two
    /// call sites**, so the next person who moves it has to move it once.
    ///
    /// 4,500 is a *measured* figure and not a round guess: the first pass is grounding plus rules
    /// plus the persona, the persona is budgeted separately by `--selftest-persona`, and the pass
    /// is the cheapest prompt on the spoken path because it is the one a person is waiting on.
    /// Measured 2026-09-27 at 4,229 — **94% of budget**, which is the number to watch. It is high
    /// because the voice path pays for grounding it cannot always use, and trimming it is a
    /// latency decision for whoever owns that path, not something to do by lowering a bound.
    static let voiceFirstPassBudget = 4_500
    /// Every switch on, every grant present, a signed-in account. The grounding checks are
    /// about the core set and the prompt's size, and neither should change because this Mac
    /// has no folder added or no Accessibility grant — those halves are asserted separately,
    /// against the live roster, with the sentence the person would be shown.
    @MainActor
    static func allEnabledFixture() -> AgentCapabilityInputs {
        .allEnabled(tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: .voiceFrontend)
    }

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

        // A fixture rather than the live index and the live roster: the assertions are about
        // what the assembler does with the facts, not about what happens to be on this Mac
        // today. The surfaces are a manifest's, because the manifest is where the abilities
        // are written in prose.
        let fixtureManifest = AgentCapabilityManifestBuilder.build(
            .allEnabled(tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: .voiceFrontend),
            request: "what's on my calendar")
        let fixture = AgentGrounding(
            assistantName: "Will", userFullName: "Serge Kadjo",
            folders: ["Desktop", "Documents", "Downloads"], indexedItems: 8_796,
            surfaces: fixtureManifest.groundingSurfaces
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
            !fixtureManifest.allowedIDs.contains(name) && !name.hasSuffix(".")
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
        let liveManifest = AgentCapabilityManifest.current(reader: .voiceFrontend)
        let roster = liveManifest.allowedIDs
        let liveTools = RealtimeAgent.plannableTools()
        let planner = RealtimeAgent.plannerSystem(
            manifest: AgentCapabilityManifestBuilder.build(
                AgentCapabilityInputs.live(reader: .voiceFrontend),
                request: "open my next notes folder"),
            voice: true, request: "open my next notes folder")
        let firstPass = RealtimeAgent.voiceRoutingSystem(voice: true)
        let spoken = LocalVoiceSplitResponse.answerInstructions
        // The voice first pass apportioned, because a number with no breakdown is a number
        // nobody can act on. The pieces are the ones `AgentPromptContext` actually assembles,
        // so this cannot drift from the prompt it is describing.
        let firstPassParts = AgentPromptContext.assemble(
            .toolLoop, rules: RealtimeAgent.voiceRoutingRules(voice: true))
        print("PROMPT_SIZE: planner=\(planner.count) chars over \(liveTools.count) tools, "
            + "first-pass=\(firstPass.count), spoken-answer=\(spoken.count)")
        print("PROMPT_SIZE_PARTS: first-pass persona=\(firstPassParts.persona.count) "
            + "grounding=\(firstPassParts.grounding.count) rules=\(firstPassParts.rules.count) "
            + "memory=\(firstPassParts.memory.count) capabilities=\(firstPassParts.capabilities.count) "
            + "skills=\(firstPassParts.skills.count)")
        check("the tool planner's prompt grew past its measured budget (\(planner.count) chars)",
              planner.count < 15_000)
        check("the conversational first pass picked up the tool roster (\(firstPass.count) chars)",
              firstPass.count < Self.voiceFirstPassBudget)

        // The roster the Apple voice path is shown. Its budget truncates from the end, so
        // the categories that matter most to the reported complaints are checked by name.
        let inventory = VoiceCapabilitySnapshot.make(tools: liveTools)
        print("PROMPT_SIZE: voice-capability-inventory=\(inventory.promptText.count) chars")
        for category in ["Local files", "Frontmost Mac UI", "Browser pages"] {
            check("the voice capability inventory dropped \(category)",
                  inventory.promptText.contains(category))
        }
        // The two indexed-folder tools are the only ids whose *allowance* depends on live
        // state: with no folder added they are enabled and unavailable, and the manifest says
        // so. Both halves are checked, because the pair is the contract — a person who has
        // added a folder must get them, and a person who has not must be told what to do.
        let indexFixtures: [(String, Bool)] = [("with folders", true), ("without folders", false)]
        for (label, available) in indexFixtures {
            var inputs = AgentCapabilityInputs.live(reader: .voiceFrontend)
            inputs.fileIndexAvailable = available
            let ids = AgentCapabilityManifestBuilder.build(
                inputs, request: "find the pricing doc")
            for id in [FileToolCatalogue.findID, FileToolCatalogue.treeID] {
                check("\(id) is not allowed \(label)",
                      ids.allowedIDs.contains(id) == available)
                check("\(id) is not named as needing setup \(label)",
                      ids.unavailableIDs.contains(id) == !available)
            }
            if !available {
                check("the missing index has no setup sentence",
                      ids.setupNotes.contains { $0.contains("Settings \u{25b8} Files") })
            }
        }
        for id in ["filesystem.reveal", "computer.open_app", "browser.navigate"] {
            check("\(id) is not in the planner roster", roster.contains(id))
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

        // P1-03: the core set survives every gate combo, and a turn's schema is whole intent
        // classes over that core — never a ranked tail. The core floor is what stops a
        // missing switch from dropping the tool a person actually needs.
        // A fixture with every gate open, so the floor is about the core set and not about
        // which folder this Mac happens to have added. What is left out of `allowed` on a
        // real machine is asserted above, with its setup sentence.
        var allTools = AgentCapabilityInputs.allEnabled(
            tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: .voiceFrontend)
        allTools.switches.knowledgeTools = false
        for (label, inputs) in [("on", allEnabledFixture()), ("off", allTools)] {
            let ids = AgentCapabilityManifestBuilder.build(inputs, request: "open a page").allowedIDs
            let missing = AgentCapabilityManifestBuilder.coreIDs.subtracting(ids)
            check("core tools missing with knowledge tools \(label): \(missing.sorted().joined(separator: ", "))",
                  missing.isEmpty)
        }
        let youtubeRequest = "open Chrome and go to youtube.com"
        // Two readers, because the fit is a function of the reader. 4,096 is Apple's floor
        // and the tightest budget the manifest ever fits for; 8,192 is what the same model
        // reports on this hardware and is the reader a voice turn is really planned against.
        var floorInputs = allEnabledFixture()
        floorInputs.reader = .init(provider: .appleFoundation, displayName: "Apple", contextTokens: 4_096)
        let worst = AgentCapabilityManifestBuilder.build(floorInputs, request: youtubeRequest)
        let youtube = AgentCapabilityManifestBuilder.build(
            allEnabledFixture(), request: youtubeRequest)
        for (label, manifest) in [("4,096", worst), ("8,192", youtube)] {
            check("core tools dropped by the class selection (\(label) reader)",
                  AgentCapabilityManifestBuilder.coreIDs.isSubset(of: manifest.selectedIDs))
            check("browser.navigate lost with the class selection (\(label) reader)",
                  manifest.selectedIDs.contains("browser.navigate"))
            // Whole classes: every allowed entry of a selected intent is in the schema.
            let partial = manifest.allowed.filter {
                manifest.selectedIntents.contains($0.intent) && !manifest.selectedIDs.contains($0.id)
            }
            check("a selected class was truncated for a \(label)-token reader "
                + "(\(partial.map(\.id).sorted().prefix(4).joined(separator: ", ")))",
                  partial.isEmpty)
        }
        // The manifest's own promise, checked in its own terms: the catalogue it fitted is
        // inside the budget it declared for this reader, and the compact rendering the
        // 4,096-token floor forces is the branch that has to work.
        for (label, manifest) in [("4,096", worst), ("8,192", youtube)] {
            let budget = AgentCapabilityManifestBuilder.catalogueBudget(for: manifest.reader)
            check("the catalogue is \(manifest.catalogueTokens) tokens over a \(label)-token "
                + "reader's \(budget)-token budget",
                  manifest.catalogueTokens <= budget)
        }
        check("a 4,096-token reader did not get the compact catalogue", worst.compactCatalogue)
        // Token budget for the prompt a navigation turn sends. Prefill is the whole latency
        // bill, so the planner prompt is counted with the provider's own tokenizer.
        //
        // The ceiling is a total, and the total has a floor that no catalogue choice moves:
        // the persona is ~250 tokens, the planner rules ~670 and the grounding ~115. A
        // whole-class screen-and-browser roster adds ~690 on top. (The P0-2 line this
        // replaces read "under 900 for 12 tools", which no prompt carrying the persona and
        // these rules could reach — measured 1,038 with an empty catalogue.)
        for (label, manifest) in [("4,096", worst), ("8,192", youtube)] {
            let youtubeSystem = RealtimeAgent.plannerSystem(
                manifest: manifest, voice: true, request: youtubeRequest)
            do {
                let counter = ToolLoopTestProvider(state: ToolLoopTestState())
                let tokens = try await counter.countTokens(youtubeSystem)
                print("PROMPT_TOKENS: \(tokens) for \(manifest.selected.count) tools "
                    + "on a \(label)-token reader")
                check("planner prompt too large: \(tokens) tokens for a whole-class roster "
                    + "on a \(label)-token reader (ceiling 2,000)", tokens < 2_000)
            } catch {
                failures.append("countTokens threw for a whole-class roster: "
                    + error.localizedDescription)
            }
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
            agent.budgetForTesting = nil
            agent.coldForTesting = nil
            agent.maxCallsForTesting = nil
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
        // P1-06: the seam is the whole budget now, with the same totals this case had.
        // P1-10 inverts the sentence, not the behaviour: the read still survives, and the
        // reply no longer names the tool that ran or counts the steps. "Did
        // computer.active_app (step 1/8). Timed out on get_agenda." is a sentence about
        // the app's insides, and the 09-22 reply that reached a typed person was its
        // ancestor. The read is the answer; the timeout is one line under it.
        let readResult = "Safari is frontmost; its window is “YouTube”."
        AgentToolExecutor.fakeForTesting = { tool, _ in
            tool.id == "computer.active_app"
                ? AgentToolResult(summary: readResult)
                : AgentToolResult(summary: "ok")
        }
        let fallbackState = ToolLoopTestState()
        agent.budgetForTesting = .init(
            perRound: .seconds(2), perReadCall: .seconds(2),
            ceiling: .seconds(2), coldLoadAllowance: .zero)
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: fallbackState, secondRoundDelay: .seconds(4)
        )
        let fallback = await agent.handle("which app is frontmost?", source: .text)
        check("a completed read was thrown away on model timeout: \"\(fallback.reply)\"",
              fallback.reply.hasPrefix(readResult))
        check("the second model pass was never exercised", (await fallbackState.rounds) >= 2)
        // P1-10b: the three things this sentence used to print.
        check("the timeout sentence named the tool that ran: \"\(fallback.reply)\"",
              !fallback.reply.contains("computer.active_app"))
        check("the timeout sentence carried a step count: \"\(fallback.reply)\"",
              fallback.reply.range(of: #"\bstep \d+/\d+\b"#,
                                   options: .regularExpression) == nil)
        check("the timeout sentence did not say it ran out of time: \"\(fallback.reply)\"",
              fallback.reply.contains("ran out of time"))
        AgentToolExecutor.fakeForTesting = nil

        // The same budget on the live loop, measured on the prompt a real navigation turn
        // sends. P1-03 replaced the hand-picked twelve-tool roster with the whole classes the
        // request matched, and this is the number that says what the planner now pays.
        do {
            let liveManifest = AgentCapabilityManifestBuilder.build(
                allEnabledFixture(), request: "open Chrome and go to youtube.com")
            check("browser.navigate lost with the class selection on (live loop)",
                  liveManifest.selectedIDs.contains("browser.navigate"))
            let liveSystem = RealtimeAgent.plannerSystem(
                manifest: liveManifest, voice: true, request: "open Chrome and go to youtube.com")
            let counter = ToolLoopTestProvider(state: ToolLoopTestState())
            let tokens = try await counter.countTokens(liveSystem)
            print("PROMPT_TOKENS: \(tokens) for \(liveManifest.selected.count) tools (live loop)")
            check("planner prompt too large in the live loop: \(tokens) tokens for a "
                + "whole-class roster", tokens < 2_000)
        } catch {
            failures.append("countTokens threw in the live loop: \(error.localizedDescription)")
        }

        // Mutations are available to the planner, but a malformed request must
        // fail at the executor before prompting or changing the user's UI.
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), firstCall: "computer.type"
        )
        let forbidden = await agent.handle("type a secret", source: .text)
        // P1-10b: the executor still refuses it, and the refusal no longer names the tool
        // or counts steps. "did not run" is gone from every user-facing string in the
        // Agent (P1-10's own Done-when), so the check is on what the sentence now owes:
        // it must not claim the text was typed, and it must name no id.
        check("malformed model mutation bypassed argument validation: \"\(forbidden.reply)\"",
              !forbidden.reply.contains("did not run")
                  && !forbidden.reply.localizedCaseInsensitiveContains("typed"))

        // A stalled model is bounded and cannot produce a late visible answer.
        agent.budgetForTesting = .init(
            perRound: .milliseconds(80), perReadCall: .milliseconds(80),
            ceiling: .milliseconds(80), coldLoadAllowance: .zero)
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), delay: .milliseconds(400)
        )
        let timedOut = await agent.handle("inspect this", source: .text)
        // P1-10b: the sentence is the renderer's — the person is still told, in the words
        // the renderer uses for a timeout.
        check("tool planner timeout was not visible: \"\(timedOut.reply)\"",
              timedOut.reply.localizedCaseInsensitiveContains("ran out of time"))

        // An ordinary answer, with no tool tag, must begin speaking from the
        // first complete streamed clause. Barge-in must suppress later chunks.
        agent.budgetForTesting = nil
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
        // The speech path's own first pass, which P1-02 leaves alone. **This check was wrong
        // about which pass it was looking at, and being wrong about it is what made it red.**
        //
        // It asserted `firstSystemCharacters - persona < 1_500`, the *header* pass's bound, on a
        // turn whose utterance is "tell me which app is frontmost" — a request for a tool, and
        // therefore a planner turn, whose first pass is the planner prompt and is supposed to
        // carry the fitted roster. The check failed at 4,229 characters having found nothing
        // wrong with anything: a correct planner prompt inside a header's budget.
        //
        // So the bound now branches on the thing it was actually about — whether the roster is in
        // this prompt — instead of on an assumption about which pass this is. Where the roster is
        // required it is held to the **planner's** 8,000, which is the bound the typed planner
        // prompt is held to above; where it is not required it is held to the header's 1,500. The
        // invariant is the same one the check was written to protect, and it is now *sharper*,
        // because the roster's presence is read off the prompt rather than inferred from the
        // utterance.
        let voiceFirstPass = await voiceState.firstSystemCharacters
        let voiceCarriesCatalogue = await voiceState.sawToolCatalogue
        check(voiceCarriesCatalogue
            ? "voice planner prompt carried the roster and stayed inside the planner bound (\(voiceFirstPass) chars, persona \(personaCharacters))"
            : "voice header pass stayed free of the roster (\(voiceFirstPass) chars, persona \(personaCharacters))",
              voiceCarriesCatalogue
                ? voiceFirstPass < 8_000
                : voiceFirstPass - personaCharacters < 1_500)

        // And the half that was never tested: a voice turn that asks for *nothing* must not reach
        // the catalogue at all. The check above could only ever see a tool-shaped utterance, so
        // "the speech path does not pick up the roster" was asserted exclusively about a turn that
        // legitimately has one. This is the case that makes the sentence true — and it is held to
        // the **same** `voiceFirstPassBudget` the pass above is held to, because inventing a
        // second, stricter number here would be the mirror image of the mistake just fixed.
        let quietVoiceState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: quietVoiceState, firstCall: "", finalAnswer: "It is frontmost."
        )
        await AgentCaptureController.shared.beginSession(captureAudio: false)
        _ = await agent.handle("say hello", source: .voice)
        check("a voice turn that wants no tool reached the planner", !(await quietVoiceState.sawToolCatalogue))
        let quietFirstPass = await quietVoiceState.firstSystemCharacters
        check("a voice turn that wants no tool stayed inside the first-pass budget (\(quietFirstPass) chars, persona \(personaCharacters))",
              quietFirstPass < Self.voiceFirstPassBudget)
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
        agent.budgetForTesting = nil
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
        agent.budgetForTesting = nil
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
        agent.budgetForTesting = nil
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
        AgentSession.shared.forgetAllConversations()
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

        // P1-04. Thirteen cases, each written before the fix and each failing on the
        // unmodified loop: the tolerant parser, the three-way error split, the name
        // resolver, the repair cap, the repeated-call note and relative-date grounding.
        // The roster is pinned so the manifest is the catalogue and not whatever this Mac
        // happens to have connected, which is the same fixture the live eval pins.
        AgentCapabilityManifestBuilder.inputsOverrideForTesting = AgentCapabilityInputs.allEnabled(
            tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: .voiceFrontend)
        defer { AgentCapabilityManifestBuilder.inputsOverrideForTesting = nil }
        failures.append(contentsOf: await runReadApprovalCases(agent: agent, check: check))
        failures.append(contentsOf: await runHistoryBudgetCases(agent: agent, check: check))
        failures.append(contentsOf: await runCutShortCases(agent: agent, check: check))
        failures.append(contentsOf: await runToleranceCases(agent: agent, check: check))
        failures.append(contentsOf: await runBudgetCases(agent: agent, check: check))
        failures.append(contentsOf: await runRendererCases(agent: agent, check: check))
        failures.append(contentsOf: await runClaimGuardCases(agent: agent, check: check))
        failures.append(contentsOf: runDirectIntentCases(check: check))
        failures.append(contentsOf: await runOnDeviceBoundaryCases(agent: agent, check: check))
        failures.append(contentsOf: runAccountReadCases(check: check))

        for failure in failures { print("  TOOLLOOP_PRODUCTION_WRONG: \(failure)") }
        print(failures.isEmpty ? "TOOLLOOP_PRODUCTION_OK" : "TOOLLOOP_PRODUCTION_FAILED")
        return failures.isEmpty
    }

    /// P1-24's table. Pure: no model, no provider, no store, no executor.
    ///
    /// The guard is pure and so is every one of these, which is deliberate and is the reason the
    /// three results P1-14 measured can be *stated* rather than hoped for. G4, G5 and G6 are the
    /// regressions that must not move, and they are the reason this is a table of eight and not
    /// a table of three: P1-14's version detected every bad turn and replaced two correct
    /// answers, so a test that only proved the good cases would have shipped that again.
    ///
    /// Red on the unmodified guard: G1, G1d, G1e, G3 and G7.
    @MainActor
    static func runAccountReadCases(check: (String, Bool) -> Void) -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name); check(name, false) }

        let manifest = AgentCapabilityManifestBuilder.build(
            AgentCapabilityInputs.allEnabled(
                tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: .voiceFrontend),
            request: "summarise my emails")
        func toolID(_ intent: AgentIntentClass) -> String? {
            AccountReadTools.toolID(for: intent, manifest: manifest)
        }
        func pending(
            _ reply: String, _ intents: Set<AgentIntentClass>, request: String = "summarise my emails",
            turn: [String] = [], session: Set<String> = []
        ) -> (intent: AgentIntentClass, toolID: String, arguments: [String: String])? {
            AgentAccountRead.pendingRead(
                reply: reply, selectedIntents: intents, completedThisTurn: turn,
                completedThisSession: session, toolIDFor: toolID, request: request)
        }

        // G1 — the owner's own failure: three emails, senders and subjects, no read at all.
        // Red before the guard: nothing proposed a read, so the invented list stood.
        let invented = """
            You have new mail:
            - Marcus Lee <marcus@productflo.example> — Pricing sheet v3
            - Ana Ruiz <ana@example.com> — Deck for Friday
            - Cyril <cyril@example.com> — Dinner tomorrow?
            """
        if pending(invented, [.mail])?.toolID != "search_email" {
            fail("G1: a fabricated mailbox with no read did not ask for one")
        }
        // G1b — the same in words rather than as a list, which is what O04 produced.
        if pending("Here are the six emails sitting in your inbox right now.", [.mail])?.toolID
            != "search_email" {
            fail("G1b: a reply naming the inbox did not ask for a read")
        }
        // G1c — a question naming the inbox is an offer, and an offer is not a claim.
        if pending("Want to see the latest messages in your inbox?", [.mail]) != nil {
            fail("G1c: an offer was treated as a fabricated answer")
        }
        // G1d — a promise to read, which is O02's own reply and the shape that made the first
        // version of the matcher miss it: the account is named with a modifier in between
        // ("your **latest** emails") and no content was produced. Running the read is strictly
        // better than the promise, and there is no correct answer here to replace.
        if pending("Got it. Checking your latest emails right away.", [.mail])?.toolID
            != "search_email" {
            fail("G1d: a promise to read the inbox was left as a promise")
        }
        // G1e — the same promise with no modifier at all, which is O04's own reply and the
        // second real sentence the modifier rule missed. Both are in the case set because both
        // were measured, and one of them is why the promise rule is a verb stem and not a word
        // from a list.
        if pending("Of course. I\u{2019}ll check your inbox right away.", [.mail])?.toolID
            != "search_email" {
            fail("G1e: \"I'll check your inbox right away\" was left as a promise")
        }

        // G2 — the honest sentence, and a pending action so "go for it" can run the read.
        //
        // **What is *not* here, deliberately.** The first draft of this case asserted that the
        // guard fires on "I haven't looked at your email yet." — which is the loop's *output*,
        // not an input it should react to. A guard that re-reads in response to the honest
        // sentence is P1-14's result 2 exactly: it would replace a correct answer with a
        // different correct sentence, forever. What the two loop paths actually do — run the
        // read where reads auto-run, say the sentence and arm the offer where they do not — is
        // decided by `agentAutoRunReadTools` inside the loop and is **not covered by a pure
        // test**; it is stated here rather than claimed.
        if pending("I haven't looked at your email yet.", [.mail]) != nil {
            fail("G2: the honest \"not looked yet\" sentence was treated as a fabricated answer")
        }
        let offer = PendingAction.unreadOffer(
            request: "check my emails", toolID: "search_email", sessionID: nil)
        if offer.capabilityID != "search_email" || offer.requestText != "check my emails" {
            fail("G2b: the unread offer does not carry the person's own request")
        }
        if AgentReplyRenderer.render(.answer(AgentAccountRead.notReadYet), voice: false)
            .contains("search_email") {
            fail("G2c: the honest sentence names a tool")
        }

        // G3 — the provenance question. "is this from" / "did you actually" / "where did you
        // get", and nothing that is merely a question about mail.
        for signature in ["Is this coming from my emails?", "Did you actually read those?",
                          "Where did you get that?"] {
            if AgentAccountRead.asksProvenance(signature) == false {
                fail("G3: \"\(signature)\" was not read as a provenance question")
            }
        }
        if AgentAccountRead.asksProvenance("What's in my email?") {
            fail("G3b: an ordinary question about email was read as a provenance question")
        }

        // G4 — K01 regression. After `meeting.decisions` ran, a reply about decisions is not a
        // fabricated mailbox, and the class is `.meetings` anyway, which this guard never fires
        // on. Both halves matter: P1-14's check replaced this answer.
        if pending("The decision was to move the launch to October 14.", [.meetings],
                   turn: ["meeting.decisions"]) != nil {
            fail("G4: a grounded meetings answer was re-planned for saying so")
        }
        // G5 — A04 regression. Same shape, the Mac's own state.
        if pending("Safari is frontmost; its window is YouTube.", [.screen],
                   turn: ["computer.active_app"]) != nil {
            fail("G5: a grounded screen answer was re-planned for saying so")
        }
        // G6 — M04 regression. A round that parsed `draft_email` never reaches the final-answer
        // site, and the guard is not consulted from anywhere else. Proved here by the shape of
        // the question: a draft is not a list of two entries, and `.mail` does not reach
        // `draft_email`'s arguments.
        let draft = "I've drafted it to ana@example.com saying you'll send the deck on Friday."
        if pending(draft, [.mail]) != nil {
            fail("G6: a proposed draft was treated as a fabricated mailbox")
        }
        // G8 — advice, not content. "your calendar is a good place to keep that" names the
        // account and asserts nothing about it.
        if pending("Your calendar is a good place to keep that — somewhere nobody would move it.",
                   [.calendar]) != nil {
            fail("G8: advice mentioning the calendar was treated as a fabricated agenda")
        }

        // The second condition, which is the one that costs a re-read: a class already read in
        // this turn, or earlier in this conversation, is not read again.
        if pending(invented, [.mail], turn: ["search_email"]) != nil {
            fail("the guard proposed a second mail read in a turn that already read mail")
        }
        if pending(invented, [.mail], session: ["search_email"]) != nil {
            fail("the guard re-read an account the conversation had already read")
        }
        // A class the manifest did not select this turn has no readable tool, so there is
        // nothing to run and nothing to promise.
        let empty = AgentCapabilityManifestBuilder.build(
            AgentCapabilityInputs.allEnabled(tools: [], reader: .voiceFrontend),
            request: "summarise my emails")
        if AccountReadTools.toolID(for: .mail, manifest: empty) != nil {
            fail("the guard found a mail tool in a manifest that selected none")
        }

        // Every class renders its own honest sentence, and none of them is a question — the
        // pending action is armed by `unreadOffer`, not by `detect`, precisely because a
        // question-shaped one would be a different thing.
        for (intent, expected) in [(AgentIntentClass.mail, "email"),
                                   (.calendar, "calendar"), (.drive, "Drive")] {
            let sentence = AgentAccountRead.notReadYet(intent)
            if sentence.contains(expected) == false {
                fail("the honest sentence for \(intent.rawValue) does not name what was not read")
            }
            if sentence.hasSuffix("?") {
                fail("the honest sentence for \(intent.rawValue) is a question")
            }
        }
        // A short offer is an offer: the three forms the 27 September log printed.
        for phrase in ["want to see the latest messages", "would you like to see them",
                       "should i show you what came in"] {
            if PendingAction.offerPhrases.contains(where: {
                phrase.lowercased().contains($0)
            }) == false {
                fail("\"\(phrase)\" is not read as an offer")
            }
        }
        print("  TOOLLOOP_PRODUCTION_ACCOUNT_READ: 10 cases, guard is pure")
        failures.append(contentsOf: runIdentifierCases(check: check))
        return failures
    }

    /// P1-17: "Look things up without asking" said one thing and did another.
    ///
    /// It was hard-coded `true` at three production call sites -- the planner's closure, the
    /// direct-intent path, and `ToolStepRunner` -- so switching it off changed nothing for a
    /// typed or a voice turn. `AgentToolExecutor.run` then folds that argument into the policy
    /// (`effective.autoRead = true`), so the constant did not merely fail to ask: it overwrote
    /// the answer the policy had already reached. The one place the switch *did* bite was
    /// `KnowledgeToolGate`, which hid the knowledge tools rather than asking about the read, so
    /// somebody who wanted to approve their reads lost meeting search outright.
    ///
    /// **These cases call the broker directly, and that is deliberate.** A whole synthetic turn
    /// through `handle` was tried first and is a broken way to test this: routing needs the
    /// state the earlier case groups build, and a case that never reaches the code it names
    /// reports the routing rather than the setting. One version of it did reach the loop and
    /// still measured nothing, because a shared `PlannerScriptLog` served the second case past
    /// the end of its own script. So the decision is read where the decision is made, and the
    /// wiring is read as text -- which is the only way to see a constant at three call sites.
    @MainActor
    static func runReadApprovalCases(
        agent: RealtimeAgent, check: (String, Bool) -> Void
    ) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name); check(name, false) }

        AgentToolExecutor.fakeForTesting = { _, _ in AgentToolResult(summary: "fixture") }
        defer { AgentToolExecutor.fakeForTesting = nil }
        /// The decision `run` made about the call it was handed, read back out of the executor
        /// rather than asserted by the caller.
        func decided(_ id: String, _ risk: AgentRisk, _ autoApproveReads: Bool) async -> Bool? {
            AgentToolExecutor.recordedReadApprovalsForTesting = []
            guard let tool = AgentToolRegistry.shared.tool(named: id), tool.risk == risk else {
                return nil
            }
            _ = try? await AgentToolExecutor.run(
                tool.id, arguments: [:], policy: .denyMutations,
                autoApproveReads: autoApproveReads, promptIfNeeded: false)
            return AgentToolExecutor.recordedReadApprovalsForTesting
                .first { $0.tool == tool.id }?.autoApproved
        }

        // 1. The switch off: a read asks. **Red before the change** -- the call sites passed
        // `true`, and the executor's `effective.autoRead = true` then overrode the policy.
        if await decided("search_email", .read, false) != false {
            fail("a read auto-ran with 'look things up' switched off")
        }
        // 2. The switch on: unchanged, which is the default and the common case.
        if await decided("search_email", .read, true) != true {
            fail("a read asked with 'look things up' switched on")
        }
        // 3. A write, with the read switch **on**: still asks. This is the half that stops the
        // fix becoming a licence, and it is why the recorded value is
        // `autoApproveReads && risk <= .read` rather than the argument on its own.
        // `.write`, not `.modify`: `draft_email` is a write that saves rather than sends, and
        // the case names the tool's own class rather than a guess at it.
        if await decided("draft_email", .write, true) != false {
            fail("a write auto-ran because the read switch was on")
        }

        // 4. The property those three call sites read, and the reason the harness needs an
        // override at all: the answer is the person's setting, with one override that exists
        // only under the harness so a self-test can never move the saved choice.
        let saved = Settings.shared.agentAutoRunReadTools
        if agent.readsRunWithoutAsking != saved {
            fail("'look things up' does not follow the saved setting")
        }
        agent.readApprovalOverrideForTesting = false
        if agent.readsRunWithoutAsking {
            fail("the self-test override did not turn the switch off")
        }
        agent.readApprovalOverrideForTesting = true
        if agent.readsRunWithoutAsking == false {
            fail("the self-test override did not turn the switch on")
        }
        agent.readApprovalOverrideForTesting = nil
        if Settings.shared.agentAutoRunReadTools != saved {
            fail("a self-test moved the owner's saved 'look things up' setting")
        }

        // 5. The three production call sites, read as text. The decision above proves the broker
        // honours the argument it is handed; this proves the argument is the person's answer at
        // every place a read can be planned. A literal `true` here *is* the bug, and it is
        // invisible to a case that only calls the function.
        let sites = ["Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift",
                     "Sources/NextNotes/Agent/Planner/ToolStepRunner.swift"]
        var literals: [String] = []
        for site in sites {
            guard let text = SourceScan.file(site) else {
                fail("could not read \(site) to check for a hard-coded read approval")
                continue
            }
            for (number, line) in text.split(separator: "\n").enumerated()
            where line.contains("autoApproveReads: true") {
                literals.append("\(site):\(number + 1)")
            }
        }
        check("a read is still approved by a constant rather than by the person's setting: "
            + literals.joined(separator: ", "), literals.isEmpty)

        // 6. And the gate, which is where the switch used to remove a tool instead of asking
        // about the read. Two inputs, and the tools stay visible either way.
        if KnowledgeToolGate.isAvailable(indexEnabled: true, toolsEnabled: true) == false {
            fail("the knowledge tools are hidden from a person who wants to approve their reads")
        }
        if KnowledgeToolGate.isAvailable(indexEnabled: true, toolsEnabled: false) {
            fail("the knowledge tools are visible with the Agent's own switch off")
        }
        if KnowledgeToolGate.isAvailable(indexEnabled: false, toolsEnabled: true) {
            fail("the knowledge tools are visible with the index off")
        }
        // P1-10b: the markup scrub, which had never run.
        //
        // `markupRegex` was written with Swift's `\u{200B}` inside an ICU pattern, so it did
        // not compile; `try?` made it `nil` and `if let markupRegex` skipped the first step of
        // the scrub on every reply in the app. The 27 September Portrait draft that was a raw
        // `tool_call` block (J L9) went through this function. The assertion is the regex
        // itself as well as the behaviour, because a scrub that does nothing and a scrub that
        // is not there look identical from a reply.
        if AgentReplyRenderer.markupPatternCompiled == false {
            fail("the reply scrub's markup pattern does not compile, so raw tool markup is never removed")
        }
        for markup in ["<\u{200B}tool_call>{\"name\":\"search_email\",\"arguments\":{}}</\u{200B}tool_call>",
                       "<tool_call>{\"name\":\"search_email\"}</tool_call>",
                       "</tool_call>", #"<think>The answer</think>"#] {
            let cleaned = AgentReplyRenderer.scrub("Here it is. \(markup) That is all.", outcome: nil)
            check("raw tool markup survived the scrub: \(cleaned)", !cleaned.contains("tool_call")
                && !cleaned.contains("<think>") && !cleaned.contains("search_email"))
            check("the answer around the markup was kept: \(cleaned)",
                  cleaned.contains("Here it is.") && cleaned.contains("That is all."))
        }
        check("a normal sentence is untouched by the markup scrub",
              AgentReplyRenderer.scrub("Your standup is at 9:30.", outcome: nil)
                  == "Your standup is at 9:30.")

        print("  TOOLLOOP_PRODUCTION_READ_APPROVAL: 3 recorded decisions, 1 setting check, "
            + "\(sites.count) call sites scanned, 2-switch knowledge gate, "
            + "5 markup forms scrubbed")
        return failures
    }

    /// P1-10b / J L8: an answer the model ran out of allowance on is shown as cut off.
    ///
    /// `finishedByLimit` existed on `LLMCompletion` and the final-answer round threw it away,
    /// taking `.text` off the optional and keeping nothing else. The person got half a sentence
    /// presented as the whole one, and there was no way to tell from the reply that anything
    /// was missing. The marker is the fix; the case is here so the flag cannot go back to
    /// being dropped.
    @MainActor
    static func runCutShortCases(
        agent: RealtimeAgent, check: (String, Bool) -> Void
    ) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name); check(name, false) }
        let hermes: (String) -> String = { "<\u{200B}tool_call>\($0)</\u{200B}tool_call>" }

        // The renderer's own sentence, both forms.
        let typed = AgentReplyRenderer.render(.cutShort("Ana owns the launch date and the deck is"),
                                              voice: false)
        check("a cut-off answer keeps what the model wrote: \"\(typed)\"",
              typed.contains("Ana owns the launch date"))
        check("a cut-off answer says it was cut off: \"\(typed)\"",
              typed.contains("cut off"))
        let spoken = AgentReplyRenderer.render(.cutShort("Ana owns the launch date and the deck is"),
                                               voice: true)
        check("the spoken form of a cut-off answer is shorter and still says so: \"\(spoken)\"",
              spoken.count <= typed.count && spoken.contains("cut off"))

        // And the wiring, read as text. The behavioural half above pins the sentence; this
        // pins the thing that made the sentence unreachable, which no call can observe:
        //
        // The planner's own rounds **stream**, and a stream yields strings, so
        // `LLMCompletion.finishedByLimit` is structurally unreachable there — the flag was
        // not being ignored, it was being thrown away. `LlamaGrammarPlanner` infers a cut-off
        // from the grammar refusing to match, and `PromptConventionPlanner` and
        // `OpenAIToolsPlanner` cannot see it at all. Carrying it out of a stream is a change
        // to every provider's signature, and not this task.
        //
        // The final answer round is the exception: it asks through `complete`, so it holds the
        // whole completion — and it is the sentence a person reads. The old line was
        // `(try? await …complete(…))?.text`, which took the text and discarded the flag.
        let loopSource = SourceScan.file("Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift")
        guard let loopSource else {
            fail("could not read the tool loop to check that a cut-off answer is not dropped")
            return failures
        }
        // The final-answer round, by the lines around its own `maxTokens: visible` call. The
        // closing paren is optional in the pattern because the call used to be wrapped in
        // `(try? …)` and no longer is — and a pattern written for the old shape is a pattern
        // that stops matching the moment the bug is fixed.
        guard let finalRound = loopSource.range(
            of: #"maxTokens: visible\)\)?[\s\S]{0,900}?finishedByLimit"#,
            options: .regularExpression) else {
            fail("the final answer round cannot see whether the model ran out of allowance, "
                + "so a cut-off answer is shown as a finished one")
            return failures
        }
        check("the final answer round reads the cut-off flag off the completion: "
            + "\(loopSource[finalRound].suffix(60).replacingOccurrences(of: "\n", with: " "))",
              loopSource[finalRound].contains("finishedByLimit"))
        // And the exact old shape is gone: the completion was taken apart for its text, which
        // is what made the flag unreachable in the first place.
        let discarded = loopSource.range(
            of: #"maxTokens: visible\)\)\?\?\.text"#, options: .regularExpression)
        check("the final answer round still throws the completion away for its text, at line "
            + "\(discarded.map { loopSource[..<$0.lowerBound].filter { $0 == "\n" }.count + 1 } ?? 0)",
              discarded == nil)

        print("  TOOLLOOP_PRODUCTION_CUT_SHORT: 3 sentences, final-answer round keeps the "
            + "completion; the streamed planner rounds cannot see the flag (recorded)")
        return failures
    }

    /// P1-18: how much earlier conversation a reader is shown scales with its own window.
    ///
    /// Red before the change at both ends: a 262,144-token reader was given 6,000 characters
    /// (a literal, and the same 6,000 whatever model answered), and `AgentSession` clipped the
    /// whole context to 10,000 on the way out — so even a caller that asked for more got 10,000
    /// and no word about it. The 4,096 reader's 2,500 is the number that must *not* move.
    ///
    /// The turn is driven the way `largestResultSeen` drives one — a scripted call, so the
    /// loop is engaged — and the measurement is the prompt the planner actually sent, read out
    /// of the recorded round rather than recomputed from the budget table.
    @MainActor
    static func runHistoryBudgetCases(
        agent: RealtimeAgent, check: (String, Bool) -> Void
    ) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name); check(name, false) }
        let hermes: (String) -> String = { "<\u{200B}tool_call>\($0)</\u{200B}tool_call>" }

        /// The conversation section of the first round the planner sent, in characters.
        ///
        /// The whole section, not its first block: the loop joins sections with a blank line and
        /// the conversation is the first one, so measuring a block measures the compaction
        /// summary and nothing else — 1,329 characters that looked like a 24,000 budget losing
        /// to a 6,000 one and was really a summary being counted on its own.
        ///
        /// `turns` is in the signature because the two readers cannot be given the same
        /// session. A 4,096-token reader cannot afford twenty exchanges of history: the prompt
        /// overflows, the round is never sent, and the case would be measuring an honest
        /// refusal rather than a budget. Six exchanges is ~4,000 characters, which is over a
        /// 2,500 budget and comfortably inside what that reader can send — so the small
        /// reader's assertion is not vacuous. If its budget were lifted to the planner's old
        /// 6,000 the section would come back at ~4,000 and the case would fail.
        func conversationShown(contextTokens: Int, turns: Int) async -> Int? {
            let log = PlannerScriptLog()
            agent.localModelProviderForTesting = PlannerScriptProvider(
                // Scaled with the window on purpose. A fixed 4,000 told a 4,096-token reader
                // that its whole prompt was 4,000 tokens, so the round could not be sent at
                // all and the case measured an honest overflow instead of a budget.
                id: .localServer, window: contextTokens,
                promptTokens: min(1_500, contextTokens / 2),
                script: [hermes(#"{"name":"search_email","arguments":{"query":"pricing"}}"#),
                         "Here is what it says."],
                log: log)
            agent.budgetForTesting = nil
            agent.setTypedPendingForTesting(nil)
            // Each pair is one exchange, which is the shape compaction keeps whole.
            for turn in 0..<turns {
                AgentSession.shared.recordUser(
                    "Turn \(turn) asked about the pricing sheet and the launch date. "
                        + String(repeating: "detail ", count: 40), source: .text)
                AgentSession.shared.recordAssistant(
                    "Turn \(turn) answered about the pricing sheet and the launch date. "
                        + String(repeating: "detail ", count: 40))
            }
            AgentSession.shared.recordUser("And what about the deck?", source: .text)
            defer {
                AgentSession.shared.forgetAllConversations()
                agent.localModelProviderForTesting = nil
            }
            _ = await agent.handle("what is in the pricing sheet", source: .text)
            let first = log.calls.first?.user ?? ""
            guard let range = first.range(of: RealtimeAgent.conversationSectionLabel) else { return nil }
            var section = first[range.upperBound...]
            for header in ["Relevant local memory for names and labels:", "Current user request:"] {
                if let end = section.range(of: header) {
                    section = section[..<end.lowerBound]
                }
            }
            return section.trimmingCharacters(in: .whitespacesAndNewlines).count
        }

        // 26 exchanges, ~660 characters each: ~17,000 characters of history, which is over the
        // assertion's 15,000 and under the 24,000 budget, so nothing is compacted away and the
        // number is the budget's rather than the summary's.
        let roomy = await conversationShown(contextTokens: 262_144, turns: 26)
        if roomy == nil {
            fail("the planner never sent a round, so no history budget was measured")
        } else if roomy! < 15_000 {
            fail("a 262,144-token reader was shown \(roomy!) characters of earlier turns, "
                + "expected at least 15,000")
        }
        let small = await conversationShown(contextTokens: 4_096, turns: 6)
        if small == nil {
            fail("the planner never sent a round to the small reader")
        } else if small! > 2_500 {
            fail("a 4,096-token reader was shown \(small!) characters of earlier turns, "
                + "over its 2,500")
        }
        print("  TOOLLOOP_PRODUCTION_HISTORY_BUDGET: 262,144 reader "
            + "\(roomy.map(String.init) ?? "no round") chars, 4,096 reader "
            + "\(small.map(String.init) ?? "no round") chars")
        return failures
    }

    /// A source file beside the compiled product, for the checks that have to read code rather
    /// than run it. `nil` when the tree is not where it was -- and the case that asked says so
    /// rather than passing quietly, because a scan that found no file must not read as a scan
    /// that found no literal.

    /// P1-25's table. Pure: no model, no provider, no store, no executor.
    ///
    /// The failure it exists for is the only Workspace write ever approved on this Mac: an
    /// `append_doc` whose `document_id` was *"You open Google Chrome"*, approved about eight
    /// seconds after it was proposed, and rejected by Google. The id was a fragment of the
    /// person's own sentence — so the rule is not "an id must look like an id", it is "an id
    /// must have been *said*", and that is what I4 pins as carefully as I1.
    static func runIdentifierCases(check: (String, Bool) -> Void) -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name); check(name, false) }

        // Every id-kind parameter in the catalogue is marked. One mark per parameter, and
        // "every" is the assertion: a tool added next month with an unmarked `document_id`
        // would otherwise be silently unguarded.
        var marked: [String] = []
        for tool in WorkspaceTools.all {
            marked += tool.parameters.filter { $0.kind == .identifier }.map {
                "\(tool.name).\($0.name)"
            }
        }
        for expected in ["read_email.message", "read_doc.document_id", "append_doc.document_id",
                         "reply_email.message_id"] {
            if marked.contains(expected) == false {
                fail("\(expected) is not marked as an identifier")
            }
        }
        // Nothing else in the catalogue claims to be one, so a later tool cannot be guarded by
        // accident through a name the heuristic happens to like.
        if marked.count != 4 {
            fail("\(marked.count) parameters are marked as identifiers, expected 4: "
                 + marked.joined(separator: ", "))
        }

        // I1 — the owner's own call. Red before the guard: nothing looked at the value.
        //
        // The refusal is read through a **named binding**, never an index. The first version of
        // this case indexed `[0]` after an `isEmpty` check, and when the guard (wrongly) found
        // nothing the test crashed with "Index out of range" instead of failing — which is how a
        // real bug in the guard was found, and the worst way to find one.
        let said = "Append bring passports to the trip doc"
        let refusals = AgentIdentifierGrounding.ungrounded(
            toolID: "append_doc", arguments: ["document_id": "You open Google Chrome"],
            haystack: said)
        guard let refusal = refusals.first else {
            fail("I1: an id lifted from the person's own sentence was accepted")
            print("  TOOLLOOP_PRODUCTION_IDENTIFIERS: aborted at I1, no guard to describe")
            return failures
        }
        let note = AgentIdentifierGrounding.note(for: refusal)
        if note.contains("document_id") {
            fail("I1b: the refusal names a schema key the model must not read back")
        }
        if note.contains("You open Google Chrome") {
            fail("I1c: the refusal quotes the value back, so the model can keep it")
        }

        // I2 — the id a search actually returned. This is the case that must keep working:
        // a guard that refuses every id is a guard that stops Drive and Docs.
        let found = "1) Pricing sheet v3 — Google Drive (id: 1AbCdEfGhIjKlMnOp)"
        if AgentIdentifierGrounding.ungrounded(
            toolID: "append_doc", arguments: ["document_id": "1AbCdEfGhIjKlMnOp"],
            haystack: said + "\n" + found).isEmpty == false {
            fail("I2: an id a search returned was refused")
        }

        // I3 — an id the person typed. The rule is "said or shown", and a person typing a
        // document id is the other half of that; refusing it would make a working request
        // impossible for the exact people who can do it.
        if AgentIdentifierGrounding.ungrounded(
            toolID: "append_doc", arguments: ["document_id": "1XyZ"],
            haystack: said + "\nAppend to doc 1XyZ please").isEmpty == false {
            fail("I3: an id the user typed was refused")
        }

        // I4 — the message *number*. A search prints numbered rows and the tool description
        // says to read one by its number, so "2" is grounded by the number being printed and
        // not by anything resembling an id. A substring test handles it; a shape test would
        // have refused it, and refusing it would break every "read the second one" turn.
        let listed = "1) Marcus Lee — Pricing sheet v3\n2) Ana Ruiz — Deck for Friday\n3) Cyril"
        if AgentIdentifierGrounding.ungrounded(
            toolID: "read_email", arguments: ["message": "2"],
            haystack: listed).isEmpty == false {
            fail("I4: a search result's own numbering was refused")
        }
        // And a number that was not printed is refused, which is the same test's other half.
        if AgentIdentifierGrounding.ungrounded(
            toolID: "read_email", arguments: ["message": "9"],
            haystack: listed).isEmpty {
            fail("I4b: a message number no search printed was accepted")
        }

        // A tool with no marked parameter is untouched by all of this, so nothing that is not
        // an id can be refused by a rule about ids.
        if AgentIdentifierGrounding.ungrounded(
            toolID: "create_event", arguments: ["title": "Anything at all"],
            haystack: "nothing relevant here").isEmpty == false {
            fail("a non-identifier parameter was refused by the identifier rule")
        }
        print("  TOOLLOOP_PRODUCTION_IDENTIFIERS: \(4) id parameters marked, "
            + "I1–I4 green, matcher is \"FunctionCallGrounding\" reused")
        return failures
    }

    /// P1-08's table. Pure: no model, no provider, no store.
    ///
    /// The shortcut exists because a planner round cost 44.78 s of prefill for a request
    /// whose arguments were in the sentence. It also dropped the rest of the sentence, so
    /// "open youtube and play the latest Cortech video" was answered "Opened youtube.com."
    /// in 0.3 s and "find the pricing document and email it to Marcus" was answered with a
    /// file search. The fix is not a smarter parser — it is the shortcut claiming only
    /// sentences it fully consumes, and the planner seeing the rest.
    ///
    /// Red on the unmodified parser: rows 3, 4 and 6 (leftover words), and "ask the agent"
    /// (routed to the answer-only local model instead of the planner). Rows 1, 2, 5 and 7
    /// are the regressions that must not move — two of them are measured utterances
    /// (2026-09-20 20:45:00Z and 20:45:41Z) and one is the eval's own A03 guard.
    @MainActor
    static func runDirectIntentCases(check: (String, Bool) -> Void) -> [String] {
        var failures: [String] = []
        func case1(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let youtube = AgentDirectIntent.openURL(url: "https://www.youtube.com", app: nil)

        // Input | strict | loose
        let table: [(input: String, strict: AgentDirectIntent?, loose: AgentDirectIntent?)] = [
            ("open youtube", youtube, youtube),
            ("open chrome and go to youtube.com",
             .openURL(url: "https://youtube.com", app: "Google Chrome"),
             .openURL(url: "https://youtube.com", app: "Google Chrome")),
            // Leftovers: "search cats" is a second thing to do, so the shortcut must not claim it.
            ("open youtube and search cats", nil, youtube),
            ("open youtube and play the latest cortech video", nil, youtube),
            ("find the pricing document", .locate(query: "pricing document", wantsFolder: false),
             .locate(query: "pricing document", wantsFolder: false)),
            // Leftovers: the email half is a send, and a shortcut that stops after the
            // search says "I'll email it to Marcus" and does nothing of the sort.
            ("find the pricing document and email it to marcus", nil,
             .locate(query: "pricing document email marcus", wantsFolder: false)),
            ("open safari", .openApp("Safari"), .openApp("Safari")),

            // P1-13. G N7, A6 22:07:03: "Open google calendar on google chrome" said
            // "Opening https://www.google.com…" and opened Chrome on google.com — the
            // calendar never opened, the planner then refused, and it fabricated a
            // get_agenda run. `knownSites` held single words only, so the bare word
            // "google" won the sentence before "calendar" was ever read.
            //
            // Red on the unmodified parser: rows 1, 2, 4 and 7 (loose). Rows 3, 5 and 6
            // are the regressions that must not move — row 3 is Apple's Calendar app,
            // row 5 is the one-word site the phrases share a word with, and row 6 is
            // P1-08's "the planner decides the rest" rule.
            ("open google calendar on google chrome",
             .openURL(url: "https://calendar.google.com", app: "Google Chrome"),
             .openURL(url: "https://calendar.google.com", app: "Google Chrome")),
            // A lone "calendar" is Apple's Calendar app; inside "google calendar" it is
            // the page, and the app must not be opened as well.
            ("open google calendar", .openURL(url: "https://calendar.google.com", app: nil),
             .openURL(url: "https://calendar.google.com", app: nil)),
            ("open calendar", .openApp("Calendar"), .openApp("Calendar")),
            // "docs" is not a word the strict remainder knows, so this row also pins that
            // a matched phrase is *consumed* rather than read as a leftover instruction.
            ("open google docs", .openURL(url: "https://docs.google.com", app: nil),
             .openURL(url: "https://docs.google.com", app: nil)),
            ("open google", .openURL(url: "https://www.google.com", app: nil),
             .openURL(url: "https://www.google.com", app: nil)),
            ("open google and search flights", nil, .openURL(url: "https://www.google.com", app: nil)),
            // Leftovers: "add lunch with Ana" is a second thing to do, so the shortcut
            // stands down and the planner reads the whole sentence.
            ("open google calendar and add lunch with ana", nil,
             .openURL(url: "https://calendar.google.com", app: nil)),
        ]
        for row in table {
            let strict = AgentDirectIntent.parse(row.input)
            let loose = AgentDirectIntent.parse(row.input, wholeSentence: false)
            case1("shortcut took \"\(row.input)\" with words left over: \(String(describing: strict))",
                  strict == row.strict)
            case1("the loose parse changed for \"\(row.input)\": \(String(describing: loose))",
                  loose == row.loose)
        }

        // The named risk of a phrase list: a site phrase shadowing an app. "google chrome"
        // is two words of "google", and it must stay the browser — the search is over
        // apps, and the only reason a phrase could take it is a phrase naming "chrome".
        case1("a site phrase shadowed the browser named in the same sentence: "
            + "\(String(describing: AgentDirectIntent.parse("open google chrome")))",
              AgentDirectIntent.parse("open google chrome")
                  == .openURL(url: "https://www.google.com", app: "Google Chrome"))
        // A one-word site and its own phrase must name the same page, or "open drive" and
        // "open google drive" would answer differently about the same thing.
        case1("\"drive\" and \"google drive\" name different pages",
              AgentDirectIntent.namedURL(in: "open drive")
                  == AgentDirectIntent.namedURL(in: "open google drive"))

        // A gate may only add routes, so the loose parse is what the voice coordinator
        // keeps: "open youtube and play the latest cortech video" must still reach work
        // rather than the conversational model.
        case1("the voice coordinator's parse is not the strict one",
              AgentDirectIntent.parse("open youtube and play the latest cortech video",
                                      wholeSentence: false) != nil)
        // "ask the agent" is this app. It used to select the answer-only local model, which
        // is why "Ask the agent what's on my calendar tomorrow" answered "I don't have that
        // information" with get_agenda sitting in the roster.
        let choice = AgentHarnessChoice(
            id: .local, source: .settings, available: true, fallbackToLocal: false, note: "")
        case1("\"ask the agent\" is not the planner",
              AgentTurnIntent.resolve(
                "Ask the agent what's on my calendar tomorrow", choice: choice)
                  == .toolLoop(prompt: "what's on my calendar tomorrow"))
        // Explicit on-device phrasing keeps its own route — now a read-only plan on the
        // app's own model rather than a tool-less answer.
        case1("explicit on-device phrasing lost its route",
              AgentTurnIntent.resolve("ask the local model what is 2+2", choice: choice)
                  == .localModel(prompt: "what is 2+2"))
        // The word boundary. "ask apple support" starts with the letters of "ask app".
        case1("\"ask apple support\" was read as \"ask app\"",
              AgentTurnIntent.resolve("ask apple support", choice: choice)
                  == .toolLoop(prompt: "ask apple support"))
        // The delegate is still asked first: a named external harness is not this app.
        case1("a named external harness no longer delegates",
              AgentTurnIntent.resolve(
                "ask the agent what's on my calendar tomorrow",
                choice: AgentHarnessChoice(
                    id: .claude, source: .explicit, available: true,
                    fallbackToLocal: true, note: "")
              ) == .delegate)

        // The read-only boundary of the on-device route, as a fact about the builder the
        // route hands `maxRisk: .read` to. Everything above a read is absent, so the
        // planner on this turn cannot even name it.
        let onDeviceReader = AgentCapabilityManifest.Reader(
            provider: .appLLM, displayName: "fixture", contextTokens: 32_768)
        let onDevice = AgentCapabilityInputs.allEnabled(
            tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: onDeviceReader)
        let readOnly = AgentCapabilityManifestBuilder.build(
            onDevice, request: "ask the local model what is on my calendar", maxRisk: .read)
        case1("the read-only manifest admitted a tool above .read",
              readOnly.allowed.allSatisfy { $0.risk <= .read })
        case1("the read-only manifest admitted a write",
              readOnly.allowedIDs.isDisjoint(with: [
                "computer.open_app", "browser.navigate", "send_email", "draft_email",
                "create_event", "schedule.create", "memory.remember", "filesystem.write",
            ]))
        case1("the read-only manifest cannot read the calendar",
              readOnly.allowedIDs.contains("get_agenda"))
        // And the ordinary turn is unchanged: the ceiling is a parameter, not a new default.
        let ordinary = AgentCapabilityManifestBuilder.build(
            allEnabledFixture(), request: "what's on my calendar", maxRisk: .send)
        case1("the ordinary manifest lost a write",
              !ordinary.allowedIDs.isDisjoint(with: ["send_email", "create_event"]))
        case1("the reader was not bound to the manifest: \(readOnly.reader.contextTokens)",
              readOnly.reader == onDeviceReader)
        return failures
    }

    /// P1-10's eight cases. Written before the fix; every one of them fails on the
    /// unmodified loop, because the loop had no cap, no fitter and no renderer — it
    /// appended every result verbatim and printed `computer.active_app (step 1/8)` at a
    /// typed person.
    ///
    /// Case 1 (the inverted timeout sentence) lives in `run()` beside the fixture it
    /// belongs to, because that fixture is the live loop's own and moving it would change
    /// what it measures. Case 7 is red by construction on today's `voiceSafeReply`, which
    /// replaces the whole reply when it contains "quota" or "not downloaded" — so
    /// "What's a sales quota?" came back as a usage-limit notice.
    @MainActor
    static func runRendererCases(
        agent: RealtimeAgent, check: (String, Bool) -> Void
    ) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name) }

        let hermes: (String) -> String = { "<tool_call>\($0)</tool_call>" }
        /// A result with a known size and no newline, so the character count the cap
        /// produced is exact rather than a function of where the lines happened to fall.
        func bulkResult() -> String { String(repeating: "abcdefghij", count: 3_000) }
        func charactersOfBulk(_ text: String) -> Int {
            text.components(separatedBy: "abcdefghij").count - 1
        }

        // Case 2. The renderer table: every outcome, through `render`, and then through
        // `scrub` as `conclude` applies it. Nothing a person reads may carry a registry
        // id, "step n/m", "ERROR:" or — on anything that is not an answer — a URL.
        let outcomes: [(String, AgentTurnOutcome)] = [
            ("timedOut/nil", .timedOut(lastVerified: nil)),
            ("timedOut/result", .timedOut(lastVerified: "Design sync at 15:00.")),
            ("stopped", .stopped),
            ("denied", .denied("You declined, so nothing was sent.")),
            ("infrastructure/plain", .infrastructure("the backend said no in a plain way")),
            ("infrastructure/usage", .infrastructure(
                "429 Too Many Requests: you've hit your quota")),
            ("repairLimit", .repairLimit(lastVerified: nil)),
            ("contextOverflow", .contextOverflow(lastVerified: "3 files found.")),
            ("modelUnavailable", .modelUnavailable("Gemma is not downloaded")),
            ("modelFailed", .modelFailed("Error: context not initialized at 0x1")),
            ("handedOffFellBack", .handedOffFellBack(
                note: "Codex stopped: ERROR: You've hit your usage limit. "
                    + "Visit https://chatgpt.com/codex/settings/usage",
                then: .modelFailed("the harness exited 1"))),
        ]
        // The ids and aliases the scrub has to know about, read from the one registry, so
        // a new tool is covered the day it is added.
        let registryNames: [String] = RealtimeAgent.callNames(
            AgentCapabilityManifestBuilder.build(
                allEnabledFixture(), request: "what is on my agenda")).sorted()
        check("the scrub table has no ids to check against (\(registryNames.count))",
              registryNames.count > 20)
        for (name, outcome) in outcomes {
            for voice in [true, false] {
                let text = AgentReplyRenderer.render(outcome, voice: voice)
                let both = text + " " + AgentReplyRenderer.scrub(text, outcome: outcome)
                let lower = both.lowercased()
                let leaked = registryNames.filter { both.localizedCaseInsensitiveContains($0) }
                check("render(\(name), voice: \(voice)) leaked \(leaked.prefix(3).joined(separator: ", "))",
                      leaked.isEmpty)
                check("render(\(name), voice: \(voice)) printed ERROR:",
                      !lower.contains("error:"))
                check("render(\(name), voice: \(voice)) printed a step count",
                      both.range(of: #"\bstep \d+/\d+\b"#, options: .regularExpression) == nil)
                if case .answer = outcome {} else {
                    check("render(\(name), voice: \(voice)) kept a url: \"\(boundedReply(both))\"",
                          !lower.contains("http://") && !lower.contains("https://"))
                }
            }
        }
        // The 09-22 string that reached a typed person, verbatim, and what it must become.
        let codex = AgentReplyRenderer.render(
            .infrastructure("Codex stopped: ERROR: You've hit your usage limit. "
                + "Visit https://chatgpt.com/codex/settings/usage"),
            voice: false)
        check("the 09-22 Codex string is not a usage-limit sentence: \"\(boundedReply(codex))\"",
              codex.contains("usage limit"))
        check("the 09-22 Codex string kept its url: \"\(boundedReply(codex))\"",
              !codex.contains("chatgpt.com"))
        check("the 09-22 Codex string kept a tool id: \"\(boundedReply(codex))\"",
              !codex.contains("Codex stopped"))
        // The four causes the table maps, and the four actions that fix them.
        for (reason, expected) in [
            ("not signed in", "Connect it in Settings"),
            ("The helper is not installed", "isn't installed"),
            ("Google timed out", "didn't answer in time"),
            ("HTTP 429: quota exceeded", "usage limit"),
        ] {
            let text = AgentReplyRenderer.render(.infrastructure(reason), voice: false)
            check("infrastructure(\(reason)) rendered \"\(boundedReply(text))\", expected \(expected)",
                  text.localizedCaseInsensitiveContains(expected))
        }

        // Case 3. The cap ladder, as a pure table, and then through a real turn.
        for (tokens, expected) in [(4_096, 700), (8_192, 1_200), (32_768, 4_000), (262_144, 12_000)] {
            let cap = ToolResultBudget.characterCap(readerContextTokens: tokens)
            check("a \(tokens)-token reader got a \(cap)-character cap, expected \(expected)",
                  cap == expected)
        }
        check("a document-reading tool did not get twice the cap",
              ToolResultBudget.characterCap(readerContextTokens: 262_144, toolID: "read_doc")
                  == 24_000)
        check("an ordinary tool got the document tool's cap",
              ToolResultBudget.characterCap(readerContextTokens: 262_144, toolID: "search_email")
                  == 12_000)
        check("WorkspaceToolRunner's cap with no bound reader is not 2,000",
              WorkspaceToolRunner.maxResultCharacters(toolID: "search_email") == 2_000)
        let bound = ToolResultBudget.$readerContextTokens.withValue(262_144) {
            WorkspaceToolRunner.maxResultCharacters(toolID: "search_email")
        }
        check("WorkspaceToolRunner's cap inside a 262,144-token reader is \(bound), expected 12,000",
              bound == 12_000)
        // And the same four numbers through the loop, with the result the model reads.
        for (window, expected) in [(4_096, 700), (8_192, 1_200), (32_768, 4_000), (262_144, 12_000)] {
            let seen = await largestResultSeen(agent: agent, hermes: hermes, bulk: bulkResult(),
                                               window: window, tool: "search_email")
            check("a \(window)-token reader was shown \(seen.characters) characters of a "
                + "30,000-character result, expected at most \(expected) "
                + "(reply: \(boundedReply(seen.reply)))", seen.characters <= expected)
        }
        let readDoc = await largestResultSeen(agent: agent, hermes: hermes, bulk: bulkResult(),
                                              window: 262_144, tool: "read_doc")
        check("read_doc at 262,144 tokens was shown \(readDoc.characters) characters, "
            + "expected over 12,000 and at most 24,000 (reply: \(boundedReply(readDoc.reply)))",
              readDoc.characters > 12_000 && readDoc.characters <= 24_000)

        // Case 4. The per-round fitter. A provider that counts characters honestly, a
        // 4,096-token window and four large results: every round it sends has to leave the
        // visible budget and the headroom inside the window, or the pass is refused for
        // being too long — which is the failure this case exists to prevent.
        do {
            let log = PlannerScriptLog()
            let calls = Array(repeating: hermes(
                #"{"name":"search_email","arguments":{"query":"q"}}"#), count: 5)
                + ["Here is what I found."]
            agent.localModelProviderForTesting = CountingScriptProvider(
                window: 4_096, script: calls, log: log)
            AgentToolExecutor.fakeForTesting = { _, _ in
                AgentToolResult(summary: bulkResult())
            }
            agent.answerDepthForTesting = .fast
            agent.budgetForTesting = .init(
                perRound: .seconds(5), perReadCall: .seconds(5),
                ceiling: .seconds(60), coldLoadAllowance: .zero)
            agent.setTypedPendingForTesting(nil)
            AgentSession.shared.forgetAllConversations()
            let turn = await agent.handle("summarize my last four emails", source: .text)
            AgentToolExecutor.fakeForTesting = nil
            agent.localModelProviderForTesting = nil
            agent.answerDepthForTesting = nil
            agent.budgetForTesting = nil
            var worst = 0
            for call in log.calls {
                let estimate = (call.system.count + call.user.count) / 4
                let total = estimate + call.maxTokens + AgentAnswerBudget.safetyTokens
                worst = max(worst, total)
            }
            print("FITTED_PROMPT: \(log.calls.count) round(s), worst total \(worst) tokens "
                + "of 4,096")
            check("the fitter let a round ask for \(worst) tokens of a 4,096-token window",
                  !log.calls.isEmpty && worst <= 4_096)
            check("the fitter ended the turn on the overflow sentence: \"\(boundedReply(turn.reply))\"",
                  !turn.reply.contains("did not produce an answer"))
        }

        // Case 5. A provider that says the prompt did not fit is `.contextOverflow`, and
        // the sentence is the plain one — not "The tool planner failed: ".
        do {
            agent.localModelProviderForTesting = OverflowingScriptProvider()
            agent.budgetForTesting = nil
            agent.setTypedPendingForTesting(nil)
            let turn = await agent.handle("what is on my agenda", source: .text)
            agent.localModelProviderForTesting = nil
            check("a context-window error is not a planner failure: \"\(boundedReply(turn.reply))\"",
                  !turn.reply.contains("The tool planner failed"))
            check("a context-window error has no plain sentence: \"\(boundedReply(turn.reply))\"",
                  turn.reply.localizedCaseInsensitiveContains("too much to read"))
        }

        // Case 6. The 09-22 03:00Z leak, through the one gate every path passes.
        do {
            agent.localModelProviderForTesting = PlannerScriptProvider(
                id: .localServer, window: 4_096, promptTokens: 2_000,
                script: ["Use filesystem.find to search for the pricing sheet."],
                log: PlannerScriptLog())
            agent.setTypedPendingForTesting(nil)
            let turn = await agent.handle("find the pricing sheet", source: .text)
            agent.localModelProviderForTesting = nil
            check("a typed reply leaked a tool id through conclude: \"\(boundedReply(turn.reply))\"",
                  !turn.reply.contains("filesystem.find"))
            check("the scrub took the sentence with it: \"\(boundedReply(turn.reply))\"",
                  turn.reply.localizedCaseInsensitiveContains("pricing"))
        }

        // Case 7. An answer is never rewritten. These three are the user's own topic, and
        // today's voice rule replaced all of them with a usage-limit or a
        // download-notice.
        for (answer, label) in [
            ("A sales quota is the target a rep must hit in a period.", "a sales quota"),
            ("The file is not downloaded yet, so open it from Drive first.", "not downloaded"),
            ("I hit a rate limit on the stairs.", "a rate limit"),
        ] {
            check("scrub rewrote an answer about \(label): \"\(answer)\"",
                  AgentReplyRenderer.scrub(answer, outcome: nil) == answer)
            check("voiceSafeReply rewrote an answer about \(label)",
                  RealtimeAgent.voiceSafeReply(answer) == answer)
        }
        check("voiceSafeReply rewrote a plain question",
              RealtimeAgent.voiceSafeReply("What's a sales quota? It's a sales target.")
                  == "What's a sales quota? It's a sales target.")
        let usage = AgentReplyRenderer.render(
            .infrastructure("429 Too Many Requests: you've hit your quota"), voice: true)
        check("a 429 is not the usage-limit sentence: \"\(boundedReply(usage))\"",
              usage.localizedCaseInsensitiveContains("usage limit"))
        let missing = AgentReplyRenderer.render(
            .modelUnavailable("Gemma is not downloaded"), voice: true)
        check("a model that is not downloaded is named as not ready: \"\(boundedReply(missing))\"",
              missing.localizedCaseInsensitiveContains("isn't ready"))
        // The four raw P0-7 fixtures, through `render` — which is the call
        // `VoiceCapabilityConversationSelfTest` has to make now that `voiceSafeReply` is a
        // scrub. Pinned here because the fix is in a file this task does not own, and a
        // handoff nobody can check is a handoff nobody will make. P0-7's own three
        // conditions: no "error:", no "http", no "is not downloaded".
        for raw in [
            "Codex stopped: ERROR: You've hit your usage limit, I'll do it myself",
            "The model is not downloaded.",
            "OpenRouter HTTP 429: Rate limited",
            "https://openrouter.ai/api/v1 failed",
        ] {
            let outcome: AgentTurnOutcome = raw.contains("not downloaded")
                ? .modelUnavailable(raw) : .infrastructure(raw)
            let fixed = AgentReplyRenderer.render(outcome, voice: true)
            let fixedLower = fixed.lowercased()
            check("P0-7 fixture \"\(raw)\" still leaks raw text through render: "
                + "\"\(boundedReply(fixed))\"",
                  !fixedLower.contains("error:") && !fixedLower.contains("http")
                    && !fixedLower.contains("is not downloaded"))
        }

        // Case 8. A speakable answer is spoken. The verified result used to win over the
        // reply, so "You have two events: standup at 9 and review at 3." was replaced by
        // the agenda count while the person was waiting for the sentence they could read.
        do {
            let tracker = AgentToolSpeechTracker(
                agent: agent, turn: agent.currentGeneration, allowSpeech: false)
            tracker.recordVerifiedResult(toolID: "get_agenda",
                                         output: "- 09:00 standup\n- 15:00 review")
            let spoken = tracker.spokenFallback(
                for: "You have two events: standup at 9 and review at 3.")
            check("a speakable answer was replaced by the result summary: \"\(boundedReply(spoken))\"",
                  spoken.contains("standup at 9"))
            let noVerified = AgentToolSpeechTracker(
                agent: agent, turn: agent.currentGeneration, allowSpeech: false)
            let unspeakable = noVerified.spokenFallback(for: "See /Users/x/a.txt")
            check("an unspeakable answer with no result read a path aloud: \"\(boundedReply(unspeakable))\"",
                  unspeakable == "I have the result, but its details are easier to read "
                    + "in the conversation.")
        }

        return failures
    }

    /// How much of a 30,000-character result the next round's user message actually
    /// carried, for one reader window. A real turn through the real loop, so the number is
    /// the one the model would read rather than the one the table predicts.
    @MainActor
    private static func largestResultSeen(
        agent: RealtimeAgent, hermes: (String) -> String, bulk: String,
        window: Int, tool: String
    ) async -> (characters: Int, reply: String) {
        let log = PlannerScriptLog()
        // P1-25 changed this fixture, and the change is the point. It used to ask
        // `read_doc` with `document_id` "1" on a turn about a pricing sheet — an id nothing
        // said and nothing showed — and the identifier guard refused it, so the case measured
        // 0 characters and failed. **The guard was right and the fixture was wrong**: a real
        // turn cannot have an id nobody ever saw. So the script now does what a person would
        // do, search and then read the document the search named, which also puts I2's
        // scenario through the real loop rather than only through the pure function.
        let documentID = "1AbCdEfGhIjKlMnOp"
        let script: [String]
        if tool == "read_doc" {
            script = [hermes(#"{"name":"search_email","arguments":{"query":"pricing document"}}"#),
                      hermes(#"{"name":"read_doc","arguments":{"document_id":"\#(documentID)"}}"#),
                      "Here is what it says."]
        } else {
            script = [hermes(#"{"name":"search_email","arguments":{"query":"pricing"}}"#),
                      "Here is what it says."]
        }
        agent.localModelProviderForTesting = PlannerScriptProvider(
            id: .localServer, window: window, promptTokens: 2_000, script: script, log: log)
        agent.budgetForTesting = nil
        agent.setTypedPendingForTesting(nil)
        // Cleared *after* the provider is built and before the turn, so the search's result is
        // the only thing in the conversation when `read_doc` is planned.
        AgentSession.shared.forgetAllConversations()
        let ran = ScriptedToolLog()
        AgentToolExecutor.fakeForTesting = { tool, _ in
            ran.record(tool.id)
            // The listing that grounds the id, and the document itself, are different sizes on
            // purpose: the listing is short and the document is the bulk result whose cap this
            // case is measuring.
            if tool.id == "search_email" {
                return AgentToolResult(summary: "1) Pricing sheet v3 — Google Drive (id: "
                    + documentID + ")")
            }
            return AgentToolResult(summary: bulk)
        }
        let turn = await agent.handle("what is in the pricing sheet", source: .text)
        AgentToolExecutor.fakeForTesting = nil
        agent.localModelProviderForTesting = nil
        // Every round, not only the last: the point is how much of the result the model was
        // shown, and a plan that took a repair round puts the result in an earlier one.
        let seen = log.calls.map(\.user).map { user -> Int in
            (user.components(separatedBy: bulk.prefix(10)).count - 1) * 10
        }.max() ?? 0
        return (seen, "\(log.calls.count) round(s); tools=\(ran.toolIDs); "
            + "longest user \(log.calls.map(\.user.count).max() ?? 0) chars; " + turn.reply)
    }

    /// A reply is logged, never replayed into the unified log whole.
    private static func boundedReply(_ text: String) -> String {
        String(text.prefix(160).replacingOccurrences(of: "\n", with: " "))
    }

    /// P1-06's cases: a per-round deadline, a ceiling, the cold-load allowance, and the one
    /// final answer-only round that has to be affordable when a plan runs out of rounds or
    /// calls.
    ///
    /// Cases 1 and 6 are the red-first pair and both fail on the unmodified loop: the plan
    /// held one number for every round together, so a three-step plan was cut off before the
    /// answer, and a plan that hit the call cap ended on a sentence with nothing in it.
    @MainActor
    static func runBudgetCases(
        agent: RealtimeAgent, check: (String, Bool) -> Void
    ) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name) }

        let hermes: (String) -> String = { "<tool_call>\($0)</tool_call>" }
        let agenda = hermes(#"{"name":"get_agenda","arguments":{}}"#)
        let mail = hermes(#"{"name":"search_email","arguments":{"query":"in:inbox"}}"#)
        let decisions = hermes(#"{"name":"meeting.decisions","arguments":{}}"#)
        let fixture = "Design sync, Dentist"
        /// P1-14. These three cases used to manufacture *distinct* reads as
        /// `search_email(query: "q0")` … `"q3"`, and stopped being distinct the moment a mail
        /// filter the user never said was grounded away (`AgentToolLoop.groundMailFilter`):
        /// four calls with four invented filters became one call with no filter, the plan saw
        /// one repeated signature, and it ended after a single read. The fixture now varies the
        /// **tool**, which is what these cases are about — the call cap, the round backstop and
        /// the answer-only round — and not about mail filtering. Every assertion below is
        /// unchanged, and the mail filter has its own cases further down.
        // `filesystem.search` and not `find`/`tree`: the latter two read the *indexed* folders
        // and are not ready on a machine with no folder added, so a call to either ends the
        // plan on a setup sentence instead of running. Six reads that need nothing.
        let distinctReads = [
            agenda,
            mail,
            decisions,
            hermes(#"{"name":"filesystem.search","arguments":{"query":"x"}}"#),
            hermes(#"{"name":"computer.active_app","arguments":{}}"#),
            hermes(#"{"name":"meeting.recent_context","arguments":{}}"#),
        ]

        /// One scripted plan: the provider's script, the delay each round spends, the calls
        /// the model made, and the reads the executor answered.
        struct Case {
            let reply: String
            let tools: [String]
            let calls: [PlannerScriptLog.Call]
        }

        @MainActor
        func run(
            request: String = "summarize my last emails and list tomorrow",
            script: [String], delays: [Duration] = [],
            budget: ToolLoopBudget, depth: AgentResponsiveness? = nil,
            cold: Bool? = nil, maxCalls: Int? = nil,
            result: String = fixture
        ) async -> Case {
            let log = PlannerScriptLog()
            let ran = ScriptedToolLog()
            AgentToolExecutor.fakeForTesting = { tool, _ in
                ran.record(tool.id)
                return AgentToolResult(summary: result)
            }
            agent.localModelProviderForTesting = BudgetScriptProvider(
                id: .localServer, window: 4_096, promptTokens: 2_000,
                script: script, delays: delays, log: log)
            agent.budgetForTesting = budget
            agent.coldForTesting = cold
            agent.maxCallsForTesting = maxCalls
            agent.answerDepthForTesting = depth
            agent.setTypedPendingForTesting(nil)
            AgentSession.shared.forgetAllConversations()
            let turn = await agent.handle(request, source: .text)
            AgentToolExecutor.fakeForTesting = nil
            agent.budgetForTesting = nil
            agent.coldForTesting = nil
            agent.maxCallsForTesting = nil
            agent.answerDepthForTesting = nil
            return Case(reply: turn.reply, tools: ran.toolIDs, calls: log.calls)
        }

        // Case 1. Three tool rounds at 2 s each and an answer round: 8 s of work that the
        // old 18 s total could not hold either, because the reads and the answer each paid
        // the whole plan's clock. The per-round deadline is what makes it fit.
        do {
            let result = await run(
                script: [agenda, mail, decisions, "Tomorrow: Dentist and Design sync."],
                delays: [.seconds(2)],
                budget: .init(perRound: .seconds(3), perReadCall: .seconds(3),
                              ceiling: .seconds(20), coldLoadAllowance: .zero))
            check("a three-read plan answered \"\(result.reply)\"",
                  result.reply.hasSuffix("Tomorrow: Dentist and Design sync."))
            check("a three-read plan made \(result.calls.count) model call(s), expected 4",
                  result.calls.count == 4)
            check("a three-read plan ran \(result.tools.count) read(s), expected 3",
                  result.tools.count == 3)
            check("a three-read plan said it ran out of time: \"\(result.reply)\"",
                  !result.reply.localizedCaseInsensitiveContains("ran out of time"))
        }

        // Case 2. One round over its own deadline, after a read succeeded. The read's result
        // is the answer; the plan is not.
        do {
            let result = await run(
                script: [agenda, "Here is your day."],
                delays: [.zero, .seconds(4)],
                budget: .init(perRound: .seconds(3), perReadCall: .seconds(3),
                              ceiling: .seconds(20), coldLoadAllowance: .zero))
            check("a round over its deadline threw the verified read away: \"\(result.reply)\"",
                  result.reply.hasPrefix(fixture))
            check("a round over its deadline did not say so: \"\(result.reply)\"",
                  result.reply.localizedCaseInsensitiveContains("ran out of time"))
            check("a round over its deadline ran \(result.tools.count) read(s), expected 1",
                  result.tools.count == 1)
        }

        // Case 3. The ceiling. Six 2 s rounds against 7 s: the plan stops on the ceiling, and
        // what it had verified still leads the reply.
        do {
            let result = await run(
                script: [agenda, mail, decisions, agenda, mail, decisions, "Later."],
                delays: [.seconds(2)],
                budget: .init(perRound: .seconds(3), perReadCall: .seconds(3),
                              ceiling: .seconds(7), coldLoadAllowance: .zero))
            check("the ceiling let the plan answer \"\(result.reply)\"",
                  result.reply.hasPrefix(fixture))
            check("the ceiling did not stop the plan: \(result.calls.count) model call(s)",
                  result.calls.count == 4)
        }

        // Case 4. The cold-load allowance. The first round is paying for weights, so its
        // deadline is perRound + the allowance, and only the first round's.
        do {
            let result = await run(
                script: [agenda, "Here is your day."],
                delays: [.seconds(5), .zero],
                budget: .init(perRound: .seconds(3), perReadCall: .seconds(3),
                              ceiling: .seconds(20), coldLoadAllowance: .seconds(3)),
                cold: true)
            check("a cold first round over its deadline answered \"\(result.reply)\"",
                  result.reply.contains("Here is your day."))
            check("a cold first round made \(result.calls.count) model call(s), expected 2",
                  result.calls.count == 2)
        }

        // Case 5. The call cap. Four reads, then the model is out of calls: it gets one
        // answer-only round, with no catalogue and a small visible cap, and its prose is the
        // reply. Before the final round this ended on "I couldn’t finish the tool plan within
        // the safe limit." with no result in it at all.
        let expectedFinalVisible = AgentAnswerBudget.tokens(
            kind: .finalAnswer, contextTokens: 4_096, promptTokens: 2_000, depth: .fast)
        do {
            let result = await run(
                script: Array(distinctReads.prefix(4)) + ["Here is what I found: result-4."],
                budget: .init(perRound: .seconds(5), perReadCall: .seconds(5),
                              ceiling: .seconds(60), coldLoadAllowance: .zero),
                depth: .fast)
            check("the call cap ran \(result.tools.count) read(s), expected exactly 4",
                  result.tools.count == 4)
            check("the call cap made \(result.calls.count) model call(s), expected 5 "
                + "(four rounds and one answer-only round)", result.calls.count == 5)
            let final = result.calls.last
            check("the final round was sent a tool catalogue",
                  final?.system.contains("Available tools:") != true)
            check("the final round was not told to answer: \""
                + String((final?.user ?? "").suffix(60)) + "\"",
                  (final?.user ?? "").hasSuffix("Answer now from what you have; no tool calls."))
            check("the final round asked for \(final?.maxTokens ?? -1) visible tokens, "
                + "expected \(expectedFinalVisible)",
                  final?.maxTokens == expectedFinalVisible)
            check("the call cap answered \"\(result.reply)\"",
                  result.reply.hasSuffix("Here is what I found: result-4."))
            check("the call cap ended on the bare safe-limit sentence: \"\(result.reply)\"",
                  !result.reply.contains("safe limit"))
        }

        // Case 6. Round exhaustion, with the call cap raised so rounds run out first. Six
        // rounds, then exactly one answer-only round: seven provider calls.
        do {
            let result = await run(
                script: Array(distinctReads.prefix(6)) + ["Here is what I found: result-6."],
                budget: .init(perRound: .seconds(5), perReadCall: .seconds(5),
                              ceiling: .seconds(60), coldLoadAllowance: .zero),
                depth: .fast, maxCalls: 20)
            check("round exhaustion ran \(result.tools.count) read(s), expected 6",
                  result.tools.count == 6)
            check("round exhaustion made \(result.calls.count) model call(s), expected "
                + "\(ToolLoopBudget.plannerMaxRounds(maxCalls: 4) + 1)",
                  result.calls.count == ToolLoopBudget.plannerMaxRounds(maxCalls: 4) + 1)
            check("round exhaustion answered \"\(result.reply)\"",
                  result.reply.hasSuffix("Here is what I found: result-6."))
        }

        // Case 7. A final round that disobeys and emits a call anyway. Nothing runs, and the
        // reply is still the last thing the plan verified.
        do {
            let result = await run(
                script: Array(distinctReads.prefix(4))
                    + [hermes(#"{"name":"meeting.action_items","arguments":{}}"#)],
                budget: .init(perRound: .seconds(5), perReadCall: .seconds(5),
                              ceiling: .seconds(60), coldLoadAllowance: .zero),
                depth: .fast)
            check("a disobedient final round executed \(result.tools.count) read(s), expected 4",
                  result.tools.count == 4)
            check("a disobedient final round lost the verified read: \"\(result.reply)\"",
                  result.reply.hasPrefix(fixture))
        }

        // Case 8. Rounds follow calls, so one rebuttal or one repair cannot cost the plan
        // its answer round. The table is pure: no provider, no turn.
        for (depth, maxCalls, expected) in [
            (AgentResponsiveness.fast, 4, 6),
            (AgentResponsiveness.balanced, 8, 10),
            (AgentResponsiveness.deep, 8, 10),
        ] {
            let rounds = ToolLoopBudget.plannerMaxRounds(maxCalls: maxCalls)
            check("planner rounds for \(depth.rawValue) with a call cap of \(maxCalls) "
                + "is \(rounds), expected \(expected)", rounds == expected)
        }

        // Case 9. The table itself, and the two deadlines it produces. Pure.
        check("a typed cloud turn did not resolve to the cloud budget",
              ToolLoopBudget.forTurn(provider: .openRouter, voice: false, background: false)
                  == .typedCloud)
        check("a typed local turn did not resolve to the local budget",
              ToolLoopBudget.forTurn(provider: .appLLM, voice: false, background: false)
                  == .typedLocal)
        check("the interactive voice path did not resolve to its own budget",
              ToolLoopBudget.forTurn(provider: .appLLM, voice: true, background: false)
                  == .voiceInteractive)
        check("a background worker did not resolve to the worker budget",
              ToolLoopBudget.forTurn(provider: .appLLM, voice: true, background: true)
                  == .voiceWorker)
        let local = ToolLoopBudget.typedLocal
        check("a cold first round got \(local.roundLimit(round: 0, cold: true, ceilingRemaining: local.ceiling)) "
            + "s, expected 75", local.roundLimit(round: 0, cold: true, ceilingRemaining: local.ceiling)
                == .seconds(75))
        check("a warm second round got the cold allowance",
              local.roundLimit(round: 1, cold: true, ceilingRemaining: local.ceiling)
                == .seconds(30))
        check("a round overran the ceiling it had left",
              local.roundLimit(round: 0, cold: true, ceilingRemaining: .seconds(20))
                == .seconds(20))
        check("a read call overran the ceiling it had left",
              local.readCallLimit(ceilingRemaining: .seconds(9)) == .seconds(9))
        check("a read call was not widened by the cold allowance",
              local.readCallLimit(ceilingRemaining: local.ceiling) == local.perReadCall)

        // Case 10. The correction refill: once, then not again for ten seconds. Pure, so
        // the rule is pinned without a model and without a stopwatch.
        do {
            let now = ContinuousClock.now
            var remaining = Duration.seconds(0)
            check("a correction with no time left did not refill",
                  ToolLoopBudget.refill(ceilingRemaining: &remaining, budget: .voiceWorker,
                                        lastRefill: nil, now: now))
            check("a refilled ceiling is \(remaining), expected 60",
                  remaining == .seconds(60))
            check("a second correction inside the interval refilled again",
                  !ToolLoopBudget.refill(ceilingRemaining: &remaining, budget: .voiceWorker,
                                         lastRefill: now,
                                         now: now.advanced(by: .seconds(9))))
            check("a correction past the interval did not refill",
                  ToolLoopBudget.refill(ceilingRemaining: &remaining, budget: .voiceWorker,
                                        lastRefill: now,
                                        now: now.advanced(by: .seconds(11))))
            check("a second refill is \(remaining), expected 60 (never more than the half)",
                  remaining == .seconds(60))
        }

        return failures
    }

    /// P1-08's read-only boundary, where it matters: not as a property of the manifest
    /// builder but as what a turn can execute.
    ///
    /// "Ask the local model" is a read-only route, and the reason is that the person who
    /// says it has asked for this Mac and for a question — not for a send. A model that
    /// reaches for a write anyway must not reach it, and the sentence it gets back must be
    /// an ordinary one with no id in it.
    ///
    /// The control row is the same script on an ordinary turn, where the same call does run.
    /// Without it a green first row would prove something about the script rather than about
    /// the ceiling, and that is the mistake this pairing exists to rule out.
    @MainActor
    static func runOnDeviceBoundaryCases(
        agent: RealtimeAgent, check: (String, Bool) -> Void
    ) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name) }

        struct Outcome {
            let reply: String
            let tools: [String]
            let rounds: Int
        }
        @MainActor
        func run(_ request: String, script: [String]) async -> Outcome {
            let log = PlannerScriptLog()
            let ran = ScriptedToolLog()
            AgentToolExecutor.fakeForTesting = { tool, _ in
                ran.record(tool.id)
                return AgentToolResult(summary: "Sent to marcus@example.com.")
            }
            agent.localModelProviderForTesting = PlannerScriptProvider(
                id: .localServer, window: 4_096, promptTokens: 2_000, script: script, log: log)
            agent.setTypedPendingForTesting(nil)
            agent.budgetForTesting = nil
            agent.setTypedPendingForTesting(nil)
            AgentSession.shared.forgetAllConversations()
            let turn = await agent.handle(request, source: .text)
            AgentToolExecutor.fakeForTesting = nil
            return Outcome(reply: turn.reply, tools: ran.toolIDs, rounds: log.calls.count)
        }

        let hermes: (String) -> String = { "<tool_call>\($0)</tool_call>" }
        let send = hermes(
            #"{"name":"send_email","arguments":{"to":"marcus@example.com","subject":"Pricing","body":"Attached."}}"#)
        let sendCase = "ask the local model send marcus the pricing sheet by email"

        // 1. The ceiling. The model asks for a send; nothing above a read may run.
        let refused = await run(sendCase, script: [send, "I can look things up for you here."])
        check("the on-device turn ran \(refused.tools) above its read ceiling, expected none",
              refused.tools.isEmpty)
        check("the refused write was named to the person: \"\(refused.reply)\"",
              !refused.reply.lowercased().contains("send_email"))
        check("the refusal was not a dead end (\(refused.rounds) model call(s))",
              refused.rounds >= 2)
        check("the on-device turn answered nothing at all: \"\(refused.reply)\"",
              !refused.reply.isEmpty)

        // 2. The control. The same call, on an ordinary turn, does run — so row 1 is the
        //    ceiling and not a script that could never have worked.
        let ordinary = await run(
            "send marcus the pricing sheet by email", script: [send, "Sent to Marcus."])
        check("the control turn did not run the write (\(ordinary.tools))",
              ordinary.tools == ["send_email"])

        // 3. A read on the same route still runs, so the ceiling is not a wall.
        let read = await run("ask the local model what is on my calendar today", script: [
            hermes(#"{"name":"get_agenda","arguments":{}}"#),
            "You have a standup at 9:30.",
        ])
        check("the on-device route could not read: \(read.tools)", read.tools == ["get_agenda"])
        check("the on-device read was thrown away: \"\(read.reply)\"",
              read.reply.contains("standup"))
        return failures
    }

    /// P1-11's cases. A reply may not claim a tool ran when none did (G N5), and the history
    /// a model is shown carries no claim to copy.
    ///
    /// Written before the guard. Cases a, b, d and every positive row of e fail on the
    /// unmodified loop, because the loop had nowhere to look: `completedToolIDs` was kept and
    /// never consulted on the way out, and "Earlier Agent conversation" carried an earlier
    /// turn's fabricated sentence verbatim.
    ///
    /// Case c and the zero rows of e are the other half of the task and are the reason this
    /// can ship: a claim the turn's own call backs passes through untouched, and an honest
    /// negative — the answer a person gets when a search really did match nothing — is not a
    /// claim and is never replaced by `honestReply`.
    @MainActor
    static func runClaimGuardCases(
        agent: RealtimeAgent, check: (String, Bool) -> Void
    ) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name) }

        /// One scripted plan: the provider's script, the calls the executor answered, and the
        /// exact user message of every round. The last of those is what carries the re-plan
        /// note, and what must not carry a stale claim.
        struct Case {
            let reply: String
            let tools: [String]
            let users: [String]
        }

        @MainActor
        func run(
            request: String, script: [String],
            seeding: [(user: String, assistant: String)] = []
        ) async -> Case {
            let log = PlannerScriptLog()
            let ran = ScriptedToolLog()
            AgentToolExecutor.fakeForTesting = { tool, _ in
                ran.record(tool.id)
                return AgentToolResult(summary: "Design sync, Dentist")
            }
            agent.localModelProviderForTesting = PlannerScriptProvider(
                id: .localServer, window: 4_096, promptTokens: 2_000, script: script, log: log)
            agent.setTypedPendingForTesting(nil)
            agent.budgetForTesting = nil
            AgentSession.shared.forgetAllConversations()
            // Seeded after the clear, because that is the state a stale claim would arrive in.
            for turn in seeding {
                AgentSession.shared.recordUser(turn.user, source: .text)
                AgentSession.shared.recordAssistant(turn.assistant)
            }
            let turn = await agent.handle(request, source: .text)
            AgentToolExecutor.fakeForTesting = nil
            return Case(reply: turn.reply, tools: ran.toolIDs, users: log.calls.map(\.user))
        }

        let hermes: (String) -> String = { "<tool_call>\($0)</tool_call>" }
        let agenda = hermes(#"{"name":"get_agenda","arguments":{}}"#)
        let calendar = "what's on my calendar today?"
        // G turn A7, word for word: the sentence reached a typed person on 2026-09-23.
        let invented = "I ran the get_agenda tool. Your main calendar for today shows no booked events."

        // a. A claim with nothing behind it buys one re-plan, and the round after it runs the
        //    tool and answers from what it returned. The fabricated sentence is never delivered.
        do {
            let result = await run(
                request: calendar,
                script: [
                    invented,
                    agenda,
                    "You have a standup at 9:30 and a budget review at 2.",
                ])
            check("an unsupported claim made \(result.users.count) model call(s), expected 3 "
                + "(the claim, the re-plan, the answer)", result.users.count == 3)
            check("the re-plan round was not told that no tool ran",
                  result.users.count > 1 && result.users[1].contains(ToolClaimGuard.replanNote))
            check("the re-planned turn ran \(result.tools), expected the agenda read",
                  result.tools == ["get_agenda"])
            check("the fabricated answer reached the user: \"\(result.reply)\"",
                  !result.reply.contains("no booked events"))
            check("the re-planned turn did not answer from what the tool returned: "
                + "\"\(result.reply)\"", result.reply.contains("standup at 9:30"))
        }

        // b. A second claim is the end of the turn, and the honest sentence replaces it whole.
        do {
            let result = await run(request: calendar, script: [invented, invented, invented])
            check("a second unsupported claim did not end on the honest sentence: "
                + "\"\(result.reply)\"", result.reply.contains(ToolClaimGuard.honestReply))
            check("the second-strike reply kept the fabricated tool name: \"\(result.reply)\"",
                  !result.reply.contains("get_agenda"))
            check("the second-strike reply kept the fabricated answer: \"\(result.reply)\"",
                  !result.reply.contains("no booked events"))
            check("a claim re-planned \(result.users.count) time(s), expected exactly 2",
                  result.users.count == 2)
            check("the second strike ran a tool: \(result.tools)", result.tools.isEmpty)
        }

        // c. A claim the turn's own call backs is not touched. This is the row that keeps the
        //    guard from being a refusal machine.
        do {
            let result = await run(
                request: calendar,
                script: [agenda, "I checked your calendar: standup at 9:30."])
            check("a claim backed by the call that ran was rewritten: \"\(result.reply)\"",
                  result.reply.contains("I checked your calendar: standup at 9:30."))
            check("a backed claim was replaced by the honest sentence: \"\(result.reply)\"",
                  !result.reply.contains(ToolClaimGuard.honestReply))
            check("a backed claim cost an extra round: \(result.users.count)",
                  result.users.count == 2)
        }

        // d. The history a model is shown carries no claim, and the store does. The seeded
        //    sentence is G turn A1: an earlier turn's own fabrication, which is what four of
        //    the nine Apple FM turns copied.
        let stale = "I've searched Desktop, Documents, and Downloads — 7,831 files — "
            + "using filesystem.find. No exact match for \u{201C}Indian direct\u{201D}."
        do {
            let result = await run(
                request: "what was my last request?",
                script: ["You asked me to look for Indian direct."],
                seeding: [(user: "find indian direct", assistant: stale)])
            let first = result.users.first ?? ""
            check("the planner's prompt still carried the stale claim: \"\(first)\"",
                  !first.contains("filesystem.find") && !first.contains("7,831 files"))
            check("the planner's prompt lost what the person actually asked",
                  first.contains("find indian direct"))
            check("the scrub edited the stored conversation",
                  AgentSession.shared.messages.contains { $0.text == stale })
            // The voice first pass reads the other view, so both are pinned: the scrub on, and
            // the same function's default off for every other caller.
            let scrubbed = AgentSession.shared.chatHistoryForCurrentTurn(
                maxCharacters: 2_500, scrubToolClaims: true)
            check("the first pass's history view kept the stale claim",
                  !scrubbed.contains { $0.content.contains("7,831 files") }
                      && !scrubbed.contains { $0.content.contains("filesystem.find") })
            check("the first pass's history view dropped the user's own words",
                  !scrubbed.isEmpty)
            let raw = AgentSession.shared.chatHistoryForCurrentTurn(maxCharacters: 2_500)
            check("scrubbing is not the default for every caller of the history view",
                  raw.contains { $0.content.contains("7,831 files") })
            let context = AgentSession.shared.contextForCurrentTurn(
                maxCharacters: 6_000, scrubToolClaims: true)
            check("the string context view kept the stale claim",
                  !context.contains("7,831 files") && context.contains("find indian direct"))
        }

        // e. The table, pure: no provider, no executor, no turn. The last column is the number
        //    of *unsupported* claims, which is the only number that ends a turn.
        let roster: Set<String> = [
            "get_agenda", "search_email", "computer.open_app", "filesystem.find",
        ]
        func unsupported(_ text: String, completed: [String] = []) -> Int {
            ToolClaimGuard.unsupported(
                ToolClaimGuard.claims(in: text, roster: roster), completed: completed).count
        }
        let table: [(String, [String], Int)] = [
            // The offer, the idiom, and the honest negative: none of them is a claim, and
            // none of them may be replaced by the honest sentence.
            ("I can check your calendar", [], 0),
            ("Ran into traffic?", [], 0),
            ("Shall I look at your calendar?", [], 0),
            ("No new emails found in the last few days.", [], 0),
            ("I couldn't find that in your inbox.", [], 0),
            ("Here is your day: standup at 9:30, budget review at 2.", [], 0),
            // A claim with nothing behind it, in each shape the guard reads. The G A7
            // sentence is two claims, not one: the verb and the tool it names.
            ("I checked your inbox", [], 1),
            ("I ran the get_agenda tool.", [], 2),
            ("7,831 files searched, no exact match.", [], 1),
            ("I found Pricing 2026.pdf in your Documents folder.", [], 1),
            // …and the same sentences with the call that backs them.
            ("Earlier I opened Safari", ["computer.open_app"], 0),
            ("I checked your calendar: standup at 9:30.", ["get_agenda"], 0),
            ("I found Pricing 2026.pdf in your Documents folder.", ["filesystem.find"], 0),
            // P1-04: the two sentences the live eval caught on Qwen3-4B, both of which had a
            // call in the turn and were still lies. The first is the worst thing this app can
            // say — the person reads it and believes an email went out.
            ("I’ll email it to Marcus now.\nSending…\n✅ Done: Email sent to Marcus",
             ["filesystem.search"], 1),
            ("I’ve set a nightly reminder at 10. It’s now active.",
             ["schedule.list"], 1),
            // A write claim with a write behind it is honest, and must survive: the whole
            // point is that the rule reads what ran, not that writes are always refused.
            ("I’ve set a nightly reminder at 10.", ["schedule.create"], 0),
            ("Sending… ✅ Done: Email sent to Marcus", ["workspace.send_email"], 0),
            // …and a read claim after a read is untouched, which is the rule this task kept.
            ("I found Pricing 2026.pdf in your Documents folder.", ["filesystem.search"], 0),
        ]
        for (text, completed, expected) in table {
            let got = unsupported(text, completed: completed)
            check("claims(\"\(text)\") with completed=[\(completed.joined(separator: ","))] is "
                + "\(got) unsupported, expected \(expected)", got == expected)
        }
        // A claim that names a tool says which one, so the audit row and the model can both
        // be specific about it.
        let named = ToolClaimGuard.claims(in: "Nothing matched, using filesystem.find.", roster: roster)
        check("a claim naming a tool did not record which (\(named))",
              named.contains { $0.toolID == "filesystem.find" })
        let unnamed = ToolClaimGuard.claims(in: "I looked through your files.", roster: roster)
        check("a first-person claim with no id invented one (\(unnamed))",
              unnamed.count == 1 && unnamed[0].toolID == nil)
        // The speech gate. Generous on purpose, like `AgentRefusalGuard.mayBeDenial`: a pause
        // costs nothing, "I ran —" being heard does.
        for (partial, expected) in [
            ("I ran", true), ("I checked yo", true), ("I have", true),
            ("I can check your calendar", false), ("Let me", false), ("", false),
        ] {
            check("mayBeClaim(\"\(partial)\") is \(ToolClaimGuard.mayBeClaim(partial)), "
                + "expected \(expected)", ToolClaimGuard.mayBeClaim(partial) == expected)
        }
        // The history scrub, sentence by sentence, on the G A1 text itself.
        let scrubbedHistory = ToolClaimGuard.scrubHistory(
            "Here is your day: standup at 9:30. I've searched Desktop, Documents, and Downloads "
                + "— 7,831 files — using filesystem.find. Nothing matched.", roster: roster)
        check("the history scrub kept \"\(scrubbedHistory)\"",
              scrubbedHistory == "Here is your day: standup at 9:30. Nothing matched.")
        check("the history scrub rewrote a clean sentence",
              ToolClaimGuard.scrubHistory("Nothing matched.", roster: roster) == "Nothing matched.")
        // And the one list both the guard and the live eval read.
        let names = ToolClaimGuard.registryNames
        check("the shared name list lost a registered id (\(names.count) names)",
              names.contains("get_agenda") && names.contains("filesystem.find")
                  && names.contains("files.find") && names.contains("workspace.search_email"))

        return failures
    }

    /// P1-04's cases. Split out because there are thirteen of them and they share one
    /// scripted-executor helper; `run()` owns the marker and the failure list.
    @MainActor
    static func runToleranceCases(
        agent: RealtimeAgent, check: (String, Bool) -> Void
    ) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name) }

        /// One scripted turn: a provider script, a fake executor, and the calls it made.
        struct Case {
            let reply: String
            let tools: [String]
            let users: [String]
        }

        @MainActor
        func run(
            request: String, script: [String],
            fake: @escaping @Sendable (AgentTool, [String: String], Int) async throws
                -> AgentToolResult = { _, _, _ in AgentToolResult(summary: "ok") }
        ) async -> Case {
            let log = PlannerScriptLog()
            let ran = ScriptedToolLog()
            let counter = CallCounter()
            AgentToolExecutor.fakeForTesting = { tool, arguments in
                let index = await counter.next()
                ran.record("\(tool.id)|\(arguments.keys.sorted().map { "\($0)=\(arguments[$0] ?? "")" }.joined(separator: ","))")
                return try await fake(tool, arguments, index)
            }
            agent.localModelProviderForTesting = PlannerScriptProvider(
                id: .localServer, window: 4_096, promptTokens: 2_000, script: script, log: log)
            agent.setTypedPendingForTesting(nil)
            agent.budgetForTesting = nil
            AgentSession.shared.forgetAllConversations()
            let turn = await agent.handle(request, source: .text)
            AgentToolExecutor.fakeForTesting = nil
            return Case(reply: turn.reply, tools: ran.toolIDs, users: log.calls.map(\.user))
        }

        let hermes: (String) -> String = { "<tool_call>\($0)</tool_call>" }

        // 1. `"parameters"` instead of `"arguments"`. The old parser read one key, so the
        //    call reached the executor with no name and ended the turn with
        //    "The tool computer.open_app did not run: …" — over the spelling of the key.
        do {
            let result = await run(
                request: "open Safari", script: [hermes(#"{"name":"computer.open_app","parameters":{"name":"Safari"}}"#)])
            check("a `parameters` call ran with empty arguments (P1-04 case 1)",
                  result.tools == ["computer.open_app|name=Safari"])
            check("a `parameters` call still ended with \"\(result.reply)\"",
                  !result.reply.contains("did not run"))
        }

        // 2. Qwen3-Coder XML, unwrapped.
        do {
            let result = await run(
                request: "search my inbox",
                script: [#"<function=search_email><parameter=query>in:inbox</parameter></function>"#])
            check("the Qwen3-Coder XML form did not execute (\(result.tools))",
                  result.tools == ["search_email|query=in:inbox"])
        }

        // 3. Attribute XML.
        do {
            let result = await run(
                request: "what is on my agenda",
                script: [#"<function name="get_agenda"><parameter name="date">2026-09-24</parameter></function>"#])
            check("the attribute XML form did not execute (\(result.tools))",
                  result.tools == ["get_agenda|date=2026-09-24"])
        }

        // 4. An alias for a canonical id. `workspace.search_email` is the alias the
        //    registry itself registers; `files.find` is the same mechanism and is pinned in
        //    the pure resolver checks below, because the indexed-folder tools are
        //    `needsSetup` under the harness (its index is an empty temporary store) and a
        //    turn cannot be given one.
        do {
            let result = await run(
                request: "search my inbox for the pricing sheet",
                script: [hermes(#"{"name":"workspace.search_email","arguments":{"query":"pricing"}}"#)])
            check("a registered alias did not run its canonical id (\(result.tools))",
                  result.tools == ["search_email|query=pricing"])
        }

        // 5. A near miss. `get_calender` is four edits from `get_agenda` and one edit from
        //    "calendar", which is what the model meant and what the manifest calls it.
        do {
            let result = await run(
                request: "what is on my calendar",
                script: [hermes(#"{"name":"get_calender","arguments":{}}"#)])
            check("the near miss get_calender did not run get_agenda (\(result.tools))",
                  result.tools.contains { $0.hasPrefix("get_agenda|") })
        }

        // 6. An unknown name is a repair, not the end of the plan.
        do {
            let result = await run(
                request: "what is on my agenda",
                script: [
                    hermes(#"{"name":"launch_rocket","arguments":{}}"#),
                    hermes(#"{"name":"get_agenda","arguments":{}}"#),
                    "You have two things today.",
                ])
            let repair = result.users.last { $0.contains("ERROR unknown_tool") } ?? ""
            check("an unknown tool produced no repair round (users \(result.users.count))",
                  !repair.isEmpty)
            check("the unknown-tool repair named no valid option", repair.contains("Valid options:"))
            check("the unknown-tool repair did not reach the corrected call (\(result.tools))",
                  result.tools.contains { $0.hasPrefix("get_agenda|") })
            check("the unknown-tool turn ended with \"\(result.reply)\"",
                  !result.reply.contains("unavailable tool"))
        }

        // 7. A recoverable failure the model can fix: a missing app with near names.
        do {
            let result = await run(
                request: "open Claude",
                script: [
                    hermes(#"{"name":"computer.open_app","arguments":{"name":"Claude Code"}}"#),
                    hermes(#"{"name":"computer.open_app","arguments":{"name":"Claude"}}"#),
                    "Opened Claude.",
                ],
                fake: { tool, _, index in
                    if index == 0 {
                        throw AgentError.notFound(
                            "No app called \u{201c}Claude Code\u{201d} is installed. "
                            + "Apps with a similar name: Claude, ChatGPT.")
                    }
                    return AgentToolResult(summary: "Opened \(tool.id).")
                })
            let repair = result.users.last { $0.contains("ERROR not_found") } ?? ""
            check("a missing app produced no not_found repair", !repair.isEmpty)
            check("the not_found repair hid the near names from the model",
                  repair.contains("ChatGPT"))
            check("the not_found turn never opened the app (\(result.tools))",
                  result.tools == ["computer.open_app|name=Claude Code",
                                   "computer.open_app|name=Claude"])
            check("the repaired turn answered \"\(result.reply)\"", result.reply.contains("Claude"))
        }

        // 8. A call cut off mid-object. The model is told, and its second attempt runs.
        do {
            let truncated = #"<tool_call>{"name":"draft_email","arguments":{"to":"a@b.com","body":"the deck goes out Friday, "#
            let result = await run(
                request: "draft an email to a@b.com about the deck",
                script: [
                    truncated,
                    hermes(#"{"name":"draft_email","arguments":{"to":"a@b.com","body":"the deck goes out Friday"}}"#),
                    "The draft is ready for your approval.",
                ])
            let repair = result.users.last { $0.contains("ERROR truncated_call") } ?? ""
            check("a truncated call produced no truncated_call repair", !repair.isEmpty)
            check("the truncated turn ran \(result.tools.count) call(s) instead of the whole second attempt (\(result.tools))",
                  result.tools.count == 1 && result.tools[0].contains("to=a@b.com")
                    && !result.tools[0].hasSuffix("Friday,"))
            check("the truncated turn ended with \"\(result.reply)\"",
                  !result.reply.contains("invalid tool request"))
        }

        // 9. A denial ends the turn. The model is never asked to try again: an optimistic
        //    rewrite of a refused write is the danger the original rule names.
        do {
            let result = await run(
                request: "send the deck to Marcus",
                script: [
                    hermes(#"{"name":"send_email","arguments":{"to":"m@example.com","subject":"Deck","body":"Attached"}}"#),
                    "There is nothing more to add.",
                ],
                fake: { _, _, _ in throw AgentError.permissionDenied("You declined.") })
            check("a denial did not end the turn with its own sentence: \"\(result.reply)\"",
                  result.reply.contains("You declined."))
            check("a denial was handed back to the model for another round",
                  result.users.count == 1)
        }

        // 10. The repair cap. Two repairs per turn, then a plain sentence.
        do {
            let result = await run(
                request: "what is on my agenda",
                script: Array(repeating: hermes(#"{"name":"launch_rocket","arguments":{}}"#), count: 5))
            check("the repair cap let \(result.users.filter { $0.contains("ERROR unknown_tool") }.count) repair rounds through, expected 2",
                  result.users.filter { $0.contains("ERROR unknown_tool") }.count == 2)
            check("the repair cap called the model \(result.users.count) time(s), expected 3",
                  result.users.count == 3)
            check("the repair cap did not end in a plain sentence: \"\(result.reply)\"",
                  !result.reply.isEmpty && !result.reply.contains("unavailable tool"))
        }

        // 11. The parser table. No model, no executor, no turn.
        // The roster the parser is given, and it is a roster: `launch_rocket` is deliberately
        // absent, which is what makes the last row a repair rather than a call.
        let known: Set<String> = [
            "get_agenda", "search_email", "schedule.create", "draft_email", "meeting.decisions",
            "files.find", "filesystem.find", "computer.open_app",
        ]
        let rows: [(String, String, Int, Int)] = [
            // input, expected call names (joined), expected calls, expected malformed
            ("I would send an email.", "", 0, 0),
            (#"<think>Let me check.</think><tool_call>{"name":"get_agenda","arguments":{}}</tool_call>"#,
             "get_agenda", 1, 0),
            (#"<think>still thinking {"name":"get_agenda""#, "", 0, 0),
            // The measured leak: one closing brace too many, then the model's own reasoning.
            (hermes(#"{"name":"meeting.decisions","arguments":{}}},"rationale":"The user is asking."}"#),
             "meeting.decisions", 1, 0),
            (hermes("{\"name\":\"search_email\",\"arguments\":{\"query\":\"x\"}}，“rationale”:“because.”}"),
             "search_email", 1, 0),
            (#"{"name":"schedule.create","arguments":{"text":"book"},"rationale":"nightly"},"rationale":"why"}"#,
             "schedule.create", 1, 0),
            (hermes(#"{"name":"get_agenda","arguments":{},"rationale":"ok",}"#), "get_agenda", 1, 0),
            (#"<function=search_email><parameter=query>in:inbox</parameter></function>"#,
             "search_email", 1, 0),
            (#"<function name="get_agenda"><parameter name="date">2026-09-24</parameter></function>"#,
             "get_agenda", 1, 0),
            (hermes(#"<function name="get_agenda"><param name="date">2026-09-24</param></function>"#),
             "get_agenda", 1, 0),
            (#"[TOOL_CALLS][{"name":"get_agenda","arguments":{}}]"#, "get_agenda", 1, 0),
            (#"<|python_tag|>{"name":"get_agenda","arguments":{}}"#, "get_agenda", 1, 0),
            (##"{"type":"function","function":{"name":"get_agenda","arguments":"{}"}}"##,
             "get_agenda", 1, 0),
            (#"{"tool":"get_agenda","args":{}}"#, "get_agenda", 1, 0),
            (hermes(#"{"name":"draft_email","arguments":{"to":"a@b.com","body":"x"#), "", 0, 1),
            // The ceiling: a tail that is a second object is ambiguous, so it is refused.
            (hermes(#"{"name":"get_agenda","arguments":{}},"rationale":"x","more":{"a":1}}"#), "", 0, 1),
            // Braces in an explanation are not a call, and they are not an answer either.
            (#"Sure. {"name": "x"} is not a call here."#, "", 0, 1),
            // A marked call is a call: the name is not in this turn's roster, and the
            // resolver is what turns that into a repair with the options.
            (hermes(#"{"name":"launch_rocket","arguments":{}}"#), "launch_rocket", 1, 0),
            // The same name with no marker is not a call at all, because braces in an
            // explanation are not a request to run anything.
            (#"{"name":"launch_rocket","arguments":{}}"#, "", 0, 1),
        ]
        for (index, row) in rows.enumerated() {
            let parsed = AgentToolCallParser.parse(row.0, knownNames: known)
            let names = parsed.calls.map(\.name).joined(separator: ",")
            check("parser row \(index + 1) read [\(names)] (\(parsed.calls.count) call(s), "
                + "\(parsed.malformed.count) malformed), expected [\(row.1)] (\(row.2)/\(row.3))",
                  names == row.1 && parsed.calls.count == row.2 && parsed.malformed.count == row.3)
        }
        // Prose is what is left once every call is removed, and it is the whole completion
        // when there was no call at all.
        let withProse = AgentToolCallParser.parse(
            "I checked.\n" + hermes(#"{"name":"get_agenda","arguments":{}}"#) + "\nThat is today.",
            knownNames: known)
        check("the parser kept the prose around a call: \"\(withProse.prose)\"",
              withProse.prose == "I checked.\n\nThat is today.")
        // The legacy entry point still refuses prose, which `--selftest-agent` and the
        // meeting callers depend on.
        check("`calls(in:)` read prose as a call",
              AgentToolCallParser.calls(in: "I would send an email.").isEmpty)

        // 12. Relative dates come from the clock, not from the model's training data.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let knownDay = utc.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        let tomorrow = AgentToolLoop.groundedArguments(
            for: "get_agenda", proposed: ["date": "2023-10-27"],
            request: "What do I have tomorrow?", now: knownDay, calendar: utc)
        check("a stale proposed date survived \"tomorrow\" (\(tomorrow["date"] ?? "-"))",
              tomorrow["date"] == "2026-09-15")
        let weekday = AgentToolLoop.groundedArguments(
            for: "get_agenda", proposed: [:], request: "what is on tuesday",
            now: knownDay, calendar: utc)
        check("\"on tuesday\" was not grounded to the next Tuesday (\(weekday["date"] ?? "-"))",
              weekday["date"] == "2026-09-15")
        let sameDay = AgentToolLoop.groundedArguments(
            for: "get_agenda", proposed: [:], request: "what is on monday",
            now: knownDay, calendar: utc)
        check("\"on monday\" said on a Monday was not today (\(sameDay["date"] ?? "-"))",
              sameDay["date"] == "2026-09-14")
        let twoDays = AgentToolLoop.groundedArguments(
            for: "get_agenda", proposed: ["date": "2023-10-27"],
            request: "today and tomorrow", now: knownDay, calendar: utc)
        check("a request naming two relative days was grounded anyway (\(twoDays["date"] ?? "-"))",
              twoDays["date"] == "2023-10-27")

        // 12b. P1-14: a mail filter is searched for only when the user said it. Every row is
        //      one of the four queries the 2026-09-26 gate run actually sent, or the request
        //      that produced it, so this pins the measurement rather than a fitted example.
        let mail = { (query: String, request: String) in
            AgentToolLoop.groundedArguments(
                for: "search_email", proposed: ["query": query], request: request)
        }
        for invented in ["recent", "subject:.*", "subject:'ProductFlo'", "subject:'summary' OR 'follow up'"] {
            let grounded = mail(invented, "Summarize my last 5 emails")
            check("a filter the user never said survived grounding: \(invented) -> "
                  + "\(grounded["query"] ?? "(dropped)")", grounded["query"] == nil)
        }
        // The two the user *did* say, and the one the case M02 is graded on.
        check("a sender the user named was dropped (\(mail("from:Marcus", "Any new emails from Marcus?")["query"] ?? "-"))",
              mail("from:Marcus", "Any new emails from Marcus?")["query"] == "from:Marcus")
        check("a subject the user described in their own words was dropped "
              + "(\(mail("subject:dentist", "find my email about the dentist")["query"] ?? "-"))",
              mail("subject:dentist", "find my email about the dentist")["query"] == "subject:dentist")
        check("an unread flag the user asked for was dropped (\(mail("is:unread", "any unread emails?")["query"] ?? "-"))",
              mail("is:unread", "any unread emails?")["query"] == "is:unread")
        // Partly asked for: the clause that was not said goes, the clause that was stays.
        let narrowed = mail("from:priya OR from:ana", "anything from Priya?")["query"] ?? "-"
        check("a partly-asked-for filter was not narrowed to the part that was asked for (\(narrowed))",
              narrowed == "from:priya")
        // A time span the user named keeps its operator; one they did not does not.
        check("a date filter the user asked for was dropped (\(mail("newer_than:2d", "anything from the last two days")["query"] ?? "-"))",
              mail("newer_than:2d", "anything from the last two days")["query"] == "newer_than:2d")
        check("a date filter the user never mentioned was kept (\(mail("newer_than:2d", "summarize my mail")["query"] ?? "-"))",
              mail("newer_than:2d", "summarize my mail")["query"] == nil)
        // Already empty, and another tool entirely, are both left exactly as they were.
        check("an empty query was rewritten",
              AgentToolLoop.groundedArguments(
                for: "search_email", proposed: ["maxResults": "5"], request: "summarize my mail")
                == ["maxResults": "5"])
        check("another tool's arguments were touched",
              AgentToolLoop.groundedArguments(
                for: "draft_email", proposed: ["to": "recent@example.com"],
                request: "draft an email to recent@example.com")
                == ["to": "recent@example.com"])

        // 12c. P1-14: the documented miss of a read is recoverable, and only once.
        let miss = ReadMissRecovery.repair(
            toolID: "search_email", arguments: ["query": "recent"],
            result: "No message matches recent.")
        check("a mail miss was not repaired (\(miss?.kind.rawValue ?? "-"))",
              miss?.kind == .badQuery)
        check("the miss repair did not say which query to use instead",
              miss?.message.contains("latest mail") == true)
        check("the miss repair does not tell a specific search to broaden",
              miss?.message.contains("Only if the user really asked about one specific sender") == true)
        check("a search that already had no filter was told to try itself",
              ReadMissRecovery.repair(
                toolID: "search_email", arguments: ["maxResults": "5"],
                result: "No message matches in:inbox.") == nil)
        check("a miss on another tool was repaired as mail",
              ReadMissRecovery.repair(
                toolID: "get_agenda", arguments: [:],
                result: "No message matches nothing.") == nil)
        check("a mail answer that is not a miss was repaired",
              ReadMissRecovery.repair(
                toolID: "search_email", arguments: ["query": "from:marcus"],
                result: "1) 2026-09-26 · Marcus Lee · Pricing sheet v3") == nil)
        // P1-11's repair text, unchanged: a variant that opened by naming its authority was
        // measured and removed (see `ToolRepair.modelText`), and this pins that the plain
        // sentence is the one that ships.
        check("a repair no longer opens with an authority clause",
              ToolRepair(kind: .badQuery, message: "x").modelText == "ERROR bad_query: x "
                + "Correct the call and try again, or answer the user with what you already have.")

        // 13. A repeated call is a question, not a loop: the note points at the result the
        //     model already has and the turn goes on to answer.
        do {
            let result = await run(
                request: "what is on my agenda",
                script: [
                    hermes(#"{"name":"get_agenda","arguments":{"date":"2026-09-24"}}"#),
                    hermes(#"{"name":"get_agenda","arguments":{"date":"2026-09-24"}}"#),
                    "You have two events tomorrow.",
                ],
                fake: { _, _, _ in AgentToolResult(summary: "Design sync, Dentist") })
            check("the repeated call ran \(result.tools.count) time(s), expected 1",
                  result.tools.count == 1)
            let note = result.users.last { $0.contains("You already ran get_agenda") } ?? ""
            check("the repeated call produced no \"already ran\" note", !note.isEmpty)
            check("the repeated turn answered \"\(result.reply)\"",
                  result.reply.contains("two events"))
            check("the repeated turn ended with \"\(result.reply)\"",
                  !result.reply.contains("repeated a completed step"))
        }

        // 13b. A second repeat ends the plan. P1-06 replaces the ending with a final
        //      answer-only round; before it lands, the plan stops and keeps what it verified.
        do {
            let result = await run(
                request: "what is on my agenda",
                script: Array(repeating: hermes(
                    #"{"name":"get_agenda","arguments":{"date":"2026-09-24"}}"#), count: 5),
                fake: { _, _, _ in AgentToolResult(summary: "Design sync, Dentist") })
            check("the second repeat ran the tool \(result.tools.count) time(s), expected 1",
                  result.tools.count == 1)
            check("the second repeat threw the verified result away: \"\(result.reply)\"",
                  result.reply.contains("Design sync"))
        }

        // The name resolver on its own, so a near miss that would have cost a whole plan is
        // pinned without a model round.
        let allowed = AgentCapabilityManifestBuilder.build(
            AgentCapabilityInputs.allEnabled(
                tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: .voiceFrontend),
            request: "what is on my calendar").allowed
        for (spelling, expected) in [
            ("get_agenda", "get_agenda"),
            ("files.find", "filesystem.find"),
            ("get_calender", "get_agenda"),
            ("search_emial", "search_email"),
        ] {
            let resolved = ToolCallNameResolver.resolve(spelling, allowed: allowed)
            check("\(spelling) resolved to \(resolved), expected \(expected)",
                  resolved == .tool(expected))
        }
        if case .unknown(let suggestions) = ToolCallNameResolver.resolve(
            "launch_rocket", allowed: allowed) {
            check("an unknown name offered no options to correct itself with (\(suggestions))",
                  suggestions.isEmpty == false)
        } else {
            fail("launch_rocket resolved to a tool")
        }

        return failures
    }
}

/// The index a scripted executor sees, so a case can fail its first attempt and succeed its
/// second. An actor because the fake is `@Sendable` and the loop is on the main actor.
private actor CallCounter {
    private var count = 0
    func next() -> Int {
        defer { count += 1 }
        return count
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
    /// P1-10b / J L8: answer every completion as one the model ran out of allowance on. Off by
    /// default, so every other case's provider behaves exactly as it did.
    var cutOffByLimit: Bool = false
    let log: PlannerScriptLog
    var contextTokens: Int { window }
    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { promptTokens }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = await next(system: system, user: user, maxTokens: maxTokens)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0,
                             finishedByLimit: cutOffByLimit)
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

/// P1-06's scripted planner. One canned completion per call, in order, and a per-call delay
/// so a case can spend exactly as long in each round as the budget under test allows. The
/// recorded `(system, user, maxTokens)` of every call is the evidence for what the final
/// answer-only round was sent and what it asked for.
private struct BudgetScriptProvider: LLMProvider {
    let id: LLMProviderID
    let window: Int
    let promptTokens: Int
    let script: [String]
    /// One entry per call, the last repeating for the calls after it. Empty spends no time.
    let delays: [Duration]
    let log: PlannerScriptLog
    var contextTokens: Int { window }
    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { promptTokens }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let index = log.calls.count
        // Recorded before the sleep, so a round the budget abandons is still on the record:
        // the call was made, the deadline is what ended it.
        log.record(.init(system: system, user: user, maxTokens: maxTokens))
        let delay = delays.isEmpty ? Duration.zero : delays[min(index, delays.count - 1)]
        if delay > .zero { try await Task.sleep(for: delay) }
        let text = index < script.count ? script[index] : "There is nothing more to add."
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let completion = try await complete(
                        system: system, user: user, maxTokens: maxTokens)
                    continuation.yield(completion.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
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

/// P1-10's fitter fixture: a scripted planner that counts characters honestly
/// (`characters / 4`) and reports a 4,096-token window, so the per-round fitter is measured
/// against a real estimate rather than a pinned one. The last script entry repeats.
private struct CountingScriptProvider: LLMProvider {
    let id = LLMProviderID.localServer
    let window: Int
    let script: [String]
    let log: PlannerScriptLog
    var contextTokens: Int { window }
    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { max(1, text.count / 4) }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let index = log.calls.count
        log.record(.init(system: system, user: user, maxTokens: maxTokens))
        let text = index < script.count ? script[index] : "There is nothing more to add."
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let completion = try await complete(
                        system: system, user: user, maxTokens: maxTokens)
                    continuation.yield(completion.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// P1-10's overflow fixture: a provider that refuses every pass the way llama.cpp does when
/// the prompt is longer than the model's context. Both shapes of turn are refused, so the
/// turn cannot pass by taking the header path.
private struct OverflowingScriptProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { max(1, text.count / 4) }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        throw LlamaError.inputTooLong
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: LlamaError.inputTooLong) }
    }

    func streamConversation(
        system: String, messages: [LLMChatMessage], maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: LlamaError.inputTooLong) }
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
