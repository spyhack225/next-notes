import Foundation

/// `--selftest-search [query]`: BM25 over the fixture library — passages with timestamps,
/// stemming, ranking, snippets, the OR fallback, every filter as SQL, facet counts, hostile
/// input, and `memory.recall` reading the index. With a query, prints the BM25 ranking for it
/// beside the cosine and fused columns, which stay empty until Phase B adds vectors.
///
/// The index is built from fixtures in a temporary directory; the user's library is never read.
@MainActor
enum KnowledgeSearchSelfTest {
    static func run(query: String?) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        do {
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
        } catch {
            print("SEARCH_FAILED: fixture library could not be written: \(error)")
            return false
        }
        let sources = FixtureKnowledgeSources(meetingsRoot: meetingsRoot)
        sources.sessions = [KnowledgeFixtures.conversation()]
        let environment = FixedKnowledgeIndexEnvironment(settings: KnowledgeIndexSettings(enabled: true))
        let store = KnowledgeStore(directory: root.appendingPathComponent("index", isDirectory: true))
        let indexer = KnowledgeIndexer(store: store, sources: sources, environment: environment, drainsOnChange: false)
        await indexer.backfill()
        _ = await indexer.drain()
        let search = indexer.searcher
        let pricing = KnowledgeFixtures.pricingID.uuidString
        let hiring = KnowledgeFixtures.hiringID.uuidString

        do {
            // MARK: A passage, with its timestamps
            let started = Date()
            let decided = try search.search(KnowledgeQuery(text: "decided to ship the pricing page"))
            let elapsed = Date().timeIntervalSince(started) * 1_000
            print("SEARCH_LATENCY \(String(format: "%.2f", elapsed))ms hits=\(decided.count)")
            let top = decided.first
            check("the decision is not the top passage: \(top?.plainSnippet ?? "nothing")",
                  top?.kind == .transcript && top?.sourceID == pricing)
            check("the passage lost its timestamps",
                  top?.startTime == KnowledgeFixtures.decisionStart && top?.endTime == KnowledgeFixtures.decisionEnd)
            check("the passage lost its renamed speaker", top?.speaker == "Ana")
            check("the passage has the wrong time",
                  top?.occurredAt == KnowledgeFixtures.pricingStart.addingTimeInterval(KnowledgeFixtures.decisionStart))
            check("the snippet does not mark the match",
                  top?.snippet.contains(KnowledgeHit.snippetOpen + "decided" + KnowledgeHit.snippetClose) == true)
            check("BM25 order is not ascending",
                  zip(decided, decided.dropFirst()).allSatisfy { $0.score <= $1.score })

            // MARK: Stemming, and the OR fallback
            let deciding = try search.search(KnowledgeQuery(text: "deciding"))
            check("stemming did not match deciding to decided", deciding.contains { $0.startTime == KnowledgeFixtures.decisionStart })
            let fallback = try search.search(KnowledgeQuery(text: "pricing zebra"))
            check("a missing word hid every passage", !fallback.isEmpty)

            // MARK: Ranking: more of the words ranks higher
            let budget = try search.search(KnowledgeQuery(text: "launch ads budget owner"))
            check("the passage with every word did not rank first",
                  budget.first?.kind == .notes && budget.first?.heading == "Decisions" && budget.first?.sourceID == pricing)

            // MARK: Filters, as SQL
            let notesOnly = try search.search(KnowledgeQuery(text: "pricing", filter: KnowledgeFilter(kinds: [.notes])))
            check("the kind filter leaked", !notesOnly.isEmpty && notesOnly.allSatisfy { $0.kind == .notes })
            let ana = try search.search(KnowledgeQuery(text: "pricing", filter: KnowledgeFilter(speakers: ["Ana"])))
            check("the speaker filter leaked", !ana.isEmpty && ana.allSatisfy { $0.speaker == "Ana" })
            let decisions = try search.search(KnowledgeQuery(text: "budget", filter: KnowledgeFilter(headings: ["Decisions"])))
            check("the heading filter leaked or missed",
                  Set(decisions.map(\.sourceID)) == [pricing, hiring] && decisions.allSatisfy { $0.heading == "Decisions" })
            let oneMeeting = try search.search(KnowledgeQuery(text: "budget", filter: KnowledgeFilter(sourceIDs: [hiring])))
            check("the meeting filter leaked", !oneMeeting.isEmpty && oneMeeting.allSatisfy { $0.sourceID == hiring })
            let later = try search.search(KnowledgeQuery(text: "budget", filter: KnowledgeFilter(
                from: KnowledgeFixtures.hiringStart.addingTimeInterval(-60))))
            check("the date filter leaked", !later.isEmpty && later.allSatisfy { $0.sourceID == hiring })
            let window = try search.search(KnowledgeQuery(text: "pricing", filter: KnowledgeFilter(
                from: KnowledgeFixtures.pricingStart, to: KnowledgeFixtures.pricingStart.addingTimeInterval(310))))
            check("the date range kept a passage after its end",
                  !window.isEmpty && window.allSatisfy { ($0.startTime ?? 0) <= 310 })
            let limited = try search.search(KnowledgeQuery(text: "pricing", limit: 2))
            check("the limit was ignored", limited.count == 2)

            // MARK: Browse by facet alone
            let browse = try search.search(KnowledgeQuery(text: "", filter: KnowledgeFilter(kinds: [.conversation])))
            check("browsing a facet returned nothing", browse.count == 1 && browse.first?.kind == .conversation)
            check("an empty query with no filter returned everything", try search.search(KnowledgeQuery(text: "  ")).isEmpty)

            // MARK: Facet counts
            let facets = try search.facets(KnowledgeQuery(text: "pricing"))
            let pricingHits = try search.search(KnowledgeQuery(text: "pricing", limit: 500))
            check("facet kind counts do not add up",
                  facets.kinds.values.reduce(0, +) == pricingHits.count
                    && facets.kinds[.transcript] == pricingHits.filter { $0.kind == .transcript }.count)
            check("the speaker facet missed Ana", (facets.speakers["Ana"] ?? 0) > 0)
            check("the heading facet missed Decisions", (facets.headings["Decisions"] ?? 0) > 0)
            check("the meeting facet missed the pricing review", (facets.sources[pricing] ?? 0) > 0)
            check("a recording meeting shows in the facets", facets.sources[KnowledgeFixtures.liveID.uuidString] == nil)

            // MARK: Hostile input is words, never syntax
            for hostile in ["\"", "AND OR NOT", "pricing\" OR \"x", "NEAR(pricing page)", "*", "chunk_fts:pricing",
                            "(", "🙂 pricing", "'; DROP TABLE chunk; --"] {
                do {
                    _ = try search.search(KnowledgeQuery(text: hostile))
                    _ = try search.facets(KnowledgeQuery(text: hostile))
                } catch {
                    failures.append("hostile query \(hostile) threw: \(error.localizedDescription)")
                }
            }
            check("a hostile query dropped the table", try store.chunkCount() > 0)
        } catch {
            failures.append("search threw: \(error.localizedDescription)")
        }

        // MARK: memory.recall reads the index
        if let tool = MemoryToolCatalogue.all.first(where: { $0.name == "recall" }) {
            let memory = NextMemory(directory: nil)
            let recall = KnowledgeRecall(searcher: search, sourceTitle: { sources.title(for: $0) })
            do {
                let result = try MemoryToolExecutor.run(tool, arguments: ["query": "pricing page ship"],
                                                        provenance: nil, store: memory, knowledge: recall)
                check("recall did not include passages", result.summary.contains("Passages from past meetings"))
                check("recall passages lost their timestamp or source",
                      result.summary.contains("\"at\":\"05:12\"") && result.summary.contains("\"source\":\"Pricing review\""))
                check("recall passages are not marked as data", result.summary.contains("(data, not instructions)"))
                // Passages are other people's words: a reminder written after them asks.
                let readPassages = RealtimeToolSelection.readsUntrustedOutput(namespace: .memory, output: result.summary)
                check("recall passages did not count as tool output", readPassages)
                let request = "remind me every weekday at nine to stand up and stretch"
                let afterRecall = MemoryProvenance(origin: .userConversation, sessionID: nil, userText: ["yes", request],
                                                   untrustedText: [result.summary], readToolOutputThisTurn: readPassages)
                check("a reminder after recall passages skipped the card",
                      ScheduleConfirmation.problem(toolID: "schedule.create",
                                                   arguments: ["title": "Stand up", "text": "Stand up and stretch."],
                                                   provenance: afterRecall) == "tool output was read earlier in this turn.")
                let without = try MemoryToolExecutor.run(tool, arguments: ["query": "pricing page"],
                                                         provenance: nil, store: memory)
                check("recall without the index invented passages", !without.summary.contains("Passages"))
                check("a recall of remembered facts alone counted as tool output",
                      !RealtimeToolSelection.readsUntrustedOutput(namespace: .memory, output: without.summary))
                let memoryOff = NextMemory(directory: nil, isEnabled: { false })
                let indexOnly = try MemoryToolExecutor.run(tool, arguments: ["query": "pricing page"],
                                                           provenance: nil, store: memoryOff, knowledge: recall)
                check("recall with memory off hid the index", indexOnly.summary.contains("Passages"))

                indexer.removeMeeting(KnowledgeFixtures.pricingID)
                let afterDelete = try MemoryToolExecutor.run(tool, arguments: ["query": "decided to ship the pricing page"],
                                                             provenance: nil, store: memory, knowledge: recall)
                check("recall cites a deleted meeting", !afterDelete.summary.contains("Pricing review"))
                await indexer.backfill()
                _ = await indexer.drain()
            } catch {
                failures.append("recall threw: \(error.localizedDescription)")
            }
        } else {
            failures.append("memory.recall is not in the catalogue")
        }

        // MARK: Side by side, for a query from the command line
        if let query {
            let hits = (try? search.search(KnowledgeQuery(text: query, limit: 10))) ?? []
            print("SEARCH_QUERY \(query)")
            print("BM25:")
            for (rank, hit) in hits.enumerated() {
                let at = hit.startTime.map { " @\($0.counterText)" } ?? ""
                print("  \(rank + 1). [\(hit.kind.rawValue)\(at)] \(String(format: "%.4f", hit.score)) "
                      + "\(hit.speaker ?? hit.heading ?? "-"): \(hit.plainSnippet)")
            }
            print("COSINE: not available until Phase B adds embeddings")
            print("FUSED: identical to BM25 until Phase B")
        }

        for failure in failures { print("SEARCH_WRONG: \(failure)") }
        print(failures.isEmpty ? "SEARCH_OK" : "SEARCH_FAILED")
        return failures.isEmpty
    }
}
