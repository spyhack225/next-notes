import Foundation
import FoundationModels

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
        /// Transcript chunks the map step read. 1 on the single-pass path.
        let chunks: Int
        /// Collapse groups the model condensed (M-05). 0 on the single-pass path.
        let collapsedGroups: Int
        /// Facts left out after the collapse pass, always with a visible line.
        let droppedFacts: Int

        var tokensPerSecond: Double {
            duration > 0 ? Double(generatedTokens) / duration : 0
        }
    }

    let provider: any LLMProvider
    /// The role that chose this provider (P0-20b). `meetingNotes` is the only role that
    /// generates notes, so it is the default; a caller that resolved the provider another
    /// way can say so.
    let requestedRole: ModelRole?
    /// Why the pass ran on a model other than the role's, when it did.
    let fallbackReason: UsageFallback?

    /// Held back from the prompt for the notes themselves, on top of the counted
    /// prompt overhead (M-12): the single-pass decision's reserve, and the floor the
    /// answer keeps.
    private static let reservedTokens = 1_536
    /// Slack over the counted system prompt and header (M-12): the chat template and
    /// the scaffolding between the counted strings. An estimate.
    private static let templateSlackTokens = 64
    /// Matches the runtime's own headroom, so a prompt this generator accepts is never one
    /// the runtime then refuses.
    private static let runtimeHeadroomTokens = 256
    /// The notes cap, scaled with the meeting's length (M-13).
    ///
    /// One flat number is wrong in both directions: 1,500 tokens is a lot of notes for a
    /// ten-minute call and too few for an hour, and the meetings that run out of room are
    /// exactly the long ones. Ten minutes keeps 1,000, an hour gets 2,000, and 3,000 is the
    /// ceiling — past that a longer answer is a transcript with bullet points in front of
    /// it. `outputBudget` still clamps by what the window has left.
    static func maxNotesTokens(minutes: Int) -> Int {
        min(notesTokenCeiling, notesTokenBase + notesTokenPerMinute * max(0, minutes))
    }

    private static let notesTokenBase = 800
    private static let notesTokenPerMinute = 20
    private static let notesTokenCeiling = 3_000

    /// How long the meeting was, for the cap that scales with it (M-13): the recording's
    /// own length when it stopped, else the transcript's span. An interrupted meeting has
    /// no `end`, and its notes still deserve a cap that matches how much was said.
    static func notesMinutes(meeting: Meeting, segments: [TranscriptSegment]) -> Int {
        let recorded = meeting.duration ?? 0
        let spoken = segments.last.map { $0.end - (segments.first?.start ?? 0) } ?? 0
        return max(1, Int((max(recorded, spoken) / 60).rounded()))
    }

    /// A map chunk never exceeds this, however large the window (M-12): the map step
    /// reads slices so the reduce has facts, not a second transcript.
    private static let maxChunkTokens = 6_000
    /// The floor under the derived chunk size, so a small window still reads.
    private static let minChunkTokens = 1_000
    /// A chunk's facts are far shorter than the chunk.
    private static let maxFactTokens = 600
    /// The retry's chunks (M-12): 70 % of the derived size.
    static let retryChunkFactor = 0.7
    /// How many times the collapse pass may re-condense the facts before the last
    /// resort: a visible line saying what was left out. A model that ignores the
    /// collapse instruction hits this cap and the line, which is honest.
    static let collapseMaxRounds = 3

    init(
        provider: any LLMProvider,
        requestedRole: ModelRole? = .meetingNotes,
        fallbackReason: UsageFallback? = nil
    ) {
        self.provider = provider
        self.requestedRole = requestedRole
        self.fallbackReason = fallbackReason
    }

    func notes(
        for meeting: Meeting,
        segments: [TranscriptSegment],
        brief: MeetingNotesBrief = .empty,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> Result {
        let transcript = segments.plainText(speakerNames: meeting.speakerNames)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotesError.emptyTranscript
        }

        let began = Date()
        progress(Step(message: "Reading the transcript\u{2026}", fraction: nil))
        let transcriptTokens = try await provider.countTokens(transcript)
        // The brief shares the window with the transcript, so it is counted before the
        // single-pass decision rather than after it: an uncounted block is a prompt the
        // runtime rejects on exactly the meetings that have the most context to add.
        let block = brief.promptBlock
        let briefTokens = block.isEmpty ? 0 : try await provider.countTokens(block)
        // The window cost counted, not assumed (M-12): the system prompt, the meeting
        // header and the scaffolding of an empty message, with slack. Used by the
        // single-pass decision and by `outputBudget`, once per call.
        let overhead = try await countedOverhead(
            system: NotesPrompts.notesSystem,
            user: NotesPrompts.notesUser(meeting: meeting, transcript: ""))
        let budget = provider.contextTokens - Self.reservedTokens
        guard budget > 0 else { throw NotesError.contextTooSmall }

        if transcriptTokens + briefTokens + overhead <= budget {
            progress(Step(message: "Writing notes\u{2026}", fraction: nil))
            let answer: Answer
            do {
                answer = try await answerWithRetry(
                    feature: .meetingNotesSingle,
                    pass: "single",
                    meetingID: meeting.id,
                    system: NotesPrompts.notesSystem,
                    user: NotesPrompts.notesUser(meeting: meeting, transcript: transcript, brief: brief),
                    promptTokens: transcriptTokens + briefTokens,
                    overhead: overhead,
                    cap: Self.maxNotesTokens(
                        minutes: Self.notesMinutes(meeting: meeting, segments: segments))
                )
            } catch let overflow where Self.isContextOverflow(overflow) {
                // The estimate said one pass and the model refused the prompt (M-12):
                // one retry through map-reduce, with the chunks shrunk to 70 %. A second
                // refusal there ends as a plain sentence, not a raw error.
                progress(Step(
                    message: "The transcript is longer than it looked; reading it in parts\u{2026}",
                    fraction: nil))
                return try await mapReduce(
                    meeting: meeting,
                    segments: segments,
                    transcript: transcript,
                    transcriptTokens: transcriptTokens,
                    brief: brief,
                    briefTokens: briefTokens,
                    budget: budget,
                    overheadTokens: overhead,
                    began: began,
                    progress: progress,
                    chunkFactor: Self.retryChunkFactor,
                    allowRetry: false
                )
            }
            // M-13: a cut-off answer says so on the page. `tidy` wrote `_None._` under
            // every section the model never reached, which reads as "nothing was decided"
            // — the one claim a cut-off document cannot support.
            var markdown = NotesFormatter.tidy(answer.completion.text, cutShort: answer.cutShort)
            // No Known context block means there is nothing true to connect, and a model
            // asked for the section writes one anyway. The prompt says the empty marker;
            // this is what makes that true. It runs after `tidy` on purpose: with no brief
            // there is nothing to connect, truncation or not.
            if brief.isEmpty {
                markdown = NotesFormatter.emptySection(NotesPrompts.relatedHeading, in: markdown)
            }
            guard !NotesFormatter.isBlank(markdown) else { throw NotesError.emptyNotes }
            return Result(
                markdown: markdown,
                providerID: provider.id,
                generatedTokens: answer.tokens,
                duration: Date().timeIntervalSince(began),
                usedMapReduce: false,
                chunks: 1,
                collapsedGroups: 0,
                droppedFacts: 0
            )
        }

        return try await mapReduce(
            meeting: meeting,
            segments: segments,
            transcript: transcript,
            transcriptTokens: transcriptTokens,
            brief: brief,
            briefTokens: briefTokens,
            budget: budget,
            overheadTokens: overhead,
            began: began,
            progress: progress,
            chunkFactor: 1.0,
            allowRetry: true
        )
    }

    // MARK: - Map / reduce

    /// One map-reduce run, with the M-12 overflow retry wrapped around it.
    ///
    /// A context-size refusal anywhere inside — a chunk the map step refuses, a fact
    /// list the collapse could not shrink enough, a reduce prompt over the line —
    /// retries the whole run once with chunks at 70 %. A refusal on that retry, or a
    /// second one when the caller has already retried, is the plain sentence.
    private func mapReduce(
        meeting: Meeting,
        segments: [TranscriptSegment],
        transcript: String,
        transcriptTokens: Int,
        brief: MeetingNotesBrief,
        briefTokens: Int,
        budget: Int,
        overheadTokens: Int,
        began: Date,
        progress: @escaping ProgressHandler,
        chunkFactor: Double,
        allowRetry: Bool
    ) async throws -> Result {
        do {
            return try await mapReduceCore(
                meeting: meeting,
                segments: segments,
                transcript: transcript,
                transcriptTokens: transcriptTokens,
                brief: brief,
                briefTokens: briefTokens,
                budget: budget,
                overheadTokens: overheadTokens,
                began: began,
                progress: progress,
                chunkFactor: chunkFactor
            )
        } catch let overflow where allowRetry && Self.isContextOverflow(overflow) {
            do {
                return try await mapReduceCore(
                    meeting: meeting,
                    segments: segments,
                    transcript: transcript,
                    transcriptTokens: transcriptTokens,
                    brief: brief,
                    briefTokens: briefTokens,
                    budget: budget,
                    overheadTokens: overheadTokens,
                    began: began,
                    progress: progress,
                    chunkFactor: Self.retryChunkFactor
                )
            } catch let second where Self.isContextOverflow(second) {
                throw NotesError.contextTooSmall
            }
        } catch let overflow where Self.isContextOverflow(overflow) {
            throw NotesError.contextTooSmall
        }
    }

    private func mapReduceCore(
        meeting: Meeting,
        segments: [TranscriptSegment],
        transcript: String,
        transcriptTokens: Int,
        brief: MeetingNotesBrief,
        briefTokens: Int,
        budget: Int,
        overheadTokens: Int,
        began: Date,
        progress: @escaping ProgressHandler,
        chunkFactor: Double
    ) async throws -> Result {
        // The chunk size derived from the reader's window (M-12), scaled by the
        // caller's factor on a retry.
        let chunkSize = Self.chunkSize(
            contextTokens: provider.contextTokens,
            mapOverheadTokens: try await countedOverhead(
                system: NotesPrompts.mapSystem,
                user: NotesPrompts.mapUser(meeting: meeting, part: 1, of: 1, transcript: "")))
        let mapTarget = max(1, min(
            Int((Double(chunkSize) * chunkFactor).rounded(.down)), budget))
        let chunks = Self.chunk(
            segments,
            speakerNames: meeting.speakerNames,
            targetTokens: mapTarget,
            transcriptCharacters: transcript.count,
            transcriptTokens: transcriptTokens
        )
        guard !chunks.isEmpty else { throw NotesError.emptyTranscript }

        var facts: [String] = []
        var generated = 0
        // Every chunk's facts share one reduce window with the brief, so the budget is
        // split before asking: a fixed 600-token allowance per chunk is what used to
        // overflow the reduce on any meeting past half an hour.
        let factBudget = max(150, min(Self.maxFactTokens, (budget - briefTokens) / max(1, chunks.count)))
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // The map step's own progress is the only honest number in the whole operation:
            // the reduce that follows is one generation of unknown length.
            progress(Step(
                message: "Reading part \(index + 1) of \(chunks.count)\u{2026}",
                fraction: Double(index) / Double(chunks.count + 1)
            ))
            // No brief here on purpose: the map step's job is "write only what was said",
            // and context facts in this prompt come back as claims someone made.
            let completion = try await recordedComplete(
                feature: .meetingNotesMap,
                pass: "map",
                meetingID: meeting.id,
                system: NotesPrompts.mapSystem,
                user: NotesPrompts.mapUser(
                    meeting: meeting,
                    part: index + 1,
                    of: chunks.count,
                    transcript: chunk,
                    wordLimit: factBudget * 3 / 4
                ),
                maxTokens: factBudget
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

        // The facts can themselves outgrow the window on a very long meeting. Deleting
        // the oldest ones is not the answer — on a 90-minute meeting that is the agenda
        // and the first decisions. Instead a collapse pass merges adjacent fact lists
        // into shorter ones with the model, keeping every decision, owner, date, number
        // and open question, until they fit or the round cap is reached. Only then is
        // anything left out, and never without the visible line below.
        var joined = facts.joined(separator: "\n")
        var collapsedGroups = 0
        var round = 0
        while try await provider.countTokens(joined) + briefTokens > budget,
              round < Self.collapseMaxRounds {
            round += 1
            // Group adjacent fact lists so each group's prompt fits:
            // at most half the budget, at most one chunk.
            let groups = try await Self.group(
                facts,
                targetTokens: min(mapTarget, budget / 2)
            ) { try await provider.countTokens($0) }
            var next: [String] = []
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                progress(Step(
                    message: "Condensing part \(index + 1) of \(groups.count)\u{2026}",
                    fraction: Double(chunks.count) / Double(chunks.count + 1)
                ))
                // A group that survived a whole round alone has nothing left to merge
                // with; asking again only spends a model call to get the same list back.
                if group.count == 1, round > 1 { next.append(group[0]); continue }
                let text = group.joined(separator: "\n")
                let groupTokens = try await provider.countTokens(text)
                // M-16b: the collapse pass is a model pass like the map and reduce steps
                // around it, so it writes its own `meeting.notes.collapse` row — one per
                // group per round, which is what `Result.collapsedGroups` counts.
                let completion = try await recordedComplete(
                    feature: .meetingNotesCollapse,
                    pass: "collapse",
                    meetingID: meeting.id,
                    system: NotesPrompts.collapseSystem,
                    user: NotesPrompts.collapseUser(meeting: meeting, facts: text),
                    maxTokens: max(150, groupTokens / 2)
                )
                generated += completion.generatedTokens
                let cleaned = NotesFormatter.stripThinking(completion.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // An empty answer never deletes facts.
                next.append(cleaned.isEmpty ? text : cleaned)
                collapsedGroups += 1
            }
            facts = next
            joined = facts.joined(separator: "\n")
        }
        var dropped = 0
        let totalParts = facts.count
        while try await provider.countTokens(joined) + briefTokens > budget, facts.count > 1 {
            facts.removeFirst()
            dropped += 1
            joined = facts.joined(separator: "\n")
        }

        let factTokens = try await provider.countTokens(joined)
        // M-13: the reduce is the answer, so it gets the same single retry and the same
        // "cut short" filler as the single pass.
        let answer = try await answerWithRetry(
            feature: .meetingNotesReduce,
            pass: "reduce",
            meetingID: meeting.id,
            system: NotesPrompts.reduceSystem,
            user: NotesPrompts.reduceUser(meeting: meeting, facts: joined, brief: brief),
            promptTokens: factTokens + briefTokens,
            overhead: overheadTokens,
            cap: Self.maxNotesTokens(
                minutes: Self.notesMinutes(meeting: meeting, segments: segments)),
            counts: ["chunks": chunks.count, "facts": facts.count]
        )
        generated += answer.tokens

        let markdown = NotesFormatter.tidy(answer.completion.text, cutShort: answer.cutShort)
        guard !NotesFormatter.isBlank(markdown) else { throw NotesError.emptyNotes }
        let body = brief.isEmpty
            ? NotesFormatter.emptySection(NotesPrompts.relatedHeading, in: markdown)
            : markdown
        return Result(
            markdown: dropped > 0
                ? body + NotesPrompts.truncatedLine(dropped: dropped, of: totalParts) + "\n"
                : body,
            providerID: provider.id,
            generatedTokens: generated,
            duration: Date().timeIntervalSince(began),
            usedMapReduce: true,
            chunks: chunks.count,
            collapsedGroups: collapsedGroups,
            droppedFacts: dropped
        )
    }

    /// One notes answer, retried once at double the allowance when the model ran out of
    /// room (M-13).
    ///
    /// `finishedByLimit` is the only signal there is: a document that stopped mid-section
    /// is indistinguishable from a finished one without it, and `tidy` then pads the rest
    /// with `_None._` — "no decisions", "no open questions" — which is the one claim a
    /// cut-off answer cannot support. One retry, and only when the window has room for
    /// it: a second refusal is minutes nobody asked to spend.
    private struct Answer {
        let completion: LLMCompletion
        /// Both calls' tokens when the retry ran — the reported figure is a sum over the
        /// usage rows, never the last row alone.
        let tokens: Int
        /// What the retry could not fix: the page says the notes were cut short.
        let cutShort: Bool
    }

    private func answerWithRetry(
        feature: UsageFeature,
        pass: String,
        meetingID: UUID,
        system: String,
        user: String,
        promptTokens: Int,
        overhead: Int,
        cap: Int,
        counts: [String: Int] = [:]
    ) async throws -> Answer {
        let first = outputBudget(promptTokens: promptTokens, overhead: overhead, cap: cap)
        var completion = try await recordedComplete(
            feature: feature, pass: pass, meetingID: meetingID,
            system: system, user: user, maxTokens: first, counts: counts)
        var tokens = completion.generatedTokens
        guard completion.finishedByLimit else {
            return Answer(completion: completion, tokens: tokens, cutShort: false)
        }
        // Twice the allowance, or as much of it as the window has left — whichever is
        // smaller, and no retry at all when the window is already spent.
        let retry = outputBudget(promptTokens: promptTokens, overhead: overhead, cap: cap * 2)
        guard retry > first else {
            logCutShort(pass: pass, budget: first, retried: false)
            return Answer(completion: completion, tokens: tokens, cutShort: true)
        }
        completion = try await recordedComplete(
            feature: feature, pass: pass, meetingID: meetingID,
            system: system, user: user, maxTokens: retry, counts: counts)
        tokens += completion.generatedTokens
        if completion.finishedByLimit {
            logCutShort(pass: pass, budget: retry, retried: true)
        }
        return Answer(
            completion: completion,
            tokens: tokens,
            cutShort: completion.finishedByLimit
        )
    }

    /// The line that says a meeting's notes were not written whole (M-13). The page says
    /// it as well; this is the one a log read answers without opening the meeting.
    private func logCutShort(pass: String, budget: Int, retried: Bool) {
        Log.llm.info("""
            notes cut short · \(provider.displayModelName, privacy: .public) · \
            \(pass, privacy: .public) · budget \(budget, privacy: .public) \
            · retried \(retried, privacy: .public)
            """)
    }

    /// One model call, wrapped in the usage recorder that writes its row (P0-20b).
    ///
    /// The recorder is installed as the task-local before the provider runs, so a provider
    /// with exact counts of its own reports into the same row. The call site still reports
    /// the completion's token count afterwards, because a provider — a scripted self-test
    /// one, or any backend that measures nothing — may report none at all; the last report
    /// wins for the fields it carries.
    private func recordedComplete(
        feature: UsageFeature,
        pass: String,
        meetingID: UUID,
        system: String,
        user: String,
        maxTokens: Int,
        counts: [String: Int] = [:]
    ) async throws -> LLMCompletion {
        let recorder = ModelPassRecorder(
            feature: feature,
            pass: pass,
            provider: provider,
            ids: UsageCorrelation(meetingID: meetingID),
            requestedRole: requestedRole
        )
        if let fallbackReason { recorder.fellBack(fallbackReason) }
        if !counts.isEmpty { recorder.noteCounts(counts) }
        do {
            let completion = try await ModelPassRecorder.$current.withValue(recorder) {
                try await provider.complete(system: system, user: user, maxTokens: maxTokens)
            }
            recorder.report(
                promptTokens: nil,
                cachedTokens: nil,
                completionTokens: completion.generatedTokens,
                reasoningTokens: nil,
                // M-13: a pass that ran out of allowance is not a pass that stopped. The
                // row says which, so `--usage-report` can answer "was this meeting's notes
                // model cut off?" without the notes being open.
                finishReason: completion.finishedByLimit ? "length" : nil,
                estimated: provider.id == .appleFoundation
            )
            recorder.finish(reason: "stop")
            return completion
        } catch {
            recorder.fail(error)
            recorder.finish(reason: error is CancellationError ? "cancelled" : "error")
            throw error
        }
    }

    /// The counted prompt overhead (M-12): the system prompt, the meeting header and
    /// the scaffolding of an empty message, plus slack for what the counted strings
    /// approximate. One count per decision, not per segment.
    private func countedOverhead(system: String, user: String) async throws -> Int {
        try await provider.countTokens(system)
            + provider.countTokens(user)
            + Self.templateSlackTokens
    }

    /// One chunk's slice of the transcript (M-12), derived from the reader's window
    /// rather than a per-provider switch: the map prompt's counted overhead, the
    /// facts' budget (M-05) and the runtime's headroom come off the top, and the rest
    /// is transcript. Capped so a huge window still reads slices, floored so a small
    /// one still reads something.
    static func chunkSize(contextTokens: Int, mapOverheadTokens: Int) -> Int {
        let derived = contextTokens - mapOverheadTokens - maxFactTokens - runtimeHeadroomTokens
        return min(maxChunkTokens, max(minChunkTokens, derived))
    }

    /// True when a provider refused the prompt for its size (M-12): llama's own guard,
    /// and Apple's two spellings of the same refusal — the session-level error from
    /// macOS 26 and the model-error one from macOS 27.
    static func isContextOverflow(_ error: Error) -> Bool {
        if let llama = error as? LlamaError, case .inputTooLong = llama { return true }
        if let generation = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generation { return true }
        if #available(macOS 27.0, *),
           let language = error as? LanguageModelError,
           case .contextSizeExceeded = language { return true }
        return false
    }

    /// How many tokens the answer may use, given what the prompt already spent and how
    /// long the meeting was (M-13).
    ///
    /// Every provider shares one window between prompt and response, so a transcript that
    /// fills the whole transcript budget has to leave the notes somewhere to go. Without
    /// this, the longest meetings — the ones that most need summarising — are exactly the
    /// ones the runtime rejects. The overhead is counted, not assumed (M-12).
    private func outputBudget(promptTokens: Int, overhead: Int, cap: Int) -> Int {
        let remaining = provider.contextTokens
            - promptTokens
            - overhead
            - Self.runtimeHeadroomTokens
        return max(Self.minNotesTokens, min(cap, remaining))
    }

    /// Below this there is no room to write anything worth keeping, and the caller is
    /// better served by the runtime refusing the prompt outright.
    private static let minNotesTokens = 256

    /// Groups adjacent fact lists so each group's collapse prompt fits `targetTokens`.
    ///
    /// Greedy and order-preserving: a fact joins the current group while it fits, else
    /// it starts the next one. A single fact larger than the target stands alone rather
    /// than joining nothing.
    static func group(
        _ facts: [String],
        targetTokens: Int,
        count: (String) async throws -> Int
    ) async throws -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var currentTokens = 0
        for fact in facts {
            let tokens = try await count(fact)
            if !current.isEmpty, currentTokens + tokens > targetTokens {
                groups.append(current)
                current = []
                currentTokens = 0
            }
            current.append(fact)
            currentTokens += tokens
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

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

    /// The six sections, in order, each present exactly once.
    ///
    /// `cutShort` switches the filler for the sections the model never reached (M-13).
    /// Without it a truncated answer is dressed up as a complete one: `_None._` under
    /// ## Decisions reads as "nothing was decided", and the reader has no way to tell it
    /// from a meeting where that is true.
    static func tidy(_ text: String, cutShort: Bool = false) -> String {
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
            let filler = cutShort ? NotesPrompts.cutShortMarker : NotesPrompts.emptyMarker
            return "## \(heading)\n\(body.isEmpty ? filler : body)"
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

    /// Replaces one section's body with the empty marker, whatever the model wrote there.
    ///
    /// The no-context rule is stated in the prompt, and the first live run of this feature
    /// had Apple's model write a connection to nothing anyway — "the read path touches
    /// billing — this aligns with known concerns", with no Known context block in the
    /// message at all. That is the lesson `SpokenStructure` taught: a rule a deterministic
    /// stage can enforce is not a rule to leave to a prompt. With no block there is nothing
    /// true to say, so the section is emptied rather than trusted.
    static func emptySection(_ name: String, in markdown: String) -> String {
        var result: [String] = []
        var inside = false
        for line in markdown.components(separatedBy: .newlines) {
            if let heading = headingName(in: line) {
                inside = heading == name
                result.append(line)
                if inside { result.append(NotesPrompts.emptyMarker) }
                continue
            }
            if inside { continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
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
            "This meeting is too long for the selected model to summarise in one go."
        case .noProvider:
            "Your assistant\u{2019}s brain isn\u{2019}t downloaded yet \u{2014} get it in "
                + "Settings \u{25b8} Models, or turn on Apple Intelligence."
        }
    }
}
