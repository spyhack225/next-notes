import Foundation

/// What the notes input could not cover, decided once from the transcript snapshot and
/// the meeting's own capture facts, and disclosed in plain words above the document.
///
/// Pure, and free of store, clock and I/O, so `NotesService` and `--selftest-notes-coverage`
/// decide the same way.
///
/// Three rules keep it honest, and each one came from a way this first version could
/// have lied:
///
/// 1. **The notes' own input decides, per track.** A meeting whose system track fell
///    back to the live tier — because the recording was known to be short on it —
///    has notes for that track that came from a short source, whatever the pass is
///    called. A pass name cannot say that: one short track and one good one are
///    both "live-only:rejected".
/// 2. **No boundary is invented.** The position of a loss comes from the producer
///    that measured it — the writer knows the frame from which a channel carried
///    only the silence it had to invent — and never from a frame count turned into
///    a position by arithmetic the producer did not do.
/// 3. **A quiet ending is not a loss, and a ratio is not a measurement.** The
///    transcript ending before the recording does is normal: people stop talking
///    and the recording continues. Nothing is claimed about the conversation's
///    completeness without a producer fact behind it.
enum NotesCoverageDisclosure {
    /// The limitation that is true of this meeting's notes input, with the sentence the
    /// page carries. One case per limit, so the wording cannot drift away from the fact
    /// it describes.
    enum Disclosure: Equatable, Sendable {
        /// The input covered the meeting as saved. The prefix is empty, so an ordinary
        /// meeting's notes are byte-identical to a meeting that never froze one.
        case none
        /// The other speakers' content in these notes came from a source that was
        /// short, so what they said after the boundary may be missing.
        case systemAudioPartial(savedThroughSeconds: TimeInterval?)
        /// The person's own content in these notes came from a source that was short.
        case micAudioPartial
        /// Both tracks came from a source that was short.
        case both
        /// The recording stopped saving partway through, so the notes cannot vouch
        /// for the later part of the call.
        case recordingIncomplete(fromLiveTranscript: Bool)
        /// A producer measured that a track stopped being delivered, so later
        /// discussion may be missing.
        case timestampsUncertain(lastKnownSeconds: TimeInterval)

        /// Stable machine word for the metrics row and the log — never the sentence.
        var kind: String {
            switch self {
            case .none: "none"
            case .systemAudioPartial: "systemAudioPartial"
            case .micAudioPartial: "micAudioPartial"
            case .both: "both"
            case .recordingIncomplete: "recordingIncomplete"
            case .timestampsUncertain: "timestampsUncertain"
            }
        }

        /// One plain-words paragraph, placed above the model's document. Empty for
        /// `.none`, which is what makes an intact meeting unchanged.
        var markdownPrefix: String {
            switch self {
            case .none:
                ""
            case .systemAudioPartial:
                "Note: the other speakers' audio stopped being saved partway through this "
                    + "meeting, so what they said after that may be missing from these notes."
            case .micAudioPartial:
                "Note: your microphone audio stopped being saved partway through this "
                    + "meeting, so what you said after that may be missing from these notes."
            case .both:
                "Note: this meeting's audio stopped being saved partway through, so later "
                    + "discussion may be missing from these notes."
            case .recordingIncomplete(let fromLiveTranscript):
                fromLiveTranscript
                    ? "Note: this meeting's recording stopped saving partway through. These "
                        + "notes come from the live transcript, so they may still cover the call."
                    : "Note: this meeting's audio stopped being saved partway through, so later "
                        + "discussion may be missing from these notes."
            case .timestampsUncertain:
                "Note: some later parts of this conversation may be missing from these notes."
            }
        }

        /// Whether the map step has to warn the model that the segment order may not be
        /// complete. Only this case earns that warning: a known audio loss already
        /// discloses itself in words, and an intact clock is one the model can trust.
        var uncertainChronology: Bool {
            if case .timestampsUncertain = self { return true }
            return false
        }
    }

    /// The facts the decision reads, as plain values so the whole rule is one pure
    /// function of what the producer already measured.
    struct Input: Equatable, Sendable {
        /// The pass the notes were written from. The pass that read the saved file
        /// is the one whose input can be short because the file is short.
        var transcriptPass: String?
        /// The tracks whose content in the saved transcript came from the live tier
        /// rather than from the recording, because the recording was short on them.
        var rejectedTracks: [AudioSource] = []
        /// A track's audio reached the recording only up to this second. Nil when the
        /// producer measured no boundary, which is "unknown", never "the whole thing".
        /// The recording stopped saving partway through.
        var recordingWriteFailed = false
        /// The recording is known to be short on a track, but the producer
        /// measured no position for the loss.
        var systemAudioShortWithoutPosition = false
        var micAudioShortWithoutPosition = false
        var systemAudioSavedThroughSeconds: TimeInterval?
        var micAudioSavedThroughSeconds: TimeInterval?
        /// A track stopped being delivered while the meeting was recording.
        var systemDeliveryStopped = false
        var micDeliveryStopped = false
    }

    /// The pass whose input is the saved recording. Notes written from any other pass
    /// read the live transcript, which is complete as far as it went.
    static let savedFilePass = "long-window"

    /// Decide what the notes input could not cover.
    ///
    /// A track that fell back to the live tier is short for these notes whenever
    /// the producer measured that the recording was short on it — that is the
    /// audit's case exactly: the other speakers' audio was saved for the first
    /// moments of the call and the rest of the notes came from the live tier.
    static func classify(_ input: Input) -> Disclosure {
        // A recording that stopped saving is its own answer, and it is decided
        // first: the notes' own input decides whether that means the notes are
        // short or that they came from the live transcript instead.
        if input.recordingWriteFailed {
            return .recordingIncomplete(
                fromLiveTranscript: input.transcriptPass != savedFilePass)
        }
        let systemShort = trackIsShort(.system, input)
        let micShort = trackIsShort(.mic, input)
        if systemShort, micShort { return .both }
        if systemShort {
            // A track whose content came from the live tier is short for these
            // notes whenever the recording was short on it — the pass name
            // cannot say that, and the rejected-track list is what says it.
            return .systemAudioPartial(savedThroughSeconds: input.systemAudioSavedThroughSeconds)
        }
        if micShort { return .micAudioPartial }
        // A known loss with no position is still a loss: the sentence says the
        // audio is missing without pretending to know where.
        if input.systemAudioShortWithoutPosition || input.micAudioShortWithoutPosition {
            return .systemAudioPartial(savedThroughSeconds: nil)
        }
        if input.rejectedTracks.contains(.system), isShort(.system, input) {
            return .systemAudioPartial(savedThroughSeconds: input.systemAudioSavedThroughSeconds)
        }
        // A delivery that stopped is a producer fact, and it is the only thing
        // that may claim the conversation is incomplete without a measured
        // boundary.
        if input.systemDeliveryStopped || input.micDeliveryStopped {
            let last = input.systemAudioSavedThroughSeconds ?? input.micAudioSavedThroughSeconds
            return .timestampsUncertain(lastKnownSeconds: last ?? 0)
        }
        return .none
    }

    /// Whether a track's content in these notes came from a short source.
    ///
    /// A measured boundary means the recording is short on the track, whichever
    /// source the notes took that track's content from. Without one, a track
    /// that fell back to the live tier is only short when the recording itself
    /// failed: a fallback on a healthy recording is a fallback, not a loss.
    private static func trackIsShort(_ source: AudioSource, _ input: Input) -> Bool {
        let boundary = source == .system
            ? input.systemAudioSavedThroughSeconds
            : input.micAudioSavedThroughSeconds
        // Only a measured boundary makes a track short. A track that fell back
        // to the live tier on a healthy recording is a fallback, not a loss, and
        // calling it one would put a false warning on a good meeting's notes.
        return boundary != nil
    }

    /// Whether the recording is known to be short on a track, with or without a
    /// measured position.
    private static func isShort(_ source: AudioSource, _ input: Input) -> Bool {
        if trackIsShort(source, input) { return true }
        return source == .system
            ? input.systemAudioShortWithoutPosition
            : input.micAudioShortWithoutPosition
    }

    /// The disclosure, and the input facts it was decided from, captured once.
    ///
    /// Held in the notes result rather than on disk: `notes.md` is the model's
    /// document, `notes.json` belongs to the extractor, and `meeting.json`'s notes
    /// fields are read by the pipeline. The pass that produced the notes stamps
    /// the disclosure's machine word into the meeting's existing metrics row, so
    /// the decision is traceable; the frozen counts themselves live only as long
    /// as the pass that measured them.
    struct Frozen: Equatable, Sendable {
        let disclosure: Disclosure
        /// Segment count, first and last timestamps, and the distinct speaker names the
        /// transcript carried at the freeze. A later diarization pass rewrites the
        /// speaker names, and notes already written must still be measurable against the
        /// input they actually came from.
        let segmentCount: Int
        let firstSegmentTimestamp: TimeInterval?
        let lastSegmentTimestamp: TimeInterval?
        let speakerNameCount: Int
    }

    /// Decide once, from the same transcript snapshot the notes are generated from, so a
    /// meeting whose speakers are identified minutes later cannot change what the page
    /// already said about its own coverage.
    static func freeze(meeting: Meeting, segments: [TranscriptSegment]) -> Frozen {
        let integrity = meeting.captureIntegrity
        let disclosure = classify(Input(
            transcriptPass: meeting.transcriptPass,
            rejectedTracks: meeting.transcriptRejectedTracks ?? [],
            recordingWriteFailed: integrity?.audioWriteFailed ?? false,
            systemAudioShortWithoutPosition: (integrity?.hasKnownSavedAudioLoss(on: .system) ?? false)
                && savedThroughSeconds(integrity) == nil,
            micAudioShortWithoutPosition: (integrity?.hasKnownSavedAudioLoss(on: .mic) ?? false)
                && micSavedThroughSeconds(integrity) == nil,
            systemAudioSavedThroughSeconds: savedThroughSeconds(integrity),
            micAudioSavedThroughSeconds: micSavedThroughSeconds(integrity),
            systemDeliveryStopped: integrity?.hasKnownDeliveryLoss(on: .system) ?? false,
            micDeliveryStopped: integrity?.hasKnownDeliveryLoss(on: .mic) ?? false))
        return Frozen(
            disclosure: disclosure,
            segmentCount: segments.count,
            firstSegmentTimestamp: segments.map(\.start).min(),
            lastSegmentTimestamp: segments.map(\.end).max(),
            speakerNameCount: meeting.speakerNames.count
        )
    }

    /// The boundary the writer measured: the frame from which the system channel
    /// carried nothing but the silence the writer had to invent, because that track
    /// had nothing left to save. A position on the recording's own clock, and nil
    /// when the writer measured none — which is "unknown", never "the whole call".
    private static func savedThroughSeconds(_ integrity: MeetingCaptureIntegrity?) -> TimeInterval? {
        // The one reader of the boundary: the coverage evaluator and the
        // diarizer read the same number, and this is it.
        guard let seconds = DiarizationEligibility.boundarySeconds(
            integrity, source: .system), ChunkedTranscriber.sampleRate > 0 else { return nil }
        return seconds
    }

    /// The same boundary for the microphone track.
    private static func micSavedThroughSeconds(_ integrity: MeetingCaptureIntegrity?) -> TimeInterval? {
        guard let seconds = DiarizationEligibility.boundarySeconds(
            integrity, source: .mic), ChunkedTranscriber.sampleRate > 0 else { return nil }
        return seconds
    }
}
