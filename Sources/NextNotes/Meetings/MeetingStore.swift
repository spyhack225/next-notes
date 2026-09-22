import Foundation
import Observation

/// Every recorded meeting on disk, and the one in-memory list the UI observes.
///
/// One directory per meeting under `Application Support/Next Notes/Meetings/<uuid>/`:
///
/// ```
/// meeting.json     the small record; the only file this store keeps in memory
/// transcript.json  every segment, loaded on demand
/// notes.md         markdown, written by Phase 4
/// notes.json       decisions, actions and questions extracted from notes.md (graph on only)
/// proposals.json   what the agent has offered to do and nobody has answered yet
/// audio.caf        two channels — L mic, R system — only when keep-audio is on
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

    static var root: URL {
        let directory = AppIdentity.applicationSupportDirectory
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private init() {
        reload()
    }

    // MARK: - Meetings

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.root,
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

    /// Marks meetings that were still running when the app died.
    ///
    /// Nothing else can clear those states: the session that owned them is gone, and a row
    /// that says "Recording" on a machine that is recording nothing is the kind of lie that
    /// makes a user stop trusting the whole feature. Called once at launch.
    func repairInterruptedMeetings() {
        var interruptedExtractions: [UUID] = []
        for meeting in meetings where meeting.status.isActive {
            var repaired = meeting
            let hadTranscript = Self.hadTranscript(meeting.status)
            repaired.status = Self.repairedStatus(meeting.status)
            if repaired.end == nil { repaired.end = Date() }
            save(repaired)
            // A meeting repaired to done is finished, and nothing will run on it again:
            // `MeetingPipeline` and `NotesService` only walk a meeting that is still on its
            // way to done. Without this, a recording written purely for a diarization pass
            // that the crash interrupted would sit under Application Support for good.
            // `.extracting` comes after the notes were written, so the recording goes the way
            // it would have once notes were done.
            if hadTranscript { releaseAudio(for: repaired.id, notesWritten: meeting.status == .extracting) }
            if meeting.status == .extracting { interruptedExtractions.append(meeting.id) }
            Log.meeting.info("repaired interrupted meeting \"\(meeting.title, privacy: .public)\"")
        }
        // Extraction is idempotent and queued: an interrupted one runs again once nothing in
        // the foreground needs the machine, rather than waiting for *Extract past meetings*.
        guard !interruptedExtractions.isEmpty else { return }
        Task { @MainActor [weak self] in
            for id in interruptedExtractions {
                while LiveKnowledgeIndexEnvironment.isForegroundBusy || LiveKnowledgeIndexEnvironment.isVoiceBusy,
                      !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                }
                guard let self, let meeting = self.meeting(id: id), meeting.status == .done,
                      KnowledgeExtractionService.shared.isEnabled else { continue }
                await KnowledgeExtractionService.shared.extract(meeting, directory: self.directory(for: id))
            }
        }
    }

    /// A meeting interrupted while diarising, summarising or extracting is not a lost meeting:
    /// the transcript was written before any of them started, so it is finished — just
    /// without speaker names, notes or a graph, which Regenerate can write whenever the user
    /// wants them.
    nonisolated static func hadTranscript(_ status: MeetingStatus) -> Bool {
        status == .diarizing || status == .summarizing || status == .extracting
    }

    /// What an interrupted meeting becomes at launch. Inactive states are left alone.
    nonisolated static func repairedStatus(_ status: MeetingStatus) -> MeetingStatus {
        guard status.isActive else { return status }
        return hadTranscript(status) ? .done : .failed("Next Notes quit while this meeting was recording.")
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
        Self.root.appendingPathComponent(id.uuidString, isDirectory: true)
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

    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID) {
        let directory = directory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        write(segments, to: directory.appendingPathComponent(Self.transcriptFile))
        transcriptCache[id] = segments
        searchCache[id] = nil
        searchInvalidated.insert(id)
        KnowledgeIndexer.shared.meetingChanged(id)
    }

    func notes(for id: UUID) -> String? {
        try? String(contentsOf: directory(for: id).appendingPathComponent(Self.notesFile), encoding: .utf8)
    }

    func saveNotes(_ markdown: String, for id: UUID) {
        let directory = directory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? markdown.write(
            to: directory.appendingPathComponent(Self.notesFile),
            atomically: true,
            encoding: .utf8
        )
        searchCache[id] = nil
        searchInvalidated.insert(id)
        KnowledgeIndexer.shared.meetingChanged(id)
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

        let root = Self.root
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
    nonisolated static let notesFile = "notes.md"
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
    private func write(_ value: some Encodable, to url: URL) {
        guard let data = try? Self.encoder.encode(value) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.meeting.error("couldn't write \(url.lastPathComponent): \(error.localizedDescription, privacy: .public)")
        }
    }
}
