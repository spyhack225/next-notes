import SwiftUI

/// Activity: what the assistant has been doing, across sessions (§8.2).
///
/// Two columns on a wide pane, stacked on a narrow one:
///
/// - the **history** — the persisted `agent-audit.jsonl`, day-grouped, newest first,
///   filtered by kind from its section header. Each row leads with the consumer title;
///   the machine's own detail is one disclosure away and never on the first line;
/// - the **rail** — a **heartbeat** saying what it is doing right now and how many things
///   are running, read live rather than off the log, because "nothing is running" is
///   information too, and the **approvals ledger** — everything the person has allowed,
///   as standing grants and approved cards, with human titles and scope names. A raw
///   tool id never appears here; a ledger a person cannot read is a ledger they cannot
///   audit.
struct ActivityView: View {
    @State private var audit = AgentAuditLog.shared
    @State private var tasks = AgentTaskManager.shared
    @State private var agent = RealtimeAgent.shared
    @State private var grants = PermissionGrantStore.shared

    @State private var persisted: [DayGroup] = []
    @State private var filter: KindFilter = .everything
    @State private var showsLedger = true

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [AgentAuditEntry]
        var id: Date { day }
    }

    private enum KindFilter: String, CaseIterable, Identifiable {
        case everything = "Everything"
        case work = "What it did"
        case approvals = "Approvals"
        case wake = "Wake word"
        var id: String { rawValue }

        func matches(_ kind: AgentAuditEntry.Kind) -> Bool {
            switch self {
            case .everything: true
            case .work: kind == .tool || kind == .task || kind == .request || kind == .reply
            case .approvals: kind == .permission
            case .wake: kind == .wake || kind == .wakeMiss || kind == .wakeFalse
            }
        }
    }

    var body: some View {
        AgentPaneScroll {
            AgentPaneHeader(
                title: "Activity",
                subtitle: "Everything your assistant has done, day by day — and everything you "
                    + "have allowed it to do again."
            )
            AgentSplit(list: { dayGroups }, rail: { rail })
        }
        .onAppear { reload() }
    }

    /// The rail beside the history: what is running now, and what the person has allowed.
    private var rail: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            heartbeat
            if !approvedHistory.isEmpty || !grants.grants.isEmpty { ledger }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Heartbeat

    private var heartbeat: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            ThinkingOrb(state: runningCount > 0 || agent.isThinking ? .searching : .breathing,
                        size: DS.Size.orbSmall)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Right now").font(DS.Font.sectionLabel)
                Text(heartbeatLine)
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if runningCount > 0 {
                    Text(runningCount == 1
                         ? "1 thing is running"
                         : "\(runningCount) things are running")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentCardSurface()
        .accessibilityElement(children: .combine)
    }

    private var heartbeatLine: String {
        if agent.isThinking {
            let title = agent.progressTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Thinking…" : title
        }
        return runningCount > 0 ? "Working in the background." : "Nothing is running."
    }

    /// Work that is still open: queued, running, or waiting on a person. A finished task is
    /// history and belongs to the day groups beside it.
    private var runningCount: Int {
        tasks.tasks.count {
            $0.status == .queued || $0.status == .running
                || $0.status == .waitingForPermission
                || $0.status == .waitingForCompatibilityCLI
                || $0.status == .waitingForInput
        }
    }

    // MARK: - Approvals ledger

    /// Approved cards from the audit log, newest first. Dismissed ones are refusals, not
    /// approvals, and the day groups already carry them.
    private var approvedHistory: [AgentAuditEntry] {
        audit.entries.filter { $0.kind == .permission && $0.detail != "Dismissed" }.prefix(20).map { $0 }
    }

    private var ledger: some View {
        DisclosureGroup(isExpanded: $showsLedger) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if !grants.grants.isEmpty {
                    Text("Always allowed").font(DS.Font.sectionLabel)
                    ForEach(grants.grants) { grant in
                        ledgerRow(
                            title: ToolCallReviewBuilder.humanTitle(forToolID: grant.toolID),
                            scope: grant.scope.displayName,
                            detail: grant.duration.displayName,
                            at: grant.createdAt
                        )
                    }
                }
                if !approvedHistory.isEmpty {
                    Text("Recently approved").font(DS.Font.sectionLabel)
                    ForEach(approvedHistory) { entry in
                        ledgerRow(
                            title: entry.title,
                            scope: "",
                            detail: entry.detail,
                            at: entry.at
                        )
                    }
                }
            }
            .padding(.top, DS.Space.s)
        } label: {
            HStack {
                Text("Everything you’ve allowed").font(DS.Font.sectionLabel)
                Spacer()
                Text("\(grants.grants.count + approvedHistory.count)")
                    .font(DS.Font.counterSmall)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    private func ledgerRow(title: String, scope: String, detail: String, at: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: "hand.raised")
                .foregroundStyle(DS.Color.textSecondary)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.callout)
                if !scope.isEmpty {
                    Text(scope)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                Text(detail)
                    .font(DS.Font.chip)
                    .foregroundStyle(DS.Color.textSecondary)
                Text(at, format: .dateTime.month(.abbreviated).day())
                    .font(DS.Font.timestamp)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentCardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(scope) \(detail)")
    }

    // MARK: - Day groups

    @ViewBuilder
    private var dayGroups: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("History").font(DS.Font.sectionLabel)
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(KindFilter.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
            }
            if filteredDays.isEmpty {
                OrbUnavailableView(
                    .breathing,
                    title: "Nothing here yet",
                    message: "What your assistant does — searches, approvals, wake words — "
                        + "shows up here, day by day."
                )
            }
            ForEach(filteredDays) { group in
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(dayTitle(group.day))
                        .font(DS.Font.sectionLabel)
                    ForEach(group.entries) { entry in
                        historyRow(entry)
                    }
                }
            }
        }
    }

    private var filteredDays: [DayGroup] {
        days.compactMap { group in
            let entries = group.entries.filter { filter.matches($0.kind) }
            return entries.isEmpty ? nil : DayGroup(day: group.day, entries: entries)
        }
    }

    /// The in-memory log plus the persisted file, de-duplicated by id. The in-memory copy
    /// is what makes the screen update while something is running; the file is what makes
    /// it a history rather than a session.
    private var days: [DayGroup] {
        var byID: [String: AgentAuditEntry] = [:]
        for entry in audit.entries { byID[entry.id] = entry }
        for group in persisted {
            for entry in group.entries { byID[entry.id] = entry }
        }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: byID.values) { calendar.startOfDay(for: $0.at) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(day: day, entries: (grouped[day] ?? []).sorted { $0.at > $1.at })
        }
    }

    private func reload() {
        persisted = AgentAuditLog.loadPersistedGroupedByDay().map {
            DayGroup(day: $0.day, entries: $0.entries)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func historyRow(_ entry: AgentAuditEntry) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: icon(for: entry.kind))
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Size.orbBadge * 0.4)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    // The consumer line first, always. Nothing here is a tool id or a
                    // status enum; those live one disclosure down.
                    Text(entry.title)
                        .font(DS.Font.callout)
                        .lineLimit(3)
                    Spacer(minLength: DS.Space.s)
                    Text(entry.at, format: .dateTime.hour().minute())
                        .font(DS.Font.timestamp)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                if !entry.detail.isEmpty, entry.detail != entry.title {
                    DisclosureGroup("Details") {
                        Text(entry.detail)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                            .textSelection(.enabled)
                    }
                    .font(DS.Font.chip)
                    .foregroundStyle(DS.Color.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentCardSurface()
        .accessibilityElement(children: .combine)
    }

    private func icon(for kind: AgentAuditEntry.Kind) -> String {
        switch kind {
        case .tool: "wrench.and.screwdriver"
        case .permission: "hand.raised"
        case .task: "checklist"
        case .wake, .wakeMiss, .wakeFalse: "waveform"
        case .request: "bubble.left"
        case .reply: "bubble.right"
        }
    }
}
