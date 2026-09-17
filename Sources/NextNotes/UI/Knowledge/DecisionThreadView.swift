import SwiftUI

/// Decisions: one decision followed across meetings, including the day it was reversed.
///
/// The bi-temporal model made visible. Each thread is one subject, oldest decision first;
/// a decision a later one superseded is struck through with the date it stopped being true,
/// and every row carries its meeting, when it was made and who made it. A row opens the
/// meeting it came from.
///
/// Extracted items are shown as proposals, in the visual language the Agent uses for its
/// own: a 4B model can invent a decision nobody made, and every row can be traced to the
/// passage that caused it. Above the threads, action items the user owns with a due date are
/// offered as reminders — offered, never created; *Remind me* asks the Agent, whose
/// confirmation card is the one every reminder goes through.
struct DecisionThreadView: View {
    @State private var settings = Settings.shared
    @State private var indexer = KnowledgeIndexer.shared
    @State private var extraction = KnowledgeExtractionService.shared
    @State private var suggestionsStore = ReminderSuggestionStore.shared
    @State private var navigation = NavigationState.shared

    @State private var threads: [DecisionThread] = []
    @State private var reminders: [ActionItemReminderSuggestion] = []
    @State private var problem: String?

    var body: some View {
        Group {
            if !settings.knowledgeGraphEnabled {
                OrbUnavailableView(
                    .connecting,
                    title: "Decisions are off",
                    message: "Turn on extraction to follow each decision across meetings — including the day it "
                        + "was reversed — from your notes, on this Mac."
                ) {
                    Button("Extract decisions and action items") { settings.knowledgeGraphEnabled = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if threads.isEmpty && reminders.isEmpty {
                OrbUnavailableView(
                    .connecting,
                    title: "No decisions yet",
                    message: "Decisions and action items are extracted after a meeting's notes are written, "
                        + "and never while something is recording."
                ) {
                    backfillControl
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                        backfillControl
                        if !reminders.isEmpty { reminderSection }
                        ForEach(threads) { thread in threadCard(thread) }
                        if let problem {
                            Text(problem)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.warning)
                        }
                    }
                    .padding(DS.Space.page)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: reloadKey) { await reload() }
    }

    // MARK: - Past meetings

    @ViewBuilder private var backfillControl: some View {
        if let progress = extraction.backfillProgress {
            HStack(spacing: DS.Space.s) {
                Text("Extracting past meetings: \(progress.done) of \(progress.total)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Button("Stop") { extraction.cancelBackfill() }
            }
        } else {
            Button("Extract past meetings") { extraction.extractLibrary() }
                .help("Reads every finished meeting's notes with the on-device model. Minutes per meeting.")
        }
    }

    // MARK: - Reminders

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Action items with a date").font(DS.Font.sectionLabel)
            ForEach(reminders) { suggestion in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(suggestion.text)
                        .font(DS.Font.callout)
                    Text("Due \(suggestion.due) · \(suggestion.meetingTitle)")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                    HStack(spacing: DS.Space.s) {
                        Button("Remind me") {
                            suggestionsStore.resolve(suggestion.id)
                            // Straight to the confirmation card, with structured fields: the
                            // item's text is not the user's words and never reaches a planner.
                            let arguments = suggestion.reminderArguments
                            Task {
                                do {
                                    _ = try await AgentToolExecutor.run(
                                        "schedule.create", arguments: arguments, policy: .fromSettings(),
                                        promptIfNeeded: true, authority: .user)
                                } catch {
                                    Log.agent.error("reminder suggestion not created: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Dismiss") { suggestionsStore.resolve(suggestion.id) }
                        Button("Open meeting") { open(suggestion.meetingID) }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(DS.Space.cardTight)
                .frame(maxWidth: DS.Size.agentEventMaxWidth, alignment: .leading)
                .glassSurface(cornerRadius: DS.Radius.card)
            }
        }
    }

    // MARK: - Threads

    private func threadCard(_ thread: DecisionThread) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(thread.subject.isEmpty ? "Decision" : thread.subject)
                    .font(DS.Font.headline)
                if thread.wasReversed {
                    StatusChip(text: "Changed", systemImage: "arrow.uturn.backward")
                }
                Spacer()
                Text("Proposed from notes")
                    .font(DS.Font.chip)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            ForEach(thread.rows) { row in
                Button { open(row.meetingID) } label: { decisionRow(row) }
                    .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    private func decisionRow(_ row: DecisionThreadRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(row.text)
                .font(DS.Font.body)
                .strikethrough(!row.isCurrent)
                .foregroundStyle(row.isCurrent ? DS.Color.text : DS.Color.textTertiary)
            HStack(spacing: DS.Space.s) {
                Text(row.meetingTitle)
                    .lineLimit(1)
                Text(row.observedAt.formatted(date: .abbreviated, time: .shortened))
                if let saidBy = row.saidBy {
                    Text(saidBy)
                }
                if let validTo = row.validTo {
                    Text("Superseded \(validTo.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(DS.Color.warning)
                }
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
    }

    private func open(_ meetingID: String) {
        guard let id = UUID(uuidString: meetingID) else { return }
        navigation.show(meeting: id)
    }

    // MARK: - Loading

    private struct ReloadKey: Equatable {
        let enabled: Bool
        let revision: Int
        let extractions: Int
        let resolved: Int
    }

    private var reloadKey: ReloadKey {
        ReloadKey(enabled: settings.knowledgeGraphEnabled && settings.knowledgeIndexEnabled,
                  revision: indexer.revision, extractions: extraction.revision,
                  resolved: suggestionsStore.resolved.count)
    }

    private func reload() async {
        guard let graph = indexer.graph else {
            threads = []
            reminders = []
            return
        }
        let resolved = suggestionsStore.resolved
        let names = ActionItemReminders.localUserNames
        let result = await Task.detached(priority: .userInitiated) {
            Result { (try graph.decisionThreads(), try graph.actionItems()) }
        }.value
        switch result {
        case .success(let (found, items)):
            threads = found
            reminders = ActionItemReminders.suggestions(items: items, userNames: names, resolved: resolved, now: Date())
            problem = nil
        case .failure(let error):
            problem = error.localizedDescription
        }
    }
}
