import Foundation

/// Turns a spoken phrase into the phone+ppinyin line this zipformer KWS model wants.
///
/// The archive's own `keywords.txt` is ARPAbet for English (`HH EY1 … @HEY_NEXT`) and
/// pinyin-with-tones for Chinese. We do not ship `sherpa-onnx-cli text2token`; English
/// goes through a small CMU-style table, everything else is written as spaced letters
/// so a custom phrase still produces a file the spotter will load.
enum WakeWordKeywords {
    static func line(for phrase: String) -> String {
        let display = phrase
            .replacingOccurrences(of: " ", with: "_")
            .uppercased()
        let words = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let phones = words.flatMap(phones(for:))
        if phones.isEmpty {
            return "\(display.lowercased()) @\(display)\n"
        }
        return "\(phones.joined(separator: " ")) @\(display)\n"
    }

    private static func phones(for word: String) -> [String] {
        let key = word.lowercased()
        if let known = lexicon[key] { return known }
        return key.compactMap { character in
            character.isLetter ? String(character).uppercased() : nil
        }
    }

    /// Enough English for “Hey Next” and a few other likely phrases. Not a full CMU dict.
    private static let lexicon: [String: [String]] = [
        "hey": ["HH", "EY1"],
        "hi": ["HH", "AY1"],
        "hello": ["HH", "AH0", "L", "OW1"],
        "next": ["N", "EH1", "K", "S", "T"],
        "notes": ["N", "OW1", "T", "S"],
        "note": ["N", "OW1", "T"],
        "ok": ["OW1", "K", "EY1"],
        "okay": ["OW1", "K", "EY1"],
        "please": ["P", "L", "IY1", "Z"],
        "listen": ["L", "IH1", "S", "AH0", "N"],
        "wake": ["W", "EY1", "K"],
        "computer": ["K", "AH0", "M", "P", "Y", "UW1", "T", "ER0"],
    ]
}
