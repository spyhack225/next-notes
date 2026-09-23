import Foundation

/// `--selftest-assemble`: D4 over a fixture corpus, with a scripted compose — never a real
/// model, and never the user's index.
///
/// The fixture library is the one `KnowledgeFixtures` writes (two finished meetings and a
/// conversation), plus a hand-built file seam, plus a seeded graph whose action items give
/// the deterministic half of the outstanding list. The pipeline under test is the production
/// one — registry entry, gate, four visible steps, the compose seam through
/// `AgentModelRouting`, the page written to disk, the artifact on the ledger — so the parts
/// that must not fail silently are the parts the run measures:
///
/// - at least three distinct sources cited on the page,
/// - the file exists on disk and carries the source list,
/// - three to five outstanding items,
/// - the run's step list shows the four steps in the demo script's order, with no tool id,
/// - the ledger holds the page for the run's task id,
/// - and with no model, the page still exists and says it was written without one — it does
///   not fail the whole step, and it does not pretend a model wrote it.
@MainActor
enum AssemblerSelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: The catalogue: registered, gated like the rest of the namespace

        guard let tool = AgentToolRegistry.shared.tool(named: AssemblerToolCatalogue.assembleID) else {
            print("ASSEMBLE_FAILED: the assemble tool is not registered")
            return false
        }
        check("the tool is not read-class, so it could not run under look things up",
              tool.risk <= .read)
        check("the tool composes outside the knowledge namespace", tool.namespace == .knowledge)
        check("the tool's own title is not a sentence a person could read",
              !tool.title(for: [:]).contains("."))

        // MARK: The fixture corpus

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-assemble-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        do {
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
        } catch {
            print("ASSEMBLE_FAILED: fixture library could not be written: \(error)")
            return false
        }
        let sources = FixtureKnowledgeSources(meetingsRoot: meetingsRoot)
        sources.sessions = [KnowledgeFixtures.conversation()]
        let environment = FixedKnowledgeIndexEnvironment(settings: KnowledgeIndexSettings(
            enabled: true, graph: true))
        let store = KnowledgeStore(directory: root.appendingPathComponent("index", isDirectory: true))
        let indexer = KnowledgeIndexer(store: store, sources: sources, environment: environment,
                                       drainsOnChange: false)
        await indexer.backfill()
        _ = await indexer.drain()
        guard let context = indexer.toolContext else {
            print("ASSEMBLE_FAILED: the indexer offered no tool context with the index on")
            return false
        }

        // A folder the person shared, as the file search would see it: names only, which is
        // all the file search ever reads.
        let files = FixtureNamedFileRetrieval(hits: [
            FileHit(path: root.appendingPathComponent("Launch checklist.md").path,
                    name: "Launch checklist.md", isDirectory: false, category: .document,
                    size: 120, modifiedAt: KnowledgeFixtures.pricingStart, accessedAt: nil,
                    root: root.path, depth: 0),
            FileHit(path: root.appendingPathComponent("press-kit", isDirectory: true).path,
                    name: "press-kit", isDirectory: true, category: .folder,
                    size: nil, modifiedAt: KnowledgeFixtures.pricingStart, accessedAt: nil,
                    root: root.path, depth: 0),
        ])
        var fixtureContext = context
        fixtureContext.files = files

        // A graph seeded the way extraction would leave it: one meeting node, four action
        // items assigned into it — the deterministic outstanding list.
        let graph = GraphStore(store: store)
        do {
            let transcript = try store.chunkRows(kind: .transcript,
                                                 sourceID: KnowledgeFixtures.pricingID.uuidString)
            let chunk = transcript.first?.id ?? 1
            let meetingKey = GraphIDs.meeting(KnowledgeFixtures.pricingID.uuidString)
            let at = Int64(KnowledgeFixtures.pricingStart.timeIntervalSince1970)
            var nodes = [GraphNodeRecord(
                id: meetingKey, type: "Meeting",
                fields: ["label": .text("Pricing review")], meetingID: meetingKey,
                sourceChunk: chunk, observedAt: at)]
            var edges: [GraphEdgeRecord] = []
            let owed = ["Publish the pricing page", "Announce it in the newsletter",
                        "Send the press kit to the list", "Book the demo call for launch day"]
            for (index, text) in owed.enumerated() {
                let id = GraphIDs.owned("ActionItem", meetingID: meetingKey, ordinal: index)
                nodes.append(GraphNodeRecord(
                    id: id, type: "ActionItem", fields: ["text": .text(text)],
                    meetingID: meetingKey, sourceChunk: chunk, observedAt: at))
                edges.append(GraphEdgeRecord(
                    type: "assigned_in", from: id, to: meetingKey, meetingID: meetingKey,
                    observedAt: at, validFrom: nil, validTo: nil, sourceChunk: chunk))
            }
            let outcome = try graph.replaceMeeting(
                GraphBatch(meetingID: meetingKey, nodes: nodes, edges: edges),
                now: KnowledgeFixtures.pricingStart)
            check("the seeded graph was written as unchanged",
                  outcome != GraphStore.ReplaceOutcome.unchanged)
            let items = try graph.actionItems()
            check("the seeded graph carries \(items.count) action items instead of four",
                  items.count == 4)
        } catch {
            failures.append("the fixture graph could not be written: \(error.localizedDescription)")
        }

        // MARK: Without a model — the degrade path

        AssemblerToolExecutor.composeForSelfTest = { _, _ in nil }
        do {
            let taskID = "assemble-fixture-no-model"
            // The tool path, whose observable outputs are the four step rows and the ledger.
            let toolResult = try await AssemblerToolExecutor.run(
                tool, arguments: ["topic": "pricing"],
                context: fixtureContext, graph: graph, taskID: taskID)
            // The same assembled pipeline, whose fields the page is judged on.
            let result = try await AssemblerToolExecutor.assembler(
                topic: "pricing", context: fixtureContext, graph: graph)
                .assemble()
            guard let url = result.fileURL else {
                failures.append("the assembly never wrote its page")
                throw AssembleError.nothingFound
            }
            let page = try String(contentsOf: url, encoding: .utf8)
            print("ASSEMBLE_PAGE \(url.path)")
            print("ASSEMBLE_SOURCES \(result.sources.count) · owed \(result.outstanding.count) · "
                  + "without model \(result.wroteWithoutModel)")
            let distinct = Set(result.sources.map { "\($0.kind.rawValue):\($0.title ?? "")" })
            check("only \(distinct.count) distinct sources cited — three is the pass mark",
                  distinct.count >= 3)
            check("the page never landed on disk", FileManager.default.fileExists(atPath: url.path))
            check("the page carries no source list", page.contains("## Sources"))
            check("the page's outstanding list held \(result.outstanding.count) items — "
                  + "the pass asks for three to five",
                  result.outstanding.count >= 3 && result.outstanding.count <= 5)
            check("the degraded page does not say it was written without a model",
                  page.contains("Written without a model pass"))
            let steps = AgentActivityStore.shared.steps(taskID: taskID).map(\.title)
            check("the run's steps were \(steps) — not the four the script names", steps == [
                KnowledgeAssembler.stepFileSearch,
                KnowledgeAssembler.stepSearch,
                KnowledgeAssembler.stepRead,
                KnowledgeAssembler.stepCompose,
            ])
            check("a step title carried a raw id", steps.allSatisfy { !$0.contains(".") })
            check("the run's page never reached the ledger",
                  !AgentArtifactLedger.peek(taskID: taskID).isEmpty)
            check("the result card leaked the tool id",
                  !toolResult.summary.contains("knowledge.\(AssemblerToolCatalogue.assembleID)"))
            check("the result card did not name the page on disk",
                  toolResult.summary.contains(url.path))
            // Clean up between runs so the on-disk assertions below stay per-run.
            try? FileManager.default.removeItem(at: url)
        } catch {
            failures.append("the no-model assembly threw: \(error.localizedDescription)")
        }

        // MARK: With a model — the scripted compose, over the same real pipeline

        AssemblerToolExecutor.composeForSelfTest = { _, user in
            guard user.contains("pricing") else { return "I have nothing to say about that." }
            return """
                The launch is set for Friday and the pricing page is ready to ship.
                Owed
                1. Publish the pricing page
                2. Announce it in the newsletter
                3. Send the press kit to the list
                4. Book the demo call for launch day
                """
        }
        do {
            let taskID = "assemble-fixture-model"
            let result = try await AssemblerToolExecutor.assembler(
                topic: "pricing", context: fixtureContext, graph: graph)
                .assemble()
            let url = result.fileURL ?? URL(fileURLWithPath: "/dev/null")
            let page = try String(contentsOf: url, encoding: .utf8)
            check("the model's overview never reached the page", page.contains("ready to ship"))
            check("the model page carries the degrade note", !page.contains("Written without a model pass"))
            check("the model's owed items did not land",
                  result.outstanding.contains("Publish the pricing page"))
            check("the model path did not write its page to disk",
                  FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        } catch {
            failures.append("the model-backed assembly threw: \(error.localizedDescription)")
        }
        AssemblerToolExecutor.composeForSelfTest = nil

        // MARK: The honest total failure

        AssemblerToolExecutor.composeForSelfTest = { _, _ in nil }
        do {
            _ = try await AssemblerToolExecutor.run(
                tool, arguments: ["topic": "zebraquux nonsense"],
                context: fixtureContext, graph: graph, taskID: nil)
            failures.append("assembling a topic that matches nothing succeeded")
        } catch let error as AssembleError {
            check("the nothing-found failure did not name the cause honestly",
                  error.localizedDescription.contains("Nothing"))
        } catch {
            failures.append("the nothing-found assembly threw the wrong error: \(error)")
        }
        AssemblerToolExecutor.composeForSelfTest = nil

        for failure in failures { print("ASSEMBLE_WRONG: \(failure)") }
        print(failures.isEmpty ? "ASSEMBLE_OK" : "ASSEMBLE_FAILED: \(failures.count) problem(s)")
        return failures.isEmpty
    }
}

/// A file-search seam over hand-built rows: the names a person could have shared, without a
/// real crawl. Named apart from `FileIndexSelfTest`'s `FixtureFileRetrieval`, which wraps a
/// real fixture store — this one only needs the shape.
private struct FixtureNamedFileRetrieval: FileRetrieving {
    let hits: [FileHit]

    var isAvailable: Bool { true }
    var folders: [String] { [] }

    func find(query: String, category: FileCategory?, folder: String?, modifiedAfter: Date?,
              limit: Int) throws -> [FileHit] {
        let words = query.lowercased().split(separator: " ")
        let matched = hits.filter { hit in
            words.allSatisfy { word in
                hit.name.lowercased().contains(word) || hit.path.lowercased().contains(word)
            }
        }
        return Array(matched.prefix(limit))
    }

    func tree(path: String, depth: Int, limit: Int) throws -> (hits: [FileHit], total: Int) {
        ([], 0)
    }
}
