import Foundation

/// What a spoken or typed computer command is asking for, without a model.
enum ComputerIntent: Equatable {
    case inspect
    case activeApp
    case open(String)
    case click(String)
    case type(String)
    case press(String)

    static func parse(_ raw: String) -> ComputerIntent? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()

        if lowered.contains("what app") || lowered.contains("frontmost") || lowered.contains("what am i looking") {
            return .activeApp
        }
        if lowered.contains("inspect") || lowered.contains("what's on screen")
            || lowered.contains("whats on screen") || lowered.contains("what is on screen")
            || lowered.contains("what can you see") {
            return .inspect
        }

        if let range = lowered.range(of: #"^open\s+"#, options: .regularExpression) {
            let name = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return .open(name) }
        }

        if let click = firstCapture(
            in: text,
            pattern: #"(?:click|press|tap)\s+(?:the\s+)?(.+?)(?:\s+button)?$"#
        ) {
            return .click(click)
        }

        if let typed = firstCapture(
            in: text,
            pattern: #"(?:type|enter|write|set text to)\s+(.+?)(?:\s+in the (?:focused )?field)?$"#
        ) {
            return .type(typed.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”")))
        }

        if lowered == "press return" || lowered == "press enter" || lowered == "hit return" {
            return .press("return")
        }
        if lowered == "press escape" || lowered == "press esc" {
            return .press("escape")
        }
        return nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text)
        else { return nil }
        let value = String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
