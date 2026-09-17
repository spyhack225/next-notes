import AVFoundation
import FluidAudio
import Observation

/// The model is fetched only after the user asks for it in Models settings.
@MainActor
@Observable
final class PocketAgentVoice {
    static let shared = PocketAgentVoice()

    // Shared by the model-backed session probe to avoid loading a second
    // Pocket model on a 16 GB machine.
    let manager = PocketTtsManager(precision: .int8)
    private(set) var isReady = false
    private(set) var isPreparing = false
    private(set) var errorMessage: String?
    private var prepareTask: Task<Void, Never>?

    func prepare() async {
        if isReady { return }
        if let prepareTask { await prepareTask.value; return }
        isPreparing = true
        errorMessage = nil
        let pending = Task { @MainActor in
            do {
                try await manager.initialize()
                try await warmFirstPrediction()
                isReady = true
            } catch {
                errorMessage = error.localizedDescription
                Log.agent.error("Pocket TTS load failed: \(error.localizedDescription, privacy: .public)")
            }
            isPreparing = false
        }
        prepareTask = pending
        await pending.value
        prepareTask = nil
    }

    /// Loading CoreML models does not run their first prediction. The first
    /// actual Pocket frame otherwise arrives about 0.55 s after a clause is
    /// submitted, versus about 0.08 s after this warmup on this machine.
    /// No generated frame reaches the speaker or the playback ledger.
    private func warmFirstPrediction() async throws {
        let session = try await manager.makeSession(voice: Settings.shared.agentPocketVoice)
        session.enqueue("Ready.")
        let produced: Bool? = await withBoundedWait(.seconds(8)) {
            do {
                for try await frame in session.frames {
                    if frame.samples.contains(where: { abs($0) > 0.0001 }) { return true }
                }
            } catch { return false }
            return false
        }
        // cancel() waits for the native generator to stop using CoreML; a
        // real clause can never overlap this synthetic, unheard warmup.
        await session.cancel()
        guard produced == true else {
            throw PocketPlaybackError.emptyOutput
        }
    }

    func frames(for text: String, voice: String)
        async throws -> AsyncThrowingStream<PocketTtsSynthesizer.AudioFrame, Error> {
        // The one-time native warmup can be draining a cancelled CoreML call.
        // If it exceeds this caller's budget, fall back for this reply while
        // the prepare task keeps exclusive ownership until cancel() returns.
        let prepared: Void? = await withBoundedWait(.seconds(10)) { await self.prepare() }
        guard prepared != nil else { throw PocketPlaybackError.modelUnavailable("Pocket TTS is still preparing.") }
        guard isReady else { throw PocketPlaybackError.modelUnavailable(errorMessage) }
        return try await manager.synthesizeStreaming(text: text, voice: voice)
    }

    static func runSelfTest() async -> Bool {
        let voice = PocketAgentVoice.shared
        await voice.prepare()
        guard voice.isReady else {
            print("POCKET_TTS_FAILED: \(voice.errorMessage ?? "model did not load")")
            return false
        }
        do {
            let data = try await voice.manager.synthesize(
                text: "Hi, I'm Next. I can help you plan your day and find what matters.",
                voice: "alba"
            )
            guard data.count > 10_000, data.dropFirst(44).contains(where: { $0 != 0 }) else {
                print("POCKET_TTS_FAILED: no generated speech")
                return false
            }
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/NextNotesTTS", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sample = directory.appendingPathComponent("pocket-preview.wav")
            try data.write(to: sample, options: .atomic)
            let playback = PocketSpeechBacking()
            var started = 0
            var finished = 0
            var beganAt: Date?
            var finishedAt: Date?
            playback.onUtteranceStarted = { _ in
                started += 1
                if beganAt == nil { beganAt = Date() }
            }
            playback.onUtteranceFinished = { _ in
                finished += 1
                if finishedAt == nil { finishedAt = Date() }
            }
            playback.speak("Here is the first sentence.", volume: 0, token: 1)
            for _ in 0..<200 where finished == 0 {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard started == 1, finished == 1, !playback.isPlaybackEngineRunning,
                  let beganAt, let finishedAt,
                  finishedAt.timeIntervalSince(beganAt) > 0.25 else {
                playback.stop()
                print("POCKET_TTS_FAILED: first clause did not drain and stop its output engine")
                return false
            }
            playback.speak("Here is the next sentence.", volume: 0, token: 1)
            for _ in 0..<150 where started < 2 {
                try await Task.sleep(for: .milliseconds(100))
            }
            let stoppedAt = ContinuousClock.now
            playback.stop()
            guard started == 2, !playback.isSpeaking,
                  stoppedAt.duration(to: .now) < .milliseconds(100) else {
                print("POCKET_TTS_FAILED: second clause did not start or stop promptly")
                return false
            }
            print("Pocket TTS generated \(data.count) bytes at \(sample.path)")
            print("POCKET_TTS_OK")
            return true
        } catch {
            print("POCKET_TTS_FAILED: \(error.localizedDescription)")
            return false
        }
    }
}

/// Playback-only engine. A stopped generation cannot schedule another frame or
/// finish a newer utterance; the outer synthesizer still owns clause ordering.
@MainActor
final class PocketSpeechBacking: AgentSpeechBacking {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var pendingFrames = 0
    private var producerFinished = false
    private var speaking = false
    private var pausedForListening = false
    private var firstFramePlayed = false
    private var clauseSubmittedAt = Date.distantPast
    private var firstProducedAt: Date?
    private var firstProducedSamples = 0
    var onUtteranceStarted: ((UInt64) -> Void)?
    var onUtteranceFinished: ((UInt64) -> Void)?
    var onFailure: ((String, Float, UInt64) -> Void)?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        VoicePlaybackReference.install(on: engine)
    }

    var isSpeaking: Bool { speaking }
    var isPlaybackEngineRunning: Bool { engine.isRunning }

    func speak(_ text: String, volume: Float, token: UInt64) {
        // A drained clause can reuse the running engine even though each
        // clause now has a distinct callback token.
        let continuing = !speaking && producerFinished
            && pendingFrames == 0 && engine.isRunning
        if !continuing { stop() }
        generation = token
        speaking = true
        pausedForListening = false
        firstFramePlayed = false
        producerFinished = false
        clauseSubmittedAt = Date()
        firstProducedAt = nil
        firstProducedSamples = 0
        let submitted = String(format: "Pocket TTS clause submitted %.3f token=%llu characters=%d",
                               clauseSubmittedAt.timeIntervalSince1970, token, text.count)
        Log.agent.info("\(submitted, privacy: .public)")
        if CommandLine.arguments.contains("--selftest-voice-pipeline") { SelfTest.diagnostic(submitted) }
        let voice = Settings.shared.agentPocketVoice
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                engine.mainMixerNode.outputVolume = max(0, min(1, volume))
                if !engine.isRunning { try engine.start() }
                if !pausedForListening && !player.isPlaying { player.play() }
                let frames = try await PocketAgentVoice.shared.frames(for: text, voice: voice)
                for try await frame in frames {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    if firstProducedAt == nil {
                        let producedAt = Date()
                        firstProducedAt = producedAt
                        firstProducedSamples = frame.samples.count
                        let detail = String(format: "Pocket TTS first PCM %.3f token=%llu synthesis=%.3fs samples=%d",
                                            producedAt.timeIntervalSince1970, token,
                                            producedAt.timeIntervalSince(clauseSubmittedAt), firstProducedSamples)
                        Log.agent.info("\(detail, privacy: .public)")
                        if CommandLine.arguments.contains("--selftest-voice-pipeline") { SelfTest.diagnostic(detail) }
                    }
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                        frameCapacity: AVAudioFrameCount(frame.samples.count)),
                          let samples = buffer.floatChannelData?[0] else { continue }
                    buffer.frameLength = buffer.frameCapacity
                    for (index, sample) in frame.samples.enumerated() { samples[index] = sample }
                    pendingFrames += 1
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
                        [weak self] _ in
                        Task { @MainActor in self?.framePlayed(token: token) }
                    }
                }
                guard generation == token else { return }
                if !firstFramePlayed && pendingFrames == 0 {
                    throw PocketPlaybackError.emptyOutput
                }
                producerFinished = true
                finishIfDrained(token: token)
            } catch is CancellationError {
                // A newer reply or barge-in has already reset the player.
            } catch {
                guard generation == token else { return }
                Log.agent.error("Pocket TTS synthesis failed: \(error.localizedDescription, privacy: .public)")
                stop()
                onFailure?(text, volume, token)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player.stop()
        engine.stop()
        VoicePlaybackReference.stopped()
        speaking = false
        pausedForListening = false
        pendingFrames = 0
        producerFinished = false
    }

    func pauseForListening() {
        guard speaking, !pausedForListening else { return }
        pausedForListening = true
        if player.isPlaying { player.pause() }
    }

    func resumeAfterListening() {
        guard speaking, pausedForListening else { return }
        pausedForListening = false
        if pendingFrames > 0 && !player.isPlaying { player.play() }
    }

    private func framePlayed(token: UInt64) {
        guard generation == token, speaking, pendingFrames > 0 else { return }
        if !firstFramePlayed {
            firstFramePlayed = true
            let playedAt = Date()
            let synthesis = firstProducedAt?.timeIntervalSince(clauseSubmittedAt) ?? -1
            let render = firstProducedAt.map { playedAt.timeIntervalSince($0) } ?? -1
            let detail = String(format: "Pocket TTS first played %.3f token=%llu synthesis=%.3fs render=%.3fs firstSamples=%d",
                                playedAt.timeIntervalSince1970, token, synthesis, render, firstProducedSamples)
            Log.agent.info("\(detail, privacy: .public)")
            if CommandLine.arguments.contains("--selftest-voice-pipeline") { SelfTest.diagnostic(detail) }
            // The callback acknowledges the first complete output buffer.
            // This deliberately overstates onset latency by that buffer's
            // duration; scheduling a buffer is not a playback observation.
            onUtteranceStarted?(token)
        }
        pendingFrames -= 1
        finishIfDrained(token: token)
    }

    private func finishIfDrained(token: UInt64) {
        guard producerFinished, pendingFrames == 0, generation == token, speaking else { return }
        speaking = false
        pausedForListening = false
        task = nil
        player.stop()
        engine.stop()
        VoicePlaybackReference.stopped()
        onUtteranceFinished?(token)
    }
}

private enum PocketPlaybackError: LocalizedError {
    case emptyOutput
    case modelUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .emptyOutput: "Pocket TTS generated no playable audio frames."
        case .modelUnavailable(let reason): reason ?? "Pocket TTS model did not load."
        }
    }
}
