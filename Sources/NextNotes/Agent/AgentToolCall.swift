import Foundation

/// One `<tool_call>` the model emitted, before it becomes a proposal.
struct AgentToolCall: Sendable, Equatable {
    let name: String
    let arguments: [String: String]
    let rationale: String
}

/// Reads tool calls out of a completion.
///
/// Qwen3.5 was tuned on the Hermes convention — a JSON object between `<tool_call>` and
/// `</tool_call>` — so that is what is asked for and that is what is parsed. Everything
/// outside the tags is deliberately thrown away: a small model padding its answer with "Here
/// is what I would do" is normal, and a parser that tried to make sense of the prose would
/// be inventing intentions the model never expressed.
enum AgentToolCallParser {
    private static let openTag = "<tool_call>"
    private static let closeTag = "</tool_call>"

    /// Every well-formed call, in the order they appeared. Malformed ones are dropped rather
    /// than failing the batch: one unparseable call out of three should still leave two
    /// proposals, and a model that emits nothing usable is answered by "nothing to do".
    static func calls(in text: String) -> [AgentToolCall] {
        var calls: [AgentToolCall] = []
        var remainder = Substring(text)

        while let open = remainder.range(of: openTag) {
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.range(of: closeTag) else { break }
            let body = afterOpen[..<close.lowerBound]
            if let call = parse(String(body)) { calls.append(call) }
            remainder = afterOpen[close.upperBound...]
        }
        return calls
    }

    /// One call's JSON. `arguments` is usually an object, but a model that has been asked
    /// for JSON inside XML sometimes hands back the object as a string — both are accepted,
    /// because the alternative is discarding a call that says exactly what it wants.
    static func parse(_ body: String) -> AgentToolCall? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty
        else { return nil }

        let rawArguments: [String: Any]
        if let nested = object["arguments"] as? [String: Any] {
            rawArguments = nested
        } else if let encoded = object["arguments"] as? String,
                  let data = encoded.data(using: .utf8),
                  let nested = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rawArguments = nested
        } else {
            rawArguments = [:]
        }

        var arguments: [String: String] = [:]
        for (key, value) in rawArguments {
            if let string = flatten(value) { arguments[key] = string }
        }
        let rationale = (object["rationale"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AgentToolCall(name: name, arguments: arguments, rationale: rationale)
    }

    /// Everything reaches `gws` as a command-line argument, so every value is flattened to
    /// a string here rather than in three places downstream. A list becomes the
    /// comma-separated form the CLI's own `--to` and `--attendee` flags take.
    private static func flatten(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            // `Bool` is an `NSNumber` on this platform, and "1" is not the word the model
            // wrote or the one a flag expects.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case let array as [Any]:
            return array.compactMap(flatten).joined(separator: ", ")
        case let dictionary as [String: Any]:
            guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        case is NSNull:
            return nil
        default:
            return nil
        }
    }
}
