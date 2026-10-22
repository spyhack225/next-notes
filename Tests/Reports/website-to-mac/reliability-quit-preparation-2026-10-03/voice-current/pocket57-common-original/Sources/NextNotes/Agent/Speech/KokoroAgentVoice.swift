import AVFoundation
import FluidAudio
import Observation

/// Optional English Kokoro 82M voice through FluidAudio's seven-stage Core ML chain.
/// macOS 26.4–26.5 can crash inside Apple BNNS during synthesis, so this backend
/// must not even try to generate there. The downloaded ONNX benchmark is unrelated.
@MainActor
@Observable
final class KokoroAgentVoice {
    static let shared = KokoroAgentVoice()
    static let voiceName = "Heart"
    static let voiceID = "af_heart"

    static var isSupportedOS: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion != 26 || version.minorVersion < 4 || version.minorVersion >= 6
    }

    nonisolated static let unavailableMessage =
        "Kokoro needs macOS 26.6 or later on this Mac. Core ML can crash on 26.5."

    private let manager = KokoroAneManager()
    private(set) var isReady = false
    private(set) var isPreparing = false
    private(set) var errorMessage: String?

    func prepare() async {
        guard Self.isSupportedOS else {
            errorMessage = Self.unavailableMessage
            return
        }
        if isReady { return }
        if isPreparing {
            while isPreparing && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return
        }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        do {
            try await manager.initialize()
            isReady = true
        } catch {
            errorMessage = error.localizedDescription
            Log.agent.error("Kokoro TTS load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func wav(for text: String) async throws -> Data {
        guard Self.isSupportedOS else { throw KokoroVoiceError.unsupportedOS }
        if !isReady { await prepare() }
        guard isReady else { throw KokoroVoiceError.unavailable(errorMessage) }
        return try await manager.synthesize(text: text, voice: Self.voiceID)
    }

    static func runSelfTest() async -> Bool {
        guard isSupportedOS else {
            print("KOKORO_TTS_FAILED: \(unavailableMessage)")
            return false
        }
        let voice = shared
        await voice.prepare()
        guard voice.isReady else {
            print("KOKORO_TTS_FAILED: \(voice.errorMessage ?? "model did not load")")
            return false
        }
        do {
            for sentence in ["Hello from Next Notes.", "This is a second Kokoro voice check."] {
                let data = try await voice.wav(for: sentence)
                guard data.count > 10_000, data.dropFirst(44).contains(where: { $0 != 0 }) else {
                    print("KOKORO_TTS_FAILED: no generated speech")
                    return false
                }
            }
            let backing = KokoroSpeechBacking()
            var started = false
            backing.onUtteranceStarted = { _ in started = true }
            backing.speak("Testing Kokoro playback.", volume: 0, token: 1)
            for _ in 0..<150 where !started { try await Task.sleep(for: .milliseconds(100)) }
            let stoppedAt = ContinuousClock.now
            backing.stop()
            guard started, !backing.isSpeaking,
                  stoppedAt.duration(to: .now) < .milliseconds(100) else {
                print("KOKORO_TTS_FAILED: playback did not start or stop promptly")
                return false
            }
            print("KOKORO_TTS_OK")
            return true
        } catch {
            print("KOKORO_TTS_FAILED: \(error.localizedDescription)")
            return false
        }
    }
}

private enum KokoroVoiceError: LocalizedError {
    case unsupportedOS
    case unavailable(String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: KokoroAgentVoice.unavailableMessage
        case .unavailable(let message): message ?? "Kokoro could not load."
        }
    }
}

/// Kokoro returns a PCM WAV; AVAudioPlayer keeps it in-process and can be
/// stopped immediately when the user interrupts. The token guards late model
/// completions so they cannot speak over a newer Agent turn.
@MainActor
final class KokoroSpeechBacking: NSObject, AgentSpeechBacking {
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var speaking = false
    private var pausedForListening = false
    private var currentText = ""
    private var currentVolume: Float = 1
    private var temporaryWAV: URL?
    var onUtteranceStarted: ((UInt64) -> Void)?
    var onUtteranceFinished: ((UInt64) -> Void)?
    var onFailure: ((String, Float, UInt64) -> Void)?

    var isSpeaking: Bool { speaking }

    override init() {
        super.init()
        playbackEngine.attach(player)
        playbackEngine.connect(player, to: playbackEngine.mainMixerNode,
                               format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)
        VoicePlaybackReference.install(on: playbackEngine)
    }

    func speak(_ text: String, volume: Float, token: UInt64) {
        stop()
        generation = token
        speaking = true
        pausedForListening = false
        currentText = text
        currentVolume = volume
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await KokoroAgentVoice.shared.wav(for: text)
                try Task.checkCancellation()
                guard generation == token else { return }
                let path = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nextnotes-kokoro-\(UUID().uuidString).wav")
                try data.write(to: path, options: .atomic)
                temporaryWAV = path
                let file = try AVAudioFile(forReading: path)
                guard file.length > 0, file.length <= AVAudioFramePosition(UInt32.max),
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: AVAudioFrameCount(file.length)
                      ) else { throw KokoroVoiceError.unavailable("Kokoro returned no playable samples.") }
                try file.read(into: buffer)
                playbackEngine.connect(player, to: playbackEngine.mainMixerNode,
                                       format: file.processingFormat)
                playbackEngine.mainMixerNode.outputVolume = max(0, min(1, volume))
                if !playbackEngine.isRunning { try playbackEngine.start() }
                let firstLength = min(Int(buffer.frameLength),
                                      max(1, Int(file.processingFormat.sampleRate / 50)))
                guard let first = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(firstLength)),
                      let source = buffer.floatChannelData,
                      let target = first.floatChannelData else {
                    throw KokoroVoiceError.unavailable("Kokoro PCM format unsupported.")
                }
                first.frameLength = AVAudioFrameCount(firstLength)
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    target[channel].update(from: source[channel], count: firstLength)
                }
                let remaining = Int(buffer.frameLength) - firstLength
                player.scheduleBuffer(first, completionCallbackType: .dataPlayedBack) {
                    [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.speaking else { return }
                        self.onUtteranceStarted?(token)
                        if remaining == 0 { self.finishPlayback(token: token) }
                    }
                }
                if remaining > 0 {
                    guard let rest = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: AVAudioFrameCount(remaining)
                    ), let restChannels = rest.floatChannelData else {
                        throw KokoroVoiceError.unavailable("Kokoro PCM buffer unavailable.")
                    }
                    rest.frameLength = AVAudioFrameCount(remaining)
                    for channel in 0..<Int(file.processingFormat.channelCount) {
                        restChannels[channel].update(from: source[channel] + firstLength,
                                                     count: remaining)
                    }
                    player.scheduleBuffer(rest, completionCallbackType: .dataPlayedBack) {
                        [weak self] _ in
                        Task { @MainActor in self?.finishPlayback(token: token) }
                    }
                }
                if !pausedForListening { player.play() }
            } catch is CancellationError {
                // A newer reply or barge-in owns playback now.
            } catch {
                guard generation == token else { return }
                Log.agent.error("Kokoro TTS synthesis failed: \(error.localizedDescription, privacy: .public)")
                stop()
                onFailure?(text, volume, token)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player.stop()
        playbackEngine.stop()
        VoicePlaybackReference.stopped()
        if let temporaryWAV { try? FileManager.default.removeItem(at: temporaryWAV) }
        temporaryWAV = nil
        speaking = false
        pausedForListening = false
        currentText = ""
        generation &+= 1
    }

    func pauseForListening() {
        guard speaking, !pausedForListening else { return }
        pausedForListening = true
        if player.isPlaying { player.pause() }
    }

    func resumeAfterListening() {
        guard speaking, pausedForListening else { return }
        pausedForListening = false
        if playbackEngine.isRunning && !player.isPlaying { player.play() }
    }

    private func finishPlayback(token: UInt64) {
        guard generation == token, speaking else { return }
        speaking = false
        pausedForListening = false
        player.stop()
        playbackEngine.stop()
        VoicePlaybackReference.stopped()
        currentText = ""
        if let temporaryWAV { try? FileManager.default.removeItem(at: temporaryWAV) }
        temporaryWAV = nil
        onUtteranceFinished?(token)
    }
}
