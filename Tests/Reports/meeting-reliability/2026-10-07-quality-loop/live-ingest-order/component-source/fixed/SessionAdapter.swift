import Foundation
@MainActor final class SessionAdapter {
    var meeting: Meeting; var segments: [TranscriptSegment] = []
    var lastSpeechAt = Date(); var startedAt = Date(); var elapsed: Double = 100
    var provisionalText: [AudioSource:String] = [:]
    var openProvisionalIDs: [AudioSource:UUID] = [:]
    var transcriptNow: Date { Date() }; var transcriptThrottle = Throttle()
    init(_ meeting: Meeting) { self.meeting = meeting }
    func accept(_ row: TranscriptSegment) { add(row) }
    func armTrailingTranscriptWrite() { }
    func writeTranscript(at clock: Double) { }
    private func add(_ segment: TranscriptSegment) {
        lastSpeechAt = Date()
        let incoming = ActivationController.shared.handleWake(in: segment)
        // M-16c: the ordered insert and the file write travel together, so the write
        // throttle cannot be exercised apart from the write it governs. `add` and
        // `--selftest-meeting-resume` come through this one method.
        insertSegment(incoming, now: transcriptNow)
        provisionalText[incoming.source] = nil
        let provisionalID = openProvisionalIDs.removeValue(forKey: incoming.source)

        let speechLag = max(0, Date().timeIntervalSince(startedAt) - incoming.end)
        LatencyTrace.record(
            .meetingSpeechToFinal,
            seconds: speechLag,
            note: incoming.source.rawValue
        )

        let candidatesBefore = MeetingContextStore.shared.current?.candidateActions.count ?? 0
        let contextTrace = LatencyTrace.start(.meetingTranscriptToContext)
        MeetingContextStore.shared.ingest([incoming], meeting: meeting)
        contextTrace.end(note: incoming.source.rawValue)
        let candidatesAfter = MeetingContextStore.shared.current?.candidateActions.count ?? 0
        if candidatesAfter > candidatesBefore {
            // Phrase → candidate is measured here. Candidate → card is measured at the
            // IslandState hand-off, after a card has actually been proposed.
            let phraseLag = max(0, Date().timeIntervalSince(startedAt) - incoming.end)
            LatencyTrace.record(
                .meetingActionPhraseToCandidate,
                seconds: phraseLag,
                note: incoming.source.rawValue
            )
        }

        Task {
            await TranscriptBus.shared.publish(
                TranscriptEvent(
                    meetingID: meeting.id,
                    source: incoming.source,
                    text: incoming.text,
                    start: incoming.start,
                    end: incoming.end,
                    isFinal: true,
                    provisionalID: provisionalID
                )
            )
        }
    }
    private func insertSegment(_ segment: TranscriptSegment, now: Date) {
        let index = segments.firstIndex { $0.start > segment.start } ?? segments.endIndex
        segments.insert(segment, at: index)
        let clock = now.timeIntervalSince1970
        transcriptThrottle.markPending()
        guard transcriptThrottle.shouldWrite(at: clock) else {
            armTrailingTranscriptWrite()
            return
        }
        writeTranscript(at: clock)
    }
}
