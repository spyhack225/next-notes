import Foundation
import SQLite3

/// `--selftest-imessage-watch` — NextNotes-iMessage IM-06.
///
/// The WAL watcher: one file event is not one message, two idempotency mechanisms, ordered
/// replay, a per-message settling deadline, and a body that could not be decoded.
///
/// **No Full Disk Access, no iPhone, no grant, and no live database.** Every case runs
/// against a *copy* of the sanitised corpus in `Tests/Fixtures/chatdb/`, built into this
/// process's own temporary directory by `make-chatdb-fixture.sh` and thrown away
/// afterwards. The one case that writes anything writes to that copy — a join row the
/// settling race has to appear at a chosen moment, rows the replay case needs — and never
/// to a path under `~/Library/Messages/`.
///
/// ## How it does not depend on filesystem timing
///
/// Three injections, and the reason each exists:
///
/// - **The event source.** `MessagesFileEventSource` is a value holding a closure, so the
///   test raises an event by calling one rather than by writing to a `-wal` and hoping.
///   Without it every case below would be a race against SQLite's checkpoint cadence, and
///   the debounce would be a real wait in the measurement of the very thing it debounces.
/// - **The clock and the sleep.** `MessagesWatcherClock` carries both, so a debounce costs
///   no wall time and the settling race's 8 waits over 2 s can be asserted exactly on any
///   machine. One case deliberately uses `.live` instead, because the per-message
///   independence claim is about real milliseconds and a virtual clock cannot make it.
/// - **The debounce gate.** `GateClock` parks the debounce until the test releases it,
///   which is what makes "five events, one pass" a fact rather than a hope.
///
/// ## The four claims that carry the weight
///
/// 1. `one_event_three_rows_in_rowid_order` — one event, three envelopes, in `ROWID` order.
/// 2. `three_events_one_row_one_envelope` — repeated events are one envelope, **and** the
///    rewind half proves the GUID cache is the reason rather than the row id.
/// 3. `replay_after_restart_emits_only_new_rows` — a stale persisted watermark replaying
///    from `ROWID 40` emits nothing for 40–60 and emits 61. This is the case the roadmap
///    names as the one that proves the second idempotency mechanism.
/// 4. `per_message_deadline_does_not_delay_the_next_message` — a row whose join row never
///    arrives does not hold up the rows behind it, with the measured milliseconds printed
///    as `IMESSAGE_WATCH_MEASURED:` so the evidence is in the transcript and not in a
///    claim in a report.
///
/// The final line is `IMESSAGE_WATCH_OK: <n> cases` or
/// `IMESSAGE_WATCH_FAILED: <reason>`. Per-case diagnostics are `IMESSAGE_WATCH_WRONG: …`
/// and the timing evidence is `IMESSAGE_WATCH_MEASURED: …`; neither is a verdict token.
@MainActor
enum MessagesWatcherSelfTest {
    /// The one chat guid every fixture this test uses shares. `delayed-attachment-join`,
    /// `empty-attributed-body`, `both-paths` and `direct-message` are all the same DM, so
    /// a filter written against one is written against all four.
    static let pairedChatGUID = "iMessage;-;+15550000001"

    static func run() async -> String {
        var failures: [String] = []
        var measured: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () async throws -> String?) async rethrows {
            caseCount += 1
            do {
                if let problem = try await body() { failures.append("\(name): \(problem)") }
            } catch {
                failures.append("\(name): threw \(error)")
            }
        }

        func note(_ line: String) { measured.append(line) }

        do {
            let corpus = try WatchCorpus.build()
            defer { corpus.discard() }

            // 1. One file event, three rows, three envelopes, in ROWID order.
            //
            // `direct-message` already holds two text rows; a third is added so the case is
            // "one event carrying three rows" rather than two, and the ordering is the claim
            // — a watcher that delivered in query order, in GUID order, or in whatever order
            // a detached task happened to finish would fail this.
            try await check("one_event_three_rows_in_rowid_order") {
                let root = corpus.copy("direct-message", as: "ordering")
                try WatchStaging.insertMessage(at: root, rowID: 3, guid: "FIXTURE-WATCH-ORDER-0003",
                                               text: "FIXTURE-WATCH-ORDER-BODY-3", inChatRowID: 1)
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID)
                await rig.arm()
                rig.bus.fireAll()
                guard await rig.waitForDeliveries(3) else {
                    return "three rows arrived behind one event and \(await rig.deliveryCount()) came out"
                }
                let deliveries = await rig.deliveries()
                guard deliveries.map(\.envelope.rowID) == [1, 2, 3] else {
                    return "row order is \(deliveries.map(\.envelope.rowID))"
                }
                let stats = await rig.watcher.statistics()
                if stats.delivered != 3 { return "delivered \(stats.delivered), not 3" }
                if stats.deferred != 0 { return "\(stats.deferred) rows were deferred; none claims an attachment" }
                if stats.attachmentQueries != 0 {
                    return "\(stats.attachmentQueries) attachment queries for three rows that claim none"
                }
                return nil
            }

            // 2. Three events carrying the same row emit one envelope — and the rewind half
            // is what makes that the *GUID cache's* doing rather than the row id's.
            //
            // `empty-attributed-body` because it is the one fixture holding exactly one
            // row, so "one row, one envelope" is a statement rather than a sum. Its body is
            // the `X'0001'` sentinel, which is irrelevant here and is case 5's job.
            try await check("three_events_one_row_one_envelope") {
                let root = corpus.copy("empty-attributed-body", as: "idempotent")
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID)
                await rig.arm()
                for _ in 0..<3 {
                    let before = await rig.passes()
                    rig.bus.fireAll()
                    guard await rig.waitForPasses(atLeast: before + 1) else {
                        return "an event produced no pass"
                    }
                }
                guard await rig.deliveryCount() == 1 else {
                    return "three events on one row produced \(await rig.deliveryCount()) envelopes"
                }
                // Rewind the row id to 0 with the guid cache intact: the shape of a crash
                // between "delivered" and "persisted". The row id alone would re-deliver.
                await rig.watcher.rewindWatermark(to: 0)
                let beforeRewind = await rig.passes()
                rig.bus.fireAll()
                guard await rig.waitForPasses(atLeast: beforeRewind + 1) else {
                    return "the pass after the rewind did not run"
                }
                guard await rig.deliveryCount() == 1 else {
                    return "after a rewind the same row was delivered \(await rig.deliveryCount()) times"
                }
                let stats = await rig.watcher.statistics()
                guard stats.skippedByGUID == 1 else {
                    return "\(stats.skippedByGUID) rows were skipped, and the guid cache should have refused exactly 1"
                }
                return nil
            }

            // 3. The replay. 40–60 are delivered, the watermark is then restored to the
            // stale 39 that was persisted before them, row 61 lands, and one pass must emit
            // 61 alone. This is the case the roadmap names as the one that needs the guid
            // cache: with only a row id, all twenty-two rows would be re-delivered.
            try await check("replay_after_restart_emits_only_new_rows") {
                let root = corpus.copy("direct-message", as: "replay")
                for rowID in 40...60 {
                    try WatchStaging.insertMessage(at: root, rowID: Int64(rowID),
                                                   guid: "FIXTURE-WATCH-REPLAY-\(rowID)",
                                                   text: "FIXTURE-WATCH-REPLAY-BODY-\(rowID)",
                                                   inChatRowID: 1)
                }
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID,
                                       watermark: MessagesWatermark(snapshot: .init(lastProcessedRowID: 39,
                                                                                    processedMessageGUIDs: [])))
                await rig.arm()
                rig.bus.fireAll()
                guard await rig.waitForDeliveries(21) else {
                    return "the first pass delivered \(await rig.deliveryCount()) of 21 rows (40…60)"
                }
                let firstPass = await rig.deliveries().map(\.envelope.rowID)
                guard firstPass == (40...60).map(Int64.init) else {
                    return "the first pass was not 40…60 in order: \(firstPass)"
                }
                // The crash: a snapshot holding the row id from before the pass, and the
                // guid cache the watcher had built by the time it stopped.
                let snapshot = await rig.watcher.currentWatermark().snapshot()
                try WatchStaging.insertMessage(at: root, rowID: 61, guid: "FIXTURE-WATCH-REPLAY-0061",
                                               text: "FIXTURE-WATCH-REPLAY-BODY-61", inChatRowID: 1)
                var stale = snapshot
                stale.lastProcessedRowID = 39
                await rig.watcher.restore(stale)
                let replayed = await rig.deliveries().map(\.envelope.rowID)
                guard replayed.dropFirst(21) == [61] else {
                    return "the replay after a restart emitted \(replayed.dropFirst(21)), expected [61]"
                }
                let stats = await rig.watcher.statistics()
                guard stats.skippedByGUID == 21 else {
                    return "\(stats.skippedByGUID) rows were refused by the guid cache, expected 21 (40…60)"
                }
                return nil
            }

            // 4a. The settling race itself. The fixture ships with the message row claiming
            // an attachment, the attachment row present, and **zero** join rows — and the
            // clock hands the join row over on the third wait, which is the moment the
            // roadmap names. A virtual clock is what makes "the third refetch" an exact
            // number rather than a number that depends on the machine.
            try await check("settling_race_refetches_until_the_join_row_lands") {
                let root = corpus.copy("delayed-attachment-join", as: "settling")
                let clock = ManualClock()
                clock.onWait = { wait in
                    if wait == 3 {
                        try? WatchStaging.insertJoinRow(at: root, rowID: 1, messageRowID: 1, attachmentRowID: 1)
                    }
                }
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID, resolverClock: clock.clock)
                await rig.arm()
                rig.bus.fireAll()
                guard await rig.waitForDeliveries(1, timeout: 10) else {
                    return "the row never settled: \(await rig.deliveryCount()) envelopes"
                }
                let delivery = await rig.deliveries().first
                guard let delivery else { return "nothing was delivered" }
                guard case .resolved(let retries, let found) = delivery.resolution else {
                    return "the resolution is \(delivery.resolution), expected .resolved"
                }
                guard retries == 3 else { return "settled after \(retries) waits, expected 3" }
                guard found.count == 1, found[0].guid == "FIXTURE-ATT-SETTLE-0001" else {
                    return "the joined attachment is \(found.map(\.guid))"
                }
                guard clock.waits == 3 else { return "the resolver waited \(clock.waits) times" }
                note("settling: 3 waits × \(AttachmentJoinResolver.Policy().retryInterval) = "
                     + "\(3 * 250)ms of virtual time, then resolved with 1 attachment")
                return nil
            }

            // 4b. The per-message deadline, measured. A never-settling row and two text rows
            // behind it, one event, and the **real** clock: the claim is about
            // milliseconds, so a virtual clock cannot make it. The text rows must arrive
            // long before the settling row's budget is spent — not "before 2 s", which is
            // what a global deadline would also produce, but *immediately*.
            try await check("per_message_deadline_does_not_delay_the_next_message") {
                let root = corpus.copy("delayed-attachment-join", as: "deadline")
                try WatchStaging.insertMessage(at: root, rowID: 2, guid: "FIXTURE-WATCH-DEADLINE-0002",
                                               text: "FIXTURE-WATCH-DEADLINE-BODY-2", inChatRowID: 1)
                try WatchStaging.insertMessage(at: root, rowID: 3, guid: "FIXTURE-WATCH-DEADLINE-0003",
                                               text: "FIXTURE-WATCH-DEADLINE-BODY-3", inChatRowID: 1)
                let clock = MessagesWatcherClock.live
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID, resolverClock: clock)
                await rig.arm()
                let started = clock.seconds()
                rig.bus.fireAll()
                // The two text rows, which the settling row is not allowed to hold up.
                guard await rig.waitForDeliveries(2, timeout: 10) else {
                    return "the two text rows behind a settling row took longer than 10 s"
                }
                let textRowsAt = clock.seconds() - started
                guard await rig.waitForDeliveries(3, timeout: 10) else {
                    return "the settling row never gave up"
                }
                let settledAt = clock.seconds() - started
                let order = await rig.deliveries().map(\.envelope.rowID)
                guard order == [2, 3, 1] else {
                    return "delivery order is \(order); the settling row must not hold the rows behind it"
                }
                let resolution = await rig.deliveries().last?.resolution
                guard case .unresolved(let retries) = resolution else {
                    return "the settling row's resolution is \(String(describing: resolution))"
                }
                guard retries == AttachmentJoinResolver.Policy().maxRetries else {
                    return "gave up after \(retries) waits, expected \(AttachmentJoinResolver.Policy().maxRetries)"
                }
                // The debounce is 80 ms, so a text row delivered inside a few hundred
                // milliseconds is proof the 2 s budget belonged to row 1 alone.
                guard textRowsAt < 1.0 else {
                    return "the text rows waited \(String(format: "%.0f", textRowsAt * 1000))ms behind a settling row"
                }
                guard settledAt > 1.5 else {
                    return "the settling row gave up after \(String(format: "%.0f", settledAt * 1000))ms, "
                        + "which is inside its 2 s budget rather than at it"
                }
                note(String(format: "per_message_deadline: rows 2 and 3 delivered at %.0fms, "
                            + "row 1 (never settles) at %.0fms, budget %d × %dms = %dms",
                            textRowsAt * 1000, settledAt * 1000,
                            AttachmentJoinResolver.Policy().maxRetries, 250,
                            AttachmentJoinResolver.Policy().maxRetries * 250))
                return nil
            }

            // 5. A body this Mac could not read still advances the watermark and is still
            // delivered — and the row behind it still comes through. A watcher that stopped
            // at an unreadable body would wedge on that row and on every message after it,
            // and the body being unreadable says nothing about the next one.
            try await check("undecodable_body_still_advances_the_watermark") {
                let root = corpus.copy("empty-attributed-body", as: "unreadable")
                try WatchStaging.insertMessage(at: root, rowID: 2, guid: "FIXTURE-WATCH-AFTER-0002",
                                               text: "FIXTURE-WATCH-AFTER-BODY-2", inChatRowID: 1)
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID)
                await rig.arm()
                rig.bus.fireAll()
                guard await rig.waitForDeliveries(2) else {
                    return "an undecodable row wedged the pass: \(await rig.deliveryCount()) of 2 arrived"
                }
                let deliveries = await rig.deliveries()
                let unreadable = deliveries[0]
                guard unreadable.envelope.rowID == 1 else {
                    return "the first delivery is row \(unreadable.envelope.rowID)"
                }
                guard case .unreadable = unreadable.envelope.decodeState else {
                    return "row 1's decode state is \(unreadable.envelope.decodeState), expected .unreadable"
                }
                guard unreadable.envelope.text == nil else {
                    return "an undecodable body decoded to a value"
                }
                guard deliveries[1].envelope.rowID == 2, deliveries[1].envelope.text != nil else {
                    return "the row behind the undecodable one did not decode"
                }
                let watermark = await rig.watcher.currentWatermark()
                guard watermark.lastProcessedRowID == 2 else {
                    return "the watermark is \(watermark.lastProcessedRowID) after delivering row 2"
                }
                guard watermark.isKnown(guid: unreadable.envelope.guid) else {
                    return "the undecodable row's guid was not claimed, so a rewind would deliver it twice"
                }
                // A second event must add nothing, which is the same watermark doing its job
                // one event later.
                rig.bus.fireAll()
                try? await Task.sleep(for: .milliseconds(300))
                guard await rig.deliveryCount() == 2 else {
                    return "a later event re-delivered an unreadable row: \(await rig.deliveryCount())"
                }
                return nil
            }

            // 6. The paired-chat filter. A row in another conversation is not read at all —
            // `messages(after:chatGUID:)` never returns it — so this is a claim about the
            // query and not about a filter applied afterwards. The second half removes the
            // filter and shows the row is there and readable, so a pass is not passing
            // because the fixture is empty.
            try await check("a_non_paired_chat_emits_nothing") {
                let root = corpus.copy("direct-message", as: "paired")
                try WatchStaging.insertChat(at: root, rowID: 2, guid: "iMessage;+;FIXTURE-UNPAIRED-CHAT",
                                            identifier: "FIXTURE-UNPAIRED")
                // ROWID 3, not 2: `direct-message` already has a row 2 in the paired chat,
                // and two rows cannot share a primary key.
                try WatchStaging.insertMessage(at: root, rowID: 3, guid: "FIXTURE-WATCH-OTHER-0003",
                                               text: "FIXTURE-WATCH-OTHER-BODY-3", inChatRowID: 2)
                let paired = try WatchRig(root: root, chatGUID: Self.pairedChatGUID)
                await paired.arm()
                await paired.watcher.drainNow()
                let pairedRows = await paired.deliveries().map(\.envelope.rowID)
                guard pairedRows == [1, 2] else {
                    return "with the filter on the rows are \(pairedRows); the unpaired chat's row 3 must not be among them"
                }
                let stats = await paired.watcher.statistics()
                guard stats.rowsRead == 2 else {
                    return "the filtered query read \(stats.rowsRead) rows; `direct-message` holds 2 in the paired chat"
                }
                // The same database, no filter: the other row is there all along.
                let unfiltered = try WatchRig(root: root, chatGUID: nil)
                await unfiltered.arm()
                await unfiltered.watcher.drainNow()
                let both = await unfiltered.deliveries().map(\.envelope.rowID)
                guard both == [1, 2, 3] else {
                    return "without the filter the rows are \(both), expected [1, 2, 3]"
                }
                return nil
            }

            // 7. Five events inside one debounce window, one query. The gate parks the
            // debounce until the test lets it go, so this is a fact about the code rather
            // than a race that usually coalesces.
            try await check("five_events_coalesce_into_one_pass") {
                let root = corpus.copy("direct-message", as: "coalesce")
                let gate = GateClock()
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID, debounceClock: gate.clock)
                await rig.arm()
                for _ in 0..<5 { rig.bus.fireAll() }
                try? await Task.sleep(for: .milliseconds(200))
                let parked = await rig.watcher.statistics()
                guard parked.passes == 0, parked.delivered == 0 else {
                    return "a pass ran while the debounce was still parked "
                        + "(\(parked.passes) passes, \(parked.delivered) delivered)"
                }
                gate.release()
                guard await rig.waitForDeliveries(2) else {
                    return "releasing the debounce delivered \(await rig.deliveryCount()) of 2 rows"
                }
                let after = await rig.watcher.statistics()
                guard after.passes == 1 else { return "\(after.passes) passes for five events" }
                return nil
            }

            // 8. The negative requirement, as a measurement. A watcher that polls would
            // move `passes` and `attachmentQueries` during a second and a half of doing
            // nothing at all, and nothing in a code review would have said so.
            try await check("idle_costs_nothing") {
                let root = corpus.copy("direct-message", as: "idle")
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID)
                await rig.arm()
                // Armed, so the window below is silence rather than a watcher that was never
                // watching — otherwise this case passes in a build where nothing works.
                guard !rig.bus.armedPaths.isEmpty else {
                    return "the watcher armed nothing, so the window below would prove nothing"
                }
                let before = await rig.watcher.statistics()
                let started = MessagesWatcherClock.live.seconds()
                try await Task.sleep(for: .milliseconds(1500))
                let window = MessagesWatcherClock.live.seconds() - started
                let after = await rig.watcher.statistics()
                guard after == before else {
                    return "an idle watcher did work: \(before) → \(after)"
                }
                note(String(format: "idle: %.0fms armed and silent, passes 0, attachment queries 0", window * 1000))
                return nil
            }

            // 9. The resolver's own connection is read-only, on the same two defences as
            // the actor's. It is a second connection to a database this app does not own,
            // and a second connection is a second chance to forget the pragma.
            try await check("the_resolver_connection_is_read_only") {
                let root = corpus.copy("delayed-attachment-join", as: "readonly")
                let resolver = try AttachmentJoinResolver(databasePath: MessagesDatabase.canonicalPath(of: root),
                                                          clock: ManualClock().clock)
                defer { resolver.close() }
                guard resolver.queryOnlyEnabled() == 1 else {
                    return "the resolver's connection read query_only as "
                        + "\(String(describing: resolver.queryOnlyEnabled())), not 1"
                }
                guard resolver.hasJoinTable else {
                    return "the fixture's message_attachment_join was not found by the probe"
                }
                return nil
            }

            // 10. A row with no guid is claimed on its row id, and — the part that matters —
            // does not poison the cache for the rows around it.
            try await check("a_row_without_a_guid_is_claimed_by_row_id") {
                let root = corpus.copy("direct-message", as: "noguid")
                try WatchStaging.insertMessage(at: root, rowID: 3, guid: "",
                                               text: "FIXTURE-WATCH-NOGUID-BODY-3", inChatRowID: 1)
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID)
                await rig.arm()
                rig.bus.fireAll()
                guard await rig.waitForDeliveries(3) else {
                    return "\(await rig.deliveryCount()) of 3 rows arrived"
                }
                let watermark = await rig.watcher.currentWatermark()
                guard watermark.lastProcessedRowID == 3 else {
                    return "the watermark is \(watermark.lastProcessedRowID) after three rows"
                }
                guard !watermark.isKnown(guid: ""), watermark.isKnown(guid: "FIXTURE-DM-0001") else {
                    return "the guid cache holds an empty key or lost a real one: \(watermark.processedMessageGUIDs)"
                }
                // A later event must not re-deliver it, and must not be blocked by it.
                rig.bus.fireAll()
                try? await Task.sleep(for: .milliseconds(200))
                guard await rig.deliveryCount() == 3 else {
                    return "a later event re-delivered \(await rig.deliveryCount()) rows"
                }
                return nil
            }

            // 11. A database with no `cache_has_attachments` column. The flag reads nil,
            // which is not "no attachments" — and a watcher that believed it was would
            // report a photo as a caption with no picture on exactly the release that
            // dropped the column. The resolver answers by looking instead.
            try await check("a_database_without_the_attachment_flag_still_finds_its_attachments") {
                let root = corpus.copy("delayed-attachment-join", as: "noflag")
                try WatchStaging.insertJoinRow(at: root, rowID: 1, messageRowID: 1, attachmentRowID: 1)
                try WatchStaging.dropColumn(at: root, table: "message", column: "cache_has_attachments")
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID)
                let rows = try await rig.database.messages(after: 0, chatGUID: Self.pairedChatGUID)
                guard rows.count == 1 else { return "the degraded copy read \(rows.count) rows" }
                guard rows[0].cacheHasAttachments == nil else {
                    return "the projection still read cache_has_attachments as \(String(describing: rows[0].cacheHasAttachments))"
                }
                await rig.arm()
                rig.bus.fireAll()
                guard await rig.waitForDeliveries(1) else { return "the row never arrived" }
                let delivery = await rig.deliveries().first
                guard case .resolved(_, let found) = delivery?.resolution else {
                    return "the resolution is \(String(describing: delivery?.resolution))"
                }
                guard found.count == 1, found[0].guid == "FIXTURE-ATT-SETTLE-0001" else {
                    return "the attachment is \(found.map(\.guid))"
                }
                return nil
            }

            // 12. The lifecycle. Three files armed, a loss re-arms them and catches up, a
            // refused stream is logged and the others are still armed, and `stop()` closes
            // every descriptor. The descriptors are real — `open(O_EVTONLY)` on files the
            // test created — so a leak here is a leak in the test process too.
            try await check("arms_disarms_and_rearms_after_a_lost_file") {
                let root = corpus.copy("direct-message", as: "lifecycle")
                for suffix in ["-wal", "-shm"] {
                    FileManager.default.createFile(atPath: root.path + suffix, contents: Data())
                }
                let bus = ManualEventBus()
                let rig = try WatchRig(root: root, chatGUID: Self.pairedChatGUID, bus: bus)
                await rig.arm()
                let canonical = MessagesDatabase.canonicalPath(of: root)
                let expected = MessagesWALWatcher.watchedPaths(forDatabase: canonical)
                let armed = bus.armedPaths
                guard armed.count == expected.count else {
                    return "armed \(armed), expected \(expected.count) paths (the fixture copy has no -wal until it is created)"
                }
                for path in expected where !armed.contains(path) {
                    return "\(path) was not armed; armed: \(armed)"
                }
                // A loss: the file is replaced under us, the new one is opened, and a pass
                // runs so nothing the old descriptor saw is lost.
                bus.loseAll()
                _ = await rig.waitForDeliveries(2)
                let stats = await rig.watcher.statistics()
                guard stats.rearms >= 1 else { return "a lost file did not re-arm" }
                guard await rig.deliveryCount() == 2 else {
                    return "the re-arm's catch-up delivered \(await rig.deliveryCount()) of 2 rows"
                }
                // The re-arm disarmed the old three before opening the new three, so this is
                // a difference rather than an absolute.
                let cancelledBeforeStop = bus.cancelled.count
                await rig.watcher.stop()
                guard bus.armedPaths.isEmpty else { return "stop() left \(bus.armedPaths) armed" }
                guard bus.cancelled.count == cancelledBeforeStop + expected.count else {
                    return "stop() closed \(bus.cancelled.count - cancelledBeforeStop) of \(expected.count) descriptors"
                }
                // And a stream that refuses to start does not take the others with it.
                let refusing = ManualEventBus()
                refusing.refuse = Set([expected[0]])
                let second = try WatchRig(root: root, chatGUID: Self.pairedChatGUID, bus: refusing)
                await second.arm()
                guard refusing.armedPaths.count == expected.count - 1 else {
                    return "a refused stream left \(refusing.armedPaths) armed"
                }
                return nil
            }

            // 13. The guid cache is bounded, which is what keeps a machine that never quits
            // from growing a `Set<String>` forever. Eviction is safe because the row id
            // covers everything older than the cache — see the type's own header.
            await check("the_guid_cache_is_bounded") {
                var watermark = MessagesWatermark()
                let total = MessagesWatermark.guidCacheLimit + 40
                for index in 0..<total {
                    _ = watermark.claim(rowID: Int64(index + 1), guid: "FIXTURE-WATCH-BOUND-\(index)")
                }
                guard watermark.guidCacheCount == MessagesWatermark.guidCacheLimit else {
                    return "the cache holds \(watermark.guidCacheCount), limit \(MessagesWatermark.guidCacheLimit)"
                }
                guard watermark.lastProcessedRowID == Int64(total) else {
                    return "the row id is \(watermark.lastProcessedRowID) after \(total) claims"
                }
                // The newest are kept, the oldest are gone, and the row id still covers
                // what was evicted.
                guard watermark.isKnown(guid: "FIXTURE-WATCH-BOUND-\(total - 1)") else {
                    return "the most recent guid was evicted"
                }
                guard !watermark.isKnown(guid: "FIXTURE-WATCH-BOUND-0") else {
                    return "the oldest guid was not evicted"
                }
                return nil
            }
        } catch {
            failures.append("fixtures: \(error)")
        }

        // One string, marker last — `writeSelfTest` writes it in a single call while
        // `print` goes through a buffered stream, so printing the diagnostics separately
        // and returning the verdict puts the verdict *before* them on stdout. A reader, or
        // `Scripts/acceptance.sh`, reads the last line.
        var lines = failures.map { "IMESSAGE_WATCH_WRONG: \($0)" }
        lines.append(contentsOf: measured.map { "IMESSAGE_WATCH_MEASURED: \($0)" })
        lines.append(failures.isEmpty
            ? "IMESSAGE_WATCH_OK: \(caseCount) cases"
            : "IMESSAGE_WATCH_FAILED: \(failures[0])")
        return lines.joined(separator: "\n")
    }
}

// MARK: - The rig

/// A watcher wired to fixtures, an injected event source and an injected clock.
///
/// The three injectable things are what make every case in this file deterministic, and
/// they are injected at the *production* `init` rather than behind a test-only switch: there
/// is no path through `MessagesWatcher` that a self-test cannot take, which is the property
/// that lets the case be a claim about the shipped code.
@MainActor
private final class WatchRig {
    let watcher: MessagesWatcher
    let database: MessagesDatabase
    let resolver: AttachmentJoinResolver
    let bus: ManualEventBus
    let log: DeliveryLog

    init(root: URL,
         chatGUID: String?,
         bus: ManualEventBus = ManualEventBus(),
         debounceClock: MessagesWatcherClock = ManualClock().clock,
         resolverClock: MessagesWatcherClock = ManualClock().clock,
         watermark: MessagesWatermark = MessagesWatermark()) throws {
        let database = try MessagesDatabase(root: root)
        self.database = database
        self.bus = bus
        self.resolver = try AttachmentJoinResolver(databasePath: database.path, clock: resolverClock)
        let log = DeliveryLog(clock: debounceClock)
        self.log = log
        self.watcher = MessagesWatcher(
            database: database,
            resolver: self.resolver,
            chatGUID: chatGUID,
            clock: debounceClock,
            eventSource: bus.makeSource(),
            watermark: watermark,
            listener: { delivery in await log.record(delivery) }
        )
    }

    func arm() async { await watcher.arm() }

    func deliveries() async -> [MessagesWatcherDelivery] { await log.entries.map(\.delivery) }
    func deliveryCount() async -> Int { await log.entries.count }
    func passes() async -> Int {
        let counts = await watcher.statistics()
        return counts.passes
    }

    /// Waits for a number of envelopes, then returns whether it got them.
    ///
    /// **A bounded wait, and it is the one place this file polls.** The ban is on the
    /// *watcher* polling `chat.db`; a test has to wait for an async callback somehow, and
    /// this is a 10 ms loop with a deadline rather than a stream nobody reads.
    func waitForDeliveries(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        await Self.waitUntil(timeout: timeout) { await self.log.entries.count >= count }
    }

    func waitForPasses(atLeast count: Int, timeout: TimeInterval = 5) async -> Bool {
        await Self.waitUntil(timeout: timeout) { await self.passes() >= count }
    }

    private static func waitUntil(timeout: TimeInterval,
                                  _ condition: () async -> Bool) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

/// What the listener saw, and when.
private actor DeliveryLog {
    struct Entry: Sendable {
        var delivery: MessagesWatcherDelivery
        /// The injected clock's reading, so a case can measure a gap between two deliveries
        /// rather than trust a stopwatch around the whole run.
        var at: Double
    }

    private let clock: MessagesWatcherClock
    private(set) var entries: [Entry] = []

    init(clock: MessagesWatcherClock) { self.clock = clock }

    func record(_ delivery: MessagesWatcherDelivery) {
        entries.append(Entry(delivery: delivery, at: clock.seconds()))
    }
}

// MARK: - The injected signal

/// A `MessagesFileEventSource` the test drives by hand.
///
/// The whole reason the watcher is testable at all: a real `-wal` produces events on a
/// schedule nobody controls, and every case in this file would be a race against SQLite.
private final class ManualEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: ManualToken] = [:]
    private(set) var cancelled: [String] = []
    /// Paths whose stream refuses to start, so the "one refused, the rest armed" case can be
    /// built without a permission failure.
    var refuse: Set<String> = []

    func makeSource() -> MessagesFileEventSource {
        MessagesFileEventSource { [self] path, onEvent, onLost in
            lock.lock()
            let refused = refuse.contains(path)
            var token: ManualToken?
            if !refused {
                let made = ManualToken(path: path, fire: onEvent, lose: onLost, bus: self)
                handlers[path] = made
                token = made
            }
            lock.unlock()
            return refused ? nil : token
        }
    }

    /// One file event, the way a commit looks from the outside.
    func fireAll() {
        for handler in currentHandlers() { handler.fireNow() }
    }

    /// The `-wal` being replaced. The production path calls this from the source's event
    /// handler when the mask carries a delete.
    func loseAll() {
        for handler in currentHandlers() { handler.loseNow() }
    }

    var armedPaths: [String] { currentHandlers().map(\.path).sorted() }

    private func currentHandlers() -> [ManualToken] {
        lock.lock()
        defer { lock.unlock() }
        return Array(handlers.values)
    }

    fileprivate func noteCancelled(_ path: String) {
        lock.lock()
        handlers.removeValue(forKey: path)
        cancelled.append(path)
        lock.unlock()
    }
}

private final class ManualToken: MessagesWatchToken, @unchecked Sendable {
    let path: String
    private let fire: @Sendable () -> Void
    private let lose: @Sendable () -> Void
    private unowned let bus: ManualEventBus
    private let lock = NSLock()
    private var stopped = false

    init(path: String, fire: @escaping @Sendable () -> Void,
         lose: @escaping @Sendable () -> Void, bus: ManualEventBus) {
        self.path = path
        self.fire = fire
        self.lose = lose
        self.bus = bus
    }

    func cancel() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        guard !already else { return }
        bus.noteCancelled(path)
    }

    func fireNow() {
        lock.lock()
        let stopped = self.stopped
        lock.unlock()
        guard !stopped else { return }
        fire()
    }

    func loseNow() {
        lock.lock()
        let stopped = self.stopped
        lock.unlock()
        guard !stopped else { return }
        lose()
    }
}

// MARK: - The injected clocks

/// A sleep that costs no wall time, and remembers how many times it was asked.
///
/// This is the settling race's clock: the policy is then 8 waits of 250 ms as an exact
/// number on any machine, instead of a number that depends on how busy the machine is.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Called with the 1-based wait number, *before* the wait returns. The settling case
    /// uses it to hand the join row over at a chosen moment, which is the only way to
    /// express "it settles on the third refetch" without a real two seconds.
    var onWait: ((Int) -> Void)?

    /// The injected clock this object stands for. A computed property rather than a
    /// conformance, because `MessagesWatcherClock` is a value type and the two closures it
    /// holds are the only state that matters.
    var clock: MessagesWatcherClock {
        MessagesWatcherClock(seconds: { 0 }, sleep: { [self] _ in
            let index = takeWait()
            onWait?(index)
        })
    }

    /// The locking half, kept synchronous: `NSLock.lock()` is unavailable from an async
    /// context, and a lock held across a `withCheckedContinuation` body would be a lock held
    /// across a suspension point.
    private func takeWait() -> Int {
        lock.lock()
        count += 1
        let index = count
        lock.unlock()
        return index
    }

    var waits: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A debounce that parks until the test lets it go.
///
/// Without it, "five events inside one debounce window" is a race that usually passes: a
/// no-op sleep returns before the next event arrives as often as not, and a test that
/// passes for the wrong reason is worse than one that is red.
private final class GateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    var clock: MessagesWatcherClock {
        MessagesWatcherClock(seconds: { 0 }, sleep: { [self] _ in
            await withCheckedContinuation { continuation in
                park(continuation)
            }
        })
    }

    /// The locking half, kept synchronous: `NSLock.lock()` is unavailable from an async
    /// context, and a lock held across a `withCheckedContinuation` body would be a lock held
    /// across a suspension point.
    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if released {
            lock.unlock()
            continuation.resume()
        } else {
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Lets every parked debounce through, including the ones a later event cancelled —
    /// a cancelled task's continuation still has to be resumed or the task never ends, and
    /// `MessagesWatcher` drops the cancelled one on the `Task.isCancelled` check after it.
    func release() {
        lock.lock()
        released = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

// MARK: - The fixtures

/// `Tests/Fixtures/chatdb/make-chatdb-fixture.sh`, built and copied into a temporary
/// directory.
///
/// **Every case runs against a copy, and that is a rule rather than tidiness.** The
/// settling case has to make a join row appear at a chosen moment and the replay case has
/// to add twenty-two rows, and both are writes. They are writes to a file this process
/// created in its own temporary directory, and never to a path under `~/Library/Messages/`
/// — a rule the roadmaps state twice and the only one that matters here.
private struct WatchCorpus {
    let directory: URL
    private let cases = ["both-paths", "direct-message", "delayed-attachment-join", "empty-attributed-body"]

    func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).sqlite") }

    /// A fresh copy under a case's own name, so two cases never share a database.
    func copy(_ fixture: String, as name: String) -> URL {
        let destination = directory.appendingPathComponent("\(name).sqlite")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: url(fixture), to: destination)
        return destination
    }

    func discard() { try? FileManager.default.removeItem(at: directory) }

    static func build() throws -> WatchCorpus {
        guard let script = generatorScript() else { throw CorpusError.generatorMissing }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-imessage-watch-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corpus = WatchCorpus(directory: directory)
        for fixture in corpus.cases {
            let result = run([script.path, fixture, "--outdir", directory.path])
            guard result.status == 0 else {
                corpus.discard()
                throw CorpusError.buildFailed("\(fixture): \(result.reason.isEmpty ? "exit \(result.status)" : result.reason)")
            }
        }
        return corpus
    }

    enum CorpusError: Error {
        case generatorMissing
        case buildFailed(String)
    }

    /// Found the way IM-04's own test finds it: `#filePath` walks up until the corpus is
    /// there, so the test runs wherever the checkout lives rather than under cwd.
    static func generatorScript() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Tests")
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("chatdb")
                .appendingPathComponent("make-chatdb-fixture.sh")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func run(_ arguments: [String]) -> (status: Int32, reason: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        do { try process.run() } catch {
            return (127, "could not run the generator: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reason = String(data: data, encoding: .utf8)?
            .split(separator: "\n").map(String.init).joined(separator: " ") ?? ""
        return (process.terminationStatus, reason)
    }
}

// MARK: - Staging rows into a copy

/// The writes a case needs on its own copy of a fixture.
///
/// **Read-write, on a temporary file, and nowhere else.** This is the one place in IM-06
/// that opens a Messages-shaped database for writing, and it is the *only* place; the two
/// read paths in the feature both go through `MessagesDatabase.openReadOnly`, and the
/// `--selftest-imessage-watch` case `the_resolver_connection_is_read_only` is what keeps
/// that true. The staged values are `FIXTURE-*` placeholders for the same reason the corpus
/// is: nothing here can be a real conversation.
private enum WatchStaging {
    enum StagingError: Error, CustomStringConvertible {
        case refused(String)
        var description: String {
            if case .refused(let reason) = self { return reason }
            return "unreachable"
        }
    }

    enum Value {
        case text(String)
        case integer(Int64)
        case null
    }

    /// One text row, joined to one chat, in the self-conversation's direction.
    static func insertMessage(at root: URL,
                              rowID: Int64,
                              guid: String,
                              text: String,
                              inChatRowID: Int64) throws {
        try run("INSERT INTO message (ROWID, guid, text, service, handle_id, date, is_from_me, "
                + "is_sent, cache_has_attachments) VALUES (?, ?, ?, 'iMessage', 1, ?, 0, 1, 0)",
                [.integer(rowID), .text(guid), .text(text), .integer(1_700_000_000_000_000_000 + rowID)],
                at: root.path)
        try run("INSERT INTO chat_message_join (ROWID, chat_rowid, message_rowid) VALUES (?, ?, ?)",
                [.integer(rowID), .integer(inChatRowID), .integer(rowID)],
                at: root.path)
    }

    static func insertChat(at root: URL, rowID: Int64, guid: String, identifier: String) throws {
        try run("INSERT INTO chat (ROWID, guid, chat_identifier, service_name, display_name, style, state) "
                + "VALUES (?, ?, ?, 'iMessage', ?, 0, 0)",
                [.integer(rowID), .text(guid), .text(identifier), .text(identifier)],
                at: root.path)
    }

    /// The row whose arrival the settling race is about.
    static func insertJoinRow(at root: URL,
                              rowID: Int64,
                              messageRowID: Int64,
                              attachmentRowID: Int64) throws {
        try run("INSERT INTO message_attachment_join (ROWID, message_rowid, attachment_rowid) "
                + "VALUES (?, ?, ?)",
                [.integer(rowID), .integer(messageRowID), .integer(attachmentRowID)],
                at: root.path)
    }

    /// Removes a column, so a case can stand on a database shaped like a macOS release
    /// that has dropped one. `SQLite` has supported `DROP COLUMN` since 3.35, and the
    /// failure mode if it ever stops is a case that reports a refusal rather than a pass.
    static func dropColumn(at root: URL, table: String, column: String) throws {
        try run("ALTER TABLE \(table) DROP COLUMN \(column)", [], at: root.path)
    }

    static func run(_ sql: String, _ bindings: [Value], at path: String) throws {
        var db: OpaquePointer?
        // Read-write, and only ever on a path under a temporary directory: the flag is the
        // opposite of every read path in this feature, which is the point. Nothing in
        // `Sources/NextNotes/IMessage/` calls this.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            throw StagingError.refused("could not open \(path) to stage a row")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let reason = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            throw StagingError.refused("\(sql): \(reason)")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let position = Int32(offset + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(statement, position, (value as NSString).utf8String, -1, nil)
            case .integer(let value):
                sqlite3_bind_int64(statement, position, value)
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StagingError.refused("\(sql): \(String(cString: sqlite3_errmsg(db)))")
        }
    }
}
