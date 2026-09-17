import Foundation

/// `--selftest-extract [notes.json]`: Part 4, Phase C on fixture meetings, with a scripted
/// model — never a real one, never the user's library.
///
/// - The GBNF API: grammars built from a schema parse, every rule they use is defined, and a
///   matcher accepts exactly what the sampler would have allowed.
/// - The ontology: the bundled YAML and the compiled-in copy agree, and validation drops an
///   unknown type, a missing or unknown field, a malformed value, a wrong edge and an edge
///   without a real source chunk.
/// - `MeetingStatus.extracting`: persisted, active, repaired to done after a crash.
/// - Extraction end to end: three fixture meetings extract with zero schema violations;
///   `notes.json` carries the notes' generation; every edge's source chunk exists; a decision
///   reversed in a later meeting is closed with `valid_to` and linked by `supersedes`.
/// - Idempotency: re-extraction reuses `notes.json` and writes nothing; a forced re-extraction
///   produces the same graph; `rm knowledge.sqlite` rebuilds the same graph without a model;
///   regenerated notes drop the stale graph; a deleted meeting takes its graph with it, also
///   when it went while the app was closed; a dropped item does not renumber the ones kept.
/// - The graph is local-only: `expand_node` and `timeline` refuse an OpenRouter reader
///   without the separate consent.
/// - Hostile output is dropped item by item; output that is not JSON changes nothing.
/// - Reminder suggestions for action items the user owns with a future due date — offered,
///   never created.
///
/// With a path, also validates that `notes.json` against the ontology's field rules. The file
/// is only read.
@MainActor
enum KnowledgeExtractSelfTest {
    static let followUpID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    /// Three days after the hiring sync.
    static let followUpStart = Date(timeIntervalSince1970: 1_773_324_000)

    static let followUpNotes = """
        ## Summary

        Follow-up on the pricing launch.

        ## Decisions

        - Move the pricing page launch to Monday.

        ## Action items

        - **You** — send the launch checklist to Sam by 2026-03-13.

        ## Open questions

        - Do we need legal review of the annual discount?
        """

    static func run(path: String?) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        failures += grammarFailures()
        failures += ontologyFailures()
        failures += statusFailures()
        failures += await endToEndFailures()
        failures += reminderStoreFailures()

        check("the graph switch is not off by default", !KnowledgeIndexSettings().graph && !KnowledgeIndexSettings().graphEnabled)
        check("the settings key drifted", KnowledgeIndexSettings.graphKey == "knowledgeGraphEnabled")
        check("the shared extraction service is on under a self-test", !KnowledgeExtractionService.shared.isEnabled)

        if let path, !path.isEmpty {
            explain(path)
        }

        for failure in failures { print("EXTRACT_WRONG: \(failure)") }
        print(failures.isEmpty ? "EXTRACT_OK" : "EXTRACT_FAILED")
        return failures.isEmpty
    }

    // MARK: - Grammar

    static func grammarFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append("grammar: \(name)") } }

        let grammar = NotesExtraction.grammar
        print("EXTRACT_GRAMMAR rules=\(grammar.text.split(separator: "\n").count) bytes=\(grammar.text.utf8.count)")
        check("notes grammar has structural problems: \(grammar.structuralProblems())", grammar.structuralProblems().isEmpty)
        let names = grammar.text.split(separator: "\n").compactMap { $0.components(separatedBy: " ::= ").first }
        check("a rule name is not [a-z0-9-]", names.allSatisfy { $0.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } })
        check("the root is not first", names.first == "root")

        let valid = #"{"decisions":[{"text":"Ship on Friday.","subject":"pricing page launch","supersedes":false,"said_by":null,"chunk":3}],"action_items":[{"text":"Send the \"checklist\"","owner":"You","due":"2026-03-13","chunk":5}],"open_questions":[],"topics":[{"label":"Pricing","chunks":[0,3]}]}"#
        check("a valid extraction does not match", grammar.matches(valid))
        let spaced = """
            {
              "decisions": [],
              "action_items": [],
              "open_questions": [],
              "topics": []
            }
            """
        check("bounded whitespace does not match", grammar.matches(spaced))
        check("trailing prose matched", !grammar.matches(valid + " Done."))
        check("a missing key matched", !grammar.matches(#"{"decisions":[],"action_items":[],"open_questions":[]}"#))
        check("keys out of order matched", !grammar.matches(#"{"action_items":[],"decisions":[],"open_questions":[],"topics":[]}"#))
        check("a string bool matched", !grammar.matches(valid.replacingOccurrences(of: #""supersedes":false"#, with: #""supersedes":"no""#)))
        check("a free-text due date matched", !grammar.matches(valid.replacingOccurrences(of: "2026-03-13", with: "next Friday")))
        check("an 81-character subject matched", !grammar.matches(valid.replacingOccurrences(
            of: "pricing page launch", with: String(repeating: "x", count: 81))))
        check("a raw newline inside a string matched", !grammar.matches(valid.replacingOccurrences(of: "Ship on", with: "Ship\non")))
        let seventeen = "{\"decisions\":[" + Array(repeating: #"{"text":"a","subject":"b","supersedes":true,"said_by":"Ana","chunk":1}"#, count: 17)
            .joined(separator: ",") + "],\"action_items\":[],\"open_questions\":[],\"topics\":[]}"
        check("seventeen decisions matched", !grammar.matches(seventeen))

        // Reusable for the memory review and schedule creation: a small schema of its own.
        let small = GBNFGrammar.json(.object([("kind", .enumeration(["reminder", "routine"])), ("minutes", .nullable(.integer))]))
        check("a small schema has problems: \(small.structuralProblems())", small.structuralProblems().isEmpty)
        check("a small schema rejects a valid value", small.matches(#"{"kind":"routine","minutes":null}"#)
            && small.matches(#"{"kind":"reminder","minutes":15}"#))
        check("a small schema accepts an unlisted value", !small.matches(#"{"kind":"alarm","minutes":1}"#))
        check("a leading zero matched", !small.matches(#"{"kind":"routine","minutes":015}"#))

        // The hand-written GBNF the parser must also read: repetition, classes, escapes, groups.
        let handWritten = GBNFGrammar(text: """
            # comments are allowed
            root ::= "a"+ ("b" | [c-e])* tail?
            tail ::= [^\\x00-\\x1F] (
              "!" | "?"
            )
            """)
        check("a hand-written grammar has problems: \(handWritten.structuralProblems())", handWritten.structuralProblems().isEmpty)
        check("a hand-written grammar rejects a sentence", handWritten.matches("aaabce") && handWritten.matches("a") && handWritten.matches("abz!"))
        check("a hand-written grammar accepts a non-sentence", !handWritten.matches("b") && !handWritten.matches("az"))
        check("an undefined rule was not reported",
              GBNFGrammar(text: "root ::= missing \"x\"\n").structuralProblems() == ["missing is used but never defined"])

        check("the llama provider does not enforce grammars", LlamaLLMProvider().enforcesGrammar)
        check("Apple's model claims to enforce grammars", !FoundationModelLLMProvider().enforcesGrammar)
        return failures
    }

    // MARK: - Ontology

    static func ontologyFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append("ontology: \(name)") } }

        let bundled = Ontology.bundledText
        print("EXTRACT_ONTOLOGY bundled=\(bundled != nil)")
        if let bundled {
            check("Resources/knowledge-ontology.yaml and the compiled-in copy have drifted", bundled == Ontology.builtInText)
        }
        let ontology: Ontology
        do {
            ontology = try Ontology.parse(Ontology.builtInText)
        } catch {
            return ["ontology: the compiled-in copy does not parse: \(error.localizedDescription)"]
        }
        check("the current ontology is not the compiled-in one", Ontology.current == ontology)
        check("node types \(ontology.nodes.keys.sorted())", Set(ontology.nodes.keys)
            == ["Meeting", "Person", "Decision", "ActionItem", "OpenQuestion", "Artifact", "Topic"])
        check("Topic is not the only optional type",
              ontology.nodes.values.filter(\.isOptional).map(\.name) == ["Topic"])
        check("edge types \(ontology.edges.keys.sorted())", Set(ontology.edges.keys)
            == ["attended", "decided_in", "supersedes", "assigned_in", "owns", "raised_in", "produced", "discussed", "about"])
        check("about does not accept three sources", ontology.edges["about"]?.from == ["Decision", "ActionItem", "OpenQuestion"])
        check("ActionItem.due is not a date", ontology.nodes["ActionItem"]?.fields["due"] == .date)
        check("a malformed ontology parsed", (try? Ontology.parse("version: 1\nnodes:\n  A:\n    fields: { x: wibble }\nedges: {}\n")) == nil)

        let meeting = GraphNodeRecord(id: "meeting:m", type: "Meeting",
                                      fields: ["title": .text("Sync"), "start": .text("2026-03-02T14:00:00Z")],
                                      meetingID: "m", sourceChunk: 1, observedAt: 0)
        func node(_ id: String, _ type: String, _ fields: [String: GraphFieldValue], chunk: Int64? = 1) -> GraphNodeRecord {
            GraphNodeRecord(id: id, type: type, fields: fields, meetingID: "m", sourceChunk: chunk, observedAt: 0)
        }
        func edge(_ type: String, _ from: String, _ to: String, chunk: Int64 = 1) -> GraphEdgeRecord {
            GraphEdgeRecord(type: type, from: from, to: to, meetingID: "m", observedAt: 0, validFrom: 0, validTo: nil, sourceChunk: chunk)
        }
        let batch = GraphBatch(meetingID: "m", nodes: [
            meeting,
            node("decision:ok", "Decision", ["text": .text("Ship it."), "subject": .text("launch"), "supersedes": .bool(false)]),
            node("widget:1", "Widget", ["text": .text("x")]),
            node("decision:nosubject", "Decision", ["text": .text("Ship it.")]),
            node("decision:extra", "Decision", ["text": .text("a"), "subject": .text("b"), "colour": .text("red")]),
            node("decision:typed", "Decision", ["text": .bool(true), "subject": .text("b")]),
            node("decision:long", "Decision", ["text": .text(String(repeating: "y", count: 401)), "subject": .text("b")]),
            node("actionitem:baddate", "ActionItem", ["text": .text("Call"), "due": .text("2026-02-30")]),
            node("actionitem:ok", "ActionItem", ["text": .text("Call"), "due": .text("2026-02-28")]),
            node("openquestion:ghost", "OpenQuestion", ["text": .text("Why?")], chunk: 999),
        ], edges: [
            edge("decided_in", "decision:ok", "meeting:m"),
            edge("assigned_in", "actionitem:ok", "meeting:m"),
            edge("decided_in", "actionitem:ok", "meeting:m"),
            edge("assigned_in", "actionitem:baddate", "meeting:m"),
            edge("teleports", "decision:ok", "meeting:m"),
            edge("decided_in", "decision:ok", "meeting:m", chunk: 42),
            GraphEdgeRecord(type: "decided_in", from: "decision:ok", to: "meeting:m", meetingID: "m", observedAt: 0,
                            validFrom: 10, validTo: 5, sourceChunk: 1),
        ])
        let (valid, violations) = ontology.validate(batch, knownChunks: [1, 2])
        for violation in violations { print("EXTRACT_ONTOLOGY_DROPPED \(violation)") }
        check("kept nodes \(valid.nodes.map(\.id))", valid.nodes.map(\.id) == ["meeting:m", "decision:ok", "actionitem:ok"])
        check("kept edges \(valid.edges.map(\.type))", valid.edges.map(\.type) == ["decided_in", "assigned_in"])
        check("violations \(violations.count), expected 12", violations.count == 12)
        let reasons = violations.map(\.reason).joined(separator: "\n")
        for expected in ["unknown node type Widget", "missing required field subject", "unknown field colour",
                         "text has the wrong type", "longer than 400", "due is not YYYY-MM-DD",
                         "source chunk 999 does not exist", "unknown edge type", "is not allowed",
                         "source chunk 42 does not exist", "joins a node that was dropped", "valid_to precedes valid_from"] {
            check("no violation says \"\(expected)\"", reasons.contains(expected))
        }

        // The YAML subset: comments, flow maps and lists, block scalars with commas.
        let yaml = try? MiniYAML.parse("""
            # heading
            a: one, two # trailing
            b: { c: [x, y], d: "q # not a comment" }
            e:
              f: g
            """)
        check("the YAML subset misparsed", yaml == .map([
            ("a", .scalar("one, two")),
            ("b", .map([("c", .list([.scalar("x"), .scalar("y")])), ("d", .scalar("q # not a comment"))])),
            ("e", .map([("f", .scalar("g"))])),
        ]))
        return failures
    }

    // MARK: - Status

    static func statusFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append("status: \(name)") } }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try? encoder.encode(MeetingStatus.extracting)
        check("extracting is not persisted as its own state",
              data.flatMap { String(data: $0, encoding: .utf8) } == #"{"state":"extracting"}"#)
        check("extracting does not round-trip", data.flatMap { try? decoder.decode(MeetingStatus.self, from: $0) } == .extracting)
        check("a file written before extracting existed no longer decodes",
              (try? decoder.decode(MeetingStatus.self, from: Data(#"{"state":"summarizing"}"#.utf8))) == .summarizing)
        check("extracting is not active", MeetingStatus.extracting.isActive)
        check("extracting has no name", MeetingStatus.extracting.displayName == "Extracting decisions")
        check("a crash while extracting is not repaired to done", MeetingStore.repairedStatus(.extracting) == .done)
        check("a crash while recording is repaired to done", MeetingStore.repairedStatus(.recording).isFailure)
        check("a finished meeting was repaired", MeetingStore.repairedStatus(.done) == .done)
        return failures
    }

    // MARK: - End to end

    static func writeFollowUp(meetingsRoot root: URL) throws {
        let directory = root.appendingPathComponent(followUpID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let record = AgentActionRecord(id: "proposal-1", tool: "create_doc", title: "Launch checklist",
                                       performedAt: followUpStart.addingTimeInterval(1_900),
                                       link: URL(string: "https://docs.example.com/d/1"))
        let meeting = Meeting(id: followUpID, title: "Pricing follow-up", start: followUpStart,
                              end: followUpStart.addingTimeInterval(900), attendees: ["sam@example.com"],
                              status: .done, agentActions: [record])
        try encoder.encode(meeting).write(to: directory.appendingPathComponent(MeetingStore.recordFile), options: .atomic)
        let segments = [TranscriptSegment(start: 2, end: 6, text: "Can we move the pricing page to Monday?", source: .mic)]
        try encoder.encode(segments).write(to: directory.appendingPathComponent(MeetingStore.transcriptFile), options: .atomic)
        try followUpNotes.write(to: directory.appendingPathComponent(MeetingStore.notesFile), atomically: true, encoding: .utf8)
    }

    static func endToEndFailures() async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        do {
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
            try writeFollowUp(meetingsRoot: meetingsRoot)
        } catch {
            return ["fixture library could not be written: \(error)"]
        }
        let schedulesBefore = ScheduleStore.shared.schedules.count
        let sources = FixtureKnowledgeSources(meetingsRoot: meetingsRoot)
        let environment = FixedKnowledgeIndexEnvironment(settings: KnowledgeIndexSettings(enabled: true, graph: true))
        let store = KnowledgeStore(directory: root.appendingPathComponent("index", isDirectory: true))
        let indexer = KnowledgeIndexer(store: store, sources: sources, environment: environment,
                                       now: { Date(timeIntervalSince1970: 1_900_000_000) }, drainsOnChange: false)
        await indexer.backfill()
        _ = await indexer.drain()

        let extractor = KnowledgeExtractor(store: store)
        let graph = GraphStore(store: store)
        let model = ScriptedExtractionModel()
        func directory(_ id: UUID) -> URL { meetingsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
        let pricing = KnowledgeFixtures.pricingID, hiring = KnowledgeFixtures.hiringID
        let ordered = [pricing, hiring, followUpID]
        check("the graph is available before anything was extracted", !graph.isAvailable)

        // MARK: Three meetings, zero violations
        let started = Date()
        var totalViolations = 0
        for id in ordered {
            do {
                let report = try await extractor.extract(meetingDirectory: directory(id), model: model)
                totalViolations += report.violations.count
                print("EXTRACT_MEETING \(id.uuidString.prefix(8)) outcome=\(report.outcome) nodes=\(report.nodes) "
                      + "edges=\(report.edges) violations=\(report.violations.count)")
                for violation in report.violations { print("EXTRACT_VIOLATION \(violation)") }
                check("\(id) was not extracted by the model", report.outcome == .extracted && report.modelCalls == 1)
                let notesJSON = KnowledgeExtractor.read(directory(id).appendingPathComponent(MeetingStore.notesJSONFile))
                let markdown = (try? String(contentsOf: directory(id).appendingPathComponent(MeetingStore.notesFile), encoding: .utf8)) ?? ""
                let meetingStart = id == pricing ? KnowledgeFixtures.pricingStart
                    : id == hiring ? KnowledgeFixtures.hiringStart : followUpStart
                let expected = KnowledgeStore.generation(of: Chunker.notes(markdown, meetingStart: meetingStart))
                check("\(id) notes.json is missing or has the wrong generation",
                      notesJSON?.generation == expected && notesJSON?.meetingID == id.uuidString
                        && notesJSON?.version == NotesExtraction.currentVersion)
                check("\(id) notes.json generation differs from the index's",
                      (try? store.indexedSources(kind: .notes)[id.uuidString]) == expected)
            } catch {
                failures.append("\(id) extraction threw: \(error.localizedDescription)")
            }
        }
        print("EXTRACT_BUILD meetings=3 violations=\(totalViolations) wall=\(String(format: "%.3f", Date().timeIntervalSince(started)))s")
        check("fixture meetings extracted with \(totalViolations) schema violations", totalViolations == 0)
        check("a scripted output did not match the grammar", model.outputs.allSatisfy { NotesExtraction.grammar.matches($0) })
        check("the follow-up prompt did not carry known subjects", model.prompts.last?.contains("\"pricing page launch\"") ?? false)
        let evening = Meeting(id: UUID(), title: "Evening", start: Date(timeIntervalSince1970: 1_789_696_800))  // 2026-09-18T02:00Z
        let losAngeles = KnowledgeExtractor.userPrompt(meeting: evening, notes: [], knownSubjects: [],
                                                       timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        check("the prompt's date is not the user's local day", losAngeles.contains("Date: 2026-09-17 (Thursday)"))
        check("the prompt lost its passage numbers", model.prompts.first?.contains("[3] (Decisions) Ship the pricing page on Friday.") ?? false)

        let nodes = (try? graph.nodeCounts()) ?? [:]
        let edges = (try? graph.edgeCounts()) ?? [:]
        print("EXTRACT_GRAPH nodes=\(nodes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")) "
              + "edges=\(edges.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
        check("nodes \(nodes)", nodes["Meeting"] == 3 && nodes["Decision"] == 4 && nodes["ActionItem"] == 2
                && nodes["OpenQuestion"] == 1 && nodes["Artifact"] == 1 && nodes["Topic"] == 1 && nodes["Person"] == 3)
        check("edges \(edges)", edges["supersedes"] == 1 && edges["decided_in"] == 4 && edges["owns"] == 2
                && edges["produced"] == 1 && edges["raised_in"] == 1 && (edges["attended"] ?? 0) == 5)
        check("an edge cites a chunk or node that does not exist", (try? graph.danglingEdges()) == 0)
        check("the index failed its integrity check", (try? store.integrityProblems()) == [])
        check("the graph is not available after extraction", graph.isAvailable)

        // MARK: Bi-temporal
        let threads = (try? graph.decisionThreads()) ?? []
        let launch = threads.first { $0.id == GraphStore.subjectKey("pricing page launch") }
        check("the launch thread has \(launch?.rows.count ?? 0) rows", launch?.rows.count == 2)
        check("the Friday decision was not closed when the follow-up reversed it",
              launch?.rows.first?.validTo == followUpStart && launch?.rows.first?.meetingID == pricing.uuidString)
        check("the reversal is not the current decision", launch?.rows.last?.isCurrent == true && launch?.wasReversed == true)
        check("an unrelated decision was closed",
              threads.filter { $0.id != launch?.id }.allSatisfy { $0.rows.allSatisfy(\.isCurrent) } && threads.count == 3)

        // MARK: The read tools, over the real graph
        if let context = indexer.toolContext, let expand = KnowledgeToolCatalogue.all.first(where: { $0.id == KnowledgeToolCatalogue.expandID }),
           let timeline = KnowledgeToolCatalogue.all.first(where: { $0.id == KnowledgeToolCatalogue.timelineID }) {
            let reversal = GraphIDs.owned("Decision", meetingID: followUpID.uuidString, ordinal: 0)
            let expanded = try? await KnowledgeGraphScope.$reader.withValue(.qwen35_4b) {
                try await KnowledgeToolExecutor.run(expand, arguments: ["node": reversal], context: context)
            }
            let cloud = try? await KnowledgeGraphScope.$reader.withValue(.openRouter) {
                try await KnowledgeToolExecutor.run(expand, arguments: ["node": reversal], context: context)
            }
            check("an OpenRouter reader read graph rows without consent",
                  context.graphCloudConsent == false && (cloud?.summary.contains("stays on this Mac") ?? false)
                    && !(cloud?.summary.contains("supersedes") ?? true))
            check("expand_node did not show the supersedes edge with its chunk",
                  (expanded?.summary.contains("\"type\":\"supersedes\"") ?? false)
                    && (expanded?.summary.contains("\"valid_from\"") ?? false) && (expanded?.summary.contains("\"source_chunk\":\"c") ?? false))
            let anaTimeline = try? await KnowledgeGraphScope.$reader.withValue(.qwen35_4b) {
                try await KnowledgeToolExecutor.run(timeline, arguments: ["entity": "Ana"], context: context)
            }
            check("timeline by a person's name found nothing", anaTimeline?.summary.contains("Pricing review") ?? false)
        } else {
            failures.append("the indexer offered no graph tools with the graph on")
        }

        // MARK: Idempotent re-extraction
        let dump = (try? graph.canonicalDump()) ?? []
        let notesJSONBytes = try? Data(contentsOf: directory(followUpID).appendingPathComponent(MeetingStore.notesJSONFile))
        do {
            let again = try await extractor.extract(meetingDirectory: directory(followUpID), model: model)
            check("re-extraction did not reuse notes.json", again.outcome == .reused && again.modelCalls == 0 && again.graph == .unchanged)
            let forced = try await extractor.extract(meetingDirectory: directory(followUpID), model: model, force: true)
            check("a forced re-extraction changed the graph", forced.outcome == .extracted && forced.graph == .unchanged)
            check("a forced re-extraction rewrote notes.json differently",
                  (try? Data(contentsOf: directory(followUpID).appendingPathComponent(MeetingStore.notesJSONFile))) == notesJSONBytes)
        } catch {
            failures.append("re-extraction threw: \(error.localizedDescription)")
        }
        for id in ordered { indexer.meetingChanged(id) }
        _ = await indexer.drain()
        check("re-extraction or a re-index changed the graph", (try? graph.canonicalDump()) == dump)

        // MARK: rm knowledge.sqlite rebuilds the same graph without a model
        let callsBefore = model.calls
        await indexer.rebuild()
        let rebuilt = (try? graph.canonicalDump()) ?? []
        check("a rebuild did not restore the graph from notes.json (\(rebuilt.count) rows, expected \(dump.count))", rebuilt == dump)
        check("a rebuild asked the model", model.calls == callsBefore)
        check("a rebuild left dangling edges", (try? graph.danglingEdges()) == 0)

        // MARK: Hostile output, item by item
        let hostile = ScriptedExtractionModel(fixed: hostileOutput(), enforcesGrammar: false)
        do {
            let report = try await extractor.extract(meetingDirectory: directory(hiring), model: hostile, force: true)
            for violation in report.violations { print("EXTRACT_HOSTILE_DROPPED \(violation)") }
            let reasons = report.violations.map(\.description).joined(separator: "\n")
            for expected in ["notes: unknown key", "cites passage 99, which does not exist", "not Decisions",
                             "text is empty", "longer than 400", "supersedes is not true or false", "unknown key colour",
                             "open_questions: missing", "cites passage 42"] {
                check("hostile output: no violation says \"\(expected)\"", reasons.contains(expected))
            }
            let stored = KnowledgeExtractor.read(directory(hiring).appendingPathComponent(MeetingStore.notesJSONFile))
            check("notes.json kept a dropped item: \(stored?.decisions.count ?? -1) decisions",
                  stored?.decisions.count == 1 && stored?.actionItems.isEmpty == true && stored?.topics.isEmpty == true)
            check("hostile output left dangling edges", (try? graph.danglingEdges()) == 0)
        } catch {
            failures.append("hostile output threw: \(error.localizedDescription)")
        }
        // MARK: A dropped item does not shift the ids of the ones kept
        let shifted = ScriptedExtractionModel(fixed: """
            {"decisions":[{"text":"From the summary.","subject":"ghost","supersedes":false,"said_by":null,"chunk":0},\
            {"text":"Open a second backend role before the budget review.","subject":"backend hiring","supersedes":false,"said_by":null,"chunk":1}],\
            "action_items":[],"open_questions":[],"topics":[{"label":"Hiring","chunks":[1]}]}
            """)
        do {
            let first = try await extractor.extract(meetingDirectory: directory(hiring), model: shifted, force: true)
            let afterFirst = (try? graph.canonicalDump()) ?? []
            let keptID = GraphIDs.owned("Decision", meetingID: hiring.uuidString, ordinal: 0)
            let droppedID = GraphIDs.owned("Decision", meetingID: hiring.uuidString, ordinal: 1)
            check("a dropped decision was not reported", first.violations.contains { $0.subject == "decisions[0]" })
            check("the kept decision was not numbered as notes.json numbers it",
                  afterFirst.contains { $0.contains(keptID) } && !afterFirst.contains { $0.contains(droppedID) })
            let reapplied = try extractor.applyStored(meetingDirectory: directory(hiring))
            check("applying notes.json after a dropped item replaced the graph (\(String(describing: reapplied.graph)))",
                  reapplied.outcome == .reused && reapplied.graph == .unchanged)
            let reused = try await extractor.extract(meetingDirectory: directory(hiring), model: shifted)
            check("re-extraction after a dropped item was not idempotent",
                  reused.outcome == .reused && reused.graph == .unchanged && (try? graph.canonicalDump()) == afterFirst)
        } catch {
            failures.append("shifted output threw: \(error.localizedDescription)")
        }
        let pretty = ScriptedExtractionModel(fixed: "{\n                    \"decisions\": [], \"action_items\": [], \"open_questions\": [], \"topics\": []}",
                                             enforcesGrammar: true)
        if let report = try? await extractor.extract(meetingDirectory: directory(hiring), model: pretty, force: true) {
            check("off-grammar output from a grammar model was not flagged",
                  report.violations.contains { $0.reason == "does not match the grammar" })
        } else {
            failures.append("valid JSON off the grammar threw")
        }
        _ = try? await extractor.extract(meetingDirectory: directory(hiring), model: model, force: true)
        check("re-extracting after hostile output did not restore the graph", (try? graph.canonicalDump()) == dump)

        // MARK: Not JSON: nothing changes
        let refusal = ScriptedExtractionModel(fixed: "I can't help with that.", enforcesGrammar: false)
        let hiringJSON = try? Data(contentsOf: directory(hiring).appendingPathComponent(MeetingStore.notesJSONFile))
        do {
            _ = try await extractor.extract(meetingDirectory: directory(hiring), model: refusal, force: true)
            failures.append("output that is not JSON did not throw")
        } catch let error as KnowledgeExtractionError {
            check("the wrong error for output that is not JSON", error == .unparseable("no JSON object"))
        } catch {
            failures.append("the wrong error for output that is not JSON: \(error)")
        }
        check("unparseable output changed the graph", (try? graph.canonicalDump()) == dump)
        check("unparseable output rewrote notes.json",
              (try? Data(contentsOf: directory(hiring).appendingPathComponent(MeetingStore.notesJSONFile))) == hiringJSON)

        // MARK: Reminder suggestions — offered, never created
        let items = (try? graph.actionItems()) ?? []
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let offered = ActionItemReminders.suggestions(items: items, userNames: [], resolved: [], now: followUpStart, calendar: utc)
        check("reminder suggestions \(offered.map(\.text))", offered.count == 1 && offered.first?.due == "2026-03-13")
        check("the suggestion's reminder is not a structured one-off at 9:00",
              offered.first?.reminderArguments == ["kind": "reminder", "title": "send the launch checklist to Sam by 2026-03-13",
                                                  "text": "send the launch checklist to Sam by 2026-03-13",
                                                  "repeat": "once", "date": "2026-03-13", "time": "09:00"])
        check("the suggestion's reminder fields do not parse as a schedule",
              offered.first.flatMap { try? ScheduleToolExecutor.parseWhen(
                  $0.reminderArguments, base: nil, now: followUpStart, timeZone: utc.timeZone) } != nil)
        check("Ana's action item was offered to the user", !offered.contains { $0.text.contains("publish") })
        check("a named user was not recognised", ActionItemReminders.isUser("Serge", names: ["serge"])
                && !ActionItemReminders.isUser("Ana", names: ["serge"]) && !ActionItemReminders.isUser(nil, names: []))
        check("a past due date was offered", ActionItemReminders.suggestions(
            items: items, userNames: [], resolved: [], now: followUpStart.addingTimeInterval(30 * 86_400), calendar: utc).isEmpty)
        check("an answered suggestion was offered again", ActionItemReminders.suggestions(
            items: items, userNames: [], resolved: Set(offered.map(\.id)), now: followUpStart, calendar: utc).isEmpty)
        check("a reminder was created without being asked", ScheduleStore.shared.schedules.count == schedulesBefore)

        // MARK: The .extracting stage, through the service
        let service = KnowledgeExtractionService(indexer: indexer)
        check("the service is off with the graph on", service.isEnabled)
        let meetingRecord = Meeting(id: hiring, title: "Hiring sync", start: KnowledgeFixtures.hiringStart)
        let serviceReport = await service.extract(meetingRecord, directory: directory(hiring), model: model, force: true)
        check("the service did not extract", serviceReport?.outcome == .extracted && service.revision == 1 && !service.isRunning(hiring))
        environment.settings.graph = false
        check("the service ran with the graph off",
              await service.extract(meetingRecord, directory: directory(hiring), model: model) == nil)
        environment.settings.graph = true

        // MARK: Regenerated notes drop the stale graph; the model restores it
        do {
            try followUpNotes.replacingOccurrences(of: "to Monday", with: "to Tuesday")
                .write(to: directory(followUpID).appendingPathComponent(MeetingStore.notesFile), atomically: true, encoding: .utf8)
            indexer.meetingChanged(followUpID)
            _ = await indexer.drain()
            let staleThreads = (try? graph.decisionThreads()) ?? []
            let staleLaunch = staleThreads.first { $0.id == GraphStore.subjectKey("pricing page launch") }
            check("regenerated notes kept the stale graph",
                  staleLaunch?.rows.count == 1 && staleLaunch?.rows.first?.isCurrent == true
                    && (try? graph.extractedMeetings().contains(followUpID.uuidString)) == false)
            let report = try await extractor.extract(meetingDirectory: directory(followUpID), model: model)
            check("regenerated notes were not extracted again", report.outcome == .extracted && report.violations.isEmpty)
            let fresh = ((try? graph.decisionThreads()) ?? []).first { $0.id == GraphStore.subjectKey("pricing page launch") }
            check("the new reversal did not close Friday again",
                  fresh?.rows.count == 2 && fresh?.rows.first?.validTo == followUpStart && fresh?.rows.last?.text.contains("Tuesday") == true)
        } catch {
            failures.append("regenerate threw: \(error.localizedDescription)")
        }

        // MARK: Deleting a meeting takes its graph
        indexer.removeMeeting(followUpID)
        let remaining = (try? graph.canonicalDump()) ?? []
        check("a deleted meeting left graph rows", !remaining.contains { $0.contains(followUpID.uuidString) })
        check("a person only the deleted meeting mentioned survived", !remaining.contains { $0.contains("person:sam@example.com") })
        let afterDelete = ((try? graph.decisionThreads()) ?? []).first { $0.id == GraphStore.subjectKey("pricing page launch") }
        check("Friday is not current again after the reversal was deleted",
              afterDelete?.rows.count == 1 && afterDelete?.rows.first?.isCurrent == true)

        // MARK: A meeting deleted while the app was closed takes its graph at the next backfill
        let hiringHadGraph = (try? graph.extractedMeetings().contains(hiring.uuidString)) == true
        try? FileManager.default.removeItem(at: directory(hiring))
        await indexer.backfill()
        let afterBackfill = (try? graph.canonicalDump()) ?? []
        check("backfill left the graph of a meeting deleted while closed",
              hiringHadGraph && !afterBackfill.contains { $0.contains(hiring.uuidString) }
                && (try? graph.extractedMeetings().contains(hiring.uuidString)) == false)

        // MARK: Switching the graph off
        do {
            try graph.deleteAll()
            check("deleteAll left rows", try graph.canonicalDump().isEmpty && !graph.isAvailable)
        } catch {
            failures.append("deleteAll threw: \(error.localizedDescription)")
        }
        return failures
    }

    static func reminderStoreFailures() -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-reminder-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures: [String] = []
        if ReminderSuggestionStore.shared.fileURL.path.hasPrefix(AppIdentity.applicationSupportDirectory.path) {
            failures.append("the shared reminder suggestion store is not isolated under a self-test")
        }
        let store = ReminderSuggestionStore(directory: directory)
        store.resolve("actionitem:x:0@2026-03-13")
        if ReminderSuggestionStore(directory: directory).resolved != ["actionitem:x:0@2026-03-13"] {
            failures.append("an answered suggestion did not persist")
        }
        return failures
    }

    static func hostileOutput() -> String {
        let long = String(repeating: "z", count: 500)
        return """
            Here you go:
            {"notes": 1,
             "decisions": [
              {"text": "Open a second backend role before the budget review.", "subject": "backend hiring", "supersedes": false, "said_by": null, "chunk": 1},
              {"text": "Invented.", "subject": "ghost", "supersedes": false, "chunk": 99},
              {"text": "From the summary.", "subject": "ghost", "supersedes": false, "chunk": 0},
              {"text": "  ", "subject": "blank", "supersedes": false, "chunk": 1},
              {"text": "\(long)", "subject": "long", "supersedes": false, "chunk": 1},
              {"text": "Yes-ish.", "subject": "flag", "supersedes": "yes", "chunk": 1},
              {"text": "Red.", "subject": "colour", "supersedes": false, "chunk": 1, "colour": "red"}
             ],
             "action_items": [{"text": "Review budget", "owner": "Ana", "due": "2026-02-30", "chunk": 1}],
             "topics": [{"label": "Hiring", "chunks": [1, 42]}]
            }
            """
    }

    /// Validates a `notes.json` on disk against the ontology's field rules, read-only.
    static func explain(_ path: String) {
        guard let extraction = KnowledgeExtractor.read(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else {
            print("EXTRACT_FILE unreadable: \(path)")
            return
        }
        var problems: [String] = []
        let ontology = Ontology.current
        func field(_ type: String, _ name: String, _ value: String?, _ subject: String) {
            guard let value, let fieldType = ontology.nodes[type]?.fields[name] else { return }
            if let problem = Ontology.problem(with: .text(value), as: fieldType) { problems.append("\(subject).\(name) \(problem)") }
        }
        for (index, decision) in extraction.decisions.enumerated() {
            field("Decision", "text", decision.text, "decisions[\(index)]")
            field("Decision", "subject", decision.subject, "decisions[\(index)]")
            field("Decision", "said_by", decision.saidBy, "decisions[\(index)]")
        }
        for (index, item) in extraction.actionItems.enumerated() {
            field("ActionItem", "text", item.text, "action_items[\(index)]")
            field("ActionItem", "owner", item.owner, "action_items[\(index)]")
            field("ActionItem", "due", item.due, "action_items[\(index)]")
        }
        for (index, question) in extraction.openQuestions.enumerated() {
            field("OpenQuestion", "text", question.text, "open_questions[\(index)]")
        }
        print("EXTRACT_FILE meeting=\(extraction.meetingID) generation=\(extraction.generation) items=\(extraction.itemCount) "
              + "violations=\(problems.count)")
        for problem in problems { print("EXTRACT_FILE_VIOLATION \(problem)") }
    }
}

/// Reads the numbered passages out of the prompt and answers the way a well-behaved model
/// would, deterministically — or returns a fixed string.
final class ScriptedExtractionModel: KnowledgeExtractionModel, @unchecked Sendable {
    let name = "scripted"
    let enforcesGrammar: Bool
    private let fixed: String?
    private let lock = NSLock()
    private var _calls = 0
    private var _outputs: [String] = []
    private var _prompts: [String] = []

    init(fixed: String? = nil, enforcesGrammar: Bool = true) {
        self.fixed = fixed
        self.enforcesGrammar = enforcesGrammar
    }

    var calls: Int { lock.withLock { _calls } }
    var outputs: [String] { lock.withLock { _outputs } }
    var prompts: [String] { lock.withLock { _prompts } }

    func generate(system: String, user: String, grammar: GBNFGrammar, maxTokens: Int) async throws -> String {
        let output = fixed ?? Self.answer(user)
        lock.withLock {
            _calls += 1
            _prompts.append(user)
            _outputs.append(output)
        }
        return output
    }

    static func answer(_ prompt: String) -> String {
        var decisions: [String] = []
        var actions: [String] = []
        var questions: [String] = []
        var pricingChunks: [Int] = []
        for line in prompt.components(separatedBy: "\n") {
            guard let match = line.firstMatch(of: /^\[(\d+)\] \(([^)]*)\) (.*)$/), let ordinal = Int(match.1) else { continue }
            let heading = String(match.2), text = String(match.3)
            if text.lowercased().contains("pricing") { pricingChunks.append(ordinal) }
            switch heading {
            case "Decisions":
                let lowered = text.lowercased()
                let subject = lowered.contains("pricing page") ? "pricing page launch"
                    : lowered.contains("budget owner") ? "launch ads budget"
                    : lowered.contains("backend role") ? "backend hiring" : "other"
                let supersedes = text.hasPrefix("Move")
                decisions.append(#"{"text":\#(json(text)),"subject":\#(json(subject)),"supersedes":\#(supersedes),"said_by":null,"chunk":\#(ordinal)}"#)
            case "Action items":
                let parts = text.components(separatedBy: " — ")
                let owner = parts.count > 1 ? json(parts[0]) : "null"
                let task = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : text
                let due = text.firstMatch(of: /by (\d{4}-\d{2}-\d{2})/).map { json(String($0.1)) } ?? "null"
                actions.append(#"{"text":\#(json(task)),"owner":\#(owner),"due":\#(due),"chunk":\#(ordinal)}"#)
            case "Open questions":
                questions.append(#"{"text":\#(json(text)),"chunk":\#(ordinal)}"#)
            default:
                continue
            }
        }
        let topics = pricingChunks.isEmpty ? "" : #"{"label":"Pricing","chunks":[\#(pricingChunks.prefix(8).map(String.init).joined(separator: ","))]}"#
        return #"{"decisions":[\#(decisions.joined(separator: ","))],"action_items":[\#(actions.joined(separator: ","))],"open_questions":[\#(questions.joined(separator: ","))],"topics":[\#(topics)]}"#
    }

    private static func json(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }
}
