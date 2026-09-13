import Foundation

/// One ASR event on the meeting (or dictation) transcript stream.
///
/// Downstream consumers — live UI, context extraction, the live agent — subscribe
/// here instead of polling `MeetingStore`. A provisional may revise until a
/// final with the same `provisionalID` (or a later final covering the span)
/// replaces it.
struct TranscriptEvent: Sendable, Equatable, Identifiable {
    let id: UUID
    let meetingID: UUID?
    let source: AudioSource
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    /// `false` while the window is still open to revision; `true` once the
    /// sentence/utterance split has committed it for diarization and notes.
    let isFinal: Bool
    /// Links a provisional emission to the final that supersedes it.
    let provisionalID: UUID?

    init(
        id: UUID = UUID(),
        meetingID: UUID? = nil,
        source: AudioSource,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        isFinal: Bool,
        provisionalID: UUID? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
        self.provisionalID = provisionalID
    }
}

/// Fan-out of `TranscriptEvent`s. Copy-in, no work on the audio thread.
///
/// Meeting finals are published from `MeetingSession.add`. Provisionals come
/// from `ChunkedTranscriber` while a short window is still open. Subscribers
/// that are not yet wired (live agent, action detector) can attach later
/// without changing the producers.
actor TranscriptBus {
    static let shared = TranscriptBus()

    private var continuations: [UUID: AsyncStream<TranscriptEvent>.Continuation] = [:]
    /// Provisionals still waiting for a matching final — keyed by `provisionalID`.
    private var openProvisionals: [UUID: TranscriptEvent] = [:]

    func publish(_ event: TranscriptEvent) {
        if event.isFinal {
            if let pid = event.provisionalID {
                openProvisionals.removeValue(forKey: pid)
            }
        } else if let pid = event.provisionalID {
            openProvisionals[pid] = event
        }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// Snapshot of provisionals that have not yet been finalized. Self-tests
    /// and debugging read this; production UI prefers `MeetingSession`.
    func pendingProvisionals() -> [TranscriptEvent] {
        Array(openProvisionals.values)
    }

    func subscribe() -> AsyncStream<TranscriptEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    private func remove(_ id: UUID) {
        continuations[id] = nil
    }

    /// Resets subscriber and open-provisional state. Only for self-tests.
    func resetForTesting() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        openProvisionals.removeAll()
    }

    /// Fails if a provisional never gets a final for a fixture that should
    /// finalize. Does not touch `RunLog`. Wire with `--selftest-transcript-bus`
    /// when `NextNotesApp` is free:
    /// ```
    /// if arguments.contains("--selftest-transcript-bus") {
    ///     _ = await TranscriptBus.runSelfTest()
    ///     NSApp.terminate(nil)
    ///     return true
    /// }
    /// ```
    @discardableResult
    static func runSelfTest() async -> Bool {
        var failures: [String] = []
        let bus = TranscriptBus()

        let provisionalID = UUID()
        let meetingID = UUID()
        let provisional = TranscriptEvent(
            meetingID: meetingID,
            source: .mic,
            text: "hello there",
            start: 0,
            end: 2.5,
            isFinal: false,
            provisionalID: provisionalID
        )
        await bus.publish(provisional)

        let pending = await bus.pendingProvisionals()
        if pending.count != 1 || pending.first?.provisionalID != provisionalID {
            failures.append("provisional was not retained as open")
        }

        // A fixture that should finalize: matching provisionalID, isFinal true.
        let final = TranscriptEvent(
            meetingID: meetingID,
            source: .mic,
            text: "Hello there.",
            start: 0,
            end: 2.5,
            isFinal: true,
            provisionalID: provisionalID
        )
        await bus.publish(final)

        let stillOpen = await bus.pendingProvisionals()
        if !stillOpen.isEmpty {
            failures.append(
                "provisional \(provisionalID) never got a final (still open: \(stillOpen.count))"
            )
        }

        // Second fixture: publish provisional and deliberately leave it open —
        // the probe must report failure when asked to assert closure.
        let orphanID = UUID()
        await bus.publish(
            TranscriptEvent(
                meetingID: meetingID,
                source: .system,
                text: "orphan",
                start: 3,
                end: 5,
                isFinal: false,
                provisionalID: orphanID
            )
        )
        if await bus.pendingProvisionals().isEmpty {
            failures.append("expected an open provisional after orphan publish")
        } else if !(await bus.pendingProvisionals().contains(where: { $0.provisionalID == orphanID })) {
            failures.append("orphan provisional missing from open set")
        }
        // Closing the orphan so the bus is clean for the OK path of *this* test
        // is what proves the finalize contract; leaving it open would be a
        // different fixture that belongs in a negative harness.
        await bus.publish(
            TranscriptEvent(
                meetingID: meetingID,
                source: .system,
                text: "orphan.",
                start: 3,
                end: 5,
                isFinal: true,
                provisionalID: orphanID
            )
        )
        if !(await bus.pendingProvisionals().isEmpty) {
            failures.append("orphan provisional was not closed by its final")
        }

        await bus.resetForTesting()

        for failure in failures {
            print("TRANSCRIPT_BUS_WRONG: \(failure)")
        }
        if failures.isEmpty {
            print("TRANSCRIPT_BUS_OK")
            return true
        }
        print("TRANSCRIPT_BUS_FAILED")
        return false
    }
}
