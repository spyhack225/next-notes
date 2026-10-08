import Foundation
@main struct EnergyCheck {
    static func main() throws {
        var audio: [Float] = []
        audio.reserveCapacity(121 * 16000)
        var state: UInt64 = 773
        // Exact deterministic audio includes speech, silence, threshold-adjacent noise,
        // hard cuts, quiet dips and end-of-speech pauses, in a 121-second hold.
        for i in 0..<(121 * 16000) {
            state = state &* 6364136223846793005 &+ 1
            let random = Float(Int((state >> 32) % 20001) - 10000) / 10000
            let second = i / 16000
            let amplitude: Float = second % 13 < 8 ? 0.08 : (second % 13 == 8 ? 0.018 : 0)
            audio.append(random * amplitude)
        }
        var totalSeconds = 0.0
        var expectedCuts: [Int] = []
        var expectedEnd = 0
        for repetition in 0..<40 {
            var segmenter = DictationSegmenter()
            let began = ContinuousClock.now
            let scan = segmenter.advance(over: audio)
            let duration = began.duration(to: .now).components
            totalSeconds += Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            if repetition == 0 { expectedCuts = scan.cuts; expectedEnd = segmenter.lastSpeechEnd }
            precondition(scan.cuts == expectedCuts && segmenter.lastSpeechEnd == expectedEnd)
        }
        var streamed = DictationSegmenter()
        var streamedCuts: [Int] = []
        var speechEnds = 0
        for end in stride(from: 1600, through: audio.count, by: 1600) {
            let scan = streamed.advance(over: Array(audio[..<end]))
            streamedCuts += scan.cuts
            speechEnds += scan.speechEnded ? 1 : 0
        }
        precondition(streamedCuts == expectedCuts && streamed.lastSpeechEnd == expectedEnd)
        let result: [String: Any] = ["millisecondsPer121sScan": totalSeconds * 1000 / 40, "cuts": expectedCuts, "lastSpeechEnd": expectedEnd, "streamedSpeechEnds": speechEnds, "audioFrames": audio.count, "repetitions": 40]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
