import Foundation
@main struct TextCheck {
    static func main() throws {
        let tokens = [" hello", "world ", "👩🏽‍💻", "e\u{301}", "東京", "\n\n", "\t", "\u{00A0}", "\u{2003}", "\u{000B}", "\u{0085}", "ßeta", "ﬃle", "?!"]
        var state: UInt64 = 181
        var results: [String] = []
        for index in 0..<500 {
            var input = ""
            for _ in 0..<(index % 180) {
                state = state &* 6364136223846793005 &+ 1
                input += tokens[Int((state >> 32) % UInt64(tokens.count))]
            }
            for limit in [-1, 0, 1, 5, 18, 96, 140, Int.max] {
                results.append(LiveDictationText.tail(input, limit: limit))
            }
        }
        let long = String(repeating: "This passage includes 👩🏽‍💻 e\u{301}quipe 東京 and ordinary words. ", count: 800)
        var last = ""
        let began = ContinuousClock.now
        for _ in 0..<1000 { last = LiveDictationText.tail(long, limit: 140) }
        let c = began.duration(to: .now).components
        let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        let out: [String: Any] = ["cases": results, "tail": last, "millisecondsPerTail": ms / 1000, "benchmarkCharacters": long.count]
        print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
    }
}
