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

    private let store: MeetingStore
    private let micCapture = AudioCapture()
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

        // Recorded whenever *something* is going to read it back, which includes a meeting
        // whose speakers will be identified even though the user never asked to keep a
        // recording. `MeetingStore.releaseAudio` deletes it again at the end of the pipeline.
        if Settings.shared.meetingsKeepAudio || Settings.shared.meetingsDiarize {
            let url = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.audioFile)
            try? FileManager.default.createDirectory(
                at: store.directory(for: meeting.id),
                withIntermediateDirectories: true
            )
            do {
                writer = try MeetingAudioWriter(url: url)
                meeting.audioFileName = MeetingStore.audioFile
                meeting.audioIsTemporary = !Settings.shared.meetingsKeepAudio
            } catch {
                Log.meeting.error("keep-audio disabled for this meeting: \(error.localizedDescription, privacy: .public)")
            }
        }

        micTranscriber = ChunkedTranscriber(source: .mic) { [weak self] segment in
            await self?.add(segment)
        }
        systemTranscriber = ChunkedTranscriber(source: .system) { [weak self] segment in
            await self?.add(segment)
        }

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
            try micCapture.start(
                outputFormat: format,
                onBuffer: { chunk in micContinuation.yield(AudioConversion.samples(of: chunk.buffer)) },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.micLevel = level }
                }
            )
            WakeWordAudioMonitor.shared.beginHold()
        } catch {
            await abort(reason: error.localizedDescription)
            throw error
        }

        // The tap is the part that can be refused. Losing it costs the other half of the
        // conversation, not the recording.
        do {
            try systemCapture.start(
                outputFormat: format,
                onBuffer: { chunk in systemContinuation.yield(AudioConversion.samples(of: chunk.buffer)) },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.systemLevel = level }
                }
            )
        } catch {
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
        // between paying 2.7 GB of resident memory for the one hour a meeting is happening
        // and paying it all day for a meeting that might not. It also has to be here rather
        // than at the end: `NotesModelRuntime` releases the weights after ten idle minutes,
        // so warming at launch would usually have unloaded them again by the time a meeting
        // finished. A meeting that has started is the earliest honest signal that notes are
        // about to be wanted.
        if Settings.shared.notesAutoGenerate,
           Settings.shared.notesProvider == .qwen35_4b,
           NotesModels.isDownloaded {
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

        micCapture.stop()
        systemCapture.stop()
        WakeWordAudioMonitor.shared.endHold()
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
        micTranscriber = nil
        systemTranscriber = nil

        await writer?.finish()
        writer = nil

        store.saveTranscript(segments, for: meeting.id)

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
    func endAbruptly() {
        guard meeting.status == .recording else { return }

        micCapture.stop()
        systemCapture.stop()
        WakeWordAudioMonitor.shared.endHold()
        clock?.cancel()
        clock = nil
        micContinuation?.finish()
        systemContinuation?.finish()
        micDrain?.cancel()
        systemDrain?.cancel()

        meeting.end = Date()
        meeting.status = segments.isEmpty
            ? .failed("Next Notes quit before anything was transcribed.")
            : .done
        store.saveTranscript(segments, for: meeting.id)
        store.save(meeting)
    }

    // MARK: - Internals

    /// Segments arrive from two transcribers, so they are inserted by time rather than
    /// appended: the system track can finish a window that started before one the mic track
    /// has already delivered.
    private func add(_ segment: TranscriptSegment) {
        lastSpeechAt = Date()
        let incoming = ActivationController.shared.handleWake(in: segment)
        let index = segments.firstIndex { $0.start > incoming.start } ?? segments.endIndex
        segments.insert(incoming, at: index)
        MeetingContextStore.shared.ingest(segments, meeting: meeting)
        // Written on every segment rather than once at the end: a two-hour meeting that
        // loses everything because the app was force-quit at minute 118 is the failure
        // this feature can least afford, and the file is a few kilobytes.
        store.saveTranscript(segments, for: meeting.id)
    }

    private func abort(reason: String) async {
        micCapture.stop()
        systemCapture.stop()
        WakeWordAudioMonitor.shared.endHold()
        clock?.cancel()
        clock = nil
        micContinuation?.finish()
        systemContinuation?.finish()
        micDrain?.cancel()
        systemDrain?.cancel()
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

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone."
        case .noAudioFormat:
            "No compatible audio format available for meeting capture."
        case .alreadyRecording:
            "A meeting is already being recorded."
        }
    }
}
