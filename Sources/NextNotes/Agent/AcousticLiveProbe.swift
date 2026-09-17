import AVFoundation
import Foundation

/// Signed-app hardware gate for a production voice renderer + Speex
/// reference path. Requires built-in speaker bleed in the raw microphone.
/// A silent tap or headphones produce FAILED, never a flattering ERLE number.
@MainActor
enum AcousticLiveProbe {
    static func run(voice requestedVoice: String = "selected") async -> (Bool, String) {
        guard await Permissions.requestMicrophone(),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000, channels: 1,
                                         interleaved: false) else {
            return (false, "ECHO_LIVE_FAILED: microphone grant or 16k format unavailable")
        }
        let voice = requestedVoice == "selected"
            ? Settings.shared.agentVoiceEngine : requestedVoice
        let backing: any AgentSpeechBacking
        let receipt = Receipt()
        switch voice {
        case "apple":
            let apple = AVSpeechBacking()
            apple.onUtteranceStarted = { _ in receipt.began = true }
            apple.onUtteranceFinished = { _ in receipt.finished = true }
            backing = apple
        case "pocket":
            await PocketAgentVoice.shared.prepare()
            guard PocketAgentVoice.shared.isReady else {
                return (false, "ECHO_LIVE_FAILED: Pocket unavailable: \(PocketAgentVoice.shared.errorMessage ?? "model missing")")
            }
            let pocket = PocketSpeechBacking()
            pocket.onUtteranceStarted = { _ in receipt.began = true }
            pocket.onUtteranceFinished = { _ in receipt.finished = true }
            backing = pocket
        case "kokoro":
            await KokoroAgentVoice.shared.prepare()
            guard KokoroAgentVoice.shared.isReady else {
                return (false, "ECHO_LIVE_FAILED: Kokoro unavailable: \(KokoroAgentVoice.shared.errorMessage ?? "model missing")")
            }
            let kokoro = KokoroSpeechBacking()
            kokoro.onUtteranceStarted = { _ in receipt.began = true }
            kokoro.onUtteranceFinished = { _ in receipt.finished = true }
            backing = kokoro
        default:
            return (false, "ECHO_LIVE_FAILED: unknown voice \(voice)")
        }
        let meter = Meter()
        let seat = AudioCaptureHub.Consumer.client(UUID())
        AcousticEchoProcessor.shared.reset()
        guard AcousticEchoProcessor.shared.backendAvailable else {
            return (false, "ECHO_LIVE_FAILED: selected AEC3 evaluation bridge unavailable")
        }
        do {
            try AudioCaptureHub.shared.subscribe(seat, outputFormat: format,
                onBuffer: { chunk in
                    let cleaned = AcousticEchoProcessor.shared.process(chunk)
                    meter.add(raw: chunk.buffer, cleaned: cleaned.buffer,
                              evidence: AcousticEchoProcessor.shared.evidenceSnapshot())
                })
        } catch {
            return (false, "ECHO_LIVE_FAILED: capture: \(error.localizedDescription)")
        }
        defer { AudioCaptureHub.shared.unsubscribe(seat) }
        try? await Task.sleep(for: .seconds(1))
        let baseline = meter.snapshot()
        meter.reset()
        backing.speak(
            "Next Notes is playing through its actual local speech output. "
                + "The microphone should hear this sentence from the laptop speakers, "
                + "and the acoustic echo processor should remove its reflection.",
            volume: 0.75, token: 1
        )
        for _ in 0..<240 where !receipt.finished {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let played = meter.snapshot()
        let reference = AcousticEchoProcessor.shared.referenceSnapshot()
        let timing = AcousticEchoProcessor.shared.timingSnapshot()
        backing.stop()
        guard receipt.began, receipt.finished, played.frames > baseline.frames + 16_000 else {
            return (false, "ECHO_LIVE_FAILED: \(voice) PCM speech did not start, drain, or deliver microphone frames")
        }
        let baselineRMS = baseline.rawRMS
        let rawExcess = sqrt(max(0, played.rawRMS * played.rawRMS - baselineRMS * baselineRMS))
        let cleanExcess = sqrt(max(0, played.cleanedRMS * played.cleanedRMS
                                    - baseline.cleanedRMS * baseline.cleanedRMS))
        // A cleaned playback RMS below room baseline does not establish zero
        // acoustic echo. Use the entire measured cleaned microphone as a
        // conservative denominator rather than reporting a huge clamp-based
        // attenuation from a negative excess-energy subtraction.
        let belowBaseline = played.cleanedRMS <= baseline.cleanedRMS
        let conservativeClean = belowBaseline ? played.cleanedRMS : cleanExcess
        let attenuation = 20 * log10(rawExcess / max(conservativeClean, 1e-8))
        let passed = baseline.frames > 8_000
            && rawExcess > max(0.002, baselineRMS * 1.5)
            && reference.frames > 16_000 && reference.rms > 0.005
            && attenuation >= 10 && played.falseNearBursts == 0
        let detail = String(format:
            "raw baseline %.5f, playback %.5f, cleaned %.5f; rendered PCM %.5f (%d frames); attenuation %.1f dB; false-near %d chunks/%d bursts; coherence <.4/.55/.7 %d/%d/%d of %d; underflow %d, queue %d..%d samples; bursts %@",
            baselineRMS, played.rawRMS, played.cleanedRMS,
            reference.rms, reference.frames, attenuation,
            played.falseNearChunks, played.falseNearBursts,
            played.lowCoherence, played.mediumCoherence, played.weakCoherence,
            played.referenceChunks, played.underflows,
            played.minimumQueue, played.maximumQueue, played.burstDetails)
        let scope = belowBaseline ? "cleaned playback below measured room baseline; attenuation is conservative lower bound" : "cleaned playback excess measured"
        let detector = "far-only near detector evaluated; positive near detection requires separate replay and human overlap"
        return (passed, "ECHO_LIVE_\(passed ? "OK" : "FAILED"): \(voice)/\(AcousticEchoProcessor.shared.backendName); \(detail); \(scope); \(detector); AEC3 timing \(timing)")
    }

    @MainActor private final class Receipt {
        var began = false
        var finished = false
    }

    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var rawSquares = 0.0
        private var cleanSquares = 0.0
        private var frames = 0
        private var falseNearChunks = 0
        private var falseNearBursts = 0
        private var previousNear = false
        private var lowCoherence = 0
        private var mediumCoherence = 0
        private var weakCoherence = 0
        private var referenceChunks = 0
        private var underflows = 0
        private var minimumQueue = Int.max
        private var maximumQueue = 0
        private var nearBursts: [String] = []

        func reset() {
            lock.lock()
            rawSquares = 0
            cleanSquares = 0
            frames = 0
            falseNearChunks = 0
            falseNearBursts = 0
            previousNear = false
            lowCoherence = 0
            mediumCoherence = 0
            weakCoherence = 0
            referenceChunks = 0
            underflows = 0
            minimumQueue = Int.max
            maximumQueue = 0
            nearBursts.removeAll()
            lock.unlock()
        }

        func add(raw: AVAudioPCMBuffer, cleaned: AVAudioPCMBuffer,
                 evidence: AcousticEchoProcessor.Evidence) {
            guard let mic = raw.floatChannelData?[0],
                  let output = cleaned.floatChannelData?[0] else { return }
            let count = min(Int(raw.frameLength), Int(cleaned.frameLength))
            var r = 0.0
            var c = 0.0
            for index in 0..<count {
                r += Double(mic[index] * mic[index])
                c += Double(output[index] * output[index])
            }
            lock.lock()
            rawSquares += r
            cleanSquares += c
            frames += count
            if evidence.independentNearCandidate {
                falseNearChunks += 1
                if !previousNear {
                    falseNearBursts += 1
                    if nearBursts.count < 12 {
                        nearBursts.append(String(format:
                            "%.2f>%.2f@%d/%.3f/%.3f/q%d/u%d",
                            evidence.echoCoherence, evidence.bestCoherence,
                            evidence.bestLagSamples,
                            evidence.rawRMS, evidence.referenceRMS,
                            evidence.queuedReferenceSamples,
                            evidence.referenceUnderflow ? 1 : 0))
                    }
                }
            }
            previousNear = evidence.independentNearCandidate
            if evidence.recentReference {
                referenceChunks += 1
                if evidence.echoCoherence < 0.4 { lowCoherence += 1 }
                if evidence.echoCoherence < 0.55 { mediumCoherence += 1 }
                if evidence.echoCoherence < 0.7 { weakCoherence += 1 }
                if evidence.referenceUnderflow { underflows += 1 }
                minimumQueue = min(minimumQueue, evidence.queuedReferenceSamples)
                maximumQueue = max(maximumQueue, evidence.queuedReferenceSamples)
            }
            lock.unlock()
        }

        func snapshot() -> (rawRMS: Double, cleanedRMS: Double, frames: Int,
                            falseNearChunks: Int, falseNearBursts: Int,
                            lowCoherence: Int, mediumCoherence: Int,
                            weakCoherence: Int, referenceChunks: Int,
                            underflows: Int, minimumQueue: Int, maximumQueue: Int,
                            burstDetails: String) {
            lock.lock()
            defer { lock.unlock() }
            return (sqrt(rawSquares / Double(max(frames, 1))),
                    sqrt(cleanSquares / Double(max(frames, 1))), frames,
                    falseNearChunks, falseNearBursts,
                    lowCoherence, mediumCoherence, weakCoherence,
                    referenceChunks, underflows,
                    minimumQueue == Int.max ? 0 : minimumQueue, maximumQueue,
                    nearBursts.joined(separator: ","))
        }
    }
}
