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
    /// Bumped whenever a transcript's speaker labels change, so a view showing them knows to
    /// re-read. `MeetingStore` caches transcripts, and nothing else observes that cache.
    private(set) var revision = 0

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    private let store: MeetingStore

    init(store: MeetingStore = .shared) {
        self.store = store
    }

    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }
    func fraction(for id: UUID) -> Double? { progress[id] }
    func problem(for id: UUID) -> String? { problems[id] }
    /// Dismissing the banner also withdraws the retry it was offering, which is what
    /// `MeetingStore.releaseAudio` was holding the recording for.
    func clearProblem(for id: UUID) {
        problems[id] = nil
        store.releaseAudio(for: id)
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

    /// Stops a pass that is no longer wanted. Deleting the meeting is the case that matters.
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        progress[id] = nil
    }

    // MARK: - The work

    private func run(_ meeting: Meeting, then next: @escaping @MainActor () -> Void) {
        let id = meeting.id
        guard tasks[id] == nil else { return }

        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tasks[id] = nil
                self.progress[id] = nil
            }
            await diarize(id)
            next()
        }
    }

    /// - Returns: whether any speaker label was written.
    @discardableResult
    private func diarize(_ id: UUID) async -> Bool {
        guard let meeting = store.meeting(id: id) else { return false }
        guard let audio = store.audioURL(for: meeting) else {
            problems[id] = DiarizationError.noAudio.localizedDescription
            return false
        }

        progress[id] = 0
        problems[id] = nil

        // Routed through the model store as well as awaited below, so that a first meeting
        // which triggers the download shows it in Settings rather than looking like a
        // clustering pass that has stalled. Both calls land on the same in-flight load
        // inside the actor, so the models are still fetched once.
        LocalModelStore.shared.prepareDiarizer()

        do {
            // The system channel alone. Mixing the microphone back in would hand the
            // clusterer the user's own voice as a speaker in a track whose entire purpose is
            // to contain everyone else.
            let samples = try AudioConversion.samples(
                fromFileAt: audio,
                sampleRate: ChunkedTranscriber.sampleRate,
                channel: MeetingAudioWriter.systemChannel
            )
            let runs = try await MeetingDiarizer.shared.speakerRuns(in: samples) { fraction in
                Task { @MainActor [weak self] in self?.progress[id] = fraction }
            }
            try Task.checkCancellation()
            guard !runs.isEmpty else {
                Log.meeting.info("diarization found no speech on the system track")
                return false
            }

            let labelled = MeetingDiarizer.assign(store.transcript(for: id), to: runs)
            // The meeting can be deleted while the model is clustering, and `saveTranscript`
            // would re-create the directory `delete` just removed.
            guard store.meeting(id: id) != nil else { return false }
            store.saveTranscript(labelled, for: id)
            revision += 1

            let speakers = MeetingDiarizer.labels(in: labelled).count
            Log.meeting.info("""
                diarized "\(meeting.title, privacy: .public)" — \
                \(speakers, privacy: .public) speaker(s) on the system track
                """)
            return speakers > 0
        } catch is CancellationError {
            return false
        } catch {
            problems[id] = error.localizedDescription
            Log.meeting.error("diarization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
