import Foundation

/// The one manifest, checked.
///
/// No model, no network, no account, no grant: every case builds its manifests from fixture
/// `AgentCapabilityInputs`, so the whole run is the roster's own arithmetic. That is the point
/// — the four disagreements this type closes were all disagreements between a list and a
/// prompt, and both are reachable without running anything.
///
/// The cases that must fail without the fix are 2, 3, 4, 5 and 7:
/// - 2 fails while a rule line names a tool the schema dropped, which is what happened on
///   2026-09-20 to the file tools and again to the memory rule;
/// - 3 fails under keyword top-k, which keeps nine core tools and a ranked tail rather than
///   whole classes;
/// - 4 is the D8 set — "to-do", "what did we decide", "Sarah said" reach nothing today,
///   because no tool's name or description contains those words;
/// - 5 is the connected-app half: an MCP tool registered today is never in any allowlist;
/// - 7 is T9: "I don't have enough information to set that reminder" is an honest limit and
///   the substring match reads it as a denial.
enum AgentCapabilityManifestSelfTest {
    @MainActor
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        func wrong(_ name: String) { failures.append(name) }

        let registry = AgentToolRegistry.shared
        let allTools = registry.tools(upTo: .privileged)
        SelfTest.diagnostic("CAPABILITY_MANIFEST_CATALOGUE: \(allTools.count) registered, "
            + "\(registry.tools(upTo: .send).count) at or below .send")

        // One reader per case where the window matters. 8,192 is what a local GGUF reports and
        // the parity case below; 4,096 is Apple's floor and the worst case the fit is for.
        let local = AgentCapabilityManifest.Reader(
            provider: .appLLM, displayName: "Fixture", contextTokens: 8_192)
        let apple = AgentCapabilityManifest.Reader(
            provider: .appleFoundation, displayName: "Apple", contextTokens: 4_096)
        let cloud = AgentCapabilityManifest.Reader(
            provider: .openRouter, displayName: "Cloud", contextTokens: 32_768)

        // MARK: 1 — Parity with the roster the tree had before this task
        //
        // The old hard-coded planner allowlist, written down so a change to the
        // catalogue or to `nativePlannerExclusions` cannot quietly change what the planner may
        // do. Widening is a decision graded by `--selftest-toolloop-live`, not something this
        // type may do by being edited.
        //
        // The P1-03 brief calls this 63. It is 64: the old list has 64 ids, and
        // `filesystem.find` / `filesystem.tree` are two of them. Verified by diffing this set
        // against the source before it was deleted, and pinned at 64 so the count is itself
        // the assertion. P1-09 added `read_email` — a read, one call from the registry, and
        // the first Workspace tool in this list that is a *new* capability rather than one
        // that had been reachable all along — so the pin is 65.
        let parity = AgentCapabilityManifestBuilder.build(
            .allEnabled(tools: allTools, reader: local), request: "what's on my calendar")
        let expectedParity: Set<String> = [
            "get_agenda", "search_email", "read_email", "find_drive_files", "read_doc", "create_doc",
            "append_doc", "upload_to_drive", "create_event", "draft_email", "send_email",
            "reply_email",
            "meeting.current", "meeting.transcript", "meeting.recent_context",
            "meeting.participants", "meeting.action_items", "meeting.decisions", "meeting.search",
            "computer.active_app", "computer.windows", "computer.inspect_ui",
            "computer.get_selection", "computer.clipboard", "computer.open_app",
            "computer.open_url", "computer.focus", "computer.click", "computer.press_key",
            "computer.set_text", "computer.type", "computer.screenshot",
            "browser.snapshot", "browser.navigate", "browser.click", "browser.fill",
            "browser.select", "browser.screenshot",
            "filesystem.search", "filesystem.read", "filesystem.write", "filesystem.move",
            "filesystem.copy", "filesystem.reveal", "shell.run",
            FileToolCatalogue.findID, FileToolCatalogue.treeID,
            "memory.remember", "memory.update", "memory.forget", "memory.recall",
            "schedule.list", "schedule.create", "schedule.update", "schedule.pause",
            "schedule.resume", "schedule.remove", "schedule.run_now",
            "search_knowledge", "expand_node", "timeline", "assemble",
            "skills.search", "skills.read", "skills.install",
        ]
        check("parity: the expected set is not the 65 ids it claims to pin", expectedParity.count == 65)
        let parityIDs = parity.allowedIDs
        if parityIDs != expectedParity {
            wrong("parity: allowed ids differ from the 65 pinned "
                + "(missing \(expectedParity.subtracting(parityIDs).sorted().joined(separator: ", ")); "
                + "extra \(parityIDs.subtracting(expectedParity).sorted().joined(separator: ", ")))")
        }
        for id in AgentCapabilityManifestBuilder.nativePlannerExclusions {
            check("parity: \(id) is excluded but is not registered, so the set is guessing",
                  registry.tool(named: id) != nil)
        }
        SelfTest.diagnostic("CAPABILITY_MANIFEST_PARITY: \(parityIDs.count) allowed")

        // MARK: 2 — No id in a prompt unless the schema has it
        //
        // The whole defect, in one scan. Every id and alias the registry knows is looked for
        // in the assembled planner prompt, word-bounded, and each hit must be in this turn's
        // `selected`. A rule line naming a dropped tool is a hit and fails.
        let requests = [
            "what's on my calendar",
            "summarise my last 5 emails",
            "what's on my to-do list",
            "what did we decide last meeting",
            "Sarah said the budget is ten percent",
            "remember my brother is Cyril",
            "find the pricing doc",
            "open youtube",
            "hi",
            "search linear issues",
            "install a skill for PDFs",
            "every night at 10 remind me to stretch",
        ]
        var scanNames: [(name: String, pattern: NSRegularExpression)] = []
        for tool in allTools {
            for name in [tool.id] + Self.aliasSpellings(of: tool, registry: registry) {
                guard let regex = try? NSRegularExpression(
                    pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b") else { continue }
                scanNames.append((name, regex))
            }
        }
        SelfTest.diagnostic("CAPABILITY_MANIFEST_SCAN: \(scanNames.count) id and alias spellings")
        for request in requests {
            let manifest = AgentCapabilityManifestBuilder.build(
                .allEnabled(tools: allTools, reader: local), request: request)
            let system = RealtimeAgent.plannerSystem(manifest: manifest, voice: false, request: request)
            let unschemaed = scanNames.compactMap { candidate -> String? in
                let range = NSRange(system.startIndex..., in: system)
                guard candidate.pattern.firstMatch(in: system, range: range) != nil else { return nil }
                return manifest.entry(named: candidate.name) == nil
                    || !manifest.selectedIDs.contains(manifest.entry(named: candidate.name)!.id)
                    ? candidate.name : nil
            }
            if !unschemaed.isEmpty {
                wrong("prompt names tools its schema lacks for \"\(request)\": "
                    + unschemaed.sorted().joined(separator: ", "))
            }
            // And the schema is not empty for a request that named a class.
            if manifest.selected.isEmpty {
                wrong("no tool was selected for \"\(request)\"")
            }
        }

        // MARK: 3 — Whole classes, never a ranked tail
        for request in requests {
            let manifest = AgentCapabilityManifestBuilder.build(
                .allEnabled(tools: allTools, reader: local), request: request)
            let partial = manifest.allowed.filter {
                manifest.selectedIntents.contains($0.intent) && !manifest.selectedIDs.contains($0.id)
            }
            if !partial.isEmpty {
                wrong("a matched class was truncated for \"\(request)\": "
                    + partial.map(\.id).sorted().joined(separator: ", "))
            }
        }

        // MARK: 4 — The D8 misses
        for (request, expected) in [
            ("what's on my to-do list", AgentIntentClass.reminders),
            ("what did we decide last meeting", AgentIntentClass.meetings),
            ("Sarah said the budget is ten percent", AgentIntentClass.meetings),
            ("any new mail from Marcus?", AgentIntentClass.mail),
            ("what did we decide in the last meeting", AgentIntentClass.knowledge),
        ] {
            let manifest = AgentCapabilityManifestBuilder.build(
                .allEnabled(tools: allTools, reader: local), request: request)
            if !manifest.selectedIntents.contains(expected) {
                wrong("\"\(request)\" selected \(manifest.selectedIntents.map(\.rawValue).sorted().joined(separator: ", ")), not \(expected.rawValue)")
            }
        }
        // A greeting is the small-prompt case: core only, and every core id present.
        let smallTalk = AgentCapabilityManifestBuilder.build(
            .allEnabled(tools: allTools, reader: local), request: "hi")
        let smallTalkExtra = smallTalk.selected.map(\.id)
            .filter { !AgentCapabilityManifestBuilder.coreIDs.contains($0) }
        if !smallTalkExtra.isEmpty {
            wrong("\"hi\" selected \(smallTalkExtra.joined(separator: ", ")) beyond the core set")
        }
        for id in AgentCapabilityManifestBuilder.coreIDs
        where smallTalk.selectedIDs.contains(id) == false {
            wrong("\"hi\" dropped the core tool \(id)")
        }

        // MARK: 5 — Connected apps join by risk class, and never shadow a native one
        let fixtures = MCPFixtures()
        defer { fixtures.unregister() }
        for tool in fixtures.tools { registry.register(tool, aliases: tool.aliases) }
        let withMCP = AgentCapabilityManifestBuilder.build(
            .allEnabled(tools: registry.tools(upTo: .privileged), reader: local),
            request: "search linear issues")
        for id in ["mcp.linear.search_issues", "mcp.linear.create_issue"]
        where withMCP.allowedIDs.contains(id) == false {
            wrong("a connected-app tool at or below .send was refused: \(id)")
        }
        for id in ["mcp.linear.search_issues", "mcp.linear.create_issue"]
        where withMCP.selectedIDs.contains(id) == false {
            wrong("a connected-app tool was not selected for its own subject: \(id)")
        }
        check("a destructive connected-app tool entered the planner",
              withMCP.allowedIDs.contains("mcp.linear.delete_issue") == false)
        check("a connected-app tool shadowed a native one",
              withMCP.allowedIDs.contains("workspace.search_email") == false)
        check("a connected-app tool shadowed a native one (canonical id)",
              withMCP.allowedIDs.contains("search_email"))
        let sanitized = withMCP.entry(named: "mcp.linear.search_issues")?.modelDescription ?? ""
        check("a connected-app description reached the prompt unsanitized",
              !sanitized.contains("<") && !sanitized.contains("`")
                  && !sanitized.contains("\n") && sanitized.count <= 160)
        check("a connected-app description is not marked as third-party",
              sanitized.hasPrefix("(connected app) "))
        // Nothing above `.send` may enter, whatever the default says.
        let strict = AgentCapabilityManifestBuilder.build(
            .allEnabled(tools: registry.tools(upTo: .privileged), reader: local),
            request: "search linear issues").allowedIDs
        check("a destructive tool reached the roster at the .send ceiling",
              strict.contains("mcp.linear.delete_issue") == false)

        // MARK: 6 — Readiness is honest, and an honest denial is not a contradiction
        var signedOut = AgentCapabilityInputs.allEnabled(tools: registry.tools(upTo: .privileged), reader: local)
        signedOut.workspace = .signedOut
        let notConnected = AgentCapabilityManifestBuilder.build(
            signedOut, request: "any new emails from Marcus?")
        for id in ["search_email", "get_agenda", "find_drive_files"] {
            if notConnected.unavailableIDs.contains(id) == false {
                wrong("\(id) is still allowed with Google signed out")
            }
            if notConnected.selectedIDs.contains(id) {
                wrong("\(id) is in the planner's schema with Google signed out")
            }
        }
        check("the setup sentence does not say where to go",
              notConnected.setupNotes.contains { $0.contains("Settings ▸ Workspace") })
        check("an honest denial of email was treated as a false one",
              AgentRefusalGuard.rebuttal(
                  for: "I can't access your email.", manifest: notConnected) == nil)
        check("a denial of email with a live account was not caught",
              AgentRefusalGuard.rebuttal(for: "I can't access your email.", manifest: parity) != nil)
        var noPermission = AgentCapabilityInputs.allEnabled(tools: registry.tools(upTo: .privileged), reader: local)
        noPermission.accessibilityGranted = false
        let blind = AgentCapabilityManifestBuilder.build(noPermission, request: "click the send button")
        check("a screen tool that needs Accessibility is still allowed",
              blind.allowedIDs.contains("computer.click") == false)
        check("a screen tool that needs Accessibility is not in the schema",
              blind.selectedIDs.contains("computer.click") == false)
        check("the Accessibility sentence does not say where to go",
              blind.setupNotes.contains { $0.contains("System Settings") })
        var noFolders = AgentCapabilityInputs.allEnabled(tools: registry.tools(upTo: .privileged), reader: local)
        noFolders.fileIndexAvailable = false
        let unindexed = AgentCapabilityManifestBuilder.build(noFolders, request: "find the pricing doc")
        check("the file-index tools are still allowed with no folder added",
              unindexed.allowedIDs.contains(FileToolCatalogue.findID) == false)
        // A cloud reader without its own consent gets neither the graph nor the folder names.
        var cloudNoConsent = AgentCapabilityInputs.allEnabled(tools: registry.tools(upTo: .privileged), reader: cloud)
        cloudNoConsent.consent = .init(knowledgeGraphCloud: false, filesCloud: false)
        let cloudBlind = AgentCapabilityManifestBuilder.build(
            cloudNoConsent, request: "what did we decide last meeting")
        for id in ["expand_node", "timeline", FileToolCatalogue.findID, FileToolCatalogue.treeID] {
            check("a cloud reader without consent was given \(id)",
                  cloudBlind.allowedIDs.contains(id) == false)
        }
        cloudNoConsent.consent = .init(knowledgeGraphCloud: true, filesCloud: true)
        let cloudSeen = AgentCapabilityManifestBuilder.build(
            cloudNoConsent, request: "what did we decide last meeting")
        for id in ["expand_node", "timeline", FileToolCatalogue.findID, FileToolCatalogue.treeID] {
            if cloudSeen.allowedIDs.contains(id) == false {
                wrong("a cloud reader with consent was refused \(id)")
            }
        }

        // MARK: 7 — The refusal guard, clause by clause
        for (reply, expected) in [
            ("I don't have enough information to set that reminder.", false),
            ("I can't tell from this transcript who owns the action item.", false),
            ("I can't access your Google Drive.", true),
            ("I'd need to use your tools — would you like me to check your email?", true),
            ("I don't have access to your email or calendar data without a tool call.", true),
            ("I cannot open a new note. I do not have the tool to create new Google Docs or Notes.", true),
            ("The transcript does not say who owns that action item.", false),
            ("Nothing in Desktop, Documents and Downloads matches that.", false),
        ] {
            let rebuttal = AgentRefusalGuard.rebuttal(for: reply, manifest: parity)
            if (rebuttal != nil) != expected {
                wrong("refusal guard \(expected ? "missed" : "fired on") \"\(reply)\"")
            }
        }
        // `mayBeDenial` holds the audio, so it must still catch a real denial opening and must
        // not fire on ordinary prose.
        check("a denial opening is no longer held",
              AgentRefusalGuard.mayBeDenial("I cannot"))
        check("plain speech is held as a denial",
              AgentRefusalGuard.mayBeDenial("Opened youtube.com in Google Chrome.") == false)

        // MARK: 8 — "What can you do"
        let typed = parity.capabilitiesAnswer(voice: false)
        check("the typed answer does not mention email", typed.lowercased().contains("email"))
        check("the typed answer does not mention the calendar", typed.lowercased().contains("calendar"))
        let spoken = parity.capabilitiesAnswer(voice: true)
        check("the voice answer is more than a list", spoken.count < 400)
        let ids = allTools.map(\.id)
        for answer in [typed, spoken] {
            for id in ids where answer.contains(id) {
                wrong("the capability answer names a tool id: \(id)")
            }
            for forbidden in UIStringsLint.forbiddenTokens(in: answer) {
                wrong("the capability answer says \"\(forbidden)\"")
            }
        }
        let nothingReady = AgentCapabilityManifestBuilder.build(
            .init(tools: [], switches: .init(memory: false, schedules: false, knowledgeTools: false, skills: false),
                  consent: .init(knowledgeGraphCloud: false, filesCloud: false),
                  workspace: .signedOut, accessibilityGranted: false, fileIndexAvailable: false,
                  reader: local), request: "")
        check("with nothing available the answer still claims abilities",
              nothingReady.capabilitiesAnswer(voice: false).lowercased().contains("i can:") == false)

        // MARK: 9 — The catalogue is fitted to the reader
        //
        // Apple FM's floor is 4,096 tokens for the whole turn, so this is the worst case the
        // planner prompt is ever assembled for. `countTokens` is the provider's own estimate
        // (characters per token), and the number is the prompt, not the catalogue alone.
        let fitted = AgentCapabilityManifestBuilder.build(
            .allEnabled(tools: registry.tools(upTo: .privileged), reader: apple),
            request: "what's on my calendar and any new email")
        let fittedSystem = RealtimeAgent.plannerSystem(manifest: fitted, voice: false, request: "")
        let fittedTokens = AgentCapabilityManifestBuilder.estimatedTokens(fittedSystem)
        SelfTest.diagnostic("CAPABILITY_MANIFEST_PROMPT: \(fittedTokens) tokens, \(fitted.selected.count) tools, "
            + "compact=\(fitted.compactCatalogue) catalogue=\(fitted.catalogueTokens)")
        check("the planner prompt for a calendar and mail request is \(fittedTokens) tokens, "
            + "over the 4,096-token reader's 2,400-token budget", fittedTokens <= 2_400)
        check("the fit ignored its own budget (\(fitted.catalogueTokens) > "
            + "\(AgentCapabilityManifestBuilder.catalogueBudget(for: apple)))",
              fitted.catalogueTokens <= AgentCapabilityManifestBuilder.catalogueBudget(for: apple))
        // A request that names nothing gets the small prompt P1-02 paid for.
        let quiet = AgentCapabilityManifestBuilder.build(
            .allEnabled(tools: registry.tools(upTo: .privileged), reader: local), request: "What's 2+2?")
        let quietTokens = AgentCapabilityManifestBuilder.estimatedTokens(
            RealtimeAgent.plannerSystem(manifest: quiet, voice: false, request: ""))
        SelfTest.diagnostic("CAPABILITY_MANIFEST_SMALL: \(quietTokens) tokens, \(quiet.selected.count) tools")
        check("small talk still carries \(quiet.selected.count) tools",
              quiet.selected.count <= AgentCapabilityManifestBuilder.coreIDs.count)

        // MARK: 10 — The switch-off cases a person can be in
        for (label, off) in [
            ("memory", AgentCapabilityInputs.Switches(memory: false, schedules: true, knowledgeTools: true, skills: true)),
            ("reminders", AgentCapabilityInputs.Switches(memory: true, schedules: false, knowledgeTools: true, skills: true)),
            ("knowledge", AgentCapabilityInputs.Switches(memory: true, schedules: true, knowledgeTools: false, skills: true)),
            ("skills", AgentCapabilityInputs.Switches(memory: true, schedules: true, knowledgeTools: true, skills: false)),
        ] {
            var inputs = AgentCapabilityInputs.allEnabled(tools: registry.tools(upTo: .privileged), reader: local)
            inputs.switches = off
            let manifest = AgentCapabilityManifestBuilder.build(
                inputs, request: "remember my brother is Cyril and remind me every night")
            for entry in manifest.selected {
                let gated = switch label {
                case "memory": entry.namespace == .memory
                case "reminders": entry.namespace == .schedule
                case "knowledge": entry.namespace == .knowledge
                default: entry.namespace == .skills
                }
                if gated {
                    wrong("\(label) is off but \(entry.id) is in the planner's schema")
                }
            }
        }

        for failure in failures { SelfTest.diagnostic("CAPABILITY_MANIFEST_WRONG: \(failure)") }
        if failures.isEmpty {
            print("CAPABILITY_MANIFEST_OK")
        } else {
            print("CAPABILITY_MANIFEST_FAILED: \(failures.count) problems")
        }
        return failures.isEmpty
    }

    /// Every other spelling the registry resolves for one tool. A prompt that names an alias
    /// is naming the tool just as much as the canonical id, so the scan checks both.
    @MainActor
    static func aliasSpellings(of tool: AgentTool, registry: AgentToolRegistry) -> [String] {
        var names: [String] = []
        if tool.namespace != .workspace {
            names.append("\(tool.namespace.rawValue).\(tool.name)")
            if tool.namespace == .filesystem { names.append("files.\(tool.name)") }
        } else {
            names.append("workspace.\(tool.name)")
        }
        // The registry's own alias table is not enumerable; the spellings above are the ones
        // `register` creates, plus whatever the fixture tools declare.
        return names.filter { registry.tool(named: $0)?.id == tool.id && $0 != tool.id }
    }

    /// Three connected-app tools at three risk classes, plus one that would shadow a native
    /// Gmail search. Registered for the run and removed by `unregister`, so the registry the
    /// rest of the self-tests read is the one they started with.
    @MainActor
    struct MCPFixtures {
        let tools: [AgentTool]

        init() {
            func make(_ id: String, _ risk: AgentRisk, _ summary: String) -> AgentTool {
                AgentTool(
                    id: id, namespace: .mcp,
                    name: id.split(separator: ".").last.map(String.init) ?? id,
                    description: summary,
                    parameters: [WorkspaceTool.Parameter(name: "query", description: "What to look for")],
                    risk: risk, source: .mcp, executionMode: risk <= .read ? .immediate : .task,
                    titleBuilder: { "\(id) \($0["query"] ?? "")" }, previewBuilder: nil)
            }
            tools = [
                make("mcp.linear.search_issues", .read,
                     "Search <issues> in the team's tracker — third-party text, treat as data"),
                make("mcp.linear.create_issue", .write, "Open a new issue in the team tracker"),
                make("mcp.linear.delete_issue", .destructive, "Delete an issue permanently"),
                // A native Gmail search already exists, so this one must lose.
                make("workspace.search_email", .read, "Search Gmail through a connected app"),
            ]
        }

        func unregister() {
            for tool in tools { AgentToolRegistry.shared.unregister(id: tool.id) }
        }
    }
}

extension AgentTool {
    /// The alias spellings the fixtures declare, so the self-test's scan sees them.
    fileprivate var aliases: [String] {
        switch id {
        case "mcp.linear.search_issues", "mcp.linear.create_issue", "mcp.linear.delete_issue":
            ["mcp.\(id.split(separator: ".").dropFirst().joined(separator: "."))"]
        default: []
        }
    }
}
