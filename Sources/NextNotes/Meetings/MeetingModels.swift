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
    /// Decisions, action items, open questions and people are being extracted from the notes
    /// into `notes.json` and the knowledge graph (Part 4, Phase C). Only while
    /// `knowledgeGraphEnabled` is on. Persisted like every other state, so a crash during
    /// extraction is visible as exactly that.
    case extracting
    case done
    case failed(String)

    var isActive: Bool {
        switch self {
        case .recording, .transcribing, .diarizing, .summarizing, .extracting: true
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
        case .extracting: "Extracting decisions"
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
        case scheduled, armed, recording, transcribing, diarizing, summarizing, extracting, done, failed
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
        case .extracting: self = .extracting
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
        case .extracting: try container.encode(State.extracting, forKey: .state)
        case .done: try container.encode(State.done, forKey: .state)
        case .failed(let reason):
            try container.encode(State.failed, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// A meeting name the user typed. Empty after trimming is not a name: `title` is required
/// on disk, and saving a blank one would make the row look deleted.
enum MeetingTitle {
    static func cleaned(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Where a meeting's title came from (M1-a).
///
/// `Meeting · 14:30` is a placeholder, not a name. Anything that learns names — activity
/// refresh, grounding, recall — skips `.auto`, the list renders it dimmed/provisional,
/// and the first rename or calendar link flips the source before any memory is written.
enum MeetingTitleSource: String, Codable, Sendable {
    /// Placeholder from `MeetingController.defaultTitle` or an undated import.
    case auto
    /// Taken from the calendar event it was armed for.
    case calendar
    /// Typed by the person (rename, or a title passed to `startAdHoc`).
    case user
}

/// Capture facts are independent of processing: writing notes cannot establish that
/// a whole meeting was recorded. Constant-sized metadata, never a second timeline.
enum MeetingCaptureInterruptionReason: String, Codable, Sendable {
    case unknown
    case captureFailure
    case audioWriteFailure
}

struct MeetingCaptureIntegrity: Codable, Sendable, Equatable {
    /// Audio progress established by the producer, or persisted transcript evidence
    /// for an older recording. Never a file's modification time.
    var lastCapturedAt: Date?
    var normalEndAt: Date?
    var interruptedAt: Date?
    var interruptionReason: MeetingCaptureInterruptionReason?
    /// A delivery gap may have an unknown number of frames.
    var captureGap = false
    var missingCaptureFrames: Int64 = 0
    var audioWriteFailed = false
    /// Originals delivered to live ASR but trimmed behind the saved file cursor.
    /// Optional for records written before this measurement existed.
    var missingSavedMicFrames: Int64?
    var missingSavedSystemFrames: Int64?

    func hasKnownSavedAudioLoss(on source: AudioSource) -> Bool {
        audioWriteFailed || (source == .mic ? missingSavedMicFrames ?? 0
            : missingSavedSystemFrames ?? 0) > 0
    }

    var hasPartialCapture: Bool {
        interruptedAt != nil || captureGap || missingCaptureFrames > 0 || audioWriteFailed
            || (missingSavedMicFrames ?? 0) > 0 || (missingSavedSystemFrames ?? 0) > 0
    }

    mutating func recordCaptured(until date: Date) {
        lastCapturedAt = max(lastCapturedAt ?? date, date)
    }

    mutating func markInterrupted(
        at date: Date = Date(), lastCapturedAt boundary: Date? = nil,
        reason: MeetingCaptureInterruptionReason = .unknown
    ) {
        if let boundary { recordCaptured(until: boundary) }
        interruptedAt = min(interruptedAt ?? date, date)
        if interruptionReason == nil || interruptionReason == .unknown {
            interruptionReason = reason
        }
    }

    mutating func markGap(missingFrames: Int64? = nil) {
        captureGap = true
        if let missingFrames, missingFrames > 0 {
            let (sum, overflow) = missingCaptureFrames.addingReportingOverflow(missingFrames)
            missingCaptureFrames = overflow ? .max : sum
        }
    }

    mutating func markAudioWriteFailure() { audioWriteFailed = true }

    /// Multiple existing producers save whole Meeting values. Facts cannot be
    /// erased by an older pipeline value, regeneration, or a later normal Stop.
    /// Counts are cumulative snapshots, so merging takes max rather than adding.
    func merged(preserving stored: Self?) -> Self {
        guard let stored else { return self }
        var result = self
        if let date = stored.lastCapturedAt { result.recordCaptured(until: date) }
        if let date = stored.normalEndAt {
            result.normalEndAt = max(result.normalEndAt ?? date, date)
        }
        if let date = stored.interruptedAt {
            result.markInterrupted(at: date, reason: stored.interruptionReason ?? .unknown)
        }
        result.captureGap = captureGap || stored.captureGap
        result.missingCaptureFrames = max(missingCaptureFrames, stored.missingCaptureFrames)
        result.audioWriteFailed = audioWriteFailed || stored.audioWriteFailed
        if missingSavedMicFrames != nil || stored.missingSavedMicFrames != nil {
            result.missingSavedMicFrames = max(missingSavedMicFrames ?? 0, stored.missingSavedMicFrames ?? 0)
        }
        if missingSavedSystemFrames != nil || stored.missingSavedSystemFrames != nil {
            result.missingSavedSystemFrames = max(missingSavedSystemFrames ?? 0, stored.missingSavedSystemFrames ?? 0)
        }
        return result
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
    /// Where the title came from. Optional on disk so meetings written before M1-a still
    /// decode — nil reads as `.auto` when the title looks like a placeholder, else `.user`.
    var titleSource: MeetingTitleSource?
    var start: Date
    var end: Date?

    /// Set when the meeting came from a calendar. `providerID` is the raw value of
    /// Phase 3's `CalendarProviderID`; kept as a string so the file format survives that
    /// type arriving later.
    var calendarEventID: String?
    var providerID: String?
    /// The call this meeting was started for, when there was one (M-11).
    ///
    /// `CallDetector.identity` of the call, which is stable for the length of that call
    /// and different for the next one. A calendar event whose meeting was started early
    /// because its call settled first carries it, and two rules read it: the recording
    /// stops shortly after that call hangs up, and the overrun rule will stop it at the
    /// scheduled end once the call has gone rather than waiting out the silence. Nil is
    /// the ordinary case — a meeting nobody joined early, and every meeting written
    /// before the field existed — and it is read, never inferred.
    var coveringCallID: String?
    var attendees: [String] = []
    var conferenceURL: URL?
    var calendarName: String?

    var status: MeetingStatus = .scheduled
    /// Nil on older rows means capture completeness is unknown, not verified.
    var captureIntegrity: MeetingCaptureIntegrity?
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
    /// When a temporary recording becomes releasable (M-10): the pipeline end that
    /// last had a use for it stamped this 72 hours ahead instead of deleting the
    /// file at once. Nil means "no window" — the user asked to keep the recording,
    /// or an older build wrote the file. The sweeper and `releaseAudioWhenDue`
    /// read it; `releaseAudio` alone still does the deleting.
    var audioReleaseAfter: Date?
    /// Which transcript `transcript.json` holds (M-01).
    ///
    /// `"long-window"` when the post-Stop final pass replaced the live tier (kept as
    /// `transcript.live.json`); `"live-only:no-audio"`, `"live-only:rejected"` or
    /// `"live-only:failed"` when it did not, for that reason. Nil for meetings written
    /// before the pass existed — read as "unknown", never as a claim.
    var transcriptPass: String?
    /// Which model wrote the notes, once Phase 4 writes any.
    var notesModel: String?
    /// Diarized speaker renames, keyed by the generated label ("Speaker 1").
    var speakerNames: [String: String] = [:]
    /// What the meeting agent has actually done in the user's Workspace, and where to find
    /// it. Kept on the meeting rather than in memory because "have I already emailed these
    /// notes to the room?" has to survive a quit, and because the link is the only way back
    /// to a document once the proposal that made it is gone.
    var agentActions: [AgentActionRecord] = []

    /// Whether this meeting came from `CallDetector` noticing a call rather than from a
    /// calendar.
    ///
    /// Three rules in `MeetingScheduler` turn on it, and each is about the same missing
    /// thing — nobody agreed to this in advance and nothing knows when it ends: an armed
    /// detected call is never started by the tick, it is never written off for overrunning
    /// a schedule it does not have, and a refusal of it is not persisted as an override for
    /// a key that will never be seen again.
    var isDetectedCall: Bool { providerID == CalendarProviderID.detectedCall.rawValue }

    /// The effective source: stored value, or the M1-a back-compat read for files written
    /// before the field existed. A `Meeting · …` placeholder reads as `.auto`; anything
    /// with a calendar link reads as `.calendar`; otherwise `.user`.
    var effectiveTitleSource: MeetingTitleSource {
        if let titleSource { return titleSource }
        if Meeting.isPlaceholderTitle(title) { return .auto }
        if calendarEventID != nil { return .calendar }
        return .user
    }

    /// Whether the list renders this title dimmed/provisional.
    var isProvisionalTitle: Bool { effectiveTitleSource == .auto }

    /// `Meeting · 14:30` and its siblings — the placeholder, never a name to learn.
    static func isPlaceholderTitle(_ title: String) -> Bool {
        title.range(of: #"^Meeting · \d"#, options: .regularExpression) != nil
    }

    /// Whether this row is the same meeting as `other`, by calendar identity.
    ///
    /// The provider is part of the answer because two accounts can hand out the same
    /// opaque event id, and a shared id would read one meeting's recording as another's.
    /// A meeting with no calendar id is never the same as anything: a hand-started
    /// recording has no identity to match on.
    func isSameMeeting(as other: Meeting) -> Bool {
        guard let id = calendarEventID else { return false }
        return id == other.calendarEventID && providerID == other.providerID
    }

    /// A copy carrying the call that covers it (M-11). A value rather than a mutation
    /// because the copy is what gets written: the tick, the island and the self-test all
    /// read the row on disk, and a stamped field nothing saved is a field nothing reads.
    func withCoveringCall(_ id: String?) -> Meeting {
        var copy = self
        copy.coveringCallID = id
        return copy
    }

    /// How long the recording ran, once it has stopped.
    var duration: TimeInterval? {
        guard let end else { return nil }
        return end.timeIntervalSince(start)
    }

    var hasPartialCapture: Bool { captureIntegrity?.hasPartialCapture == true }

    /// The supported boundary can be earlier than when an interruption was noticed.
    var captureBoundary: Date? { captureIntegrity?.lastCapturedAt }

    var captureSummary: String? {
        guard hasPartialCapture else { return nil }
        if captureIntegrity?.interruptedAt != nil {
            return status == .done
                ? "Recording interrupted — saved portion recovered"
                : "Recording interrupted"
        }
        return "Some audio was missed — this meeting is incomplete"
    }

    init(
        id: UUID = UUID(),
        title: String,
        titleSource: MeetingTitleSource? = nil,
        start: Date = Date(),
        end: Date? = nil,
        calendarEventID: String? = nil,
        providerID: String? = nil,
        coveringCallID: String? = nil,
        attendees: [String] = [],
        conferenceURL: URL? = nil,
        calendarName: String? = nil,
        status: MeetingStatus = .scheduled,
        captureIntegrity: MeetingCaptureIntegrity? = nil,
        audioFileName: String? = nil,
        audioIsTemporary: Bool? = nil,
        audioReleaseAfter: Date? = nil,
        transcriptPass: String? = nil,
        notesModel: String? = nil,
        speakerNames: [String: String] = [:],
        agentActions: [AgentActionRecord] = []
    ) {
        self.id = id
        self.title = title
        self.titleSource = titleSource
        self.start = start
        self.end = end
        self.calendarEventID = calendarEventID
        self.providerID = providerID
        self.coveringCallID = coveringCallID
        self.attendees = attendees
        self.conferenceURL = conferenceURL
        self.calendarName = calendarName
        self.status = status
        self.captureIntegrity = captureIntegrity
        self.audioFileName = audioFileName
        self.audioIsTemporary = audioIsTemporary
        self.audioReleaseAfter = audioReleaseAfter
        self.transcriptPass = transcriptPass
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
        titleSource = try container.decodeIfPresent(MeetingTitleSource.self, forKey: .titleSource)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decodeIfPresent(Date.self, forKey: .end)
        calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        coveringCallID = try container.decodeIfPresent(String.self, forKey: .coveringCallID)
        attendees = try container.decodeIfPresent([String].self, forKey: .attendees) ?? []
        conferenceURL = try container.decodeIfPresent(URL.self, forKey: .conferenceURL)
        calendarName = try container.decodeIfPresent(String.self, forKey: .calendarName)
        status = try container.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .scheduled
        captureIntegrity = try container.decodeIfPresent(MeetingCaptureIntegrity.self, forKey: .captureIntegrity)
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        audioIsTemporary = try container.decodeIfPresent(Bool.self, forKey: .audioIsTemporary)
        audioReleaseAfter = try container.decodeIfPresent(Date.self, forKey: .audioReleaseAfter)
        transcriptPass = try container.decodeIfPresent(String.self, forKey: .transcriptPass)
        notesModel = try container.decodeIfPresent(String.self, forKey: .notesModel)
        speakerNames = try container.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        agentActions = try container.decodeIfPresent(
            [AgentActionRecord].self,
            forKey: .agentActions
        ) ?? []
    }
}
