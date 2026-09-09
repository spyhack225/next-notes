import SwiftUI

/// The Dictation section: record, watch the level, read what came out.
///
/// The meter and counter stay above the list rather than inside the toolbar because the
/// meter is the one instrument in the app that has to be readable at a glance from across
/// the desk, and toolbar items are sized for icons.
struct DictationView: View {
    @Bindable var controller: DictationController

    @State private var store = RunStore.shared
    @State private var settings = Settings.shared
    @State private var query = ""
    @State private var isConfirmingClear = false
    /// Which rows are selected, by run id. Native `List` selection rather than a bespoke
    /// edit mode, so click, shift-click, command-click, arrow keys and command-A all behave
    /// the way they do everywhere else on the system without this view implementing any of
    /// them.
    @State private var selection: Set<UUID> = []
    /// Set while a multi-row delete waits for confirmation. Holds the ids rather than
    /// reading `selection` when the dialog fires, so a selection change behind the sheet
    /// cannot redirect the delete at something the user never saw.
    @State private var pendingDeletion: Set<UUID> = []
    @State private var isConfirmingSelection = false
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.state.isActive }

    private var runs: [DictationRun] {
        let all = store.newestFirst
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !controller.hotkeyReady {
                AccessibilityNotice(controller: controller)
                Divider()
            }

            if runs.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcriptionList
            }

            Divider()
            footer
        }
        .navigationTitle(SidebarSection.dictation.title)
        .searchable(text: $query, prompt: Text("Search transcriptions"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                recordButton
            }
        }
        .onChange(of: controller.state.isActive) { _, _ in syncCounter() }
        // The key works from every section, so this view can be built while a recording is
        // already running — in which case the transition that starts the counter happened
        // before the view existed.
        .onAppear { syncCounter() }
        // Rows can leave under the selection — "Delete All", or a delete from the context
        // menu of a row that was not itself selected. A selection holding ids that no longer
        // exist would report a count the list cannot show.
        .onChange(of: store.runs.count) { _, _ in
            selection = DictationSelectionPolicy.pruned(selection, existing: store.runs)
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Matches the counter to the controller, seeding it from the hold's real start so a
    /// recording already in flight continues rather than restarting at zero.
    private func syncCounter() {
        guard controller.state.isActive else {
            startedAt = nil
            elapsed = 0
            return
        }
        if startedAt == nil {
            let start = controller.holdStarted ?? Date()
            startedAt = start
            elapsed = Date().timeIntervalSince(start)
        }
    }

    // MARK: - Pieces

    private var recordButton: some View {
        Button {
            if isRecording {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        } label: {
            Label(
                isRecording ? "Stop" : "Record",
                systemImage: isRecording ? "stop.fill" : "record.circle"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? DS.Color.record : DS.Color.accent)
        .help(isRecording ? "Stop recording" : "Record without holding the key")
    }

    private var transcriptionList: some View {
        List(selection: $selection) {
            ForEach(runs) { run in
                TranscriptionRow(run: run)
                    .tag(run.id)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        // `forSelectionType` rather than a per-row menu: right-clicking a row that is not in
        // the selection has to act on that row alone, and right-clicking one that is has to
        // act on the whole selection. That rule is the system's, and this hands it over
        // instead of re-deriving it.
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.isEmpty {
                Button("Delete All…") { isConfirmingClear = true }
            } else {
                Button(ids.count == 1 ? "Copy" : "Copy \(ids.count) Transcriptions") {
                    copy(ids)
                }
                Button(
                    ids.count == 1 ? "Delete" : "Delete \(ids.count) Transcriptions…",
                    role: .destructive
                ) { requestDelete(ids) }
            }
        }
        // The Delete key is what a list of things is expected to answer to.
        .onDeleteCommand { requestDelete(selection) }
        // A new transcription arrives at the moment the key is released, which is the one
        // moment the user is watching this list. It should slide in rather than appear.
        .animation(DS.Motion.fluid, value: runs.map(\.id))
    }

    // MARK: - Selection

    private func copy(_ ids: Set<UUID>) {
        let text = DictationSelectionPolicy.copyText(for: ids, from: runs)
        guard !text.isEmpty else { return }
        text.copyToPasteboard()
    }

    /// One row goes immediately; several ask first.
    ///
    /// The asymmetry is deliberate and matches "Delete All…" below: a single row is trivially
    /// re-recorded, so a dialog on every delete is friction with no payoff, while losing a
    /// dozen at once is not recoverable — there is no undo behind any of this.
    private func requestDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if !DictationSelectionPolicy.needsConfirmation(ids) {
            performDelete(ids)
        } else {
            pendingDeletion = ids
            isConfirmingSelection = true
        }
    }

    private func performDelete(_ ids: Set<UUID>) {
        withAnimation(DS.Motion.standard) { RunLog.delete(ids: ids) }
        selection.subtract(ids)
        pendingDeletion = []
    }

    private var footerCount: String {
        if selection.isEmpty {
            return "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")"
        }
        return "\(selection.count) of \(store.runs.count) selected"
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.runs.isEmpty {
            ContentUnavailableView(
                "No recordings",
                systemImage: SidebarSection.dictation.systemImage,
                description: Text("Hold \(settings.pushToTalkKey.displayName), or press Record.")
            )
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private var footer: some View {
        HStack {
            // The count becomes the selection's while there is one. Two counts side by side
            // is the thing to avoid: the number that matters is the number about to be
            // deleted, and it should be in the place the eye already goes.
            Text(footerCount)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            Spacer()
            if !selection.isEmpty {
                Button("Deselect") { selection = [] }
                    .buttonStyle(.link)
                Button(
                    selection.count == 1 ? "Delete" : "Delete \(selection.count)…",
                    role: .destructive
                ) { requestDelete(selection) }
                    .buttonStyle(.link)
            }
            Button("Delete All…") { isConfirmingClear = true }
                .buttonStyle(.link)
                .disabled(store.runs.isEmpty)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        // Confirmed, unlike a single row: one row is trivially re-recorded, the whole
        // history is not, and there's no undo.
        .confirmationDialog(
            "Delete all \(store.runs.count) recordings?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Delete \(pendingDeletion.count) recordings?",
            isPresented: $isConfirmingSelection,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performDelete(pendingDeletion) }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("This can't be undone.")
        }
    }
}

/// Shown when the event tap isn't armed. Accessibility can read as granted in System
/// Settings while a re-signed binary is no longer trusted, so this offers the retry too.
private struct AccessibilityNotice: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "keyboard.badge.ellipsis")
                .foregroundStyle(DS.Color.warning)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Push-to-talk is not armed")
                    .font(DS.Font.headline)
                Text("Grant Accessibility to this build. The Record button still works.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer()
            Button("Open Accessibility…") {
                Permissions.promptForAccessibility()
                Permissions.openAccessibilitySettings()
            }
            Button("Retry") { controller.reloadHotkey() }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(DS.Color.groupedFill)
    }
}

/// The rules the dictation list's selection follows.
///
/// Lifted out of the view so they can be asserted headlessly. Speechify cannot be driven by
/// UI automation on this machine, so "clicking two rows and pressing delete removes exactly
/// those two" is not something a test can perform — but every rule that decision rests on is
/// a pure function, and those are checked by `--selftest-dictation`.
enum DictationSelectionPolicy {
    /// One row goes immediately; several ask first.
    ///
    /// A single row is trivially re-recorded, so a dialog on every delete is friction with no
    /// payoff. Losing a dozen at once is not recoverable — there is no undo behind any of
    /// this — so that one asks.
    static func needsConfirmation(_ ids: Set<UUID>) -> Bool { ids.count > 1 }

    /// Newest first, in the order the list is showing, not the order the set iterates in.
    /// A `Set<UUID>` has no order at all, so copying straight from it would paste the rows
    /// shuffled.
    static func copyText(for ids: Set<UUID>, from runs: [DictationRun]) -> String {
        runs.filter { ids.contains($0.id) }
            .map(\.text)
            .joined(separator: "\n\n")
    }

    /// Drops ids that no longer exist. Rows can leave under the selection — "Delete All", or
    /// a delete from the context menu of a row that was not itself selected — and a selection
    /// holding vanished ids would report a count the list cannot show.
    static func pruned(_ selection: Set<UUID>, existing: [DictationRun]) -> Set<UUID> {
        selection.intersection(Set(existing.map(\.id)))
    }
}
