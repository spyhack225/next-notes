import AVFoundation
import CryptoKit
import Foundation

/// Bounded Pocket/Kokoro PCM in the TTS's existing preview cache, never turn-time synthesis.
@MainActor
final class VoiceAcknowledgementClips {
    static let shared = VoiceAcknowledgementClips()
    static let texts = ["Mm.", "Okay."]
    struct Selection: Equatable, Sendable {
        let engine: String
        let voice: String
        @MainActor static var current: Selection {
            if VoiceAcknowledgementClips.shared.permitsFixture,
               let fixture = VoiceAcknowledgementClips.shared.renderFixture { return fixture.selection }
            let engine = SelfTest.isRunning
                ? (AgentSpeechSynthesizer.shared.engineOverrideForTesting ?? Settings.shared.agentVoiceEngine)
                : Settings.shared.agentVoiceEngine
            return Selection(engine: engine, voice: engine == "pocket"
                ? Settings.shared.agentPocketVoice : KokoroAgentVoice.voiceID)
        }
        @MainActor var ready: Bool {
            if VoiceAcknowledgementClips.shared.permitsFixture,
               let fixture = VoiceAcknowledgementClips.shared.renderFixture,
               fixture.selection == self { return fixture.ready }
            return switch engine {
            case "pocket": PocketAgentVoice.shared.isReady
            case "kokoro": KokoroAgentVoice.isSupportedOS && KokoroAgentVoice.shared.isReady
            default: false
            }
        }
        var key: String {
            SHA256.hash(data: Data("ack-v1/\(engine)/\(voice)".utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Clip {
        let text: String
        /// Pre-split at 10ms so dataPlayedBack acknowledges first audio, not clip end.
        let buffers: [AVAudioPCMBuffer]
    }
    private(set) var selection: Selection?
    private var clips: [Clip] = []
    private var last: Int?
    private var cursor = 0
    private var task: Task<Void, Never>?
    private var generation = 0
    private var terminating = false
    private var harnessDirectory: URL?
    private var permitsFixture: Bool {
        SelfTest.isRunning && SelfTest.requested == "--selftest-voice-latency"
            && CommandLine.arguments.contains("--voice-latency-ack-policy")
    }
    private var renderFixture: (selection: Selection, ready: Bool,
        render: @MainActor (String, Selection) async throws -> LongFormRenderer.Audio)?
    func setRenderFixture(selection: Selection, ready: Bool,
        render: @escaping @MainActor (String, Selection) async throws -> LongFormRenderer.Audio) -> Bool {
        guard permitsFixture, harnessDirectory != nil else { return false }
        renderFixture = (selection, ready, render)
        return true
    }
    func clearRenderFixture() { if permitsFixture { invalidate(); renderFixture = nil } }
    private var directory: URL? {
        if SelfTest.isRunning { return harnessDirectory }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NextNotesTTS", isDirectory: true)
    }
    /// Only this latency fixture may enable disk rendering under the harness.
    func useHarnessDirectory(_ root: URL?) -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-latency" else { return false }
        if let root {
            let candidate = root.standardizedFileURL.resolvingSymlinksInPath().path
            let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            guard candidate.hasPrefix(temp + "/"), candidate != temp else { return false }
        }
        invalidate(); harnessDirectory = root; return true
    }
    func beginTermination() -> Task<Void, Never>? {
        terminating = true
        let owned = task
        stopPrewarm()
        return owned
    }
    func stopPrewarm() {
        generation += 1; task?.cancel()
    }
    func invalidate() {
        generation += 1; task?.cancel()
        clips = []; selection = nil
    }
    var readyCount: Int {
        selection == .current && Selection.current.ready ? clips.count : 0
    }
    func next() -> Clip? {
        guard readyCount >= 2 else { return nil }
        if cursor == last { cursor = (cursor + 1) % clips.count }
        let index = cursor
        cursor = (cursor + 1) % clips.count; last = index
        return clips[index]
    }
    var permitsPrewarmForTesting: Bool {
        permitsFixture && harnessDirectory != nil && renderFixture != nil
    }
    func prewarm() {
        guard !SelfTest.isRunning || permitsPrewarmForTesting else { return }
        startPrewarm()
    }
    private func startPrewarm() {
        guard !terminating else { return }
        let selected = Selection.current
        guard ["pocket", "kokoro"].contains(selected.engine), let directory,
              VoiceAcknowledgement.shared.idleForPrewarm,
              selection != selected || clips.count != Self.texts.count else { return }
        guard task == nil else { return }
        generation += 1
        let owned = generation
        clips = []; selection = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                task = nil
                // A native cancellation can finish after the idle observation
                // already fired. Re-arm here once the same producer has joined.
                if selected != .current || Task.isCancelled,
                   VoiceAcknowledgement.shared.idleForPrewarm { startPrewarm() }
            }
            guard !Task.isCancelled, generation == owned else { return }
            // Prewarm only joins the already-selected model owner, away from a turn.
            guard VoiceAcknowledgement.shared.idleForPrewarm else { return }
            if renderFixture == nil {
                if selected.engine == "pocket" { await PocketAgentVoice.shared.prepare() }
                else { await KokoroAgentVoice.shared.prepare() }
            }
            guard !Task.isCancelled, selected == .current, selected.ready else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var prepared: [Clip] = []
                // Confined native diagnostic only: inspect complete fixed phrases
                // without publishing or playing any candidate, including a refusal.
                let traceOnly = SelfTest.isRunning && SelfTest.requested == "--selftest-voice-latency"
                    && CommandLine.arguments.contains("--voice-latency-ack-native-clips")
                let phrases = traceOnly ? ["Mm.", "Okay.", "Got it.", "One sec."] : Self.texts
                for (index, text) in phrases.enumerated() {
                    try Task.checkCancellation()
                    guard VoiceAcknowledgement.shared.idleForPrewarm, selected == .current else { return }
                    let url = directory.appendingPathComponent("ack-\(selected.key)-\(index).wav")
                    let buffer: AVAudioPCMBuffer
                    if let cached = try? Self.read(url) { buffer = cached }
                    else {
                        let audio: LongFormRenderer.Audio
                        if let fixture = renderFixture, permitsFixture {
                            audio = try await fixture.render(text, selected)
                        } else if selected.engine == "pocket" {
                            let session = try await PocketAgentVoice.shared.makeReplySession(voice: selected.voice)
                            var samples: [Float] = []
                            var failure: Error?
                            do {
                                try Task.checkCancellation()
                                session.enqueue(text); session.finish()
                                for try await frame in session.frames {
                                    try Task.checkCancellation()
                                    guard samples.count + frame.samples.count <= 24_000 * (traceOnly ? 4 : 2) else { throw ClipError.invalidPCM }
                                    samples.append(contentsOf: frame.samples)
                                }
                            } catch { failure = error }
                            // Stream cancellation is not a native join. Keep this same
                            // session until its CoreML producer has actually returned.
                            await session.cancel()
                            if let failure { throw failure }
                            audio = .init(samples: samples, sampleRate: 24_000)
                        } else {
                            audio = try LongFormSynthesisFactory.decodeWAV(await KokoroAgentVoice.shared.wav(for: text))
                        }
                        if traceOnly {
                            let first = audio.samples.firstIndex { abs($0) > 0.0001 }
                            let last = audio.samples.lastIndex { abs($0) > 0.0001 }
                            let body = first.flatMap { first in last.map { $0 - first + 1 } } ?? 0
                            SelfTest.diagnostic("VOICE_ACK_NATIVE_CLIP index=\(index) raw_samples=\(audio.samples.count) body_samples=\(body) rate=\(audio.sampleRate) original_bound_ok=\(audio.samples.count <= 48_000 && body > 0) finite=\(audio.samples.allSatisfy(\.isFinite))")
                            continue
                        }
                        buffer = try Self.prepare(audio)
                        let staging = directory.appendingPathComponent("ack-\(UUID().uuidString).wav")
                        defer { try? FileManager.default.removeItem(at: staging) }
                        do {
                            let writer = try AVAudioFile(forWriting: staging, settings: buffer.format.settings)
                            try writer.write(from: buffer)
                        }
                        try Task.checkCancellation()
                        guard generation == owned, selected == .current else { return }
                        if FileManager.default.fileExists(atPath: url.path) {
                            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
                        } else { try FileManager.default.moveItem(at: staging, to: url) }
                    }
                    prepared.append(Clip(text: text, buffers: try Self.split(buffer)))
                }
                guard !Task.isCancelled, generation == owned, selected == .current else { return }
                clips = prepared; selection = selected
            } catch {
                // Optional courtesy audio has no fallback and no answer failure.
                Log.agent.info("Acknowledgement clips unavailable")
            }
        }
    }
    func prepareForLatency() async -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-latency", harnessDirectory != nil else { return false }
        startPrewarm(); await task?.value
        return readyCount == Self.texts.count
    }
    private static func read(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= 48_000,
              file.processingFormat.channelCount == 1,
              file.processingFormat.sampleRate == 24_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw ClipError.invalidPCM }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0,
              UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)).allSatisfy(\.isFinite), abs(channel[0]) > 0.0001 else { throw ClipError.invalidPCM }
        return buffer
    }
    private static func prepare(_ audio: LongFormRenderer.Audio) throws -> AVAudioPCMBuffer {
        guard audio.sampleRate == 24_000, audio.samples.count <= 48_000,
              audio.samples.allSatisfy(\.isFinite),
              let first = audio.samples.firstIndex(where: { abs($0) > 0.0001 }),
              let last = audio.samples.lastIndex(where: { abs($0) > 0.0001 }),
              let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first + 1)),
              let channel = buffer.floatChannelData?[0] else { throw ClipError.invalidPCM }
        buffer.frameLength = buffer.frameCapacity
        audio.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!.advanced(by: first), count: last - first + 1) }
        return buffer
    }
    private static func split(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        guard let samples = buffer.floatChannelData?[0] else { throw ClipError.invalidPCM }
        var result: [AVAudioPCMBuffer] = []
        for offset in stride(from: 0, to: Int(buffer.frameLength), by: 240) {
            let count = min(240, Int(buffer.frameLength) - offset)
            guard let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
                  let destination = part.floatChannelData?[0] else { throw ClipError.invalidPCM }
            part.frameLength = AVAudioFrameCount(count)
            destination.update(from: samples.advanced(by: offset), count: count)
            result.append(part)
        }
        return result
    }
    private enum ClipError: Error { case invalidPCM }
}
