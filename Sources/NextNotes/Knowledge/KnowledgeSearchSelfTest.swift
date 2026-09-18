import Foundation

/// `--selftest-search [query] [--gold <path>]`: BM25 over the fixture library — passages with
/// timestamps, stemming, ranking, snippets, the OR fallback, every filter as SQL, facet counts,
/// hostile input, and `memory.recall` reading the index. Then hybrid search with the fake
/// embedder: a paraphrase BM25 cannot find, names BM25 keeps, filters applied to the vector
/// leg, a deleted meeting's vectors gone from the matrix, RRF order, conversation-only
/// recency, and an embedder that must be awaited. Last, recall@10 and MRR for BM25, cosine
/// and fused on `Tests/Fixtures/knowledge-gold.json`. With a query, prints the three rankings
/// side by side.
///
/// Every index is built from fixtures in a temporary directory; the user's library is never
/// read and no model is loaded.
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

        failures += await hybridFailures(root: root.appendingPathComponent("hybrid", isDirectory: true), query: query)
        failures += await recencyFailures(root: root.appendingPathComponent("recency", isDirectory: true))
        failures += await goldFailures(root: root.appendingPathComponent("gold", isDirectory: true))

        for failure in failures { print("SEARCH_WRONG: \(failure)") }
        print(failures.isEmpty ? "SEARCH_OK" : "SEARCH_FAILED")
        return failures.isEmpty
    }

    /// An indexer over `sources` with every chunk embedded by `embedder`.
    private static func embeddedIndexer(
        root: URL, sources: FixtureKnowledgeSources, embedder: any KnowledgeEmbedder
    ) async -> KnowledgeIndexer {
        let environment = FixedKnowledgeIndexEnvironment(settings: KnowledgeIndexSettings(enabled: true, embedder: .potion))
        let indexer = KnowledgeIndexer(store: KnowledgeStore(directory: root), sources: sources, environment: environment,
                                       drainsOnChange: false, embedders: { $0 == .none ? nil : embedder })
        await indexer.backfill()
        _ = await indexer.drain()
        return indexer
    }

    // MARK: - Hybrid

    private static func hybridFailures(root: URL, query: String?) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        do {
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
        } catch {
            return ["hybrid fixture library could not be written: \(error)"]
        }
        let sources = FixtureKnowledgeSources(meetingsRoot: meetingsRoot)
        sources.sessions = [KnowledgeFixtures.conversation()]
        let fake = FakeKnowledgeEmbedder()
        let indexer = await embeddedIndexer(root: root.appendingPathComponent("index", isDirectory: true),
                                            sources: sources, embedder: fake)
        let pricing = KnowledgeFixtures.pricingID.uuidString
        let hiring = KnowledgeFixtures.hiringID.uuidString
        guard let hybrid = indexer.searcher as? HybridKnowledgeSearch else {
            return ["an indexer with an embedder did not search hybrid"]
        }
        do {
            check("the fixture library has chunks without vectors",
                  try indexer.store.embeddingCount(model: fake.model) == indexer.store.chunkCount())

            // MARK: A paraphrase BM25 cannot find
            // "release" and "fee" appear nowhere; the fake maps them onto ship and price.
            let paraphrase = "release fee"
            let lexical = try KeywordKnowledgeSearch(store: indexer.store).search(KnowledgeQuery(text: paraphrase))
            check("the paraphrase fixture is not a BM25 miss", lexical.isEmpty)
            let started = Date()
            let found = try hybrid.rankings(KnowledgeQuery(text: paraphrase, limit: 10))
            print(String(format: "SEARCH_HYBRID_LATENCY %.2fms", Date().timeIntervalSince(started) * 1_000))
            check("hybrid did not use the vectors", found.usedVectors)
            check("hybrid missed the paraphrase: \(found.fused.first?.plainSnippet ?? "nothing")",
                  found.fused.first?.text.localizedCaseInsensitiveContains("ship the pricing page") == true)
            check("fused order is not ascending", zip(found.fused, found.fused.dropFirst()).allSatisfy { $0.score <= $1.score })
            check("a recording meeting leaked through the vectors",
                  !found.fused.contains { $0.sourceID == KnowledgeFixtures.liveID.uuidString })

            // MARK: A query that matches nothing returns nothing
            // Every passage has some cosine with any query; below the floor it is not a match.
            let nonsense = "zebra xylophone quantum"
            let nothing = try hybrid.rankings(KnowledgeQuery(text: nonsense, limit: 10))
            check("a nonsense query found BM25 hits", nothing.bm25.isEmpty)
            check("a nonsense query found vector matches: \(nothing.cosine.map(\.similarity))", nothing.cosine.isEmpty)
            check("a nonsense query returned fused passages", nothing.fused.isEmpty)
            check("recall handed over passages for a query that matches nothing",
                  KnowledgeRecall(searcher: hybrid).passages(for: nonsense) == nil)
            check("every cosine match is above the embedder's floor",
                  found.cosine.allSatisfy { $0.similarity > fake.minimumSimilarity })

            // MARK: Names stay BM25's
            let names = try hybrid.search(KnowledgeQuery(text: "Sam", limit: 3))
            check("an exact name fell out of the fused top three", names.contains { $0.text.contains("Sam") })

            // MARK: Filters narrow the vector leg as SQL
            let notes = try hybrid.search(KnowledgeQuery(text: paraphrase, filter: KnowledgeFilter(kinds: [.notes])))
            check("the kind filter leaked through the vectors", !notes.isEmpty && notes.allSatisfy { $0.kind == .notes })
            let ana = try hybrid.search(KnowledgeQuery(text: paraphrase, filter: KnowledgeFilter(speakers: ["Ana"])))
            check("the speaker filter leaked through the vectors", !ana.isEmpty && ana.allSatisfy { $0.speaker == "Ana" })
            let oneMeeting = try hybrid.search(KnowledgeQuery(text: paraphrase, filter: KnowledgeFilter(sourceIDs: [hiring])))
            check("the meeting filter leaked through the vectors",
                  !oneMeeting.isEmpty && oneMeeting.allSatisfy { $0.sourceID == hiring })
            let later = try hybrid.search(KnowledgeQuery(text: paraphrase, filter: KnowledgeFilter(
                from: KnowledgeFixtures.hiringStart.addingTimeInterval(-60))))
            check("the date filter leaked through the vectors", later.allSatisfy { $0.sourceID != pricing })
            check("facets changed with the embedder",
                  try hybrid.facets(KnowledgeQuery(text: "pricing"))
                    == KeywordKnowledgeSearch(store: indexer.store).facets(KnowledgeQuery(text: "pricing")))
            check("a browse by facet went through the vectors",
                  try hybrid.search(KnowledgeQuery(text: "", filter: KnowledgeFilter(kinds: [.conversation]))).count == 1)

            // MARK: An embedder behind an actor
            let awaited = HybridKnowledgeSearch(store: indexer.store, embedder: AwaitedEmbedder(base: fake),
                                                vectors: KnowledgeVectorIndex())
            check("an embedder that must be awaited was called inline",
                  try !awaited.rankings(KnowledgeQuery(text: paraphrase)).usedVectors)
            let prepared = await awaited.prepare(KnowledgeQuery(text: paraphrase))
            check("prepare did not embed the query", prepared.vector?.count == fake.dimensions)
            check("a prepared query did not use the vectors", try awaited.rankings(prepared).usedVectors)
            check("prepare embedded an empty query", await awaited.prepare(KnowledgeQuery(text: " ")).vector == nil)
            var nonsenseRecall = KnowledgeRecall(searcher: awaited)
            await nonsenseRecall.prepare(for: nonsense)
            check("a prepared recall handed over passages for a query that matches nothing",
                  nonsenseRecall.passages(for: nonsense) == nil)
            var recall = KnowledgeRecall(searcher: awaited)
            await recall.prepare(for: paraphrase)
            check("recall with a prepared query missed the paraphrase",
                  recall.passages(for: paraphrase)?.contains("pricing page") == true)
            check("recall with an inline embedder missed the paraphrase",
                  KnowledgeRecall(searcher: hybrid).passages(for: paraphrase)?.contains("pricing page") == true)

            // MARK: Side by side, for a query from the command line
            if let query {
                let rankings = try hybrid.rankings(KnowledgeQuery(text: query, limit: 10))
                func row(_ rank: Int, _ hit: KnowledgeHit, _ score: String) -> String {
                    let at = hit.startTime.map { " @\($0.counterText)" } ?? ""
                    return "  \(rank + 1). [\(hit.kind.rawValue)\(at)] \(score) \(hit.speaker ?? hit.heading ?? "-"): "
                        + hit.plainSnippet
                }
                print("SEARCH_QUERY \(query) (fixture library, \(fake.model))")
                print("BM25:")
                for (rank, hit) in rankings.bm25.prefix(10).enumerated() { print(row(rank, hit, String(format: "%.4f", hit.score))) }
                print("COSINE:")
                for (rank, entry) in rankings.cosine.prefix(10).enumerated() {
                    print(row(rank, entry.hit, String(format: "%.4f", entry.similarity)))
                }
                print("FUSED (RRF k=60):")
                for (rank, hit) in rankings.fused.enumerated() { print(row(rank, hit, String(format: "%.5f", -hit.score))) }
            }

            // MARK: A deleted meeting's vectors leave the matrix
            _ = try hybrid.search(KnowledgeQuery(text: paraphrase))
            indexer.removeMeeting(KnowledgeFixtures.pricingID)
            let afterDelete = try hybrid.search(KnowledgeQuery(text: paraphrase))
            check("search returned a deleted meeting from cached vectors", !afterDelete.contains { $0.sourceID == pricing })
        } catch {
            failures.append("hybrid search threw: \(error.localizedDescription)")
        }
        return failures
    }

    // MARK: - Recency

    /// Two conversations and two transcripts, each pair an older passage that matches better
    /// and a newer one that matches worse. Only the conversations may swap.
    private static func recencyFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check("transcripts are recency weighted",
              HybridKnowledgeSearch.recencyWeight(kind: .transcript, occurredAt: now.addingTimeInterval(-400 * 86_400), now: now) == 1)
        check("a new conversation is discounted",
              HybridKnowledgeSearch.recencyWeight(kind: .conversation, occurredAt: now, now: now) == 1)
        check("the half-life is not thirty days",
              abs(HybridKnowledgeSearch.recencyWeight(kind: .conversation, occurredAt: now.addingTimeInterval(-30 * 86_400),
                                                      now: now) - 0.9) < 1e-9)
        check("recency is not mild",
              HybridKnowledgeSearch.recencyWeight(kind: .conversation, occurredAt: .distantPast, now: now) >= 0.8)

        let store = KnowledgeStore(directory: root)
        let fake = FakeKnowledgeEmbedder()
        let older = Int64(now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970)
        let newer = Int64(now.addingTimeInterval(-3_600).timeIntervalSince1970)
        let better = "quarterly tax filing deadline"
        let worse = "quarterly tax filing deadline " + KnowledgeFixtures.filler(12)
        do {
            for (kind, prefix) in [(KnowledgeSourceKind.conversation, "User: "), (.transcript, "")] {
                try store.replace(kind: kind, sourceID: "\(kind.rawValue)-older",
                                  chunks: [KnowledgeChunk(ordinal: 0, text: prefix + better, occurredAt: older)])
                try store.replace(kind: kind, sourceID: "\(kind.rawValue)-newer",
                                  chunks: [KnowledgeChunk(ordinal: 0, text: prefix + worse, occurredAt: newer)])
            }
            let pending = try store.chunksNeedingEmbedding(model: fake.model, limit: 10)
            let vectors = try fake.embedNow(pending.map(\.text), purpose: .document)
            try store.writeEmbeddings(zip(pending, vectors).map { ($0.chunkID, $1) }, model: fake.model,
                                      dimensions: fake.dimensions)
            let search = HybridKnowledgeSearch(store: store, embedder: fake, vectors: KnowledgeVectorIndex(), now: { now })
            let conversations = try search.search(KnowledgeQuery(text: "quarterly tax filing deadline",
                                                                 filter: KnowledgeFilter(kinds: [.conversation])))
            check("the newer conversation did not rise above the older, closer one",
                  conversations.map(\.sourceID) == ["conversation-newer", "conversation-older"])
            let transcripts = try search.search(KnowledgeQuery(text: "quarterly tax filing deadline",
                                                               filter: KnowledgeFilter(kinds: [.transcript])))
            check("an older transcript lost to recency",
                  transcripts.map(\.sourceID) == ["transcript-older", "transcript-newer"])
        } catch {
            failures.append("recency threw: \(error.localizedDescription)")
        }
        return failures
    }

    // MARK: - Gold set

    private static func goldFailures(root: URL) async -> [String] {
        let gold: KnowledgeGoldSet
        do {
            gold = try KnowledgeGoldSet.load()
        } catch {
            return ["the gold set could not be read: \(error.localizedDescription)"]
        }
        var failures: [String] = []
        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        let sources = FixtureKnowledgeSources(meetingsRoot: meetingsRoot)
        do {
            sources.sessions = try gold.writeLibrary(meetingsRoot: meetingsRoot)
        } catch {
            return ["the gold library could not be written: \(error.localizedDescription)"]
        }
        let fake = FakeKnowledgeEmbedder()
        let indexer = await embeddedIndexer(root: root.appendingPathComponent("index", isDirectory: true),
                                            sources: sources, embedder: fake)
        guard var hybrid = indexer.searcher as? HybridKnowledgeSearch else { return ["the gold index is not hybrid"] }
        // Asked a week after the newest source, as someone would ask about recent work; the
        // real clock would age the fixture conversations further every day this test exists.
        let asked = (gold.meetings.map(\.start) + gold.conversations.map(\.at)).max()?.addingTimeInterval(7 * 86_400) ?? Date()
        hybrid.now = { asked }
        do {
            let chunks = try indexer.store.chunkCount()
            // Every answer must exist in the index, or a miss is the fixture's fault.
            for question in gold.questions {
                guard let id = gold.sourceIDs[question.source] else {
                    failures.append("gold: unknown source \(question.source)")
                    continue
                }
                let passages = try KeywordKnowledgeSearch(store: indexer.store)
                    .search(KnowledgeQuery(text: "", filter: KnowledgeFilter(sourceIDs: [id]), limit: 500))
                if !passages.contains(where: { $0.text.localizedCaseInsensitiveContains(question.contains) }) {
                    failures.append("gold: no passage in \(question.source) contains \(question.contains)")
                }
            }
            let report = try gold.evaluate(hybrid)
            print("SEARCH_GOLD questions=\(gold.questions.count) chunks=\(chunks) embedder=\(fake.model) (fake: pipeline, not model quality)")
            print("SEARCH_GOLD bm25   \(report.bm25.line)")
            print("SEARCH_GOLD cosine \(report.cosine.line)")
            print("SEARCH_GOLD fused  \(report.fused.line)")
            for kind in report.byKind.keys.sorted() {
                guard let scores = report.byKind[kind] else { continue }
                print("SEARCH_GOLD \(kind): bm25 \(scores.bm25.line) | cosine \(scores.cosine.line) | fused \(scores.fused.line)")
            }
            for question in report.missed { print("SEARCH_GOLD missed: \(question)") }
            print("SEARCH_GOLD real models: pending — no embedding model downloaded, and no gold set on a real library yet")
            print("SEARCH_GOLD beats Phase A: pending — the fake's synonym table was written for these questions, so its margin shows the fusion works, not that a model beats BM25")
            if gold.questions.count < 40 { failures.append("gold: fewer than 40 questions") }
            // Regression guards for the pipeline, not quality claims.
            if report.fused.recallAt10 < report.bm25.recallAt10 {
                failures.append("gold: fused recall@10 \(report.fused.recallAt10) is below BM25's \(report.bm25.recallAt10)")
            }
            if report.fused.mrr + 1e-9 < report.bm25.mrr {
                failures.append("gold: fused MRR \(report.fused.mrr) is below BM25's \(report.bm25.mrr)")
            }
            // Questions that share no word with their answer: BM25 misses them by construction,
            // so vectors — and the fusion carrying them — must find strictly more.
            if let vocabulary = report.byKind["vocabulary"] {
                if vocabulary.cosine.recallAt10 <= vocabulary.bm25.recallAt10 {
                    failures.append("gold: cosine recall@10 on vocabulary questions \(vocabulary.cosine.recallAt10) is not above BM25's \(vocabulary.bm25.recallAt10)")
                }
                if vocabulary.fused.recallAt10 <= vocabulary.bm25.recallAt10 {
                    failures.append("gold: fused recall@10 on vocabulary questions \(vocabulary.fused.recallAt10) is not above BM25's \(vocabulary.bm25.recallAt10)")
                }
            } else {
                failures.append("gold: no vocabulary questions")
            }
            if report.fused.recallAt10 < 0.9 {
                failures.append("gold: fused recall@10 \(report.fused.recallAt10) is below 0.9")
            }
        } catch {
            failures.append("gold evaluation threw: \(error.localizedDescription)")
        }
        return failures
    }
}

/// The fake behind an `async` call only, like `EmbeddingRuntime`.
private struct AwaitedEmbedder: KnowledgeEmbedder {
    let base: FakeKnowledgeEmbedder

    var model: String { base.model }
    var dimensions: Int { base.dimensions }
    var minimumSimilarity: Float { base.minimumSimilarity }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        await Task.yield()
        return try base.embedNow(texts, purpose: purpose)
    }

    func release() async {}
}
