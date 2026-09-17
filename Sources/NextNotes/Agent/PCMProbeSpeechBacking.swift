import AVFoundation
import Foundation

/// Self-test-only speech backing that feeds one known WAV through the actual
/// source-node renderer. It deliberately ignores the utterance text: the
/// acoustic probe measures a fixed far waveform, not speech synthesis.
@MainActor
final class PCMProbeSpeechBacking: AgentSpeechBacking {
    private let renderer = AgentPCMRenderer.shared
    private let samples: [Float]
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var speaking = false
    private var paused = false
    private var prepared = false
    private var currentText = ""
    private var currentVolume: Float = 1
    private(set) var sourceFailure: String?

    var onUtteranceStarted: ((UInt64) -> Void)?
    var onUtteranceFinished: ((UInt64) -> Void)?
    var onFailure: ((String, Float, UInt64) -> Void)?

    init(farURL: URL) throws {
        let file = try AVAudioFile(forReading: farURL)
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / max(sampleRate, 1)
        guard duration >= 3, duration <= 25 else {
            throw ProbeError.invalidDuration
        }
        let capacity = AVAudioFrameCount(file.length)
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: capacity) else {
            throw ProbeError.invalidFormat
        }
        try file.read(into: source)
        guard source.frameLength > 0 else {
            throw ProbeError.invalidFormat
        }
        let converted: AVAudioPCMBuffer
        if source.format == AgentPCMRenderer.sourceFormat {
            converted = source
        } else {
            guard let converter = AVAudioConverter(from: source.format,
                                                   to: AgentPCMRenderer.sourceFormat),
                  let output = AudioConversion.convert(source,
                                                        to: AgentPCMRenderer.sourceFormat,
                                                        using: converter) else {
                throw ProbeError.invalidFormat
            }
            converted = output
        }
        guard let channel = converted.floatChannelData?[0] else {
            throw ProbeError.invalidFormat
        }
        samples = Array(UnsafeBufferPointer(start: channel,
                                             count: Int(converted.frameLength)))
        guard samples.count >= 16_000 * 3,
              samples.count <= 16_000 * 25 else {
            throw ProbeError.invalidDuration
        }
    }

    var isSpeaking: Bool { speaking }

    /// Starts the real renderer before the hybrid probe subscribes to capture.
    func prepare() throws {
        guard SelfTest.isRunning else { throw ProbeError.notSelfTest }
        guard !prepared else { return }
        renderer.onFirstSample = { [weak self] token in
            self?.firstSample(token: token)
        }
        renderer.onDrained = { [weak self] token in
            self?.drained(token: token)
        }
        renderer.onFailure = { [weak self] token, reason in
            self?.rendererFailed(token: token, reason: reason)
        }
        do {
            try renderer.startSession()
            prepared = true
        } catch {
            renderer.endSession()
            renderer.onFirstSample = nil
            renderer.onDrained = nil
            renderer.onFailure = nil
            throw error
        }
    }

    func endTest() {
        stop()
        guard prepared else { return }
        renderer.onFirstSample = nil
        renderer.onDrained = nil
        renderer.onFailure = nil
        renderer.endSession()
        prepared = false
        sourceFailure = nil
    }

    func speak(_ text: String, volume: Float, token: UInt64) {
        guard prepared, token != 0 else {
            onFailure?(text, volume, token)
            return
        }
        stop()
        generation = token
        currentText = text
        currentVolume = volume
        sourceFailure = nil
        speaking = true
        paused = false
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: AgentPCMRenderer.sourceFormat,
                                            frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            speaking = false
            generation = 0
            onFailure?(text, volume, token)
            return
        }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await renderer.enqueue(buffer, token: token, volume: volume)
                try Task.checkCancellation()
                guard generation == token else { return }
                renderer.finish(token: token)
            } catch {
                // Renderer deadlines and graph failures are reported; only
                // explicit producer cancellation is silent.
                guard !Task.isCancelled else { return }
                guard generation == token else { return }
                let reason = Self.bounded(error.localizedDescription)
                sourceFailure = reason
                Log.agent.error("PCM probe sourceFailure token=\(token, privacy: .public) reason=\(reason, privacy: .public)")
                renderer.stop(token: token)
                generation = 0
                speaking = false
                paused = false
                onFailure?(text, volume, token)
            }
        }
    }

    func pauseForListening() {
        guard speaking, !paused, generation != 0 else { return }
        paused = true
        renderer.pause(token: generation)
    }

    func resumeAfterListening() {
        guard speaking, paused, generation != 0 else { return }
        paused = false
        renderer.resume(token: generation)
    }

    func stop() {
        task?.cancel()
        task = nil
        let token = generation
        generation = 0
        speaking = false
        paused = false
        currentText = ""
        currentVolume = 1
        if token != 0 { renderer.stop(token: token) }
    }

    private func firstSample(token: UInt64) {
        guard generation == token else { return }
        onUtteranceStarted?(token)
    }

    private func drained(token: UInt64) {
        guard generation == token else { return }
        speaking = false
        paused = false
        currentText = ""
        currentVolume = 1
        onUtteranceFinished?(token)
    }

    private func rendererFailed(token rendererToken: UInt64, reason: String) {
        guard generation == rendererToken else { return }
        let text = currentText
        let volume = currentVolume
        sourceFailure = Self.bounded(reason)
        let boundedReason = sourceFailure ?? "renderer failure"
        Log.agent.error("PCM probe sourceFailure token=\(rendererToken, privacy: .public) reason=\(boundedReason, privacy: .public)")
        task?.cancel()
        task = nil
        generation = 0
        speaking = false
        paused = false
        currentText = ""
        currentVolume = 1
        onFailure?(text, volume, rendererToken)
    }

    private static func bounded(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return String(String.UnicodeScalarView(scalars.prefix(160)))
    }

    private enum ProbeError: LocalizedError {
        case invalidDuration
        case invalidFormat
        case notSelfTest

        var errorDescription: String? {
            switch self {
            case .invalidDuration: "Probe WAV must be between 3 and 25 seconds."
            case .invalidFormat: "Probe WAV could not be converted to 16 kHz mono PCM."
            case .notSelfTest: "PCM probe backing is restricted to self-tests."
            }
        }
    }
}
