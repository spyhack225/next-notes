import Foundation

/// `--selftest-notes-truncation`: a cut-off answer is visible, not padded with `_None._`.
///
/// `LLMCompletion` used to carry no finish reason, so a model that ran out of room in the
/// middle of writing its last section produced a document that looked complete and said
/// "no decisions" and "no open questions" — the two sections a reader most needs to trust.
/// M-13 gives every provider a way to say "I stopped because the budget ran out", retries
/// the answer once at double the allowance, and when that fails says so on the page.
///
/// No model and no store: the fake provider below is the worst case, a model that fills its
/// whole allowance and stops mid-document.
@MainActor
enum NotesTruncationSelfTest {
    static func run(write: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let meeting = hourLongMeeting()
        let segments = tenMinuteSegments()

        // a. Cut on the first call and again on the retry: the sections the model never
        // reached say so, and none of them claims there was nothing to say.
        do {
            let provider = TruncationNotesProvider(contextTokens: 8_192, alwaysCut: true)
            if let result = try? await NotesGenerator(provider: provider)
                .notes(for: meeting, segments: segments, brief: .empty) {
                for heading in ["Decisions", "Action items", "Open questions"] {
                    check("\(heading) is missing from the cut-short notes",
                          result.markdown.contains("## \(heading)\n\(NotesPrompts.cutShortMarker)"))
                    check("\(heading) claims there was nothing to say after a cut",
                          !result.markdown
                              .contains("## \(heading)\n\(NotesPrompts.emptyMarker)"))
                }
                check("the summary the model did write was lost",
                      result.markdown.contains("## Summary\n- The team agreed to ship on Friday."))
                // The Related-context rule is not M-13's to change: with no brief there is
                // nothing to connect, so `emptySection` still wins over the cut-short line.
                check("an empty brief stopped forcing the empty marker",
                      result.markdown
                          .contains("## \(NotesPrompts.relatedHeading)\n\(NotesPrompts.emptyMarker)"))
                check("the Related-context section was marked cut short",
                      !result.markdown.contains(
                        "## \(NotesPrompts.relatedHeading)\n\(NotesPrompts.cutShortMarker)"))
                write("NOTES_TRUNCATION cut calls=\(provider.calls.count) "
                    + "budget=\(provider.calls.map { String($0.maxTokens) }.joined(separator: ","))")
                check("the retry never ran", provider.calls.count == 2)
            } else {
                failures.append("the always-cut run threw")
            }
        }

        // b. Cut once, complete on the retry: the answer is whole, and the retry asked for
        // twice the budget rather than the same one again.
        do {
            let provider = TruncationNotesProvider(contextTokens: 8_192, cutFirstCallOnly: true)
            if let result = try? await NotesGenerator(provider: provider)
                .notes(for: meeting, segments: segments, brief: .empty) {
                check("a completed retry is still marked cut short",
                      !result.markdown.contains("cut short"))
                check("the retry did not run", provider.calls.count == 2)
                if provider.calls.count == 2 {
                    let first = provider.calls[0].maxTokens
                    let second = provider.calls[1].maxTokens
                    check("the retry repeated the first budget (\(first) then \(second))",
                          second == first * 2)
                }
                for heading in NotesPrompts.headings
                where heading != NotesPrompts.relatedHeading {
                    check("\(heading) is still empty after a completed retry",
                          !result.markdown
                              .contains("## \(heading)\n\(NotesPrompts.emptyMarker)"))
                }
                check("a completed answer is not a blank one",
                      !NotesFormatter.isBlank(result.markdown))
            } else {
                failures.append("the cut-then-complete run threw")
            }
        }

        // c. The cap scales with the meeting: a 10-minute call keeps 1,000 tokens and a
        // 60-minute one 2,000, with the ceiling above that.
        check("a 10-minute meeting did not get 1,000 tokens",
              NotesGenerator.maxNotesTokens(minutes: 10) == 1_000)
        check("a 60-minute meeting did not get 2,000 tokens",
              NotesGenerator.maxNotesTokens(minutes: 60) == 2_000)
        check("a 3-hour meeting was not capped at 3,000",
              NotesGenerator.maxNotesTokens(minutes: 180) == 3_000)
        check("a 30-second meeting got more room than a 10-minute one",
              NotesGenerator.maxNotesTokens(minutes: 1) <= 1_000)

        // d. Every provider that can tell says so: the two wire legs and Apple's estimate
        // rule are pure, so they are pinned here rather than needing a model.
        let cutBody = #"{"choices":[{"message":{"content":"half a section"},"finish_reason":"length"}]}"#
        let stopBody = #"{"choices":[{"message":{"content":"whole"},"finish_reason":"stop"}]}"#
        do {
            let cut = try JSONDecoder().decode(
                OpenAICompatibleLLMProvider.CompletionResponse.self,
                from: Data(cutBody.utf8))
            let stop = try JSONDecoder().decode(
                OpenAICompatibleLLMProvider.CompletionResponse.self,
                from: Data(stopBody.utf8))
            check("a local server's finish_reason was not read off the wire",
                  cut.choices.first?.finish_reason == "length")
            check("a local server's finish_reason: length did not mean a cut",
                  OpenAICompatibleLLMProvider.finishedByLimit(
                    finishReason: cut.choices.first?.finish_reason))
            check("a local server's finish_reason: stop was misread as a cut",
                  !OpenAICompatibleLLMProvider.finishedByLimit(
                    finishReason: stop.choices.first?.finish_reason))
        } catch {
            failures.append("the local-server finish_reason probe threw: \(error)")
        }
        check("a reply that filled the whole allowance was not seen as cut",
              FoundationModelLLMProvider.finishedByLimit(
                generatedTokens: 1_500, maxTokens: 1_500))
        check("a reply two tokens short of the allowance was seen as cut",
              FoundationModelLLMProvider.finishedByLimit(
                generatedTokens: 1_498, maxTokens: 1_500))
        check("a reply with room left was seen as cut",
              !FoundationModelLLMProvider.finishedByLimit(
                generatedTokens: 900, maxTokens: 1_500))
        for failure in failures { write("  NOTES_TRUNCATION_WRONG: \(failure)") }
        write(failures.isEmpty
            ? "NOTES_TRUNCATION_OK: a cut answer says so, one retry doubles the budget, "
                + "the cap scales with the meeting, the wire finish reasons are read"
            : "NOTES_TRUNCATION_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }

    /// 60 minutes, so the cap is the scaled one rather than the old flat 1,500.
    static func hourLongMeeting() -> Meeting {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        return Meeting(
            title: "Release review",
            start: start,
            end: start.addingTimeInterval(3_600),
            status: .summarizing
        )
    }

    /// 100 segments of 6 s: 10 minutes of speech, sparse enough for the single pass on
    /// 8,192 tokens while the meeting itself is an hour long.
    nonisolated static func tenMinuteSegments() -> [TranscriptSegment] {
        (0..<100).map { i in
            TranscriptSegment(
                start: Double(i) * 6,
                end: Double(i + 1) * 6,
                text: "call point \(i) on the agenda today",
                source: .system,
                speaker: "Speaker 1"
            )
        }
    }
}

/// The worst case as a provider: a model that writes the first half of its document and
/// stops because the allowance ran out. `cutFirstCallOnly` is the recoverable one — the
/// retry gets the whole document.
final class TruncationNotesProvider: LLMProvider, @unchecked Sendable {
    let id = LLMProviderID.openRouter
    let contextTokens: Int
    let alwaysCut: Bool
    let cutFirstCallOnly: Bool

    private let lock = NSLock()
    private var recorded: [(system: String, user: String, maxTokens: Int)] = []

    init(contextTokens: Int, alwaysCut: Bool = false, cutFirstCallOnly: Bool = false) {
        self.contextTokens = contextTokens
        self.alwaysCut = alwaysCut
        self.cutFirstCallOnly = cutFirstCallOnly
    }

    var calls: [(system: String, user: String, maxTokens: Int)] {
        lock.withLock { recorded }
    }

    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { max(1, text.count / 4) }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let index = lock.withLock { () -> Int in
            recorded.append((system, user, maxTokens))
            return recorded.count - 1
        }
        let cut = alwaysCut || (cutFirstCallOnly && index == 0)
        // What a cut-off answer looks like: the first two sections written, the third
        // heading opened with nothing under it, the rest never reached. A model that was
        // not cut writes all six.
        let sections = cut
            ? ["## Summary\n- The team agreed to ship on Friday.",
               "## Key points\n- The release is Friday.",
               "## Decisions"]
            : NotesPrompts.headings
                .filter { $0 != NotesPrompts.relatedHeading }
                .map { "## \($0)\n- The team agreed to ship on Friday." }
        return LLMCompletion(
            text: sections.joined(separator: "\n\n"),
            generatedTokens: cut ? maxTokens : 40,
            duration: 0,
            finishedByLimit: cut
        )
    }
}
