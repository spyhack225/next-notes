import Foundation
import AVFoundation

@main struct LiveCoverageCheck {
    static func chunk(_ pcm: ArraySlice<Float>) -> AudioChunk {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(pcm.count))!
        buffer.frameLength = UInt32(pcm.count)
        for (i, value) in pcm.enumerated() { buffer.floatChannelData![0][i] = value }
        return AudioChunk(buffer: buffer)
    }
    static func wait(_ condition: @Sendable () async -> Bool) async -> Bool {
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < until {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
    static func main() async throws {
        let pcm = try AudioConversion.monoSamples(fromFileAt: URL(fileURLWithPath: CommandLine.arguments[1]), sampleRate:16000)
        precondition(pcm.count == 52566)
        var failures: [String] = []
        var cases: [[String:Any]] = []
        for held in [false, true] {
            await ASRBoundary.shared.reset()
            if held { await ASRBoundary.shared.hold() }
            let engine = ParakeetEngine()
            let stream = try await engine.start()
            let consumer = Task {
                do { for try await _ in stream {} } catch {}
            }
            var fed = 0, firstRequestAt: Int? = nil
            while fed < pcm.count {
                let end = min(fed+1600, pcm.count)
                await engine.feed(chunk(pcm[fed..<end]))
                if !held {
                    if !(await wait({ await engine.workerIsIdleForProbe() })) { failures.append("worker did not join") }
                } else {
                    if !(await engine.workerIsIdleForProbe()) {
                        _ = await wait({ await ASRBoundary.shared.count > 0 })
                    }
                }
                if firstRequestAt == nil, await ASRBoundary.shared.count > 0 { firstRequestAt = end }
                fed = end
            }
            let before = await engine.diagnostics
            let sameWorker = await engine.workerHandleForProbe()
            let final = Task { await engine.finish() }
            if held {
                let entered = await wait({ await ASRBoundary.shared.waiting >= 2 })
                if !entered { failures.append("fresh final pass queued behind stale held partial") }
                await ASRBoundary.shared.release()
            }
            await final.value
            await sameWorker?.value
            await consumer.value
            if held { _ = await wait({ await ASRBoundary.shared.waiting == 0 }) }
            let calls = await ASRBoundary.shared.snapshot()
            let counts = calls.map(\.count)
            if (firstRequestAt ?? Int.max) > 8000 { failures.append("accepted recognizable quiet PCM has no live request within first500ms") }
            if before.segmentPasses != 0 { failures.append("quiet phrase was frozen after false RMS cut") }
            if held, !counts.contains(pcm.count) { failures.append("held partial final did not receive complete quiet phrase") }
            if await ASRBoundary.shared.waiting != 0 { failures.append("held native boundary not joined") }
            cases.append(["held":held,"firstRequestAtSamples":firstRequestAt ?? -1,"passesBeforeRelease":before.passes,"segmentPassesBeforeRelease":before.segmentPasses,"modelInputCounts":counts])
        }
        for count in [1600, 6400, 52566] {
            await ASRBoundary.shared.reset()
            let engine = ParakeetEngine()
            let stream = try await engine.start()
            let consumer = Task { () -> [TranscriptionChunk] in
                var chunks: [TranscriptionChunk] = []
                do { for try await chunk in stream { chunks.append(chunk) } } catch {}
                return chunks
            }
            let zero = [Float](repeating: 0, count: count)
            var fed = 0
            while fed < count {
                let end = min(fed+1600,count)
                await engine.feed(chunk(zero[fed..<end]))
                _ = await wait({ await engine.workerIsIdleForProbe() })
                fed = end
            }
            await engine.finish()
            let chunks = await consumer.value
            let calls = await ASRBoundary.shared.count
            if calls != 0 { failures.append("literal-zero hold entered native recognition") }
            if chunks.count != 1 || !chunks[0].isFinal || !chunks[0].text.isEmpty {
                failures.append("literal-zero hold failed to deliver one empty final")
            }
            cases.append(["digitalZeroSamples":count,"modelCalls":calls,"chunks":chunks.count])
        }
        let report: [String:Any] = ["inputSamples":pcm.count,"cases":cases,"failures":failures,"scope":"Actual production actor feed/schedule/drain/finish, real public WAV/AV buffers/RMS/segmentation. Native recognizer/converter/scheduler/registry boundaries substituted. Returned marker is explicitly not recognized speech; first native words and hallucinations are unproven."]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        print(failures.isEmpty ? "LIVE_COVERAGE_PRODUCER_OK" : "LIVE_COVERAGE_PRODUCER_FAILED")
        if !failures.isEmpty { exit(1) }
    }
}
