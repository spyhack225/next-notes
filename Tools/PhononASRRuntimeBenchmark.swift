import AVFoundation
import CoreML
import Darwin
import Foundation
import PhononCoreML

@main
struct PhononASRRuntimeBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        let folder = URL(fileURLWithPath: args[1])
        // Keep even the compiled model inside the disposable candidate folder.
        // The unmodified vendor loader reuses this explicit local compiled model.
        let began = Date()
        let compiled = try MLModel.compileModel(at: folder.appendingPathComponent("Phonon-2.mlpackage"))
        try FileManager.default.moveItem(at: compiled, to: folder.appendingPathComponent("Phonon-2.mlmodelc"))
        let compileMS = Date().timeIntervalSince(began) * 1000
        let start = Date()
        var options = Transcriber.Options()
        let live = ProcessInfo.processInfo.environment["ASR_LIVE"] == "1"
        if live {
            // These paced holds are <=7.25s. Avoid compiling the unused default
            // 15s/35s functions before the short-dictation graphs can load.
            options.functions = [5, 10]
            options.eagerFunctions = [5]
            options.progress = { phase, elapsed in
                if let data = try? JSONSerialization.data(withJSONObject: ["phase":phase,"elapsed_seconds":elapsed]) {
                    FileHandle.standardOutput.write(Data("ASR_PROGRESS ".utf8) + data + Data([10]))
                }
            }
        }
        let transcriber = try Transcriber(bundle: folder, options: options)
        let loadMS = Date().timeIntervalSince(start) * 1000
        if ProcessInfo.processInfo.environment["ASR_LIVE"] == "1" {
            func emit(_ value: [String: Any]) throws {
                var measured = value
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                measured["native_peak_rss_bytes"] = usage.ru_maxrss
                let data = try JSONSerialization.data(withJSONObject: measured, options: [.sortedKeys])
                FileHandle.standardOutput.write(Data("ASR_RPC ".utf8) + data + Data([10]))
            }
            try emit(["ready": true, "load_ms": loadMS, "compile_ms": compileMS,
                "function_seconds": [5,10], "eager_seconds": [5]])
            while let line = readLine() {
                let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: request["path"] as! String))
                let count = request["samples"] as! Int
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
                try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                let result = try transcriber.transcribe(samples)
                try emit(["text": result.text])
            }
            return
        }
        var rows: [[String: Any]] = []
        for path in args.dropFirst(3) {
            for trial in 0..<3 {
                let begin = Date()
                let result = try transcriber.transcribe(url: URL(fileURLWithPath: path))
                let elapsed = Date().timeIntervalSince(begin)
                rows.append(["fixture": path, "trial": trial, "text": result.text,
                    "audio_seconds": result.audioSeconds, "wall_seconds": elapsed,
                    "rtfx": result.audioSeconds / elapsed, "windows": result.windows])
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["compile_ms": compileMS, "load_ms": loadMS,
            "peak_rss_bytes": usage.ru_maxrss, "trials": rows,
            "scope": "vendor CoreML defaults, existing English fixture; French unsupported",
            "rescue_windows": transcriber.timing.rescued]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    }
}
