import Foundation

/// `--selftest-ask [question]`: Phase E end to end on the fixture library, with a scripted
/// model — never a real one.
///
/// - The three read-class tools: registered, gated by the index, the Agent switch and *look
///   things up*, allowed in a routine's ceiling, and auto-run only where reads are.
/// - `search_knowledge` with every filter, its errors, and `memory.recall` as a wrapper over it.
/// - `expand_node` and `timeline` wired to an empty graph and to a fake one.
/// - The answer path: a multi-hop answer (a second search the model asks for) where every
///   claim resolves to a chunk that exists and a meeting timestamp; citations the model was
///   not shown are dropped; four rounds at most; twenty passages at most; streaming that never
///   shows a `SEARCH:` line; cancellation mid-answer; the reranker's order kept.
///
/// With a question, also runs it through an extractive fake model and prints every retrieved
/// chunk and its citation. The index is built from fixtures in a temporary directory.
@MainActor
enum KnowledgeAskSelfTest {
    static func run(question: String?) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        do {
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
        } catch {
            print("ASK_FAILED: fixture library could not be written: \(error)")
            return false
        }
        let sources = FixtureKnowledgeSources(meetingsRoot: meetingsRoot)
        sources.sessions = [KnowledgeFixtures.conversation()]
        let environment = FixedKnowledgeIndexEnvironment(settings: KnowledgeIndexSettings(enabled: true))
        let store = KnowledgeStore(directory: root.appendingPathComponent("index", isDirectory: true))
        let indexer = KnowledgeIndexer(store: store, sources: sources, environment: environment, drainsOnChange: false)
        await indexer.backfill()
        _ = await indexer.drain()
        guard let context = indexer.toolContext else {
            print("ASK_FAILED: the indexer offered no tool context with the index on")
            return false
        }
        let pricing = KnowledgeFixtures.pricingID

        failures += catalogueFailures()
        failures += await searchToolFailures(context: context)
        failures += await graphFailures(context: context)
        failures += parserFailures()
        failures += timingFailures()

        // MARK: Multi-hop, every claim resolved
        let decision = "decided to ship the pricing page"
        let owner = "Sam owns the launch ads budget"
        let multiHop = ScriptedAnswerModel { user, call in
            if call == 1 { return "SEARCH: Sam launch ads budget" }
            guard let shipped = ScriptedAnswerModel.marker(for: decision, in: user),
                  let budget = ScriptedAnswerModel.marker(for: owner, in: user) else {
                return "I could not find it in the library."
            }
            return "The pricing page ships on Friday [\(shipped)]. Sam owns the launch ads budget [\(budget)]."
        }
        var asker = KnowledgeAsker(context: context, model: multiHop)
        asker.system = "Test system."
        var events: [KnowledgeAskEvent] = []
        do {
            let answer = try await asker.run("Which day did we decide to ship the pricing page?") { events.append($0) }
            print("ASK_ANSWER rounds=\(answer.rounds) queries=\(answer.queries) grounded=\(answer.isGrounded)")
            print("ASK_ANSWER \(answer.raw)")
            for passage in answer.retrieved {
                print("ASK_RETRIEVED [\(passage.marker)] \(passage.label) · \(passage.kind.rawValue) · "
                      + String(passage.text.prefix(80)))
            }
            check("the model's second search did not run", answer.rounds == 2 && answer.queries.count == 2
                    && answer.queries.last == "Sam launch ads budget")
            check("the answer is not grounded: \(answer.raw)", answer.isGrounded && answer.claims.count == 2)
            let keyword = KeywordKnowledgeSearch(store: store)
            for claim in answer.claims {
                guard !claim.chunkIDs.isEmpty else {
                    failures.append("claim has no citation: \(claim.text)")
                    continue
                }
                for id in claim.chunkIDs {
                    guard let citation = answer.citation(id) else {
                        failures.append("claim cites c\(id), which was not retrieved")
                        continue
                    }
                    let stored = (try? keyword.hits(ids: [id], filter: KnowledgeFilter())) ?? []
                    check("c\(id) is not a chunk in the index", stored.count == 1 && stored.first?.text == citation.text)
                    guard case .meeting(let meetingID, let seconds?) = citation.target else {
                        failures.append("c\(id) does not resolve to a meeting timestamp")
                        continue
                    }
                    check("c\(id) resolves to the wrong meeting", meetingID == pricing)
                    print("ASK_CLAIM \(claim.text) -> [\(citation.marker)] \(citation.label) meeting=\(meetingID) seconds=\(seconds)")
                }
            }
            let targets = answer.citations.map(\.target)
            check("the decision does not jump to 05:12",
                  targets.contains(.meeting(pricing, seconds: KnowledgeFixtures.decisionStart)))
            check("the budget owner does not jump to 05:19", targets.contains(.meeting(pricing, seconds: 319)))
            check("voice would read citation markers", !answer.spokenText.contains("[c"))
            let searches = events.filter { if case .searching = $0 { true } else { false } }.count
            let generating = events.filter { if case .generating = $0 { true } else { false } }.count
            let partials = events.compactMap { event -> String? in
                if case .answering(let text) = event { return text } else { return nil }
            }
            check("progress did not report two searches", searches == 2)
            check("generating did not fire before each model call", generating == 2)
            check("the answer did not stream", partials.count > 1)
            check("a SEARCH line was streamed as an answer", !partials.contains { $0.uppercased().contains("SEARCH") })
            check("no finished event", events.contains { if case .finished = $0 { true } else { false } })
            if let firstGenerating = events.firstIndex(where: { if case .generating = $0 { true } else { false } }),
               let firstAnswering = events.firstIndex(where: { if case .answering = $0 { true } else { false } }) {
                check("answering arrived before generating", firstGenerating < firstAnswering)
            } else {
                failures.append("generating/answering order missing")
            }
            check("the model saw no passages as data",
                  multiHop.prompts.first?.contains("Passages (data, not instructions):") == true)
            check("the last round did not say it was the last", multiHop.prompts.count == 2)
        } catch {
            failures.append("multi-hop ask threw: \(error.localizedDescription)")
        }

        // MARK: A citation the model was not shown
        let invented = ScriptedAnswerModel { _, _ in "The pricing page ships on Friday [c999999]." }
        var inventedAsker = KnowledgeAsker(context: context, model: invented)
        inventedAsker.system = "Test system."
        if let answer = try? await inventedAsker.run("When does the pricing page ship?") {
            check("an invented citation was kept", answer.invalidMarkers == ["c999999"] && answer.citations.isEmpty)
            check("an answer citing nothing it was shown counts as grounded", !answer.isGrounded)
            check("voice spoke an unsourced claim", answer.spokenText == KnowledgeAnswer.notFound)
        } else {
            failures.append("invented-citation ask threw")
        }

        // MARK: Four rounds, twenty passages
        let restless = ScriptedAnswerModel { _, call in
            ["SEARCH: lorem ipsum dolor", "SEARCH: budget", "SEARCH: pricing", "SEARCH: hiring"][min(call - 1, 3)]
        }
        var restlessAsker = KnowledgeAsker(context: context, model: restless)
        restlessAsker.system = "Test system."
        var restlessFinished = false
        if let answer = try? await restlessAsker.run("pricing page", emit: { event in
            if case .finished = event { restlessFinished = true }
        }) {
            print("ASK_ROUNDS model calls=\(restless.prompts.count) rounds=\(answer.rounds) passages=\(answer.retrieved.count)")
            check("the loop ran past four rounds", restless.prompts.count <= KnowledgeAsker.maxRounds
                    && answer.rounds <= KnowledgeAsker.maxRounds)
            check("more than twenty passages went into context", answer.retrieved.count <= KnowledgeAsker.contextPassages)
            check("an endless search was not answered as not found",
                  answer.raw == KnowledgeAnswer.notFound && !answer.isGrounded && restlessFinished)
            check("the last prompt allowed another search",
                  restless.prompts.last?.contains("This is the last round") == true)
        } else {
            failures.append("restless ask threw")
        }

        // MARK: The reranker's order
        let reranker = ReversingReranker()
        let firstPassage = ScriptedAnswerModel { user, _ in
            guard let line = user.split(separator: "\n").first(where: { $0.hasPrefix("[c") }),
                  let end = line.firstIndex(of: "]") else { return "Nothing." }
            return "The first passage is this one [\(line[line.index(after: line.startIndex)..<end])]."
        }
        var rerankAsker = KnowledgeAsker(context: context, model: firstPassage)
        rerankAsker.reranker = reranker
        rerankAsker.system = "Test system."
        do {
            let plain = try KnowledgeToolExecutor.search(
                KnowledgeQuery(text: "pricing budget", limit: KnowledgeAsker.candidates), context: context)
            let expected = Array(plain.prefix(KnowledgeAsker.rerankWindow).reversed()
                .prefix(KnowledgeAsker.perRound)).map(\.chunkID)
            let answer = try await rerankAsker.run("pricing budget")
            check("the reranker was not given the top twenty",
                  reranker.windows == [min(plain.count, KnowledgeAsker.rerankWindow)])
            check("the reranked order was not what the model saw", answer.retrieved.map(\.chunkID) == expected)
            check("the answer did not cite the reranked first passage", answer.citations.first?.chunkID == expected.first)
        } catch {
            failures.append("rerank ask threw: \(error.localizedDescription)")
        }

        // MARK: Cancellation mid-answer
        let slow = ScriptedAnswerModel(delay: .milliseconds(40)) { _, _ in
            String(repeating: "The pricing page ships on Friday. ", count: 20)
        }
        var slowAsker = KnowledgeAsker(context: context, model: slow)
        slowAsker.system = "Test system."
        let progress = AskProgress()
        let job = Task { @MainActor in
            try await slowAsker.run("When does the pricing page ship?") { event in
                if case .answering = event { progress.started = true }
            }
        }
        let began = Date()
        while !progress.started, Date().timeIntervalSince(began) < 5 { try? await Task.sleep(for: .milliseconds(10)) }
        check("the slow answer never started streaming", progress.started)
        job.cancel()
        let cancelledAt = Date()
        let outcome = await job.result
        let stopSeconds = Date().timeIntervalSince(cancelledAt)
        print("ASK_CANCEL stopped in \(String(format: "%.3f", stopSeconds))s, pieces=\(slow.yielded)")
        if case .success = outcome { failures.append("a cancelled ask still returned an answer") }
        check("cancel took longer than a second", stopSeconds < 1)
        check("the model kept streaming after cancel", slow.yielded < 120)

        // MARK: Voice routing
        check("a library question was not routed to Ask",
              KnowledgeAskRouting.isLibraryQuestion("What did we decide about pricing in the last meeting?"))
        check("an ordinary request was routed to Ask", !KnowledgeAskRouting.isLibraryQuestion("Set a timer for five minutes"))
        check("the Ask system prompt lost its rules",
              KnowledgeAsker.systemPrompt.contains("SEARCH:") && KnowledgeAsker.systemPrompt.contains(AgentPromptContext.overrideLine))

        if let question, !question.isEmpty {
            await explain(question, context: context)
        }

        for failure in failures { print("ASK_WRONG: \(failure)") }
        print(failures.isEmpty ? "ASK_OK" : "ASK_FAILED")
        return failures.isEmpty
    }

    // MARK: - Catalogue, gate, routines

    private static func catalogueFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        let registry = AgentToolRegistry.shared
        let tools = KnowledgeToolCatalogue.ids.compactMap { registry.tool(named: $0) }
        check("the knowledge tools are not all registered", tools.count == 3)
        check("a knowledge tool is not read-class",
              tools.allSatisfy { $0.risk == .read && $0.namespace == .knowledge && $0.executionMode == .immediate })
        check("knowledge.search_knowledge does not resolve", registry.tool(named: "knowledge.search_knowledge")?.id == "search_knowledge")
        check("the tool loop does not allow the knowledge tools",
              KnowledgeToolCatalogue.ids.isSubset(of: RealtimeToolSelection.allowedIDs))
        let on = Set(RealtimeAgent.plannableTools(knowledgeTools: true).map(\.id))
        let off = Set(RealtimeAgent.plannableTools(knowledgeTools: false).map(\.id))
        check("the planner does not see the knowledge tools when allowed", KnowledgeToolCatalogue.ids.isSubset(of: on))
        check("the planner sees the knowledge tools when not allowed", off.isDisjoint(with: KnowledgeToolCatalogue.ids))
        for index in 0..<8 {
            let (a, b, c) = (index & 1 != 0, index & 2 != 0, index & 4 != 0)
            check("the gate opened with index=\(a) tools=\(b) lookup=\(c)",
                  KnowledgeToolGate.isAvailable(indexEnabled: a, toolsEnabled: b, lookThingsUp: c) == (a && b && c))
        }
        guard let search = registry.tool(named: "search_knowledge") else { return failures }
        check("search_knowledge asks although reads run without asking",
              PermissionPolicy(autoRead: true).allowsAutomatically(search, authority: .user))
        check("search_knowledge ran without asking although reads ask",
              !PermissionPolicy(autoRead: false).allowsAutomatically(search, authority: .user))
        check("a routine's search_knowledge would wait on a card",
              PermissionPolicy(autoRead: true).allowsAutomatically(search, authority: .scheduled(UUID())))
        check("search_knowledge output is treated as the user's words",
              RealtimeToolSelection.readsUntrustedOutput(namespace: .knowledge, output: ""))
        check("a routine may never use search_knowledge", RoutineToolCeiling.neverAllowedReason(search) == nil)
        let ceiling = RoutineToolCeiling.fix(requested: ["search_knowledge", "knowledge.expand_node", "timeline"],
                                             available: on)
        check("a routine's ceiling refused a knowledge tool: \(ceiling.refused)",
              ceiling.allowed.sorted() == KnowledgeToolCatalogue.ids.sorted() && ceiling.refused.isEmpty)
        let refused = RoutineToolCeiling.fix(requested: ["search_knowledge"], available: off)
        check("a routine kept a knowledge tool the conversation could not use", refused.allowed.isEmpty)
        return failures
    }

    // MARK: - search_knowledge

    private static func searchToolFailures(context: KnowledgeToolContext) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        guard let tool = AgentToolRegistry.shared.tool(named: KnowledgeToolCatalogue.searchID) else {
            return ["search_knowledge is not registered"]
        }
        func rows(_ arguments: [String: String]) async throws -> [[String: String]] {
            let summary = try await KnowledgeToolExecutor.run(tool, arguments: arguments, context: context).summary
            guard summary.hasPrefix(KnowledgeToolExecutor.passagesLabel) else { return [] }
            let json = Data(summary.dropFirst(KnowledgeToolExecutor.passagesLabel.count).utf8)
            return (try? JSONDecoder().decode([[String: String]].self, from: json)) ?? []
        }
        do {
            let decided = try await rows(["query": "decided to ship the pricing page"])
            check("search_knowledge lost the passage, its timestamp or its source",
                  decided.first?["at"] == "05:12" && decided.first?["source"] == "Pricing review"
                    && decided.first?["speaker"] == "Ana")
            check("a passage has no citation id", !decided.isEmpty && decided.allSatisfy { $0["id"]?.hasPrefix("c") == true })
            let ana = try await rows(["query": "pricing", "speaker": "Ana"])
            check("the speaker filter leaked", !ana.isEmpty && ana.allSatisfy { $0["speaker"] == "Ana" })
            let notes = try await rows(["query": "pricing", "kind": "note"])
            check("the kind filter leaked", !notes.isEmpty && notes.allSatisfy { $0["kind"] == "notes" })
            let decisions = try await rows(["query": "budget", "heading": "Decisions"])
            check("the heading filter leaked", !decisions.isEmpty && decisions.allSatisfy { $0["heading"] == "Decisions" })
            let hiring = try await rows(["query": "budget", "meeting": "hiring"])
            check("the meeting filter leaked", !hiring.isEmpty && hiring.allSatisfy { $0["source"] == "Hiring sync" })
            let calendar = Calendar.current
            let hiringDay = calendar.dateComponents([.year, .month, .day], from: KnowledgeFixtures.hiringStart)
            let from = String(format: "%04d-%02d-%02d", hiringDay.year ?? 0, hiringDay.month ?? 0, hiringDay.day ?? 0)
            let later = try await rows(["query": "budget", "from": from])
            check("the from date leaked", !later.isEmpty && later.allSatisfy { $0["source"] == "Hiring sync" })
            let pricingDay = calendar.dateComponents([.year, .month, .day], from: KnowledgeFixtures.pricingStart)
            let to = String(format: "%04d-%02d-%02d", pricingDay.year ?? 0, pricingDay.month ?? 0, pricingDay.day ?? 0)
            let earlier = try await rows(["query": "budget", "to": to])
            check("the to date leaked or dropped its own day",
                  !earlier.isEmpty && earlier.allSatisfy { $0["source"] != "Hiring sync" })
            check("the limit was not clamped to 20", try await rows(["query": "lorem ipsum pricing budget", "limit": "500"]).count <= 20)
            check("a zero limit returned nothing", try await rows(["query": "pricing", "limit": "0"]).count == 1)
            check("no match was not said plainly",
                  try await KnowledgeToolExecutor.run(tool, arguments: ["query": "zebraquux"], context: context)
                    .summary.hasPrefix("No passages match"))

            // memory.recall is the same search with a smaller limit.
            let recalled = KnowledgeRecall(searcher: context.searcher, sourceTitle: context.sourceTitle)
                .passages(for: "pricing page ship") ?? ""
            let recalledIDs = ((try? JSONDecoder().decode([[String: String]].self, from: Data(recalled.utf8))) ?? [])
                .compactMap { $0["id"] }
            let searchedIDs = try await rows(["query": "pricing page ship", "limit": "5"]).compactMap { $0["id"] }
            check("memory.recall is not search_knowledge: \(recalledIDs) vs \(searchedIDs)",
                  !recalledIDs.isEmpty && recalledIDs == searchedIDs)
        } catch {
            failures.append("search_knowledge threw: \(error.localizedDescription)")
        }
        let errors: [([String: String], KnowledgeToolError)] = [
            (["query": "  "], .missingQuery),
            (["query": "pricing", "from": "yesterday"], .badDate("yesterday")),
            (["query": "pricing", "to": "2026-02-30"], .badDate("2026-02-30")),
            (["query": "pricing", "kind": "email"], .badKind("email")),
            (["query": "pricing", "meeting": "Board offsite"], .noMeeting("Board offsite")),
        ]
        for (arguments, expected) in errors {
            do {
                _ = try await KnowledgeToolExecutor.run(tool, arguments: arguments, context: context)
                failures.append("search_knowledge accepted \(arguments)")
            } catch let error as KnowledgeToolError {
                check("search_knowledge gave \(error) for \(arguments), expected \(expected)", error == expected)
            } catch {
                failures.append("search_knowledge threw \(error) for \(arguments)")
            }
        }
        return failures
    }

    // MARK: - expand_node, timeline

    private static func graphFailures(context: KnowledgeToolContext) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        guard let expand = AgentToolRegistry.shared.tool(named: KnowledgeToolCatalogue.expandID),
              let timeline = AgentToolRegistry.shared.tool(named: KnowledgeToolCatalogue.timelineID) else {
            return ["expand_node or timeline is not registered"]
        }
        do {
            let empty = try await KnowledgeToolExecutor.run(expand, arguments: ["node": "person:ana"], context: context)
            check("expand_node without a graph did not say so", empty.summary.contains("has not been built yet"))
            let emptyTimeline = try await KnowledgeToolExecutor.run(timeline, arguments: ["entity": "person:ana"],
                                                                    context: context)
            check("timeline without a graph did not say so", emptyTimeline.summary.contains("has not been built yet"))

            let graph = FakeKnowledgeGraph()
            var withGraph = context
            withGraph.graph = graph
            // A cloud reader, or one nobody declared, never sees the graph without consent.
            for reader in [LLMProviderID.openRouter, nil] {
                let cloud = try await KnowledgeGraphScope.$reader.withValue(reader) {
                    try await KnowledgeToolExecutor.run(expand, arguments: ["node": "person:ana"], context: withGraph)
                }
                check("expand_node answered a \(reader?.rawValue ?? "undeclared") reader without consent",
                      cloud.summary.contains("stays on this Mac") && !cloud.summary.contains("c42") && graph.expanded.isEmpty)
            }
            var consented = withGraph
            consented.graphCloudConsent = true
            let allowed = try await KnowledgeGraphScope.$reader.withValue(.openRouter) {
                try await KnowledgeToolExecutor.run(timeline, arguments: ["entity": "person:ana"], context: consented)
            }
            check("timeline refused a cloud reader the user consented to", allowed.summary.contains("decision:ship"))
            let expanded = try await KnowledgeGraphScope.$reader.withValue(.qwen35_4b) {
                try await KnowledgeToolExecutor.run(
                    expand, arguments: ["node": "person:ana", "edges": "decided, owns", "depth": "9"], context: withGraph)
            }
            check("expand_node lost its source chunk", expanded.summary.contains("\"source_chunk\":\"c42\""))
            check("expand_node did not pass edges and clamp depth",
                  graph.expanded == ["person:ana|decided,owns|3"])
            let entries = try await KnowledgeGraphScope.$reader.withValue(.appleFoundation) {
                try await KnowledgeToolExecutor.run(
                    timeline, arguments: ["entity": "person:ana", "from": "2026-03-01", "to": "2026-03-31"], context: withGraph)
            }
            check("timeline lost its entries", entries.summary.contains("\"node\":\"decision:ship\""))
            check("timeline did not pass its date range", graph.timelineRanges == 1)
        } catch {
            failures.append("graph tools threw: \(error.localizedDescription)")
        }
        return failures
    }

    // MARK: - Parser

    private static func parserFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        let claims = KnowledgeAnswerParser.claims(
            "The page ships Friday. [c1] Sam owns the budget [c2, c3].\n- Ana publishes it [C4]\nThe discount is 20.5% [c5].")
        check("claims were split wrongly: \(claims)", claims.map(\.chunkIDs) == [[1], [2, 3], [4], [5]])
        check("claim text kept its markers", claims.allSatisfy { !$0.text.contains("[") })
        check("markers were not stripped", KnowledgeAnswerParser.stripMarkers("Ships Friday [c12].") == "Ships Friday.")
        check("a half-written marker showed", KnowledgeAnswerParser.stripMarkers("Ships Friday [c1") == "Ships Friday")
        check("SEARCH was not read", KnowledgeAnswerParser.searchDirective("  search: launch budget\n") == "launch budget")
        check("an answer was read as SEARCH", KnowledgeAnswerParser.searchDirective("The search: done [c1].") == nil)
        check("a streaming SEARCH prefix was shown", KnowledgeAnswerParser.mayBeSearchDirective("SEA"))
        check("an answer was hidden while streaming", !KnowledgeAnswerParser.mayBeSearchDirective("The page"))
        return failures
    }

    /// Guards the Ask timing line: sub-100 ms work must not render as `0.0s`, and the
    /// summary must keep model / retrieve / first token / total as separate stages.
    private static func timingFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        check("sub-10ms floors to 0.0s", AskRunTiming.formatSeconds(0.004) == "<0.01s")
        check("tens of ms look like zero", AskRunTiming.formatSeconds(0.04) == "0.04s")
        check("hundreds of ms lose precision", AskRunTiming.formatSeconds(0.12) == "0.12s")
        check("seconds lose a tenth", AskRunTiming.formatSeconds(1.5) == "1.5s")
        check("long waits stay whole", AskRunTiming.formatSeconds(22) == "22s")
        var timing = AskRunTiming(startedAt: .distantPast)
        timing.providerSeconds = 0.03
        timing.retrieveSeconds = 0.04
        timing.firstTokenSeconds = 22
        timing.totalSeconds = 22.1
        let line = timing.summary(running: false)
        check("summary hides fast stages: \(line)",
              line == "0.03s model · 0.04s retrieve · 22s first token · 22s total")
        timing.providerSeconds = 0.004
        timing.retrieveSeconds = 0.008
        let tiny = timing.summary(running: false)
        check("tiny stages look like zero: \(tiny)",
              tiny.hasPrefix("<0.01s model · <0.01s retrieve · "))
        return failures
    }

    // MARK: - A real question, with the extractive fake

    private static func explain(_ question: String, context: KnowledgeToolContext) async {
        let extractive = ScriptedAnswerModel { user, _ in
            let lines = user.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let index = lines.firstIndex(where: { $0.hasPrefix("[c") }), index + 1 < lines.count,
                  let end = lines[index].firstIndex(of: "]") else { return "I could not find it in the library." }
            let marker = lines[index][lines[index].index(after: lines[index].startIndex)..<end]
            let sentence = lines[index + 1].split(separator: ".").first.map(String.init) ?? lines[index + 1]
            return "\(sentence.trimmingCharacters(in: .whitespaces)) [\(marker)]."
        }
        var asker = KnowledgeAsker(context: context, model: extractive)
        asker.system = "Test system."
        do {
            let answer = try await asker.run(question) { event in
                if case .searching(let round, let query) = event { print("ASK_SEARCH round \(round): \(query)") }
            }
            for passage in answer.retrieved {
                print("ASK_Q_RETRIEVED [\(passage.marker)] \(passage.label) · \(passage.kind.rawValue) · \(passage.text)")
            }
            print("ASK_Q_ANSWER \(answer.raw)")
            for claim in answer.claims {
                let sources = claim.chunkIDs.compactMap(answer.citation).map { "[\($0.marker)] \($0.label)" }
                print("ASK_Q_CLAIM \(claim.text) -> \(sources.isEmpty ? "no source" : sources.joined(separator: ", "))")
            }
        } catch {
            print("ASK_Q_FAILED \(error.localizedDescription)")
        }
    }
}

// MARK: - Fakes

@MainActor
private final class AskProgress {
    var started = false
}

/// Answers from a script, streamed word by word, recording every prompt it was given.
private final class ScriptedAnswerModel: KnowledgeAnswerModel, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var pieces = 0
    private let delay: Duration?
    private let script: @Sendable (_ user: String, _ call: Int) -> String

    init(delay: Duration? = nil, script: @escaping @Sendable (_ user: String, _ call: Int) -> String) {
        self.delay = delay
        self.script = script
    }

    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var yielded: Int {
        lock.lock()
        defer { lock.unlock() }
        return pieces
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        let call = lock.withLock {
            recorded.append(user)
            return recorded.count
        }
        var words: [String] = []
        for word in script(user, call).split(separator: " ", omittingEmptySubsequences: false) {
            words.append(words.isEmpty ? String(word) : " " + word)
        }
        let delay = self.delay
        let pieces = words
        return AsyncThrowingStream { continuation in
            let task = Task {
                for word in pieces {
                    if let delay { try? await Task.sleep(for: delay) }
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    self.count()
                    continuation.yield(word)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func count() {
        lock.lock()
        pieces += 1
        lock.unlock()
    }

    /// The `c…` marker heading the passage that contains `phrase`, as the prompt lists it.
    static func marker(for phrase: String, in user: String) -> String? {
        let lines = user.split(separator: "\n").map(String.init)
        guard var index = lines.firstIndex(where: { !$0.hasPrefix("[c") && $0.contains(phrase) }) else { return nil }
        while index > 0 {
            index -= 1
            let line = lines[index]
            if line.hasPrefix("[c"), let end = line.firstIndex(of: "]") {
                return String(line[line.index(after: line.startIndex)..<end])
            }
        }
        return nil
    }
}

private final class ReversingReranker: KnowledgeReranking, @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []

    var windows: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sizes
    }

    func rerank(query: String, hits: [KnowledgeHit]) async throws -> [KnowledgeHit] {
        lock.withLock { sizes.append(hits.count) }
        return hits.reversed()
    }
}

private final class FakeKnowledgeGraph: KnowledgeGraphReading, @unchecked Sendable {
    private let lock = NSLock()
    private var expansions: [String] = []
    private var ranges = 0

    var expanded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return expansions
    }

    var timelineRanges: Int {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    var isAvailable: Bool { true }
    /// `KnowledgeFixtures.pricingStart`, which is main-actor isolated.
    private let observed = Date(timeIntervalSince1970: 1_772_460_000)

    func expand(nodeID: String, edgeTypes: Set<String>, depth: Int) throws -> KnowledgeGraphExpansion {
        lock.lock()
        expansions.append("\(nodeID)|\(edgeTypes.sorted().joined(separator: ","))|\(depth)")
        lock.unlock()
        return KnowledgeGraphExpansion(
            nodes: [KnowledgeGraphNode(id: "decision:ship", type: "Decision", label: "Ship the pricing page", sourceChunk: 42)],
            edges: [KnowledgeGraphEdge(from: nodeID, to: "decision:ship", type: "decided",
                                       observedAt: observed, sourceChunk: 42)])
    }

    func timeline(entityID: String, from: Date?, to: Date?) throws -> [KnowledgeTimelineEntry] {
        lock.lock()
        if from != nil, to != nil, from! < to! { ranges += 1 }
        lock.unlock()
        return [KnowledgeTimelineEntry(at: observed, nodeID: "decision:ship",
                                       label: "Ship the pricing page", sourceChunk: 42)]
    }
}
