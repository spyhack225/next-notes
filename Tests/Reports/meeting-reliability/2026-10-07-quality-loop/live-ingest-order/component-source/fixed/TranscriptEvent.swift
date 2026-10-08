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

