import Foundation

/// The live session's coverage inputs, injected rather than reached into: the
/// evaluation is pure over `MeetingCaptureCoverage.Evidence`, and this seam is
/// only how a caller hands a real session's own facts to the pure function.
/// `@MainActor` so `MeetingSession` can conform without leaving the main actor.
@MainActor
protocol CaptureCoverageSource: AnyObject {
    var captureIntegrity: MeetingCaptureIntegrity? { get }
    /// The frame-shape drift snapshot reduced to a verdict string; nil when the
    /// build retained none. `MeetingCaptureCoverage.parseFrameShapeVerdict`
    /// decides which spellings count — anything else is neutral, never "ok".
    func frameShapeDriftVerdict() -> String?
}

/// Truthful saved-coverage evaluation for one meeting (MR-02 / MR-04).
///
/// The whole point is that a finished notes pass does not prove a whole
/// recording was saved, and that a live frame stream that is currently healthy
/// does not un-make a fact established earlier. Every function here is pure
/// over its inputs — no disk, no clock, no microphone — so the self-test can
/// drive every branch, and the session can call it from its existing health
/// tick without a new store, queue, timer or model pass.
enum MeetingCaptureCoverage {
    /// Spellings the frame-shape drift producer may report. `system-stalled`
    /// and `mic-stalled` are the two that mean a track's frame delivery stopped
    /// while the other continued; anything a future build adds and this one does
    /// not recognise is neutral, and neutral never blocks a "complete" verdict —
    /// it only cannot supply extra evidence.
    enum FrameShapeVerdict: String, Sendable, Equatable {
        case healthy
        case systemStalled
        case micStalled
        /// The track delivered about half the frames it claimed — the audit's
        /// live symptom. A loss, not a stall: the frames were there and did not
        /// arrive.
        case halfCadence
        /// Both tracks stopped: the recording as a whole has nothing more in
        /// it, which is not a per-track statement.
        case bothStalled
        case unrecognized
    }

    /// Everything one evaluation needs, built by the caller from state it
    /// already holds. Explicit fields rather than a `Meeting` + session pair:
    /// the verdict must be reproducible in the self-test without a session.
    struct Evidence: Sendable, Equatable {
        var integrity: MeetingCaptureIntegrity?
        var frameShapeVerdict: String?
        var lastMicAt: Date?
        var lastSystemAt: Date?
        var beganAt: Date
        var now: Date
        /// False only when this recording never had a system track (keep-audio
        /// off and diarization off, for example): silence or a stale system
        /// track is then expected and is not a stall or a loss.
        var expectsSystem: Bool
        /// True when the recording was *meant* to carry the other speakers —
        /// diarization or a kept recording asked for it. Separate from
        /// `expectsSystem`, which says the track is healthy: a tap that was
        /// wanted and never arrived is a loss, and a tap nobody wanted is not.
        var systemTrackRequired: Bool
        var isRecording: Bool
        /// Wall-clock seconds from `beganAt` to the natural end (Stop for a
        /// finished meeting, `now` while recording). Used only for wording
        /// that is about the meeting; 0 is safe.
        var wallDuration: TimeInterval
        /// How long the recording itself was, when the writer measured it.
        /// A boundary is a position on THIS clock, so a fraction of it has to be
        /// a fraction of this length — never of the meeting's wall span, which
        /// is a different clock and can be much longer.
        var recordedSeconds: TimeInterval?

        init(
            integrity: MeetingCaptureIntegrity? = nil,
            frameShapeVerdict: String? = nil,
            lastMicAt: Date? = nil,
            lastSystemAt: Date? = nil,
            beganAt: Date,
            now: Date,
            expectsSystem: Bool = true,
            systemTrackRequired: Bool = false,
            isRecording: Bool = false,
            wallDuration: TimeInterval = 0,
            recordedSeconds: TimeInterval? = nil
        ) {
            self.integrity = integrity
            self.frameShapeVerdict = frameShapeVerdict
            self.lastMicAt = lastMicAt
            self.lastSystemAt = lastSystemAt
            self.beganAt = beganAt
            self.now = now
            self.expectsSystem = expectsSystem
            self.systemTrackRequired = systemTrackRequired
            self.isRecording = isRecording
            self.wallDuration = wallDuration
            self.recordedSeconds = recordedSeconds
        }
    }

    /// What the saved recording is known to cover. The order of evaluation is
    /// load-bearing: a live stall outranks a partial verdict (the person needs
    /// to know now), and a sticky partial fact outranks a currently-healthy
    /// frame stream (the fact cannot be un-made by later frames arriving).
    enum Verdict: Sendable, Equatable {
        /// The recording is finished and every established fact says it covers
        /// the whole meeting. Never returned while `isRecording` is true.
        case complete
        /// Nothing is known to be missing, and nothing is known to be complete
        /// either — an old meeting with no coverage metadata, or one still
        /// recording with no loss and no stall. Never presented as "ok".
        case unknown
        /// A track's frames stopped arriving while the meeting was still
        /// recording. Distinct from `partial`: this is happening now.
        case stalled(track: AudioSource?)
        /// A fact established earlier in the meeting says part of it is not in
        /// the saved recording. `systemLostAfter` is the saved-sample boundary
        /// on the system channel when one is known (nil means "some, boundary
        /// unknown"); `track` is nil when both tracks or the delivery itself is
        /// affected; `wallDuration` is carried so `userMessage` can render a
        /// fraction without a second parameter.
        case partial(systemLostAfter: TimeInterval?, track: AudioSource?, wallDuration: TimeInterval)
    }

    /// One warning, at most once per transition into a warning state. The UI
    /// recomputes the message each tick from the current verdict, so this
    /// carries no copy of its own.
    struct Alert: Sendable, Equatable {
        var verdict: Verdict
        var message: String
        var firedAt: Date
    }

    // Frame-shape verdict spellings.
    static let frameVerdictSystemStalled = "system-stalled"
    static let frameVerdictMicStalled = "mic-stalled"
    static let frameVerdictHealthy = "aligned"

    // Plain-words copy. No jargon, no sample counts, no file names — the person
    // reading this was in a meeting, not watching a capture pipeline.
    static let unknownMessage =
        "It isn't confirmed that this whole meeting was saved, so part of it may be missing from the notes."
    static let stalledSystemMessage =
        "The other speakers' audio stopped arriving while you were still speaking, so their side may be missing from the notes."
    static let stalledBothMessage =
        "This meeting's audio stopped arriving on every track, so the recording may have stopped early."
    static let stalledMicMessage =
        "This meeting's microphone stopped responding, so the recording may have stopped early."
    static let partialGenericMessage =
        "This recording does not cover the whole meeting. The notes are still here for the part that was saved."
    static let partialSystemUnpositionedMessage =
        "Some of the other speakers' audio is missing from this recording. The notes are still here for the part that was saved."
    static let partialMicMessage =
        "Part of what you said is missing from this recording. The notes are still here for the part that was saved."

    /// The one verdict for one snapshot. Pure: every input is on `evidence`.
    static func verdict(for evidence: Evidence) -> Verdict {
        if evidence.isRecording, let stall = stalledVerdict(for: evidence) {
            return stall
        }
        if let loss = partialVerdict(for: evidence) {
            return loss
        }
        // A track delivering about half the frames it claims is the audit's
        // symptom: the audio was there and did not arrive. It is a loss, and it
        // is not the same as a stall.
        if parseFrameShapeVerdict(evidence.frameShapeVerdict) == .halfCadence {
            return .partial(systemLostAfter: nil, track: nil, wallDuration: evidence.wallDuration)
        }
        if parseFrameShapeVerdict(evidence.frameShapeVerdict) == .bothStalled {
            return .stalled(track: nil)
        }
        if evidence.systemTrackRequired, !evidence.expectsSystem {
            // The other speakers were asked for and never arrived. A recording
            // without them is not a whole-meeting recording, and saying so is
            // the difference between a complete meeting and a mic-only one.
            return .partial(systemLostAfter: nil, track: .system, wallDuration: evidence.wallDuration)
        }
        if isComplete(evidence) {
            return .complete
        }
        return .unknown
    }

    /// A live stall: the mic stopped, or the expected system track stopped while
    /// the mic continued. Silence is never a stall — buffers still arriving with
    /// zero energy are a healthy, quiet track, which is why the timestamps are
    /// the only evidence and `MeetingResourceHealth` deliberately does not
    /// silence-stall. Timestamps and the frame-shape verdict are independent
    /// paths to the same answer; either alone is enough.
    private static func stalledVerdict(for evidence: Evidence) -> Verdict? {
        let frame = parseFrameShapeVerdict(evidence.frameShapeVerdict)
        let micStale = micStaleVerdict(evidence, frame: frame)
        if micStale { return .stalled(track: .mic) }
        if evidence.expectsSystem,
           systemStale(evidence, frame: frame) {
            return .stalled(track: .system)
        }
        return nil
    }

    private static func micStaleVerdict(_ evidence: Evidence, frame: FrameShapeVerdict?) -> Bool {
        if frame == .micStalled { return true }
        let lastMic = evidence.lastMicAt ?? evidence.beganAt
        return evidence.now.timeIntervalSince(lastMic) >= MeetingResourceHealth.stallInterval
    }

    private static func systemStale(_ evidence: Evidence, frame: FrameShapeVerdict?) -> Bool {
        if frame == .systemStalled { return true }
        // Same fallback as `MeetingResourceHealth.issues`: an expected system
        // track that has never produced a frame is stale from the began-at
        // clock, not healthy by absence.
        let lastSystem = evidence.lastSystemAt ?? evidence.beganAt
        return evidence.now.timeIntervalSince(lastSystem) >= MeetingResourceHealth.stallInterval
    }

    /// A sticky fact established earlier in the meeting. Order: write failure
    /// first (it affects both tracks and no position is truthful), then the
    /// system channel (most common and the one a person can act on), then the
    /// mic, then delivery-level and interruption facts. Never consults frame
    /// timestamps — a fact does not become false because frames resumed.
    private static func partialVerdict(for evidence: Evidence) -> Verdict? {
        guard let integrity = evidence.integrity else { return nil }
        let rawBoundary = knownSystemLossBoundary(integrity, sampleRate: ChunkedTranscriber.sampleRate)
        // Clamp into the wall clock at the one place a sample index becomes a
        // person-facing number, so a clock-skewed sample can never render
        // "about 90 minutes into" a 60-minute meeting.
        // The ceiling is the recording's own length when it is known, and the
        // meeting's wall span otherwise. Clamping to the wrong one would move a
        // position that is true.
        let ceiling = evidence.recordedSeconds ?? evidence.wallDuration
        let systemBoundary = rawBoundary.map { boundary -> TimeInterval in
            let nonNegative = max(0, boundary)
            guard ceiling > 0 else { return nonNegative }
            return min(nonNegative, ceiling)
        }
        // A delivery stall is not a saved loss: the frames that arrived are
        // all in the file, and the sentence "stopped saving" would be false.
        let systemLost = systemBoundary != nil
            || integrity.missingSavedSystemFrames ?? 0 > 0
            || (integrity.coverageWarnings?.contains(where: {
                $0.track == .system && $0.kind.isSavedLoss
            }) ?? false)
        let micLost = integrity.missingSavedMicFrames ?? 0 > 0
            || (integrity.coverageWarnings?.contains(where: {
                $0.track == .mic && $0.kind.isSavedLoss
            }) ?? false)
        let deliveryLost = integrity.captureGap || integrity.missingCaptureFrames > 0
        let interrupted = integrity.interruptedAt != nil

        if integrity.audioWriteFailed {
            return .partial(systemLostAfter: systemBoundary, track: nil, wallDuration: evidence.wallDuration)
        }
        if systemLost && micLost {
            return .partial(systemLostAfter: systemBoundary, track: nil, wallDuration: evidence.wallDuration)
        }
        if systemLost {
            return .partial(systemLostAfter: systemBoundary, track: .system, wallDuration: evidence.wallDuration)
        }
        if micLost {
            return .partial(systemLostAfter: nil, track: .mic, wallDuration: evidence.wallDuration)
        }
        if deliveryLost || interrupted {
            return .partial(systemLostAfter: nil, track: nil, wallDuration: evidence.wallDuration)
        }
        return nil
    }

    /// The system-loss boundary in wall-clock seconds, from the earliest known
    /// of: the writer's silence boundary, and any system warning's sample
    /// index. Raw: `partialVerdict` clamps it into the meeting's wall clock
    /// before it becomes a payload or a person-facing position.
    static func knownSystemLossBoundary(
        _ integrity: MeetingCaptureIntegrity,
        sampleRate: Double
    ) -> TimeInterval? {
        // The same number the diarizer and the notes read.
        guard sampleRate > 0,
              let seconds = DiarizationEligibility.boundarySeconds(integrity, source: .system)
        else { return nil }
        return seconds
    }

    /// Finished, every established fact says whole-meeting coverage, the frame
    /// stream agrees, and the producer stopped within one stall interval of the
    /// normal end. A recording that ended while its expected system track was
    /// stalled can never be complete, even if the sticky fact has not been
    /// persisted yet.
    static func isComplete(_ evidence: Evidence) -> Bool {
        guard !evidence.isRecording,
              let integrity = evidence.integrity,
              integrity.savedCoverageMeasured == true,
              !integrity.hasPartialCapture,
              let normalEnd = integrity.normalEndAt,
              let lastCaptured = integrity.lastCapturedAt
        else { return false }
        guard normalEnd.timeIntervalSince(lastCaptured) <= MeetingResourceHealth.stallInterval else {
            return false
        }
        if evidence.expectsSystem,
           parseFrameShapeVerdict(evidence.frameShapeVerdict) == .systemStalled {
            return false
        }
        if parseFrameShapeVerdict(evidence.frameShapeVerdict) == .micStalled {
            return false
        }
        if parseFrameShapeVerdict(evidence.frameShapeVerdict) == .halfCadence {
            return false
        }
        return true
    }

    /// Reads a frame-shape drift string down to the closed verdict set.
    /// Stall matching needs both the track word and a stop word, and a negated
    /// stop ("did not stall", "not stopped") is not a stall — a sentence like
    /// "system track did not stall" must not read as one. Healthy matching is
    /// an explicit token list. Anything else is `.unrecognized`, which is
    /// neutral — it never means "ok" and never blocks `complete`.
    static func parseFrameShapeVerdict(_ raw: String?) -> FrameShapeVerdict? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let text = raw.lowercased()
        let hasMic = text.contains("mic") || text.contains("microphone")
        let hasSystem = text.contains("system")
        let stopWords = ["stall", "stopped", "stop ", "died", "dead", "frozen", "halted"]
        let isStop = stopWords.contains { text.contains($0) }
        let isNegated = text.contains("did not stall") || text.contains("did not stop")
            || text.contains("not stalled") || text.contains("not stopped")
            || text.contains("no stall") || text.contains("never stall")
            || text.contains("never stopped") || text.contains("did not freeze")
            || text.contains("never froze")
        if !isNegated, hasMic, !hasSystem, isStop { return .micStalled }
        if !isNegated, hasSystem, !hasMic, isStop { return .systemStalled }
        if !isNegated, hasMic, hasSystem, isStop, text.contains("both") { return .bothStalled }
        // A stop word with no single track named is still not healthy: a string
        // that says one track stopped and the other is fine is a stall, and a
        // string that names both is ambiguous — which is not the same as ok.
        if !isNegated, isStop { return .unrecognized }
        if text.contains("half cadence") || text.contains("half-cadence")
            || text.contains("halfcadence") {
            return .halfCadence
        }
        let healthyTokens = [frameVerdictHealthy, "healthy", "no drift", "none"]
        if healthyTokens.contains(where: { text.contains($0) }) { return .healthy }
        return .unrecognized
    }

    /// Fires at most once per transition into a warning state. `previous` is
    /// the last verdict the caller showed (or `.unknown` at the start of the
    /// meeting). Equal ranks suppress re-fires, which is what stops a
    /// partial ↔ stalled oscillation from spraying the person with cards while
    /// the sticky fact keeps the verdict at partial either way. `.complete` and
    /// `.unknown` are rank 0 and never produce an alert — "we don't know" is
    /// not an interruption, and a completed meeting's card comes from the
    /// pipeline, not from here.
    static func shouldWarn(
        previous: Verdict,
        current: Verdict,
        now: Date
    ) -> Alert? {
        guard warningRank(current) > warningRank(previous) else { return nil }
        guard let message = current.userMessage else { return nil }
        return Alert(verdict: current, message: message, firedAt: now)
    }

    private static func warningRank(_ verdict: Verdict) -> Int {
        switch verdict {
        // A stall outranks a partial: the person needs to know now. Equal
        // ranks are what make a repeated state quiet, so the two must differ.
        case .stalled: return 2
        case .partial: return 1
        case .complete, .unknown: return 0
        }
    }

    /// Builds the evidence a real caller already has, deriving `wallDuration`
    /// once so no call site re-implements the recording-vs-finished rule.
    @MainActor
    static func evidence(
        from source: CaptureCoverageSource,
        startedAt: Date,
        now: Date,
        lastMicAt: Date?,
        lastSystemAt: Date?,
        expectsSystem: Bool,
        systemTrackRequired: Bool = false,
        isRecording: Bool,
        recordedSeconds: TimeInterval? = nil
    ) -> Evidence {
        let integrity = source.captureIntegrity
        let wallEnd = isRecording ? now : (integrity?.normalEndAt ?? now)
        return Evidence(
            integrity: integrity,
            frameShapeVerdict: source.frameShapeDriftVerdict(),
            lastMicAt: lastMicAt,
            lastSystemAt: lastSystemAt,
            beganAt: startedAt,
            now: now,
            expectsSystem: expectsSystem,
            systemTrackRequired: systemTrackRequired,
            isRecording: isRecording,
            wallDuration: max(0, wallEnd.timeIntervalSince(startedAt)),
            recordedSeconds: recordedSeconds
        )
    }

    // Internal rather than private: `Verdict.userMessage` lives in an extension
    // on the nested type, which is outside this declaration's private scope.
    static func partialSystemMessage(after boundary: TimeInterval, wallDuration: TimeInterval) -> String {
        "The other speakers' audio stopped saving \(positionWords(after: boundary, wallDuration: wallDuration)). "
            + "The notes are still here for the part that was saved."
    }

    /// The position, in the recording's own clock.
    ///
    /// The boundary is a position in the saved recording and the wall clock is
    /// the meeting's real length; when they disagree — which is exactly what
    /// the audit measured — a fraction of one cannot be a fraction of the
    /// other. So the position is stated in minutes, and the halfway wording is
    /// only used when the two clocks agree closely enough for it to be true.
    private static func positionWords(after boundary: TimeInterval, wallDuration: TimeInterval) -> String {
        let clamped = max(0, boundary)
        // A boundary of zero is a channel that never carried anything: saying
        // "in the first minute" would imply a moment of audio was saved.
        if clamped == 0 { return "from the start of this meeting" }
        // The fraction is of the RECORDING, and the "halfway" wording is only
        // used when the two clocks agree closely enough for it to be true: a
        // recording whose clock ran at half the wall clock would otherwise be
        // described as halfway through a meeting it barely reached.
        let recording = wallDuration
        if recording > 0 {
            let fraction = clamped / recording
            if abs(fraction - 0.5) <= 0.05 {
                return "about halfway through this recording"
            }
            if fraction > 0.9 {
                return "near the end of this recording"
            }
        }
        if clamped < 60 { return "in the first minute of this recording" }
        return "about \(minutesWord(clamped)) into this recording"
    }

    private static func minutesWord(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

extension MeetingCaptureCoverage.Verdict {
    /// The person-facing sentence for this verdict, or nil when there is
    /// nothing worth interrupting them about (`.complete`).
    var userMessage: String? {
        switch self {
        case .complete:
            return nil
        case .unknown:
            return MeetingCaptureCoverage.unknownMessage
        case .stalled(let track):
            if track == nil { return MeetingCaptureCoverage.stalledBothMessage }
            return track == .system
                ? MeetingCaptureCoverage.stalledSystemMessage
                : MeetingCaptureCoverage.stalledMicMessage
        case .partial(let boundary, let track, let wallDuration):
            if track == .system {
                if let boundary {
                    return MeetingCaptureCoverage.partialSystemMessage(
                        after: boundary, wallDuration: wallDuration)
                }
                return MeetingCaptureCoverage.partialSystemUnpositionedMessage
            }
            if track == .mic { return MeetingCaptureCoverage.partialMicMessage }
            return MeetingCaptureCoverage.partialGenericMessage
        }
    }
}
