import Foundation

/// Diagnostic-only whole-transcript experiment. It changes neither the production
/// writer nor provider choices, and never saves into a meeting or knowledge store.
@MainActor
enum NotesExtractiveReplaySelfTest {
    static func run(meeting: Meeting, segments: [TranscriptSegment],
                    provider: any LLMProvider, write: (String) -> Void,
                    indicesOnly: Bool = false) async -> Bool {
        guard SelfTest.isRunning else { return false }
        do {
            let result = try await NotesExtractiveContract.generate(
                meeting: meeting, segments: segments, provider: provider, indicesOnly: indicesOnly)
            write("NOTES_EXTRACTIVE_RESULT mode=\(indicesOnly ? "indices" : "quotes") seconds=\(result.duration)"
                + " inputTokens=\(result.inputTokens) windowTokens=\(provider.contextTokens)"
                + " outputBudget=\(result.outputBudget) generatedTokens=\(result.generatedTokens)"
                + " passes=1 admitted=\(result.admission.entries.count)"
                + " refused=\(result.admission.refused) incomplete=\(result.incomplete)"
                + " sectionClassification=unverified readability=unverified")
            UsageLog.shared.flush()
            let usage = try JSONEncoder().encode(UsageLog.shared.load())
            write("NOTES_EXTRACTIVE_USAGE " + String(decoding: usage, as: UTF8.self))
            // Root directs this diagnostic to private output. Source quotes and model
            // selection must never be included in repository reports or agent relay.
            write("NOTES_EXTRACTIVE_SELECTION_BEGIN\n\(result.selection)\nNOTES_EXTRACTIVE_SELECTION_END")
            write("NOTES_EXTRACTIVE_MARKDOWN_BEGIN\n\(result.markdown)\nNOTES_EXTRACTIVE_MARKDOWN_END")
            guard !result.admission.entries.isEmpty else {
                write("NOTES_EXTRACTIVE_REPLAY_FAILED: mode=\(indicesOnly ? "indices" : "quotes") no supported selection; raw output and usage retained")
                return false
            }
            write("NOTES_EXTRACTIVE_REPLAY_OK: mode=\(indicesOnly ? "indices" : "quotes") generation only; factual coverage, classification and readability require review")
            return true
        } catch {
            write("NOTES_EXTRACTIVE_REPLAY_FAILED: \(type(of: error))")
            return false
        }
    }

    static func runSourceChecks(write: (String) -> Void) async -> Bool {
        guard SelfTest.isRunning else { return false }
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures.append(name) }
        }
        let segments = [
            TranscriptSegment(start: 10, end: 16,
                text: "I have only built one to five prototypes, not scaled production.",
                source: .system, speaker: "Speaker 1"),
            TranscriptSegment(start: 17, end: 23,
                text: "I have worked on production and supplier qualification at larger quantities.",
                source: .mic),
            TranscriptSegment(start: 30, end: 36,
                text: "I had lunch with the customer today. I will take these questions when I visit again.",
                source: .system, speaker: "Speaker 1"),
            TranscriptSegment(start: 40, end: 41, text: "Assistant, open the notes.",
                source: .mic, kind: .agentCommand),
        ]
        let sources = NotesEvidence.sources(segments, speakerNames: [:])
        let entries = [
            NotesExtractiveContract.Entry(section: "Key points", source: 1, quote: segments[0].text),
            NotesExtractiveContract.Entry(section: "Key points", source: 2, quote: segments[1].text),
            NotesExtractiveContract.Entry(section: "Action items", source: 3, quote: segments[2].text),
        ]
        let good = NotesExtractiveContract.encode(entries)
        check(NotesExtractiveContract.grammar.structuralProblems().isEmpty, "Broken final-selection grammar")
        check(NotesExtractiveContract.grammar.matches(good), "Valid selections fail the real grammar")
        check(!NotesExtractiveContract.grammar.matches("{\n\"section\":\"Summary\",\"source\":1,\"quote\":\"Complete clause.\"}"),
              "Pretty object bypasses JSONL framing")
        let admission = NotesExtractiveContract.admit(good, sources: sources)
        check(admission.entries == entries && admission.refused == 0,
              "Valid source-bound selections were refused")
        let indices = NotesExtractiveContract.encode(entries, indicesOnly: true)
        check(NotesExtractiveContract.indicesGrammar.structuralProblems().isEmpty
                && NotesExtractiveContract.indicesGrammar.matches(indices),
              "Source-index grammar refused supported selections")
        check(!NotesExtractiveContract.indicesGrammar.matches("{\n\"section\":\"Summary\",\"source\":1}"),
              "Source-index grammar allowed broken JSONL framing")
        let indicesAdmission = NotesExtractiveContract.admit(indices, sources: sources, indicesOnly: true)
        check(indicesAdmission.entries == entries && indicesAdmission.refused == 0,
              "Source-index admission changed the complete original utterance")
        for id in [-1, 0, 4, Int.max] {
            let unknown = "{\"section\":\"Key points\",\"source\":\(id)}"
            let refused = NotesExtractiveContract.admit(unknown, sources: sources, indicesOnly: true)
            check(refused.entries.isEmpty && refused.refused == 1,
                  "Invalid or command-only source index admitted: \(id)")
        }
        check(NotesExtractiveContract.admit(good, sources: sources, indicesOnly: true).entries.isEmpty,
              "Index-only mode accepted model-supplied replacement quotes")
        let cases = [
            NotesExtractiveContract.Entry(section: "Action items", source: 3, quote: "I will visit next week."),
            NotesExtractiveContract.Entry(section: "Key points", source: 1, quote: segments[1].text),
            NotesExtractiveContract.Entry(section: "Key points", source: 1, quote: "scaled production"),
            NotesExtractiveContract.Entry(section: "Summary", source: 4, quote: segments[3].text),
            NotesExtractiveContract.Entry(section: "Related context", source: 1, quote: segments[0].text),
        ]
        for (index, entry) in cases.enumerated() {
            let refused = NotesExtractiveContract.admit(NotesExtractiveContract.encode([entry]), sources: sources)
            check(refused.entries.isEmpty && refused.refused == 1, "Unsupported selection admitted: \(index)")
        }
        let injected = "{\"section\":\"Key points\",\"source\":1,\"quote\":"
            + String(decoding: try! JSONEncoder().encode(segments[0].text), as: UTF8.self)
            + ",\"owner\":\"Invented owner\",\"date\":\"Next week\"}"
        check(NotesExtractiveContract.admit(injected, sources: sources).entries.isEmpty,
              "Free owner/date fields were accepted")
        let partial = NotesExtractiveContract.admit(good + "\n{\"section\":\"Summary\"", sources: sources)
        check(partial.entries == entries && partial.refused == 1,
              "A cut final record erased supported excerpts")
        let rendered = NotesExtractiveContract.render(admission, segments: segments,
            speakerNames: [:], incomplete: false)
        check(rendered.contains("**Speaker 1** · 00:10") && rendered.contains("**You** · 00:17"),
              "Renderer changed source attribution or time")
        check(!rendered.contains("next week") && !rendered.contains("[S"),
              "Renderer invented a date or exposed internal source IDs")
        check(NotesPrompts.headings.allSatisfy { rendered.contains("## " + $0 + "\n") },
              "Renderer lost maintained section headings")
        do {
            let provider = ExtractiveFixtureProvider(reply: good)
            let meeting = Meeting(title: "Owned extractive fixture", start: Date(), status: .summarizing)
            let result = try await NotesExtractiveContract.generate(
                meeting: meeting, segments: segments, provider: provider)
            check(provider.calls == 1 && provider.grammarCalls == 1,
                  "The actual whole-transcript producer added a pass or bypassed grammar")
            check(result.inputTokens + result.outputBudget + 320 <= provider.contextTokens,
                  "Full transcript/output/headroom exceeded the actual window")
            check(result.admission.entries == entries && result.markdown == rendered,
                  "Production consumer changed admitted evidence")
            let indicesProvider = ExtractiveFixtureProvider(reply: indices)
            let indicesResult = try await NotesExtractiveContract.generate(meeting: meeting,
                segments: segments, provider: indicesProvider, indicesOnly: true)
            check(indicesProvider.calls == 1 && indicesProvider.grammarCalls == 1
                    && indicesResult.admission.entries == entries && indicesResult.markdown == rendered,
                  "Index selection changed source text/attribution or added a pass")
            // Native quote failure previously threw before retaining its raw output.
            // All empty/refused outcomes must still fail, with one model call and the
            // actual selection/usage written before the diagnostic verdict.
            for reply in ["", "[]", "{\"section\":\"Action items\",\"source\":3,\"quote\":\"I will visit next week.\"}"] {
                let emptyProvider = ExtractiveFixtureProvider(reply: reply)
                let emptyResult = try await NotesExtractiveContract.generate(meeting: meeting,
                    segments: segments, provider: emptyProvider)
                check(emptyResult.selection == reply && emptyResult.admission.entries.isEmpty
                        && emptyResult.incomplete && emptyProvider.calls == 1,
                      "Empty/refused result lost diagnostic evidence or repeated the model")
                var output: [String] = []
                let replayProvider = ExtractiveFixtureProvider(reply: reply)
                let success = await run(meeting: meeting, segments: segments,
                    provider: replayProvider, write: { output.append($0) })
                check(!success && replayProvider.calls == 1
                        && output.contains { $0.hasPrefix("NOTES_EXTRACTIVE_REPLAY_FAILED:") }
                        && !output.contains { $0.hasPrefix("NOTES_EXTRACTIVE_REPLAY_OK:") },
                      "Zero supported selection was promoted to a replay pass")
                check(output.contains { $0 == "NOTES_EXTRACTIVE_SELECTION_BEGIN\n\(reply)\nNOTES_EXTRACTIVE_SELECTION_END" }
                        && output.contains { $0.hasPrefix("NOTES_EXTRACTIVE_USAGE ") },
                      "Failed replay did not retain actual raw selection and usage")
            }
            let tooSmall = ExtractiveFixtureProvider(reply: good, contextTokens: 128)
            do {
                _ = try await NotesExtractiveContract.generate(
                    meeting: meeting, segments: segments, provider: tooSmall)
                failures.append("Insufficient window was admitted")
            } catch {
                check(tooSmall.calls == 0, "Oversized whole input reached model completion")
            }
        } catch { failures.append("Actual diagnostic producer failed: \(type(of: error))") }
        failures.forEach { write("  FAIL: " + $0) }
        write("NOTES_EXTRACTIVE_CONTRACT_\(failures.isEmpty ? "OK" : "FAILED"): checks=\(checks) failures=\(failures.count); semantic classification and readability unproven")
        return failures.isEmpty
    }
}

/// Same one-generation final contract: the model may select sections and source spans,
/// but no generated owner, deadline or free-form factual statement is accepted.
enum NotesExtractiveContract {
    struct Entry: Codable, Equatable, Sendable {
        let section: String
        let source: Int
        let quote: String
    }
    struct IndexEntry: Codable, Sendable {
        let section: String
        let source: Int
    }
    struct Admission: Sendable {
        let entries: [Entry]
        let refused: Int
    }
    struct Result: Sendable {
        let markdown: String
        let selection: String
        let admission: Admission
        let incomplete: Bool
        let inputTokens: Int
        let outputBudget: Int
        let generatedTokens: Int
        let duration: TimeInterval
    }

    static let sections = NotesPrompts.headings.filter { $0 != NotesPrompts.relatedHeading }
    static let grammar: GBNFGrammar = {
        let json = GBNFGrammar.composed { builder in
            let item = builder.rule(for: .object([
                ("section", .enumeration(sections)), ("source", .integer),
                ("quote", .string(maxLength: 768)),
            ]), name: "selection")
            return "\"[]\" | \(item) (\"\\n\" \(item)){0,23}"
        }
        let rules = json.text.components(separatedBy: .newlines).map {
            $0.hasPrefix("ws ::=") ? "ws ::= [ \\t]{0,8}" : $0
        }
        return GBNFGrammar(text: rules.joined(separator: "\n"), root: json.root)
    }()

    static let indicesGrammar: GBNFGrammar = {
        let json = GBNFGrammar.composed { builder in
            let item = builder.rule(for: .object([
                ("section", .enumeration(sections)), ("source", .integer),
            ]), name: "selection")
            return "\"[]\" | \(item) (\"\\n\" \(item)){0,23}"
        }
        let rules = json.text.components(separatedBy: .newlines).map {
            $0.hasPrefix("ws ::=") ? "ws ::= [ \\t]{0,8}" : $0
        }
        return GBNFGrammar(text: rules.joined(separator: "\n"), root: json.root)
    }()

    static let indicesSystem = """
        Select the important original speech utterances for meeting notes.
        Return one JSON object per line, no prose:
        {"section":"Key points","source":1}
        Section is Summary, Key points, Decisions, Action items or Open questions.
        [S1] identifies source 1. Select only IDs actually shown in the transcript.
        The complete original utterance and its real speaker will be shown. Select
        related source IDs together when a short reply needs its question or context.
        Cover substantive distinctions throughout the conversation, not only its opening.
        Summary selects a few representative utterances. Key points selects important facts.
        Decisions requires an explicit agreement. Action items requires an actual future
        commitment or request, not explanation, examples or an activity already completed.
        Open questions requires a question that remained unanswered.
        Do not supply quotes, names, owners, dates or new text. At most 24 records.
        Return [] if no useful speech.
        """

    static let system = """
        Select the important original speech excerpts for meeting notes.
        Return one JSON object per line, no prose:
        {"section":"Key points","source":1,"quote":"exact source words"}
        Section is Summary, Key points, Decisions, Action items or Open questions.
        [S1] identifies source 1. Copy exact contiguous quotes from that source.
        Preserve speaker qualifications, negation and whether an activity already happened.
        Cover substantive distinctions throughout the conversation, not only its opening.
        Summary selects a few representative excerpts. Key points selects important facts.
        Decisions requires an explicit agreement. Action items requires an actual future
        commitment or request, not explanation, examples or an activity already completed.
        Open questions requires a question that remained unanswered.
        Never add words, dates, names, owners or conclusions. Retain clause context.
        At most 24 records, at most 768 characters per quote. Return [] if no useful speech.
        """

    static func generate(meeting: Meeting, segments: [TranscriptSegment],
                         provider: any LLMProvider, indicesOnly: Bool = false) async throws -> Result {
        guard SelfTest.isRunning else { throw CocoaError(.fileReadNoPermission) }
        let began = Date()
        let sources = NotesEvidence.sources(segments, speakerNames: meeting.speakerNames)
        guard !sources.isEmpty else { throw NotesError.emptyTranscript }
        let user = "Transcript:\n" + sources.map(\.line).joined(separator: "\n")
        let selectedSystem = indicesOnly ? indicesSystem : system
        let selectedGrammar = indicesOnly
            ? NotesEvidence.restrictingIDs(in: indicesGrammar, sources: sources) : grammar
        let inputTokens = try await provider.countTokens(selectedSystem) + provider.countTokens(user)
        let available = provider.contextTokens - inputTokens - 320
        guard available >= 256 else { throw NotesError.contextTooSmall }
        let outputBudget = min(available, NotesGenerator.maxNotesTokens(
            minutes: NotesGenerator.notesMinutes(meeting: meeting, segments: segments)))
        let recorder = ModelPassRecorder(feature: .meetingNotesSingle,
            pass: indicesOnly ? "single-extractive-indices-replay" : "single-extractive-replay",
            provider: provider, ids: UsageCorrelation(meetingID: meeting.id), requestedRole: .meetingNotes)
        recorder.noteCounts(["sourceCount": sources.count, "outputBudget": outputBudget,
                             "countedInputTokens": inputTokens, "indicesOnly": indicesOnly ? 1 : 0])
        let completion: LLMCompletion
        do {
            completion = try await ModelPassRecorder.$current.withValue(recorder) {
                try await provider.complete(system: selectedSystem, user: user,
                    maxTokens: outputBudget, grammar: selectedGrammar)
            }
            recorder.report(promptTokens: nil, cachedTokens: nil,
                completionTokens: completion.generatedTokens, reasoningTokens: nil,
                finishReason: completion.finishedByLimit ? "length" : nil,
                estimated: provider.id == .appleFoundation)
            recorder.finish(reason: "stop")
        } catch {
            recorder.fail(error)
            recorder.finish(reason: error is CancellationError ? "cancelled" : "error")
            throw error
        }
        let admission = admit(completion.text, sources: sources, indicesOnly: indicesOnly)
        // Preserve failed model output/usage for diagnosis. The replay reports failure
        // after writing those artifacts; zero admission never becomes a generation pass.
        let incomplete = completion.finishedByLimit || admission.refused > 0 || admission.entries.isEmpty
        return Result(markdown: render(admission, segments: segments,
                speakerNames: meeting.speakerNames, incomplete: incomplete),
            selection: completion.text, admission: admission, incomplete: incomplete,
            inputTokens: inputTokens, outputBudget: outputBudget,
            generatedTokens: completion.generatedTokens, duration: Date().timeIntervalSince(began))
    }

    static func admit(_ text: String, sources: [NotesEvidence.Source],
                      indicesOnly: Bool = false) -> Admission {
        let body = NotesFormatter.stripCodeFence(NotesFormatter.stripThinking(text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body == "[]" { return Admission(entries: [], refused: 0) }
        let lines = body.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let lookup = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var entries: [Entry] = []
        var refused = 0
        for line in lines.prefix(24) {
            let data = Data(line.utf8)
            guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  Set(fields.keys) == Set(indicesOnly ? ["section", "source"] : ["section", "source", "quote"])
                else { refused += 1; continue }
            let entry: Entry
            if indicesOnly {
                guard let selection = try? JSONDecoder().decode(IndexEntry.self, from: data),
                      sections.contains(selection.section), let source = lookup[selection.source]
                    else { refused += 1; continue }
                // Full original utterance, including context, is code-owned. The model
                // cannot supply a replacement quote, owner, tense or date.
                entry = Entry(section: selection.section, source: source.id, quote: source.text)
            } else {
                guard let selection = try? JSONDecoder().decode(Entry.self, from: data),
                      sections.contains(selection.section) else { refused += 1; continue }
                let source = NotesEvidence.admit(line, sources: sources)
                guard source.entries.count == 1 && !source.incomplete else { refused += 1; continue }
                entry = selection
            }
            if !entries.contains(entry) { entries.append(entry) }
        }
        if lines.count > 24 { refused += lines.count - 24 }
        return Admission(entries: entries, refused: refused)
    }

    static func render(_ admission: Admission, segments: [TranscriptSegment],
                       speakerNames: [String: String], incomplete: Bool) -> String {
        let speech = segments.filter(\.includeInMeetingNotes)
        func escape(_ text: String) -> String {
            var result = text.replacingOccurrences(of: "\n", with: " ")
            for character in ["\\", "*", "_", "[", "]", "<", ">", "`"] {
                result = result.replacingOccurrences(of: character, with: "\\" + character)
            }
            return result
        }
        let body = NotesPrompts.headings.map { section -> String in
            if section == NotesPrompts.relatedHeading { return "## \(section)\n\(NotesPrompts.emptyMarker)" }
            let rows = admission.entries.filter { $0.section == section }.sorted { $0.source < $1.source }
            let bullets = rows.compactMap { row -> String? in
                guard speech.indices.contains(row.source - 1) else { return nil }
                let segment = speech[row.source - 1]
                let name = speakerNames[segment.displaySpeaker] ?? segment.displaySpeaker
                return "- **\(escape(name))** · \(segment.start.counterText): \(escape(row.quote))"
            }
            return "## \(section)\n" + (bullets.isEmpty
                ? "_No excerpt was selected for this section._" : bullets.joined(separator: "\n"))
        }.joined(separator: "\n\n") + "\n"
        return (incomplete ? NotesGenerator.incompleteFactsNotice + "\n\n" : "") + body
    }

    static func encode(_ entries: [Entry], indicesOnly: Bool = false) -> String {
        entries.map {
            "{\"section\":" + String(decoding: try! JSONEncoder().encode($0.section), as: UTF8.self)
                + ",\"source\":\($0.source)"
                + (indicesOnly ? "" : ",\"quote\":"
                    + String(decoding: try! JSONEncoder().encode($0.quote), as: UTF8.self)) + "}"
        }.joined(separator: "\n")
    }
}

private final class ExtractiveFixtureProvider: LLMProvider, @unchecked Sendable {
    let id = LLMProviderID.localServer
    let contextTokens: Int
    private let reply: String
    private let lock = NSLock()
    private var completed = 0
    private var grammars = 0
    var calls: Int { lock.withLock { completed } }
    var grammarCalls: Int { lock.withLock { grammars } }
    var unavailableReason: String? { get async { nil } }
    init(reply: String, contextTokens: Int = 4096) { self.reply = reply; self.contextTokens = contextTokens }
    func countTokens(_ text: String) async throws -> Int { max(1, text.count / 4) }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        lock.withLock { completed += 1 }
        return LLMCompletion(text: reply, generatedTokens: max(1, reply.count / 4), duration: 0)
    }
    func complete(system: String, user: String, maxTokens: Int,
                  grammar: GBNFGrammar) async throws -> LLMCompletion {
        lock.withLock { grammars += 1 }
        return try await complete(system: system, user: user, maxTokens: maxTokens)
    }
}
