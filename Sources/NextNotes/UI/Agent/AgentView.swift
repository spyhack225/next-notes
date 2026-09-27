import SwiftUI

/// The persistent agent: conversation, running tasks and the audit log — and, in their own
/// panes, Ideas, Goals, Reminders, Activity and About (identity, SOUL, MEMORY).
struct AgentView: View {
    @State private var navigation = NavigationState.shared
    @State private var session = AgentSession.shared
    @State private var agent = RealtimeAgent.shared
    @State private var tasks = AgentTaskManager.shared
    @State private var audit = AgentAuditLog.shared
    @State private var gate = PermissionGate.shared
    @State private var acpGate = ACPConfirmationGate.shared
    @State private var identity = AgentIdentityStore.shared
    @State private var activityStore = AgentActivityStore.shared
    @State private var roles = ModelRoleStore.shared
    @State private var loadNotice = ModelLoadNotice.shared
    @State private var draft = ""
    @State private var showsRecentTasks = false
    /// Whether the trailing inspector is open. A layout preference, so it is persisted
    /// rather than held in `NavigationState` — which is where *places*, not pane furniture,
    /// live.
    @AppStorage("agent.inspector.visible") private var showsInspector = true

    private var isEmpty: Bool { session.messages.isEmpty && tasks.tasks.isEmpty }
    private var activeTasks: [AgentTask] {
        tasks.tasks.filter {
            $0.status == .queued || $0.status == .running
                || $0.status == .waitingForPermission
                || $0.status == .waitingForCompatibilityCLI
                || $0.status == .waitingForInput
        }
    }
    private var recentTasks: [AgentTask] {
        Array(tasks.tasks.filter { !activeTasks.contains($0) }.prefix(8))
    }

    private enum TimelineItem: Identifiable {
        case message(AgentSession.Message, String?)
        case event(AgentAuditEntry)

        var id: String {
            switch self {
            case .message(let message, _): "message-\(message.id)"
            case .event(let entry): "event-\(entry.id)"
            }
        }
        var at: Date {
            switch self {
            case .message(let message, _): message.at
            case .event(let entry): entry.at
            }
        }
    }

    /// The conversation is the source of truth for speech; audit requests and replies
    /// duplicate those rows. Only action events are interleaved with the messages.
    private var timeline: [TimelineItem] {
        let messages = Array(session.messages.suffix(40))
        let start = messages.first?.at ?? .distantPast
        let requests = audit.entries.filter { $0.kind == .request && $0.at >= start }
        let speech = messages.map { message -> TimelineItem in
            let source = message.source ?? (message.role == "user"
                ? requests.first(where: {
                    $0.title == String(message.text.prefix(300))
                        && abs($0.at.timeIntervalSince(message.at)) < 5
                })?.detail
                : nil)
            return .message(message, source)
        }
        let actions = audit.entries.filter {
            $0.at >= start && ($0.kind == .tool || $0.kind == .permission || $0.kind == .task)
        }.prefix(40).map { TimelineItem.event($0) }
        return (speech + (messages.isEmpty ? [] : actions)).sorted {
            if $0.at == $1.at { return $0.id < $1.id }
            return $0.at < $1.at
        }
    }

    /// Visible strings for this screen. Named so `--selftest-settings` can prove they
    /// still contain U+0020 — screenshots of this heading have been misread as one word.
    static let headingEyebrow = "Agent"
    static let headingTitle = "Your Mac is your best personal agent"

    var body: some View {
        // Two arrangements of the same section: the pane with the inspector's column
        // beside it, and the pane alone. `ViewThatFits` picks the first that fits, so on a
        // window too narrow for a fixed-width column beside a readable conversation the
        // panel — and the control that opens it — are simply not offered. A toggle whose
        // panel cannot appear is worse than no toggle.
        ViewThatFits(in: .horizontal) {
            section(offersInspector: true)
            section(offersInspector: false)
        }
        .navigationTitle("Agent")
        // A typed turn is coming: warm the on-device model while the person types. Opening
        // the pane and starting to type are the earliest honest signals, and `prewarm` is a
        // no-op when it is already warm, when the assistant role is on another model, or
        // when the model is not on this Mac. Never at launch — see `NotesModelRuntime.prewarm`.
        .task { _ = NotesModelRuntime.shared.prewarm() }
        .onChange(of: draft) { _, _ in _ = NotesModelRuntime.shared.prewarm() }
    }

    /// The section, laid out for a window that can (`offersInspector`) or cannot hold the
    /// inspector's fixed column. The pane bar keeps the visible pane's own control either
    /// way; only the toggle comes and goes with the room.
    private func section(offersInspector: Bool) -> some View {
        VStack(spacing: 0) {
            // The pane switcher lives in content, not the toolbar: on macOS 26 a menu in
            // `ToolbarItem(placement: .principal)` draws as a chevron-only circle and
            // never its label. See AgentPaneSwitcherBar.
            AgentPaneSwitcherBar {
                paneBarAccessory(offersInspector: offersInspector)
            }
            Divider()
            HStack(spacing: 0) {
                paneContent
                if offersInspector, showsInspector {
                    Divider()
                    // Fixed. `agentWideMinWidth` is the same threshold the panes use for a
                    // list with a rail: below it the conversation would be squeezed under
                    // a full bubble's width and neither column would be readable.
                    AgentInspector()
                        .frame(width: DS.Size.agentRailWidth)
                }
            }
            .frame(minWidth: offersInspector && showsInspector
                   ? DS.Size.agentWideMinWidth
                   : nil,
                   alignment: .topLeading)
        }
    }

    /// The tab the row selected, full size — everything except the inspector column. The
    /// six panes that used to be here are sidebar sections of their own now.
    private var paneContent: some View {
        Group {
            switch navigation.agentPane {
            case .conversation: conversation
            case .activity: ActivityView()
            case .about: AgentAboutView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The pane bar's trailing slot: the visible pane's own control, then the inspector's
    /// toggle. The toggle is passed the room rather than reading it, because the bar draws
    /// only in the arrangement `ViewThatFits` chose.
    @ViewBuilder
    private func paneBarAccessory(offersInspector: Bool) -> some View {
        if navigation.agentPane == .conversation, !session.messages.isEmpty {
            newConversationButton
        }
        if offersInspector {
            Button {
                showsInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
                    .foregroundStyle(showsInspector ? DS.Color.accent : DS.Color.textSecondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            .accessibilityLabel(showsInspector ? "Hide the inspector" : "Show the inspector")
        }
    }

    /// The Conversation pane's one control, in the bar rather than the scroll.
    ///
    /// It was the first row of the history, which meant a conversation long enough to need
    /// clearing was also long enough to have buried the button that clears it. The bar does
    /// not scroll, so the way out is always in the same place.
    ///
    /// P1-26 changed what it does and what it says. It was "Clear conversation" with a trash
    /// can, and it deleted **every** conversation ever indexed through `onConversationCleared`
    /// — a person reads that button as "tidy this chat". It now starts a new conversation, and
    /// says so in a verb rather than an adjective: "New conversation", a plus rather than a
    /// bin. Deleting still exists, and lives with the knowledge settings' own "Forget
    /// everything" (`KnowledgeSettingsView`), where the one confirmation says what it removes.
    private var newConversationButton: some View {
        Button("New conversation", systemImage: "plus") {
            session.startNewConversation()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Start a new conversation. Past conversations stay in search.")
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    // A label, not a control: the Clear button lives in the pane bar above,
                    // because a button that scrolls with the history it acts on can only be
                    // pressed from the top of a conversation.
                    Text("Conversation")
                        .font(DS.Font.sectionLabel)
                    if isEmpty {
                        OrbUnavailableView(
                            .breathing,
                            title: "Nothing yet",
                            message: "Ask what’s on your calendar, or what was just said in a meeting."
                        ) {
                            Button("What’s on my calendar?") {
                                Task { await RealtimeAgent.shared.handleLive("What's on my calendar today?", source: .text) }
                            }
                        }
                    }
                    ForEach(timeline) { item in
                        switch item {
                        case .message(let message, let source): messageRow(message, source: source)
                        case .event(let entry): eventRow(entry)
                        }
                    }
                    if agent.isThinking { thinkingRow }
                    if !activeTasks.isEmpty {
                        Text("Working on now").font(DS.Font.sectionLabel)
                        ForEach(activeTasks) { task in
                            // P1-1: a live run gets the working surface — status pill,
                            // step list, live view, inline approval. The states that wait
                            // on a person (compatibility CLI, an answer) keep the plain
                            // row, which carries their own buttons.
                            if task.status == .running || task.status == .queued
                                || task.status == .waitingForPermission {
                                AgentWorkingCard(task: task) { tasks.cancel(task.id) }
                            } else {
                                taskRow(task)
                            }
                        }
                    }
                    if !recentTasks.isEmpty {
                        DisclosureGroup("Recent activity (\(recentTasks.count))", isExpanded: $showsRecentTasks) {
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                ForEach(recentTasks) { task in taskRow(task) }
                            }
                            .padding(.top, DS.Space.s)
                        }
                        .font(DS.Font.callout)
                    }
                    Color.clear.frame(height: DS.Space.xs).id("conversation-bottom")
                }
                .padding(DS.Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            .onChange(of: session.messages.last?.id) { _, _ in
                withAnimation(DS.Motion.standard) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: audit.entries.first?.id) { _, _ in
                withAnimation(DS.Motion.standard) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DS.Space.s) {
                // A request that belongs to a live run is drawn inline by that run's
                // working card, one screen above. Drawing it here too would ask the same
                // question twice, and answering one would leave the other on screen.
                if let pending = gate.pending, !isShownInline(pending) { permissionCard(pending) }
                if let acp = acpGate.pending { acpConfirmCard(acp) }
                if let caption = answeringModelCaption {
                    // P0-03: the pane says which model answered, so a turn that fell back
                    // to another one cannot be described by Settings as something else.
                    Text(caption)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if let message = loadNotice.message {
                    // A model that failed is said here too, not only in Settings, with the
                    // one move that changes it a click away.
                    HStack(spacing: DS.Space.s) {
                        Text(message)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                        Button("Settings") { navigation.selectedSettingsTab = .agent }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                composer
                // P2-6: persistent, fixed position, and the same sentence the working
                // card and the island use. It sits under the composer so it is on every
                // conversation, including an empty one.
                Text("Next Notes is AI and can make mistakes.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, DS.Space.s)
            .background(DS.Color.window)
        }
    }

    /// Whether a live run's working card is already drawing this request inline.
    private func isShownInline(_ request: PermissionRequest) -> Bool {
        guard let taskID = request.taskID, let task = tasks.task(id: taskID) else { return false }
        return task.status == .running || task.status == .queued
            || task.status == .waitingForPermission
    }

    /// The full review — every argument, where it came from, and what is still missing.
    /// `ToolReviewCard` owns the layout; this only binds it to the gate.
    private func permissionCard(_ request: PermissionRequest) -> some View {
        ToolReviewCard(
            review: gate.pendingReview ?? ToolCallReviewStore.shared.review(for: request),
            isCompact: true,
            approve: {
                PermissionGate.shared.respond(
                    id: request.id,
                    approved: true,
                    duration: .once,
                    scope: request.scope
                )
            },
            dismiss: {
                PermissionGate.shared.respond(id: request.id, approved: false)
            },
            alwaysAllow: request.scope.kind == .any ? nil : {
                PermissionGate.shared.respond(
                    id: request.id,
                    approved: true,
                    duration: .alwaysThisAction,
                    scope: request.scope
                )
            }
        )
    }

    private func acpConfirmCard(_ request: ACPConfirmationRequest) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(request.title)
                .font(DS.Font.headline)
            Text(request.detail)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
            HStack(spacing: DS.Space.s) {
                Button("Cancel") {
                    ACPConfirmationGate.shared.cancel()
                }
                Button("Run once") {
                    let utterance = request.utterance
                    let hadWaiter = ACPConfirmationGate.shared.confirmOnce()
                    if !hadWaiter {
                        Task {
                            await RealtimeAgent.shared.runWithLocalToolsOnce(
                                utterance,
                                source: .text
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.cardTight)
        .glassSurface()
    }

    private func messageRow(_ message: AgentSession.Message, source: String?) -> some View {
        let isUser = message.role == "user"
        return HStack(alignment: .bottom, spacing: DS.Space.s) {
            if isUser { Spacer(minLength: DS.Space.xl) }
            if !isUser {
                NotionAvatarView(config: identity.avatar, size: DS.Size.agentAvatar)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    Text(isUser ? "You" : identity.name).font(DS.Font.chip)
                    if isUser, source == "voice" {
                        Label("Voice", systemImage: "waveform")
                    } else if isUser, source == "text" {
                        Label("Typed", systemImage: "keyboard")
                    }
                    Text(message.at, format: .dateTime.hour().minute())
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                Text(message.text)
                    .font(DS.Font.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.m)
                    .background(
                        isUser ? DS.Color.accent.opacity(DS.Opacity.chipFill) : DS.Color.content,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card)
                    )
            }
            .frame(maxWidth: DS.Size.agentBubbleMaxWidth, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: DS.Space.xl) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func eventRow(_ entry: AgentAuditEntry) -> some View {
        let icon: String = switch entry.kind {
        case .tool: "wrench.and.screwdriver"
        case .task: "checklist"
        case .permission: "hand.raised"
        default: "circle.dotted"
        }
        let label: String = switch entry.kind {
        case .tool: "What it did"
        case .task: "Started"
        case .permission: "Approval"
        case .wake, .wakeMiss, .wakeFalse: "Wake word"
        case .request: "You asked"
        case .reply: "Answered"
        }
        return HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: icon)
                .frame(width: DS.Size.orbSmall)
                .foregroundStyle(DS.Color.textSecondary)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text(label).font(DS.Font.chip)
                    Spacer()
                    Text(entry.at, format: .dateTime.hour().minute())
                }
                .foregroundStyle(DS.Color.textSecondary)
                Text(entry.title).font(DS.Font.callout)
                    .textSelection(.enabled)
                if entry.kind == .tool, !entry.detail.isEmpty {
                    // Progressive disclosure (§8.3): the machine's own words are one
                    // click away, never on the line a person reads.
                    DisclosureGroup("Details") {
                        Text(entry.detail).font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                            .textSelection(.enabled)
                    }
                    .font(DS.Font.chip)
                    .foregroundStyle(DS.Color.textSecondary)
                }
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: DS.Size.agentEventMaxWidth, alignment: .leading)
        .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var thinkingRow: some View {
        HStack(spacing: DS.Space.s) {
            // The character, in whatever state the run is actually in — a page being read,
            // a file being written, something being sent. `liveAvatarState` is the tool
            // layer's own decision; `thinking` is only the fallback for a turn that has not
            // reached a tool yet.
            AgentAvatarView(
                config: identity.avatar,
                state: activityStore.liveAvatarState ?? .thinking,
                size: DS.Size.agentAvatar
            )
            Text(agent.progressTitle.isEmpty
                 ? "\(identity.name) is thinking…"
                 : agent.progressTitle)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    private func taskRow(_ task: AgentTask) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: task.status == .completed ? "checkmark.circle" : "checklist")
                .frame(width: DS.Size.orbSmall)
                .foregroundStyle(DS.Color.textSecondary)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(task.status.humanState)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Text(task.objective).font(DS.Font.callout)
                if !task.progress.isEmpty {
                    Text(task.progress).font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                if let result = task.result { Text(result).font(DS.Font.callout).textSelection(.enabled) }
                if task.status == .waitingForCompatibilityCLI { compatibilityCLICard(for: task) }
                if task.status == .running { Button("Cancel") { tasks.cancel(task.id) } }
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: DS.Size.agentEventMaxWidth, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    private func compatibilityCLICard(for task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("ACP unavailable.")
                .font(DS.Font.callout)
            Text("Compatibility CLI mode has weaker progress and permission guarantees and runs only once after your approval.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            if let command = task.compatibilityCommand {
                Text("Command: \(command)")
                    .font(DS.Font.caption)
                    .textSelection(.enabled)
            }
            if let directory = task.compatibilityDirectory, !directory.isEmpty {
                Text("Working directory: \(directory)")
                    .font(DS.Font.caption)
                    .textSelection(.enabled)
            }
            HStack(spacing: DS.Space.s) {
                Button("Cancel") { tasks.cancel(task.id) }
                Button("Run once in compatibility CLI mode") {
                    tasks.approveCompatibilityCLI(taskID: task.id)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.s)
        .glassSurface()
    }

    /// "Answered by <name>", hidden until a turn has answered. When the answer did not
    /// come from the model the assistant role names, the caption adds why, in the same
    /// plain words the fallback's own sentence uses.
    ///
    /// The qualification is deliberately limited to local choices answered by a different
    /// local model. A multi-step request routed online, or a cloud choice that fell back
    /// because its key or network is missing, is not a model that "can’t run on this Mac",
    /// and the caption must not invent that reason for it.
    private var answeringModelCaption: String? {
        guard let answering = agent.answeringModel else { return nil }
        let chosen = roles.resolution(for: .agent).effective
        let chosenIsLocal: Bool
        switch chosen {
        case .builtIn, .installedModel, .appleFoundation: chosenIsLocal = true
        case .cloud, .localServer, .app: chosenIsLocal = false
        }
        let answeredLocally = answering.id == .appLLM || answering.id == .appleFoundation
        guard chosenIsLocal, answeredLocally,
              !Self.choice(chosen, namesAnswering: answering.id) else {
            return "Answered by \(answering.name)"
        }
        let chosenName = roles.displayName(for: chosen, role: .agent)
        return "Answered by \(answering.name) — \(chosenName) can’t run on this Mac."
    }

    /// Whether the model kind a choice resolves to is the one that answered.
    private static func choice(_ choice: ModelRoleChoice, namesAnswering id: LLMProviderID) -> Bool {
        switch choice {
        case .builtIn, .installedModel, .app: id == .appLLM
        case .appleFoundation: id == .appleFoundation
        case .cloud: id == .openRouter
        case .localServer: id == .localServer
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            TextField("Ask \(identity.name)…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit { send() }
                .onKeyPress(phases: .down) { press in
                    // Plain Return sends; Shift/Option/Control+Return inserts a newline.
                    guard press.key == .return else { return .ignored }
                    if press.modifiers.contains(.shift)
                        || press.modifiers.contains(.option)
                        || press.modifiers.contains(.control) {
                        return .ignored
                    }
                    send()
                    return .handled
                }
            if agent.isThinking {
                Button("Stop") {
                    ACPConfirmationGate.shared.cancel()
                    RealtimeAgent.shared.cancel()
                }
            }
            Button("Send", action: send)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.bottom, DS.Space.m)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        ACPConfirmationGate.shared.cancel()
        if agent.isThinking {
            RealtimeAgent.shared.interrupt()
        }
        Task { await RealtimeAgent.shared.handleLive(text, source: .text) }
    }
}
