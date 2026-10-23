import AVFoundation
import Foundation

/// Native component evidence, deliberately separate from production ASR/TTS.
/// Both graphs and the bounded endpoint owner are the exact production sources.
@main
enum VoiceTurnNativeProbe {
    struct Fixture: Decodable {
        let id: String; let wav: String; let speechEndMS: Double
        let protectedIntervalsMS: [[Double]]; let audioSHA256: String
    }
    struct Manifest: Decodable { let fixtures: [Fixture] }
    static func main() async throws {
        if CommandLine.arguments.contains("--selftest-turn-policy") {
            let failures = await SmartTurnEndpointSelfTest.failures()
            print(failures.isEmpty ? "TURN_POLICY_OK" : "TURN_POLICY_FAILED: \(failures)")
            exit(failures.isEmpty ? 0 : 1)
        }
        guard let manifestPath = SelfTest.value(after: "--turn-fixtures"),
              let rootPath = SelfTest.value(after: "--turn-model-root"),
              let output = SelfTest.value(after: "--turn-output") else { throw CocoaError(.fileReadInvalidFileName) }
        let root = URL(fileURLWithPath: rootPath)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".nextnotes-turn-fixture").path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let fixtures = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)).fixtures
        let sileroURL = VoiceTurnAssets.directory(.silero, root: root)
        let smartURL = VoiceTurnAssets.directory(.smartTurn, root: root)
        let silero = try SileroFrameModel(directory: sileroURL)
        let smart = try SmartTurnModel(directory: smartURL)
        var rows: [[String: Any]] = []
        let repetitions = Int(SelfTest.value(after: "--turn-repetitions") ?? "3") ?? 3
        for fixture in fixtures {
            let wav = manifestURL.deletingLastPathComponent().appendingPathComponent(fixture.wav)
            guard try ModelDownloader.sha256(of: wav) == fixture.audioSHA256 else { throw CocoaError(.coderInvalidValue) }
            let file = try AVAudioFile(forReading: wav)
            guard file.length <= 16_000 * 60, file.processingFormat.sampleRate == 16_000,
                  file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw CocoaError(.coderInvalidValue)
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.coderInvalidValue) }
            let pcm = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            // Native inference latency and semantic pause correctness, no ASR substituted
            // into a product claim. Full app endpoint traces use the other collector.
            var points: [(String, Double)] = fixture.protectedIntervalsMS.map { ("internal-pause", $0[0] + min(300, $0[1] - $0[0] - 10)) }
            points.append(("completed-turn", fixture.speechEndMS + 300))
            for (kind, atMS) in points {
                let end = min(pcm.count, max(1, Int(atMS * 16)))
                let audio = Array(pcm.prefix(end).suffix(128_000))
                for index in 0..<repetitions {
                    let began = DispatchTime.now().uptimeNanoseconds
                    let probability = try smart.probability(audio)
                    let duration = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                    rows.append(["case": fixture.id, "boundary": kind, "trial": index,
                        "probability": probability, "inference_ms": duration,
                        "audio_sha256": fixture.audioSHA256, "sample_end": end,
                        "semantic_correct": kind == "completed-turn" ? probability >= 0.5 : probability < 0.5])
                }
            }
            let anchor = DispatchTime.now().uptimeNanoseconds
            var probabilities: [[String: Any]] = []
            var high = 0
            var firstDuck: Double?
            let onset = pcm.firstIndex(where: { abs($0) >= 0.006 }) ?? 0
            for start in stride(from: 0, through: max(0, pcm.count - 512), by: 512) {
                let end = start + 512
                let due = anchor + UInt64(end) * 62_500
                let now = DispatchTime.now().uptimeNanoseconds
                if now < due { try await Task.sleep(nanoseconds: due - now) }
                let began = DispatchTime.now().uptimeNanoseconds
                let probability = try silero.probability(Array(pcm[start..<end]), endNanos: due)
                let completed = DispatchTime.now().uptimeNanoseconds
                high = probability >= 0.6 ? high + 1 : 0
                if high >= 2 && firstDuck == nil {
                    firstDuck = Double(completed - anchor) / 1_000_000 - Double(onset) / 16
                }
                probabilities.append(["sample_end": end, "probability": probability,
                    "inference_ms": Double(completed - began) / 1_000_000,
                    "pacing_error_ms": Double(began - due) / 1_000_000])
            }
            rows.append(["case": fixture.id, "boundary": "silero-paced-frames",
                "first_two_positive_ms_from_amplitude_onset": firstDuck.map { $0 as Any } ?? NSNull(),
                "frames": probabilities, "audio_sha256": fixture.audioSHA256])
            print("NATIVE_TURN_MODEL \(fixture.id)")
        }
        let report: [String: Any] = ["schema": "nextnotes.turn-model-probe.v1", "rows": rows,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Native production CoreML graph component replay; no ASR, microphone, playback, LLM or effects. Semantic snapshots are unpaced; Silero32ms frames are paced.",
            "smart_revision": VoiceTurnAssets.smartRevision, "silero_revision": VoiceTurnAssets.sileroRevision]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
