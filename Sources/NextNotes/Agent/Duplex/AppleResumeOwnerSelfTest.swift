import AVFoundation
import Foundation

/// OFF-SOURCE: requires the EXACT common APIs in OWNER-BRIDGE/LATE-NOTICE.
/// Same conductor/backend gate before both versions; only synth publication
/// bridge differs. This is actual Apple native input, never scripted playback.
@MainActor
enum AppleResumeOwnerSelfTest {
    /// Fixture-only metadata/closure holder. Never retains PCM or creates a
    /// product queue. Capture at most one callback, then immediately disarm.
    private final class OnceBarrier<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var closed = false
        private var value: Value?
        private var forward: (@Sendable () -> Void)?
        func arm() { lock.lock(); armed = !closed; lock.unlock() }
        func intercept(_ input: Value, forward next: @escaping @Sendable () -> Void) {
            lock.lock()
            let keep = armed && !closed && forward == nil
            if keep { armed = false; value = input; forward = next }
            lock.unlock()
            if !keep { next() }
        }
        func held() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
        func release(close: Bool = false) {
            lock.lock()
            closed = closed || close; armed = false
            let next = forward; forward = nil; value = nil
            lock.unlock()
            next?()
        }
    }
    private struct Handled {
        let packet: ApplePlaybackNativeObservation
        let phase: UInt64
        let current: Bool
    }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10)) // harness only
        }
        return predicate()
    }
    static func run() async -> String {
        guard SelfTest.isRunning else { return "APPLE_RESUME_OWNER_FAILED: harness required" }
        let speech = AgentSpeechSynthesizer.shared
        let audio = RealtimeAudioSession.shared
        let capture = AgentCaptureController.shared
        let shadow = VoiceSession.shared
        guard !speech.isSpeaking, !capture.isSessionActive,
              !CommandLine.arguments.contains("--voice-pocket-source") else {
            return "APPLE_RESUME_OWNER_FAILED: isolated Apple owner required"
        }
        let ownerBefore = SelfTestStoreGuard.take()
        let oldEngine = speech.engineOverrideForTesting
        let oldVolume = speech.utteranceVolume
        let oldPlayback = speech.onPlaybackEvent
        let oldSettled = speech.onVoiceLifecycleSettled
        let oldTimeline = speech.appleTimelineObserverForTesting
        let oldInterceptor = speech.appleNativeCompletionInterceptorForTesting
        let oldRaw = speech.appleRawCompletionDeferralForTesting
        let oldProof = speech.appleResumeProofObserverForTesting
        let oldTurn = capture.turnHandlerForTesting
        let oldResume = audio.voiceResumeObserverForTesting
        let packetBarrier = OnceBarrier<ApplePlaybackNativeObservation>()
        let rawBarrier = OnceBarrier<RawApplePlayedNotice>()
        var scheduled: [ApplePlaybackBufferObservation] = []
        var handled: [Handled] = []
        var resumes: [(token: UInt64, phase: UInt64, host: UInt64)] = []
        var proofs: [AppleResumePlaybackReceipt] = []
        var events: [AppleResumePlaybackReceipt] = []
        var onsets: [UInt64] = []
        var livePlayback: ((AgentSpeechSynthesizer.PlaybackEvent) -> Void)?
        var overflow = false
        var turns = 0
        var checks = 0
        var failures: [String] = []
        func check(_ okay: Bool, _ name: String) {
            checks += 1
            if !okay { failures.append(name) }
        }
        func fail(_ name: String) { failures.append("INPUT: " + name) }
        func receiptValid(_ receipt: AppleResumePlaybackReceipt) -> Bool {
            guard let request = resumes.first(where: {
                $0.token == receipt.packet.buffer.token && $0.phase == receipt.packet.originPhase
            }) else { return false }
            return receipt.earlier.frame >= 0
                && receipt.later.frame > receipt.earlier.frame
                && receipt.later.nodeHostTime > receipt.earlier.nodeHostTime
                && receipt.later.observedHostTime > receipt.earlier.observedHostTime
                && receipt.earlier.nodeHostTime >= request.host
                && receipt.earlier.observedHostTime >= request.host
                && receipt.earlier.sampleRate == receipt.later.sampleRate
                && receipt.later.sampleRate == receipt.packet.buffer.sampleRate
                && receipt.checkpoint == max(receipt.later.frame, receipt.checkpointBuffer.upperFrame)
                && receipt.checkpointBuffer.token == receipt.packet.buffer.token
                && receipt.checkpointBuffer.sampleRate == receipt.packet.buffer.sampleRate
                && scheduled.contains(receipt.checkpointBuffer)
                && receipt.packet.buffer.upperFrame > receipt.checkpoint
                && receipt.packet.originHostTime >= receipt.later.observedHostTime
                && receipt.packet.callbackKind == Int(AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack.rawValue)
                && scheduled.contains(receipt.packet.buffer)
        }
        speech.restoreSystemBacking()
        speech.engineOverrideForTesting = "apple"
        speech.utteranceVolume = 0
        capture.turnHandlerForTesting = { _ in turns += 1 }
        speech.appleTimelineObserverForTesting = { input in
            guard scheduled.count + handled.count < 16384 else { overflow = true; return }
            switch input {
            case .scheduled(let buffer): scheduled.append(buffer)
            case .handled(let packet, let phase, _, _, _, let current, _):
                handled.append(.init(packet: packet, phase: phase, current: current))
                SelfTest.diagnostic("APPLE_RESUME_OWNER_PACKET: token=\(packet.buffer.token) ordinal=\(packet.buffer.ordinal) range=\(packet.buffer.lowerFrame)..<\(packet.buffer.upperFrame) originPhase=\(packet.originPhase) currentPhase=\(phase) originHost=\(packet.originHostTime) kind=\(packet.callbackKind) originMain=\(packet.originWasMainThread) current=\(current)")
            case .resumed(let token, let phase, let host, _, _):
                resumes.append((token, phase, host))
            case .paused, .stopped: break
            }
        }
        speech.appleNativeCompletionInterceptorForTesting = { packet, next in
            packetBarrier.intercept(packet, forward: next)
        }
        speech.appleRawCompletionDeferralForTesting = { raw, next in
            rawBarrier.intercept(raw, forward: next)
        }
        speech.appleResumeProofObserverForTesting = { receipt in
            if proofs.count < 16 { proofs.append(receipt) } else { overflow = true }
            SelfTest.diagnostic("APPLE_RESUME_OWNER_PROOF: \(receipt)")
        }
        defer {
            // Idempotent release closes both barriers before original callbacks
            // are restored. Callbacks already scheduled retain the closed holder.
            packetBarrier.release(close: true); rawBarrier.release(close: true)
            speech.stop()
            speech.appleTimelineObserverForTesting = oldTimeline
            speech.appleNativeCompletionInterceptorForTesting = oldInterceptor
            speech.appleRawCompletionDeferralForTesting = oldRaw
            speech.appleResumeProofObserverForTesting = oldProof
            speech.onPlaybackEvent = oldPlayback
            speech.onVoiceLifecycleSettled = oldSettled
            speech.engineOverrideForTesting = oldEngine
            speech.utteranceVolume = oldVolume
            capture.turnHandlerForTesting = oldTurn
            audio.voiceResumeObserverForTesting = oldResume
        }
        let clause = "This single silent Apple utterance keeps its real owned player active "
            + "while two short harmless backchannels pause and resume the same output "
            + "so old native notifications and fresh playback receipts can be traced "
            + "without another model microphone or voice preference"
        shadow.resetDiagnosticsForTesting()
        await capture.beginSession(captureAudio: false)
        guard let captureID = capture.sessionID else {
            fail("actual capture session absent")
            await capture.endSession(source: .done)
            return "APPLE_RESUME_OWNER_FAILED: actual capture prerequisite"
        }
        // beginSession installs the REAL audio consumer. Capture it HERE, not
        // before restoreSystemBacking/beginSession cleared or replaced handlers.
        livePlayback = speech.onPlaybackEvent
        speech.onPlaybackEvent = { event in
            if case .startAcknowledged = event { onsets.append(speech.currentPlaybackToken) }
            if case .resumeAcknowledged(let receipt) = event { events.append(receipt) }
            livePlayback?(event)
        }
        // Same actual capture seam as original94: starts producer isolation but
        // does not dispatch a model or create a microphone graph.
        capture.simulateCumulativeSpeech("Um")
        audio.beginSpokenReply(OutputScheduler.tokenForTesting())
        speech.utteranceVolume = 0
        audio.appendSpokenReply(clause); audio.finalizeSpokenReply()
        let token = speech.currentPlaybackToken
        let generation = speech.outputGeneration
        let output = shadow.state.output?.id
        check(output != nil && shadow.state.output?.status == .queued && onsets.isEmpty,
              "C01 queued text is not speaking")
        guard await reached({ onsets.contains(token) || !speech.isSpeaking }),
              onsets.contains(token), speech.isSpeaking else {
            fail("actual initial native onset absent")
            audio.noteUserSpeech(); await capture.endSession(source: .done)
            return "APPLE_RESUME_OWNER_FAILED: native onset prerequisite"
        }
        check(onsets.filter { $0 == token }.count == 1 && speech.pendingClauseCount == 0,
              "C02 one actual onset and one clause")
        check(shadow.state.output?.status == .playing && shadow.state.output?.id == output,
              "C03 initial native onset reaches actual shadow consumer")

        for phase in [UInt64(4), UInt64(6)] {
            if phase == 4 { packetBarrier.arm() } else { rawBarrier.arm() }
            guard await reached({ phase == 4 ? packetBarrier.held() != nil : rawBarrier.held() != nil }),
                  speech.isSpeaking else {
                fail("live actual callback unavailable before phase \(phase)")
                break
            }
            let oldPacket = packetBarrier.held()
            let oldRawNotice = rawBarrier.held()
            check(phase == 4 ? oldPacket?.originPhase == 2 : oldRawNotice?.buffer.token == token,
                  "C04 actual retained callback belongs to pre-pause owner \(phase)")
            let beforePauseHost = mach_absolute_time()
            capture.simulateCumulativeSpeech("Please stop speaking")
            check(speech.isPausedForListening && shadow.state.output?.status == .paused,
                  "C05 actual reversible pause confirmed \(phase)")
            capture.simulateCumulativeSpeech("mm hmm"); capture.simulateSilence()
            var observedResume = 0
            let precedingProof = proofs.last
            audio.voiceResumeObserverForTesting = { id, observedGeneration in
                observedResume += 1
                check(id == captureID && observedGeneration == generation,
                      "C06 actual synchronous resume owner \(phase)")
                check(speech.voiceLifecycleSnapshot.resumeBinding == .init(token: token, phase: phase)
                      && speech.voiceLifecycleSnapshot.resumePending,
                      "C07 exact newly requested epoch retained \(phase)")
                check(shadow.state.output?.status == .awaitingResume
                      && audio.voiceShadowOutputSnapshot?.status == .awaitingResume,
                      "C08 no historical heard restore before fresh receipt \(phase)")
                if let precedingProof {
                    // Deliberate replay of an EXACT actual prior backend receipt
                    // at the existing listener. Tests the actual consumer boundary;
                    // it is not a claim of a natural duplicated native callback.
                    livePlayback?(.resumeAcknowledged(precedingProof))
                    check(shadow.state.output?.status == .awaitingResume,
                          "C09 previous resume epoch cannot restore current output")
                }
                packetBarrier.release(); rawBarrier.release()
            }
            let discarded = await capture.considerEndpoint()
            audio.voiceResumeObserverForTesting = oldResume
            check(discarded && observedResume == 1 && speech.currentPlaybackToken == token
                  && speech.outputGeneration == generation && shadow.state.output?.id == output,
                  "C10 actual backchannel resumes same owner once \(phase)")
            if let oldPacket {
                check(await reached({ handled.contains { $0.packet == oldPacket } }),
                      "C11 exact held packet eventually joins")
                check(handled.contains { $0.packet == oldPacket && $0.phase == phase && !$0.current }
                      && !proofs.contains { $0.packet == oldPacket },
                      "C12 pre-captured old epoch is not positive resume evidence")
            }
            if let raw = oldRawNotice {
                check(await reached({ handled.contains { $0.packet.buffer == raw.buffer } }),
                      "C13 late-origin actual raw notice joins")
                check(raw.nativeEntryHostTime <= beforePauseHost
                      && raw.callbackKind == Int(AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack.rawValue)
                      && resumes.last.map { raw.nativeEntryHostTime < $0.host } == true,
                      "C14 actual completed raw notice preceded pause and resume")
                check(handled.contains { $0.packet.buffer == raw.buffer
                    && $0.packet.originPhase == phase && $0.current },
                      "C15 initially late producer observation looks current")
                check(!proofs.contains { $0.packet.buffer == raw.buffer },
                      "C16 current epoch alone cannot admit already completed old buffer")
            }
            guard await reached({ proofs.contains { $0.packet.buffer.token == token
                    && $0.packet.originPhase == phase } || !speech.isSpeaking }),
                  let proof = proofs.first(where: { $0.packet.buffer.token == token
                    && $0.packet.originPhase == phase }) else {
                fail("advancing native player proof unavailable at phase \(phase)")
                break // never classify a missing native prerequisite as feature RED
            }
            check(receiptValid(proof), "C17 real native frame/cursor proof \(phase)")
            check(proofs.filter { $0.packet.buffer.token == token && $0.packet.originPhase == phase }.count == 1,
                  "C18 exact backend receipt once per resume \(phase)")
            check(!speech.voiceLifecycleSnapshot.resumePending,
                  "TARGET R01 actual synth clears awaiting only after qualified receipt \(phase)")
            check(events.filter { $0 == proof }.count == 1,
                  "TARGET R02 actual synth publishes exact native receipt once \(phase)")
            check(shadow.state.output?.id == output && shadow.state.output?.status == .playing
                  && shadow.state.island == .speaking
                  && audio.voiceShadowOutputSnapshot?.status == .playing,
                  "TARGET R03 real synth/audio/shadow owner receives fresh resumed playback \(phase)")
        }

        // Stop then replacement shares the same existing synth/audio owners.
        // Retain an actual native packet before stop, not a forged callback.
        packetBarrier.arm()
        guard await reached({ packetBarrier.held() != nil || !speech.isSpeaking }),
              let stoppedPacket = packetBarrier.held(), speech.isSpeaking else {
            fail("stop/replacement held native input absent")
            packetBarrier.release(close: true); rawBarrier.release(close: true)
            audio.noteUserSpeech(); await capture.endSession(source: .done)
            return "APPLE_RESUME_OWNER_FAILED: stop/replacement prerequisite"
        }
        let retainedProof = proofs.last
        audio.noteUserSpeech()
        check(speech.didStop && shadow.state.output == nil, "C19 stop removes old output owner")
        audio.beginSpokenReply(OutputScheduler.tokenForTesting()); speech.utteranceVolume = 0
        audio.appendSpokenReply(OutputScheduler.currentTokenForTesting(), clause); audio.finalizeSpokenReply(OutputScheduler.currentTokenForTesting())
        let replacementToken = speech.currentPlaybackToken
        let replacementOutput = shadow.state.output?.id
        check(replacementToken != token && speech.outputGeneration != generation
              && replacementOutput != output, "C20 replacement mints distinct real identity")
        if let retainedProof { livePlayback?(.resumeAcknowledged(retainedProof)) }
        check(shadow.state.output?.status == .queued, "C21 old real receipt cannot promote replacement")
        packetBarrier.release(close: true); rawBarrier.release(close: true)
        check(await reached({ handled.contains { $0.packet == stoppedPacket } }),
              "C22 retained stopped callback joins")
        check(handled.contains { $0.packet == stoppedPacket && !$0.current }
              && !proofs.contains { $0.packet == stoppedPacket },
              "C23 stop/replacement rejects old native provenance")
        check(await reached({ onsets.contains(replacementToken) || !speech.isSpeaking })
              && onsets.filter { $0 == replacementToken }.count == 1,
              "C24 replacement remains playable through actual native onset")
        audio.noteUserSpeech()
        await capture.endSession(source: .done)
        let expected = scheduled.count
        check(await reached({ handled.count == expected }), "C25 all real scheduled native callbacks joined")
        check(Set(handled.map { "\($0.packet.buffer.token):\($0.packet.buffer.ordinal)" }).count == handled.count
              && handled.allSatisfy { scheduled.contains($0.packet.buffer) },
              "C26 native callback unique and exact scheduled origin")
        let tokens = Set(scheduled.map(\.token))
        check(tokens.allSatisfy { token in
            let rows = scheduled.filter { $0.token == token }
            return rows.first?.lowerFrame == 0 && zip(rows, rows.dropFirst()).allSatisfy {
                $0.0.upperFrame == $0.1.lowerFrame && $0.1.ordinal == $0.0.ordinal + 1
                    && $0.1.sampleRate == $0.0.sampleRate
            }
        }, "C27 exact contiguous per-player frame domain")
        check(!overflow && packetBarrier.held() == nil && rawBarrier.held() == nil,
              "C28 bounded recorder/barriers empty")
        check(turns == 0 && !speech.isSpeaking && !capture.isSessionActive
              && shadow.state.phase == .closed, "C29 cleanup/no model dispatch")
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
              "C30 owner stores/defaults unchanged")
        SelfTest.diagnostic("APPLE_RESUME_OWNER_RECORDING: checks=\(checks) scheduled=\(scheduled.count) handled=\(handled.count) proofs=\(proofs.count) events=\(events.count) resumes=\(resumes.count) overflow=\(overflow) divergences=\(shadow.divergenceCount)")
        for failure in failures { SelfTest.diagnostic("APPLE_RESUME_OWNER_WRONG: " + failure) }
        return failures.isEmpty && !SelfTest.failed
            ? "APPLE_RESUME_OWNER_OK: \(checks) checks"
            : "APPLE_RESUME_OWNER_FAILED: \(failures.count) assertions"
    }
}
