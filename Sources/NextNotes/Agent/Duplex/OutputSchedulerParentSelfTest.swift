import Foundation

/// Existing primary voice completion → queue admission → SAME audio receipts.
/// The item-boundary cases do not prove spoken permission/question ownership.
@MainActor
enum OutputSchedulerParentSelfTest {
    private enum InputError: Error { case unsafe, missingRow }
    private enum Mode: String, CaseIterable { case chronology, countBound, characterBound, expiredCarry, expiryRefusal }
    static func run(root: URL, recorder: RecordingSpeechBacking) async throws -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              AgentSession.shared.fileURL == nil, !AgentCaptureController.shared.isSessionActive,
              PermissionGate.shared.pending == nil else { throw InputError.unsafe }
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("scheduler parent: " + label) }
        }
        let capture = AgentCaptureController.shared
        let speech = AgentSpeechSynthesizer.shared
        for mode in Mode.allCases {
            let startChecks = checks
            let directory = root.appendingPathComponent("parent-" + mode.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw InputError.unsafe }
            let manager = AgentTaskManager(store: store)
            let bridge = TaskBridge(manager: manager)
            guard let output = OutputScheduler.isolatedForTesting(bridge),
                  VoicePlaybackDelivery.shared.installOutputForTesting(output) else { throw InputError.unsafe }
            output.setPhraseForTesting { _ in nil }
            var clock = Date(timeIntervalSince1970: 10_000)
            manager.progressDateForTesting = { clock }
            output.setNowForTesting(clock)
            await capture.beginSession(captureAudio: false)
            do {
                guard let sessionID = capture.sessionID else { throw InputError.unsafe }
                var rows: [AgentTask] = []
                let count = mode == .countBound ? 10 : (mode == .chronology || mode == .characterBound ? 3 : 1)
                for index in 0..<count {
                    let id = UUID()
                    let marker = "Owned result number \(index + 1)."
                    let facts = mode == .characterBound ? marker + String(repeating: " x", count: 440) : marker
                    clock = Date(timeIntervalSince1970: 10_000 + Double(index))
                    guard manager.beginVoiceObjective(id: id, objective: "Owned task \(index + 1)",
                        origin: .voice(sessionID: sessionID, turn: TurnID(raw: UInt64(index + 1))), userWords: "Owned task \(index + 1)"),
                        manager.finishVoiceObjective(id: id, result: facts),
                        let row = manager.task(id: id.uuidString), row.status == .completed else { throw InputError.missingRow }
                    rows.append(row)
                }
                check(try sql.load().filter { $0.status == .completed }.count == count,
                    "C40 actual primary completion inputs (\(mode.rawValue))")
                // Facts and chronology come only from those actual completed rows.
                // Reversed admission exercises the existing item boundary; there is
                // no inference/tool/native-result substitute or second payload store.
                let ordered = mode == .chronology ? Array(rows.reversed()) : rows
                for row in ordered {
                    let item = DeliveryItem(task: TaskID(row.id), kind: .result,
                        title: TaskStatusRenderer.title(row.objective), facts: row.result ?? "",
                        enqueuedAt: row.finishedAt ?? clock, attempts: row.deliveryAttempts, carriedOver: false)
                    guard output.enqueue(item) else { throw InputError.unsafe }
                }
                check(output.pendingCount == count && rows.allSatisfy { manager.task(id: $0.id)?.delivery == .pending },
                    "C41 SAME item admission retains primary pending rows (\(mode.rawValue))")
                recorder.reset()
                let opportunity = clock.addingTimeInterval(1)
                output.setNowForTesting(opportunity)
                switch mode {
                case .chronology, .countBound, .characterBound:
                    let flushed = await output.flushAndJoinForTesting(userHasFloor: false)
                    let expectedCount = mode == .countBound ? 8 : (mode == .characterBound ? 2 : 3)
                    let live = try sql.load().filter { $0.delivery == .delivering }
                    let expectedIDs = Set(rows.prefix(expectedCount).map(\.id))
                    check(flushed && Set(live.map(\.id)) == expectedIDs && output.pendingCount == count - expectedCount,
                        "F40 real batch respects oldest/count/fact budget (\(mode.rawValue))")
                    check(output.activeOutputID != nil && output.activeOutputID == RealtimeAudioSession.shared.voiceShadowOutputSnapshot?.id,
                        "C42 batch uses SAME speak-owned identity (\(mode.rawValue))")
                    speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
                    drain(speech, recorder)
                    let spoken = recorder.spoken.joined(separator: " ")
                    if mode == .chronology {
                        let first = spoken.range(of: "Owned result number 1")
                        let second = spoken.range(of: "Owned result number 2")
                        let third = spoken.range(of: "Owned result number 3")
                        check(first != nil && second != nil && third != nil
                            && first!.lowerBound < second!.lowerBound && second!.lowerBound < third!.lowerBound,
                            "F41 actual recording consumer receives chronological facts")
                    } else {
                        check(expectedIDs.allSatisfy { manager.task(id: $0)?.delivery == .delivered }
                            && rows.dropFirst(expectedCount).allSatisfy { manager.task(id: $0.id)?.delivery == .pending },
                            "C43 first positive audio consumes only selected primary rows (\(mode.rawValue))")
                    }
                    if mode != .chronology {
                        output.setNowForTesting(opportunity.addingTimeInterval(1)); recorder.reset()
                        let rest = await output.flushAndJoinForTesting(userHasFloor: false)
                        check(rest && output.pendingCount == 0 && rows.dropFirst(expectedCount).allSatisfy { manager.task(id: $0.id)?.delivery == .delivering },
                            "C44 deferred remainder reaches next real window (\(mode.rawValue))")
                        speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken); drain(speech, recorder)
                    }
                case .expiredCarry, .expiryRefusal:
                    await capture.endSession(source: .done)
                    let before = try sql.load()
                    if mode == .expiryRefusal {
                        try sql.withConnection { try TaskStore.exec($0,
                            "CREATE TRIGGER refuse_expired_silence BEFORE UPDATE ON task WHEN NEW.delivery='silent' BEGIN SELECT RAISE(ABORT,'owned expiry refusal'); END") }
                    }
                    guard let finished = before.first(where: { $0.id == rows[0].id })?.finishedAt else { throw InputError.missingRow }
                    let expiryOpportunity = finished.addingTimeInterval(43_201)
                    traceExpiry(mode: mode.rawValue, phase: "beforeSessionOpen",
                        row: before.first { $0.id == rows[0].id }, opportunity: expiryOpportunity)
                    output.setNowForTesting(expiryOpportunity)
                    await capture.beginSession(captureAudio: false)
                    let after = try sql.load()
                    traceExpiry(mode: mode.rawValue, phase: "afterSessionOpen",
                        row: after.first { $0.id == rows[0].id }, opportunity: expiryOpportunity)
                    if mode == .expiredCarry {
                        check(after.first?.delivery == .silent && manager.task(id: rows[0].id)?.delivery == .silent
                            && output.pendingCount == 0,
                            "F42 existing queued result expires at SAME session-open producer")
                        output.setNowForTesting(finished.addingTimeInterval(43_202)); recorder.reset()
                        check(!output.flush(userHasFloor: false) && recorder.spoken.isEmpty,
                            "F43 actual expired queued result is not replayed")
                    } else {
                        check(after == before && output.pendingCount == 1 && after.first?.delivery == .pending,
                            "C45 refused expiry preserves exact pending primary and queue")
                        try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_expired_silence") }
                        traceExpiry(mode: mode.rawValue, phase: "beforeAdmissionRetry",
                            row: manager.task(id: rows[0].id), opportunity: expiryOpportunity)
                        output.sessionOpened()
                        traceExpiry(mode: mode.rawValue, phase: "afterAdmissionRetry",
                            row: manager.task(id: rows[0].id), opportunity: expiryOpportunity)
                        check(try sql.load().first?.delivery == .silent && output.pendingCount == 0,
                            "F44 existing retained item expires after primary admission restored")
                    }
                }
                await capture.endSession(source: .done)
                let integrity = try sql.integrityProblems()
                check(!capture.isSessionActive && !speech.isSpeaking && integrity.isEmpty,
                    "C46 actual output/session/primary cleanup (\(mode.rawValue))")
                print("OUTPUT_SCHEDULER_PARENT_TRACE mode=\(mode.rawValue) checks=\(checks-startChecks) pending=\(output.pendingCount) physicalAudio=false")
            } catch {
                await capture.endSession(source: .done)
                _ = VoicePlaybackDelivery.shared.installOutputForTesting(nil)
                throw error
            }
            _ = VoicePlaybackDelivery.shared.installOutputForTesting(nil)
            manager.progressDateForTesting = nil
        }
        return (checks, failures)
    }
    /// Scalar observation over rows already read by the fixture; no dates, IDs or payloads.
    private static func traceExpiry(mode: String, phase: String, row: AgentTask?, opportunity: Date) {
        let age = row?.finishedAt.map { opportunity.timeIntervalSince($0) }
        let ageSeconds = age.map { String($0) } ?? "missing"
        let hasFinishedAt = row?.finishedAt != nil
        let expiryThresholdExceeded = age.map { $0 > 43_200 } ?? false
        let clockAfterFinished = age.map { $0 >= 0 } ?? false
        let retainedState = row?.delivery?.rawValue ?? "nil"
        print("OUTPUT_SCHEDULER_PARENT_EXPIRY mode=\(mode) phase=\(phase) hasFinishedAt=\(hasFinishedAt) ageSeconds=\(ageSeconds) expiryThresholdExceeded=\(expiryThresholdExceeded) clockAfterFinished=\(clockAfterFinished) retainedState=\(retainedState)")
    }
    private static func drain(_ speech: AgentSpeechSynthesizer, _ recorder: RecordingSpeechBacking) {
        var ended = 0
        print("OUTPUT_SCHEDULER_PARENT_DRAIN phase=before hasClause=\(speech.voiceLifecycleSnapshot.hasClause) queued=\(speech.pendingClauseCount) synthSpeaking=\(speech.isSpeaking) backingSpeaking=\(recorder.isSpeaking)")
        while (speech.voiceLifecycleSnapshot.hasClause || speech.pendingClauseCount > 0) && ended < 32 {
            recorder.finishNaturallyForTesting()
            speech.notifyTestingAudioFinished(token: speech.currentPlaybackToken)
            ended += 1
        }
        print("OUTPUT_SCHEDULER_PARENT_DRAIN phase=after ended=\(ended) hasClause=\(speech.voiceLifecycleSnapshot.hasClause) queued=\(speech.pendingClauseCount) synthSpeaking=\(speech.isSpeaking) backingSpeaking=\(recorder.isSpeaking)")
    }
}
