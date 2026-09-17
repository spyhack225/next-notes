import Foundation

/// `--selftest-index`: build the index from fixture meeting folders and sessions, and report
/// chunks, bytes and wall time. Also the rules the index rests on — the chunker's cuts, the
/// foreign-key pragma and the cascade, the FTS5 mirror, generation idempotency and rollback,
/// yielding to recording, resuming a backfill, the deletion hooks (meeting delete, *Clear
/// conversation*, *Forget everything*), the settings gates, and deleting or corrupting
/// `knowledge.sqlite` rebuilding cleanly.
///
/// Everything lives in a temporary directory. No model, no network, no microphone.
@MainActor
enum KnowledgeIndexSelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

        // MARK: Isolation
        check("the shared indexer is not isolated under a self-test",
              !KnowledgeIndexer.shared.store.fileURL.path.hasPrefix(AppIdentity.applicationSupportDirectory.path)
                && !KnowledgeIndexer.shared.settings.enabled)

        failures += chunkerFailures()

        // MARK: Build from the fixture library
        let meetingsRoot = directory("Meetings")
        do {
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
        } catch {
            print("INDEX_FAILED: fixture library could not be written: \(error)")
            return false
        }
        let sources = FixtureKnowledgeSources(meetingsRoot: meetingsRoot)
        sources.sessions = [KnowledgeFixtures.conversation()]
        sources.dictationRuns = [KnowledgeDictation(id: KnowledgeFixtures.dictationID,
                                                    text: "Draft the pricing FAQ tonight", at: KnowledgeFixtures.pricingStart)]
        sources.routines = [KnowledgeRoutineRun(id: KnowledgeFixtures.routineRunID,
                                                text: "Morning brief: pricing launch is on Friday.",
                                                at: KnowledgeFixtures.hiringStart)]
        let environment = FixedKnowledgeIndexEnvironment(settings: KnowledgeIndexSettings(enabled: true))
        let store = KnowledgeStore(directory: directory("index"))
        // A fixed clock later than every fixture, so *Forget everything*'s watermark covers
        // the fixture sessions whatever the real date is.
        let indexer = KnowledgeIndexer(store: store, sources: sources, environment: environment,
                                       now: { Date(timeIntervalSince1970: 1_900_000_000) }, drainsOnChange: false)
        let pricing = KnowledgeFixtures.pricingID.uuidString

        let started = Date()
        let enqueued = await indexer.backfill()
        let first = await indexer.drain()
        let wall = Date().timeIntervalSince(started)
        guard case .finished(let pass) = first else {
            print("INDEX_FAILED: the first drain did not finish: \(first)")
            return false
        }
        check("backfill enqueued the wrong number of jobs (\(enqueued))", enqueued == 4)
        check("the build failed a job: \(pass.failures)", pass.failures.isEmpty)
        check("the build indexed \(pass.indexed) sources, deferred \(pass.deferred)", pass.indexed == 3 && pass.deferred == 1)
        let stats = (try? store.stats()) ?? KnowledgeIndexStats()
        print("INDEX_BUILD chunks=\(stats.chunks) sources=\(stats.sources) bytes=\(stats.bytes) "
              + "wall=\(String(format: "%.3f", wall))s "
              + "by-kind=\(stats.chunksByKind.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: ","))")
        check("transcript chunks \(stats.chunksByKind[.transcript] ?? 0), expected 9", stats.chunksByKind[.transcript] == 9)
        check("notes chunks \(stats.chunksByKind[.notes] ?? 0), expected 8", stats.chunksByKind[.notes] == 8)
        check("conversation chunks \(stats.chunksByKind[.conversation] ?? 0), expected 1", stats.chunksByKind[.conversation] == 1)
        check("dictation or routine indexed while their switches are off",
              stats.chunksByKind[.dictation] == nil && stats.chunksByKind[.routine] == nil)
        check("a recording meeting was indexed",
              (try? store.chunkCount(sourceID: KnowledgeFixtures.liveID.uuidString)) == 0)
        check("the FTS5 mirror does not match the chunk table",
              (try? store.mirroredCount()) == stats.chunks)
        check("integrity check failed: \((try? store.integrityProblems()) ?? ["threw"])",
              (try? store.integrityProblems()) == [])

        // MARK: Foreign keys on every connection, and the cascade
        do {
            check("PRAGMA foreign_keys is off on the first connection", try store.foreignKeysEnabled())
            store.close()
            check("PRAGMA foreign_keys is off on a reopened connection", try store.foreignKeysEnabled())
            try store.withConnection { db in
                try KnowledgeStore.exec(db, """
                    INSERT INTO embedding (chunk_id, model, dims, vector)
                    SELECT id, 'selftest', 1, x'00000000' FROM chunk WHERE source_kind = 'notes' AND source_id = '\(pricing)'
                    """)
            }
            let embedded = try store.withConnection { db in try KnowledgeStore.int(db, "SELECT count(*) FROM embedding") }
            check("the embedding fixture did not insert", embedded == 6)
            try KnowledgeFixtures.writeNotes(root: meetingsRoot, id: KnowledgeFixtures.pricingID,
                                             notes: KnowledgeFixtures.pricingNotes.replacingOccurrences(
                                                of: "Ship the pricing page on Friday.", with: "Ship the pricing page on Monday."))
            let oldGeneration = try store.generations(kind: .notes, sourceID: pricing)
            indexer.meetingChanged(KnowledgeFixtures.pricingID)
            _ = await indexer.drain()
            let newGeneration = try store.generations(kind: .notes, sourceID: pricing)
            check("regenerate left \(newGeneration.count) generations", newGeneration.count == 1)
            check("regenerate did not bump the generation", newGeneration != oldGeneration)
            let orphans = try store.withConnection { db in try KnowledgeStore.int(db, "SELECT count(*) FROM embedding") }
            check("ON DELETE CASCADE left \(orphans) orphaned embeddings", orphans == 0)
            let monday = try KeywordKnowledgeSearch(store: store).search(KnowledgeQuery(text: "monday"))
            let friday = try KeywordKnowledgeSearch(store: store)
                .search(KnowledgeQuery(text: "friday", filter: KnowledgeFilter(kinds: [.notes])))
            check("the new generation is not searchable", monday.contains { $0.kind == .notes })
            check("the old generation is still searchable", friday.isEmpty)
            check("the mirror drifted after a regenerate", try store.mirroredCount() == store.chunkCount())
        } catch {
            failures.append("foreign keys / regenerate threw: \(error.localizedDescription)")
        }

        // MARK: Idempotent: a second pass writes nothing
        do {
            let before = try store.chunkCount()
            await indexer.backfill()
            if case .finished(let again) = await indexer.drain() {
                check("an unchanged library was rewritten (indexed \(again.indexed))", again.indexed == 0 && again.unchanged == 2)
                check("an indexed ended session was enqueued again", !indexer.pending.contains(.conversation(KnowledgeFixtures.sessionID)))
            } else {
                failures.append("the second drain did not finish")
            }
            check("a second pass changed the chunk count", try store.chunkCount() == before)
        } catch {
            failures.append("idempotency threw: \(error.localizedDescription)")
        }

        // MARK: A failed replace rolls back and leaves the old generation whole
        do {
            let before = try store.generations(kind: .transcript, sourceID: pricing)
            let count = try store.chunkCount(kind: .transcript, sourceID: pricing)
            let broken = [KnowledgeChunk(ordinal: 0, text: "rollback one", occurredAt: 1),
                          KnowledgeChunk(ordinal: 0, text: "rollback two", occurredAt: 1)]
            let threw = (try? store.replace(kind: .transcript, sourceID: pricing, chunks: broken)) == nil
            check("a duplicate ordinal did not fail the transaction", threw)
            check("a failed replace changed the old generation",
                  try store.generations(kind: .transcript, sourceID: pricing) == before
                    && store.chunkCount(kind: .transcript, sourceID: pricing) == count)
            check("a rolled-back row is searchable",
                  try KeywordKnowledgeSearch(store: store).search(KnowledgeQuery(text: "rollback")).isEmpty)
        } catch {
            failures.append("rollback threw: \(error.localizedDescription)")
        }

        // MARK: Yields to recording
        environment.isRecording = true
        indexer.meetingChanged(KnowledgeFixtures.hiringID)
        if case .waiting = await indexer.drain() {
            check("a waiting drain dropped its queue", indexer.pending == [.meeting(KnowledgeFixtures.hiringID)])
        } else {
            failures.append("the indexer ran while recording")
        }
        environment.isRecording = false
        if case .finished = await indexer.drain() {
            check("the queue was not drained after recording stopped", indexer.pending.isEmpty)
        } else {
            failures.append("the indexer did not resume after recording stopped")
        }

        // MARK: Deleting a meeting removes its chunks
        do {
            try FileManager.default.removeItem(at: meetingsRoot.appendingPathComponent(pricing, isDirectory: true))
            indexer.removeMeeting(KnowledgeFixtures.pricingID)
            check("deleting a meeting left chunks", try store.chunkCount(sourceID: pricing) == 0)
            check("a deleted meeting is still searchable",
                  try KeywordKnowledgeSearch(store: store).search(KnowledgeQuery(text: "decided pricing", filter: KnowledgeFilter(sourceIDs: [pricing]))).isEmpty)
            // A meeting removed while the app was closed goes at the next backfill.
            let hiring = KnowledgeFixtures.hiringID.uuidString
            try FileManager.default.removeItem(at: meetingsRoot.appendingPathComponent(hiring, isDirectory: true))
            await indexer.backfill()
            check("a meeting deleted while closed kept its chunks", try store.chunkCount(sourceID: hiring) == 0)
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
        } catch {
            failures.append("meeting deletion threw: \(error.localizedDescription)")
        }

        // MARK: Clear conversation and Forget everything remove conversation chunks
        do {
            let clock = FakeClock()
            let session = AgentSession(fileURL: directory("session").appendingPathComponent(AgentSession.fileName),
                                       now: clock.now, idleMinutes: { 30 })
            let memory = NextMemory(directory: directory("memory"))
            indexer.connect(session: session, memory: memory)

            session.recordUser("Remind me what we said about the newsletter launch", source: .text)
            session.recordAssistant("The newsletter launch follows the pricing page.", source: .text)
            clock.advance(31 * 60)
            check("an idle session did not end", session.endSessionIfIdle())
            _ = await indexer.drain()
            check("an ended session was not indexed", try store.chunkCount(kind: .conversation) == 2)

            session.recordUser("And the podcast launch?", source: .text)
            session.clear()
            check("Clear conversation left conversation chunks", try store.chunkCount(kind: .conversation) == 0)
            check("Clear conversation indexed the cleared session", indexer.pending.isEmpty)

            session.recordUser("Remember the newsletter goes out on Tuesdays", source: .text)
            clock.advance(31 * 60)
            session.endSessionIfIdle()
            _ = await indexer.drain()
            check("a later session was not indexed", try store.chunkCount(kind: .conversation) == 1)
            try memory.forgetEverything()
            check("Forget everything left conversation chunks", try store.chunkCount(kind: .conversation) == 0)
            check("a cleared conversation is searchable",
                  try KeywordKnowledgeSearch(store: store).search(KnowledgeQuery(text: "tuesdays")).isEmpty)

            // Forget everything leaves `agent-conversation.json` alone: a later backfill must
            // not index the forgotten sessions again, but a session after it still indexes.
            let later = Date(timeIntervalSince1970: 1_900_000_100)
            let afterForget = KnowledgeConversationSession(id: UUID(), rows: [
                KnowledgeConversationRow(role: "user", text: "What is the podcast budget?", source: "text", at: later),
                KnowledgeConversationRow(role: "assistant", text: "Twelve hundred a month.", source: "text", at: later),
            ])
            sources.sessions = [KnowledgeFixtures.conversation()]
                + session.endedSessions().map(KnowledgeIndexer.conversationSession)
            await indexer.backfill()
            _ = await indexer.drain()
            check("a backfill after Forget everything indexed forgotten sessions",
                  try store.chunkCount(kind: .conversation) == 0)
            sources.sessions.append(afterForget)
            await indexer.backfill()
            _ = await indexer.drain()
            check("a session after Forget everything was not indexed",
                  try store.chunkCount(kind: .conversation) == 1
                    && store.chunkCount(kind: .conversation, sourceID: afterForget.id.uuidString) == 1)
            indexer.removeConversations()
            sources.sessions = [KnowledgeFixtures.conversation()]
        } catch {
            failures.append("conversation hooks threw: \(error.localizedDescription)")
        }

        // MARK: Settings gates
        do {
            environment.settings = KnowledgeIndexSettings(enabled: true, includeConversations: false,
                                                          includeDictation: true, includeRoutines: true)
            await indexer.backfill()
            _ = await indexer.drain()
            check("dictation was not indexed when included", try store.chunkCount(kind: .dictation) == 1)
            check("a routine run was not indexed when included", try store.chunkCount(kind: .routine) == 1)
            check("conversations were indexed while excluded", try store.chunkCount(kind: .conversation) == 0)
            indexer.removeDictations([KnowledgeFixtures.dictationID])
            check("deleting a dictation left its chunk", try store.chunkCount(kind: .dictation) == 0)
            environment.settings = KnowledgeIndexSettings(enabled: true)
            await indexer.backfill()
            _ = await indexer.drain()
            check("excluding routines did not remove them", try store.chunkCount(kind: .routine) == 0)

            let offStore = KnowledgeStore(directory: directory("off"))
            let off = KnowledgeIndexer(store: offStore, sources: sources,
                                       environment: FixedKnowledgeIndexEnvironment(), drainsOnChange: false)
            let offEnqueued = await off.backfill()
            off.meetingChanged(KnowledgeFixtures.pricingID)
            let offResult = await off.drain()
            off.removeMeeting(KnowledgeFixtures.pricingID)
            check("the index did work while off", offEnqueued == 0 && offResult == .disabled && off.pending.isEmpty)
            check("an index that is off created knowledge.sqlite", !offStore.existsOnDisk)
            check("recall reads an index that is off", off.recall == nil)
        } catch {
            failures.append("settings gates threw: \(error.localizedDescription)")
        }

        // MARK: Resume a backfill interrupted part-way
        do {
            let resumeStore = KnowledgeStore(directory: directory("resume"))
            let quitting = KnowledgeIndexer(store: resumeStore, sources: sources, environment: environment, drainsOnChange: false)
            await quitting.backfill()
            _ = await quitting.drain(maxJobs: 1)
            let partial = try resumeStore.chunkCount()
            // The app quits; the next launch backfills again with a new indexer.
            let relaunched = KnowledgeIndexer(store: resumeStore, sources: sources, environment: environment, drainsOnChange: false)
            await relaunched.backfill()
            guard case .finished(let resumed) = await relaunched.drain() else {
                throw KnowledgeStoreError.sqlite("the resumed drain did not finish")
            }
            let full = try store.chunkCount()
            check("the interrupted pass wrote nothing or everything (\(partial))", partial > 0 && partial < full)
            check("a resumed backfill redid finished work (unchanged \(resumed.unchanged))", resumed.unchanged == 1)
            check("a resumed backfill does not match a full one", try resumeStore.chunkCount() == full)
        } catch {
            failures.append("resume threw: \(error.localizedDescription)")
        }

        // MARK: rm knowledge.sqlite while the connection is open
        do {
            let before = try store.chunkCount()
            try FileManager.default.removeItem(at: store.fileURL)
            check("rm left the database", !store.existsOnDisk)
            check("search read the removed file through the open connection",
                  try KeywordKnowledgeSearch(store: store).search(KnowledgeQuery(text: "decided pricing")).isEmpty)
            await indexer.backfill()
            _ = await indexer.drain()
            check("a rebuild after an external rm has \(try store.chunkCount()) chunks, expected \(before)",
                  try store.chunkCount() == before)

            try FileManager.default.removeItem(at: store.fileURL)
            try FileManager.default.removeItem(at: meetingsRoot.appendingPathComponent(pricing, isDirectory: true))
            indexer.removeMeeting(KnowledgeFixtures.pricingID)
            await indexer.backfill()
            _ = await indexer.drain()
            check("a meeting deleted after an external rm is searchable",
                  try KeywordKnowledgeSearch(store: store).search(KnowledgeQuery(
                    text: "decided pricing", filter: KnowledgeFilter(sourceIDs: [pricing]))).isEmpty)
            check("stats after an external rm do not match search",
                  indexer.stats.chunks == (try store.chunkCount()) && indexer.stats.chunks > 0)
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
            await indexer.backfill()
            _ = await indexer.drain()
            check("the library after an external rm has \(try store.chunkCount()) chunks, expected \(before)",
                  try store.chunkCount() == before)
        } catch {
            failures.append("external rm threw: \(error.localizedDescription)")
        }

        // MARK: rm knowledge.sqlite rebuilds cleanly; a corrupt file too
        do {
            let before = try store.chunkCount()
            let generations = try store.indexedSources(kind: .transcript).merging(store.indexedSources(kind: .notes)) { $0 &+ $1 }
            store.deleteFile()
            check("deleteFile left the database", !store.existsOnDisk)
            await indexer.backfill()
            _ = await indexer.drain()
            check("a rebuild after rm has \(try store.chunkCount()) chunks, expected \(before)", try store.chunkCount() == before)
            check("a rebuild after rm changed generations",
                  try store.indexedSources(kind: .transcript).merging(store.indexedSources(kind: .notes)) { $0 &+ $1 } == generations)

            store.close()
            try Data(repeating: 0x5A, count: 8_192).write(to: store.fileURL)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: store.fileURL.path + suffix) }
            check("a corrupt file was not replaced", try store.chunkCount() == 0)
            await indexer.rebuild()
            check("Rebuild index after corruption has \(try store.chunkCount()) chunks", try store.chunkCount() == before)
            check("integrity after rebuild", try store.integrityProblems().isEmpty && store.mirroredCount() == before)
            let rebuilt = (try? store.stats()) ?? KnowledgeIndexStats()
            print("INDEX_REBUILD chunks=\(rebuilt.chunks) bytes=\(rebuilt.bytes)")
        } catch {
            failures.append("rebuild threw: \(error.localizedDescription)")
        }

        for failure in failures { print("INDEX_WRONG: \(failure)") }
        print(failures.isEmpty ? "INDEX_OK" : "INDEX_FAILED")
        return failures.isEmpty
    }

    // MARK: - Chunker rules

    private static func chunkerFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let start = KnowledgeFixtures.pricingStart
        let chunks = Chunker.transcript(KnowledgeFixtures.pricingSegments(), meetingStart: start,
                                        speakerNames: ["Speaker 1": "Ana"])
        print("CHUNKER transcript=\(chunks.count) words=\(chunks.map { Chunker.wordCount($0.text) })")
        check("transcript chunk count \(chunks.count), expected 7", chunks.count == 7)
        if chunks.count == 7 {
            check("the first cut was not at the pause after ~150 words", Chunker.wordCount(chunks[0].text) == 180)
            check("a length cut did not overlap by one segment",
                  chunks[1].text.hasPrefix(KnowledgeFixtures.filler(20, seed: 8)) && chunks[1].startTime == KnowledgeFixtures.pricingSegments()[8].start)
            check("a speaker change carried an overlap", chunks[2].text == "What about the pricing page timing?"
                  && chunks[2].speaker == "You")
            check("the decision chunk lost its timing or speaker",
                  chunks[3].startTime == KnowledgeFixtures.decisionStart && chunks[3].endTime == KnowledgeFixtures.decisionEnd
                    && chunks[3].speaker == "Ana"
                    && chunks[3].occurredAt == Int64(start.timeIntervalSince1970 + KnowledgeFixtures.decisionStart))
            check("a chunk passed the hard cut", chunks.allSatisfy { Chunker.wordCount($0.text) <= Chunker.hardWords })
            check("the long monologue was not split", chunks[5].startTime == 400 && chunks[6].endTime == 520)
            check("ordinals are not positions", chunks.enumerated().allSatisfy { $0.offset == $0.element.ordinal })
        }
        check("an agent command was indexed", !chunks.contains { $0.text.contains("add a reminder") })

        // A short run, then one long segment: the hard cut still holds.
        let longAfterShort = Chunker.transcript([
            TranscriptSegment(start: 0, end: 50, text: KnowledgeFixtures.filler(140), source: .system, speaker: "Speaker 1"),
            TranscriptSegment(start: 50, end: 140, text: KnowledgeFixtures.filler(250, seed: 3), source: .system, speaker: "Speaker 1"),
        ], meetingStart: start)
        check("a short run and a long segment passed the hard cut: \(longAfterShort.map { Chunker.wordCount($0.text) })",
              longAfterShort.count == 2 && longAfterShort.allSatisfy { Chunker.wordCount($0.text) <= Chunker.hardWords })

        let notes = Chunker.notes(KnowledgeFixtures.pricingNotes, meetingStart: start)
        check("notes chunk count \(notes.count), expected 6", notes.count == 6)
        check("a notes chunk lost its heading", notes.first { $0.text.hasPrefix("Ship the pricing page") }?.heading == "Decisions")
        check("a bullet continuation was not joined",
              notes.contains { $0.heading == "Action items" && $0.text == "Ana — publish the pricing page and announce it in the newsletter." })
        check("_None._ became a passage", !notes.contains { $0.text.contains("None") })
        check("a summary paragraph was lost", notes.first?.heading == "Summary" && notes.first?.startTime == nil)

        let conversation = Chunker.conversation(KnowledgeFixtures.conversation().rows)
        check("conversation chunks \(conversation.count), expected 1", conversation.count == 1)
        check("a conversation chunk carried tool output, a meeting line or the routine offer",
              conversation.first?.text == "User: When does the pricing page ship?\nAgent: On Friday, as decided in the pricing review.")

        let dictation = Chunker.dictation(KnowledgeDictation(id: UUID(), text: "  one   whole run ", at: start))
        check("a dictation was not one whole chunk", dictation.map(\.text) == ["one whole run"])
        check("an empty dictation became a chunk",
              Chunker.dictation(KnowledgeDictation(id: UUID(), text: "  ", at: start)).isEmpty)

        let generation = KnowledgeStore.generation(of: notes)
        check("generation is not deterministic", generation == KnowledgeStore.generation(of: notes))
        var edited = notes
        edited[0].text += " Edited."
        check("generation did not change with the text", generation != KnowledgeStore.generation(of: edited))
        check("generation is not positive", generation > 0)
        return failures
    }

    private final class FakeClock {
        private var current = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { current }
        func advance(_ seconds: TimeInterval) { current += seconds }
    }
}
