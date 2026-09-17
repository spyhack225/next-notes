import SwiftUI

/// Agent → Routines (Part 3).
///
/// Every schedule with its plain-English sentence, next run, last result and a switch; open
/// one for its run history — skipped slots and their reasons included — the drafts it left
/// awaiting approval, *Run now*, *Edit* and *Delete*. Routine suggestions from the memory
/// review sit at the top with *Set it up* and *Dismiss*, and every draft still awaiting
/// approval is listed above the schedules so none is buried in a closed row.
struct RoutinesView: View {
    @State private var store = ScheduleStore.shared
    @State private var review = MemoryReviewStateStore.shared
    @State private var settings = Settings.shared
    @State private var expanded: Set<UUID> = []
    @State private var editing: AgentSchedule?
    @State private var busy: Set<UUID> = []
    @State private var message: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                if !review.openSuggestions.isEmpty { suggestions }
                if !store.awaitingDrafts.isEmpty { drafts(store.awaitingDrafts, title: "Awaiting your approval") }
                schedulesSection
                launchAtLogin
                if let message {
                    Text(message)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                }
            }
            .padding(DS.Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.reload() }
        .sheet(item: $editing) { schedule in
            RoutineEditor(schedule: schedule) { edit in
                perform(schedule.id) { _ = try await AgentScheduler.shared.update(id: schedule.id, edit: edit, now: Date()) }
            }
        }
    }

    // MARK: - Sections

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Suggested").font(DS.Font.sectionLabel)
            ForEach(review.openSuggestions) { suggestion in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(suggestion.offer())
                        .font(DS.Font.callout)
                    HStack(spacing: DS.Space.s) {
                        Button("Set it up") {
                            review.resolveSuggestion(id: suggestion.id)
                            NavigationState.shared.agentPane = .conversation
                            let request = suggestion.request
                            Task { await RealtimeAgent.shared.handleLive("Set up a routine for this: \(request)", source: .text) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Dismiss") { review.resolveSuggestion(id: suggestion.id) }
                    }
                }
                .padding(DS.Space.cardTight)
                .frame(maxWidth: DS.Size.agentEventMaxWidth, alignment: .leading)
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
                Text(store.schedule(id: draft.scheduleID)?.title ?? "Routine")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer()
                Text(draft.createdAt, format: .dateTime.weekday().hour().minute())
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Text(draft.title).font(DS.Font.headline)
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
        .frame(maxWidth: DS.Size.agentEventMaxWidth, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    private var schedulesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Routines and reminders").font(DS.Font.sectionLabel)
            if store.schedules.isEmpty {
                OrbUnavailableView(
                    .breathing,
                    title: "Nothing scheduled",
                    message: "Ask the Agent, for example “every Monday at 8, summarise last week’s meetings.”"
                )
            }
            ForEach(store.schedules.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }) { schedule in
                scheduleRow(schedule)
            }
        }
    }

    private func scheduleRow(_ schedule: AgentSchedule) -> some View {
        let isOpen = expanded.contains(schedule.id)
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: schedule.kind == .routine ? "gearshape.2" : "bell")
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
        .frame(maxWidth: DS.Size.agentEventMaxWidth, alignment: .leading)
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
        if schedule.kind == .routine {
            Text("Allowed tools: \(schedule.allowedTools.isEmpty ? "none" : schedule.allowedTools.joined(separator: ", ")) · "
                 + "model: \(schedule.model.rawValue) · limit \(schedule.budget.maxSeconds / 60) min, \(schedule.budget.maxToolCalls) tool calls")
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

    private var launchAtLogin: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Toggle("Open Next Notes at login", isOn: $settings.agentLaunchAtLogin)
                .onChange(of: settings.agentLaunchAtLogin) { _, on in
                    message = LaunchAtLogin.apply(on)
                }
            Text("Routines run only while Next Notes is open. Reminders also reach you through macOS when it is closed.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    // MARK: - Helpers

    private func summary(_ schedule: AgentSchedule) -> String {
        var parts: [String] = []
        if !schedule.enabled {
            parts.append(schedule.isOneShot && schedule.nextRunAt == nil ? "Done" : "Off")
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
            TextField(schedule.kind == .routine ? "Instructions" : "Reminder", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
            if schedule.kind == .routine {
                Picker("Model", selection: $model) {
                    Text("Automatic").tag(AgentSchedule.ModelChoice.auto)
                    Text("Qwen on this Mac").tag(AgentSchedule.ModelChoice.local)
                    Text("OpenRouter").tag(AgentSchedule.ModelChoice.cloud)
                }
                Text("When a routine uses OpenRouter, your persona, memories and what the routine reads are sent to it.")
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
