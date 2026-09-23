import Foundation

/// The consumer-naming lint (§8.3): no user-visible string in `UI/` may say `cron`,
/// `artifact`, `AgentTask`, `TranscriptBus`, `"Task ·"`, `"Tool call"`,
/// `"Allowed tools:"`, a schema key, or a raw dotted tool id.
///
/// It reads the source tree rather than the running views on purpose: the words this
/// catches are introduced by editing a file, and a test that walked the live view tree
/// would need every pane on screen. `#filePath` locates `UI/`, so the check runs from the
/// built app in the developer's checkout — which is where `--selftest-ui-strings` is used.
///
/// Only the four call sites a person actually reads are checked — `Text`, `Label`,
/// `LabeledContent`, `accessibilityLabel` — so identifiers, log lines, `print`s and
/// comments are all invisible to it. When something legitimate must say one of these
/// words, it is allowlisted by file and line below with a comment, never by weakening a
/// rule.
enum UIStringsLint {

    /// The flag entry point. Prints every offender and one terminal verdict.
    static func run() -> Bool {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            print("UI_STRINGS_FAILED: source directory not found at \(directory.path)")
            return false
        }
        let offenders = scan(directory: directory)
        for offender in offenders { print("UI_STRINGS_WRONG: \(offender)") }
        print(offenders.isEmpty ? "UI_STRINGS_OK" : "UI_STRINGS_FAILED")
        return offenders.isEmpty
    }

    /// Every offending literal, as `<path>:<line>: <literal>`. Pure file I/O.
    static func scan(directory: URL) -> [String] {
        let files = swiftFiles(in: directory).sorted { $0.path < $1.path }
        var offenders: [String] = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let relative = file.path.hasPrefix(directory.path + "/")
                ? String(file.path.dropFirst(directory.path.count + 1))
                : file.lastPathComponent
            for literal in userVisibleLiterals(in: source) {
                let tokens = forbiddenTokens(in: literal.text)
                guard !tokens.isEmpty else { continue }
                guard !isAllowlisted(file: relative, line: literal.line) else { continue }
                offenders.append("\(relative):\(literal.line): \(literal.text)")
            }
        }
        return offenders
    }

    // MARK: - The rules

    /// The words and shapes that must never reach a person. Exposed so `--selftest-guided`
    /// can check the strings a scripted run produced without a source tree.
    static func forbiddenTokens(in text: String) -> [String] {
        var found: [String] = []
        let lowered = text.lowercased()

        for word in ["cron", "artifact", "agenttask", "transcriptbus"] {
            if lowered.range(of: "\\b\(word)s?\\b", options: .regularExpression) != nil {
                found.append(word)
            }
        }
        if lowered.contains("task ·") { found.append("Task ·") }
        if lowered.contains("tool call") { found.append("Tool call") }
        if lowered.contains("allowed tools:") { found.append("Allowed tools:") }

        // Schema keys. Named explicitly rather than guessed from a shape, so the lint
        // cannot start failing on ordinary prose that happens to end in "id".
        for key in [
            "document_id", "message_id", "target_id", "targetId", "browserTargetId",
            "cdpTargetId", "tool_id", "toolID", "taskID", "scheduleID", "allowedTools",
            "maxToolCalls", "maxSeconds", "mimeType", "pixelWidth", "previewField",
        ] where text.contains(key) {
            found.append(key)
        }

        // A raw tool id: a known namespace, a dot, and a lowercase name. `filesystem.` and
        // `computer.` are the two this app has leaked before; the full list is the
        // namespaces the catalogue actually declares.
        let namespaces = "filesystem|computer|browser|workspace|schedule|memory|shell|"
            + "meeting|knowledge|skills|github|notion|slack|mcp"
        if text.range(of: "\\b(?:\(namespaces))\\.[a-z][a-z0-9_]*\\b",
                      options: .regularExpression) != nil {
            found.append("raw tool id")
        }
        return found
    }

    /// Explicit exceptions, by file and line, each with the reason it is legitimate.
    ///
    /// Format: `"<path relative to UI/>:<line>"`. Keep this list short; every entry is a
    /// string a person will read.
    private static func isAllowlisted(file: String, line: Int) -> Bool {
        let key = "\(file):\(line)"
        return allowlist.contains(key)
    }

    private static let allowlist: Set<String> = [
        // Empty. Add entries as `"Agent/Foo.swift:42"` with a comment saying why the word
        // is the right word there — never by dropping a rule.
    ]

    // MARK: - Source scanning

    private struct Literal {
        let line: Int
        let text: String
        let index: Int
    }

    /// Every string literal in `source`, comments excluded, with the line it starts on.
    ///
    /// The four-call-site walk below answers "would a person read this?". This one answers
    /// "does this file say the word in a literal at all?", which is what
    /// `--selftest-agent-panes` needs: pane copy is often a continuation fragment
    /// (`"…" + "…"`) whose first half carries no banned word, and a naming rule that reads
    /// only half a sentence is not a rule.
    static func allLiterals(in source: String) -> [(line: Int, text: String)] {
        literals(in: Array(source)).map { (line: $0.line, text: $0.text) }
    }

    /// The string literals passed to `Text(`, `Label(`, `LabeledContent(` or
    /// `accessibilityLabel(`, with interpolations removed (their code is not user-visible
    /// text).
    private static func userVisibleLiterals(in source: String) -> [Literal] {
        let characters = Array(source)
        return literals(in: characters).filter {
            isUserVisibleCallSite(characters: characters, before: $0.index)
        }
    }

    private static func literals(in characters: [Character]) -> [Literal] {
        var literals: [Literal] = []
        var index = 0
        var line = 1
        var inBlockComment = false

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if character == "\n" { line += 1 }

            if inBlockComment {
                if character == "*", next == "/" {
                    inBlockComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if character == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", next == "*" {
                inBlockComment = true
                index += 2
                continue
            }
            if character == "\"" {
                let startLine = line
                var raw = ""
                var cursor = index + 1
                var escaped = false
                var interpolationDepth = 0
                while cursor < characters.count {
                    let current = characters[cursor]
                    if current == "\n" { line += 1 }
                    if escaped {
                        raw.append(current)
                        escaped = false
                        cursor += 1
                        continue
                    }
                    if current == "\\" {
                        // `\(` opens an interpolation; its code is skipped until the
                        // matching `)`.
                        if cursor + 1 < characters.count, characters[cursor + 1] == "(" {
                            interpolationDepth += 1
                            cursor += 2
                            continue
                        }
                        escaped = true
                        raw.append(current)
                        cursor += 1
                        continue
                    }
                    if interpolationDepth > 0 {
                        if current == "(" { interpolationDepth += 1 }
                        if current == ")" { interpolationDepth -= 1 }
                        cursor += 1
                        continue
                    }
                    if current == "\"" { break }
                    raw.append(current)
                    cursor += 1
                }
                literals.append(Literal(line: startLine, text: raw, index: index))
                index = cursor + 1
                continue
            }
            index += 1
        }
        return literals
    }

    /// Whether the literal opening at `index` is an argument to one of the four call
    /// sites. Walks back over whitespace and `verbatim:` so `Text(verbatim: "…")` counts.
    private static func isUserVisibleCallSite(characters: [Character], before index: Int) -> Bool {
        let callSites = ["Text(", "Label(", "LabeledContent(", "accessibilityLabel("]
        var cursor = index - 1
        var seen = 0
        while cursor >= 0, seen < 40 {
            let character = characters[cursor]
            if character.isWhitespace || character == "\n" { cursor -= 1; seen += 1; continue }
            break
        }
        // `Text(verbatim: ` — the colon is part of the label.
        if cursor >= 0, characters[cursor] == ":" {
            var back = cursor - 1
            let word = "verbatim"
            var matched = true
            for expected in word.reversed() {
                if back < 0 || characters[back] != expected { matched = false; break }
                back -= 1
            }
            if matched { cursor = back }
            while cursor >= 0, characters[cursor].isWhitespace { cursor -= 1 }
        }
        guard cursor >= 0 else { return false }
        let prefix = String(characters[0...cursor])
        return callSites.contains { prefix.hasSuffix($0) }
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }
}
