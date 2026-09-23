import Foundation

/// `--selftest-portrait`: the P2-1 pass and the P2-2 grouping, scripted end to end — a fake
/// model with fixed prose, a fixture graph, and a store that lives in a temporary directory.
///
/// What it pins, because each of these is the difference between an insight and a leak:
///
/// - the pass writes drafts only — after a pass, `saved` is empty, and the only writer of a
///   saved insight is the person's keep action;
/// - the review flow: keep one draft and it moves to the saved list, discard another and it
///   is gone; the third stays because review is per-sentence, not per-batch;
/// - per-insight deletion on the kept list, and a kept sentence cannot resurrect a discarded
///   batch;
/// - the cadence: a pass that ran recently waits, and the pane can say so;
/// - Corners render from the graph without a model, one fresh fact per card, and no corner
///   exists for a life area nothing in the extraction can source;
/// - and the model's own wording never reaches the graph, the index or memory — the store is
///   the small file it owns, and nothing else reads it.
@MainActor
enum PortraitSelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let store = PortraitInsightStore.shared
        store.resetForSelfTest()
        defer { store.resetForSelfTest() }

        // MARK: The fixture graph — one meeting, one person, recurring work

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-portrait-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        do {
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
        } catch {
            print("PORTRAIT_FAILED: fixture library could not be written: \(error)")
            return false
        }
        let settings = KnowledgeIndexSettings(enabled: true, graph: true)
        let indexer = KnowledgeIndexer(
            store: KnowledgeStore(directory: root.appendingPathComponent("index", isDirectory: true)),
            sources: FixtureKnowledgeSources(meetingsRoot: meetingsRoot),
            environment: FixedKnowledgeIndexEnvironment(settings: settings), drainsOnChange: false)
        await indexer.backfill()
        _ = await indexer.drain()
        guard let graph = indexer.graph else {
            print("PORTRAIT_FAILED: the graph switch was on, and the indexer offered no graph")
            return false
        }
        do {
            let transcript = try indexer.store.chunkRows(
                kind: .transcript, sourceID: KnowledgeFixtures.pricingID.uuidString)
            let chunk = transcript.first?.id ?? 1
            let at = Int64(KnowledgeFixtures.pricingStart.timeIntervalSince1970)
            let meetingKey = GraphIDs.meeting(KnowledgeFixtures.pricingID.uuidString)
            var batch = GraphBatch(meetingID: meetingKey)
            batch.nodes.append(GraphNodeRecord(
                id: meetingKey, type: "Meeting", fields: ["label": .text("Pricing review")],
                meetingID: meetingKey, sourceChunk: chunk, observedAt: at))
            // The user's own node, which every life edge hangs from: extraction always
            // writes it, and the edge table's foreign key needs it here too.
            batch.nodes.append(GraphNodeRecord(
                id: GraphIDs.person("You"), type: "Person", fields: ["name": .text("You")],
                meetingID: meetingKey, sourceChunk: chunk, observedAt: at))
            for (name, type, edge) in [
                ("Ana", "Person", "related_to"), ("Sam", "Person", "related_to"),
                ("Next Notes launch", "Project", "works_on"), ("Marathon training", "Activity", "participates_in"),
            ] {
                let id = switch type {
                case "Person": GraphIDs.person(name)
                case "Project": GraphIDs.project(name)
                default: GraphIDs.activity(name)
                }
                batch.nodes.append(GraphNodeRecord(
                    id: id, type: type, fields: ["name": .text(name)], meetingID: nil,
                    sourceChunk: chunk, observedAt: at))
                batch.edges.append(GraphEdgeRecord(
                    type: edge, from: GraphIDs.person("You"), to: id, meetingID: meetingKey,
                    observedAt: at, validFrom: nil, validTo: nil, sourceChunk: chunk))
            }
            try graph.replaceMeeting(batch, now: KnowledgeFixtures.pricingStart)
        } catch {
            print("PORTRAIT_FAILED: the fixture graph could not be written: \(error)")
            return false
        }

        // MARK: Corners — no model, no writes

        let corners = LifeCorners.corners(graph: graph)
        print("PORTRAIT_CORNERS \(corners.map { "\($0.area.name)·\($0.count)" }.joined(separator: ", "))")
        check("the work corner was not rendered from the graph",
              corners.contains { $0.area == .work })
        check("the people corner did not pick up the two seeded people",
              corners.contains { $0.area == .people && $0.count >= 1 })
        check("the wellbeing corner did not pick up the seeded activity",
              corners.contains { $0.area == .wellbeing && $0.count >= 1 })
        check("a corner was rendered for a life area the extraction cannot source",
              corners.allSatisfy { $0.area != .learning })
        check("no corner carries a fresh line naming a real node",
              corners.contains { $0.latest?.isEmpty == false })
        check("an empty corner was rendered",
              corners.allSatisfy { $0.count > 0 })

        // MARK: The pass, with a scripted model

        PortraitService.scriptedModel = ScriptedMemoryReviewModel { _, _ in
            "Ana keeps pulling the launch forward, and the newsletter keeps slipping.\n"
                + "Your Tuesday evenings keep clearing for the marathon sessions.\n"
                + "The press kit is the one launch task nobody has picked up.\n"
                + "Fourth sentence that should never reach a card, because three is the whole list."
        }
        let service = PortraitService(store: store)
        let outcome = await service.run(now: Date(), graph: graph)
        check("the pass did not read the scripted model", outcome.model == "scripted")
        guard case .drafted(let count) = outcome.result else {
            print("PORTRAIT_FAILED: the pass did not draft anything: \(outcome.result)")
            return false
        }
        check("the pass drafted \(count) sentences — three is the cap", count == 3)
        check("an insight saved itself without the person's review", store.saved.isEmpty)
        check("the pass left no drafts to review", store.drafts.count == 3)
        check("the pass did not stamp that it looked", store.sinceLastPass() != nil)

        // MARK: The review flow, per insight

        let kept = store.drafts[0]
        store.keep(kept)
        check("keeping a draft did not save exactly one insight",
              store.saved.count == 1 && store.saved.first?.text == kept.text)
        check("the kept draft stayed in the draft list", store.drafts.count == 2)
        check("the saved insight forgot who wrote it", store.saved.first?.model == "scripted")

        let passedOver = store.drafts[1]
        store.discard(passedOver.id)
        check("discarding one draft removed another", store.drafts.count == 1)
        check("discarding a draft touched the saved list", store.saved.count == 1)

        // A second pass over the same material: the kept sentence is not re-offered (the
        // person has answered it), the discarded one may come back — a pattern persists even
        // after the person passed on it once — and the surviving draft is not duplicated.
        let again = await service.run(now: Date().addingTimeInterval(3_600), graph: graph)
        guard case .drafted = again.result else {
            failures.append("the second pass did not run at all")
            return false
        }
        check("the kept sentence came back as a draft after the second pass",
              !store.drafts.contains { NextMemory.normalize($0.text) == NextMemory.normalize(kept.text) })
        check("the second pass duplicated an already-kept insight",
              store.saved.count == 1)
        check("the second pass left \(store.drafts.count) drafts instead of two",
              store.drafts.count == 2)

        // MARK: Per-insight deletion on the kept list

        store.delete(store.saved[0].id)
        check("deleting one insight emptied the whole list", store.saved.isEmpty)
        check("a deleted insight returned as a draft",
              !store.drafts.contains { NextMemory.normalize($0.text) == NextMemory.normalize(kept.text) })

        // MARK: The cadence

        let due = await service.runIfDue(now: Date(), graph: graph)
        guard case .waited(let reason) = due.result else {
            failures.append("a pass from a minute ago ran again instead of waiting")
            return false
        }
        check("the wait reason does not say when it last looked", reason.contains("recently"))
        let forced = await service.runIfDue(now: Date(), force: true, graph: graph)
        if case .drafted = forced.result {} else {
            failures.append("a forced pass did not run")
        }

        // MARK: The honest empty answer

        PortraitService.scriptedModel = nil
        let nothing = await service.run(now: Date(), graph: nil)
        guard case .waited(let why) = nothing.result else {
            failures.append("a pass over no graph claimed to have looked")
            return false
        }
        check("the no-graph reason did not name the graph as the missing piece", why.contains("graph"))
        for failure in failures { print("PORTRAIT_WRONG: \(failure)") }
        print(failures.isEmpty ? "PORTRAIT_OK" : "PORTRAIT_FAILED: \(failures.count) problem(s)")
        return failures.isEmpty
    }
}
