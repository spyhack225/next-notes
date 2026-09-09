import Foundation

/// Turns a meeting transcript into the markdown that lands in `notes.md`.
///
/// Two paths, chosen by arithmetic rather than by preference: if the whole transcript fits
/// the provider's context it is read in one piece, because a model that has seen the whole
/// conversation is the only one that can tell a decision from a suggestion. When it doesn't
/// fit — always, on Apple's 4K window, for anything past a quarter of an hour — the
/// transcript is mapped to facts chunk by chunk and reduced to notes from those. The reduce
/// step reuses the single-pass prompt, so both paths produce the same shape.
struct NotesGenerator: Sendable {
    /// Reported so the `.summarizing` state can say what it is doing. A meeting that has
    /// been "Writing notes" for four minutes with no further detail looks hung.
    struct Step: Sendable {
        let message: String
        /// 0…1, or nil while the work has no measurable length.
        let fraction: Double?
    }

    typealias ProgressHandler = @Sendable (Step) -> Void

    struct Result: Sendable {
        let markdown: String
        let providerID: LLMProviderID
        let generatedTokens: Int
        let duration: TimeInterval
        let usedMapReduce: Bool

        var tokensPerSecond: Double {
            duration > 0 ? Double(generatedTokens) / duration : 0
        }
    }

    let provider: any LLMProvider

    /// Held back from the prompt for the system message and the notes themselves.
    private static let reservedTokens = 1_536
    /// The system prompt, the chat template and the meeting header, which the transcript's
    /// own token count doesn't include. Subtracted again when the output is budgeted, so a
    /// transcript that exactly fills the reserve still leaves room for an answer.
    private static let promptOverheadTokens = 512
    /// Matches the runtime's own headroom, so a prompt this generator accepts is never one
    /// the runtime then refuses.
    private static let runtimeHeadroomTokens = 256
    /// Notes longer than this are a transcript with bullet points in front of it.
    private static let maxNotesTokens = 1_500
    /// One chunk's worth of transcript in the map step.
    private static let qwenChunkTokens = 3_000
    private static let appleChunkTokens = 2_000
    /// A chunk's facts are far shorter than the chunk.
    private static let maxFactTokens = 600

    init(provider: any LLMProvider) {
        self.provider = provider
    }

    func notes(
        for meeting: Meeting,
        segments: [TranscriptSegment],
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> Result {
        let transcript = segments.plainText(speakerNames: meeting.speakerNames)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotesError.emptyTranscript
        }

        let began = Date()
        progress(Step(message: "Reading the transcript\u{2026}", fraction: nil))
        let transcriptTokens = try await provider.countTokens(transcript)
        let budget = provider.contextTokens - Self.reservedTokens
        guard budget > 0 else { throw NotesError.contextTooSmall }

        if transcriptTokens <= budget {
            progress(Step(message: "Writing notes\u{2026}", fraction: nil))
            let completion = try await provider.complete(
                system: NotesPrompts.notesSystem,
                user: NotesPrompts.notesUser(meeting: meeting, transcript: transcript),
                maxTokens: outputBudget(promptTokens: transcriptTokens)
            )
            let markdown = NotesFormatter.tidy(completion.text)
            guard !NotesFormatter.isBlank(markdown) else { throw NotesError.emptyNotes }
            return Result(
                markdown: markdown,
                providerID: provider.id,
                generatedTokens: completion.generatedTokens,
                duration: Date().timeIntervalSince(began),
                usedMapReduce: false
            )
        }

        return try await mapReduce(
            meeting: meeting,
            segments: segments,
            transcript: transcript,
            transcriptTokens: transcriptTokens,
            budget: budget,
            began: began,
            progress: progress
        )
    }

    // MARK: - Map / reduce

    private func mapReduce(
        meeting: Meeting,
        segments: [TranscriptSegment],
        transcript: String,
        transcriptTokens: Int,
        budget: Int,
        began: Date,
        progress: @escaping ProgressHandler
    ) async throws -> Result {
        let chunks = Self.chunk(
            segments,
            speakerNames: meeting.speakerNames,
            targetTokens: min(chunkTokens, budget),
            transcriptCharacters: transcript.count,
            transcriptTokens: transcriptTokens
        )
        guard !chunks.isEmpty else { throw NotesError.emptyTranscript }

        var facts: [String] = []
        var generated = 0
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // The map step's own progress is the only honest number in the whole operation:
            // the reduce that follows is one generation of unknown length.
            progress(Step(
                message: "Reading part \(index + 1) of \(chunks.count)\u{2026}",
                fraction: Double(index) / Double(chunks.count + 1)
            ))
            let completion = try await provider.complete(
                system: NotesPrompts.mapSystem,
                user: NotesPrompts.mapUser(
                    meeting: meeting,
                    part: index + 1,
                    of: chunks.count,
                    transcript: chunk
                ),
                maxTokens: Self.maxFactTokens
            )
            generated += completion.generatedTokens
            let cleaned = NotesFormatter.stripThinking(completion.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { facts.append(cleaned) }
        }

        try Task.checkCancellation()
        progress(Step(
            message: "Writing notes\u{2026}",
            fraction: Double(chunks.count) / Double(chunks.count + 1)
        ))

        // The facts can themselves outgrow the window on a very long meeting. Trimming the
        // oldest is the least-bad answer: the end of a meeting is where its decisions are.
        var joined = facts.joined(separator: "\n")
        while try await provider.countTokens(joined) > budget, facts.count > 1 {
            facts.removeFirst()
            joined = facts.joined(separator: "\n")
        }

        let factTokens = try await provider.countTokens(joined)
        let completion = try await provider.complete(
            system: NotesPrompts.reduceSystem,
            user: NotesPrompts.reduceUser(meeting: meeting, facts: joined),
            maxTokens: outputBudget(promptTokens: factTokens)
        )
        generated += completion.generatedTokens

        let markdown = NotesFormatter.tidy(completion.text)
        guard !NotesFormatter.isBlank(markdown) else { throw NotesError.emptyNotes }
        return Result(
            markdown: markdown,
            providerID: provider.id,
            generatedTokens: generated,
            duration: Date().timeIntervalSince(began),
            usedMapReduce: true
        )
    }

    private var chunkTokens: Int {
        switch provider.id {
        case .qwen35_4b: Self.qwenChunkTokens
        case .appleFoundation: Self.appleChunkTokens
        }
    }

    /// How many tokens the answer may use, given what the prompt already spent.
    ///
    /// Every provider shares one window between prompt and response, so a transcript that
    /// fills the whole transcript budget has to leave the notes somewhere to go. Without
    /// this, the longest meetings — the ones that most need summarising — are exactly the
    /// ones the runtime rejects.
    private func outputBudget(promptTokens: Int) -> Int {
        let remaining = provider.contextTokens
            - promptTokens
            - Self.promptOverheadTokens
            - Self.runtimeHeadroomTokens
        return max(Self.minNotesTokens, min(Self.maxNotesTokens, remaining))
    }

    /// Below this there is no room to write anything worth keeping, and the caller is
    /// better served by the runtime refusing the prompt outright.
    private static let minNotesTokens = 256

    /// Splits the transcript at segment boundaries into pieces of roughly `targetTokens`.
    ///
    /// Sized by characters against one measured tokens-per-character ratio rather than by
    /// tokenizing each segment: a two-hour meeting is thousands of segments, and thousands
    /// of round trips into the tokenizer to place a chunk boundary is minutes of work to
    /// answer a question that only needs to be roughly right. Chunks are deliberately under
    /// budget, so an estimate that is a few percent low costs a little context, not a
    /// rejected prompt.
    static func chunk(
        _ segments: [TranscriptSegment],
        speakerNames: [String: String],
        targetTokens: Int,
        transcriptCharacters: Int,
        transcriptTokens: Int
    ) -> [String] {
        guard targetTokens > 0, !segments.isEmpty else { return [] }
        let charactersPerToken = max(1.0, Double(transcriptCharacters) / Double(max(1, transcriptTokens)))
        let targetCharacters = Int(Double(targetTokens) * charactersPerToken)

        var chunks: [String] = []
        var current: [TranscriptSegment] = []
        var characters = 0

        for segment in segments {
            let line = [segment].plainText(speakerNames: speakerNames)
            if !current.isEmpty, characters + line.count > targetCharacters {
                chunks.append(current.plainText(speakerNames: speakerNames))
                current = []
                characters = 0
            }
            current.append(segment)
            characters += line.count + 1
        }
        if !current.isEmpty {
            chunks.append(current.plainText(speakerNames: speakerNames))
        }
        return chunks
    }
}

/// Makes a model's output into the document the Notes tab expects.
///
/// Two failures are common enough to be worth correcting rather than rejecting: a hybrid
/// reasoning model leaking part of its `<think>` block, and a small model dropping a section
/// it had nothing to put in. Neither is worth losing a whole meeting's notes over.
enum NotesFormatter {
    /// Removes a `<think>` block, and the far more common half of one — the prompt supplies
    /// an already-closed block, so a model that opens a second one often emits only the
    /// closing tag.
    static func stripThinking(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>"),
              let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result
            .replacingOccurrences(of: "</think>", with: "")
            .replacingOccurrences(of: "<think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips a code fence wrapping the entire answer. Models asked for markdown reliably
    /// hand back markdown *inside* a ```markdown fence perhaps one time in five.
    static func stripCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count > 2 else { return trimmed }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The five sections, in order, each present exactly once.
    static func tidy(_ text: String) -> String {
        let cleaned = stripCodeFence(stripThinking(text))
        var sections: [String: [String]] = [:]
        var preamble: [String] = []
        var current: String?

        for line in cleaned.components(separatedBy: .newlines) {
            if let heading = headingName(in: line) {
                current = heading
                if sections[heading] == nil { sections[heading] = [] }
                continue
            }
            if let current {
                sections[current, default: []].append(line)
            } else {
                preamble.append(line)
            }
        }

        // Anything written before the first heading is the summary the model forgot to
        // label — keeping it is strictly better than dropping the one paragraph a reader
        // was most likely to want.
        let orphan = preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !orphan.isEmpty {
            let summary = NotesPrompts.headings[0]
            sections[summary] = [orphan] + (sections[summary] ?? [])
        }

        return NotesPrompts.headings.map { heading in
            let body = (sections[heading] ?? [])
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "## \(heading)\n\(body.isEmpty ? NotesPrompts.emptyMarker : body)"
        }
        .joined(separator: "\n\n") + "\n"
    }

    /// True when every section came back empty — a model that answered with nothing, which
    /// `tidy` would otherwise dress up as a complete document of five empty headings.
    static func isBlank(_ markdown: String) -> Bool {
        markdown
            .components(separatedBy: .newlines)
            .allSatisfy { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty
                    || trimmed == NotesPrompts.emptyMarker
                    || headingName(in: trimmed) != nil
            }
    }

    /// Recognises a section heading however the model chose to mark it up.
    private static func headingName(in line: String) -> String? {
        var candidate = line.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return nil }
        while candidate.hasPrefix("#") { candidate.removeFirst() }
        candidate = candidate
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return nil }
        // Bare text is not a heading: a bullet reading "Decisions were deferred" must not
        // open a section. Only a line that was marked up as one, and matches, counts.
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            || line.trimmingCharacters(in: .whitespaces).hasPrefix("**")
        else { return nil }
        return NotesPrompts.headings.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
    }
}

enum NotesError: LocalizedError {
    case emptyTranscript
    case emptyNotes
    case contextTooSmall
    case noProvider

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "There is nothing in this transcript to write notes from."
        case .emptyNotes:
            "The model found nothing to write about in this transcript."
        case .contextTooSmall:
            "The notes model has no room for a transcript."
        case .noProvider:
            "No notes model is available. Download \(NotesModels.spec.displayName), or turn "
                + "on Apple Intelligence."
        }
    }
}
