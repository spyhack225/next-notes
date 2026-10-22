import AVFoundation
import CoreML
import Darwin
import Foundation
import Voz

@main struct VozASRLiveProbe {
    static func main() async throws {
        let start = Date()
        let model = try Voz(modelDirectory: URL(fileURLWithPath: CommandLine.arguments[1]))
        func emit(_ value: [String: Any]) throws {
            var measured = value
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            measured["native_peak_rss_bytes"] = usage.ru_maxrss
            let data = try JSONSerialization.data(withJSONObject: measured, options: [.sortedKeys])
            FileHandle.standardOutput.write(Data("ASR_RPC ".utf8) + data + Data([10]))
        }
        try emit(["ready": true, "load_ms": Date().timeIntervalSince(start)*1000])
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: request["path"] as! String))
            let count = request["samples"] as! Int
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let result = try await model.transcribe(samples: samples)
            try emit(["text": result.text])
        }
    }
}
