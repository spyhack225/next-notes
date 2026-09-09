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

/// One stretch of speech, positioned in seconds from the start of the recording.
struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let source: AudioSource
    /// Set by diarization in Phase 5. Until then the source's default name is used.
    var speaker: String?

    var displaySpeaker: String { speaker ?? source.defaultSpeaker }

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        source: AudioSource,
        speaker: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.source = source
        self.speaker = speaker
    }
}

/// Where a meeting is in its life.
///
/// The states are persisted, so a crash mid-transcription is visible as exactly that
/// rather than as a meeting that silently lost its transcript.
enum MeetingStatus: Codable, Sendable, Equatable {
    /// Known from the calendar, not started. Phase 3 fills this in.
    case scheduled
    /// The scheduler has claimed it and is waiting for the start time.
    case armed
    case recording
    case transcribing
    /// Speakers are being told apart on the system track. Between transcribing and notes on
    /// purpose: the notes are written from the transcript's own labels, so a name learned
    /// here is a name the notes can attribute an action item to.
    case diarizing
    /// Notes are being generated.
    case summarizing
    case done
    case failed(String)

    var isActive: Bool {
        switch self {
        case .recording, .transcribing, .diarizing, .summarizing: true
        case .scheduled, .armed, .done, .failed: false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .scheduled: "Scheduled"
        case .armed: "Armed"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .diarizing: "Identifying speakers"
        case .summarizing: "Writing notes"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    /// Codable by hand: `failed` carries a reason, and a synthesized enum encoding would
    /// bake SwiftUI-invisible key names into a file the next phases keep reading.
    private enum CodingKeys: String, CodingKey {
        case state
        case reason
    }

    private enum State: String, Codable {
        case scheduled, armed, recording, transcribing, diarizing, summarizing, done, failed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .scheduled: self = .scheduled
        case .armed: self = .armed
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .diarizing: self = .diarizing
        case .summarizing: self = .summarizing
        case .done: self = .done
        case .failed:
            self = .failed(try container.decodeIfPresent(String.self, forKey: .reason) ?? "Unknown error")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .scheduled: try container.encode(State.scheduled, forKey: .state)
        case .armed: try container.encode(State.armed, forKey: .state)
        case .recording: try container.encode(State.recording, forKey: .state)
        case .transcribing: try container.encode(State.transcribing, forKey: .state)
        case .diarizing: try container.encode(State.diarizing, forKey: .state)
        case .summarizing: try container.encode(State.summarizing, forKey: .state)
        case .done: try container.encode(State.done, forKey: .state)
        case .failed(let reason):
            try container.encode(State.failed, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// One meeting: what it was, when, and what came out of it.
///
/// The heavy parts — transcript, notes, audio — live in sibling files rather than in this
/// struct, so listing a hundred meetings reads a hundred small JSON files instead of a
/// hundred transcripts.
struct Meeting: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var start: Date
    var end: Date?

    /// Set when the meeting came from a calendar. `providerID` is the raw value of
    /// Phase 3's `CalendarProviderID`; kept as a string so the file format survives that
    /// type arriving later.
    var calendarEventID: String?
    var providerID: String?
    var attendees: [String] = []
    var conferenceURL: URL?
    var calendarName: String?

    var status: MeetingStatus = .scheduled
    /// Present only when `Settings.meetingsKeepAudio` was on for this recording.
    var audioFileName: String?
    /// Whether this recording exists only so the speakers could be told apart.
    ///
    /// Answered when the recording starts rather than read out of the settings when it
    /// ends: a meeting recorded while "Keep the recorded audio" was on is the user's copy
    /// for good, and turning that switch off next month must not reach back and delete it.
    /// Optional so meetings written before this existed still decode — nil reads as "the
    /// user asked for this one", the answer that keeps a file rather than deleting one.
    var audioIsTemporary: Bool?
    /// Which model wrote the notes, once Phase 4 writes any.
    var notesModel: String?
    /// Diarized speaker renames, keyed by the generated label ("Speaker 1").
    var speakerNames: [String: String] = [:]
    /// What the meeting agent has actually done in the user's Workspace, and where to find
    /// it. Kept on the meeting rather than in memory because "have I already emailed these
    /// notes to the room?" has to survive a quit, and because the link is the only way back
    /// to a document once the proposal that made it is gone.
    var agentActions: [AgentActionRecord] = []

    /// How long the recording ran, once it has stopped.
    var duration: TimeInterval? {
        guard let end else { return nil }
        return end.timeIntervalSince(start)
    }

    init(
        id: UUID = UUID(),
        title: String,
        start: Date = Date(),
        end: Date? = nil,
        calendarEventID: String? = nil,
        providerID: String? = nil,
        attendees: [String] = [],
        conferenceURL: URL? = nil,
        calendarName: String? = nil,
        status: MeetingStatus = .scheduled,
        audioFileName: String? = nil,
        audioIsTemporary: Bool? = nil,
        notesModel: String? = nil,
        speakerNames: [String: String] = [:],
        agentActions: [AgentActionRecord] = []
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarEventID = calendarEventID
        self.providerID = providerID
        self.attendees = attendees
        self.conferenceURL = conferenceURL
        self.calendarName = calendarName
        self.status = status
        self.audioFileName = audioFileName
        self.audioIsTemporary = audioIsTemporary
        self.notesModel = notesModel
        self.speakerNames = speakerNames
        self.agentActions = agentActions
    }

    /// Decoded by hand for one reason: a synthesized `init(from:)` does not treat a
    /// property's default value as a fallback for a key that isn't there, so every field
    /// added to this struct after the first meeting was written turns every earlier
    /// `meeting.json` into a decoding error — and a meeting that fails to decode is a
    /// meeting that has silently vanished from the list. `agentActions` is the one that
    /// proved it; the other collections are read the same way so the next addition is free.
    /// `id`, `title` and `start` stay required: a file without them is not a meeting, and
    /// minting a fresh id for it would orphan the folder it lives in.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decodeIfPresent(Date.self, forKey: .end)
        calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        attendees = try container.decodeIfPresent([String].self, forKey: .attendees) ?? []
        conferenceURL = try container.decodeIfPresent(URL.self, forKey: .conferenceURL)
        calendarName = try container.decodeIfPresent(String.self, forKey: .calendarName)
        status = try container.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .scheduled
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        audioIsTemporary = try container.decodeIfPresent(Bool.self, forKey: .audioIsTemporary)
        notesModel = try container.decodeIfPresent(String.self, forKey: .notesModel)
        speakerNames = try container.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        agentActions = try container.decodeIfPresent(
            [AgentActionRecord].self,
            forKey: .agentActions
        ) ?? []
    }
}
