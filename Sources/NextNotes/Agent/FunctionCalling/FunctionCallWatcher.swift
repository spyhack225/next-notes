import Foundation
import Observation

/// Listens while you talk — in a meeting or to the agent — and notices when you asked for
/// something the app could do.
///
/// It never does the thing. It produces a call with arguments, hands it to the approval card
/// that already exists (`PermissionGate` → `IslandState`), and stops. The user presses a
/// button or they don't.
///
/// ## Why it is event-driven and not a poll
///
/// The previous live path re-read the last excerpt every two minutes and proposed whatever
/// it found, which is how you get a card about a sentence from four minutes ago. This runs
/// off `TranscriptBus` finals, debounced by `debounceMilliseconds`, so one burst of segments
/// makes at most one proposal and the proposal is about the sentence that just ended.
///
/// ## Why only the microphone drives it
///
/// A meeting records two tracks and the system track is other people. "Can you send me the
/// deck" from a remote participant is a request *to the user*, not authority for this app to
/// send anything — the existing `MeetingIntentDetector.mayAuthorizeExecute` rule says so and
/// this obeys it rather than inventing a second answer. System speech still enters the
/// rolling window, because it is where an address or a date is usually said.
///
/// ## Why the work does not starve ASR
///
/// Nothing here watches the compute lane, and that is deliberate — an earlier version did,
/// and it was 1.5 s of pure delay on every meeting proposal that avoided no contention at
/// all. Both backends are already handled by something that actually owns the decision:
///
/// - Needle runs in a child process (`NeedleRunner`, ~130 ms, ~90 MB) and never touches the
///   in-process lane, so there is nothing to yield.
/// - The fallback goes through `NotesModelRuntime`, which acquires `.background` from
///   `ComputeScheduler` — the class whose entire job is to yield to `.realtimeASR`.
///
/// Polling `occupancy()` on top of that could not work anyway: a meeting runs two
/// transcribers, each holding `.realtimeASR` for the length of its window, and occupancy
/// counts queued and parked jobs as busy — so the lane reads busy continuously while anyone
/// is speaking, the backoffs run out, and the proposal proceeds regardless. What this does
/// instead is keep one proposal in flight at a time at `.utility`, and drain the sentence
/// that arrived while the last one was running rather than dropping it.
@Observable
@MainActor
final class FunctionCallWatcher {
    static let shared = FunctionCallWatcher()

    /// Long enough to collapse a burst of segments, short enough that the card still lands
    /// before the next sentence. Same window the live meeting agent settled on.
    static let debounceMilliseconds = 700
    /// How much speech a proposal may look back over for an address or a time. Ninety
    /// seconds is roughly the span in which "her address is …" and "send her the deck" are
    /// still the same request.
    static let windowSeconds: TimeInterval = 90
    /// A card about something said three minutes ago is stale. It withdraws itself rather
    /// than queueing behind the next one forever.
    static let cardLifetime: TimeInterval = 180
    /// Nothing under this many characters is a request. "Yes." is not.
    static let minimumUtteranceCharacters = 12
    /// At most one card of this feature's own may be waiting for an answer.
    ///
    /// `PermissionGate` queues rather than drops, so without this a meeting that says three
    /// actionable things in a minute leaves three cards stacked behind each other, each one
    /// about a sentence the user has stopped thinking about.
    static let maximumOutstandingCards = 1
    /// And a ceiling per session, so a long meeting cannot drip them out indefinitely.
    static let maximumCardsPerWindow = 3
    static let rateLimitWindow: TimeInterval = 600
    /// After the user has finished talking to the assistant, this much quiet before ambient
    /// listening resumes. The agent's own turn runs tools for several seconds after the
    /// reply; a proposal raised inside that span competes with work already under way.
    static let agentTurnCooldown: TimeInterval = 20

    /// The last calls this process proposed, newest first. Read by the self-test and by
    /// anything that wants to show what the app noticed.
    private(set) var recent: [ProposedFunctionCall] = []

    @ObservationIgnored private var busTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var proposeTask: Task<Void, Never>?
    /// Finals seen lately, oldest first, across both tracks of the current meeting.
    @ObservationIgnored private var window: [TranscriptEvent] = []
    /// What the debounce is holding: the newest microphone final.
    @ObservationIgnored private var pending: Trigger?
    /// Utterances already offered, so a revised final for the same sentence does not ask
    /// twice, and identical calls do not stack.
    @ObservationIgnored private var seenUtterances: Set<String> = []
    @ObservationIgnored private var seenCalls: Set<String> = []
    @ObservationIgnored private var isStarted = false
    /// Cards this watcher raised that nobody has answered yet.
    @ObservationIgnored private var outstanding: Set<String> = []
    /// When each card went up, for the rolling ceiling.
    @ObservationIgnored private var raisedAt: [Date] = []
    /// When the user last began a turn addressed to the assistant.
    @ObservationIgnored private var lastAgentTurnAt: Date?
    /// Self-tests only: stands in for the live agent-session singletons, which cannot be
    /// driven from a terminal.
    @ObservationIgnored var agentBusyOverrideForTesting: Bool?

    private let store: FunctionCallStore

    init(store: FunctionCallStore = .shared) {
        self.store = store
    }

    /// What one proposal is about.
    struct Trigger: Sendable, Equatable {
        var utterance: String
        var span: TranscriptSpan
        var meetingID: UUID?
        var speaker: String?
        /// True for the agent conversation: the user was talking to the app on purpose, so
        /// the card quotes "You said" rather than "someone said in the meeting".
        var isDirectToAgent: Bool
    }

    // MARK: - Lifecycle

    /// Subscribes to the live transcript. Called once, from the app delegate.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        busTask = Task { @MainActor [weak self] in
            let stream = await TranscriptBus.shared.subscribe()
            for await event in stream {
                guard let self else { return }
                self.ingest(event)
            }
        }
        Task { await store.refreshStatus() }
    }

    func stop() {
        busTask?.cancel()
        debounceTask?.cancel()
        proposeTask?.cancel()
        busTask = nil
        isStarted = false
    }

    /// What the debounce is currently holding. Self-tests only: the question "would this
    /// have asked?" cannot be answered from `recent`, which only fills once a model has run.
    var pendingTriggerForTesting: Trigger? { pending }

    /// Self-tests only: stands in for the model, so the debounce, the one-proposal-at-a-time
    /// rule and the drain below can be driven on a machine with nothing downloaded. Without
    /// it the only way to reach `fire()` is to have a model, which is how the drain bug
    /// survived review in the first place.
    @ObservationIgnored var proposerOverrideForTesting: (any FunctionCallProposer)?

    /// Clears everything this process remembers. Self-tests only.
    func resetForTesting() {
        stop()
        window.removeAll()
        pending = nil
        seenUtterances.removeAll()
        seenCalls.removeAll()
        recent.removeAll()
        outstanding.removeAll()
        raisedAt.removeAll()
        lastAgentTurnAt = nil
        proposeTask = nil
    }

    // MARK: - Who owns this turn

    /// Why the watcher must stay silent right now, or nil.
    ///
    /// ## The failure this exists for
    ///
    /// On 2026-09-20 the user woke the agent and said "open Google Chrome and go to
    /// youtube.com". `VoiceConversationCoordinator.handle` did two things with that sentence:
    /// it started the conversation turn that correctly ran `browser.navigate`, and it handed
    /// the same sentence to `noteUserTurn`. Eight seconds later a card appeared offering to
    /// write the sentence into a Google Doc, while the agent was still working on the real
    /// request. Two agents, one utterance, one of them uninvited.
    ///
    /// The division of labour is not subtle and the code simply did not have it: **the
    /// conversation agent owns anything said to it.** This watcher is for ambient speech —
    /// a meeting, a sentence said to somebody else in the room, a thing muttered while the
    /// app is not being addressed. A sentence spoken into an open agent session is, by
    /// construction, not ambient.
    ///
    /// Read off the signals that already exist, without editing the files that own them:
    /// `ActivationController.mode` is the wake/shortcut session, `AgentCaptureController`
    /// is the microphone that session holds, `RealtimeAgent` and
    /// `VoiceConversationCoordinator` are the turn and its background jobs, and
    /// `IslandState` is the surface a proposal would have to steal.
    static func agentTurnOwnsThisUtterance() -> String? {
        if ActivationController.shared.mode != .idle {
            return "an agent session is open"
        }
        if AgentCaptureController.shared.isSessionActive {
            return "the agent is holding the microphone"
        }
        if RealtimeAgent.shared.isThinking || RealtimeAgent.shared.voiceInputActive
            || RealtimeAgent.shared.voiceWork != nil {
            return "an agent turn is in flight"
        }
        if VoiceConversationCoordinator.shared.hasActiveWork
            || VoiceConversationCoordinator.shared.inputPending {
            return "the agent is still working on the last thing you said"
        }
        if IslandState.shared.hasForegroundVoiceActivity {
            return "the agent is on screen"
        }
        return nil
    }

    /// The same question, including this watcher's own cooldown and test override.
    private func suppressionReason() -> String? {
        // The override stands in for the live singletons only. The cooldown below is this
        // object's own state and is always honoured, or the self-test would be asserting
        // against a rule it had switched off.
        if let override = agentBusyOverrideForTesting {
            if override { return "an agent turn is in flight" }
        } else if let reason = Self.agentTurnOwnsThisUtterance() {
            return reason
        }
        // Timed from the *start* of the turn, which is when `noteUserTurn` hears about it.
        // The live signals above cover the turn while it runs; this covers the tail, when
        // the tool loop is still going and the user is usually still talking to it.
        if let turn = lastAgentTurnAt,
           Date().timeIntervalSince(turn) < Self.agentTurnCooldown {
            return "you were talking to the agent moments ago"
        }
        return nil
    }

    /// Whether another card may go up at all: one at a time, a few per session.
    private func rateLimitReason() -> String? {
        raisedAt.removeAll { Date().timeIntervalSince($0) > Self.rateLimitWindow }
        if outstanding.count >= Self.maximumOutstandingCards {
            return "a card of ours is already waiting"
        }
        if raisedAt.count >= Self.maximumCardsPerWindow {
            return "already asked \(raisedAt.count) times in the last "
                + "\(Int(Self.rateLimitWindow / 60)) minutes"
        }
        return nil
    }

    /// Whether this request id was raised by the watcher rather than by the agent's own
    /// tool loop. Read by `run` before anything executes, and by the self-test.
    func isOurs(requestID: String) -> Bool { outstanding.contains(requestID) }

    // MARK: - Intake

    /// Whether this event may arm a proposal, as a pure function of the event and the two
    /// switches — so the rule can be checked without a meeting, a model or the machine's
    /// own settings.
    ///
    /// Four separate reasons to say no, and each one is a bug somebody would otherwise ship:
    ///
    /// - **No meeting.** Dictation publishes to the same bus, and a dictation is text on its
    ///   way into somebody else's app, not a request made of this one.
    /// - **Not final.** A provisional may still be revised; a card built from one is about
    ///   words the speaker had not finished saying.
    /// - **Not the microphone.** The system track is the other people on the call. Someone
    ///   asking the *user* to send something is not authority for this app to send it — the
    ///   rule `MeetingIntentDetector.mayAuthorizeExecute` already states.
    /// - **Too short.** "Yes." is not a request.
    static func mayArmProposal(
        _ event: TranscriptEvent,
        isEnabled: Bool,
        liveAgentEnabled: Bool
    ) -> Bool {
        guard isEnabled, liveAgentEnabled else { return false }
        guard event.meetingID != nil, event.isFinal, event.source == .mic else { return false }
        return event.text.trimmingCharacters(in: .whitespacesAndNewlines).count
            >= minimumUtteranceCharacters
    }

    /// One transcript event from a meeting.
    func ingest(_ event: TranscriptEvent) {
        guard event.meetingID != nil, event.isFinal, store.isEnabled else { return }
        // The user already has a switch for "let the agent work during a meeting", and it
        // means this too. A second switch that had to be found separately would be a way of
        // ignoring the first one. Read through the store rather than from `Settings`
        // directly, so the section that claims to be ready reads the same bit it shows,
        // and so a self-test can drive this without touching the user's own settings.
        let liveAgentEnabled = store.noticesMeetings
        guard liveAgentEnabled else { return }

        // Both tracks enter the window — an address or a date is usually said by whoever is
        // not driving — but only the microphone arms anything.
        window.append(event)
        trimWindow(around: event)

        // The window still fills while the agent is being spoken to; what stops is asking.
        // A meeting mic final that lands inside an open agent session is the user talking to
        // the app, not to the room, and the conversation agent already has it.
        if let reason = suppressionReason() {
            Log.agent.info("function call watcher silent: \(reason, privacy: .public)")
            return
        }

        guard Self.mayArmProposal(
            event,
            isEnabled: store.isEnabled,
            liveAgentEnabled: liveAgentEnabled
        ) else { return }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)

        pending = Trigger(
            utterance: text,
            span: TranscriptSpan(text: text, start: event.start, end: event.end),
            meetingID: event.meetingID,
            speaker: AudioSource.mic.defaultSpeaker,
            isDirectToAgent: false
        )
        scheduleDebounce()
    }

    /// One committed turn from the voice agent — the user talking to the app on purpose.
    ///
    /// Called from `VoiceConversationCoordinator.handle`. **It never proposes anything**, and
    /// that is the fix rather than an omission.
    ///
    /// This used to arm a proposal, which is how one sentence came to be answered twice. The
    /// call site is the function that handles a turn *addressed to the assistant*: by the
    /// time it runs, the conversation agent has the sentence, has a tool loop, and is about
    /// to act on it. A second opinion from a 35 MB classifier with a catalogue of eight
    /// workspace writes is not a safety net, it is a competitor — and it lost, spectacularly,
    /// by offering to paste "open Google Chrome and go to youtube.com" into a Google Doc
    /// while the agent was opening Chrome.
    ///
    /// What it does instead is note when the turn happened, so ambient listening stays quiet
    /// for `agentTurnCooldown` afterwards: the agent's tool loop runs for several seconds
    /// past the reply, and the user is usually still talking to it.
    ///
    /// The hand-off is kept rather than deleted so the call site — which this workstream does
    /// not own — keeps compiling and keeps supplying the signal.
    func noteUserTurn(_ text: String) {
        lastAgentTurnAt = Date()
        // Whatever was armed a moment ago was armed by the same voice that is now talking to
        // the agent. Drop it rather than letting the debounce deliver it afterwards.
        pending = nil
        debounceTask?.cancel()
        guard store.isEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Log.agent.info("function call watcher silent: the sentence was addressed to the agent")
    }

    private func trimWindow(around event: TranscriptEvent) {
        let cutoff = event.end - Self.windowSeconds
        window.removeAll { $0.end < cutoff || $0.meetingID != event.meetingID }
        // A hard cap as well as a time cap: a meeting with very short segments would
        // otherwise carry hundreds of events into a prompt sized in tokens.
        if window.count > 120 { window.removeFirst(window.count - 120) }
    }

    /// What the proposer may treat as already said.
    private func windowText(for trigger: Trigger) -> String {
        let lines = window
            .filter { $0.meetingID == trigger.meetingID }
            .suffix(40)
            .map { "\($0.source.defaultSpeaker): \($0.text)" }
        return lines.joined(separator: "\n")
    }

    // MARK: - Debounce

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        // A proposal already in flight is not a reason to lose this sentence. The debounce
        // that called this has run to completion, so nothing would re-arm it: the held
        // trigger would sit in `pending` until the next utterance overwrote it, with no log
        // line and no status change. A proposal takes a second or two — longer than the
        // debounce — so the window in which this happens is exactly the window in which
        // somebody says the next thing. `pending` is left alone here and drained by the
        // `defer` below when the running proposal finishes.
        guard proposeTask == nil, let trigger = pending else { return }
        // Asked again here and not only at `ingest`: the debounce is 700 ms, and a wake word
        // landing inside it is exactly the case where the user started talking to the app
        // halfway through the sentence this is about.
        if let reason = suppressionReason() {
            pending = nil
            Log.agent.info("function call watcher silent: \(reason, privacy: .public)")
            return
        }
        if let reason = rateLimitReason() {
            pending = nil
            Log.agent.info("function call not proposed: \(reason, privacy: .public)")
            return
        }
        pending = nil

        let key = FunctionCallGrounding.normalize(trigger.utterance)
        guard seenUtterances.insert(key).inserted else { return }
        if seenUtterances.count > 400 { seenUtterances.removeAll() }

        let window = windowText(for: trigger)
        proposeTask = Task(priority: .utility) { @MainActor [weak self] in
            defer {
                self?.proposeTask = nil
                // Whatever was said while this was running is still waiting.
                if self?.pending != nil { self?.scheduleDebounce() }
            }
            await self?.propose(trigger, window: window)
        }
    }

    // MARK: - Proposing

    /// Runs the proposer and raises a card for anything it returns.
    func propose(_ trigger: Trigger, window: String) async {
        // Not `??`: its right-hand side is an autoclosure, which cannot carry an `await`.
        let resolved: (any FunctionCallProposer)?
        if let override = proposerOverrideForTesting {
            resolved = override
        } else {
            resolved = await store.resolveProposer()
        }
        guard let proposer = resolved else {
            await store.refreshStatus()
            return
        }
        let tools = FunctionCallCatalogue.current()
        guard !tools.isEmpty else { return }
        let request = FunctionCallRequest(
            utterance: trigger.utterance,
            window: window,
            span: trigger.span,
            tools: tools,
            facts: Self.facts(for: trigger)
        )

        let calls: [ProposedFunctionCall]
        do {
            calls = try await proposer.propose(request)
        } catch {
            Log.agent.info(
                "function-call proposal failed: \(error.localizedDescription, privacy: .public)"
            )
            store.setStatus(.problem(
                "Next Notes could not listen for actions just then. It will try again."
            ))
            return
        }

        for call in calls {
            guard seenCalls.insert(Self.identity(of: call)).inserted else { continue }
            recent.insert(call, at: 0)
            if recent.count > 20 { recent.removeLast(recent.count - 20) }
            store.noteProposal(latency: call.latency, backend: call.backend)
            LatencyTrace.record(
                .meetingActionPhraseToCandidate,
                seconds: call.latency,
                note: "function call · \(call.backend.rawValue)"
            )
            present(call, trigger: trigger)
        }
        if !store.status.isReady { await store.refreshStatus() }
    }

    /// Session facts the model may use. Sentences, not a JSON blob: this is a 121M model.
    static func facts(for trigger: Trigger) -> [String] {
        var facts: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        facts.append("Today is \(formatter.string(from: Date())).")
        if let context = MeetingContextStore.shared.current, context.meetingID == trigger.meetingID {
            facts.append("A meeting called \(context.title) is being recorded.")
            if !context.participants.isEmpty {
                facts.append("The people in it are \(context.participants.joined(separator: ", ")).")
            }
        }
        return facts
    }

    /// Two proposals are the same when they would do the same thing with the same values.
    static func identity(of call: ProposedFunctionCall) -> String {
        let arguments = call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(FunctionCallGrounding.normalize($0.value))" }
            .joined(separator: "&")
        return "\(call.toolID)?\(arguments)"
    }

    // MARK: - Handing over

    /// Puts the call in front of the user, and runs it only if they say yes.
    ///
    /// Every part of this is somebody else's: `PermissionGate` raises the card,
    /// `ToolCallReviewStore` turns the absent arguments into the questions it asks, and
    /// `AgentToolExecutor` is the only thing that runs anything. What this method contributes
    /// is the request — and, crucially, arguments that contain nothing nobody said.
    private func present(_ call: ProposedFunctionCall, trigger: Trigger) {
        guard let tool = AgentToolRegistry.shared.tool(named: call.toolID) else { return }
        // Checked again per call, not once per turn: one utterance may produce three.
        if let reason = rateLimitReason() {
            Log.agent.info("function call not shown: \(reason, privacy: .public)")
            return
        }
        let request = Self.request(for: call, tool: tool, trigger: trigger)
        // The origin tag. `PermissionRequest` has no field for it (that type is not this
        // workstream's), so it is held here: everything the watcher raises is in this set
        // until it is answered or expires, and `run` refuses to execute anything that is
        // not in it. A proposal that has lost its provenance is a proposal nobody can say
        // came from overheard speech.
        outstanding.insert(request.id)
        raisedAt.append(Date())

        Task { @MainActor [weak self] in
            let ask = Task { @MainActor in await PermissionGate.shared.ask(request) }
            let expiry = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.cardLifetime))
                ask.cancel()
            }
            let approved = await ask.value
            expiry.cancel()
            guard approved else {
                // Dismissed, or expired unanswered. Either way it stops occupying the one
                // outstanding slot, and no status line announces a card nobody answered.
                self?.outstanding.remove(request.id)
                return
            }
            await self?.run(call, tool: tool, requestID: request.id, meetingID: trigger.meetingID)
            self?.outstanding.remove(request.id)
        }
    }

    /// Exactly what is handed over. Separated from `present` so the self-test can assert on
    /// it without a screen, a meeting or anybody to press a button.
    static func request(
        for call: ProposedFunctionCall,
        tool: AgentTool,
        trigger: Trigger
    ) -> PermissionRequest {
        let descriptor = FunctionCallCatalogue.descriptor(for: tool)
        return PermissionRequest(
            id: call.id,
            toolID: tool.id,
            title: tool.title(for: call.arguments),
            detail: call.missingSentence(in: descriptor)
                ?? tool.preview(for: call.arguments)
                ?? tool.description,
            risk: tool.risk,
            // The missing arguments are simply not here. That absence is the feature: the
            // review builder turns each one into a question, and Approve stays off until
            // somebody has answered it.
            arguments: call.arguments,
            meetingID: trigger.meetingID,
            trigger: Self.trigger(for: call, from: trigger)
        )
    }

    /// The card's "why" line.
    ///
    /// Always `.overheard`, and that is the point. Every proposal this file raises came from
    /// speech nobody addressed to the app — that is now the only kind it raises — so the card
    /// says so rather than borrowing "You said this", which is what the 2026-09-20 card did
    /// while quoting an instruction the user had given to the assistant instead.
    static func trigger(for call: ProposedFunctionCall, from trigger: Trigger) -> ToolCallTrigger {
        let quote = call.span.text.isEmpty ? trigger.utterance : call.span.text
        return .overheard(
            quote,
            speaker: trigger.speaker,
            at: call.span.start > 0 ? call.span.start : nil
        )
    }

    private func run(
        _ call: ProposedFunctionCall,
        tool: AgentTool,
        requestID: String,
        meetingID: UUID?
    ) async {
        // Three things have to be true before overheard speech changes anything:
        //
        // 1. This id is one we raised. Anything else reaching here would be a proposal whose
        //    provenance was lost, and a write with no provenance is not approvable.
        // 2. There is a review, and it is ready to run — the same gate `PermissionGate`
        //    applies, re-checked because the card and the execution are separate awaits, and
        //    the earlier code would have run `call.arguments` if the review had gone.
        // 3. Nothing about this call was auto-allowed. It cannot have been: this path calls
        //    `PermissionGate.ask` unconditionally rather than going through
        //    `PermissionBroker`, so no standing grant and no "without asking" switch is ever
        //    consulted for a watcher proposal. Asserted in `--selftest-function-calls`.
        guard isOurs(requestID: requestID) else {
            Log.agent.error("refusing a function call that did not come from the watcher")
            return
        }
        guard let review = ToolCallReviewStore.shared.review(id: requestID),
              review.isReadyToRun else {
            Log.agent.info("approved function call still had unanswered fields; not running")
            return
        }
        // The user's edits, not the draft. Somebody who typed the address on the card must
        // not have the model's version sent instead.
        let arguments = review.arguments
        // `PermissionGate` keeps an approved review until whoever asked has read it back —
        // this is that read, so this is where it stops being live. Left behind, the values
        // the user typed on one card outlive it under an id nothing else will answer.
        defer { ToolCallReviewStore.shared.remove(id: requestID) }
        do {
            _ = try await AgentToolExecutor.run(
                tool.id,
                arguments: arguments,
                policy: PermissionPolicy.fromSettings(),
                meetingID: meetingID,
                permissionAlreadyGranted: true
            )
        } catch {
            Log.agent.error(
                "approved function call failed: \(error.localizedDescription, privacy: .public)"
            )
            // Reported on the feature's own status line rather than as another island
            // notice: the card the user just pressed has gone, and a second card under the
            // notch a moment later reads as the action having happened twice.
            store.setStatus(.problem("That didn\u{2019}t work: \(error.localizedDescription)"))
        }
    }
}
