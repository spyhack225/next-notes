import AVFoundation
import Darwin
import FluidAudio
import Foundation
import Synchronization

/// One engine per process. The parent saves each result and removes its own model
/// directory only after this process exits, so no previous model remains loaded.
@MainActor
enum TTSFirstAudioBenchmark {
    static func runSourceContractStandalone() -> Never {
        Task { @MainActor in
            let failures = await sourceContract()
            print(failures.isEmpty ? "TTS_SOURCE_OK" : "TTS_SOURCE_FAILED: \(failures.joined(separator: "; "))")
            exit(failures.isEmpty ? 0 : 1)
        }
        RunLoop.main.run()
        exit(1)
    }

    /// Actual output graph, muted deterministic PCM: pause before the first
    /// generated buffer and retain a producer held longer than its active IO budget.
    private static func sourceContract() async -> [String] {
        var failures: [String] = []
        var failed = false
        var started = false
        let source = PocketSourceSpeechBacking(synthesis: { _, consume in
            try await consume(Array(repeating: Float(0.1), count: 24_000 * 16))
        })
        source.onFailure = { _, _, _ in failed = true }
        source.onUtteranceStarted = { _ in started = true }
        source.speak("Muted source contract.", volume: 0, token: 41)
        source.pauseForListening()
        try? await Task.sleep(for: .milliseconds(2_300))
        if AgentPCMRenderer.shared.renderedSampleCount != 0 || started {
            failures.append("pause before PCM rendered audio")
        }
        if failed || !source.isSpeaking { failures.append("deliberate listening pause timed out the producer") }
        source.resumeAfterListening()
        let deadline = Date().addingTimeInterval(3)
        while !started && !failed && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        if !started { failures.append("paused producer did not resume") }
        source.stop()
        if source.isSpeaking { failures.append("stop left source speaking") }
        source.endSession()
        return failures
    }

    /// Exercise each new provider through the actual shared output consumer after
    /// timing generation. Muted output keeps this diagnostic unobtrusive.
    private static func playbackContract(_ voice: NativeAgentVoice) async throws {
        var started = false
        var finished = false
        var failed = false
        let source = PocketSourceSpeechBacking(synthesis: { text, consume in
            try await voice.synthesize(text, consume: consume)
        })
        defer { source.stop(); source.endSession() }
        source.onUtteranceStarted = { _ in started = true }
        source.onUtteranceFinished = { _ in finished = true }
        source.onFailure = { _, _, _ in failed = true }
        source.speak("Ready.", volume: 0, token: 43)
        source.pauseForListening()
        try await Task.sleep(for: .milliseconds(2_300))
        guard !started, !failed, AgentPCMRenderer.shared.renderedSampleCount == 0 else {
            throw BenchmarkError.playback
        }
        source.resumeAfterListening()
        let deadline = Date().addingTimeInterval(60)
        while !finished && !failed && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard started, finished, !failed else { throw BenchmarkError.playback }
    }
    struct Trial: Codable {
        let index: Int
        let phase: String
        let firstPCMms: Double
        let completionMs: Double
        let frames: Int
        let audioSeconds: Double
    }
    struct Report: Codable {
        var schema = "nextnotes.tts-first-pcm.v1"
        let engine: String
        let model: String
        var nativeVoice: NativeAgentVoice?
        let macOS: String
        let memoryBytes: UInt64
        let peakRSSBytes: Int64
        let generatedAt: String
        let text: String
        let preparationMs: Double
        let trials: [Trial]
        let notes: [String]
    }

    static func runStandalone() -> Never {
        Task { @MainActor in
            do { try await run(); print("TTS_BENCHMARK_OK"); exit(0) }
            catch {
                FileHandle.standardError.write(Data("TTS_BENCHMARK_FAILED: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }

    static func run() async throws {
        let args = CommandLine.arguments
        func argument(_ key: String) throws -> String {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { throw NativeVoiceError.missing }
            return args[i + 1]
        }
        let engine = try argument("--tts-engine")
        let root = URL(fileURLWithPath: try argument("--tts-model-root"), isDirectory: true).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard (root.path == temporary || root.path.hasPrefix(temporary + "/")),
              root.lastPathComponent.hasPrefix("nextnotes-tts-"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".benchmark-owned").path),
              let trials = Int(try argument("--tts-trials")), (1...100).contains(trials) else {
            throw NativeVoiceError.missing
        }
        #if DEBUG
        throw BenchmarkError.releaseRequired
        #else
        NativeVoiceAssets.benchmarkRoot = root
        defer { NativeVoiceAssets.benchmarkRoot = nil }
        let text = try argument("--tts-text")
        let output = URL(fileURLWithPath: try argument("--tts-report"))
        let preparationStart = DispatchTime.now().uptimeNanoseconds
        typealias Render = @MainActor (String, @escaping @MainActor (Int, Double, UInt64) -> Void) async throws -> Void
        let render: Render
        let model: String
        var notes = ["Measures request to first non-empty generated PCM, not speaker output or speech-end-to-answer latency.",
                     "Trial zero is the first synthesis after preparation; later trials are back-to-back warm runs.",
                     "Preparation includes downloading and loading. No microphone or speaker is opened."]
        switch engine {
        case "apple":
            model = "AVSpeechSynthesizer/system-default"
            render = { text, observe in try await apple(text, observe: observe) }
        case "pocket":
            let cached = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/fluidaudio/Models/pocket-tts")
            try await NativeVoiceAssets.cloneCachedDirectory(from: cached, to: root.appendingPathComponent("Models/pocket-tts"))
            let manager = PocketTtsManager(defaultVoice: "alba", directory: root, precision: .int8)
            try await manager.initialize()
            model = "FluidAudio/PocketTTS-int8/alba"
            render = { text, observe in
                let stream = try await manager.synthesizeStreaming(text: text, voice: "alba")
                for try await frame in stream { observe(frame.samples.count, 24_000, DispatchTime.now().uptimeNanoseconds) }
            }
        case "kokoro":
            guard KokoroAgentVoice.isSupportedOS else { throw BenchmarkError.unsupported }
            // FluidAudio hardcodes its shared G2P cache. Refuse if absent rather
            // than downloading unowned files outside the disposable directory.
            let shared = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/fluidaudio/Models/kokoro")
            let required = ModelNames.G2P.requiredModels.union(["us_lexicon_cache.json"])
            guard required.allSatisfy({ FileManager.default.fileExists(atPath: shared.appendingPathComponent($0).path) }) else {
                throw BenchmarkError.sharedAssetsMissing
            }
            let cached = shared.deletingLastPathComponent().appendingPathComponent("kokoro-82m-coreml")
            try await NativeVoiceAssets.cloneCachedDirectory(from: cached, to: root.appendingPathComponent("kokoro-82m-coreml"))
            let manager = KokoroAneManager(directory: root)
            try await manager.initialize()
            model = "FluidAudio/Kokoro82M/af_heart"
            notes.append("Reuses existing shared G2P assets; those user-owned files are retained. The model chain is temporary.")
            render = { text, observe in
                let wav = try await manager.synthesize(text: text, voice: "af_heart")
                let audio = try LongFormSynthesisFactory.decodeWAV(wav)
                observe(audio.samples.count, audio.sampleRate, DispatchTime.now().uptimeNanoseconds)
            }
        case "phonon", "qwen":
            let voice = NativeAgentVoice(engine == "qwen" ? .qwen : .phonon)
            nativeVoice = voice
            await voice.prepare(download: true)
            guard voice.isReady else { throw BenchmarkError.preparation(voice.errorMessage ?? "Voice preparation failed.") }
            model = engine == "qwen" ? "Qwen3-TTS-0.6B-CustomVoice-4bit@" + NativeVoiceAssets.qwenRevision : "Phonon31m-CoreML/v0.4.0"
            if engine == "qwen" {
                notes.append("Qwen currently returns whole clauses: first PCM includes full-clause generation. Streaming promotion awaits a native producer join contract.")
            }
            render = { text, observe in
                try await voice.synthesize(text) { observe($0.count, voice.sampleRate, DispatchTime.now().uptimeNanoseconds) }
            }
        default: throw BenchmarkError.unsupported
        }
        notes.append("Compatible existing model directories are reused through APFS copy-on-write snapshots; SDK cache changes and cleanup affect only the temporary snapshot.")
        let preparedMs = milliseconds(since: preparationStart)
        var results: [Trial] = []
        for index in 0...trials {
            var first: Double?
            var frames = 0
            var duration = 0.0
            let start = DispatchTime.now().uptimeNanoseconds
            try await render(text) { count, rate, producedAt in
                guard count > 0 else { return }
                if first == nil { first = Double(producedAt - start) / 1_000_000 }
                frames += count
                duration += Double(count) / rate
            }
            guard let first, frames > 0 else { throw NativeVoiceError.empty }
            results.append(Trial(index: index, phase: index == 0 ? "first-after-prepare" : "warm",
                                 firstPCMms: first, completionMs: milliseconds(since: start),
                                 frames: frames, audioSeconds: duration))
        }
        if args.contains("--tts-playback-check"), let nativeVoice {
            try await playbackContract(nativeVoice)
            notes.append("After timing, this provider passed muted native source playback: pause before PCM, resume, first-render receipt and drain. No microphone was opened.")
            notes.removeAll { $0 == "Preparation includes downloading and loading. No microphone or speaker is opened." }
            notes.append("Preparation includes downloading and loading. Timed trials generate PCM without speaker playback; the separate playback check opens muted output.")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report = Report(engine: engine, model: model,
                            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                            memoryBytes: ProcessInfo.processInfo.physicalMemory,
                            peakRSSBytes: Int64(usage.ru_maxrss), generatedAt: ISO8601DateFormatter().string(from: Date()), text: text,
                            preparationMs: preparedMs, trials: results, notes: notes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
        #endif
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private final class AppleCapture: @unchecked Sendable {
        struct State { var first: UInt64?; var frames = 0; var rate = 0.0; var done = false }
        let state = Mutex(State())
        func accept(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            state.withLock {
                if pcm.frameLength == 0 { $0.done = true; return }
                if $0.first == nil { $0.first = DispatchTime.now().uptimeNanoseconds }
                $0.frames += Int(pcm.frameLength)
                $0.rate = pcm.format.sampleRate
            }
        }
    }

    private static func apple(_ text: String, observe: @escaping @MainActor (Int, Double, UInt64) -> Void) async throws {
        let synth = AVSpeechSynthesizer()
        let capture = AppleCapture()
        synth.write(AVSpeechUtterance(string: text)) { capture.accept($0) }
        defer { synth.stopSpeaking(at: .immediate) }
        let deadline = Date().addingTimeInterval(60)
        // This polling is only a headless measurement adapter, never a product turn.
        var previousFrames = 0
        while Date() < deadline {
            let value = capture.state.withLock { $0 }
            if value.frames > previousFrames {
                observe(value.frames - previousFrames, value.rate, value.first!)
                previousFrames = value.frames
            }
            if value.done { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw BenchmarkError.timeout
    }

    private enum BenchmarkError: LocalizedError {
        case releaseRequired, unsupported, sharedAssetsMissing, timeout, playback, preparation(String)
        var errorDescription: String? {
            switch self {
            case .releaseRequired: "Use an optimized release build for this benchmark."
            case .unsupported: "This speech engine is unavailable on this Mac."
            case .sharedAssetsMissing: "Kokoro’s shared pronunciation files are absent; skipped to avoid downloads outside the benchmark folder."
            case .timeout: "Speech generation timed out."
            case .playback: "The native voice playback contract failed."
            case .preparation(let message): message
            }
        }
    }
}
