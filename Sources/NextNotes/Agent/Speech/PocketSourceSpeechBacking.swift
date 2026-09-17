import AVFoundation
import Foundation
import FluidAudio

/// Pocket TTS playback through the shared source-node renderer.
///
/// Pocket produces 24 kHz mono `Float` frames. Those frames are handed to
/// `AgentPCMRenderer` unchanged; the renderer owns conversion to its 16 kHz
/// source format and the reverse-stream copy used by acoustic processing.
/// The renderer graph is kept alive between clauses in one prepared session.
@MainActor
final class PocketSourceSpeechBacking: AgentSpeechBacking {
    private let renderer = AgentPCMRenderer.shared
    private let pocketFormat = AVAudioFormat(
        standardFormatWithSampleRate: 24_000,
        channels: 1
    )!

    private var task: Task<Void, Never>?
    private var prepared = false
    private var speaking = false
    private var pausedForListening = false
    private var currentText = ""
    private var currentVolume: Float = 1
    private(set) var sourceFailure: String?

    /// The renderer token is deliberately independent of the synthesizer's
    /// caller token. Callers may reuse their token (the voice self-tests do),
    /// while renderer callbacks can arrive after a prior clause was stopped.
    private var generationCounter: UInt64 = 0
    private var generation: UInt64 = 0
    private var callerToken: UInt64 = 0

    var onUtteranceStarted: ((UInt64) -> Void)?
    var onUtteranceFinished: ((UInt64) -> Void)?
    var onFailure: ((String, Float, UInt64) -> Void)?

    var isSpeaking: Bool { speaking }

    /// Starts the source-node graph once for the lifetime of a voice session.
    /// Root owns the session boundary and should call `endSession()` when the
    /// voice session is no longer needed.
    func prepare() throws {
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
            // Do not leave callbacks installed on a graph that failed to
            // start. `endSession` also stops any partially created graph.
            renderer.onFirstSample = nil
            renderer.onDrained = nil
            renderer.onFailure = nil
            renderer.endSession()
            throw error
        }
    }

    /// Cancels the current producer, detaches receipt callbacks, and tears
    /// down the source-node graph. Callback removal precedes teardown because
    /// a receipt poll may already be queued on the main actor.
    func endSession() {
        stop()
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
        let rendererToken = nextGeneration()
        generation = rendererToken
        callerToken = token
        currentText = text
        currentVolume = volume
        sourceFailure = nil
        speaking = true
        pausedForListening = false

        let voice = Settings.shared.agentPocketVoice
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let frames = try await PocketAgentVoice.shared.frames(
                    for: text,
                    voice: voice
                )
                var enqueuedBuffers = 0

                for try await frame in frames {
                    try Task.checkCancellation()
                    guard generation == rendererToken else { return }

                    let sampleCount = frame.samples.count
                    // Empty frames do not establish that the stream produced
                    // playable audio and must not be sent to the converter.
                    guard sampleCount > 0 else { continue }
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: pocketFormat,
                        frameCapacity: AVAudioFrameCount(sampleCount)
                    ), let samples = buffer.floatChannelData?[0] else {
                        throw PocketSourcePlaybackError.bufferAllocationFailed
                    }
                    buffer.frameLength = AVAudioFrameCount(sampleCount)
                    frame.samples.withUnsafeBufferPointer { source in
                        samples.update(
                            from: source.baseAddress!,
                            count: sampleCount
                        )
                    }

                    // AgentPCMRenderer bounds both its token handshake and
                    // ring backpressure. Renderer failures reach the catch
                    // below unless this producer task was explicitly
                    // cancelled by stop().
                    try await renderer.enqueue(
                        buffer,
                        token: rendererToken,
                        volume: volume
                    )
                    enqueuedBuffers += 1
                }

                guard generation == rendererToken else { return }
                guard enqueuedBuffers > 0 else {
                    throw PocketSourcePlaybackError.emptyOutput
                }

                renderer.finish(token: rendererToken)
            } catch {
                if Task.isCancelled {
                    // `stop()` already invalidates the renderer generation in
                    // the normal path. Clean up here too for task cancellation
                    // that arrives without a synchronous stop call, while
                    // never reporting a late failure.
                    if generation == rendererToken {
                        renderer.stop(token: rendererToken)
                        generation = 0
                        callerToken = 0
                        speaking = false
                        pausedForListening = false
                        task = nil
                    }
                    return
                }
                guard generation == rendererToken else { return }
                let reason = Self.bounded(error.localizedDescription)
                sourceFailure = reason
                Log.agent.error("Pocket sourceFailure token=\(rendererToken, privacy: .public) reason=\(reason, privacy: .public)")
                renderer.stop(token: rendererToken)
                let failedCallerToken = callerToken
                generation = 0
                callerToken = 0
                speaking = false
                pausedForListening = false
                task = nil
                onFailure?(text, volume, failedCallerToken)
            }
        }
    }

    func pauseForListening() {
        guard speaking, !pausedForListening, generation != 0 else { return }
        pausedForListening = true
        renderer.pause(token: generation)
    }

    func resumeAfterListening() {
        guard speaking, pausedForListening, generation != 0 else { return }
        pausedForListening = false
        renderer.resume(token: generation)
    }

    func stop() {
        task?.cancel()
        task = nil

        let token = generation
        generation = 0
        callerToken = 0
        speaking = false
        pausedForListening = false
        currentText = ""
        currentVolume = 1
        if token != 0 {
            renderer.stop(token: token)
        }
    }

    private func nextGeneration() -> UInt64 {
        generationCounter &+= 1
        if generationCounter == 0 { generationCounter = 1 }
        return generationCounter
    }

    private func firstSample(token: UInt64) {
        guard generation == token, speaking else { return }
        onUtteranceStarted?(callerToken)
    }

    private func drained(token: UInt64) {
        guard generation == token, speaking else { return }
        let finishedCallerToken = callerToken
        generation = 0
        callerToken = 0
        speaking = false
        pausedForListening = false
        task = nil
        onUtteranceFinished?(finishedCallerToken)
    }

    private func rendererFailed(token rendererToken: UInt64, reason: String) {
        guard generation == rendererToken, speaking else { return }
        let failedCallerToken = callerToken
        let text = currentText
        let volume = currentVolume
        sourceFailure = Self.bounded(reason)
        let boundedReason = sourceFailure ?? "graph failure"
        Log.agent.error("Pocket sourceFailure token=\(rendererToken, privacy: .public) reason=\(boundedReason, privacy: .public)")
        task?.cancel()
        task = nil
        generation = 0
        callerToken = 0
        speaking = false
        pausedForListening = false
        currentText = ""
        currentVolume = 1
        onFailure?(text, volume, failedCallerToken)
    }

    private static func bounded(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return String(String.UnicodeScalarView(scalars.prefix(160)))
    }
}

private enum PocketSourcePlaybackError: LocalizedError {
    case emptyOutput
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .emptyOutput:
            "Pocket TTS generated no playable audio frames."
        case .bufferAllocationFailed:
            "Unable to allocate a PCM buffer for Pocket TTS output."
        }
    }
}
