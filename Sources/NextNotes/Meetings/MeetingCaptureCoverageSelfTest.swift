import Foundation

/// `--selftest-meeting-capture-coverage`: truthful saved-coverage verdicts,
/// warning hysteresis, sticky facts, and old-meeting decode (MR-02 / MR-04).
///
/// Pure: strings and in-memory values only — no disk, no model, no microphone,
/// no session. The old-format decode cases carry literal `meeting.json` text so
/// they fail if a future field stops decoding what is already on the owner's
/// disk; an old meeting that fails to decode is a meeting that has silently
/// vanished from the list.
@MainActor
enum MeetingCaptureCoverageSelfTest {
    static func run(log: (String) -> Void) async -> Bool {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition {
                failures += 1
                log("COVERAGE_WRONG: \(label)")
            }
        }
        func note(_ name: String, _ verdict: MeetingCaptureCoverage.Verdict) {
            log("COVERAGE_CASE \(name) verdict=\(describe(verdict))")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        // MARK: Case 1 — an old meeting.json with no coverage metadata decodes.

        let noIntegrityJSON = """
        {"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","title":"Weekly sync","start":"2026-09-10T10:00:00Z"}
        """
        let meeting: Meeting?
        do {
            meeting = try decoder.decode(Meeting.self, from: Data(noIntegrityJSON.utf8))
            check(true, "old-format meeting without captureIntegrity decodes")
            check(meeting?.captureIntegrity == nil, "old-format row has no captureIntegrity")
        } catch {
            meeting = nil
            check(false, "old-format meeting without captureIntegrity decodes (threw \(error))")
        }
        // MR-04: nil integrity must never read as a finished, whole recording.
        let unknownVerdict = MeetingCaptureCoverage.verdict(for: finishedEvidence(integrity: meeting?.captureIntegrity))
        note("old-format-no-integrity", unknownVerdict)
        check(unknownVerdict != .complete, "nil integrity verdict is never complete")
        check(unknownVerdict.userMessage == MeetingCaptureCoverage.unknownMessage,
              "an unknown verdict carries the unknown words")

        // MARK: Case 2 — old captureIntegrity keys decode; round-trip preserves.

        let oldIntegrityJSON = """
        {"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","title":"Weekly sync","start":"2026-09-10T10:00:00Z","captureIntegrity":{"lastCapturedAt":"2026-09-10T10:59:55Z","normalEndAt":"2026-09-10T11:00:00Z","captureGap":false,"missingCaptureFrames":0,"audioWriteFailed":false}}
        """
        do {
            let oldMeeting = try decoder.decode(Meeting.self, from: Data(oldIntegrityJSON.utf8))
            if let integrity = oldMeeting.captureIntegrity {
                check(integrity.systemSilentAfterSample == nil, "old row's silence boundary stays nil")
                check((integrity.coverageWarnings ?? []).isEmpty, "old row's warnings stay empty")
                check(integrity.lastCapturedAt != nil && integrity.normalEndAt != nil, "old row's dates decode")
                // Whole recording, finished, every established fact clean → complete.
                let fullCoverage = MeetingCaptureCoverage.verdict(for: .init(
                    integrity: integrity,
                    lastMicAt: integrity.lastCapturedAt,
                    lastSystemAt: integrity.lastCapturedAt,
                    beganAt: start,
                    now: Date(timeIntervalSince1970: 1_760_003_600),
                    expectsSystem: true,
                    isRecording: false,
                    wallDuration: 3_600))
                note("old-format-full-coverage", fullCoverage)
                check(fullCoverage != .complete, "an unmeasured row is never complete")
                check(fullCoverage == .unknown, "an unmeasured row is unknown")
                check(fullCoverage.userMessage == MeetingCaptureCoverage.unknownMessage,
                      "an unmeasured row carries the honest unknown words")
            } else {
                check(false, "old captureIntegrity keys decode (integrity missing)")
            }
            let roundTripped = try decoder.decode(Meeting.self, from: try encoder.encode(oldMeeting))
            check(roundTripped == oldMeeting, "old-format meeting round-trips through encode/decode")
        } catch {
            check(false, "old captureIntegrity keys decode (threw \(error))")
        }

        // MARK: Case 2b — a measured, intact recording is complete; an unmeasured
        // one is not. "Never measured" and "measured, nothing lost" are different
        // answers, and only one of them may read as a whole meeting.
        do {
            var measured = MeetingCaptureIntegrity()
            measured.savedCoverageMeasured = true
            measured.recordCaptured(until: start.addingTimeInterval(1_795))
            measured.normalEndAt = start.addingTimeInterval(1_800)
            check(MeetingCaptureCoverage.verdict(for: finishedEvidence(integrity: measured)) == .complete,
                  "a measured, intact recording is complete")
            var unmeasured = MeetingCaptureIntegrity()
            unmeasured.recordCaptured(until: start.addingTimeInterval(1_795))
            unmeasured.normalEndAt = start.addingTimeInterval(1_800)
            check(MeetingCaptureCoverage.verdict(for: finishedEvidence(integrity: unmeasured)) == .unknown,
                  "an unmeasured recording is unknown, not complete")
        }

        // MARK: Case 3 — unknown coverage-warning kinds are skipped, valid kept.

        let warningsJSON = """
        {"lastCapturedAt":"2026-09-10T10:29:55Z","normalEndAt":"2026-09-10T10:30:00Z","systemSilentAfterSample":14400000,"coverageWarnings":[{"track":"system","kind":"brandNewKind","atSample":100},{"track":"speaker","kind":"micTrimmed","atSample":5},{"track":"system","kind":"systemSilent","atSample":14400000}]}
        """
        do {
            let decoded = try decoder.decode(MeetingCaptureIntegrity.self, from: Data(warningsJSON.utf8))
            let warnings = decoded.coverageWarnings ?? []
            check(warnings.count == 1, "unknown-kind and bad-track warnings skipped, valid kept (got \(warnings.count))")
            check(warnings.first?.kind == .systemSilent && warnings.first?.atSample == 14_400_000,
                  "the valid systemSilent warning survives")
            check(decoded.systemSilentAfterSample == 14_400_000, "silence boundary decodes")
            let roundTripped = try decoder.decode(MeetingCaptureIntegrity.self, from: try encoder.encode(decoded))
            check(roundTripped == decoded, "integrity with warnings round-trips")
        } catch {
            check(false, "unknown coverage-warning kinds are skipped (threw \(error))")
        }

        // MARK: Case 4 — half-trim: system loss at the halfway boundary names it.

        var half = MeetingCaptureIntegrity()
        half.missingSavedSystemFrames = 8_000_000
        half.systemSilentAfterSample = 15 * 60 * 16_000 // 900 s into an 1800 s meeting
        half.recordCaptured(until: start.addingTimeInterval(1_795))
        half.normalEndAt = start.addingTimeInterval(1_800)
        check(!half.captureGap && half.missingCaptureFrames == 0 && !half.audioWriteFailed,
              "half-trim fixture has zero delivery drops and no write failure")
        let halfVerdict = MeetingCaptureCoverage.verdict(for: finishedEvidence(integrity: half))
        note("half-trim-boundary", halfVerdict)
        if case .partial(let boundary, let track, _) = halfVerdict {
            check(boundary.map { abs($0 - 900) < 1 } == true, "half-trim names the 900 s boundary")
            check(track == .system, "half-trim is a system-track partial")
        } else {
            check(false, "half-trim verdict is partial (got \(describe(halfVerdict)))")
        }
        check(halfVerdict.userMessage?.contains("halfway") == true, "half-trim message names the halfway point")
        check(halfVerdict != .complete, "half-trim is never complete")

        // MARK: Case 5 — counts-only loss, no boundary: generic system copy.

        var countsOnly = MeetingCaptureIntegrity()
        countsOnly.missingSavedSystemFrames = 8_000_000
        countsOnly.recordCaptured(until: start.addingTimeInterval(1_795))
        countsOnly.normalEndAt = start.addingTimeInterval(1_800)
        let countsVerdict = MeetingCaptureCoverage.verdict(for: finishedEvidence(integrity: countsOnly))
        note("half-trim-counts-only", countsVerdict)
        if case .partial(let boundary, let track, _) = countsVerdict {
            check(boundary == nil, "counts-only partial has no boundary")
            check(track == .system, "counts-only partial is a system track")
        } else {
            check(false, "counts-only verdict is partial (got \(describe(countsVerdict)))")
        }
        check(countsVerdict.userMessage?.contains("Some of the other speakers") == true,
              "counts-only uses the unpositioned system message")
        check(countsVerdict.userMessage?.contains("halfway") != true,
              "counts-only never invents a position")

        // MARK: Case 6 — a recording still live with fresh tracks is not stalled.

        let liveFresh = start.addingTimeInterval(600)
        let liveEvidence = MeetingCaptureCoverage.Evidence(
            integrity: half,
            lastMicAt: liveFresh,
            lastSystemAt: liveFresh,
            beganAt: start,
            now: liveFresh,
            expectsSystem: true,
            isRecording: true,
            wallDuration: 600)
        let liveVerdict = MeetingCaptureCoverage.verdict(for: liveEvidence)
        note("live-fresh-tracks", liveVerdict)
        if case .stalled = liveVerdict {
            check(false, "fresh live tracks are not stalled")
        } else {
            check(true, "fresh live tracks are not stalled")
        }
        // …but the sticky fact still keeps it partial while live.
        check(liveVerdict != .complete, "a live recording is never complete")

        // MARK: Case 7 — a live system stall, by timestamp and by frame verdict.

        let staleSystem = MeetingCaptureCoverage.Evidence(
            integrity: nil,
            lastMicAt: liveFresh,
            lastSystemAt: liveFresh.addingTimeInterval(-60),
            beganAt: start,
            now: liveFresh,
            expectsSystem: true,
            isRecording: true,
            wallDuration: 600)
        let stallByTime = MeetingCaptureCoverage.verdict(for: staleSystem)
        note("live-system-stall-by-time", stallByTime)
        if case .stalled(let track) = stallByTime {
            check(track == .system, "a stale system track while the mic is fresh stalls the system track")
        } else {
            check(false, "stale system track verdict is stalled (got \(describe(stallByTime)))")
        }
        check(stallByTime.userMessage?.contains("other speakers") == true, "system stall message is about the other speakers")
        check(stallByTime.userMessage != MeetingCaptureCoverage.stalledMicMessage, "system stall never uses the mic message")
        check(stallByTime.userMessage == MeetingCaptureCoverage.stalledSystemMessage,
              "a stall is never dressed up as uncertainty")

        let stallByFrame = MeetingCaptureCoverage.verdict(for: .init(
            frameShapeVerdict: MeetingCaptureCoverage.frameVerdictSystemStalled,
            lastMicAt: liveFresh,
            lastSystemAt: liveFresh,
            beganAt: start,
            now: liveFresh,
            expectsSystem: true,
            isRecording: true,
            wallDuration: 600))
        note("live-system-stall-by-frame", stallByFrame)
        check(stallByFrame == .stalled(track: .system), "the frame-shape verdict alone proves a system stall")

        let stallByMicTime = MeetingCaptureCoverage.verdict(for: .init(
            lastMicAt: liveFresh.addingTimeInterval(-60),
            lastSystemAt: liveFresh,
            beganAt: start,
            now: liveFresh,
            expectsSystem: true,
            isRecording: true,
            wallDuration: 600))
        note("live-mic-stall-by-time", stallByMicTime)
        if case .stalled(let track) = stallByMicTime {
            check(track == .mic, "a stale mic stalls the mic track")
        } else {
            check(false, "stale mic verdict is stalled (got \(describe(stallByMicTime)))")
        }
        check(stallByMicTime.userMessage?.contains("microphone") == true, "mic stall message names the microphone")

        // A recording that never had a system track: a stale system timestamp
        // is expected, not a stall.
        let noSystemTrack = MeetingCaptureCoverage.verdict(for: .init(
            lastMicAt: liveFresh,
            lastSystemAt: nil,
            beganAt: start,
            now: liveFresh,
            expectsSystem: false,
            isRecording: true,
            wallDuration: 600))
        check(noSystemTrack != .stalled(track: .system), "an unexpected system track cannot stall it")

        // MARK: Case 7b — the frame verdict vocabulary, including the audit's
        // half-cadence symptom. A string that names a stop is never "healthy",
        // and half cadence is a loss rather than an unknown.
        do {
            check(MeetingCaptureCoverage.parseFrameShapeVerdict("system-stalled")
                    == .systemStalled, "a system stall string parses")
            check(MeetingCaptureCoverage.parseFrameShapeVerdict("mic-stalled")
                    == .micStalled, "a mic stall string parses")
            check(MeetingCaptureCoverage.parseFrameShapeVerdict("system-half-cadence")
                    == .halfCadence, "a half-cadence string parses")
            check(MeetingCaptureCoverage.parseFrameShapeVerdict("system ok, mic stopped")
                    != .healthy, "a mixed stall string is never healthy")
            check(MeetingCaptureCoverage.parseFrameShapeVerdict("system track did not stall")
                    == .unrecognized, "a negated stall is unrecognized, not healthy")
            check(MeetingCaptureCoverage.parseFrameShapeVerdict("aligned") == .healthy,
                  "an aligned string parses as healthy")
            check(MeetingCaptureCoverage.parseFrameShapeVerdict("something new")
                    == .unrecognized, "an unknown string is unrecognized")
            check(MeetingCaptureCoverage.parseFrameShapeVerdict(nil) == nil,
                  "no verdict is no verdict")
        }

        // MARK: Case 7c — a required system track that never arrived is a loss.
        do {
            var required = MeetingCaptureIntegrity()
            required.savedCoverageMeasured = true
            required.recordCaptured(until: start.addingTimeInterval(1_795))
            required.normalEndAt = start.addingTimeInterval(1_800)
            let verdict = MeetingCaptureCoverage.verdict(for: .init(
                integrity: required,
                frameShapeVerdict: MeetingCaptureCoverage.frameVerdictHealthy,
                lastMicAt: start.addingTimeInterval(1_795),
                lastSystemAt: nil,
                beganAt: start,
                now: start.addingTimeInterval(1_800),
                expectsSystem: false,
                systemTrackRequired: true,
                isRecording: false,
                wallDuration: 1_800))
            if case .partial(_, let track, _) = verdict {
                check(track == .system, "the loss names the system track")
            } else {
                check(false, "a wanted system track that never arrived is a loss")
            }
            let optional = MeetingCaptureCoverage.verdict(for: .init(
                integrity: required,
                frameShapeVerdict: MeetingCaptureCoverage.frameVerdictHealthy,
                lastMicAt: start.addingTimeInterval(1_795),
                lastSystemAt: nil,
                beganAt: start,
                now: start.addingTimeInterval(1_800),
                expectsSystem: false,
                systemTrackRequired: false,
                isRecording: false,
                wallDuration: 1_800))
            check(optional == .complete, "a system track nobody wanted is not a loss")
        }

        // MARK: Case 8 — warning hysteresis: one transition, one alert.

        let partial = MeetingCaptureCoverage.verdict(for: finishedEvidence(integrity: half))
        let stalled = MeetingCaptureCoverage.Verdict.stalled(track: .system)
        var previous = MeetingCaptureCoverage.Verdict.unknown
        var fired = 0
        var lastMessage = ""
        for tick in 0..<100 {
            let current = tick == 0 ? partial : MeetingCaptureCoverage.verdict(for: finishedEvidence(integrity: half))
            if let alert = MeetingCaptureCoverage.shouldWarn(
                previous: previous, current: current, now: start.addingTimeInterval(Double(tick))) {
                fired += 1
                lastMessage = alert.message
            }
            previous = current
        }
        note("hysteresis-100-ticks", previous)
        check(fired == 1, "100 identical warning ticks fire exactly 1 alert (got \(fired))")
        check(lastMessage == MeetingCaptureCoverage.partialSystemMessage(
            after: 900, wallDuration: 1_800),
              "the alert carries the system partial's own words")

        var chainFired = 0
        var chainPrevious = MeetingCaptureCoverage.Verdict.unknown
        for current in [partial, stalled, partial] {
            if MeetingCaptureCoverage.shouldWarn(
                previous: chainPrevious, current: current, now: start) != nil {
                chainFired += 1
            }
            chainPrevious = current
        }
        // A stall outranks a partial: the person needs to know now. The repeat
        // that must stay quiet is the SAME state again.
        check(chainFired == 2,
              "partial → stalled → partial fires the stall and not the repeat (got \(chainFired))")

        // MARK: Case 9 — sticky: 1000 healthy ticks can never erase the fact.

        var stickyIntegrity = MeetingCaptureIntegrity()
        stickyIntegrity.missingSavedSystemFrames = 4_000_000
        stickyIntegrity.systemSilentAfterSample = 14_400_000
        stickyIntegrity.recordCaptured(until: start.addingTimeInterval(1_795))
        stickyIntegrity.normalEndAt = start.addingTimeInterval(1_800)
        var allPartial = true
        var boundarySurvived = true
        for tick in 0..<1_000 {
            let tickTime = start.addingTimeInterval(Double(tick) * 10)
            let v = MeetingCaptureCoverage.verdict(for: .init(
                integrity: stickyIntegrity,
                frameShapeVerdict: MeetingCaptureCoverage.frameVerdictHealthy,
                lastMicAt: tickTime,
                lastSystemAt: tickTime,
                beganAt: start,
                now: tickTime,
                expectsSystem: true,
                isRecording: false,
                wallDuration: 1_800))
            if case .partial(let boundary, _, _) = v {
                if boundary.map({ abs($0 - 900) < 1 }) != true { boundarySurvived = false }
            } else {
                allPartial = false
            }
        }
        note("sticky-1000-ticks", partial)
        check(allPartial, "a loss fact stays partial across 1000 healthy ticks")
        check(boundarySurvived, "the loss boundary survives every healthy tick")

        // MARK: Case 10 — merge preserves sticky facts and refines the boundary.

        var stored = MeetingCaptureIntegrity()
        stored.missingSavedSystemFrames = 4_000_000
        stored.systemSilentAfterSample = 500_000
        stored.coverageWarnings = [
            MeetingCaptureCoverageWarning(track: .system, kind: .systemSilent, atSample: 500_000),
            MeetingCaptureCoverageWarning(track: .system, kind: .systemTrimmed, atSample: 600_000),
        ]
        let empty = MeetingCaptureIntegrity().merged(preserving: stored)
        check(empty.missingSavedSystemFrames == 4_000_000, "merge preserves the stored loss count")
        check(empty.systemSilentAfterSample == 500_000, "merge preserves the stored silence boundary")
        check(empty.coverageWarnings?.count == 2, "merge preserves stored warnings")
        check(empty.hasPartialCapture, "merged sticky facts still read as partial")

        var refining = MeetingCaptureIntegrity()
        refining.systemSilentAfterSample = 400_000
        refining.coverageWarnings = [
            MeetingCaptureCoverageWarning(track: .system, kind: .systemSilent, atSample: 400_000),
        ]
        let refined = refining.merged(preserving: stored)
        check(refined.systemSilentAfterSample == 400_000, "merge keeps the earliest silence boundary")
        check(refined.coverageWarnings?.contains(where: { $0.kind == .systemSilent && $0.atSample == 400_000 }) == true,
              "merge keys warnings by (track, kind) and keeps the earliest")
        check(refined.coverageWarnings?.count == 2, "a later distinct warning is added, not replaced")

        // MARK: Case 11 — delivery-level loss is a generic partial.

        var gapOnly = MeetingCaptureIntegrity()
        gapOnly.markGap()
        let gapVerdict = MeetingCaptureCoverage.verdict(for: finishedEvidence(integrity: gapOnly))
        note("capture-gap-only", gapVerdict)
        if case .partial(let boundary, let track, _) = gapVerdict {
            check(boundary == nil && track == nil, "capture gap alone is an unpositioned, whole-recording partial")
        } else {
            check(false, "capture gap verdict is partial (got \(describe(gapVerdict)))")
        }
        check(gapVerdict.userMessage == MeetingCaptureCoverage.partialGenericMessage,
              "capture gap uses the generic delivery message")

        // MARK: Case 12 — the @MainActor source seam maps a real session's facts.

        let fake = FakeCoverageSource(integrity: fullIntegrity(), frameVerdict: MeetingCaptureCoverage.frameVerdictHealthy)
        let built = MeetingCaptureCoverage.evidence(
            from: fake,
            startedAt: start,
            now: start.addingTimeInterval(1_800),
            lastMicAt: start.addingTimeInterval(1_795),
            lastSystemAt: start.addingTimeInterval(1_795),
            expectsSystem: true,
            isRecording: false)
        check(built.integrity == fullIntegrity(), "evidence maps the source's integrity")
        check(built.frameShapeVerdict == MeetingCaptureCoverage.frameVerdictHealthy, "evidence maps the frame verdict")
        check(abs(built.wallDuration - 1_800) < 1, "finished evidence derives wallDuration from normalEndAt")
        note("source-seam-finished", MeetingCaptureCoverage.verdict(for: built))
        check(MeetingCaptureCoverage.verdict(for: built) == .complete, "source seam yields complete for a clean finished meeting")

        let liveBuilt = MeetingCaptureCoverage.evidence(
            from: fake,
            startedAt: start,
            now: start.addingTimeInterval(600),
            lastMicAt: start.addingTimeInterval(600),
            lastSystemAt: start.addingTimeInterval(600),
            expectsSystem: true,
            isRecording: true)
        check(abs(liveBuilt.wallDuration - 600) < 1, "live evidence derives wallDuration from now")

        // MARK: Case 13 — frame-shape strings reduce to the closed verdict set.

        check(MeetingCaptureCoverage.parseFrameShapeVerdict("system-stalled") == .systemStalled,
              "the producer's system-stalled spelling parses")
        check(MeetingCaptureCoverage.parseFrameShapeVerdict("mic-stalled") == .micStalled,
              "the producer's mic-stalled spelling parses")
        check(MeetingCaptureCoverage.parseFrameShapeVerdict("aligned") == .healthy,
              "the producer's aligned spelling parses")
        check(MeetingCaptureCoverage.parseFrameShapeVerdict("system track did not stall") != .systemStalled,
              "a negated stall is not a stall")
        check(MeetingCaptureCoverage.parseFrameShapeVerdict("") == nil, "an empty verdict is nil, not ok")
        check(MeetingCaptureCoverage.parseFrameShapeVerdict(nil) == nil, "an absent verdict is nil, not ok")
        check(MeetingCaptureCoverage.parseFrameShapeVerdict("some odd string") == .unrecognized,
              "an unknown spelling is neutral, never ok")

        // MARK: Case 14 — a boundary beyond the wall clock clamps, never extrapolates.

        var clamped = MeetingCaptureIntegrity()
        clamped.systemSilentAfterSample = 2_000 * 60 * 16_000 // 2000 min into a 10 min meeting
        clamped.missingSavedSystemFrames = 1
        clamped.normalEndAt = start.addingTimeInterval(600)
        clamped.recordCaptured(until: start.addingTimeInterval(595))
        let clampedVerdict = MeetingCaptureCoverage.verdict(for: finishedEvidence(
            integrity: clamped, wall: 600))
        if case .partial(let boundary, _, _) = clampedVerdict {
            check(boundary.map({ abs($0 - 600) < 1 }) == true, "an out-of-range boundary clamps to the wall duration")
        } else {
            check(false, "out-of-range boundary verdict is partial (got \(describe(clampedVerdict)))")
        }
        check(clampedVerdict.userMessage?.contains("near the end") == true,
              "a clamped boundary reads as near the end, never as a huge minute count")

        if failures == 0 {
            log("COVERAGE_OK: \(checks) checks")
            return true
        } else {
            log("COVERAGE_FAILED: \(failures) of \(checks) checks wrong")
            return false
        }
    }

    // MARK: - Fixtures

    private static let start = Date(timeIntervalSince1970: 1_760_000_000)

    /// A recording whose coverage was measured and found whole.
    private static func fullIntegrity() -> MeetingCaptureIntegrity {
        var integrity = MeetingCaptureIntegrity()
        integrity.savedCoverageMeasured = true
        integrity.recordCaptured(until: start.addingTimeInterval(1_795))
        integrity.normalEndAt = start.addingTimeInterval(1_800)
        return integrity
    }

    private static func finishedEvidence(
        integrity: MeetingCaptureIntegrity?,
        wall: TimeInterval = 1_800,
        frame: String? = nil
    ) -> MeetingCaptureCoverage.Evidence {
        MeetingCaptureCoverage.Evidence(
            integrity: integrity,
            frameShapeVerdict: frame,
            lastMicAt: start.addingTimeInterval(wall - 5),
            lastSystemAt: start.addingTimeInterval(wall - 5),
            beganAt: start,
            now: start.addingTimeInterval(wall),
            expectsSystem: true,
            isRecording: false,
            wallDuration: wall)
    }

    private static func describe(_ verdict: MeetingCaptureCoverage.Verdict) -> String {
        switch verdict {
        case .complete: "complete"
        case .unknown: "unknown"
        case .stalled(let track): "stalled(\(track?.rawValue ?? "both"))"
        case .partial(let after, let track, _):
            "partial(after=\(after.map { String(format: "%.0f", $0) } ?? "nil"), track=\(track?.rawValue ?? "nil"))"
        }
    }
}

/// A stand-in for a live session: the seam exists so the pure functions can be
/// driven without constructing `MeetingSession` or touching its stores.
@MainActor
private final class FakeCoverageSource: CaptureCoverageSource {
    var captureIntegrity: MeetingCaptureIntegrity?
    private let frameVerdict: String?

    init(integrity: MeetingCaptureIntegrity?, frameVerdict: String?) {
        self.captureIntegrity = integrity
        self.frameVerdict = frameVerdict
    }

    func frameShapeDriftVerdict() -> String? { frameVerdict }
}
