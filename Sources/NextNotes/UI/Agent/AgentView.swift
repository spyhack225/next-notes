import SwiftUI

/// The persistent agent: conversation, running tasks and the audit log.
struct AgentView: View {
    @State private var session = AgentSession.shared
    @State private var agent = RealtimeAgent.shared
    @State private var tasks = AgentTaskManager.shared
    @State private var audit = AgentAuditLog.shared
    @State private var activity = AgentActivityStore.shared
    @State private var gate = PermissionGate.shared
    @State private var draft = ""

    private var isEmpty: Bool { session.messages.isEmpty && tasks.tasks.isEmpty }

    /// Visible strings for this screen. Named so `--selftest-settings` can prove they
    /// still contain U+0020 — screenshots of this heading have been misread as one word.
    static let headingEyebrow = "Agent"
    static let headingTitle = "Talk to your computer"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                SectionHeading(
                    title: Self.headingTitle,
                    eyebrow: Self.headingEyebrow,
                    subtitle: "Wake it with \(Settings.shared.agentShortcut.displayName) or the phrase “\(Settings.shared.wakePhrase)”."
                )

                if let pending = gate.pending {
                    permissionCard(pending)
                }

                if isEmpty {
                    OrbUnavailableView(
                        .breathing,
                        title: "Nothing yet",
                        message: "Ask what’s on your calendar, or what was just said in a meeting."
                    ) {
                        Button("What’s on my calendar?") {
                            Task {
                                await RealtimeAgent.shared.handle(
                                    "What's on my calendar today?",
                                    source: .text
                                )
                            }
                        }
                    }
                } else {
                    if !agent.harnessLine.isEmpty {
                        Text(agent.harnessLine)
                            .font(DS.Font.callout)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    conversation
                    if agent.isThinking {
                        Text(agent.progressTitle.isEmpty ? "Thinking…" : agent.progressTitle)
                            .font(DS.Font.callout)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    taskList
                    history
                }
            }
            .padding(DS.Space.page)
        }
        .background {
            if !isEmpty {
                Color.clear.orbBackdrop(.breathing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .navigationTitle("Agent")
    }

    private func permissionCard(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(request.title)
                .font(DS.Font.headline)
            Text(request.detail)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
            HStack(spacing: DS.Space.s) {
                Button("Dismiss") {
                    PermissionGate.shared.respond(id: request.id, approved: false)
                }
                Button("Approve") {
                    PermissionGate.shared.respond(id: request.id, approved: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.cardTight)
        .glassSurface()
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Conversation")
                .font(DS.Font.sectionLabel)
            ForEach(session.messages.suffix(12)) { message in
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(message.role == "user" ? "You" : "Next")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                    Text(message.text)
                        .font(DS.Font.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.cardTight)
                .glassSurface()
            }
        }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if !tasks.tasks.isEmpty {
                Text("Tasks")
                    .font(DS.Font.sectionLabel)
            }
            ForEach(tasks.tasks.prefix(8)) { task in
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(task.objective)
                        .font(DS.Font.headline)
                    Text(task.status.rawValue + (task.progress.isEmpty ? "" : " · \(task.progress)"))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                    if let result = task.result {
                        Text(result)
                            .font(DS.Font.callout)
                    }
                    if task.status == .running {
                        Button("Cancel") { tasks.cancel(task.id) }
                    }
                }
                .padding(DS.Space.cardTight)
                .glassSurface()
            }
            if let latest = activity.activities.first {
                Text(latest.title)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if !audit.entries.isEmpty {
                Text("History")
                    .font(DS.Font.sectionLabel)
            }
            ForEach(audit.entries.prefix(12)) { entry in
                LabeledContent(entry.at.formatted(date: .omitted, time: .shortened)) {
                    Text(entry.title)
                        .font(DS.Font.callout)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: DS.Space.s) {
            TextField("Ask Next…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }
            if agent.isThinking {
                Button("Stop") { RealtimeAgent.shared.cancel() }
            }
            Button("Send", action: send)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.isThinking)
        }
        .padding(DS.Space.m)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await RealtimeAgent.shared.handle(text, source: .text) }
    }
}
