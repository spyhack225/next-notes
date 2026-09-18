import Foundation

/// `--selftest-persona`: the assembled prompt for every Agent path, with persona and memory
/// character counts against the plan's budgets. No model, no network, no microphone.
///
/// Production prompt accessors read `PersonaStore.shared`, which under a self-test is a
/// per-process temporary directory — the user's `persona.md` is never read or written.
@MainActor
enum PersonaSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: The store, in its own temporary directory.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-persona-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonaStore(directory: directory)
        check("store path escaped the temporary directory",
              store.fileURL.path.hasPrefix(directory.path))
        check("the shared store is not isolated under a self-test",
              !PersonaStore.shared.fileURL.path.hasPrefix(AppIdentity.applicationSupportDirectory.path))
        check("a fresh store was not seeded from the base preset", store.text() == PersonaStore.baseText)
        check("seeding did not write persona.md", FileManager.default.fileExists(atPath: store.fileURL.path))
        if let bundled = PersonaStore.bundledBaseText {
            check("Resources/agent-persona-base.md and the compiled-in preset have drifted",
                  bundled == PersonaStore.builtInBaseText)
            print("PERSONA_BASE bundled resource present (\(bundled.count) chars)")
        } else {
            print("PERSONA_BASE no bundled resource; using compiled-in preset")
        }
        let baseCard = PersonaStore.shortCard(of: PersonaStore.baseText)
        check("the base preset's short card is not its first paragraph",
              baseCard.kept.hasPrefix("You are Next Notes") && baseCard.kept.hasSuffix("when asked for one.")
                && !baseCard.isTruncated)

        let edited = "You are Juniper. Call me Serge.\n\nSpeak warmly."
        do { try store.save(edited) } catch { failures.append("save failed: \(error)") }
        let reopened = PersonaStore(directory: directory)
        check("an edited persona was overwritten by seeding", reopened.text() == edited)
        check("short card is not the first paragraph", reopened.shortCard() == "You are Juniper. Call me Serge.")
        check("full persona lost its second paragraph", reopened.fullPersona().contains("Speak warmly."))
        do { try reopened.resetToBase() } catch { failures.append("reset failed: \(error)") }
        check("Reset to base did not restore the preset", reopened.text() == PersonaStore.baseText)

        let longFirst = String(repeating: "Brisk and exact. ", count: 40)   // 680 chars
        let longBody = String(repeating: "Detail about tone and names. ", count: 100)  // 2,900 chars
        let long = longFirst + "\n\n" + longBody
        do { try store.save(long) } catch { failures.append("long save failed: \(error)") }
        let full = PersonaStore.fullCard(of: store.text())
        let card = PersonaStore.shortCard(of: store.text())
        check("full cap exceeded (\(full.kept.count))", full.kept.count <= PersonaStore.fullLimit && full.isTruncated)
        check("short-card cap exceeded (\(card.kept.count))",
              card.kept.count <= PersonaStore.shortCardLimit && card.isTruncated)
        check("truncation touched the file", store.text() == long)
        check("short card crossed into the second paragraph", !card.kept.contains("Detail about tone"))

        let disabled = PersonaStore(directory: directory, isEnabled: { false })
        check("a disabled persona still reached a prompt",
              AgentPromptContext.assemble(.toolLoop, rules: "Rule.", personaStore: disabled).persona.isEmpty
                && disabled.shortCard().isEmpty)

        // MARK: Budgets, including memory, on a store with an over-long persona.
        let oversizedMemory = String(repeating: "m", count: 5_000)
        for path in AgentPromptPath.allCases {
            let context = AgentPromptContext.assemble(path, rules: "Fixed rule.", memory: oversizedMemory,
                                                      capabilities: "Tools: none.", personaStore: store)
            let budget = path.budget
            check("\(path.rawValue) persona over budget (\(context.personaCharacters)/\(budget.personaLimit))",
                  context.personaCharacters <= budget.personaLimit)
            check("\(path.rawValue) memory over budget (\(context.memoryCharacters)/\(budget.memoryLimit))",
                  context.memoryCharacters <= budget.memoryLimit)
            switch budget.persona {
            case .none:
                check("\(path.rawValue) carries a persona", context.persona.isEmpty)
            case .shortCard:
                check("\(path.rawValue) is not the short card", context.persona == card.kept)
            case .full:
                check("\(path.rawValue) is not the full persona", context.persona == full.kept)
            }
            if path == .acpAgent {
                check("ACP agents receive prompt text", context.system.isEmpty)
            } else {
                check("\(path.rawValue) rules do not end with the override line",
                      context.rules.hasSuffix(AgentPromptContext.overrideLine))
                check("\(path.rawValue) sections are out of order", inOrder(context))
            }
        }

        // MARK: Every production path, through its real accessor.
        try? PersonaStore.shared.save(PersonaStore.baseText + "\nCall the user Serge. Your name is Juniper.\n")
        let shared = PersonaStore.shared
        let sharedFull = shared.fullPersona()
        let sharedCard = shared.shortCard()
        check("shared store did not pick up the edit", sharedFull.contains("Juniper"))

        let tools = RealtimeAgent.plannableTools()
        let productionPaths: [(name: String, path: AgentPromptPath, system: String)] = [
            ("voice answer (Apple)", .voiceAnswer, LocalVoiceSplitResponse.answerInstructions),
            ("voice route (Apple)", .voiceRoute, LocalVoiceSplitResponse.routeInstructions),
            ("voice turn instructions (coordinator)", .voiceAnswer, VoiceConversationCoordinator.systemPrompt),
            ("tool loop first pass, voice", .toolLoop, RealtimeAgent.voiceRoutingSystem(voice: true)),
            ("tool loop first pass, typed", .toolLoop, RealtimeAgent.voiceRoutingSystem(voice: false)),
            ("model turn, voice", .toolLoop, RealtimeAgent.modelTurnSystem(voice: true)),
            ("tool planner, voice", .toolLoop, RealtimeAgent.plannerSystem(tools: tools, voice: true)),
            ("tool planner, typed", .toolLoop, RealtimeAgent.plannerSystem(tools: tools, voice: false)),
            ("ask the local model", .localModel, RealtimeAgent.localModelSystem),
            ("meeting assistant", .meetingAssistant, AgentPrompts.system),
            ("knowledge ask", .knowledgeAsk, KnowledgeAsker.systemPrompt),
        ]
        for entry in productionPaths {
            let budget = entry.path.budget
            let expected = switch budget.persona {
            case .none: ""
            case .shortCard: sharedCard
            case .full: sharedFull
            }
            let personaCount = expected.count
            print("""
                PERSONA_PATH \(entry.name) [\(entry.path.rawValue)] \
                persona=\(personaCount)/\(budget.personaLimit) (\(budget.persona.rawValue)) \
                memory=0/\(budget.memoryLimit) (\(budget.memoryScope)) system=\(entry.system.count) chars
                ----
                \(entry.system)
                ----
                """)
            check("\(entry.name) persona over budget", personaCount <= budget.personaLimit)
            switch budget.persona {
            case .none:
                check("\(entry.name) carries the persona", !entry.system.contains("Juniper")
                      && !entry.system.contains(sharedCard))
            case .shortCard:
                check("\(entry.name) does not start with the short card", entry.system.hasPrefix(sharedCard))
                check("\(entry.name) carries more than the short card",
                      !entry.system.contains("Keep spoken replies") && !entry.system.contains("Juniper"))
            case .full:
                check("\(entry.name) does not start with the full persona", entry.system.hasPrefix(sharedFull))
            }
            if let personaEnd = expected.isEmpty ? entry.system.startIndex : entry.system.range(of: expected)?.upperBound,
               let override = entry.system.range(of: AgentPromptContext.overrideLine) {
                check("\(entry.name) rules precede the persona", personaEnd <= override.lowerBound)
            } else {
                check("\(entry.name) has no override line", false)
            }
        }
        check("the planner's tool inventory is not after the rules",
              isAfterOverride(RealtimeAgent.plannerSystem(tools: tools, voice: false), "Available tools:"))

        // The trap: the coordinator's instructions must be what the split answer stage hears.
        check("VoiceConversationCoordinator.systemPrompt is not the production answer prompt",
              VoiceConversationCoordinator.systemPrompt == LocalVoiceSplitResponse.answerInstructions)
        let facts = LLMChatMessage(role: .system, content: "Application facts: fixture.")
        let plan = LocalVoiceSplitResponse.answerPlan(
            system: VoiceConversationCoordinator.systemPrompt,
            messages: [facts, .init(role: .user, content: "Hello?")])
        check("the split answer plan ignores the coordinator's instructions",
              plan?.instructions.hasPrefix(sharedCard) == true
                && plan?.instructions.hasSuffix("Application facts: fixture.") == true)
        let route = LocalVoiceSplitResponse.routePlan(messages: [facts, .init(role: .user, content: "Hello?")])
        check("the route plan carries the persona or facts",
              route.map { !$0.instructions.contains(sharedCard) && !$0.instructions.contains("fixture") } == true)

        try? FileManager.default.removeItem(at: PersonaStore.shared.fileURL.deletingLastPathComponent())
        for failure in failures { print("PERSONA_WRONG: \(failure)") }
        print(failures.isEmpty ? "PERSONA_OK" : "PERSONA_FAILED")
        return failures.isEmpty
    }

    private static func inOrder(_ context: AgentPromptContext) -> Bool {
        let system = context.system
        var cursor = system.startIndex
        for section in [context.persona, context.rules, context.memory, context.capabilities] where !section.isEmpty {
            guard let range = system.range(of: section, range: cursor..<system.endIndex) else { return false }
            cursor = range.upperBound
        }
        return true
    }

    private static func isAfterOverride(_ system: String, _ marker: String) -> Bool {
        guard let override = system.range(of: AgentPromptContext.overrideLine),
              let found = system.range(of: marker) else { return false }
        return override.upperBound <= found.lowerBound
    }
}
