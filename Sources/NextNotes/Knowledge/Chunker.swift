import Foundation

/// One row of an Agent conversation, as the chunker needs it. Decoupled from
/// `AgentSession.Message` so the rules are pure and run off the main actor.
struct KnowledgeConversationRow: Equatable, Sendable {
    var role: String
    var text: String
    var contextKind: String? = nil
    var source: String? = nil
    var at: Date
}

/// An ended Agent session, ready to chunk.
struct KnowledgeConversationSession: Equatable, Sendable {
    var id: UUID
    var rows: [KnowledgeConversationRow]
}

/// A routine run's final output.
struct KnowledgeRoutineRun: Equatable, Sendable {
    var id: UUID
    var text: String
    var at: Date
}

/// A dictation, whole.
struct KnowledgeDictation: Equatable, Sendable {
    var id: UUID
    var text: String
    var at: Date
}

/// Transcript, notes, conversation, routine and dictation → `[KnowledgeChunk]`.
///
/// A chunk is one retrievable passage — the ninety seconds inside a meeting where the thing
/// was said, not the meeting:
///
/// - **transcript** — a run of consecutive segments from one speaker, cut at the first pause
///   after ~150 words and hard cut at ~300. A cut for length overlaps the next chunk by one
///   segment, because the answer usually straddles the boundary; a change of speaker starts
///   a fresh chunk with no overlap, so every chunk has exactly one speaker. Agent commands
///   spoken during a meeting stay out, as they stay out of the notes.
/// - **notes** — one bullet or one paragraph under one heading; `_None._` is not a passage.
/// - **conversation** — one user turn with the Agent's plain reply. Tool-backed rows, the
///   routine offer and meeting lines are excluded: tool output is not what the user said.
/// - **routine** — one run's final output. **dictation** — one run, whole.
///
/// Pure and `nonisolated`, so `--selftest-index` checks each rule directly.
enum Chunker {
    static let targetWords = 150
    static let hardWords = 300
    /// A gap between segments at least this long is a pause worth cutting at.
    static let pauseSeconds: TimeInterval = 0.8

    // MARK: - Transcript

    private struct Piece {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var speaker: String
        var words: Int
    }

    static func transcript(
        _ segments: [TranscriptSegment], meetingStart: Date, speakerNames: [String: String] = [:]
    ) -> [KnowledgeChunk] {
        let pieces = segments
            .filter { $0.includeInMeetingNotes }
            .sorted { $0.start < $1.start }
            .flatMap { segment -> [Piece] in
                let text = collapsed(segment.text)
                guard !text.isEmpty else { return [] }
                let speaker = speakerNames[segment.displaySpeaker] ?? segment.displaySpeaker
                return split(Piece(start: segment.start, end: max(segment.end, segment.start), text: text,
                                   speaker: speaker, words: wordCount(text)))
            }

        var chunks: [KnowledgeChunk] = []
        var current: [Piece] = []
        var words = 0
        /// How many leading pieces of `current` are the overlap carried from the last chunk.
        var carried = 0

        func flush(overlap: Bool) {
            guard current.count > carried, let first = current.first, let last = current.last else {
                current = []
                words = 0
                carried = 0
                return
            }
            chunks.append(KnowledgeChunk(
                ordinal: chunks.count,
                text: current.map(\.text).joined(separator: " "),
                startTime: first.start,
                endTime: last.end,
                speaker: first.speaker,
                occurredAt: Int64((meetingStart.timeIntervalSince1970 + first.start).rounded(.down))
            ))
            if overlap, current.count > 1 {
                current = [last]
                words = last.words
                carried = 1
            } else {
                current = []
                words = 0
                carried = 0
            }
        }

        for piece in pieces {
            if let last = current.last {
                let fresh = current.count > carried
                if last.speaker != piece.speaker {
                    flush(overlap: false)
                } else if fresh, words >= hardWords || (words >= targetWords && piece.start - last.end >= pauseSeconds) {
                    flush(overlap: true)
                } else if fresh, words + piece.words > hardWords {
                    // The hard cut holds whatever the run's length: a short run followed by
                    // a long segment is two chunks, not one past the limit.
                    flush(overlap: true)
                }
            }
            // The overlap gives way when it and the next piece together would pass the hard cut.
            if carried > 0, current.count == carried, words + piece.words > hardWords {
                current = []
                words = 0
                carried = 0
            }
            current.append(piece)
            words += piece.words
        }
        flush(overlap: false)
        return chunks
    }

    /// A single segment longer than the hard cut becomes several, with time shared out by
    /// word position — rare (Parakeet windows are short) but a monologue must not become one
    /// thousand-word passage.
    private static func split(_ piece: Piece) -> [Piece] {
        guard piece.words > hardWords else { return [piece] }
        let tokens = piece.text.split(separator: " ")
        let duration = piece.end - piece.start
        var result: [Piece] = []
        var index = 0
        while index < tokens.count {
            let upper = min(tokens.count, index + targetWords)
            let start = piece.start + duration * Double(index) / Double(tokens.count)
            let end = piece.start + duration * Double(upper) / Double(tokens.count)
            result.append(Piece(start: start, end: end, text: tokens[index..<upper].joined(separator: " "),
                                speaker: piece.speaker, words: upper - index))
            index = upper
        }
        return result
    }

    // MARK: - Notes

    static func notes(_ markdown: String, meetingStart: Date) -> [KnowledgeChunk] {
        let occurredAt = Int64(meetingStart.timeIntervalSince1970.rounded(.down))
        var chunks: [KnowledgeChunk] = []
        var heading: String?
        // The Related context section is what Next Notes already knew before the meeting —
        // memory, prior decisions, file names — not something anyone said. Indexing it would
        // put memory facts into search under a meeting's citation, and `KnowledgeExtractor`
        // would turn them into decisions and entities that were never spoken. It is
        // deliberately not part of the record.
        var skipping = false
        var item: [String] = []

        func flush() {
            let text = collapsed(item.joined(separator: " "))
            item = []
            guard !skipping, !text.isEmpty, text != NotesPrompts.emptyMarker, text != "None." else { return }
            chunks.append(KnowledgeChunk(ordinal: chunks.count, text: text, heading: heading, occurredAt: occurredAt))
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let match = line.firstMatch(of: /^#{1,6}\s+(.+)$/) {
                flush()
                let name = plain(String(match.1))
                skipping = name == NotesPrompts.relatedHeading
                heading = skipping ? nil : name
                continue
            }
            if skipping { continue }
            if let match = line.firstMatch(of: /^(?:[-*+]|\d+[.)])\s+(.*)$/) {
                flush()
                item = [plain(String(match.1))]
                continue
            }
            // An indented continuation of a bullet, or the next line of a paragraph.
            item.append(plain(line))
        }
        flush()
        return chunks
    }

    /// Markdown emphasis and code marks removed; the words are what is searched.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Conversation

    static func conversation(_ rows: [KnowledgeConversationRow]) -> [KnowledgeChunk] {
        var chunks: [KnowledgeChunk] = []
        var user: KnowledgeConversationRow?
        var replies: [String] = []

        func flush() {
            defer {
                user = nil
                replies = []
            }
            guard let user else { return }
            let said = collapsed(user.text)
            guard !said.isEmpty else { return }
            var lines = ["User: \(said)"]
            let reply = collapsed(replies.joined(separator: " "))
            if !reply.isEmpty { lines.append("Agent: \(reply)") }
            chunks.append(KnowledgeChunk(ordinal: chunks.count, text: lines.joined(separator: "\n"),
                                         occurredAt: Int64(user.at.timeIntervalSince1970.rounded(.down))))
        }

        for row in rows {
            switch row.role {
            case "user":
                flush()
                // A meeting line is evidence the transcript already holds, not the user
                // talking to the Agent.
                if row.source != "meeting" { user = row }
            case "assistant":
                // A tool-backed reply carries tool output; the routine offer is not a reply.
                guard user != nil, row.contextKind == nil else { continue }
                replies.append(row.text)
            default:
                continue
            }
        }
        flush()
        return chunks
    }

    // MARK: - Routine and dictation

    static func routine(_ run: KnowledgeRoutineRun) -> [KnowledgeChunk] {
        single(run.text, at: run.at)
    }

    static func dictation(_ run: KnowledgeDictation) -> [KnowledgeChunk] {
        single(run.text, at: run.at)
    }

    private static func single(_ raw: String, at: Date) -> [KnowledgeChunk] {
        let text = collapsed(raw)
        guard !text.isEmpty else { return [] }
        return [KnowledgeChunk(ordinal: 0, text: text, occurredAt: Int64(at.timeIntervalSince1970.rounded(.down)))]
    }

    // MARK: - Text

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
