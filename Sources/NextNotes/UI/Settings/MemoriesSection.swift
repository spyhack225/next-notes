import SwiftUI

/// Settings → Agent: memory policy. The list itself is edited under Agent → About → MEMORY.
struct MemoriesSection: View {
    @State private var settings = Settings.shared
    @State private var memory = NextMemory.shared

    var body: some View {
        Group {
            policy
            DataControlsSection()
        }
    }

    private var policy: some View {
        Section {
            Toggle("Remember what I tell the Agent", isOn: $settings.agentMemoryEnabled)

            Picker("Review conversations with", selection: $settings.agentMemoryReviewModel) {
                ForEach(MemoryReviewModelChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
            }
            .disabled(!settings.agentMemoryEnabled)
            SettingsNote(text: (MemoryReviewModelChoice(rawValue: settings.agentMemoryReviewModel) ?? .auto).summary
                         + " It never runs while a meeting or dictation is recording.")

            Stepper("New conversation after \(settings.agentSessionIdleMinutes) minutes of silence",
                    value: $settings.agentSessionIdleMinutes, in: 5...240, step: 5)

            HStack(spacing: DS.Space.m) {
                ForEach(MemoryEntry.Kind.allCases, id: \.self) { kind in
                    meter(kind)
                }
            }

            Button("Edit memories in Agent → About") {
                NavigationState.shared.showAgentAbout()
            }

            MemoryLookAgainRow(isEnabled: settings.agentMemoryEnabled)
        } header: {
            Text("Memories")
        } footer: {
            SettingsNote(text: "The Agent saves facts you tell it about yourself and says out loud "
                         + "what it saved. Edit and Forget live under Agent → About → MEMORY. "
                         + "When OpenRouter is the Agent model, memories are sent with each request. "
                         + "Coding agents never receive them.")
        }
    }

    private func meter(_ kind: MemoryEntry.Kind) -> some View {
        let used = memory.used(kind)
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text("\(kind.displayName) \(used.formatted()) / \(kind.budget.formatted())")
                .font(DS.Font.caption)
                .foregroundStyle(used >= kind.budget * 9 / 10 ? DS.Color.warning : DS.Color.textSecondary)
            ProgressView(value: Double(min(used, kind.budget)), total: Double(kind.budget))
        }
    }
}

/// Full memory list — Forget, edit, badges. Hosted by Agent → About, whose own *Your data*
/// card carries importing and downloading; this sheet does not repeat them.
struct MemoriesEditor: View {
    /// The fact a graph dot asked to open, badged so it can be found in a long list.
    var focus: UUID? = nil

    @State private var settings = Settings.shared
    @State private var memory = NextMemory.shared
    @State private var reviewState = MemoryReviewStateStore.shared
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var newText = ""
    @State private var newKind: MemoryEntry.Kind = .profile
    @State private var error: String?
    @State private var confirmingForgetAll = false
    @State private var showActivity = false

    var body: some View {
        Section {
            Toggle("Remember what I tell the Agent", isOn: $settings.agentMemoryEnabled)

            HStack(spacing: DS.Space.m) {
                ForEach(MemoryEntry.Kind.allCases, id: \.self) { kind in
                    meter(kind)
                }
            }

            MemoryLookAgainRow(isEnabled: settings.agentMemoryEnabled)

            if memory.entries.isEmpty {
                // Why the list is empty, in the reviewer's own words. The sentence comes from
                // `MemoryReviewScheduler.emptyListLine` — never composed here, because the
                // view cannot know whether the review is waiting, running or done.
                Text(reviewStatusLine)
                    .foregroundStyle(DS.Color.textSecondary)
            } else {
                ForEach(MemoryEntry.Kind.allCases, id: \.self) { kind in
                    let rows = memory.entries(of: kind)
                    Text(kind.displayName)
                        .font(DS.Font.headline)
                    if rows.isEmpty {
                        Text("None yet")
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    ForEach(rows) { entry in
                        row(entry)
                    }
                }
            }

            HStack(spacing: DS.Space.s) {
                Picker("", selection: $newKind) {
                    ForEach(MemoryEntry.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Add a fact, e.g. “The user prefers short answers.”", text: $newText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }

            HStack {
                Spacer()
                Button("Forget everything", role: .destructive) { confirmingForgetAll = true }
                    .disabled(memory.entries.isEmpty && memory.items.isEmpty)
                    .confirmationDialog("Forget every memory, its history and the activity index?",
                                        isPresented: $confirmingForgetAll) {
                        Button("Forget everything", role: .destructive) {
                            perform { try memory.forgetEverything() }
                        }
                    }
            }

            DisclosureGroup("Names and labels from activity (\(memory.items.count))", isExpanded: $showActivity) {
                if memory.items.isEmpty {
                    Text("None yet")
                        .foregroundStyle(DS.Color.textSecondary)
                } else {
                    ForEach(memory.items.sorted(by: { $0.updatedAt > $1.updatedAt })) { item in
                        LabeledContent(item.value) {
                            Text(item.kind.rawValue)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                }
            }
        } header: {
            Text("MEMORY")
        } footer: {
            SettingsNote(text: "Facts the Agent keeps about you. It never saves anything from email, "
                         + "web pages, files or other tool results, and a memory never grants "
                         + "permission. Changes reach the Agent at its next conversation; Forget "
                         + "takes effect immediately.")
        }
    }

    /// The reviewer's sentence for an empty list, evaluated against the store this sheet
    /// observes so a backfill that advances while it is open redraws the line. The sentence
    /// itself is still the reviewer's to write.
    private var reviewStatusLine: String {
        _ = reviewState.backfill
        return MemoryReviewScheduler.shared.emptyListLine()
    }

    private func meter(_ kind: MemoryEntry.Kind) -> some View {
        let used = memory.used(kind)
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text("\(kind.displayName) \(used.formatted()) / \(kind.budget.formatted())")
                .font(DS.Font.caption)
                .foregroundStyle(used >= kind.budget * 9 / 10 ? DS.Color.warning : DS.Color.textSecondary)
            ProgressView(value: Double(min(used, kind.budget)), total: Double(kind.budget))
        }
    }

    @ViewBuilder
    private func row(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if editingID == entry.id {
                TextField("Memory", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save(entry) }
                HStack {
                    Button("Save") { save(entry) }
                    Button("Cancel") { editingID = nil }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(entry.text)
                        .textSelection(.enabled)
                    if memory.isNew(entry) {
                        Text("New")
                            .font(DS.Font.caption)
                            .padding(.horizontal, DS.Space.xs)
                            .background(DS.Color.accent.opacity(0.2), in: Capsule())
                    }
                    if entry.id == focus {
                        Text("From the graph")
                            .font(DS.Font.caption)
                            .padding(.horizontal, DS.Space.xs)
                            .background(DS.Color.accent.opacity(0.2), in: Capsule())
                    }
                    Spacer()
                    Button("Edit") {
                        draft = entry.text
                        editingID = entry.id
                    }
                    if entry.supersedes != nil {
                        Button("Undo change") { perform { try memory.undoSupersede(id: entry.id) } }
                    }
                    Button("Forget") { perform { try memory.forget(id: entry.id) } }
                }
                Text(detail(entry))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                if let reason = memory.flagged[entry.id] {
                    Text("Not used by the Agent: \(reason)")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                }
            }
        }
    }

    private func detail(_ entry: MemoryEntry) -> String {
        // An imported fact says where it came from and when, in one phrase, rather than
        // "Imported · 19 Sep 2026" in two — that is the sentence someone reads back later.
        if let label = entry.importLabel {
            var parts = [label]
            if entry.updatedAt > entry.createdAt { parts.append("edited") }
            return parts.joined(separator: " · ")
        }
        var parts = [entry.source.displayName, entry.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if entry.updatedAt > entry.createdAt { parts.append("edited") }
        if let session = entry.sessionID {
            parts.append("conversation \(session.uuidString.prefix(8).lowercased())")
        }
        return parts.joined(separator: " · ")
    }

    private func add() {
        let text = newText
        perform {
            try memory.remember(kind: newKind, text: text, source: .manual)
            newText = ""
        }
    }

    private func save(_ entry: MemoryEntry) {
        let text = draft
        perform {
            try memory.edit(id: entry.id, text: text)
            editingID = nil
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

}

/// *Look again at your past activity* — one button that re-reads the whole history.
///
/// It exists because the first backfill ran while the on-device model could not answer the
/// review at all: every source was read and nothing was saved, and the ticked-off list then
/// made that history permanently unreadable. `MemoryBackfill.startAgain` un-ticks it; this
/// row drives the passes and says what happened in the person's words. It stops the moment
/// a pass makes no progress — a recording started, the model is busy, the model failed —
/// and the scheduler's own minute tick carries on later, so nothing here retries in a loop.
struct MemoryLookAgainRow: View {
    let isEnabled: Bool

    @State private var backfill = MemoryBackfill.shared
    @State private var baseline: Int?
    @State private var savedCount: Int?
    @State private var isDriving = false

    private var state: MemoryBackfillState { backfill.state }
    private var isBusy: Bool { isDriving || backfill.isWorking || state.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button("Look again at your past activity", action: lookAgain)
                .disabled(!isEnabled || isBusy)

            if !isEnabled {
                Text("Turn on “Remember what I tell the Agent” first.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            } else if isBusy {
                HStack(spacing: DS.Space.s) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressLine)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            } else if let savedCount {
                Text(savedCount == 0
                     ? "Nothing new."
                     : "Saved \(savedCount) thing\(savedCount == 1 ? "" : "s") about you.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        // A pass that a recording interrupted finishes on the scheduler's own tick; the
        // result line follows the state rather than this view's task.
        .onChange(of: state.finishedAt) { _, finished in
            guard finished != nil, let baseline else { return }
            savedCount = max(0, state.savedEntryIDs.count - baseline)
        }
    }

    /// "Reading your past dictations and conversations… 12 of 198."
    private var progressLine: String {
        let total = state.total
        guard total > 0 else { return "Reading your past dictations and conversations…" }
        return "Reading your past dictations and conversations… \(min(state.done, total)) of \(total)."
    }

    private func lookAgain() {
        backfill.startAgain()
        baseline = state.savedEntryIDs.count
        savedCount = nil
        isDriving = true
        Task {
            // One pass at a time while it is making progress. A pass that waits or fails
            // advances nothing, and this stops rather than retrying — the minute tick owns
            // the long run, so a recording only pauses the work, it does not storm it.
            var lastDone = -1
            while !Task.isCancelled {
                let before = backfill.state.done
                _ = await backfill.run(passes: 1)
                let done = backfill.state.done
                if backfill.state.hasRun || done <= before || done <= lastDone { break }
                lastDone = done
            }
            isDriving = false
        }
    }
}
