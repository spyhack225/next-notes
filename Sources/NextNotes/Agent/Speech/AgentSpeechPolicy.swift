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

    /// Immediate voice form of a verified tool result. The full result remains in
    /// the text conversation. This path runs no model and never reads an opaque
    /// identifier, URL, path, or multiline listing to the speaker.
    static func toolResultSummary(toolID: String, result: String) -> String? {
        let lines = result.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // A single raw result row may fit the ordinary short-answer budget but
        // still contain an opaque mail ID, a file path, or a bullet.
        if !lines.contains(where: { $0.hasPrefix("- ") }),
           !spokenForm(result).isEmpty { return result }
        if toolID.hasPrefix("memory."), toolID != "memory.recall",
           let first = lines.first, !first.isEmpty, !spokenForm(first).isEmpty {
            return first
        }
        switch toolID {
        case "get_agenda":
            let events = lines.filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
            guard !events.isEmpty else { break }
            let first = events[0].replacingOccurrences(of: " — ", with: ", ")
            let intro = "I found \(events.count) calendar "
                + (events.count == 1 ? "event" : "events")
            let details = events.prefix(3).map {
                String($0.replacingOccurrences(of: " — ", with: ", ").prefix(90))
            }
            let candidate = intro + ". " + (events.count == 1
                ? "It's \(String(first.prefix(140)))."
                : "They include \(details.joined(separator: "; ")).")
            return spokenForm(candidate).isEmpty
                ? "I found \(events.count) calendar events. The details are in the conversation."
                : candidate
        case "search_email":
            let emails = lines.filter { $0.hasPrefix("- id ") }
            guard let first = emails.first else { break }
            let pieces = first.components(separatedBy: " — ")
            let intro = "I found \(emails.count) matching "
                + (emails.count == 1 ? "email" : "emails")
            guard pieces.count >= 3 else { return intro + "." }
            let sender = pieces[1].replacingOccurrences(of: "from ", with: "")
            let subject = pieces[2]
            let candidate = intro + ". The latest is from "
                + "\(String(sender.prefix(70))), about \(String(subject.prefix(100)))."
            return spokenForm(candidate).isEmpty
                ? intro + ". The details are in the conversation."
                : candidate
        case "filesystem.search", "find_drive_files":
            let matches = lines.filter { $0.hasPrefix("- ") }
            if !matches.isEmpty {
                return "I found \(matches.count) matching files. The details are in the conversation."
            }
        default: break
        }
        return result.isEmpty ? nil
            : "I have the result, but its details are easier to read in the conversation."
    }

    // MARK: - Memory confirmations

    enum MemoryAction: Sendable {
        case saved
        case updated
        case forgotten
        case alreadyKnown
    }

    /// The one sentence the Agent says after an in-conversation memory write, so a memory
    /// is never saved silently: "Noted — you prefer short answers." The stored text is
    /// third person ("The user prefers…"); the spoken form addresses the user.
    static func memoryConfirmation(_ action: MemoryAction, text: String) -> String {
        var fact = secondPerson(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = fact.last, ".!?".contains(last) { fact.removeLast() }
        let sentence: String = switch action {
        case .saved: "Noted — \(fact)."
        case .updated: "Updated — \(fact)."
        case .forgotten: "Forgotten — I no longer remember that \(fact)."
        case .alreadyKnown: "I already remember that \(fact)."
        }
        guard !fact.isEmpty, sentence.count <= 220, !spokenForm(sentence).isEmpty else {
            return switch action {
            case .saved: "Noted — I saved that to memory."
            case .updated: "Updated — I changed that memory."
            case .forgotten: "Forgotten — I removed that memory."
            case .alreadyKnown: "I already remember that."
            }
        }
        return sentence
    }

    /// "The user prefers short answers" → "you prefer short answers". Handles the subject
    /// and possessive, and the verb (or adverb + verb) right after the subject.
    static func secondPerson(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return text }
        var index = 0
        var changedSubject = false
        while index < words.count {
            let lowered = words[index].lowercased()
            let next = index + 1 < words.count ? words[index + 1].lowercased() : ""
            if lowered == "the", next == "user's" || next == "user’s" {
                words.replaceSubrange(index...(index + 1), with: ["your"])
            } else if lowered == "the", next == "user" {
                words.replaceSubrange(index...(index + 1), with: ["you"])
                changedSubject = true
                var verb = index + 1
                if verb < words.count, words[verb].lowercased().hasSuffix("ly") { verb += 1 }
                if verb < words.count { words[verb] = baseVerb(words[verb]) }
            }
            index += 1
        }
        // A sentence-initial article reads mid-sentence after "Noted —"; a name keeps its capital.
        if !changedSubject, let first = words.first, ["The", "A", "An"].contains(first) {
            words[0] = first.lowercased()
        }
        return words.joined(separator: " ")
    }

    private static func baseVerb(_ word: String) -> String {
        let lowered = word.lowercased()
        let irregular = ["is": "are", "has": "have", "was": "were", "does": "do", "goes": "go",
                         "doesn't": "don't", "isn't": "aren't", "wasn't": "weren't", "hasn't": "haven't"]
        if let base = irregular[lowered] { return base }
        guard lowered.count > 3, lowered.hasSuffix("s"), !lowered.hasSuffix("ss") else { return word }
        if lowered.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        for ending in ["ches", "shes", "sses", "xes", "zes"] where lowered.hasSuffix(ending) {
            return String(word.dropLast(2))
        }
        return String(word.dropLast())
    }

    /// Streaming guard used after a clause may already have started. Once unsafe
    /// content appears, queued speech is stopped so URLs, tool output and code never
    /// continue through the speaker.
    static func isUnsafeForStreaming(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return containsURL(trimmed)
            || containsToolName(trimmed)
            || containsCode(trimmed)
            || isFileListing(trimmed)
            || isLongListing(trimmed)
            || trimmed.count > spokenCap
            || lineCount(trimmed) > 3
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

        let agenda = """
            On Monday, September 14, 2026:
            - 9:00 AM — Weekly plan
            - 10:00 AM — Design review
            - 2:00 PM — Planning
            """
        let agendaSummary = toolResultSummary(toolID: "get_agenda", result: agenda) ?? ""
        if agendaSummary != "I found 3 calendar events. They include 9:00 AM, Weekly plan; 10:00 AM, Design review; 2:00 PM, Planning." {
            failures.append("calendar listing did not produce a concise voice answer: \(agendaSummary)")
        }
        if spokenForm(agendaSummary).isEmpty {
            failures.append("calendar voice answer was not speakable")
        }
        let unsafeAgenda = "On Monday:\n- 9:00 AM — https://example.com/private"
        if toolResultSummary(toolID: "get_agenda", result: unsafeAgenda)?.contains("https://") == true {
            failures.append("calendar voice answer spoke a URL")
        }
        let oneEvent = "On Monday:\n- 9:00 AM — Weekly plan"
        if toolResultSummary(toolID: "get_agenda", result: oneEvent) != "I found 1 calendar event. It's 9:00 AM, Weekly plan." {
            failures.append("single calendar row was read as a raw listing")
        }
        let oneMail = "- id opaque123 — from Alex — Project review"
        let mailSummary = toolResultSummary(toolID: "search_email", result: oneMail) ?? ""
        if mailSummary.contains("opaque123") || mailSummary != "I found 1 matching email. The latest is from Alex, about Project review." {
            failures.append("single mail row exposed an opaque ID")
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
        "memory.remember", "memory.update", "memory.forget", "memory.recall",
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
