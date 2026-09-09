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
        List {
            ForEach(runs) { run in
                TranscriptionRow(run: run)
                    .contextMenu {
                        Button("Copy") { run.text.copyToPasteboard() }
                        Button("Delete", role: .destructive) {
                            withAnimation(DS.Motion.standard) { RunLog.delete(run) }
                        }
                    }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        // A new transcription arrives at the moment the key is released, which is the one
        // moment the user is watching this list. It should slide in rather than appear.
        .animation(DS.Motion.fluid, value: runs.map(\.id))
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
            Text("\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            Spacer()
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
