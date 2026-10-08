import Foundation

/// Which microphone a segment came from.
///
/// Two tracks rather than a mixdown is the decision the whole meeting feature rests on:
/// it buys "You / Others" attribution for nothing, and it lets Phase 5 diarize only the
/// side that actually contains several people. The known cost is bleed — with laptop
/// speakers and the built-in microphone, remote voices also land on the mic track.
enum AudioSource: String, Codable, Sendable, CaseIterable {
    case mic
    case system

    /// The speaker name a segment gets before any diarization has run.
    var defaultSpeaker: String {
        switch self {
        case .mic: "You"
        case .system: "Others"
        }
    }
}

/// Whether a segment is ordinary speech or an agent command spoken during the meeting.
enum TranscriptKind: String, Codable, Sendable {
    case speech
    case agentCommand
}

/// One stretch of speech, positioned in seconds from the start of the recording.
struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let source: AudioSource
    /// Set by diarization in Phase 5. Until then the source's default name is used.
    var speaker: String?
    /// Nil in every file written before v2, and read as ordinary speech there.
    var kind: TranscriptKind?

    var displaySpeaker: String { speaker ?? source.defaultSpeaker }

    /// Agent commands stay in the audit trail and drop out of notes.
    var includeInMeetingNotes: Bool { kind != .agentCommand }

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        source: AudioSource,
        speaker: String? = nil,
        kind: TranscriptKind? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.source = source
        self.speaker = speaker
        self.kind = kind
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        source = try container.decode(AudioSource.self, forKey: .source)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        kind = try container.decodeIfPresent(TranscriptKind.self, forKey: .kind)
    }
}

