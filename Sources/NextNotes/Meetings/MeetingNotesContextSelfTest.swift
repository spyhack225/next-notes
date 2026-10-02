import Foundation

/// `--selftest-notes-context`: the Related-context brief, end to end and without a model.
///
/// Four things have to hold, and each is a way the feature could be quietly wrong:
/// the brief is assembled from the right sources, under the right consent for the reader;
/// it is counted against the window rather than overflowing it; it never reaches the map
/// step or the search index, which stay transcript-only; and an empty brief leaves the old
/// prompt exactly as it was.
///
/// Every source is a fixture — no user memory, no index, no graph, no folders — and the two
/// providers record the prompts they are handed, so the assertions are about what the model
/// actually saw rather than about what a live store happened to contain.
@MainActor
enum MeetingNotesContextSelfTest {
    static func run(write: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let meeting = Meeting(
            id: UUID(),
            title: "Pricing review",
            start: Date(timeIntervalSince1970: 1_750_000_000),
            attendees: ["Sarah Chen", "ana@example.com"],
            status: .summarizing
        )
        let segment = TranscriptSegment(
            start: 0, end: 3, text: "We will ship the pricing page on Friday.", source: .mic
        )

        // The meeting's own chunks rank first, as they do on a Regenerate, and the stub
        // truncates to the requested limit like a real searcher — so asking for only
        // `passageLimit` would return three self-hits, filter all three away, and report no
        // connections while the library is full of them.
        let search = StubKnowledgeSearch(hits: [
            KnowledgeHit(
                chunkID: 1, kind: .notes, sourceID: meeting.id.uuidString, ordinal: 0,
                text: "This very meeting's own note.", snippet: "",
                startTime: nil, endTime: nil, speaker: nil, heading: "Summary",
                occurredAt: meeting.start, score: 1
            ),
            KnowledgeHit(
                chunkID: 2, kind: .transcript, sourceID: meeting.id.uuidString, ordinal: 1,
                text: "Also this meeting's own transcript.", snippet: "",
                startTime: nil, endTime: nil, speaker: "You", heading: nil,
                occurredAt: meeting.start, score: 2
            ),
            KnowledgeHit(
                chunkID: 3, kind: .notes, sourceID: meeting.id.uuidString, ordinal: 2,
                text: "And this meeting's own action item.", snippet: "",
                startTime: nil, endTime: nil, speaker: nil, heading: "Action items",
                occurredAt: meeting.start, score: 3
            ),
            KnowledgeHit(
                chunkID: 4, kind: .transcript, sourceID: UUID().uuidString, ordinal: 0,
                text: "We agreed the STEP export goes out before the pricing page.", snippet: "",
                startTime: nil, endTime: nil, speaker: "Sarah", heading: nil,
                occurredAt: meeting.start, score: 4
            ),
        ])

        func assembler(
            memory: Bool = true,
            graphConsent: Bool = false,
            fileConsent: Bool = false
        ) -> MeetingNotesContextAssembler {
            var assembler = MeetingNotesContextAssembler()
            assembler.memoryEnabled = { memory }
            assembler.recallMemory = { _, _ in
                (
                    [MemoryEntry(
                        kind: .profile,
                        text: "Sarah Chen leads pricing.",
                        source: .manual,
                        createdAt: meeting.start
                    )],
                    [NextMemoryItem(
                        kind: .project, key: "STEP", value: "STEP export project",
                        source: "self-test", updatedAt: meeting.start, useCount: 1
                    )]
                )
            }
            assembler.decisionThreads = {
                [
                    DecisionThread(
                        id: "pricing-page",
                        subject: "pricing page",
                        rows: [DecisionThreadRow(
                            id: "decision-1",
                            text: "Ship the pricing page after the export.",
                            saidBy: "Sarah",
                            meetingID: UUID().uuidString,
                            meetingTitle: "Weekly pricing sync",
                            observedAt: meeting.start.addingTimeInterval(-86_400 * 7),
                            validTo: nil,
                            sourceChunk: 1
                        )]
                    ),
                    DecisionThread(
                        id: "hiring-plan",
                        subject: "hiring plan",
                        rows: [DecisionThreadRow(
                            id: "decision-2",
                            text: "Hire two support engineers.",
                            saidBy: "Ana",
                            meetingID: UUID().uuidString,
                            meetingTitle: "Hiring sync",
                            observedAt: meeting.start,
                            validTo: nil,
                            sourceChunk: 2
                        )]
                    ),
                ]
            }
            assembler.graphCloudConsent = { graphConsent }
            assembler.relatedNodes = { _ in
                [
                    KnowledgeGraphNode(id: "person:ana", type: "Person", label: "Ana Ruiz",
                                       sourceChunk: 1),
                    KnowledgeGraphNode(id: "project:pricing", type: "Project", label: "Pricing page",
                                       sourceChunk: 2),
                ]
            }
            assembler.filesCloudConsent = { fileConsent }
            assembler.files = {
                StubFileRetrieval(hits: [FileHit(
                    path: "/Users/test/Documents/pricing-deck.key",
                    name: "pricing-deck.key",
                    isDirectory: false,
                    category: .presentation,
                    size: 4_096,
                    modifiedAt: meeting.start,
                    accessedAt: nil,
                    root: "/Users/test/Documents",
                    depth: 1
                )])
            }
            assembler.knowledge = {
                KnowledgeToolContext(
                    searcher: search,
                    sourceTitle: { _ in "Past pricing sync" }
                )
            }
            return assembler
        }

        // MARK: Assembly and the consent gates

        let full = await assembler().brief(for: meeting, reader: .appLLM)
        check("memory was missing", full.memory.contains("Sarah Chen leads pricing."))
        check("activity was missing", full.memory.contains("STEP export project"))
        check("the matching decision was missing", full.decisions.contains("pricing page"))
        check("an unrelated decision was included", !full.decisions.contains("hiring plan"))
        check("a graph connection was missing", full.connections.contains("Person: Ana Ruiz"))
        check("the passage was missing", full.passages.contains("export goes out"))
        check("the meeting cited itself", !full.passages.contains("very meeting's own note")
            && !full.passages.contains("own transcript")
            && !full.passages.contains("own action item"))
        check("a file was missing", full.files.contains("pricing-deck.key"))
        check("the passage search asked for too few to survive its own filter",
              (search.queries.first?.limit ?? 0) > MeetingNotesContextAssembler.passageLimit)
        check("the intended sources were not reported",
              full.sources == ["memory", "decisions", "connections", "passages", "files"])

        let cloud = await assembler().brief(for: meeting, reader: .openRouter)
        check("the graph reached a cloud reader without consent", cloud.decisions.isEmpty)
        check("connections reached a cloud reader without consent", cloud.connections.isEmpty)
        check("files reached a cloud reader without consent", cloud.files.isEmpty)
        check("passages were withheld from a cloud reader", cloud.passages.contains("export goes out"))

        let consented = await assembler(graphConsent: true, fileConsent: true)
            .brief(for: meeting, reader: .openRouter)
        check("graph consent had no effect", consented.decisions.contains("pricing page"))
        check("graph consent did not add connections", consented.connections.contains("Ana Ruiz"))
        check("file consent had no effect", consented.files.contains("pricing-deck.key"))

        let noMemory = await assembler(memory: false).brief(for: meeting, reader: .appLLM)
        check("memory ignored its switch", noMemory.memory.isEmpty)
        check("another source was lost with memory", !noMemory.decisions.isEmpty)

        var emptySources = MeetingNotesContextAssembler()
        emptySources.memoryEnabled = { false }
        emptySources.decisionThreads = { [] }
        emptySources.knowledge = { nil }
        emptySources.files = { EmptyFileRetrieval() }
        let none = await emptySources.brief(for: meeting, reader: .appLLM)
        check("an empty brief did not stay empty", none.isEmpty && none.promptBlock.isEmpty && none.sources.isEmpty)

        // MARK: Upcoming events and reader-sized context (P4-04a)

        let explicitDefault = await assembler().brief(for: meeting, reader: .appLLM,
                                                       contextTokens: 8_192)
        let zeroWindow = await assembler().brief(for: meeting, reader: .appLLM,
                                                  contextTokens: 0)
        let upcoming = await assembler().brief(forEvent: meeting.title,
            attendees: meeting.attendees, excluding: meeting.id, reader: .appLLM)
        check("the explicit default window changed the original brief", explicitDefault == full)
        check("a zero window changed the default brief", zeroWindow == full)
        check("the event path changed the recorded meeting brief", upcoming == full)
        let noExclusion = await assembler().brief(forEvent: meeting.title,
            attendees: meeting.attendees, reader: .appLLM)
        check("an upcoming event invented an exclusion identity",
              noExclusion.passages.contains("very meeting's own note"))
        let whitespaceEvent = await assembler().brief(forEvent: "  \n ", attendees: [" "],
                                                       reader: .appLLM, contextTokens: 32_768)
        check("a nameless event produced context", whitespaceEvent == .empty)
        let emptyLarge = await emptySources.brief(for: meeting, reader: .appLLM,
                                                   contextTokens: 32_768)
        check("an empty source gained context at a larger window", emptyLarge == .empty)

        let denseMemory = (0..<8).map { index in
            MemoryEntry(kind: .profile,
                text: "pricing memory \(index): " + String(repeating: "detail ", count: 20),
                source: .manual, createdAt: meeting.start)
        }
        let denseThreads = (0..<20).map { index in
            DecisionThread(id: "pricing-\(index)", subject: "pricing \(index)",
                rows: [DecisionThreadRow(id: "dense-\(index)",
                    text: "decision \(index): " + String(repeating: "detail ", count: 10),
                    saidBy: "Sarah", meetingID: "earlier-\(index)", meetingTitle: "Past pricing",
                    observedAt: meeting.start.addingTimeInterval(-Double(index + 1)),
                    validTo: nil, sourceChunk: Int64(index + 1))])
        }
        let denseNodes = (0..<30).map { index in
            KnowledgeGraphNode(id: "dense-person-\(index)", type: "Person",
                label: "pricing connection \(index): " + String(repeating: "name ", count: 5),
                sourceChunk: Int64(index + 1))
        }
        let denseHits = (0..<50).map { index in
            KnowledgeHit(chunkID: Int64(index + 1), kind: .notes,
                sourceID: index < 3 ? meeting.id.uuidString : "past-\(index)", ordinal: index,
                text: "pricing passage \(index)", snippet: "", startTime: nil, endTime: nil,
                speaker: nil, heading: "Summary", occurredAt: meeting.start, score: Double(index))
        }
        let denseFiles = (0..<25).map { index in
            FileHit(path: "/fixture/pricing-\(index).txt", name: "pricing-\(index).txt",
                isDirectory: false, category: .document, size: 100,
                modifiedAt: meeting.start, accessedAt: nil, root: "/fixture", depth: 1)
        }
        let denseSearch = StubKnowledgeSearch(hits: denseHits)
        let denseFileReader = StubFileRetrieval(hits: denseFiles)
        var denseAssembler = assembler()
        denseAssembler.recallMemory = { _, _ in (denseMemory, []) }
        denseAssembler.decisionThreads = { denseThreads }
        denseAssembler.relatedNodes = { _ in denseNodes }
        denseAssembler.knowledge = {
            KnowledgeToolContext(searcher: denseSearch, sourceTitle: { _ in "Past pricing" })
        }
        denseAssembler.files = { denseFileReader }
        let denseDefault = await denseAssembler.brief(for: meeting, reader: .appLLM)
        let denseLarge = await denseAssembler.brief(for: meeting, reader: .appLLM,
                                                    contextTokens: 32_768)
        for (name, small, large) in [
            ("memory", denseDefault.memory, denseLarge.memory),
            ("decisions", denseDefault.decisions, denseLarge.decisions),
            ("connections", denseDefault.connections, denseLarge.connections),
            ("passages", denseDefault.passages, denseLarge.passages),
            ("files", denseDefault.files, denseLarge.files)
        ] {
            check("the large reader did not retain more \(name)", large.count > small.count)
        }
        check("the default passage fetch changed", denseSearch.queries.first?.limit == 10)
        check("the trusted reader fetch was still clamped to the tool limit",
              denseSearch.queries.last?.limit == 40)
        check("the default file request changed", denseFileReader.requests.first?.limit == 5)
        check("the large reader did not request more files", denseFileReader.requests.last?.limit == 20)
        let passageRows = denseLarge.passages.data(using: .utf8).flatMap {
            try? JSONDecoder().decode([[String: String]].self, from: $0)
        }
        check("the reader-scaled passage count did not stop at twelve", passageRows?.count == 12)
        check("the fixture returned more files than the request",
              !denseLarge.files.contains("pricing-20.txt"))
        check("file search started using attendee names", denseFileReader.requests.allSatisfy {
            $0.query == meeting.title
        })
        check("reader-scaled memory exceeded its cap", denseLarge.memory.count <= 700 * 4)
        check("reader-scaled decisions exceeded their cap", denseLarge.decisions.count <= 500 * 4)
        check("reader-scaled connections exceeded their cap", denseLarge.connections.count <= 400 * 4)
        check("reader-scaled passages exceeded their cap", denseLarge.passages.count <= 900 * 4)
        check("large passages included the excluded meeting", !denseLarge.passages.contains("passage 0"))
        let publicQuery = try? KnowledgeToolExecutor.searchQuery(
            ["query": "pricing", "limit": "40"],
            context: KnowledgeToolContext(searcher: denseSearch))
        check("the public tool's 20-hit bound changed", publicQuery?.limit == 20)

        let longHit = KnowledgeHit(chunkID: 99, kind: .notes, sourceID: "past-long",
            ordinal: 0, text: String(repeating: "x", count: 400) + "END_OF_LONG_PASSAGE",
            snippet: "", startTime: nil, endTime: nil, speaker: nil, heading: nil,
            occurredAt: meeting.start, score: 1)
        var longAssembler = denseAssembler
        longAssembler.knowledge = {
            KnowledgeToolContext(searcher: StubKnowledgeSearch(hits: [longHit]))
        }
        let longDefault = await longAssembler.brief(for: meeting, reader: .appLLM)
        let longLarge = await longAssembler.brief(for: meeting, reader: .appLLM,
                                                  contextTokens: 32_768)
        check("the default passage text limit changed",
              !longDefault.passages.contains("END_OF_LONG_PASSAGE"))
        check("the passage text limit did not scale with the reader",
              longLarge.passages.contains("END_OF_LONG_PASSAGE"))

        let wideCloud = await denseAssembler.brief(forEvent: meeting.title,
            attendees: meeting.attendees, excluding: meeting.id, reader: .openRouter,
            contextTokens: 32_768)
        check("scaled event graph bypassed cloud consent",
              wideCloud.decisions.isEmpty && wideCloud.connections.isEmpty)
        check("scaled event files bypassed cloud consent", wideCloud.files.isEmpty)

        // Drive the real consumers with the same instance-local assembler. A nonlocal
        // fixture provider has an explicit window, so resident GGUF state cannot replace it.
        let originalRelated = Settings.shared.notesRelatedContext
        defer { Settings.shared.notesRelatedContext = originalRelated }
        Settings.shared.notesRelatedContext = true
        let contextStore = MeetingStore.isolated()
        check("context consumer fixture did not save its meeting", contextStore.save(meeting))
        let reader = RecordingNotesProvider(contextTokens: 32_768, id: .appleFoundation)
        let notesConsumer = NotesService(store: contextStore, providerResolver: { _ in reader },
                                         contextAssembler: denseAssembler)
        let agentConsumer = AgentService(store: contextStore, contextAssembler: denseAssembler)
        let notesContext = await notesConsumer.notesBrief(for: meeting, provider: reader)
        let agentContext = await agentConsumer.knownContext(for: meeting, provider: reader)
        check("the notes consumer lost the actual reader window", notesContext == denseLarge)
        check("the agent consumer lost the actual reader window", agentContext == denseLarge)
        let generatedModel = await notesConsumer.generate(for: meeting, segments: [segment])
        check("the actual notes consumer did not run its provider", generatedModel != nil)
        check("the actual notes provider did not receive the scaled brief",
              reader.calls.first?.user.contains(denseLarge.promptBlock) == true)
        check("the actual notes consumer did not save its result",
              contextStore.freshReaderForTesting().notes(for: meeting.id)?.contains("## Summary") == true)
        check("the context consumer changed capture integrity",
              contextStore.freshReaderForTesting().meeting(id: meeting.id)?.captureIntegrity == meeting.captureIntegrity)
        Settings.shared.notesRelatedContext = false
        let offNotes = await notesConsumer.notesBrief(for: meeting, provider: reader)
        let offAgent = await agentConsumer.knownContext(for: meeting, provider: reader)
        check("the actual notes consumer ignored its switch", offNotes == .empty)
        check("the actual agent consumer ignored its switch", offAgent == .empty)
        Settings.shared.notesRelatedContext = originalRelated

        // MARK: The prompt and the formatter

        check("Related context is not the last heading", NotesPrompts.headings.last == "Related context")
        let withBrief = NotesPrompts.notesUser(meeting: meeting, transcript: "x", brief: full)
        check("the brief missed the single-pass prompt", withBrief.contains("Known context about the user"))
        let withoutBrief = NotesPrompts.notesUser(meeting: meeting, transcript: "x")
        check("an empty brief changed the prompt", !withoutBrief.contains("Known context"))

        let model = NotesPrompts.headings.map { heading in
            "## \(heading)\n\(heading == "Summary" ? "One sentence." : NotesPrompts.emptyMarker)"
        }.joined(separator: "\n\n")
        let tidied = NotesFormatter.tidy(model)
        check("tidy dropped a section", NotesPrompts.headings.allSatisfy { tidied.contains("## \($0)") })
        if let related = tidied.range(of: "## Related context"),
           let questions = tidied.range(of: "## Open questions") {
            check("tidy reordered the sections", related.lowerBound > questions.lowerBound)
        } else {
            check("tidy lost the new section's position", false)
        }

        // MARK: The window is shared

        var big = MeetingNotesBrief()
        big.memory = "related: " + String(repeating: "x", count: 1_000)

        // M-12 counts the prompt overhead in the single-pass decision, so the
        // transcript is sized against the new boundary: alone it fits
        // (1,704 tokens + the counted ~715 overhead ≤ 2,464), the brief pushes it over.
        let long = TranscriptSegment(
            start: 0,
            end: 600,
            text: String(repeating: "a", count: 6_800),
            source: .mic
        )
        let budgetProvider = RecordingNotesProvider(contextTokens: 4_000)
        let without = try? await NotesGenerator(provider: budgetProvider)
            .notes(for: meeting, segments: [long])
        let budget = 4_000 - 1_536
        let counted = try? await NotesGenerator(provider: budgetProvider)
            .notes(for: meeting, segments: [long], brief: big)
        check("the transcript did not fit one pass without the brief", without?.usedMapReduce == false)
        check("the brief was not counted against the window", counted?.usedMapReduce == true)
        check("the transcript was already over budget", (try? await budgetProvider.countTokens(
            [long].plainText(speakerNames: meeting.speakerNames)
        )).map { $0 <= budget } ?? false)

        let mapCalls = budgetProvider.calls.filter { $0.system == NotesPrompts.mapSystem }
        check("the map step was never run", !mapCalls.isEmpty)
        check("the map step saw the brief", mapCalls.allSatisfy { !$0.user.contains("Known context") })
        check("the reduce step lost the brief", budgetProvider.calls.last?.user.contains("Known context") == true)

        let singleProvider = RecordingNotesProvider(contextTokens: 8_000)
        let single = try? await NotesGenerator(provider: singleProvider)
            .notes(for: meeting, segments: [segment], brief: big)
        check("a small meeting was chunked", single?.usedMapReduce == false)
        check("the single pass missed the brief", singleProvider.calls.first?.user.contains("Known context") == true)
        check("the notes lost the new section", single?.markdown.contains("## Related context") == true)
        check("a grounded connection was dropped", single?.markdown.contains("aligns with known concerns") == true)

        // The live first run had Apple's model write a connection with no block to connect
        // to. The prompt rule lost to the model; a deterministic stage has to win.
        let ungroundedProvider = RecordingNotesProvider(contextTokens: 8_000)
        let ungrounded = try? await NotesGenerator(provider: ungroundedProvider)
            .notes(for: meeting, segments: [segment])
        check("an invented connection survived with no brief",
              ungrounded?.markdown.contains("aligns with known concerns") == false)
        check("an empty Related context was not marked",
              ungrounded?.markdown.contains("## Related context\n\(NotesPrompts.emptyMarker)") == true)
        check("emptying the new section broke the summary",
              ungrounded?.markdown.contains("## Summary\nOne sentence.") == true)

        let invented = """
            ## Summary
            One.

            ## Related context
            - a connection to nothing

            ## Open questions
            _None._
            """
        let emptied = NotesFormatter.emptySection(NotesPrompts.relatedHeading, in: invented)
        check("emptySection kept an invented connection", !emptied.contains("a connection to nothing"))
        check("emptySection damaged another section", emptied.contains("One."))
        check("emptySection replaced the wrong section", emptied.contains("## Open questions\n_None._"))

        // MARK: The index keeps its distance

        let markdown = """
            ## Summary
            We discussed pricing.

            ## Related context
            - Sarah Chen leads pricing at Acme.

            ## Action items
            - **Sarah** — send the export.
            """
        let chunks = Chunker.notes(markdown, meetingStart: meeting.start)
        check("Related context was indexed", !chunks.contains { $0.text.contains("leads pricing at Acme") })
        check("a real section was dropped", chunks.contains { $0.text.contains("send the export") })
        check("the skipped section leaked its heading", !chunks.contains { $0.heading == "Related context" })

        let review = AgentPrompts.review(meeting: meeting, notes: "n", transcript: "t", brief: full.promptBlock)
        check("the brief missed the follow-up review", review.contains("Known context about the user"))
        check("the brief replaced the transcript", review.contains("Transcript:\nt"))

        for failure in failures { write("  NOTES_CONTEXT_WRONG: \(failure)") }
        write(failures.isEmpty
              ? "NOTES_CONTEXT_OK: assembly, consent gates, window accounting, map purity and index safety hold"
              : "NOTES_CONTEXT_FAILED: \(failures.count) rule(s) wrong")
        return failures.isEmpty
    }
}

/// `--notes-context-live`: assembles the brief for the newest meeting with a transcript,
/// against this machine's own memory, index, graph and file index, and prints it.
///
/// Read-only, and no model is loaded — the provider is resolved through the same
/// `ModelRoleStore` seam production uses, then only its `id` is read.
///
/// It is deliberately **not** a `--selftest-*` flag. The self-test harness isolates every
/// store by design — `KnowledgeIndexer.shared` gets a temp index with the feature off and
/// `NextMemory.shared` a temp memory — and `NotesModelRuntime` refuses to adopt the saved
/// model, so a probe run under `SelfTest.isRunning` prints an empty brief and Apple's model
/// on a machine whose index is full and whose notes run on a downloaded one. That is a
/// green-looking answer to a question nobody asked, so this one has to run outside the
/// harness. `_EMPTY` is data, not a failure: a machine whose index is off or whose meeting
/// names match nothing legitimately has nothing to connect. It fails only when the
/// production path cannot run at all.
@MainActor
enum MeetingNotesContextLiveProbe {
    static func run(write: (String) -> Void) async -> Bool {
        guard Settings.shared.notesRelatedContext else {
            write("NOTES_CONTEXT_LIVE_DISABLED: Connect notes to what Next Notes knows is off")
            return true
        }
        guard let meeting = MeetingStore.shared.meetings
            .filter({ !MeetingStore.shared.transcript(for: $0.id).isEmpty })
            .max(by: { $0.start < $1.start }) else {
            write("NOTES_CONTEXT_LIVE_FAILED: no meeting with a transcript to probe")
            return false
        }
        guard let provider = await ModelRoleStore.shared.provider(for: .meetingNotes) else {
            write("NOTES_CONTEXT_LIVE_FAILED: the meeting-notes role resolved to no provider")
            return false
        }
        let query = MeetingNotesContextAssembler.query(for: meeting)
        let brief = await MeetingNotesContextAssembler.live.brief(for: meeting, reader: provider.id)
        write("""
            NOTES_CONTEXT_LIVE: meeting="\(meeting.title)" provider="\(provider.displayModelName)" \
            query="\(query)" sources=[\(brief.sources.joined(separator: ","))] \
            chars=\(brief.promptBlock.count)
            """)
        if brief.isEmpty {
            write("NOTES_CONTEXT_LIVE_EMPTY: nothing matched the meeting's own names")
        } else {
            write(brief.promptBlock)
        }
        return true
    }
}

// MARK: - Fixtures

/// Returns fixed hits, truncated to the query's own limit like a real searcher, and records
/// what it was asked for. Truncating is what lets the test catch the fetch limit: with three
/// self-hits ahead of the only other meeting's, a fetch of three starves the section.
private final class StubKnowledgeSearch: KnowledgeSearching, @unchecked Sendable {
    let hits: [KnowledgeHit]

    private let lock = NSLock()
    private var recorded: [KnowledgeQuery] = []

    init(hits: [KnowledgeHit] = []) {
        self.hits = hits
    }

    var queries: [KnowledgeQuery] { lock.withLock { recorded } }

    func search(_ query: KnowledgeQuery) throws -> [KnowledgeHit] {
        lock.withLock { recorded.append(query) }
        return Array(hits.prefix(query.limit))
    }

    func facets(_ query: KnowledgeQuery) throws -> KnowledgeFacets { KnowledgeFacets() }
    func prepare(_ query: KnowledgeQuery) async -> KnowledgeQuery { query }
}

private final class StubFileRetrieval: FileRetrieving, @unchecked Sendable {
    let hits: [FileHit]
    private let lock = NSLock()
    private var recorded: [(query: String, limit: Int)] = []
    var requests: [(query: String, limit: Int)] { lock.withLock { recorded } }

    init(hits: [FileHit] = []) { self.hits = hits }

    var isAvailable: Bool { true }
    var folders: [String] { ["/Users/test/Documents"] }

    func find(query: String, category: FileCategory?, folder: String?, modifiedAfter: Date?,
              limit: Int) throws -> [FileHit] {
        lock.withLock { recorded.append((query, limit)) }
        return Array(hits.prefix(limit))
    }
    func tree(path: String, depth: Int, limit: Int) throws -> (hits: [FileHit], total: Int) { ([], 0) }
}

/// Records every prompt it is handed; answers facts to the map step and a complete document
/// to everything else, so `NotesFormatter.isBlank` is never what fails the test.
private final class RecordingNotesProvider: LLMProvider, @unchecked Sendable {
    let id: LLMProviderID
    let contextTokens: Int

    private let lock = NSLock()
    private var recorded: [(system: String, user: String)] = []

    init(contextTokens: Int, id: LLMProviderID = .appLLM) {
        self.contextTokens = contextTokens
        self.id = id
    }

    var calls: [(system: String, user: String)] {
        lock.withLock { recorded }
    }

    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        lock.withLock { recorded.append((system, user)) }
        if system == NotesPrompts.mapSystem {
            return LLMCompletion(
                text: "- Sarah: will send the STEP export.",
                generatedTokens: 9,
                duration: 0
            )
        }
        let markdown = NotesPrompts.headings.map { heading in
            if heading == "Summary" { return "## \(heading)\nOne sentence." }
            if heading == NotesPrompts.relatedHeading {
                // What Apple's model actually wrote when no block was in the message.
                return "## \(heading)\n- It aligns with known concerns."
            }
            return "## \(heading)\n\(NotesPrompts.emptyMarker)"
        }.joined(separator: "\n\n")
        return LLMCompletion(text: markdown, generatedTokens: 40, duration: 0)
    }
}
