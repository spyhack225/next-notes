import Foundation
import SQLite3

/// `--selftest-meeting-recall`: the query behind the panel that opens during a meeting.
///
/// The honesty claim comes first, because it is the one a green run can quietly lose: a
/// filter says what it needs, `.related` refuses rather than answering `samePeople`'s
/// question, and a search that throws is an empty answer rather than a plausible-looking
/// one. Then each filter over fixtures this test writes itself — a temporary
/// `MeetingStore`, a temporary index and a temporary map. No model, no network, no
/// microphone, and no usage-log row.
///
/// **Every `check` names the property that must hold and asserts it.** The earlier draft of
/// this file mixed that with naming the *failure* and asserting the bug, which is a test
/// that passes on broken behaviour and reports itself as a gate; `--selftest-*` has to fail
/// when the thing it names did not happen, and a check whose name says one thing and whose
/// condition says the other is worse than no check at all.
@MainActor
enum MeetingRecallSelfTest {
    @discardableResult
    static func run() async -> Bool {
        let failures = await checks()
        for failure in failures { print("MEETING_RECALL_FAILED: \(failure)") }
        print(failures.isEmpty ? "MEETING_RECALL_OK" : "MEETING_RECALL_FAILED")
        return failures.isEmpty
    }

    // MARK: - The checks

    private static func checks() async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures.append(name) }
        }
        /// A line per stage, because the only other failure mode used to be a bare budget
        /// expiry, and "the checks did not finish" names no stage to look at.
        func stage(_ name: String) { SelfTest.diagnostic("  …   \(name)") }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-meeting-recall-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // MARK: Availability — the honesty claim, asserted directly.

        stage("availability")
        check("samePeople answers with every switch off",
              MeetingRecall.availability(indexEnabled: false, graphEnabled: false, filter: .samePeople) == .ready)
        check("recent answers with every switch off",
              MeetingRecall.availability(indexEnabled: false, graphEnabled: false, filter: .recent) == .ready)
        check("related needs the map when the map is off",
              MeetingRecall.availability(indexEnabled: true, graphEnabled: false, filter: .related) == .needsGraph)
        check("related needs the index when the index is off",
              MeetingRecall.availability(indexEnabled: false, graphEnabled: true, filter: .related) == .needsIndex)
        check("related answers with the index and the map both on",
              MeetingRecall.availability(indexEnabled: true, graphEnabled: true, filter: .related) == .ready)
        check("sameTopic needs the index when the index is off",
              MeetingRecall.availability(indexEnabled: false, graphEnabled: true, filter: .sameTopic) == .needsIndex)
        check("sameTopic answers with the index on",
              MeetingRecall.availability(indexEnabled: true, graphEnabled: false, filter: .sameTopic) == .ready)

        // MARK: Every string a person reads.

        check("the four filters carry the panel's own titles",
              MeetingRecallFilter.allCases.map(\.title) == ["Earlier", "Same people", "Same topic", "Related"])
        check("no two filters share a title",
              Set(MeetingRecallFilter.allCases.map(\.title)).count == MeetingRecallFilter.allCases.count)
        for filter in MeetingRecallFilter.allCases {
            check("\(filter.rawValue) has a title", !filter.title.isEmpty)
            check("\(filter.rawValue) has a symbol", !filter.symbol.isEmpty)
            check("\(filter.rawValue) has a question", !filter.question.isEmpty)
            check("\(filter.rawValue) has a help", !filter.help.isEmpty)
        }
        for availability in [MeetingRecall.Availability.ready, .needsIndex, .needsGraph] {
            let reason = MeetingRecall.reasonUnavailable(availability)
            check("the \(availability) sentence is not empty", !reason.isEmpty)
            check("the \(availability) sentence ends in a full stop",
                  reason.hasSuffix(".") || reason.hasSuffix("!") || reason.hasSuffix("?"))
            check("the \(availability) sentence names none of \(Self.jargon)",
                  Self.jargon.allSatisfy { reason.range(of: $0, options: .caseInsensitive) == nil })
        }

        // MARK: Fixtures: one meeting in the room, six on disk.

        stage("fixtures")
        let store = MeetingStore.isolated()
        let now = Date()
        let day: TimeInterval = 86_400
        let live = Meeting(id: UUID(), title: "Pricing launch", start: now,
                           attendees: ["Nico M.", "Ana Ruiz"], status: .recording)
        let ana = Meeting(id: UUID(), title: "Growth review", start: now - 2 * day,
                          attendees: ["ana ruiz", "Bo"], status: .done)
        let nico = Meeting(id: UUID(), title: "Roadmap", start: now - 9 * day,
                           attendees: ["Nico  M.", "Bo"], status: .done)
        let both = Meeting(id: UUID(), title: "Planning", start: now - 40 * day,
                           attendees: ["Sam", "nico m.", "Ana  Ruiz"], status: .done)
        let stranger = Meeting(id: UUID(), title: "One to one", start: now - 30 * day,
                               attendees: ["Sam"], status: .done)
        // A recording that began before the calendar said it would (M-11): a list of earlier
        // meetings must not answer "in 3 days" about one.
        let early = Meeting(id: UUID(), title: "Board prep", start: now + 3 * day,
                            attendees: ["Kai"], status: .done)
        // And one that began a moment ago, which the formatter rounds into its own units and
        // can still call a time away.
        let justNow = Meeting(id: UUID(), title: "Standup", start: now - 0.4,
                              attendees: ["Zoe"], status: .done)
        for meeting in [live, ana, nico, both, stranger, early, justNow] { store.save(meeting) }

        // The indexer the harness hands out, which really is switched off — the claim
        // "samePeople works with everything off" is only worth anything against one.
        check("the harness indexer really is switched off", !KnowledgeIndexer.shared.settings.enabled)

        // MARK: `.recent`

        stage("recent")
        let recent = await MeetingRecall.hits(meeting: live, filter: .recent, indexer: KnowledgeIndexer.shared,
                                              store: store, limit: 10)
        check("the meeting in the room is left out of the list of earlier meetings",
              !recent.contains { $0.meetingID == live.id })
        check("every recent row carries a reason", !recent.contains { $0.why.isEmpty })
        check("a recent row counts no matches", !recent.contains { $0.matchCount != 0 })
        check("recent comes back newest first", recent.map(\.at) == recent.map(\.at).sorted(by: >))
        check("recent keeps every other meeting and invents none",
              Set(recent.map(\.meetingID)) == Set([ana.id, nico.id, both.id, stranger.id, early.id,
                                                  justNow.id]))
        // A list of meetings that already happened must not describe one of them as a time
        // away, whichever direction the date is wrong in.
        check("no recent row describes a meeting as a time away",
              !recent.contains { $0.why.lowercased().hasPrefix("in ") })
        let earlyWhy = recent.first { $0.meetingID == early.id }?.why ?? ""
        check("a meeting that has not started reads as a plain date rather than a time away",
              earlyWhy == early.start.formatted(date: .abbreviated, time: .omitted))
        let anaWhy = recent.first { $0.meetingID == ana.id }?.why ?? ""
        check("a meeting two days old reads relatively rather than as a plain date",
              anaWhy != ana.start.formatted(date: .abbreviated, time: .omitted))
        check("recent honours its limit",
              (await MeetingRecall.hits(meeting: live, filter: .recent, indexer: KnowledgeIndexer.shared,
                                        store: store, limit: 2)).count == 2)
        check("a limit of zero returns no rows",
              (await MeetingRecall.hits(meeting: live, filter: .recent, indexer: KnowledgeIndexer.shared,
                                       store: store, limit: 0)).isEmpty)

        // MARK: `.samePeople` — the floor, with the index and the map both off.

        stage("samePeople")
        let people = await MeetingRecall.hits(meeting: live, filter: .samePeople,
                                              indexer: KnowledgeIndexer.shared, store: store, limit: 10)
        check("samePeople leaves the meeting in the room, the stranger and the two others out "
                + "(\(people.map(\.title).sorted()))",
              !people.contains { $0.meetingID == live.id || $0.meetingID == stranger.id
                  || $0.meetingID == early.id || $0.meetingID == justNow.id })
        check("samePeople finds exactly the three meetings that share a person "
                + "(\(people.map(\.title).sorted()))",
              Set(people.map(\.meetingID)) == Set([both.id, ana.id, nico.id]))
        check("samePeople puts the biggest overlap first", people.first?.meetingID == both.id)
        check("a two-person row names them in the current meeting's order and spelling",
              people.first?.people == ["Nico M.", "Ana Ruiz"])
        check("a two-person row says how many they share",
              people.first?.why == "2 of the same people")
        check("a two-person row counts both of them", people.first?.matchCount == 2)
        check("a one-person row names the person in the current meeting's spelling",
              people.first { $0.meetingID == ana.id }?.why == "Ana Ruiz was in both")
        check("a one-person row folds the other meeting's spacing",
              people.first { $0.meetingID == nico.id }?.people == ["Nico M."])
        check("every samePeople row carries a reason", !people.contains { $0.why.isEmpty })
        let peopleAgain = await MeetingRecall.hits(meeting: live, filter: .samePeople,
                                                   indexer: KnowledgeIndexer.shared, store: store, limit: 10)
        check("samePeople answers the same way the second time it is asked", people == peopleAgain)
        // A meeting whose folder is gone between the read and the row: the store is what
        // says a meeting exists, so the row is dropped rather than offered unopenable.
        let gone = Meeting(id: UUID(), title: "Deleted", start: now - day,
                           attendees: ["Ana Ruiz"], status: .done)
        store.save(gone)
        store.delete(gone)
        check("a deleted meeting is not offered",
              !(await MeetingRecall.hits(meeting: live, filter: .samePeople,
                                        indexer: KnowledgeIndexer.shared, store: store, limit: 10))
                .contains { $0.meetingID == gone.id })

        // MARK: `.sameTopic` and `.related` refuse rather than answer.

        stage("refusal")
        check("sameTopic answers nothing while the index is switched off",
              (await MeetingRecall.hits(meeting: live, filter: .sameTopic, indexer: KnowledgeIndexer.shared,
                                       store: store, limit: 10)).isEmpty)
        check("related answers nothing with no map to read",
              (await MeetingRecall.hits(meeting: live, filter: .related, indexer: KnowledgeIndexer.shared,
                                       store: store, limit: 10)).isEmpty)

        // MARK: A search that throws is an empty answer, and an empty question is never asked.

        stage("throwing search")
        let unreadable = UnreadableSearch()
        let threw = await MeetingRecall.topicSignals(text: live.title, sourceIDs: [ana.id.uuidString],
                                                     searcher: unreadable, limit: 5)
        check("a search that throws produces no answers (\(threw.count))", threw.isEmpty)
        // `asked` is cumulative, so each of the two below is about whether the count *moved*
        // — a question with nothing to look in must cost no search at all, which is a
        // correctness point and not only a speed one: an empty `sourceIDs` is not a
        // restrictive filter, it is no filter, so searching on it would answer with every
        // meeting including the one in the room.
        let afterTheThrow = unreadable.asked
        check("a search that throws was still reached (\(afterTheThrow))", afterTheThrow == 1)
        _ = await MeetingRecall.topicSignals(text: live.title, sourceIDs: [], searcher: unreadable, limit: 5)
        check("a question with no other meeting never reaches the searcher "
                + "(\(unreadable.asked) before \(afterTheThrow))",
              unreadable.asked == afterTheThrow)
        let afterNoSources = unreadable.asked
        _ = await MeetingRecall.topicSignals(text: "   ", sourceIDs: [ana.id.uuidString],
                                             searcher: unreadable, limit: 5)
        check("a title with no words never reaches the searcher "
                + "(\(unreadable.asked) before \(afterNoSources))",
              unreadable.asked == afterNoSources)

        // MARK: The collapse: one row per meeting, the best passage, the count.

        stage("collapse")
        let stub = StubSearch(hits: [
            Self.hit(1, ana, score: 4, heading: "Decisions"),
            Self.hit(2, ana, score: 9, heading: "Key points"),
            Self.hit(3, stranger, score: 1, heading: nil),
        ])
        let signals = await MeetingRecall.topicSignals(text: live.title,
                                                       sourceIDs: [ana.id.uuidString, stranger.id.uuidString],
                                                       searcher: stub, limit: 4)
        check("two meetings' passages collapse to one row each (\(signals.count))", signals.count == 2)
        check("the stronger passage wins the row (\(signals[ana.id.uuidString]?.best.chunkID ?? 0))",
              signals[ana.id.uuidString]?.best.chunkID == 1)
        check("a meeting's passages are counted (\(signals[ana.id.uuidString]?.count ?? 0))",
              signals[ana.id.uuidString]?.count == 2)
        // A passage with no heading of its own is kept and still becomes a row — the heading
        // only chooses between "Same topic: <section>" and the plain "Same topic", so a
        // meeting whose best passage has no section is exactly the case the plain wording
        // exists for. Dropping it would leave a meeting the user can see the words for
        // absent from the list.
        check("a passage with no heading of its own is still a row "
                + "(\(signals[stranger.id.uuidString]?.count ?? 0))",
              signals[stranger.id.uuidString]?.count == 1)
        check("a passage with no heading of its own is not the one a section would name",
              signals[stranger.id.uuidString]?.best.chunkID == 3)
        check("the search is narrowed to transcripts and notes",
              stub.lastQuery?.filter.kinds == [.transcript, .notes])
        check("the search is over-fetched (\(stub.lastQuery?.limit ?? 0))",
              stub.lastQuery?.limit == 4 * MeetingRecall.topicOverFetch)
        check("the search is over this meeting's own title", stub.lastQuery?.text == live.title)

        // MARK: `.sameTopic` end to end, over a real index this test wrote.

        stage("sameTopic end to end")
        do {
            let directory = root.appendingPathComponent("topic", isDirectory: true)
            let knowledge = KnowledgeStore(directory: directory)
            let indexer = KnowledgeIndexer(
                store: knowledge, sources: EmptyKnowledgeSources(root: directory),
                environment: FixedKnowledgeIndexEnvironment(settings: KnowledgeIndexSettings(enabled: true)),
                drainsOnChange: false)
            let past = Int64(live.start.timeIntervalSince1970) - 4 * Int64(day)
            _ = try knowledge.replace(kind: .notes, sourceID: ana.id.uuidString, chunks: [
                KnowledgeChunk(ordinal: 0, text: "Ship the pricing page on the launch date.",
                               heading: "Decisions", occurredAt: past),
            ])
            // No heading of its own, so the reason falls back to the plain sentence.
            _ = try knowledge.replace(kind: .notes, sourceID: stranger.id.uuidString, chunks: [
                KnowledgeChunk(ordinal: 0, text: "Pricing came up again in that launch.", occurredAt: past),
            ])
            // Two passages, so the count has something to count.
            _ = try knowledge.replace(kind: .notes, sourceID: nico.id.uuidString, chunks: [
                KnowledgeChunk(ordinal: 0, text: "The launch plan for pricing.",
                               heading: "Summary", occurredAt: past - Int64(day)),
                KnowledgeChunk(ordinal: 1, text: "Pricing review before launch.", occurredAt: past - Int64(day)),
            ])
            // Not a meeting, and not a passage: a filter that only looks through meetings'
            // own words must not answer with somebody else's conversation.
            _ = try knowledge.replace(kind: .conversation, sourceID: "not-a-meeting", chunks: [
                KnowledgeChunk(ordinal: 0, text: "Pricing and launch again.", occurredAt: past),
            ])
            // The meeting in the room owns the best passage there is and must still not
            // answer its own question.
            _ = try knowledge.replace(kind: .notes, sourceID: live.id.uuidString, chunks: [
                KnowledgeChunk(ordinal: 0, text: "Pricing launch pricing launch pricing launch.",
                               heading: "Summary", occurredAt: Int64(now.timeIntervalSince1970)),
            ])

            // The honesty claim, against an indexer that is *on* so that refusing is the
            // only possible reason for an empty answer. Asserted against the harness indexer
            // it is vacuous: that one is switched off, so a `.related` that quietly answered
            // `.sameTopic`'s question would return the same empty list and the check would
            // pass on the bug. The pair below is what makes it real — one filter on the same
            // indexer answers, the other refuses.
            let refused = await MeetingRecall.hits(meeting: live, filter: .related, indexer: indexer,
                                                   store: store, limit: 10)
            let answered = await MeetingRecall.hits(meeting: live, filter: .sameTopic, indexer: indexer,
                                                    store: store, limit: 10)
            check("the index is on, so the pair below can tell a refusal from a dead end",
                  indexer.settings.enabled)
            check("the same index answers .sameTopic", !answered.isEmpty)
            check("related answers nothing with the index on and the map off (\(refused.count))",
                  refused.isEmpty)

            let found = answered
            check("sameTopic finds the three meetings that say the same words "
                    + "(\(found.map(\.title).sorted()))",
                  Set(found.map(\.meetingID)) == Set([ana.id, stranger.id, nico.id]))
            check("sameTopic leaves the meeting in the room out", !found.contains { $0.meetingID == live.id })
            check("sameTopic names the passage's section "
                    + "(\(found.first { $0.meetingID == ana.id }?.why ?? ""))",
                  found.first { $0.meetingID == ana.id }?.why == "Same topic: Decisions")
            check("sameTopic falls back to a plain reason when a passage has no section "
                    + "(\(found.first { $0.meetingID == stranger.id }?.why ?? ""))",
                  found.first { $0.meetingID == stranger.id }?.why == "Same topic")
            check("sameTopic counts every passage that matched "
                    + "(\(found.first { $0.meetingID == nico.id }?.matchCount ?? 0))",
                  found.first { $0.meetingID == nico.id }?.matchCount == 2)
            check("every sameTopic row carries a reason", !found.contains { $0.why.isEmpty })
            let unrelated = Meeting(id: UUID(), title: "Zzz", start: now, status: .done)
            check("a meeting nobody says anything like finds nothing",
                  (await MeetingRecall.hits(meeting: unrelated, filter: .sameTopic, indexer: indexer,
                                           store: store, limit: 10)).isEmpty)
        } catch {
            failures.append("the sameTopic fixture failed: \(error.localizedDescription)")
        }

        // MARK: `.related` end to end, over a real map this test wrote.

        stage("related end to end")
        do {
            let directory = root.appendingPathComponent("related", isDirectory: true)
            let knowledge = KnowledgeStore(directory: directory)
            let graph = GraphStore(store: knowledge)
            let indexer = KnowledgeIndexer(
                store: knowledge, sources: EmptyKnowledgeSources(root: directory),
                environment: FixedKnowledgeIndexEnvironment(
                    settings: KnowledgeIndexSettings(enabled: true, graph: true)),
                drainsOnChange: false)

            /// A meeting node, and whatever it shares with the meeting in the room.
            func batch(_ meeting: Meeting, shares: Bool, project: Bool) throws -> GraphBatch {
                let node = GraphIDs.meeting(meeting.id.uuidString)
                let person = GraphIDs.person("Ana Ruiz")
                let topic = GraphIDs.topic("Pricing")
                let projectNode = GraphIDs.project("Atlas")
                let at = Int64(meeting.start.timeIntervalSince1970)
                _ = try knowledge.replace(kind: .notes, sourceID: meeting.id.uuidString, chunks: [
                    KnowledgeChunk(ordinal: 0, text: "Notes for \(meeting.title).", occurredAt: at),
                ])
                // Every edge cites a passage that exists, so the fixture is written the way
                // the real extractor writes it rather than around the constraint.
                let source = try knowledge.withConnection { db -> Int64 in
                    let statement = try KnowledgeStore.prepare(
                        db, "SELECT id FROM chunk WHERE source_id = ?1 ORDER BY id LIMIT 1")
                    defer { sqlite3_finalize(statement) }
                    KnowledgeStore.bind(statement, [.text(meeting.id.uuidString)])
                    return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
                }
                guard source > 0 else { throw KnowledgeStoreError.open("the fixture wrote no passage") }
                var nodes = [GraphNodeRecord(id: node, type: "Meeting",
                                             fields: ["title": .text(meeting.title)],
                                             meetingID: meeting.id.uuidString, sourceChunk: source,
                                             observedAt: at)]
                var edges: [GraphEdgeRecord] = []
                func add(_ id: String, _ type: String, _ fields: [String: GraphFieldValue]) {
                    nodes.append(GraphNodeRecord(id: id, type: type, fields: fields, meetingID: nil,
                                                 sourceChunk: source, observedAt: at))
                }
                func edge(_ type: String, _ from: String, _ to: String) {
                    edges.append(GraphEdgeRecord(type: type, from: from, to: to,
                                                meetingID: meeting.id.uuidString, observedAt: at,
                                                validFrom: at, validTo: nil, sourceChunk: source))
                }
                if shares {
                    add(person, "Person", ["name": .text("Ana Ruiz")])
                    edge("attended", person, node)
                    add(topic, "Topic", ["label": .text("Pricing")])
                    edge("discussed", node, topic)
                }
                if project {
                    add(projectNode, "Project", ["name": .text("Atlas")])
                    edge("mentioned_in", projectNode, node)
                }
                return GraphBatch(meetingID: meeting.id.uuidString, nodes: nodes, edges: edges)
            }

            _ = try graph.replaceMeeting(try batch(live, shares: true, project: true))
            // The person in the room, the person who was in the room before, and a meeting
            // that shares only the project.
            _ = try graph.replaceMeeting(try batch(ana, shares: true, project: false))
            _ = try graph.replaceMeeting(try batch(stranger, shares: false, project: true))
            check("the map is reachable for the test that needs it", indexer.graph != nil)

            let found = await MeetingRecall.hits(meeting: live, filter: .related, indexer: indexer,
                                                 store: store, limit: 10)
            check("related finds the two meetings the map connects (\(found.map(\.title)))",
                  Set(found.map(\.meetingID)) == Set([ana.id, stranger.id]))
            check("related leaves the meeting in the room out", !found.contains { $0.meetingID == live.id })
            check("related names the person who was in both "
                    + "(\(found.first { $0.meetingID == ana.id }?.why ?? ""))",
                  found.first { $0.meetingID == ana.id }?.why == "Ana Ruiz was in both")
            check("related counts the person and the topic once each, not twice "
                    + "(\(found.first { $0.meetingID == ana.id }?.matchCount ?? 0))",
                  found.first { $0.meetingID == ana.id }?.matchCount == 2)
            check("related names the shared project "
                    + "(\(found.first { $0.meetingID == stranger.id }?.why ?? ""))",
                  found.first { $0.meetingID == stranger.id }?.why == "Same project: Atlas")
            check("the strongest connection comes first", found.first?.meetingID == ana.id)
            check("every related row carries a reason", !found.contains { $0.why.isEmpty })
            check("a related row names the person it connected through",
                  found.first { $0.meetingID == ana.id }?.people == ["Ana Ruiz"])
            let unmapped = Meeting(id: UUID(), title: "Nothing connected", start: now, status: .done)
            check("a meeting the map knows nothing about finds nothing",
                  (await MeetingRecall.hits(meeting: unmapped, filter: .related, indexer: indexer,
                                           store: store, limit: 10)).isEmpty)
            check("a map that is on is reported as available",
                  MeetingRecall.availability(indexEnabled: indexer.settings.enabled,
                                            graphEnabled: indexer.settings.graph,
                                            filter: .related) == .ready)
        } catch {
            failures.append("the related fixture failed: \(error.localizedDescription)")
        }

        stage("done")
        return failures
    }

    // MARK: - Fixtures

    /// Words a person must never be shown about a filter that cannot answer.
    private static let jargon = ["nil", "error", "graph", "index", "enabled", "null"]

    private static func hit(_ id: Int64, _ meeting: Meeting, score: Double, heading: String?) -> KnowledgeHit {
        KnowledgeHit(chunkID: id, kind: .notes, sourceID: meeting.id.uuidString, ordinal: 0,
                     text: "text \(id)", snippet: "text \(id)", startTime: nil, endTime: nil,
                     speaker: nil, heading: heading, occurredAt: meeting.start, score: score)
    }

    /// A searcher that cannot read anything — the case the whole slice turns on, because a
    /// filter that answers with a guess when its read fails is worse than one that admits
    /// it cannot answer.
    private final class UnreadableSearch: KnowledgeSearching, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        /// How many times `search` was reached, so "answered nothing" can be told apart
        /// from "was never asked".
        var asked: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
        func search(_ query: KnowledgeQuery) throws -> [KnowledgeHit] {
            lock.lock()
            calls += 1
            lock.unlock()
            throw KnowledgeStoreError.sqlite("selftest: the index could not be read")
        }
        func facets(_ query: KnowledgeQuery) throws -> KnowledgeFacets { KnowledgeFacets() }
    }

    /// A searcher that answers from a list, and remembers what it was asked.
    private final class StubSearch: KnowledgeSearching, @unchecked Sendable {
        private let lock = NSLock()
        private let hits: [KnowledgeHit]
        private var query: KnowledgeQuery?
        init(hits: [KnowledgeHit]) { self.hits = hits }
        var lastQuery: KnowledgeQuery? {
            lock.lock()
            defer { lock.unlock() }
            return query
        }
        func search(_ query: KnowledgeQuery) throws -> [KnowledgeHit] {
            lock.lock()
            self.query = query
            lock.unlock()
            return hits
        }
        func facets(_ query: KnowledgeQuery) throws -> KnowledgeFacets { KnowledgeFacets() }
    }
}
