import AVFoundation
import Foundation
import Synchronization

/// Authored PCM through the retained native graph and its native callback/cursor producer.
/// Muted software playback is not an acoustic or Pocket/Kokoro receipt claim.
@MainActor
enum NativePCMReceiptSelfTest {
    static func run() async -> [String] {
        guard SelfTest.isRunning else { return ["R6: harness required"] }
        let native = PreparedPCMSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        var failures: [String] = [], receipts: [PCMResumePlaybackReceipt] = []
        var handled: [PCMPlaybackTimelineObservation] = [], started = false, finished = false
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let shadow = VoiceSession.shared
        let oldTurn = capture.turnHandlerForTesting
        var dispatched = 0
        capture.turnHandlerForTesting = { _ in dispatched += 1 }
        synth.useTestingBacking(native)
        defer { synth.stop(); synth.restoreSystemBacking(); capture.turnHandlerForTesting = oldTurn }
        shadow.resetDiagnosticsForTesting()
        await capture.beginSession(captureAudio: false)
        capture.simulateCumulativeSpeech("Um")
        let handle = OutputScheduler.tokenForTesting()
        guard audio.beginSpokenReply(handle) else {
            await capture.endSession(source: .done)
            return ["R6: native output admission"]
        }
        audio.appendSpokenReply(handle, "Authored native PCM retains its exact clause owner.")
        let token = synth.currentPlaybackToken
        native.onUtteranceStarted = { value in started = true; synth.notifyTestingFirstAudio(token: value) }
        native.onUtteranceFinished = { value in finished = true; synth.notifyTestingAudioFinished(token: value) }
        native.timelineObserverForTesting = { handled.append($0) }
        let withheld = Mutex<(PCMPlaybackNativeObservation, @Sendable () -> Void)?>(nil)
        native.nativeCompletionInterceptorForTesting = { packet, forward in
            if packet.buffer.ordinal == 2 { withheld.withLock { $0 = (packet, forward) } }
            else { forward() }
        }
        native.resumeProofObserverForTesting = { receipts.append($0) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffers = (0..<100).map { ordinal -> AVAudioPCMBuffer in
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            buffer.frameLength = 960
            for frame in 0..<960 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame + ordinal * 960) * 0.07)) * 0.05 }
            return buffer
        }
        native.playPrepared(buffers, volume: 0, token: token)
        audio.finalizeSpokenReply(handle)
        for _ in 0..<100 where !started { try? await Task.sleep(for: .milliseconds(10)) }
        if !started {
            await capture.endSession(source: .done)
            return ["R6: native played callback did not reach synth"]
        }
        for _ in 0..<100 where withheld.withLock({ $0 == nil }) { try? await Task.sleep(for: .milliseconds(10)) }
        if withheld.withLock({ $0 == nil }) { failures.append("R6: native callback barrier absent") }
        for phase in [UInt64(4), UInt64(6)] {
            capture.simulateCumulativeSpeech("Please stop speaking")
            try? await Task.sleep(for: .milliseconds(70))
            if !synth.isPausedForListening || finished { failures.append("R6: native pause lost clause") }
            capture.simulateCumulativeSpeech("mm hmm"); capture.simulateSilence()
            if !(await capture.considerEndpoint()) { failures.append("R6: native backchannel was not discarded") }
            if phase == 4, let old = withheld.withLock({ value in let old = value; value = nil; return old }) {
                old.1()
                for _ in 0..<100 where !handled.contains(where: {
                    if case .handled(let packet, _, _, _, _, _, _) = $0 { return packet == old.0 }; return false
                }) { try? await Task.sleep(for: .milliseconds(10)) }
                if !handled.contains(where: {
                    if case .handled(let packet, _, _, _, _, let current, let candidate) = $0 {
                        return packet == old.0 && !current && !candidate
                    }; return false
                }) { failures.append("R6: retained native producer admitted pre-pause callback phase") }
            }
            if synth.voiceLifecycleSnapshot.resumeBinding != .init(token: token, phase: phase) { failures.append("R6: actual player resume binding") }
            for _ in 0..<150 where !receipts.contains(where: { $0.packet.originPhase == phase }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let receipt = receipts.first(where: { $0.packet.originPhase == phase }) else {
                failures.append("R6: native cursor/callback did not produce phase \(phase) receipt"); continue
            }
            if receipt.packet.originWasMainThread || receipt.packet.callbackKind != 2
                || receipt.earlier.frame >= receipt.later.frame
                || receipt.earlier.nodeHostTime >= receipt.later.nodeHostTime
                || receipt.packet.buffer.upperFrame <= receipt.checkpoint
                || receipt.packet.originHostTime < receipt.later.observedHostTime {
                failures.append("R6: actual native provenance/cursor/checkpoint invalid")
            }
            if synth.voiceLifecycleSnapshot.resumePending || shadow.state.output?.status != .playing
                || audio.voiceShadowOutputSnapshot?.status != .playing {
                failures.append("R6: native proof not consumed by synth/audio/shadow")
            }
            // Re-deliver actual prior phase at the real receiving boundary, bypassing fake filters.
            let prior = receipts[0]
            native.onResumePlaybackAcknowledged?(prior)
            if synth.voiceLifecycleSnapshot.resumeBinding?.phase != phase { failures.append("R6: stale native receipt replaced owner") }
        }
        for _ in 0..<500 where !finished { try? await Task.sleep(for: .milliseconds(10)) }
        if !finished || native.isSpeaking || synth.isSpeaking { failures.append("R6: actual native player did not drain") }
        if !handled.contains(where: { if case .handled(let packet, _, let cursor, _, _, true, _) = $0 {
            return !packet.originWasMainThread && cursor != nil
        }; return false }) { failures.append("R6: no real callback/cursor observations") }
        await capture.endSession(source: .done)
        if dispatched != 0 || shadow.state.output != nil { failures.append("R6: native fixture dispatched model or lost cleanup") }
        SelfTest.diagnostic("NATIVE_PCM_RECEIPT_COUNTS receipts=\(receipts.count) callback_observations=\(handled.count) muted=true")
        return failures
    }
}
