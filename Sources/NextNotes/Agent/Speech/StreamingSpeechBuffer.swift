import Foundation

/// Incremental reply text → clause-by-clause TTS while generation is still
/// in flight.
///
/// Producers with a real token stream should call `append` as chunks arrive
/// and `finalize` when the reply is complete. Explicit on-device answers stream here;
/// one-shot tool and Foundation Models replies go through `RealtimeAudioSession.speak`,
/// which feeds the full text into this buffer in one append + finalize.
///
/// Silence rules use the accumulating buffer: if `isSpeakableReply` is false
/// (URL, tool id, code, file or long listing), nothing is enqueued. Length is
/// judged per clause by `speakableClauses`, so a long reply is still spoken in
/// full and a clause already playing is never stopped for being long.
/// Incomplete trailing text is held until a clause boundary or `finalize`.
@MainActor
final class StreamingSpeechBuffer {
    private let synthesizer: AgentSpeechSynthesizer
    private var buffer = ""
    private var flushedCount = 0
    // Keep clause indexing: the policy splits long clauses and ASCII dashes.
    // Only the first clause may have a prefix already handed to playback.
    private var firstChunkCharacters = 0
    static let firstChunkMinimumWords = 4
    static let firstChunkForceWords = 8
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
        firstChunkCharacters = 0
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
            firstChunkCharacters = 0
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
        synthesizer.finishStream()
    }

    /// Barge-in / session end. Clears this buffer; caller still stops TTS.
    func cancel() {
        cancelled = true
        buffer = ""
        flushedCount = 0
        firstChunkCharacters = 0
        didEnqueue = false
    }

    /// Accumulated raw reply text for the current turn (empty after cancel).
    var accumulated: String { buffer }

    // MARK: - Flush

    private func flush(finalize: Bool) {
        // Whole-reply content silencers (URL / tool id / code / listing): do not
        // start speaking. A clause already playing is never stopped here.
        guard AgentSpeechPolicy.isSpeakableReply(buffer) else { return }

        let all = AgentSpeechPolicy.speakableClauses(buffer)
        let ready = finalize ? all : completePrefix(of: all)
        if !finalize, !didEnqueue, ready.isEmpty,
           let first = all.first,
           // The policy trims the clause. Keep its original next character so
           // a trailing space proves the last word/punctuation is complete.
           let chunk = Self.firstChunk(in: String(buffer.drop(while: { $0.isWhitespace })
               .prefix(first.count + 1))) {
            firstChunkCharacters = chunk.count
            VoiceLatencyTimeline.shared.mark(.firstClauseEnqueued)
            synthesizer.enqueueClause(chunk)
            didEnqueue = true
            return
        }
        var newOnes = Array(ready.dropFirst(flushedCount))
        guard !newOnes.isEmpty else { return }
        if flushedCount == 0, firstChunkCharacters > 0 {
            newOnes[0] = String(newOnes[0].dropFirst(firstChunkCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            firstChunkCharacters = 0
        }
        flushedCount = ready.count
        for clause in newOnes where !clause.isEmpty {
            // The first clause of a reply is the boundary between the model's first token
            // and the synthesizer, so it is stamped once per reply, here, before the enqueue.
            if !didEnqueue {
                VoiceLatencyTimeline.shared.mark(.firstClauseEnqueued)
            }
            synthesizer.enqueueClause(clause)
            didEnqueue = true
        }
    }

    /// Cut only a complete word, after the existing whole-reply safety checks.
    /// A comma in 1,000 or a colon in 09:00 has no following whitespace.
    private static func firstChunk(in clause: String) -> String? {
        for index in clause.indices where [",", ":", "、"].contains(clause[index]) {
            let next = clause.index(after: index)
            guard next < clause.endIndex, clause[next].isWhitespace else { continue }
            let prefix = String(clause[...index])
            if prefix.split(whereSeparator: \.isWhitespace).count >= firstChunkMinimumWords,
               prefix.count <= AgentSpeechPolicy.shortLimit { return prefix }
        }
        var words = 0
        var insideWord = false
        for index in clause.indices {
            if clause[index].isWhitespace {
                if insideWord { words += 1; insideWord = false }
                if words == firstChunkForceWords {
                    let prefix = String(clause[..<index])
                    return prefix.count <= AgentSpeechPolicy.shortLimit ? prefix : nil
                }
            } else { insideWord = true }
        }
        return nil
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

        // P2-06: exercise the actual buffer -> synthesizer -> backing seam.
        // These are software clause receipts, not a claim about audible onset.
        var enqueued: [String] = []
        let priorPlaybackEvent = synth.onPlaybackEvent
        synth.onPlaybackEvent = { event in
            if case .enqueued(let text) = event { enqueued.append(text) }
        }
        defer { synth.onPlaybackEvent = priorPlaybackEvent; synth.stop() }
        func fresh() {
            recorder.reset()
            enqueued.removeAll()
            buffer.begin()
        }
        func check(_ label: String, _ condition: Bool) {
            if !condition { failures.append("first-chunk: " + label) }
        }
        for mark in [",", ":", "、"] {
            fresh()
            buffer.append("Here are your next steps" + mark + " ")
            check("\(mark) starts before sentence end", recorder.spoken == ["Here are your next steps" + mark])
            buffer.append("we can review them together.")
            buffer.finalize()
            buffer.finalize()
            check("\(mark) retains its exact remainder once", enqueued == ["Here are your next steps" + mark, "we can review them together."])
        }
        fresh()
        buffer.append("I can help you organise these notes today ")
        check("eight complete words start before punctuation", recorder.spoken == ["I can help you organise these notes today"])
        buffer.append("and keep the original files safe.")
        buffer.finalize()
        check("forced chunk retains the exact remainder", enqueued == ["I can help you organise these notes today", "and keep the original files safe."])
        fresh()
        buffer.append("Here are steps, ")
        check("short comma waits", enqueued.isEmpty)
        fresh()
        buffer.append("I can help you organise these notes today")
        check("incomplete eighth word waits", enqueued.isEmpty)
        buffer.append("ish ")
        check("continued word is kept whole", enqueued == ["I can help you organise these notes todayish"])
        fresh()
        buffer.append("We have a total of 1,000 ")
        check("number separator never cuts a chunk", enqueued.isEmpty)
        buffer.append("files.")
        buffer.finalize()
        check("number remains intact", enqueued == ["We have a total of 1,000 files."])
        fresh()
        buffer.append("Here are your next steps, ")
        buffer.append("read https://example.com for details.")
        check("unsafe continuation stops pending playback", synth.didStop && synth.pendingClauseCount == 0 && !recorder.isSpeaking)
        buffer.finalize()
        check("unsafe continuation never enqueues", enqueued == ["Here are your next steps,"])
        fresh()
        buffer.append("Here are your next steps, ")
        buffer.cancel()
        synth.stop()
        buffer.append("this cancelled continuation must stay silent.")
        buffer.finalize()
        check("cancellation retains only the original chunk", enqueued == ["Here are your next steps,"])
        fresh()
        buffer.append("Here is a complete sentence. Another follows.")
        buffer.finalize()
        check("complete sentences retain existing boundaries", enqueued == ["Here is a complete sentence.", "Another follows."])

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
