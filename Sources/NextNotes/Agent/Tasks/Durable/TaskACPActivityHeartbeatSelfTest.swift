import Foundation

/// Actual correct-session ACP progress, not a synthetic journal beat or health probe.
@MainActor
enum TaskACPActivityHeartbeatSelfTest {
    private enum FixtureError: Error { case unsafeRoot, busyGate, timeout, missingOwner, invalidPeer }
    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
    private static func release(_ url: URL) throws {
        try Data(#"{"release":true}"#.utf8).write(to: url, options: .atomic)
    }
    private static func object(_ url: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
    }
    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        guard PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else { throw FixtureError.busyGate }
        let oldHook = ACPAgentBackend.activityHandledForTesting
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let grantsBefore = PermissionGrantStore.shared.grants
        defer {
            ACPAgentBackend.activityHandledForTesting = oldHook
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
        }
        AgentToolExecutor.fakeForTesting = nil
        var unexpectedTools = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in
            unexpectedTools += 1
            throw FixtureError.invalidPeer
        }
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        let objective = "Owned ACP progress fixture: publish status, no tools or effects"
        let marker = "Owned ACP progress completed."
        let warning = "\nNext Notes could not independently verify the effect. Inspect the target before retrying."
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = "fixture-acp-activity-heartbeat"

        for mode in ["accepted", "rejected-save", "fresh-primary-held", "released-running-row", "burst-small", "burst-history"] {
            let held = mode == "fresh-primary-held"
            let rejected = mode == "rejected-save"
            let released = mode == "released-running-row"
            let burst = mode.hasPrefix("burst-")
            let burstCount = burst ? 32 : 1
            let historyCount = mode == "burst-history" ? 512 : 0
            let directory = safe.appendingPathComponent("acp-activity-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.authorityBoundaryForTesting = nil; sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let archived = (0..<historyCount).map { _ in
                AgentTask(objective: "Owned archived fixture task", source: "selftest", createdAt: start,
                    status: .completed, progress: "Finished", result: String(repeating: "Owned archived fixture result. ", count: 16))
            }
            if !archived.isEmpty {
                guard store.save(archived).primaryCommitted else { throw FixtureError.missingOwner }
            }
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let script = directory.appendingPathComponent("owned-activity-peer.py")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            let phase1 = directory.appendingPathComponent("release-phase1.json")
            let phase2 = directory.appendingPathComponent("release-phase2.json")
            let finish = directory.appendingPathComponent("release-result.json")
            var clock = start
            var context: TaskJournalContext?
            var binding: TaskWorkerBinding?
            var entered = 0
            var ended = 0
            var handled: [Bool?] = []
            var callbackTaskIDs: [String] = []
            var callbackMilliseconds: [Double] = []
            var announcements: [String] = []
            let stallProbe = MainActorStallProbe.shared
            var stallStartedAt: UInt64 = 0
            var lastActivityCompletedAt: UInt64 = 0
            var pingSentTimes: [UInt64] = []
            var worstSchedulingNanos: UInt64 = 0
            var ownsStallProbe = false
            let oldLandingObserver = stallProbe.landingForTesting
            // Existing callback landmarks only; no extra persistence, query or await.
            let oldMigrationBoundary = store.migrationBoundaryForTesting
            var phaseArmed = false, phaseOrderValid = true
            var primaryBegan: ContinuousClock.Instant?, primaryCommitted: ContinuousClock.Instant?
            var primaryBeginCount = 0, primaryCommitCount = 0
            var primaryMilliseconds: [Double] = [], postPrimaryMilliseconds: [Double] = []
            // Reuse the existing numeric SQL collector on each actual activity writer.
            // One writer closes before the existing activity callback consumes its snapshot.
            let oldActivityAuthorityBoundary = sql.authorityBoundaryForTesting
            var activitySQLProfile: VoiceReceiptSQLProfileForTesting?
            var activitySQLSnapshots: [VoiceReceiptSQLProfileForTesting.Snapshot] = []
            var activitySQLOrderValid = true
            sql.authorityBoundaryForTesting = { name, db in
                try oldActivityAuthorityBoundary?(name, db)
                guard burst, phaseArmed, primaryBegan != nil, primaryCommitted == nil,
                      name == "existingOpened", let db else { return }
                if activitySQLProfile != nil { activitySQLOrderValid = false }
                let profile = VoiceReceiptSQLProfileForTesting()
                activitySQLProfile = profile
                profile.install(on: db)
            }
            defer { sql.authorityBoundaryForTesting = oldActivityAuthorityBoundary }
            func phaseMilliseconds(_ duration: Duration) -> Double {
                let parts = duration.components
                return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
            }
            if burst {
                store.migrationBoundaryForTesting = { name in
                    try oldMigrationBoundary?(name)
                    guard phaseArmed else { return }
                    if name == "beforePrimaryCommit" {
                        if primaryBegan != nil || primaryCommitted != nil { phaseOrderValid = false }
                        primaryBegan = ContinuousClock.now; primaryBeginCount += 1
                    } else if name == "primaryCommitted" {
                        guard primaryBegan != nil, primaryCommitted == nil else { phaseOrderValid = false; return }
                        primaryCommitted = ContinuousClock.now; primaryCommitCount += 1
                    }
                }
            }
            defer { phaseArmed = false; store.migrationBoundaryForTesting = oldMigrationBoundary }
            defer {
                if ownsStallProbe { stallProbe.stop(); stallProbe.landingForTesting = oldLandingObserver }
            }
            var holdingSQL: TaskStore?
            var holdingManager: AgentTaskManager?
            defer { holdingSQL?.close() }
            manager.progressDateForTesting = { clock }
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendExitForTesting = { ended += 1 }
            manager.backendEntryForTesting = {
                entered += 1
                guard let captured = TaskEventJournal.current else { throw FixtureError.missingOwner }
                context = captured
                binding = manager.workerBinding(taskID: captured.taskID)
                try JSONSerialization.data(withJSONObject: ["objective": objective, "marker": marker,
                    "taskID": captured.taskID, "taskAttempt": captured.attempt, "taskLeaseOwner": owner, "phases": released ? 0 : (rejected ? 2 : 1), "burstCount": burstCount], options: .sortedKeys)
                    .write(to: directory.appendingPathComponent("config.json"), options: .atomic)
                if released {
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "CREATE TRIGGER reject_activity_terminal BEFORE UPDATE ON task WHEN NEW.state='completed' BEGIN SELECT RAISE(ABORT,'owned terminal rejection'); END")
                    }
                }
            }
            ACPAgentBackend.activityHandledForTesting = { taskID, admitted, milliseconds in
                callbackTaskIDs.append(taskID)
                handled.append(admitted)
                callbackMilliseconds.append(milliseconds)
                if burst, phaseArmed {
                    let finished = ContinuousClock.now
                    if let began = primaryBegan, let committed = primaryCommitted,
                       began <= committed, committed <= finished {
                        primaryMilliseconds.append(phaseMilliseconds(began.duration(to: committed)))
                        postPrimaryMilliseconds.append(phaseMilliseconds(committed.duration(to: finished)))
                    } else { phaseOrderValid = false }
                    if let profile = activitySQLProfile {
                        activitySQLSnapshots.append(profile.snapshot())
                    } else { activitySQLOrderValid = false }
                    activitySQLProfile = nil
                    primaryBegan = nil; primaryCommitted = nil
                }
                if burst { lastActivityCompletedAt = VoiceLatencyTimeline.nowNanos() }
            }
            let submitted = manager.submit(objective: objective, arguments: ["acpFixture": script.path],
                backend: .acp, source: "selftest")
            do {
                guard await reached({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("prompt-observed.json").path) }),
                      let context, let binding else { throw FixtureError.timeout }
                let launch = object(directory.appendingPathComponent("launch.json"))
                let before = try sql.load().first { $0.id == submitted.id }
                let beforeJournal = try sql.journal(taskID: submitted.id)
                guard let fired = receipts.receipts.first else { throw FixtureError.missingOwner }
                check(entered == 1 && ended == 0 && manager.backendStartsForTesting == 1
                    && context.taskID == submitted.id && context.attempt == 1 && context.leaseOwner == owner
                    && context.receiptStore === receipts && context.isStillValid?() == true
                    && manager.workerBinding(taskID: submitted.id) == binding,
                    "ACP activity: actual admitted live owner missing (\(mode))") // C01
                check(before?.status == .running && before?.durability?.runtimeClass == .acpWorker
                    && before?.durability?.heartbeatAt == start && before?.durability?.lastProgressAt == start
                    && fired.taskID == submitted.id && fired.taskAttempt == 1 && fired.taskLeaseOwner == owner
                    && fired.status == .fired && fired.preparedAction?.id == fired.actionID
                    && before?.durability?.receiptIDs == [fired.actionID.uuidString]
                    && beforeJournal.filter { $0.draft.kind == .toolStarted }.count == 1,
                    "ACP activity: real startup receipt/primary timing mismatch (\(mode))") // C02
                let initial = await manager.workerHeartbeatObservation(taskID: submitted.id, now: start.addingTimeInterval(1801))
                check(initial?.primary.outcome == .accepted && initial?.age?.diagnosticName == "ageCandidate"
                    && initial?.evidence.processAlive == .yes && initial?.evidence.backendSessionAlive == .unknown
                    && initial?.evidence.toolInFlight == .unknown && initial?.evidence.receiptCreated == .yes,
                    "ACP activity: old-age/current facts control missing (\(mode))") // C03
                let receiptBefore = try Data(contentsOf: receiptFile)
                if released {
                    try release(finish)
                    guard await reached({ ended == 1 }) else { throw FixtureError.timeout }
                    let rowAtRelease = try sql.load().first { $0.id == submitted.id }
                    let journalAtRelease = try sql.journal(taskID: submitted.id)
                    let exportAtRelease = try Data(contentsOf: export)
                    check(rowAtRelease?.status == .running && manager.workerBinding(taskID: submitted.id) == nil
                        && context.isStillValid?() == false && manager.lastPersistenceResult == .sqlFailed,
                        "ACP activity: terminal SQL rejection did not leave genuinely released running row") // L01
                    var opens = 0
                    sql.authorityBoundaryForTesting = { name, _ in if name == "existingOpened" { opens += 1 } }
                    let admitted = context.record(TaskJournalEventDraft(taskID: submitted.id,
                        kind: .heartbeat, detail: "acp.activity", attempt: context.attempt))
                    sql.authorityBoundaryForTesting = nil
                    check(!admitted, "ACP activity: released exact callback accepted heartbeat") // L02 target
                    check(opens == 0, "ACP activity: released callback opened primary without handle") // L03 target
                    check(try sql.load().first { $0.id == submitted.id } == rowAtRelease
                        && sql.journal(taskID: submitted.id) == journalAtRelease && Data(contentsOf: export) == exportAtRelease,
                        "ACP activity: released callback changed task/journal/export") // L04 target
                } else {
                    if held {
                        let freshSQL = TaskStore(root: directory)
                        holdingSQL = freshSQL
                        holdingManager = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: freshSQL),
                            receiptStore: ActionReceiptStore(fileURL: receiptFile))
                        check(holdingManager?.task(id: submitted.id)?.status == .recovering
                            && holdingManager?.backendStartsForTesting == 0 && manager.workerBinding(taskID: submitted.id) == binding
                            && context.isStillValid?() == false && ended == 0,
                            "ACP activity: fresh SQL hold replaced by old Task cancellation") // H01
                    }
                    if rejected {
                        try sql.withConnection { db in
                            try TaskStore.exec(db, "CREATE TRIGGER reject_activity_beat BEFORE INSERT ON task_event WHEN NEW.kind='heartbeat' BEGIN SELECT RAISE(ABORT,'owned activity rejection'); END")
                        }
                    }
                    let boundaryRow = try sql.load().first { $0.id == submitted.id }
                    let boundaryJournal = try sql.journal(taskID: submitted.id)
                    let boundaryExport = try Data(contentsOf: export)
                    clock = start.addingTimeInterval(1800)
                    if burst {
                        guard !stallProbe.isRunning else { throw FixtureError.invalidPeer }
                        stallProbe.clearSamples()
                        stallStartedAt = VoiceLatencyTimeline.nowNanos()
                        stallProbe.landingForTesting = { sent, landed in
                            guard sent >= stallStartedAt else { return }
                            pingSentTimes.append(sent)
                            worstSchedulingNanos = max(worstSchedulingNanos, landed &- sent)
                        }
                        // Arm the EXISTING diagnostic timer after setup, before the SAME release.
                        stallProbe.start()
                        ownsStallProbe = true
                    }
                    if burst { phaseArmed = true }
                    try release(phase1)
                    guard await reached({
                        guard handled.count == burstCount else { return false }
                        guard burst else { return true }
                        // A ping dispatched during the burst qualifies coverage; a later sent
                        // ping landing proves the previous outstanding ping drained as well.
                        return lastActivityCompletedAt > stallStartedAt
                            && pingSentTimes.contains { $0 < lastActivityCompletedAt }
                            && pingSentTimes.contains { $0 >= lastActivityCompletedAt }
                    }) else { throw FixtureError.timeout }
                    if burst { stallProbe.stop(); phaseArmed = false }
                    check(callbackTaskIDs == Array(repeating: submitted.id, count: burstCount) && ended == 0
                        && manager.workerBinding(taskID: submitted.id) == binding
                        && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-error.json").path),
                        "ACP activity: actual handled callback/owner/wrong-session control missing (\(mode))") // C04
                    if held || rejected {
                        check(try sql.load().first { $0.id == submitted.id } == boundaryRow
                            && sql.journal(taskID: submitted.id) == boundaryJournal && Data(contentsOf: export) == boundaryExport
                            && manager.task(id: submitted.id)?.durability == before?.durability,
                            "ACP activity: rejected/held progress changed memory or primary history (\(mode))") // C05
                        check(handled[0] != true, "ACP activity: rejected/held heartbeat acknowledged admission (\(mode))") // C06
                    }
                    if rejected {
                        check(handled[0] == false && manager.lastPersistenceResult == .sqlFailed,
                            "ACP activity: actual heartbeat INSERT rejection was not surfaced") // D01 target
                        try sql.withConnection { db in try TaskStore.exec(db, "DROP TRIGGER reject_activity_beat") }
                        clock = start.addingTimeInterval(1900)
                        try release(phase2)
                        guard await reached({ handled.count == 2 }) else { throw FixtureError.timeout }
                        check(callbackTaskIDs == [submitted.id, submitted.id] && entered == 1 && ended == 0,
                            "ACP activity: genuine retry event lost same owned callback/worker") // D02
                    }
                    if !held {
                        let row = try sql.load().first { $0.id == submitted.id }
                        let events = try sql.journal(taskID: submitted.id)
                        let beats = events.filter { $0.draft.kind == .heartbeat }
                        check((rejected ? Array(handled.dropFirst()) : handled).allSatisfy { $0 == true }, "ACP activity: real progress not admitted to owning task (\(mode))") // P01 target
                        check(row?.durability?.heartbeatAt == clock && row?.durability?.lastProgressAt == clock,
                            "ACP activity: actual progress lost durable activity stamp (\(mode))") // P02 target
                        check(manager.task(id: submitted.id)?.durability?.heartbeatAt == clock
                            && manager.task(id: submitted.id)?.durability?.lastProgressAt == clock,
                            "ACP activity: actual owning Manager lost admitted progress (\(mode))") // P03 target
                        check(beats.count == burstCount && beats.allSatisfy {
                            $0.draft.detail == "acp.activity" && $0.draft.at == clock && $0.draft.attempt == 1
                        },
                            "ACP activity: exact single metadata event not atomically retained (\(mode))") // P04 target
                        let sample = await manager.workerHeartbeatObservation(taskID: submitted.id, now: clock.addingTimeInterval(1))
                        check(sample?.age?.diagnosticName == "withinWindow" && sample?.evidence.processAlive == .yes
                            && sample?.evidence.backendSessionAlive == .unknown && sample?.evidence.toolInFlight == .unknown,
                            "ACP activity: current diagnostic ignores actual progress or invents health (\(mode))") // P05 target
                        check(row?.status == .running && row?.durability?.attempt == 1
                            && row?.durability?.leaseOwner == owner && row?.durability?.receiptIDs == [fired.actionID.uuidString]
                            && row?.durability?.retryCount == 0 && row?.durability?.resumePolicy == .neverAuto,
                            "ACP activity: heartbeat changed state/attempt/receipt/retry policy (\(mode))") // P06
                    } else {
                        let sample = await manager.workerHeartbeatObservation(taskID: submitted.id, now: clock.addingTimeInterval(1))
                        check(sample?.age == nil && sample?.evidence.processAlive == .yes
                            && sample?.primary.outcome != .accepted && sample?.evidence.backendSessionAlive == .unknown,
                            "ACP activity: fresh held primary became healthy or current-age authority") // H02
                    }
                    if burst {
                        check(Array(try sql.load().dropFirst()) == archived && manager.tasks.count == historyCount + 1,
                            "ACP activity: burst changed isolated archived full-history rows (\(mode))") // B01
                        let schedulingSeconds = Double(worstSchedulingNanos) / 1_000_000_000
                        check(callbackMilliseconds.count == burstCount && callbackMilliseconds.allSatisfy { $0.isFinite && $0 >= 0 }
                            && schedulingSeconds.isFinite && schedulingSeconds <= 0.100,
                            "ACP activity: common actual callback samples or 100ms scheduling-stall contract failed (\(mode))") // B02
                        SelfTest.diagnostic("ACP_ACTIVITY_SCHEDULING: mode=\(mode) history=\(historyCount) activities=\(burstCount) landedPings=\(pingSentTimes.count) burstPing=\(pingSentTimes.contains { $0 < lastActivityCompletedAt }) drainedPing=\(pingSentTimes.contains { $0 >= lastActivityCompletedAt }) maxSchedulingMs=\(schedulingSeconds * 1000) limitMs=100")
                        let sorted = callbackMilliseconds.sorted()
                        let sum = callbackMilliseconds.reduce(0, +)
                        SelfTest.diagnostic("ACP_ACTIVITY_OVERHEAD: mode=\(mode) history=\(historyCount) activities=\(burstCount) callbackTotalMs=\(sum) callbackMedianMs=\(sorted[sorted.count / 2]) callbackMaxMs=\(sorted.last ?? 0)")
                        let phasesQualified = phaseOrderValid && primaryBeginCount == burstCount
                            && primaryCommitCount == burstCount && primaryMilliseconds.count == burstCount
                            && postPrimaryMilliseconds.count == burstCount && primaryBegan == nil && primaryCommitted == nil
                            && primaryMilliseconds.allSatisfy { $0.isFinite && $0 >= 0 }
                            && postPrimaryMilliseconds.allSatisfy { $0.isFinite && $0 >= 0 }
                        let primaryTotal = primaryMilliseconds.reduce(0, +)
                        let postPrimaryTotal = postPrimaryMilliseconds.reduce(0, +)
                        // Residual uses the existing rounded callback millisecond sample;
                        // it is not a precise witness/decode span and may be negative.
                        SelfTest.diagnostic("ACP_ACTIVITY_PHASES: mode=\(mode) qualified=\(phasesQualified) beforePrimary=\(primaryBeginCount) committed=\(primaryCommitCount) primarySamples=\(primaryMilliseconds.count) postSamples=\(postPrimaryMilliseconds.count) primaryTotalMs=\(primaryTotal) postPrimaryExportAndPresentationTotalMs=\(postPrimaryTotal) roundedCallbackResidualMs=\(sum - primaryTotal - postPrimaryTotal) callbackQuantized=true")
                        let activitySQLQualified = activitySQLOrderValid && activitySQLProfile == nil
                            && activitySQLSnapshots.count == burstCount
                            && activitySQLSnapshots.allSatisfy { sample in
                                guard let began = sample.commitStart, let committed = sample.commitEnd,
                                      let closed = sample.closeObserved else { return false }
                                return began <= committed && committed <= closed
                                    && sample.installs == 1 && sample.closeCount == 1 && sample.problems == 0
                                    && sample.counts[2] == 1 && sample.counts[3] == 1 && sample.counts[4] == 0
                                    && sample.counts[5] == 0 && !sample.currentVersions.isEmpty
                                    && sample.currentVersions.allSatisfy { $0 == TaskStoreSchema.version }
                            }
                        check(activitySQLQualified,
                            "ACP activity schema C01 actual writers not positively qualified (\(mode))")
                        check(activitySQLQualified && activitySQLSnapshots.allSatisfy { $0.currentVersions.count == 1 },
                            "ACP activity schema F01 writer repeated schema version read in locked snapshot (\(mode))")
                        SelfTest.diagnostic("ACP_ACTIVITY_SCHEMA: mode=\(mode) qualified=\(activitySQLQualified) callbacks=\(burstCount) writers=\(activitySQLSnapshots.count) versionReads=\(activitySQLSnapshots.map { $0.currentVersions.count }) assignments=\(activitySQLSnapshots.map { $0.counts[5] })")
                    }
                    check(try Data(contentsOf: receiptFile) == receiptBefore && unexpectedTools == 0,
                        "ACP activity: metadata event changed actual receipt or ran a tool (\(mode))") // C07
                    try release(finish)
                    guard await reached({ ended == 1 }) else { throw FixtureError.timeout }
                    if held {
                        check(try sql.load().first { $0.id == submitted.id } == boundaryRow
                            && sql.journal(taskID: submitted.id) == boundaryJournal
                            && !announcements.contains { $0.contains(marker) },
                            "ACP activity: held worker published success or changed primary") // H03
                    } else {
                        check(manager.task(id: submitted.id)?.status == .completed
                            && manager.task(id: submitted.id)?.result == marker + warning,
                            "ACP activity: accepted original result changed (\(mode))") // P07
                    }
                }
                let terminal = ActionReceiptStore(fileURL: receiptFile).receipts.first
                check(entered == 1 && ended == 1 && manager.workerBinding(taskID: submitted.id) == nil
                    && terminal?.actionID == fired.actionID && terminal?.status == .couldNotVerify
                    && terminal?.taskID == submitted.id && terminal?.taskAttempt == 1 && terminal?.taskLeaseOwner == owner,
                    "ACP activity: actual owner/result receipt failed to join/release (\(mode))") // C08
                check(object(directory.appendingPathComponent("calls.json"))["methods"] as? [String]
                    == ["initialize", "session/new", "session/prompt"] && launch["launchCount"] as? Int == 1
                    && launch["parentPID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier)
                    && UUID(uuidString: object(directory.appendingPathComponent("prompt-observed.json"))["taskID"] as? String ?? "") != nil
                    && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-error.json").path),
                    "ACP activity: real peer restarted or changed protocol (\(mode))") // C09
                SelfTest.diagnostic("ACP_ACTIVITY_TRACE: mode=\(mode) callbacks=\(handled.count) heartbeatRows=\((try sql.journal(taskID: submitted.id)).filter { $0.draft.kind == .heartbeat }.count) released=\(manager.workerBinding(taskID: submitted.id) == nil)")
            } catch {
                SelfTest.diagnostic("ACP_ACTIVITY_INPUT_FAILURE: mode=\(mode) callbacks=\(handled.count) entered=\(entered) ended=\(ended) stallLandedPings=\(pingSentTimes.count) peerErrorClass=\(object(directory.appendingPathComponent("peer-error.json"))["errorClass"] as? String ?? "none")")
                try? release(phase1); try? release(phase2); try? release(finish)
                manager.cancel(submitted.id)
                guard await reached({ ended == 1 }) else { throw FixtureError.timeout }
                throw error
            }
        }
        check(unexpectedTools == 0 && PermissionGrantStore.shared.grants == grantsBefore
            && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
            "ACP activity: fixture left backing/permission/standing grants") // E01
    }

    /// Reuse the SAME owned protocol peer for actual mounted voice activity.
    static func writeVoiceActivityPeer(root: URL) throws -> URL {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              safe.path.hasPrefix(temp.path + "/"), !safe.pathComponents.contains("Application Support") else {
            throw FixtureError.unsafeRoot
        }
        let script = safe.appendingPathComponent("owned-voice-activity-peer.py")
        try peer.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    private static let peer = #"""
    import json, os, pathlib, sys, tempfile, time, uuid
    root = pathlib.Path(__file__).resolve().parent
    tmp = pathlib.Path(tempfile.gettempdir()).resolve()
    assert root != tmp and tmp in root.parents and 'Application Support' not in root.parts
    config = json.loads((root / 'config.json').read_text())
    assert isinstance(config['taskID'], str) and str(uuid.UUID(config['taskID'])).lower() == config['taskID'].lower()
    assert config['taskAttempt'] == 1 and config['taskLeaseOwner'] == str(os.getppid())
    session = 'fixture-acp-activity-heartbeat'
    methods = []
    def write(name, value):
        target = root / name
        temporary = root / (name + '.tmp')
        temporary.write_text(json.dumps(value, sort_keys=True))
        temporary.replace(target)
    def send(value):
        sys.stdout.write(json.dumps(value) + '\n')
        sys.stdout.flush()
    def wait(name):
        deadline = time.monotonic() + 12
        while not (root / name).exists():
            if time.monotonic() >= deadline:
                raise TimeoutError('owned phase release')
            time.sleep(0.005)
        assert json.loads((root / name).read_text()) == {'release': True}
    def activity(sid, title):
        send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':sid,
            'update':{'sessionUpdate':'tool_call_update','title':title}}})
    try:
        assert not (root / 'launch.json').exists()
        write('launch.json', {'launchCount':1, 'pid':os.getpid(), 'parentPID':os.getppid()})
        for line in sys.stdin:
            request = json.loads(line)
            mid, method = request.get('id'), request.get('method')
            assert mid is not None and method is not None
            methods.append(method)
            write('calls.json', {'methods':methods})
            if method == 'initialize':
                send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':1,'agentCapabilities':{}}})
            elif method == 'session/new':
                send({'jsonrpc':'2.0','id':mid,'result':{'sessionId':session}})
            elif method == 'session/prompt':
                assert methods == ['initialize','session/new','session/prompt']
                assert request['params']['sessionId'] == session
                assert request['params']['prompt'][0]['text'] == config['objective']
                write('prompt-observed.json', {'taskID':config['taskID'],'promptCount':1})
                if config['phases']:
                    wait('release-phase1.json')
                    activity('wrong-session', 'Do not attribute this status')
                    # Actual non-message progress is unbounded in the producer. Bound this workload only.
                    for index in range(config['burstCount']):
                        activity(session, 'Owned fixture phase one ' + str(index))
                    # These native message/thought updates must not become durable progress events.
                    send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                        'update':{'sessionUpdate':'agent_thought_chunk','content':{'type':'text','text':'owned thought'}}}})
                    send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                        'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':''}}}})
                if config['phases'] == 2:
                    wait('release-phase2.json')
                    activity(session, 'Owned fixture phase two')
                wait('release-result.json')
                send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                    'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':config['marker']}}}})
                send({'jsonrpc':'2.0','id':mid,'result':{'stopReason':'end_turn'}})
            elif method == 'session/cancel':
                send({'jsonrpc':'2.0','id':mid,'result':{}})
            else:
                raise ValueError('unexpected owned protocol method')
    except Exception as error:
        write('peer-error.json', {'errorClass':type(error).__name__})
        raise
    """#
}
