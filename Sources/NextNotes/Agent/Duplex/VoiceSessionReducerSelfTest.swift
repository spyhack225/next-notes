import Foundation

enum VoiceSessionReducerSelfTest {
    struct Frame { let at: Int64; let event: VoiceEvent; let commands: [VoiceCommand] }
    struct RecordedFrame: Codable { let at: Int64; let event: VoiceEvent }
    static let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let t1 = TurnID(raw: 1), t2 = TurnID(raw: 2), t3 = TurnID(raw: 3)
    static let o1 = OutputID(raw: 1), o2 = OutputID(raw: 2)
    static let task = TaskID("non-uuid-task")
    static func frame(_ at: Int64, _ event: VoiceEvent, _ commands: [VoiceCommand] = []) -> Frame {
        .init(at: at, event: event, commands: commands)
    }
    static var opening: Frame { frame(0, .sessionOpened(sessionID: session), [
        .scheduleTimer(.quietWindow, after: .milliseconds(350)), .scheduleTimer(.idleCheck, after: .seconds(1)), .publishIsland(.listening)]) }
    static var committed: Frame { frame(100, .committed(t1, text: "Question"), [
        .setEffectsHeld(true), .startResponse(t1, text: "Question"), .publishIsland(.thinking)]) }
    static var classified: Frame { frame(110, .decisionMade(t1, .answer), [.setEffectsHeld(false)]) }
    static var playing: [Frame] { [opening, committed, classified,
        frame(120, .responseStarted(t1, o1)), frame(130, .playback(o1, .firstAudio), [.publishIsland(.speaking)])] }

    static var traces: [(String, [Frame])] {
        [
            ("T1", [opening, frame(10, .inputActivity(t1), [.setEffectsHeld(true)]),
                frame(20, .partial(t1, text: "Question", stable: true), [.speculate(t1, text: "Question")]),
                frame(100, .committed(t1, text: "Question"), [.startResponse(t1, text: "Question"), .publishIsland(.thinking)]),
                classified, frame(120, .responseStarted(t1, o1)), frame(130, .playback(o1, .firstAudio), [.publishIsland(.speaking)]),
                frame(131, .responseStarted(t1, o1)), frame(132, .responseStarted(t1, o2), [.stopOutput(o2, byUser: false)]),
                frame(140, .responseEnded(t1, .answered), [.scheduleTimer(.quietWindow, after: .milliseconds(350)), .publishIsland(.listening)]),
                frame(200, .playback(o1, .finished), [.scheduleTimer(.quietWindow, after: .milliseconds(350))]),
                frame(210, .committed(t1, text: "Duplicate"))]),
            ("T2", playing + [
                frame(200, .interruption(.provisional(t2)), [.setEffectsHeld(true), .pauseOutput(o1)]),
                frame(210, .inputDiscarded(t2, .playbackEcho), [.setEffectsHeld(false), .resumeOutput(o1), .scheduleTimer(.quietWindow, after: .milliseconds(350))])]),
            ("T3", playing + [
                frame(200, .interruption(.committed(t2)), [.stopOutput(o1, byUser: true), .cancelResponse(t1)]),
                frame(210, .committed(t2, text: "Correction"), [.setEffectsHeld(true), .startResponse(t2, text: "Correction"), .publishIsland(.thinking)]),
                frame(211, .committed(t2, text: "Duplicate")), frame(212, .responseStarted(t1, o2), [.stopOutput(o2, byUser: false)])]),
            ("T4", [opening, committed,
                frame(120, .responseEnded(t1, .failed(code: "deadline")), [.scheduleTimer(.quietWindow, after: .milliseconds(350)), .publishIsland(.listening)]),
                frame(130, .decisionMade(t1, .answer)), frame(131, .responseEnded(t1, .cancelled)), frame(132, .inputDiscarded(t1, .noWords)),
                frame(140, .committed(t2, text: "Repair"), [.startResponse(t2, text: "Repair"), .publishIsland(.thinking)]),
                frame(141, .decisionMade(t1, .answer)), frame(150, .decisionMade(t2, .answer), [.setEffectsHeld(false)]),
                frame(160, .responseEnded(t2, .failed(code: "deadline")), [.setEffectsHeld(true), .scheduleTimer(.quietWindow, after: .milliseconds(350)), .publishIsland(.listening)]),
                frame(170, .inputWithdrawn, [.setEffectsHeld(false), .scheduleTimer(.quietWindow, after: .milliseconds(350))]),
                frame(180, .committed(t3, text: "Another"), [.setEffectsHeld(true), .startResponse(t3, text: "Another"), .publishIsland(.thinking)]),
                frame(190, .responseEnded(t3, .failed(code: "deadline")), [.scheduleTimer(.quietWindow, after: .milliseconds(350)), .publishIsland(.listening)]),
                frame(200, .sessionClosed(.done), [.setEffectsHeld(false), .publishIsland(.none)])]),
            ("T5", playing + [
                frame(500, .task(.deliveryQueued(count: 1)), [.scheduleTimer(.quietWindow, after: .zero)]),
                frame(600, .timer(.quietWindow)),
                frame(700, .responseEnded(t1, .answered), [.scheduleTimer(.quietWindow, after: .milliseconds(350)), .publishIsland(.listening)]),
                frame(1000, .playback(o1, .finished), [.scheduleTimer(.quietWindow, after: .milliseconds(350))]),
                frame(1200, .timer(.quietWindow), [.scheduleTimer(.quietWindow, after: .milliseconds(150))]),
                frame(1360, .timer(.quietWindow), [.openDeliveryWindow])]),
            ("T6", playing + [frame(150, .task(.accepted(task, title: "Work", origin: .voice(sessionID: session, turn: t1)))),
                frame(200, .sessionClosed(.done), [.stopOutput(o1, byUser: false), .cancelResponse(t1), .publishIsland(.none)])]),
            ("T7", [opening, frame(10, .inputActivity(t1), [.setEffectsHeld(true)]), frame(100, .hesitation(t1, text: "Um")),
                frame(200, .timer(.quietWindow)), frame(210, .inputActivity(t2)),
                frame(220, .partial(t3, text: "Newer", stable: false)), frame(230, .responseEnded(t2, .cancelled)),
                frame(240, .decisionMade(t2, .answer)), frame(250, .committed(t2, text: "Stale")),
                frame(260, .interruption(.committed(t2)))]),
            ("T8", [opening, frame(100, .interruption(.explicitCancel(nil)), [.cancelTask(nil)])]),
            ("T9", [opening, frame(10, .task(.accepted(task, title: "Work", origin: .voice(sessionID: session, turn: t1)))),
                frame(25010, .timer(.idleCheck), [.scheduleTimer(.idleCheck, after: .seconds(1))]),
                frame(25020, .task(.completed(task, result: "Done", artifacts: []))),
                frame(25030, .approvalPending(requestID: "request", task: task), [.publishIsland(.proposal("request"))]),
                frame(25040, .timer(.idleCheck), [.scheduleTimer(.idleCheck, after: .seconds(1))]),
                frame(25050, .approvalResolved(requestID: "stale")),
                frame(25060, .approvalResolved(requestID: "request"), [.publishIsland(.listening)]),
                frame(25070, .timer(.idleCheck), [.closeSession(.idle)])]),
            ("T10", [opening, committed,
                frame(120, .responseEnded(t1, .failed(code: "deadline")), [.scheduleTimer(.quietWindow, after: .milliseconds(350)), .publishIsland(.listening)]),
                frame(130, .inputActivity(t2)), frame(140, .inputEnded(t2)),
                frame(150, .inputActivity(t3)), frame(160, .inputEnded(t2)), frame(170, .inputEnded(t3)),
                frame(180, .committed(t3, text: "Repair"), [.startResponse(t3, text: "Repair"), .publishIsland(.thinking)]),
                frame(190, .inputEnded(t2)), frame(200, .decisionMade(t3, .answer), [.setEffectsHeld(false)])])
        ]
    }
    static func runPure(tracePath: String? = nil, printFinalMarker: Bool = true) -> Bool {
        var failures: [String] = []
        for (name, frames) in traces { failures += replay(name, frames, expected: true) }
        if let tracePath {
            do {
                let data = try String(contentsOfFile: tracePath, encoding: .utf8)
                let decoded = try data.split(separator: "\n").map { try JSONDecoder().decode(RecordedFrame.self, from: Data($0.utf8)) }
                let frames = decoded.map { frame($0.at, $0.event) }
                if frames.isEmpty {
                    failures.append("file: trace contained no events")
                } else if frames.contains(where: { $0.at < 0 }) || zip(frames, frames.dropFirst()).contains(where: { pair in pair.0.at > pair.1.at }) {
                    failures.append("file: trace timestamps were not nonnegative and ordered")
                } else {
                    failures += replay("file", frames, expected: false)
                }
                print("VOICE_SESSION_REDUCER_TRACE events=\(frames.count)")
            } catch { failures.append("file: \(error.localizedDescription)") }
        }
        for failure in failures { print("VOICE_SESSION_REDUCER_WRONG: \(failure)") }
        if printFinalMarker {
            print(failures.isEmpty ? "VOICE_SESSION_REDUCER_OK: \(traces.count) traces" : "VOICE_SESSION_REDUCER_FAILED: \(failures.first!)")
        } else { print("VOICE_SESSION_REDUCER_PURE: traces=\(traces.count) failures=\(failures.count)") }
        return failures.isEmpty
    }
    #if !VOICE_REDUCER_PURE
    /// The registered flag exercises independent current producers as well as
    /// pure traces. It never supplies model, permission or playback decisions.
    @MainActor static func run(tracePath: String? = nil) async -> Bool {
        guard SelfTest.isRunning else { return false }
        // A supplied observation file is a pure replay diagnostic.
        if let tracePath { return runPure(tracePath: tracePath) }
        let pure = runPure(printFinalMarker: false)
        let shadow = VoiceSession.shared
        shadow.resetDiagnosticsForTesting()
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        var failures: [String] = []
        func check(_ value: Bool, _ reason: String) { if !value { failures.append(reason) } }
        check(await VoiceConversationSelfTest.run(), "actual capture correction/approval flow failed")
        await Task.yield()
        let captureSamples = shadow.comparisonCounts
        check(captureSamples.values.allSatisfy { $0 > 0 } && captureSamples.count == 4,
              "actual capture lacked four-field comparator coverage")
        check(shadow.unavailableCounts.isEmpty, "actual capture reported unavailable floor coverage")

        let recorder = RecordingSpeechBacking()
        synth.useTestingBacking(recorder)
        let coordinator = VoiceConversationCoordinator.shared
        let oldStream = coordinator.streamForTesting
        let oldQueueObserver = capture.voiceShadowQueuedObserverForTesting
        coordinator.streamForTesting = { _, _ in AsyncThrowingStream { $0.yield("<answer/>Current answer."); $0.finish() } }
        await capture.beginSession(captureAudio: false)
        capture.simulateSpeech("Um")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        check(capture.voiceShadowHasFloor && shadow.state.floor != .free, "actual filler lost its unfinished floor")
        RealtimeAgent.shared.discardVoiceInput()
        check(!capture.voiceShadowHasFloor && shadow.state.floor == .free, "current withdrawal retained filler floor")
        await capture.endSession(source: .done)
        check(!capture.voiceShadowHasFloor && shadow.state.phase == .closed, "close retained filler floor")
        await capture.beginSession(captureAudio: false)
        capture.simulateSpeech("Um")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        var queuedObserved = false
        capture.voiceShadowQueuedObserverForTesting = {
            queuedObserved = true
            check(AgentSession.shared.messages.last(where: { $0.role == "user" })?.text == "Um",
                  "queued fixture did not precede history update")
            check(!capture.voiceShadowHasFloor && shadow.state.floor == .free,
                  "meaningful queued turn inherited history-only filler floor")
        }
        capture.simulateSpeech("How are things?")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        check(queuedObserved, "actual meaningful turn never reached queue observation")
        await capture.waitForActiveTurnForTesting()
        capture.voiceShadowQueuedObserverForTesting = oldQueueObserver
        await capture.endSession(source: .done)
        coordinator.streamForTesting = oldStream
        await capture.beginSession(captureAudio: false)
        // C1's real control floor ends before the stalled text is handled.
        // Speech ending must not classify it or release a write-effect hold.
        let agent = RealtimeAgent.shared
        agent.userSpeechStarted()
        check(agent.voiceInputActive && shadow.state.floor != .free && coordinator.inputPending,
              "actual control speech start lacked floor/input ownership")
        await Task.yield()
        let pendingInput = shadow.state.unclassified
        agent.userSpeechEnded()
        check(!agent.voiceInputActive && shadow.state.floor == .free,
              "actual control speech end retained acoustic floor")
        check(coordinator.inputPending && shadow.state.unclassified == pendingInput && shadow.state.effectsHeld,
              "actual control speech end classified input or released effect hold")
        await Task.yield()
        agent.discardVoiceInput()
        let spokenBeforeReply = recorder.spoken.count
        audio.beginSpokenReply()
        audio.appendSpokenReply("First clause.")
        let output = shadow.state.output?.id
        check(output != nil && shadow.state.output?.status == .queued,
              "queue before first render was not recorded")
        check(audio.voiceShadowOutputSnapshot?.status == .queued && synth.isSpeaking,
              "independent queued lifecycle was confused with speaking")
        check(synth.voiceLifecycleSnapshot.hasClause && !synth.voiceLifecycleSnapshot.rendered,
              "queued clause lacks independent pre-render producer evidence")
        await Task.yield()
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        check(shadow.state.output?.heard == true, "real first-audio acknowledgement missing")
        recorder.finishNaturallyForTesting()
        synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
        check(shadow.state.output?.id == output && audio.voiceShadowOutputSnapshot?.id == output,
              "streaming clause gap prematurely finished output")
        let firstClauseToken = synth.currentPlaybackToken
        // Stream chunks concatenate verbatim; retain the sentence separator.
        audio.appendSpokenReply(" Second clause.")
        check(recorder.spoken.count == spokenBeforeReply + 2
              && Array(recorder.spoken.suffix(2)) == ["First clause.", "Second clause."]
              && synth.currentPlaybackToken != firstClauseToken,
              "second streamed clause did not start at the backing before finalization (new clauses=\(recorder.spoken.count - spokenBeforeReply), token changed=\(synth.currentPlaybackToken != firstClauseToken))")
        check(shadow.state.output?.id == output && audio.voiceShadowOutputSnapshot?.id == output,
              "second streamed clause lost matching output identity")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        audio.finalizeSpokenReply()
        recorder.finishNaturallyForTesting()
        synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
        check(shadow.state.output == nil && audio.voiceShadowOutputSnapshot == nil,
              "finalized final clause did not release output")
        await capture.endSession(source: .done)
        synth.restoreSystemBacking()
        await Task.yield()
        let wake = WakeWordAudioMonitor.shared
        check(wake.harnessSyncSkipCount > 0 && !wake.isListening && !AudioCaptureHub.shared.isSubscribed(.wake),
              "scripted capture teardown enabled live wake capture")
        print("VOICE_SESSION_WAKE_ISOLATION: skipped=\(wake.harnessSyncSkipCount) listening=\(wake.isListening) subscribed=\(AudioCaptureHub.shared.isSubscribed(.wake))")
        shadow.printDiagnostics()
        check(shadow.divergenceCount == 0, "actual producer divergences=\(shadow.divergenceCount)")
        for failure in failures { print("VOICE_SESSION_REDUCER_INTEGRATION_WRONG: \(failure)") }
        let passed = pure && failures.isEmpty && !SelfTest.failed
        print(passed ? "VOICE_SESSION_REDUCER_OK: \(traces.count) traces and actual capture/output producers" : "VOICE_SESSION_REDUCER_FAILED: integration")
        return passed
    }
    #endif
    static func replay(_ name: String, _ frames: [Frame], expected: Bool) -> [String] {
        var failures: [String] = [], state = VoiceSessionState()
        var starts: [TurnID: Int] = [:]
        for (index, frame) in frames.enumerated() {
            let now = VoiceSessionInstant(milliseconds: frame.at)
            let (next, commands) = VoiceSessionReducer.reduce(state, frame.event, at: now)
            let repeated = VoiceSessionReducer.reduce(state, frame.event, at: now)
            func check(_ value: Bool, _ reason: String) { if !value { failures.append("\(name)/\(index): \(reason)") } }
            if expected { check(commands == frame.commands, "expected \(frame.commands), got \(commands)") }
            check(next == repeated.0 && commands == repeated.1, "INV7 nondeterministic")
            if case .responseEnded(let turn, _) = frame.event { check(!next.unclassified.contains(turn), "INV4 ended input retained") }
            for command in commands {
                switch command {
                case .startResponse(let turn, _): starts[turn, default: 0] += 1; check(starts[turn] == 1, "INV2 duplicate response")
                case .openDeliveryWindow: check(state.deliveryWindowOpen(now: now), "INV3 closed delivery window")
                case .cancelTask:
                    if case .interruption(.explicitCancel) = frame.event {} else { check(false, "INV6 incidental cancellation") }
                case .stopOutput(_, byUser: true):
                    switch frame.event {
                    case .interruption(.committed(let turn)), .committed(let turn, _):
                        check(state.response == nil || state.response!.turn < turn, "INV5 old interruption")
                    default: check(false, "INV5 stop without committed interruption")
                    }
                default: break
                }
            }
            if case .committed(let turn, _) = frame.event, state.phase == .open,
               state.lastCommittedTurn == nil || turn > state.lastCommittedTurn! {
                if case .userProvisional(let newer) = state.floor, newer > turn {
                    check(starts[turn] == nil, "INV2 stale commitment started response")
                } else { check(starts[turn] == 1, "INV2 missing committed response") }
            }
            if let previous = state.output, let current = next.output, previous.id != current.id {
                check(commands.contains(.stopOutput(previous.id, byUser: false)) || commands.contains(.stopOutput(previous.id, byUser: true)), "INV1 silently replaced active output")
            }
            if name == "T7", index >= 5 {
                check(next.floor == .userProvisional(t3) && next.unclassified.contains(t3) && next.effectsHeld, "stale input cleared newer floor/hold")
            }
            if name == "T4", (3...5).contains(index) || index == 7 {
                check(next.failedInputHold != nil && next.effectsHeld, "failed effect hold released")
                if index == 3 { check(next.unclassified.isEmpty && next.response == nil, "C1 read/input retained") }
            }
            if name == "T6", index == frames.count - 1 { check(next.activeTasks.contains(task), "session close discarded work") }
            if name == "T7", index == 2 { check(next.effectsHeld && next.response == nil, "hesitation classified input") }
            if name == "T10", index == 4 || index == 7 {
                check(next.floor == .free && next.effectsHeld && next.failedInputHold == t1,
                      "ended acoustic floor retained or cleared failed effect hold")
                check(next.unclassified == state.unclassified, "speech end classified pending input")
            }
            if name == "T10", index == 6 {
                check(next.floor == .userProvisional(t3) && next.unclassified.contains(t3),
                      "stale speech end cleared newer floor")
            }
            state = next
        }
        return failures
    }
}
