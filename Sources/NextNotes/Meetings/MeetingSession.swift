import AVFoundation
import Darwin
import Foundation
import Observation

/// One meeting being recorded, from the first buffer to the finished transcript.
///
/// It owns both captures, both transcribers and the optional audio file, and it is the only
/// thing that moves a `Meeting` through its states. Every transition is persisted as it
/// happens: if the app dies mid-transcription the meeting says `transcribing` on the next
/// launch, which is the truth, rather than looking finished and empty.
@MainActor
@Observable
final class MeetingSession {
    private(set) var meeting: Meeting
    /// Both tracks merged and ordered by when they were spoken.
    private(set) var segments: [TranscriptSegment] = []
    /// Latest provisional window text per track, for the live pane before finals land.
    private(set) var provisionalText: [AudioSource: String] = [:]
    /// `TranscriptEvent.provisionalID` still open per track — attached to the next final
    /// so `TranscriptBus` can close the provisional.
    private var openProvisionalIDs: [AudioSource: UUID] = [:]
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var elapsed: TimeInterval = 0
    /// When speech was last transcribed on either track.
    ///
    /// Seeded with the start time, so a meeting that never produces a word is still
    /// measured from somewhere. Phase 3's scheduler reads it to stop a call that ended
    /// without anyone telling Next Notes; a level threshold would have been cheaper still,
    /// but keyboard noise and an open fan register as level and never as a segment.
    private(set) var lastSpeechAt = Date()
    /// Set when the process tap couldn't start. The meeting continues on the mic alone —
    /// a recording of half the conversation beats no recording at all.
    private(set) var systemAudioProblem: String?
    /// Set when the recording's own file could not be had (M-10): under 1 GB free
    /// at start, or the writer's first write error. The meeting continues — the
    /// transcript is still written — but this says what the user is not getting.
    private(set) var audioProblem: String?

    private let store: MeetingStore
    private let captureHub: AudioCaptureHub
    typealias AudioWriterFactory = (URL, @escaping @Sendable (String) -> Void) throws -> MeetingAudioWriter
    private let writerFactory: AudioWriterFactory?
    private let diskCapacityForTesting: MeetingDiskCapacity?
    private(set) var healthWarnings: [MeetingHealthIssue] = []
    private(set) var liveTranscriptPaused = false
    private var resourceHealthTask: Task<Void, Never>?
    private var lastResourceCheck: Date?
    private var lastWrittenFrames = 0
    private var lastWriteProgressAt: Date?
    private let systemCapture = SystemAudioCapture()

    private var micTranscriber: ChunkedTranscriber?
    private var systemTranscriber: ChunkedTranscriber?
    private var writer: MeetingAudioWriter?

    private var micDrain: Task<Void, Never>?
    private var systemDrain: Task<Void, Never>?
    private var micContinuation: AsyncStream<MeetingAudioPacket>.Continuation?
    private var systemContinuation: AsyncStream<MeetingAudioPacket>.Continuation?
    private let captureDrops = MeetingCaptureDrops()
    private var clock: Task<Void, Never>?

    /// The late-join retry for the system tap (M-09), armed when the first start
    /// fails. One slot per session: armed once, cancelled by `stop`, `endAbruptly`
    /// and `abort`, ended by success or by the attempt limit.
    private var tapRetry: Task<Void, Never>?

    private var startedAt = Date()
    private var startedHostTime: UInt64 = 0
    private var isStopping = false
    /// Stop can arrive while the microphone permission prompt suspends start().
    /// Nothing has been captured yet in that case; the answer to the prompt must
    /// never start a session the person already stopped.
    private var startCancelled = false
    private var hasBegunCapture = false

    /// Test-only (`--selftest-meeting-tap-retry`): replaces the transcriber model call
    /// so the tap-retry self-test runs without Parakeet. Set by the test, cleared after.
    nonisolated(unsafe) static var transcribeOverrideForTesting: ChunkedTranscriber.Transcribe?
    /// Test-only: park the permission answer so Stop can race a suspended start.
    static var microphonePermissionOverrideForTesting: (@MainActor () async -> Bool)?

    /// Test-only (`--selftest-meeting-resume`, M-16c): the clock the transcript throttle
    /// reads, so a self-test can put twenty seconds of segments through it in a
    /// millisecond. Production leaves it nil and reads `Date()`.
    private var transcriptClock: (() -> Date)?

    /// Test-only setter for the throttle's clock (see `transcriptClock`).
    func setTranscriptClockForTesting(_ clock: @escaping () -> Date) {
        transcriptClock = clock
    }

    /// What the throttle calls "now". Everything that times the transcript file goes
    /// through this one line, so a test's clock governs the write decision, the trailing
    /// write's delay and the flush alike.
    private var transcriptNow: Date { transcriptClock?() ?? Date() }

    /// M-16c: the throttle's own state — when the file was last written, and whether a
    /// segment is waiting to be in it. Nothing is written before the first segment.
    private var transcriptThrottle = TranscriptSaveThrottle()

    /// M-16c: the one trailing write a throttled segment arms, so a meeting that goes
    /// quiet still puts its newest segment on disk within the interval.
    private var transcriptTrailingWrite: Task<Void, Never>?

    /// Test-only: the cadence the M-09 tap retry waits between attempts. Production
    /// keeps `Self.tapRetryInterval`; the self-test shortens it to fit in seconds.
    private var tapRetryIntervalForTesting: Duration?

    /// Test-only setter for the retry cadence (see `tapRetryIntervalForTesting`).
    func setTapRetryIntervalForTesting(_ interval: Duration) {
        tapRetryIntervalForTesting = interval
    }

    /// Test-only (`--selftest-meeting-tap-retry`): drives the track wiring and the tap
    /// start that `start()` performs, with no microphone gate, no hub subscription and
    /// no audio writer — the capture is injected through
    /// `SystemAudioCapture.startCallOverrideForTesting`. Not a production path.
    func startTapForTesting() async throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ChunkedTranscriber.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingError.noAudioFormat
        }
        ModelResidencyPolicy.installPressureObserver()
        startedAt = Date()
        startedHostTime = mach_absolute_time()
        lastSpeechAt = startedAt
        meeting.start = startedAt
        meeting.status = .recording
        persistMeeting()
        wireTracks(outputFormat: format)
        hasBegunCapture = true
        try await startSystemTap(outputFormat: format)
    }

    init(
        meeting: Meeting, store: MeetingStore = .shared,
        captureHub: AudioCaptureHub = .shared, writerFactory: AudioWriterFactory? = nil,
        diskCapacityForTesting: MeetingDiskCapacity? = nil
    ) {
        self.meeting = meeting
        self.store = store
        self.captureHub = captureHub
        self.writerFactory = writerFactory
        self.diskCapacityForTesting = SelfTest.isRunning ? diskCapacityForTesting : nil
    }

    var isRecording: Bool { meeting.status == .recording }

    /// Whether this recording writes `audio.caf` at all (M-10 Target 4). Pure, so
    /// the self-test and `start()` decide the same way: something has to want the
    /// file — keep-audio, diarization, the final pass — and under
    /// `minimumFreeBytesForAudio` nothing is written, whatever wanted it.
    nonisolated static func shouldWriteAudio(
        keep: Bool,
        diarize: Bool,
        finalPass: Bool,
        freeBytes: Int64
    ) -> Bool {
        guard keep || diarize || finalPass else { return false }
        return freeBytes >= minimumFreeBytesForAudio
    }

    /// The start disk guard (M-10 Target 4): under this little free space the
    /// recording writes no audio file at all, and the pass records
    /// `live-only:no-audio` rather than filling the last gigabyte.
    nonisolated static let minimumFreeBytesForAudio: Int64 = 1_000_000_000

    /// In-memory only. `MeetingStore.rename` writes the file and then calls this so the
    /// live pane and the island do not keep showing the old name until the session ends.
    func applyTitle(_ title: String, ifID id: UUID) {
        guard meeting.id == id else { return }
        meeting.title = title
    }

    // MARK: - Lifecycle

    func start() async throws {
        let permissionGranted: Bool
        if let override = Self.microphonePermissionOverrideForTesting {
            permissionGranted = await override()
        } else {
            permissionGranted = await Permissions.requestMicrophone()
        }
        guard permissionGranted else {
            throw MeetingError.microphoneDenied
        }
        guard !startCancelled else { throw MeetingError.startCancelled }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ChunkedTranscriber.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingError.noAudioFormat
        }

        ModelResidencyPolicy.installPressureObserver()
        startedAt = Date()
        startedHostTime = mach_absolute_time()
        lastSpeechAt = startedAt
        meeting.start = startedAt
        meeting.status = .recording
        meeting.captureIntegrity = MeetingCaptureIntegrity()
        persistMeeting()

        // Recorded whenever *something* is going to read it back: diarization reads
        // the system channel, and the M-01 final pass re-transcribes both channels
        // after Stop, each whether or not the user asked to keep a recording.
        // `MeetingStore.releaseAudio` deletes a temporary file again at the end of
        // the pipeline — M-10 gives that release a 72-hour window. Under 1 GB free
        // nothing is written at all: without audio the final pass records
        // `live-only:no-audio` and the pipeline continues on the live transcript,
        // and the problem below says so while it is still true.
        let keep = Settings.shared.meetingsKeepAudio
        let capacityAtStart = diskCapacityForTesting ?? MeetingDiskCapacity.current(at: store.directory(for: meeting.id))
        let freeBytes = capacityAtStart.immediateBytes ?? 0
        if capacityAtStart.immediateBytes == nil { reportHealthIssue(.storageUnknown) }
        let wantsAudio = Self.shouldWriteAudio(
            keep: keep,
            diarize: Settings.shared.meetingsDiarize,
            finalPass: Settings.shared.meetingsFinalPass,
            freeBytes: freeBytes
        )
        if !wantsAudio,
           keep || Settings.shared.meetingsDiarize || Settings.shared.meetingsFinalPass {
            audioProblem = "A recording could not be saved. This meeting is using the live transcript."
            Log.meeting.info("meeting audio skipped: immediate storage headroom unavailable")
            if capacityAtStart.immediateBytes != nil { reportHealthIssue(.storageLow) }
        }
        if wantsAudio {
            let url = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.audioFile)
            try? FileManager.default.createDirectory(
                at: store.directory(for: meeting.id),
                withIntermediateDirectories: true
            )
            do {
                // The writer is the only part that can fail *while* the meeting runs
                // (a disk filling up mid-recording). It stops at its first error and
                // reports once through the callback below; the meeting keeps going on
                // the transcript alone.
                let writeError: @Sendable (String) -> Void = { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.captureDrops.setLiveTranscriptionDeferred(false)
                        self.liveTranscriptPaused = false
                        var integrity = self.meeting.captureIntegrity ?? .init()
                        integrity.markAudioWriteFailure()
                        self.meeting.captureIntegrity = integrity
                        self.persistMeeting()
                        self.reportHealthIssue(.audioWriteFailure)
                    }
                }
                let audioWriter = try writerFactory?(url, writeError)
                    ?? MeetingAudioWriter(url: url, onWriteError: writeError)
                writer = audioWriter
                meeting.audioFileName = MeetingStore.audioFile
                meeting.audioIsTemporary = !keep
                // Persist the link before capture starts. A force-quit during recording
                // leaves audio.caf behind; launch repair must know it belongs here.
                persistMeeting()
            } catch {
                Log.meeting.error("keep-audio disabled for this meeting: \(error.localizedDescription, privacy: .public)")
                audioProblem = "This meeting's recording could not start saving. Check your Mac's storage."
                reportHealthIssue(.audioWriteFailure)
            }
        }

        wireTracks(outputFormat: format)

        do {
            // Mic via the shared hub so wake KWS stays subscribed. System audio
            // stays on `SystemAudioCapture` — two tracks, two owners.
            let micContinuation = self.micContinuation
            let startedAt = self.startedAt
            let startedHostTime = self.startedHostTime
            let captureDrops = self.captureDrops
            try captureHub.subscribe(
                .meeting,
                outputFormat: format,
                onBuffer: { [weak self] chunk in
                    let packet = Self.audioPacket(
                        chunk, startedAt: startedAt, startedHostTime: startedHostTime)
                    captureDrops.observe(packet, from: .mic, beganAt: startedAt)
                    if let result = micContinuation?.yield(packet),
                       case .dropped(let dropped) = result {
                        if captureDrops.addStreamFrames(dropped.samples.count) {
                            Task { @MainActor in self?.reportCaptureGap() }
                        }
                    }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.micLevel = level }
                },
                onOverflow: { [weak self] count in
                    if captureDrops.addHubBuffers(count) {
                        Task { @MainActor in self?.reportCaptureGap() }
                    }
                }
            )
            hasBegunCapture = true
        } catch {
            await abort(reason: error.localizedDescription)
            throw error
        }

        // The tap is the part that can be refused. Losing it costs the other half of the
        // conversation, not the recording.
        try await startSystemTap(outputFormat: format)
        guard !startCancelled else { throw MeetingError.startCancelled }

        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()
                self.elapsed = now.timeIntervalSince(self.startedAt)
                self.scheduleResourceHealthCheck(now: now)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        // Warming Parakeet after capture is running rather than before means the first
        // seconds of the meeting are already on disk while the model loads.
        if !SelfTest.isRunning {
            Task.detached(priority: .utility) {
                try? await TranscriptionQueue.shared.warmUp()
            }
        }

        // Notes are wanted at Stop, not at recording start. Do not speculatively
        // load a language model beside live ASR for a meeting that may last hours.
        // An explicit Agent/voice request still uses its existing intent warm-up.

        Log.meeting.info("recording \"\(self.meeting.title, privacy: .public)\"")
    }

    /// Stops capture, drains everything still in flight, and files the transcript.
    func stop() async {
        startCancelled = true
        // A pending permission prompt has no captures, drains or persisted meeting.
        // The suspended start() observes this flag when the prompt returns.
        guard hasBegunCapture else { return }
        guard !isStopping, meeting.status == .recording else { return }
        isStopping = true
        let began = Date()

        // A live late-join retry dies with the recording (M-09); an attempt already in
        // flight hits the stop-race guard below it and tears itself down.
        tapRetry?.cancel()
        tapRetry = nil

        systemCapture.stop()
        resourceHealthTask?.cancel()
        resourceHealthTask = nil
        meeting.end = Date()
        var integrity = meeting.captureIntegrity ?? .init()
        integrity.normalEndAt = meeting.end
        meeting.captureIntegrity = integrity
        meeting.status = .transcribing
        persistMeeting()
        // Removing the hub seat immediately would discard converted mic buffers
        // already queued by the callback. Keep the stream open until that delivery
        // worker has handed over every accepted buffer (bounded to three seconds).
        let hubDrained = await captureHub.unsubscribeAndDrain(.meeting)
        if !hubDrained {
            _ = captureDrops.addHubBuffers(1)
            reportCaptureGap()
        }
        clock?.cancel()
        clock = nil
        micLevel = 0
        systemLevel = 0

        micContinuation?.finish()
        systemContinuation?.finish()
        micContinuation = nil
        systemContinuation = nil
        await micDrain?.value
        await systemDrain?.value
        micDrain = nil
        systemDrain = nil

        await micTranscriber?.flush()
        await systemTranscriber?.flush()
        // M-07: whatever the live tier shed under the seconds bound is named once, here —
        // per meeting, both tracks summed. A healthy saved recording can recover it in
        // the final pass; otherwise the meeting is marked incomplete below.
        let skippedSeconds = (await micTranscriber?.droppedAudioSeconds ?? 0)
            + (await systemTranscriber?.droppedAudioSeconds ?? 0)
        if skippedSeconds > 0.01 {
            if meeting.audioFileName != nil {
                Log.meeting.info("""
                    live transcript skipped \(skippedSeconds, format: .fixed(precision: 1), privacy: .public)s; \
                    checking the saved recording for recovery
                    """)
            } else {
                Log.meeting.info("""
                    live transcript skipped \(skippedSeconds, format: .fixed(precision: 1), privacy: .public)s
                    """)
            }
        }
        micTranscriber = nil
        systemTranscriber = nil

        await writer?.finish()
        if let saved = writer?.resourceSnapshot() { recordSavedAudioCoverage(saved) }
        if let saved = await writer?.resourceSnapshot(), saved.writtenFrames > 0 {
            var integrity = meeting.captureIntegrity ?? .init()
            integrity.recordCaptured(until: startedAt.addingTimeInterval(Double(saved.writtenFrames) / ChunkedTranscriber.sampleRate))
            meeting.captureIntegrity = integrity
            persistMeeting()
        }
        let writerFailed = await writer?.didFail ?? false
        writer = nil
        let lostCapture = captureDrops.hasLoss
        let hasAudio = audioFileHasContent
        let savedAudioComplete = meeting.captureIntegrity?.hasKnownSavedAudioLoss(on: .mic) != true
            && meeting.captureIntegrity?.hasKnownSavedAudioLoss(on: .system) != true
        let recoverDroppedAudio = skippedSeconds > 0.01 && hasAudio && !writerFailed && savedAudioComplete
        if Self.hasUnrecoverableLoss(
            capturedDrop: lostCapture,
            skippedSeconds: skippedSeconds,
            hasAudio: hasAudio && savedAudioComplete,
            writerFailed: writerFailed,
            hasTranscript: !segments.isEmpty,
            audioProblem: audioProblem != nil
        ) {
            audioProblem = "Some speech could not be saved. This meeting's transcript is incomplete."
            meeting.status = .failed("Some speech could not be saved; the transcript is incomplete.")
            persistMeeting()
            reportHealthIssue(.captureGap)
        }

        // M-16c: an exit path always writes the file, whatever the throttle had pending.
        flushTranscript()
        // M-16a: the drain after Stop is a stage span, not a log line. Counts
        // only — no transcript text ever rides in a span note.
        LatencyTrace.record(
            .meetingDrain,
            seconds: Date().timeIntervalSince(began),
            note: "segments=\(segments.count)"
        )

        // Everything after the transcript is handed to `MeetingPipeline` rather than awaited
        // here. Identifying speakers and summarising a long meeting are each minutes of
        // model time, and a `stop()` that waited would keep this session — and therefore the
        // Record button — alive for all of them.
        // An incomplete transcript must remain visibly failed. The usual pipeline
        // would advance it to diarization/notes and make the loss look successful.
        if !meeting.status.isFailure, writerFailed {
            // The live ASR may have continued after the file stopped. A final pass
            // over that partial file can pass its 60% word threshold and erase the
            // unsaved tail, so notes use the complete live transcript instead.
            meeting.transcriptPass = "live-only:audio-incomplete"
            persistMeeting()
            meeting = MeetingPipeline.afterDiarizing(meeting, store: store)
        } else if !meeting.status.isFailure {
            meeting = MeetingPipeline.afterTranscribing(
                meeting, store: store, recoverDroppedAudio: recoverDroppedAudio)
        }

        Log.meeting.info("""
            finished "\(self.meeting.title, privacy: .public)" — \
            \(self.segments.count, privacy: .public) segment(s)
            """)
        isStopping = false
    }

    /// Stops everything without waiting, for app termination. Whatever has already been
    /// transcribed is saved; anything still inside Parakeet is not.
    ///
    /// M-08: the meeting is left where the next launch resumes it, not written off here.
    /// Anything the pipeline can still read — a transcript, or an audio file with content
    /// that the final pass can re-transcribe — becomes `.transcribing`, and only a meeting
    /// with neither is failed. Marking it `.done` instead is what left a recording with no
    /// speaker names and no notes, and a temporary `audio.caf` nothing would ever release:
    /// `pkill` (which `make install` sends) skips `applicationWillTerminate`, but a normal
    /// Quit arrives here and used to lose the meeting all the same.
    func endAbruptly() {
        startCancelled = true
        // The resume harness injects already-transcribed segments without opening
        // capture; those still need the same final file flush as a live session.
        guard hasBegunCapture || !segments.isEmpty else { return }
        guard meeting.status == .recording else { return }

        tapRetry?.cancel()
        tapRetry = nil
        resourceHealthTask?.cancel()
        resourceHealthTask = nil
        captureHub.unsubscribe(.meeting)
        systemCapture.stop()
        clock?.cancel()
        clock = nil
        micContinuation?.finish()
        systemContinuation?.finish()
        micDrain?.cancel()
        systemDrain?.cancel()

        meeting.end = Date()
        var integrity = meeting.captureIntegrity ?? .init()
        integrity.markInterrupted(at: meeting.end!, lastCapturedAt: integrity.lastCapturedAt)
        meeting.captureIntegrity = integrity
        switch MeetingStore.resumeAction(
            for: .recording,
            hasTranscript: !segments.isEmpty,
            hasAudio: audioFileHasContent
        ) {
        case .fail(let message):
            meeting.status = .failed(message)
        case .finalPass, .pipelineAfterTranscript, .diarize, .notes, .extractAgain, .none:
            meeting.status = .transcribing
        }
        // M-16c: a throttle must never cost a crash-recoverable transcript, and this is
        // the path a SIGTERM takes. Whatever the last write had pending is flushed here.
        flushTranscript()
        persistMeeting()
    }

    /// Whether the writer has put anything on disk yet. The pass can only recover speech
    /// from a file with content, so a meeting whose writer never got a frame is the same
    /// as one with no recording at all.
    private var audioFileHasContent: Bool {
        guard let name = meeting.audioFileName else { return false }
        let url = store.directory(for: meeting.id).appendingPathComponent(name)
        return ((try? AVAudioFile(forReading: url).length) ?? 0) > 0
    }

    /// A failed recording with no live words cannot be marked finished as an empty
    /// meeting: there may have been speech on the capture path that neither copy kept.
    nonisolated static func hasUnrecoverableLoss(
        capturedDrop: Bool,
        skippedSeconds: Double,
        hasAudio: Bool,
        writerFailed: Bool,
        hasTranscript: Bool,
        audioProblem: Bool
    ) -> Bool {
        capturedDrop
            || (skippedSeconds > 0.01 && (!hasAudio || writerFailed))
            || (!hasTranscript && (writerFailed || audioProblem))
    }

    // MARK: - System tap (M-09)

    /// The tap is retried while the meeting records: every `tapRetryInterval`, at most
    /// `maxTapRetries` times. A tap without the grant returns silence, not an error, so
    /// a retry cannot detect the missing grant and must not loop on one — this answers
    /// start *errors and timeouts* only. Stops on Stop, abort, quit, or after the final
    /// failure (logged once).
    private static let tapRetryInterval: Duration = .seconds(30)
    private static let maxTapRetries = 10

    private func beginSystemTapRetry(outputFormat: AVAudioFormat) {
        guard tapRetry == nil else { return }
        let interval = tapRetryIntervalForTesting ?? Self.tapRetryInterval
        let continuation = systemContinuation
        let startedAt = self.startedAt
        let startedHostTime = self.startedHostTime
        let captureDrops = self.captureDrops
        tapRetry = Task { [weak self] in
            defer { self?.tapRetry = nil }
            var attempts = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                // The same stop-race guard as the first start.
                guard !self.isStopping, self.meeting.status == .recording,
                      self.systemAudioProblem != nil else { return }
                attempts += 1
                guard attempts <= Self.maxTapRetries else {
                    Log.systemAudio.error("""
                        system-audio tap never joined; the meeting stays on the microphone \
                        alone after \(Self.maxTapRetries) attempts
                        """)
                    return
                }
                do {
                    try await self.systemCapture.start(
                        outputFormat: outputFormat,
                        onBuffer: { [weak self] chunk in
                            let packet = Self.audioPacket(
                                chunk, startedAt: startedAt, startedHostTime: startedHostTime)
                            captureDrops.observe(packet, from: .system, beganAt: startedAt)
                            if let result = continuation?.yield(packet),
                               case .dropped(let dropped) = result,
                               captureDrops.addStreamFrames(dropped.samples.count) {
                                Task { @MainActor in self?.reportCaptureGap() }
                            }
                        },
                        onLevel: { [weak self] level in
                            Task { @MainActor in self?.systemLevel = level }
                        }
                    )
                    guard !self.isStopping, self.meeting.status == .recording else {
                        self.systemCapture.stop()
                        return
                    }
                    self.systemAudioProblem = nil
                    let joinedAt = Date().timeIntervalSince(self.startedAt)
                    Log.systemAudio.info("system audio joined late at \(Self.recordingClock(joinedAt), privacy: .public)")
                    return
                } catch {
                    if self.isStopping || self.meeting.status != .recording {
                        self.systemCapture.stop()
                        return
                    }
                    self.systemAudioProblem = error.localizedDescription
                }
            }
        }
    }

    /// The `<mm:ss>` form the late-join log uses — the recording clock a person reads.
    private static func recordingClock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Builds both transcribers, the ordered drain streams and the two drain tasks.
    /// Extracted from `start()` so the tap-retry self-test can drive the system track
    /// without the microphone, the hub or the audio writer. The transcriber model call
    /// goes through the shared lane unless `transcribeOverrideForTesting` is set.
    private func wireTracks(outputFormat: AVAudioFormat) {
        let meetingID = meeting.id
        let transcribe = Self.transcribeOverrideForTesting
        micTranscriber = ChunkedTranscriber(
            source: .mic,
            meetingID: meetingID,
            onProvisional: { [weak self] event in
                await self?.setProvisional(event)
            },
            transcribe: transcribe ?? { try await TranscriptionQueue.shared.transcribeWithLaneWait($0) },
            onSegment: { [weak self] segment in
                await self?.add(segment)
            }
        )
        systemTranscriber = ChunkedTranscriber(
            source: .system,
            meetingID: meetingID,
            onProvisional: { [weak self] event in
                await self?.setProvisional(event)
            },
            transcribe: transcribe ?? { try await TranscriptionQueue.shared.transcribeWithLaneWait($0) },
            onSegment: { [weak self] segment in
                await self?.add(segment)
            }
        )

        // Ordered drains, for the same reason `DictationController` uses one: a task per
        // buffer has no ordering guarantee, and out-of-order audio transcribes as word salad.
        let (micStream, micContinuation) = AsyncStream<MeetingAudioPacket>.makeStream(
            bufferingPolicy: .bufferingNewest(1_024))
        let (systemStream, systemContinuation) = AsyncStream<MeetingAudioPacket>.makeStream(
            bufferingPolicy: .bufferingNewest(1_024))
        self.micContinuation = micContinuation
        self.systemContinuation = systemContinuation

        let micTranscriber = self.micTranscriber
        let systemTranscriber = self.systemTranscriber
        let writer = self.writer
        let captureDrops = self.captureDrops
        micDrain = Task.detached(priority: .userInitiated) {
            for await packet in micStream {
                // Audio on disk is the recovery path if the live model falls behind.
                let deferred = captureDrops.isLiveTranscriptionDeferred
                let saved = await writer?.append(packet.samples, from: .mic, startFrame: packet.startFrame, requireWritten: deferred)
                if deferred, saved == true {
                    await micTranscriber?.deferForRecovery(throughSample: packet.startFrame + packet.samples.count)
                } else {
                    await micTranscriber?.append(packet.samples)
                }
            }
        }
        systemDrain = Task.detached(priority: .userInitiated) {
            var placedOrigin = false
            for await packet in systemStream {
                // The first *captured* packet, not the time a retry began, is the
                // system track's origin. A slow tap start can deliver buffers before
                // its async start call returns, so placing the origin afterwards is
                // too late and placing it before the call stamps speech early.
                if !placedOrigin, !packet.samples.isEmpty {
                    await systemTranscriber?.advanceOrigin(toSample: packet.startFrame)
                    placedOrigin = true
                }
                let deferred = captureDrops.isLiveTranscriptionDeferred
                let saved = await writer?.append(packet.samples, from: .system, startFrame: packet.startFrame, requireWritten: deferred)
                if deferred, saved == true {
                    await systemTranscriber?.deferForRecovery(throughSample: packet.startFrame + packet.samples.count)
                } else {
                    await systemTranscriber?.append(packet.samples)
                }
            }
        }
    }

    /// Starts the system tap once. On failure the meeting continues on the microphone
    /// alone and the late-join retry is armed (M-09). Extracted from `start()` so the
    /// tap-retry self-test drives the same path with the capture injected through
    /// `SystemAudioCapture.startCallOverrideForTesting`.
    private func startSystemTap(outputFormat: AVAudioFormat) async throws {
        let continuation = systemContinuation
        let startedAt = self.startedAt
        let startedHostTime = self.startedHostTime
        let captureDrops = self.captureDrops
        do {
            try await systemCapture.start(
                outputFormat: outputFormat,
                onBuffer: { [weak self] chunk in
                    let packet = Self.audioPacket(
                        chunk, startedAt: startedAt, startedHostTime: startedHostTime)
                    captureDrops.observe(packet, from: .system, beganAt: startedAt)
                    if let result = continuation?.yield(packet), case .dropped(let dropped) = result {
                        if captureDrops.addStreamFrames(dropped.samples.count) {
                            Task { @MainActor in self?.reportCaptureGap() }
                        }
                    }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.systemLevel = level }
                }
            )
            // `stop()` can run while the bounded system-audio startup is suspended. A late
            // successful HAL start belongs to that cancelled session and must be torn down
            // instead of resurrecting its clock/model work.
            guard !isStopping, meeting.status == .recording else {
                systemCapture.stop()
                throw MeetingError.startCancelled
            }
        } catch {
            if case MeetingError.startCancelled = error {
                throw error
            }
            if isStopping || meeting.status != .recording {
                systemCapture.stop()
                throw MeetingError.startCancelled
            }
            systemAudioProblem = error.localizedDescription
            reportHealthIssue(.systemUnavailable)
            Log.systemAudio.error("meeting continues on the microphone alone: \(error.localizedDescription, privacy: .public)")
            beginSystemTapRetry(outputFormat: outputFormat)
        }
    }

    // MARK: - Internals

    /// The audio timestamp belongs to capture, not the arrival of a later drain task.
    /// The writer uses the first packet of each track to align a late system tap.
    private nonisolated static func audioPacket(
        _ chunk: AudioChunk,
        startedAt: Date,
        startedHostTime: UInt64
    ) -> MeetingAudioPacket {
        let elapsed: TimeInterval
        if let hostTime = chunk.captureHostTime, startedHostTime > 0 {
            elapsed = AVAudioTime.seconds(forHostTime: hostTime)
                - AVAudioTime.seconds(forHostTime: startedHostTime)
        } else {
            elapsed = Date().timeIntervalSince(startedAt)
        }
        return MeetingAudioPacket(
            samples: AudioConversion.samples(of: chunk.buffer),
            startFrame: Int(max(0, elapsed) * ChunkedTranscriber.sampleRate)
        )
    }

    private func reportCaptureGap() {
        guard [.recording, .transcribing].contains(meeting.status) else { return }
        var integrity = meeting.captureIntegrity ?? .init()
        integrity.markGap()
        // This is a cumulative snapshot, not a count to add again on later checks.
        integrity.missingCaptureFrames = max(integrity.missingCaptureFrames, captureDrops.snapshot.streamFrames)
        meeting.captureIntegrity = integrity
        persistMeeting()
        reportHealthIssue(.captureGap)
    }

    private func scheduleResourceHealthCheck(now: Date) {
        guard resourceHealthTask == nil,
              lastResourceCheck.map({ now.timeIntervalSince($0) >= MeetingResourceHealth.interval }) ?? true
        else { return }
        lastResourceCheck = now
        resourceHealthTask = Task { [weak self] in
            guard let self else { return }
            await self.checkResourceHealth(now: now)
            self.resourceHealthTask = nil
        }
    }

    /// Called by the live tick and isolated fixtures. Capacity is queried off the
    /// MainActor; no capture callback waits on a filesystem or memory query.
    func checkResourceHealth(
        now: Date = Date(), capacityForTesting: MeetingDiskCapacity? = nil,
        criticalForTesting: Bool? = nil
    ) async {
        guard meeting.status == .recording else { return }
        let began = Date()
        let directory = store.directory(for: meeting.id)
        let injectedCapacity = SelfTest.isRunning ? (capacityForTesting ?? diskCapacityForTesting) : nil
        let capacity = await Task.detached(priority: .utility) {
            injectedCapacity ?? MeetingDiskCapacity.current(at: directory)
        }.value
        let saved = writer?.resourceSnapshot()
        let mic = await micTranscriber?.resourceSnapshot()
        let system = await systemTranscriber?.resourceSnapshot()
        guard meeting.status == .recording, !Task.isCancelled else { return }
        if let saved { recordSavedAudioCoverage(saved) }
        let progress = captureDrops.snapshot
        if let saved, saved.writtenFrames > lastWrittenFrames {
            lastWrittenFrames = saved.writtenFrames
            lastWriteProgressAt = now
        }
        let pressure = ModelResidencyPolicy.pressureSnapshot
        let critical = criticalForTesting ?? (pressure.level == .critical)
        let healthyCapture = progress.lastMicAt.map { now.timeIntervalSince($0) < MeetingResourceHealth.interval * 2 } ?? false
        let free = capacity.immediateBytes
        let writerRecent = lastWriteProgressAt.map {
            now.timeIntervalSince($0) < MeetingResourceHealth.stallInterval
        } ?? false
        let canRecover = saved.map { !$0.writeFailed && $0.writtenFrames > 0 } ?? false
        let pause = critical && healthyCapture && canRecover
            && writerRecent
            && (free.map { $0 >= Self.minimumFreeBytesForAudio } ?? false)
        captureDrops.setLiveTranscriptionDeferred(pause)
        liveTranscriptPaused = pause
        let input = MeetingHealthInput(
            now: now, beganAt: startedAt, disk: capacity,
            memoryIsTight: !pressure.allowsOptionalWork || critical,
            lastMicAt: progress.lastMicAt, lastSystemAt: progress.lastSystemAt,
            expectsSystem: systemAudioProblem == nil, writerPresent: saved != nil,
            writerFailed: saved?.writeFailed ?? false, lastWriteProgressAt: lastWriteProgressAt)
        let issues = MeetingResourceHealth.issues(input)
        // Risk warnings clear when the condition does. Actual loss remains persisted.
        healthWarnings.removeAll { !$0.isCaptureFailure && $0 != .audioWriteFailure
            && $0 != .savedAudioGap
            && $0 != .transcriptWriteFailure && $0 != .metadataWriteFailure && !issues.contains($0) }
        for issue in issues { reportHealthIssue(issue) }
        var integrity = meeting.captureIntegrity ?? .init()
        if let saved, saved.writtenFrames > 0 {
            integrity.recordCaptured(until: startedAt.addingTimeInterval(Double(saved.writtenFrames) / ChunkedTranscriber.sampleRate))
        }
        if progress.streamFrames > 0 || progress.hubBuffers > 0 {
            integrity.markGap()
            integrity.missingCaptureFrames = max(integrity.missingCaptureFrames, progress.streamFrames)
        }
        meeting.captureIntegrity = integrity
        persistMeeting()
        // Numeric counts only; model/provider attribution stays in usage.jsonl.
        let queued = (mic?.queuedBytes ?? 0) + (system?.queuedBytes ?? 0)
        let active = (mic?.activeBytes ?? 0) + (system?.activeBytes ?? 0)
        let swap = MeetingResourceHealth.swapBytes()
        let note = "queuedBytes=\(queued) activeBytes=\(active) writerBytes=\(saved.map { $0.writtenFrames * 4 } ?? 0) freeBytes=\(free ?? -1) swapUsed=\(swap.used.map(String.init) ?? "unknown") swapAvailable=\(swap.available.map(String.init) ?? "unknown") pressure=\(pressure.level.rawValue) missedFrames=\(progress.streamFrames) missedBuffers=\(progress.hubBuffers) paused=\(pause ? 1 : 0)"
        LatencyTrace.record(.meetingResources, seconds: Date().timeIntervalSince(began), note: note)
    }

    @discardableResult
    private func persistMeeting() -> Bool {
        let saved = store.save(meeting)
        if !saved { reportHealthIssue(.metadataWriteFailure) }
        return saved
    }

    private func recordSavedAudioCoverage(_ saved: MeetingAudioWriter.ResourceSnapshot) {
        guard saved.missingSavedMicFrames > 0 || saved.missingSavedSystemFrames > 0 else { return }
        var integrity = meeting.captureIntegrity ?? .init()
        integrity.missingSavedMicFrames = max(integrity.missingSavedMicFrames ?? 0,
            Int64(saved.missingSavedMicFrames))
        integrity.missingSavedSystemFrames = max(integrity.missingSavedSystemFrames ?? 0,
            Int64(saved.missingSavedSystemFrames))
        meeting.captureIntegrity = integrity
        persistMeeting()
        reportHealthIssue(.savedAudioGap)
    }

    private func reportHealthIssue(_ issue: MeetingHealthIssue) {
        if issue == .audioWriteFailure {
            var integrity = meeting.captureIntegrity ?? .init()
            integrity.markAudioWriteFailure()
            meeting.captureIntegrity = integrity
            persistMeeting()
        }
        if issue.isCaptureFailure {
            var integrity = meeting.captureIntegrity ?? .init()
            integrity.markGap()
            meeting.captureIntegrity = integrity
            persistMeeting()
        }
        guard !healthWarnings.contains(issue) else { return }
        healthWarnings.append(issue)
        if issue.isCaptureFailure || issue == .audioWriteFailure || issue == .transcriptWriteFailure {
            audioProblem = issue.message
        }
        Notifications.shared.postMeetingProblem(meeting: meeting, issue: issue)
        LatencyTrace.record(.meetingHealthWarning, seconds: 0, note: "kind=\(issue.rawValue)")
    }

    /// Provisional window text for the live UI / `TranscriptBus`. Cleared when a final
    /// segment from the same track arrives.
    private func setProvisional(_ event: TranscriptEvent) {
        provisionalText[event.source] = event.text
        if let id = event.provisionalID {
            openProvisionalIDs[event.source] = id
        }
        // Speech end (window `end` on the recording clock) → visible provisional.
        let lag = max(0, Date().timeIntervalSince(startedAt) - event.end)
        LatencyTrace.record(
            .meetingSpeechToPartial,
            seconds: lag,
            note: event.source.rawValue
        )
        Task { await TranscriptBus.shared.publish(event) }
    }

    /// Segments arrive from two transcribers, so they are inserted by time rather than
    /// appended: the system track can finish a window that started before one the mic track
    /// has already delivered.
    private func add(_ segment: TranscriptSegment) {
        lastSpeechAt = Date()
        let incoming = ActivationController.shared.handleWake(in: segment)
        // M-16c: the ordered insert and the file write travel together, so the write
        // throttle cannot be exercised apart from the write it governs. `add` and
        // `--selftest-meeting-resume` come through this one method.
        insertSegment(incoming, now: transcriptNow)
        provisionalText[incoming.source] = nil
        let provisionalID = openProvisionalIDs.removeValue(forKey: incoming.source)

        let speechLag = max(0, Date().timeIntervalSince(startedAt) - incoming.end)
        LatencyTrace.record(
            .meetingSpeechToFinal,
            seconds: speechLag,
            note: incoming.source.rawValue
        )

        let candidatesBefore = MeetingContextStore.shared.current?.candidateActions.count ?? 0
        let contextTrace = LatencyTrace.start(.meetingTranscriptToContext)
        MeetingContextStore.shared.ingest(segments, meeting: meeting)
        contextTrace.end(note: incoming.source.rawValue)
        let candidatesAfter = MeetingContextStore.shared.current?.candidateActions.count ?? 0
        if candidatesAfter > candidatesBefore {
            // Phrase → candidate is measured here. Candidate → card is measured at the
            // IslandState hand-off, after a card has actually been proposed.
            let phraseLag = max(0, Date().timeIntervalSince(startedAt) - incoming.end)
            LatencyTrace.record(
                .meetingActionPhraseToCandidate,
                seconds: phraseLag,
                note: incoming.source.rawValue
            )
        }

        Task {
            await TranscriptBus.shared.publish(
                TranscriptEvent(
                    meetingID: meeting.id,
                    source: incoming.source,
                    text: incoming.text,
                    start: incoming.start,
                    end: incoming.end,
                    isFinal: true,
                    provisionalID: provisionalID
                )
            )
        }
    }

    /// M-16c: one segment into the ordered transcript, and the decision about the file.
    ///
    /// The transcript is a crash record, so it is written on a throttle rather than on
    /// every segment — `TranscriptSaveThrottle` — and every exit path flushes it. The
    /// insert and the write are one call because a segment that is not in the file yet
    /// is exactly what the throttle is counting.
    private func insertSegment(_ segment: TranscriptSegment, now: Date) {
        let index = segments.firstIndex { $0.start > segment.start } ?? segments.endIndex
        segments.insert(segment, at: index)
        let clock = now.timeIntervalSince1970
        transcriptThrottle.markPending()
        guard transcriptThrottle.shouldWrite(at: clock) else {
            armTrailingTranscriptWrite()
            return
        }
        writeTranscript(at: clock)
    }

    /// M-16c: the newest segment is on disk within one interval, even when nothing else
    /// is said. Without it a meeting that went quiet after a throttled segment would keep
    /// that segment in memory only, and a crash an hour later would lose it.
    private func armTrailingTranscriptWrite() {
        guard transcriptTrailingWrite == nil else { return }
        let wait = TranscriptSaveThrottle.secondsUntilDue(
            now: transcriptNow.timeIntervalSince1970,
            lastWrite: transcriptThrottle.lastWrite
        )
        transcriptTrailingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.transcriptTrailingWrite = nil
            guard self.transcriptThrottle.pending else { return }
            self.writeTranscript(at: self.transcriptNow.timeIntervalSince1970)
        }
    }

    /// M-16c: the only place a live meeting writes `transcript.json`.
    ///
    /// A trailing write armed for an earlier segment must not outlive this one: the M-01
    /// final pass overwrites `transcript.json` with long-window finals, and a late write
    /// of the live tier would put the shorter one back.
    private func writeTranscript(at clock: TimeInterval) {
        transcriptTrailingWrite?.cancel()
        transcriptTrailingWrite = nil
        let trace = LatencyTrace.start(.meetingTranscriptWrite)
        let saved = store.saveTranscript(segments, for: meeting.id)
        trace.end(note: "segments=\(segments.count)")
        transcriptThrottle.recordWrite(at: clock)
        if saved, let end = segments.map(\.end).max() {
            var integrity = meeting.captureIntegrity ?? .init()
            integrity.recordCaptured(until: startedAt.addingTimeInterval(end))
            meeting.captureIntegrity = integrity
            persistMeeting()
        }
        if !saved {
            transcriptThrottle.markPending()
            armTrailingTranscriptWrite()
            reportHealthIssue(.transcriptWriteFailure)
        }
    }

    /// M-16c: every exit path — `stop`, `endAbruptly` and `abort` — writes the file
    /// whatever the throttle thought. A meeting that is over must be on disk: the
    /// pipeline reads it next, and the next launch resumes from it.
    private func flushTranscript() {
        transcriptThrottle.markPending()
        writeTranscript(at: transcriptNow.timeIntervalSince1970)
    }

    /// Test-only (`--selftest-meeting-resume`, M-16c): one segment through the ordered
    /// insert and the throttled write, with no capture, no bus, no context store and no
    /// model — the two things M-16c governs, driven directly. `add` calls the same pair.
    func insertSegmentForTesting(_ segment: TranscriptSegment) {
        insertSegment(segment, now: transcriptNow)
    }

    private func abort(reason: String) async {
        tapRetry?.cancel()
        tapRetry = nil
        resourceHealthTask?.cancel()
        resourceHealthTask = nil
        captureHub.unsubscribe(.meeting)
        systemCapture.stop()
        clock?.cancel()
        clock = nil
        micContinuation?.finish()
        systemContinuation?.finish()
        micDrain?.cancel()
        systemDrain?.cancel()
        await micTranscriber?.cancel()
        await systemTranscriber?.cancel()
        micTranscriber = nil
        systemTranscriber = nil
        writer = nil
        meeting.status = .failed(reason)
        meeting.end = Date()
        // M-16c: the third exit path. A start that failed still has a folder, and a
        // segment that reached `add` before the failure is still a crash record.
        flushTranscript()
        persistMeeting()
    }
}

private struct MeetingAudioPacket: Sendable {
    let samples: [Float]
    let startFrame: Int
}

/// Capture callbacks cannot hop to the main actor to count loss. Keep one small,
/// synchronized count per session and ask the UI to surface the first gap.
private final class MeetingCaptureDrops: @unchecked Sendable {
    private let lock = NSLock()
    private var streamFrames = 0
    private var hubBuffers = 0
    private var lastMicAt: Date?
    private var lastSystemAt: Date?
    private var capturedUntil: Date?
    private var deferLive = false

    struct Snapshot: Sendable {
        var streamFrames: Int64
        var hubBuffers: Int
        var lastMicAt: Date?
        var lastSystemAt: Date?
        var capturedUntil: Date?
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(streamFrames: Int64(streamFrames), hubBuffers: hubBuffers,
                        lastMicAt: lastMicAt, lastSystemAt: lastSystemAt, capturedUntil: capturedUntil)
    }

    func observe(_ packet: MeetingAudioPacket, from source: AudioSource, beganAt: Date) {
        guard !packet.samples.isEmpty else { return }
        let end = beganAt.addingTimeInterval(Double(packet.startFrame + packet.samples.count) / ChunkedTranscriber.sampleRate)
        lock.lock()
        if source == .mic { lastMicAt = Date() } else { lastSystemAt = Date() }
        capturedUntil = max(capturedUntil ?? end, end)
        lock.unlock()
    }

    func setLiveTranscriptionDeferred(_ value: Bool) {
        lock.lock()
        deferLive = value
        lock.unlock()
    }

    var isLiveTranscriptionDeferred: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deferLive
    }

    func addStreamFrames(_ frames: Int) -> Bool {
        lock.lock()
        let wasClear = streamFrames == 0 && hubBuffers == 0
        streamFrames += frames
        lock.unlock()
        return wasClear
    }

    func addHubBuffers(_ count: Int) -> Bool {
        lock.lock()
        let wasClear = streamFrames == 0 && hubBuffers == 0
        hubBuffers += count
        lock.unlock()
        return wasClear
    }

    var hasLoss: Bool {
        lock.lock()
        let result = streamFrames > 0 || hubBuffers > 0
        lock.unlock()
        return result
    }
}

/// M-16c: when `transcript.json` is written while a meeting records.
///
/// The file is the meeting's crash record — `MeetingStore.resumeAction` decides from it
/// whether there is anything to resume — so it cannot be written rarely. But rewriting
/// the whole thing on every 2–5 s segment is the wrong kind of careful: a two-hour
/// meeting is ≈2,700 writes of a file that ends at half a megabyte, so the disk absorbs
/// roughly a gigabyte of rewriting to protect a record nobody reads until something went
/// wrong. The compromise is one write per interval, a trailing write so the newest
/// segment is never more than one interval from disk, and an unconditional flush on
/// every exit path — so a crash costs at most `interval` seconds of speech.
///
/// Pure, so `MeetingSession` and `--selftest-meeting-resume` decide by the same rule
/// and the case that pins the count also pins the interval.
struct TranscriptSaveThrottle {
    /// The task's number, and a limit: a crash may cost at most this much unwritten
    /// speech, and the old comment's argument ("a two-hour meeting that loses
    /// everything at minute 118") holds at a 5 s interval.
    static let interval: TimeInterval = 5

    /// When the file was last written, on the same clock as `now`. Nil before the first.
    private(set) var lastWrite: TimeInterval?
    /// Segments have arrived that the file does not have yet.
    private(set) var pending = false

    /// A segment is waiting to be in the file.
    mutating func markPending() { pending = true }

    /// The file holds everything again.
    mutating func recordWrite(at now: TimeInterval) {
        lastWrite = now
        pending = false
    }

    /// The rule on its own, so the table in the self-test reads as the specification:
    /// never write an unchanged file, write the first segment at once, and after that
    /// only once the interval has passed.
    func shouldWrite(at now: TimeInterval) -> Bool {
        Self.shouldWrite(now: now, lastWrite: lastWrite, pending: pending)
    }

    static func shouldWrite(now: TimeInterval, lastWrite: TimeInterval?, pending: Bool) -> Bool {
        guard pending else { return false }
        guard let lastWrite else { return true }
        return now - lastWrite >= interval
    }

    /// How long a trailing write should wait, so it lands when the next segment would.
    static func secondsUntilDue(now: TimeInterval, lastWrite: TimeInterval?) -> TimeInterval {
        guard let lastWrite else { return 0 }
        return max(0, interval - (now - lastWrite))
    }
}

enum MeetingError: LocalizedError {
    case microphoneDenied
    case noAudioFormat
    case alreadyRecording
    case startCancelled

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone."
        case .noAudioFormat:
            "No compatible audio format available for meeting capture."
        case .alreadyRecording:
            "A meeting is already being recorded."
        case .startCancelled:
            "Meeting recording startup was cancelled."
        }
    }
}
