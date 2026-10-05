import Foundation

/// Actual handle → committed Manager row → output scheduler → existing audio
/// session/listener with a recording backing. Callback receipts test software
/// ownership only; there is no microphone, native model or audibility claim.
@MainActor
enum OutputSchedulerSelfTest {
    private enum InputError: Error { case unsafe, missingWorker, missingRow }
    private enum Mode: String, CaseIterable {
        case acknowledge, userBarge, provisional, retry, closePending, closeHeard, rejectedDelivery, restart, statusConsume, statusRefusal
        case answerUnheard, answerHeard, answerRefused, answerUncommitted, answerHeardRefused
    }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
    private static func canonical(_ rows: [AgentTask]) throws -> [AgentTask] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentTask].self, from: encoder.encode(rows))
    }
    static func run() async -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              AgentSession.shared.fileURL == nil, !AgentCaptureController.shared.isSessionActive,
              PermissionGate.shared.pending == nil else {
            return (0, ["scheduler: INVALID isolated delivery prerequisite"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent("NextNotesOutputDelivery-" + UUID().uuidString, isDirectory: true)
        guard root.deletingLastPathComponent().path == temp.path,
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: root.path) else {
            return (0, ["scheduler: INVALID confined root prerequisite"])
        }
        let owner = SelfTestStoreGuard.take()
        var checks = 0; var failures: [String] = []
        var actualCompletedForCodec: AgentTask?
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("scheduler: " + label) }
        }
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        let playback = VoicePlaybackDelivery.shared
        let conversation = VoiceConversationCoordinator.shared
        guard conversation.taskBridge.cachedTasks.allSatisfy({ row in
            guard let id = UUID(uuidString: row.id) else { return true }
            return conversation.captureVoiceWorkerForTesting(id: id) == nil
        }), !conversation.inputPending else {
            return (0, ["scheduler: INVALID existing shared work/input owner"])
        }
        let priorBridge = conversation.taskBridgeOverrideForTesting
        let priorRemember = conversation.rememberExplicit
        defer {
            _ = conversation.installTaskBridgeForTesting(priorBridge)
            conversation.rememberExplicit = priorRemember
        }
        let recorder = RecordingSpeechBacking()
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking(); _ = playback.installOutputForTesting(nil); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            // This confined actual RTA companion owns first correction/context access.
            let phraseApproval = await SpokenApprovalSelfTest.runPhrasePreemption(recorder: recorder)
            checks += phraseApproval.checks; failures += phraseApproval.failures
            // A rejected first admission is INVALID, never permission for older
            // real RTA cases to first-touch an unconfined default singleton.
            if phraseApproval.failures.contains(where: { $0.contains("INVALID") }) { return (checks, failures) }
            for mode in Mode.allCases {
                let startChecks = checks
                let directory = root.appendingPathComponent(mode.rawValue, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw InputError.unsafe }
                let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json"))
                let manager = AgentTaskManager(store: store, receiptStore: receipts)
                var projectionOwner = manager
                let bridge = TaskBridge(manager: manager)
                guard let output = OutputScheduler.isolatedForTesting(bridge), playback.installOutputForTesting(output) else { throw InputError.unsafe }
                output.setPhraseForTesting { _ in nil }
                var clock = Date()
                output.setNowForTesting(clock)
                conversation.resetForTesting()
                guard conversation.installTaskBridgeForTesting(bridge) else { throw InputError.unsafe }
                let words = "Open Safari for the owned delivery test."
                let frontend = OutputDeliveryFrontend(words: words)
                conversation.rememberExplicit = { _ in }
                conversation.streamForTesting = { _, messages in await frontend.stream(messages) }
                conversation.prewarmObserverForTesting = { }
                var release: CheckedContinuation<String, Never>?
                var ownedWorker: Task<Void, Never>?
                var entered = 0; var ended = 0; var announcements = 0; var callbacks = 0
                manager.announcementForTesting = { _ in announcements += 1 }
                manager.completionDeliveryForTesting = { id in
                    callbacks += 1; clock = Date(); output.setNowForTesting(clock)
                    _ = output.enqueueCompletion(id)
                }
                conversation.workerForTesting = { _ in
                    entered += 1
                    let result = await withCheckedContinuation { release = $0 }
                    ended += 1
                    return result
                }
                do {
                    await capture.beginSession(captureAudio: false)
                    guard let sessionID = capture.sessionID else { throw InputError.unsafe }
                    let inputOwner = RealtimeAgent.shared
                    inputOwner.userSpeechStarted(); inputOwner.userSpeechEnded()
                    let turn = await inputOwner.handle(words, source: .voice)
                    // The actual intake speaks its acknowledgement independently of
                    // task-result delivery. Finish that SAME recording output before
                    // measuring a quiet opportunity; never erase its queued clauses.
                    synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
                    drain(synth, recorder)
                    // Capture the existing owner immediately after admission,
                    // before qualification can throw with a retained worker.
                    if let raw = bridge.cachedTasks.first(where: { $0.source == "voice" })?.id,
                       let admittedID = UUID(uuidString: raw) {
                        ownedWorker = conversation.captureVoiceWorkerForTesting(id: admittedID)?.task
                    }
                    guard await reached({ release != nil }), let rawID = bridge.cachedTasks.first(where: { $0.source == "voice" })?.id,
                          let workerID = UUID(uuidString: rawID),
                          let job = conversation.captureVoiceWorkerForTesting(id: workerID),
                          let task = job.task else { throw InputError.missingWorker }
                    ownedWorker = task
                    let id = TaskID(job.id)
                    let admitted = try sql.load().first { $0.id == id.raw }
                    let realOrigin: UUID? = if case .voice(let session, _)? = admitted?.origin { session } else { nil }
                    print("OUTPUT_SCHEDULER_INTAKE mode=\(mode.rawValue) replyMatches=\(turn.reply == "I'm on it.") enteredOne=\(entered == 1) endedZero=\(ended == 0) primaryRunning=\(admitted?.status == .running) originMatches=\(realOrigin == sessionID) wordsMatch=\(admitted?.userWords == words) audioQuiet=\(!audio.isSpeaking) synthQuiet=\(!synth.isSpeaking) deliveryAbsent=\(admitted?.delivery == nil) hasClause=\(synth.voiceLifecycleSnapshot.hasClause) backingSpeaking=\(recorder.isSpeaking)")
                    check(turn.reply == "I'm on it." && entered == 1 && ended == 0
                        && admitted?.status == .running && realOrigin == sessionID && admitted?.userWords == words
                        && !audio.isSpeaking && !synth.isSpeaking && admitted?.delivery == nil,
                        "C01 actual voice intake/current held worker/primary origin (\(mode.rawValue))")
                    if mode == .rejectedDelivery {
                        try sql.withConnection { db in try TaskStore.exec(db,
                            "CREATE TRIGGER refuse_delivery BEFORE UPDATE ON task WHEN NEW.delivery='pending' BEGIN SELECT RAISE(ABORT,'owned delivery refusal'); END") }
                    }
                    release?.resume(returning: "The owned result is ready. A later detail remains written."); release = nil
                    await task.value; ownedWorker = nil
                    guard let completed = manager.task(id: id.raw) else { throw InputError.missingRow }
                    actualCompletedForCodec = completed
                    let retained = try sql.load().first { $0.id == id.raw }
                    check(completed.status == .completed && retained?.status == .completed && completed.result == retained?.result
                        && callbacks == 1 && announcements == 1 && entered == 1 && ended == 1,
                        "C02 real completion/announcement/callback and same worker join (\(mode.rawValue))")
                    if mode == .statusConsume || mode == .statusRefusal {
                        if mode == .statusRefusal {
                            try sql.withConnection { try TaskStore.exec($0,
                                "CREATE TRIGGER refuse_status_delivery BEFORE UPDATE ON task WHEN NEW.delivery='consumedByStatus' BEGIN SELECT RAISE(ABORT,'owned status delivery refusal'); END") }
                        }
                        let streamsBefore = await frontend.streamCount
                        let rowsBefore = try sql.load()
                        recorder.reset()
                        inputOwner.userSpeechStarted(); inputOwner.userSpeechEnded()
                        let status = await inputOwner.handle("How is that task going?", source: .voice)
                        let streamsAfter = await frontend.streamCount
                        let statusRow = try sql.load().first { $0.id == id.raw }
                        if mode == .statusConsume {
                            check(status.reply.contains("owned result is ready") && streamsAfter == streamsBefore,
                                "F30 actual completed status response omitted gist or ran frontend model")
                            check(statusRow?.delivery == .consumedByStatus && manager.task(id: id.raw)?.delivery == .consumedByStatus,
                                "F31 same completed status answer did not commit consumption")
                            let audioRows = recorder.spoken
                            check(audioRows.joined(separator: " ").contains("owned result is ready"),
                                "F32 actual status gist did not reach SAME audio consumer")
                        } else {
                            check(!status.reply.contains("owned result is ready") && statusRow?.delivery == .pending
                                && manager.task(id: id.raw)?.delivery == .pending && statusRow?.result == completed.result,
                                "C30 rejected status consumption cannot deliver or discard pending result")
                            check(try sql.load() == rowsBefore, "C31 rejected status consumption preserves exact primary rows")
                            try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_status_delivery") }
                        }
                        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
                        drain(synth, recorder)
                        output.setNowForTesting(clock.addingTimeInterval(2)); recorder.reset()
                        let afterStatus = await output.flushAndJoinForTesting(userHasFloor: false)
                        if mode == .statusConsume {
                            check(!afterStatus && recorder.spoken.isEmpty && output.pendingCount == 0,
                                "F33 SAME queue replayed positively consumed status result")
                        } else {
                            check(afterStatus && recorder.spoken.first?.contains("owned result is ready") == true,
                                "C32 failed status commit preserves actual pending output opportunity")
                            synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken); drain(synth, recorder)
                        }
                    } else if mode == .rejectedDelivery {
                        check(completed.delivery == nil && retained?.delivery == nil && output.pendingCount == 0,
                            "C03 rejected primary delivery preserved cached+SQL completion/no queue")
                        output.setNowForTesting(clock.addingTimeInterval(2))
                        recorder.reset()
                        check(!output.flush(userHasFloor: false) && recorder.spoken.isEmpty,
                            "C04 rejected delivery launched output")
                        try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_delivery") }
                    } else {
                        check(completed.delivery == .pending && retained?.delivery == .pending && output.pendingCount == 1,
                            "F01 real completion did not publish canonical pending delivery (\(mode.rawValue))")
                        let rowBefore = try sql.load(); let bytesBefore = try Data(contentsOf: file)
                        recorder.reset()
                        output.setNowForTesting(clock.addingTimeInterval(0.119))
                        check(!output.flush(userHasFloor: false) && recorder.spoken.isEmpty,
                            "C05 batching/quiet interval admitted early output (\(mode.rawValue))")
                        output.setNowForTesting(clock.addingTimeInterval(0.351))
                        check(!output.flush(userHasFloor: true) && recorder.spoken.isEmpty,
                            "C06 actual floor admitted output (\(mode.rawValue))")
                        let deferredRows = try sql.load(); let deferredBytes = try Data(contentsOf: file)
                        check(deferredRows == rowBefore && deferredBytes == bytesBefore,
                            "C07 deferred opportunity changed primary facts (\(mode.rawValue))")
                        output.setNowForTesting(clock.addingTimeInterval(0.702))
                        let flushed = await output.flushAndJoinForTesting(userHasFloor: false)
                        check(flushed && output.activeOutputID != nil
                            && output.activeOutputID == RealtimeAudioSession.shared.voiceShadowOutputSnapshot?.id
                            && recorder.spoken.first?.contains("owned result is ready") == true,
                            "F02 canonical completion did not enter same audio/listener consumer (\(mode.rawValue))")
                        check(manager.task(id: id.raw)?.delivery == .delivering,
                            "F03 enqueue incorrectly marked heard or missed delivering (\(mode.rawValue))")
                        let token = synth.currentPlaybackToken
                        let generation = synth.outputGeneration
                        switch mode {
                        case .answerUnheard, .answerHeard, .answerRefused, .answerUncommitted, .answerHeardRefused:
                            let deliveryID = output.activeOutputID
                            let committedBefore = VoiceSession.shared.state.lastCommittedTurn
                            let stopsBefore = recorder.stopCount
                            check(deliveryID != nil && deliveryID == audio.retainedOutputID
                                && synth.voiceLifecycleSnapshot.hasClause && recorder.isSpeaking
                                && manager.task(id: id.raw)?.delivery == .delivering
                                && manager.task(id: id.raw)?.deliveryAttempts == 0,
                                "C40 SAME real result output held before answer priority (\(mode.rawValue))")
                            if mode == .answerHeard || mode == .answerUncommitted || mode == .answerHeardRefused {
                                synth.notifyTestingFirstAudio(token: token)
                            }
                            let beforeAnswer = try sql.load()
                            let expectedBefore: TaskDelivery = (mode == .answerHeard || mode == .answerUncommitted || mode == .answerHeardRefused) ? .delivered : .delivering
                            check(manager.task(id: id.raw)?.delivery == expectedBefore,
                                "C41 exact current first-audio evidence before answer (\(mode.rawValue))")
                            if mode == .answerRefused {
                                try sql.withConnection { try TaskStore.exec($0,
                                    "CREATE TRIGGER refuse_answer_pending BEFORE UPDATE ON task WHEN NEW.delivery='pending' BEGIN SELECT RAISE(ABORT,'owned answer pending refusal'); END") }
                            }
                            if mode == .answerHeardRefused {
                                try sql.withConnection { try TaskStore.exec($0,
                                    "CREATE TRIGGER refuse_answer_context BEFORE UPDATE ON task WHEN NEW.delivery='deliveredInContext' BEGIN SELECT RAISE(ABORT,'owned answer context refusal'); END") }
                            }
                            let answerWords = "Tell me a haiku."
                            let answerText = "A haiku is a short poem."
                            let streamsBefore = await frontend.streamCount
                            let answer: AgentTurn
                            if mode == .answerUncommitted {
                                // Existing public nil-turn compatibility is not a
                                // committed user turn. Exercise the SAME real tracker.
                                let replyOwner = inputOwner.beginVoiceFrontend()
                                let tracker = AgentToolSpeechTracker(agent: inputOwner, turn: replyOwner, allowSpeech: true)
                                tracker.beginResponse(); tracker.receive(answerText); tracker.finish(hasToolCalls: false)
                                answer = inputOwner.finishVoiceFrontend(answerText, turn: replyOwner, streamed: true)
                            } else {
                                // The SAME production RTA/Coordinator commits the new
                                // turn and streams its answer. There is no synthetic
                                // userSpeechStarted stop before beginAnswer's own rule.
                                answer = await inputOwner.handle(answerWords, source: .voice)
                            }
                            let streamsAfter = await frontend.streamCount
                            let answerID = audio.retainedOutputID
                            let answerNative = synth.currentPlaybackToken
                            let answerGeneration = synth.outputGeneration
                            let answeredTurn: TurnID?
                            if case .answer(let t)? = audio.voiceShadowOutputSnapshot?.kind { answeredTurn = t }
                            else { answeredTurn = nil }
                            let realCommitted = mode == .answerUncommitted
                                ? answeredTurn == nil && VoiceSession.shared.state.lastCommittedTurn == committedBefore && streamsAfter == streamsBefore
                                : answeredTurn != nil && answeredTurn == VoiceSession.shared.state.lastCommittedTurn
                                    && answeredTurn != committedBefore && streamsAfter == streamsBefore + 1
                            check(answer.reply == answerText && realCommitted && answerID != nil && answerID != deliveryID
                                && answerGeneration > generation && synth.voiceLifecycleSnapshot.hasClause
                                && recorder.spoken.last == answerText && recorder.stopCount > stopsBefore,
                                "C42 SAME actual answer/tracker replaced output with correct committed scope (\(mode.rawValue))")
                            if mode == .answerUnheard {
                                check(manager.task(id: id.raw)?.delivery == .pending
                                    && manager.task(id: id.raw)?.deliveryAttempts == 0 && output.pendingCount == 1,
                                    "F40 unheard answer priority requeues without an interruption attempt")
                            } else if mode == .answerHeard {
                                check(manager.task(id: id.raw)?.delivery == .deliveredInContext
                                    && manager.task(id: id.raw)?.deliveryAttempts == 0 && output.pendingCount == 0,
                                    "F41 heard answer follows current committed turn and retires in context")
                            } else if mode == .answerRefused {
                                check(try sql.load() == beforeAnswer && manager.task(id: id.raw)?.delivery == .delivering
                                    && manager.task(id: id.raw)?.deliveryAttempts == 0 && output.pendingCount == 1,
                                    "F43 refused unheard pending commit retains SAME row and queue entry without attempt")
                            } else if mode == .answerHeardRefused {
                                check(try sql.load() == beforeAnswer && manager.task(id: id.raw)?.delivery == .delivered
                                    && manager.task(id: id.raw)?.deliveryAttempts == 0 && output.pendingCount == 1,
                                    "F46 refused heard context commit retains SAME delivered row/entry without attempt")
                            } else {
                                check(manager.task(id: id.raw)?.delivery == .pending
                                    && manager.task(id: id.raw)?.deliveryAttempts == 1 && output.pendingCount == 1,
                                    "C44 nil-turn tracker replacement retains existing non-user retry contract")
                            }
                            let afterAnswer = try sql.load()
                            synth.notifyTestingFirstAudio(token: token); synth.notifyTestingAudioFinished(token: token)
                            check(try sql.load() == afterAnswer && audio.retainedOutputID == answerID
                                && synth.currentPlaybackToken == answerNative && synth.outputGeneration == answerGeneration,
                                "C45 obsolete delivery callback cannot acknowledge current answer or change row (\(mode.rawValue))")
                            drain(synth, recorder)
                            if mode == .answerRefused {
                                try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_answer_pending") }
                                check(bridge.setDelivery([id], .pending, attempts: 0),
                                    "C46 restored primary explicitly admits SAME held pending row")
                            }
                            output.setNowForTesting(clock.addingTimeInterval(mode == .answerHeardRefused ? 3 : 1.053)); recorder.reset()
                            let replayed = await output.flushAndJoinForTesting(userHasFloor: false)
                            if mode == .answerHeardRefused {
                                check(!replayed && recorder.spoken.isEmpty && output.pendingCount == 1
                                    && manager.task(id: id.raw)?.delivery == .delivered,
                                    "F47 refused heard retirement never authorizes retry/replay after backoff")
                                // Drain any original-version erroneous replay before
                                // explicit primary repair and before leaving this scope.
                                drain(synth, recorder)
                                try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_answer_context") }
                                check(bridge.setDelivery([id], .deliveredInContext),
                                    "C49 restored primary explicitly admits SAME held heard-context row")
                                recorder.reset()
                                let afterContext = await output.flushAndJoinForTesting(userHasFloor: false)
                                check(!afterContext && output.pendingCount == 0 && recorder.spoken.isEmpty,
                                    "C50 positive heard-context commit retires SAME held entry without replay")
                            } else if mode == .answerHeard {
                                check(!replayed && recorder.spoken.isEmpty && output.pendingCount == 0,
                                    "F44 heard committed result never replays after answer")
                            } else if mode == .answerUncommitted {
                                check(!replayed && recorder.spoken.isEmpty && output.pendingCount == 1,
                                    "C47 noncommitted replacement preserves existing retry backoff")
                            } else {
                                check(replayed && recorder.spoken.first?.contains("owned result is ready") == true
                                    && manager.task(id: id.raw)?.deliveryAttempts == 0,
                                    "F42 SAME unheard result is rephrased at next quiet opportunity without backoff (\(mode.rawValue))")
                                synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
                                check(manager.task(id: id.raw)?.delivery == .delivered,
                                    "F45 replayed SAME result requires its own positive first-audio receipt (\(mode.rawValue))")
                                drain(synth, recorder)
                            }
                        case .acknowledge:
                            synth.notifyTestingFirstAudio(token: token)
                            check(manager.task(id: id.raw)?.delivery == .delivered,
                                "F04 actual current-token first-audio receipt not retained")
                            drain(synth, recorder)
                            check(output.activeOutputID == nil && !output.flush(userHasFloor: false),
                                "C08 finished output replayed")
                        case .userBarge:
                            synth.notifyTestingFirstAudio(token: token)
                            RealtimeAgent.shared.userSpeechStarted()
                            RealtimeAgent.shared.userSpeechEnded()
                            output.setNowForTesting(clock.addingTimeInterval(3))
                            check(manager.task(id: id.raw)?.delivery == .deliveredInContext && output.pendingCount == 0
                                && !output.flush(userHasFloor: false),
                                "F05 committed actual user barge replayed result or lost context delivery")
                        case .provisional:
                            let beforePause = try sql.load()
                            synth.pauseForListening()
                            let pausedRows = try sql.load()
                            check(pausedRows == beforePause && output.pendingCount == 0 && (!flushed || recorder.pauseCount == 1),
                                "C09 provisional pause consumed/requeued delivery")
                            synth.resumeAfterListening()
                            // A resume request is not a positive receipt. The recording
                            // backing cannot establish native post-resume progress.
                            check(manager.task(id: id.raw)?.delivery == .delivering && synth.outputGeneration == generation,
                                "F06 provisional resume manufactured delivery or lost current generation")
                            drain(synth, recorder)
                        case .retry:
                            // A non-user interruption retries the WHOLE retained result,
                            // even when an earlier sample was acknowledged. Session close
                            // is the distinct no-retry case tested below.
                            synth.notifyTestingFirstAudio(token: token)
                            RealtimeAgent.shared.interrupt()
                            check(manager.task(id: id.raw)?.delivery == .pending && manager.task(id: id.raw)?.deliveryAttempts == 1,
                                "F07 non-user stop after acknowledged onset lost pending attempt")
                            output.setNowForTesting(clock.addingTimeInterval(1.6))
                            check(!output.flush(userHasFloor: false), "C10 retry ignored existing backoff opportunity")
                            output.setNowForTesting(clock.addingTimeInterval(1.8))
                            recorder.reset()
                            let retried = await output.flushAndJoinForTesting(userHasFloor: false)
                            let next = synth.currentPlaybackToken
                            check(retried && recorder.spoken.first?.contains("owned result is ready") == true,
                                "F08 actual retry lost whole retained result")
                            let beforeLate = try sql.load()
                            synth.notifyTestingFirstAudio(token: token)
                            synth.notifyTestingAudioFinished(token: token)
                            let lateRows = try sql.load()
                            check(lateRows == beforeLate && (!retried || token != next),
                                "C11 old callback changed successor delivery")
                            synth.notifyTestingFirstAudio(token: next)
                            check(manager.task(id: id.raw)?.delivery == .delivered,
                                "F09 new retry positive receipt unavailable")
                            drain(synth, recorder)
                        case .closePending, .closeHeard:
                            if mode == .closeHeard { synth.notifyTestingFirstAudio(token: token) }
                            await capture.endSession(source: .done)
                            check(manager.task(id: id.raw)?.delivery == (mode == .closeHeard ? .delivered : .pending)
                                && manager.task(id: id.raw)?.deliveryAttempts == 0,
                                "F10 actual session close lost positive/pending receipt or counted stop retry (\(mode.rawValue))")
                            output.setNowForTesting(clock.addingTimeInterval(2))
                            await capture.beginSession(captureAudio: false)
                            output.setNowForTesting(clock.addingTimeInterval(2.351))
                            recorder.reset()
                            let nextFlush = await output.flushAndJoinForTesting(userHasFloor: false)
                            check(mode == .closePending ? nextFlush && recorder.spoken.first?.contains("While you were away") == true : !nextFlush && recorder.spoken.isEmpty,
                                "F11 session carry replayed heard result or dropped unacknowledged result (\(mode.rawValue))")
                            drain(synth, recorder)
                        case .restart:
                            await capture.endSession(source: .done)
                            // New actual SQL/JSON reader + Manager; no owner task decode/seed.
                            let freshSQL = TaskStore(root: directory); defer { freshSQL.close() }
                            let freshStore = AgentTaskStore(fileURL: file, mirror: freshSQL)
                            let fresh = AgentTaskManager(store: freshStore, receiptStore: receipts)
                            projectionOwner = fresh
                            let freshBridge = TaskBridge(manager: fresh)
                            guard let restored = OutputScheduler.isolatedForTesting(freshBridge), playback.installOutputForTesting(restored) else { throw InputError.unsafe }
                            restored.setPhraseForTesting { _ in nil }
                            restored.setNowForTesting(clock.addingTimeInterval(2))
                            await capture.beginSession(captureAudio: false)
                            restored.setNowForTesting(clock.addingTimeInterval(2.351)); recorder.reset()
                            let carried = await restored.flushAndJoinForTesting(userHasFloor: false)
                            check(carried && fresh.task(id: id.raw)?.delivery == .delivering
                                && recorder.spoken.first?.contains("While you were away") == true,
                                "F12 fresh reader did not carry SAME pending task/result")
                            synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
                            check(fresh.task(id: id.raw)?.delivery == .delivered,
                                "F13 fresh same-row positive receipt not retained")
                            drain(synth, recorder)
                        case .rejectedDelivery, .statusConsume, .statusRefusal: break
                        }
                    }
                    await capture.endSession(source: .done)
                    manager.completionDeliveryForTesting = nil
                    conversation.resetForTesting()
                    check(entered == 1 && ended == 1 && !capture.isSessionActive && receipts.receipts.isEmpty,
                        "C12 delivery repeated worker/effect or leaked capture (\(mode.rawValue))")
                    let integrity = try sql.integrityProblems()
                    let actualRows = try sql.load(); let projectedRows = try canonical(projectionOwner.tasks)
                    check(integrity.isEmpty && actualRows == projectedRows,
                        "C13 SAME primary/export fields or integrity diverged (\(mode.rawValue))")
                    _ = playback.installOutputForTesting(nil)
                    print("OUTPUT_SCHEDULER_TRACE mode=\(mode.rawValue) checks=\(checks-startChecks) entered=\(entered) ended=\(ended) callback=\(callbacks) primaryStatus=\(manager.task(id:id.raw)?.status.rawValue ?? "unknown") delivery=\(manager.task(id:id.raw)?.delivery?.rawValue ?? "unknown") attempts=\(manager.task(id:id.raw)?.deliveryAttempts ?? -1) physicalAudio=false")
                } catch {
                    // Discover the SAME current owner before requesting cancellation.
                    if ownedWorker == nil,
                       let raw = bridge.cachedTasks.first(where: { $0.source == "voice" })?.id,
                       let failedID = UUID(uuidString: raw) {
                        ownedWorker = conversation.captureVoiceWorkerForTesting(id: failedID)?.task
                    }
                    if let task = ownedWorker {
                        if let rawID = bridge.cachedTasks.first(where: { $0.source == "voice" })?.id,
                           let id = UUID(uuidString: rawID) { conversation.cancel(id) }
                        release?.resume(returning: "Owned invalid cleanup."); release = nil
                        await task.value
                    }
                    await capture.endSession(source: .done)
                    manager.completionDeliveryForTesting = nil
                    conversation.resetForTesting()
                    throw error
                }
            }
            guard let actual = actualCompletedForCodec else { throw InputError.missingRow }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard var old = try JSONSerialization.jsonObject(with: encoder.encode(actual)) as? [String: Any] else { throw InputError.unsafe }
            old.removeValue(forKey: "delivery"); old.removeValue(forKey: "deliveryAttempts")
            let decoded = try decoder.decode(AgentTask.self, from: JSONSerialization.data(withJSONObject: old))
            check(decoded.id == actual.id && decoded.result == actual.result && decoded.delivery == nil && decoded.deliveryAttempts == 0,
                "C15 actual legacy codec absence invented positive delivery")
            var negative = old; negative["deliveryAttempts"] = -1
            let negativeData = try JSONSerialization.data(withJSONObject: negative)
            check((try? decoder.decode(AgentTask.self, from: negativeData)) == nil,
                "C16 external negative delivery attempts admitted")
            var future = old; future["delivery"] = "future-owned-delivery"
            let futureData = try JSONSerialization.data(withJSONObject: future)
            check((try? decoder.decode(AgentTask.self, from: futureData)) == nil,
                "C17 external unknown delivery kind admitted")
            let legacy = try await legacyCompletionCases(root: root, recorder: recorder)
            checks += legacy.checks; failures += legacy.failures
            let parentCases = try await OutputSchedulerParentSelfTest.run(root: root, recorder: recorder)
            checks += parentCases.checks; failures += parentCases.failures
            let questions = await OutputSchedulerQuestionSelfTest.run(recorder: recorder)
            checks += questions.checks; failures += questions.failures
            let approvals = await SpokenApprovalSelfTest.run(recorder: recorder)
            checks += approvals.checks; failures += approvals.failures
            let sends = await SpokenApprovalSendSelfTest.run(recorder: recorder)
            checks += sends.checks; failures += sends.failures
            let riskPolicy = await SpokenApprovalDeclaredRiskSelfTest.run()
            checks += riskPolicy.checks; failures += riskPolicy.failures
            let managedRisk = await SpokenApprovalManagedRiskSelfTest.run(recorder: recorder)
            checks += managedRisk.checks; failures += managedRisk.failures
            let noticeLog = IslandNoticeLogSelfTest.run()
            checks += noticeLog.checks; failures += noticeLog.failures
            let phrases = await OutputSchedulerPhraseSelfTest.run(recorder: recorder)
            checks += phrases.checks; failures += phrases.failures
            let encoding = try encodingCases(root: root)
            checks += encoding.checks; failures += encoding.failures
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C14 owner store/default/grant invariant")
        } catch { failures.append("scheduler: INVALID actual input/control: \(error)") }
        print("OUTPUT_SCHEDULER_RESULT checks=\(checks) problems=\(failures.count)")
        return (checks, failures)
    }
    /// Real Manager completion with no canonical origin retains the old consumer.
    /// It creates no effect worker; it does not grant origin/permission authority.
    private static func legacyCompletionCases(root: URL, recorder: RecordingSpeechBacking) async throws -> (checks: Int, failures: [String]) {
        let directory = root.appendingPathComponent("legacy-completion", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let sql = TaskStore(root: directory); defer { sql.close() }
        let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
        guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw InputError.unsafe }
        let manager = AgentTaskManager(store: store)
        let bridge = TaskBridge(manager: manager)
        guard let output = OutputScheduler.isolatedForTesting(bridge),
              VoicePlaybackDelivery.shared.installOutputForTesting(output) else { throw InputError.unsafe }
        output.setPhraseForTesting { _ in nil }
        manager.announcementOutputForTesting = output
        // Break the same Manager→Output→Bridge injection cycle on every exit.
        defer { manager.announcementOutputForTesting = nil }
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("scheduler legacy: " + label) }
        }
        let capture = AgentCaptureController.shared
        let speech = AgentSpeechSynthesizer.shared
        await capture.beginSession(captureAudio: false)
        do {
            let id = UUID(); let result = "The owned legacy result is ready."
            let started = manager.beginVoiceObjective(id: id, objective: "Owned legacy work")
            let running = try sql.load().first { $0.id == id.uuidString }
            check(started && running?.source == "voice" && running?.origin == nil && running?.status == .running,
                "C22 real nil-origin Manager admission")
            let finished = manager.finishVoiceObjective(id: id, result: result)
            let completed = try sql.load().first { $0.id == id.uuidString }
            check(finished && completed?.status == .completed && completed?.result == result && completed?.origin == nil,
                "C23 same nil-origin completion primary committed")
            check(output.pendingCount == 1 && completed?.delivery == nil,
                "C24 actual announcement entered legacy queue only")
            let beforeSpoken = recorder.spoken.count
            let flushed = await output.flushAndJoinForTesting(userHasFloor: false)
            check(flushed && recorder.spoken.count == beforeSpoken + 1 && recorder.spoken.last == result,
                "C25 actual legacy queue-to-audio consumer retains result")
            speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
            let afterOnset = try sql.load().first { $0.id == id.uuidString }
            check(afterOnset?.delivery == nil && afterOnset?.origin == nil,
                "C26 real legacy onset cannot mint bound delivery/origin")
            drain(speech, recorder)
            check(!speech.isSpeaking && output.pendingCount == 0,
                "C27 actual legacy recording consumer joins")
            await capture.endSession(source: .done)
        } catch {
            await capture.endSession(source: .done)
            throw error
        }
        return (checks, failures)
    }
    /// Actual existing row writer/reader; this adds no second persistence owner.
    private static func encodingCases(root: URL) throws -> (checks: Int, failures: [String]) {
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("scheduler encoding: " + label) }
        }
        func raw(_ sql: TaskStore) throws -> [String] {
            try sql.withConnection { try TaskStore.stringColumn($0,
                "SELECT quote(metadata_encoding_version)||'|'||quote(origin)||'|'||quote(user_words)||'|'||quote(started_at)||'|'||quote(finished_at)||'|'||quote(delivery)||'|'||quote(delivery_attempts)||'|'||quote(revision) FROM task") }
        }
        func refused(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch { return true }
        }
        func test(_ name: String, _ body: (TaskStore, AgentTask, URL) throws -> Void) throws {
            let directory = root.appendingPathComponent("encoding-" + name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let row = AgentTask(id: UUID().uuidString, objective: "Owned delivery encoding fixture",
                createdAt: Date(timeIntervalSince1970: 1000))
            if name != "witness" { try sql.replaceSnapshot([row]) }; try body(sql, row, directory)
        }
        for marker in [0, 1] {
            try test("unowned-\(marker)") { sql, row, _ in
                var expected = row
                if marker == 1 {
                    expected.origin = .typed; expected.userWords = "Owned metadata only"
                    try sql.replaceSnapshot([expected])
                }
                try sql.withConnection { try TaskStore.exec($0,
                    "UPDATE task SET delivery='pending',delivery_attempts=3,revision=X'ABCD'") }
                let bytes = try raw(sql)
                check(try sql.load() == [expected], "F20 marker\(marker) exact old enum collision stays unowned")
                try sql.replaceSnapshot([expected])
                check(try raw(sql) == bytes, "F21 marker\(marker) save preserves unowned delivery bytes")
                var attempted = expected; attempted.delivery = .pending
                check(refused { try sql.replaceSnapshot([attempted]) }, "F22 marker\(marker) non-neutral delivery activation refused")
                let afterBytes = try raw(sql); let afterRows = try sql.load()
                check(afterBytes == bytes && afterRows == [expected], "F23 marker\(marker) activation has no partial write")
            }
        }
        try test("owned") { sql, row, _ in
            var metadata = row; metadata.origin = .typed
            metadata.userWords = "Owned current voice words"
            try sql.replaceSnapshot([metadata])
            var delivered = metadata; delivered.delivery = .pending; delivered.deliveryAttempts = 1
            try sql.replaceSnapshot([delivered])
            check(try sql.load() == [delivered], "F24 positively owned2 delivery roundtrip")
            check(try sql.withConnection { try TaskStore.integer($0, "SELECT metadata_encoding_version FROM task") } == 2,
                "F25 positive delivery promotion owns2")
            try sql.replaceSnapshot([row])
            check(try sql.load() == [row], "F26 explicit owned2 clearing preserves projection")
            check(try sql.withConnection { try TaskStore.integer($0, "SELECT metadata_encoding_version FROM task") } == 2,
                "F27 cleared delivery ownership remains monotonic2")
        }
        for (name, edit) in [("future", "metadata_encoding_version=4"),
                             ("kind", "delivery='future-owned-delivery'"),
                             ("attempts", "delivery_attempts=-1")] {
            try test("strict-" + name) { sql, row, _ in
                var metadata = row; metadata.origin = .typed
                try sql.replaceSnapshot([metadata])
                try sql.withConnection { try TaskStore.exec($0,
                    "UPDATE task SET metadata_encoding_version=2,delivery='pending',delivery_attempts=0; UPDATE task SET " + edit) }
                let bytes = try raw(sql)
                check(refused { _ = try sql.load() }, "F28 owned2 malformed/future \(name) refused")
                check(try raw(sql) == bytes, "F29 refused \(name) source bytes retained")
            }
        }
        try test("witness") { sql, row, directory in
            let file = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: file, mirror: sql)
            // The actual primary importer owns this fixture's existing neutral row.
            guard store.allowsHarnessPersistence else { throw InputError.unsafe }
            var owned = row; owned.origin = .typed; owned.userWords = "Owned current delivery words"
            guard store.save([owned]) == .saved else { throw InputError.unsafe }
            owned.delivery = .pending
            let saved = store.save([owned])
            let actualRows = try sql.load()
            check(saved == .saved && actualRows == [owned], "F30 actual primary save retains owned delivery")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            let rowsData = try JSONSerialization.data(withJSONObject: object?["tasks"] ?? [])
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let exported = try decoder.decode([AgentTask].self, from: rowsData)
            check(exported == [owned], "C20 actual saved witness keeps exact typed delivery")
        }
        check(checks == 20, "C21 actual encoding case count")
        return (checks, failures)
    }
    private static func drain(_ speech: AgentSpeechSynthesizer, _ recorder: RecordingSpeechBacking) {
        var completed = 0
        print("OUTPUT_SCHEDULER_DRAIN phase=before hasClause=\(speech.voiceLifecycleSnapshot.hasClause) queued=\(speech.pendingClauseCount) synthSpeaking=\(speech.isSpeaking) backingSpeaking=\(recorder.isSpeaking)")
        while (speech.voiceLifecycleSnapshot.hasClause || speech.pendingClauseCount > 0) && completed < 32 {
            recorder.finishNaturallyForTesting()
            speech.notifyTestingAudioFinished(token: speech.currentPlaybackToken)
            completed += 1
        }
        print("OUTPUT_SCHEDULER_DRAIN phase=after completed=\(completed) hasClause=\(speech.voiceLifecycleSnapshot.hasClause) queued=\(speech.pendingClauseCount) synthSpeaking=\(speech.isSpeaking) backingSpeaking=\(recorder.isSpeaking)")
    }
}
private actor OutputDeliveryFrontend {
    let words: String
    private(set) var streamCount = 0
    init(words: String) { self.words = words }
    func stream(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        streamCount += 1
        let work = messages.last?.role == .user && messages.last?.content.hasSuffix("Latest user speech:\n" + words) == true
        return AsyncThrowingStream { $0.yield(work ? "<use_tools/>" : "<answer/>A haiku is a short poem."); $0.finish() }
    }
}
