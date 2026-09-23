import SwiftUI

/// Agent → Reminders (Part 3). What runs and when.
///
/// Triggers (R3) are listed with the rest: the event they wait for instead of a next run.
/// Every reminder and run with its plain-English sentence, next run, last result and a
/// switch; open one for its run history — skipped slots and their reasons included — the
/// drafts it left awaiting approval, *Run now*, *Edit* and *Delete*. Suggestions from the
/// memory review sit at the top with *Set it up* and *Dismiss*, and every draft still
/// awaiting approval is listed above the rest so none is buried in a closed row. Goals —
/// the outcomes these reminders are about — live one pane over.
struct RoutinesView: View {
    @State private var store = ScheduleStore.shared
    @State private var review = MemoryReviewStateStore.shared
    @State private var settings = Settings.shared
    @State private var expanded: Set<UUID> = []
    @State private var editing: AgentSchedule?
    @State private var busy: Set<UUID> = []
    @State private var message: String?

    var body: some View {
        AgentPaneScroll {
            AgentPaneHeader(
                title: "Reminders",
                subtitle: "What your assistant runs on its own, and when — reminders, recurring runs "
                    + "and runs that wait for something to happen. Anything it would write or "
                    + "send waits for your yes."
            )
            if !review.openSuggestions.isEmpty { suggestions }
            AgentSplit {
                listsColumn
            } rail: {
                railColumn
            }
            if let message {
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
        }
        .onAppear { store.reload() }
        .sheet(item: $editing) { schedule in
            RoutineEditor(schedule: schedule) { edit in
                perform(schedule.id) { _ = try await AgentScheduler.shared.update(id: schedule.id, edit: edit, now: Date()) }
            }
        }
    }

    // MARK: - Sections

    /// The left column: anything awaiting approval first — a draft is never buried in a
    /// closed row — then the reminders, recurring runs and triggers.
    private var listsColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            if !store.awaitingDrafts.isEmpty {
                AgentPaneSection(title: "Awaiting your approval", count: store.awaitingDrafts.count) {
                    ForEach(store.awaitingDrafts) { draft in draftRow(draft) }
                }
            }
            schedulesSections
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The right rail: the login switch, and the empty state when nothing is set up yet.
    /// On a narrow window `AgentSplit` stacks it under the list.
    private var railColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            launchAtLogin
            if store.schedules.isEmpty { emptyState }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestions: some View {
        AgentPaneSection(title: "Suggested", count: review.openSuggestions.count) {
            ForEach(review.openSuggestions) { suggestion in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(suggestion.offer())
                        .font(DS.Font.callout)
                    HStack(spacing: DS.Space.s) {
                        Button("Set it up") {
                            review.resolveSuggestion(id: suggestion.id)
                            NavigationState.shared.agentPane = .conversation
                            let request = suggestion.request
                            Task { await RealtimeAgent.shared.handleLive("Set this up: \(request)", source: .text) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Dismiss") { review.resolveSuggestion(id: suggestion.id) }
                    }
                }
                .padding(DS.Space.cardTight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(cornerRadius: DS.Radius.card)
            }
        }
    }

    private func drafts(_ items: [RoutineDraft], title: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title).font(DS.Font.sectionLabel)
            ForEach(items) { draft in draftRow(draft) }
        }
    }

    private func draftRow(_ draft: RoutineDraft) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(store.schedule(id: draft.scheduleID)?.title ?? "Reminder")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer()
                Text(draft.createdAt, format: .dateTime.weekday().hour().minute())
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Text(draft.title).font(DS.Font.headline)
            if draft.status == .awaitingApproval {
                // §8.2 status sublines: every tracked row carries a live one-line state,
                // so "waiting" is never silent about what it is waiting for.
                Text(draftSummary(draft))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            if let preview = draft.preview, !preview.isEmpty {
                Text(preview)
                    .font(DS.Font.callout)
                    .textSelection(.enabled)
            }
            switch draft.status {
            case .awaitingApproval:
                HStack(spacing: DS.Space.s) {
                    Button("Dismiss") { AgentScheduler.shared.dismissDraft(id: draft.id) }
                    Button("Approve") {
                        perform(draft.id) { _ = try await AgentScheduler.shared.approveDraft(id: draft.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy.contains(draft.id))
                }
            case .approved, .dismissed, .failed:
                Text(draft.status == .approved ? "Approved\(draft.result.map { " — \($0)" } ?? "")"
                     : draft.status == .dismissed ? "Dismissed" : "Failed: \(draft.result ?? "")")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    /// Split by what each row is, not by which store it came from (§8.3): a reminder is
    /// what it says, a recurring run is what it does on a schedule, and a trigger waits
    /// for something to happen. Outcomes — the goals these runs are about — belong to the
    /// Goals pane. The empty state lives in the rail, so nothing renders here when there
    /// is nothing to list.
    @ViewBuilder
    private var schedulesSections: some View {
        let sorted = store.schedules.sorted {
            ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture)
        }
        let reminders = sorted.filter { $0.kind == .reminder }
        let recurring = sorted.filter { $0.kind == .routine }
        let triggers = sorted.filter { $0.kind == .trigger }
        if !reminders.isEmpty {
            AgentPaneSection(title: "Your reminders", count: reminders.count) {
                ForEach(reminders) { scheduleRow($0) }
            }
        }
        if !recurring.isEmpty {
            AgentPaneSection(title: "Recurring runs", count: recurring.count) {
                ForEach(recurring) { scheduleRow($0) }
            }
        }
        if !triggers.isEmpty {
            AgentPaneSection(title: "When something happens", count: triggers.count) {
                ForEach(triggers) { scheduleRow($0) }
            }
        }
    }

    private func scheduleRow(_ schedule: AgentSchedule) -> some View {
        let isOpen = expanded.contains(schedule.id)
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: schedule.kind == .routine ? "gearshape.2" : schedule.kind == .trigger ? "bolt" : "bell")
                    .foregroundStyle(DS.Color.textSecondary)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(schedule.plainEnglish)
                        .font(DS.Font.callout)
                        .textSelection(.enabled)
                    Text(summary(schedule))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { schedule.enabled },
                    set: { on in
                        perform(schedule.id) {
                            if on { _ = try await AgentScheduler.shared.resume(id: schedule.id, now: Date()) }
                            else { _ = try await AgentScheduler.shared.pause(id: schedule.id, now: Date()) }
                        }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(busy.contains(schedule.id))
                Button {
                    if isOpen { expanded.remove(schedule.id) } else { expanded.insert(schedule.id) }
                } label: {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isOpen ? "Hide details" : "Show details")
            }
            if isOpen { details(schedule) }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    @ViewBuilder
    private func details(_ schedule: AgentSchedule) -> some View {
        HStack(spacing: DS.Space.s) {
            Button("Run now") {
                perform(schedule.id) { _ = try await AgentScheduler.shared.runNow(id: schedule.id, now: Date()) }
            }
            .disabled(busy.contains(schedule.id))
            Button("Edit") { editing = schedule }
            Button("Delete", role: .destructive) {
                perform(schedule.id) { try await AgentScheduler.shared.remove(id: schedule.id) }
            }
        }
        if let trigger = schedule.trigger, schedule.kind == .trigger {
            Text("Runs once per event: \(trigger.describe())"
                 + (schedule.endsAt.map { " · until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            if let note = ScheduleTrigger.callDetectionNote(
                for: trigger, detectionEnabled: Settings.shared.callDetectionEnabled) {
                Text(note)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
        }
        if schedule.kind != .reminder {
            // The internals stay one disclosure down (§8.3 exposure discipline): what a
            // person needs is what it may use and what stops it, in their own words —
            // never a tool id, a model id or a step budget on the open row.
            DisclosureGroup("What it can use") {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(schedule.allowedTools.isEmpty
                         ? "It can use: nothing extra"
                         : "It can use: "
                             + schedule.allowedTools
                                 .map(ToolCallReviewBuilder.humanName(forToolID:))
                                 .joined(separator: ", "))
                    Text("Runs on: \(Self.modelLabel(schedule.model))")
                    Text("Stops after \(schedule.budget.maxToolCalls) step"
                         + (schedule.budget.maxToolCalls == 1 ? "" : "s")
                         + " or \(max(1, schedule.budget.maxSeconds / 60)) minute"
                         + (schedule.budget.maxSeconds / 60 == 1 ? "" : "s"))
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .padding(.top, DS.Space.xxs)
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
        }
        let scheduleDrafts = store.drafts(for: schedule.id)
        if !scheduleDrafts.isEmpty {
            drafts(Array(scheduleDrafts.prefix(10)), title: "Drafts")
        }
        let history = store.runs(for: schedule.id, limit: 30).reversed()
        Text("History").font(DS.Font.sectionLabel)
        if history.isEmpty {
            Text("Nothing has run yet.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
        ForEach(Array(history)) { run in
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(run.at, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(DS.Font.timestamp)
                    .foregroundStyle(DS.Color.textSecondary)
                Text(Self.outcomeLabel(run.outcome))
                    .font(DS.Font.chip)
                Text(run.detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    private static let examples = [
        "Every Monday at 8, summarise last week’s meetings",
        "Remind me every weekday at 9 to stand up",
        "When a call ends, draft the follow-up email",
    ]

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                ThinkingOrb(state: .breathing, size: DS.Size.iconLarge)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Nothing set up yet").font(DS.Font.headline)
                    Text("Just ask, in your own words. Try one of these:")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(Self.examples, id: \.self) { example in
                    Button {
                        NavigationState.shared.agentPane = .conversation
                        Task { await RealtimeAgent.shared.handleLive(example, source: .text) }
                    } label: {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(DS.Color.accent)
                            Text("“\(example)”")
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, DS.Space.xs)
                    .padding(.horizontal, DS.Space.s)
                    .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                }
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    private var launchAtLogin: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: "power")
                .font(DS.Font.title3)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Size.iconLarge)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Open Next Notes at login")
                Text("Recurring runs wait until Next Notes is open. Reminders still reach you when it is closed.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            Toggle("Open Next Notes at login", isOn: $settings.agentLaunchAtLogin)
                .labelsHidden()
                .toggleStyle(.switch)
                .onChange(of: settings.agentLaunchAtLogin) { _, on in
                    message = LaunchAtLogin.apply(on)
                }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: - Helpers

    private func summary(_ schedule: AgentSchedule) -> String {
        var parts: [String] = []
        if !schedule.enabled {
            parts.append(schedule.isOneShot && schedule.nextRunAt == nil ? "Done" : "Off")
        } else if schedule.kind == .trigger {
            parts.append("Waiting for its event")
        } else if let next = schedule.nextRunAt {
            parts.append("Next " + next.formatted(date: .abbreviated, time: .shortened))
        }
        if let last = schedule.lastRun {
            parts.append("last: \(Self.outcomeLabel(last.outcome).lowercased()) "
                         + last.at.formatted(date: .abbreviated, time: .shortened))
        }
        if schedule.consecutiveFailures > 0 {
            parts.append("\(schedule.consecutiveFailures) failure\(schedule.consecutiveFailures == 1 ? "" : "s") in a row")
        }
        let waiting = store.drafts(for: schedule.id).filter { $0.status == .awaitingApproval }.count
        if waiting > 0 { parts.append("\(waiting) awaiting approval") }
        return parts.joined(separator: " · ")
    }

    /// The one-line state under a draft awaiting a yes (§8.2): how long it has waited and
    /// what it is waiting on. "Blocked on who it goes to" is answerable; "Awaiting
    /// approval" is not.
    private func draftSummary(_ draft: RoutineDraft) -> String {
        var parts: [String] = []
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: draft.createdAt),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        switch days {
        case ...0: parts.append("Waiting today")
        case 1: parts.append("Waiting 1 day")
        default: parts.append("Waiting \(days) days")
        }
        let blocked = draftBlockers(draft)
        if blocked.isEmpty {
            parts.append("ready for your yes")
        } else {
            parts.append("blocked on " + blocked.prefix(2).map { $0.label.lowercased() }
                .joined(separator: " and "))
        }
        return parts.joined(separator: " · ")
    }

    /// The fields the card would still ask for. Empty means the draft is ready to run.
    private func draftBlockers(_ draft: RoutineDraft) -> [ToolCallField] {
        guard let tool = AgentToolRegistry.shared.tool(named: draft.toolID) else { return [] }
        return ToolCallReviewBuilder.review(
            id: draft.id.uuidString, tool: tool, arguments: draft.arguments
        ).blockers
    }

    static func modelLabel(_ model: AgentSchedule.ModelChoice) -> String {
        switch model {
        case .auto: "Automatic"
        case .local: "This Mac"
        case .cloud: "OpenRouter"
        }
    }

    static func outcomeLabel(_ outcome: ScheduleRunRecord.Outcome) -> String {
        switch outcome {
        case .started: "Running"
        case .delivered: "Delivered"
        case .missed: "Missed"
        case .skipped: "Skipped"
        case .deferred: "Held"
        case .deliveredBySystem: "Delivered by macOS"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .ended: "Ended"
        case .ranNow: "Ran now"
        case .completed: "Ran"
        case .nothingToReport: "Nothing to report"
        }
    }

    private func perform(_ id: UUID, _ action: @escaping @MainActor () async throws -> Void) {
        busy.insert(id)
        Task { @MainActor in
            defer { busy.remove(id) }
            do {
                try await action()
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// Edits what the user confirmed: the title, the instructions and, for a routine, the model.
/// The time, the allowed tools and the end date change through the Agent, which restates
/// the sentence first; nothing the scheduler owns is editable.
private struct RoutineEditor: View {
    let schedule: AgentSchedule
    let save: (ScheduleEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var prompt: String
    @State private var model: AgentSchedule.ModelChoice

    init(schedule: AgentSchedule, save: @escaping (ScheduleEdit) -> Void) {
        self.schedule = schedule
        self.save = save
        _title = State(initialValue: schedule.title)
        _prompt = State(initialValue: schedule.prompt)
        _model = State(initialValue: schedule.model)
    }

    var body: some View {
        Form {
            TextField("Title", text: $title)
            TextField(schedule.kind == .reminder ? "Reminder" : "Instructions", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
            if schedule.kind != .reminder {
                Picker("Model", selection: $model) {
                    Text("Automatic").tag(AgentSchedule.ModelChoice.auto)
                    Text("Local model on this Mac").tag(AgentSchedule.ModelChoice.local)
                    Text("OpenRouter").tag(AgentSchedule.ModelChoice.cloud)
                }
                Text("When one of these uses OpenRouter, your persona, memories and what it reads are sent to it.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var edit = ScheduleEdit()
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedTitle.isEmpty, trimmedTitle != schedule.title { edit.title = trimmedTitle }
                    if !trimmedPrompt.isEmpty, trimmedPrompt != schedule.prompt { edit.prompt = trimmedPrompt }
                    if model != schedule.model { edit.model = model }
                    save(edit)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420)
        .padding(DS.Space.m)
    }
}
