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
final class KokoroSpeechBacking: NSObject, AgentSpeechBacking, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var speaking = false
    private var currentText = ""
    private var currentVolume: Float = 1
    var onUtteranceStarted: ((UInt64) -> Void)?
    var onUtteranceFinished: ((UInt64) -> Void)?
    var onFailure: ((String, Float, UInt64) -> Void)?

    var isSpeaking: Bool { speaking }

    func speak(_ text: String, volume: Float, token: UInt64) {
        stop()
        generation = token
        speaking = true
        currentText = text
        currentVolume = volume
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await KokoroAgentVoice.shared.wav(for: text)
                try Task.checkCancellation()
                guard generation == token else { return }
                let audio = try AVAudioPlayer(data: data)
                audio.delegate = self
                audio.volume = max(0, min(1, volume))
                audio.prepareToPlay()
                guard audio.play() else { throw KokoroVoiceError.unavailable("Kokoro playback could not start.") }
                player = audio
                onUtteranceStarted?(token)
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
        player?.stop()
        player?.delegate = nil
        player = nil
        speaking = false
        currentText = ""
        generation &+= 1
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == identifier else { return }
            let token = self.generation
            let text = self.currentText
            let volume = self.currentVolume
            self.player = nil
            self.speaking = false
            self.currentText = ""
            if flag { self.onUtteranceFinished?(token) }
            else { self.onFailure?(text, volume, token) }
        }
    }
}
