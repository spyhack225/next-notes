import Foundation

/// Real Coordinator.handle intake and same Manager SQL; only model/worker bodies are
/// held scripted existing seams. No hardware, synthesized receipt or private dispatch.
@MainActor
enum TaskRecordStatusSelfTest {
    private enum FixtureError: Error { case unsafe, missingActualWorker, missingSession }
    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
    private static func canonical(_ tasks: [AgentTask]) throws -> [AgentTask] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentTask].self, from: encoder.encode(tasks))
    }
    static func run() async -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, PermissionGate.shared.pending == nil,
              !AgentCaptureController.shared.isSessionActive else {
            return (0, ["task record: INVALID isolated lifecycle required"])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesTaskRecords-" + UUID().uuidString, isDirectory: true)
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard safe.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else {
            return (0, ["task record: INVALID unsafe root"])
        }
        let owner = SelfTestStoreGuard.take()
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("task record: " + label) }
        }
        let capture = AgentCaptureController.shared
        let conversation = VoiceConversationCoordinator.shared
        let priorBridge = conversation.taskBridgeOverrideForTesting
        conversation.resetForTesting()
        func input(_ words: String) async -> AgentTurn {
            let agent = RealtimeAgent.shared
            agent.userSpeechStarted()
            agent.userSpeechEnded()
            return await agent.handle(words, source: .voice)
        }
        var release: CheckedContinuation<String, Never>?
        var workerTask: Task<Void, Never>?
        var ownedWorkerID: UUID?
        defer {
            _ = conversation.installTaskBridgeForTesting(priorBridge)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let sql = TaskStore(root: root); defer { sql.close() }
            let file = root.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: file, mirror: sql)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw FixtureError.unsafe }
            let receipts = ActionReceiptStore(fileURL: root.appendingPathComponent("action-receipts.json"))
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let bridge = TaskBridge(manager: manager)
            guard conversation.installTaskBridgeForTesting(bridge) else { throw FixtureError.unsafe }
            let requests = (1...7).map { "Open Safari for owned task \($0)." }
            let frontend = TaskRecordFrontendProbe(requests: requests)
            conversation.rememberExplicit = { _ in }
            conversation.streamForTesting = { _, messages in await frontend.stream(messages) }
            conversation.prewarmObserverForTesting = { }
            var entered = 0; var ended = 0
            conversation.workerForTesting = { _ in
                entered += 1
                let value = await withCheckedContinuation { release = $0 }
                ended += 1
                return value
            }
            manager.announcementForTesting = { _ in }
            await capture.beginSession(captureAudio: false)
            guard let sessionA = capture.sessionID else { throw FixtureError.missingSession }
            var taskIDs: [String] = []
            let newestResult = String(repeating: "Owned complete sentence. ", count: 35)
                + "The later retained detail is present. " + String(repeating: "Owned remaining sentence. ", count: 35)
            for (index, words) in requests.prefix(6).enumerated() {
                let response = await input(words)
                await Task.yield()
                print("TASK_RECORD_INTAKE mode=voice index=\(index) replyOnIt=\(response.reply == "I'm on it.") jobs=\(conversation.taskBridge.cachedTasks.filter { $0.source == "voice" }.count) entered=\(entered) ended=\(ended)")
                guard await reached({ release != nil }), let rawID = bridge.cachedTasks.first(where: { $0.source == "voice" && $0.userWords == words })?.id,
                      let workerID = UUID(uuidString: rawID),
                      let job = conversation.captureVoiceWorkerForTesting(id: workerID),
                      let task = job.task else { throw FixtureError.missingActualWorker }
                workerTask = task; ownedWorkerID = job.id; taskIDs.append(job.id.uuidString)
                check(response.reply == "I'm on it." && entered == index + 1 && ended == index,
                    "C01 actual intake/held worker did not qualify (\(index))")
                let admitted = try sql.load().first { $0.id == job.id.uuidString }
                check(admitted?.userWords == words && admitted?.objective == job.work.prompt,
                    "F01 intake lost exact original words or objective (\(index))")
                let ownedSession: UUID? = if case .voice(let session, _)? = admitted?.origin { session } else { nil }
                check(ownedSession == sessionA && admitted?.startedAt != nil && admitted?.finishedAt == nil,
                    "F02 actual admitted voice origin/start unavailable (\(index))")
                let originalRow = bridge.record(TaskID(job.id))
                let projected = bridge.taskRecord(TaskID(job.id))
                check(projected?.id.raw == originalRow?.id && projected?.status == originalRow?.status,
                    "C02 value projection replaced cached canonical row (\(index))")
                release?.resume(returning: index == 5 ? newestResult : "Owned prior result \(index).")
                release = nil
                await task.value; workerTask = nil
                let terminal = try sql.load().first { $0.id == job.id.uuidString }
                check(terminal?.status == .completed && terminal?.finishedAt != nil
                    && terminal?.startedAt != nil && terminal?.origin == admitted?.origin
                    && terminal?.userWords == words,
                    "F03 completion lost same admitted ownership/terminal time (\(index))")
            }
            let retained = try sql.load()
            let canonicalRows = try canonical(manager.tasks)
            check(retained == canonicalRows && entered == 6 && ended == 6,
                "C03 actual SQL/export domain or SAME worker joins changed")
            guard let actualTerminal = manager.task(id: taskIDs[5]), actualTerminal.status == .completed else {
                throw FixtureError.missingActualWorker
            }
            let terminalRecord = TaskRecord(actualTerminal)
            let displayedAt = Date()
            let completedNow = TaskStatusRenderer.workLines([terminalRecord], now: displayedAt)
            let completedLater = TaskStatusRenderer.workLines([terminalRecord], now: displayedAt.addingTimeInterval(600))
            check(completedNow == completedLater && !completedNow.contains("minutes in")
                && !completedNow.contains("just started"),
                "C16 real completed row elapsed changed with observation clock")
            // A value-only missing-field boundary over that SAME actual terminal row;
            // no stored outcome or backing changes, and no inferred finish time.
            var unknownFinish = actualTerminal
            unknownFinish.finishedAt = nil
            let unknownDuration = TaskStatusRenderer.workLines([TaskRecord(unknownFinish)], now: displayedAt.addingTimeInterval(600))
            check(!unknownDuration.contains("took ") && !unknownDuration.contains("minutes in")
                && !unknownDuration.contains("just started"),
                "C17 unknown terminal finish invented elapsed duration")
            let sessionRows = bridge.indexedSessionTasks(sessionA)
            check(sessionRows.count == 5 && sessionRows.map { $0.id.raw } == Array(taskIDs.suffix(5).reversed()),
                "F04 newest five session terminal rows/index order unavailable")
            let lines = bridge.workStatusLines(sessionID: sessionA)
            check(lines.contains("The later retained detail is present.") && lines.count <= 2_500,
                "F05 latest result lost post600 detail or exceeded frontend envelope")
            let result = lines.components(separatedBy: "\nResult: ").dropFirst().first?.components(separatedBy: "\n").first ?? ""
            check(!result.isEmpty && result.count <= 1_200 && !result.contains("…") && result.hasSuffix("."),
                "F06 actual newest result did not end at complete sentence within1200")
            check(lines.split(separator: "\n").filter { !$0.hasPrefix("Result: ") }.allSatisfy { $0.count <= 250 }
                && sessionRows.allSatisfy { $0.title.count <= 60 },
                "C04 current frontend row/title budgets exceeded")
            _ = await input("What is a haiku?")
            let actualA = await frontend.lastPackage
            check(!lines.isEmpty && actualA.contains(lines) && actualA.hasSuffix("Latest user speech:\nWhat is a haiku?"),
                "F07 actual frontend consumer missed SAME cached indexed status")
            check(!taskIDs.contains(where: { actualA.contains($0) }),
                "C05 frontend exposed internal task identity")
            check(bridge.indexedSessionTasks(UUID()).isEmpty && bridge.indexedSessionTasks(nil).isEmpty,
                "C06 missing/wrong session acquired cached task rows")
            check(bridge.indexedSessionTasks(sessionA, now: Date().addingTimeInterval(601)).isEmpty,
                "C07 stale terminal rows remained in current frontend context")

            // Open a genuine next capture session. No manufactured session id or row.
            await capture.endSession(source: .done)
            await capture.beginSession(captureAudio: false)
            guard let sessionB = capture.sessionID, sessionB != sessionA else { throw FixtureError.missingSession }
            _ = await input(requests[6])
            guard await reached({ release != nil }), let rawID = bridge.cachedTasks.first(where: { $0.source == "voice" && $0.userWords == requests[6] })?.id,
                  let workerID = UUID(uuidString: rawID),
                  let second = conversation.captureVoiceWorkerForTesting(id: workerID),
                  let task = second.task else { throw FixtureError.missingActualWorker }
            workerTask = task; ownedWorkerID = second.id
            check(entered == 7 && ended == 6 && taskIDs.allSatisfy { $0 != second.id.uuidString },
                "C08 real successor session/current worker did not qualify")
            let currentRows = bridge.indexedSessionTasks(sessionB)
            check(currentRows.count == 1 && currentRows.first?.id == TaskID(second.id),
                "F08 current session acquired prior session rows or missed its live row")
            _ = await input("What is a haiku?")
            let actualB = await frontend.lastPackage
            check(actualB.contains("Task 1 [Working]") && !actualB.contains("Owned prior result")
                && !actualB.contains("The later retained detail is present.")
                && !actualB.contains("Task 2 ["),
                "F09 actual frontend context leaked prior-session work")
            let beforeProjectionRows = try sql.load(); let beforeProjectionExport = try Data(contentsOf: file)
            let beforeEvents = try sql.journal(taskID: second.id.uuidString)
            for _ in 0..<8 {
                _ = bridge.taskRecord(TaskID(second.id)); _ = bridge.indexedSessionTasks(sessionB)
                _ = bridge.workStatusLines(sessionID: sessionB)
            }
            let afterProjectionRows = try sql.load(); let afterProjectionExport = try Data(contentsOf: file)
            let afterEvents = try sql.journal(taskID: second.id.uuidString)
            check(beforeProjectionRows == afterProjectionRows && beforeProjectionExport == afterProjectionExport
                && beforeEvents == afterEvents && entered == 7 && ended == 6,
                "C09 cached projection mutated store/journal or started another worker")
            release?.resume(returning: "Owned successor result."); release = nil
            await task.value; workerTask = nil

            // Actual canonical legacy bytes omit each new key. No inferred origin/times.
            let old = AgentTask(objective: "Owned legacy row", source: "voice", status: .completed)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard var object = try JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any] else { throw FixtureError.unsafe }
            for name in ["origin", "userWords", "startedAt", "finishedAt"] { object.removeValue(forKey: name) }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let legacy = try decoder.decode(AgentTask.self, from: JSONSerialization.data(withJSONObject: object))
            check(legacy.origin == nil && legacy.userWords == nil && legacy.startedAt == nil && legacy.finishedAt == nil,
                "C10 legacy missing codec metadata acquired inferred ownership")
            let integrity = try sql.integrityProblems()
            check(TaskStatusRenderer.workLines([]).isEmpty && integrity.isEmpty && entered == 7 && ended == 7,
                "C11 empty projection, actual store integrity or worker joins changed")
            await capture.endSession(source: .done)
            // The outer lifecycle intentionally substitutes unrelated tool backings.
            // This real owned read must exercise Executor/Runtime/receipt production.
            let priorFake = AgentToolExecutor.fakeForTesting
            let priorFire = AgentToolExecutor.fireOverrideForTesting
            let priorPolicy = AgentToolExecutor.policyOverrideForTesting
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.fireOverrideForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            defer {
                AgentToolExecutor.fakeForTesting = priorFake
                AgentToolExecutor.fireOverrideForTesting = priorFire
                AgentToolExecutor.policyOverrideForTesting = priorPolicy
            }
            var typedEnded = 0
            manager.backendExitForTesting = { typedEnded += 1 }
            let ownedFile = root.appendingPathComponent("owned-reader.txt")
            try "Owned reader content.".write(to: ownedFile, atomically: true, encoding: .utf8)
            let typedWords = "Read the owned reader file."
            let typed = manager.submit(objective: typedWords, tool: "filesystem.read",
                arguments: ["path": ownedFile.path], source: "text", origin: .typed, userWords: typedWords)
            let typedReturned = await reached({ typedEnded == 1 })
            let observedTyped = manager.task(id: typed.id)
            print("TASK_RECORD_TYPED_ADMISSION returned=\(typedReturned) backendEnded=\(typedEnded) state=\(observedTyped?.status.rawValue ?? "missing") pendingInputs=\(manager.pendingInputs.count) gatePending=\(PermissionGate.shared.pending != nil) primaryResult=\(manager.lastPersistenceResult) attempt=\(observedTyped?.durability?.attempt ?? -1) resultMatches=\(observedTyped?.result?.contains("Owned reader content.") == true)")
            guard typedReturned, let typedRow = observedTyped,
                  typedRow.status == .completed else { throw FixtureError.missingActualWorker }
            print("TASK_RECORD_TYPED_CONTROL completed=\(typedRow.status == .completed) resultMatches=\(typedRow.result?.contains("Owned reader content.") == true) attempt=\(typedRow.durability?.attempt ?? -1) receiptJoined=\(receipts.receipts.contains { $0.taskID == typed.id }) fakeNil=\(AgentToolExecutor.fakeForTesting == nil) fireNil=\(AgentToolExecutor.fireOverrideForTesting == nil)")
            check(typedRow.result?.contains("Owned reader content.") == true && typedRow.durability?.attempt == 1,
                "C13 actual typed local read/primary attempt did not qualify")
            check(typedRow.origin == .typed && typedRow.userWords == typedWords
                && typedRow.startedAt != nil && typedRow.finishedAt != nil,
                "F10 actual typed local producer omitted same-row metadata")
            check(bridge.indexedSessionTasks(sessionA).allSatisfy { $0.id.raw != typed.id }
                && bridge.indexedSessionTasks(sessionB).allSatisfy { $0.id.raw != typed.id },
                "C14 typed read acquired voice session membership")
            let typedSQL = try sql.load().first { $0.id == typed.id }
            let typedCanonical = try canonical([typedRow]).first
            check(typedSQL == typedCanonical && receipts.receipts.contains { $0.taskID == typed.id },
                "C15 typed SQL metadata/result/retained receipt join changed")
            conversation.resetForTesting()
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty,
                "C12 owner stores/defaults/grants changed")
            print("TASK_RECORD_STATUS_TRACE checks=\(checks) entered=\(entered) ended=\(ended) actualSessions=2 sessionASelected=\(sessionRows.count) sessionBSelected=\(currentRows.count) resultCharacters=\(result.count) contextCharacters=\(lines.count) typedEnded=\(typedEnded)")
        } catch {
            if let task = workerTask {
                if let id = ownedWorkerID { conversation.cancel(id) }
                release?.resume(returning: "Owned invalid cleanup."); release = nil
                await task.value
            }
            await capture.endSession(source: .done)
            conversation.resetForTesting()
            failures.append("task record: INVALID actual input/control: \(error)")
        }
        print("TASK_RECORD_STATUS_RESULT checks=\(checks) problems=\(failures.count)")
        return (checks, failures)
    }
}

private actor TaskRecordFrontendProbe {
    let requests: [String]
    private(set) var lastPackage = ""
    init(requests: [String]) { self.requests = requests }
    func stream(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        lastPackage = messages.last?.role == .user ? (messages.last?.content ?? "") : ""
        let work = requests.contains { lastPackage.hasSuffix("Latest user speech:\n" + $0) }
        return AsyncThrowingStream { continuation in
            continuation.yield(work ? "<use_tools/>" : "<answer/>A haiku is a short poem.")
            continuation.finish()
        }
    }
}
