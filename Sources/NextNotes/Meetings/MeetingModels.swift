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

/// A coverage fact that was true at least once for this meeting, persisted so a
/// later-arriving frame stream can never present itself as whole-meeting saved
/// coverage. The kinds are a closed set on purpose: a future build writes rows
/// today's binaries must keep reading, and an unknown kind is skipped by the
/// decoder rather than failing the meeting.
enum MeetingCoverageWarningKind: String, Codable, Sendable {
    /// The system channel is zero from this saved sample onward; the other
    /// speakers are not in the recording after it.
    case systemSilent
    /// Delivered system samples fell behind the saved-file cursor.
    case systemTrimmed
    case micTrimmed
    /// Frame delivery on the system track stopped while the microphone continued.
    case systemStalled
    /// Frame delivery on the microphone stopped while the other track continued.
    case micStalled

    /// The kind describes a saved file that is short on this track.
    var isSavedLoss: Bool {
        switch self {
        case .systemSilent, .systemTrimmed, .micTrimmed: true
        case .systemStalled, .micStalled: false
        }
    }

    /// The kind describes frames that never arrived.
    var isDeliveryLoss: Bool {
        self == .systemStalled || self == .micStalled
    }
}

/// One persisted coverage warning: which track, what happened, and the
/// saved-sample index on the recording clock where it began — a boundary,
/// never a count.
struct MeetingCaptureCoverageWarning: Codable, Sendable, Equatable {
    var track: AudioSource
    var kind: MeetingCoverageWarningKind
    var atSample: Int64
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
    /// The saved-sample index after which the system channel is known silent,
    /// from writer evidence. Optional: rows written before the measurement and
    /// meetings whose writer reported no silence stay nil — "unknown", never "ok".
    var systemSilentAfterSample: Int64?
    /// Persisted coverage warnings. Decoded element by element: an entry whose
    /// kind this build does not know is skipped, and a malformed entry never
    /// fails the surrounding meeting.
    var coverageWarnings: [MeetingCaptureCoverageWarning]?
    /// How long the recording actually was, in seconds, from the frames the
    /// writer saved.
    ///
    /// The calendar's span is not this: an armed meeting's end is the time the
    /// calendar said, and a meeting that was recorded for ten minutes of a
    /// thirty-minute slot is ten minutes long. A fraction of a loss has to be a
    /// fraction of the thing that was recorded.
    var recordedSeconds: Double?
    /// Whether the saved-coverage measurement ran at all for this recording.
    /// Nil means it never ran — which is "unknown", never "complete". A row
    /// written before this measurement existed stays nil, and reads as unknown
    /// rather than as a whole-meeting recording.
    var savedCoverageMeasured: Bool?

    /// Memberwise initializer kept by hand (defining `init(from:)` suppresses
    /// the synthesized one) so every existing `MeetingCaptureIntegrity(...)`
    /// call site keeps compiling, and new fields arrive with defaults.
    init(
        lastCapturedAt: Date? = nil,
        normalEndAt: Date? = nil,
        interruptedAt: Date? = nil,
        interruptionReason: MeetingCaptureInterruptionReason? = nil,
        captureGap: Bool = false,
        missingCaptureFrames: Int64 = 0,
        audioWriteFailed: Bool = false,
        missingSavedMicFrames: Int64? = nil,
        missingSavedSystemFrames: Int64? = nil,
        systemSilentAfterSample: Int64? = nil,
        coverageWarnings: [MeetingCaptureCoverageWarning]? = nil,
        savedCoverageMeasured: Bool? = nil,
        recordedSeconds: Double? = nil
    ) {
        self.lastCapturedAt = lastCapturedAt
        self.normalEndAt = normalEndAt
        self.interruptedAt = interruptedAt
        self.interruptionReason = interruptionReason
        self.captureGap = captureGap
        self.missingCaptureFrames = missingCaptureFrames
        self.audioWriteFailed = audioWriteFailed
        self.missingSavedMicFrames = missingSavedMicFrames
        self.missingSavedSystemFrames = missingSavedSystemFrames
        self.systemSilentAfterSample = systemSilentAfterSample
        self.coverageWarnings = coverageWarnings
        self.savedCoverageMeasured = savedCoverageMeasured
        self.recordedSeconds = recordedSeconds
    }

    /// Decoded by hand for one reason: a synthesized `init(from:)` would fail the
    /// whole meeting on one coverage-warning entry a future build wrote with a
    /// kind this one does not know. Every field is `decodeIfPresent`, so a row
    /// written before any of them existed still decodes — an old meeting that
    /// fails to decode is a meeting that has silently vanished from the list.
    init(from decoder: any Decoder) throws {
        struct RawWarning: Decodable {
            var track: String?
            var kind: String?
            var atSample: Int64?
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCapturedAt = try container.decodeIfPresent(Date.self, forKey: .lastCapturedAt)
        normalEndAt = try container.decodeIfPresent(Date.self, forKey: .normalEndAt)
        interruptedAt = try container.decodeIfPresent(Date.self, forKey: .interruptedAt)
        interruptionReason = try container.decodeIfPresent(
            MeetingCaptureInterruptionReason.self, forKey: .interruptionReason)
        captureGap = try container.decodeIfPresent(Bool.self, forKey: .captureGap) ?? false
        missingCaptureFrames = try container.decodeIfPresent(
            Int64.self, forKey: .missingCaptureFrames) ?? 0
        audioWriteFailed = try container.decodeIfPresent(Bool.self, forKey: .audioWriteFailed) ?? false
        missingSavedMicFrames = try container.decodeIfPresent(Int64.self, forKey: .missingSavedMicFrames)
        missingSavedSystemFrames = try container.decodeIfPresent(Int64.self, forKey: .missingSavedSystemFrames)
        systemSilentAfterSample = try container.decodeIfPresent(Int64.self, forKey: .systemSilentAfterSample)
        if let raw = try? container.decode([RawWarning?].self, forKey: .coverageWarnings) {
            let mapped = raw.compactMap { entry -> MeetingCaptureCoverageWarning? in
                guard let entry,
                      let track = entry.track.flatMap(AudioSource.init(rawValue:)),
                      let kind = entry.kind.flatMap(MeetingCoverageWarningKind.init(rawValue:)),
                      let atSample = entry.atSample
                else { return nil }
                return MeetingCaptureCoverageWarning(track: track, kind: kind, atSample: atSample)
            }
            coverageWarnings = mapped.isEmpty ? nil : mapped
        } else {
            coverageWarnings = nil
        }
        savedCoverageMeasured = try container.decodeIfPresent(Bool.self, forKey: .savedCoverageMeasured)
        recordedSeconds = try container.decodeIfPresent(Double.self, forKey: .recordedSeconds)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastCapturedAt, forKey: .lastCapturedAt)
        try container.encodeIfPresent(normalEndAt, forKey: .normalEndAt)
        try container.encodeIfPresent(interruptedAt, forKey: .interruptedAt)
        try container.encodeIfPresent(interruptionReason, forKey: .interruptionReason)
        try container.encode(captureGap, forKey: .captureGap)
        try container.encode(missingCaptureFrames, forKey: .missingCaptureFrames)
        try container.encode(audioWriteFailed, forKey: .audioWriteFailed)
        try container.encodeIfPresent(missingSavedMicFrames, forKey: .missingSavedMicFrames)
        try container.encodeIfPresent(missingSavedSystemFrames, forKey: .missingSavedSystemFrames)
        try container.encodeIfPresent(systemSilentAfterSample, forKey: .systemSilentAfterSample)
        try container.encodeIfPresent(coverageWarnings, forKey: .coverageWarnings)
        try container.encodeIfPresent(savedCoverageMeasured, forKey: .savedCoverageMeasured)
        try container.encodeIfPresent(recordedSeconds, forKey: .recordedSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case lastCapturedAt, normalEndAt, interruptedAt, interruptionReason
        case captureGap, missingCaptureFrames, audioWriteFailed
        case missingSavedMicFrames, missingSavedSystemFrames
        case systemSilentAfterSample, coverageWarnings, savedCoverageMeasured, recordedSeconds
    }

    /// The saved file is known to be short on this track.
    ///
    /// A delivery warning — a track that stopped delivering — is not this: the
    /// frames that did arrive are all in the file. Mixing the two would make
    /// the final pass skip a good track and the diarizer refuse a track whose
    /// audio is fine.
    func hasKnownSavedAudioLoss(on source: AudioSource) -> Bool {
        audioWriteFailed || (source == .mic ? missingSavedMicFrames ?? 0
            : missingSavedSystemFrames ?? 0) > 0
            || (source == .system && systemSilentAfterSample != nil)
            || (coverageWarnings?.contains {
                $0.track == source && $0.kind.isSavedLoss
            } ?? false)
    }

    /// The track is known to have stopped delivering, whether or not the file
    /// is short. A delivery fact, never a saved-audio fact.
    func hasKnownDeliveryLoss(on source: AudioSource) -> Bool {
        coverageWarnings?.contains {
            $0.track == source && $0.kind.isDeliveryLoss
        } ?? false
    }

    var hasPartialCapture: Bool {
        interruptedAt != nil || captureGap || missingCaptureFrames > 0 || audioWriteFailed
            || (missingSavedMicFrames ?? 0) > 0 || (missingSavedSystemFrames ?? 0) > 0
            || systemSilentAfterSample != nil
            || (coverageWarnings?.isEmpty == false)
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

    /// Records what the writer measured about the saved file.
    ///
    /// One implementation, read by the session and by the self-test alike: the
    /// mapping from a writer's counters to a meeting's durable facts is the
    /// part that must not drift, and a second copy of it in a test would prove
    /// nothing about the first.
    mutating func recordSavedCoverage(_ saved: MeetingAudioWriter.ResourceSnapshot) {
        savedCoverageMeasured = true
        // Both counts are set every time, zero included: "measured, nothing
        // lost" is a fact, and a missing value is "never measured", which is a
        // different answer.
        missingSavedMicFrames = max(missingSavedMicFrames ?? 0,
            Int64(saved.missingSavedMicFrames))
        missingSavedSystemFrames = max(missingSavedSystemFrames ?? 0,
            Int64(saved.missingSavedSystemFrames))
        // The boundary the writer measured: the frame from which a channel
        // carries only the silence the writer had to invent, because that track
        // had nothing left to save. A position on the recording clock, not a
        // count — and the fact the notes disclosure reads.
        //
        // A boundary of ZERO is a channel that never carried real audio at all.
        // That is not a loss on its own: a microphone-only meeting is a normal
        // configuration, and a meeting whose other speakers never arrived is the
        // coverage verdict's business, not this counter's. Only a boundary the
        // track passed — audio that stopped — is a saved loss.
        if let silent = saved.systemSilentAfterSample, silent > 0 {
            systemSilentAfterSample = systemSilentAfterSample.map { min($0, silent) } ?? silent
            addCoverageWarning(
                MeetingCaptureCoverageWarning(
                    track: .system, kind: .systemSilent, atSample: silent))
        }
        if let silent = saved.micSilentAfterSample, silent > 0 {
            addCoverageWarning(
                MeetingCaptureCoverageWarning(
                    track: .mic, kind: .micTrimmed, atSample: silent))
        }
    }

    /// Records a coverage warning once.
    ///
    /// Sticky by construction: the same warning at the same boundary is not
    /// recorded twice, and a later reading of the same fact at a later boundary
    /// does not replace the earlier one — the earliest boundary is the one that
    /// says where the loss began.
    mutating func addCoverageWarning(_ warning: MeetingCaptureCoverageWarning) {
        var existing = coverageWarnings ?? []
        if existing.contains(where: {
            $0.track == warning.track && $0.kind == warning.kind && $0.atSample == warning.atSample
        }) {
            coverageWarnings = existing
            return
        }
        existing.append(warning)
        // Bounded: a meeting has two tracks and a closed set of kinds, so a
        // list longer than that is a fact that has already been recorded.
        if existing.count > 8 { existing.removeLast(existing.count - 8) }
        coverageWarnings = existing.sorted {
            $0.atSample == $1.atSample
                ? $0.track.rawValue < $1.track.rawValue
                : $0.atSample < $1.atSample
        }
    }

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
        // Sticky coverage facts: silence is a boundary, so the earliest known one
        // is the truthful one, and warnings union so a later empty snapshot can
        // never erase a fact an earlier one established.
        if let storedSilent = stored.systemSilentAfterSample {
            result.systemSilentAfterSample = min(result.systemSilentAfterSample ?? storedSilent, storedSilent)
        }
        result.coverageWarnings = Self.mergedWarnings(stored.coverageWarnings, coverageWarnings)
        // The measurement flag is a fact like the others: a save whose copy
        // lacks it must not erase the fact that the coverage was measured, or a
        // healthy meeting starts reading as unconfirmed.
        if stored.savedCoverageMeasured == true { result.savedCoverageMeasured = true }
        if let storedSeconds = stored.recordedSeconds {
            result.recordedSeconds = max(result.recordedSeconds ?? 0, storedSeconds)
        }
        return result
    }

    /// Union of both warning lists keyed by `(track, kind)`, keeping the earliest
    /// `atSample`; nil when neither side carries any. The key set is closed
    /// (2 tracks × 4 kinds), so the result is bounded without a separate guard.
    private static func mergedWarnings(
        _ first: [MeetingCaptureCoverageWarning]?,
        _ second: [MeetingCaptureCoverageWarning]?
    ) -> [MeetingCaptureCoverageWarning]? {
        guard !(first ?? []).isEmpty || !(second ?? []).isEmpty else { return nil }
        var earliest: [MeetingCaptureCoverageWarning] = []
        for warning in (first ?? []) + (second ?? []) {
            if let index = earliest.firstIndex(where: { $0.track == warning.track && $0.kind == warning.kind }) {
                if warning.atSample < earliest[index].atSample { earliest[index] = warning }
            } else {
                earliest.append(warning)
            }
        }
        return earliest.isEmpty ? nil : earliest
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
    /// The tracks whose content in the saved transcript came from the live tier
    /// rather than from the recording, because the recording was known to be
    /// short on them.
    ///
    /// The pass name alone cannot say this: a meeting with one short track and
    /// one good one is "live-only:rejected", and the notes for the short track
    /// came from the live tier — which is exactly the case the coverage
    /// disclosure exists for.
    var transcriptRejectedTracks: [AudioSource]?
    /// Which model wrote the notes, once Phase 4 writes any.
    var notesModel: String?
    /// Bounded recording observations survive the global metrics ring aging out.
    /// Nil means this build did not retain coverage; it never implies healthy capture.
    var performanceSummary: MeetingPerformanceSummary?
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
            guard status == .done else { return "Recording interrupted" }
            return notesModel != nil
                ? "Recording interrupted — partial notes recovered"
                : "Recording interrupted — saved portion recovered"
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
        transcriptRejectedTracks: [AudioSource]? = nil,
        notesModel: String? = nil,
        performanceSummary: MeetingPerformanceSummary? = nil,
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
        self.transcriptRejectedTracks = transcriptRejectedTracks
        self.notesModel = notesModel
        self.performanceSummary = performanceSummary
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
        transcriptRejectedTracks = try container.decodeIfPresent(
            [AudioSource].self, forKey: .transcriptRejectedTracks)
        notesModel = try container.decodeIfPresent(String.self, forKey: .notesModel)
        performanceSummary = try container.decodeIfPresent(MeetingPerformanceSummary.self, forKey: .performanceSummary)
        speakerNames = try container.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        agentActions = try container.decodeIfPresent(
            [AgentActionRecord].self,
            forKey: .agentActions
        ) ?? []
    }
}
