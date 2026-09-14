import AVFoundation
import Foundation

/// Hardware measurement, not a unit test. Run through LaunchServices so the
/// signed app, rather than Terminal, owns the microphone permission:
/// `open -n -a 'Next Notes' --args --selftest-acoustic-measure /tmp/probe.aiff --selftest-out /tmp/aec.txt`
/// The same file is played at the same mixer gain for each condition.
@MainActor
enum AcousticEchoProbe {
    struct Measurement {
        let baseline: Double
        let playback: Double
        let frames: Int

        var excess: Double {
            sqrt(max(0, playback * playback - baseline * baseline))
        }

        var description: String {
            String(
                format: "baseline %.5f, playback %.5f, excess %.5f, %d frames",
                baseline, playback, excess, frames
            )
        }
    }

    enum ProbeError: LocalizedError {
        case missingMicrophone
        case noInputFrames
        case noPlaybackEvidence
        case sampleTooLong
        case operation(String, String)

        var errorDescription: String? {
            switch self {
            case .missingMicrophone: "Microphone permission is required for the acoustic measurement."
            case .noInputFrames: "The microphone tap delivered no samples."
            case .noPlaybackEvidence: "Raw capture did not measure speaker bleed above the room baseline."
            case .sampleTooLong: "Use a speech sample shorter than 10 seconds."
            case let .operation(stage, reason): "\(stage): \(reason)"
            }
        }
    }

    static func run(fileURL: URL) async throws -> String {
        guard await Permissions.requestMicrophone() else { throw ProbeError.missingMicrophone }
        let file = try AVAudioFile(forReading: fileURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 0, duration <= 10 else { throw ProbeError.sampleTooLong }

        let raw = try await measure(fileURL: fileURL, voiceProcessing: false, sameGraph: true)
        guard raw.frames > 0 else {
            throw ProbeError.noInputFrames
        }
        // This is a measurement of cancellation only if the untreated microphone
        // demonstrably heard the speaker. Quiet playback/headphones cannot pass.
        guard raw.excess > max(0.001, raw.baseline * 1.5) else {
            throw ProbeError.noPlaybackEvidence
        }
        func voiceProcessingResult(sameGraph: Bool) async -> String {
            let label = sameGraph ? "same graph VP" : "separate output VP"
            do {
                let measured = try await measure(
                    fileURL: fileURL,
                    voiceProcessing: true,
                    sameGraph: sameGraph
                )
                guard measured.frames > 0 else { return "\(label) {no microphone frames}" }
                let attenuation = 20 * log10(raw.excess / max(0.000001, measured.excess))
                return "\(label) {\(measured.description), mic attenuation \(String(format: "%.1f dB", attenuation))}"
            } catch {
                return "\(label) {unavailable: \(error.localizedDescription)}"
            }
        }
        let managed = await voiceProcessingResult(sameGraph: true)
        let separate = await voiceProcessingResult(sameGraph: false)
        return "raw {\(raw.description)}; \(managed); \(separate); physical speaker level unmeasured"
    }

    private static func measure(
        fileURL: URL,
        voiceProcessing: Bool,
        sameGraph: Bool
    ) async throws -> Measurement {
        let inputEngine = AVAudioEngine()
        if voiceProcessing {
            // Apple requires the engine to be stopped while changing this mode.
            do {
                try inputEngine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                throw ProbeError.operation("enable voice processing", error.localizedDescription)
            }
        }
        let outputEngine = sameGraph ? inputEngine : AVAudioEngine()
        let player = AVAudioPlayerNode()
        outputEngine.attach(player)
        let file = try AVAudioFile(forReading: fileURL)
        outputEngine.connect(player, to: outputEngine.mainMixerNode, format: file.processingFormat)
        outputEngine.mainMixerNode.outputVolume = 0.65

        let meter = AcousticProbeMeter()
        let input = inputEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: format,
            block: makeTapCallback(meter: meter)
        )
        defer {
            player.stop()
            input.removeTap(onBus: 0)
            if !sameGraph { outputEngine.stop() }
            inputEngine.stop()
        }
        do { try inputEngine.start() } catch {
            throw ProbeError.operation("start input engine", error.localizedDescription)
        }
        if !sameGraph {
            do { try outputEngine.start() } catch {
                throw ProbeError.operation("start separate output engine", error.localizedDescription)
            }
        }

        meter.reset()
        try await Task.sleep(for: .seconds(1))
        let baseline = meter.take()

        player.scheduleFile(file, at: nil, completionHandler: {})
        player.play()
        let duration = Double(file.length) / file.processingFormat.sampleRate
        try await Task.sleep(for: .milliseconds(Int((duration + 0.25) * 1000)))
        let playback = meter.take()
        return Measurement(
            baseline: baseline.rms,
            playback: playback.rms,
            frames: playback.frames
        )
    }

    /// `installTap` invokes this off the main actor. Forming the closure inside
    /// `measure` would inherit MainActor and trap on the first audio buffer.
    nonisolated private static func makeTapCallback(
        meter: AcousticProbeMeter
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in meter.add(buffer) }
    }
}

private final class AcousticProbeMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSquares: Double = 0
    private var frames = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let stride = buffer.stride
        var sum = 0.0
        for index in 0..<count {
            let value = Double(channel[index * stride])
            sum += value * value
        }
        lock.lock()
        sumSquares += sum
        frames += count
        lock.unlock()
    }

    func reset() { _ = take() }

    func take() -> (rms: Double, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        let result = (sqrt(sumSquares / Double(max(1, frames))), frames)
        sumSquares = 0
        frames = 0
        return result
    }
}
