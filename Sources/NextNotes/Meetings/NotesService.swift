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
    /// The stall watchdog's clock (M-08): when each running pass last changed its
    /// step. Advanced beside every `steps[id]` write, never on its own.
    @ObservationIgnored private var lastProgressAt: [UUID: Date] = [:]
    /// Passes the stall watchdog stopped. Their recording is kept: the problem says
    /// "Try again", and there is nothing to try again with without it.
    @ObservationIgnored private var stoppedByWatchdog: Set<UUID> = []

    private let store: MeetingStore
    private let providerResolver: (@MainActor (LLMProviderID?) async -> (any LLMProvider)?)?

    /// Instance-local fixture substitution leaves every production generation/save
    /// step intact; no global provider override or owner model choice is changed.
    init(
        store: MeetingStore = .shared,
        providerResolver: (@MainActor (LLMProviderID?) async -> (any LLMProvider)?)? = nil
    ) {
        self.store = store
        self.providerResolver = providerResolver
    }

    func step(for id: UUID) -> NotesGenerator.Step? { steps[id] }
    func isRunning(_ id: UUID) -> Bool { steps[id] != nil }
    func problem(for id: UUID) -> String? { problems[id] }
    func clearProblem(for id: UUID) { problems[id] = nil }
    func reportSaveFailure(for id: UUID) { problems[id] = NotesError.saveFailed.localizedDescription }
    func notesDidChange() { revision += 1 }

    /// Advances the watchdog's clock for one pass.
    private func noteProgress(_ id: UUID) { lastProgressAt[id] = Date() }

    /// Test-only seam for the resume self-test's stalled-stage fake, which drives
    /// `StageWatch` directly instead of running a model (the
    /// `startTimeoutOverrideForTesting` pattern). Production sets problems only
    /// from its own passes and the watchdog below.
    func setProblemForTesting(_ message: String?, for id: UUID) { problems[id] = message }

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
        // M-16a: the notes pass is a stage span. The note carries the
        // map-reduce flag with chunk, collapse and drop counts (M-05), or the
        // error's type name — never a model name, a token count or text.
        let began = Date()
        // Model selection may load or probe a provider. Show that work immediately and
        // keep a second press from appearing to do nothing while the await is in flight.
        steps[id] = NotesGenerator.Step(message: "Preparing\u{2026}", fraction: nil)
        problems[id] = nil
        noteProgress(id)
        defer { steps[id] = nil }

        // Use the role-based model selection for meeting notes.
        // If a specific provider is preferred (e.g., from Regenerate button), use that.
        // Otherwise, use the model configured for the meeting notes role.
        let provider: (any LLMProvider)?
        if let providerResolver {
            provider = await providerResolver(preferred)
        } else if let preferred {
            provider = await LLMProviders.resolve(preferring: preferred)
        } else {
            provider = await ModelRoleStore.shared.provider(for: .meetingNotes)
        }

        guard let provider else {
            let reason = if let preferred {
                await LLMProviders.make(preferred).unavailableReason
            } else {
                await LLMProviders.make(.appLLM).unavailableReason
            }
            problems[id] = reason ?? NotesError.noProvider.localizedDescription
            // P0-20b: a pass that never reached a model still writes a row, so "did the
            // notes run?" has an answer on disk after the process is gone.
            recordUnavailableNotesProvider(for: meeting, preferred: preferred, reason: reason)
            Log.llm.info("no notes provider available for \"\(meeting.title, privacy: .public)\"")
            return nil
        }

        do {
            let brief = await notesBrief(for: meeting, provider: provider)
            // P0-20b: the usage row names the role that chose the model, and says when
            // Regenerate's preferred engine overrode it rather than the role.
            let generator = NotesGenerator(
                provider: provider,
                fallbackReason: preferred == nil ? nil : .preferredOverride
            )
            let result = try await generator.notes(for: meeting, segments: segments, brief: brief) { step in
                Task { @MainActor [weak self] in
                    self?.noteProgress(id)
                    self?.steps[id] = step
                }
            }
            // The meeting can be deleted while the model is generating, and `saveNotes`
            // would re-create the directory that `delete` just removed — a meeting the user
            // deleted minutes ago reappearing with notes and no audio.
            guard store.meeting(id: id) != nil else { return nil }
            // The lines the person typed themselves go in above the model's, under their
            // own heading, and the merge is idempotent — so a second pass over a document
            // that already carries the block cannot leave two of them behind.
            let manual = ScratchNotesMerger.markdown(store.scratchpad(for: id))
            guard store.saveNotes(
                ScratchNotesMerger.merged(manual: manual, generated: result.markdown),
                for: id
            ) else { throw NotesError.saveFailed }
            revision += 1
            LatencyTrace.record(
                .meetingNotes,
                seconds: Date().timeIntervalSince(began),
                note: "mapReduce=\(result.usedMapReduce) chunks=\(result.chunks)"
                    + " collapsed=\(result.collapsedGroups) dropped=\(result.droppedFacts)"
            )
            Log.llm.info("""
                notes for "\(meeting.title, privacy: .public)" — \
                \(provider.displayModelName, privacy: .public), \
                \(result.generatedTokens, privacy: .public) tokens in \
                \(Int(result.duration), privacy: .public)s\
                \(result.usedMapReduce ? " (map-reduce)" : "", privacy: .public)
                """)
            if result.usedMapReduce {
                Log.llm.info("""
                    notes map-reduce · chunks \(result.chunks, privacy: .public) · \
                    collapsed \(result.collapsedGroups, privacy: .public) · \
                    dropped \(result.droppedFacts, privacy: .public)
                    """)
            }
            if !brief.isEmpty {
                Log.llm.info("""
                    notes context for "\(meeting.title, privacy: .public)": \
                    \(brief.sources.joined(separator: "+"), privacy: .public)
                    """)
            }
            return provider.displayModelName
        } catch is CancellationError {
            return nil
        } catch {
            LatencyTrace.record(
                .meetingNotes,
                seconds: Date().timeIntervalSince(began),
                note: "error=\(type(of: error))"
            )
            problems[id] = error.localizedDescription
            Log.llm.error("notes failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The connections the notes may draw on, or an empty brief while the user has the
    /// feature off. Every source inside still applies its own switch and cloud consent —
    /// this one toggle decides whether the notes even look.
    private func notesBrief(for meeting: Meeting, provider: any LLMProvider) async -> MeetingNotesBrief {
        guard Settings.shared.notesRelatedContext else { return .empty }
        return await MeetingNotesContextAssembler.live.brief(for: meeting, reader: provider.id)
    }

    /// One `meeting.notes.single` row for a pass with no provider to run (P0-20b).
    ///
    /// There is no model to wrap in a `ModelPassRecorder`, so the row is built directly.
    /// It names the role's candidate model rather than claiming a pass happened: the
    /// `errorClass` is `modelUnavailable` and `totalMs` is zero.
    private func recordUnavailableNotesProvider(
        for meeting: Meeting,
        preferred: LLMProviderID?,
        reason: String?
    ) {
        let named = preferred ?? .appLLM
        let provider = LLMProviders.make(named)
        UsageLog.shared.record(UsageRecord(
            v: 1,
            id: UUID(),
            ts: Date(),
            feature: UsageFeature.meetingNotesSingle.rawValue,
            pass: "single",
            round: nil,
            provider: ModelPassRecorder.usageProvider(for: provider.id).rawValue,
            modelID: provider.displayModelName,
            locality: provider.id == .openRouter ? "cloud" : "local",
            requestedRole: ModelRole.meetingNotes.rawValue,
            requestedModel: provider.displayModelName,
            fallbackReason: preferred == nil
                ? nil
                : UsageFallback.preferredOverride.rawValue,
            warm: nil,
            loadMs: nil,
            promptTokens: nil,
            cachedTokens: nil,
            completionTokens: nil,
            reasoningTokens: nil,
            countsEstimated: nil,
            ttftMs: nil,
            totalMs: 0,
            tokensPerSec: nil,
            finishReason: "error",
            truncated: nil,
            toolsProposed: nil,
            toolsExecuted: nil,
            errorClass: UsageErrorClass.modelUnavailable.rawValue,
            errorMessage: reason.map(UsageLog.sanitise),
            audioSeconds: nil,
            realtimeFactor: nil,
            stages: nil,
            counts: nil,
            turnID: nil,
            conversationID: nil,
            workID: nil,
            revision: nil,
            meetingID: meeting.id,
            dictationRunID: nil,
            scheduleID: nil
        ))
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
        noteProgress(id)

        // M-08: a generation that stops changing its step is stopped rather than left
        // showing "Writing notes…" until the next launch — a launch that used to delete
        // the recording behind it. The pass is cancelled into its own failure path, which
        // parks the meeting at `.done` with the problem below.
        let watchdog = StageWatch(
            limit: StageWatchdog.notesLimit,
            lastProgress: { [weak self] in self?.lastProgressAt[id] ?? .distantPast },
            isLaneBusy: { await StageWatchdog.urgentLaneBusy() },
            onStall: { [weak self] in
                guard let self else { return }
                let since = Date().timeIntervalSince(self.lastProgressAt[id] ?? .distantPast)
                Log.llm.error("""
                    notes stalled · \(Int(since), privacy: .public)s without a step \
                    on "\(meeting.title, privacy: .public)"
                    """)
                self.problems[id] = StageWatchdog.stallMessage
                self.stoppedByWatchdog.insert(id)
                self.tasks[id]?.cancel()
            }
        )
        watchdog.start()

        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                watchdog.cancel()
                self.tasks[id] = nil
                self.stoppedByWatchdog.remove(id)
            }

            guard var updated = store.meeting(id: id) else { return }
            let previousStatus = updated.status
            updated.status = .summarizing
            store.save(updated)

            let segments = store.transcript(for: id)
            let model = await generate(for: updated, segments: segments, preferring: provider)
            // A failed model cannot hide the person's notes. This also catches a line
            // saved after generate's snapshot while the panel was closing: the merge
            // compares first, so an ordinary completed pass does no second file write.
            if !MeetingPipeline.saveManualNotesIfPresent(for: id, store: store) {
                reportSaveFailure(for: id)
            }

            // Re-read rather than write the captured copy back: the store's record may
            // have been rewritten while this ran, and it may be gone entirely — a deleted
            // meeting must stay deleted rather than be resurrected by this save.
            guard var finished = store.meeting(id: id) else { return }
            if let model { finished.notesModel = model }
            // A meeting whose notes couldn't be written is still a finished meeting — it has
            // a transcript. Only a recording that had already failed keeps its failure.
            let finalStatus: MeetingStatus = previousStatus.isFailure ? previousStatus : .done
            // Part 4, Phase C: between the notes and done, while the graph is switched on. It
            // follows the notes rather than gating them: everything that waited for the notes
            // — the recording's release, the review, "after every meeting" routines — runs now,
            // and extraction is minutes of background work nobody should wait on.
            let extracts = model != nil && KnowledgeExtractionService.shared.isEnabled
            finished.status = extracts ? .extracting : finalStatus
            store.save(finished)
            // The last thing that had a use for the recording has finished with it — but
            // only on the automatic pass, and never when the pass was stopped by the stall
            // watchdog: the problem it left offers "Try again", and a recording is the one
            // copy of the meeting that a retry of diarization can still read. Regenerate
            // replays work that has already been done, and a button offering to write the
            // notes again is not a button that may delete the recording they were written
            // from. M-10: a temporary recording is scheduled 72 hours out, not deleted here.
            if announce, !stoppedByWatchdog.contains(id) {
                store.releaseAudioWhenDue(for: id, notesWritten: model != nil)
            }
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
                // "After every meeting…" triggers wait for exactly this: the automatic pass,
                // with notes written. Regenerate is not a new meeting to act on.
                AgentTriggerEvents.shared.notesReady(finished)
            }

            guard extracts else { return }
            await KnowledgeExtractionService.shared.extract(finished, directory: store.directory(for: id))
            // Done whether or not extraction ran — unless the meeting went while it did.
            guard var extracted = store.meeting(id: id), extracted.status == .extracting else { return }
            extracted.status = finalStatus
            store.save(extracted)
        }
    }

    /// Stops a generation that is no longer wanted — deleting the meeting is the one that
    /// matters, since the model would otherwise spend minutes writing notes for a folder
    /// that no longer exists.
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        steps[id] = nil
        lastProgressAt[id] = nil
        stoppedByWatchdog.remove(id)
    }
}
