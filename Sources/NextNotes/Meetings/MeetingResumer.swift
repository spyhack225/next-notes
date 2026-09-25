import Foundation

/// What a launch-time repair decided for one interrupted meeting (M-08).
///
/// Computed purely from the status on disk, whether a transcript and audio survived,
/// and whether M-01's final pass is on — so the self-test and the repair decide the
/// same way. Resume itself lives in `MeetingResumer`, which takes injected runners.
enum ResumeAction: Equatable, Sendable {
    /// `.recording` / `.transcribing` with audio and the final pass on: re-transcribe
    /// each track in long windows (M-01), then continue the pipeline.
    case finalPass
    /// `.recording` / `.transcribing` with a non-empty transcript but no final pass:
    /// continue past it (diarize if possible, then notes).
    case pipelineAfterTranscript
    /// `.diarizing` with audio: identify speakers, then notes. With no audio the
    /// diarizer has nothing to read, so this also covers "skip to notes".
    case diarize
    /// `.summarizing`, or `.diarizing` with no audio: write the notes.
    case notes
    /// `.recording` / `.transcribing` with nothing transcribed and nothing to
    /// recover from: the meeting never started saying anything.
    case fail(String)
    /// `.extracting`: notes are already written; finished, queued re-extraction.
    case extractAgain
    /// Not interrupted (or not a meeting state): leave alone.
    case none
}

/// Executes a launch-repair plan with injected stage runners.
///
/// The runners are closures so `--selftest-meeting-resume` never touches a model:
/// production passes `FinalTranscriptService.shared.process`,
/// `MeetingPipeline.afterFinalPass`, `DiarizationService.shared.process` and
/// `NotesService.shared.summarize(_, announce: true)`; the test passes fakes that
/// write `notes.md` and advance the status the way the real services do.
///
/// Resumes run one meeting at a time, after launch settles (the `isBusy` gate —
/// production waits out foreground and voice work, the same gate the extraction
/// resume uses), and each meeting is watched until it leaves its active state
/// before the next starts. A resume either finishes a meeting or leaves a problem
/// and a non-active status, so the next launch never resumes it again.
@MainActor
struct MeetingResumer {
    var store: MeetingStore
    var finalPass: @MainActor (Meeting) -> Void
    var afterTranscript: @MainActor (Meeting) -> Void
    var diarize: @MainActor (Meeting) -> Void
    var notes: @MainActor (Meeting) -> Void
    var isBusy: @MainActor () -> Bool
    var busyPoll: Duration = .seconds(30)
    var settlePoll: Duration = .seconds(5)

    func resume(_ plan: [(UUID, ResumeAction)]) async {
        for (id, action) in plan {
            // Repair writes the failures and the re-extractions itself; only the four
            // stage actions have a runner to dispatch.
            switch action {
            case .finalPass, .pipelineAfterTranscript, .diarize, .notes:
                break
            case .fail, .extractAgain, .none:
                continue
            }
            // One meeting at a time, and only once launch has settled: a foreground
            // card or a live voice turn owns the machine first (the gate the extraction
            // resume already waits behind), and never while a new meeting records.
            while isBusy(), !Task.isCancelled {
                try? await Task.sleep(for: busyPoll)
            }
            guard !Task.isCancelled, let meeting = store.meeting(id: id) else { continue }
            switch action {
            case .finalPass: finalPass(meeting)
            case .pipelineAfterTranscript: afterTranscript(meeting)
            case .diarize: diarize(meeting)
            case .notes: notes(meeting)
            case .fail, .extractAgain, .none:
                continue
            }
            // Each stage runs in a task its own service owns, so this waits rather than
            // assumes. It ends when the meeting does — finished, or parked with a problem
            // by `StageWatch` — and a deleted meeting simply disappears from the store.
            while store.meeting(id: id)?.status.isActive == true, !Task.isCancelled {
                try? await Task.sleep(for: settlePoll)
            }
        }
    }
}
