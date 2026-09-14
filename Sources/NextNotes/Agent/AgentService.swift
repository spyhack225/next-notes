import Foundation
import Observation

/// The app's side of the meeting agent: when it runs, what it has offered, and what
/// happened when somebody said yes.
///
/// The same shape as `NotesService` and `DiarizationService`, and for the same reason — one
/// place that owns "is this meeting being worked on", so that a proposal approved from the
/// island, from a notification and from the Actions tab all reach the same list. The actor
/// behind it plans; this decides when to ask it and never performs anything the user hasn't
/// answered.
@MainActor
@Observable
final class AgentService {
    static let shared = AgentService()

    /// Meetings the agent is currently thinking about.
    private(set) var thinking: Set<UUID> = []
    /// The last failure per meeting, for the banner in the Actions tab.
    private(set) var problems: [UUID: String] = [:]
    /// Bumped whenever a proposal list or a meeting's actions change, so views reading the
    /// store's unobserved caches know to look again.
    private(set) var revision = 0
    /// Where the CLI's own setup has got to, re-probed rather than remembered.
    private(set) var authState: WorkspaceAuthState = .notInstalled
    /// `gws 0.22.5`, when there is a binary to ask.
    private(set) var version: String?
    private(set) var isProbing = false
    /// Proposals whose tool is running right now. Observed rather than hidden, because the
    /// card has to be able to disable its own Approve button: `gws gmail +send` is a network
    /// round trip, and a card that looks untouched for two seconds gets pressed again.
    private(set) var running: Set<String> = []

    /// How long to wait after a meeting-context delta before raising a card.
    ///
    /// Sentence-scale, not the two-minute poll that used to re-read the last excerpt and
    /// propose a summary Doc every tick. Held inside 500–1500 ms so a burst of segments
    /// collapses to one card, and a single ask still lands before the next sentence.
    static var liveDebounceMilliseconds: Int { MeetingLiveAgent.debounceMilliseconds }

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Which meeting a live proposal belongs to, so a button pressed on a notification —
    /// which carries only the proposal's id — can find it again.
    @ObservationIgnored private var owners: [String: UUID] = [:]
    @ObservationIgnored private var liveDebounce: Task<Void, Never>?
    @ObservationIgnored private var lastLiveFingerprint: String?
    @ObservationIgnored private var announcedCandidates: Set<String> = []
    @ObservationIgnored private var dismissedCandidates: Set<String> = []
    @ObservationIgnored private var isStarted = false

    private let store: MeetingStore
    private let cli: GoogleWorkspaceCLI

    init(store: MeetingStore = .shared, cli: GoogleWorkspaceCLI = .shared) {
        self.store = store
        self.cli = cli
    }

    // MARK: - Lifecycle

    /// Wires the agent to the two places a proposal can be answered from, and starts
    /// watching `MeetingContextStore` for candidate deltas. Called once, from the app
    /// delegate.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // A list, not an assignment: the scheduler and the island are already listening,
        // and an assignment here would have silently replaced one of them.
        Notifications.shared.observe { [weak self] action in
            self?.handle(action)
        }
        IslandState.shared.onProposalDecision = { [weak self] proposal, approved in
            if PermissionGate.shared.respond(id: proposal.id, approved: approved) { return }
            if proposal.isCandidate {
                self?.decideCandidate(proposal, approved: approved)
                return
            }
            self?.decide(proposalID: proposal.id, approved: approved)
        }

        observeLiveContext()
        Task { await refreshStatus() }
    }

    // MARK: - Status

    /// Re-reads where `gws` is and whether it is signed in.
    ///
    /// Asked rather than remembered, and asked again whenever the Settings window comes
    /// back to the front: the user answers these questions in a Terminal window beside it,
    /// and a status row that only looked once is a row that is wrong for the whole session.
    /// How long a probe's answer is trusted before another one is worth spawning.
    ///
    /// Every probe is two `gws` subprocesses, and the callers are a `.task` and an
    /// app-activation notification — so alt-tabbing between Next Notes and System Settings,
    /// which is exactly what setting the agent up involves, spawned a pair per switch. The
    /// answer only changes when the user does something in Terminal, and `force` covers
    /// the case where they just did.
    private static let statusCacheLifetime: TimeInterval = 30

    @ObservationIgnored private var lastProbe: Date?

    /// Drops the cached answer, so the next probe actually runs.
    ///
    /// Called when a step that changes the answer is launched — installing, setting up a
    /// client, signing in. Those all finish in Terminal, and the user comes back to
    /// Next Notes afterwards, which is the activation that must not be served from cache.
    func invalidateStatus() {
        lastProbe = nil
    }

    func refreshStatus(force: Bool = false) async {
        guard !isProbing else { return }
        if !force, let lastProbe, Date().timeIntervalSince(lastProbe) < Self.statusCacheLifetime {
            return
        }
        isProbing = true
        defer {
            isProbing = false
            lastProbe = Date()
        }

        await cli.forget()
        let state = await cli.authState()
        // The version cannot change without a reinstall, and a reinstall restarts the app,
        // so it is asked for once rather than on every probe.
        var resolvedVersion = version
        if state == .notInstalled {
            resolvedVersion = nil
        } else if resolvedVersion == nil {
            resolvedVersion = await cli.version()
        }
        authState = state
        version = resolvedVersion
    }

    /// Whether the agent can actually do anything right now.
    var isReady: Bool { Settings.shared.agentEnabled && authState.isSignedIn }

    // MARK: - Reading a meeting

    func proposals(for id: UUID) -> [AgentProposal] {
        _ = revision
        return store.proposals(for: id)
    }

    /// Candidates the extractor has offered for this meeting, minus ones already dismissed.
    func candidates(for id: UUID) -> [MeetingCandidateAction] {
        _ = revision
        return context(for: id)?.candidateActions
            .filter { !dismissedCandidates.contains($0.id) } ?? []
    }

    /// Live cards and Workspace proposals as one list: duplicates fold, invented summary
    /// Docs stay off the Actions tab. Live candidates are never dropped.
    func reconciled(for id: UUID) -> MeetingActionReconciler.Outcome {
        _ = revision
        let context = context(for: id)
        let live = (context?.candidateActions ?? []).filter { !dismissedCandidates.contains($0.id) }
        return MeetingActionReconciler.reconcile(
            candidates: live,
            proposals: store.proposals(for: id),
            mentioned: context?.documentsMentioned ?? [],
            actionItems: context?.actionItems ?? []
        )
    }

    /// In-memory context while the meeting is live; the on-disk copy afterwards.
    private func context(for id: UUID) -> MeetingContext? {
        if let current = MeetingContextStore.shared.current, current.meetingID == id {
            return current
        }
        return MeetingContextStore.shared.load(meetingID: id)
    }

    func isCandidateDismissed(_ id: String) -> Bool {
        _ = revision
        return dismissedCandidates.contains(id)
    }

    func isThinking(_ id: UUID) -> Bool { thinking.contains(id) }
    /// Whether this proposal's tool is running right now, for the card that offered it.
    func isRunning(_ proposal: AgentProposal) -> Bool { running.contains(proposal.id) }
    func problem(for id: UUID) -> String? { problems[id] }
    func clearProblem(for id: UUID) { problems[id] = nil }

    /// Plans the follow-ups for a meeting that has just finished.
    ///
    /// Returns immediately; the pass runs in a task this service owns, exactly as notes do.
    /// - Parameter force: run again even though this meeting already has proposals or
    ///   performed actions. The "Review again" button; never the automatic path.
    func review(_ meeting: Meeting, force: Bool = false) {
        guard isReady else { return }
        guard tasks[meeting.id] == nil else { return }
        // A recording that produced nothing has nothing to follow up, and a banner saying so
        // on a meeting that already failed is a second complaint about the same thing.
        guard !store.transcript(for: meeting.id).isEmpty else { return }
        if !force {
            // "Has this meeting been reviewed", not "is anything on the list": a mid-meeting
            // proposal nobody has answered yet is not a review, and treating it as one meant
            // that turning the live pass on quietly turned the post-meeting one off.
            let reviewed = store.proposals(for: meeting.id).contains(where: \.isFromReview)
                || meeting.agentActions.contains(where: \.isFromReview)
            guard !reviewed else { return }
        }

        let id = meeting.id
        thinking.insert(id)
        problems[id] = nil
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.thinking.remove(id)
                self.tasks[id] = nil
            }
            guard let provider = await LLMProviders.resolve(
                preferring: Settings.shared.agentModelProvider,
                modelID: Settings.shared.openRouterAgentModelID,
                contextTokens: Settings.shared.openRouterAgentContextTokens
            ) else {
                self.problems[id] = AgentError.noProvider.localizedDescription
                return
            }
            do {
                let proposals = try await MeetingAgent.shared.proposals(
                    for: meeting,
                    segments: self.store.transcript(for: id),
                    notes: self.store.notes(for: id),
                    provider: provider,
                    policy: AgentPolicy.fromSettings()
                )
                // The meeting can be deleted while the model is thinking, and writing
                // proposals for it would re-create the directory that `delete` removed.
                guard self.store.meeting(id: id) != nil else { return }
                // Drop invented summary Docs before they reach disk. Matching live cards
                // stay filed — Approve on the card is what runs them — but the Actions
                // tab folds them into one row via `reconciled(for:)`.
                let context = self.context(for: id)
                let accepted = MeetingActionReconciler.acceptedProposals(
                    from: proposals,
                    candidates: context?.candidateActions ?? [],
                    mentioned: context?.documentsMentioned ?? [],
                    actionItems: context?.actionItems ?? []
                )
                let dropped = proposals.count - accepted.count
                // A forced review replaces what the previous one offered. Appending would
                // put a second copy of the same Doc and the same email on the list, and
                // approving both copies creates both. An empty accept list still replaces
                // when forced, so a second pass that finds only inventions clears the old
                // ones rather than leaving them.
                self.record(accepted, for: id, announce: true, replacing: force)
                Log.agent.info("""
                    \(accepted.count, privacy: .public) proposal(s) for \
                    "\(meeting.title, privacy: .public)"\
                    \(dropped > 0 ? " (\(dropped) dropped by reconcile)" : "")
                    """)
            } catch is CancellationError {
                return
            } catch {
                self.problems[id] = error.localizedDescription
                Log.agent.error("agent failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Stops a pass that is no longer wanted, and forgets what it had offered.
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        thinking.remove(id)
        for proposal in store.proposals(for: id) {
            Notifications.shared.withdrawAgentProposal(id: proposal.id)
            owners[proposal.id] = nil
        }
    }

    // MARK: - Answering

    /// Runs one proposal's tool, once.
    ///
    /// The guard is the whole point of the set: nothing is written until the tool returns, so
    /// until this the card looked exactly as it did before it was pressed — and a `send_email`
    /// pressed twice is two emails to the same people, recorded as one because the record is
    /// keyed on the proposal.
    func approve(_ proposal: AgentProposal) {
        guard !running.contains(proposal.id) else { return }
        running.insert(proposal.id)
        Notifications.shared.withdrawAgentProposal(id: proposal.id)
        let id = proposal.meetingID
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.running.remove(proposal.id) }
            do {
                let result = try await AgentToolExecutor.run(
                    proposal,
                    cli: self.cli,
                    approvedByUser: true
                )
                self.record(
                    AgentActionRecord(
                        id: proposal.id,
                        tool: proposal.tool,
                        title: proposal.title,
                        performedAt: Date(),
                        reference: result.reference,
                        link: result.link,
                        detail: proposal.risk == .read ? result.summary : nil,
                        failure: nil,
                        source: proposal.source
                    ),
                    for: id
                )
                self.remove(proposal)
                Log.agent.info("performed \(proposal.tool, privacy: .public)")
            } catch {
                // The proposal stays on the list: a failure here is usually a signed-out
                // CLI or a rejected address, both of which are worth one more press once
                // they are fixed. The attempt is recorded so the meeting says it was tried.
                self.problems[id] = error.localizedDescription
                self.record(
                    AgentActionRecord(
                        id: proposal.id,
                        tool: proposal.tool,
                        title: proposal.title,
                        performedAt: Date(),
                        reference: nil,
                        link: nil,
                        detail: nil,
                        failure: error.localizedDescription,
                        source: proposal.source
                    ),
                    for: id
                )
                Log.agent.error("\(proposal.tool, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func dismiss(_ proposal: AgentProposal) {
        Notifications.shared.withdrawAgentProposal(id: proposal.id)
        remove(proposal)
    }

    func dismissCandidate(_ candidate: MeetingCandidateAction) {
        dismissedCandidates.insert(candidate.id)
        announcedCandidates.insert(candidate.id)
        revision += 1
    }

    /// Opens the meeting so the candidate can be edited or approved where the whole
    /// card is on screen. Never a Workspace write.
    func prepareCandidate(_ candidate: MeetingCandidateAction, meetingID: UUID) {
        NavigationState.shared.show(meeting: meetingID)
        AppDelegate.showMainWindow()
        Log.agent.info(
            "prepared candidate \(candidate.action, privacy: .public) \(candidate.object ?? "", privacy: .public)"
        )
    }

    /// Approve-to-execute for a live candidate. System audio is refused here, not only
    /// in the detector — a card that lost its source check still cannot run.
    func approveCandidate(_ candidate: MeetingCandidateAction, meetingID: UUID) {
        guard MeetingLiveAgent.canAuthorizeExecute(candidate) else {
            Log.agent.info("refused execute: system audio is not authority")
            prepareCandidate(candidate, meetingID: meetingID)
            return
        }
        // Existing Workspace proposals still go through `approve`, which is the only
        // path that runs a tool. A candidate without one is not turned into a send
        // or a Doc — that is how the two-minute poll used to invent work.
        if let match = matchingProposal(for: candidate, meetingID: meetingID) {
            approve(match)
            return
        }
        prepareCandidate(candidate, meetingID: meetingID)
    }

    /// Replaces one proposal's arguments, from the Actions tab's editor.
    func update(_ proposal: AgentProposal, arguments: [String: String]) {
        var proposals = store.proposals(for: proposal.meetingID)
        guard let index = proposals.firstIndex(where: { $0.id == proposal.id }) else { return }
        proposals[index].arguments = arguments
        store.saveProposals(proposals, for: proposal.meetingID)
        revision += 1
    }

    /// Answers a proposal from wherever the button was — the island, a banner, the tab.
    ///
    /// A send is never performed on this path however it arrives: this build posts no Approve
    /// button for one, but a notification left over from a previous launch has one, and the
    /// answer to it is the meeting rather than an email. Approving a send happens on the card
    /// that shows the whole message and nowhere else.
    private func decide(proposalID: String, approved: Bool) {
        guard let meetingID = meeting(owning: proposalID),
              let proposal = store.proposals(for: meetingID).first(where: { $0.id == proposalID })
        else { return }
        guard approved else {
            dismiss(proposal)
            return
        }
        guard proposal.risk < .send else {
            Notifications.shared.withdrawAgentProposal(id: proposalID)
            NavigationState.shared.show(meeting: meetingID)
            AppDelegate.showMainWindow()
            return
        }
        approve(proposal)
    }

    /// Which meeting a proposal belongs to.
    ///
    /// The map is filled as proposals are made, and the scan behind it is what answers a
    /// button pressed on a notification left over from a previous launch — the proposal is
    /// on disk, but this process has never seen it. Scanning opens a file per meeting, which
    /// is why it happens on a press rather than at launch.
    private func meeting(owning proposalID: String) -> UUID? {
        if let id = owners[proposalID] { return id }
        for meeting in store.meetings
        where store.proposals(for: meeting.id).contains(where: { $0.id == proposalID }) {
            owners[proposalID] = meeting.id
            return meeting.id
        }
        return nil
    }

    private func handle(_ action: Notifications.Action) {
        switch action {
        case .approveProposal(let id): decide(proposalID: id, approved: true)
        case .dismissProposal(let id): decide(proposalID: id, approved: false)
        case .recordNow, .skip, .open: break
        }
    }

    // MARK: - Storage

    /// Files a batch of proposals and, optionally, puts the first one in front of the user.
    ///
    /// One notification for a batch rather than one each: three banners for one meeting is
    /// how a feature gets turned off. The rest are in the Actions tab, which is where they
    /// are answered properly anyway — with the full text of anything being sent.
    ///
    /// A card outside the app can approve anything up to a write. A `send` cannot: the island
    /// shows a title and two lines, the banner shows a title and a sentence, and neither has
    /// room for the message that would go out in the user's name. Those get a card that only
    /// opens the meeting, where the whole thing is on screen above the button.
    ///
    /// - Parameter replacing: throw away whatever was waiting for this meeting first. The
    ///   "Review again" button reads the same transcript and proposes the same actions, so
    ///   appending would list every one of them twice. An empty list still clears when
    ///   replacing — reconcile may have dropped every invention a forced pass produced.
    private func record(
        _ proposals: [AgentProposal],
        for id: UUID,
        announce: Bool,
        replacing: Bool = false
    ) {
        if proposals.isEmpty && !replacing { return }
        var existing = store.proposals(for: id)
        if replacing {
            for proposal in existing {
                Notifications.shared.withdrawAgentProposal(id: proposal.id)
                owners[proposal.id] = nil
            }
            existing = []
        }
        existing.append(contentsOf: proposals)
        store.saveProposals(existing, for: id)
        for proposal in proposals { owners[proposal.id] = id }
        revision += 1

        guard announce, let first = proposals.first else { return }
        let remaining = proposals.count - 1
        let detail = remaining > 0
            ? "\(first.rationale) (+\(remaining) more)"
            : first.rationale
        let needsReview = first.risk == .send
        IslandState.shared.propose(IslandProposal(
            id: first.id,
            title: first.title,
            detail: detail,
            meetingID: id,
            needsReview: needsReview
        ))
        Notifications.shared.postAgentProposal(first, canApprove: !needsReview)
    }

    private func record(_ action: AgentActionRecord, for id: UUID) {
        guard var meeting = store.meeting(id: id) else { return }
        // Keyed on the proposal, so approving the same thing twice after a failure replaces
        // the failed attempt rather than filling the list with retries.
        if let index = meeting.agentActions.firstIndex(where: { $0.id == action.id }) {
            meeting.agentActions[index] = action
        } else {
            meeting.agentActions.append(action)
        }
        store.save(meeting)
        revision += 1
    }

    private func remove(_ proposal: AgentProposal) {
        var proposals = store.proposals(for: proposal.meetingID)
        proposals.removeAll { $0.id == proposal.id }
        store.saveProposals(proposals, for: proposal.meetingID)
        owners[proposal.id] = nil
        revision += 1
    }

    // MARK: - Live

    /// Re-registers after every write to the live context, the same hop `IslandState`
    /// uses so the callback is not on the mutation stack and never needs `assumeIsolated`.
    private func observeLiveContext() {
        withObservationTracking {
            _ = MeetingContextStore.shared.current?.meetingID
            _ = MeetingContextStore.shared.current?.candidateActions
            _ = MeetingContextStore.shared.current?.actionItems
            _ = MeetingContextStore.shared.current?.documentsMentioned
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleLiveDebounce()
                self.observeLiveContext()
            }
        }
    }

    private func scheduleLiveDebounce() {
        liveDebounce?.cancel()
        liveDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.liveDebounceMilliseconds))
            guard !Task.isCancelled else { return }
            self?.handleLiveDelta()
        }
    }

    /// Raises island cards for new candidates. Does not call `MeetingAgent.liveProposals`
    /// — that path is what proposed a summary Doc every two minutes.
    private func handleLiveDelta() {
        guard Settings.shared.agentLiveDuringMeeting else { return }
        guard let context = MeetingContextStore.shared.current else { return }

        let fingerprint = MeetingLiveAgent.fingerprint(context)
        guard fingerprint != lastLiveFingerprint else { return }
        lastLiveFingerprint = fingerprint

        let fresh = MeetingLiveAgent.unannouncedCards(
            from: context,
            announced: announcedCandidates.union(dismissedCandidates)
        )
        guard let card = fresh.last else { return }
        for next in fresh { announcedCandidates.insert(next.id) }
        IslandState.shared.propose(card)
        if let candidate = context.candidateActions.first(where: { $0.id == card.id }) {
            // The span ends at the IslandState hand-off. This measures the real candidate
            // age seen by the card path; the context store cannot claim a card exists.
            LatencyTrace.record(
                .meetingCandidateToCard,
                seconds: max(0, Date().timeIntervalSince(candidate.createdAt)),
                note: "IslandState.propose handoff"
            )
        }
        revision += 1
    }

    private func decideCandidate(_ proposal: IslandProposal, approved: Bool) {
        let meetingID = proposal.meetingID
        let candidate = meetingID.flatMap { id in
            candidates(for: id).first { $0.id == proposal.id }
        }
        guard approved else {
            if let candidate { dismissCandidate(candidate) }
            else { dismissedCandidates.insert(proposal.id) }
            return
        }
        guard let meetingID else { return }
        guard let candidate else {
            NavigationState.shared.show(meeting: meetingID)
            AppDelegate.showMainWindow()
            return
        }
        if MeetingLiveAgent.canAuthorizeExecute(candidate) {
            approveCandidate(candidate, meetingID: meetingID)
        } else {
            prepareCandidate(candidate, meetingID: meetingID)
        }
    }

    /// A Workspace proposal that already exists for this meeting and names the same object.
    /// Matching is conservative: no object, no guess, no invented tool — the same rule
    /// `MeetingActionReconciler` uses when folding the two lists.
    private func matchingProposal(for candidate: MeetingCandidateAction, meetingID: UUID) -> AgentProposal? {
        let matches = store.proposals(for: meetingID).filter {
            MeetingActionReconciler.matches(candidate, $0)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Event-driven live meeting intelligence: debounce context deltas, raise cards, and
/// refuse execute unless the microphone authorised it.
enum MeetingLiveAgent {
    /// 800 ms sits in the 500–1500 ms window: long enough to collapse a burst of
    /// segments, short enough that an ask still lands before the next sentence.
    static let debounceMilliseconds = 800

    static func canAuthorizeExecute(source: AudioSource) -> Bool {
        MeetingIntentDetector.mayAuthorizeExecute(source: source)
    }

    static func canAuthorizeExecute(_ candidate: MeetingCandidateAction) -> Bool {
        MeetingIntentDetector.mayAuthorizeExecute(candidate)
    }

    static func fingerprint(_ context: MeetingContext) -> String {
        let candidates = context.candidateActions.map {
            "\($0.id)|\($0.action)|\($0.object ?? "")"
        }.joined(separator: ";")
        let actions = context.actionItems.map(\.text).joined(separator: "\u{1e}")
        let mentions = context.documentsMentioned.map(\.text).joined(separator: "\u{1e}")
        return "\(context.meetingID.uuidString)|\(candidates)|\(actions)|\(mentions)"
    }

    static func islandProposal(for candidate: MeetingCandidateAction, meetingID: UUID) -> IslandProposal {
        let authorized = canAuthorizeExecute(candidate)
        return IslandProposal(
            id: candidate.id,
            title: title(for: candidate),
            detail: detail(for: candidate),
            meetingID: meetingID,
            needsReview: !authorized,
            canExecute: authorized,
            isCandidate: true
        )
    }

    static func unannouncedCards(
        from context: MeetingContext,
        announced: Set<String>
    ) -> [IslandProposal] {
        context.candidateActions
            .filter { !announced.contains($0.id) }
            .map { islandProposal(for: $0, meetingID: context.meetingID) }
    }

    static func title(for candidate: MeetingCandidateAction) -> String {
        let object = candidate.object ?? "that"
        let verb = candidate.action.prefix(1).uppercased() + candidate.action.dropFirst()
        if let recipient = candidate.recipient, !recipient.isEmpty {
            return "\(verb) \(object) to \(recipient)?"
        }
        return "\(verb) \(object)?"
    }

    static func detail(for candidate: MeetingCandidateAction) -> String {
        if candidate.source == .system {
            let who = candidate.speaker ?? "Someone"
            return "\(who) asked for this. Prepare it — it cannot run from their speech."
        }
        return "You said this. Approve runs it only if a Workspace proposal already exists."
    }

    /// Prints one last `MEETING_LIVE_OK` / `MEETING_LIVE_FAILED` line, and runs the bus
    /// bridge probe (`MEETING_BUS_OK` / `FAILED`) so finals → context stay covered without
    /// a separate NextNotesApp flag. Does not start a recording, does not touch `RunLog`,
    /// and does not call `gws`.
    @MainActor
    @discardableResult
    static func runSelfTest() -> Bool {
        var failures = MeetingContextExtractor.selfTestFailures()
        // Bus → context is its own OK/FAILED line; fold the bool into this verdict so a
        // green MEETING_LIVE cannot hide a broken ingestFinal path.
        if !MeetingContextBusBridge.runSelfTest() {
            failures.append("meeting bus bridge")
        }
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        check(
            "debounce left the 500–1500 ms window",
            debounceMilliseconds >= 500 && debounceMilliseconds <= 1_500
        )

        let system = TranscriptSegment(
            start: 0, end: 2,
            text: "Can you send the deck",
            source: .system,
            speaker: "Sarah"
        )
        let mic = TranscriptSegment(start: 3, end: 5, text: "Can you send the deck", source: .mic)
        check("a .system segment authorised execute", !canAuthorizeExecute(source: system.source))
        check("a .system segment authorised execute", !MeetingIntentDetector.mayAuthorizeExecute(system))

        guard let systemCandidate = MeetingIntentDetector.candidate(in: system) else {
            failures.append("can you send the deck produced no candidate")
            writeLine(failures)
            return false
        }
        check("a system candidate authorised execute", !canAuthorizeExecute(systemCandidate))

        let meetingID = UUID()
        let systemCard = islandProposal(for: systemCandidate, meetingID: meetingID)
        check("a system card offered Approve-to-execute", !systemCard.canExecute)
        check("a system card skipped Prepare", systemCard.leadAction == .prepare)
        check("a system card was not marked as a candidate", systemCard.isCandidate)

        if let micCandidate = MeetingIntentDetector.candidate(in: mic) {
            check("mic speech was refused authority", canAuthorizeExecute(micCandidate))
            let micCard = islandProposal(for: micCandidate, meetingID: meetingID)
            check("a mic card hid Approve", micCard.canExecute && micCard.leadAction == .approve)
        } else {
            failures.append("mic can you send the deck produced no candidate")
        }

        var context = MeetingContext.empty(meetingID: meetingID, title: "Standup", participants: ["Sam"])
        context = MeetingContextExtractor.apply(
            [TranscriptSegment(start: 0, end: 2, text: "We should write this up in a doc later.", source: .mic)],
            to: context
        )
        check(
            "a discussion produced a live card",
            unannouncedCards(from: context, announced: []).isEmpty
        )

        context = MeetingContextExtractor.apply([system], to: context)
        let cards = unannouncedCards(from: context, announced: [])
        check("a send-the-deck ask produced no card", !cards.isEmpty)
        check("the deck card could execute", cards.allSatisfy { !$0.canExecute })

        writeLine(failures)
        return failures.isEmpty
    }

    private static func writeLine(_ failures: [String]) {
        for failure in failures {
            emit("  MEETING_LIVE_WRONG: \(failure)")
        }
        emit(failures.isEmpty
             ? "MEETING_LIVE_OK: cadence, cards and the authority split hold"
             : "MEETING_LIVE_FAILED: \(failures.count) rule(s) wrong")
    }

    private static func emit(_ line: String) {
        let text = "\(line)\n"
        FileHandle.standardOutput.write(Data(text.utf8))
        Log.app.info("selftest · \(line, privacy: .public)")
        guard let path = SelfTest.outputPath else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
