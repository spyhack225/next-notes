import AVFoundation
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let captureHostTime: UInt64?
}
@main struct Main {
    static func main() {
        let ok = TTSOutputProbe.selfTest()
        print(ok ? "TTS_OUTPUT_OBSERVER_OK" : "TTS_OUTPUT_OBSERVER_FAILED")
        exit(ok ? 0 : 1)
    }
}
