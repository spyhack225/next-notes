import AVFoundation
import CoreML
import Darwin
import FluidAudio
import Foundation

/// Offline runtime comparison over explicit local assets. Never downloads models or
/// reads/writes Next Notes settings. Application/streaming acceptance is separate.
@main
struct ASRRuntimeBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else {
            throw NSError(domain: "ASRBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Expected model directory, vocabulary, output JSON and WAV files"])
        }
        let root = URL(fileURLWithPath: args[1])
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let began = Date()
        let vocabData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let raw = try JSONSerialization.jsonObject(with: vocabData)
        var vocab: [Int: String] = [:]
        if let list = raw as? [String] {
            vocab = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.offset, $0.element) })
        } else if let dict = raw as? [String: String] {
            vocab = Dictionary(uniqueKeysWithValues: dict.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        }
        guard !vocab.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let models = try AsrModels(
            encoder: MLModel(contentsOf: root.appendingPathComponent("Encoder.mlmodelc"), configuration: config),
            preprocessor: MLModel(contentsOf: root.appendingPathComponent("Preprocessor.mlmodelc"), configuration: cpu),
            decoder: MLModel(contentsOf: root.appendingPathComponent("Decoder.mlmodelc"), configuration: config),
            joint: MLModel(contentsOf: root.appendingPathComponent("JointDecisionv3.mlmodelc"), configuration: config),
            configuration: config, vocabulary: vocab, version: .v3)
        let manager = AsrManager(config: .default, models: models)
        let loadMS = Date().timeIntervalSince(began) * 1000
        if ProcessInfo.processInfo.environment["ASR_LIVE"] == "1" {
            func emit(_ value: [String: Any]) throws {
                var measured = value
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                measured["native_peak_rss_bytes"] = usage.ru_maxrss
                let data = try JSONSerialization.data(withJSONObject: measured, options: [.sortedKeys])
                FileHandle.standardOutput.write(Data("ASR_RPC ".utf8) + data + Data([10]))
            }
            try emit(["ready": true, "load_ms": loadMS])
            while let line = readLine() {
                let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: request["path"] as! String))
                let count = request["samples"] as! Int
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
                try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                var state = try TdtDecoderState()
                let result = try await manager.transcribe(samples, decoderState: &state)
                try emit(["text": result.text])
            }
            return
        }
        var rows: [[String: Any]] = []
        for path in args.dropFirst(4) {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            guard file.processingFormat.sampleRate == 16_000,
                  file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                      frameCapacity: AVAudioFrameCount(file.length)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            for trial in 0..<3 {
                var decoderState = try TdtDecoderState()
                let start = Date()
                let result = try await manager.transcribe(samples, decoderState: &decoderState)
                let elapsed = Date().timeIntervalSince(start)
                rows.append(["fixture": path, "trial": trial, "text": result.text,
                    "audio_seconds": Double(samples.count) / 16_000,
                    "wall_seconds": elapsed, "rtfx": Double(samples.count) / 16_000 / elapsed])
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["load_ms": loadMS, "trials": rows,
            "peak_rss_bytes": usage.ru_maxrss, "compute": "cpuAndNeuralEngine; preprocessor cpuOnly",
            "scope": "explicit CoreML files, v3-family decoder, whole-file unpaced runtime probe"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    }
}
