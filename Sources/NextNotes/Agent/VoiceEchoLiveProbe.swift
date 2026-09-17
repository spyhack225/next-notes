import AVFoundation
import Foundation

/// Real speaker -> microphone -> production AEC/ASR/endpoint regression.
/// A quiet room and audible speaker bleed are required. No tool effects run.
@MainActor
enum VoiceEchoLiveProbe {
    static func run() async -> (Bool, String) {
        guard SelfTest.isRunning else { return (false, "VOICE_ECHO_LIVE_FAILED: self-test only") }
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared
        await capture.endSession(source: .done)
        let priorHandler = capture.turnHandlerForTesting
        var turns: [String] = []
        capture.turnHandlerForTesting = { turns.append($0) }
        await capture.beginSession(captureAudio: true)
        guard capture.isSessionActive else {
            capture.turnHandlerForTesting = priorHandler
            return (false, "VOICE_ECHO_LIVE_FAILED: live microphone/recognizer did not start")
        }
        let meter = Meter()
        let priorEvent = speech.onPlaybackEvent
        var enqueued = 0
        var started = 0
        var completed = 0
        var interrupted = 0
        var pausedPolls = 0
        speech.onPlaybackEvent = { event in
            priorEvent?(event)
            switch event {
            case .enqueued: enqueued += 1
            case .startAcknowledged:
                started += 1
                meter.setPlayback(true)
            case .completed:
                completed += 1
                meter.setPlayback(false)
            case .interrupted:
                interrupted += 1
                meter.setPlayback(false)
            default: break
            }
        }
        let seat = AudioCaptureHub.Consumer.client(UUID())
        defer {
            AudioCaptureHub.shared.unsubscribe(seat)
            capture.turnHandlerForTesting = priorHandler
            speech.onPlaybackEvent = priorEvent
        }
        do {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
                throw TranscriptionError.notRunning
            }
            // Observe raw capture only. Processing AEC again would corrupt the
            // production filter's frame clock and invalidate this test.
            try AudioCaptureHub.shared.subscribe(seat, outputFormat: format,
                onBuffer: { meter.add($0.buffer) })
        } catch {
            await capture.endSession(source: .done)
            return (false, "VOICE_ECHO_LIVE_FAILED: raw microphone meter unavailable")
        }
        try? await Task.sleep(for: .seconds(1))
        let baseline = meter.snapshot(reset: true)
        meter.observePlaybackOnly()
        let replies = [
            "I can help with questions or tasks. Do you have anything in mind?",
            "I can help with questions. What would you like to know?"
        ]
        for reply in replies {
            audio.speak(reply)
            for _ in 0..<250 {
                if !speech.isSpeaking || speech.persistentPlaybackFailure != nil { break }
                // A false interruption that later resumes is still audible
                // disruption. Do not let reversible pauses turn this echo-only
                // acceptance gate green while playback repeatedly stalls.
                if speech.isPausedForListening { pausedPolls += 1 }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Include delayed ASR revisions after physical playback drains.
            try? await Task.sleep(for: .seconds(3))
        }
        let played = meter.snapshot(reset: false)
        let reference = AcousticEchoProcessor.shared.referenceSnapshot()
        let excess = sqrt(max(0, played.rms * played.rms - baseline.rms * baseline.rms))
        let didDrain = !speech.isSpeaking && enqueued >= 2 && started == enqueued
            && completed == enqueued && interrupted == 0 && speech.persistentPlaybackFailure == nil
        let recognizers = capture.echoProbeReceiptsForTesting
        await capture.endSession(source: .done)
        await capture.waitForActiveTurnForTesting()
        let passed = didDrain && pausedPolls == 0 && turns.isEmpty && played.frames > 32_000 && excess > 0.002
            && reference.frames > 16_000 && reference.rms > 0.005
            && recognizers.asrFrames > 32_000 && recognizers.eouProcessed && recognizers.eouReady
        let detail = "enqueued=\(enqueued) started=\(started) completed=\(completed) interrupted=\(interrupted) pausedPolls=\(pausedPolls) "
            + "userTurns=\(turns.count) rawRMS=\(played.rms) baselineRMS=\(baseline.rms) "
            + "speakerExcess=\(excess) playbackWindowFrames=\(played.frames) reference=\(reference) "
            + "asrFedFrames=\(recognizers.asrFrames) eouProcessed=\(recognizers.eouProcessed) eouReady=\(recognizers.eouReady)"
        for turn in turns { SelfTest.diagnostic("VOICE_ECHO_LIVE_UNEXPECTED_TURN=\(turn)") }
        return (passed, "VOICE_ECHO_LIVE_\(passed ? "OK" : "FAILED"): \(detail)")
    }

    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var squares = 0.0
        private var frames = 0
        private var playbackOnly = false
        private var playing = false
        func setPlayback(_ value: Bool) {
            lock.lock()
            playing = value
            lock.unlock()
        }
        func observePlaybackOnly() {
            lock.lock()
            playbackOnly = true
            lock.unlock()
        }
        func add(_ buffer: AVAudioPCMBuffer) {
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum = 0.0
            for index in 0..<count { sum += Double(samples[index] * samples[index]) }
            lock.lock()
            if !playbackOnly || playing {
                squares += sum
                frames += count
            }
            lock.unlock()
        }
        func snapshot(reset: Bool) -> (rms: Double, frames: Int) {
            lock.lock()
            defer { lock.unlock() }
            let result = (sqrt(squares / Double(max(1, frames))), frames)
            if reset { squares = 0; frames = 0 }
            return result
        }
    }
}
