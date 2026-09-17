import AVFoundation
import Foundation

/// Signed-app gate for the source-node reference producer. This deliberately
/// bypasses every existing voice backing until exact rendered PCM, honest
/// playback receipts and acoustic suppression pass on real speakers.
@MainActor
enum AgentPCMSourceProbe {
    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = 0.0
        private var cleaned = 0.0
        private var frames = 0
        func add(_ original: AVAudioPCMBuffer, _ processed: AVAudioPCMBuffer) {
            guard let a = original.floatChannelData?[0],
                  let b = processed.floatChannelData?[0] else { return }
            let count = min(Int(original.frameLength), Int(processed.frameLength))
            var r = 0.0, c = 0.0
            for i in 0..<count { r += Double(a[i] * a[i]); c += Double(b[i] * b[i]) }
            lock.lock()
            raw += r; cleaned += c; frames += count
            lock.unlock()
        }
        func take() -> (raw: Double, cleaned: Double, frames: Int) {
            lock.lock()
            defer { lock.unlock() }
            let result = (sqrt(raw / Double(max(frames, 1))),
                          sqrt(cleaned / Double(max(frames, 1))), frames)
            raw = 0; cleaned = 0; frames = 0
            return result
        }
    }

    static func run(farURL: URL) async -> (Bool, String) {
        guard await AgentPCMRenderer.runReverseCallbackIsolationSelfTest() else {
            return (false, "PCM_SOURCE_FAILED: off-main reference callback did not drain")
        }
        guard await Permissions.requestMicrophone(),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000, channels: 1, interleaved: false) else {
            return (false, "PCM_SOURCE_FAILED: microphone permission or format missing")
        }
        let renderer = AgentPCMRenderer.shared
        let seat = AudioCaptureHub.Consumer.client(UUID())
        let meter = Meter()
        AcousticEchoProcessor.shared.reset()
        guard AcousticEchoProcessor.shared.backendAvailable else {
            return (false, "PCM_SOURCE_FAILED: selected AEC3 bridge unavailable")
        }
        do {
            try renderer.startSession()
            try AudioCaptureHub.shared.subscribe(seat, outputFormat: mono,
                onBuffer: { original in
                    let cleaned = AcousticEchoProcessor.shared.process(original)
                    meter.add(original.buffer, cleaned.buffer)
                })
            defer {
                AudioCaptureHub.shared.unsubscribe(seat)
                renderer.endSession()
            }
            let file = try AVAudioFile(forReading: farURL)
            guard file.length > AVAudioFramePosition(file.processingFormat.sampleRate * 3),
                  file.length < AVAudioFramePosition(file.processingFormat.sampleRate * 25),
                  let audio = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                              frameCapacity: AVAudioFrameCount(file.length)) else {
                return (false, "PCM_SOURCE_FAILED: requires 3–25s speech WAV")
            }
            try file.read(into: audio)
            try await Task.sleep(for: .seconds(1))
            let baseline = meter.take()
            var first = false, drained = false
            renderer.onFirstSample = { if $0 == 1 { first = true } }
            renderer.onDrained = { if $0 == 1 { drained = true } }
            try await renderer.enqueue(audio, token: 1, volume: 0.75)
            renderer.finish(token: 1)
            for _ in 0..<300 where !drained {
                try await Task.sleep(for: .milliseconds(100))
            }
            let playback = meter.take()
            let reference = AcousticEchoProcessor.shared.referenceSnapshot()
            let rawEcho = sqrt(max(0, playback.raw * playback.raw - baseline.raw * baseline.raw))
            let cleanedEcho = playback.cleaned <= baseline.cleaned ? playback.cleaned
                : sqrt(max(0, playback.cleaned * playback.cleaned
                          - baseline.cleaned * baseline.cleaned))
            let attenuation = 20 * log10(rawEcho / max(cleanedEcho, 1e-8))
            let passed = first && drained && baseline.frames > 8_000
                && playback.frames > 32_000 && rawEcho > max(0.002, baseline.raw * 1.5)
                && reference.frames > 16_000 && reference.rms > 0.005
                && renderer.referenceOverflowSamples == 0 && attenuation >= 10
            return (passed, String(format:
                "PCM_SOURCE_%@: first=%@ drained=%@ raw %.5f→%.5f cleaned %.5f→%.5f; rendered %.5f/%d frames, consumed %d, reverse overflow %d; conservative attenuation %.1f dB; timing %@; human double-talk unmeasured",
                passed ? "OK" : "FAILED", first.description, drained.description,
                baseline.raw, playback.raw, baseline.cleaned, playback.cleaned,
                reference.rms, reference.frames, renderer.renderedSampleCount,
                renderer.referenceOverflowSamples, attenuation,
                AcousticEchoProcessor.shared.timingSnapshot()))
        } catch {
            renderer.endSession()
            return (false, "PCM_SOURCE_FAILED: \(error.localizedDescription)")
        }
    }
}
