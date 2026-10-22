import AVFoundation
import Foundation
import Darwin

/// The app's real factory, segmented engine, scheduler and transcript stream.
/// Input is paced authored PCM; physical microphone/display/polish are excluded.
@MainActor enum ASRLiveAppBenchmark {
    struct Trial: Codable {
        let language: String
        let index: Int
        let firstWordMS: Double?
        let releaseToFinalMS: Double
        let text: String
        let partialCount: Int
        let capturedSamples: Int
    }
    struct Report: Codable {
        let model: String
        let preparationMS: Double
        let scope: String
        let trials: [Trial]
        let temporaryAssetsDeleted: Bool
    }
    static func runStandalone() -> Never {
        Task {
            do { try await run(); print("ASR_LIVE_OK"); exit(0) }
            catch { print("ASR_LIVE_FAILED: \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run(); exit(1)
    }
    static func run() async throws {
        func argument(_ flag: String) throws -> String {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: flag), i+1 < args.count else { throw ASRModelError.unavailable }
            return args[i+1]
        }
        guard SelfTest.requested == "--selftest-asr-live",
              let model = SpeechEngineChoice(rawValue: try argument("--asr-model")),
              ASRModelCatalog.info(model) != nil else { throw ASRModelError.unavailable }
        let fixtures = URL(fileURLWithPath: try argument("--asr-fixtures"))
        let output = URL(fileURLWithPath: try argument("--asr-output"))
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NextNotesASRBench")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let owned = cache.appendingPathComponent("app-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try String(ProcessInfo.processInfo.processIdentifier).write(to: owned.appendingPathComponent(".pid"), atomically: true, encoding: .utf8)
        ASRModelStore.fixtureRoot = owned
        let started = ProcessInfo.processInfo.systemUptime
        var rows: [Trial] = []
        do {
            try await ASRModelStore.shared.ready(model)
            let prepared = 1000 * (ProcessInfo.processInfo.systemUptime - started)
            for language in (model == .phonon ? ["en"] : ["en", "fr"]) {
                let file = try AVAudioFile(forReading: fixtures.appendingPathComponent(language + "-dialogue.wav"))
                let count = language == "en" ? 116_000 : 106_400
                guard file.processingFormat.sampleRate == 16_000,
                      file.processingFormat.channelCount == 1,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else {
                    throw TranscriptionError.noAudioFormat
                }
                try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
                guard Int(buffer.frameLength) == count, let channel = buffer.floatChannelData?[0] else { throw TranscriptionError.noAudioFormat }
                let audio = Array(UnsafeBufferPointer(start: channel, count: count))
                // Warm full-tail and first-prefix native shapes before timed holds.
                _ = try await replay(audio, model: model, language: language, index: -1, paced: false)
                _ = try await replay(Array(audio.prefix(6400)), model: model, language: language, index: -1, paced: false)
                for trial in 0..<3 {
                    let row = try await replay(audio, model: model, language: language, index: trial, paced: true)
                    guard row.firstWordMS != nil, !row.text.isEmpty else { throw ASRModelError.runtime("No live words or final text arrived.") }
                    rows.append(row)
                    print("APP_ASR \(model.rawValue) \(language)/\(trial) first=\(Int(row.firstWordMS ?? -1)) final=\(Int(row.releaseToFinalMS)) ms")

                }
            }
            await NativeASRRuntime.shared.unload()
            try FileManager.default.removeItem(at: owned)
            ASRModelStore.fixtureRoot = nil
            let report = Report(model: model.rawValue, preparationMS: prepared,
                scope: "Optimized app factory/segmented engine/scheduler/transcript consumer,20ms paced PCM; excludes physical mic/UI/polish/insertion/concurrent voice. Warm shape preparation excluded.",
                trials: rows, temporaryAssetsDeleted: !FileManager.default.fileExists(atPath: owned.path))
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(report).write(to: output, options: .atomic)
        } catch {
            await NativeASRRuntime.shared.unload()
            try? FileManager.default.removeItem(at: owned)
            ASRModelStore.fixtureRoot = nil
            throw error
        }
    }
    private static func replay(_ audio: [Float], model: SpeechEngineChoice, language: String,
                               index: Int, paced: Bool) async throws -> Trial {
        let engine = engineForSetting(model, language: language == "en" ? .english : .multi)
        let stream = try await engine.start()
        guard let format = await engine.preferredInputFormat() else { throw TranscriptionError.noAudioFormat }
        let began = ProcessInfo.processInfo.systemUptime
        let consumer = Task { () throws -> (Double?, Double?, String, Int) in
            var first: Double?; var final: Double?; var text = ""; var partials = 0
            for try await chunk in stream {
                let now = ProcessInfo.processInfo.systemUptime
                if !chunk.text.isEmpty, !chunk.isFinal { first = first ?? now; partials += 1 }
                if chunk.isFinal { final = now; text = chunk.text }
            }
            return (first,final,text,partials)
        }
        var offset = 0
        while offset < audio.count {
            let end = paced ? min(offset+320,audio.count) : audio.count
            if paced {
                let wait = began + Double(end)/16_000 - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end-offset)),
                  let channel = buffer.floatChannelData?[0] else { throw TranscriptionError.noAudioFormat }
            buffer.frameLength = AVAudioFrameCount(end-offset)
            for i in 0..<(end-offset) { channel[i] = audio[offset+i] }
            await engine.feed(AudioChunk(buffer: buffer)); offset = end
        }
        let release = ProcessInfo.processInfo.systemUptime
        await engine.finish()
        let result = try await consumer.value
        guard let final = result.1 else { throw ASRModelError.runtime("Final transcript did not reach the app consumer.") }
        return Trial(language: language, index: index, firstWordMS: result.0.map { 1000*($0-began) },
                     releaseToFinalMS: max(0,1000*(final-release)), text: result.2,
                     partialCount: result.3, capturedSamples: audio.count)
    }
}
