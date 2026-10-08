import Foundation
import Observation

/// The live meeting's structured state, plus the last finished one the agent can still ask
/// about. Written beside `meeting.json` so a quit mid-call does not lose what was extracted.
///
/// Two writers reach the same record:
/// 1. `MeetingSession.add` → `ingest(segments:meeting:)`
/// 2. `TranscriptBus` finals → `MeetingContextBusBridge` → `ingestFinal(_:)`
///
/// Both share `ingestedKeys` (start|end|source|text). Session publishes the final *after*
/// it ingests, so the bus redelivery is a no-op rather than a second extractor pass.
///
/// A third, occasional writer is the light LLM reconcile: after a minute of new speech, and
/// never more often than every 45 s, it debounces and may tidy topics / unresolved /
/// candidate wording. It reads the last three minutes of meeting time. It never runs on
/// every segment and never restores the old two-minute proposal poll. Whether it runs at
/// all is `Settings.meetingLiveUnderstanding` — automatic means a model on this Mac.
@MainActor
@Observable
final class MeetingContextStore {
    static let shared = MeetingContextStore()
    static let fileName = "context.json"

    private(set) var current: MeetingContext?
    @ObservationIgnored private var lastSegments = 0
    /// Dedupes Session ingest against bus finals (and bus against itself).
    @ObservationIgnored private var ingestedKeys: Set<String> = []
    /// The model's short, source-labelled evidence buffer, bounded independently of the full
    /// meeting transcript and shared by session and transcript-bus ingest. Sized from
    /// `MeetingContextReconciler.evidenceBufferSegments` so it can hold a pass's whole
    /// three-minute window; a pass windows it by time on the way out.
    @ObservationIgnored private var recentSegments: [TranscriptSegment] = []

    /// How much new speech has arrived, and when the last pass ran. The rule is
    /// `MeetingContextReconciler`'s, so the store and its self-test decide the same way.
    @ObservationIgnored private var cadence = MeetingContextReconciler.Cadence()
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    /// Injected for tests; production uses the selected Agent model.
    @ObservationIgnored private var completer: any MeetingContextCompleter =
        MeetingContextReconciler.ModelCompleter()
    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let optionalAdmission: @Sendable () -> Bool

    private init(
        store: MeetingStore = .shared, startBus: Bool = true,
        optionalAdmission: @escaping @Sendable () -> Bool = {
            ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork
        }
    ) {
        self.store = store
        self.optionalAdmission = optionalAdmission
        if startBus { MeetingContextBusBridge.start(store: self) }
    }

    static func isolatedForTesting(
        store: MeetingStore,
        completer: any MeetingContextCompleter,
        optionalAdmission: @escaping @Sendable () -> Bool
    ) -> MeetingContextStore {
        precondition(SelfTest.isRunning)
        let context = MeetingContextStore(store: store, startBus: false,
                                          optionalAdmission: optionalAdmission)
        context.useCompleter(completer)
        return context
    }

    /// Swap the reconcile completer (self-tests inject a fake).
    func useCompleter(_ completer: any MeetingContextCompleter) {
        self.completer = completer
    }

    /// Exercise the actual cadence/run/apply/save path in an isolated diagnostic.
    func runReconcileForTesting() async {
        precondition(SelfTest.isRunning)
        reconcileTask?.cancel()
        reconcileTask = nil
        await runReconcile()
    }

    func ingest(_ segments: [TranscriptSegment], meeting: Meeting) {
        if current?.meetingID != meeting.id {
            ingestedKeys.removeAll()
            recentSegments.removeAll()
            lastSegments = 0
            resetReconcileCadence()
        }
        let fresh = segments.suffix(from: min(lastSegments, segments.count))
        lastSegments = segments.count
        let novel = fresh.filter { ingestedKeys.insert(Self.key(for: $0)).inserted }
        guard !novel.isEmpty else { return }

        var context = current?.meetingID == meeting.id
            ? current!
            : MeetingContext.empty(
                meetingID: meeting.id,
                title: meeting.title,
                participants: meeting.attendees
            )
        context = MeetingContextExtractor.apply(
            Array(novel),
            to: context,
            speakerNames: meeting.speakerNames
        )
        current = context
        save(context, meetingID: meeting.id)
        noteIngest(Array(novel))
    }

    /// Bus path. Only finals for the active meeting; provisionals are ignored here (the
    /// live pane reads them from `MeetingSession.provisionalText`).
    func ingestFinal(_ event: TranscriptEvent) {
        guard event.isFinal else { return }
        guard let meetingID = event.meetingID else { return }
        guard isActive(meetingID) else { return }

        let key = Self.key(
            start: event.start,
            end: event.end,
            source: event.source,
            text: event.text
        )
        guard ingestedKeys.insert(key).inserted else { return }

        let segment = TranscriptSegment(
            start: event.start,
            end: event.end,
            text: event.text,
            source: event.source
        )
        var context = current?.meetingID == meetingID
            ? current!
            : MeetingContext.empty(meetingID: meetingID, title: title(for: meetingID), participants: [])
        let speakerNames = MeetingController.shared.session?.meeting.speakerNames ?? [:]
        context = MeetingContextExtractor.apply(
            [segment],
            to: context,
            speakerNames: speakerNames
        )
        current = context
        save(context, meetingID: meetingID)
        noteIngest([segment])
    }

    func load(meetingID: UUID) -> MeetingContext? {
        let url = store.directory(for: meetingID).appendingPathComponent(Self.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(MeetingContext.self, from: data)
    }

    /// Reads the committed final transcript rather than a model's pending labels.
    /// The same path is used after diarization and a confirmed speaker-name edit.
    @discardableResult
    func refreshSpeakers(meetingID: UUID) -> Bool {
        guard let meeting = store.meeting(id: meetingID) else { return false }
        guard let context = current?.meetingID == meetingID ? current : load(meetingID: meetingID)
        else {
            // No live understanding was recorded: nothing needs projecting. An
            // existing but unreadable context is a refusal, not a successful no-op.
            let url = store.directory(for: meetingID).appendingPathComponent(Self.fileName)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        let projected = MeetingSpeakerProjection.apply(context,
            segments: store.transcript(for: meetingID),
            liveSegments: store.liveTranscript(for: meetingID), speakerNames: meeting.speakerNames)
        guard projected != context else { return true }
        guard save(projected, meetingID: meetingID) else { return false }
        if current?.meetingID == meetingID {
            // A pending live reconcile owns old speaker evidence. Cancellation refuses
            // its late result; no new pass is scheduled just to relabel existing facts.
            reconcileTask?.cancel()
            reconcileTask = nil
            current = projected
        }
        return true
    }

    func reset() {
        replace(nil)
    }

    /// Keeps the agent's copy of the name in step with a rename. Nothing to do when this
    /// meeting has never grown a `context.json`.
    func rename(meetingID: UUID, to title: String) {
        if var context = current, context.meetingID == meetingID {
            context.title = title
            current = context
            save(context, meetingID: meetingID)
            return
        }
        guard var context = load(meetingID: meetingID) else { return }
        context.title = title
        save(context, meetingID: meetingID)
    }

    /// `--selftest-realtime` plants a fixture without a recording.
    func replace(_ context: MeetingContext?) {
        reconcileTask?.cancel()
        reconcileTask = nil
        current = context
        lastSegments = 0
        ingestedKeys.removeAll()
        recentSegments.removeAll()
        resetReconcileCadence()
    }

    func recentTranscript(minutes: Double) -> String {
        guard let session = MeetingController.shared.session else { return "" }
        let cutoff = session.elapsed - (minutes * 60)
        return session.segments
            .filter { $0.start >= cutoff && $0.kind != .agentCommand }
            .plainText(speakerNames: session.meeting.speakerNames)
    }

    /// Source-labelled finals for an event-driven live tool proposal. Unlike the
    /// plain-text transcript, these preserve the mic/system authority boundary.
    func recentEvidenceSegments(for meetingID: UUID) -> [TranscriptSegment] {
        guard current?.meetingID == meetingID else { return [] }
        return Array(recentSegments.suffix(32))
    }

    func searchTranscript(_ query: String) -> String {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return "" }
        let segments = MeetingController.shared.session?.segments
            ?? (current.flatMap { store.transcript(for: $0.meetingID) } ?? [])
        let hits = segments.filter {
            $0.kind != .agentCommand && $0.text.lowercased().contains(needle)
        }
        return hits.prefix(12).map { "\($0.displaySpeaker): \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Occasional reconcile

    private func noteIngest(_ segments: [TranscriptSegment]) {
        recentSegments.append(contentsOf: segments.filter { $0.kind != .agentCommand })
        if recentSegments.count > MeetingContextReconciler.evidenceBufferSegments {
            recentSegments.removeFirst(
                recentSegments.count - MeetingContextReconciler.evidenceBufferSegments
            )
        }
        cadence.noteIngest(
            speechSeconds: segments.reduce(0) { partial, segment in
                partial + max(0, segment.end - segment.start)
            }
        )
        // One rule, two places: this asks whether to *arm* a pass, and the completer asks
        // again before it resolves a provider and spends a model call. Automatic mode with
        // an online model must not even schedule the debounce.
        guard isLiveUnderstandingEnabled, cadence.isDue(now: Date()) else { return }
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .milliseconds(MeetingContextReconciler.debounceMilliseconds)
            )
            guard !Task.isCancelled else { return }
            await self?.runReconcile()
        }
    }

    private func runReconcile() async {
        guard let context = current else { return }
        let now = Date()
        guard isLiveUnderstandingEnabled, cadence.isDue(now: now) else { return }

        // Counted before awaiting so a long stretch of talk that arrives while the model is
        // working starts a fresh window rather than immediately re-arming on the same speech.
        cadence.notePass(at: now)

        let elapsed = meetingElapsed
        let snapshot = MeetingContextReconciler.Snapshot(
            context: context,
            recentTranscript: recentTranscript(minutes: MeetingContextReconciler.windowMinutes),
            recentSegments: MeetingContextReconciler.window(
                recentSegments, endingAt: elapsed
            ),
            now: elapsed
        )
        let suggestion = await completer.refine(snapshot)
        guard suggestion.hasRefinements, !Task.isCancelled else { return }

        // Drop the result if the live meeting moved on while we waited.
        guard current?.meetingID == context.meetingID else { return }
        let base = current ?? context
        let refined = MeetingContextReconciler.apply(
            suggestion, to: base, recentSegments: snapshot.recentSegments
        )
        guard refined.topics != base.topics
            || refined.unresolvedItems != base.unresolvedItems
            || refined.candidateActions != base.candidateActions
            || refined.actionItems != base.actionItems
        else { return }

        current = refined
        save(refined, meetingID: refined.meetingID)
    }

    private func resetReconcileCadence() {
        cadence.reset()
    }

    /// Whether a live pass may run: the person's switch, and in automatic mode whether the
    /// model that would answer runs on this Mac.
    ///
    /// `ModelRoleStore.resolution` is the read-only decision P0-14 settled on, so this asks
    /// the role store rather than re-resolving a provider of its own — the same question the
    /// Agent turn asks, and `ModelRoleStore.provider(for: .agent)` hands back what it judged.
    private var isLiveUnderstandingEnabled: Bool {
        MeetingContextReconciler.isEnabled(
            stored: Settings.shared.meetingLiveUnderstanding,
            choice: ModelRoleStore.shared.resolution(for: .agent).effective
        )
    }

    /// The meeting clock a window is measured against: the live session's elapsed time, or
    /// the end of the last segment once there is no session — the pipeline finishing a
    /// meeting it has already stopped. `TranscriptSegment.start` counts from the same zero,
    /// so the two are comparable.
    private var meetingElapsed: TimeInterval {
        MeetingController.shared.session?.elapsed ?? recentSegments.last?.end ?? 0
    }

    private func isActive(_ meetingID: UUID) -> Bool {
        if current?.meetingID == meetingID { return true }
        return MeetingController.shared.session?.meeting.id == meetingID
    }

    private func title(for meetingID: UUID) -> String {
        if let session = MeetingController.shared.session, session.meeting.id == meetingID {
            return session.meeting.title
        }
        return store.meeting(id: meetingID)?.title ?? "Meeting"
    }

    static func key(for segment: TranscriptSegment) -> String {
        key(start: segment.start, end: segment.end, source: segment.source, text: segment.text)
    }

    static func key(
        start: TimeInterval,
        end: TimeInterval,
        source: AudioSource,
        text: String
    ) -> String {
        "\(start)|\(end)|\(source.rawValue)|\(text)"
    }

    @discardableResult
    private func save(_ context: MeetingContext, meetingID: UUID) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(context) else { return false }
        let url = store.directory(for: meetingID).appendingPathComponent(Self.fileName)
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }
}
