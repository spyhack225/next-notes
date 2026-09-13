import Foundation

/// What the agent may say out loud. The island still shows the full reply.
///
/// Speak short answers, permission questions and task-done lines. Never speak URLs,
/// tool names, file listings or code — those stay on the card. A long listing has
/// an empty spoken form rather than a truncated reading.
///
/// Spoken replies are split into short clauses (sentence / semicolon / em-dash)
/// so TTS can enqueue utterance-by-utterance and barge-in can cut mid-reply.
///
/// Speak-replies is hardcoded on while an agent listen session is open
/// (`AgentCaptureController.isSessionActive`). Wave 2 can promote that to a
/// Settings toggle; there is no “Speak replies” row yet, and dictation stays silent.
enum AgentSpeechPolicy {
    static let shortLimit = 280
    static let spokenCap = 400

    /// The string `AVSpeechSynthesizer` may speak, or empty when the reply stays visual.
    static func spokenForm(_ reply: String) -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if containsURL(trimmed) { return "" }
        if containsToolName(trimmed) { return "" }
        if containsCode(trimmed) { return "" }

        if isPermissionQuestion(trimmed) || isTaskDone(trimmed) {
            return trimmed.count <= spokenCap ? trimmed : ""
        }
        if isFileListing(trimmed) || isLongListing(trimmed) { return "" }
        if isShortAnswer(trimmed) { return trimmed }
        return ""
    }

    /// Speakable clauses for streamed TTS. Empty when `spokenForm` is empty.
    /// Boundaries: sentence end (`.!?`), semicolon, em-dash (`—`), or ` -- `.
    static func spokenClauses(_ reply: String) -> [String] {
        let spoken = spokenForm(reply)
        guard !spoken.isEmpty else { return [] }
        return splitIntoClauses(spoken)
    }

    /// Split already-speakable text into short playback clauses.
    static func splitIntoClauses(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var clauses: [String] = []
        var start = trimmed.startIndex
        var i = trimmed.startIndex

        while i < trimmed.endIndex {
            let c = trimmed[i]
            let next = trimmed.index(after: i)

            if c == ";" || c == "\u{2014}" {
                let clause = trimmed[start...i]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !clause.isEmpty { clauses.append(clause) }
                i = skipWhitespace(trimmed, from: next)
                start = i
                continue
            }

            // ASCII stand-in for an em-dash: " -- " (space-dash-dash).
            if c == "-", i > trimmed.startIndex {
                let prev = trimmed.index(before: i)
                if trimmed[prev] == "-" {
                    let afterDashes = next
                    let precededBySpace = prev > trimmed.startIndex
                        && trimmed[trimmed.index(before: prev)].isWhitespace
                    let followedBySpaceOrEnd = afterDashes == trimmed.endIndex
                        || trimmed[afterDashes].isWhitespace
                    if precededBySpace && followedBySpaceOrEnd {
                        // Include both dashes in the preceding clause; drop them
                        // from the boundary so the next clause starts clean.
                        let endOfClause = trimmed.index(before: prev)
                        let clause = trimmed[start...endOfClause]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clause.isEmpty { clauses.append(clause) }
                        i = skipWhitespace(trimmed, from: afterDashes)
                        start = i
                        continue
                    }
                }
            }

            if c == "." || c == "!" || c == "?" {
                let atEnd = next == trimmed.endIndex
                let followedBySpace = !atEnd && trimmed[next].isWhitespace
                if atEnd || followedBySpace {
                    let clause = trimmed[start...i]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clause.isEmpty { clauses.append(clause) }
                    i = skipWhitespace(trimmed, from: next)
                    start = i
                    continue
                }
            }

            i = next
        }

        let tail = trimmed[start...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { clauses.append(tail) }

        return clauses.isEmpty ? [trimmed] : clauses
    }

    // MARK: - Kinds that may speak

    static func isShortAnswer(_ text: String) -> Bool {
        text.count <= shortLimit && lineCount(text) <= 3
    }

    static func isPermissionQuestion(_ text: String) -> Bool {
        guard text.contains("?") else { return false }
        let lowered = text.lowercased()
        return lowered.contains("may i")
            || lowered.contains("can i")
            || lowered.contains("allow")
            || lowered.contains("approve")
            || lowered.contains("permission")
    }

    static func isTaskDone(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return [
            "that's done", "thats done", "all done",
            "i'll work on that", "i’ll work on that",
            "created the", "sent the", "saved the",
            "uploaded", "moved ", "copied ", "wrote ",
            "finished", "completed",
        ].contains { lowered.contains($0) }
            || lowered == "done."
            || lowered == "done"
    }

    // MARK: - Kinds that must stay silent

    static func containsURL(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("https://")
            || lowered.contains("http://")
            || lowered.contains("www.")
    }

    static func containsToolName(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return toolMarks.contains { lowered.contains($0) }
    }

    static func containsCode(_ text: String) -> Bool {
        if text.contains("```") || text.contains("#!/") { return true }
        let codeish = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                line.hasPrefix("func ")
                    || line.hasPrefix("import ")
                    || line.hasPrefix("struct ")
                    || line.hasPrefix("class ")
                    || line.hasPrefix("enum ")
                    || line.hasPrefix("def ")
                    || line.hasPrefix("const ")
                    || line.hasPrefix("{")
                    || line.hasSuffix("{")
                    || line == "}"
                    || line.hasPrefix("}")
            }
        return codeish.count >= 2
    }

    static func isFileListing(_ text: String) -> Bool {
        let fileLines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && looksLikeFileLine($0) }
        return fileLines.count >= 3
    }

    static func isLongListing(_ text: String) -> Bool {
        lineCount(text) >= 4
    }

    // MARK: - Self-test

    /// Pure policy cases plus synthesizer interrupt / clause-queue checks.
    /// No speaker, no `--selftest-tts` wiring — call this directly.
    /// Prints `TTS_OK` / `TTS_FAILED` last. Never calls `RunLog.record`.
    @MainActor
    @discardableResult
    static func runSelfTest() -> Bool {
        var failures = policyFailures()
        failures += AgentSpeechSynthesizer.runInterruptSelfTest()
        failures += AgentSpeechSynthesizer.runStreamSelfTest()
        if failures.isEmpty {
            print("TTS_OK")
            return true
        }
        for failure in failures {
            print("  \(failure)")
        }
        print("TTS_FAILED")
        return false
    }

    /// Clause-stream helper. Prints `TTS_STREAM_OK` / `TTS_STREAM_FAILED` last
    /// for the clause-queue checks, then runs the incremental token-stream
    /// probe (`TTS_TOKEN_STREAM_OK` / `FAILED`). Not a new NextNotesApp flag —
    /// `--selftest-tts-stream` already calls this.
    @MainActor
    @discardableResult
    static func runStreamSelfTest() -> Bool {
        var failures = clauseFailures()
        failures += AgentSpeechSynthesizer.runStreamSelfTest()
        let streamOk: Bool
        if failures.isEmpty {
            print("TTS_STREAM_OK")
            streamOk = true
        } else {
            for failure in failures {
                print("  \(failure)")
            }
            print("TTS_STREAM_FAILED")
            streamOk = false
        }
        let tokenOk = StreamingSpeechBuffer.runTokenStreamSelfTest()
        return streamOk && tokenOk
    }

    /// Incremental append → early first-clause speak. Prints
    /// `TTS_TOKEN_STREAM_OK` / `TTS_TOKEN_STREAM_FAILED`. Not wired into
    /// `NextNotesApp` — harness follow-up.
    @MainActor
    @discardableResult
    static func runTokenStreamSelfTest() -> Bool {
        StreamingSpeechBuffer.runTokenStreamSelfTest()
    }

    /// Policy vectors only. No MainActor, no audio.
    static func policyFailures() -> [String] {
        var failures: [String] = []

        let listing = """
            - /Users/me/Documents/Enclosure_v17.step  2.1 MB  Sep 13, 2026
            - /Users/me/Documents/Enclosure_v16.step  2.0 MB  Sep 12, 2026
            - /Users/me/Documents/Enclosure_v15.step  1.9 MB  Sep 11, 2026
            - /Users/me/Documents/notes.txt  12 KB  Sep 10, 2026
            """
        let listingSpoken = spokenForm(listing)
        if !listingSpoken.isEmpty {
            failures.append("long listing should be silent, got “\(listingSpoken)”")
        }

        let short = "I found three files."
        let shortSpoken = spokenForm(short)
        if shortSpoken != short {
            failures.append("“I found three files.” should speak as itself, got “\(shortSpoken)”")
        }

        let url = "Open https://example.com/doc for the write-up."
        if !spokenForm(url).isEmpty {
            failures.append("URL replies must stay silent")
        }

        let tool = "Executing shell.run /usr/bin/find ."
        if !spokenForm(tool).isEmpty {
            failures.append("tool-name replies must stay silent")
        }

        let code = """
            ```
            func handle() {
                return
            }
            ```
            """
        if !spokenForm(code).isEmpty {
            failures.append("code replies must stay silent")
        }

        let permission = "May I run a shell command in your Documents folder?"
        if spokenForm(permission) != permission {
            failures.append("permission questions should speak, got “\(spokenForm(permission))”")
        }

        let done = "Created the event “Follow-up”."
        if spokenForm(done) != done {
            failures.append("task-done replies should speak, got “\(spokenForm(done))”")
        }

        failures += clauseFailures()
        return failures
    }

    /// Multi-sentence / semicolon / em-dash → multiple clauses; silence stays empty.
    static func clauseFailures() -> [String] {
        var failures: [String] = []

        let multi = "I found three files. The latest is enclosure version seventeen."
        let multiClauses = spokenClauses(multi)
        if multiClauses != [
            "I found three files.",
            "The latest is enclosure version seventeen.",
        ] {
            failures.append("multi-sentence should yield two clauses, got \(multiClauses)")
        }

        let semi = "I saved the draft; it's ready to send."
        let semiClauses = spokenClauses(semi)
        if semiClauses.count != 2
            || semiClauses[0] != "I saved the draft;"
            || semiClauses[1] != "it's ready to send."
        {
            failures.append("semicolon should yield two clauses, got \(semiClauses)")
        }

        let em = "That's done — I created the follow-up."
        let emClauses = spokenClauses(em)
        if emClauses.count != 2
            || emClauses[0] != "That's done —"
            || emClauses[1] != "I created the follow-up."
        {
            failures.append("em-dash should yield two clauses, got \(emClauses)")
        }

        let asciiDash = "All done -- I finished the upload."
        let asciiClauses = spokenClauses(asciiDash)
        if asciiClauses.count != 2
            || asciiClauses[0] != "All done"
            || asciiClauses[1] != "I finished the upload."
        {
            failures.append("ASCII em-dash should yield two clauses, got \(asciiClauses)")
        }

        let listing = """
            - /Users/me/a.step
            - /Users/me/b.step
            - /Users/me/c.step
            - /Users/me/d.txt
            """
        if !spokenClauses(listing).isEmpty {
            failures.append("silent listings must yield no clauses")
        }

        let single = "I found three files."
        if spokenClauses(single) != [single] {
            failures.append("single sentence should be one clause, got \(spokenClauses(single))")
        }

        return failures
    }

    // MARK: - Private

    private static let toolMarks: [String] = [
        "filesystem.", "computer.", "shell.run", "shell.status", "shell.cancel",
        "browser.", "meeting.", "workspace.", "mcp.",
        "search_email", "get_agenda", "find_drive_files",
        "inspect_ui", "active_app",
    ]

    private static func lineCount(_ text: String) -> Int {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).count
    }

    private static func looksLikeFileLine(_ line: String) -> Bool {
        let body = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        if body.hasPrefix("/") || body.hasPrefix("~") { return true }
        if body.contains("/") && body.contains(".") { return true }
        return body.range(of: #"\.[A-Za-z0-9]{1,8}(?:\s|$)"#, options: .regularExpression) != nil
    }

    private static func skipWhitespace(_ text: String, from index: String.Index) -> String.Index {
        var i = index
        while i < text.endIndex, text[i].isWhitespace {
            i = text.index(after: i)
        }
        return i
    }
}
