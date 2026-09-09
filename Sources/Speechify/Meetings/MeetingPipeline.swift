import Foundation

/// What happens to a meeting between the last transcribed window and `.done`.
///
/// Two optional steps, in this order: tell the speakers apart, then write the notes. The
/// order is not arbitrary — the notes are generated from the transcript's own speaker
/// labels, so a name learned by diarization is a name an action item can be attributed to.
/// Reversing them would produce notes that say "someone" about a person the app had already
/// identified.
///
/// It lives here rather than inside `MeetingSession.stop()` because two things need to make
/// the same decision: the session, when a recording ends, and `DiarizationService`, when the
/// step it owns finishes. Neither waits for the next one — each hands over and lets go, so
/// the Record button comes back while the machine is still working.
@MainActor
enum MeetingPipeline {

    /// Called by the session once the transcript is on disk.
    ///
    /// - Returns: the meeting with the status it now has, so the caller's copy stays in step
    ///   with the file.
    @discardableResult
    static func afterTranscribing(_ meeting: Meeting, store: MeetingStore = .shared) -> Meeting {
        guard !store.transcript(for: meeting.id).isEmpty else {
            return finish(meeting, store: store)
        }
        guard shouldDiarize(meeting, store: store) else {
            return afterDiarizing(meeting, store: store)
        }

        var diarizing = meeting
        diarizing.status = .diarizing
        store.save(diarizing)
        DiarizationService.shared.process(diarizing)
        return diarizing
    }

    /// Called once speakers have been identified — or immediately, when they weren't.
    @discardableResult
    static func afterDiarizing(_ meeting: Meeting, store: MeetingStore = .shared) -> Meeting {
        guard Settings.shared.notesAutoGenerate, !store.transcript(for: meeting.id).isEmpty else {
            return finish(meeting, store: store)
        }

        var summarizing = meeting
        summarizing.status = .summarizing
        store.save(summarizing)
        NotesService.shared.summarize(summarizing, announce: true)
        return summarizing
    }

    /// The end of the line: nothing else is going to read this meeting's audio.
    ///
    /// The agent is asked from here and from `NotesService`'s own finish, which are the two
    /// ways a meeting reaches `.done` and are mutually exclusive — this one is the path
    /// where no notes were written. It refuses meetings it has already looked at, so a
    /// double call would cost nothing either way.
    private static func finish(_ meeting: Meeting, store: MeetingStore = .shared) -> Meeting {
        var done = meeting
        // A recording that had already failed keeps its failure. Reaching the end of the
        // pipeline is not the same as having worked.
        if !done.status.isFailure { done.status = .done }
        store.save(done)
        store.releaseAudio(for: done.id)
        let finished = store.meeting(id: done.id) ?? done
        AgentService.shared.review(finished)
        return finished
    }

    /// Whether this meeting's speakers are worth telling apart, and can be.
    ///
    /// The audio is the hard requirement: a meeting recorded before the setting was turned
    /// on, or one whose writer failed, has nothing left to cluster.
    private static func shouldDiarize(_ meeting: Meeting, store: MeetingStore = .shared) -> Bool {
        Settings.shared.meetingsDiarize && store.audioURL(for: meeting) != nil
    }
}
