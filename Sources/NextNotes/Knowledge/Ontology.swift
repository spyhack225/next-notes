import Foundation

// Part 4, Phase C: the ontology the graph is validated against.
//
// `Resources/knowledge-ontology.yaml` declares the node types, their fields and the legal
// edges between them. Extraction validates against it and drops what does not fit — the one
// idea worth taking from meetgraph, and what keeps an extracted graph from turning to mush
// after a hundred meetings. A bare binary (`make build`) has no bundle, so a compiled-in copy
// stands in, and `--selftest-extract` fails if the two drift.

/// One field value on a node. Dates and datetimes are strings in their fixed formats.
enum GraphFieldValue: Equatable, Sendable, Codable {
    case text(String)
    case bool(Bool)

    var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// A node as extraction produces it. `meetingID` is the owning meeting — nil for nodes many
/// meetings share (a person, a topic), which outlive any one meeting's re-extraction.
struct GraphNodeRecord: Equatable, Sendable {
    var id: String
    var type: String
    var fields: [String: GraphFieldValue]
    var meetingID: String?
    var sourceChunk: Int64?
    /// Unix seconds: the meeting that stated it.
    var observedAt: Int64

    /// What a list shows for the node.
    var label: String {
        for key in ["title", "name", "label", "text"] {
            if let value = fields[key]?.string, !value.isEmpty { return value }
        }
        return id
    }
}

/// A bi-temporal edge. `sourceChunk` is required: it is what makes a graph answer citable,
/// and what lets a wrong edge be traced to the sentence that caused it.
struct GraphEdgeRecord: Equatable, Sendable {
    var type: String
    var from: String
    var to: String
    var meetingID: String
    /// When the meeting that stated this happened.
    var observedAt: Int64
    /// When the fact became true.
    var validFrom: Int64?
    /// When it stopped being true; nil while it still is.
    var validTo: Int64?
    var sourceChunk: Int64
}

/// Everything one meeting contributes to the graph.
struct GraphBatch: Equatable, Sendable {
    var meetingID: String
    var nodes: [GraphNodeRecord] = []
    var edges: [GraphEdgeRecord] = []
}

/// Something extraction produced that the ontology does not allow. It is dropped, and counted.
struct OntologyViolation: Equatable, Sendable, CustomStringConvertible {
    var subject: String
    var reason: String

    var description: String { "\(subject): \(reason)" }
}

enum OntologyFieldType: String, Sendable, CaseIterable {
    case string, text, label, date, datetime, bool, url

    var maxLength: Int? {
        switch self {
        case .string: 200
        case .text: 400
        case .label: 80
        case .url: 2_000
        case .date, .datetime, .bool: nil
        }
    }
}

struct Ontology: Equatable, Sendable {
    struct NodeType: Equatable, Sendable {
        var name: String
        var fields: [String: OntologyFieldType]
        var required: Set<String>
        var isOptional: Bool
    }

    struct EdgeType: Equatable, Sendable {
        var name: String
        var from: Set<String>
        var to: Set<String>
    }

    var version: Int
    var nodes: [String: NodeType]
    var edges: [String: EdgeType]

    enum LoadError: LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let reason): "knowledge-ontology.yaml is malformed: \(reason)"
            }
        }
    }

    // MARK: - Loading

    /// The ontology the app runs with: the bundled file, or the compiled-in copy.
    static let current: Ontology = {
        if let text = bundledText, let ontology = try? parse(text) { return ontology }
        // The compiled-in copy is checked by the self-test; it cannot fail to parse there.
        return (try? parse(builtInText)) ?? Ontology(version: 0, nodes: [:], edges: [:])
    }()

    static var bundledText: String? {
        guard let url = Bundle.main.url(forResource: "knowledge-ontology", withExtension: "yaml") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func parse(_ text: String) throws -> Ontology {
        guard case .map(let top) = try MiniYAML.parse(text) else { throw LoadError.malformed("top level is not a map") }
        func lookup(_ entries: [(String, MiniYAML.Value)], _ key: String) -> MiniYAML.Value? {
            entries.first { $0.0 == key }?.1
        }
        guard let rawVersion = lookup(top, "version")?.scalar, let version = Int(rawVersion) else {
            throw LoadError.malformed("no version")
        }
        guard case .map(let nodeEntries)? = lookup(top, "nodes") else { throw LoadError.malformed("no nodes") }
        guard case .map(let edgeEntries)? = lookup(top, "edges") else { throw LoadError.malformed("no edges") }

        var nodes: [String: NodeType] = [:]
        for (name, value) in nodeEntries {
            guard case .map(let entries) = value, case .map(let fieldEntries)? = lookup(entries, "fields") else {
                throw LoadError.malformed("\(name) has no fields")
            }
            var fields: [String: OntologyFieldType] = [:]
            for (field, type) in fieldEntries {
                guard let raw = type.scalar, let fieldType = OntologyFieldType(rawValue: raw) else {
                    throw LoadError.malformed("\(name).\(field) has an unknown type")
                }
                fields[field] = fieldType
            }
            let required = Set(lookup(entries, "required")?.list.compactMap(\.scalar) ?? [])
            guard required.isSubset(of: fields.keys) else {
                throw LoadError.malformed("\(name) requires a field it does not declare")
            }
            nodes[name] = NodeType(name: name, fields: fields, required: required,
                                   isOptional: lookup(entries, "optional")?.scalar == "true")
        }

        var edges: [String: EdgeType] = [:]
        for (name, value) in edgeEntries {
            guard case .map(let entries) = value else { throw LoadError.malformed("edge \(name) is not a map") }
            let from = Set(lookup(entries, "from")?.names ?? [])
            let to = Set(lookup(entries, "to")?.names ?? [])
            guard !from.isEmpty, !to.isEmpty, from.isSubset(of: nodes.keys), to.isSubset(of: nodes.keys) else {
                throw LoadError.malformed("edge \(name) joins undeclared node types")
            }
            edges[name] = EdgeType(name: name, from: from, to: to)
        }
        return Ontology(version: version, nodes: nodes, edges: edges)
    }

    // MARK: - Validation

    /// The batch with everything the ontology does not allow removed, and what was removed.
    ///
    /// A node that fails takes its edges with it; an edge whose source chunk is not one of
    /// `knownChunks` is dropped, because an uncitable edge is exactly what this graph refuses
    /// to hold.
    func validate(_ batch: GraphBatch, knownChunks: Set<Int64>) -> (valid: GraphBatch, violations: [OntologyViolation]) {
        var violations: [OntologyViolation] = []
        var kept: [GraphNodeRecord] = []
        var types: [String: String] = [:]
        for node in batch.nodes {
            if let problem = problem(with: node, knownChunks: knownChunks) {
                violations.append(OntologyViolation(subject: node.id, reason: problem))
                continue
            }
            if let existing = types[node.id] {
                if existing != node.type {
                    violations.append(OntologyViolation(subject: node.id, reason: "declared as \(existing) and \(node.type)"))
                }
                continue
            }
            types[node.id] = node.type
            kept.append(node)
        }

        var edges: [GraphEdgeRecord] = []
        var seen: Set<String> = []
        for edge in batch.edges {
            let subject = "\(edge.type) \(edge.from) -> \(edge.to)"
            guard let type = self.edges[edge.type] else {
                violations.append(OntologyViolation(subject: subject, reason: "unknown edge type"))
                continue
            }
            guard let fromType = types[edge.from], let toType = types[edge.to] else {
                violations.append(OntologyViolation(subject: subject, reason: "joins a node that was dropped or never declared"))
                continue
            }
            guard type.from.contains(fromType), type.to.contains(toType) else {
                violations.append(OntologyViolation(subject: subject, reason: "\(fromType) -> \(toType) is not allowed"))
                continue
            }
            guard knownChunks.contains(edge.sourceChunk) else {
                violations.append(OntologyViolation(subject: subject, reason: "source chunk \(edge.sourceChunk) does not exist"))
                continue
            }
            if let validFrom = edge.validFrom, let validTo = edge.validTo, validTo < validFrom {
                violations.append(OntologyViolation(subject: subject, reason: "valid_to precedes valid_from"))
                continue
            }
            guard seen.insert("\(edge.type)|\(edge.from)|\(edge.to)").inserted else { continue }
            edges.append(edge)
        }
        return (GraphBatch(meetingID: batch.meetingID, nodes: kept, edges: edges), violations)
    }

    private func problem(with node: GraphNodeRecord, knownChunks: Set<Int64>) -> String? {
        guard let type = nodes[node.type] else { return "unknown node type \(node.type)" }
        for field in type.required where node.fields[field] == nil {
            return "missing required field \(field)"
        }
        for (name, value) in node.fields {
            guard let fieldType = type.fields[name] else { return "unknown field \(name)" }
            if let problem = Self.problem(with: value, as: fieldType) { return "\(name) \(problem)" }
        }
        if let chunk = node.sourceChunk, !knownChunks.contains(chunk) {
            return "source chunk \(chunk) does not exist"
        }
        return nil
    }

    static func problem(with value: GraphFieldValue, as type: OntologyFieldType) -> String? {
        switch (type, value) {
        case (.bool, .bool): return nil
        case (.bool, .text), (_, .bool): return "has the wrong type"
        case (_, .text(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "is empty" }
            if let max = type.maxLength, text.count > max { return "is longer than \(max) characters" }
            switch type {
            case .date:
                return isDay(text) ? nil : "is not YYYY-MM-DD"
            case .datetime:
                return ISO8601DateFormatter().date(from: text) == nil ? "is not ISO 8601" : nil
            case .url:
                return URL(string: text)?.scheme == nil ? "is not a URL" : nil
            default:
                return nil
            }
        }
    }

    /// A real calendar day in `YYYY-MM-DD`, not merely the shape of one.
    static func isDay(_ text: String) -> Bool {
        day(text) != nil
    }

    static func day(_ text: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar) else { return nil }
        return components
    }

    // MARK: - The compiled-in copy

    static let builtInText = """
        # The knowledge graph's ontology (Part 4, Phase C).
        #
        # Extraction validates every node and edge against this file and drops what does not fit:
        # an unknown type, a missing or unknown field, a value of the wrong shape, an edge between the
        # wrong types, or an edge without a source chunk. Node ids are assigned by code; the model
        # never names a node.
        #
        # Field types: string (200 chars), text (400), label (80), date (YYYY-MM-DD),
        # datetime (ISO 8601), bool, url (2000).
        #
        # Edges are bi-temporal: observed_at, valid_from, valid_to (null = still true) and
        # source_chunk, which is required on every edge.
        #
        # Version 2 widens the graph from meetings into a life map: projects, organisations, places,
        # activities (hobbies), goals, preferences and non-meeting events. Topic stays the speculative
        # catch-all for subjects that do not fit a tighter type. New types are optional — empty is
        # correct when a passage names none of them.
        #
        # Version 3 adds Folder and File, the user's own folders and the files worth naming in them.
        # These two are the one part of the vocabulary a model never produces: they come from
        # file-index.sqlite, which is built by crawling the folders the user shared, and they are
        # merged into the map when it is drawn rather than written into graph_node. That is why they
        # need no source chunk — a path is its own evidence, where a decision is only ever somebody's
        # word for something.

        version: 3

        nodes:
          Meeting:
            source: meeting.json
            fields: { title: string, start: datetime }
            required: [title, start]
          Person:
            source: attendees, speaker names, action owners, and people named in dictation or chat
            fields: { name: label }
            required: [name]
          Decision:
            source: notes heading Decisions
            fields: { text: text, subject: label, supersedes: bool, said_by: label }
            required: [text, subject]
          ActionItem:
            source: notes heading Action items
            fields: { text: text, owner: label, due: date }
            required: [text]
          OpenQuestion:
            source: notes heading Open questions
            fields: { text: text }
            required: [text]
          Artifact:
            source: Meeting.agentActions
            fields: { title: text, kind: label, url: url }
            required: [title, kind]
          Topic:
            source: model extraction; speculative catch-all, so optional
            optional: true
            fields: { label: label }
            required: [label]
          Project:
            source: model extraction from notes, dictation and Agent chat
            optional: true
            fields: { name: label, domain: label }
            required: [name]
          Organization:
            source: model extraction; companies, schools, clubs, teams
            optional: true
            fields: { name: label, kind: label }
            required: [name]
          Place:
            source: model extraction; cities, homes, venues
            optional: true
            fields: { name: label, kind: label }
            required: [name]
          Activity:
            source: model extraction; hobbies and recurring activities
            optional: true
            fields: { name: label, kind: label }
            required: [name]
          Goal:
            source: model extraction; aims and standing intentions
            optional: true
            fields: { text: text }
            required: [text]
          Preference:
            source: model extraction; stated likes and dislikes
            optional: true
            fields: { label: label }
            required: [label]
          Event:
            source: model extraction; life events that are not meetings
            optional: true
            fields: { title: string, when: date }
            required: [title]
          Folder:
            source: the folders the user shared with the assistant, and their sub-folders
            optional: true
            fields: { name: label, path: string }
            required: [name, path]
          File:
            source: files recently used, or named in a meeting, a memory or a task
            optional: true
            fields: { name: label, path: string, kind: label }
            required: [name, path]

        edges:
          attended: { from: Person, to: Meeting }
          decided_in: { from: Decision, to: Meeting }
          supersedes: { from: Decision, to: Decision }
          assigned_in: { from: ActionItem, to: Meeting }
          owns: { from: Person, to: ActionItem }
          raised_in: { from: OpenQuestion, to: Meeting }
          produced: { from: Meeting, to: Artifact }
          discussed: { from: Meeting, to: Topic }
          about: { from: [Decision, ActionItem, OpenQuestion, Project, Goal], to: Topic }
          mentioned_in: { from: [Project, Organization, Place, Activity, Goal, Preference, Event, Topic], to: Meeting }
          works_on: { from: Person, to: Project }
          member_of: { from: Person, to: Organization }
          lives_in: { from: Person, to: Place }
          located_at: { from: [Organization, Event, Activity], to: Place }
          interested_in: { from: Person, to: [Topic, Activity] }
          participates_in: { from: Person, to: [Activity, Event] }
          related_to: { from: Person, to: Person }
          aims_at: { from: Person, to: Goal }
          prefers: { from: Person, to: Preference }
          part_of: { from: [Project, Activity], to: [Organization, Topic] }
          occurs_at: { from: Event, to: Place }
          inside: { from: [Folder, File], to: Folder }
          refers_to: { from: [Meeting, Person, Project, Decision, ActionItem, Goal, Topic], to: File }

        """
}

// MARK: - YAML, the subset the ontology uses

/// Block maps by indentation, `key: value` scalars, and flow `{ a: b }` / `[a, b]`
/// collections; `#` comments. Nothing else — no anchors, no multi-line strings, no block
/// lists — because the ontology file needs none of it and a full YAML parser is a dependency.
enum MiniYAML {
    indirect enum Value: Equatable, Sendable {
        case scalar(String)
        case list([Value])
        case map([(String, Value)])

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.scalar(let a), .scalar(let b)): a == b
            case (.list(let a), .list(let b)): a == b
            case (.map(let a), .map(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: false
            }
        }

        var scalar: String? {
            if case .scalar(let value) = self { return value }
            return nil
        }

        var list: [Value] {
            if case .list(let values) = self { return values }
            return []
        }

        /// A scalar or a list of scalars, as names.
        var names: [String] {
            switch self {
            case .scalar(let value): [value]
            case .list(let values): values.compactMap(\.scalar)
            case .map: []
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String) throws -> Value {
        let lines: [(indent: Int, text: String, number: Int)] = text.components(separatedBy: .newlines)
            .enumerated().compactMap { number, raw in
                let content = stripComment(raw)
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                let indent = content.prefix { $0 == " " }.count
                return (indent, content.trimmingCharacters(in: .whitespaces), number + 1)
            }
        var index = 0
        let value = try block(lines, &index, indent: lines.first?.indent ?? 0)
        guard index == lines.count else { throw Failure(description: "unexpected indentation at line \(lines[index].number)") }
        return value
    }

    private static func block(_ lines: [(indent: Int, text: String, number: Int)], _ index: inout Int, indent: Int) throws -> Value {
        var entries: [(String, Value)] = []
        while index < lines.count, lines[index].indent == indent {
            let line = lines[index]
            guard let colon = line.text.firstIndex(of: ":") else {
                throw Failure(description: "expected key: value at line \(line.number)")
            }
            let key = line.text[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line.text[line.text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            index += 1
            if rest.isEmpty {
                guard index < lines.count, lines[index].indent > indent else {
                    entries.append((key, .scalar("")))
                    continue
                }
                entries.append((key, try block(lines, &index, indent: lines[index].indent)))
            } else if !rest.hasPrefix("{"), !rest.hasPrefix("[") {
                // A plain block scalar runs to the end of the line, commas included.
                var cursor = Array(rest)[...]
                entries.append((key, .scalar(scalar(&cursor, stops: []))))
            } else {
                var cursor = Array(rest)[...]
                let value = try flow(&cursor)
                guard cursor.allSatisfy({ $0 == " " }) else {
                    throw Failure(description: "trailing text at line \(line.number)")
                }
                entries.append((key, value))
            }
        }
        return .map(entries)
    }

    private static func flow(_ cursor: inout ArraySlice<Character>) throws -> Value {
        skip(&cursor)
        switch cursor.first {
        case "{":
            cursor.removeFirst()
            var entries: [(String, Value)] = []
            while true {
                skip(&cursor)
                if cursor.first == "}" { cursor.removeFirst(); break }
                let key = scalar(&cursor, stops: [":"])
                guard cursor.first == ":" else { throw Failure(description: "expected : in a flow map") }
                cursor.removeFirst()
                entries.append((key, try flow(&cursor)))
                skip(&cursor)
                if cursor.first == "," { cursor.removeFirst(); continue }
                guard cursor.first == "}" else { throw Failure(description: "unclosed flow map") }
            }
            return .map(entries)
        case "[":
            cursor.removeFirst()
            var values: [Value] = []
            while true {
                skip(&cursor)
                if cursor.first == "]" { cursor.removeFirst(); break }
                values.append(try flow(&cursor))
                skip(&cursor)
                if cursor.first == "," { cursor.removeFirst(); continue }
                guard cursor.first == "]" else { throw Failure(description: "unclosed flow list") }
            }
            return .list(values)
        default:
            return .scalar(scalar(&cursor, stops: [",", "}", "]"]))
        }
    }

    private static func scalar(_ cursor: inout ArraySlice<Character>, stops: Set<Character>) -> String {
        skip(&cursor)
        if let quote = cursor.first, quote == "\"" || quote == "'" {
            cursor.removeFirst()
            var result = ""
            while let next = cursor.first, next != quote {
                result.append(next)
                cursor.removeFirst()
            }
            if !cursor.isEmpty { cursor.removeFirst() }
            return result
        }
        var result = ""
        while let next = cursor.first, !stops.contains(next) {
            result.append(next)
            cursor.removeFirst()
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func skip(_ cursor: inout ArraySlice<Character>) {
        while cursor.first == " " { cursor.removeFirst() }
    }

    /// Everything before a `#` that starts a comment (line start, or after a space).
    private static func stripComment(_ line: String) -> String {
        var previous: Character = " "
        var inQuote: Character?
        for (offset, character) in line.enumerated() {
            if let quote = inQuote {
                if character == quote { inQuote = nil }
            } else if character == "\"" || character == "'" {
                inQuote = character
            } else if character == "#", previous == " " {
                return String(line.prefix(offset))
            }
            previous = character
        }
        return line
    }
}
