import Foundation
import Observation

/// Every recorded meeting on disk, and the one in-memory list the UI observes.
///
/// One directory per meeting under `Application Support/Next Notes/Meetings/<uuid>/`:
///
/// ```
/// meeting.json     the small record; the only file this store keeps in memory
/// transcript.json  every segment, loaded on demand
/// transcript.live.json  the live 2–5 s tier, kept once the M-01 final pass
///                  replaces transcript.json with long-window finals (evidence)
/// notes.md         markdown, written by Phase 4
/// scratchpad.json  the lines the person typed themselves during the meeting; folded into
///                  notes.md after every generation pass, and never rewritten by one
/// notes.json       decisions, actions and questions extracted from notes.md (graph on only)
/// proposals.json   what the agent has offered to do and nobody has answered yet
/// audio.caf        two channels — L mic, R system — when keep-audio is on, or when
///                  diarization or the final pass is going to read it back (temporary
///                  then, released at the end of the pipeline)
/// ```
///
/// Separate from `RunLog` on purpose. Dictation history is an append-only log of one-line
/// utterances; a meeting is a folder of artefacts with a lifecycle, and forcing them into
/// one file would mean rewriting the user's dictation history every time a transcript grows.
@MainActor
@Observable
final class MeetingStore {
    static let shared = MeetingStore()

    /// Newest first — the order the list always wants.
    private(set) var meetings: [Meeting] = []

    /// Transcripts are large and most meetings are never opened, so they are read when a
    /// meeting is selected and cached from then on.
    ///
    /// `@ObservationIgnored` matters: `transcript(for:)` fills this cache, and it is called
    /// from a view's `body`. Mutating an observed property during view evaluation is what
    /// SwiftUI warns about and, with a cache, would re-invalidate the very view that filled
    /// it. Nothing observes the cache — the detail view is rebuilt when the selection
    /// changes, which is the only time a transcript can differ from what it is showing.
    @ObservationIgnored private var transcriptCache: [UUID: [TranscriptSegment]] = [:]

    /// Transcript plus notes as one haystack per meeting, for `matches(_:query:)`.
    /// `@ObservationIgnored` because it is read from a view's `body` on every keystroke;
    /// `searchRevision` is the observed thing that says a newly built entry has landed.
    @ObservationIgnored private var searchCache: [UUID: String] = [:]

    /// Unanswered agent proposals, cached for the same reason transcripts are: the Actions
    /// tab reads them from a view's `body`. `AgentService.revision` is the observed thing
    /// that says the file has changed.
    @ObservationIgnored private var proposalCache: [UUID: [AgentProposal]] = [:]

    /// Meetings whose text was rewritten while `prepareSearchIndex()` was reading it, so the
    /// copy that comes back from the background read is already stale and must be dropped
    /// rather than cached — a live meeting grows a transcript window every thirty seconds.
    @ObservationIgnored private var searchInvalidated: Set<UUID> = []

    /// Bumped when a batch of search text lands, so a list drawn while the index was still
    /// being built re-evaluates against the full text rather than titles alone.
    private(set) var searchRevision = 0

    /// Bumped when `scratchpad.json` is written, so a pane watching somebody type knows to
    /// re-read the file. It is the observed signal for the same reason `searchRevision` is:
    /// `scratchpad(for:)` opens the file on every call, so there is no cache to observe and
    /// something has to say when the answer changed.
    private(set) var scratchpadRevision = 0

    static var root: URL {
        let directory = AppIdentity.applicationSupportDirectory
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The directory this instance reads and writes. The production store uses
    /// `Self.root`; seeded-meeting self-tests use `isolated()` (M-08). The static
    /// root stays the answer for `KnowledgeIndexer.meetingsRoot`, which always
    /// means the production store's path.
    private let root: URL

    /// Test seam (M-08): a store rooted at a fresh temporary directory, so seeded
    /// interrupted meetings never touch the user's real `Meetings/`.
    static func isolated() -> MeetingStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NextNotesMeetingResumeTest-\(UUID().uuidString)", isDirectory: true
            )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return MeetingStore(root: url)
    }

    private init(root: URL = MeetingStore.root) {
        self.root = root
        reload()
    }

    // MARK: - Meetings

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []

        meetings = contents
            .compactMap { Self.loadMeeting(in: $0) }
            .sorted { $0.start > $1.start }
        searchCache.removeAll()
        searchInvalidated.removeAll()
    }

    func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    /// Plans what each still-running meeting resumes as, repairs the statuses, and
    /// returns the plan for `MeetingResumer`.
    ///
    /// Nothing releases audio here: a recording made only for a pipeline stage goes
    /// when that stage finishes, through the unchanged `releaseAudio` rule — never
    /// in repair. Called once at launch, before the scheduler starts.
    @discardableResult
    func repairInterruptedMeetings() -> [(UUID, ResumeAction)] {
        var plan: [(UUID, ResumeAction)] = []
        var interruptedExtractions: [UUID] = []
        for meeting in meetings where meeting.status.isActive {
            var repaired = meeting
            // Older recordings saved the audio link only at Stop. If the process died
            // first, a valid audio.caf survived but the resumer could not see it.
            // Adopt it conservatively: an orphan is kept, never auto-deleted, because
            // the original keep-audio choice was not persisted either.
            if repaired.audioFileName == nil,
               [.recording, .transcribing].contains(repaired.status) {
                let orphan = directory(for: meeting.id).appendingPathComponent(Self.audioFile)
                let size = (try? FileManager.default.attributesOfItem(atPath: orphan.path))?[.size]
                    as? NSNumber
                if (size?.int64Value ?? 0) > 4_096 {
                    repaired.audioFileName = Self.audioFile
                    repaired.audioIsTemporary = false
                    Log.meeting.info("recovered unlinked audio for \"\(meeting.title, privacy: .public)\"")
                }
            }
            let action = Self.resumeAction(
                for: repaired.status,
                hasTranscript: !transcript(for: meeting.id).isEmpty,
                hasAudio: audioURL(for: repaired) != nil
            )
            switch action {
            case .finalPass, .pipelineAfterTranscript:
                repaired.status = .transcribing
            case .diarize:
                repaired.status = .diarizing
            case .notes:
                repaired.status = .summarizing
            case .extractAgain:
                repaired.status = .done
                interruptedExtractions.append(meeting.id)
            case .fail(let message):
                repaired.status = .failed(message)
            case .none:
                continue
            }
            let lastTranscriptEnd = transcript(for: meeting.id).map(\.end).max()
                .map { meeting.start.addingTimeInterval($0) }
            let lastAudioWrite = audioURL(for: repaired).flatMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            let lastCaptured = [lastTranscriptEnd, lastAudioWrite].compactMap { $0 }.max()
            if meeting.status == .recording {
                // An armed calendar row still carries its scheduled end at the instant
                // of a crash. Show the last captured moment, not a duration the app
                // never recorded.
                repaired.end = lastCaptured ?? Date()
            } else if repaired.end == nil ||
                        (lastCaptured.map { repaired.end! > $0.addingTimeInterval(60) } ?? false) {
                // Also repairs a row that an older launch moved to `.transcribing`
                // without replacing the scheduled end.
                repaired.end = lastCaptured ?? Date()
            }
            save(repaired)
            plan.append((meeting.id, action))
            Log.meeting.info("repaired interrupted meeting \"\(meeting.title, privacy: .public)\"")
        }
        // Extraction is idempotent and queued: an interrupted one runs again once nothing in
        // the foreground needs the machine, rather than waiting for *Extract past meetings*.
        guard !interruptedExtractions.isEmpty else { return plan }
        Task { @MainActor [weak self] in
            for id in interruptedExtractions {
                while LiveKnowledgeIndexEnvironment.isForegroundBusy || LiveKnowledgeIndexEnvironment.isVoiceBusy,
                      !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                }
                guard let self, let meeting = self.meeting(id: id), meeting.status == .done else { continue }
                if KnowledgeExtractionService.shared.isEnabled {
                    await KnowledgeExtractionService.shared.extract(meeting, directory: self.directory(for: id))
                }
                // Not in repair: this is the stage that finishes. The notes were already
                // written when the meeting was interrupted, so the recording goes the way
                // it would have once notes were done — whether or not the extraction ran.
                // M-10: a temporary recording gets its 72-hour window from here too.
                self.releaseAudioWhenDue(for: id, notesWritten: true)
            }
        }
        return plan
    }

    /// Where an interrupted meeting resumes (M-08 Target 1). Pure, so the repair, the
    /// session's own abrupt end and the self-test decide the same way.
    /// Recovery reads surviving audio even when the normal final-pass preference is off:
    /// the live transcript may have stopped before the recording did.
    ///
    /// | Status on disk | transcript | audio | Action |
    /// |---|---|---|---|
    /// | `.recording` / `.transcribing` | any | yes | the final pass, then the pipeline |
    /// | `.recording` / `.transcribing` | non-empty | no | the pipeline from the transcript |
    /// | `.recording` / `.transcribing` | empty | no | failed — nothing was said |
    /// | `.diarizing` | — | yes | diarization, then notes |
    /// | `.diarizing` | — | no | notes |
    /// | `.summarizing` | — | — | notes |
    /// | `.extracting` | — | — | finished; re-extraction is queued |
    nonisolated static func resumeAction(
        for status: MeetingStatus,
        hasTranscript: Bool,
        hasAudio: Bool
    ) -> ResumeAction {
        switch status {
        case .recording, .transcribing:
            if hasAudio { return .finalPass }
            return hasTranscript
                ? .pipelineAfterTranscript
                : .fail("Next Notes quit before anything was transcribed.")
        case .diarizing:
            return hasAudio ? .diarize : .notes
        case .summarizing:
            return .notes
        case .extracting:
            return .extractAgain
        case .scheduled, .armed, .done, .failed:
            return .none
        }
    }

    /// Writes the record and refreshes the list in place.
    ///
    /// The list is patched rather than re-enumerated: this runs on every state transition
    /// of a live recording, and re-reading every meeting's JSON to learn one status is the
    /// kind of thing that only shows up as jank once a user has a few hundred of them.
    func save(_ meeting: Meeting) {
        let directory = directory(for: meeting.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stamped = meeting
        // M1-a: a calendar link implies a calendar title. An `.auto` placeholder saved
        // with an event id becomes `.calendar` here, so the scheduler — which this file
        // owns and `MeetingScheduler` does not need to touch — still records the link.
        if stamped.titleSource == nil, stamped.calendarEventID != nil,
           !Meeting.isPlaceholderTitle(stamped.title) {
            stamped.titleSource = .calendar
        }
        // A live session saving an older copy must not downgrade a rename: a stored
        // `.user` wins over an incoming `.auto`/nil for the same title.
        if let stored = meetings.first(where: { $0.id == stamped.id }),
           stored.effectiveTitleSource == .user, stamped.effectiveTitleSource != .user,
           stored.title == stamped.title {
            stamped.titleSource = .user
        }
        write(stamped, to: directory.appendingPathComponent(Self.recordFile))

        if let index = meetings.firstIndex(where: { $0.id == stamped.id }) {
            meetings[index] = stamped
        } else {
            meetings.append(stamped)
            meetings.sort { $0.start > $1.start }
        }
        // A finished meeting's speaker names or status changed what its chunks say.
        if !stamped.status.isActive { KnowledgeIndexer.shared.meetingChanged(stamped.id) }
    }

    /// Changes the name a person sees in the list. Empty after trimming is refused, so a
    /// meeting can never lose the required `title` that decode treats as identity-adjacent.
    ///
    /// M1-a: a rename flips the source to `.user` *before* any memory is written, so the
    /// activity refresh that follows learns a name the person chose, never a placeholder.
    @discardableResult
    func rename(_ meeting: Meeting, to rawTitle: String) -> Bool {
        guard let title = MeetingTitle.cleaned(rawTitle) else { return false }
        var updated = self.meeting(id: meeting.id) ?? meeting
        updated.title = title
        updated.titleSource = .user
        save(updated)
        MeetingContextStore.shared.rename(meetingID: updated.id, to: title)
        MeetingController.shared.syncTitle(of: updated.id, to: title)
        // The renamed title is worth remembering; placeholders never reach the store
        // (see `NextMemory.refreshFromActivity` and the `Meeting ·` backstop).
        NextMemory.shared.remember(.meeting, key: title, value: title, source: "meeting:\(updated.id.uuidString)")
        return true
    }

    /// Removes a meeting and everything it produced.
    ///
    /// The work still running on it is stopped first, and from here rather than from each
    /// Delete button: a generation or a clustering pass writes `transcript.json`, `notes.md`
    /// and `meeting.json` when it finishes, which would re-create the directory removed on
    /// the line below and put the deleted meeting back in the list.
    func delete(_ meeting: Meeting) {
        NotesService.shared.cancel(meeting.id)
        DiarizationService.shared.cancel(meeting.id)
        FinalTranscriptService.shared.cancel(meeting.id)
        AgentService.shared.cancel(meeting.id)
        try? FileManager.default.removeItem(at: directory(for: meeting.id))
        meetings.removeAll { $0.id == meeting.id }
        transcriptCache[meeting.id] = nil
        proposalCache[meeting.id] = nil
        searchCache[meeting.id] = nil
        searchInvalidated.insert(meeting.id)
        // Or the index confidently cites a meeting that no longer exists.
        KnowledgeIndexer.shared.removeMeeting(meeting.id)
    }

    // MARK: - Artefacts

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func transcript(for id: UUID) -> [TranscriptSegment] {
        if let cached = transcriptCache[id] { return cached }
        let url = directory(for: id).appendingPathComponent(Self.transcriptFile)
        guard let data = try? Data(contentsOf: url),
              let segments = try? Self.decoder.decode([TranscriptSegment].self, from: data)
        else { return [] }
        transcriptCache[id] = segments
        return segments
    }

    @discardableResult
    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID) -> Bool {
        let directory = directory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard write(segments, to: directory.appendingPathComponent(Self.transcriptFile)) else {
            return false
        }
        transcriptCache[id] = segments
        searchCache[id] = nil
        searchInvalidated.insert(id)
        KnowledgeIndexer.shared.meetingChanged(id)
        return true
    }

    /// The live 2–5 s tier, saved before the M-01 final pass overwrites
    /// `transcript.json` with the long-window finals. Text, not audio: `releaseAudio`
    /// never deletes it, and it is the evidence when the pass is questioned.
    func saveLiveTranscript(_ segments: [TranscriptSegment], for id: UUID) {
        let directory = directory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        write(segments, to: directory.appendingPathComponent(Self.liveTranscriptFile))
    }

    /// The live tier for one meeting, or empty when the final pass never ran.
    /// Uncached on purpose: only the quality report reads it, once per meeting.
    func liveTranscript(for id: UUID) -> [TranscriptSegment] {
        let url = directory(for: id).appendingPathComponent(Self.liveTranscriptFile)
        guard let data = try? Data(contentsOf: url),
              let segments = try? Self.decoder.decode([TranscriptSegment].self, from: data)
        else { return [] }
        return segments
    }

    func notes(for id: UUID) -> String? {
        try? String(contentsOf: directory(for: id).appendingPathComponent(Self.notesFile), encoding: .utf8)
    }

    @discardableResult
    func saveNotes(_ markdown: String, for id: UUID) -> Bool {
        let directory = directory(for: id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try markdown.write(
                to: directory.appendingPathComponent(Self.notesFile),
                atomically: true,
                encoding: .utf8
            )
            searchCache[id] = nil
            searchInvalidated.insert(id)
            KnowledgeIndexer.shared.meetingChanged(id)
            return true
        } catch {
            Log.meeting.error("couldn't save notes: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Hand-written notes

    /// The lines the person typed themselves during this meeting, oldest first.
    ///
    /// Uncached exactly like `notes(for:)`: a line is added while the meeting is still
    /// running and read back at once, so a cache would be a second answer to a question
    /// whose file is one read away. The file is the record, and `saveScratchpad` is the
    /// only thing that writes it.
    func scratchpad(for id: UUID) -> [MeetingScratchNote] {
        let url = directory(for: id).appendingPathComponent(Self.scratchpadFile)
        guard let data = try? Data(contentsOf: url),
              let notes = try? Self.decoder.decode([MeetingScratchNote].self, from: data)
        else { return [] }
        return Self.ordered(notes)
    }

    /// Writes the hand-written lines, keeping the most recent `maxStored`.
    ///
    /// Atomic for the reason `meeting.json` is: this is written while a meeting is running
    /// and a half-written file would lose notes the person cannot type again. Search and
    /// the knowledge index are invalidated the way `saveNotes` invalidates them, because a
    /// typed line is the meeting's own text and belongs in the same haystack as its
    /// transcript — `NotesService` folds the same lines into `notes.md` when the notes are
    /// written, which is where they are chunked.
    @discardableResult
    func saveScratchpad(_ notes: [MeetingScratchNote], for id: UUID) -> Bool {
        let directory = directory(for: id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.meeting.error("couldn't save scratchpad: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let ordered = Self.ordered(notes)
        // The freeform page is the person's ongoing document. A long meeting may produce
        // more than 200 captured lines, but that must never evict the page written first.
        let pages = Array(ordered.filter { $0.kind == .document }
            .suffix(MeetingScratchNote.maxStored))
        let lines = Array(ordered.filter { $0.kind == .line }
            .suffix(MeetingScratchNote.maxStored - pages.count))
        let retainedIDs = Set((pages + lines).map(\.id))
        let kept = ordered.filter { retainedIDs.contains($0.id) }
        guard write(kept, to: directory.appendingPathComponent(Self.scratchpadFile)) else {
            return false
        }
        scratchpadRevision += 1
        searchCache[id] = nil
        searchInvalidated.insert(id)
        KnowledgeIndexer.shared.meetingChanged(id)
        return true
    }

    /// By when each line was typed, ties keeping the order they arrived in.
    ///
    /// Swift's sort is not stable, and two lines typed inside the same millisecond would
    /// otherwise swap places on every read — which reads as the list shuffling itself
    /// under the person typing. The tie-break is the file's own order, which is the order
    /// the list was last saved in.
    private nonisolated static func ordered(_ notes: [MeetingScratchNote]) -> [MeetingScratchNote] {
        notes.enumerated().sorted { earlier, later in
            earlier.element.at == later.element.at
                ? earlier.offset < later.offset
                : earlier.element.at < later.element.at
        }.map(\.element)
    }

    /// What the agent has offered to do about this meeting and nobody has answered.
    ///
    /// On disk rather than in memory because a proposal outlives the process: notes land
    /// minutes after a meeting ends, the user reads them the next morning, and a proposal
    /// that evaporated at quit is a feature that only worked if you were watching.
    func proposals(for id: UUID) -> [AgentProposal] {
        if let cached = proposalCache[id] { return cached }
        let url = directory(for: id).appendingPathComponent(Self.proposalsFile)
        guard let data = try? Data(contentsOf: url),
              let proposals = try? Self.decoder.decode([AgentProposal].self, from: data)
        else { return [] }
        proposalCache[id] = proposals
        return proposals
    }

    func saveProposals(_ proposals: [AgentProposal], for id: UUID) {
        let directory = directory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.proposalsFile)
        if proposals.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            write(proposals, to: url)
        }
        proposalCache[id] = proposals
    }

    /// The recorded audio, when this meeting kept any.
    func audioURL(for meeting: Meeting) -> URL? {
        guard let name = meeting.audioFileName else { return nil }
        let url = directory(for: meeting.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Drops the recording once everything made from it has been made.
    ///
    /// Called at the end of the pipeline rather than by whoever wrote the audio, because
    /// what the audio was *for* is only knowable there: a meeting records itself so its
    /// speakers can be told apart even when the user never asked to keep a recording, and
    /// silently leaving 230 MB an hour behind for that is not a bargain anyone agreed to.
    ///
    /// The whole keep-or-drop rule lives here, and it is three lines:
    ///
    /// - A recording made only for diarization (`Meeting.audioIsTemporary`) goes. That
    ///   answer was written when the recording started, so changing the settings later
    ///   never turns a recording the user asked to keep into one this method may delete.
    /// - A recording the user asked to keep goes only when "delete once the notes are
    ///   written" is on *and* notes were actually written; a generation that failed, or
    ///   never ran, leaves the audio alone rather than deleting the one copy of a meeting
    ///   nothing was made from.
    /// - Nothing goes while a failed diarization pass is still offering "Identify again",
    ///   because that retry has nothing to read without it.
    ///
    /// M-10: the pipeline end no longer calls this directly — `releaseAudioWhenDue`
    /// schedules a temporary recording's release 72 hours out first, and the sweep
    /// and the speaker-confirm action reach here at their own moments. This method
    /// stays the only thing in the app that deletes a recording.
    ///
    /// - Parameter notesWritten: whether the pass that is finishing rewrote `notes.md`.
    func releaseAudio(for id: UUID, notesWritten: Bool = false) {
        guard var meeting = meeting(id: id), let name = meeting.audioFileName else { return }
        guard DiarizationService.shared.problem(for: id) == nil else { return }
        if meeting.audioIsTemporary != true {
            guard Settings.shared.meetingsDeleteAudioAfterNotes, notesWritten else { return }
        }

        try? FileManager.default.removeItem(at: directory(for: id).appendingPathComponent(name))
        meeting.audioFileName = nil
        save(meeting)
        Log.meeting.info("released audio for \"\(meeting.title, privacy: .public)\"")
    }

    // MARK: - Audio retention (M-10)

    /// How long a finished temporary recording keeps its file past the pipeline
    /// end before the sweep takes it (M-10).
    nonisolated static let temporaryAudioRetention: TimeInterval = 72 * 60 * 60
    /// The retention disk guard: with less free space than this, "as today" wins
    /// and temporary audio is released at once instead of kept for the window.
    nonisolated static let minimumFreeBytesForRetention: Int64 = 5_000_000_000

    /// Free bytes available for important usage on the volume holding `url`.
    /// `.max` when unknowable: a missing answer must never delete a recording.
    nonisolated static func freeBytes(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap(\.volumeAvailableCapacityForImportantUsage) ?? .max
    }

    /// Ends the pipeline's use of a recording the way M-10 says: a temporary file is
    /// scheduled for release instead of deleted at once, a kept one follows the
    /// unchanged `releaseAudio` rule immediately.
    ///
    /// M-10 changes when `releaseAudio` runs, never its rule. A temporary
    /// recording (`audioIsTemporary == true`, the answer written when the recording
    /// started) keeps its file for `temporaryAudioRetention` — 72 hours past the
    /// pipeline end, which is what makes a later "Identify again" possible (M-03) —
    /// unless the disk is under `minimumFreeBytesForRetention`, where "as today"
    /// wins and it goes now. The window is stamped once: a second pipeline end
    /// (Regenerate re-announcing, extraction finishing late) neither shortens nor
    /// extends it, and a window that has already passed releases now. Every delete
    /// still goes through `releaseAudio`; this method and the sweep only decide when.
    ///
    /// - Parameters:
    ///   - notesWritten: whether the pass that is finishing rewrote `notes.md`
    ///     (read only by the kept-recording rule).
    ///   - now: injected so the self-test decides the same way production does.
    ///   - freeBytes: injected free space; measured at this store's root when nil.
    func releaseAudioWhenDue(
        for id: UUID,
        notesWritten: Bool,
        now: Date = Date(),
        freeBytes injectedFree: Int64? = nil
    ) {
        guard var meeting = meeting(id: id), meeting.audioFileName != nil else { return }
        // A recording the user asked to keep: the unchanged rule, now.
        if meeting.audioIsTemporary != true {
            releaseAudio(for: id, notesWritten: notesWritten)
            return
        }
        let free = injectedFree ?? Self.freeBytes(at: root)
        guard free >= Self.minimumFreeBytesForRetention else {
            // Under the guard there is nothing to be patient about.
            releaseAudio(for: id, notesWritten: notesWritten)
            return
        }
        if let due = meeting.audioReleaseAfter {
            // A window that has already passed releases now; a live one is left
            // exactly as it was first written.
            if due <= now { releaseAudio(for: id, notesWritten: notesWritten) }
            return
        }
        meeting.audioReleaseAfter = now.addingTimeInterval(Self.temporaryAudioRetention)
        save(meeting)
        Log.meeting.info("""
            temporary audio kept for "\(meeting.title, privacy: .public)" — \
            release in \(Int(Self.temporaryAudioRetention / 3600), privacy: .public) h
            """)
    }

    /// Releases temporary recordings that are past their window, and — while the
    /// disk is under `minimumFreeBytesForRetention` — the oldest temporary
    /// recordings first, whatever their window says.
    ///
    /// Never a meeting that is still active (a resume is running through exactly
    /// those statuses, so a sweep during repair cannot touch one), never a meeting
    /// whose diarization problem is still offering "Identify again", and never a
    /// kept recording. Every delete still goes through `releaseAudio`, whose own
    /// problem guard answers the same question a second time.
    ///
    /// - Parameters:
    ///   - now: injected so the self-test decides the same way production does.
    ///   - freeBytes: injected free space; measured at this store's root when nil.
    ///   - hasDiarizationProblem: production passes nil, which reads
    ///     `DiarizationService.shared`; the self-test injects its own answer
    ///     because the shared service reads the production store.
    /// - Returns: how many recordings were released.
    @discardableResult
    func sweepExpiredAudio(
        now: Date = Date(),
        freeBytes injectedFree: Int64? = nil,
        hasDiarizationProblem: ((UUID) -> Bool)? = nil
    ) -> Int {
        let problem = hasDiarizationProblem ?? { DiarizationService.shared.problem(for: $0) != nil }
        let candidates = meetings
            .filter { $0.audioIsTemporary == true && $0.audioFileName != nil }
            .filter { !$0.status.isActive }
            .filter { !problem($0.id) }
            .sorted { $0.start < $1.start }

        var released = 0
        var free = injectedFree ?? Self.freeBytes(at: root)
        for meeting in candidates {
            let expired = meeting.audioReleaseAfter.map { now >= $0 } ?? false
            let diskTight = free < Self.minimumFreeBytesForRetention
            guard expired || diskTight else { continue }
            releaseAudio(for: meeting.id)
            released += 1
            // Re-measure between releases: the point of the disk guard is to
            // reclaim only what the space needs, oldest first.
            free = injectedFree ?? Self.freeBytes(at: root)
        }
        if released > 0 {
            Log.meeting.info("retention sweep released \(released, privacy: .public) recording(s)")
        }
        return released
    }

    // MARK: - Search

    /// Whether a meeting matches a search string, looking at everything it holds.
    ///
    /// Called from a view's `body`, once per meeting, on every keystroke — so it opens no
    /// files. The title is matched directly and everything else against the haystack
    /// `prepareSearchIndex()` built off the main actor; a meeting whose text hasn't landed
    /// yet matches on its title alone for that frame, and `searchRevision` brings it back
    /// when it does.
    func matches(_ meeting: Meeting, query: String) -> Bool {
        // Reading the revision is what subscribes the calling view to the index landing:
        // the cache it reads below is deliberately unobserved.
        _ = searchRevision
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if meeting.title.localizedCaseInsensitiveContains(needle) { return true }
        return searchCache[meeting.id]?.localizedCaseInsensitiveContains(needle) ?? false
    }

    /// Reads each meeting's transcript and notes into one haystack, off the main actor.
    ///
    /// Two file reads and a JSON decode per meeting is nothing for one meeting and a frozen
    /// window for two hundred, which is what doing it inside `matches` amounted to. It also
    /// deliberately bypasses `transcript(for:)`: that cache exists so the transcripts of
    /// meetings nobody opens are never held in memory, and a full-library search would have
    /// filled it with every one of them.
    ///
    /// Called when the search field first has something in it, and cheap to call again — a
    /// meeting already in the cache is not read twice.
    func prepareSearchIndex() async {
        let pending = meetings.map(\.id).filter { searchCache[$0] == nil }
        guard !pending.isEmpty else { return }
        searchInvalidated.subtract(pending)

        let root = self.root
        let built = await Task.detached(priority: .utility) {
            pending.reduce(into: [UUID: String]()) { haystacks, id in
                haystacks[id] = Self.searchText(in: root.appendingPathComponent(id.uuidString, isDirectory: true))
            }
        }.value

        for (id, text) in built where !searchInvalidated.contains(id) {
            searchCache[id] = text
        }
        searchInvalidated.subtract(built.keys)
        searchRevision += 1
    }

    /// Everything in one meeting's folder worth searching. `nonisolated` so the read happens
    /// on whichever thread the index is being built on.
    private nonisolated static func searchText(in directory: URL) -> String {
        let transcript = (try? Data(contentsOf: directory.appendingPathComponent(transcriptFile)))
            .flatMap { try? decoder.decode([TranscriptSegment].self, from: $0) } ?? []
        let notes = try? String(
            contentsOf: directory.appendingPathComponent(notesFile),
            encoding: .utf8
        )
        return transcript.map(\.text).joined(separator: "\n") + "\n" + (notes ?? "")
    }

    // MARK: - Files

    /// `nonisolated` so the background search index can name the files it reads.
    nonisolated static let recordFile = "meeting.json"
    nonisolated static let transcriptFile = "transcript.json"
    nonisolated static let liveTranscriptFile = "transcript.live.json"
    nonisolated static let notesFile = "notes.md"
    /// The lines the person typed themselves during the meeting. Its own file beside
    /// `notes.md` rather than inside it, because the notes are rewritten by every
    /// generation pass and a hand-written line has to survive all of them.
    nonisolated static let scratchpadFile = "scratchpad.json"
    /// Decisions, action items and open questions extracted from `notes.md`, stamped with the
    /// same generation as its chunks in the knowledge index (Part 4, Phase C).
    nonisolated static let notesJSONFile = "notes.json"
    nonisolated static let proposalsFile = "proposals.json"
    nonisolated static let audioFile = "audio.caf"

    private nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func loadMeeting(in directory: URL) -> Meeting? {
        let url = directory.appendingPathComponent(recordFile)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Meeting.self, from: data)
    }

    /// Atomic on purpose: this is written from a state machine that can be interrupted by
    /// a crash or a forced quit, and a half-written `meeting.json` makes the whole meeting
    /// invisible on the next launch.
    @discardableResult
    private func write(_ value: some Encodable, to url: URL) -> Bool {
        do {
            let data = try Self.encoder.encode(value)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.meeting.error("couldn't write \(url.lastPathComponent): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
