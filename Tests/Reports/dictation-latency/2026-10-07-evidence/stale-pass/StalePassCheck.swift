import Foundation
import AVFoundation
@main struct StalePassCheck {
    static func chunk(_ count: Int) -> AudioChunk {
        let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:UInt32(count))!
        buffer.frameLength=UInt32(count)
        for i in 0..<count { buffer.floatChannelData![0][i] = 0.02 }
        return AudioChunk(buffer:buffer)
    }
    static func until(_ predicate: @Sendable () async -> Bool) async -> Bool {
        let end=ContinuousClock.now.advanced(by:.seconds(2))
        while ContinuousClock.now < end { if await predicate() {return true}; await Task.yield() }
        return await predicate()
    }
    static func main() async throws {
        await ASRBoundary.shared.reset()
        let engine=ParakeetEngine()
        let first=try await engine.start()
        let firstConsumer=Task { do {for try await _ in first {}} catch {} }
        await ASRBoundary.shared.hold()
        await engine.feed(chunk(9000))
        let entered=await until { await ASRBoundary.shared.waiting == 1 }
        let old=await engine.workerHandleForProbe()
        let second=try await engine.start()
        let secondConsumer=Task { () -> [TranscriptionChunk] in
            var chunks:[TranscriptionChunk]=[]
            do {for try await chunk in second {chunks.append(chunk)}} catch {}
            return chunks
        }
        let reset=await engine.diagnostics
        await ASRBoundary.shared.release()
        await old?.value
        let afterStale=await engine.diagnostics
        await engine.feed(chunk(9600))
        let joined=await until { await engine.workerIsIdleForProbe() }
        await engine.finish()
        let final=await secondConsumer.value
        firstConsumer.cancel();await firstConsumer.value
        let afterSecond=await engine.diagnostics
        let calls=await ASRBoundary.shared.snapshot()
        let checks:[(String,Bool)] = [
            ("first actual worker held across next start",entered && old != nil),
            ("new session reset counters",reset.passes == 0 && reset.computeSeconds == 0),
            ("retired pass cannot stamp successor counters",afterStale.passes == 0 && afterStale.computeSeconds == 0),
            ("successor diagnostics count its one actual pass",afterSecond.passes == 1),
            ("successor actual consumer receives one correct final",final.filter{$0.isFinal}.count == 1 && final.last?.text == "diagnostic marker only"),
            ("same accepted model inputs and worker joined",joined && calls.map{$0.count} == [9000,9600])
        ]
        let record:[String:Any] = ["scope":"Actual copied Engine/AV/segmenter; native/converter/scheduler/registry replaced. Original first-stream supersession lifecycle is outside this metrics claim.","checks":checks.map{["name":$0.0,"pass":$0.1]},"stalePassCount":afterStale.passes,"successorPassCount":afterSecond.passes,"inputSamples":calls.map{$0.count}]
        print(String(decoding:try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        print(checks.allSatisfy{$0.1} ? "STALE_PASS_OK" : "STALE_PASS_FAILED")
        if !checks.allSatisfy({$0.1}) {exit(1)}
    }
}
