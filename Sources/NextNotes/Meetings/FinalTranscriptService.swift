import Foundation
import FluidAudio

/// The one place the post-Stop final transcription pass runs (M-01).
///
/// The same shape as `DiarizationService`, and for the same reason: the session is
/// gone by the time the pass runs, and a second caller starting its own pass over
/// the same audio would double the CoreML work. One task per meeting, cancellable
/// on deletion.
///
/// After Stop, before diarization: each channel of `audio.caf` is re-transcribed in
/// long windows (`MeetingFinalPass`), each track is accepted only if it kept at
/// least 60 % of its live words, live agent commands survive the merge, and the
/// live transcript is kept as `transcript.live.json` before `transcript.json` is
/// replaced. An error keeps the live transcript and never blocks the pipeline.
@MainActor
final class FinalTranscriptService {
    static let shared = FinalTranscriptService()

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var terminationRequested = false
    private var terminationFixtureID: UUID?
    private var terminationFixtureTrace: FinalTranscriptTerminationTrace?
    private var quietFixtureTaskForTesting: Task<Void, Never>?

    /// COMMON metadata-only diagnostic; the ordinary default remains nil.
    func configureFinalTerminationFixture(id: UUID, store: MeetingStore,
                                          trace: FinalTranscriptTerminationTrace) throws {
        let root = store.directory(for: id).deletingLastPathComponent().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "NextNotesMeetingResumeTest-"
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-native-termination",
              NativeFinalTranscriptQuitSelfTest.isRequested, self === Self.shared,
              tasks.isEmpty, terminationFixtureTrace == nil,
              root.path == root.resolvingSymlinksInPath().path,
              root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        terminationFixtureID = id
        terminationFixtureTrace = trace
    }

    /// One safe quiet-session fixture reuses the existing fixture identity and map.
    /// No shared singleton or native model is initialized by this configuration.
    func configureQuietSessionFixture(id: UUID, store: MeetingStore) throws {
        let root = store.directory(for: id).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "NextNotesMeetingResumeTest-"
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-meeting-quiet-input",
              CommandLine.arguments.contains("--meeting-quiet-session"),
              Settings.shared.usesHarnessPreferencesForTesting,
              tasks.isEmpty, terminationFixtureID == nil,
              root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        terminationFixtureID = id
    }

    /// Release only the joined quiet diagnostic reference; production stays nil.
    func releaseQuietSessionFixture(id: UUID) -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-meeting-quiet-input",
              CommandLine.arguments.contains("--meeting-quiet-session"),
              Settings.shared.usesHarnessPreferencesForTesting,
              id == terminationFixtureID, tasks[id] == nil else { return false }
        quietFixtureTaskForTesting = nil
        terminationFixtureID = nil
        return true
    }

    /// Returns the SAME map handle; no replacement Task or native result override.
    func finalTerminationTaskForTesting(id: UUID) -> Task<Void, Never>? {
        if SelfTest.isRunning, SelfTest.requested == "--selftest-meeting-quiet-input",
           CommandLine.arguments.contains("--meeting-quiet-session"),
           Settings.shared.usesHarnessPreferencesForTesting, id == terminationFixtureID {
            return quietFixtureTaskForTesting
        }
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-native-termination",
              NativeFinalTranscriptQuitSelfTest.isRequested, id == terminationFixtureID else { return nil }
        return tasks[id]
    }

    /// Close future admission and retain the SAME existing map before cancellation.
    func beginTermination() -> [Task<Void, Never>] {
        terminationRequested = true
        let owned = Array(tasks.values)
        terminationFixtureTrace?.captured(count: owned.count)
        for task in owned { task.cancel() }
        return owned
    }

    /// A cancelled native await still owns work until its actual Task returns.
    func finishTermination(_ owned: [Task<Void, Never>]) async {
        for task in owned { await task.value }
    }

    private let transcribe: @Sendable ([Float]) async throws -> ASRResult
    private let afterFinalPass: @MainActor (Meeting, MeetingStore) -> Void

    init(
        transcribe: @escaping @Sendable ([Float]) async throws -> ASRResult = {
            try await TranscriptionQueue.shared.transcribe($0, lane: .background)
        },
        afterFinalPass: @escaping @MainActor (Meeting, MeetingStore) -> Void = {
            _ = MeetingPipeline.afterFinalPass($0, store: $1)
        }
    ) {
        self.transcribe = transcribe
        self.afterFinalPass = afterFinalPass
    }

    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }

    /// Stops a pass that is no longer wanted. Deleting the meeting is the case
    /// that matters (wired in `MeetingStore.delete` beside the other cancels).
    func cancel(_ id: UUID) {
        // Only the actual Task's defer releases the slot. Removing it here would
        // lose native ownership and admit a successor while this pass still lives.
        tasks[id]?.cancel()
    }

    /// Runs the final pass, then hands the meeting to whatever comes next.
    /// Returns immediately; the session that called it is already gone.
    func process(_ meeting: Meeting, store: MeetingStore = .shared) {
        let id = meeting.id
        guard !terminationRequested, tasks[id] == nil else { return }
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tasks[id] = nil
                if id == self.terminationFixtureID { self.terminationFixtureTrace?.ended() }
            }
            await self.run(id: id, store: store)
        }
        if SelfTest.isRunning, SelfTest.requested == "--selftest-meeting-quiet-input",
           CommandLine.arguments.contains("--meeting-quiet-session"), id == terminationFixtureID {
            // Retain the SAME assigned handle before a fast all-silent task can remove
            // its normal map slot. Only the configured private diagnostic owns it.
            quietFixtureTaskForTesting = tasks[id]
        }
        if id == terminationFixtureID { terminationFixtureTrace?.assigned() }
    }

    private func run(id: UUID, store: MeetingStore) async {
        guard !terminationRequested, !Task.isCancelled,
              var meeting = store.meeting(id: id) else { return }
        guard let audio = store.audioURL(for: meeting) else {
            meeting.transcriptPass = "live-only:no-audio"
            store.save(meeting)
            if id == terminationFixtureID { terminationFixtureTrace?.handoff() }
            afterFinalPass(meeting, store)
            return
        }
        let began = Date()
        let live = store.transcript(for: id)
        do {
            var finalsByTrack: [AudioSource: [TranscriptSegment]] = [:]
            var windows = 0
            var trackSeconds = 0.0
            for (channel, source) in [
                (MeetingAudioWriter.micChannel, AudioSource.mic),
                (MeetingAudioWriter.systemChannel, AudioSource.system),
            ] as [(Int, AudioSource)] {
                try Task.checkCancellation()
                // A deleted meeting stays deleted: no write below may re-create it.
                guard store.meeting(id: id) != nil else { return }
                // The writer can trim a delayed track after padding the saved file.
                // Its live originals still reached ASR. A word-count threshold cannot
                // prove that this partial recording can replace those originals.
                if store.meeting(id: id)?.captureIntegrity?.hasKnownSavedAudioLoss(on: source) == true,
                   live.contains(where: { $0.source == source }) {
                    continue
                }
                let track: (segments: [TranscriptSegment], windows: [ClosedRange<TimeInterval>])
                if AudioConversion.usesBoundedMeetingAudioExperiment {
                    let samples = try AudioConversion.meetingSampleSource(fromFileAt: audio, channel: channel)
                    trackSeconds = Double(samples.sampleCount) / ChunkedTranscriber.sampleRate
                    track = try await MeetingFinalPass.transcribeTrack(
                        audioSource: samples, source: source, transcribe: transcribe
                    )
                } else {
                    let samples = try AudioConversion.samples(
                        fromFileAt: audio,
                        sampleRate: ChunkedTranscriber.sampleRate,
                        channel: channel
                    )
                    trackSeconds = Double(samples.count) / ChunkedTranscriber.sampleRate
                    track = try await MeetingFinalPass.transcribeTrack(
                        samples, source: source, transcribe: transcribe
                    )
                }
                try Task.checkCancellation()
                guard !terminationRequested else { return }
                windows += track.windows.count
                finalsByTrack[source] = track.segments
            }
            try Task.checkCancellation()
            guard !terminationRequested, store.meeting(id: id) != nil else { return }

            var accepted: [AudioSource: Bool] = [:]
            var combined: [TranscriptSegment] = []
            for source in [AudioSource.mic, .system] as [AudioSource] {
                let final = finalsByTrack[source] ?? []
                let trackLive = live.filter { $0.source == source }
                let knownLoss = store.meeting(id: id)?.captureIntegrity?.hasKnownSavedAudioLoss(on: source) == true
                let ok = (trackLive.isEmpty || !knownLoss)
                    && MeetingFinalPass.accept(final: final, live: trackLive, source: source)
                accepted[source] = ok
                combined.append(contentsOf: ok ? final : trackLive)
            }
            let merged = MeetingFinalPass.merge(final: combined, live: live)
                .sorted { $0.start < $1.start }
            store.saveLiveTranscript(live, for: id)
            store.saveTranscript(merged, for: id)
            let allAccepted = accepted.values.allSatisfy { $0 }
            // Track inference awaited while the person could rename this meeting or
            // its capture producer could report a late failure. Save today's row.
            guard let current = store.meeting(id: id) else { return }
            meeting = current
            meeting.transcriptPass = allAccepted ? "long-window" : "live-only:rejected"
            store.save(meeting)

            let elapsed = Date().timeIntervalSince(began)
            let rtf = trackSeconds > 0 ? elapsed / trackSeconds : 0
            let acceptedNote = "mic:\(accepted[.mic] ?? false),system:\(accepted[.system] ?? false)"
            LatencyTrace.record(
                .meetingFinalPass,
                seconds: elapsed,
                note: "audio=\(String(format: "%.1f", trackSeconds))s"
                    + " windows=\(windows) rtf=\(String(format: "%.4f", rtf))"
                    + " accepted=\(acceptedNote)"
            )
            Log.meeting.info("""
                final pass "\(meeting.title, privacy: .public)" — \
                \(String(format: "%.1f", trackSeconds), privacy: .public)s audio in \
                \(String(format: "%.1f", elapsed), privacy: .public)s \
                (rtf \(String(format: "%.4f", rtf), privacy: .public), \
                \(windows, privacy: .public) windows, accepted \(acceptedNote, privacy: .public)
                """)
            if id == terminationFixtureID { terminationFixtureTrace?.handoff() }
            afterFinalPass(store.meeting(id: id) ?? meeting, store)
        } catch is CancellationError {
            // Cancellation is an unfinished pass, not a failed-but-ready pipeline.
            return
        } catch {
            Log.meeting.error("final pass failed: \(error.localizedDescription, privacy: .public)")
            keepLive(id: id, pass: "live-only:failed", store: store)
        }
    }

    /// The error path: the live transcript stays, the pass is named, and the
    /// pipeline continues. Never blocks diarization or notes on a failed pass.
    private func keepLive(id: UUID, pass: String, store: MeetingStore) {
        guard !terminationRequested, !Task.isCancelled,
              var meeting = store.meeting(id: id) else { return }
        meeting.transcriptPass = pass
        if store.transcript(for: id).isEmpty {
            meeting.status = .failed("The recording could not be transcribed.")
        }
        store.save(meeting)
        if id == terminationFixtureID { terminationFixtureTrace?.handoff() }
        afterFinalPass(meeting, store)
    }
}
