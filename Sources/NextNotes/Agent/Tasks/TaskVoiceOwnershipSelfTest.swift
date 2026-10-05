import Foundation
import SQLite3

/// Numeric-only diagnostic on the SAME temporary existing-only SQLite writer.
/// SQLite retains this context until its CLOSE callback; no connection is retained.
/// PROFILE nanoseconds are SQLite estimates; monotonic COMMIT endpoints are separate.
final class VoiceReceiptSQLProfileForTesting {
    struct Snapshot {
        let installs: Int, closeCount: Int, problems: Int
        let counts: [Int], nanoseconds: [UInt64], currentVersions: [Int64]
        let commitStart: ContinuousClock.Instant?, commitEnd: ContinuousClock.Instant?
        let closeObserved: ContinuousClock.Instant?
    }
    private let lock = NSLock()
    private var installs = 0, closeCount = 0, problems = 0
    private var counts = Array(repeating: 0, count: 6)
    private var nanoseconds = Array(repeating: UInt64(0), count: 6)
    private var currentVersions: [Int64] = []
    private var commitStart: ContinuousClock.Instant?, commitEnd: ContinuousClock.Instant?
    private var closeObserved: ContinuousClock.Instant?
    func install(on db: OpaquePointer) {
        lock.lock(); installs += 1; lock.unlock()
        let context = Unmanaged.passRetained(self).toOpaque()
        let result = sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE | SQLITE_TRACE_ROW | SQLITE_TRACE_CLOSE), { event, context, pointer, value in
            guard let context else { return 0 }
            let collector = Unmanaged<VoiceReceiptSQLProfileForTesting>.fromOpaque(context).takeUnretainedValue()
            collector.observe(event, pointer: pointer, value: value)
            if event == UInt32(SQLITE_TRACE_CLOSE) {
                Unmanaged<VoiceReceiptSQLProfileForTesting>.fromOpaque(context).release()
            }
            return 0
        }, context)
        if result != SQLITE_OK {
            Unmanaged<VoiceReceiptSQLProfileForTesting>.fromOpaque(context).release()
            lock.lock(); problems += 1; lock.unlock()
        }
    }
    private func observe(_ event: UInt32, pointer: UnsafeMutableRawPointer?, value: UnsafeMutableRawPointer?) {
        let landed = ContinuousClock.now
        lock.lock(); defer { lock.unlock() }
        if event == UInt32(SQLITE_TRACE_CLOSE) { closeCount += 1; closeObserved = landed; return }
        guard let pointer else { problems += 1; return }
        let statement = OpaquePointer(pointer)
        let sql = sqlite3_sql(statement)
        if event == UInt32(SQLITE_TRACE_ROW) {
            if let sql, strcmp(sql, "PRAGMA user_version") == 0 {
                guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER, currentVersions.count < 16 else { problems += 1; return }
                currentVersions.append(sqlite3_column_int64(statement, 0))
            }
            return
        }
        let kind: Int
        if let sql, strcmp(sql, "COMMIT") == 0 { kind = 3 }
        else if let sql, strcmp(sql, "BEGIN IMMEDIATE") == 0 { kind = 2 }
        else if let sql, strcmp(sql, "ROLLBACK") == 0 { kind = 4 }
        else if let sql, strcmp(sql, "PRAGMA user_version = 5") == 0 { kind = 5 }
        else { kind = sqlite3_stmt_readonly(statement) != 0 ? 0 : 1 }
        if event == UInt32(SQLITE_TRACE_STMT) {
            if kind == 3 { if commitStart != nil { problems += 1 }; commitStart = landed }
            return
        }
        guard event == UInt32(SQLITE_TRACE_PROFILE), let value else { problems += 1; return }
        counts[kind] += 1
        let ns = value.assumingMemoryBound(to: UInt64.self).pointee
        let sum = nanoseconds[kind].addingReportingOverflow(ns)
        if sum.overflow { problems += 1 } else { nanoseconds[kind] = sum.partialValue }
        if kind == 3 { if commitEnd != nil { problems += 1 }; commitEnd = landed }
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(installs: installs, closeCount: closeCount, problems: problems,
            counts: counts, nanoseconds: nanoseconds, currentVersions: currentVersions, commitStart: commitStart,
            commitEnd: commitEnd, closeObserved: closeObserved)
    }
    func report(fixture: String, started: ContinuousClock.Instant, ended: ContinuousClock.Instant,
                authorityLandmarks: [(String, ContinuousClock.Instant)], authorityQualified: Bool,
                writerCloseReturns: [ContinuousClock.Instant] = []) {
        let observed = snapshot()
        let qualified = authorityQualified && observed.installs == 1 && observed.closeCount == 1
            && observed.problems == 0 && observed.counts[2] == 1 && observed.counts[3] == 1 && observed.counts[4] == 0
            && !observed.currentVersions.isEmpty && observed.currentVersions.allSatisfy { $0 == TaskStoreSchema.version }
            && observed.counts[5] <= 1
            && observed.commitStart.map { $0 >= authorityLandmarks[6].1 && $0 <= ended } == true
            && observed.commitEnd.map { end in observed.commitStart.map { $0 <= end } == true && end <= authorityLandmarks[7].1 } == true
            && observed.closeObserved.map { close in observed.commitEnd.map { $0 <= close } == true && close <= authorityLandmarks[7].1 } == true
        print("VOICE_RECEIPT_SQL_PROFILE fixture=\(fixture) qualified=\(qualified) installs=\(observed.installs) closes=\(observed.closeCount) problems=\(observed.problems)")
        guard qualified, let commitStart = observed.commitStart, let commitEnd = observed.commitEnd, let close = observed.closeObserved else { return }
        print("VOICE_RECEIPT_SCHEMA_ASSIGNMENT fixture=\(fixture) currentReadCount=\(observed.currentVersions.count) currentVersion=\(TaskStoreSchema.version) assignmentCount=\(observed.counts[5]) estimatedNs=\(observed.nanoseconds[5])")
        for kind in observed.counts.indices {
            print("VOICE_RECEIPT_SQL_CLASS fixture=\(fixture) kind=\(kind) count=\(observed.counts[kind]) estimatedNs=\(observed.nanoseconds[kind])")
        }
        let intervals = [("preCommitFinalChecks", authorityLandmarks[6].1.duration(to: commitStart)),
            ("commitStatement", commitStart.duration(to: commitEnd)),
            ("postCommitToCloseHook", commitEnd.duration(to: close)),
            ("closeHookToPrimaryReturn", close.duration(to: authorityLandmarks[7].1))]
        for (stage, duration) in intervals {
            let parts = duration.components
            let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
            print("VOICE_RECEIPT_SQL_STAGE fixture=\(fixture) stage=\(stage) ms=\(ms)")
        }
        let closeReturnQualified = writerCloseReturns.count == 1
            && writerCloseReturns.allSatisfy { close <= $0 && $0 <= authorityLandmarks[7].1 }
        print("VOICE_RECEIPT_CLOSE_RETURN fixture=\(fixture) qualified=\(closeReturnQualified) count=\(writerCloseReturns.count)")
        if closeReturnQualified, let returned = writerCloseReturns.first {
            for (stage, duration) in [("closeHookToCloseReturn", close.duration(to: returned)),
                                      ("closeReturnToPrimaryReturn", returned.duration(to: authorityLandmarks[7].1))] {
                let parts = duration.components
                let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
                print("VOICE_RECEIPT_CLOSE_STAGE fixture=\(fixture) stage=\(stage) ms=\(ms)")
            }
        }
    }
}

/// Actual intake/Bridge -> real planner -> temporary backing, then SAME retained Task return.
/// ORIGINAL observes Coordinator handles; COMMON does not transfer live ownership.
@MainActor
enum TaskVoiceOwnershipSelfTest {
    private enum Invalid: Error { case unsafe, owner, worker, grammar }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let until = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < until { if await predicate() { return true }; await Task.yield() }
        return await predicate()
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared; let capture = AgentCaptureController.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0,
              c.taskBridge.cachedTasks.allSatisfy({ row in UUID(uuidString: row.id).flatMap { c.captureVoiceWorkerForTesting(id: $0) } == nil })
        else { return (0, ["voice ownership: INVALID existing owner"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.deletingLastPathComponent().path == temp.path,
              root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["voice ownership: INVALID root"]) }
        let previousBridge = c.taskBridgeOverrideForTesting; let previousRemember = c.rememberExplicit
        let oldFake = AgentToolExecutor.fakeForTesting; let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting; let oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let owner = SelfTestStoreGuard.take()
        var checks = 0; var failures: [String] = []; var created = false
        var owned: [Task<Void, Never>] = []; var probe: VoiceOwnershipProbe?
        func check(_ ok: Bool, _ label: String) { checks += 1; if !ok { failures.append("voice ownership: " + label) } }
        func input(_ text: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(text, source: .voice)
        }
        defer {
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(previousBridge); c.rememberExplicit = previousRemember
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole; ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            if created { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .selfTest
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            for mode in ["completed", "raw-spawn", "raw-resume", "cancel-accepted", "cancel-save-refused", "finish-save-refused"] {
                let beforeChecks = checks
                var followupReached = false
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("owned.txt"); let bytes = "Owned migration bytes " + UUID().uuidString
                try Data(bytes.utf8).write(to: target)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store); let bridge = TaskBridge(manager: manager)
                c.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard c.installTaskBridgeForTesting(bridge) else { throw Invalid.unsafe }
                await capture.beginSession(captureAudio: false)
                guard let session = capture.sessionID else { throw Invalid.owner }
                let request = "Inspect the owned migration document for " + mode + "."
                let answer = "Use the file at " + target.path
                let state = VoiceOwnershipProbe(request: request, answer: answer, target: target.path,
                    contents: bytes, asksQuestion: mode == "raw-resume"); probe = state
                c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}; c.workerForTesting = nil
                c.workerProviderForTesting = VoiceOwnershipProvider(probe: state)
                c.streamForTesting = { _, messages in await state.frontend(messages) }
                var reads = 0
                c.streamForTesting = { _, messages in
                    return await state.frontend(messages)
                }
                AgentToolExecutor.fireOverrideForTesting = { tool, args in
                    guard tool.id == "filesystem.read", args == ["path": target.path],
                          target.standardizedFileURL.path == target.resolvingSymlinksInPath().standardizedFileURL.path else { throw Invalid.unsafe }
                    reads += 1; return try FilesystemExecutor.run(tool, arguments: args)
                }
                let accepted = await input(request)
                owned = bridge.cachedTasks.compactMap { row in UUID(uuidString: row.id).flatMap { c.captureVoiceWorkerForTesting(id: $0) }?.task }
                guard let row = bridge.cachedTasks.first, let id = UUID(uuidString: row.id),
                      let initial = c.captureVoiceWorkerForTesting(id: id), let task = initial.task,
                      await reached({ await state.heldCount == 1 }),
                      case .voice(let rowSession, let turn)? = row.origin, rowSession == session,
                      let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.worker }
                check(accepted.reply == "I'm on it." && row.status == .running && reads == 0 && owned.count == 1,
                    "C01 actual current primary/held planner did not qualify (\(mode))")
                let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: initial.work.original,
                    previousRequest: AgentSession.shared.recentUserTexts(limit: 2).dropLast().last)
                let call = try state.call(); let parsed = AgentToolCallParser.parse(call, knownNames: RealtimeAgent.callNames(manifest))
                guard manifest.allowedIDs.contains("filesystem.read"), LlamaGrammarPlanner.grammar(for: manifest).matches(call),
                      parsed.calls.count == 1, parsed.calls.first?.name == "filesystem.read" else { throw Invalid.grammar }
                check(!task.isCancelled && initial.bridge === bridge, "C02 actual planner/captured owner invalid (\(mode))")
                check(manager.voiceOwnedOperationForTesting(id: id) == task && manager.voiceWorkHeldForTesting(id: id),
                    "F01 SAME actual voice Task was not owned by Manager map (\(mode))")
                if mode == "raw-spawn" {
                    let objective = "Read another owned migration document."
                    var receiptStages: [(String, Duration)] = []
                    var saveBoundaries: [(String, ContinuousClock.Instant)] = []
                    var admissionReturned: ContinuousClock.Instant?
                    var authorityLandmarks: [(String, ContinuousClock.Instant)] = []
                    var writerCloseReturns: [ContinuousClock.Instant] = []
                    let sqlProfile = VoiceReceiptSQLProfileForTesting()
                    let probeProfile = VoiceReceiptSQLProfileForTesting()
                    var existingOpens = 0
                    let priorAuthorityBoundary = sql.authorityBoundaryForTesting
                    sql.authorityBoundaryForTesting = { name, db in
                        if ["beforeExistingOpen", "existingOpened", "probeMarkerRead", "beforeAuthorityCommit"].contains(name) {
                            authorityLandmarks.append((name, ContinuousClock.now))
                        }
                        if name == "existingOpened" {
                            existingOpens += 1
                            if existingOpens == 1, let db { probeProfile.install(on: db) }
                            if existingOpens == 2, let db { sqlProfile.install(on: db) }
                        }
                        if name == "existingClosed", existingOpens == 2 {
                            writerCloseReturns.append(ContinuousClock.now)
                        }
                        try priorAuthorityBoundary?(name, db)
                    }
                    let priorBoundary = store.migrationBoundaryForTesting
                    defer {
                        sql.authorityBoundaryForTesting = priorAuthorityBoundary
                        store.migrationBoundaryForTesting = priorBoundary
                    }
                    store.migrationBoundaryForTesting = { name in
                        if name == "beforePrimaryCommit" || name == "primaryCommitted" {
                            let landed = ContinuousClock.now
                            saveBoundaries.append((name, landed))
                            authorityLandmarks.append((name, landed))
                        }
                        try priorBoundary?(name)
                    }
                    c.voiceReceiptTimingForTesting = { stage, duration in
                        receiptStages.append((stage, duration))
                        if stage == "bridgeAdmission" { admissionReturned = ContinuousClock.now }
                    }
                    let started = ContinuousClock.now
                    let receipt = bridge.spawnVoiceObjective(id: UUID(), objective: objective, userWords: objective,
                        origin: .voice(sessionID: session, turn: turn))
                    let receiptEnded = ContinuousClock.now
                    let elapsed = started.duration(to: receiptEnded)
                    sql.authorityBoundaryForTesting = priorAuthorityBoundary
                    c.voiceReceiptTimingForTesting = nil
                    store.migrationBoundaryForTesting = priorBoundary
                    let expectedAuthorityStages = ["beforeExistingOpen", "existingOpened", "probeMarkerRead", "beforePrimaryCommit", "beforeExistingOpen", "existingOpened", "beforeAuthorityCommit", "primaryCommitted"]
                    let authorityQualified = authorityLandmarks.map { $0.0 } == expectedAuthorityStages
                        && authorityLandmarks.allSatisfy { $0.1 >= started && $0.1 <= receiptEnded }
                        && zip(authorityLandmarks, authorityLandmarks.dropFirst()).allSatisfy { $0.0.1 <= $0.1.1 }
                    print("VOICE_RECEIPT_AUTHORITY_STAGES fixture=C03 qualified=\(authorityQualified) count=\(authorityLandmarks.count)")
                    if authorityQualified {
                        let labels = ["probeOpen", "readProbeBody", "probeReturnWitnessPreflight", "writePreparation", "writeOpen", "writeBody", "commitPostcheckClose"]
                        var measured: [(String, Duration)] = [("beforeProbe", started.duration(to: authorityLandmarks[0].1))]
                        for index in labels.indices { measured.append((labels[index], authorityLandmarks[index].1.duration(to: authorityLandmarks[index + 1].1))) }
                        measured.append(("exportAndPublicDispatch", authorityLandmarks[7].1.duration(to: receiptEnded)))
                        for (stage, duration) in measured {
                            let parts = duration.components
                            let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
                            print("VOICE_RECEIPT_AUTHORITY_STAGE fixture=C03 stage=\(stage) ms=\(ms)")
                        }
                    }
                    sqlProfile.report(fixture: "C03", started: started, ended: receiptEnded, authorityLandmarks: authorityLandmarks, authorityQualified: authorityQualified, writerCloseReturns: writerCloseReturns)
                    let readProbe = probeProfile.snapshot()
                    let probeQualified = authorityQualified && readProbe.installs == 1 && readProbe.closeCount == 1
                        && readProbe.problems == 0 && readProbe.counts[2] == 0 && readProbe.counts[3] == 1
                        && readProbe.counts[4] == 0 && !readProbe.currentVersions.isEmpty
                        && readProbe.currentVersions.allSatisfy { $0 == TaskStoreSchema.version }
                    print("VOICE_RECEIPT_PROBE_VERSION fixture=C03 qualified=\(probeQualified) reads=\(readProbe.currentVersions.count) installs=\(readProbe.installs) closes=\(readProbe.closeCount) problems=\(readProbe.problems)")
                    check(probeQualified, "PROBE_C03 actual existing read transaction observation did not qualify")
                    check(probeQualified && readProbe.currentVersions.count == 1, "PROBE_C03 actual authority probe repeated the validated schema version read")
                    let writerSchema = sqlProfile.snapshot()
                    check(authorityQualified && writerSchema.installs == 1 && writerSchema.closeCount == 1
                        && writerSchema.problems == 0 && writerSchema.counts[2] == 1
                        && writerSchema.counts[3] == 1 && writerSchema.counts[4] == 0
                        && writerSchema.currentVersions == [TaskStoreSchema.version],
                        "SCHEMA_C03 actual writer repeated schema version validation in one transaction")
                    let saveNames = saveBoundaries.map { $0.0 }
                    let saveQualified = saveNames == ["beforePrimaryCommit", "primaryCommitted"]
                        && admissionReturned != nil && saveBoundaries.allSatisfy { $0.1 >= started }
                        && (admissionReturned.map { returned in saveBoundaries.last.map { last in last.1 <= returned } ?? false } ?? false)
                    print("VOICE_OWNERSHIP_RECEIPT_SAVE_STAGES qualified=\(saveQualified) count=\(saveBoundaries.count)")
                    if saveQualified, let admittedAt = admissionReturned {
                        let measurements = [("precommit", started.duration(to: saveBoundaries[0].1)),
                            ("primaryCommit", saveBoundaries[0].1.duration(to: saveBoundaries[1].1)),
                            ("postcommitExport", saveBoundaries[1].1.duration(to: admittedAt))]
                        for (stage, duration) in measurements {
                            let parts = duration.components
                            let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
                            print("VOICE_OWNERSHIP_RECEIPT_SAVE_STAGE stage=\(stage) ms=\(ms)")
                        }
                    }
                    let admissionStages = ["bridgeAdmission", "bridgeTotal"]
                    let dispatchStages = ["bridgeAdmission", "prewarm", "workerConstruction", "managerStart", "acceptedEvent", "bridgeTotal"]
                    let landedStages = receiptStages.map { $0.0 }
                    print("VOICE_OWNERSHIP_RECEIPT_STAGES qualified=\(landedStages == admissionStages || landedStages == dispatchStages) dispatchObserved=\(landedStages == dispatchStages) count=\(receiptStages.count)")
                    for (stage, duration) in receiptStages {
                        let parts = duration.components
                        let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
                        print("VOICE_OWNERSHIP_RECEIPT_STAGE stage=\(stage) ms=\(ms)")
                    }
                    guard receipt.status == .accepted, let secondID = receipt.id,
                          let secondUUID = UUID(uuidString: secondID.raw) else { throw Invalid.worker }
                    let next = c.captureVoiceWorkerForTesting(id: secondUUID)
                    if let operation = next?.task { owned.append(operation) }
                    check(next?.task != nil, "F02 public raw spawn admitted a row without dispatching an actual worker")
                    check(elapsed <= .milliseconds(5), "C03 raw receipt exceeded unchanged 5ms target")
                    print("VOICE_OWNERSHIP_RECEIPT elapsed=\(elapsed) entered=\(await state.calls) actualTask=\(next?.task != nil)")
                    // ORIGINAL has no new worker. Never seed/direct-submit to fabricate its continuation.
                    if let next, let operation = next.task {
                        guard await reached({ await state.heldCount == 2 }) else { throw Invalid.worker }
                        followupReached = true
                        check(next.work.id == secondUUID && next.worker !== initial.worker
                            && manager.voiceOwnedOperationForTesting(id: secondUUID) == operation,
                            "F03 raw spawn did not dispatch its exact admitted Manager Task")
                        await state.releaseAll(); for operation in owned { await operation.value }
                        check(manager.task(id: secondID.raw)?.status == .completed && manager.tasks.count == 2 && reads == 2,
                            "C04 actual raw dispatch did not deliver its two real reads")
                        check(!manager.voiceWorkHeldForTesting(id: secondUUID) && c.captureVoiceWorkerForTesting(id: secondUUID) == nil,
                            "F04 terminal raw worker/work references were retained")
                    } else { await state.releaseAll(); await task.value }
                } else if mode == "raw-resume" {
                    await state.releaseAll(); await task.value
                    guard let question = bridge.voiceInputRequest(TaskID(id)),
                          manager.task(id: row.id)?.status == .waitingForInput else { throw Invalid.worker }
                    check(reads == 0 && question.question == VoiceOwnershipProbe.question
                        && c.captureVoiceWorkerForTesting(id: id)?.worker === initial.worker,
                        "C05 actual question lost its legitimately resumable SAME worker")
                    check(manager.voiceWorkHeldForTesting(id: id) && manager.voiceOwnedOperationForTesting(id: id) == nil,
                        "F05 Manager did not retain waiting work without a running Task")
                    await state.parkNext()
                    let admitted = bridge.resumeVoiceObjective(id: id, requestID: question.id, answer: answer, sessionID: session)
                    let resumed = c.captureVoiceWorkerForTesting(id: id)
                    if let operation = resumed?.task { owned.append(operation) }
                    check(admitted && resumed?.task != nil, "F06 raw explicit answer did not dispatch SAME saved job")
                    if let resumed, let operation = resumed.task {
                        guard await reached({ await state.heldCount == 1 }) else { throw Invalid.worker }
                        followupReached = true
                        let primary = try sql.load().first { $0.id == row.id }
                        check(resumed.work === initial.work && resumed.worker === initial.worker
                            && primary?.pendingInteraction == nil && primary?.userWords == answer
                            && primary?.revision == resumed.work.revision && resumed.work.followUps == [answer] && reads == 0,
                            "F07 raw continuation did not commit exact answer/revision before backing")
                        check(manager.voiceOwnedOperationForTesting(id: id) == operation,
                            "F08 resumed actual operation is not the SAME Manager-owned Task")
                        await state.releaseAll(); await operation.value
                        check(reads == 1 && manager.tasks.count == 1 && manager.task(id: row.id)?.status == .completed,
                            "C06 SAME raw resumed planner/backing did not complete once")
                    }
                } else {
                    let before = try sql.load(); let exported = try Data(contentsOf: file); let events = try sql.journal(taskID: row.id)
                    if mode == "cancel-save-refused" || mode == "finish-save-refused" {
                        let stateName = mode == "cancel-save-refused" ? "cancelled" : "completed"
                        try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_owned_finish BEFORE UPDATE ON task WHEN NEW.state='" + stateName + "' BEGIN SELECT RAISE(ABORT,'owned migration refusal'); END") }
                    }
                    if mode == "cancel-save-refused" || mode == "cancel-accepted" {
                        // Actual deterministic Coordinator caller, while the real model Task is held.
                        let reply = await input("Stop that task.")
                        let stopped = manager.lastPersistenceResult?.primaryCommitted == true
                        let legacyCancelCopy = reply.reply == (mode == "cancel-accepted" ? "I'm stopping that task." : "I'm stopping that task, but couldn't save its status.")
                        let namedCancel = "Stopping " + TaskStatusRenderer.title(row.objective) + " now."
                            + (mode == "cancel-accepted" ? "" : " I couldn't save its status.")
                        let namedCancelCopy = reply.reply == namedCancel
                        print("VOICE_STATUS_COPY scope=ownershipCancel mode=\(mode) legacy=\(legacyCancelCopy) named=\(namedCancelCopy) sameTaskCancelled=\(task.isCancelled)")
                        check((legacyCancelCopy || namedCancelCopy)
                            && task.isCancelled,
                            "F13 pending cancellation acknowledgment claimed cessation (\(mode))")
                        check(stopped == (mode == "cancel-accepted") && task.isCancelled && !c.hasActiveWork
                            && (mode == "cancel-accepted" || manager.lastPersistenceResult == .sqlFailed),
                            "C07 refused primary cancellation did not stop SAME live operation immediately")
                        check(manager.voiceOwnedOperationForTesting(id: id) == task,
                            "F09 cancellation released the actual Task before its genuine return")
                        if mode == "cancel-save-refused" {
                            check(try sql.load() == before && Data(contentsOf: file) == exported && sql.journal(taskID: row.id) == events,
                                "C08 refused cancellation changed primary/export/journal")
                        }
                        _ = await input("Tell me a haiku.")
                        check(await state.stoppingShown && reads == 0 && task.isCancelled,
                            "F12 actual frontend called pending cancellation stopped (\(mode))")
                    }
                    await state.releaseAll(); await task.value
                    if mode == "completed" {
                        check(reads == 1 && manager.task(id: row.id)?.status == .completed,
                            "C09 real planner/read/terminal result did not qualify")
                    } else if mode == "cancel-accepted" {
                        check(reads == 0 && manager.task(id: row.id)?.status == .cancelled,
                            "C13 accepted cancelled operation ran backing or lost stored cancellation")
                    } else {
                        check(manager.task(id: row.id)?.status == .running && manager.lastPersistenceResult == .sqlFailed
                            && reads == (mode == "cancel-save-refused" ? 0 : 1),
                            "C10 refused terminal transition lost uncertainty or replayed backing (\(mode))")
                        check(bridge.voiceControlObservation(id) == .returned,
                            "F10 exact operation return did not preserve payload-free uncertainty")
                    }
                }
                check(manager.voiceOwnedOperationForTesting(id: id) == nil && !manager.voiceWorkHeldForTesting(id: id)
                    && c.captureVoiceWorkerForTesting(id: id) == nil,
                    "F11 returned terminal operation retained Task/work/worker references (\(mode))")
                check(try Data(contentsOf: target) == Data(bytes.utf8), "C11 actual read changed its input (\(mode))")
                print("VOICE_OWNERSHIP_CASE mode=\(mode) checks=\(checks-beforeChecks) reads=\(reads) calls=\(await state.calls) initialJoined=true followupReached=\(followupReached)")
                owned = []; probe = nil
                await capture.endSession(source: .done); c.resetForTesting()
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C12 owner isolation")
        } catch {
            failures.append("voice ownership: INVALID \(error)")
            for row in c.taskBridge.cachedTasks { if let id = UUID(uuidString: row.id) { _ = c.cancel(id) } }
            await probe?.releaseAll(); for task in owned { await task.value }
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
}
private actor VoiceOwnershipProbe {
    nonisolated static let question = "Which file should I read?"
    let request: String; let answer: String; let target: String; let contents: String; let asksQuestion: Bool
    private var held: [CheckedContinuation<Void, Never>] = []; private var shouldPark = true
    private(set) var calls = 0
    private(set) var stoppingShown = false
    var heldCount: Int { held.count }
    init(request: String, answer: String, target: String, contents: String, asksQuestion: Bool) {
        self.request = request; self.answer = answer; self.target = target; self.contents = contents; self.asksQuestion = asksQuestion
    }
    func releaseAll() { let all = held; held = []; for continuation in all { continuation.resume() } }
    func parkNext() { shouldPark = true }
    func frontend(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        stoppingShown = stoppingShown || messages.contains { $0.content.contains("[Stopping]") || $0.content.contains("[Stopping; saved status uncertain]") }
        let text = messages.last?.content ?? ""
        return AsyncThrowingStream { stream in
            stream.yield(text.hasSuffix("Latest user speech:\n" + request) ? "<use_tools/>" : "<answer/>The owned document is ready.")
            stream.finish()
        }
    }
    nonisolated func call() throws -> String {
        let arguments = try JSONSerialization.data(withJSONObject: ["path": target], options: [.sortedKeys])
        return "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":" + String(decoding: arguments, as: UTF8.self)
            + ",\"rationale\":\"Read the exact owned migration file.\"}</tool_call>"
    }
    func complete(user: String) async throws -> String {
        calls += 1
        if user.contains(contents) { return "The owned migration document is ready." }
        if shouldPark || !asksQuestion { shouldPark = false; await withCheckedContinuation { held.append($0) } }
        if asksQuestion && !user.contains(answer) { return Self.question }
        return try call()
    }
}
private struct VoiceOwnershipProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: VoiceOwnershipProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let value = try await probe.complete(user: user)
        return LLMCompletion(text: value, generatedTokens: value.count, duration: 0)
    }
}
