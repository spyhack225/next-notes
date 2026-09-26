import Foundation

/// One `<tool_call>` the model emitted, before it becomes a proposal.
struct AgentToolCall: Sendable, Equatable {
    let name: String
    let arguments: [String: String]
    let rationale: String
    /// Verbatim transcript excerpt supporting a meeting proposal.
    let evidence: String?
}

/// A piece of text that is clearly a tool call and could not be read as one.
///
/// It exists so the planner can hand the model a *repair* rather than either dropping the
/// call silently — which is how "The tool planner returned an invalid tool request." reached
/// a person — or showing the text as though it were the answer, which is how a raw
/// `"},"rationale":` reached one. The excerpt is for the model and the audit log; it is never
/// printed to the user.
struct MalformedCall: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// An opening marker with no complete object before the text ran out.
        case truncated
        /// Something that is not JSON at all.
        case unparseableJSON
        /// JSON, but nothing that names a tool to call.
        case missingName
    }

    let kind: Kind
    let nameGuess: String?
    /// At most 200 characters.
    let excerpt: String

    init(kind: Kind, nameGuess: String? = nil, excerpt: String) {
        self.kind = kind
        self.nameGuess = nameGuess
        self.excerpt = String(excerpt.prefix(200))
    }
}

/// What one planner completion contained: the calls that could be read, the ones that could
/// not, and whatever prose was left once both are removed.
struct ToolCallParse: Sendable, Equatable {
    var calls: [AgentToolCall] = []
    var malformed: [MalformedCall] = []
    /// Text outside every recognised or malformed range, trimmed. Shown to the user only when
    /// `calls` and `malformed` are both empty.
    var prose: String = ""
}

/// Reads tool calls out of a completion.
///
/// The on-device model was tuned on the Hermes convention — a JSON object between `<tool_call>` and
/// `</tool_call>` — so that is what is asked for, and `calls(in:)` reads exactly that, for the
/// meeting, memory and `--selftest-agent` callers that have always used it. Everything outside
/// the tags is deliberately thrown away there: a small model padding its answer with "Here is
/// what I would do" is normal, and a parser that tried to make sense of the prose would be
/// inventing intentions the model never expressed.
///
/// `parse(_:knownNames:)` is the planner's entry point and it makes a different promise. It
/// reads the nine formats the shipped models are actually seen to emit, it reports what it
/// could not read instead of dropping it, and it recovers the one mistake a 4B model makes
/// constantly: a complete, correct call object followed by the model's own reasoning, which
/// arrives as `"},"rationale":"…` and used to cost the whole turn.
enum AgentToolCallParser {
    /// The two tag strings, internal rather than private because P1-05's grammar builds its
    /// `<tool_call>` literals out of them. A grammar that spelled the tag a second way would
    /// steer the sampler toward a shape this parser could not read — and nothing would fail,
    /// because the call would simply never arrive.
    static let openTag = "<tool_call>"
    static let closeTag = "</tool_call>"

    /// The keys the arguments have been observed under. Hermes says `arguments`; a fine-tune
    /// on OpenAI's function format, a gateway and a MiniCPM prompt each say something else,
    /// and reading only one of them meant a call ran with its arguments silently emptied.
    private static let argumentKeys = ["arguments", "parameters", "args", "input", "params"]
    /// The keys a name has been observed under.
    private static let nameKeys = ["name", "tool", "tool_name", "function_name"]
    /// The keys a tool object nests its name and arguments under (OpenAI's `function`).
    private static let containerKeys = ["function", "tool_call"]

    // MARK: - The existing callers

    /// Every well-formed call, in the order they appeared. Malformed ones are dropped rather
    /// than failing the batch: one unparseable call out of three should still leave two
    /// proposals, and a model that emits nothing usable is answered by "nothing to do".
    ///
    /// Unchanged in what it *accepts* — prose must never become a call, which
    /// `--selftest-agent` pins — and widened only in which argument key it reads.
    static func calls(in text: String) -> [AgentToolCall] {
        var calls: [AgentToolCall] = []
        var rest = Substring(text)

        while let open = rest.range(of: openTag) {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: closeTag) else { break }
            let body = afterOpen[..<close.lowerBound]
            if let call = decodeCall(
                String(body), knownNames: [], requireKnownName: false, tolerant: false).call {
                calls.append(call)
            }
            rest = afterOpen[close.upperBound...]
        }
        return calls
    }

    /// One call's JSON, strictly. The name may be under any of `nameKeys` and the arguments
    /// under any of `argumentKeys`, each an object or a JSON-encoded string, because the
    /// alternative is discarding a call that says exactly what it wants.
    static func parse(_ body: String) -> AgentToolCall? {
        decodeCall(body, knownNames: [], requireKnownName: false, tolerant: false).call
    }

    // MARK: - The planner's entry point

    /// Every call in one completion, in every format the shipped models are known to emit.
    ///
    /// `knownNames` is this turn's roster: the ids and aliases the planner may call. It is
    /// what stops a bare JSON object in the middle of an explanation from becoming a call —
    /// the risk a tolerant parser carries, and the reason an unmarked object is read only at
    /// the start of the completion or inside a code fence, and only for a name in this set.
    static func parse(_ text: String, knownNames: Set<String>) -> ToolCallParse {
        let body = stripReasoningBlock(text)
        var result = ToolCallParse()
        var consumed: [Range<String.Index>] = []
        func isFree(_ range: Range<String.Index>) -> Bool {
            !consumed.contains { $0.overlaps(range) }
        }
        func take(_ range: Range<String.Index>, _ decoded: Decoded) {
            consumed.append(range)
            switch decoded {
            case .success(let call): result.calls.append(call)
            case .failure(let malformed): result.malformed.append(malformed)
            }
        }

        // 1–7: a region the model marked itself. Found in the order the table below lists
        // them, and a region an earlier one already claimed is left alone.
        for region in markedRegions(in: body) where isFree(region.range) {
            // 6. Mistral's array is a batch, and a batch is the one shape that yields more
            // than one call from one region, so it is read here rather than in the
            // single-call decoder.
            if region.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["),
               let calls = decodeArray(
                region.body, knownNames: knownNames, requireKnownName: false),
               !calls.isEmpty {
                consumed.append(region.range)
                result.calls.append(contentsOf: calls)
                continue
            }
            take(region.range, decodeCall(
                region.body, knownNames: knownNames,
                requireKnownName: region.requireKnownName, tolerant: true))
        }

        // 8: bare JSON, at the very start of the completion or inside a ```json fence.
        for region in bareJSONRegions(in: body) where isFree(region.range) {
            if let calls = decodeArray(region.body, knownNames: knownNames) {
                for call in calls { result.calls.append(call) }
                consumed.append(region.range)
            } else {
                let decoded = decodeCall(
                    region.body, knownNames: knownNames, requireKnownName: true, tolerant: true)
                if case .success = decoded { take(region.range, decoded) }
                else if case .failure(let malformed) = decoded,
                        malformed.kind != .truncated || region.body.contains("{") {
                    take(region.range, decoded)
                }
            }
        }

        // `prose` is what is left once every call and every unreadable region is removed. A
        // leftover that still looks like call syntax is not prose: it is the model leaking
        // itself, and it becomes a repair rather than an answer.
        var prose = ""
        var cursor = body.startIndex
        for range in consumed.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= cursor else { continue }
            prose += body[cursor..<range.lowerBound]
            cursor = range.upperBound
        }
        prose += body[cursor...]
        prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeCallSyntax(prose) {
            result.malformed.append(MalformedCall(
                kind: .unparseableJSON, nameGuess: nameGuess(in: prose), excerpt: prose))
            prose = ""
        }
        result.prose = prose
        return result
    }

    // MARK: - Marked regions

    /// One stretch of the completion the model fenced off, with the body inside it.
    private struct Region {
        let range: Range<String.Index>
        let body: String
        /// True for a form written without a marker, where only a name in this turn's roster
        /// makes it a call rather than a piece of an explanation.
        let requireKnownName: Bool
    }

    private static func markedRegions(in text: String) -> [Region] {
        var regions: [Region] = []
        // 1. Hermes, with or without its closing tag.
        var rest = Substring(text)
        while let open = rest.range(of: openTag) {
            let afterOpen = rest[open.upperBound...]
            if let close = afterOpen.range(of: closeTag) {
                regions.append(Region(
                    range: open.lowerBound..<close.upperBound,
                    body: String(afterOpen[..<close.lowerBound]), requireKnownName: false))
                rest = afterOpen[close.upperBound...]
            } else {
                // An opening marker with nothing after it: the body runs to the end of the
                // completion, which is what a cut-off call looks like.
                regions.append(Region(
                    range: open.lowerBound..<rest.endIndex,
                    body: String(afterOpen), requireKnownName: false))
                break
            }
        }
        // 4–5. The XML families, as JSON so there is one decode path and one set of rules.
        regions.append(contentsOf: xmlRegions(in: text))
        // 6. Mistral's `[TOOL_CALLS]` then a JSON array.
        for marker in occurrences(of: "[TOOL_CALLS]", in: text) {
            let after = text[marker.upperBound...]
            let end = endOfBalanced(after, open: "[", close: "]", includingCloser: true)
                ?? endOfBalanced(after, open: "{", close: "}", includingCloser: true)
                ?? after.endIndex
            regions.append(Region(
                range: marker.lowerBound..<end,
                body: String(after[..<end]), requireKnownName: false))
        }
        // 7. Llama 3.x's `<|python_tag|>` then a JSON object.
        for marker in occurrences(of: "<|python_tag|>", in: text) {
            let after = text[marker.upperBound...]
            let end = endOfBalanced(after, open: "{", close: "}", includingCloser: true)
                ?? after.endIndex
            regions.append(Region(
                range: marker.lowerBound..<end,
                body: String(after[..<end]), requireKnownName: false))
        }
        return regions.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Qwen3-Coder's `<function=NAME><parameter=KEY>…`, the attribute form
    /// `<function name="NAME"><parameter name="KEY">…`, MiniCPM5-2B's native
    /// `<param name="KEY">…` inside it, and `<invoke name="NAME">…</invoke>`.
    ///
    /// Parameters are read as name/value pairs, so this path never touches JSON and cannot
    /// inherit JSON's tolerance.
    private static func xmlRegions(in text: String) -> [Region] {
        var regions: [Region] = []
        for (openMarker, closeMarker) in [("<function", "</function>"), ("<invoke", "</invoke>")] {
            for marker in occurrences(of: openMarker, in: text) {
                let after = text[marker.upperBound...]
                guard let close = after.range(of: closeMarker) else { continue }
                let openTag = String(after[..<close.lowerBound])
                let inner = String(after[..<close.upperBound])
                regions.append(Region(
                    range: marker.lowerBound..<close.upperBound,
                    body: xmlBody(openTag: openTag, inner: inner), requireKnownName: false))
            }
        }
        return regions
    }

    /// An XML call as the JSON body the decoder understands.
    private static func xmlBody(openTag: String, inner: String) -> String {
        // `<function=NAME>` and `<function name="NAME">` are the two spellings, and an
        // attribute may come before the name, so the `name=` attribute is looked for first
        // and the positional form is the fallback.
        var name = attribute("name", in: openTag).map(unquote) ?? ""
        if name.isEmpty, let equals = openTag.range(of: "=", options: .regularExpression)?.lowerBound {
            name = unquote(String(openTag[openTag.index(after: equals)...].prefix(while: { $0 != ">" })))
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var pairs: [(String, String)] = []
        var rest = Substring(inner)
        while let open = rest.range(of: "<param") {
            // `<parameter` and `<param` share a prefix, and MiniCPM5-2B uses the short one
            // (its delimiters are control tokens, so P0-04 renders them itself). Which one
            // this is decides both the tag's own text and the closer that ends the value.
            let isLong = open.upperBound < rest.endIndex && rest[open.upperBound] == "e"
            let tagStart = isLong
                ? rest.index(open.upperBound, offsetBy: "<parameter".count - "<param".count)
                : open.upperBound
            let tag = String(rest[tagStart...].prefix(while: { $0 != ">" }))
            let key = (quotedValue(in: tag)
                ?? unquote(String(tag.drop(while: { $0 != "=" }).dropFirst())))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let afterTag = rest[rest.index(tagStart, offsetBy: tag.count + 1)...]
            let closer = isLong ? "</parameter>" : "</param>"
            let value: String
            if let close = afterTag.range(of: closer) {
                value = String(afterTag[..<close.lowerBound])
                rest = afterTag[close.upperBound...]
            } else {
                value = String(afterTag)
                rest = ""
            }
            if !key.isEmpty { pairs.append((key, value)) }
        }
        guard !name.isEmpty else { return "{}" }
        let body = pairs.map { key, value in
            "\"\(key)\":\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }.joined(separator: ",")
        return "{\"name\":\"\(name)\",\"arguments\":{\(body)}}"
    }

    // MARK: - Decoding one call body

    private enum Decoded {
        case success(AgentToolCall)
        case failure(MalformedCall)

        var call: AgentToolCall? {
            if case .success(let call) = self { return call }
            return nil
        }
    }

    /// One body, with the two mistakes a small model actually makes repaired before it is
    /// given up on.
    ///
    /// The order is: the body as written; then a repaired body; then the *first complete
    /// object* in the body with the rest of the text dropped; then the same for the repaired
    /// body. That last pair is the `"},"rationale":` recovery, and it is the only place a
    /// parser here discards anything — see `isReasoningTail` for the ceiling on it.
    private static func decodeCall(
        _ body: String, knownNames: Set<String>, requireKnownName: Bool, tolerant: Bool
    ) -> Decoded {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(MalformedCall(kind: .truncated, excerpt: body)) }
        // 4–5. XML, whichever way it is spelled. A model that wrote `<function …>` *inside* a
        // `<tool_call>` wrapper is the MiniCPM5-2B form, and that wrapper's body is XML
        // rather than JSON — so the same reader serves the marked and the unmarked path.
        if tolerant, trimmed.contains("<function") || trimmed.contains("<invoke") {
            let xml = xmlBody(
                openTag: String(trimmed.prefix(while: { $0 != ">" })), inner: trimmed)
            if let call = call(
                from: xml, knownNames: knownNames, requireKnownName: requireKnownName) {
                return .success(call)
            }
        }
        let repaired = tolerant ? repair(trimmed) : nil
        for candidate in [trimmed, repaired].compactMap({ $0 }) {
            if let call = call(from: candidate, knownNames: knownNames, requireKnownName: requireKnownName) {
                return .success(call)
            }
        }
        guard tolerant else { return .failure(failure(trimmed, objectParsed: object(in: trimmed) != nil)) }
        for candidate in [trimmed, repaired].compactMap({ $0 }) {
            guard let end = endOfFirstObject(candidate) else { continue }
            let prefix = String(candidate[..<end])
            guard let call = call(
                from: prefix, knownNames: knownNames, requireKnownName: requireKnownName) else {
                // A complete object with no usable name, or a name this turn may not call.
                return .failure(MalformedCall(
                    kind: .missingName, nameGuess: nameGuess(in: prefix), excerpt: candidate))
            }
            guard isReasoningTail(String(candidate[end...])) else {
                // The rest is a second call, or something no rule here can read.
                return .failure(failure(trimmed, objectParsed: true))
            }
            return .success(call)
        }
        return .failure(failure(
            trimmed, objectParsed: endOfFirstObject(trimmed) != nil || object(in: trimmed) != nil))
    }

    private static func failure(_ body: String, objectParsed: Bool) -> MalformedCall {
        MalformedCall(
            kind: objectParsed ? .unparseableJSON : .truncated,
            nameGuess: nameGuess(in: body), excerpt: body)
    }

    /// A well-formed object that names a tool this turn may call. `requireKnownName` is the
    /// unmarked forms' safety margin: only a name in `knownNames` is a call there, so braces
    /// inside an explanation cannot become one.
    private static func call(
        from body: String, knownNames: Set<String>, requireKnownName: Bool
    ) -> AgentToolCall? {
        guard let object = object(in: body), let name = name(in: object), !name.isEmpty else {
            return nil
        }
        if requireKnownName {
            // Only a name this turn may call. This is the whole safety margin of the
            // unmarked formats, and it is why the parser needs no registry of its own: the
            // roster arrives with the call.
            guard knownNames.contains(name) else { return nil }
        }
        return makeCall(name: name, object: object)
    }

    private static func object(in body: String) -> [String: Any]? {
        let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8))
        guard let outer = parsed as? [String: Any] else { return nil }
        if name(in: outer) != nil { return outer }
        // OpenAI's shape: `{"type":"function","function":{"name":…,"arguments":…}}`. The
        // unwrapping is tried only when the outer object names nothing itself, or a tool
        // object would be read as a call with no name and no arguments.
        for key in containerKeys {
            if let inner = outer[key] as? [String: Any], name(in: inner) != nil { return inner }
        }
        return outer
    }

    private static func name(in object: [String: Any]) -> String? {
        for key in nameKeys {
            if let name = object[key] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    private static func makeCall(name: String, object: [String: Any]) -> AgentToolCall {
        var rawArguments: [String: Any] = [:]
        for key in argumentKeys {
            if let nested = object[key] as? [String: Any] {
                rawArguments = nested
                break
            }
            if let encoded = object[key] as? String,
               let data = encoded.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                rawArguments = nested
                break
            }
        }
        var arguments: [String: String] = [:]
        for (key, value) in rawArguments {
            guard let string = flatten(value) else { continue }
            // A slot the model could not fill comes back as furniture — "[Name]",
            // john.doe@example.com — rather than as an absent key, because the schema said
            // the field was required and the model would rather satisfy the shape than
            // admit the gap. Dropping it here makes the call say what is actually true:
            // this argument is missing, and the card has to ask for it. Nothing is
            // substituted in its place.
            //
            // Only what is furniture whatever tool this is. The parser has read a name, not
            // looked a tool up, so it cannot tell `query: "todo"` on a file search — a
            // perfectly ordinary thing to look for — from `subject: "TBD"` on an email.
            // That judgement needs the tool's own risk and is made in
            // `AgentToolLoop.grounded`, one step later, where the tool is known.
            //
            // Multi-line values are left alone: a message body with a placeholder in it is
            // still a draft worth editing, and it is refused at the executor rather than
            // deleted here.
            if !string.contains("\n"), ToolCallInspector.isUniversalStandIn(string) {
                continue
            }
            arguments[key] = string
        }
        let rationale = (object["rationale"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let evidence = (object["evidence"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentToolCall(
            name: name, arguments: arguments, rationale: rationale,
            evidence: evidence?.isEmpty == true ? nil : evidence
        )
    }

    /// The two JSON slips worth repairing, and nothing else. A trailing comma is the shape a
    /// model produces when it runs out of budget mid-object; single quotes are the shape one
    /// produces when it has been taught Python. Both are unambiguous, and a body that needed
    /// no repair returns nil so there is only one candidate per input.
    private static func repair(_ body: String) -> String? {
        var out = body
        if out.contains(",}") || out.contains(",]") || out.contains(",\n}") || out.contains(",\n]") {
            out = replacing(of: ",\\s*([}\\]])", with: "$1", in: out)
        }
        if !out.contains("\""), out.contains("'") {
            out = out.replacingOccurrences(of: "'", with: "\"")
        }
        return out == body ? nil : out
    }

    // MARK: - Scanning

    /// Whether everything after a recovered call is the model's reasoning rather than a
    /// second call.
    ///
    /// This is the ceiling on the tolerant path, and it is deliberately tight:
    /// - the recovered object must be a **prefix** of the body — nothing may precede it;
    /// - the whole prefix must parse as one object with a usable name;
    /// - the tail must contain no `{`, no `[`, and none of `"name"`, `"arguments"`,
    ///   `"tool_call"` or `name="`, so two calls in one body are never collapsed into one.
    ///
    /// So at most one call is recovered per region, and never out of the middle of an
    /// ambiguous blob. What it recovers is the shape the 4B model emits when it closes the
    /// call and then keeps writing: `{"name":…,"arguments":{…}},"rationale":"…"`, which
    /// arrives as `"},"rationale":` and used to lose the whole turn.
    private static func isReasoningTail(_ tail: String) -> Bool {
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("{"), !trimmed.contains("[") else { return false }
        let lowered = trimmed.lowercased()
        for forbidden in ["\"name\"", "\"arguments\"", "\"tool_call\"", "name=\""] where
            lowered.contains(forbidden) {
            return false
        }
        return true
    }

    /// The index just past the first complete `{…}` at the start of the text, string-aware,
    /// or nil when the text ran out first. A brace inside a string does not count — `"a}b"`
    /// is a value, not the end of the object, and treating it as one truncates every query
    /// that happens to contain a brace.
    private static func endOfFirstObject<T: StringProtocol>(_ text: T) -> T.Index? {
        endOfBalanced(text, open: "{", close: "}", includingCloser: true)
    }

    private static func endOfBalanced<T: StringProtocol>(
        _ text: T, open: Character, close: Character, includingCloser: Bool = false
    ) -> T.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case open: depth += 1
                case close:
                    depth -= 1
                    if depth == 0 { return includingCloser ? text.index(after: index) : index }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func offset<T: StringProtocol>(_ text: T, _ index: T.Index) -> Int {
        text.distance(from: text.startIndex, to: index)
    }

    private static func occurrences(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var rest = Substring(text)
        while let range = rest.range(of: needle) {
            found.append(range)
            rest = rest[range.upperBound...]
        }
        return found
    }

    private static func replacing(of pattern: String, with replacement: String, in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: replacement)
    }

    private static func unquote(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote)
            && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// `name="NAME"`, `name='NAME'` or `name=NAME` in an opening tag. Nil when the tag has
    /// no such attribute, which is what tells the positional `<function=NAME>` form apart
    /// from the attribute one.
    private static func attribute(_ key: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: "\\b\(key)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)"
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    private static func quotedValue(in text: String) -> String? {
        for quote: Character in ["\"", "'"] {
            guard let first = text.firstIndex(of: quote) else { continue }
            let rest = text[text.index(after: first)...]
            guard let last = rest.firstIndex(of: quote) else { continue }
            return String(rest[..<last])
        }
        return nil
    }

    private static func stripReasoningBlock(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var out = text
        while let open = out.range(of: "<think>") {
            if let close = out[open.upperBound...].range(of: "</think>") {
                out = String(out[..<open.lowerBound]) + String(out[close.upperBound...])
            } else {
                // An unterminated block is thinking that ran out of budget: everything from
                // `<think>` on is reasoning, not an answer.
                out = String(out[..<open.lowerBound])
                break
            }
        }
        return out
    }

    /// A name the model was part way through writing, for the repair message and the log.
    private static func nameGuess(in text: String) -> String? {
        let pattern = "\"(?:\(nameKeys.joined(separator: "|")))\"\\s*:\\s*\"([^\"]*)\""
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[valueRange])
        return value.isEmpty ? nil : value
    }

    /// Text a person must never be shown as an answer, because it is call syntax.
    private static func looksLikeCallSyntax(_ prose: String) -> Bool {
        let lowered = prose.lowercased()
        return ["<tool_call", "<function", "<parameter", "name=\"", "<|", "{\"name\""]
            .contains { lowered.contains($0) }
    }

    // MARK: - Bare JSON

    private static func bareJSONRegions(in text: String) -> [Region] {
        var regions: [Region] = []
        if let start = text.firstIndex(where: { !$0.isWhitespace }),
           text[start] == "{" || text[start] == "[" {
            // The whole rest of the completion, not just its first object: `{"name":…},
            // "rationale":"…"` is one call plus a tail, and the tail is what the recovery
            // rule has to see before it will accept the object.
            regions.append(Region(
                range: start..<text.endIndex, body: String(text[start...]),
                requireKnownName: true))
        }
        for fence in occurrences(of: "```json", in: text) {
            let after = text[fence.upperBound...]
            guard let close = after.range(of: "```") else { continue }
            regions.append(Region(
                range: fence.lowerBound..<close.upperBound,
                body: String(after[..<close.lowerBound]), requireKnownName: true))
        }
        return regions
    }

    /// `[{"name":…},{"name":…}]`, every name in this turn's roster. Nil when the array is not
    /// a list of calls, so the caller falls through to the single-object reader.
    private static func decodeArray(
        _ body: String, knownNames: Set<String>, requireKnownName: Bool = true
    ) -> [AgentToolCall]? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
                  as? [[String: Any]], !parsed.isEmpty else { return nil }
        var calls: [AgentToolCall] = []
        for element in parsed {
            guard let name = name(in: element), !name.isEmpty,
                  !requireKnownName || knownNames.contains(name) else { return nil }
            calls.append(makeCall(name: name, object: element))
        }
        return calls
    }

    // MARK: - Values

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
