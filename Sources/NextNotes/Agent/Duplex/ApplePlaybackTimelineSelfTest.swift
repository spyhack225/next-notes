import AVFoundation
import Foundation

/// Actual existing synth->Apple backing->owned player diagnostic, not UI authority.
@MainActor
enum ApplePlaybackTimelineSelfTest {
    private final class CallbackBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private var holding = false
        private var closed = false
        private var callbacks: [(PCMPlaybackNativeObservation, @Sendable () -> Void)] = []
        private var seen: [PCMPlaybackNativeObservation] = []
        private var overflow = false
        func intercept(_ packet: PCMPlaybackNativeObservation,
                       forward: @escaping @Sendable () -> Void) {
            lock.lock()
            if seen.count < 4096 { seen.append(packet) } else { overflow = true }
            let retain = holding && !closed && callbacks.count < 4096
            if retain { callbacks.append((packet, forward)) }
            else if holding && !closed { overflow = true }
            lock.unlock()
            if !retain { forward() }
        }
        func arm() { lock.lock(); holding = true; lock.unlock() }
        func held() -> [PCMPlaybackNativeObservation] {
            lock.lock(); defer { lock.unlock() }
            return callbacks.map { $0.0 }
        }
        func observed() -> [PCMPlaybackNativeObservation] {
            lock.lock(); defer { lock.unlock() }; return seen
        }
        func didOverflow() -> Bool {
            lock.lock(); defer { lock.unlock() }; return overflow
        }
        func release(close: Bool = false) {
            lock.lock()
            holding = false
            closed = closed || close
            let saved = callbacks
            callbacks.removeAll()
            lock.unlock()
            for (_, forward) in saved { forward() }
        }
    }
    private struct Handled {
        let packet: PCMPlaybackNativeObservation
        let phase: UInt64
        let cursor: PCMPlaybackCursorObservation?
        let before: Int64?
        let after: Int64?
        let current: Bool
        let candidate: Bool
    }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
    static func run() async -> String {
        guard SelfTest.isRunning else { return "APPLE_PLAYBACK_TIMELINE_FAILED: harness required" }
        let speech = AgentSpeechSynthesizer.shared
        guard !speech.isSpeaking, !AgentCaptureController.shared.isSessionActive,
              !CommandLine.arguments.contains("--voice-pocket-source") else {
            return "APPLE_PLAYBACK_TIMELINE_FAILED: isolated existing Apple player required"
        }
        let beforeOwner = SelfTestStoreGuard.take()
        let oldEngine = speech.engineOverrideForTesting
        let oldVolume = speech.utteranceVolume
        let oldPlayback = speech.onPlaybackEvent
        let oldSettled = speech.onVoiceLifecycleSettled
        let oldObserver = speech.appleTimelineObserverForTesting
        let oldInterceptor = speech.appleNativeCompletionInterceptorForTesting
        let barrier = CallbackBarrier()
        var scheduled: [PCMPlaybackBufferObservation] = []
        var handled: [Handled] = []
        var resumes: [(UInt64, UInt64, UInt64, PCMPlaybackCursorObservation?, Int64?)] = []
        var stops: [(UInt64?, UInt64)] = []
        var nativeOnsetTokens: [UInt64] = []
        var overflow = false
        var failures: [String] = []
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures.append(label) }
        }
        speech.restoreSystemBacking()
        speech.engineOverrideForTesting = "apple"
        speech.utteranceVolume = 0
        speech.appleTimelineObserverForTesting = { observation in
            guard scheduled.count + handled.count < 8192 else { overflow = true; return }
            switch observation {
            case .scheduled(let buffer): scheduled.append(buffer)
            case .handled(let packet, let phase, let cursor, let prior, let next, let current, let candidate):
                handled.append(.init(packet: packet, phase: phase, cursor: cursor,
                    before: prior, after: next, current: current, candidate: candidate))
                SelfTest.diagnostic("APPLE_TIMELINE_PACKET: token=\(packet.buffer.token) ordinal=\(packet.buffer.ordinal) frames=\(packet.buffer.lowerFrame)..<\(packet.buffer.upperFrame) rate=\(packet.buffer.sampleRate) originPhase=\(packet.originPhase) currentPhase=\(phase) originHost=\(packet.originHostTime) originMain=\(packet.originWasMainThread) kind=\(packet.callbackKind) cursor=\(String(describing: cursor)) checkpointBefore=\(String(describing: prior)) checkpointAfter=\(String(describing: next)) current=\(current) candidate=\(candidate)")
            case .resumed(let token, let phase, let host, let cursor, let checkpoint):
                resumes.append((token, phase, host, cursor, checkpoint))
                SelfTest.diagnostic("APPLE_TIMELINE_RESUME: token=\(token) phase=\(phase) requestedHost=\(host) cursor=\(String(describing: cursor)) checkpoint=\(String(describing: checkpoint))")
            case .stopped(let token, let phase): stops.append((token, phase))
            case .paused: break
            }
        }
        speech.appleNativeCompletionInterceptorForTesting = { packet, forward in
            barrier.intercept(packet, forward: forward)
        }
        speech.onPlaybackEvent = { event in
            if case .startAcknowledged = event { nativeOnsetTokens.append(speech.currentPlaybackToken) }
            oldPlayback?(event)
        }
        defer {
            // Closed barrier forwards any future native callback immediately.
            // Every retained callback is released once; no continuation remains.
            barrier.release(close: true)
            speech.stop()
            speech.appleTimelineObserverForTesting = oldObserver
            speech.appleNativeCompletionInterceptorForTesting = oldInterceptor
            speech.onPlaybackEvent = oldPlayback
            speech.onVoiceLifecycleSettled = oldSettled
            speech.engineOverrideForTesting = oldEngine
            speech.utteranceVolume = oldVolume
        }
        let clause = "This single silent Apple utterance has enough real queued buffers to "
            + "hold an actual playback completion before pause and observe later buffers "
            + "from the same player after resuming the same token without a model "
            + "microphone or another audio graph"
        speech.speak(clause)
        let token = speech.currentPlaybackToken
        let generation = speech.outputGeneration
        guard await reached({ nativeOnsetTokens.contains(token) || !speech.isSpeaking }),
              nativeOnsetTokens.contains(token) else {
            return "APPLE_PLAYBACK_TIMELINE_FAILED: INPUT actual initial positive-buffer onset absent"
        }
        check(nativeOnsetTokens.filter { $0 == token }.count == 1 && speech.pendingClauseCount == 0,
              "CONTROL: initial actual onset was not exactly once")
        barrier.arm()
        guard await reached({ !barrier.held().isEmpty || !speech.isSpeaking }),
              let old = barrier.held().first, speech.isSpeaking else {
            return "APPLE_PLAYBACK_TIMELINE_FAILED: INPUT live real pre-pause callback unavailable"
        }
        check(old.buffer.token == token && old.originPhase == 2
              && old.buffer.upperFrame > old.buffer.lowerFrame,
              "CONTROL: held callback did not originate in positive initial phase")
        check(old.callbackKind == Int(AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack.rawValue)
              && old.originHostTime > 0,
              "CONTROL: native origin/kind/thread provenance absent")
        speech.pauseForListening()
        check(speech.isPausedForListening && speech.currentPlaybackToken == token,
              "CONTROL: actual owner pause did not retain token")
        speech.resumeAfterListening()
        check(!speech.isPausedForListening && speech.currentPlaybackToken == token
              && speech.outputGeneration == generation,
              "CONTROL: actual owner resume replaced or failed current token")
        check(resumes.count == 1 && resumes[0].0 == token && resumes[0].1 == 4 && resumes[0].2 > 0,
              "CONTROL: exact existing backing resume/phase observation absent")
        guard let resume = resumes.first, resume.0 == token, resume.1 == 4 else {
            return "APPLE_PLAYBACK_TIMELINE_FAILED: INPUT current owned resume metadata absent"
        }
        barrier.release()
        guard await reached({ handled.contains { $0.packet == old } }) else {
            return "APPLE_PLAYBACK_TIMELINE_FAILED: INPUT retained native callback did not join"
        }
        let oldRows = handled.filter { $0.packet == old }
        check(oldRows.count == 1 && oldRows[0].phase == 4
              && !oldRows[0].current && !oldRows[0].candidate,
              "TARGET: old native packet was relabelled or accepted after resume")
        _ = await reached({
            handled.contains { $0.candidate && $0.packet.buffer.token == token }
                || !speech.isSpeaking
        })
        let currentRows = handled.filter { $0.current && $0.phase == 4 && $0.packet.buffer.token == token }
        check(!currentRows.isEmpty, "CONTROL: no actual current-phase native completion")
        let checkpointRows = currentRows.filter { $0.after != nil }
        check(!checkpointRows.isEmpty,
              "TARGET: valid same-player POST-resume checkpoint absent")
        let candidate = currentRows.first { $0.candidate }
        check(candidate.map { row in
            guard let cut = row.before else { return false }
            return row.packet.buffer.upperFrame > cut
                && row.packet.originHostTime >= resume.2
                && row.packet.originPhase == row.phase
                && row.packet.callbackKind == Int(AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack.rawValue)
        } == true, "TARGET: later positive current packet did not strictly exceed previous checkpoint")
        let validCheckpointClock: Bool
        if let cursor = resume.3, let cut = resume.4 {
            validCheckpointClock = cursor.nodeHostTime >= resume.2
                && cursor.sampleRate == old.buffer.sampleRate && cut >= cursor.frame
        } else if let row = currentRows.first(where: { $0.before == nil && $0.after != nil }),
                  let cursor = row.cursor, let cut = row.after {
            validCheckpointClock = cursor.nodeHostTime >= resume.2
                && cursor.sampleRate == row.packet.buffer.sampleRate
                && cut >= cursor.frame && cut >= row.packet.buffer.upperFrame
        } else { validCheckpointClock = false }
        check(validCheckpointClock, "TARGET: checkpoint lacked valid POST-resume player clock/rate")
        let firstBuffers = scheduled.filter { $0.token == token }
        check(firstBuffers.first?.lowerFrame == 0 && zip(firstBuffers, firstBuffers.dropFirst()).allSatisfy {
            $0.0.upperFrame == $0.1.lowerFrame && $0.1.ordinal == $0.0.ordinal + 1
        }, "CONTROL: scheduled intervals did not share player origin/contiguous frame units")
        check(firstBuffers.allSatisfy { $0.sampleRate == firstBuffers.first?.sampleRate
            && $0.upperFrame > $0.lowerFrame }, "CONTROL: native buffer range changed format or had no frames")
        speech.stop()
        let firstScheduleCount = scheduled.filter { $0.token == token }.count
        check(await reached({ handled.filter { $0.packet.buffer.token == token }.count == firstScheduleCount }),
              "CONTROL: first token native callbacks did not all join after stop")

        // Distinct real stop case: retain an actual positive callback, invalidate
        // owner before player.stop, then release it and join every scheduled one.
        speech.speak(clause)
        let stopToken = speech.currentPlaybackToken
        guard await reached({ nativeOnsetTokens.contains(stopToken) || !speech.isSpeaking }),
              nativeOnsetTokens.contains(stopToken) else {
            return "APPLE_PLAYBACK_TIMELINE_FAILED: INPUT stop case real onset absent"
        }
        barrier.arm()
        guard await reached({ !barrier.held().isEmpty || !speech.isSpeaking }),
              let heldAtStop = barrier.held().first, speech.isSpeaking else {
            return "APPLE_PLAYBACK_TIMELINE_FAILED: INPUT stop case real callback unavailable"
        }
        let handledBeforeStop = handled.count
        speech.stop()
        let stopScheduleCount = scheduled.filter { $0.token == stopToken }.count
        barrier.release(close: true)
        check(await reached({ handled.filter { $0.packet.buffer.token == stopToken }.count == stopScheduleCount }),
              "CONTROL: every actual stop-token native callback did not join")
        let stopRows = handled.dropFirst(handledBeforeStop).filter { $0.packet.buffer.token == stopToken }
        check(stopRows.contains { $0.packet == heldAtStop }, "CONTROL: held stop packet lost immutable origin")
        check(stopRows.allSatisfy { $0.phase == 0 && !$0.current && !$0.candidate },
              "TARGET: stopped/unscheduled callback was treated as current played evidence")
        check(stops.contains { $0.0 == stopToken && $0.1 == 2 }
              && speech.didStop && !speech.isSpeaking,
              "CONTROL: native stop owner/phase invalidation absent")
        let seen = barrier.observed()
        check(seen.allSatisfy { packet in scheduled.contains(packet.buffer) },
              "CONTROL: native callback had no exact original scheduled interval")
        check(Set(seen.map { "\($0.buffer.token):\($0.buffer.ordinal)" }).count == seen.count,
              "CONTROL: native callback repeated a buffer")
        check(!barrier.didOverflow() && !overflow && barrier.held().isEmpty,
              "CONTROL: bounded fixture overflowed or retained callbacks")
        check(SelfTestStoreGuard.diff(beforeOwner, SelfTestStoreGuard.take()).isEmpty,
              "CONTROL: actual player diagnostic changed owner stores/defaults")
        SelfTest.diagnostic("APPLE_TIMELINE_RECORDING: scheduled=\(scheduled.count) handled=\(handled.count) nativeSeen=\(seen.count) firstScheduled=\(firstScheduleCount) stopScheduled=\(stopScheduleCount) observerOverflow=\(overflow) barrierOverflow=\(barrier.didOverflow()) held=\(barrier.held().count)")
        for failure in failures { SelfTest.diagnostic("APPLE_PLAYBACK_TIMELINE_WRONG: " + failure) }
        return failures.isEmpty && !SelfTest.failed
            ? "APPLE_PLAYBACK_TIMELINE_OK: \(checks) checks"
            : "APPLE_PLAYBACK_TIMELINE_FAILED: \(failures.count) assertions"
    }
}
