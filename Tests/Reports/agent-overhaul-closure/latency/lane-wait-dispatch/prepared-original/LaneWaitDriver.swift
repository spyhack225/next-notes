import Foundation
import Darwin
import AVFoundation

// Only the measured value is scripted. The full production protocol/types and
// DictationController's exact optional-existential read are compiled unchanged.
actor MeasuredWaitEngine: TranscriptionEngine {
    private var startLaneWaitSeconds: TimeInterval = 0
    var startLaneWait: TimeInterval { startLaneWaitSeconds }

    func preferredInputFormat() async -> AVAudioFormat? { nil }
    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        startLaneWaitSeconds = 1.25
        return AsyncThrowingStream { $0.finish() }
    }
    func feed(_ chunk: AudioChunk) async {}
    func finish() async {}
}

actor DefaultWaitEngine: TranscriptionEngine {
    func preferredInputFormat() async -> AVAudioFormat? { nil }
    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func feed(_ chunk: AudioChunk) async {}
    func finish() async {}
}

@main struct LaneWaitDriver {
    static func main() async throws {
        var failures = 0
        func require(_ name: String, _ actual: TimeInterval, _ expected: TimeInterval) {
            print("LANE_WAIT_CASE \(name) actual=\(actual) expected=\(expected)")
            if actual != expected { failures += 1 }
        }

        let measured = MeasuredWaitEngine()
        _ = try await measured.start()
        await measured.finish()
        require("actor-concrete-after-finish", await measured.startLaneWait, 1.25)

        // Exact production expression at DictationController.runTail's usage read.
        // runTail retains self.engine before clearing it; that variable is an
        // optional TranscriptionEngine existential, not a concrete Parakeet actor.
        let engine: (any TranscriptionEngine)? = measured
        let laneWait = await engine?.startLaneWait ?? 0
        require("actual-optional-existential-after-finish", laneWait, 1.25)

        let defaultEngine: (any TranscriptionEngine)? = DefaultWaitEngine()
        _ = try await defaultEngine?.start()
        await defaultEngine?.finish()
        require("extension-default-engine", await defaultEngine?.startLaneWait ?? 0, 0)

        let absentEngine: (any TranscriptionEngine)? = nil
        require("absent-engine", await absentEngine?.startLaneWait ?? 0, 0)
        print(failures == 0 ? "LANE_WAIT_DISPATCH_OK: 4 cases" : "LANE_WAIT_DISPATCH_FAILED: \(failures) cases")
        if failures != 0 { exit(1) }
    }
}
