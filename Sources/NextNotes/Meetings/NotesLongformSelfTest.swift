import Foundation
import FoundationModels

/// `--selftest-notes-longform`: the map-reduce path never drops facts silently.
///
/// A 90-minute meeting on a 4,096-token provider overflows the reduce window even when
/// every chunk's facts are budgeted: the map step's answers have to be condensed by a
/// collapse pass, not trimmed from the front. The fake provider below is the worst case —
/// a model that always fills its whole allowance — so a run that keeps every fact here
/// keeps them against any model.
///
/// No model, no store: the generator takes segments in memory.
@MainActor
enum NotesLongformSelfTest {
    static func run(write: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let meeting = Meeting(
            title: "Longform review",
            start: Date(timeIntervalSince1970: 1_750_000_000),
            status: .summarizing
        )
        let segments = longSegments()
        let brief = bigBrief()

        // a. 90 minutes on the 4K path: every part reaches the reduce, nothing dropped.
        do {
            let provider = LongformNotesProvider(contextTokens: 4_096)
            if let result = try? await NotesGenerator(provider: provider)
                .notes(for: meeting, segments: segments, brief: brief) {
                write("NOTES_LONGFORM cases=a chunks=\(result.chunks) collapsed=\(result.collapsedGroups) dropped=\(result.droppedFacts)")
                check("the 90-min meeting skipped map-reduce", result.usedMapReduce)
                check("FACT-P1 missing from the reduce prompt",
                      containsToken(provider.reducePrompt, "FACT-P1"))
                check("the agenda marker missing from the reduce prompt",
                      provider.reducePrompt.contains(LongformNotesProvider.agendaMarker))
                for n in 1...max(1, result.chunks) {
                    check("FACT-P\(n) missing from the reduce prompt",
                          containsToken(provider.reducePrompt, "FACT-P\(n)"))
                }
                check("facts were dropped on the 4K path", result.droppedFacts == 0)
                check("the collapse pass never ran", result.collapsedGroups >= 1)
                check("the truncation line leaked into complete notes",
                      !result.markdown.contains("could not be included"))
                check("the brief reached the map step",
                      !provider.calls.contains {
                          ($0.system == NotesPrompts.mapSystem
                              || $0.system == NotesPrompts.collapseSystem)
                              && $0.user.contains("Known context")
                      })
            } else {
                failures.append("the 90-min run on 4K threw")
            }
        }

        // b. The same meeting on the 8K path: nothing dropped either.
        do {
            let provider = LongformNotesProvider(contextTokens: 8_192)
            if let result = try? await NotesGenerator(provider: provider)
                .notes(for: meeting, segments: segments, brief: brief) {
                check("the 90-min meeting skipped map-reduce on 8K", result.usedMapReduce)
                check("facts were dropped on the 8K path", result.droppedFacts == 0)
            } else {
                failures.append("the 90-min run on 8K threw")
            }
        }

        // c. A collapse step that refuses to shrink: the oldest facts go, visibly.
        do {
            let provider = LongformNotesProvider(contextTokens: 4_096, stubbornCollapse: true)
            if let result = try? await NotesGenerator(provider: provider)
                .notes(for: meeting, segments: segments, brief: brief) {
                check("a stubborn collapse dropped nothing", result.droppedFacts > 0)
                check("a stubborn collapse was never attempted", result.collapsedGroups >= 1)
                check("dropped facts left no visible line",
                      result.markdown.contains("could not be included"))
                check("the visible line hides the count",
                      result.markdown.contains("(\(result.droppedFacts) of "))
                let trimmed = result.markdown
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                check("the visible line is not the last line",
                      trimmed.hasSuffix("parts left out)._"))
            } else {
                failures.append("the stubborn-collapse run threw")
            }
        }

        // d. A 10-minute meeting still takes the single pass, and the brief rules hold:
        // with no brief the Related-context section is emptied deterministically.
        do {
            let provider = LongformNotesProvider(contextTokens: 4_096)
            if let result = try? await NotesGenerator(provider: provider)
                .notes(for: meeting, segments: shortSegments(), brief: .empty) {
                check("a 10-min meeting took map-reduce", result.usedMapReduce == false)
                check("an invented connection survived with no brief",
                      result.markdown.contains("## Related context\n\(NotesPrompts.emptyMarker)"))
                check("emptying the new section broke the summary",
                      result.markdown.contains("## Summary\nNotes from a long meeting."))
            } else {
                failures.append("the 10-min run threw")
            }
        }

        // e. The model refused a prompt the estimate said would fit (M-12): one
        // context-size refusal on the single pass retries once through map-reduce,
        // and notes are written.
        do {
            let provider = LongformNotesProvider(
                contextTokens: 4_096, overflowOnFirstCall: true)
            do {
                let result = try await NotesGenerator(provider: provider)
                    .notes(for: meeting, segments: shortSegments(), brief: .empty)
                check("the context-size refusal did not take map-reduce", result.usedMapReduce)
                check("the context-size retry wrote no notes",
                      !NotesFormatter.isBlank(result.markdown))
            } catch {
                failures.append("the overflow retry surfaced the raw error: \(error)")
            }
        }

        // e2. A second refusal, after the shrunk-chunk retry: a plain sentence, not a
        // raw error and not silence.
        do {
            let provider = LongformNotesProvider(contextTokens: 4_096, alwaysOverflow: true)
            do {
                _ = try await NotesGenerator(provider: provider)
                    .notes(for: meeting, segments: shortSegments(), brief: .empty)
                failures.append("the second context-size refusal was swallowed")
            } catch let error as NotesError {
                check("the second refusal did not say so plainly: \(error.localizedDescription)",
                      error.localizedDescription
                          .contains("too long for the selected model to summarise in one go"))
            } catch {
                failures.append("the second overflow surfaced raw: \(error)")
            }
        }

        // f. The real window read, not the old constant: a 12-minute meeting takes the
        // single pass on 8,192 tokens (it does not at 4,096), and the chunk size
        // derived for 8,192 clears the old 2,000-token Apple value.
        do {
            let provider = LongformNotesProvider(contextTokens: 8_192)
            if let result = try? await NotesGenerator(provider: provider)
                .notes(for: meeting, segments: twelveMinuteSegments(), brief: .empty) {
                check("a 12-min meeting took map-reduce on the 8K window",
                      result.usedMapReduce == false)
                check("a 12-min meeting on 8K was split into parts", result.chunks == 1)
            } else {
                failures.append("the 12-min run on 8K threw")
            }
            let mapSystemTokens = (try? await provider.countTokens(NotesPrompts.mapSystem)) ?? 0
            let mapUserTokens = (try? await provider.countTokens(
                NotesPrompts.mapUser(meeting: meeting, part: 1, of: 1, transcript: ""))) ?? 0
            let mapOverhead = mapSystemTokens + mapUserTokens + 64
            let chunkSize = NotesGenerator.chunkSize(
                contextTokens: 8_192, mapOverheadTokens: mapOverhead)
            write("NOTES_LONGFORM chunks8k=\(chunkSize) mapOverhead=\(mapOverhead)")
            check("chunkTokens for the 8K window is still the old 2,000 constant",
                  chunkSize > 3_000)
        }

        // g. The real Apple tokenizer, Apple FM only (ABSENT elsewhere): the budget
        // counter is the system model's own token count, not the character rule.
        // M-12 red: the estimate is characters / 4, so both paragraphs land exactly
        // on that quotient.
        do {
            if #available(macOS 26.4, *) {
                if let unavailable = FoundationModelFormatter.unavailableReason {
                    write("  NOTES_LONGFORM_APPLE_FM_ABSENT: \(unavailable)")
                } else {
                    let provider = FoundationModelLLMProvider()
                    let english = Self.fourAligned(
                        "The team agreed to ship the pricing page on Friday, review the "
                            + "churn dashboard after launch, and tell the channel what changed.")
                    let french = Self.fourAligned(
                        "L'équipe a convenu de publier la page tarifaire vendredi, d'examiner "
                            + "le tableau de bord après le lancement et d'annoncer le changement "
                            + "à tout le monde.")
                    do {
                        let englishTokens = try await provider.countTokens(english)
                        let frenchTokens = try await provider.countTokens(french)
                        write("APPLE_FM_TOKENS text=\(english.count) tokens=\(englishTokens)")
                        write("APPLE_FM_TOKENS text=\(french.count) tokens=\(frenchTokens)")
                        check("countTokens answered characters / 4 for both paragraphs — "
                            + "the real counter was not used",
                              !(englishTokens == english.count / 4
                                  && frenchTokens == french.count / 4))
                    } catch {
                        failures.append("the Apple tokenizer probe threw: \(error)")
                    }
                }
            } else {
                write("  NOTES_LONGFORM_APPLE_FM_ABSENT: needs macOS 26.4 for the real tokenizer")
            }
        }

        // The three refusals the retry matches, directly.
        check("the llama input-too-long refusal did not match",
              NotesGenerator.isContextOverflow(LlamaError.inputTooLong))
        check("the session context-window refusal did not match",
              NotesGenerator.isContextOverflow(
                  LanguageModelSession.GenerationError.exceededContextWindowSize(
                      .init(debugDescription: "fixture"))))
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            check("the macOS 27 context-size refusal did not match",
                  NotesGenerator.isContextOverflow(
                      LanguageModelError.contextSizeExceeded(.init(
                          contextSize: 4_096, tokenCount: 5_000,
                          debugDescription: "fixture"))))
        }
        #endif
        check("an unrelated error matched the context-refusal matcher",
              !NotesGenerator.isContextOverflow(NotesError.emptyNotes))

        for failure in failures { write("  NOTES_LONGFORM_WRONG: \(failure)") }
        write(failures.isEmpty
            ? "NOTES_LONGFORM_OK: 90-min facts kept on 4K and 8K, stubborn collapse visible, "
                + "single pass intact, overflow retried, window-derived chunks"
            : "NOTES_LONGFORM_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }

    /// Whole-token match: "FACT-P1" must not match inside "FACT-P13".
    static func containsToken(_ text: String, _ token: String) -> Bool {
        text.range(of: "\\b\(token)\\b", options: .regularExpression) != nil
    }

    /// 1,800 segments of 3 s: 90 minutes. 45 characters of speech each, the agenda
    /// marker in the first segment — the fact the old front-trimming deleted first.
    /// `nonisolated`: the usage-log self-test calls these from its own nonisolated cases.
    nonisolated static func longSegments() -> [TranscriptSegment] {
        (0..<1_800).map { i in
            let body = i == 0
                ? "AGENDA-ITEM-ONE kickoff and the plan ahead"
                : "discussion point \(i) budget timeline owner date"
            return TranscriptSegment(
                start: Double(i) * 3,
                end: Double(i + 1) * 3,
                text: fit45(body),
                source: .system,
                speaker: "Speaker 1"
            )
        }
    }

    /// 100 segments of 6 s: 10 minutes, sparse enough for the single pass on 4K.
    static func shortSegments() -> [TranscriptSegment] {
        (0..<100).map { i in
            TranscriptSegment(
                start: Double(i) * 6,
                end: Double(i + 1) * 6,
                text: fit45("short call point \(i) today"),
                source: .system,
                speaker: "Speaker 1"
            )
        }
    }

    /// 240 segments of 3 s: 12 minutes. Above the 4K single-pass budget, below the
    /// 8K one (M-12 case f).
    static func twelveMinuteSegments() -> [TranscriptSegment] {
        (0..<240).map { i in
            TranscriptSegment(
                start: Double(i) * 3,
                end: Double(i + 1) * 3,
                text: fit45("meeting point \(i) on the agenda today"),
                source: .system,
                speaker: "Speaker 1"
            )
        }
    }

    /// Chops to a length divisible by four, so the old characters/4 estimate equals
    /// the count exactly and the check can tell it from the real tokenizer (M-12 g).
    static func fourAligned(_ text: String) -> String {
        String(text.prefix(text.count - text.count % 4))
    }

    nonisolated static func fit45(_ s: String) -> String {
        if s.count >= 45 { return String(s.prefix(45)) }
        return s + String(repeating: ".", count: 45 - s.count)
    }

    /// Memory + decisions at roughly 2,800 characters: a full brief, like a real meeting.
    nonisolated static func bigBrief() -> MeetingNotesBrief {
        MeetingNotesBrief(
            memory: String(repeating: "m", count: 1_400),
            decisions: String(repeating: "d", count: 1_400)
        )
    }
}

/// The worst case as a provider: a model that always fills its whole allowance, so the
/// map step's answers are as large as the budget allows. The collapse step keeps every
/// `FACT-P<n>` token and the agenda marker and halves the filler — unless
/// `stubbornCollapse` is set, in which case it returns its input unchanged.
///
/// `overflowOnFirstCall` throws the Apple context-size refusal once, on the first call
/// (the single pass, when the transcript fits) — M-12 case e. `alwaysOverflow` throws
/// the llama one on every call, so even the shrunk-chunk retry refuses — case e2.
///
/// Internal so the usage-log self-test (M6, M-16b) can drive the same 90-minute case
/// and count the rows each pass writes, rather than rebuild the worst case beside it.
final class LongformNotesProvider: LLMProvider, @unchecked Sendable {
    static let agendaMarker = "AGENDA-ITEM-ONE"

    let id = LLMProviderID.appleFoundation
    let contextTokens: Int
    let stubbornCollapse: Bool
    let overflowOnFirstCall: Bool
    let alwaysOverflow: Bool

    private let lock = NSLock()
    private var recorded: [(system: String, user: String)] = []
    private var reducePromptValue = ""
    private var sawOverflowCall = false

    init(
        contextTokens: Int,
        stubbornCollapse: Bool = false,
        overflowOnFirstCall: Bool = false,
        alwaysOverflow: Bool = false
    ) {
        self.contextTokens = contextTokens
        self.stubbornCollapse = stubbornCollapse
        self.overflowOnFirstCall = overflowOnFirstCall
        self.alwaysOverflow = alwaysOverflow
    }

    var calls: [(system: String, user: String)] {
        lock.withLock { recorded }
    }

    var reducePrompt: String {
        lock.withLock { reducePromptValue }
    }

    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        lock.withLock { recorded.append((system, user)) }
        let firstCall = lock.withLock { () -> Bool in
            defer { sawOverflowCall = true }
            return !sawOverflowCall
        }
        if alwaysOverflow || (overflowOnFirstCall && firstCall) {
            throw overflowError()
        }
        if system == NotesPrompts.mapSystem {
            let part = Self.partNumber(in: user) ?? (lock.withLock { recorded.count })
            let head = "- Speaker 1: FACT-P\(part) "
            let agenda = user.contains(Self.agendaMarker) ? " \(Self.agendaMarker)" : ""
            let filler = max(0, maxTokens * 4 - head.count - agenda.count)
            return LLMCompletion(
                text: head + String(repeating: "f", count: filler) + agenda,
                generatedTokens: maxTokens,
                duration: 0
            )
        }
        if system == NotesPrompts.collapseSystem {
            if stubbornCollapse {
                return LLMCompletion(text: user, generatedTokens: user.count / 4 + 1, duration: 0)
            }
            let text = Self.collapsedAnswer(from: user)
            return LLMCompletion(
                text: text, generatedTokens: text.count / 4 + 1, duration: 0
            )
        }
        if system == NotesPrompts.reduceSystem {
            lock.withLock { reducePromptValue = user }
        }
        let markdown = NotesPrompts.headings.map { heading in
            if heading == "Summary" { return "## \(heading)\nNotes from a long meeting." }
            if heading == NotesPrompts.relatedHeading {
                // What a model writes when it connects nothing: the deterministic
                // `emptySection` stage, not the prompt, is what removes it.
                return "## \(heading)\n- It aligns with known concerns."
            }
            return "## \(heading)\n\(NotesPrompts.emptyMarker)"
        }.joined(separator: "\n\n")
        return LLMCompletion(text: markdown, generatedTokens: 40, duration: 0)
    }

    /// The context-size refusal the fixture raises (M-12): Apple's macOS 27 spelling
    /// where the OS has it, the session-level one before that.
    private func overflowError() -> Error {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            return LanguageModelError.contextSizeExceeded(.init(
                contextSize: contextTokens,
                tokenCount: contextTokens + 1,
                debugDescription: "fixture: the prompt exceeds the context window"))
        }
        #endif
        return LanguageModelSession.GenerationError.exceededContextWindowSize(
            .init(debugDescription: "fixture: the prompt exceeds the context window"))
    }

    /// The "Part X of Y" line of the map prompt. Falls back to the call count, since map
    /// calls run in order.
    static func partNumber(in user: String) -> Int? {
        guard let range = user.range(of: "Part ") else { return nil }
        var digits = ""
        for ch in user[range.upperBound...] {
            guard ch.isNumber else { break }
            digits.append(ch)
        }
        return Int(digits)
    }

    /// Every fact marker survives; only the filler shrinks.
    static func collapsedAnswer(from text: String) -> String {
        var markers: [String] = []
        var search = text.startIndex..<text.endIndex
        while let found = text.range(
            of: "FACT-P\\d+|AGENDA-ITEM-ONE",
            options: .regularExpression,
            range: search
        ) {
            markers.append(String(text[found]))
            search = found.upperBound..<text.endIndex
        }
        let markerChars = markers.joined().count
        let filler = max(0, (text.count - markerChars) / 2)
        var out = markers.map { "- Speaker 1: \($0)" }.joined(separator: "\n")
        if filler > 0 { out += "\n" + String(repeating: "f", count: filler) }
        return out
    }
}
