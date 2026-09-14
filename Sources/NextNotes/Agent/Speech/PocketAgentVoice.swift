import AVFoundation
import FluidAudio
import Observation

/// The model is fetched only after the user asks for it in Models settings.
@MainActor
@Observable
final class PocketAgentVoice {
    static let shared = PocketAgentVoice()

    private let manager = PocketTtsManager(precision: .int8)
    private(set) var isReady = false
    private(set) var isPreparing = false
    private(set) var errorMessage: String?

    func prepare() async {
        guard !isPreparing, !isReady else { return }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        do {
            try await manager.initialize()
            isReady = true
        } catch {
            errorMessage = error.localizedDescription
            Log.agent.error("Pocket TTS load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func frames(for text: String, voice: String)
        async throws -> AsyncThrowingStream<PocketTtsSynthesizer.AudioFrame, Error> {
        try await manager.synthesizeStreaming(text: text, voice: voice)
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
            var heardFirstFrame = false
            playback.onUtteranceStarted = { _ in heardFirstFrame = true }
            playback.speak("This is a playback and interruption check.", volume: 0, token: 1)
            for _ in 0..<150 where !heardFirstFrame {
                try await Task.sleep(for: .milliseconds(100))
            }
            let stoppedAt = ContinuousClock.now
            playback.stop()
            guard heardFirstFrame, !playback.isSpeaking,
                  stoppedAt.duration(to: .now) < .milliseconds(100) else {
                print("POCKET_TTS_FAILED: playback did not start or stop promptly")
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
    private var firstFramePlayed = false
    var onUtteranceStarted: ((UInt64) -> Void)?
    var onUtteranceFinished: ((UInt64) -> Void)?
    var onFailure: ((String, Float, UInt64) -> Void)?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    var isSpeaking: Bool { speaking }

    func speak(_ text: String, volume: Float, token: UInt64) {
        stop()
        generation = token
        speaking = true
        firstFramePlayed = false
        let voice = Settings.shared.agentPocketVoice
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                engine.mainMixerNode.outputVolume = max(0, min(1, volume))
                if !engine.isRunning { try engine.start() }
                player.play()
                let frames = try await PocketAgentVoice.shared.frames(for: text, voice: voice)
                for try await frame in frames {
                    try Task.checkCancellation()
                    guard generation == token else { return }
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
        speaking = false
        pendingFrames = 0
        producerFinished = false
    }

    private func framePlayed(token: UInt64) {
        guard generation == token, speaking, pendingFrames > 0 else { return }
        if !firstFramePlayed {
            firstFramePlayed = true
            onUtteranceStarted?(token)
        }
        pendingFrames -= 1
        finishIfDrained(token: token)
    }

    private func finishIfDrained(token: UInt64) {
        guard producerFinished, pendingFrames == 0, generation == token, speaking else { return }
        speaking = false
        task = nil
        onUtteranceFinished?(token)
    }
}
