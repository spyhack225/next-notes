import SwiftUI

/// The persistent agent: conversation, running tasks and the audit log — and, in their own
/// panes, Routines and About (identity, SOUL, MEMORY).
struct AgentView: View {
    @State private var navigation = NavigationState.shared
    @State private var session = AgentSession.shared
    @State private var agent = RealtimeAgent.shared
    @State private var tasks = AgentTaskManager.shared
    @State private var audit = AgentAuditLog.shared
    @State private var gate = PermissionGate.shared
    @State private var acpGate = ACPConfirmationGate.shared
    @State private var identity = AgentIdentityStore.shared
    @State private var draft = ""
    @State private var showsRecentTasks = false

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
    static let headingTitle = "Your Mac is your best personal assistant"

    var body: some View {
        Group {
            switch navigation.agentPane {
            case .conversation: conversation
            case .routines: RoutinesView()
            case .graph: KnowledgeGraphPane()
            case .skills: SkillsView()
            case .about: AgentAboutView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Agent pane", selection: $navigation.agentPane) {
                    ForEach(NavigationState.AgentPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .navigationTitle("Agent")
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack {
                        Text("Conversation")
                            .font(DS.Font.sectionLabel)
                        Spacer()
                        if !session.messages.isEmpty {
                            Button("Clear conversation", systemImage: "trash") {
                                session.clear()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
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
                        Text("Active tasks").font(DS.Font.sectionLabel)
                        ForEach(activeTasks) { task in taskRow(task) }
                    }
                    if !recentTasks.isEmpty {
                        DisclosureGroup("Recent tasks (\(recentTasks.count))", isExpanded: $showsRecentTasks) {
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
                if let pending = gate.pending { permissionCard(pending) }
                if let acp = acpGate.pending { acpConfirmCard(acp) }
                composer
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, DS.Space.s)
            .background(DS.Color.window)
        }
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
        case .tool: "Tool call"
        case .task: "Task started"
        case .permission: "Permission"
        default: "Activity"
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
                    Text(entry.detail).font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textTertiary)
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
            NotionAvatarView(config: identity.avatar, size: DS.Size.agentAvatar)
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
                Text("Task · \(task.status == .waitingForCompatibilityCLI ? "Needs approval" : task.status.rawValue.capitalized)")
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

    private var composer: some View {
        HStack(spacing: DS.Space.s) {
            TextField("Ask Next…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }
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
