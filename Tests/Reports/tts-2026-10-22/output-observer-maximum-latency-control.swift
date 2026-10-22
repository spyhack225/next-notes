import AVFoundation
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let captureHostTime: UInt64?
}
@main struct Main {
    static func main() {
        let probe = TTSOutputProbe()
        let request = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        func buffer(_ value: Float) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            b.frameLength = 160
            b.floatChannelData![0].update(repeating: value, count: 160)
            return b
        }
        for index in -70..<0 {
            let host = UInt64(Double(request) + Double(index) / 100 * Double(AVAudioTime.hostTime(forSeconds: 1)))
            probe.captured(AudioChunk(buffer: buffer(0.00001), captureHostTime: host))
        }
        probe.arm(request: request, token: 17)
        TTSOutputProbe.install(probe)
        for index in 0..<250 {
            let value: Float = index < 20 ? 0 : Float(0.01 + Double((index * 73 + index * index * 7) % 97) / 2_000)
            let host = request + AVAudioTime.hostTime(forSeconds: Double(index) / 100)
            TTSOutputProbe.rendered(buffer(value), host: host, latency: 0.300, origin: "authored-render-generation-17")
            probe.captured(AudioChunk(buffer: buffer(value * 0.25),
                captureHostTime: host + AVAudioTime.hostTime(forSeconds: 0.080)))
        }
        TTSOutputProbe.install(nil)
        let result = probe.finish(request: request, route: TTSOutputProbe.route())
        print(String(data: try! JSONEncoder().encode(result), encoding: .utf8)!)
        let passed = result.qualified && abs((result.acousticOnsetMs ?? 0) - 280) <= 20
            && abs((result.estimatedPresentationMs ?? 0) - 500) <= 5
        print(passed ? "TTS_MAXIMUM_LATENCY_CONTROL_OK" : "TTS_MAXIMUM_LATENCY_CONTROL_FAILED")
        exit(passed ? 0 : 1)
    }
}
