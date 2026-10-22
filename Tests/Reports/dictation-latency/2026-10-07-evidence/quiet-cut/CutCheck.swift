import Foundation
import AVFoundation

@main struct CutCheck {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let path = CommandLine.arguments[2]
        let audio = try AudioConversion.monoSamples(fromFileAt: URL(fileURLWithPath: path), sampleRate: 16_000)
        precondition(audio.count == 52_566, "exact public producer-selected window required")
        var original = OriginalDictationSegmenter(), current = DictationSegmenter()
        var oldCuts: [Int] = [], newCuts: [Int] = []
        for end in stride(from: 1600, through: audio.count + 1599, by: 1600) {
            let a = Array(audio.prefix(min(end, audio.count)))
            oldCuts += original.advance(over: a).cuts
            newCuts += current.advance(over: a).cuts
        }
        let selected = mode == "original" ? oldCuts : newCuts
        var failures: [String] = []
        if !selected.isEmpty { failures.append("entire below-floor recognized turn is cut inside quiet PCM") }
        if selected.contains(where: { (6544..<52566).contains($0) }) {
            failures.append("RMS pause cut lies inside independently rendered spoken turn")
        }
        if original.lastSpeechEnd != 0 || current.lastSpeechEnd != 0 { failures.append("fixture no longer entirely below shared floor") }
        var related = 0
        func tone(_ seconds: Double) -> [Float] {
            (0..<Int(seconds*16000)).map { 0.1 * sinf(Float($0)*2 * .pi*220/16000) }
        }
        func zero(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds*16000)) }
        for pcm in [tone(4)+zero(0.6)+tone(4),tone(2)+zero(0.6)+tone(2),tone(4)+zero(0.35)+tone(5)+zero(0.35)+tone(2),tone(31)] {
            var a=OriginalDictationSegmenter(), b=DictationSegmenter()
            let old=a.advance(over:pcm), new=b.advance(over:pcm)
            related += 1
            if old != OriginalDictationSegmenter.Scan(cuts: new.cuts, speechEnded: new.speechEnded) || a.lastSpeechEnd != b.lastSpeechEnd { failures.append("existing above-floor pauses/hard cap differ") }
        }
        var quietCap = DictationSegmenter()
        let capped = quietCap.advance(over: zero(31)).cuts
        var start=0
        for end in capped {
            if end-start>232000 || end-start<48000 { failures.append("quiet hard-cap bound changed") }
            start=end
        }
        if capped.count < 2 { failures.append("quiet long input no longer bounded") }
        let report: [String: Any] = ["mode":mode,"inputSamples":audio.count,"originalCuts":oldCuts,"candidateCuts":newCuts,"lastAboveFloorEnd":original.lastSpeechEnd,"relatedCases":related,"quiet31sHardCuts":capped,"failures":failures,"scope":"Actual AV file conversion/RMS and segmenter; copied shared floor predicate/logger boundary only; no recognizer/model/controller/physical flow"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys]), as:UTF8.self))
        print(failures.isEmpty ? "QUIET_CUT_OK" : "QUIET_CUT_FAILED")
        if !failures.isEmpty { exit(1) }
    }
}
