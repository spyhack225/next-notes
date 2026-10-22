import FluidAudio
import Foundation
import Observation

/// The one place speakers are identified, whether the meeting just ended or the user asked
/// again from the detail view.
///
/// The same shape as `NotesService`, and for the same reason: two callers each running their
/// own clustering pass would put two copies of the segmentation and embedding models on a
/// 16 GB machine that is already holding Parakeet.
@MainActor
@Observable
final class DiarizationService {
    static let shared = DiarizationService()

    /// How far through the segmentation pass each running meeting is, 0…1.
    private(set) var progress: [UUID: Double] = [:]
    /// The last failure per meeting, for the banner in the detail view.
    private(set) var problems: [UUID: String] = [:]
    /// A decision to *not* identify speakers, and why. Separate from
    /// `problems` on purpose: the failure slot is what holds a recording for a
    /// retry and what keeps the retention sweep away from a file, and a
    /// meeting that was refused needs neither. A refusal is shown, and it
    /// offers no retry, because retrying it would refuse again.
    private(set) var refusals: [UUID: String] = [:]
    /// Bumped whenever a transcript's speaker labels change, so a view showing them knows to
    /// re-read. `MeetingStore` caches transcripts, and nothing else observes that cache.
    private(set) var revision = 0

    private struct OwnedTask {
        let binding: UUID
        let handle: Task<Void, Never>
        let onStallForTesting: (@MainActor () -> Void)?
        var watchdogFallback = false
    }
    @ObservationIgnored private var tasks: [UUID: OwnedTask] = [:]
    @ObservationIgnored private var terminationRequested = false
    @ObservationIgnored private var terminationFixtureID: UUID?
    @ObservationIgnored private var terminationFixtureTrace: DiarizationTerminationTrace?

    func configureTerminationFixture(id: UUID, store: MeetingStore,
                                     trace: DiarizationTerminationTrace) throws {
        guard NativeDiarizationQuitSelfTest.isRequested, self === Self.shared,
              store === MeetingStore.shared, tasks.isEmpty, terminationFixtureTrace == nil,
              NativeDiarizationQuitSelfTest.isConfinedMeetingStore(store) else {
            throw CocoaError(.fileReadNoPermission)
        }
        terminationFixtureID = id; terminationFixtureTrace = trace
    }
    func ownedTerminationTaskForTesting(id: UUID) -> Task<Void, Never>? {
        guard NativeDiarizationQuitSelfTest.isRequested, id == terminationFixtureID else { return nil }
        return tasks[id]?.handle
    }
    func triggerActualWatchdogForTesting(id: UUID) -> Bool {
        guard NativeDiarizationQuitSelfTest.isRequested, id == terminationFixtureID,
              let operation = tasks[id]?.onStallForTesting else { return false }
        operation(); return true
    }
    // COMMON nil/no-op original bodies retain its actual cancellation/handoff.
    func beginTermination() -> [Task<Void, Never>] {
        terminationRequested = true
        let owned = tasks.values.map(\.handle)
        terminationFixtureTrace?.captured(count: owned.count)
        for task in owned { task.cancel() }
        return owned
    }
    func finishTermination(_ owned: [Task<Void, Never>]) async {
        for task in owned { await task.value }
    }
    private func acceptsOwner(_ id: UUID, _ binding: UUID) -> Bool {
        guard !terminationRequested, let owned = tasks[id] else { return false }
        return owned.binding == binding && !owned.handle.isCancelled
    }
    private func permitsHandoff(_ id: UUID, _ binding: UUID) -> Bool {
        guard !terminationRequested, let owned = tasks[id], owned.binding == binding else { return false }
        return !owned.handle.isCancelled || owned.watchdogFallback
    }
    private func markWatchdogFallback(_ id: UUID, _ binding: UUID) -> Bool {
        guard acceptsOwner(id, binding) else { return false }
        tasks[id]?.watchdogFallback = true
        return true
    }
    private func releaseOwner(_ id: UUID, _ binding: UUID) {
        guard tasks[id]?.binding == binding else { return }
        tasks[id] = nil; progress[id] = nil; lastProgressAt[id] = nil
    }
    private func applyProgress(_ id: UUID, _ binding: UUID, _ fraction: Double) {
        guard acceptsOwner(id, binding) else { return }
        noteProgress(id); progress[id] = fraction
    }
    /// The stall watchdog's clock: when each running pass last reported progress
    /// (M-08). Advanced beside every `progress[id]` write, never on its own.
    @ObservationIgnored private var lastProgressAt: [UUID: Date] = [:]

    // Retain an explicitly injected store; resolving the default happens only
    // when real service work needs it, so quit can close an empty owner cheaply.
    private let providedStore: MeetingStore?
    private let providedContextStore: MeetingContextStore?
    private var store: MeetingStore { providedStore ?? MeetingStore.shared }

    init(store: MeetingStore? = nil, contextStore: MeetingContextStore? = nil) {
        providedStore = store
        providedContextStore = contextStore
    }

    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }
    func fraction(for id: UUID) -> Double? { progress[id] }
    /// A failure that is worth another try. Never a refusal.
    func problem(for id: UUID) -> String? { problems[id] }
    /// A decision to not identify speakers, and the reason. Shown to the
    /// person; never holds the recording and never offers a retry.
    func refusal(for id: UUID) -> String? { refusals[id] }

    /// Advances the watchdog's clock for one pass.
    private func noteProgress(_ id: UUID) { lastProgressAt[id] = Date() }

    /// Dismissing the banner also withdraws the retry it was offering, which is what
    /// `MeetingStore.releaseAudio` was holding the recording for.
    func clearProblem(for id: UUID) {
        problems[id] = nil
        refusals[id] = nil
        store.releaseAudio(for: id)
    }

    /// Withdraws a refusal, which is what dismissing its banner does.
    func clearRefusal(for id: UUID) {
        refusals[id] = nil
    }

    /// The automatic pipeline path's refusal, recorded so the detail view's banner
    /// says why the speakers won't be told apart instead of leaving "Others"
    /// unexplained. Same admission as a run: a live pass owns the problem slot.
    func noteRefusal(_ id: UUID, decision: DiarizationEligibility.Decision) {
        guard !terminationRequested, tasks[id] == nil, let message = decision.problem else { return }
        refusals[id] = message
    }

    /// Identifies speakers and then hands the meeting to whatever comes next.
    ///
    /// Returns immediately. The session that called it is already gone by the time the first
    /// window has been clustered — that is the point.
    func process(_ meeting: Meeting) {
        run(meeting) { [weak self] in
            guard let self, let updated = store.meeting(id: meeting.id) else { return }
            MeetingPipeline.afterDiarizing(updated, store: store)
        }
    }

    /// Identifies speakers on a meeting that has already finished, leaving its status alone.
    ///
    /// What the detail view's "Identify speakers" calls: a finished meeting shouldn't fall
    /// back through the pipeline and rewrite notes that are already there.
    func identifySpeakers(in meeting: Meeting) {
        run(meeting) { [weak self] in
            // A pass that succeeded is the last thing that needed the recording. One that
            // failed leaves a problem set, and `releaseAudio` holds the audio for as long as
            // the banner is still offering another try.
            self?.store.releaseAudio(for: meeting.id)
        }
    }

    /// Identifies speakers with an exact count the person set (M-03).
    ///
    /// The speaker sheet's "Identify again" stepper. A count from someone who was in the
    /// call is not a hint the model may overrule, which is why it travels as
    /// `numSpeakers` — an exact target — and not as a bound. Everything else is the
    /// "Identify speakers" path untouched.
    func reidentify(_ meeting: Meeting, speakers: Int) {
        run(meeting, forcedSpeakers: max(1, speakers)) { [weak self] in
            self?.store.releaseAudio(for: meeting.id)
        }
    }

    /// Stops a pass that is no longer wanted. Deleting the meeting is the case that matters.
    func cancel(_ id: UUID) {
        tasks[id]?.watchdogFallback = false
        tasks[id]?.handle.cancel()
        // Retain exact native owner until its actual Task defer. Progress withdraws.
        progress[id] = nil
        lastProgressAt[id] = nil
    }

    // MARK: - The work

    private func run(
        _ meeting: Meeting,
        forcedSpeakers: Int? = nil,
        then next: @escaping @MainActor () -> Void
    ) {
        let id = meeting.id
        guard !terminationRequested, tasks[id] == nil else { return }
        let binding = UUID()
        noteProgress(id)

        // M-08: a clustering pass that stops reporting progress is stopped rather than
        // left showing "Identifying speakers…" until the next launch. The problem holds
        // the recording (`releaseAudio` refuses to drop audio while one is set), and the
        // pipeline continues with the labels it has — a diarization that failed never
        // blocked the notes.
        let onStall: @MainActor () -> Void = { [weak self] in
                guard let self, self.markWatchdogFallback(id, binding) else { return }
                let since = Date().timeIntervalSince(self.lastProgressAt[id] ?? .distantPast)
                Log.meeting.error("""
                    diarize stalled · \(Int(since), privacy: .public)s without progress \
                    on "\(meeting.title, privacy: .public)"
                    """)
                self.problems[id] = StageWatchdog.stallMessage
                self.tasks[id]?.handle.cancel()
        }
        let watchdog = StageWatch(
            limit: StageWatchdog.diarizeLimit,
            lastProgress: { [weak self] in self?.lastProgressAt[id] ?? .distantPast },
            isLaneBusy: { await StageWatchdog.urgentLaneBusy() },
            onStall: onStall
        )
        watchdog.start()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                watchdog.cancel()
                if id == self.terminationFixtureID { self.terminationFixtureTrace?.ended() }
                self.releaseOwner(id, binding)
            }
            await diarize(id, binding: binding, forcedSpeakers: forcedSpeakers)
            guard self.permitsHandoff(id, binding) else { return }
            if id == self.terminationFixtureID { self.terminationFixtureTrace?.handoff() }
            next()
        }
        tasks[id] = OwnedTask(binding: binding, handle: task,
            onStallForTesting: NativeDiarizationQuitSelfTest.isRequested ? onStall : nil)
        if id == terminationFixtureID { terminationFixtureTrace?.assigned() }
    }

    /// The shortest track `MeetingDiarizer.speakerRuns` clusters. Mirrors that actor's own
    /// gate: below it the models are not worth loading, and awaiting `prepare()` here would
    /// make a short meeting wait on a download it will never use.
    private static let minimumDiarizableSeconds: TimeInterval = 2
    /// Below this the diarizer was already in memory: `prepare()` returns without loading.
    /// A model load is seconds of CoreML compilation, so the two cases cannot be confused.
    private static let diarizerLoadThresholdMs = 50
    /// The engine id the `meeting.diarize` row reports — FluidAudio's model folder.
    private static let diarizerModelID = "speaker-diarization"

    /// - Parameters:
    ///   - forcedSpeakers: an exact count a person set from the speaker sheet (M-03).
    ///     nil clusters with whatever hint the meeting's own shape supports.
    /// - Returns: whether any speaker label was written.
    @discardableResult
    private func diarize(_ id: UUID, binding: UUID, forcedSpeakers: Int? = nil) async -> Bool {
        let began = ContinuousClock.now
        var audioSeconds = 0.0
        var runsCount = 0
        var speakersCount = 0
        var errorClass: UsageErrorClass?
        var errorMessage: String?
        var warm: Bool?
        var loadMs: Int?
        var hint: SpeakerCountHint?
        // P0-20b: one `meeting.diarize` row on every exit, built from whatever this pass
        // learned. `defer` rather than a call per return path, so a new `return false`
        // added later cannot quietly lose the row.
        defer {
            recordDiarize(
                meetingID: id,
                totalMs: ModelPassRecorder.milliseconds(began.duration(to: .now)),
                audioSeconds: audioSeconds,
                runs: runsCount,
                speakers: speakersCount,
                hint: hint,
                errorClass: errorClass,
                errorMessage: errorMessage,
                warm: warm,
                loadMs: loadMs
            )
        }

        guard acceptsOwner(id, binding), let meeting = store.meeting(id: id) else { return false }
        // The same eligibility the automatic pipeline path runs, before the diarizer
        // loads: known lost remote audio is refused in plain words instead of
        // reaching the clusterer and coming back "No speech detected in audio".
        var audio: URL?
        let eligibility = DiarizationEligibility.admit(
            captureIntegrity: meeting.captureIntegrity,
            hasAudio: store.audioURL(for: meeting) != nil,
            recordingSeconds: meeting.captureIntegrity?.recordedSeconds
        ) { audio = store.audioURL(for: meeting) }
        guard eligibility == .run, let audio else {
            let message = eligibility.problem ?? DiarizationError.noAudio.localizedDescription
            // A refusal replaces whatever was there: a failed attempt followed by
            // a refused one must not leave two banners, and the recording must
            // not be held for a failure that is no longer current.
            problems[id] = nil
            refusals[id] = message
            errorClass = .other
            errorMessage = message
            return false
        }

        progress[id] = 0
        problems[id] = nil
        refusals[id] = nil
        noteProgress(id)
        // M-16a: the diarization pass is a stage span. The note carries runs,
        // speakers and audio seconds, or the error's type name — never the
        // message, which can contain a path.

        // Routed through the model store as well as awaited below, so that a first meeting
        // which triggers the download shows it in Settings rather than looking like a
        // clustering pass that has stalled. Both calls land on the same in-flight load
        // inside the actor, so the models are still fetched once.
        LocalModelStore.shared.prepareDiarizer()

        do {
            // The system channel alone. Mixing the microphone back in would hand the
            // clusterer the user's own voice as a speaker in a track whose entire purpose is
            // to contain everyone else.
            let samples: [Float]
            let boundedSamples: (any AudioSampleSource)?
            if AudioConversion.usesBoundedMeetingAudioExperiment {
                let range = try AudioConversion.meetingSampleSource(
                    fromFileAt: audio, channel: MeetingAudioWriter.systemChannel)
                boundedSamples = range
                samples = []
                audioSeconds = Double(range.sampleCount) / ChunkedTranscriber.sampleRate
            } else {
                boundedSamples = nil
                samples = try AudioConversion.samples(
                    fromFileAt: audio,
                    sampleRate: ChunkedTranscriber.sampleRate,
                    channel: MeetingAudioWriter.systemChannel
                )
                audioSeconds = Double(samples.count) / ChunkedTranscriber.sampleRate
            }

            // P0-20b: awaiting the load here is what makes `warm`/`loadMs` measurable; for a
            // track `speakerRuns` will cluster, that call does exactly this load anyway.
            if audioSeconds >= Self.minimumDiarizableSeconds {
                let prepareBegan = ContinuousClock.now
                try await MeetingDiarizer.shared.prepare()
                guard acceptsOwner(id, binding) else { throw CancellationError() }
                let prepareMs = ModelPassRecorder.milliseconds(prepareBegan.duration(to: .now))
                if prepareMs >= Self.diarizerLoadThresholdMs {
                    warm = false
                    loadMs = prepareMs
                } else {
                    warm = true
                }
            }

            // M-03: a person's exact count is the answer, not a bound; a hint read from
            // the meeting's own shape is a bound the clustering may still beat. A
            // browser, an unknown app and a meeting with no attendees get neither.
            hint = forcedSpeakers.map { SpeakerCountHint(numSpeakers: $0) }
                ?? SpeakerCountHint.for(meeting)
            guard acceptsOwner(id, binding) else { throw CancellationError() }
            let reportProgress: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let operation: @MainActor () -> Void = { [weak self] in
                        self?.applyProgress(id, binding, fraction)
                    }
                    if id == self.terminationFixtureID,
                       self.terminationFixtureTrace?.holdFirstProgress(operation) == true { return }
                    operation()
                }
            }
            let runs: [MeetingDiarizer.SpeakerRun]
            if let boundedSamples {
                runs = try await MeetingDiarizer.shared.speakerRuns(in: boundedSamples, hint: hint, progress: reportProgress)
            } else {
                runs = try await MeetingDiarizer.shared.speakerRuns(in: samples, hint: hint, progress: reportProgress)
            }
            runsCount = runs.count
            guard acceptsOwner(id, binding) else { throw CancellationError() }
            try Task.checkCancellation()
            guard !runs.isEmpty else {
                refusals[id] = DiarizationEligibility.noRunsMessage(
                    captureIntegrity: meeting.captureIntegrity)
                Log.meeting.info("diarization found no speech on the system track")
                LatencyTrace.record(
                    .meetingDiarize,
                    seconds: ChunkedTranscriber.seconds(began.duration(to: .now)),
                    note: "runs=0 speakers=0 audio=\(String(format: "%.1f", audioSeconds))s"
                )
                return false
            }

            let labelled = MeetingDiarizer.assign(store.transcript(for: id), to: runs)
            // Deletion while the model awaited must stop the entire native stage,
            // including its later voice-print writes and pipeline handoff.
            guard store.meeting(id: id) != nil else { return false }
            try commitSpeakerLabels(labelled, for: id)
            // Voice prints only while the knowledge graph is on: nothing else reads them.
            if PersonResolutionService.shared.isEnabled {
                let prints = MeetingVoicePrints.centroids(of: runs)
                do {
                    if prints.speakers.isEmpty {
                        // Old prints would carry labels this transcript no longer uses.
                        MeetingVoicePrints.remove(directory: store.directory(for: id))
                    } else {
                        try prints.write(directory: store.directory(for: id))
                    }
                    PersonResolutionService.shared.scheduleResolve()
                } catch {
                    Log.meeting.error("voice prints not written: \(error.localizedDescription, privacy: .public)")
                }
            }

            speakersCount = MeetingDiarizer.labels(in: labelled).count
            LatencyTrace.record(
                .meetingDiarize,
                seconds: ChunkedTranscriber.seconds(began.duration(to: .now)),
                note: "runs=\(runs.count) speakers=\(speakersCount) audio=\(String(format: "%.1f", audioSeconds))s"
            )
            Log.meeting.info("""
                diarized "\(meeting.title, privacy: .public)" — \
                \(speakersCount, privacy: .public) speaker(s) on the system track
                """)
            return speakersCount > 0
        } catch is CancellationError {
            errorClass = .cancelled
            return false
        } catch {
            guard acceptsOwner(id, binding) else { return false }
            errorClass = UsageErrorClass.classify(error)
            errorMessage = error.localizedDescription
            LatencyTrace.record(
                .meetingDiarize,
                seconds: ChunkedTranscriber.seconds(began.duration(to: .now)),
                note: "error=\(type(of: error))"
            )
            // The engine's own words — a model name, a batch size, a file path
            // — are for the log, not for a person reading a banner.
            problems[id] = DiarizationEligibility.problemMessage(for: error)
                ?? DiarizationEligibility.engineUnavailableMessage
            Log.meeting.error("diarization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The committed-label handoff, shared by actual diarization and its isolated
    /// consumer regression. It never creates a deleted meeting or projects unsaved labels.
    func commitSpeakerLabels(_ labelled: [TranscriptSegment], for id: UUID) throws {
        guard store.meeting(id: id) != nil else { return }
        guard store.saveTranscript(labelled, for: id) else {
            throw CocoaError(.fileWriteUnknown)
        }
        revision += 1
        let surviving = Set(MeetingDiarizer.labels(in: labelled))
        if var updated = store.meeting(id: id) {
            let merged = Self.mergedSpeakerNames(updated.speakerNames, labels: surviving)
            if merged != updated.speakerNames {
                updated.speakerNames = merged
                store.save(updated)
            }
        }
        // An injected isolated store must never initialize the owner's singleton.
        if let providedContextStore {
            guard providedContextStore.refreshSpeakers(meetingID: id) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } else if providedStore == nil {
            guard MeetingContextStore.shared.refreshSpeakers(meetingID: id) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    /// One `meeting.diarize` row. Counts only — never a title, a speaker name or a path.
    private func recordDiarize(
        meetingID: UUID,
        totalMs: Int,
        audioSeconds: Double,
        runs: Int,
        speakers: Int,
        hint: SpeakerCountHint?,
        errorClass: UsageErrorClass?,
        errorMessage: String?,
        warm: Bool?,
        loadMs: Int?
    ) {
        var counts = ["speakers": speakers, "runs": runs]
        // Counts only, per the schema — the shape of the constraint, never the meeting
        // that produced it.
        if let maxSpeakers = hint?.maxSpeakers { counts["maxSpeakers"] = maxSpeakers }
        if let numSpeakers = hint?.numSpeakers { counts["numSpeakers"] = numSpeakers }
        UsageLog.shared.record(UsageRecord(
            v: 1,
            id: UUID(),
            ts: Date(),
            feature: UsageFeature.meetingDiarize.rawValue,
            pass: "cluster",
            round: nil,
            provider: UsageProvider.diarizer.rawValue,
            modelID: Self.diarizerModelID,
            locality: "local",
            requestedRole: nil,
            requestedModel: nil,
            fallbackReason: nil,
            warm: warm,
            loadMs: loadMs,
            promptTokens: nil,
            cachedTokens: nil,
            completionTokens: nil,
            reasoningTokens: nil,
            countsEstimated: nil,
            ttftMs: nil,
            totalMs: totalMs,
            tokensPerSec: nil,
            finishReason: errorClass == nil ? "stop" : "error",
            truncated: nil,
            toolsProposed: nil,
            toolsExecuted: nil,
            errorClass: errorClass?.rawValue,
            errorMessage: errorMessage.map(UsageLog.sanitise),
            audioSeconds: audioSeconds,
            realtimeFactor: audioSeconds > 0
                ? Double(totalMs) / 1_000 / audioSeconds
                : nil,
            stages: nil,
            counts: counts,
            turnID: nil,
            conversationID: nil,
            workID: nil,
            revision: nil,
            meetingID: meetingID,
            dictationRunID: nil,
            scheduleID: nil
        ))
    }

    /// What of the person's saved name map survives a labelling pass: every label
    /// the pass still uses keeps its name, a label the pass retired is pruned, and
    /// a label nobody has named yet gains no entry. Pure so the self-test can pin
    /// the over-split merge without a store or a model.
    nonisolated static func mergedSpeakerNames(
        _ prior: [String: String], labels: Set<String>
    ) -> [String: String] {
        prior.filter { labels.contains($0.key) }
    }
}

/// One eligibility decision, shared by the automatic pipeline path and both
/// manual ones (MR-06). Three states, kept apart on purpose:
///
/// - `.run` — the other speakers' saved audio is intact enough to cluster.
/// - `.refuseIncompleteRemoteAudio` — known capture loss on the system track.
///   Without this the clusterer would return nothing and the person would be
///   told "No speech detected in audio", which is a lie about a recording
///   problem.
/// - `.refuseNoAudio` — no saved audio at all: a live-only meeting.
///
/// After this gate a genuine "no speech" from the clusterer can only mean the
/// saved other-speakers track was present, intact and silent — a different
/// sentence for a different fact.
enum DiarizationEligibility {
    enum Decision: Equatable, Sendable {
        case run
        case refuseIncompleteRemoteAudio
        case refuseNoAudio

        var problem: String? {
            switch self {
            case .run: nil
            case .refuseIncompleteRemoteAudio: DiarizationEligibility.refuseIncompleteRemoteAudioMessage
            case .refuseNoAudio: DiarizationError.noAudio.localizedDescription
            }
        }
    }

    /// The other speakers' audio from this meeting was not fully saved, so
    /// speakers can't be told apart reliably.
    ///
    /// Nothing is said about the person's own audio: the microphone can be
    /// short too, and a sentence claiming otherwise is a sentence that can be
    /// false.
    static let refuseIncompleteRemoteAudioMessage =
        "The other speakers' audio from this meeting was not fully saved, so speakers can't be told apart reliably."
    /// No speech was found in the other speakers' audio, so they couldn't be
    /// told apart. The engine's own "No speech detected in audio" reaches the
    /// banner only when this sentence is wrong about it.
    static let noChannelSpeechMessage =
        "No speech was found in the other speakers' audio, so they couldn't be told apart."

    /// The share of a recording that has to be missing before the whole meeting
    /// loses its speaker attribution.
    ///
    /// Below it the pass still runs: the intact part of the track is worth
    /// identifying, and the damaged part is already disclosed by the coverage
    /// facts. Above it, the survivors would be a sample of the call presented
    /// as the call, and the person would read a partial answer as a whole one.
    static let materialLossFraction = 0.2

    static func decision(
        for source: AudioSource = .system,
        captureIntegrity: MeetingCaptureIntegrity?,
        hasAudio: Bool,
        recordingSeconds: TimeInterval? = nil
    ) -> Decision {
        guard hasAudio else { return .refuseNoAudio }
        guard captureIntegrity?.hasKnownSavedAudioLoss(on: source) == true else { return .run }
        // A loss whose extent is measured, and small, does not take the whole
        // meeting's attribution with it. The loss is the tail after the
        // boundary — the part that is not in the recording — and the fraction
        // is of the recording's own length.
        if let boundary = boundarySeconds(captureIntegrity, source: source),
           let recordingSeconds, recordingSeconds > 0 {
            let lost = max(0, recordingSeconds - boundary)
            if lost / recordingSeconds < materialLossFraction { return .run }
        }
        return .refuseIncompleteRemoteAudio
    }

    /// The position on the recording's own clock at which a track stopped
    /// carrying real audio, when the producer measured one.
    ///
    /// This is where the track goes quiet, not how much was lost: the loss is
    /// everything after it.
    static func boundarySeconds(
        _ integrity: MeetingCaptureIntegrity?,
        source: AudioSource
    ) -> TimeInterval? {
        guard let integrity else { return nil }
        let rate = ChunkedTranscriber.sampleRate
        guard rate > 0 else { return nil }
        // The EARLIEST boundary on the track: a loss that starts earlier is the
        // one that bounds what the track covers, and the coverage evaluator,
        // the diarizer and the notes all read this number.
        var samples: [Int64] = []
        if source == .system, let silent = integrity.systemSilentAfterSample {
            samples.append(silent)
        }
        for warning in integrity.coverageWarnings ?? []
        where warning.track == source && warning.kind.isSavedLoss {
            samples.append(warning.atSample)
        }
        guard let earliest = samples.min() else { return nil }
        return TimeInterval(earliest) / rate
    }

    /// The one admission hop: `load` runs only when the meeting may be
    /// diarized, so a refused meeting never reaches the diarizer's first read.
    /// The self-test's spy closure proves it; production's load resolves the
    /// audio URL.
    static func admit(
        for source: AudioSource = .system,
        captureIntegrity: MeetingCaptureIntegrity?,
        hasAudio: Bool,
        recordingSeconds: TimeInterval? = nil,
        load: () -> Void
    ) -> Decision {
        let outcome = decision(
            for: source, captureIntegrity: captureIntegrity,
            hasAudio: hasAudio, recordingSeconds: recordingSeconds)
        if outcome == .run { load() }
        return outcome
    }

    /// The message a clustering pass that found nothing leaves behind: known
    /// lost remote audio stays the incomplete sentence, never "no speech".
    static func noRunsMessage(captureIntegrity: MeetingCaptureIntegrity?) -> String {
        if captureIntegrity?.hasKnownSavedAudioLoss(on: .system) == true {
            return refuseIncompleteRemoteAudioMessage
        }
        return noChannelSpeechMessage
    }

    /// FluidAudio's "no speech" is honest after the eligibility gate: the saved
    /// track was present and intact and the clusterer still found nothing.
    static func problemMessage(for error: Error) -> String? {
        guard let engine = error as? OfflineDiarizationError else { return nil }
        switch engine {
        case .noSpeechDetected:
            return noChannelSpeechMessage
        case .modelNotLoaded:
            return DiarizationError.notPrepared.localizedDescription
        case .invalidConfiguration, .invalidBatchSize, .processingFailed, .exportFailed:
            return engineUnavailableMessage
        }
    }

    /// The speaker models could not be used. The engine's own wording stays in
    /// the log; a person reading a banner does not need "Invalid batch size".
    static let engineUnavailableMessage =
        "The speaker models could not be used on this recording, so the speakers couldn't be told apart."
}
