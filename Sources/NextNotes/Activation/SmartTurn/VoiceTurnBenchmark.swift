import AVFoundation
import Darwin
import Foundation

/// Early dispatch: policy controls and native endpoint replay do not construct
/// SwiftUI, migrate settings or write any meeting/recording/history store.
@MainActor
enum VoiceTurnBenchmark {
    struct Observation {
        let words: String
        let commits: [Double]
        let source: String
        let pacingMS: Double?
        let failure: String?
    }
    struct Fixture: Codable, Sendable {
        let id: String
        let wav: String
        let language: String
        let speechEndMS: Double
        let protectedIntervalsMS: [[Double]]
        let expectedTail: String
        let audioSHA256: String
    }
    struct Manifest: Codable { let fixtures: [Fixture] }
    struct Event: Codable { let name: String; let at_ms: Double }
    struct Trial: Codable {
        let trial_id: String
        let case_id: String
        let phase: String
        let asr: String
        let tts: String
        let condition: String
        let language: String
        let status: String
        let tail_retained: Bool
        let pacing_p95_error_ms: Double?
        let audio_sha256: String
        let ground_truth: GroundTruth
        let events: [Event]
        let endpoint_source: String
        let recognized: String
        let failure: String?
        struct GroundTruth: Codable {
            let speech_end_ms: Double
            let protected_intervals_ms: [[Double]]
        }
    }
    struct Trace: Codable {
        let schema = "nextnotes.turn-trace.v1"
        let run_id: String
        let evidence = "native_replay"
        let clock = "monotonic"
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let trials: [Trial]
        let limitations: [String]
    }
    static func runStandalone(policyOnly: Bool) -> Never {
        Task { @MainActor in
            do {
                if policyOnly {
                    let failures = await SmartTurnEndpointSelfTest.failures()
                    for failure in failures { print("TURN_POLICY_WRONG: \(failure)") }
                    print(failures.isEmpty ? "TURN_POLICY_OK" : "TURN_POLICY_FAILED")
                    exit(failures.isEmpty ? 0 : 1)
                }
                try await run()
                await AgentCaptureController.sharedIfLoaded?.beginEOUTermination()?.value
                print("TURN_BENCHMARK_COLLECTED")
                exit(0)
            } catch {
                await AgentCaptureController.sharedIfLoaded?.beginEOUTermination()?.value
                FileHandle.standardError.write(Data("TURN_BENCHMARK_FAILED: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }
    static func run() async throws {
        guard SelfTest.isRunning,
              let manifestPath = SelfTest.value(after: "--turn-fixtures"),
              let outputPath = SelfTest.value(after: "--turn-output"),
              let modelRoot = SelfTest.value(after: "--turn-model-root"),
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: modelRoot)
                .appendingPathComponent(".nextnotes-turn-fixture").path) else { throw CocoaError(.fileReadInvalidFileName) }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let repetitions = Int(SelfTest.value(after: "--turn-repetitions") ?? "3") ?? 0
        guard (1...100).contains(repetitions), !manifest.fixtures.isEmpty else { throw CocoaError(.coderInvalidValue) }
        var trials: [Trial] = []
        let runID = UUID().uuidString
        try save(trials, runID: runID, path: outputPath)
        for fixture in manifest.fixtures {
            let wav = manifestURL.deletingLastPathComponent().appendingPathComponent(fixture.wav)
            guard try ModelDownloader.sha256(of: wav) == fixture.audioSHA256 else { throw CocoaError(.coderInvalidValue) }
            for iteration in 0..<repetitions {
                let observation = await AgentCaptureController.runTurnEndpointBenchmark(wav: wav)
                let tail = fixture.expectedTail.lowercased().split(whereSeparator: { !$0.isLetter })
                let words = observation.words.lowercased().split(whereSeparator: { !$0.isLetter })
                let tailRetained = tail.isEmpty || words.suffix(tail.count).elementsEqual(tail)
                let events = observation.commits.map { Event(name: "commit", at_ms: $0) }
                trials.append(Trial(trial_id: "\(fixture.id)-\(iteration)", case_id: fixture.id,
                    phase: "cold_capture", asr: "Apple+Parakeet-EOU-160ms",
                    tts: "not-run-endpoint-only", condition: "paced-file-production-capture",
                    language: fixture.language, status: observation.failure == nil ? "measured" : "failed",
                    tail_retained: tailRetained, pacing_p95_error_ms: observation.pacingMS,
                    audio_sha256: fixture.audioSHA256,
                    ground_truth: Trial.GroundTruth(speech_end_ms: fixture.speechEndMS,
                        protected_intervals_ms: fixture.protectedIntervalsMS), events: events,
                    endpoint_source: observation.source, recognized: observation.words,
                    failure: observation.failure))
                print("TURN_TRIAL \(fixture.id) \(iteration) commits=\(events.count) source=\(observation.source)")
                try save(trials, runID: runID, path: outputPath)
            }
        }
    }
    private static func save(_ trials: [Trial], runID: String, path: String) throws {
        let trace = Trace(run_id: runID, trials: trials, limitations: [
            "Synthesized fixture boundaries; no physical microphone, audible response, tools or LLM.",
            "Real Apple/Parakeet/Silero/Smart Turn production capture and endpoint consumer.",
            "Every trial opens a fresh capture session; residency is not independently measured. Warm/cold-process/pressure/routes are separate gates.",
            "Commit timestamps come from the existing producer probe at actual commit selection; no held checkpoint.",
            "A missing first_audible stage stays missing in the full roadmap scorer."])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(trace).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
