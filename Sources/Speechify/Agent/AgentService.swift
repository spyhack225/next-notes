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

    /// How long between live passes while a meeting is recording. Two minutes is what the
    /// plan asks for and about what a 4B model costs to run over two minutes of speech —
    /// any faster and the agent is competing with the transcription it reads.
    static let liveInterval: TimeInterval = 120

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Live passes are tracked apart from the post-meeting ones. They shared a slot once,
    /// and the cost was silent: a live pass still generating when the user pressed Stop made
    /// `review` return, and nothing ever asked again.
    @ObservationIgnored private var liveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var liveTicker: Task<Void, Never>?
    /// Which meeting a live proposal belongs to, so a button pressed on a notification —
    /// which carries only the proposal's id — can find it again.
    @ObservationIgnored private var owners: [String: UUID] = [:]
    /// How far through the transcript the last live pass read, per meeting.
    @ObservationIgnored private var liveWatermark: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var isStarted = false

    private let store: MeetingStore
    private let cli: GoogleWorkspaceCLI

    init(store: MeetingStore = .shared, cli: GoogleWorkspaceCLI = .shared) {
        self.store = store
        self.cli = cli
    }

    // MARK: - Lifecycle

    /// Wires the agent to the two places a proposal can be answered from, and starts the
    /// live ticker. Called once, from the app delegate.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // A list, not an assignment: the scheduler and the island are already listening,
        // and an assignment here would have silently replaced one of them.
        Notifications.shared.observe { [weak self] action in
            self?.handle(action)
        }
        IslandState.shared.onProposalDecision = { [weak self] proposal, approved in
            self?.decide(proposalID: proposal.id, approved: approved)
        }

        liveTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.liveInterval))
                guard !Task.isCancelled else { return }
                await self?.liveTick()
            }
        }
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
    /// app-activation notification — so alt-tabbing between Speechify and System Settings,
    /// which is exactly what setting the agent up involves, spawned a pair per switch. The
    /// answer only changes when the user does something in Terminal, and `force` covers
    /// the case where they just did.
    private static let statusCacheLifetime: TimeInterval = 30

    @ObservationIgnored private var lastProbe: Date?

    /// Drops the cached answer, so the next probe actually runs.
    ///
    /// Called when a step that changes the answer is launched — installing, setting up a
    /// client, signing in. Those all finish in Terminal, and the user comes back to
    /// Speechify afterwards, which is the activation that must not be served from cache.
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
            guard let provider = await LLMProviders.resolve(preferring: Settings.shared.notesProvider) else {
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
                // A forced review replaces what the previous one offered. Appending would
                // put a second copy of the same Doc and the same email on the list, and
                // approving both copies creates both.
                self.record(proposals, for: id, announce: true, replacing: force)
                Log.agent.info("""
                    \(proposals.count, privacy: .public) proposal(s) for \
                    "\(meeting.title, privacy: .public)"
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
        liveTasks[id]?.cancel()
        liveTasks[id] = nil
        thinking.remove(id)
        for proposal in store.proposals(for: id) {
            Notifications.shared.withdrawAgentProposal(id: proposal.id)
            owners[proposal.id] = nil
        }
        liveWatermark[id] = nil
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
                let result = try await WorkspaceToolRunner.run(proposal, cli: self.cli)
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
    ///   appending would list every one of them twice.
    private func record(
        _ proposals: [AgentProposal],
        for id: UUID,
        announce: Bool,
        replacing: Bool = false
    ) {
        guard !proposals.isEmpty else { return }
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

    /// Looks at the last couple of minutes of a running meeting, when asked to.
    ///
    /// Deliberately narrow: only what was said since the previous pass, and only an explicit
    /// request in it counts. The post-meeting prompt run every two minutes would propose a
    /// summary Doc every two minutes.
    private func liveTick() async {
        guard Settings.shared.agentLiveDuringMeeting, isReady else { return }
        guard let session = MeetingController.shared.session, session.isRecording else { return }

        let meeting = session.meeting
        let since = liveWatermark[meeting.id] ?? 0
        let recent = session.segments.filter { $0.start >= since }
        guard !recent.isEmpty, let last = recent.last else { return }
        // Checked before the watermark moves: a pass still running means this excerpt has
        // not been read by anyone, and advancing past it would lose those two minutes. Only
        // the live slot is consulted — a post-meeting review is about a different meeting.
        guard liveTasks[meeting.id] == nil else { return }
        liveWatermark[meeting.id] = last.end

        guard let provider = await LLMProviders.resolve(preferring: Settings.shared.notesProvider) else {
            return
        }
        thinking.insert(meeting.id)
        liveTasks[meeting.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.thinking.remove(meeting.id)
                self.liveTasks[meeting.id] = nil
            }
            do {
                let proposals = try await MeetingAgent.shared.liveProposals(
                    for: meeting,
                    recent: recent,
                    provider: provider
                )
                guard self.store.meeting(id: meeting.id) != nil else { return }
                // Each live proposal is announced on its own: there is usually one, and it
                // is about something said thirty seconds ago.
                for proposal in proposals {
                    self.record([proposal], for: meeting.id, announce: true)
                }
            } catch {
                Log.agent.error("live agent pass failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
