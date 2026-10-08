import Foundation

/// Source evidence is a factual provenance contract, not a semantic quality verdict.
/// Maintains the original unsupported map reply and exercises the actual generator
/// through map -> collapse -> reduce without a model, account or owner store.
@MainActor
enum NotesEvidenceSelfTest {
    static func run(write: (String) -> Void) async -> Bool {
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let segments = [
            TranscriptSegment(start: 0, end: 5,
                text: "I only built one to five prototypes; I have not scaled production.",
                source: .system, speaker: "Speaker 1"),
            TranscriptSegment(start: 6, end: 12,
                text: "I handled sourcing and production at larger quantities.", source: .mic),
            TranscriptSegment(start: 13, end: 19,
                text: "I had lunch with the customer today. I will take the questions when I visit again.",
                source: .system, speaker: "Speaker 1"),
            TranscriptSegment(start: 20, end: 21, text: "Assistant, open the notes.",
                source: .mic, kind: .agentCommand),
        ]
        let sources = NotesEvidence.sources(segments, speakerNames: ["Speaker 1": "Ana"])
        let scope = [sources[0], sources[2]]
        let indexGrammar = NotesEvidence.selectionGrammar(sources: scope)
        check(indexGrammar.structuralProblems().isEmpty && indexGrammar.matches("[1,3]"),
              "Bounded source-index grammar refused actual scope")
        check(!indexGrammar.matches("[2]") && !indexGrammar.matches("[999999999999999999999999]"),
              "Grammar admitted an out-of-scope or unbounded integer")
        let selected = NotesEvidence.admitIndices("[3,1]", sources: scope)
        check(selected.entries.map(\.source) == [1, 3]
                && selected.entries.map(\.quote) == [segments[0].text, segments[2].text]
                && !selected.incomplete,
              "Index selection changed source order, identity or complete negation/tense context")
        let crossScope = NotesEvidence.admitIndices("[1,2]", sources: scope)
        check(crossScope.entries.map(\.source) == [1] && crossScope.incomplete,
              "Decoder admitted an ID outside the actual group")
        check(NotesEvidence.admitIndices("[1,", sources: scope).incomplete,
              "A truncated index response looked complete")
        let oldQuoteSelection = NotesEvidenceFixture.encode([
            NotesEvidence.Entry(source: 1, quote: segments[0].text),
        ])
        check(NotesEvidence.admitIndices(oldQuoteSelection, sources: scope).entries.isEmpty,
              "Old quote-copy contract was accepted by index-only producer")
        check(sources.count == 3 && sources.map(\.id) == [1, 2, 3],
              "Commands entered evidence indexing")
        check(sources[0].prefix.contains("Ana:") && sources[1].prefix.contains("You:"),
              "Source-owned speaker identity was changed")
        check(NotesEvidence.grammar.structuralProblems().isEmpty, "Invalid evidence grammar")
        let supported = NotesEvidenceFixture.encode([
            NotesEvidence.Entry(source: 3, quote: segments[2].text),
            NotesEvidence.Entry(source: 1, quote: segments[0].text),
        ])
        check(NotesEvidence.grammar.matches(supported), "Grammar refused supported exact quotes")
        check(!NotesEvidence.grammar.matches("{\n\"source\":1,\"quote\":\"A complete source clause.\"}"),
              "Grammar allowed a pretty object the JSONL reader cannot admit")
        let escapedNewline = NotesEvidenceFixture.encode([
            NotesEvidence.Entry(source: 1, quote: "A source clause.\nAnother source clause."),
        ])
        check(NotesEvidence.grammar.matches(escapedNewline),
              "Grammar rejected an escaped newline inside a JSON string")
        let admission = NotesEvidence.admit(supported, sources: sources)
        check(admission.entries.map(\.source) == [1, 3] && !admission.incomplete,
              "Admitted evidence lost source order/coverage")
        let cases: [(String, Int, String)] = [
            ("invented deadline", 3, "I will visit the customer next week."),
            ("wrong speaker binding", 1, segments[1].text),
            ("unknown source", 20, segments[0].text),
            ("dropped negation", 1, "scaled production"),
            ("paraphrased experience", 1, "I have scaled large-volume production."),
        ]
        for (name, id, quote) in cases {
            let result = NotesEvidence.admit(NotesEvidenceFixture.encode([
                NotesEvidence.Entry(source: id, quote: quote),
            ]), sources: sources)
            check(result.entries.isEmpty && result.incomplete, name + " was promoted to facts")
        }
        let cut = supported + "\n{\"source\":2,\"quote\":\"I handled"
        let partial = NotesEvidence.admit(cut, sources: sources)
        check(partial.entries == admission.entries && partial.incomplete,
              "A cut last record deleted earlier complete evidence")
        let originalMap = "- Speaker 1: FACT-P1 — call point 1 was agreed."
        let original = NotesEvidence.admit(originalMap, sources: sources)
        check(original.entries.isEmpty && original.incomplete,
              "Original unsupported map was still accepted as source evidence")
        let narrowed = NotesEvidence.render([admission.entries[0]], sources: sources)
        let crossGroup = NotesEvidence.admit(supported, sources: sources, allowedEvidence: narrowed)
        check(crossGroup.entries.count == 1 && crossGroup.incomplete,
              "Collapse imported source evidence from outside its own group")

        do {
            // A 4K provider makes the same real call path read long speech in parts.
            let repeated = (0..<160).flatMap { i -> [TranscriptSegment] in
                segments.prefix(3).map { segment in
                    TranscriptSegment(start: Double(i * 20) + segment.start,
                        end: Double(i * 20) + segment.end, text: segment.text,
                        source: segment.source, speaker: segment.speaker)
                }
            }
            let meeting = Meeting(title: "Owned evidence fixture", start: Date(), status: .summarizing)
            // Default construction keeps the inherited generated-facts producer.
            // The source-ID experiment must require an explicit initializer option.
            let legacy = LongformNotesProvider(contextTokens: 4_096)
            let legacyObserver = EvidenceTraceBox()
            let legacyResult = try await NotesGenerator(provider: legacy,
                evidenceTrace: { legacyObserver.append($0) }).notes(for: meeting,
                    segments: NotesLongformSelfTest.longSegments())
            check(legacyResult.usedMapReduce && legacy.reducePrompt.contains("FACT-P1"),
                  "Default generation stopped using inherited generated facts")
            check(!legacy.calls.contains {
                $0.system == NotesPrompts.mapSelectionSystem
                    || $0.system == NotesPrompts.collapseSelectionSystem
            } && !legacy.calls.filter { $0.system == NotesPrompts.mapSystem }
                .contains { $0.user.contains("[S1]") },
                  "Default construction activated source-ID selection or indexed chunks")
            check(legacyObserver.values.isEmpty,
                  "Default generated facts were attributed as admitted source selections")
            let provider = EvidenceNotesProvider()
            let result = try await NotesGenerator(provider: provider, sourceIndices: true)
                .notes(for: meeting, segments: repeated)
            let calls = await provider.calls
            check(result.usedMapReduce && result.incompleteFacts,
                  "The actual map producer lost evidence admission failure")
            check(result.markdown.hasPrefix(NotesGenerator.incompleteFactsNotice),
                  "The actual notes consumer hid incomplete evidence")
            check(!provider.unsupportedReachedReduce, "Unsupported map summary reached reduce")
            check(provider.validSourceReachedReduce, "Original source evidence never reached reduce")
            check(calls.filter { $0 == "map" }.count == result.chunks,
                  "Evidence refusal added a map retry")
            check(provider.grammarCalls == calls.filter { $0 != "reduce" }.count,
                  "The real extraction call sites bypassed constrained completion")
            write("NOTES_EVIDENCE_PRODUCTION chunks=\(result.chunks) collapsed=\(result.collapsedGroups) calls=\(calls.count)")
            let conforming = EvidenceNotesProvider(invalidMap: false)
            let observer = EvidenceTraceBox()
            let complete = try await NotesGenerator(provider: conforming, sourceIndices: true)
                .notes(for: meeting, segments: repeated)
            let conformingCalls = await conforming.calls
            check(!complete.incompleteFacts && conforming.validSourceReachedReduce,
                  "Conforming source selections were refused or lost")
            check(complete.collapsedGroups == 0
                    && conformingCalls.count == complete.chunks + 1,
                  "Conforming evidence extraction added a model pass")
            let observedProvider = EvidenceNotesProvider(invalidMap: false)
            _ = try await NotesGenerator(provider: observedProvider,
                evidenceTrace: { observer.append($0) }, sourceIndices: true).notes(for: meeting, segments: repeated)
            let observations = observer.values
            check(observations.count == complete.chunks && observations.allSatisfy {
                $0.pass == "map" && $0.admitted == 1 && !$0.incomplete && !$0.raw.isEmpty
            }, "Actual diagnostic evidence observer lost selected output/admission")
        } catch { failures.append("Actual generator failed: \(error)") }
        failures.forEach { write("  FAIL: " + $0) }
        write("NOTES_EVIDENCE_\(failures.isEmpty ? "OK" : "FAILED"): checks=\(checks) failures=\(failures.count); semantic quality requires native review")
        return failures.isEmpty
    }
}

private final class EvidenceTraceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [NotesGenerator.EvidenceTrace] = []
    func append(_ trace: NotesGenerator.EvidenceTrace) { lock.withLock { observations.append(trace) } }
    var values: [NotesGenerator.EvidenceTrace] { lock.withLock { observations } }
}

/// Generic test providers select the actual source lines they were shown; tests never
/// fabricate 'facts' that the source fixture did not say.
enum NotesEvidenceFixture {
    static func entries(in prompt: String) -> [NotesEvidence.Entry] {
        prompt.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("[S"), let bracket = line.firstIndex(of: "]"),
                  let id = Int(line[line.index(line.startIndex, offsetBy: 2)..<bracket]),
                  let separator = line.range(of: "]: ") ?? line.range(of: ": "),
                  separator.lowerBound > bracket else { return nil }
            return NotesEvidence.Entry(source: id, quote: String(line[separator.upperBound...]))
        }
    }
    static func encodeSelection(_ entries: [NotesEvidence.Entry]) -> String {
        String(decoding: try! JSONEncoder().encode(entries.map(\.source)), as: UTF8.self)
    }
    static func encode(_ entries: [NotesEvidence.Entry]) -> String {
        entries.map { "{\"source\":\($0.source),\"quote\":" + String(decoding: try! JSONEncoder().encode($0.quote), as: UTF8.self) + "}" }
            .joined(separator: "\n")
    }
}

private final class EvidenceNotesProvider: LLMProvider, @unchecked Sendable {
    let id = LLMProviderID.localServer
    let contextTokens = 4096
    private let lock = NSLock()
    private var passes: [String] = []
    private var unsupported = false
    private var sourceReached = false
    private var grammarCount = 0
    private let invalidMap: Bool
    init(invalidMap: Bool = true) { self.invalidMap = invalidMap }
    var calls: [String] { get async { lock.withLock { passes } } }
    var unsupportedReachedReduce: Bool { lock.withLock { unsupported } }
    var validSourceReachedReduce: Bool { lock.withLock { sourceReached } }
    var grammarCalls: Int { lock.withLock { grammarCount } }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { max(1, text.count / 4) }
    func complete(system: String, user: String, maxTokens: Int,
                  grammar: GBNFGrammar) async throws -> LLMCompletion {
        lock.withLock { grammarCount += 1 }
        return try await complete(system: system, user: user, maxTokens: maxTokens)
    }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let pass = system == NotesPrompts.mapSelectionSystem ? "map"
            : system == NotesPrompts.collapseSelectionSystem ? "collapse" : "reduce"
        lock.withLock { passes.append(pass) }
        if pass == "map" {
            let text = invalidMap ? "- Speaker 1: will scale production next week."
                : NotesEvidenceFixture.encodeSelection(Array(NotesEvidenceFixture.entries(in: user).prefix(1)))
            return LLMCompletion(text: text,
                generatedTokens: 12, duration: 0)
        }
        if pass == "collapse" {
            let entries = Array(NotesEvidenceFixture.entries(in: user).prefix(1))
            return LLMCompletion(text: NotesEvidenceFixture.encodeSelection(entries), generatedTokens: 40, duration: 0)
        }
        lock.withLock {
            unsupported = user.contains("will scale production next week")
            sourceReached = user.contains("I only built one to five prototypes; I have not scaled production.")
        }
        return LLMCompletion(text: "## Summary\nA discussion of manufacturing experience.\n\n## Key points\n- Participants contrasted prototype and production experience.",
            generatedTokens: 35, duration: 0)
    }
}
