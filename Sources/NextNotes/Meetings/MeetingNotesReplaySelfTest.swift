import Foundation
import os

/// Read-only native quality replay on a copied transcript. No meeting store, capture,
/// graph, actions, provider preference or original notes are mutated. A smaller reader
/// window exercises the existing map/reduce producer for a controlled comparison;
/// it is an experiment, not a new production default.
@MainActor
enum MeetingNotesReplaySelfTest {
    static func run(input: String, provider: any LLMProvider, window: Int?,
                    write: (String) -> Void, sourceIndices: Bool = false,
                    tracePasses: Bool = false) async -> Bool {
        do {
            let (meeting, segments) = try loadFixture(input: input)
            let reader: any LLMProvider
            if let window {
                guard window >= 4096, window <= provider.contextTokens else {
                    throw NotesError.contextTooSmall
                }
                reader = ReaderWindow(provider: provider, contextTokens: window)
            } else {
                reader = provider
            }
            // This copied-fixture-only buffer joins observations before private output.
            // The production generator retains no evidence trace or history.
            let traces = OSAllocatedUnfairLock(initialState: [NotesGenerator.EvidenceTrace]())
            // Explicit copied-fixture diagnostics only; production never wraps a provider.
            let passTraces = tracePasses && SelfTest.isRunning
                ? OSAllocatedUnfairLock(initialState: [PassTrace]()) : nil
            let selected: any LLMProvider = if let passTraces {
                PassTracingProvider(provider: reader, traces: passTraces)
            } else {
                reader
            }
            var usageWritten = false
            var generationCompleted = false
            defer {
                if let passTraces {
                    for trace in passTraces.withLock({ $0 }) {
                        if let encoded = try? JSONEncoder().encode(trace) {
                            write("NOTES_REPLAY_PASS " + String(decoding: encoded, as: UTF8.self))
                        }
                    }
                }
                // Failure visibility uses existing usage only, without a new recorder.
                if !usageWritten {
                    UsageLog.shared.flush()
                    if let usage = try? JSONEncoder().encode(UsageLog.shared.load()) {
                        write("NOTES_REPLAY_USAGE " + String(decoding: usage, as: UTF8.self))
                    }
                }
                for trace in traces.withLock({ $0 }) {
                    if let encoded = try? JSONEncoder().encode(trace) {
                        write("NOTES_REPLAY_EVIDENCE " + String(decoding: encoded, as: UTF8.self))
                    }
                }
                if generationCompleted {
                    write("NOTES_REPLAY_OK: generation completed; factual quality needs review")
                }
            }
            let result = try await NotesGenerator(provider: selected, evidenceTrace: { trace in
                traces.withLock { $0.append(trace) }
            }, sourceIndices: sourceIndices).notes(for: meeting, segments: segments, brief: .empty)
            write("NOTES_REPLAY_RESULT mode=\(sourceIndices ? "source-indices" : "legacy") seconds=\(result.duration) tokens=\(result.generatedTokens)"
                + " mapReduce=\(result.usedMapReduce) chunks=\(result.chunks)"
                + " collapsed=\(result.collapsedGroups) dropped=\(result.droppedFacts)"
                + " incompleteFacts=\(result.incompleteFacts)")
            UsageLog.shared.flush()
            let usage = try JSONEncoder().encode(UsageLog.shared.load())
            write("NOTES_REPLAY_USAGE " + String(decoding: usage, as: UTF8.self))
            usageWritten = true
            // Caller directs this output to its private diagnostic file. Do not publish
            // owner speech or generated content in a repository report or relay message.
            write("NOTES_REPLAY_MARKDOWN_BEGIN\n\(result.markdown)\nNOTES_REPLAY_MARKDOWN_END")
            generationCompleted = true
            return true
        } catch {
            write("NOTES_REPLAY_FAILED: \(error.localizedDescription)")
            return false
        }
    }

    /// Shared read-only boundary for copied transcript experiments.
    static func loadFixture(input: String) throws -> (Meeting, [TranscriptSegment]) {
        let directory = URL(fileURLWithPath: input, isDirectory: true).standardizedFileURL
        let resolved = directory.resolvingSymlinksInPath()
        // An explicit copied fixture under the OS temporary root, never an owner store.
        let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        guard SelfTest.isRunning, directory.path == resolved.path,
              resolved.path.hasPrefix(temporary.path + "/"),
              resolved.lastPathComponent.hasPrefix("NextNotesMeetingNotesReplay-"),
              UUID(uuidString: String(resolved.lastPathComponent
                .dropFirst("NextNotesMeetingNotesReplay-".count))) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func read(_ name: String) throws -> Data {
            let url = resolved.appendingPathComponent(name)
            guard url.resolvingSymlinksInPath().path == url.path else {
                throw CocoaError(.fileReadNoPermission)
            }
            return try Data(contentsOf: url)
        }
        let meeting = try decoder.decode(Meeting.self, from: read("meeting.json"))
        let segments = try decoder.decode([TranscriptSegment].self,
            from: read("transcript.json"))
        return (meeting, segments)
    }

    static func runExtractive(input: String, provider: any LLMProvider,
                              write: (String) -> Void, indicesOnly: Bool = false) async -> Bool {
        do {
            let (meeting, segments) = try loadFixture(input: input)
            return await NotesExtractiveReplaySelfTest.run(meeting: meeting, segments: segments,
                provider: provider, write: write, indicesOnly: indicesOnly)
        } catch {
            write("NOTES_EXTRACTIVE_REPLAY_FAILED: \(error.localizedDescription)")
            return false
        }
    }

    /// Optional generic diagnostic forwarding fixture: no model, meeting files or usage
    /// commits. Root may hook this named check in the next coordinated native build.
    static func runTraceForwardingSelfTest(write: (String) -> Void) async -> Bool {
        guard SelfTest.isRunning else { return false }
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name) }
        }
        let calls = OSAllocatedUnfairLock(initialState: [TraceProbeCall]())
        let failure = TraceProbeFailure()
        let tokenInputs = OSAllocatedUnfairLock(initialState: [String]())
        let probe = TraceProbeProvider(calls: calls, tokenInputs: tokenInputs, failure: failure)
        let traces = OSAllocatedUnfairLock(initialState: [PassTrace]())
        let wrapped = PassTracingProvider(provider: probe, traces: traces)
        let recorder = ModelPassRecorder(feature: .meetingNotesMap, pass: "map",
            provider: probe, ids: UsageCorrelation())
        let system = "Fixture system \"quoted\"\nnext line"
        let user = "Fixture utterance: café\nsecond line"
        let grammar = GBNFGrammar(text: "root ::= \"ok\"", root: "root")
        check(wrapped.id == probe.id && wrapped.displayModelName == probe.displayModelName
            && wrapped.contextTokens == probe.contextTokens
            && wrapped.enforcesGrammar == probe.enforcesGrammar, "provider properties")
        let unavailable = await wrapped.unavailableReason
        let structured = await wrapped.supportsStructuredToolCalls
        check(unavailable == "Fixture unavailable" && structured, "async provider properties")
        do {
            let count = try await wrapped.countTokens(user)
            check(count == user.utf8.count + 7, "tokenizer unchanged")
            let plain = try await ModelPassRecorder.$current.withValue(recorder) {
                try await wrapped.complete(system: system, user: user, maxTokens: 19)
            }
            check(plain.text == "Plain fixture\nraw" && plain.generatedTokens == 17
                && plain.duration == 0.25 && !plain.finishedByLimit, "plain completion unchanged")
            let constrained = try await ModelPassRecorder.$current.withValue(recorder) {
                try await wrapped.complete(system: system, user: user, maxTokens: 23, grammar: grammar)
            }
            check(constrained.text == "Grammar fixture" && constrained.generatedTokens == 23
                && constrained.duration == 0.5 && constrained.finishedByLimit,
                "grammar completion unchanged")
        } catch { failures.append("unexpected successful-call error") }
        do {
            _ = try await ModelPassRecorder.$current.withValue(recorder) {
                try await wrapped.complete(system: system, user: "throw", maxTokens: 29)
            }
            failures.append("error not propagated")
        } catch { check((error as? TraceProbeFailure) === failure, "same error instance") }
        do {
            _ = try await ModelPassRecorder.$current.withValue(recorder) {
                try await wrapped.complete(system: system, user: "cancel", maxTokens: 31, grammar: grammar)
            }
            failures.append("cancellation not propagated")
        } catch { check(error is CancellationError, "cancellation unchanged") }
        do {
            _ = try await wrapped.countTokens("tokenizer throw")
            failures.append("tokenizer error not propagated")
        } catch { check((error as? TraceProbeFailure) === failure, "same tokenizer error instance") }
        check(tokenInputs.withLock { $0 } == [user, "tokenizer throw"], "exact tokenizer input/call count")
        let forwarded = calls.withLock { $0 }
        let retained = traces.withLock { $0 }
        check(forwarded.count == 4 && retained.count == 4, "exactly one backing call per completion")
        if forwarded.count == 4 && retained.count == 4 {
            check(forwarded.allSatisfy { $0.recorder == ObjectIdentifier(recorder) },
                "caller recorder preserved in every backing call")
            check(retained.allSatisfy { $0.feature == UsageFeature.meetingNotesMap.rawValue && $0.pass == "map" },
                "exact recorder identity retained")
            for index in forwarded.indices {
                check(retained[index].call == index + 1
                    && retained[index].system == forwarded[index].system
                    && retained[index].user == forwarded[index].user
                    && retained[index].maxTokens == forwarded[index].maxTokens
                    && retained[index].grammarText == forwarded[index].grammar?.text
                    && retained[index].grammarRoot == forwarded[index].grammar?.root,
                    "exact call fields \(index + 1)")
            }
            check(forwarded[0].system == system && forwarded[0].user == user
                && forwarded[0].maxTokens == 19 && forwarded[0].grammar == nil
                && forwarded[1].grammar == grammar && forwarded[1].maxTokens == 23,
                "correct overload and caller arguments")
            check(retained[0].completion == "Plain fixture\nraw"
                && retained[1].finishedByLimit == true && retained[2].completion == nil
                && retained[2].errorType != nil && retained[3].errorType != nil,
                "success/refusal/cancellation trace retained")
            do {
                let data = try JSONEncoder().encode(retained)
                let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                check(rows?.first?["system"] as? String == system
                    && rows?.first?["user"] as? String == user
                    && rows?.first?["completion"] as? String == "Plain fixture\nraw",
                    "JSON exact multiline and unicode fields")
            } catch { failures.append("JSON encoding failed") }
        }
        for failure in failures { write("NOTES_REPLAY_TRACE_WRONG: " + failure) }
        write(failures.isEmpty ? "NOTES_REPLAY_TRACE_OK" : "NOTES_REPLAY_TRACE_FAILED")
        return failures.isEmpty
    }

    private struct TraceProbeCall: Sendable {
        let system: String
        let user: String
        let maxTokens: Int
        let grammar: GBNFGrammar?
        let recorder: ObjectIdentifier?
    }
    private final class TraceProbeFailure: Error, @unchecked Sendable {}
    private struct TraceProbeProvider: LLMProvider {
        let calls: OSAllocatedUnfairLock<[TraceProbeCall]>
        let tokenInputs: OSAllocatedUnfairLock<[String]>
        let failure: TraceProbeFailure
        var id: LLMProviderID { .localServer }
        var displayModelName: String { "Fixture model" }
        var contextTokens: Int { 8192 }
        var enforcesGrammar: Bool { true }
        var unavailableReason: String? { get async { "Fixture unavailable" } }
        var supportsStructuredToolCalls: Bool { get async { true } }
        func countTokens(_ text: String) async throws -> Int {
            tokenInputs.withLock { $0.append(text) }
            if text == "tokenizer throw" { throw failure }
            return text.utf8.count + 7
        }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            try response(system: system, user: user, maxTokens: maxTokens, grammar: nil)
        }
        func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar) async throws -> LLMCompletion {
            try response(system: system, user: user, maxTokens: maxTokens, grammar: grammar)
        }
        private func response(system: String, user: String, maxTokens: Int,
                              grammar: GBNFGrammar?) throws -> LLMCompletion {
            calls.withLock { $0.append(TraceProbeCall(system: system, user: user,
                maxTokens: maxTokens, grammar: grammar,
                recorder: ModelPassRecorder.current.map(ObjectIdentifier.init))) }
            if user == "throw" { throw failure }
            if user == "cancel" { throw CancellationError() }
            return grammar == nil
                ? LLMCompletion(text: "Plain fixture\nraw", generatedTokens: 17, duration: 0.25)
                : LLMCompletion(text: "Grammar fixture", generatedTokens: 23, duration: 0.5, finishedByLimit: true)
        }
    }

    /// Raw data remains only in the explicit private replay output. `finishedByLimit`
    /// is the exact completion flag; the corresponding existing usage row supplies the
    /// provider/recorder's finish reason. No guessed EOG or successful quality verdict.
    private struct PassTrace: Encodable, Sendable {
        let call: Int
        let feature: String?
        let pass: String?
        let system: String
        let user: String
        let maxTokens: Int
        let grammarText: String?
        let grammarRoot: String?
        var completion: String?
        var generatedTokens: Int?
        var duration: TimeInterval?
        var finishedByLimit: Bool?
        var errorType: String?
        var errorDescription: String?
    }

    private struct PassTracingProvider: LLMProvider {
        let provider: any LLMProvider
        let traces: OSAllocatedUnfairLock<[PassTrace]>
        var id: LLMProviderID { provider.id }
        var displayModelName: String { provider.displayModelName }
        var contextTokens: Int { provider.contextTokens }
        var enforcesGrammar: Bool { provider.enforcesGrammar }
        var unavailableReason: String? { get async { await provider.unavailableReason } }
        var supportsStructuredToolCalls: Bool { get async { await provider.supportsStructuredToolCalls } }
        func countTokens(_ text: String) async throws -> Int {
            try await provider.countTokens(text)
        }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            try await tracedComplete(system: system, user: user, maxTokens: maxTokens, grammar: nil)
        }
        func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar) async throws -> LLMCompletion {
            try await tracedComplete(system: system, user: user, maxTokens: maxTokens, grammar: grammar)
        }
        private func tracedComplete(system: String, user: String, maxTokens: Int,
                                    grammar: GBNFGrammar?) async throws -> LLMCompletion {
            let identity = ModelPassRecorder.current?.replayIdentity
            let index = traces.withLock { traces in
                let index = traces.count
                traces.append(PassTrace(call: index + 1, feature: identity?.feature,
                    pass: identity?.pass, system: system, user: user, maxTokens: maxTokens,
                    grammarText: grammar?.text, grammarRoot: grammar?.root))
                return index
            }
            do {
                // A direct await retains the caller's exact ModelPassRecorder task-local.
                // Do not create a Task, recorder, inference, retry or replacement result.
                let result: LLMCompletion
                if let grammar {
                    result = try await provider.complete(system: system, user: user,
                        maxTokens: maxTokens, grammar: grammar)
                } else {
                    result = try await provider.complete(system: system, user: user,
                        maxTokens: maxTokens)
                }
                traces.withLock {
                    $0[index].completion = result.text
                    $0[index].generatedTokens = result.generatedTokens
                    $0[index].duration = result.duration
                    $0[index].finishedByLimit = result.finishedByLimit
                }
                return result
            } catch {
                traces.withLock {
                    $0[index].errorType = String(reflecting: type(of: error))
                    $0[index].errorDescription = error.localizedDescription
                }
                throw error
            }
        }
    }

    private struct ReaderWindow: LLMProvider {
        let provider: any LLMProvider
        let contextTokens: Int
        var id: LLMProviderID { provider.id }
        var displayModelName: String { provider.displayModelName }
        var enforcesGrammar: Bool { provider.enforcesGrammar }
        var unavailableReason: String? { get async { await provider.unavailableReason } }
        func countTokens(_ text: String) async throws -> Int {
            try await provider.countTokens(text)
        }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            try await provider.complete(system: system, user: user, maxTokens: maxTokens)
        }
        func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar) async throws -> LLMCompletion {
            try await provider.complete(system: system, user: user, maxTokens: maxTokens, grammar: grammar)
        }
    }
}
