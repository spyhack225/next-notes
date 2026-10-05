import Foundation
import SQLite3

/// Real voice intake -> retained worker -> planner/executor -> SAME canonical task.
/// Scripted provider and confined temporary file are the external fixture boundaries.
@MainActor
enum OutputSchedulerQuestionSelfTest {
    private enum FixtureError: Error { case unsafe, input, missingWorker, invalidCallShape, missingBacking }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }
    private static func command(_ sql: String, in file: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw FixtureError.unsafe }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.unsafe }
    }
    static func run(recorder: RecordingSpeechBacking) async -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              AgentSession.shared.fileURL == nil, PermissionGate.shared.pending == nil,
              !AgentCaptureController.shared.isSessionActive else {
            return (0, ["delivery question: INVALID isolated lifecycle required"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        guard root.standardizedFileURL.path == canonical.path,
              canonical.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else {
            return (0, ["delivery question: INVALID unsafe root"])
        }
        let conversation = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let agent = RealtimeAgent.shared
        let priorBridge = conversation.taskBridgeOverrideForTesting
        let oldRemember = conversation.rememberExplicit
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting
        let oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let playback = VoicePlaybackDelivery.shared
        let synth = AgentSpeechSynthesizer.shared
        let owner = SelfTestStoreGuard.take()
        var checks = 0; var failures: [String] = []
        var ownedTask: Task<Void, Never>?
        var probe: OutputQuestionProbe?
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("delivery question: " + label) }
        }
        func input(_ text: String) async -> AgentTurn {
            agent.userSpeechStarted(); agent.userSpeechEnded()
            return await agent.handle(text, source: .voice)
        }
        defer {
            _ = playback.installOutputForTesting(nil)
            conversation.resetForTesting()
            _ = conversation.installTaskBridgeForTesting(priorBridge)
            conversation.rememberExplicit = oldRemember
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole
            ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil
            ToolLoopLiveEval.needleFirstForTesting = false
            for mode in ["completed", "model-failed", "tool-failed", "question", "question-save-refused", "answer-save-refused", "question-cancel"] {
                let beforeChecks = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("owned.txt")
                try Data("The authored temporary file was read.".utf8).write(to: target)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw FixtureError.unsafe }
                let manager = AgentTaskManager(store: store)
                let bridge = TaskBridge(manager: manager)
                guard let output = OutputScheduler.isolatedForTesting(bridge), playback.installOutputForTesting(output) else { throw FixtureError.unsafe }
                output.setPhraseForTesting { _ in nil }
                let clock = Date()
                output.setNowForTesting(clock)
                var completionCallbacks = 0; var questionCallbacks = 0
                manager.completionDeliveryForTesting = { id in completionCallbacks += 1; _ = output.enqueueCompletion(id) }
                manager.questionDeliveryForTesting = { id in questionCallbacks += 1; _ = output.enqueueQuestion(id) }
                defer { manager.completionDeliveryForTesting = nil; manager.questionDeliveryForTesting = nil }
                conversation.resetForTesting()
                guard conversation.installTaskBridgeForTesting(bridge) else { throw FixtureError.unsafe }
                await capture.beginSession(captureAudio: false)
                guard let session = capture.sessionID else { throw FixtureError.input }
                let request = "Inspect the owned document for " + mode + "."
                let answer = "Use the fixture at " + target.path
                let state = OutputQuestionProbe(mode: mode, target: target.path, request: request, answer: answer)
                probe = state
                conversation.rememberExplicit = { _ in }
                conversation.prewarmObserverForTesting = {}
                conversation.workerForTesting = nil
                conversation.workerProviderForTesting = OutputQuestionProvider(probe: state)
                conversation.streamForTesting = { _, messages in await state.frontend(messages) }
                var backing = 0; var backingEntries = 0; var announcements: [String] = []
                manager.announcementForTesting = { announcements.append($0) }
                AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                    guard tool.id == "filesystem.read", arguments["path"] == target.path,
                          target.standardizedFileURL.path == target.resolvingSymlinksInPath().standardizedFileURL.path else {
                        throw FixtureError.unsafe
                    }
                    backingEntries += 1
                    if mode == "tool-failed" { throw AgentError.backendUnavailable("The owned fixture backend is unavailable.") }
                    backing += 1
                    return try FilesystemExecutor.run(tool, arguments: arguments)
                }
                if mode == "question-save-refused" {
                    try command("CREATE TRIGGER reject_voice_question BEFORE UPDATE ON task WHEN NEW.state='waitingForInput' BEGIN SELECT RAISE(ABORT,'fixture question refusal'); END;", in: directory.appendingPathComponent("agent-tasks.sqlite"))
                }
                let response = await input(request)
                guard let rawID = bridge.cachedTasks.first(where: { $0.source == "voice" })?.id,
                      let workerID = UUID(uuidString: rawID),
                      let job = conversation.captureVoiceWorkerForTesting(id: workerID), let task = job.task else { throw FixtureError.missingWorker }
                ownedTask = task // Retain before the first asynchronous qualification.
                let initial = await state.snapshot()
                print("VOICE_OUTCOME_INTAKE mode=\(mode) onIt=\(response.reply == "I'm on it.") jobs=\(conversation.taskBridge.cachedTasks.filter { $0.source == "voice" }.count) providerCalls=\(initial.calls) parked=\(initial.parked)")
                guard await reached({ await state.snapshot().parked }) else { throw FixtureError.missingWorker }
                finishAudio(synth, recorder)
                // Rebuild through the SAME production builder at the real held reader.
                // No setting/grammar/parser producer changes: only authored script shape.
                guard let reader = AgentCapabilityManifestRuntime.publishedReader else { throw FixtureError.invalidCallShape }
                let selected = AgentCapabilityManifestBuilder.build(.live(reader: reader),
                    request: job.work.original,
                    previousRequest: AgentSession.shared.recentUserTexts(limit: 2).dropLast().last)
                let grammar = LlamaGrammarPlanner.grammar(for: selected)
                let names = RealtimeAgent.callNames(selected)
                let correctedCall = try OutputQuestionProbe.call(target: target.path)
                let oldData = try JSONSerialization.data(withJSONObject: ["name": "read", "arguments": ["path": target.path]], options: [.sortedKeys])
                let oldCall = "<tool_call>" + String(decoding: oldData, as: UTF8.self) + "</tool_call>"
                let decoded = AgentToolCallParser.parse(correctedCall, knownNames: names)
                print("VOICE_OUTCOME_SHAPE mode=\(mode) readerWindow=\(reader.contextTokens) selectedRead=\(selected.selected.contains { $0.id == "filesystem.read" }) oldGrammarMatch=\(grammar.matches(oldCall)) correctedGrammarMatch=\(grammar.matches(correctedCall)) correctedParsedRead=\(decoded.calls.count == 1 && decoded.calls[0].name == "filesystem.read")")
                guard selected.selected.contains(where: { $0.id == "filesystem.read" }),
                      grammar.matches(correctedCall), decoded.calls.count == 1,
                      decoded.calls[0].name == "filesystem.read", decoded.calls[0].arguments == ["path": target.path] else {
                    throw FixtureError.invalidCallShape
                }
                var tracedRounds = 0; var tracedReads = 0; var matchedGrammar = 0; var rejectedCalls = 0
                job.worker.plannerTraceForTesting = { event in
                    switch event {
                    case .round(_, _, _, _, let raw, _):
                        tracedRounds += 1
                        if grammar.matches(raw) { matchedGrammar += 1 }
                        tracedReads += AgentToolCallParser.parse(raw, knownNames: names).calls.filter { $0.name == "filesystem.read" }.count
                    case .rejectedCall: rejectedCalls += 1
                    case .stopped: break
                    }
                }
                let originalSession: UUID? = if case .voice(let owned, _)? = bridge.record(TaskID(job.id))?.origin { owned } else { nil }
                check(response.reply == "I'm on it." && originalSession == session
                    && job.worker.isVoiceWorker && conversation.workerForTesting == nil,
                    "C01 real intake/session/production worker did not qualify (\(mode))")
                let start = try sql.load().first { $0.id == job.id.uuidString }
                check(start?.status == .running && start?.userWords == request && start?.pendingInteraction == nil,
                    "C02 real current canonical task did not start (\(mode))")
                await state.release()
                await task.value; ownedTask = nil
                let final = try sql.load().first { $0.id == job.id.uuidString }
                let ended = await state.snapshot()
                print("VOICE_OUTCOME_BOUNDARY mode=\(mode) tracedRounds=\(tracedRounds) tracedReads=\(tracedReads) matchedGrammar=\(matchedGrammar) rejectedCalls=\(rejectedCalls) backingEntries=\(backingEntries) resultExpected=\(final?.result == "The owned document is ready.") resultQuestion=\(final?.result == OutputQuestionProbe.question) resultHasCallMarkup=\(final?.result?.contains("<tool_call>") == true) matchedReadText=\(ended.matchedReadText)")
                if ["completed", "tool-failed"].contains(mode), backingEntries != 1 { throw FixtureError.missingBacking }
                check(ended.calls > 0 && !ended.parked && conversation.taskBridge.cachedTasks.filter { $0.source == "voice" }.count == 1
                    && bridge.record(TaskID(job.id))?.id == job.id.uuidString && conversation.captureVoiceWorkerForTesting(id: job.id)?.task == nil,
                    "C03 same actual worker did not return/release its slot (\(mode))")
                check(try Data(contentsOf: target) == Data("The authored temporary file was read.".utf8),
                    "C04 actual read changed authored bytes (\(mode))")
                if mode == "completed" {
                    check(completionCallbacks == 1 && questionCallbacks == 0 && output.pendingCount == 1,
                        "DQ01 admitted completed-only callback and no question callback")
                    check(final?.status == .completed && final?.result == "The owned document is ready."
                        && final?.failure == nil && backing == 1 && announcements == ["The owned document is ready."],
                        "C05 healthy real read lost successful completion")
                    check(!VoiceSession.shared.state.activeTasks.contains(TaskID(job.id)), "C06 healthy worker lost its actual shadow completion")
                } else if mode == "model-failed" || mode == "tool-failed" {
                    check(completionCallbacks == 0 && questionCallbacks == 0 && output.pendingCount == 0,
                        "DQ02 failed actual producer emitted a completion/question (\(mode))")
                    check(final?.status == .failed && final?.failure?.isEmpty == false
                        && final?.result == nil && final?.pendingInteraction == nil,
                        "F01 typed producer failure was committed as successful work (\(mode))")
                    check(bridge.record(TaskID(job.id))?.status == .failed && backing == 0
                        && !VoiceSession.shared.state.activeTasks.contains(TaskID(job.id)), "F02 actual failed worker consumer emitted successful completion (\(mode))")
                } else if mode == "question-save-refused" {
                    check(questionCallbacks == 0 && completionCallbacks == 0 && output.pendingCount == 0,
                        "DQ03 refused actual question save entered scheduler")
                    check(final?.status == .running && final?.result == nil && final?.pendingInteraction == nil
                        && manager.lastPersistenceResult == .sqlFailed,
                        "F03 refused real question save invented committed completion")
                    let callsBefore = ended.calls
                    _ = await input(answer)
                    let after = await state.snapshot()
                    check(backing == 0 && after.calls == callsBefore && conversation.taskBridge.cachedTasks.filter { $0.source == "voice" }.count == 1
                        && job.work.followUps.isEmpty,
                        "F04 refused question was consumed/dispatched as an answer")
                } else {
                    check(final?.status == .waitingForInput && final?.result == OutputQuestionProbe.question
                        && final?.failure == nil && backing == 0,
                        "F05 actual question was completed instead of waiting (\(mode))")
                    let actualRequest = bridge.voiceInputRequest(TaskID(job.id))
                    check(questionCallbacks == 1 && completionCallbacks == 0 && output.pendingCount == 1
                        && final?.delivery == .pending,
                        "DF01 committed actual question missing exact canonical scheduler admission (\(mode))")
                    check(actualRequest?.taskID == job.id.uuidString && actualRequest?.question == OutputQuestionProbe.question,
                        "F06 canonical question identity unavailable (\(mode))")
                    check(conversation.hasActiveWork && VoiceSession.shared.state.activeTasks.contains(TaskID(job.id)), "F07 needs-you consumer lost active work/exact question (\(mode))")
                    var companionID: UUID?
                    if mode == "question", let actualRequest {
                        let companion = UUID()
                        guard bridge.beginVoiceObjective(id: companion, objective: "Prepare the owned companion result",
                            origin: .voice(sessionID: session, turn: TurnID(raw: 1)), userWords: "Prepare the owned companion result"),
                            bridge.finishVoiceObjective(id: companion, outcome: .completed("The companion result is ready.")) else { throw FixtureError.input }
                        companionID = companion
                        output.setNowForTesting(clock.addingTimeInterval(2)); recorder.reset()
                        let spoke = await output.flushAndJoinForTesting(userHasFloor: false)
                        check(spoke && recorder.spoken == [actualRequest.question] && output.pendingCount == 1,
                            "DF02 actual question priority did not withhold companion result batch")
                        check(bridge.record(TaskID(companion))?.delivery == .pending,
                            "DF07 question priority consumed completed companion")
                        finishAudio(synth, recorder)
                        _ = bridge.currentStatusReply(TaskID(companion))
                        check(manager.task(id: job.id.uuidString)?.status == .waitingForInput
                            && bridge.voiceInputRequest(TaskID(job.id)) == actualRequest,
                            "DQ05 actual question onset consumed/replaced work question")
                    }
                    let statusCallsBefore = ended.calls
                    let questionBeforeStatus = manager.task(id: job.id.uuidString)
                    let companionBeforeStatus = companionID.flatMap { manager.task(id: $0.uuidString) }
                    let statusReply = await input("How's it going?")
                    let statusObservation = await state.snapshot()
                    let legacyQuestionCopy = statusReply.reply == "I'm waiting for your answer. " + OutputQuestionProbe.question
                    let namedQuestion = TaskStatusRenderer.title(job.work.original)
                        + " needs an answer: " + OutputQuestionProbe.question
                        + (companionID == nil ? "" : " Also, Prepare the owned companion result is done: The companion result is ready.")
                    let namedQuestionCopy = statusReply.reply == namedQuestion
                    let questionRowMatches = questionBeforeStatus?.id == job.id.uuidString
                        && questionBeforeStatus?.status == .waitingForInput
                        && questionBeforeStatus?.result == OutputQuestionProbe.question
                        && bridge.voiceInputRequest(TaskID(job.id)) == actualRequest
                    let companionRowMatches = companionID == nil || (companionBeforeStatus?.id == companionID?.uuidString
                        && companionBeforeStatus?.objective == "Prepare the owned companion result"
                        && companionBeforeStatus?.status == .completed
                        && companionBeforeStatus?.result == "The companion result is ready.")
                    let statusRowsUnchanged = manager.task(id: job.id.uuidString) == questionBeforeStatus
                        && companionID.flatMap { manager.task(id: $0.uuidString) } == companionBeforeStatus
                    print("VOICE_STATUS_COPY scope=outputQuestion mode=\(mode) legacy=\(legacyQuestionCopy) named=\(namedQuestionCopy) sameCalls=\(statusObservation.calls == statusCallsBefore) companion=\(companionID != nil) rowsMatch=\(questionRowMatches && companionRowMatches) rowsUnchanged=\(statusRowsUnchanged)")
                    check((legacyQuestionCopy || namedQuestionCopy) && questionRowMatches && companionRowMatches && statusRowsUnchanged
                        && statusObservation.calls == statusCallsBefore
                        && job.work.followUps.isEmpty && backing == 0,
                        "F13 actual status reply lost canonical question or started another model/run (\(mode))")
                    finishAudio(synth, recorder)
                    _ = await input("What is a haiku?")
                    finishAudio(synth, recorder)
                    check(job.work.followUps.isEmpty && backing == 0,
                        "C07 unrelated speech consumed the question (\(mode))")
                    if let actualRequest, mode == "question-cancel" {
                        let beforeCancelCalls = ended.calls
                        let item = DeliveryItem(task: TaskID(job.id), kind: .question, title: TaskStatusRenderer.title(job.work.original),
                            facts: actualRequest.question, enqueuedAt: actualRequest.createdAt, attempts: 0, carriedOver: false)
                        let admittedQuestion = output.enqueueQuestion(TaskID(job.id)) || output.enqueue(item)
                        check(admittedQuestion && output.pendingCount == 1,
                            "DQ06 real retained request input did not qualify cancellation queue")
                        manager.cancel(job.id.uuidString)
                        let cancelled = try sql.load().first { $0.id == job.id.uuidString }
                        check(cancelled?.status == .cancelled && cancelled?.pendingInteraction == nil
                            && !conversation.hasActiveWork && !VoiceSession.shared.state.activeTasks.contains(TaskID(job.id)),
                            "F12 actual Manager cancel did not clear same waiting question/shadow work")
                        output.setNowForTesting(clock.addingTimeInterval(3)); recorder.reset()
                        check(output.pendingCount == 0 && !output.flush(userHasFloor: false) && recorder.spoken.isEmpty,
                            "DF03 explicit cancel retained/replayed exact queued question")
                        _ = await input(answer)
                        let afterCancel = await state.snapshot()
                        check(afterCancel.calls == beforeCancelCalls && backing == 0
                            && conversation.taskBridge.cachedTasks.filter { $0.source == "voice" }.count == 1 && job.work.followUps.isEmpty
                            && !bridge.resumeVoiceObjective(id: job.id, requestID: actualRequest.id, answer: answer),
                            "C13 cancelled question replayed model/backing or created another job")
                    } else if let actualRequest {
                        let fabricated = DeliveryItem(task: TaskID(job.id), kind: .question, title: "Owned question",
                            facts: "Invented question unrelated to saved request?", enqueuedAt: actualRequest.createdAt,
                            attempts: 0, carriedOver: false)
                        check(!output.enqueue(fabricated), "DF04 assistant facts minted a question absent exact saved request")
                        let beforeWrong = try Data(contentsOf: file)
                        check(!bridge.resumeVoiceObjective(id: job.id, requestID: UUID().uuidString, answer: answer)
                            && !bridge.resumeVoiceObjective(id: job.id, requestID: actualRequest.id, answer: " "),
                            "C08 stale/empty explicit answer authorized a continuation (\(mode))")
                        check(try Data(contentsOf: file) == beforeWrong,
                            "C09 refused answer changed retained primary/export (\(mode))")
                        let rows = try sql.load(); let events = try sql.journal(taskID: job.id.uuidString)
                        if mode == "answer-save-refused" {
                            try command("CREATE TRIGGER reject_voice_answer BEFORE UPDATE ON task WHEN OLD.state='waitingForInput' AND NEW.state='running' BEGIN SELECT RAISE(ABORT,'fixture answer refusal'); END;", in: directory.appendingPathComponent("agent-tasks.sqlite"))
                            let rejected = await input(answer)
                            check(rejected.reply == "I couldn't save your answer. The task is still waiting." && conversation.effectHoldEpoch != nil
                                && job.work.followUps.isEmpty && backing == 0,
                                "F08 refused explicit answer changed work or released its hold")
                            check(try sql.load() == rows && sql.journal(taskID: job.id.uuidString) == events
                                && Data(contentsOf: file) == beforeWrong && bridge.voiceInputRequest(TaskID(job.id)) == actualRequest,
                                "C10 rejected answer lost exact primary question/history")
                            try command("DROP TRIGGER reject_voice_answer;", in: directory.appendingPathComponent("agent-tasks.sqlite"))
                        }
                        await state.parkNext()
                        let answerResponse = await input(answer)
                        guard let resumedOwner = conversation.captureVoiceWorkerForTesting(id: job.id),
                              let next = resumedOwner.task else { throw FixtureError.missingWorker }
                        ownedTask = next
                        guard await reached({ await state.snapshot().parked }) else { throw FixtureError.missingWorker }
                        let resumed = try sql.load().first { $0.id == job.id.uuidString }
                        let retainedVoiceIDs = Set(conversation.taskBridge.cachedTasks.filter { $0.source == "voice" }.map(\.id))
                        let expectedRetainedIDs = Set([job.id.uuidString] + (companionID.map { [$0.uuidString] } ?? []))
                        let activeVoiceIDs = conversation.taskBridge.liveVoiceTasks(owner: conversation).map(\.id)
                        print("VOICE_QUESTION_RESUME_ROWS mode=\(mode) retained=\(retainedVoiceIDs.count) expected=\(expectedRetainedIDs.count) live=\(activeVoiceIDs.count) exactIDs=\(retainedVoiceIDs == expectedRetainedIDs)")
                        check(answerResponse.reply == "Got it. I'll continue that task." && retainedVoiceIDs == expectedRetainedIDs
                            && activeVoiceIDs == [job.id.uuidString]
                            && resumedOwner.id == job.id && resumedOwner.worker === job.worker
                            && resumedOwner.work === job.work && resumedOwner.work.followUps == [answer],
                            "F09 actual explicit answer replaced the same job/worker (\(mode))")
                        check(resumed?.status == .running && resumed?.pendingInteraction == nil
                            && resumed?.userWords == answer && resumed?.startedAt == start?.startedAt && backing == 0,
                            "F10 answer did not commit before real resumed model/backing (\(mode))")
                        check(resumed?.delivery == TaskDelivery.none && output.pendingCount == (mode == "question" ? 1 : 0),
                            "DF05 accepted exact answer failed to retire only question delivery")
                        await state.release(); await next.value; ownedTask = nil
                        let completed = try sql.load().first { $0.id == job.id.uuidString }
                        let joined = await state.snapshot()
                        check(completed?.status == .completed && completed?.pendingInteraction == nil
                            && completed?.result == "The owned document is ready." && backing == 1
                            && joined.sawAnswer && conversation.captureVoiceWorkerForTesting(id: job.id)?.task == nil,
                            "F11 real same-job answer/read/completion contract failed (\(mode))")
                        check(completionCallbacks == (mode == "question" ? 2 : 1)
                            && questionCallbacks == 1 && completed?.delivery == .pending,
                            "DF06 resumed completed producer did not publish new result stage exactly once")
                        check(!bridge.resumeVoiceObjective(id: job.id, requestID: actualRequest.id, answer: answer),
                            "C11 consumed terminal question replayed (\(mode))")
                    } else {
                        // Old producer emits no question. Do not seed one or pretend its
                        // unreachable continuation controls ran; SAME authored answer still routes.
                        _ = await input(answer)
                    }
                }
                print("VOICE_OUTCOME_CASE mode=\(mode) checks=\(checks - beforeChecks) calls=\(ended.calls) backing=\(backing) status=\(manager.task(id: job.id.uuidString)?.status.rawValue ?? "missing")")
                await capture.endSession(source: .done)
                conversation.resetForTesting(); probe = nil
            }
            let boundary = try await questionBoundaries(root: root, recorder: recorder)
            checks += boundary.checks; failures += boundary.failures
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty,
                "C12 isolated fixture changed owner state")
        } catch {
            failures.append("delivery question: INVALID \(error)")
            if let probe { await probe.release() }
            for row in conversation.taskBridge.cachedTasks where row.source == "voice" {
                if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) }
            }
            if let ownedTask { await ownedTask.value }
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
    /// Additional formal Manager finish/answer/cancel entry controls use saved requests,
    /// not model-generated DeliveryItem ownership. They are source-owner boundary proof;
    /// the seven cases above separately exercise actual RTA/planner/worker callers.
    private static func questionBoundaries(root: URL, recorder: RecordingSpeechBacking) async throws -> (checks: Int, failures: [String]) {
        var checks = 0; var failures: [String] = []
        func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures.append("delivery question: " + label) } }
        let capture = AgentCaptureController.shared; let synth = AgentSpeechSynthesizer.shared
        let playback = VoicePlaybackDelivery.shared
        for mode in ["recipient", "repeatedRequest", "refusedCancel", "onsetRecipient"] {
            let directory = root.appendingPathComponent("boundary-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let file = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: file, mirror: sql)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw FixtureError.unsafe }
            let manager = AgentTaskManager(store: store); let bridge = TaskBridge(manager: manager)
            guard let output = OutputScheduler.isolatedForTesting(bridge), playback.installOutputForTesting(output) else { throw FixtureError.unsafe }
            output.setPhraseForTesting { _ in nil }
            let clock = Date(); output.setNowForTesting(clock)
            manager.announcementOutputForTesting = output
            var questions = 0; var completions = 0
            manager.questionDeliveryForTesting = { id in questions += 1; _ = output.enqueueQuestion(id) }
            manager.completionDeliveryForTesting = { id in completions += 1; _ = output.enqueueCompletion(id) }
            defer { manager.questionDeliveryForTesting = nil; manager.completionDeliveryForTesting = nil; manager.announcementOutputForTesting = nil }
            await capture.beginSession(captureAudio: false)
            guard let session = capture.sessionID else { throw FixtureError.input }
            let id = UUID()
            guard bridge.beginVoiceObjective(id: id, objective: "Inspect the owned document",
                origin: .voice(sessionID: session, turn: TurnID(raw: 1)), userWords: "Inspect the owned document") else { throw FixtureError.input }
            if mode == "recipient" {
                await capture.endSession(source: .done)
                await capture.beginSession(captureAudio: false)
            }
            guard bridge.finishVoiceObjective(id: id, outcome: .voiceReply("Which owned file should I read?")),
                  let request = bridge.voiceInputRequest(TaskID(id)) else { throw FixtureError.input }
            check(request.taskID == id.uuidString && manager.task(id: id.uuidString)?.status == .waitingForInput
                && completions == 0, "DB01 real waiting request/completed-only callback (\(mode))")
            output.setNowForTesting(clock.addingTimeInterval(2)); recorder.reset()
            if mode == "recipient" {
                let forgedRecipient = DeliveryItem(task: TaskID(id), kind: .question, title: "Owned task",
                    facts: request.question, enqueuedAt: request.createdAt, attempts: 0, carriedOver: false)
                check(capture.sessionID != session && !output.enqueue(forgedRecipient),
                    "DF08 saved old-session question routed to new recipient")
                check(!output.flush(userHasFloor: false) && recorder.spoken.isEmpty,
                    "DF09 real Manager late question spoke through anonymous new-session fallback")
                check(manager.task(id: id.uuidString)?.status == .waitingForInput && bridge.voiceInputRequest(TaskID(id)) == request,
                    "DB02 recipient refusal rewrote work/question")
            } else if mode == "repeatedRequest" {
                check(output.flush(userHasFloor: false) && recorder.spoken == [request.question],
                    "DF10 saved question did not reach SAME audio owner")
                let retiredToken = synth.currentPlaybackToken
                synth.notifyTestingFirstAudio(token: retiredToken)
                guard bridge.resumeVoiceObjective(id: id, requestID: request.id, answer: "Use the newer owned document", sessionID: session) else { throw FixtureError.input }
                check(output.activeOutputID == nil && !synth.isSpeaking && !recorder.isSpeaking,
                    "DF15 accepted answer failed to withdraw exact active question output")
                // Identical speech is a different source request. Text matching must
                // never attribute an old receipt to this new immutable request.
                guard bridge.finishVoiceObjective(id: id, outcome: .voiceReply(request.question)),
                      let newer = bridge.voiceInputRequest(TaskID(id)) else { throw FixtureError.input }
                check(newer.id != request.id && questions == 2 && completions == 0,
                    "DF11 repeated actual question reused request/callback identity")
                let stale = DeliveryItem(task: TaskID(id), kind: .question, title: "Owned task",
                    facts: request.question, enqueuedAt: request.createdAt, attempts: 0, carriedOver: false)
                check(!output.enqueue(stale), "DF12 old request speech replaced successor question")
                output.setNowForTesting(clock.addingTimeInterval(4)); recorder.reset()
                check(output.flush(userHasFloor: false) && recorder.spoken == [newer.question],
                    "DF13 successor question retained old delivered stage/audio")
                let currentID = output.activeOutputID
                let currentToken = synth.currentPlaybackToken
                check(currentID != nil && currentID == RealtimeAudioSession.shared.voiceShadowOutputSnapshot?.id,
                    "DF16 question output identity differs from SAME actual speak owner")
                synth.notifyTestingFirstAudio(token: retiredToken)
                synth.notifyTestingAudioFinished(token: retiredToken)
                check(output.activeOutputID == currentID && synth.currentPlaybackToken == currentToken
                    && manager.task(id: id.uuidString)?.delivery == .delivering
                    && bridge.voiceInputRequest(TaskID(id)) == newer,
                    "DF17 retired original native token attributed a positive successor receipt")
                check(bridge.voiceInputRequest(TaskID(id)) == newer && manager.task(id: id.uuidString)?.status == .waitingForInput,
                    "DB03 question audio consumed task continuation")
                finishAudio(synth, recorder)
            } else if mode == "onsetRecipient" {
                let flushed = await output.flushAndJoinForTesting(userHasFloor: false)
                let originalToken = synth.currentPlaybackToken
                check(flushed && output.activeOutputID == RealtimeAudioSession.shared.voiceShadowOutputSnapshot?.id,
                    "DF18 real question was not admitted before recipient change")
                await capture.endSession(source: .done)
                await capture.beginSession(captureAudio: false)
                guard let successorSession = capture.sessionID else { throw FixtureError.input }
                synth.notifyTestingFirstAudio(token: originalToken)
                synth.notifyTestingAudioFinished(token: originalToken)
                check(successorSession != session && bridge.voiceInputRequest(TaskID(id)) == request,
                    "DB06 real close/new session rewrote retained immutable question")
                check(manager.task(id: id.uuidString)?.delivery != .delivered && output.activeOutputID == nil,
                    "DB07 late original onset manufactured successor-recipient acknowledgment")
                recorder.reset(); output.setNowForTesting(clock.addingTimeInterval(5))
                check(!output.flush(userHasFloor: false) && recorder.spoken.isEmpty,
                    "DB08 old-session question replayed in new recipient window")
            } else {
                // Existing public enqueue input is derived from the actual saved request.
                // Qualifies both variants before measuring explicit cancel SQL refusal.
                let item = DeliveryItem(task: TaskID(id), kind: .question, title: "Owned task",
                    facts: request.question, enqueuedAt: request.createdAt, attempts: 0, carriedOver: false)
                guard output.enqueueQuestion(TaskID(id)) || output.enqueue(item) else { throw FixtureError.input }
                let before = try sql.load(); let bytes = try Data(contentsOf: file)
                try command("CREATE TRIGGER reject_question_cancel BEFORE UPDATE ON task WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'owned cancel refusal'); END;", in: directory.appendingPathComponent("agent-tasks.sqlite"))
                check(!bridge.cancelVoiceObjective(id: id) && manager.lastPersistenceResult == .sqlFailed,
                    "DB04 actual cancel refusal did not qualify")
                check(try sql.load() == before && Data(contentsOf: file) == bytes
                    && bridge.voiceInputRequest(TaskID(id)) == request,
                    "DB05 refused cancel changed exact primary question")
                recorder.reset()
                check(output.pendingCount == 0 && !output.flush(userHasFloor: false) && recorder.spoken.isEmpty,
                    "DF14 cancelled presentation replayed after failed durable cancellation")
                try command("DROP TRIGGER reject_question_cancel;", in: directory.appendingPathComponent("agent-tasks.sqlite"))
            }
            _ = bridge.cancelVoiceObjective(id: id)
            await capture.endSession(source: .done)
        }
        _ = playback.installOutputForTesting(nil)
        return (checks, failures)
    }
    private static func finishAudio(_ synth: AgentSpeechSynthesizer, _ recorder: RecordingSpeechBacking) {
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        var remaining = 64
        while (synth.voiceLifecycleSnapshot.hasClause || synth.pendingClauseCount > 0) && remaining > 0 {
            recorder.finishNaturallyForTesting()
            synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
            remaining -= 1
        }
    }
}

private actor OutputQuestionProbe {
    static let question = "Which file should I read?"
    struct Snapshot: Sendable { let calls: Int; let parked: Bool; let sawAnswer: Bool; let matchedReadText: Bool }
    let mode: String; let target: String; let request: String; let answer: String
    private var calls = 0; private var continuation: CheckedContinuation<Void, Never>?
    private var shouldPark = true; private var sawAnswer = false; private var matchedReadText = false
    init(mode: String, target: String, request: String, answer: String) {
        self.mode = mode; self.target = target; self.request = request; self.answer = answer
    }
    func snapshot() -> Snapshot { Snapshot(calls: calls, parked: continuation != nil, sawAnswer: sawAnswer, matchedReadText: matchedReadText) }
    func release() { let held = continuation; continuation = nil; held?.resume() }
    func parkNext() { shouldPark = true }
    func frontend(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        let package = messages.last?.content ?? ""
        let response: String
        if package.hasSuffix("Latest user speech:\n" + request) { response = "<use_tools/>" }
        else if package.hasSuffix("Latest user speech:\n" + answer) { response = "<revise id=\"1\"/>" }
        else { response = "<answer/>A haiku is a short poem." }
        return AsyncThrowingStream { $0.yield(response); $0.finish() }
    }
    func complete(user: String) async throws -> String {
        calls += 1
        if shouldPark { shouldPark = false; await withCheckedContinuation { continuation = $0 } }
        if mode == "model-failed" { throw OutputQuestionModelError.failed }
        if user.contains(answer) { sawAnswer = true }
        if mode.hasPrefix("question") || mode == "answer-save-refused", !sawAnswer { return Self.question }
        if user.contains("The authored temporary file was read.") { matchedReadText = true; return "The owned document is ready." }
        return try Self.call(target: target)
    }
    nonisolated static func call(target: String) throws -> String {
        let args = try JSONSerialization.data(withJSONObject: ["path": target], options: [.sortedKeys])
        // Actual GBNF callBody requires canonical name, arguments, rationale IN ORDER.
        return "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":"
            + String(decoding: args, as: UTF8.self)
            + ",\"rationale\":\"Read the owned fixture file.\"}</tool_call>"
    }
}
private enum OutputQuestionModelError: Error { case failed }
private struct OutputQuestionProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: OutputQuestionProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user: user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}
