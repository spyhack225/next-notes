import Foundation

/// `--selftest-imessage-loop` — NextNotes-iMessage IM-08b.
///
/// The outbound store, the match, and the breaker: **the three things that stop Next Notes reading
/// its own message back as a command.** No Full Disk Access, no iPhone, no paired conversation, no
/// Messages grant, no model and no live database — every case runs against a store on a fresh
/// temporary directory and a value for a clock, which is the same claim the store makes, asserted
/// by the fact that this test can exist at all.
///
/// ## The cases, and what each one is for
///
/// | # | case | the rule or measurement it pins |
/// |---|---|---|
/// | 1 | `the_loop_breaks` | IM-01's two copies, one pending send, and the design's core claim: a row carrying our own words never becomes a command |
/// | 2 | `a_different_command_with_the_same_words_is_not_this_send` | **the match is on identity, not on text** — same digest, different dispatch instant, and the ambiguity tiebreak |
/// | 3 | `one_send_breaks_both_copies_once` | "one send, one match": two rows, one claim, one count |
/// | 4 | `a_row_dated_six_minutes_ahead_still_matches` | **the one-sided window**, on the measured side |
/// | 5 | `a_row_outside_the_window_does_not_match` | and on the other side, both as an expiry and as a date |
/// | 6 | `retention_bounds_the_table` | a settled row 8 days old is gone; a pending row is not |
/// | 7 | `an_ambiguous_match_is_treated_as_a_command` | the safe direction, and it is counted |
/// | 8 | `a_crash_between_dispatch_and_match_still_breaks_the_loop` | the store is reloaded mid-case, on the same file, with nothing in memory |
/// | 9 | `no_sentence_reaches_the_file` | **the privacy claim, read off the disk with `strings(1)`** |
/// | 10 | `the_row_type_has_no_free_string` | the allowlist itself, by reflection |
/// | 11 | `a_row_that_could_never_match_is_refused` | and the uniqueness that stops a retry manufacturing an ambiguity |
/// | 12 | `the_breaker_stops_a_flood_and_a_message_resumes_it` | `> 5` in 10 s, and the immediate resume |
/// | 13 | `the_breaker_is_not_persisted` | the design's in-memory rule, and the crash case above is where it is load-bearing |
/// | 14 | `the_breaker_says_one_plain_sentence` | `pausedReplying`, and the eleven words a person must never read |
/// | 15 | `a_harness_run_never_touches_the_owner_file` | the isolation the harness is trusted on |
///
/// ## Red first, and proven able to fail
///
/// The store was written **after** this test, against a seam that reproduced the roadmap's own
/// superseded rule — *"a `from-me` row that matches a pending outbound is ours; everything else is
/// a user command"*, `00-README.md` §11 — which has no ledger at all, so every case below failed
/// for the right reason rather than compiling into a pass. Every mutation in
/// `IM-08b-red.txt` names the assertion it reddened. **A test nobody has watched fail is
/// indistinguishable from one that cannot detect a wrong answer.**
///
/// ## Why case 9 reads the file and does not read the type
///
/// The design's own finding is that `UsageLog.sanitise` is blind to prose: it strips quoted
/// content, addresses, URLs, paths and long digit runs, and **a third party's promotional offer is
/// none of those — it is prose and it survives every rule in it.** So a field-level assertion
/// answers the wrong question. Case 9 builds a send from a fixture body carrying all three, writes
/// it, and runs `strings(1)` over the database **and its `-wal` and `-shm` siblings** — a row in
/// the WAL has not been checkpointed, and a check that read only the main file would pass on a
/// store that had just written somebody's sentence next door.
///
/// ## Blocked, and not counted
///
/// Nothing is blocked in this file: every case runs without a grant, a device, an account or a
/// model, and a case that could not run would be named on an `IMESSAGE_LOOP_BLOCKED:` line and left
/// out of the number. The number is a claim this run can stand behind rather than a denominator that
/// quietly absorbed a skip.
///
/// The final line is `IMESSAGE_LOOP_OK: <n> cases` or `IMESSAGE_LOOP_FAILED: <case>: <reason>`.
/// Per-case diagnostics are `IMESSAGE_LOOP_WRONG: …`; **`IMESSAGE_LOOP_WRONG` is not a verdict
/// token** — `writeSelfTest` looks for `_FAILED`, `_SILENT`, `_TIMEOUT` and `_MISSING` — so the
/// marker really is last.
@MainActor
enum MessagesLedgerSelfTest {

    // MARK: - The fixtures

    /// The paired chat, Apple's spelling. **Not committed from a real conversation**: `chat.guid`
    /// is `service;-;handle` and this is the shape with a reserved fiction number in it, the same
    /// thing `MessagesWatcherSelfTest.pairedChatGUID` uses.
    nonisolated static let pairedChatGUID = "iMessage;-;+15550000001"

    /// The two row ids IM-01 read for one self-message. Apple's, opaque, and named here so a case
    /// says *"the second copy"* rather than a pair of invented numbers.
    nonisolated static let firstCopyRowID: Int64 = 55189
    nonisolated static let secondCopyRowID: Int64 = 55190

    /// A fixed instant in Apple's epoch, nanoseconds, so every window assertion is arithmetic and
    /// not a wall clock. `2026-09-26 12:00:00 UTC` expressed in nanoseconds since 2001-01-01.
    nonisolated static let dispatchInstant: Int64 = 812_208_000_000_000_000

    /// **The fixture the privacy case is built from**, and the reason it is synthetic: the real
    /// body IM-01 captured carries a live link and a third party's offer and stays a local
    /// artefact (`TYPEDSTREAM-NOTES.md`, `MessagesSelfFlowReport.fixtureDirectory`). This one
    /// carries the same three *kinds* of thing — a promotional offer, a link, and a file name —
    /// with nothing real in any of them, which is the strict direction: the case looks for the
    /// strings themselves, so a fixture that accidentally held a real one would still fail.
    nonisolated static let promotionalOffer = "Limited time only, get 40 percent off your first order"
    nonisolated static let promotionalLink = "https://example.invalid/sale?utm_source=sms"
    nonisolated static let attachmentFileName = "quarterly-report.pdf"

    /// The eleven words this feature must never put in front of a person. `--selftest-ui-strings`
    /// cannot catch them here because it scans `UI/` and reads five call sites, so the check
    /// lives beside the copy. Matched as a **substring, case-insensitively** — the strict
    /// direction, because a sentence that accidentally contains one is a failure and not a near
    /// miss.
    static let forbiddenWords = [
        "tcc", "grant", "attributedbody", "typedstream", "payload_data", "database", "sqlite",
        "watermark", "probe", "signature", "ledger",
    ]

    // MARK: - The run

    static func run() async -> String {
        var failures: [String] = []
        let blocked: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () async throws -> String?) async rethrows {
            caseCount += 1
            do {
                if let problem = try await body() { failures.append("\(name): \(problem)") }
            } catch {
                failures.append("\(name): threw \(error)")
            }
        }

        do {
            // 1. The loop breaks. One send, one row carrying its bytes, and the row never becomes
            //    a command — which is the whole feature.
            try await check("the_loop_breaks") {
                let store = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: store.root) }
                let ledger = OutboundMessageLedger(store: store, nowNanos: { dispatchInstant })
                let digest = OutboundDigest.text("The meeting is at three.")
                _ = try await ledger.recordDispatch(chatGUID: pairedChatGUID,
                                                    conversationID: "conv-1",
                                                    textDigest: digest)
                let verdict = try await ledger.verdict(for: candidate(
                    rowID: 900_001, guid: "row-guid-1", digest: digest,
                    date: dispatchInstant + 1_000_000_000))
                guard verdict == .ownEcho else { return "an echo of our own words read as \(verdict)" }
                // And the classification half, so the case is the claim rather than half of it:
                // an echo is `.ownEcho` from every direction and produces no remote answer and no
                // local notice, which is where the silence is enforced.
                let classification = IMessageClassifier.classify(
                    body: .text("The meeting is at three.", discardedBytes: 0),
                    isFromMe: false,
                    sender: .localNumber,
                    echo: verdict)
                guard classification.messageClass == .ownEcho else {
                    return "a matched row classified as \(classification.messageClass.rawValue)"
                }
                guard IMessageClassifier.remoteAnswer(for: classification) == .nothing,
                      IMessageClassifier.localNotice(for: classification) == .nothing,
                      classification.messageClass.remoteSpeaker == nil
                else { return "a matched row produced an answer, a card or a turn" }
                return nil
            }

            // 2. **The match is on identity, not on text.** Two sends, identical words, different
            //    instants: the row is both, so it is ambiguous — and ambiguous is a *command*,
            //    because losing a real request silently is worse than counting our own echo.
            await check("a_different_command_with_the_same_words_is_not_this_send") {
                let first = PendingOutboundMessage(
                    id: 1, conversationID: "conv-1", chatGUID: pairedChatGUID,
                    textDigest: OutboundDigest.text("buy milk"),
                    attachmentDigests: [], dispatchedAt: dispatchInstant,
                    matchedRowID: nil, matchedMessageGUID: nil, state: .pending)
                let second = PendingOutboundMessage(
                    id: 2, conversationID: "conv-1", chatGUID: pairedChatGUID,
                    textDigest: OutboundDigest.text("buy milk"),
                    attachmentDigests: [], dispatchedAt: dispatchInstant + 4 * 60_000_000_000,
                    matchedRowID: nil, matchedMessageGUID: nil, state: .pending)
                let digest = OutboundDigest.text("buy milk")
                // A row 6 minutes after the *first* send is inside both windows, and the two
                // sends are 4 minutes apart, so a time window alone would pick one at random.
                let observed = candidate(rowID: 900_002, guid: "row-guid-2", digest: digest,
                                         date: dispatchInstant + 6 * 60_000_000_000)
                let both = OutboundEchoMatch.verdict(ledger: [first, second], candidate: observed)
                guard both == .ambiguous(sendIDs: [1, 2]) else {
                    return "two sends with identical words read as \(both)"
                }
                guard both.verdict == .ambiguous else { return "the verdict was not the ambiguity" }
                // The same words, a *different* chat, is a different conversation and matches
                // neither — a digest is worthless without the conversation.
                let elsewhere = OutboundEchoMatch.verdict(ledger: [first, second], candidate:
                    OutboundEchoCandidate(rowID: 900_003, messageGUID: "row-guid-3",
                                          chatGUID: "iMessage;-;+15550009999",
                                          textDigest: digest, attachmentDigests: [],
                                          date: observed.date))
                guard elsewhere == .noMatch else { return "another conversation matched \(elsewhere)" }
                // And a row that arrives after the second send's window is not either of them.
                let later = OutboundEchoMatch.verdict(ledger: [first, second], candidate:
                    OutboundEchoCandidate(rowID: 900_004, messageGUID: "row-guid-4",
                                          chatGUID: pairedChatGUID,
                                          textDigest: digest, attachmentDigests: [],
                                          date: dispatchInstant + 30 * 60_000_000_000))
                guard later == .noMatch else { return "a row 30 minutes on matched \(later)" }
                return nil
            }

            // 3. One send, two rows — IM-01's measurement — and **one** claim and **one** count.
            try await check("one_send_breaks_both_copies_once") {
                let store = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: store.root) }
                let ledger = OutboundMessageLedger(store: store, nowNanos: { dispatchInstant })
                let digest = OutboundDigest.text("réponds-moi s'il te plaît")
                _ = try await ledger.recordDispatch(chatGUID: pairedChatGUID,
                                                    conversationID: "conv-1", textDigest: digest)
                let first = try await ledger.verdict(for: candidate(
                    rowID: firstCopyRowID, guid: "copy-a", digest: digest,
                    date: dispatchInstant + 2_000_000_000))
                let second = try await ledger.verdict(for: candidate(
                    rowID: secondCopyRowID, guid: "copy-b", digest: digest,
                    date: dispatchInstant + 2_500_000_000))
                guard first == .ownEcho, second == .ownEcho else {
                    return "the two copies read as \(first) and \(second)"
                }
                let counts = await ledger.counts
                guard counts.echoesBroken == 1 else {
                    return "\(counts.echoesBroken) echoes counted for one send"
                }
                let rows = try await ledger.rows()
                guard rows.count == 1 else { return "\(rows.count) rows for one send" }
                guard rows[0].matchedRowID == firstCopyRowID,
                      rows[0].state == .landed
                else {
                    return "the send was claimed by row \(rows[0].matchedRowID.map(String.init) ?? "none") "
                        + "in state \(rows[0].state.rawValue)"
                }
                // The second copy is recognised and **not** re-claimed: "one send, one match".
                guard rows[0].matchedRowID != secondCopyRowID else {
                    return "the second copy claimed the send as well"
                }
                return nil
            }

            // 4. **The one-sided window, on the measured side.** `message.date` read up to ~6
            //    minutes in the future on this Mac (IM-01's side finding), so a row stamped
            //    ahead still has to be ours.
            try await check("a_row_dated_six_minutes_ahead_still_matches") {
                let store = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: store.root) }
                let ledger = OutboundMessageLedger(store: store, nowNanos: { dispatchInstant })
                let digest = OutboundDigest.text("stand up at seven")
                _ = try await ledger.recordDispatch(chatGUID: pairedChatGUID,
                                                    conversationID: "conv-1", textDigest: digest)
                // Read at dispatch + 30 s, so the *wall clock* sweep is nowhere near the row's own
                // date: what admits this row is the date comparison, not a sweep that ran late.
                let verdict = try await ledger.verdict(for: candidate(
                    rowID: 900_010, guid: "ahead", digest: digest,
                    date: dispatchInstant + 30_000_000_000 + 6 * 60_000_000_000))
                guard verdict == .ownEcho else {
                    return "a row 6 minutes ahead read as \(verdict)"
                }
                return nil
            }

            // 5. And the other side, three ways: **as a date** (the window refused it while it
            //    was still pending), **as a state** (the sweep expired it, and an expired row can
            //    never match), and **as a refusal** (a local act abandoned the send).
            try await check("a_row_outside_the_window_does_not_match") {
                let store = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: store.root) }
                let digest = OutboundDigest.text("call the dentist")
                // (a) As a date: still `pending`, 40 minutes on. The row is refused by the
                //     window on the row's own clock.
                let pending = PendingOutboundMessage(
                    id: 1, conversationID: "conv-1", chatGUID: pairedChatGUID,
                    textDigest: digest, attachmentDigests: [], dispatchedAt: dispatchInstant,
                    matchedRowID: nil, matchedMessageGUID: nil, state: .pending)
                let dated = OutboundEchoMatch.verdict(ledger: [pending], candidate:
                    candidate(rowID: 900_020, guid: "too-far", digest: digest,
                              date: dispatchInstant + 40 * 60_000_000_000))
                guard dated == .noMatch else { return "a row 40 minutes on matched \(dated)" }

                // (b) As a state: the sweep has expired it, and **an expired row can never match a
                //     later row** even when the date would admit it.
                let expired = PendingOutboundMessage(
                    id: 2, conversationID: "conv-1", chatGUID: pairedChatGUID,
                    textDigest: digest, attachmentDigests: [], dispatchedAt: dispatchInstant,
                    matchedRowID: nil, matchedMessageGUID: nil, state: .expired)
                let after = OutboundEchoMatch.verdict(ledger: [expired], candidate:
                    candidate(rowID: 900_021, guid: "after-expiry", digest: digest,
                              date: dispatchInstant + 2_000_000_000))
                guard after == .noMatch else { return "an expired row matched \(after)" }

                // And the wall-clock sweep really moves the state rather than being decoration.
                let swept = OutboundMessageLedger(store: store,
                                                  nowNanos: { dispatchInstant + 20 * 60_000_000_000 })
                try store.record(pending)
                let deleted = try await swept.sweep()
                guard deleted == 0 else { return "the sweep deleted \(deleted) pending rows" }
                let rows = try store.allRows()
                guard rows.count == 1, rows[0].state == .expired else {
                    return "the sweep left \(rows.map(\.state.rawValue))"
                }
                guard try store.claimableRows().isEmpty else {
                    return "an expired row is still offered to the match"
                }

                // (c) As a third state: a local act that gave up. **`abandoned` is reachable and
                //     is a refusal** — a send this app will not make must not later claim a row in
                //     somebody's conversation, and this is the case that says so. It is also the
                //     only writer of that state, so without this half the four-case enum would
                //     have an unreachable case: a finished feature with no call site.
                let abandoned = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: abandoned.root) }
                let kept = OutboundMessageLedger(store: abandoned, nowNanos: { dispatchInstant })
                _ = try await kept.recordDispatch(chatGUID: pairedChatGUID,
                                                  conversationID: "conv-1", textDigest: digest)
                guard try await kept.abandon(chatGUID: pairedChatGUID, textDigest: digest) == 1 else {
                    return "abandoning a live send did not mark it"
                }
                guard try await kept.verdict(for: candidate(
                    rowID: 900_022, guid: "after-abandon", digest: digest,
                    date: dispatchInstant + 2_000_000_000)) == .notOurEcho else {
                    return "an abandoned send still claimed a row"
                }
                return nil
            }

            // 6. **Retention bounds the table**, and a pending row is not swept by it — a send
            //    whose echo has not arrived is the crash-recovery case, not garbage.
            try await check("retention_bounds_the_table") {
                let store = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: store.root) }
                let eightDays: Int64 = 8 * 86_400 * 1_000_000_000
                let twoDays: Int64 = 2 * 86_400 * 1_000_000_000
                try store.record(PendingOutboundMessage(
                    id: 0, conversationID: "conv-1", chatGUID: pairedChatGUID,
                    textDigest: OutboundDigest.text("old"), attachmentDigests: [],
                    dispatchedAt: dispatchInstant - eightDays, matchedRowID: 1,
                    matchedMessageGUID: "row-1", state: .landed))
                try store.record(PendingOutboundMessage(
                    id: 0, conversationID: "conv-1", chatGUID: pairedChatGUID,
                    textDigest: OutboundDigest.text("still waiting"), attachmentDigests: [],
                    dispatchedAt: dispatchInstant - twoDays, matchedRowID: nil,
                    matchedMessageGUID: nil, state: .pending))
                let ledger = OutboundMessageLedger(store: store, nowNanos: { dispatchInstant })
                try await ledger.sweep()
                let rows = try store.allRows()
                // **Gone is deleted, not expired.** The landed row is deleted; the pending one is
                // still on disk because retention does not touch a pending row — and it *is*
                // expired, because a send two days old is well past the identification window and
                // that is a state, not a deletion.
                guard rows.count == 1 else {
                    return "after retention: \(rows.map { "\($0.state.rawValue)@\($0.dispatchedAt)" })"
                }
                guard rows[0].state == .expired else {
                    return "a two-day-old pending row is \(rows[0].state.rawValue), not expired"
                }
                guard try store.claimableRows().isEmpty else {
                    return "an expired row is still offered to the match"
                }

                return nil
            }

            // 7. The ambiguity, end to end through the store: not claimed, not persisted, and
            //    **counted**, so the degradation is visible rather than silent.
            try await check("an_ambiguous_match_is_treated_as_a_command") {
                let store = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: store.root) }
                let ledger = OutboundMessageLedger(store: store, nowNanos: { dispatchInstant })
                let digest = OutboundDigest.text("same words")
                _ = try await ledger.recordDispatch(chatGUID: pairedChatGUID,
                                                    conversationID: "conv-1", textDigest: digest)
                _ = try await ledger.recordDispatch(chatGUID: pairedChatGUID,
                                                    conversationID: "conv-1", textDigest: digest,
                                                    dispatchedAt: dispatchInstant + 120_000_000_000)
                let verdict = try await ledger.verdict(for: candidate(
                    rowID: 900_030, guid: "ambiguous", digest: digest,
                    date: dispatchInstant + 180_000_000_000))
                guard verdict == .ambiguous else { return "two live sends read as \(verdict)" }
                let counts = await ledger.counts
                guard counts.ambiguities == 1, counts.echoesBroken == 0 else {
                    return "ambiguities \(counts.ambiguities), echoes broken \(counts.echoesBroken)"
                }
                let rows = try await ledger.rows()
                guard rows.allSatisfy({ $0.matchedRowID == nil && $0.state == .pending }) else {
                    return "an ambiguous match claimed a send"
                }
                return nil
            }

            // 8. **A crash between dispatch and match.** The store is closed, a *second* store and
            //    a *second* ledger are built on the same file, and the match happens through
            //    them — so nothing that survived did so because it was in memory. The two
            //    instances assert the file itself is what carried the pending set.
            try await check("a_crash_between_dispatch_and_match_still_breaks_the_loop") {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NextNotesOutboundTest-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let digest = OutboundDigest.text("remind me to buy milk")

                // "Before the process went away": the send is recorded and nothing is matched.
                let firstStore = IMessageOutboundStore(root: root)
                let first = OutboundMessageLedger(store: firstStore, nowNanos: { dispatchInstant })
                _ = try await first.recordDispatch(chatGUID: pairedChatGUID,
                                                   conversationID: "conv-1", textDigest: digest)
                _ = try await first.rows()

                // The crash. The connection is closed and the first pair of objects goes out of
                // scope, and the second half is handed **the path and nothing else** — no row, no
                // value, no closure. A second `IMessageOutboundStore` opens its own connection, so
                // nothing that survives did so because it was in the first one's memory.
                firstStore.close()

                // "After the relaunch": fresh store, fresh ledger, same file.
                let second = OutboundMessageLedger(store: IMessageOutboundStore(root: root),
                                                   nowNanos: { dispatchInstant + 5_000_000_000 })
                let recovered = try await second.rows()
                guard recovered.count == 1, recovered[0].state == .pending,
                      recovered[0].textDigest == digest else {
                    return "the pending set did not survive the reload: \(recovered.map(\.state.rawValue))"
                }
                let verdict = try await second.verdict(for: candidate(
                    rowID: secondCopyRowID, guid: "copy-b", digest: digest,
                    date: dispatchInstant + 6_000_000_000))
                guard verdict == .ownEcho else {
                    return "the echo after a crash read as \(verdict)"
                }
                // The breaker's state is the one thing that did **not** survive, on purpose.
                guard (await second.counts).suspensions == 0 else {
                    return "the breaker was persisted"
                }
                return nil
            }

            // 9. **The privacy claim, read off the disk.** A send built from a body carrying a
            //    promotional offer, a link and a file name, written, checkpointed, and then read
            //    with `strings(1)` over the database *and* its two journal siblings.
            try await check("no_sentence_reaches_the_file") {
                let store = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: store.root) }
                let body = "\(promotionalOffer) \(promotionalLink)"
                let bytes = Data("\(body) \(attachmentFileName)".utf8)
                try store.record(PendingOutboundMessage(
                    id: 0, conversationID: "conv-1", chatGUID: pairedChatGUID,
                    textDigest: OutboundDigest.text(body),
                    attachmentDigests: [OutboundDigest.attachment(bytes)],
                    dispatchedAt: dispatchInstant, matchedRowID: 900_040,
                    matchedMessageGUID: "row-guid-40", state: .landed))
                store.flush()
                let haystack = try Self.strings(in: store.filesToInspect)
                // Each of the three is looked for on its own, so the diagnostic names which one
                // leaked rather than "something did".
                for needle in [promotionalOffer, promotionalLink, attachmentFileName, "percent off"] {
                    if haystack.contains(needle) {
                        return "\"\(needle)\" is in the store's own files"
                    }
                }
                // The positive controls, because a check that finds nothing in an empty file
                // proves nothing: the three `TEXT` columns this row really did write are there.
                for control in [pairedChatGUID, "conv-1", OutboundState.landed.rawValue] {
                    guard haystack.contains(control) else {
                        return "\"\(control)\" is not in the file either, so nothing was written"
                    }
                }
                // **And the digest is not a printable run, on purpose.** A digest is stored as
                // raw bytes precisely so that `strings(1)` — or any text tool, or a hex dump read
                // by a person — cannot lift a fingerprint of somebody's message out of this file.
                // The hex form of it is therefore absent too, and that is the property: a store
                // that wrote `textDigest.hexString` would fail this case.
                let hex = OutboundDigest.attachment(bytes).map { String(format: "%02x", $0) }.joined()
                guard !haystack.contains(hex) else {
                    return "the attachment's digest is readable as text, so it is a fingerprint"
                }
                return nil
            }

            // 10. **The allowlist, by reflection.** Nine stored properties and the nine the design
            //     names, with their types. This is the assertion that reddens the day somebody
            //     adds a tenth field — which is the moment the diff should be argued about.
            await check("the_row_type_has_no_free_string") {
                let fields = Mirror(reflecting: PendingOutboundMessage()).children
                    .map { ($0.label ?? "?", String(reflecting: type(of: $0.value))) }
                let expected: [String: String] = [
                    "id": "Swift.Int64",
                    "conversationID": "Swift.String",
                    "chatGUID": "Swift.String",
                    "textDigest": "Foundation.Data",
                    "attachmentDigests": "Swift.Array<Foundation.Data>",
                    "dispatchedAt": "Swift.Int64",
                    "matchedRowID": "Swift.Optional<Swift.Int64>",
                    "matchedMessageGUID": "Swift.Optional<Swift.String>",
                    "state": "NextNotes.OutboundState",
                ]
                var seen: [String: String] = [:]
                for (label, type) in fields { seen[label] = type }
                guard seen == expected else {
                    let added = Set(seen.keys).subtracting(expected.keys).sorted()
                    let changed = expected.keys.filter { seen[$0] != nil && seen[$0] != expected[$0] }.sorted()
                    return "the row type is not the allowlist — added \(added), changed \(changed), "
                        + "got \(seen.keys.sorted())"
                }
                // The three strings are opaque ids, and each is compared against Apple's own
                // value — so the one remaining thing a caller could do is put a sentence in
                // `chatGUID`, and that matches nothing at all.
                let strings = fields.filter { $0.1 == "Swift.String" || $0.1 == "Swift.Optional<Swift.String>" }
                    .map(\.0).sorted()
                guard strings == ["chatGUID", "conversationID", "matchedMessageGUID"] else {
                    return "the type holds \(strings) as strings"
                }
                return nil
            }

            // 11. **A row that could never match is refused**, and one send is one row: the
            //     uniqueness that stops a retried dispatch from manufacturing an ambiguity.
            try await check("a_row_that_could_never_match_is_refused") {
                let store = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: store.root) }
                do {
                    try store.record(PendingOutboundMessage(
                        id: 0, conversationID: "conv-1", chatGUID: pairedChatGUID,
                        textDigest: Data("not a digest".utf8), attachmentDigests: [],
                        dispatchedAt: dispatchInstant, matchedRowID: nil,
                        matchedMessageGUID: nil, state: .pending))
                    return "a 12-byte 'digest' was stored"
                } catch let error as IMessageOutboundStoreError {
                    guard case .notAMatchableRow = error else {
                        return "a bad digest failed as \(error.localizedDescription)"
                    }
                }
                do {
                    try store.record(PendingOutboundMessage(
                        id: 0, conversationID: "conv-1", chatGUID: pairedChatGUID,
                        textDigest: Data(), attachmentDigests: [], dispatchedAt: dispatchInstant,
                        matchedRowID: nil, matchedMessageGUID: nil, state: .pending))
                    return "a send with no digest at all was stored"
                } catch let error as IMessageOutboundStoreError {
                    guard case .notAMatchableRow = error else {
                        return "an empty digest failed as \(error.localizedDescription)"
                    }
                }
                guard try store.allRows().isEmpty else {
                    return "a refused row was written anyway"
                }
                // One send, one row. A retry that inserted twice would make the row permanently
                // ambiguous, which fails toward *command* — so the second insert must fail.
                let send = PendingOutboundMessage(
                    id: 0, conversationID: "conv-1", chatGUID: pairedChatGUID,
                    textDigest: OutboundDigest.text("once"), attachmentDigests: [],
                    dispatchedAt: dispatchInstant, matchedRowID: nil, matchedMessageGUID: nil,
                    state: .pending)
                try store.record(send)
                do {
                    try store.record(send)
                    return "the same send was recorded twice"
                } catch { /* the constraint is the point */ }
                let rows = try store.allRows()
                guard rows.count == 1 else { return "\(rows.count) rows for one send" }
                let matches = OutboundEchoMatch.claims(ledger: rows, candidate:
                    candidate(rowID: 1, guid: "g", digest: OutboundDigest.text("once"),
                              date: dispatchInstant + 1_000_000_000))
                guard matches.count == 1 else { return "the one send matched \(matches.count) times" }
                return nil
            }

            // 12. **The breaker.** Six sends in ten seconds with no user row pauses it; a user row
            //     resumes it immediately, without waiting for a timer.
            await check("the_breaker_stops_a_flood_and_a_message_resumes_it") {
                var breaker = OutboundLoopBreaker()
                let start = Date(timeIntervalSince1970: 1_700_000_000)
                var decisions: [OutboundSendDecision] = []
                for step in 0..<6 {
                    decisions.append(breaker.noteAgentSend(at: start.addingTimeInterval(Double(step))))
                }
                guard decisions.count == 6 else { return "no decisions were produced" }
                for (index, decision) in decisions.enumerated() {
                    let expected: OutboundSendDecision = index < 5 ? .send : .sentAndPaused
                    guard decision == expected else {
                        return "send \(index + 1) was \(decision), expected \(expected)"
                    }
                }
                guard breaker.isSuspended else { return "six sends did not pause it" }
                // A seventh is refused, and **nothing is recorded for it**: a reply that was never
                // sent cannot come back and match.
                guard breaker.noteAgentSend(at: start.addingTimeInterval(7)) == .refusedWhilePaused,
                      breaker.agentSends.count == 6 else {
                    return "a refused send was still timed"
                }
                // The design's own escape: a user row, immediately.
                guard breaker.noteUserCommand(at: start.addingTimeInterval(8)) == .resumed,
                      !breaker.isSuspended else { return "a user message did not resume it" }
                guard breaker.noteAgentSend(at: start.addingTimeInterval(9)) == .send else {
                    return "it was still paused after the user spoke"
                }
                // And the window is ten seconds, not forever: a person typing six commands in a
                // row is not a loop.
                var spread = OutboundLoopBreaker()
                var spreadDecisions: [OutboundSendDecision] = []
                for step in 0..<6 {
                    spreadDecisions.append(spread.noteAgentSend(at: start.addingTimeInterval(Double(step) * 4)))
                }
                guard spreadDecisions.allSatisfy({ $0 == .send }) else {
                    return "a burst spread over 20 seconds was not six plain sends"
                }
                guard !spread.isSuspended else {
                    return "six sends spread over 20 seconds paused it anyway"
                }
                // Six with a user row inside the window is a conversation, not a loop.
                var answered = OutboundLoopBreaker()
                guard answered.noteUserCommand(at: start) == .none else {
                    return "a breaker that was never paused reported a resume"
                }
                var answeredDecisions: [OutboundSendDecision] = []
                for step in 0..<6 {
                    answeredDecisions.append(answered.noteAgentSend(at: start.addingTimeInterval(Double(step) + 1)))
                }
                guard answeredDecisions.allSatisfy({ $0 == .send }) else {
                    return "six answers to a person were not all sent"
                }
                guard !answered.isSuspended else { return "six answers to a person paused the app" }
                return nil
            }

            // 13. **The breaker is not persisted**, and the ledger's pause is visible through the
            //     counts the design's vocabulary will read.
            try await check("the_breaker_is_not_persisted") {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NextNotesOutboundTest-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = IMessageOutboundStore(root: root)
                let start = Date(timeIntervalSince1970: 1_700_000_000)
                let first = OutboundMessageLedger(store: store, nowNanos: { dispatchInstant },
                                                 nowWallClock: { start })
                var last: OutboundSendDecision = .send
                for step in 0..<6 {
                    last = try await first.recordDispatch(chatGUID: pairedChatGUID,
                                                          conversationID: "conv-1",
                                                          textDigest: OutboundDigest.text("burst \(step)"))
                }
                guard last == .sentAndPaused else { return "the sixth send was \(last)" }
                let counts = await first.counts
                guard counts.suspensions == 1, counts.dispatches == 6 else {
                    return "dispatches \(counts.dispatches), suspensions \(counts.suspensions)"
                }
                // Nothing in the table records the pause. A ten-second window does not survive a
                // relaunch, and persisting a rate would be a second store for a number.
                let rows = try store.allRows()
                let written = try Self.strings(in: store.filesToInspect)
                let hasPause = written.contains("suspend") || written.contains("paused")
                guard !hasPause, rows.allSatisfy({ $0.state == .pending }) else {
                    return "the pause reached the store"
                }
                // A relaunch is a fresh ledger, and a fresh ledger is not paused.
                let relaunched = OutboundMessageLedger(store: store, nowNanos: { dispatchInstant })
                guard try await relaunched.recordDispatch(chatGUID: pairedChatGUID,
                                                          conversationID: "conv-1",
                                                          textDigest: OutboundDigest.text("after"))
                    == .send else {
                    return "the pause survived a relaunch"
                }
                // The counts line a person reads in the log carries numbers only.
                guard counts.summary.range(of: "^[0-9a-z ·]+$", options: .regularExpression) != nil else {
                    return "the summary line is not numbers only: \(counts.summary)"
                }
                return nil
            }

            // 14. **One plain sentence.** The breaker's copy comes from the register, names no
            //     part of this machinery, and says what starts it again.
            await check("the_breaker_says_one_plain_sentence") {
                let sentence = IMessageClassifierCopy.pausedReplying
                guard !sentence.isEmpty else { return "the breaker has no sentence" }
                for word in forbiddenWords where sentence.lowercased().contains(word) {
                    return "\"\(word)\" is in the sentence a person reads"
                }
                // It says what happened and what starts it again, and it does not apologise.
                guard sentence.contains("paused"), sentence.contains("starts it again") else {
                    return "the sentence does not say what happened and what to do"
                }
                // And every sentence the ledger could ever show comes from the same register.
                guard IMessageClassifierCopy.all.contains(sentence) else {
                    return "the breaker's sentence is not in the copy register"
                }
                return nil
            }

            // 15. **The isolation the harness is trusted on.** A ledger built the way the app
            //     builds one, under `--selftest-*`, writes into a per-process temporary directory
            //     and never beside the owner's stores.
            try await check("a_harness_run_never_touches_the_owner_file") {
                let store = IMessageOutboundStore.isolated()
                defer { try? FileManager.default.removeItem(at: store.root) }
                try store.record(PendingOutboundMessage(
                    id: 0, conversationID: "conv-1", chatGUID: pairedChatGUID,
                    textDigest: OutboundDigest.text("isolation"), attachmentDigests: [],
                    dispatchedAt: dispatchInstant, matchedRowID: nil, matchedMessageGUID: nil,
                    state: .pending))
                let ownerRoot = AppIdentity.applicationSupportDirectory
                guard store.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
                    return "an isolated store was rooted at \(store.fileURL.path)"
                }
                // **The way the app builds one, which is the claim that matters**: a ledger built
                // by `OutboundMessageLedger.shared` under `--selftest-*` is rooted in a
                // per-process temporary directory, so a harness run cannot append to the owner's
                // file even by accident. `SelfTest.isRunning` is true for this whole run — the
                // flag is what launched this process — so the branch is being read, not assumed.
                guard SelfTest.isRunning else { return "the harness is not running" }
                guard IMessageOutboundStore.defaultRoot.path
                    .hasPrefix(FileManager.default.temporaryDirectory.path) else {
                    return "the default root is \(IMessageOutboundStore.defaultRoot.path)"
                }
                guard !store.fileURL.path.hasPrefix(ownerRoot.path) else {
                    return "an isolated store was rooted in the owner's support directory"
                }
                // And the file the harness must be watching is one the guard actually names, so
                // `--selftest-store-isolation` is checking something.
                let watched = SelfTestStoreGuard.fileNames
                for name in [IMessageOutboundStore.fileName,
                             IMessageOutboundStore.fileName + "-wal",
                             IMessageOutboundStore.fileName + "-shm"] {
                    guard watched.contains(name) else {
                        return "\"\(name)\" is not in SelfTestStoreGuard.fileNames"
                    }
                }
                return nil
            }
        } catch {
            failures.append("harness: threw \(error)")
        }

        // MARK: - IM-08d: the bridge

        do {
            let bridgeDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-bridge-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? FileManager.default.createDirectory(at: bridgeDir, withIntermediateDirectories: true)
            let bridgeStore = RemoteIdentityStore(directory: bridgeDir)
            try? bridgeStore.update { $0.localIdentity = "+15551234567" }
            let bridgeLedger = OutboundMessageLedger(store: IMessageOutboundStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-bridge-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)))
            let collector = BridgeCollector()
            let bridge = IMessageBridge(ledger: bridgeLedger, store: bridgeStore) { candidate in
                await collector.addCandidate(candidate)
            } onCard: { notice in
                await collector.addCard(notice)
            }

            // 1. A .userCommand yields one candidate with the sender's own words.
            let commandEnvelope = IMessageEnvelope(
                rowID: 1, guid: "g1", date: 0, isFromMe: false, service: "iMessage",
                body: .text("Hi Next", discardedBytes: 0), source: .textColumn)
            await bridge.handle(delivery: MessagesWatcherDelivery(
                envelope: commandEnvelope,
                resolution: .noneNeeded,
                chatGUID: "iMessage;-;+15551234567",
                senderHandle: "+15551234567"))
            await check("a .userCommand yields one candidate") {
                let count = await collector.candidateCount
                let text = await collector.firstCandidateText
                return count == 1 && text == "Hi Next" ? nil : "got \(count) candidates"
            }

            // 2. A .fromSomebodyElse yields no candidate and one card.
            let foreignEnvelope = IMessageEnvelope(
                rowID: 2, guid: "g2", date: 0, isFromMe: false, service: "iMessage",
                body: .text("Hello from somebody else", discardedBytes: 0), source: .textColumn)
            await bridge.handle(delivery: MessagesWatcherDelivery(
                envelope: foreignEnvelope,
                resolution: .noneNeeded,
                chatGUID: "iMessage;-;+15551234567",
                senderHandle: "+15559876543"))
            await check("a .fromSomebodyElse yields no candidate and one card") {
                let count = await collector.candidateCount
                let cards = await collector.cardCount
                return count == 1 && cards == 1 ? nil : "got \(count) candidates, \(cards) cards"
            }

            // 3. A second .userCommand with the same text yields no second candidate (fingerprint).
            await bridge.handle(delivery: MessagesWatcherDelivery(
                envelope: commandEnvelope,
                resolution: .noneNeeded,
                chatGUID: "iMessage;-;+15551234567",
                senderHandle: "+15551234567"))
            await check("a second .userCommand with the same text yields no second candidate") {
                let count = await collector.candidateCount
                return count == 1 ? nil : "got \(count) candidates"
            }

            // 4. A .userSentSomethingElse yields no candidate and no card.
            let effectEnvelope = IMessageEnvelope(
                rowID: 3, guid: "g3", date: 0, isFromMe: false, service: "iMessage",
                body: .notText(bundleID: nil, discardedBytes: 0), source: .attributedBody)
            await bridge.handle(delivery: MessagesWatcherDelivery(
                envelope: effectEnvelope,
                resolution: .noneNeeded,
                chatGUID: "iMessage;-;+15551234567",
                senderHandle: "+15551234567"))
            await check("a .userSentSomethingElse yields no candidate and no card") {
                let count = await collector.candidateCount
                let cards = await collector.cardCount
                return count == 1 && cards == 1 ? nil : "got \(count) candidates, \(cards) cards"
            }
        } catch {
            failures.append("bridge: threw \(error)")
        }

        // Blocked first, then the wrong lines, then the marker: `writeSelfTest` writes this in a
        // single call while `print` goes through a buffered stream, so the verdict has to be in
        // the returned string to be the last thing a reader sees.
        var lines = blocked.map { "IMESSAGE_LOOP_BLOCKED: \($0)" }
        lines.append(contentsOf: failures.map { "IMESSAGE_LOOP_WRONG: \($0)" })
        lines.append(failures.isEmpty
            ? "IMESSAGE_LOOP_OK: \(caseCount) cases"
            : "IMESSAGE_LOOP_FAILED: \(failures[0])")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// A thread-safe collector for the bridge's output, so the self-test can assert on
    /// what the bridge produced without a mutable capture in a `@Sendable` closure.
    private actor BridgeCollector {
        private var candidates: [RemoteCandidate] = []
        private var cards: [IMessageLocalNotice] = []
        var candidateCount: Int { candidates.count }
        var cardCount: Int { cards.count }
        var firstCandidateText: String? { candidates.first?.text }
        func addCandidate(_ candidate: RemoteCandidate) { candidates.append(candidate) }
        func addCard(_ notice: IMessageLocalNotice) { cards.append(notice) }
    }

    /// A candidate for a row carrying exactly the digest a send recorded, in the paired chat.
    static func candidate(rowID: Int64, guid: String, digest: Data, date: Int64) -> OutboundEchoCandidate {
        OutboundEchoCandidate(rowID: rowID, messageGUID: guid, chatGUID: pairedChatGUID,
                              textDigest: digest, attachmentDigests: [], date: date)
    }

    /// Everything `strings(1)` can see in a set of files, joined.
    ///
    /// **Runs the real tool** rather than reading the bytes in Swift, because the design's proof
    /// was `strings(1)` and the claim being tested is what is *on the disk*: a check that scanned
    /// for a known pattern would agree with itself and disagree with nothing. `strings` is asked
    /// for its default minimum length, and a file that does not exist contributes nothing — which
    /// is the case for `-wal` after a `wal_checkpoint(TRUNCATE)`.
    static func strings(in urls: [URL]) throws -> String {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/strings")
        process.arguments = existing.map(\.path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a pipe's buffer is finite and a large database would deadlock a
        // run that waited first.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IMessageOutboundStoreError.read("strings(1) exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
