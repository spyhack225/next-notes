import SwiftUI

/// The tabs of the Agent inspector, in strip order. Mirrors the four panes a person looks
/// at most while working beside the conversation: what it has been doing, what is waiting
/// for a yes, what runs on its own, and who it is.
///
/// `rawValue` is what `@AppStorage` persists; the `title` is the consumer word the app
/// already uses for the same thing (the pane switcher calls the schedule pane "Reminders"),
/// and the symbol is what the compact strip draws.
enum AgentInspectorTab: String, CaseIterable, Identifiable {
    case activity
    case approvals
    case reminders
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .approvals: "Approvals"
        case .reminders: "Reminders"
        case .agent: "Agent"
        }
    }

    var symbol: String {
        switch self {
        case .activity: "clock.arrow.circlepath"
        case .approvals: "hand.raised"
        case .reminders: "calendar"
        case .agent: "person.crop.circle"
        }
    }
}

/// The Agent section's trailing inspector: the same information the full panes carry,
/// arranged as a narrow column beside the conversation so it can be read *while* the
/// conversation stays on screen.
///
/// The layout reference is a right sidebar with a compact icon tab strip over grouped,
/// timestamped history; only the layout is borrowed. The vocabulary is this app's, the
/// surfaces are DS tokens, and every row is fed by the store its pane already reads —
/// `AgentAuditLog` (with `AgentActivityStore` for what is running now) for Activity and
/// Approvals, `ScheduleStore` for Reminders, `AgentIdentityStore` for the Agent card.
///
/// Deliberately not here: answering a pending approval, running a routine now, editing
/// memories. Each of those has a full surface — the reviewed card, the routine row, the
/// editor — and a 340pt column is not it. The inspector says what is true and points at
/// where the act lives.
struct AgentInspector: View {
    @AppStorage("agent.inspector.tab") private var selected: AgentInspectorTab = .activity

    @State private var audit = AgentAuditLog.shared
    @State private var activity = AgentActivityStore.shared
    @State private var schedules = ScheduleStore.shared
    @State private var identity = AgentIdentityStore.shared
    @State private var settings = Settings.shared
    @State private var gate = PermissionGate.shared
    @State private var acpGate = ACPConfirmationGate.shared
    @State private var grants = PermissionGrantStore.shared
    @State private var persisted: [DayGroup] = []

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [AgentAuditEntry]
        var id: Date { day }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    switch selected {
                    case .activity: activityTab
                    case .approvals: approvalsTab
                    case .reminders: remindersTab
                    case .agent: agentTab
                    }
                }
                .padding(DS.Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // A pane of its own, not a card: the material gives the column a plane against the
        // window, and the DS token keeps Reduce Transparency's fallback the system's job.
        .background(DS.Material.thin)
        .onAppear { reload() }
    }

    // MARK: - Tab strip

    /// Icon-only, four equal targets, name in the tooltip and the accessibility tree. Kept
    /// compact on purpose: the strip is a way in, not a second header.
    private var tabStrip: some View {
        HStack(spacing: DS.Space.xxs) {
            ForEach(AgentInspectorTab.allCases) { tab in
                Button {
                    selected = tab
                } label: {
                    Image(systemName: tab.symbol)
                        .font(DS.Font.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.s)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.glassSmall)
                                .fill(tab == selected
                                      ? DS.Color.accent.opacity(DS.Opacity.chipFill)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == selected ? DS.Color.accent : DS.Color.textSecondary)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab == selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
    }

    // MARK: - Activity

    /// What the assistant has done, day by day, plus the step running right now. The store
    /// models the live step; the audit log models the history.
    @ViewBuilder
    private var activityTab: some View {
        if let live = liveActivity {
            AgentPaneSection(title: "Right now") {
                row(
                    symbol: "circle.dotted",
                    title: live.title,
                    subtitle: live.detail.isEmpty ? nil : live.detail,
                    age: live.createdAt
                )
            }
        }
        if activityDays.isEmpty {
            emptyLine("What your assistant does — searches, approvals, wake words — shows up here, day by day.")
        }
        ForEach(activityDays) { group in
            AgentPaneSection(title: AgentInspectorWording.dayTitle(group.day)) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(group.entries) { entry in activityRow(entry) }
                }
            }
        }
    }

    /// The newest step of the task that is running now — the one thing
    /// `AgentActivityStore` models that the audit log cannot say live. Nil when nothing
    /// is running, so the line never names work that has stopped.
    private var liveActivity: AgentActivity? {
        guard let taskID = activity.activeTaskID else { return nil }
        return activity.activities.first { $0.taskID == taskID }
    }

    /// The in-memory log plus the persisted file, de-duplicated by id — ActivityView's own
    /// merge, at the inspector's scale: the newest day groups only. The full history is the
    /// Activity pane's job; a column read at a glance is not it.
    private var activityDays: [DayGroup] {
        var byID: [String: AgentAuditEntry] = [:]
        for entry in audit.entries where showsInHistory(entry) { byID[entry.id] = entry }
        for group in persisted {
            for entry in group.entries where showsInHistory(entry) { byID[entry.id] = entry }
        }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: byID.values) { calendar.startOfDay(for: $0.at) }
        return grouped.keys.sorted(by: >).prefix(3).map { day in
            DayGroup(day: day, entries: (grouped[day] ?? []).sorted { $0.at > $1.at })
        }
    }

    /// A request and its reply are the conversation itself, which is on screen beside this
    /// column; the history shows what the assistant did with what was asked.
    private func showsInHistory(_ entry: AgentAuditEntry) -> Bool {
        switch entry.kind {
        case .request, .reply: false
        case .tool, .permission, .task, .wake, .wakeMiss, .wakeFalse: true
        }
    }

    private func activityRow(_ entry: AgentAuditEntry) -> some View {
        row(
            symbol: AgentInspectorWording.symbol(for: entry.kind),
            title: AgentInspectorWording.title(entry),
            subtitle: AgentInspectorWording.approvalStatus(entry),
            age: entry.at
        )
    }

    // MARK: - Approvals

    /// First what is waiting for an answer right now (the gate's own pending request, and
    /// the ACP harness card), then the standing always-allowed answers, then the history
    /// the audit log recorded.
    @ViewBuilder
    private var approvalsTab: some View {
        if gate.pending != nil || acpGate.pending != nil {
            AgentPaneSection(title: "Waiting for you", count: pendingCount) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if let request = gate.pending {
                        row(
                            symbol: "hand.raised",
                            title: request.title,
                            subtitle: "Waiting for your answer",
                            age: request.createdAt
                        )
                    }
                    if let acp = acpGate.pending {
                        row(
                            symbol: "terminal",
                            title: acp.title,
                            subtitle: acp.detail,
                            age: nil
                        )
                    }
                }
            }
        }
        if !alwaysGrants.isEmpty {
            AgentPaneSection(title: "Always allowed", count: alwaysGrants.count) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(alwaysGrants) { grant in grantRow(grant) }
                }
            }
        }
        AgentPaneSection(title: "History", count: approvalHistory.count) {
            if approvalHistory.isEmpty {
                emptyLine("Nothing has been approved or dismissed yet. Anything that needs your yes shows up here.")
            } else {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(approvalHistory) { entry in approvalRow(entry) }
                }
            }
        }
    }

    private var pendingCount: Int {
        (gate.pending == nil ? 0 : 1) + (acpGate.pending == nil ? 0 : 1)
    }

    /// Standing "always allow this action" answers — the one stored form of "always
    /// allowed". A grant for one task or one meeting is not always, and the ledger that
    /// lists every grant is the Activity pane's.
    private var alwaysGrants: [PermissionGrant] {
        grants.grants.filter { $0.duration == .alwaysThisAction }
    }

    private func grantRow(_ grant: PermissionGrant) -> some View {
        row(
            symbol: "checkmark.shield",
            title: ToolCallReviewBuilder.humanTitle(forToolID: grant.toolID),
            subtitle: grant.scope.displayName,
            age: grant.createdAt
        )
    }

    private var approvalHistory: [AgentAuditEntry] {
        Array(audit.entries.filter { $0.kind == .permission }.prefix(20))
    }

    private func approvalRow(_ entry: AgentAuditEntry) -> some View {
        row(
            symbol: "hand.raised",
            title: AgentInspectorWording.title(entry),
            subtitle: AgentInspectorWording.approvalStatus(entry),
            age: entry.at
        )
    }

    // MARK: - Reminders

    /// The next runs, grouped the way the recurrence reads. `nextRunAt` is the scheduler's
    /// own answer, never recomputed here — the inspector reads the store, it does not
    /// schedule.
    @ViewBuilder
    private var remindersTab: some View {
        if schedules.schedules.isEmpty {
            emptyLine("Nothing runs on its own yet. Ask for a reminder, and it shows up here with its next run.")
        }
        ForEach(scheduleGroups) { group in
            AgentPaneSection(title: group.group.title, count: group.items.count) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(group.items) { schedule in scheduleRow(schedule) }
                }
            }
        }
    }

    private struct ScheduleGroup: Identifiable {
        let group: AgentInspectorScheduleGroup
        let items: [AgentSchedule]
        var id: String { group.rawValue }
    }

    private var scheduleGroups: [ScheduleGroup] {
        AgentInspectorScheduleGroup.allCases.compactMap { group in
            let items = schedules.schedules
                .filter { AgentInspectorScheduleGroup.of($0) == group }
                .sorted(by: AgentInspectorWording.scheduleOrder)
            return items.isEmpty ? nil : ScheduleGroup(group: group, items: items)
        }
    }

    private func scheduleRow(_ schedule: AgentSchedule) -> some View {
        row(
            symbol: AgentInspectorWording.scheduleSymbol(for: schedule.kind),
            title: schedule.title,
            subtitle: AgentInspectorWording.scheduleTimeLine(schedule),
            age: nil
        )
    }

    // MARK: - Agent

    /// The compact identity card. The avatar is the still `NotionAvatarView`, never the
    /// animated one: the conversation's thinking row and the working card already animate
    /// the character, and two live portraits on one screen is one too many.
    private var agentTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                NotionAvatarView(config: identity.avatar, size: DS.Size.agentAvatarThumb)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(identity.name)
                        .font(DS.Font.title3)
                        .lineLimit(1)
                    connectedStatus
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: DS.Space.s) {
                Button("Edit") { NavigationState.shared.showAgentAbout() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("SOUL") { NavigationState.shared.showAgentAbout() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("MEMORY") { NavigationState.shared.openMemories(nil) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentCardSurface()
    }

    /// The same status line AgentAboutView's hero carries, from the same two switches.
    private var connectedStatus: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "bolt.fill")
                .font(DS.Font.caption)
            Text(settings.voiceWakeEnabled || settings.agentShortcutEnabled
                 ? "Connected"
                 : "Ready")
                .font(DS.Font.callout.weight(.medium))
        }
        .foregroundStyle(DS.Color.success)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    /// One row: a leading symbol, the sentence, an optional second line, and the relative
    /// age at the trailing edge. No card surface and no animation — the column itself is
    /// the surface, and a list of cards in a 340pt strip reads as a stack of windows.
    private func row(
        symbol: String,
        title: String,
        subtitle: String? = nil,
        age: Date? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: symbol)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Size.orbBadge)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.xs)
            if let age {
                Text(AgentInspectorWording.relativeAge(age))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The inspector's empty line. Deliberately not `OrbUnavailableView`: that illustration
    /// is sized for a full pane, and the orb vocabulary allows one animating mark per
    /// screen, naming work that is running — an empty tab has none.
    private func emptyLine(_ message: String) -> some View {
        Text(message)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload() {
        persisted = AgentAuditLog.loadPersistedGroupedByDay().map {
            DayGroup(day: $0.day, entries: $0.entries)
        }
        schedules.reload()
    }
}

/// How a reminder is grouped in the inspector. Muse's Daily / Weekly are the two groups a
/// person expects first; the rest of what the scheduler can express (a monthly run, a
/// one-shot, an event trigger) keeps its own heading rather than being hidden under one
/// that would be untrue of it.
enum AgentInspectorScheduleGroup: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly
    case oneTime
    case event

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .oneTime: "One time"
        case .event: "When something happens"
        }
    }

    static func of(_ schedule: AgentSchedule) -> Self {
        if schedule.kind == .trigger { return .event }
        switch schedule.when?.repeatRule {
        case .daily, .weekdays: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .once, nil: return .oneTime
        }
    }
}

/// The inspector's pure wording, kept beside the view so the rules — which stored audit
/// detail is a status, which day reads as "Today", which tool id a person sees — can be
/// read and pinned without a window.
@MainActor
enum AgentInspectorWording {
    /// "2d ago". `RelativeDateTimeFormatter` is what the app already uses for relative
    /// time; the abbreviated unit style is the one that fits a 340pt row.
    static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The same three-day wording the Activity pane uses.
    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    static func symbol(for kind: AgentAuditEntry.Kind) -> String {
        switch kind {
        case .tool: "wrench.and.screwdriver"
        case .permission: "hand.raised"
        case .task: "checklist"
        case .wake, .wakeMiss, .wakeFalse: "waveform"
        case .request: "bubble.left"
        case .reply: "bubble.right"
        }
    }

    /// The row's title. A routine's permission rows embed the raw tool id ("Refused in a
    /// routine: browser.click"); a person reads the tool's own name instead, the same
    /// substitution the Activity pane's ledger makes for a standing grant.
    static func title(_ entry: AgentAuditEntry) -> String {
        guard let toolID = entry.toolID, entry.title.contains(toolID) else { return entry.title }
        return entry.title.replacingOccurrences(
            of: toolID,
            with: ToolCallReviewBuilder.humanName(forToolID: toolID)
        )
    }

    /// The status line of a recorded approval, from what the audit log stores and nothing
    /// else. `PermissionGate` writes the outcome into `detail` — "Approved as proposed",
    /// "Approved after you edited …", "Dismissed" — and those are what a status may say.
    /// A scheduled run's `detail` is either a reference to itself (a tool id and the
    /// routine's own id, which is not an outcome) or the reason a call was refused; only
    /// the refusal is a status, and its machine half becomes the tool's name.
    static func approvalStatus(_ entry: AgentAuditEntry) -> String? {
        guard entry.kind == .permission else { return nil }
        let detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail == "Dismissed" { return detail }
        if detail.hasPrefix("Approved") { return detail }
        guard let toolID = entry.toolID, detail.contains("was refused") else { return nil }
        return detail.replacingOccurrences(
            of: toolID,
            with: ToolCallReviewBuilder.humanName(forToolID: toolID)
        )
    }

    /// What the row under a reminder says: its next run, or why it has none. The wording
    /// follows the Reminders pane's own summary line ("Off", "Done", "Waiting for its
    /// event"), so the two never describe one schedule two ways.
    static func scheduleTimeLine(_ schedule: AgentSchedule) -> String {
        if !schedule.enabled {
            return schedule.isOneShot && schedule.nextRunAt == nil ? "Done" : "Off"
        }
        if schedule.kind == .trigger { return "Waiting for its event" }
        guard let next = schedule.nextRunAt else { return "No next run" }
        return "Next " + next.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func scheduleSymbol(for kind: AgentSchedule.Kind) -> String {
        switch kind {
        case .routine: "gearshape.2"
        case .trigger: "bolt"
        case .reminder: "bell"
        }
    }

    /// Soonest first, and a schedule with no next run last. The reminder is what the
    /// heading promises, so the order under it is the schedule's own.
    static func scheduleOrder(_ lhs: AgentSchedule, _ rhs: AgentSchedule) -> Bool {
        let left = lhs.nextRunAt ?? .distantFuture
        let right = rhs.nextRunAt ?? .distantFuture
        if left != right { return left < right }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}
