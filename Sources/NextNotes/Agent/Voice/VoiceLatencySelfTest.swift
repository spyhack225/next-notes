import Foundation

/// `--selftest-voice-latency` (P2-01).
///
/// Where a voice turn's three seconds go, stage by stage, on the production pipeline: one
/// warm-up turn plus N measured turns through the same file-fed path
/// `--selftest-voice-pipeline` uses, a per-run span table, the medians, and the main-actor
/// stall with the site it was attributed to.
///
/// Three rules make the numbers worth reading:
///
/// 1. **A stage that did not happen is a missing row, not a zero.** The measured runs fail
///    on any absent required span, so this test cannot go green by measuring nothing.
/// 2. **One turn, one story.** The spans and the per-turn summary row are rows in
///    `metrics.jsonl` and `usage.jsonl` beside the per-pass rows, and a counted run asserts
///    they share the voice turn's `turnID`. A second metrics file would be the failure this
///    whole task exists to prevent.
/// 3. **A stall attributed wrongly is worse than no attribution.** The probe's own accuracy
///    is measured first, on a main-actor block of known length, before any production stall
///    is believed.
@MainActor
enum VoiceLatencySelfTest {
    typealias Result = (ok: Bool, marker: String)

    /// The columns of the printed table, in the order a turn meets them.
    private static let columns: [(String, LatencySpanID)] = [
        ("speech_end_to_eou", .voiceSpeechEndToEOU),
        ("eou_hop", .voiceEOUHop),
        ("eou_to_endpoint", .voiceEOUToEndpoint),
        ("speech_end_to_endpoint", .voiceSpeechEndToEndpoint),
        ("endpoint_to_request", .voiceEndpointToRequest),
        ("request_to_lane", .voiceRequestToLane),
        ("route", .voiceRoute),
        ("route_to_first_token", .voiceRouteToFirstToken),
        ("transcript_to_first_token", .voiceTranscriptToFirstToken),
        ("first_token_to_clause", .voiceFirstTokenToClause),
        ("clause_to_first_pcm", .voiceClauseToFirstPCM),
        ("first_pcm_to_audible", .voiceFirstPCMToAudible),
        ("speech_end_to_first_audio", .voiceSpeechEndToFirstAudio),
    ]

    static func run() async -> Result {
        let runs = max(1, Int(SelfTest.value(after: "--voice-latency-runs") ?? "") ?? 5)
        let budget = Double(SelfTest.value(after: "--voice-latency-budget") ?? "")
        let maxStall = Double(SelfTest.value(after: "--voice-latency-max-stall") ?? "") ?? 0.100
        let startDelay = Double(SelfTest.value(after: "--voice-latency-start-delay") ?? "") ?? 0
        let islandOff = SelfTest.value(after: "--voice-latency-island") == "off"
        let speculation = CommandLine.arguments.contains("--voice-no-speculation")
            ? "disabled" : "as-configured"
        let fixture = SelfTest.value(after: "--voice-latency-fixture")
            .map(URL.init(fileURLWithPath:)) ?? Self.defaultFixture

        var wrong: [String] = []

        // --- Preconditions. Each names what is missing, and never passes. ---
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            return absent("fixture \(fixture.lastPathComponent) is missing — run "
                + "Scripts/make-voice-fixtures.sh")
        }
        let pocketModel = Self.pocketModelDirectory()
        guard FileManager.default.fileExists(atPath: pocketModel.path) else {
            return absent("Pocket TTS is not downloaded (looked in \(pocketModel.path)); "
                + "voice.clause_to_first_pcm has no source without it")
        }
        if let reason = FoundationModelFormatter.unavailableReason {
            return absent("the on-device voice model is unavailable: \(reason)")
        }

        // --- The table, the absent case, the store and the probe, before any measurement
        // is believed. A run that cannot be trusted to fail is not a measurement. ---
        wrong += selfTestEmission()
        wrong += selfTestAbsentStages()
        wrong += selfTestDiscard()
        wrong += selfTestUsageRow()
        wrong += await MainActorStallProbeSelfTest.run()
        if !wrong.isEmpty { return finish(wrong) }

        VoiceLatencyTimeline.shared.resetForTesting()
        if islandOff { IslandState.suppressUpdatesForTesting = true }
        defer { IslandState.suppressUpdatesForTesting = false }

        // Pocket is forced rather than read from Settings: a self-test must not write the
        // owner's voice preference, and the Apple and Kokoro backings have no PCM mark, so a
        // run on either would be measuring a stage that does not exist.
        let speech = AgentSpeechSynthesizer.shared
        let priorEngine = speech.engineOverrideForTesting
        speech.engineOverrideForTesting = "pocket"
        defer { speech.engineOverrideForTesting = priorEngine }

        let capture = AgentCaptureController.shared
        await capture.endSession(source: .done)
        SelfTest.diagnostic("VOICE_LATENCY_FIXTURE=\(fixture.path)")
        SelfTest.diagnostic("VOICE_LATENCY_TTS=pocket island=\(islandOff ? "off" : "on") "
            + "speculation=\(speculation) runs=\(runs)")
        SelfTest.diagnostic("VOICE_LATENCY_PID=\(ProcessInfo.processInfo.processIdentifier)")
        if startDelay > 0 {
            SelfTest.diagnostic("VOICE_LATENCY_START_DELAY=\(startDelay)s")
            try? await Task.sleep(for: .seconds(startDelay))
        }
        MainActorStallProbe.shared.start()
        defer { MainActorStallProbe.shared.stop() }

        var counted: [VoiceClosedTurn] = []
        for index in 0...runs {
            let outcome = await oneRun(index: index, fixture: fixture)
            wrong += outcome.wrong
            if let turn = outcome.turn, index > 0 { counted.append(turn) }
            if outcome.fatal { break }
        }
        MainActorStallProbe.shared.stop()
        await capture.endSession(source: .done)

        if counted.isEmpty, wrong.isEmpty {
            wrong.append("no measured run produced a closed turn")
        }
        for (_, span) in columns {
            let values = counted.compactMap { $0.seconds(span) }
            SelfTest.diagnostic("VOICE_LATENCY_MEDIAN \(name(for: span))="
                + "\(Self.format(median(values))) p90=\(Self.format(p90(values))) "
                + "n=\(values.count)")
        }
        let stalls = counted.map(\.mainStallSeconds)
        SelfTest.diagnostic("VOICE_LATENCY_MEDIAN main_stall_max="
            + "\(Self.format(median(stalls))) p90=\(Self.format(p90(stalls))) "
            + "n=\(stalls.count)")
        if let worst = counted.max(by: { $0.mainStallSeconds < $1.mainStallSeconds }),
           worst.mainStallSeconds > maxStall {
            wrong.append(String(format: "main-actor stall %.3fs > %.3fs in turn %d (site %@)",
                worst.mainStallSeconds, maxStall, worst.number,
                worst.stallSite ?? "unlabelled"))
        }
        if let budget, let headline = median(counted.compactMap {
            $0.seconds(.voiceSpeechEndToFirstAudio)
        }), headline > budget {
            wrong.append(String(format: "median speech_end_to_first_audio %.3fs > budget %.3fs",
                headline, budget))
        }
        return finish(wrong)
    }

    // MARK: - One measured run

    private struct RunOutcome {
        let turn: VoiceClosedTurn?
        let wrong: [String]
        /// The session could not be run at all; every later run would fail the same way.
        var fatal: Bool { turn == nil }
    }

    private static func oneRun(index: Int, fixture: URL) async -> RunOutcome {
        let capture = AgentCaptureController.shared
        let speech = AgentSpeechSynthesizer.shared
        let priorPlaybackEvent = speech.onPlaybackEvent
        var firstAudioAcknowledged = false
        speech.onPlaybackEvent = { event in
            priorPlaybackEvent?(event)
            if case .startAcknowledged = event { firstAudioAcknowledged = true }
        }
        defer { speech.onPlaybackEvent = priorPlaybackEvent }
        MainActorStallProbe.shared.clearSamples()
        let turnsBefore = VoiceLatencyTimeline.shared.closedTurnsForTesting().count
        let prepareBefore = MetricsStore.shared.spans(named: .voiceEOUPrepare).count

        do {
            try await capture.beginFileSession(wav: fixture)
        } catch {
            return RunOutcome(turn: nil, wrong: ["run \(index): could not open the file-fed "
                + "voice session: \(error.localizedDescription)"])
        }
        let progress = capture.fileSessionProgress
        await progress.feed?.value
        if let failure = progress.feedFailure {
            return RunOutcome(turn: nil, wrong: ["run \(index): file feed: \(failure)"])
        }
        let deadline = Date().addingTimeInterval(55)
        while Date() < deadline,
              (capture.fileSessionProgress.committedTurns == 0 || capture.lastReply.isEmpty
                || !firstAudioAcknowledged) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The next run must start from silence, or the previous reply is measured twice.
        let quiet = Date().addingTimeInterval(20)
        while RealtimeAudioSession.shared.isSpeaking, Date() < quiet {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let reply = capture.lastReply
        await capture.endSession(source: .done)
        MetricsStore.shared.flushForTesting()
        UsageLog.shared.flush()

        let closed = VoiceLatencyTimeline.shared.closedTurnsForTesting().dropFirst(turnsBefore)
        let books = VoiceLatencyTimeline.shared.accounting()
        let openNumber = books.open.map(String.init) ?? "none"
        let openTurn = books.openTurnID.map { String($0.uuidString.prefix(8)) } ?? "none"
        let reasons = books.reasons.joined(separator: ",")
        let committed = capture.fileSessionProgress.committedTurns
        let endpoint = capture.lastEndpoint.rawValue
        let didHear = reply.isEmpty ? "no" : "yes"
        let heard = progress.heardWords ? "yes" : "no"
        SelfTest.diagnostic("VOICE_LATENCY_RUN=\(index) bookkeeping closed=\(closed.count)"
            + " open=\(openNumber) openTurn=\(openTurn)"
            + " discarded=\(books.discarded) (\(reasons))"
            + " endpoint=\(endpoint) committed=\(committed)"
            + " heard=\(heard) reply=\(didHear)")
        let orphans = VoiceLatencyTimeline.shared.orphanMarks()
        if !orphans.isEmpty {
            SelfTest.diagnostic("VOICE_LATENCY_ORPHANS run=\(index) "
                + orphans.joined(separator: ","))
        }
        for turn in closed {
            let id = turn.turnID.map { String($0.uuidString.prefix(8)) } ?? "none"
            let names = turn.marks.keys.map(\.rawValue).sorted().joined(separator: ",")
            SelfTest.diagnostic("VOICE_LATENCY_TURN run=\(index) n=\(turn.number)"
                + " reason=\(turn.reason) turn=\(id) marks=\(names)")
        }
        guard let turn = closed.last else {
            return RunOutcome(turn: nil, wrong: ["run \(index): no turn was recorded, so "
                + "nothing was measured"])
        }
        let eouPrepare = MetricsStore.shared.spans(named: .voiceEOUPrepare)
            .dropFirst(prepareBefore).last?.durationSeconds
        SelfTest.diagnostic(Self.line(index: index, turn: turn, eouPrepare: eouPrepare))
        SelfTest.diagnostic("VOICE_LATENCY_STORES run=\(index) "
            + "spans=\(MetricsStore.shared.spans(named: nil).count) "
            + "turnRows=\(UsageLog.shared.load().filter { $0.pass == "turn" }.count)")
        guard index > 0 else { return RunOutcome(turn: turn, wrong: []) }
        var wrong = validate(turn: turn, index: index, reply: reply)
        wrong += validateStore(turn: turn, index: index)
        wrong += validateUsageLog(turn: turn, index: index)
        return RunOutcome(turn: turn, wrong: wrong)
    }

    private static func line(
        index: Int, turn: VoiceClosedTurn, eouPrepare: Double?
    ) -> String {
        var parts = ["VOICE_LATENCY_RUN=\(index)"]
        if index == 0 { parts.append("kind=warmup") }
        for (name, span) in columns {
            parts.append("\(name)=\(Self.format(turn.seconds(span)))")
        }
        parts.append("speculation=\(turn.notes["speculation"] ?? "absent")")
        parts.append("main_stall_max=\(Self.format(turn.mainStallSeconds))")
        parts.append("stall_site=\(turn.stallSite ?? "unlabelled")")
        parts.append("eou_prepare=\(Self.format(eouPrepare))")
        parts.append("endpoint_source=\(turn.notes["endpoint_source"] ?? "absent")")
        parts.append("marks=\(turn.marks.count)")
        return parts.joined(separator: " ")
    }

    private static func name(for span: LatencySpanID) -> String {
        columns.first { $0.1 == span }?.0 ?? span.rawValue
    }

    // MARK: - The assertions a counted run must pass

    private static func validate(
        turn: VoiceClosedTurn, index: Int, reply: String
    ) -> [String] {
        var wrong: [String] = []
        for stage in VoiceStageSpan.all where stage.required {
            guard turn.seconds(stage.span) != nil else {
                wrong.append("run \(index): \(stage.span.rawValue) is absent — the stage did "
                    + "not happen, or its mark was never stamped")
                continue
            }
            if let seconds = turn.seconds(stage.span), seconds < 0 {
                wrong.append("run \(index): \(stage.span.rawValue) is negative")
            }
        }
        if turn.notes["endpoint_source"] != "localEOU" {
            wrong.append("run \(index): the endpoint came from "
                + "\(turn.notes["endpoint_source"] ?? "nothing"), not the local EOU model, so "
                + "the EOU stages in this run are not the ones a warm turn pays")
        }
        if reply.isEmpty { wrong.append("run \(index): the local frontend produced no answer") }
        return wrong
    }

    /// The spans reached the store, not only the in-memory turn. Without this the table
    /// would be a printout of something that was never written anywhere.
    private static func validateStore(turn: VoiceClosedTurn, index: Int) -> [String] {
        let stored = MetricsStore.shared.spans(named: nil).filter {
            $0.source == "voice" && $0.correlation?.sessionID == turn.sessionID
        }
        guard !stored.isEmpty else {
            return ["run \(index): no voice spans reached the metrics store for this turn"]
        }
        return VoiceStageSpan.all.compactMap { stage in
            guard stage.required, turn.seconds(stage.span) != nil else { return nil }
            guard !stored.contains(where: { $0.name == stage.span }) else { return nil }
            return "run \(index): \(stage.span.rawValue) was measured but not stored"
        }
    }

    /// The one-usage-log contract, checked per run: this turn's summary row is in
    /// `usage.jsonl` and the per-pass frontend rows share its `turnID`. Without the join the
    /// log answers "which model answered" and "how long did the turn take" about two
    /// different turns.
    private static func validateUsageLog(turn: VoiceClosedTurn, index: Int) -> [String] {
        var wrong: [String] = []
        let rows = UsageLog.shared.load()
        let summaries = rows.filter {
            $0.pass == "turn" && $0.feature == UsageFeature.agentVoice.rawValue
                && $0.turnID == turn.turnID
        }
        guard summaries.count == 1 else {
            return ["run \(index): expected exactly one agent.voice/turn row for this turn, "
                + "got \(summaries.count)"]
        }
        let summary = summaries[0]
        for stage in VoiceStageSpan.all where stage.inTurnSummary {
            let key = stage.span.rawValue.replacingOccurrences(of: "voice.", with: "")
            if turn.seconds(stage.span) != nil, summary.stages?[key] == nil {
                wrong.append("run \(index): the turn row is missing stage \(key)")
            }
        }
        let passes = rows.filter {
            $0.feature == UsageFeature.agentVoice.rawValue && $0.turnID == turn.turnID
                && $0.pass != "turn"
        }
        if turn.marks[.frontendFirstToken] != nil, passes.isEmpty {
            wrong.append("run \(index): the frontend answered but no agent.voice pass row "
                + "shares the turn's id")
        }
        if let ttft = summary.ttftMs, let measured = turn.seconds(.voiceTranscriptToFirstToken),
           abs(Double(ttft) / 1_000 - measured) > 0.002 {
            wrong.append("run \(index): the turn row's ttft \(ttft)ms disagrees with the "
                + "measured span \(Self.format(measured))s")
        }
        return wrong
    }

    // MARK: - The pure cases, before any pipeline run

    /// A complete turn produces every required stage, in the store as well as in memory.
    private static func selfTestEmission() -> [String] {
        let timeline = VoiceLatencyTimeline()
        timeline.beginSession(UUID())
        stampCompleteTurn(timeline)
        timeline.mark(.firstAudible)
        guard let turn = timeline.closedTurnsForTesting().last else {
            return ["emission case: a complete turn wrote no turn at all"]
        }
        var problems = VoiceStageSpan.all.compactMap { stage -> String? in
            guard stage.required, turn.seconds(stage.span) == nil else { return nil }
            return "emission case: \(stage.span.rawValue) is missing from a complete turn"
        }
        MetricsStore.shared.flushForTesting()
        let stored = Set(MetricsStore.shared.spans(named: nil).map(\.name))
        for stage in VoiceStageSpan.all where stage.required && !stored.contains(stage.span) {
            problems.append("emission case: \(stage.span.rawValue) was never written to the "
                + "store")
        }
        return problems
    }

    /// The absent case, which is the one that matters: a turn with no PCM mark produces no
    /// PCM spans, and the missing rows stay missing rather than becoming zeros.
    private static func selfTestAbsentStages() -> [String] {
        let timeline = VoiceLatencyTimeline()
        timeline.beginSession(UUID())
        stampCompleteTurn(timeline, tts: false)
        timeline.mark(.firstAudible)
        guard let turn = timeline.closedTurnsForTesting().last else {
            return ["absent case: a turn with no PCM mark wrote no turn at all"]
        }
        var problems: [String] = []
        // No PCM mark: the two synthesis stages are absent and nothing else is.
        for span in [LatencySpanID.voiceClauseToFirstPCM, .voiceFirstPCMToAudible]
        where turn.seconds(span) != nil {
            problems.append("absent case: \(span.rawValue) was written for a turn that never "
                + "produced PCM")
        }
        // First audio did happen, so the headline is real even without a PCM stage.
        if turn.seconds(.voiceSpeechEndToFirstAudio) == nil {
            problems.append("absent case: speech_end_to_first_audio went missing because a "
                + "synthesis stage did not happen")
        }
        for span in [LatencySpanID.voiceSpeechEndToEndpoint, .voiceEndpointToRequest,
                     .voiceSpeechEndToEOU] where turn.seconds(span) == nil {
            problems.append("absent case: \(span.rawValue) went missing because a later stage "
                + "did not happen")
        }
        return problems
    }

    /// A discarded utterance writes nothing at all: no spans, no summary row, no turn.
    private static func selfTestDiscard() -> [String] {
        let timeline = VoiceLatencyTimeline()
        timeline.beginSession(UUID())
        stampCompleteTurn(timeline, endpoint: false)
        UsageLog.shared.flush()
        let rowsBefore = UsageLog.shared.load().filter { $0.pass == "turn" }.count
        timeline.discardTurn("selftest")
        timeline.mark(.firstAudible)
        UsageLog.shared.flush()
        var problems: [String] = []
        if !timeline.closedTurnsForTesting().isEmpty {
            problems.append("discard case: a discarded turn was still written")
        }
        let books = timeline.accounting()
        if books.discarded != 1 {
            problems.append("discard case: the discard was not counted (\(books.discarded))")
        }
        if UsageLog.shared.load().filter({ $0.pass == "turn" }).count != rowsBefore {
            problems.append("discard case: a discarded turn wrote a usage row")
        }
        return problems
    }

    /// A turn that never produced audio still gets its row, marked incomplete, and no
    /// headline stage — the honest shape for a turn that stopped.
    private static func selfTestUsageRow() -> [String] {
        let timeline = VoiceLatencyTimeline()
        timeline.beginSession(UUID())
        let turnID = UUID()
        stampCompleteTurn(timeline, turnID: turnID)
        timeline.endSession()
        UsageLog.shared.flush()
        guard let row = UsageLog.shared.load().filter({
            $0.pass == "turn" && $0.turnID == turnID
        }).last else {
            return ["usage row case: a turn with no first audio wrote no row"]
        }
        var problems: [String] = []
        if row.truncated != true || row.finishReason != "incomplete" {
            problems.append("usage row case: a turn with no first audio is not marked "
                + "incomplete (finishReason \(row.finishReason ?? "nil"))")
        }
        if row.stages?["speech_end_to_first_audio"] != nil {
            problems.append("usage row case: a turn with no first audio carries a "
                + "speech_end_to_first_audio stage")
        }
        if row.stages?["speech_end_to_endpoint"] == nil {
            problems.append("usage row case: a turn with no first audio lost the stage it did "
                + "measure")
        }
        return problems
    }

    /// A turn with every mark, on a timeline of its own so the shared one stays clean.
    /// `endpoint: false` stops before the commit, which is the shape a turn the capture
    /// controller throws away always has.
    private static func stampCompleteTurn(
        _ timeline: VoiceLatencyTimeline, tts: Bool = true, endpoint: Bool = true,
        turnID: UUID = UUID()
    ) {
        var at = VoiceLatencyTimeline.nowNanos()
        func step(_ gap: UInt64) { at &+= gap }
        timeline.mark(.voiceOnset, at: at)
        // The ids are attached once the turn is open, exactly as the coordinator does it
        // after the endpoint — an attach before the onset has no turn to land on.
        timeline.attachTurnIDs(turnID: turnID, conversationID: UUID())
        step(120_000_000)
        timeline.mark(.lastVoice, at: at, overwrite: true)
        step(900_000_000)
        timeline.mark(.eouRaw, at: at)
        step(1_000_000)
        timeline.mark(.eouCallback, at: at)
        step(40_000_000)
        timeline.mark(.eouConfirmed, at: at)
        guard endpoint else { return }
        step(5_000_000)
        timeline.mark(.endpoint, at: at)
        timeline.note("endpoint_source", "localEOU")
        step(2_000_000)
        timeline.mark(.frontendRequest, at: at)
        step(1_000_000)
        timeline.mark(.schedulerAcquired, at: at)
        timeline.note("speculation", "miss reason=no-slot")
        step(600_000_000)
        timeline.mark(.routeDone, at: at)
        step(400_000_000)
        timeline.mark(.frontendFirstToken, at: at)
        step(1_000_000)
        timeline.mark(.firstClauseEnqueued, at: at)
        if tts {
            step(250_000_000)
            timeline.mark(.ttsFirstPCM, at: at)
        }
        timeline.noteStall(nanos: 7_000_000, site: "selftest.stall")
    }

    // MARK: - Numbers

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[mid - 1] + sorted[mid]) / 2 }
        return sorted[mid]
    }

    static func p90(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.9).rounded()))
        return sorted[index]
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.3f", value)
    }

    static var defaultFixture: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NextNotesBuild/voice-fixtures/haiku16k.wav")
    }

    /// Where FluidAudio keeps the Pocket TTS models on this Mac. Read only: a self-test
    /// never triggers a download, so an absent model is ABSENT rather than a wait.
    static func pocketModelDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models/pocket-tts", isDirectory: true)
    }

    // MARK: - The verdict

    private static func finish(_ wrong: [String]) -> Result {
        for problem in wrong { SelfTest.diagnostic("VOICE_LATENCY_WRONG: \(problem)") }
        guard let first = wrong.first else { return (true, "VOICE_LATENCY_OK") }
        return (false, "VOICE_LATENCY_FAILED: \(first)")
    }

    private static func absent(_ reason: String) -> Result {
        // ABSENT is a skip, not a pass and not a failure: the precondition is missing, so
        // nothing was tested and nothing is claimed.
        SelfTest.diagnostic("VOICE_LATENCY_ABSENT: \(reason)")
        return (false, "VOICE_LATENCY_ABSENT: \(reason)")
    }
}

/// The probe's own accuracy, measured before any production stall is believed: block the
/// main actor for a known interval inside a labelled section and require the probe to
/// report that interval, and that label.
///
/// A stall attributed to the wrong site is worse than an unattributed one, so this is the
/// case that keeps the attribution honest. The busy loop is inside the self-test and
/// nowhere else: it is the measurement, not a pause on a person's turn.
enum MainActorStallProbeSelfTest {
    static let blockSeconds = 0.20
    static let tolerance: Double = 0.12

    @MainActor
    static func run() async -> [String] {
        let probe = MainActorStallProbe.shared
        probe.clearSamples()
        probe.start()
        let before = VoiceLatencyTimeline.nowNanos()
        MainActorSection.run("selftest.block") {
            let until = Date().addingTimeInterval(blockSeconds)
            while Date() < until { _ = (0..<4_000).reduce(0, +) }
        }
        // Suspend rather than block: a blocked main thread cannot drain the main queue, so
        // the ping would never land and the probe would read as perfect.
        try? await Task.sleep(for: .milliseconds(150))
        let worst = probe.maxLatenessSeconds(since: before)
        probe.stop()
        var problems: [String] = []
        if abs(worst.seconds - blockSeconds) > tolerance {
            problems.append(String(format: "stall probe case: a %.0fms main-actor block "
                + "measured %.0fms, outside ±%.0fms", blockSeconds * 1_000,
                worst.seconds * 1_000, tolerance * 1_000))
        }
        if worst.site != "selftest.block" {
            problems.append("stall probe case: the worst stall was attributed to "
                + "\(worst.site ?? "nothing"), not the section that blocked")
        }
        return problems
    }
}
