import AVFoundation
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
    static func afterTranscribing(
        _ meeting: Meeting,
        store: MeetingStore = .shared,
        recoverDroppedAudio: Bool = false
    ) -> Meeting {
        guard let meeting = store.meeting(id: meeting.id) else { return meeting }
        let hasAudio = store.audioURL(for: meeting).flatMap {
            try? AVAudioFile(forReading: $0).length > 0
        } ?? false
        let hasTranscript = !store.transcript(for: meeting.id).isEmpty
        // Live ASR can produce no segments even though the recording contains speech.
        // The saved tracks are still eligible for the final pass in that case.
        guard hasTranscript || hasAudio else {
            return finish(meeting, store: store)
        }
        // M-01: with the final pass on and audio on disk, the meeting stays
        // `.transcribing` while `FinalTranscriptService` re-transcribes each track
        // in long windows; otherwise today's body runs as `afterFinalPass`.
        switch finalPassDecision(
            settingOn: Settings.shared.meetingsFinalPass,
            hasAudio: hasAudio,
            hasTranscript: hasTranscript,
            droppedAudio: recoverDroppedAudio
        ) {
        case .run:
            FinalTranscriptService.shared.process(meeting, store: store)
            return meeting
        case .skip(let pass):
            var updated = meeting
            if let pass {
                updated.transcriptPass = pass
                guard store.save(updated) else { return meeting }
            }
            return afterFinalPass(store.meeting(id: meeting.id) ?? updated, store: store)
        }
    }

    /// Whether the post-Stop final pass applies. Pure, so the resume planner (M-08)
    /// and the self-test decide the same way production does. The skip case carries
    /// the `Meeting.transcriptPass` value to record, or nil when the setting is off
    /// and nothing is recorded at all.
    static nonisolated func finalPassDecision(
        settingOn: Bool,
        hasAudio: Bool,
        hasTranscript: Bool = true,
        droppedAudio: Bool = false
    ) -> FinalPassDecision {
        // A saved recording is the recovery path when the live tier produced nothing
        // or shed windows. Run it even if the optional quality pass was switched off.
        if hasAudio && (!hasTranscript || droppedAudio) { return .run }
        guard settingOn else { return .skip(nil) }
        return hasAudio ? .run : .skip("live-only:no-audio")
    }

    /// Called once the final transcript is on disk — or immediately, when the final
    /// pass did not apply. This is today's `afterTranscribing` body: tell the
    /// speakers apart, then write the notes.
    @discardableResult
    static func afterFinalPass(
        _ meeting: Meeting, store: MeetingStore = .shared,
        notesService: NotesService = .shared,
        diarize: (@MainActor (Meeting) -> Void)? = nil
    ) -> Meeting {
        guard let meeting = store.meeting(id: meeting.id) else { return meeting }
        guard !store.transcript(for: meeting.id).isEmpty else {
            return finish(meeting, store: store)
        }
        guard shouldDiarize(meeting, store: store) else {
            return afterDiarizing(meeting, store: store, notesService: notesService)
        }

        var diarizing = meeting
        diarizing.status = .diarizing
        guard store.save(diarizing), let accepted = store.meeting(id: meeting.id) else { return meeting }
        if let diarize { diarize(accepted) }
        else { DiarizationService.shared.process(accepted) }
        return accepted
    }

    /// Called once speakers have been identified — or immediately, when they weren't.
    @discardableResult
    static func afterDiarizing(
        _ meeting: Meeting, store: MeetingStore = .shared,
        notesService: NotesService = .shared
    ) -> Meeting {
        guard let meeting = store.meeting(id: meeting.id) else { return meeting }
        guard Settings.shared.notesAutoGenerate, !store.transcript(for: meeting.id).isEmpty else {
            return finish(meeting, store: store)
        }

        var summarizing = meeting
        summarizing.status = .summarizing
        guard store.save(summarizing), let accepted = store.meeting(id: meeting.id) else { return meeting }
        notesService.summarize(accepted, announce: store === MeetingStore.shared)
        return accepted
    }

    /// The end of the line: nothing else is going to read this meeting's audio.
    ///
    /// The agent is asked from here and from `NotesService`'s own finish, which are the two
    /// ways a meeting reaches `.done` and are mutually exclusive — this one is the path
    /// where no notes were written. It refuses meetings it has already looked at, so a
    /// double call would cost nothing either way.
    ///
    /// `review` is where end-of-meeting reconcile lives: live `candidateActions` stay on
    /// the Actions tab, matching Workspace proposals fold into them, and an invented
    /// summary Doc is dropped before it reaches `proposals.json`.
    private static func finish(_ meeting: Meeting, store: MeetingStore = .shared) -> Meeting {
        guard var done = store.meeting(id: meeting.id) else { return meeting }
        // With automatic generation off (or no transcript to generate from), NotesService
        // never runs. The person's own lines still need to reach the finished Notes tab.
        if !saveManualNotesIfPresent(for: done.id, store: store), store === MeetingStore.shared {
            NotesService.shared.reportSaveFailure(for: done.id)
        }
        // A recording that had already failed keeps its failure. Reaching the end of the
        // pipeline is not the same as having worked.
        if !done.status.isFailure { done.status = .done }
        guard store.save(done) else { return meeting }
        // M-10: a temporary recording is scheduled for release 72 hours out rather
        // than deleted here; a kept one follows the unchanged rule.
        store.releaseAudioWhenDue(for: done.id, notesWritten: false)
        let finished = store.meeting(id: done.id) ?? done
        if !finished.status.isFailure { AgentService.shared.review(finished) }
        return finished
    }

    /// Keep the scratchpad's source file and put its current lines on the finished page.
    /// Merging with an existing document is idempotent, so a resumed finish cannot append
    /// another "Your notes" block or erase notes from a prior manual generation.
    @discardableResult
    static func saveManualNotesIfPresent(for id: UUID, store: MeetingStore) -> Bool {
        let manual = ScratchNotesMerger.markdown(store.scratchpad(for: id))
        guard !manual.isEmpty else { return true }
        let current = store.notes(for: id) ?? ""
        let merged = ScratchNotesMerger.merged(manual: manual, generated: current)
        guard merged != current else { return true }
        guard store.saveNotes(
            merged,
            for: id
        ) else { return false }
        if store === MeetingStore.shared { NotesService.shared.notesDidChange() }
        return true
    }

    /// Whether this meeting's speakers are worth telling apart, and can be.
    ///
    /// The audio is the hard requirement: a meeting recorded before the setting was turned
    /// on, or one whose writer failed, has nothing left to cluster.
    private static func shouldDiarize(_ meeting: Meeting, store: MeetingStore = .shared) -> Bool {
        guard meeting.captureIntegrity?.hasKnownSavedAudioLoss(on: .system) != true else { return false }
        return Settings.shared.meetingsDiarize && store.audioURL(for: meeting) != nil
    }
}

/// M-01: whether the post-Stop final pass runs, and what `Meeting.transcriptPass`
/// records when it does not.
enum FinalPassDecision: Sendable, Equatable {
    case run
    case skip(String?)
}
