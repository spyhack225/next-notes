import SwiftUI

/// The meeting panel's Ask section: the assistant, asked something while the meeting runs.
///
/// **No service, no prompt prefix, and no second conversation.** The question goes out as it
/// was typed, with `source: .meeting`, and the assistant reads the meeting through the seven
/// tools `Agent/Tools/MeetingTools.swift` already registers — the same tools every other turn
/// gets, chosen for it by `AgentCapabilityManifest`. Nothing here prepends a transcript:
/// `RealtimeAgent` records the utterance verbatim into the permanent conversation, so a
/// prefix would be a few hundred characters of raw speech sitting in the transcript and in
/// every later turn's context forever, and a hand-rolled context path around the manifest is
/// the regression `AGENTS.md` names. If a question needs something the assistant cannot look
/// at, the answer is a tool — never a prefix.
///
/// What this view *is* is the four things the reference chat panel is: a way in without
/// typing a sentence, the thread, a progress row that says what is happening, and a
/// composer. The status orb, the section chrome and the floating action belong to
/// `MeetingConsoleSheet`; this file draws none of them, and it draws no orb of its own.
struct MeetingConsoleAskSection: View {
    let session: MeetingSession
    @Binding var draft: String

    @State private var navigation = NavigationState.shared
    /// The one conversation. Held as state so the panel redraws when a row lands, and named
    /// for what it is rather than for the type.
    @State private var conversation = AgentSession.shared
    @State private var agent = RealtimeAgent.shared
    @State private var activityStore = AgentActivityStore.shared
    @State private var identity = AgentIdentityStore.shared
    @State private var loadNotice = ModelLoadNotice.shared

    @FocusState private var isComposerFocused: Bool

    /// `.thinking` while a turn is in flight, and `.idle` the rest of the time — including
    /// while the meeting itself is recording, because the recording is the *meeting's* work
    /// and the Meetings screen already says so. This case means one thing: a turn this
    /// section started is running right now.
    var activity: MeetingConsoleActivity { agent.isThinking ? .thinking : .idle }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if visibleMessages.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            Image(systemName: "sparkles")
                                .font(DS.Font.title)
                                .foregroundStyle(DS.Color.accent)
                            Text("Ask about this meeting")
                                .font(DS.Font.title)
                            Text("Find a decision, a follow-up or something you missed.")
                                .font(DS.Font.callout)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                        .padding(.top, DS.Space.xl)
                        suggestions
                    } else {
                        MeetingConsoleSectionHeader(section: .ask)
                    }
                    thread
                    if agent.isThinking { thinkingRow }
                    // A model failure belongs beside the question that exposed it.
                    if let problem = loadNotice.message {
                        notice(problem, symbol: "exclamationmark.triangle")
                    }
                }
                .padding(DS.Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            composer
            .padding(DS.Space.page)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The way in

    /// Ready-made questions, in the reference's inset bubble and collapsible.
    ///
    /// Generic on purpose: this card is the same on every meeting, so a question that names a
    /// person, a project or a deadline would be wrong in the meeting it is shown in. Tapping
    /// one fills the field rather than sending it — a person in a call should see what they
    /// are about to ask before it is asked.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Self.suggestions, id: \.self) { question in
                Button {
                    draft = question
                    isComposerFocused = true
                } label: {
                    HStack(spacing: DS.Space.s) {
                        Text(question)
                            .font(DS.Font.callout)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: DS.Space.s)
                        Image(systemName: "arrow.up.left")
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                    .padding(DS.Space.m)
                    .background(DS.Color.content, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                        .stroke(DS.Color.separator))
                }
                .buttonStyle(.plain)
                .help("Put this in the box so you can change it first")
            }
        }
    }

    private static let suggestions = [
        "What have we decided so far?",
        "What is still open?",
        "Who do I need to follow up with?",
        "What did we agree about the deadline?",
    ]

    // MARK: - The thread

    /// A window onto the one conversation, not a second one.
    ///
    /// A filter rather than an assembly, and the filter has to carry the *answers* as well
    /// as the questions. `AgentSession.recordUser` stamps `source` on the question
    /// (`RealtimeAgent.swift:1133`), but `recordAssistant` is called with
    /// `source: currentTurnSource == .voice ? .voice : nil`
    /// (`RealtimeAgent.swift:748`) — so an answer given to a question asked from a meeting is
    /// an ordinary row with no source at all, and filtering on `source == "meeting"` alone
    /// would show every question this panel has ever asked and not one reply. A question
    /// therefore carries the rows that follow it up to the next question of any kind, which
    /// drops an answer that a spoken turn overtook rather than showing it under the wrong
    /// question.
    private var threadMessages: [AgentSession.Message] {
        var out: [AgentSession.Message] = []
        var carriesAnswer = false
        for message in conversation.messages where message.at >= session.meeting.start {
            // A question re-decides whether the rows after it belong to this panel; every
            // other row belongs to whichever question is open, and to none once a question
            // from somewhere else has taken over.
            if message.role == "user" {
                carriesAnswer = message.source == MeetingConsoleAskSection.meetingSource
            }
            if carriesAnswer { out.append(message) }
        }
        return out
    }

    /// `AgentUtteranceSource.meeting.rawValue`, read from the case rather than typed out.
    private static let meetingSource = AgentUtteranceSource.meeting.rawValue

    /// The rows this panel draws. `AgentSession` keeps 120 of them and a panel over a long
    /// meeting is not the place to render all of them; the count of what is left is said
    /// below, with the way to reach it.
    private var visibleMessages: [AgentSession.Message] {
        Array(threadMessages.suffix(Self.maxThreadRows))
    }

    private static let maxThreadRows = 8

    @ViewBuilder
    private var thread: some View {
        if !visibleMessages.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                ForEach(visibleMessages) { message in
                    messageRow(message)
                }
                threadFooter
            }
        }
    }

    /// `AgentView.messageRow`, unchanged where it can be: the same bubble geometry, the same
    /// weights, the same still portrait. The one difference is the source chip, which is
    /// dropped — `AgentView` labels a row by how it arrived, and every row here arrived the
    /// same way, so a chip would say the same thing once per question.
    private func messageRow(_ message: AgentSession.Message) -> some View {
        let isUser = message.role == "user"
        return HStack(alignment: .bottom, spacing: DS.Space.s) {
            if isUser { Spacer(minLength: DS.Space.xl) }
            if !isUser {
                NotionAvatarView(config: identity.avatar, size: DS.Size.agentAvatar)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    Text(isUser ? "You" : identity.name).font(DS.Font.chip)
                    Text(message.at, format: .dateTime.hour().minute())
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                Text(message.text)
                    .font(DS.Font.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(isUser ? DS.Space.m : 0)
                    .background(isUser ? DS.Color.accent.opacity(DS.Opacity.chipFill) : .clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.card))
            }
            // The Agent pane's own bubble cap, which the 312pt content column is far narrower
            // than — `maxWidth` clamps, so the bubble simply takes the column.
            .frame(maxWidth: DS.Size.agentBubbleMaxWidth, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: DS.Space.xl) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// What this panel is not, and the one press that reaches it.
    private var threadFooter: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(footerSentence)
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open the full conversation") { navigation.showConversation() }
                .buttonStyle(.link)
                .font(DS.Font.callout)
        }
    }

    private var footerSentence: String {
        let all = threadMessages.count
        guard all > visibleMessages.count else {
            return "These are only the turns asked from inside meetings. The rest of the "
                + "conversation is one press away."
        }
        return "Showing \(visibleMessages.count) of \(all) messages from meetings."
    }

    // MARK: - The turn in flight

    /// `AgentView.thinkingRow`'s shape, with the step list under it.
    ///
    /// The panel's own orb is the sheet's `searching` case, so what this row has to add is
    /// the *words*: a turn that reads a meeting and calls four things can take a minute, and
    /// a minute of one sentence that does not change is a screen that looks frozen. The step
    /// titles are the tool layer's own — `AgentActivityProjector` has already rewritten them
    /// into the person's words, so they are shown as they are and no state is inferred from
    /// them; the ✓ and ◐ come from the position in the list, which is data rather than a
    /// reading of the text.
    private var thinkingRow: some View {
        let feed = activityStore.liveSteps
        return HStack(alignment: .top, spacing: DS.Space.s) {
            // The still portrait, never `AgentAvatarView`: the sheet's `searching` orb is
            // the one animating shape on this screen, and a second live avatar beside a
            // meeting is the battery bug the avatar rules are written against. The fallback
            // is the same state the row is in — reading things this app did not write.
            NotionAvatarView(
                config: identity.avatar,
                size: DS.Size.agentAvatar,
                fallbackOrb: .searching
            )
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(agent.progressTitle.isEmpty
                     ? "\(identity.name) is thinking…"
                     : agent.progressTitle)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !feed.titles.isEmpty {
                    ForEach(Array(feed.titles.enumerated()), id: \.offset) { index, title in
                        stepRow(title, isCurrent: index + 1 == feed.current)
                    }
                    Text("Step \(feed.current) of \(feed.total)")
                        .font(DS.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.textTertiary)
                        .contentTransition(.numericText())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stepRow(_ title: String, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: isCurrent ? "circle.bottomhalf.filled" : "checkmark.circle")
                .font(DS.Font.footnote)
                .foregroundStyle(isCurrent ? DS.Color.accent : DS.Color.success)
                .frame(width: DS.Size.orbBadge)
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(2)
        }
    }

    // MARK: - Model availability

    /// A quiet inline notice, with the one move that changes it.
    ///
    /// A model that cannot answer needs to say why in the panel where the question was asked.
    private func notice(_ message: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(DS.Color.warning)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(message)
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Open Settings…") }
                    .buttonStyle(.link)
                    .font(DS.Font.callout)
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: - The composer

    /// The question field and its controls. Tool access is decided by the agent's manifest
    /// for the actual words asked; a separate scope selector here would need to change that
    /// decision before it could promise a narrower answer.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Space.m) {
            TextField("Ask about this meeting…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isComposerFocused)
                .onSubmit { send() }
                .onKeyPress(phases: .down) { press in
                    // Plain Return sends; Shift/Option/Control+Return inserts a newline.
                    // Copied from `AgentView.composer` rather than reinvented, because two
                    // composers that disagree about Shift-Return is the kind of thing a
                    // person only discovers by pressing it.
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
                Button("Stop", systemImage: "stop.fill") {
                    // The gate first, as in `AgentView`: this panel cannot draw the card a
                    // parked confirmation waits on, so a turn that would have stopped for
                    // approval has to be told no rather than left asking in silence.
                    ACPConfirmationGate.shared.cancel()
                    RealtimeAgent.shared.cancel()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(DS.Space.m)
        .background(DS.Color.content, in: RoundedRectangle(cornerRadius: DS.Radius.glass))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.glass)
            .stroke(DS.Color.separator))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        // A second question while the first is still running supersedes it, which is what
        // `AgentView.send` does: `interrupt` keeps the transcript and drops the work, and
        // `cancel` would write a "Stopped." line into the meeting's own thread.
        if agent.isThinking { RealtimeAgent.shared.interrupt() }
        Task { await RealtimeAgent.shared.handleLive(text, source: .meeting) }
    }
}
