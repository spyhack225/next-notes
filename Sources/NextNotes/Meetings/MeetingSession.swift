import AVFoundation
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
    private let systemCapture = SystemAudioCapture()

    private var micTranscriber: ChunkedTranscriber?
    private var systemTranscriber: ChunkedTranscriber?
    private var writer: MeetingAudioWriter?

    private var micDrain: Task<Void, Never>?
    private var systemDrain: Task<Void, Never>?
    private var micContinuation: AsyncStream<[Float]>.Continuation?
    private var systemContinuation: AsyncStream<[Float]>.Continuation?
    private var clock: Task<Void, Never>?

    private var startedAt = Date()
    private var isStopping = false

    init(meeting: Meeting, store: MeetingStore = .shared) {
        self.meeting = meeting
        self.store = store
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
        guard await Permissions.requestMicrophone() else {
            throw MeetingError.microphoneDenied
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ChunkedTranscriber.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingError.noAudioFormat
        }

        startedAt = Date()
        lastSpeechAt = startedAt
        meeting.start = startedAt
        meeting.status = .recording
        store.save(meeting)

        // Recorded whenever *something* is going to read it back: diarization reads
        // the system channel, and the M-01 final pass re-transcribes both channels
        // after Stop, each whether or not the user asked to keep a recording.
        // `MeetingStore.releaseAudio` deletes a temporary file again at the end of
        // the pipeline — M-10 gives that release a 72-hour window. Under 1 GB free
        // nothing is written at all: without audio the final pass records
        // `live-only:no-audio` and the pipeline continues on the live transcript,
        // and the problem below says so while it is still true.
        let keep = Settings.shared.meetingsKeepAudio
        let freeBytes = MeetingStore.freeBytes(at: MeetingStore.root)
        let wantsAudio = Self.shouldWriteAudio(
            keep: keep,
            diarize: Settings.shared.meetingsDiarize,
            finalPass: Settings.shared.meetingsFinalPass,
            freeBytes: freeBytes
        )
        if !wantsAudio,
           keep || Settings.shared.meetingsDiarize || Settings.shared.meetingsFinalPass {
            audioProblem = "Not enough disk space to keep a recording; the transcript is still being written."
            Log.meeting.info("meeting audio skipped: less than 1 GB free")
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
                let audioWriter = try MeetingAudioWriter(url: url, onWriteError: { [weak self] message in
                    Task { @MainActor in self?.audioProblem = message }
                })
                writer = audioWriter
                meeting.audioFileName = MeetingStore.audioFile
                meeting.audioIsTemporary = !keep
            } catch {
                Log.meeting.error("keep-audio disabled for this meeting: \(error.localizedDescription, privacy: .public)")
            }
        }

        let meetingID = meeting.id
        micTranscriber = ChunkedTranscriber(
            source: .mic,
            meetingID: meetingID,
            onProvisional: { [weak self] event in
                await self?.setProvisional(event)
            },
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
            onSegment: { [weak self] segment in
                await self?.add(segment)
            }
        )

        // Ordered drains, for the same reason `DictationController` uses one: a task per
        // buffer has no ordering guarantee, and out-of-order audio transcribes as word salad.
        let (micStream, micContinuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let (systemStream, systemContinuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.micContinuation = micContinuation
        self.systemContinuation = systemContinuation

        let micTranscriber = self.micTranscriber
        let systemTranscriber = self.systemTranscriber
        let writer = self.writer
        micDrain = Task.detached(priority: .userInitiated) {
            for await samples in micStream {
                await micTranscriber?.append(samples)
                await writer?.append(samples, from: .mic)
            }
        }
        systemDrain = Task.detached(priority: .userInitiated) {
            for await samples in systemStream {
                await systemTranscriber?.append(samples)
                await writer?.append(samples, from: .system)
            }
        }

        do {
            // Mic via the shared hub so wake KWS stays subscribed. System audio
            // stays on `SystemAudioCapture` — two tracks, two owners.
            try AudioCaptureHub.shared.subscribe(
                .meeting,
                outputFormat: format,
                onBuffer: { chunk in micContinuation.yield(AudioConversion.samples(of: chunk.buffer)) },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.micLevel = level }
                }
            )
        } catch {
            await abort(reason: error.localizedDescription)
            throw error
        }

        // The tap is the part that can be refused. Losing it costs the other half of the
        // conversation, not the recording.
        do {
            try await systemCapture.start(
                outputFormat: format,
                onBuffer: { chunk in systemContinuation.yield(AudioConversion.samples(of: chunk.buffer)) },
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
            Log.systemAudio.error("meeting continues on the microphone alone: \(error.localizedDescription, privacy: .public)")
        }

        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        // Warming Parakeet after capture is running rather than before means the first
        // seconds of the meeting are already on disk while the model loads.
        Task.detached(priority: .utility) {
            try? await TranscriptionQueue.shared.warmUp()
        }

        // The notes model is warmed here rather than at launch, which is the difference
        // between paying gigabytes of resident memory for the one hour a meeting is happening
        // and paying it all day for a meeting that might not. It also has to be here rather
        // than at the end: `NotesModelRuntime` releases the weights after ten idle minutes,
        // so warming at launch would usually have unloaded them again by the time a meeting
        // finished. A meeting that has started is the earliest honest signal that notes are
        // about to be wanted.
        if Settings.shared.notesAutoGenerate,
           // Only the built-in choice loads this runtime: Apple Intelligence, a local
           // server and the cloud need no warm-up, and warming the GGUF for them would
           // spend gigabytes and seconds on weights nothing will read.
           ModelRoleStore.shared.resolution(for: .meetingNotes).effective == .builtIn,
           // Any installed brain, not only the built-in file — a Mac whose only model
           // came from the library still deserves the warm start.
           InstalledModelLibrary.shared.hasUsableModel {
            Task.detached(priority: .background) {
                try? await NotesModelRuntime.shared.prepare()
            }
        }

        Log.meeting.info("recording \"\(self.meeting.title, privacy: .public)\"")
    }

    /// Stops capture, drains everything still in flight, and files the transcript.
    func stop() async {
        guard !isStopping, meeting.status == .recording else { return }
        isStopping = true
        let began = Date()

        AudioCaptureHub.shared.unsubscribe(.meeting)
        systemCapture.stop()
        clock?.cancel()
        clock = nil
        micLevel = 0
        systemLevel = 0

        meeting.end = Date()
        meeting.status = .transcribing
        store.save(meeting)

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
        // per meeting, both tracks summed. The final pass re-reads `audio.caf` and covers
        // it, so the line says so when there is audio to read; without one the number is
        // speech the transcript has lost.
        let skippedSeconds = (await micTranscriber?.droppedAudioSeconds ?? 0)
            + (await systemTranscriber?.droppedAudioSeconds ?? 0)
        if skippedSeconds > 0.01 {
            if meeting.audioFileName != nil {
                Log.meeting.info("""
                    live transcript skipped \(skippedSeconds, format: .fixed(precision: 1), privacy: .public)s; \
                    the final pass covers them
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
        writer = nil

        store.saveTranscript(segments, for: meeting.id)
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
        meeting = MeetingPipeline.afterTranscribing(meeting, store: store)

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
        guard meeting.status == .recording else { return }

        AudioCaptureHub.shared.unsubscribe(.meeting)
        systemCapture.stop()
        clock?.cancel()
        clock = nil
        micContinuation?.finish()
        systemContinuation?.finish()
        micDrain?.cancel()
        systemDrain?.cancel()

        meeting.end = Date()
        switch MeetingStore.resumeAction(
            for: .recording,
            hasTranscript: !segments.isEmpty,
            hasAudio: audioFileHasContent,
            finalPassOn: Settings.shared.meetingsFinalPass
        ) {
        case .fail(let message):
            meeting.status = .failed(message)
        case .finalPass, .pipelineAfterTranscript, .diarize, .notes, .extractAgain, .none:
            meeting.status = .transcribing
        }
        store.saveTranscript(segments, for: meeting.id)
        store.save(meeting)
    }

    /// Whether the writer has put anything on disk yet. The pass can only recover speech
    /// from a file with content, so a meeting whose writer never got a frame is the same
    /// as one with no recording at all.
    private var audioFileHasContent: Bool {
        guard let name = meeting.audioFileName else { return false }
        let path = store.directory(for: meeting.id).appendingPathComponent(name).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        return (size?.int64Value ?? 0) > 0
    }

    // MARK: - Internals

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
        let index = segments.firstIndex { $0.start > incoming.start } ?? segments.endIndex
        segments.insert(incoming, at: index)
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

        // Written on every segment rather than once at the end: a two-hour meeting that
        // loses everything because the app was force-quit at minute 118 is the failure
        // this feature can least afford, and the file is a few kilobytes.
        store.saveTranscript(segments, for: meeting.id)
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

    private func abort(reason: String) async {
        AudioCaptureHub.shared.unsubscribe(.meeting)
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
        store.save(meeting)
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
