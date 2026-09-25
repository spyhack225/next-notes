import Foundation

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

    private init() {}

    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }

    /// Stops a pass that is no longer wanted. Deleting the meeting is the case
    /// that matters (wired in `MeetingStore.delete` beside the other cancels).
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    /// Runs the final pass, then hands the meeting to whatever comes next.
    /// Returns immediately; the session that called it is already gone.
    func process(_ meeting: Meeting, store: MeetingStore = .shared) {
        let id = meeting.id
        guard tasks[id] == nil else { return }
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil }
            await self.run(id: id, store: store)
        }
    }

    private func run(id: UUID, store: MeetingStore) async {
        guard var meeting = store.meeting(id: id) else { return }
        guard let audio = store.audioURL(for: meeting) else {
            meeting.transcriptPass = "live-only:no-audio"
            store.save(meeting)
            _ = MeetingPipeline.afterFinalPass(meeting, store: store)
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
                let samples = try AudioConversion.samples(
                    fromFileAt: audio,
                    sampleRate: ChunkedTranscriber.sampleRate,
                    channel: channel
                )
                trackSeconds = Double(samples.count) / ChunkedTranscriber.sampleRate
                let track = try await MeetingFinalPass.transcribeTrack(
                    samples, source: source
                ) { window in
                    try await TranscriptionQueue.shared.transcribe(window, lane: .background)
                }
                windows += track.windows.count
                finalsByTrack[source] = track.segments
            }
            guard store.meeting(id: id) != nil else { return }

            var accepted: [AudioSource: Bool] = [:]
            var combined: [TranscriptSegment] = []
            for source in [AudioSource.mic, .system] as [AudioSource] {
                let final = finalsByTrack[source] ?? []
                let trackLive = live.filter { $0.source == source }
                let ok = MeetingFinalPass.accept(final: final, live: trackLive, source: source)
                accepted[source] = ok
                combined.append(contentsOf: ok ? final : trackLive)
            }
            let merged = MeetingFinalPass.merge(final: combined, live: live)
                .sorted { $0.start < $1.start }
            store.saveLiveTranscript(live, for: id)
            store.saveTranscript(merged, for: id)
            let allAccepted = accepted.values.allSatisfy { $0 }
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
            _ = MeetingPipeline.afterFinalPass(store.meeting(id: id) ?? meeting, store: store)
        } catch is CancellationError {
            keepLive(id: id, pass: "live-only:failed", store: store)
        } catch {
            Log.meeting.error("final pass failed: \(error.localizedDescription, privacy: .public)")
            keepLive(id: id, pass: "live-only:failed", store: store)
        }
    }

    /// The error path: the live transcript stays, the pass is named, and the
    /// pipeline continues. Never blocks diarization or notes on a failed pass.
    private func keepLive(id: UUID, pass: String, store: MeetingStore) {
        guard var meeting = store.meeting(id: id) else { return }
        meeting.transcriptPass = pass
        store.save(meeting)
        _ = MeetingPipeline.afterFinalPass(meeting, store: store)
    }
}
