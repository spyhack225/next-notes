import AVFoundation
import Darwin
import Foundation

/// One instant in a voice turn, stamped by whoever already owns that moment.
///
/// There is no second clock: every mark is `CLOCK_UPTIME_RAW` nanoseconds, the same
/// clock `LatencyTrace` times with, and every wall-clock stamp is the real `Date()` read
/// beside it. A span is the difference between two marks, so a stage is never timed twice
/// — the capture controller, the coordinator, the frontend and the synthesizer each stamp
/// the one boundary they already own and nothing else.
enum VoiceMark: String, CaseIterable, Sendable {
    case voiceOnset = "voice_onset"
    case lastVoice = "last_voice"
    case asrFirstPartial = "asr_first_partial"
    case eouRaw = "eou_raw"
    case eouCallback = "eou_callback"
    case eouConfirmed = "eou_confirmed"
    /// P2-04's end-of-turn arbiter. Declared now so the vocabulary has one home.
    case smartTurn = "smart_turn"
    case endpoint = "endpoint"
    case frontendRequest = "frontend_request"
    case schedulerAcquired = "scheduler_acquired"
    case routeDone = "route_done"
    case frontendFirstToken = "frontend_first_token"
    case firstClauseEnqueued = "first_clause_enqueued"
    case ttsFirstPCM = "tts_first_pcm"
    case firstAudible = "first_audible"
    case bargeOnset = "barge_onset"
    case bargePause = "barge_pause"
    case bargeStop = "barge_stop"
    /// P2-05's ducking measure. There is no duck today, so nothing stamps it and
    /// `voice.onset_to_duck` is absent rather than zero.
    case bargeDuck = "barge_duck"
}

/// One stage of a voice turn: the span it writes and the two marks it reads.
///
/// A stage whose marks are not both present writes nothing. That is the whole contract
/// that makes this a measurement: a stage that did not happen is a missing row, never a
/// zero, and `--selftest-voice-latency` fails on the missing row.
struct VoiceStageSpan: Sendable {
    enum Kind: Sendable {
        /// Two marks, one difference.
        case interval(from: VoiceMark, to: VoiceMark)
        /// The worst main-actor lateness observed while the turn was open.
        case stall
        /// A zero-duration marker whose reason rides in `note`.
        case marker
    }

    let span: LatencySpanID
    let kind: Kind
    /// A counted run in `--selftest-voice-latency` must produce this row.
    let required: Bool
    /// The headline stages also go into the per-turn usage row's `stages`.
    let inTurnSummary: Bool

    static let all: [VoiceStageSpan] = [
        VoiceStageSpan(span: .voiceSpeechEndToEOU,
            kind: .interval(from: .lastVoice, to: .eouConfirmed), required: true, inTurnSummary: false),
        VoiceStageSpan(span: .voiceEOUHop,
            kind: .interval(from: .eouCallback, to: .eouConfirmed), required: true, inTurnSummary: false),
        VoiceStageSpan(span: .voiceEOUToEndpoint,
            kind: .interval(from: .eouConfirmed, to: .endpoint), required: true, inTurnSummary: false),
        VoiceStageSpan(span: .voiceSpeechEndToEndpoint,
            kind: .interval(from: .lastVoice, to: .endpoint), required: true, inTurnSummary: true),
        VoiceStageSpan(span: .voiceEndpointToRequest,
            kind: .interval(from: .endpoint, to: .frontendRequest), required: true, inTurnSummary: false),
        VoiceStageSpan(span: .voiceRequestToLane,
            kind: .interval(from: .frontendRequest, to: .schedulerAcquired), required: false, inTurnSummary: false),
        VoiceStageSpan(span: .voiceRoute,
            kind: .interval(from: .schedulerAcquired, to: .routeDone), required: false, inTurnSummary: false),
        VoiceStageSpan(span: .voiceRouteToFirstToken,
            kind: .interval(from: .routeDone, to: .frontendFirstToken), required: false, inTurnSummary: false),
        VoiceStageSpan(span: .voiceTranscriptToFirstToken,
            kind: .interval(from: .endpoint, to: .frontendFirstToken), required: true, inTurnSummary: true),
        VoiceStageSpan(span: .voiceFirstTokenToClause,
            kind: .interval(from: .frontendFirstToken, to: .firstClauseEnqueued), required: true, inTurnSummary: true),
        VoiceStageSpan(span: .voiceClauseToFirstPCM,
            kind: .interval(from: .firstClauseEnqueued, to: .ttsFirstPCM), required: true, inTurnSummary: true),
        VoiceStageSpan(span: .voiceFirstPCMToAudible,
            kind: .interval(from: .ttsFirstPCM, to: .firstAudible), required: true, inTurnSummary: false),
        VoiceStageSpan(span: .voiceSpeechEndToFirstAudio,
            kind: .interval(from: .lastVoice, to: .firstAudible), required: true, inTurnSummary: true),
        VoiceStageSpan(span: .voiceMainActorStall, kind: .stall, required: true, inTurnSummary: true),
        VoiceStageSpan(span: .voiceSpeculation, kind: .marker, required: true, inTurnSummary: false),
    ]

    /// Spans only a barge test produces. Kept out of `all` so a plain latency run does
    /// not report three absent rows as three failures.
    static let barge: [VoiceStageSpan] = [
        VoiceStageSpan(span: .voiceOnsetToDuck,
            kind: .interval(from: .bargeOnset, to: .bargeDuck), required: false, inTurnSummary: false),
        VoiceStageSpan(span: .voiceOnsetToPause,
            kind: .interval(from: .bargeOnset, to: .bargePause), required: false, inTurnSummary: false),
        VoiceStageSpan(span: .voiceOnsetToStop,
            kind: .interval(from: .bargeOnset, to: .bargeStop), required: false, inTurnSummary: false),
    ]
}

/// A mark and the wall clock read beside it, so a span's `startedAt` is real time and its
/// duration is monotonic — the same pair `LatencyTrace` keeps.
struct VoiceInstant: Sendable {
    let nanos: UInt64
    let wall: Date
}

/// One turn's marks, the worst stall seen while it was open, and the ids that join it to
/// the usage log.
struct VoiceClosedTurn: Sendable {
    let number: Int
    let sessionID: UUID?
    let turnID: UUID?
    let conversationID: UUID?
    let reason: String
    let marks: [VoiceMark: VoiceInstant]
    let notes: [String: String]
    let maxStallNanos: UInt64
    let stallSite: String?
    let closedAtNanos: UInt64
    /// Seconds per span id, for the printed table. An absent stage is absent, not zero.
    let durations: [LatencySpanID: Double]
    let speculationHit: Bool

    func seconds(_ span: LatencySpanID) -> Double? { durations[span] }
    var mainStallSeconds: Double { Double(maxStallNanos) / 1_000_000_000 }
}

/// The one place a voice turn's stage boundaries are stamped, and the one place they
/// become rows.
///
/// Not `@MainActor`, and never `MainActor.assumeIsolated` (it asserts and crashes). Every
/// method is O(1) behind one `NSLock` and is callable from the capture lane, from
/// FluidAudio's callback thread, from any actor, or from the main actor, because the
/// boundaries it stamps live on all four.
///
/// A turn opens on the first voice onset and closes on the first audible sample. Marks that
/// arrive with no turn open are dropped, because a span between two marks of different
/// utterances is a number nobody asked for.
final class VoiceLatencyTimeline: @unchecked Sendable {
    static let shared = VoiceLatencyTimeline()

    /// Barge marks arriving after a turn closed attach to it inside this window: a person
    /// interrupting a reply interrupts *that* reply's turn.
    private static let bargeAttachmentWindow: UInt64 = 30 * 1_000_000_000

    private let lock = NSLock()
    private var open: OpenTurn?
    private var nextTurnNumber = 1
    private var closed: [VoiceClosedTurn] = []
    private var lastClosed: VoiceClosedTurn?
    private var fileFedOwnsMarks = false
    /// An atomic mirror of `RealtimeAudioSession.isSpeaking`, which is main-actor state the
    /// capture lane must not read. Set from `RealtimeAudioSession` on every change.
    private var outputActive = false
    private var sessionID: UUID?
    private var discarded = 0
    private var discardReasons: [String] = []
    /// Marks that arrived with no turn open. A mark with nowhere to land is a fact about
    /// the turn lifecycle, not a number, so it is counted here and read by the self-test
    /// rather than dropped without a trace.
    private var orphans: [String] = []

    private struct OpenTurn {
        let number: Int
        let sessionID: UUID?
        var marks: [VoiceMark: VoiceInstant] = [:]
        var notes: [String: String] = [:]
        var turnID: UUID?
        var conversationID: UUID?
        var maxStallNanos: UInt64 = 0
        var stallSite: String?
    }

    // MARK: - Clock

    /// `CLOCK_UPTIME_RAW` nanoseconds — the clock `LatencyTrace` times with, so a span
    /// written from these marks and a span written by a trace are the same kind of number.
    static func nowNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// An `AVAudioTime` host time in the same units, for a capture buffer's own timestamp.
    static func nanos(hostTime: UInt64) -> UInt64 {
        UInt64(AVAudioTime.seconds(forHostTime: hostTime) * 1_000_000_000)
    }

    // MARK: - Session

    /// A new capture session resets the turn counter and closes whatever was open. A turn
    /// that never produced audio is still written: it is the record that the stage it missed
    /// did not happen.
    func beginSession(_ id: UUID) {
        lock.lock()
        let pending = open
        open = nil
        nextTurnNumber = 1
        fileFedOwnsMarks = false
        sessionID = id
        lock.unlock()
        if let pending { close(pending, reason: "session_end") }
    }

    func endSession() {
        lock.lock()
        let pending = open
        open = nil
        fileFedOwnsMarks = false
        sessionID = nil
        lock.unlock()
        if let pending { close(pending, reason: "session_end") }
    }

    /// A file-fed session stamps its own voice marks where it already stamps
    /// `fileFirstVoiceAt` / `fileLastVoiceAt`, on the *source* level rather than the cleaned
    /// one. `voice.speech_end_to_endpoint` then means the same thing it means for a live
    /// microphone, and the live path does not double-count the same utterance.
    var fileFedOwnsVoiceMarks: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return fileFedOwnsMarks
        }
        set {
            lock.lock()
            fileFedOwnsMarks = newValue
            lock.unlock()
        }
    }

    /// `RealtimeAudioSession` mirrors its `isSpeaking` here so the capture lane can decide a
    /// barge onset without touching main-actor state.
    func setOutputActive(_ active: Bool) {
        lock.lock()
        outputActive = active
        lock.unlock()
    }

    // MARK: - Marks

    /// Stamps one boundary. `lastVoice` is the only mark that moves; every other mark keeps
    /// its first value, because "the first thing the person said" must not become "the
    /// latest thing the person said" as the utterance goes on.
    func mark(
        _ mark: VoiceMark,
        at nanos: UInt64 = VoiceLatencyTimeline.nowNanos(),
        overwrite: Bool = false
    ) {
        let instant = VoiceInstant(nanos: nanos, wall: Date())
        var toClose: OpenTurn?
        var bargeTarget: VoiceClosedTurn?
        lock.lock()
        // One unlock, whatever happens: this lock is also taken by the capture lane and by
        // FluidAudio's callback thread, so a path that returned holding it would hang a
        // voice turn and every later mark with it.
        defer { lock.unlock() }
        switch mark {
        case .voiceOnset:
            if open != nil, open?.marks[.endpoint] != nil {
                // A second onset after the previous turn committed: close that one and open
                // this turn. An onset before any endpoint is the same utterance resuming.
                toClose = open
                open = nil
            }
            if open == nil {
                var turn = OpenTurn(number: nextTurnNumber, sessionID: sessionID)
                nextTurnNumber += 1
                turn.marks[.voiceOnset] = instant
                if outputActive { turn.marks[.bargeOnset] = instant }
                open = turn
            }
        case .bargeOnset, .bargePause, .bargeStop, .bargeDuck:
            if open != nil {
                setLocked(mark, instant, overwrite: overwrite || mark == .bargeOnset)
            } else if let recent = lastClosed,
                      VoiceLatencyTimeline.nowNanos() &- recent.closedAtNanos
                        <= Self.bargeAttachmentWindow {
                bargeTarget = recent
            }
        case .lastVoice:
            // Speech can resume inside one utterance. Once the endpoint exists the turn is
            // committed and further audio belongs to nothing.
            if open != nil, open?.marks[.endpoint] == nil {
                setLocked(mark, instant, overwrite: true)
            }
        case .firstAudible:
            if open != nil {
                setLocked(mark, instant, overwrite: false)
                toClose = open
                open = nil
            }
        default:
            if !setLocked(mark, instant, overwrite: overwrite) { noteOrphan(mark) }
        }
        let closing = toClose
        let barge = bargeTarget
        lock.unlock()
        if let closing { close(closing, reason: mark == .firstAudible ? "first_audio" : "interrupted") }
        if let barge, mark == .bargeStop { emitBarge(on: barge, mark: mark, at: instant) }
    }

    /// A named value for the turn: a reason, a source, a head start. Not text and never a
    /// transcript — `notes` joins into every span's `note`.
    func note(_ key: String, _ value: String) {
        lock.lock()
        if open != nil { open?.notes[key] = value }
        lock.unlock()
    }

    /// The ids that join this turn to `usage.jsonl`. The coordinator owns both and hands
    /// them over where it already builds the request; the timeline never reads main-actor
    /// state to find them. Called while the turn is open — the voice onset is stamped long
    /// before the request is built, so there is always one to attach to.
    func attachTurnIDs(turnID: UUID?, conversationID: UUID?) {
        lock.lock()
        open?.turnID = turnID
        open?.conversationID = conversationID
        lock.unlock()
    }

    /// Which model answered, from the one place that knows (`AgentToolSpeechTracker`). The
    /// usage row needs the field; the timeline does not invent it.
    func noteAnswering(provider: UsageProvider, modelID: String, locality: String) {
        lock.lock()
        if open != nil {
            open?.notes["provider"] = provider.rawValue
            open?.notes["model"] = modelID
            open?.notes["locality"] = locality
        }
        lock.unlock()
    }

    /// The main-actor probe reports its worst lateness. Only the maximum is kept: a turn's
    /// stall is the worst moment in it, and a list would be a list to interpret later.
    func noteStall(nanos: UInt64, site: String?) {
        guard nanos > 0 else { return }
        lock.lock()
        if let turn = open, nanos > turn.maxStallNanos {
            open?.maxStallNanos = nanos
            open?.stallSite = site
        }
        lock.unlock()
    }

    /// `tick` threw the input away: forget the marks, write nothing. A discarded utterance
    /// has no endpoint and no request, so every one of its intervals would be a span between
    /// two moments that were never part of a turn.
    ///
    /// A turn that already reached `emitTurn` is **not** discardable. Its endpoint exists and
    /// its request went out, so it is a turn whatever the capture controller does with it
    /// next; measured on 2026-09-27 a later tick evaluation discarded a turn whose frontend
    /// answer was already being spoken, which threw away every span of a real turn. The
    /// anomaly is kept as a note instead of as a silent loss, because a discard after an
    /// endpoint is a finding and not a stage boundary.
    func discardTurn(_ reason: String) {
        lock.lock()
        if let turn = open, turn.marks[.endpoint] != nil {
            open?.notes["discard_after_endpoint"] = reason
            lock.unlock()
            return
        }
        if open != nil {
            discarded += 1
            discardReasons.append(reason)
        }
        open = nil
        lock.unlock()
    }

    /// Turn bookkeeping, for a self-test that recorded nothing and needs to say why.
    func accounting() -> (open: Int?, openTurnID: UUID?, openConversationID: UUID?,
        discarded: Int, reasons: [String], next: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (open?.number, open?.turnID, open?.conversationID,
            discarded, discardReasons, nextTurnNumber)
    }

    // MARK: - Emission

    /// Emits every stage whose two marks exist, then the one per-turn usage row. The caller
    /// has already taken the turn out of `open`, so nothing is emitted under the lock.
    private func close(_ openTurn: OpenTurn, reason: String) {
        let turn = VoiceClosedTurn(
            number: openTurn.number,
            sessionID: openTurn.sessionID,
            turnID: openTurn.turnID,
            conversationID: openTurn.conversationID,
            reason: reason,
            marks: openTurn.marks,
            notes: openTurn.notes,
            maxStallNanos: openTurn.maxStallNanos,
            stallSite: openTurn.stallSite,
            closedAtNanos: VoiceLatencyTimeline.nowNanos(),
            durations: Self.durations(for: openTurn),
            speculationHit: Self.speculationHit(openTurn.notes)
        )
        let correlation = LatencyCorrelation(
            sessionID: turn.sessionID, workID: nil, revision: turn.number)
        let note = Self.noteText(turn.notes)
        var stages = VoiceStageSpan.all
        if turn.marks[.bargeOnset] != nil { stages += VoiceStageSpan.barge }
        for stage in stages {
            guard let built = Self.span(for: stage, turn: turn, correlation: correlation,
                note: note) else { continue }
            // Sampled on the writer, not by whoever happened to end the stage.
            MetricsStore.shared.recordAsync { built }
        }
        UsageLog.shared.record(Self.turnRow(turn))
        lock.lock()
        closed.append(turn)
        if closed.count > 64 { closed.removeFirst(closed.count - 64) }
        lastClosed = turn
        lock.unlock()
    }

    /// A barge that arrived after its turn closed: the interruption belongs to the reply it
    /// interrupted, and the spans say so.
    private func emitBarge(on turn: VoiceClosedTurn, mark: VoiceMark, at instant: VoiceInstant) {
        var marks = turn.marks
        marks[mark] = instant
        let extended = VoiceClosedTurn(
            number: turn.number, sessionID: turn.sessionID, turnID: turn.turnID,
            conversationID: turn.conversationID, reason: turn.reason, marks: marks,
            notes: turn.notes, maxStallNanos: turn.maxStallNanos, stallSite: turn.stallSite,
            closedAtNanos: turn.closedAtNanos,
            durations: Self.durations(for: marks, stallNanos: 0,
                speculation: turn.notes["speculation"] != nil),
            speculationHit: turn.speculationHit)
        let correlation = LatencyCorrelation(
            sessionID: turn.sessionID, workID: nil, revision: turn.number)
        for stage in VoiceStageSpan.barge {
            guard let built = Self.span(for: stage, turn: extended, correlation: correlation,
                note: "barge") else { continue }
            MetricsStore.shared.recordAsync { built }
        }
    }

    /// The one persistent sink for a turn: a `usage.jsonl` row beside the per-pass rows,
    /// never a second file. The spans above stay in `metrics.jsonl`, which is a ~31-hour
    /// ring; this row is what `--usage-report` reads weeks later.
    private static func turnRow(_ turn: VoiceClosedTurn) -> UsageRecord {
        let noted = turn.notes["provider"].flatMap(UsageProvider.init(rawValue:))
        // The same short names the dictation tail and `dictation tail · drain …` use, so
        // `--usage-report` reads one vocabulary rather than two: `voice.` is the span
        // namespace, not the stage's name.
        var stages: [String: Double] = [:]
        for stage in VoiceStageSpan.all where stage.inTurnSummary {
            guard let seconds = turn.seconds(stage.span) else { continue }
            stages[stage.span.rawValue.replacingOccurrences(of: "voice.", with: "")] = seconds
        }
        stages["main_actor_stall"] = turn.mainStallSeconds
        return UsageRecord(
            v: 1,
            id: UUID(),
            ts: Date(),
            feature: UsageFeature.agentVoice.rawValue,
            pass: "turn",
            round: nil,
            // The model that answered is on the pass rows. This row is a stage summary, and
            // when no pass was noted it names the turn rather than inventing a model.
            provider: (noted ?? .rules).rawValue,
            modelID: turn.notes["model"] ?? "voice-turn",
            locality: turn.notes["locality"] ?? "local",
            requestedRole: nil,
            requestedModel: nil,
            fallbackReason: nil,
            warm: nil,
            loadMs: nil,
            promptTokens: nil,
            cachedTokens: nil,
            completionTokens: nil,
            reasoningTokens: nil,
            countsEstimated: nil,
            ttftMs: turn.seconds(.voiceTranscriptToFirstToken).map { Int(($0 * 1_000).rounded()) },
            totalMs: Int(((turn.seconds(.voiceSpeechEndToFirstAudio) ?? 0) * 1_000).rounded()),
            tokensPerSec: nil,
            finishReason: turn.marks[.firstAudible] != nil ? "stop" : "incomplete",
            truncated: turn.marks[.firstAudible] == nil,
            toolsProposed: nil,
            toolsExecuted: nil,
            errorClass: turn.marks[.firstAudible] != nil ? nil : UsageErrorClass.other.rawValue,
            errorMessage: nil,
            audioSeconds: nil,
            realtimeFactor: nil,
            stages: stages,
            counts: [
                "turn": turn.number,
                "marks": turn.marks.count,
                "speculationHit": turn.speculationHit ? 1 : 0,
            ],
            turnID: turn.turnID,
            conversationID: turn.conversationID,
            workID: nil,
            revision: turn.number,
            meetingID: nil,
            dictationRunID: nil,
            scheduleID: nil
        )
    }

    /// One stage's row, or nil because one of its two marks never happened.
    ///
    /// A negative difference is a stage that finished before the mark it is measured from —
    /// a speculated request whose work was already done, or a clock read that crossed. It is
    /// written as zero and says so in the note, because the alternative is dropping a real
    /// event and reporting an absent one.
    private static func span(
        for stage: VoiceStageSpan, turn: VoiceClosedTurn,
        correlation: LatencyCorrelation, note: String
    ) -> LatencySpan? {
        switch stage.kind {
        case .interval(let from, let to):
            guard let start = turn.marks[from], let end = turn.marks[to] else { return nil }
            let raw = Double(Int64(end.nanos) - Int64(start.nanos)) / 1_000_000_000
            let speculated = raw < 0
            return LatencySpan(
                name: stage.span,
                startedAt: start.wall,
                endedAt: end.wall,
                durationSeconds: max(0, raw),
                note: speculated ? "\(note) speculated".trimmingCharacters(in: .whitespaces) : note,
                correlation: correlation,
                source: "voice"
            )
        case .stall:
            guard turn.maxStallNanos > 0 else { return nil }
            let ended = turn.marks[.firstAudible]?.wall
                ?? turn.marks[.endpoint]?.wall
                ?? Date()
            let site = turn.stallSite ?? "unlabelled"
            return LatencySpan(
                name: stage.span,
                startedAt: ended.addingTimeInterval(-turn.mainStallSeconds),
                endedAt: ended,
                durationSeconds: turn.mainStallSeconds,
                note: "site=\(site) \(note)".trimmingCharacters(in: .whitespaces),
                correlation: correlation,
                source: "voice"
            )
        case .marker:
            guard let speculation = turn.notes["speculation"] else { return nil }
            let at = turn.marks[.endpoint]?.wall ?? Date()
            return LatencySpan(
                name: stage.span,
                startedAt: at,
                endedAt: at,
                durationSeconds: 0,
                note: "\(speculation) \(note)".trimmingCharacters(in: .whitespaces),
                correlation: correlation,
                source: "voice"
            )
        }
    }

    private static func durations(for turn: OpenTurn) -> [LatencySpanID: Double] {
        // A miss is a marker too: the row says the turn did not speculate and why, which is
        // the number a later task needs to know it was on the critical path.
        durations(for: turn.marks, stallNanos: turn.maxStallNanos,
            speculation: turn.notes["speculation"] != nil)
    }

    /// A marker's own duration is zero and its presence is the fact, so it appears in the
    /// table only when the note that produced it is there. `stall` is zero for a turn whose
    /// main actor never stalled, which is a real measurement rather than an absence: a turn
    /// that ends without a `firstAudible` simply has no stall sample, and the row is absent.
    private static func durations(
        for marks: [VoiceMark: VoiceInstant], stallNanos: UInt64, speculation: Bool
    ) -> [LatencySpanID: Double] {
        var out: [LatencySpanID: Double] = [:]
        for stage in VoiceStageSpan.all + VoiceStageSpan.barge {
            switch stage.kind {
            case .interval(let from, let to):
                guard let start = marks[from], let end = marks[to] else { continue }
                out[stage.span] = max(0,
                    Double(Int64(end.nanos) - Int64(start.nanos)) / 1_000_000_000)
            case .stall:
                out[stage.span] = Double(stallNanos) / 1_000_000_000
            case .marker:
                if speculation { out[stage.span] = 0 }
            }
        }
        return out
    }

    private static func speculationHit(_ notes: [String: String]) -> Bool {
        notes["speculation"]?.hasPrefix("hit") == true
    }

    private static func noteText(_ notes: [String: String]) -> String {
        notes.keys.sorted().map { "\($0)=\(notes[$0] ?? "")" }
            .joined(separator: " ")
    }

    // MARK: - Turn lifecycle (called under the lock)

    @discardableResult
    private func setLocked(
        _ mark: VoiceMark, _ instant: VoiceInstant, overwrite: Bool
    ) -> Bool {
        guard let turn = open else { return false }
        if overwrite || turn.marks[mark] == nil {
            open?.marks[mark] = instant
        }
        return true
    }

    /// Caller holds the lock. A mark with no turn open is a fact about the turn lifecycle,
    /// not a number, so it is recorded and read by the self-test rather than dropped
    /// without a trace. `firstAudible` is not one of them: an acknowledgement after the
    /// turn closed is ordinary (a second clause of the same reply acknowledges too).
    private func noteOrphan(_ mark: VoiceMark) {
        guard mark != .firstAudible, orphans.count < 12 else { return }
        orphans.append(mark.rawValue)
    }

    /// The marks that arrived with no turn open, in order.
    func orphanMarks() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return orphans
    }

    // MARK: - Reading

    func closedTurnsForTesting() -> [VoiceClosedTurn] {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func resetForTesting() {
        lock.lock()
        open = nil
        closed.removeAll()
        lastClosed = nil
        discarded = 0
        discardReasons = []
        orphans = []
        nextTurnNumber = 1
        sessionID = nil
        fileFedOwnsMarks = false
        lock.unlock()
        UsageLog.shared.flush()
        MetricsStore.shared.flushForTesting()
    }
}
