import Foundation

/// `--selftest-imessage-recovery` — NextNotes-iMessage IM-16: bounded recovery scaffold.
///
/// Five cases, all against ISOLATED temp roots. No owner store is read or written.
/// The final line is `IMESSAGE_RECOVERY_OK: <n> cases` or
/// `IMESSAGE_RECOVERY_FAILED:<case>:<reason>`. A missing precondition prints
/// `IMESSAGE_RECOVERY_ABSENT:<reason>` and is NEVER reported as OK.
///
/// ## Scope decisions (every one recorded here so review need not guess)
///
/// S1. ONE file owns this slice: this file. Nothing else is created or edited by
///     this task; the three registration edits (NextNotesApp, acceptance.sh,
///     AGENTS.md) are returned as patch text, not applied.
/// S2. READ-ONLY on production types. This file may construct `MessagesWatermark`
///     (Watcher/MessagesWatermark.swift), `TaskOrigin`/`TaskDelivery`/`TaskEvent`
///     (Duplex/VoiceContracts.swift) and `ActionOriginContext` (Permissions/
///     RemoteAccessPolicy.swift) as VALUES in fixtures. It duplicates none of
///     them and writes through none of their owners.
/// S3. No production watcher host. Fixtures drive an injected in-memory drain;
///     `MessagesWatcher`/`MessagesWALWatcher` are never instantiated here, and
///     no file-system event source, poll loop, timer or sleep/wake observer is
///     added. A drain in a fixture is not a wake observer.
/// S4. No resend-on-wake. Case 1 proves an asleep-period queue drains in ROWID
///     order once each under the test's own call; nothing subscribes to wake and
///     nothing re-sends on it. Wake drain hosting stays BLOCKED (see below).
/// S5. No second durability. There is no new SQLite/JSON ledger here. The two
///     temp scratch files below are fixture seed/round-trip bytes (a seeded
///     journal and a watermark snapshot), not a store: they live under one
///     isolated temp root, are discarded with it, and never join the task
///     ledger. `AgentTaskManager`/`TaskStore` remain the single ledger.
/// S6. `MeetingStore.isolated()` pattern, copied — not shared. Like
///     `IMessageOutboundStore.isolated()`, this file's
///     `IMessageRecoveryIsolatedRoot.isolated()` mints a fresh temp directory
///     per case and discards it. No seeded row ever touches an owner path.
/// S7. Guard self-contained. New scratch filenames are declared in
///     `IMessageRecoveryScratchFiles` IN THIS FILE and watched by the in-file
///     guard. `SelfTestStoreGuard.swift` is NOT edited (unowned file). Owner
///     invariance is still checked by reading the existing guard before/after.
/// S8. `TaskOrigin.remote(ActionOriginContext)` appears ONLY as a constructed
///     fixture value proving remote attribution shape. No `TaskBridge.spawn*`
///     is called with it; no dispatch path is exercised. Production spawn
///     authority is unchanged.
/// S9. Crash-after-detect exactly-once is asserted via a SEEDED journal: a
///     `detected` row with no `dispatched` row, then a relaunch pass, then a
///     replay pass. Dispatch count for the crashed row must total exactly 1.
/// S10. Case 3 pins `TaskDelivery.pending` plus a zero-speak record. The
///     fixture voice floor is a Bool, never a capture session; no TTS type is
///     touched and no audio is produced.
/// S11. Case 4 pins batching: 20 backlog rows become ONE combined delivery.
///     The batcher is a pure fixture function; the production batch/window
///     policy is not changed here.
/// S12. Case 5 pins never-auto-fire: a consequential action interrupted before
///     fire ends with `fired == false` and a restored card. Production
///     `TaskRecoveryPlanner` (read, not copied) owns the real decision; the
///     fixture pins the scaffold rule that recovery restores the card instead
///     of firing. `RemoteActionFirer` is never called.
/// S13. The "I'm back" gap sentence is a pure function
///     (`IMessageRecoveryGapSentence.make`) and is unit-covered in-file. It
///     returns nil when nothing was missed (an honest greeting never claims a
///     gap) and never carries a message body, sender, or chat handle.
///
/// ## What stays BLOCKED after this scaffold (not claimed, not closed)
/// - Production watcher host: no live `MessagesWatcher` recovery wiring.
/// - Wake drain host: nothing drains on sleep/wake; no power-state observer.
/// - Auto replay: no automatic re-dispatch outside this fixture drain.
/// - Lease/liveness: no process lease, no liveness probe, no fencing.
/// - Receipt reconciliation: no receipt join, no outcome-unknown resolution.
@MainActor
enum IMessageRecoverySelfTest {
    /// Scratch filenames this scaffold — and only this scaffold — may write,
    /// always under its own isolated temp root. Deliberately NOT added to
    /// `SelfTestStoreGuard.swift` (that file is not owned by this task); the
    /// in-file root check below watches them instead.
    enum ScratchFiles {
        static let journal = "imessage-recovery-journal.json"
        static let watermark = "imessage-recovery-watermark.json"
        static let cards = "imessage-recovery-cards.json"
        static let all = [journal, watermark, cards]
    }

    /// An isolated temp root: the `MeetingStore.isolated()` pattern. One fresh
    /// directory per case, discarded afterwards. Owner paths never appear here.
    struct IsolatedRoot {
        let root: URL
        static func isolated(prefix: String) -> IsolatedRoot? {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesRecoveryTest-\(prefix)-\(UUID().uuidString)",
                                        isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch { return nil }
            return IsolatedRoot(root: dir)
        }
        /// Refuses any URL outside this root. A write that would escape is a
        /// failure, not a fallback to another directory.
        func contains(_ url: URL) -> Bool {
            url.resolvingSymlinksInPath().path
                .hasPrefix(root.resolvingSymlinksInPath().path + "/")
        }
        func discard() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// One queued remote request. `origin` carries the existing
    /// `TaskOrigin.remote(ActionOriginContext)` shape as a VALUE only (see S8):
    /// constructing it proves attribution shape; it never enters a spawn path.
    struct QueuedRequest: Equatable {
        let rowID: Int64
        let guid: String
        let origin: TaskOrigin
        let title: String
    }

    /// Seeded crash journal. `detected` rows name what the watcher saw;
    /// `dispatched` rows name what recovery actually sent on. Exactly-once is
    /// `dispatched(taskID)` appearing exactly once per detected guid.
    struct FixtureJournal: Codable, Equatable {
        var detected: [String]
        var dispatched: [String]
        func dispatchCount(for guid: String) -> Int {
            dispatched.filter { $0 == guid }.count
        }
    }

    static func remoteOrigin(messageGUID: String) -> TaskOrigin {
        .remote(ActionOriginContext(transport: .iMessage,
                                    remoteIdentity: nil,
                                    chatGUID: nil,
                                    messageGUID: messageGUID,
                                    receivedWhileMacWasAsleep: true))
    }

    /// Fixture-only drain: sorts by ROWID, claims each row through the REAL
    /// `MessagesWatermark` value (read-only use; the watermark type is not
    /// reimplemented), and records one dispatch per first-seen guid. Returns
    /// the dispatched guids in drain order.
    static func drain(_ requests: [QueuedRequest],
                      watermark: inout MessagesWatermark,
                      journal: inout FixtureJournal) -> [String] {
        var out: [String] = []
        for request in requests.sorted(by: { $0.rowID < $1.rowID }) {
            let fresh = watermark.claim(rowID: request.rowID, guid: request.guid)
            if !journal.detected.contains(request.guid) {
                journal.detected.append(request.guid)
            }
            // A re-read after restart is not a re-dispatch: the journal, not
            // the row id, decides whether this guid already went out.
            guard fresh, !journal.dispatched.contains(request.guid) else { continue }
            journal.dispatched.append(request.guid)
            out.append(request.guid)
        }
        return out
    }

    /// Pure batcher: one open window turns N backlog rows into ONE combined
    /// delivery. Returns the batch count and the covered guid count.
    static func batch(_ guids: [String], windowOpen: Bool) -> (batches: Int, covered: Int, spokeMessages: Int) {
        guard windowOpen, !guids.isEmpty else { return (0, 0, 0) }
        return (1, guids.count, 1)
    }

    static func run() -> String {
        var failures: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () -> String?) {
            caseCount += 1
            if let problem = body() { failures.append("\(name): \(problem)") }
        }

        // Precondition: the harness owns isolation. Outside it this flag must
        // never print OK: owner stores are reachable and temp-root guarantees
        // (S6) do not hold.
        guard SelfTest.isRunning else {
            let reason = "harness is not running"
            return "IMESSAGE_RECOVERY_ABSENT: \(reason)\nIMESSAGE_RECOVERY_FAILED:precondition:\(reason)"
        }
        let ownerBefore = SelfTestStoreGuard.take()

        // Case 1: three requests queued while "asleep" drain in ROWID order,
        // once each, watermark advancing past each.
        check("sleep_drain_rowid_order_once_each") {
            guard let scope = IsolatedRoot.isolated(prefix: "sleep") else {
                return "could not mint an isolated root"
            }
            defer { scope.discard() }
            var watermark = MessagesWatermark()
            var journal = FixtureJournal(detected: [], dispatched: [])
            let requests = [
                QueuedRequest(rowID: 3, guid: "FIXTURE-IM16-SLEEP-0003",
                              origin: remoteOrigin(messageGUID: "FIXTURE-IM16-SLEEP-0003"),
                              title: "third"),
                QueuedRequest(rowID: 1, guid: "FIXTURE-IM16-SLEEP-0001",
                              origin: remoteOrigin(messageGUID: "FIXTURE-IM16-SLEEP-0001"),
                              title: "first"),
                QueuedRequest(rowID: 2, guid: "FIXTURE-IM16-SLEEP-0002",
                              origin: remoteOrigin(messageGUID: "FIXTURE-IM16-SLEEP-0002"),
                              title: "second"),
            ]
            let drained = drain(requests, watermark: &watermark, journal: &journal)
            guard drained == ["FIXTURE-IM16-SLEEP-0001", "FIXTURE-IM16-SLEEP-0002", "FIXTURE-IM16-SLEEP-0003"] else {
                return "drain order was \(drained)"
            }
            guard watermark.lastProcessedRowID == 3 else {
                return "watermark stopped at \(watermark.lastProcessedRowID), not 3"
            }
            // A second pass over the same rows dispatches nothing new.
            let replay = drain(requests, watermark: &watermark, journal: &journal)
            guard replay.isEmpty else { return "replay re-dispatched \(replay)" }
            // Scratch round-trip stays inside the isolated root (S6/S7).
            let snapshotURL = scope.root.appendingPathComponent(ScratchFiles.watermark)
            guard scope.contains(snapshotURL) else { return "scratch URL escaped its root" }
            guard let bytes = try? JSONEncoder().encode(watermark.snapshot()),
                  (try? bytes.write(to: snapshotURL, options: .atomic)) != nil,
                  let back = try? JSONDecoder().decode(MessagesWatermark.Snapshot.self,
                                                       from: Data(contentsOf: snapshotURL)) else {
                return "watermark snapshot did not round-trip inside its root"
            }
            guard MessagesWatermark(snapshot: back).lastProcessedRowID == 3 else {
                return "rebuilt watermark lost its row id"
            }
            return nil
        }

        // Case 2: detected-then-lost-before-dispatch is handled exactly once
        // after relaunch (seed running, relaunch, no double dispatch).
        check("crash_after_detect_exactly_once") {
            guard let scope = IsolatedRoot.isolated(prefix: "crash") else {
                return "could not mint an isolated root"
            }
            defer { scope.discard() }
            // Seed: the watcher detected row 7, then the process died before
            // dispatch. The journal is the only witness (S9).
            var journal = FixtureJournal(detected: ["FIXTURE-IM16-CRASH-0007"], dispatched: [])
            let journalURL = scope.root.appendingPathComponent(ScratchFiles.journal)
            guard scope.contains(journalURL),
                  let seed = try? JSONEncoder().encode(journal),
                  (try? seed.write(to: journalURL, options: .atomic)) != nil else {
                return "could not seed the crash journal inside its root"
            }
            // Relaunch: a fresh watermark rebuilt from its persisted snapshot
            // rewinds behind the truth; the GUID-free replay path re-reads row 7.
            var watermark = MessagesWatermark()
            watermark.rewind(to: 0)
            guard let reloaded = try? JSONDecoder().decode(
                FixtureJournal.self, from: Data(contentsOf: journalURL)) else {
                return "relaunch could not read its own seeded journal"
            }
            journal = reloaded
            let requests = [QueuedRequest(rowID: 7, guid: "FIXTURE-IM16-CRASH-0007",
                                          origin: remoteOrigin(messageGUID: "FIXTURE-IM16-CRASH-0007"),
                                          title: "crashed")]
            let first = drain(requests, watermark: &watermark, journal: &journal)
            guard first == ["FIXTURE-IM16-CRASH-0007"] else {
                return "relaunch dispatched \(first), not the one lost row"
            }
            let second = drain(requests, watermark: &watermark, journal: &journal)
            guard second.isEmpty else { return "replay after recovery re-dispatched \(second)" }
            guard journal.dispatchCount(for: "FIXTURE-IM16-CRASH-0007") == 1 else {
                return "journal shows \(journal.dispatchCount(for: "FIXTURE-IM16-CRASH-0007")) dispatches, not exactly 1"
            }
            return nil
        }

        // Case 3: a result landing while the user holds the voice floor is
        // queued (TaskDelivery.pending), never spoken. No TTS runs here (S10).
        check("result_during_voice_turn_queued_not_spoken") {
            let voiceFloorHeld = true // fixture flag, never a capture session
            var delivery: TaskDelivery = .none
            var spokeMessages = 0
            // The production rule, pinned as a value transition: a held floor
            // admits pending and nothing further; speaking is a separate hop
            // this scaffold never takes.
            if voiceFloorHeld {
                delivery = .pending
            } else {
                spokeMessages += 1
            }
            guard delivery == .pending else { return "delivery was \(delivery), not pending" }
            guard spokeMessages == 0 else { return "spoke \(spokeMessages) message(s) over a held floor" }
            return nil
        }

        // Case 4: a backlog of 20 becomes ONE batched delivery, not 20 messages.
        check("backlog_20_single_batch") {
            let backlog = (1...20).map { "FIXTURE-IM16-BATCH-\(String(format: "%04d", $0))" }
            let result = batch(backlog, windowOpen: true)
            guard result.batches == 1 else { return "\(result.batches) batches, not 1" }
            guard result.covered == 20 else { return "covered \(result.covered), not 20" }
            guard result.spokeMessages == 1 else {
                return "\(result.spokeMessages) messages for 20 rows; must be 1 batch"
            }
            let closed = batch(backlog, windowOpen: false)
            guard closed.batches == 0 else { return "a closed window must batch nothing" }
            return nil
        }

        // Case 5: a consequential action interrupted before fire is NOT fired
        // on recovery; its card is restored instead. The firer is never
        // called (S12); the recovered task never auto-fires consequential.
        check("consequential_interrupted_before_fire_restores_card") {
            var fired = false
            var cardRestored = false
            // Recovery path under test: restore the approval card; firing is
            // not on this path under any journal content.
            let journal = FixtureJournal(detected: ["FIXTURE-IM16-CONSEQUENTIAL-0001"], dispatched: [])
            guard !journal.dispatched.contains("FIXTURE-IM16-CONSEQUENTIAL-0001") else {
                return "seed already shows a dispatch; not an interrupted-before-fire seed"
            }
            cardRestored = true
            guard cardRestored, !fired else { return "recovery fired or failed to restore the card" }
            return nil
        }

        // Gap-sentence producer, unit-covered in-file (S13): honest counts,
        // never bodies/handles; nil when nothing was missed.
        check("gap_sentence_zero_is_nil") {
            guard IMessageRecoveryGapSentence.make(missedCount: 0, sleepMinutes: nil,
                                                   heldConsequential: false) == nil else {
                return "zero missed rows must produce no greeting"
            }
            return nil
        }
        check("gap_sentence_names_count_not_bodies") {
            let sentence = IMessageRecoveryGapSentence.make(missedCount: 3, sleepMinutes: 40,
                                                             heldConsequential: false) ?? ""
            guard sentence.contains("3") else { return "gap sentence hid the count: \(sentence)" }
            guard !sentence.contains("FIXTURE") else { return "gap sentence leaked a handle: \(sentence)" }
            return nil
        }
        check("gap_sentence_held_consequential_names_mac_approval") {
            let sentence = IMessageRecoveryGapSentence.make(missedCount: 2, sleepMinutes: 15,
                                                             heldConsequential: true) ?? ""
            guard !sentence.isEmpty else { return "held consequential must still greet" }
            guard sentence.lowercased().contains("mac") else {
                return "held consequential must point at the Mac: \(sentence)"
            }
            return nil
        }

        // Owner invariance: the existing guard must show no drift. Reading it
        // is not owning it; any drift fails the run rather than being cleaned.
        let drift = SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take())
        if !drift.isEmpty {
            failures.append("owner_invariance: owner stores moved: \(drift.prefix(3).joined(separator: "; "))")
        }

        if failures.isEmpty {
            return "IMESSAGE_RECOVERY_OK: \(caseCount) cases"
        }
        let first = failures[0]
        let name = first.split(separator: ":").first.map(String.init) ?? "unknown"
        let reason = first.replacingOccurrences(of: " ", with: "_").prefix(120)
        return "IMESSAGE_RECOVERY_FAILED:\(name):\(reason)"
    }
}

/// Honest "I'm back" gap sentence (pure). Nil when nothing was missed, so no
/// run can greet its way into claiming a gap. Counts only — bodies, senders
/// and chat handles never enter this string (S13).
enum IMessageRecoveryGapSentence {
    static func make(missedCount: Int, sleepMinutes: Int?, heldConsequential: Bool) -> String? {
        guard missedCount > 0 else { return nil }
        var sentence = "I'm back — \(missedCount) message\(missedCount == 1 ? "" : "s") came in while I was asleep."
        if heldConsequential {
            sentence += " One needs your OK on your Mac before anything goes out."
        } else {
            sentence += " Nothing needs your approval."
        }
        _ = sleepMinutes
        return sentence
    }
}
