import Foundation

/// A llama.cpp GBNF grammar: what constrained decoding is allowed to emit.
///
/// Constrained decoding turns "usually parseable" into "parses or the generation failed".
/// The framework has had it for a long time (`llama_sampler_init_grammar`); this is the Swift
/// side, exposed once and meant to be used three times — `notes.json` extraction (Part 4,
/// Phase C), the memory review and schedule creation, where a 4B model otherwise emits JSON
/// that is almost right.
///
/// Grammars are built from a `GBNFSchema` rather than written by hand, so the shape a caller
/// decodes and the shape the sampler enforces cannot drift, and every string and array has a
/// bound: an unbounded `char*` is how a small model writes one field until the token budget
/// runs out.
struct GBNFGrammar: Sendable, Equatable {
    /// The production rules, one per line.
    let text: String
    /// The start symbol.
    let root: String

    init(text: String, root: String = "root") {
        self.text = text
        self.root = root
    }

    /// The grammar that accepts exactly the JSON `schema` describes, with bounded whitespace.
    static func json(_ schema: GBNFSchema) -> GBNFGrammar {
        var builder = GBNFBuilder()
        let value = builder.rule(for: schema, name: "value")
        builder.add("root", "ws \(value) ws")
        return GBNFGrammar(text: builder.render())
    }

    /// Rule names referenced but never defined, and a missing start symbol. Empty for a
    /// grammar `llama_sampler_init_grammar` can parse — the same check the native parser
    /// makes, run without a vocabulary so a self-test needs no model.
    func structuralProblems() -> [String] {
        do {
            let parsed = try GBNFParser.parse(text)
            var problems: [String] = []
            if parsed.rules[root] == nil { problems.append("no rule named \(root)") }
            for name in parsed.references.sorted() where parsed.rules[name] == nil {
                problems.append("\(name) is used but never defined")
            }
            return problems
        } catch {
            return ["unparseable: \(error)"]
        }
    }

    /// Whether `output` is a complete sentence of this grammar. Used by the self-tests to
    /// prove a scripted model's output is what the sampler would have allowed, and by the
    /// extractor to flag a provider that cannot enforce grammars.
    func matches(_ output: String) -> Bool {
        guard let parsed = try? GBNFParser.parse(text) else { return false }
        var matcher = GBNFMatcher(rules: parsed.rules, input: Array(output.unicodeScalars))
        return matcher.ends(of: .ref(root), at: 0).contains(matcher.input.count)
    }
}

/// The JSON shapes a grammar can be built from. Every object's keys are required and in
/// order; optional values are `.nullable`.
indirect enum GBNFSchema: Sendable, Equatable {
    case string(maxLength: Int)
    case integer
    case boolean
    /// `"YYYY-MM-DD"`.
    case date
    case enumeration([String])
    case nullable(GBNFSchema)
    case array(GBNFSchema, maxItems: Int)
    case object([(String, GBNFSchema)])

    static func == (lhs: GBNFSchema, rhs: GBNFSchema) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): a == b
        case (.integer, .integer), (.boolean, .boolean), (.date, .date): true
        case (.enumeration(let a), .enumeration(let b)): a == b
        case (.nullable(let a), .nullable(let b)): a == b
        case (.array(let a, let m), .array(let b, let n)): a == b && m == n
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }
}

/// Emits rules for a schema. Rule names are `[a-z0-9-]` only — GBNF does not allow `_`.
private struct GBNFBuilder {
    private var rules: [(String, String)] = []
    private var names: Set<String> = []

    mutating func add(_ name: String, _ body: String) {
        guard names.insert(name).inserted else { return }
        rules.append((name, body))
    }

    func render() -> String {
        // The root first, then the shared terminals, then everything else in creation order.
        let ordered = rules.filter { $0.0 == "root" } + rules.filter { $0.0 != "root" }
        return ordered.map { "\($0.0) ::= \($0.1)" }.joined(separator: "\n") + "\n"
    }

    private func sanitized(_ name: String) -> String {
        let mapped = name.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        }
        return String(mapped)
    }

    /// The expression for `schema`, defining whatever rules it needs.
    mutating func rule(for schema: GBNFSchema, name: String) -> String {
        addTerminals()
        switch schema {
        case .string(let maxLength):
            let rule = "str\(max(1, maxLength))"
            add(rule, "\"\\\"\" char{0,\(max(1, maxLength))} \"\\\"\"")
            return rule
        case .integer:
            return "int"
        case .boolean:
            return "bool"
        case .date:
            return "date"
        case .enumeration(let values):
            return "(" + values.map { Self.literal("\"\($0)\"") }.joined(separator: " | ") + ")"
        case .nullable(let inner):
            return "(\(rule(for: inner, name: name)) | \"null\")"
        case .array(let item, let maxItems):
            let itemRule = rule(for: item, name: name + "-item")
            let rule = sanitized(name)
            let more = maxItems > 1 ? " (ws \",\" ws \(itemRule)){0,\(maxItems - 1)}" : ""
            add(rule, "\"[\" ws (\(itemRule)\(more))? ws \"]\"")
            return rule
        case .object(let fields):
            var parts: [String] = []
            for (index, field) in fields.enumerated() {
                let value = rule(for: field.1, name: name + "-" + field.0)
                parts.append((index > 0 ? "\",\" ws " : "") + Self.literal("\"\(field.0)\"") + " ws \":\" ws \(value)")
            }
            let rule = sanitized(name)
            add(rule, "\"{\" ws " + parts.joined(separator: " ws ") + " ws \"}\"")
            return rule
        }
    }

    private mutating func addTerminals() {
        guard !names.contains("ws") else { return }
        // Bounded, so the model cannot spend its budget on newlines between two keys.
        add("ws", "[ \\t\\n]{0,8}")
        add("char", "[^\"\\\\\\x00-\\x1F] | \"\\\\\" [\"\\\\/bfnrt]")
        add("int", "\"0\" | [1-9] [0-9]{0,6}")
        add("bool", "\"true\" | \"false\"")
        add("date", "\"\\\"\" [0-9]{4} \"-\" [0-1] [0-9] \"-\" [0-3] [0-9] \"\\\"\"")
    }

    /// A GBNF string literal.
    static func literal(_ raw: String) -> String {
        "\"" + raw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Parsing and matching

/// The subset of GBNF this app emits, parsed well enough to check references and to match a
/// string: literals, character classes with ranges, negation and `\x`/`\u` escapes, rule
/// references, groups, alternation, `.`, and the `* + ? {m} {m,} {m,n}` repetitions.
indirect enum GBNFNode: Sendable {
    case literal([Unicode.Scalar])
    case charClass(negated: Bool, ranges: [ClosedRange<UInt32>])
    case any
    case ref(String)
    case sequence([GBNFNode])
    case alternation([GBNFNode])
    case repetition(GBNFNode, min: Int, max: Int?)
}

enum GBNFParser {
    struct Parsed {
        var rules: [String: GBNFNode] = [:]
        var references: Set<String> = []
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String) throws -> Parsed {
        var cursor = Cursor(scalars: Array(text.unicodeScalars))
        var parsed = Parsed()
        while true {
            cursor.skipSpace(newlines: true)
            guard !cursor.atEnd else { break }
            let name = cursor.name()
            guard !name.isEmpty else { throw Failure(description: "expected a rule name at \(cursor.index)") }
            cursor.skipSpace(newlines: false)
            guard cursor.consume("::=") else { throw Failure(description: "expected ::= after \(name)") }
            let body = try alternation(&cursor, depth: 0, references: &parsed.references)
            parsed.rules[name] = body
        }
        return parsed
    }

    private static func alternation(_ cursor: inout Cursor, depth: Int, references: inout Set<String>) throws -> GBNFNode {
        var options = [try sequence(&cursor, depth: depth, references: &references)]
        while true {
            cursor.skipSpace(newlines: depth > 0)
            guard cursor.peek == "|" else { break }
            cursor.index += 1
            options.append(try sequence(&cursor, depth: depth, references: &references))
        }
        return options.count == 1 ? options[0] : .alternation(options)
    }

    private static func sequence(_ cursor: inout Cursor, depth: Int, references: inout Set<String>) throws -> GBNFNode {
        var items: [GBNFNode] = []
        while true {
            cursor.skipSpace(newlines: depth > 0)
            guard let scalar = cursor.peek else { break }
            var item: GBNFNode
            switch scalar {
            case "\"":
                item = .literal(try literal(&cursor))
            case "[":
                item = try charClass(&cursor)
            case "(":
                cursor.index += 1
                item = try alternation(&cursor, depth: depth + 1, references: &references)
                cursor.skipSpace(newlines: true)
                guard cursor.peek == ")" else { throw Failure(description: "unclosed group") }
                cursor.index += 1
            case ".":
                cursor.index += 1
                item = .any
            case "|", ")", "\n":
                return items.count == 1 ? items[0] : .sequence(items)
            default:
                // A rule reference — unless it is the next rule's name, `name ::=`.
                let start = cursor.index
                let name = cursor.name()
                guard !name.isEmpty else { throw Failure(description: "unexpected \(scalar) at \(start)") }
                var lookahead = cursor
                lookahead.skipSpace(newlines: false)
                if lookahead.consume("::=") {
                    cursor.index = start
                    return items.count == 1 ? items[0] : .sequence(items)
                }
                references.insert(name)
                item = .ref(name)
            }
            item = try postfix(&cursor, item)
            items.append(item)
        }
        return items.count == 1 ? items[0] : .sequence(items)
    }

    private static func postfix(_ cursor: inout Cursor, _ item: GBNFNode) throws -> GBNFNode {
        switch cursor.peek {
        case "*": cursor.index += 1; return .repetition(item, min: 0, max: nil)
        case "+": cursor.index += 1; return .repetition(item, min: 1, max: nil)
        case "?": cursor.index += 1; return .repetition(item, min: 0, max: 1)
        case "{":
            cursor.index += 1
            let low = cursor.number() ?? 0
            var high: Int? = low
            if cursor.peek == "," {
                cursor.index += 1
                high = cursor.number()
            }
            guard cursor.peek == "}" else { throw Failure(description: "unclosed repetition") }
            cursor.index += 1
            return .repetition(item, min: low, max: high)
        default:
            return item
        }
    }

    private static func literal(_ cursor: inout Cursor) throws -> [Unicode.Scalar] {
        cursor.index += 1
        var result: [Unicode.Scalar] = []
        while let scalar = cursor.peek, scalar != "\"" {
            result.append(try escaped(&cursor))
        }
        guard cursor.peek == "\"" else { throw Failure(description: "unclosed literal") }
        cursor.index += 1
        return result
    }

    private static func charClass(_ cursor: inout Cursor) throws -> GBNFNode {
        cursor.index += 1
        var negated = false
        if cursor.peek == "^" {
            negated = true
            cursor.index += 1
        }
        var ranges: [ClosedRange<UInt32>] = []
        while let scalar = cursor.peek, scalar != "]" {
            let low = try escaped(&cursor).value
            if cursor.peek == "-", cursor.peek(offset: 1) != "]" {
                cursor.index += 1
                let high = try escaped(&cursor).value
                ranges.append(low...max(low, high))
            } else {
                ranges.append(low...low)
            }
        }
        guard cursor.peek == "]" else { throw Failure(description: "unclosed character class") }
        cursor.index += 1
        return .charClass(negated: negated, ranges: ranges)
    }

    private static func escaped(_ cursor: inout Cursor) throws -> Unicode.Scalar {
        guard let scalar = cursor.peek else { throw Failure(description: "unexpected end") }
        cursor.index += 1
        guard scalar == "\\" else { return scalar }
        guard let next = cursor.peek else { throw Failure(description: "dangling escape") }
        cursor.index += 1
        switch next {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "x", "u", "U":
            let digits = next == "x" ? 2 : (next == "u" ? 4 : 8)
            var value: UInt32 = 0
            for _ in 0..<digits {
                guard let digit = cursor.peek, let hex = UInt32(String(digit), radix: 16) else {
                    throw Failure(description: "bad hex escape")
                }
                value = value * 16 + hex
                cursor.index += 1
            }
            guard let result = Unicode.Scalar(value) else { throw Failure(description: "bad scalar") }
            return result
        default:
            return next
        }
    }

    struct Cursor {
        let scalars: [Unicode.Scalar]
        var index = 0

        var atEnd: Bool { index >= scalars.count }
        var peek: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }
        func peek(offset: Int) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }

        mutating func skipSpace(newlines: Bool) {
            while let scalar = peek {
                if scalar == "#" {
                    while let next = peek, next != "\n" { index += 1 }
                } else if scalar == " " || scalar == "\t" || scalar == "\r" || (newlines && scalar == "\n") {
                    index += 1
                } else {
                    break
                }
            }
        }

        mutating func consume(_ text: String) -> Bool {
            let target = Array(text.unicodeScalars)
            guard index + target.count <= scalars.count, Array(scalars[index..<index + target.count]) == target
            else { return false }
            index += target.count
            return true
        }

        mutating func name() -> String {
            var result = ""
            while let scalar = peek, scalar.isASCII,
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
                index += 1
            }
            return result
        }

        mutating func number() -> Int? {
            var result = ""
            while let scalar = peek, ("0"..."9").contains(scalar) {
                result.unicodeScalars.append(scalar)
                index += 1
            }
            return Int(result)
        }
    }
}

/// Every position a node can end at, from a start position. Rule references are memoised,
/// so the bounded repetitions this app emits stay linear in the input.
struct GBNFMatcher {
    let rules: [String: GBNFNode]
    let input: [Unicode.Scalar]
    private var memo: [String: [Int: Set<Int>]] = [:]

    init(rules: [String: GBNFNode], input: [Unicode.Scalar]) {
        self.rules = rules
        self.input = input
    }

    mutating func ends(of node: GBNFNode, at position: Int) -> Set<Int> {
        switch node {
        case .literal(let scalars):
            guard position + scalars.count <= input.count,
                  Array(input[position..<position + scalars.count]) == scalars else { return [] }
            return [position + scalars.count]
        case .charClass(let negated, let ranges):
            guard position < input.count else { return [] }
            let value = input[position].value
            let inClass = ranges.contains { $0.contains(value) }
            return inClass != negated ? [position + 1] : []
        case .any:
            return position < input.count ? [position + 1] : []
        case .ref(let name):
            if let cached = memo[name]?[position] { return cached }
            guard let rule = rules[name] else { return [] }
            // Seeded empty: a left-recursive reference matches nothing rather than looping.
            memo[name, default: [:]][position] = []
            let result = ends(of: rule, at: position)
            memo[name, default: [:]][position] = result
            return result
        case .sequence(let items):
            var frontier: Set<Int> = [position]
            for item in items {
                var next: Set<Int> = []
                for start in frontier { next.formUnion(ends(of: item, at: start)) }
                frontier = next
                if frontier.isEmpty { break }
            }
            return frontier
        case .alternation(let options):
            var result: Set<Int> = []
            for option in options { result.formUnion(ends(of: option, at: position)) }
            return result
        case .repetition(let item, let low, let high):
            var result: Set<Int> = low == 0 ? [position] : []
            var visited: Set<Int> = result
            var frontier: Set<Int> = [position]
            var count = 0
            while !frontier.isEmpty, high.map({ count < $0 }) ?? true {
                var next: Set<Int> = []
                for start in frontier { next.formUnion(ends(of: item, at: start)) }
                count += 1
                if count >= low {
                    next.subtract(visited)
                    visited.formUnion(next)
                    result.formUnion(next)
                }
                frontier = next
            }
            return result
        }
    }
}
