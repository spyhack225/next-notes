import Foundation
import Observation

/// The one place notes are generated, whether the meeting just ended or the user asked again.
///
/// `MeetingSession` calls it once, between transcribing and done; the detail view's
/// Regenerate calls it for a meeting that finished days ago. Both go through here so there
/// is one answer to "is this meeting being summarised right now" — two callers each running
/// their own generator would put two multi-gigabyte models on a 16 GB machine at once.
@MainActor
@Observable
final class NotesService {
    static let shared = NotesService()

    /// What each running generation is doing, keyed by meeting.
    private(set) var steps: [UUID: NotesGenerator.Step] = [:]
    /// The last failure per meeting, for the banner in the detail view.
    private(set) var problems: [UUID: String] = [:]
    /// Bumped whenever `notes.md` changes, so a view showing it knows to re-read the file.
    private(set) var revision = 0

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    private let store: MeetingStore

    init(store: MeetingStore = .shared) {
        self.store = store
    }

    func step(for id: UUID) -> NotesGenerator.Step? { steps[id] }
    func isRunning(_ id: UUID) -> Bool { steps[id] != nil }
    func problem(for id: UUID) -> String? { problems[id] }
    func clearProblem(for id: UUID) { problems[id] = nil }

    // MARK: - Generating

    /// Writes notes for a meeting that has just been transcribed.
    ///
    /// Returns the display name of the model that wrote them, so the caller can record it on
    /// the meeting — or nil when nothing was written, which is a normal outcome: no model
    /// available, an empty transcript, automatic notes turned off.
    @discardableResult
    func generate(
        for meeting: Meeting,
        segments: [TranscriptSegment],
        preferring preferred: LLMProviderID? = nil
    ) async -> String? {
        let id = meeting.id
        guard !isRunning(id) else { return nil }

        let choice = preferred ?? Settings.shared.notesProvider
        guard let provider = await LLMProviders.resolve(preferring: choice) else {
            problems[id] = NotesError.noProvider.localizedDescription
            Log.llm.info("no notes provider available for \"\(meeting.title, privacy: .public)\"")
            return nil
        }

        steps[id] = NotesGenerator.Step(message: "Preparing\u{2026}", fraction: nil)
        problems[id] = nil
        defer { steps[id] = nil }

        do {
            let generator = NotesGenerator(provider: provider)
            let result = try await generator.notes(for: meeting, segments: segments) { step in
                Task { @MainActor [weak self] in self?.steps[id] = step }
            }
            // The meeting can be deleted while the model is generating, and `saveNotes`
            // would re-create the directory that `delete` just removed — a meeting the user
            // deleted minutes ago reappearing with notes and no audio.
            guard store.meeting(id: id) != nil else { return nil }
            store.saveNotes(result.markdown, for: id)
            revision += 1
            Log.llm.info("""
                notes for "\(meeting.title, privacy: .public)" — \
                \(result.providerID.rawValue, privacy: .public), \
                \(result.generatedTokens, privacy: .public) tokens in \
                \(Int(result.duration), privacy: .public)s\
                \(result.usedMapReduce ? " (map-reduce)" : "", privacy: .public)
                """)
            return result.providerID.displayName
        } catch is CancellationError {
            return nil
        } catch {
            problems[id] = error.localizedDescription
            Log.llm.error("notes failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Takes a meeting from `.summarizing` to `.done`, writing `notes.md` on the way.
    ///
    /// Returns immediately; the work runs in a task this service owns. That is the whole
    /// reason this isn't inside `MeetingSession.stop()`: summarising a two-hour meeting is
    /// minutes of work, and a `stop()` that waited for it would keep the session alive and
    /// the Record button disabled for all of them. The session hands the meeting over at
    /// `.summarizing` and lets go.
    /// - Parameter announce: post a "notes are ready" notification when they land. True for
    ///   the automatic pass at the end of a meeting, where the user has long since moved on;
    ///   false for Regenerate, where they are looking straight at the progress bar.
    func summarize(
        _ meeting: Meeting,
        using provider: LLMProviderID? = nil,
        announce: Bool = false
    ) {
        let id = meeting.id
        guard !isRunning(id), tasks[id] == nil else { return }

        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil }

            guard var updated = store.meeting(id: id) else { return }
            let previousStatus = updated.status
            updated.status = .summarizing
            store.save(updated)

            let segments = store.transcript(for: id)
            let model = await generate(for: updated, segments: segments, preferring: provider)

            // Re-read rather than write the captured copy back: the store's record may
            // have been rewritten while this ran, and it may be gone entirely — a deleted
            // meeting must stay deleted rather than be resurrected by this save.
            guard var finished = store.meeting(id: id) else { return }
            if let model { finished.notesModel = model }
            // A meeting whose notes couldn't be written is still a finished meeting — it has
            // a transcript. Only a recording that had already failed keeps its failure.
            finished.status = previousStatus.isFailure ? previousStatus : .done
            store.save(finished)
            // The last thing that had a use for the recording has finished with it — but
            // only on the automatic pass. Regenerate replays work that has already been
            // done, and a button offering to write the notes again is not a button that may
            // delete the recording they were written from.
            if announce { store.releaseAudio(for: id, notesWritten: model != nil) }
            // The agent reads the notes, so it is asked once they exist rather than when
            // the transcript did. Only on the automatic pass: Regenerate rewrites notes the
            // user is looking at, and a second set of proposals for the same meeting is not
            // what pressing it asked for.
            if announce { AgentService.shared.review(finished) }
            if announce, model != nil {
                Notifications.shared.postNotesReady(meeting: finished, model: model)
                // Announced from here rather than from `revision`, which also moves when
                // the user presses Regenerate with the meeting open in front of them —
                // telling them in the corner of the screen what they are already watching.
                IslandState.shared.announceNotesReady(finished)
            }
        }
    }

    /// Stops a generation that is no longer wanted — deleting the meeting is the one that
    /// matters, since the model would otherwise spend minutes writing notes for a folder
    /// that no longer exists.
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        steps[id] = nil
    }
}
