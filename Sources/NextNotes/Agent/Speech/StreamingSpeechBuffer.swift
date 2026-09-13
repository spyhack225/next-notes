import Foundation

/// Incremental reply text → clause-by-clause TTS while generation is still
/// in flight.
///
/// Producers with a real token stream should call `append` as chunks arrive
/// and `finalize` when the reply is complete. Explicit Qwen answers stream here;
/// one-shot tool and Foundation Models replies go through `RealtimeAudioSession.speak`,
/// which feeds the full text into this buffer in one append + finalize.
///
/// Silence rules use the accumulating buffer: if `spokenForm` is empty
/// (URL, tool name, code, long listing), nothing is enqueued. Incomplete
/// trailing text is held until a clause boundary or `finalize`.
@MainActor
final class StreamingSpeechBuffer {
    private let synthesizer: AgentSpeechSynthesizer
    private var buffer = ""
    private var flushedCount = 0
    private var cancelled = false
    /// True once at least one clause was handed to the synthesizer this turn.
    private(set) var didEnqueue = false

    init(synthesizer: AgentSpeechSynthesizer = .shared) {
        self.synthesizer = synthesizer
    }

    /// Start a new spoken reply. Clears any prior utterance / pending clauses.
    func begin() {
        cancelled = false
        buffer = ""
        flushedCount = 0
        didEnqueue = false
        synthesizer.prepareForStream()
    }

    /// Grow the reply. Completed clauses (same boundaries as
    /// `AgentSpeechPolicy.spokenClauses`) are enqueued immediately.
    func append(_ chunk: String) {
        guard !cancelled, !chunk.isEmpty else { return }
        let next = buffer + chunk
        if AgentSpeechPolicy.isUnsafeForStreaming(next) {
            buffer = next
            cancelled = true
            flushedCount = 0
            didEnqueue = false
            // This is deliberately stronger than clearing pending clauses: if an
            // unsafe token follows a spoken clause, stop the current utterance too.
            synthesizer.stop()
            return
        }
        buffer += chunk
        flush(finalize: false)
    }

    /// End of reply — speak any trailing incomplete clause, then stop accepting.
    func finalize() {
        guard !cancelled else { return }
        guard !AgentSpeechPolicy.isUnsafeForStreaming(buffer) else {
            cancelled = true
            synthesizer.stop()
            return
        }
        flush(finalize: true)
    }

    /// Barge-in / session end. Clears this buffer; caller still stops TTS.
    func cancel() {
        cancelled = true
        buffer = ""
        flushedCount = 0
        didEnqueue = false
    }

    /// Accumulated raw reply text for the current turn (empty after cancel).
    var accumulated: String { buffer }

    // MARK: - Flush

    private func flush(finalize: Bool) {
        let spoken = AgentSpeechPolicy.spokenForm(buffer)
        // Policy silence (URL / tool / code / listing): do not speak mid-stream.
        guard !spoken.isEmpty else { return }

        let all = AgentSpeechPolicy.splitIntoClauses(spoken)
        let ready = finalize ? all : completePrefix(of: all)
        let newOnes = Array(ready.dropFirst(flushedCount))
        guard !newOnes.isEmpty else { return }
        flushedCount = ready.count
        for clause in newOnes {
            synthesizer.enqueueClause(clause)
            didEnqueue = true
        }
    }

    /// Clauses that already ended on a boundary; hold an incomplete tail.
    private func completePrefix(of clauses: [String]) -> [String] {
        guard let last = clauses.last else { return [] }
        if Self.isCompleteClause(last) { return clauses }
        return Array(clauses.dropLast())
    }

    /// A clause is complete when it ends on the same marks `splitIntoClauses` cuts on.
    static func isCompleteClause(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return last == "." || last == "!" || last == "?"
            || last == ";" || last == "\u{2014}"
    }

    // MARK: - Self-test

    /// Incremental append speaks the first clause before the second chunk arrives.
    /// Interrupt clears the queue. Prints `TTS_TOKEN_STREAM_OK` / `FAILED`.
    /// Not wired into `NextNotesApp` — invoke directly (harness follow-up).
    @discardableResult
    static func runTokenStreamSelfTest() -> Bool {
        var failures: [String] = []
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking() }

        let buffer = StreamingSpeechBuffer(synthesizer: synth)
        buffer.begin()
        buffer.append("Hello there. ")

        if recorder.spoken != ["Hello there."] {
            failures.append(
                "token-stream: first clause should speak after first append, got \(recorder.spoken)"
            )
        }
        if !buffer.didEnqueue {
            failures.append("token-stream: didEnqueue should be true after first clause")
        }
        let spokenAfterFirst = recorder.spoken.count

        buffer.append("More text.")
        // Second append finalizes the second clause only after finalize — "More text."
        // ends with `.`, so it should enqueue as a pending (or spoken if advanced) clause.
        if recorder.spoken.count < spokenAfterFirst {
            failures.append("token-stream: second append must not clear the first clause")
        }
        // With recording backing still “speaking”, the second clause sits in pending.
        if synth.pendingClauseCount < 1, recorder.spoken.count < 2 {
            failures.append(
                "token-stream: second complete clause should enqueue (spoken=\(recorder.spoken), pending=\(synth.pendingClauseCount))"
            )
        }

        // Fresh turn: first clause before second append; then interrupt clears pending.
        recorder.reset()
        buffer.begin()
        buffer.append("Hello there. ")
        if recorder.spoken != ["Hello there."] {
            failures.append(
                "token-stream: re-begin first clause, got \(recorder.spoken)"
            )
        }
        buffer.append("More text.")
        if synth.pendingClauseCount < 1 {
            failures.append(
                "token-stream: expected pending after second append, got \(synth.pendingClauseCount)"
            )
        }

        RealtimeAgent.shared.interrupt()
        if !synth.didStop || recorder.stopCount == 0 {
            failures.append("token-stream: interrupt did not stop synthesizer")
        }
        if synth.pendingClauseCount != 0 {
            failures.append(
                "token-stream: interrupt left \(synth.pendingClauseCount) pending"
            )
        }
        if recorder.spoken.count != 1 {
            failures.append(
                "token-stream: interrupt must not speak remaining clauses, got \(recorder.spoken)"
            )
        }

        // Silence mid-stream: URL reply must never enqueue.
        recorder.reset()
        buffer.begin()
        buffer.append("Open https://example.com/doc ")
        buffer.append("for the write-up.")
        buffer.finalize()
        if !recorder.spoken.isEmpty || synth.pendingClauseCount != 0 {
            failures.append(
                "token-stream: URL buffer must stay silent, got spoken=\(recorder.spoken) pending=\(synth.pendingClauseCount)"
            )
        }

        if failures.isEmpty {
            print("TTS_TOKEN_STREAM_OK")
            return true
        }
        for failure in failures {
            print("  \(failure)")
        }
        print("TTS_TOKEN_STREAM_FAILED")
        return false
    }
}
