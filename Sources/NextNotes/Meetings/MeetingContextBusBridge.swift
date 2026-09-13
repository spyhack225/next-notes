import Foundation

/// Subscribes to `TranscriptBus` finals and feeds them into `MeetingContextStore`.
///
/// `MeetingSession.add` already calls `ingest(segments:)` and then publishes the same
/// final on the bus. Both paths share the store's ingest-key set, so a Session-then-bus
/// round trip does not double-apply the extractor. The bus path exists so a final that
/// never went through Session (self-tests, future producers) still updates live context
/// without polling.
@MainActor
enum MeetingContextBusBridge {
    private static var listenTask: Task<Void, Never>?

    /// Idempotent. Called from `MeetingContextStore` so the subscription is owned with
    /// the context it writes, not with the agent card layer.
    static func start(
        store: MeetingContextStore = .shared,
        bus: TranscriptBus = .shared
    ) {
        guard listenTask == nil else { return }
        listenTask = Task { [weak store] in
            let stream = await bus.subscribe()
            for await event in stream {
                guard !Task.isCancelled else { break }
                guard let store else { break }
                store.ingestFinal(event)
            }
        }
    }

    /// Cancels the shared listener. Self-tests only — production keeps one subscription
    /// for the process lifetime.
    static func stopForTesting() {
        listenTask?.cancel()
        listenTask = nil
    }

    /// Sync half: the same `ingestFinal` the bus listener calls. Exercised from
    /// `MeetingLiveAgent.runSelfTest` (already wired) so NextNotesApp does not need a
    /// second flag. Prints its own `MEETING_BUS_OK` / `FAILED` line.
    @discardableResult
    static func runSelfTest() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let store = MeetingContextStore.shared
        let previous = store.current
        defer {
            store.replace(previous)
        }

        let meetingID = UUID()
        store.replace(
            MeetingContext.empty(meetingID: meetingID, title: "Bus bridge", participants: [])
        )

        let ask = TranscriptEvent(
            meetingID: meetingID,
            source: .mic,
            text: "Can you send the deck?",
            start: 1,
            end: 3,
            isFinal: true
        )
        store.ingestFinal(ask)

        let afterFirst = store.current?.candidateActions.count ?? 0
        check(
            "publishing a final ask produced no candidate",
            afterFirst == 1
                && (store.current?.candidateActions.first?.object == "deck")
        )

        // Identical final again — Session+bus would deliver this shape.
        store.ingestFinal(ask)
        check(
            "duplicate identical final duplicated candidates",
            (store.current?.candidateActions.count ?? 0) == afterFirst
        )

        // Non-final must not touch context.
        let beforeProvisional = store.current?.updatedAt
        store.ingestFinal(
            TranscriptEvent(
                meetingID: meetingID,
                source: .mic,
                text: "Can you send the proposal?",
                start: 4,
                end: 6,
                isFinal: false,
                provisionalID: UUID()
            )
        )
        check(
            "a provisional finalised a candidate",
            (store.current?.candidateActions.count ?? 0) == afterFirst
        )
        check(
            "a provisional bumped updatedAt",
            store.current?.updatedAt == beforeProvisional
        )

        // A final for a different meeting must be ignored while another is active.
        store.ingestFinal(
            TranscriptEvent(
                meetingID: UUID(),
                source: .mic,
                text: "Can you send the deck?",
                start: 7,
                end: 9,
                isFinal: true
            )
        )
        check(
            "a foreign meeting's final was ingested",
            (store.current?.candidateActions.count ?? 0) == afterFirst
        )

        for failure in failures {
            emit("  MEETING_BUS_WRONG: \(failure)")
        }
        emit(failures.isEmpty ? "MEETING_BUS_OK" : "MEETING_BUS_FAILED")
        return failures.isEmpty
    }

    private static func emit(_ line: String) {
        let text = "\(line)\n"
        FileHandle.standardOutput.write(Data(text.utf8))
        Log.app.info("selftest · \(line, privacy: .public)")
        guard let path = SelfTest.outputPath else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
