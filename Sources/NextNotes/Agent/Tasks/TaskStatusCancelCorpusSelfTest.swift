import Foundation
import SQLite3

/// Actual voice intake/Bridge/Manager and planned read, with scripted external model
/// and a confined real filesystem backing. No seeded Job, request, or effect receipt.
@MainActor
enum TaskStatusCancelCorpusSelfTest {
    private enum Invalid: Error { case unsafe, scope, worker, grammar }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline { if await predicate() { return true }; await Task.yield() }
        return await predicate()
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let conversation = VoiceConversationCoordinator.shared; let capture = AgentCaptureController.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive, !conversation.hasActiveWork,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            return (0, ["status corpus: INVALID scope"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["status corpus: INVALID root"]) }
        let priorBridge = conversation.taskBridgeOverrideForTesting; let oldRemember = conversation.rememberExplicit
        let oldFake = AgentToolExecutor.fakeForTesting; let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting; let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting; let oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let owner = SelfTestStoreGuard.take()
        var tasks: [Task<Void, Never>] = []; var captures: [VoiceWorkerTestCapture] = []; var activeProbe: StatusCorpusProbe?
        var created = false; var safeCleanup = true; var contextInstalled = false
        var contextManager: AgentTaskManager?
        // Retain SAME admitted handles before any held/grammar qualification can fail.
        func retainCurrentWorkers() {
            guard let manager = contextManager else { return }
            for row in manager.tasks.reversed() {
                guard let id = UUID(uuidString: row.id), !captures.contains(where: { $0.id == id }),
                      let observed = conversation.captureVoiceWorkerForTesting(id: id) else { continue }
                captures.append(observed)
                if let task = observed.task { tasks.append(task) }
            }
        }
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("status corpus: " + label) } }
        func input(_ text: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(text, source: .voice)
        }
        defer {
            if contextInstalled { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            contextManager?.completionDeliveryForTesting = nil
            conversation.resetForTesting(); _ = conversation.installTaskBridgeForTesting(priorBridge)
            conversation.rememberExplicit = oldRemember
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy; AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole; ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            if created && safeCleanup { try? FileManager.default.removeItem(at: root) }
        }
        let signatures = ["How's it going?", "How is it going?", "Hows it going?", "How's that going?", "How is that going?",
            "Is it done?", "Is it done yet?", "Are you done?", "Are you done yet?", "Is that done?",
            "Any update?", "Any updates?", "Any news?", "What's the status?", "What is the status?", "Status?",
            "How far along are you?", "Is it finished?", "Are you finished?", "What are you working on?",
            "Are you still working on it?", "Still working on it?", "How long will it take?"]
        let cancels = ["Cancel.", "Cancel it.", "Cancel that task", "Stop that task."]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                guard meeting == nil, let task, contextManager?.task(id: task) != nil else { return nil }
                return ToolCallContext()
            }, root: root) else { throw Invalid.unsafe }; contextInstalled = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .selfTest
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            let modes = signatures.indices.map { "status-\($0)" }
                + cancels.indices.flatMap { ["cancel-one-\($0)", "cancel-two-\($0)"] }
                + ["repeat", "multi", "no-task-status", "no-task-cancel", "typed-all", "typed-one", "typed-none",
                   "completed", "consume-refused", "receipt-budget", "ambiguous"]
            for mode in modes {
                let startChecks = checks
                let dir = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                let target = dir.appendingPathComponent("owned.txt"); let contents = "Owned status bytes " + UUID().uuidString
                try Data(contents.utf8).write(to: target)
                let sql = TaskStore(root: dir); defer { sql.close() }
                let file = dir.appendingPathComponent("agent-tasks.json"); let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store); contextManager = manager; let bridge = TaskBridge(manager: manager)
                conversation.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard conversation.installTaskBridgeForTesting(bridge) else { throw Invalid.scope }
                var completedCallbacks = 0; var completionAdmissions = 0
                if mode == "completed" || mode == "consume-refused" {
                    guard let output = OutputScheduler.isolatedForTesting(bridge) else { throw Invalid.scope }
                    manager.completionDeliveryForTesting = { id in
                        completedCallbacks += 1
                        if output.enqueueCompletion(id) { completionAdmissions += 1 }
                    }
                }
                await capture.beginSession(captureAudio: false); guard let session = capture.sessionID else { throw Invalid.scope }
                let probe = StatusCorpusProbe(target: target.path, contents: contents); activeProbe = probe
                var reads = 0; var forbidden = 0
                conversation.rememberExplicit = { _ in }; conversation.prewarmObserverForTesting = {}
                conversation.workerForTesting = nil; conversation.workerProviderForTesting = StatusCorpusProvider(probe: probe)
                conversation.streamForTesting = { _, messages in await probe.frontend(messages) }
                AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                    guard tool.id == "filesystem.read", arguments["path"] == target.path,
                          target.path == target.resolvingSymlinksInPath().standardizedFileURL.path else {
                        forbidden += 1; throw Invalid.unsafe
                    }
                    reads += 1; return try FilesystemExecutor.run(tool, arguments: arguments)
                }
                let noTask = mode.hasPrefix("no-task") || mode == "typed-none"
                let count = noTask ? 0 : (mode == "multi" ? 3 : (mode.hasPrefix("cancel-two") || mode == "typed-one" ? 2 : 1))
                var authorityLandmarks: [(String, ContinuousClock.Instant)] = []
                var writerCloseReturns: [ContinuousClock.Instant] = []
                let sqlProfile = VoiceReceiptSQLProfileForTesting()
                let probeProfile = VoiceReceiptSQLProfileForTesting()
                var existingOpens = 0
                let priorAuthorityBoundary = sql.authorityBoundaryForTesting
                let priorMigrationBoundary = store.migrationBoundaryForTesting
                if mode == "receipt-budget" {
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
                    store.migrationBoundaryForTesting = { name in
                        if name == "beforePrimaryCommit" || name == "primaryCommitted" {
                            authorityLandmarks.append((name, ContinuousClock.now))
                        }
                        try priorMigrationBoundary?(name)
                    }
                }
                defer {
                    sql.authorityBoundaryForTesting = priorAuthorityBoundary
                    store.migrationBoundaryForTesting = priorMigrationBoundary
                }
                for index in 0..<count {
                    safeCleanup = false
                    let request = "Inspect owned status document \(index + 1)."
                    let started = ContinuousClock.now
                    let acknowledgment: String
                    if mode == "receipt-budget" {
                        let origin = TaskOrigin.voice(sessionID: session, turn: VoiceSession.shared.beginTurnIfNeeded())
                        let receipt = conversation.spawn(objective: request, userWords: request, origin: origin)
                        let receiptEnded = ContinuousClock.now
                        let receiptElapsed = started.duration(to: receiptEnded)
                        sql.authorityBoundaryForTesting = priorAuthorityBoundary
                        store.migrationBoundaryForTesting = priorMigrationBoundary
                        let expectedAuthorityStages = ["beforeExistingOpen", "existingOpened", "probeMarkerRead", "beforePrimaryCommit", "beforeExistingOpen", "existingOpened", "beforeAuthorityCommit", "primaryCommitted"]
                        let authorityQualified = authorityLandmarks.map { $0.0 } == expectedAuthorityStages
                            && authorityLandmarks.allSatisfy { $0.1 >= started && $0.1 <= receiptEnded }
                            && zip(authorityLandmarks, authorityLandmarks.dropFirst()).allSatisfy { $0.0.1 <= $0.1.1 }
                        print("VOICE_RECEIPT_AUTHORITY_STAGES fixture=F09 qualified=\(authorityQualified) count=\(authorityLandmarks.count)")
                        if authorityQualified {
                            let labels = ["probeOpen", "readProbeBody", "probeReturnWitnessPreflight", "writePreparation", "writeOpen", "writeBody", "commitPostcheckClose"]
                            var measured: [(String, Duration)] = [("beforeProbe", started.duration(to: authorityLandmarks[0].1))]
                            for index in labels.indices { measured.append((labels[index], authorityLandmarks[index].1.duration(to: authorityLandmarks[index + 1].1))) }
                            measured.append(("exportAndPublicDispatch", authorityLandmarks[7].1.duration(to: receiptEnded)))
                            for (stage, duration) in measured {
                                let parts = duration.components
                                let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
                                print("VOICE_RECEIPT_AUTHORITY_STAGE fixture=F09 stage=\(stage) ms=\(ms)")
                            }
                        }
                        sqlProfile.report(fixture: "F09", started: started, ended: receiptEnded, authorityLandmarks: authorityLandmarks, authorityQualified: authorityQualified, writerCloseReturns: writerCloseReturns)
                        let readProbe = probeProfile.snapshot()
                        let probeQualified = authorityQualified && readProbe.installs == 1 && readProbe.closeCount == 1
                            && readProbe.problems == 0 && readProbe.counts[2] == 0 && readProbe.counts[3] == 1
                            && readProbe.counts[4] == 0 && !readProbe.currentVersions.isEmpty
                            && readProbe.currentVersions.allSatisfy { $0 == TaskStoreSchema.version }
                        print("VOICE_RECEIPT_PROBE_VERSION fixture=F09 qualified=\(probeQualified) reads=\(readProbe.currentVersions.count) installs=\(readProbe.installs) closes=\(readProbe.closeCount) problems=\(readProbe.problems)")
                        check(probeQualified, "PROBE_F09 actual existing read transaction observation did not qualify")
                        check(probeQualified && readProbe.currentVersions.count == 1, "PROBE_F09 actual authority probe repeated the validated schema version read")
                        let writerSchema = sqlProfile.snapshot()
                        check(authorityQualified && writerSchema.installs == 1 && writerSchema.closeCount == 1
                            && writerSchema.problems == 0 && writerSchema.counts[2] == 1
                            && writerSchema.counts[3] == 1 && writerSchema.counts[4] == 0
                            && writerSchema.currentVersions == [TaskStoreSchema.version],
                            "SCHEMA_F09 actual writer repeated schema version validation in one transaction")
                        acknowledgment = receipt.spokenAcknowledgment
                        check(receipt.status == .accepted && receipt.id != nil && receiptElapsed <= .milliseconds(5),
                              "F09 actual fresh public receipt exceeded 5ms or was refused")
                    } else { acknowledgment = await input(request).reply }
                    let elapsed = started.duration(to: .now)
                    retainCurrentWorkers()
                    guard acknowledgment == "I'm on it.", await reached({ await probe.heldCount == index + 1 }) else { throw Invalid.worker }
                    print("STATUS_CORPUS_INTAKE mode=\(mode) index=\(index) elapsed=\(elapsed)")
                }
                guard captures.map({ $0.id.uuidString }) == manager.tasks.reversed().map(\.id) else { throw Invalid.worker }
                let sameSecond = count > 1 && manager.tasks.first?.createdAt == manager.tasks.last?.createdAt
                print("STATUS_CORPUS_ORDER mode=\(mode) count=\(count) sameSavedDate=\(sameSecond) admissionOrder=true")
                check(tasks.count == count && manager.tasks.count == count && reads == 0 && forbidden == 0,
                      "C01 genuine isolated admitted held workers did not qualify (\(mode))")
                // Empty-task inputs have no planner turn and therefore no published reader.
                if count > 0 {
                    guard let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.grammar }
                    let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: "Inspect owned status document 1.", previousRequest: nil)
                    let call = try probe.call()
                    guard manifest.allowedIDs.contains("filesystem.read"), LlamaGrammarPlanner.grammar(for: manifest).matches(call),
                          AgentToolCallParser.parse(call, knownNames: RealtimeAgent.callNames(manifest)).calls.count == 1 else { throw Invalid.grammar }
                }
                check(forbidden == 0, "C02 actual permitted read grammar changed (\(mode))")
                if mode == "completed" || mode == "consume-refused" {
                    await probe.releaseAll(); for task in tasks { await task.value }
                    let completedRow = manager.tasks.first
                    print("STATUS_CORPUS_COMPLETION mode=\(mode) status=\(completedRow?.status.rawValue ?? "unknown") delivery=\(completedRow?.delivery?.rawValue ?? "absent") callbacks=\(completedCallbacks) admissions=\(completionAdmissions) reads=\(reads) joined=\(tasks.count)")
                    guard manager.tasks.first?.status == .completed, manager.tasks.first?.delivery == .pending, reads == 1,
                          completedCallbacks == 1, completionAdmissions == 1 else { throw Invalid.worker }
                    if mode == "consume-refused" {
                        try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_status_consumption BEFORE UPDATE ON task WHEN NEW.delivery='consumedByStatus' BEGIN SELECT RAISE(ABORT,'owned status refusal'); END") }
                    }
                }
                let before = try sql.load(); let bytes = try Data(contentsOf: file)
                let frontendBefore = await probe.frontendCalls
                let ask: String
                if mode.hasPrefix("status-") { ask = signatures[Int(mode.dropFirst("status-".count))!] }
                else if mode.hasPrefix("cancel-") { ask = cancels[Int(mode.suffix(1))!] }
                else if mode == "typed-all" { await probe.setControl("<status/>"); ask = "Tell me the current work situation." }
                else if mode == "typed-one" { await probe.setControl("<status id=\"2\"/>"); ask = "Tell me about the second work item." }
                else if mode == "typed-none" { await probe.setControl("<status/>"); ask = "Tell me the current work situation." }
                else if mode == "ambiguous" { ask = "Cancel the email one." }
                else if mode == "no-task-cancel" { ask = "Cancel it." }
                else { ask = "Is it done?" }
                let queryStart = ContinuousClock.now; let answer = await input(ask); let answerElapsed = queryStart.duration(to: .now)
                let frontendAfter = await probe.frontendCalls
                if mode.hasPrefix("cancel-") {
                    guard let newest = captures.last, let selectedTask = tasks.last else { throw Invalid.worker }
                    check(selectedTask.isCancelled && manager.task(id: newest.id.uuidString)?.status == .cancelled,
                          "F02 exact cancel did not stop newest same task/primary (\(mode))")
                    check(answer.reply.contains(TaskStatusRenderer.title(newest.work.original)) && answer.reply.hasPrefix("Stopping ")
                        && frontendAfter == frontendBefore, "F03 named pending-return cancel did not avoid model (\(mode))")
                    if count == 2 {
                        check(tasks[0].isCancelled == false && manager.task(id: captures[0].id.uuidString)?.status == .running
                            && answer.reply.contains("is still going"), "F04 newest cancel stopped or hid older task (\(mode))")
                    }
                } else if noTask || mode == "ambiguous" {
                    check(frontendAfter == frontendBefore + 1 && (mode != "typed-none" || answer.reply == "Nothing is running right now."),
                          mode == "typed-none" ? "F05 typed empty status did not reach canonical consumer" : "C03 empty/ambiguous request was subtracted (\(mode))")
                    check(try sql.load() == before && Data(contentsOf: file) == bytes,
                          "C04 empty/ambiguous request changed ledger (\(mode))")
                } else if mode == "consume-refused" {
                    check(try sql.load() == before && Data(contentsOf: file) == bytes && manager.lastPersistenceResult == .sqlFailed,
                          "F14 refused completion consumption lost pending primary/export or did not attempt primary")
                    check(!answer.reply.contains("is done:"), "F06 refused status consumption delivered successful result")
                } else {
                    let title = TaskStatusRenderer.title(captures.first?.work.original ?? "")
                    let deterministic = mode != "typed-all" && mode != "typed-one"
                    check(answer.reply.contains(title) || (mode == "typed-one" && answer.reply.contains("document 2")),
                          "F01 canonical status omitted owned title (\(mode))")
                    check(frontendAfter == frontendBefore + (deterministic ? 0 : 1) && !answer.delegated,
                          "F07 status made inference/new work instead of cached consumer (\(mode))")
                    if deterministic { check(answerElapsed <= .milliseconds(50), "F08 actual status exceeded 50ms (\(mode))") }
                    if mode == "multi" { check(answer.reply.contains("Also,") && answer.reply.contains("1 more"), "F10 multi-task report lost bounded other work") }
                    if mode == "completed" {
                        check(manager.tasks.first?.delivery == .consumedByStatus && answer.reply.contains("is done:"), "F11 completed status did not consume SAME pending result")
                    } else { check(try sql.load() == before && Data(contentsOf: file) == bytes, "C06 running status mutated primary/export (\(mode))") }
                    if mode == "repeat" {
                        let beforeRepeat = await probe.frontendCalls; _ = await input(ask)
                        check(await probe.frontendCalls == beforeRepeat + 1, "F12 repeated exact status within5s did not reach model")
                    }
                }
                await probe.releaseAll(); for task in tasks { await task.value }
                let expectedReads = mode.hasPrefix("cancel-") ? count - 1 : count
                check(reads == expectedReads && forbidden == 0, (mode.hasPrefix("cancel-") ? "F13" : "C07") + " same tasks did not drain exact confined backing (\(mode))")
                print("TASK_STATUS_CORPUS_CASE mode=\(mode) checks=\(checks-startChecks) rows=\(manager.tasks.count) reads=\(reads) frontends=\(frontendAfter-frontendBefore) elapsed=\(answerElapsed)")
                for observed in captures { _ = conversation.cancel(observed.id) }
                for task in tasks { await task.value }; tasks=[]; captures=[]; activeProbe=nil; safeCleanup=true
                manager.completionDeliveryForTesting = nil
                await capture.endSession(source: .done); conversation.resetForTesting()
            }
            for phrase in ["Stop.", "stop it", "cancel my three pm meeting", "cancel the email one", "Cancel it and read a file.", "Wait."] {
                check(!VoiceTurnPolicy.isExplicitWorkCancellation(phrase), "C08 ambiguous cancellation stolen: \(phrase)")
            }
            for text in ["<status id=\"0\"/>", "<status id=\"-1\"/>", "<status id=\"1\"/>tail", "<status extra=\"1\"/>"] {
                check(VoiceFrontendEnvelope.parse(text) == .invalid, "C09 malformed status admitted")
            }
            check(VoiceTurnPolicy.normalizedKey("How's it going?") == "how s it going", "C10 exact apostrophe normalization changed")
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C11 owner state changed")
        } catch {
            failures.append("status corpus: INVALID \(error)")
            retainCurrentWorkers()
            for observed in captures { _ = conversation.cancel(observed.id) }
            await activeProbe?.releaseAll()
            for task in tasks { await task.value }
            contextManager?.completionDeliveryForTesting = nil
            safeCleanup = contextManager?.tasks.allSatisfy { row in
                captures.contains(where: { $0.id.uuidString == row.id && $0.task != nil })
                    || [.completed, .failed].contains(row.status)
            } ?? true
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }

    /// Existing producer selector controls; ambiguous real intake is in unchanged285.
    static func runToolShapeAdmission() -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle" else {
            return (0, ["status tool shape: INVALID scope"])
        }
        let cases: [(String, Set<String>, String?)] = [
            ("Email Marcus the notes.", ["send_email"], "send_email"),
            ("Please email Marcus the notes.", ["send_email"], "send_email"),
            ("Could you email Marcus the notes?", ["send_email"], "send_email"),
            ("Send an email to Marcus.", ["send_email"], "send_email"),
            ("Forward the email to Marcus.", ["send_email"], "send_email"),
            ("Reply to the email.", ["send_email"], "send_email"),
            ("Find the pricing document and email it to Marcus.", ["send_email"], "send_email"),
            ("Find the file then please email it to Marcus.", ["send_email"], "send_email"),
            ("Read my email.", ["search_email", "send_email"], "search_email"),
            ("Check my inbox.", ["search_email", "send_email"], "search_email"),
            ("Cancel the email one.", ["send_email", "create_event"], nil),
            ("Cancel my three pm meeting.", ["send_email", "create_event"], nil),
            ("What about the email one?", ["send_email"], nil),
            ("Do not email Marcus.", ["send_email"], nil),
            ("What's the email status?", ["send_email"], nil),
            ("Stop the email one.", ["send_email"], nil),
            ("Email Marcus the notes.", [], nil),
        ]
        var failures: [String] = []
        for (index, test) in cases.enumerated() {
            let actual = AgentDirectIntent.toolShapeMatch(in: AgentDirectIntent.normalize(test.0), allowedIDs: test.1)
            if actual != test.2 {
                failures.append("status tool shape: " + (test.2 == nil ? "F18" : "C01") + " standalone verb admission (case\(index))")
            }
        }
        return (cases.count, failures)
    }

    /// Mixed real owners: two still running, one completed but outside spoken prefix.
    static func runMixedConsumption() async -> (checks: Int, failures: [String]) {
        let conversation = VoiceConversationCoordinator.shared; let capture = AgentCaptureController.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive, !conversation.hasActiveWork,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            return (0, ["status mixed: INVALID scope"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["status mixed: INVALID root"]) }
        let priorBridge = conversation.taskBridgeOverrideForTesting; let oldRemember = conversation.rememberExplicit
        let oldFake = AgentToolExecutor.fakeForTesting; let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting; let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting; let oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let owner = SelfTestStoreGuard.take()
        var manager: AgentTaskManager?; var probe: StatusCorpusProbe?
        var captures: [VoiceWorkerTestCapture] = []; var tasks: [Task<Void, Never>] = []
        var created = false; var safeCleanup = true; var contextInstalled = false
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("status mixed: " + label) } }
        func retainCurrentWorkers() {
            guard let manager else { return }
            for row in manager.tasks.reversed() {
                guard let id = UUID(uuidString: row.id), !captures.contains(where: { $0.id == id }),
                      let observed = conversation.captureVoiceWorkerForTesting(id: id) else { continue }
                captures.append(observed); if let task = observed.task { tasks.append(task) }
            }
        }
        func input(_ text: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(text, source: .voice)
        }
        defer {
            manager?.completionDeliveryForTesting = nil
            if contextInstalled { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            conversation.resetForTesting(); _ = conversation.installTaskBridgeForTesting(priorBridge)
            conversation.rememberExplicit = oldRemember
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy; AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole; ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            if created && safeCleanup { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                guard meeting == nil, let task, manager?.task(id: task) != nil else { return nil }
                return ToolCallContext()
            }, root: root) else { throw Invalid.unsafe }; contextInstalled = true
            let target = root.appendingPathComponent("owned.txt"); let contents = "Owned mixed status bytes " + UUID().uuidString
            try Data(contents.utf8).write(to: target)
            let sql = TaskStore(root: root); defer { sql.close() }
            let file = root.appendingPathComponent("agent-tasks.json"); let store = AgentTaskStore(fileURL: file, mirror: sql)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
            let current = AgentTaskManager(store: store); manager = current; let bridge = TaskBridge(manager: current)
            guard let output = OutputScheduler.isolatedForTesting(bridge) else { throw Invalid.scope }
            var callbacks = 0; var admissions = 0; var reads = 0; var forbidden = 0
            current.completionDeliveryForTesting = { id in callbacks += 1; if output.enqueueCompletion(id) { admissions += 1 } }
            conversation.resetForTesting(); AgentSession.shared.forgetAllConversations()
            guard conversation.installTaskBridgeForTesting(bridge) else { throw Invalid.scope }
            await capture.beginSession(captureAudio: false); guard let session = capture.sessionID else { throw Invalid.scope }
            let held = StatusCorpusProbe(target: target.path, contents: contents); probe = held
            conversation.rememberExplicit = { _ in }; conversation.prewarmObserverForTesting = {}
            conversation.workerForTesting = nil; conversation.workerProviderForTesting = StatusCorpusProvider(probe: held)
            conversation.streamForTesting = { _, messages in await held.frontend(messages) }
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .selfTest
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments["path"] == target.path,
                      target.path == target.resolvingSymlinksInPath().standardizedFileURL.path else {
                    forbidden += 1; throw Invalid.unsafe
                }
                reads += 1; return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            for index in 0..<3 {
                safeCleanup = false
                let answer = await input("Inspect owned status document \(index + 1).")
                retainCurrentWorkers()
                guard answer.reply == "I'm on it.", await reached({ await held.heldCount == index + 1 }) else { throw Invalid.worker }
            }
            guard captures.count == 3, tasks.count == 3,
                  captures.map({ $0.id.uuidString }) == current.tasks.reversed().map(\.id),
                  let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.worker }
            let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: "Inspect owned status document 3.", previousRequest: nil)
            let call = try held.call()
            guard manifest.allowedIDs.contains("filesystem.read"), LlamaGrammarPlanner.grammar(for: manifest).matches(call),
                  AgentToolCallParser.parse(call, knownNames: RealtimeAgent.callNames(manifest)).calls.count == 1 else { throw Invalid.grammar }
            guard await held.release(index: 2) else { throw Invalid.worker }
            await tasks[2].value
            let third = TaskID(captures[2].id)
            let indexed = bridge.indexedSessionTasks(session)
            guard indexed.count == 3, indexed[2].id == third,
                  current.task(id: third.raw)?.status == .completed, current.task(id: third.raw)?.delivery == .pending,
                  callbacks == 1, admissions == 1, reads == 1, output.pendingCount == 1 else { throw Invalid.worker }
            check(!tasks[0].isCancelled && !tasks[1].isCancelled && forbidden == 0,
                  "C01 actual mixed owners/backing did not qualify")
            check(indexed.prefix(2).allSatisfy({ $0.status == .running }) && indexed[2].status == .completed,
                  "C02 actual unseen completed result not outside spoken prefix")
            let before = try sql.load(); let bytes = try Data(contentsOf: file)
            let oldFrontend = await held.frontendCalls
            let answer = await input("How's it going?")
            let afterFrontend = await held.frontendCalls
            check(answer.reply.contains("document 1") && answer.reply.contains("document 2")
                && answer.reply.contains("1 more") && afterFrontend == oldFrontend,
                "F16 mixed status did not use exact represented active tasks")
            check(!answer.reply.contains("document 3") && !answer.reply.contains("authored fixture data"),
                  "C03 mixed status delivered excluded result")
            check(try sql.load() == before && Data(contentsOf: file) == bytes
                && current.task(id: third.raw)?.delivery == .pending && output.pendingCount == 1,
                "F17 unheard completion lost pending primary/opportunity")
            print("STATUS_CORPUS_MIXED running=2 completed=1 represented=2 callback=\(callbacks) admitted=\(admissions) reads=\(reads) excludedPending=\(current.task(id: third.raw)?.delivery == .pending)")
            await held.releaseAll(); for task in tasks { await task.value }
            check(reads == 3 && forbidden == 0 && callbacks == 3 && admissions == 3,
                  "C04 mixed same tasks did not drain actual read/completion consumers")
            current.completionDeliveryForTesting = nil; safeCleanup = true
            await capture.endSession(source: .done); conversation.resetForTesting()
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C05 owner state changed")
        } catch {
            failures.append("status mixed: INVALID \(error)")
            retainCurrentWorkers(); for observed in captures { _ = conversation.cancel(observed.id) }
            await probe?.releaseAll(); for task in tasks { await task.value }
            manager?.completionDeliveryForTesting = nil
            safeCleanup = manager?.tasks.allSatisfy { row in
                captures.contains(where: { $0.id.uuidString == row.id && $0.task != nil }) || [.completed, .failed].contains(row.status)
            } ?? true
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
}

private actor StatusCorpusProbe {
    let target: String; let contents: String
    private var held: [CheckedContinuation<Void, Never>] = []
    private var releaseFuture = false; private var control: String?
    private(set) var frontendCalls = 0
    var heldCount: Int { held.count }
    init(target: String, contents: String) { self.target=target; self.contents=contents }
    func setControl(_ value: String) { control=value }
    func frontend(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        frontendCalls += 1
        let latest = messages.last?.content.components(separatedBy: "Latest user speech:\n").last ?? ""
        let body = latest.hasPrefix("Inspect owned status document ") ? "<use_tools/>" : (control ?? "<answer/>A haiku is a short poem.")
        control=nil
        return AsyncThrowingStream { $0.yield(body); $0.finish() }
    }
    func release(index: Int) -> Bool {
        guard held.indices.contains(index) else { return false }
        held.remove(at: index).resume(); return true
    }
    func releaseAll() { releaseFuture=true; let current=held; held=[]; for value in current { value.resume() } }
    nonisolated func call() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["path":target], options:[.sortedKeys])
        return "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":" + String(decoding:data,as:UTF8.self)
            + ",\"rationale\":\"Read the owned fixture file.\"}</tool_call>"
    }
    func complete(user: String) async throws -> String {
        if user.contains(contents) { return "The owned document is ready. It contains the authored fixture data." }
        if !releaseFuture { await withCheckedContinuation { held.append($0) } }
        return try call()
    }
}
private struct StatusCorpusProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: StatusCorpusProbe
    var contextTokens: Int { 8192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text:String) async throws -> Int { text.count / 4 }
    func complete(system:String,user:String,maxTokens:Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user:user)
        return LLMCompletion(text:text,generatedTokens:text.count,duration:0)
    }
}
