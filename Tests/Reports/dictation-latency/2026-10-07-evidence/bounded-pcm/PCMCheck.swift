import Foundation
import AVFoundation

@main struct PCMCheck {
    static let rate = 16_000
    static func tone(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sinf(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }
    static func quiet(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * Double(rate))) }
    static func chunk(_ audio: ArraySlice<Float>) -> AudioChunk {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(audio.count))!
        buffer.frameLength = UInt32(audio.count)
        for (index, sample) in audio.enumerated() { buffer.floatChannelData![0][index] = sample }
        return AudioChunk(buffer: buffer)
    }
    static func wait(_ condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
    static func hash(_ audio: [Float]) -> String {
        var value: UInt64 = 14695981039346656037
        for sample in audio { value = (value ^ UInt64(sample.bitPattern)) &* 1099511628211 }
        return "\(audio.count):\(value)"
    }
    static func run(_ name: String, audio: [Float], step: Int = 1600, failFirst: Bool = false,
                    heldFinish: Bool = false, holdFailure: Bool = false) async -> [String: Any] {
        await ASRBoundary.shared.reset()
        let engine = ParakeetEngine()
        var failure: [String] = []
        guard let stream = try? await engine.start() else { return ["name": name, "error": "start"] }
        let consumer = Task { () -> [String] in
            var rows: [String] = []
            do { for try await chunk in stream { rows.append("\(chunk.isFinal):\(chunk.committedText ?? "nil"):\(chunk.text)") } }
            catch { rows.append("ERROR:\(error)") }
            return rows
        }
        if failFirst { await ASRBoundary.shared.failOne() }
        var peak = 0
        var count = 0
        while count < audio.count {
            let end = min(count + step, audio.count)
            if heldFinish && count < 44 * rate / 10 && end >= 44 * rate / 10 {
                await ASRBoundary.shared.hold()
                if holdFailure { await ASRBoundary.shared.failOne() }
            }
            await engine.feed(chunk(audio[count..<end]))
            let probe = await engine.pcmProbe()
            peak = max(peak, probe.retained)
            if !heldFinish || end < 44 * rate / 10 {
                if !(await wait({ await engine.pcmProbe().idle })) { failure.append("worker did not settle") }
            }
            count = end
        }
        let before = await engine.pcmProbe()
        if before.total != audio.count { failure.append("absolute captured samples changed") }
        if heldFinish {
            if !(await wait({ await ASRBoundary.shared.waiting > 0 })) { failure.append("held producer did not enter") }
            let finish = Task { await engine.finish() }
            if !(await wait({ await ASRBoundary.shared.waiting >= 2 })) { failure.append("key-up did not overlap held segment") }
            await ASRBoundary.shared.release()
            await finish.value
        } else { await engine.finish() }
        let rows = await consumer.value
        let diagnostic = await engine.diagnostics
        let calls = await ASRBoundary.shared.snapshot()
        let after = await engine.pcmProbe()
        if after.retained != 0 || after.total != 0 { failure.append("session PCM not reset") }
        if await ASRBoundary.shared.waiting != 0 { failure.append("boundary child not joined") }
        return ["name": name, "inputSamples": audio.count, "retainedBeforeFinish": before.retained,
                "peakRetainedSamples": peak, "calls": calls.map(hash), "stream": rows,
                "keyUpPlan": diagnostic.keyUpPlan, "final": diagnostic.finalText, "failures": failure]
    }
    static func main() async {
        var monologue = tone(31)
        for index in 6 * rate..<6 * rate + 1600 { monologue[index] *= 0.02 }
        let unit = tone(3.5) + quiet(0.6)
        let long = Array(repeating: unit, count: 29).flatMap { $0 } + tone(2.1)
        let short = tone(0.13)
        var rows: [[String: Any]] = []
        for (name, audio, step, fail) in [
            ("short padding", short, 113, false), ("all quiet", tone(2, amplitude: 0.002), 791, false),
            ("pause", tone(4) + quiet(0.6) + tone(4), 1600, false),
            ("hard rewind", monologue, 997, false), ("121s segments", long, 1600, false),
            ("failed first pass", tone(4) + quiet(0.6) + tone(4), 1600, true),
            ("quiet tail after commit", tone(4) + quiet(0.6) + tone(2, amplitude: 0.002), 1600, false)
        ] { rows.append(await run(name, audio: audio, step: step, failFirst: fail)) }
        let end = tone(4) + quiet(0.6) + tone(1)
        rows.append(await run("held segment and tail", audio: end, heldFinish: true))
        rows.append(await run("failed held segment fallback", audio: end, heldFinish: true, holdFailure: true))
        let longRow = rows.first { $0["name"] as? String == "121s segments" }!
        let boundOK = (longRow["peakRetainedSamples"] as! Int) <= 16_000 * 15
        let output: [String: Any] = ["cases": rows, "retentionRequirementMet": boundOK,
            "scope": "Actual engine/segmenter with native ASR, scheduler and converter boundaries substituted; real AV buffers. No native accuracy or end-to-end latency claim."]
        print(String(data: try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
