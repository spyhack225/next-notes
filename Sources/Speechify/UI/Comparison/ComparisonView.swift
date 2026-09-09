import SwiftUI

/// The Comparison section: one recording, every engine, side by side.
///
/// This used to be its own window, and before that a generated HTML file opened in the
/// browser. Both had the same problem — a second place to look, holding data that may or
/// may not be current. As a sidebar section it is one destination, always live.
struct ComparisonView: View {
    @Bindable var controller: DictationController
    @State private var store = RunStore.shared
    @State private var settings = Settings.shared
    @State private var isConfirmingClear = false

    private var isRecording: Bool { controller.state.isActive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                recordBar

                if store.runs.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(store.comparisons.enumerated()), id: \.offset) { _, group in
                        ComparisonCard(runs: group)
                    }
                    ForEach(Array(store.singles.enumerated()), id: \.offset) { _, run in
                        SingleCard(run: run)
                    }
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(SidebarSection.comparison.title)
        .navigationSubtitle("\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // This section and the Dictation list read the same log, so clearing here
                // clears there too. Same wording and same confirmation as the Dictation
                // footer, because it is the same irreversible deletion.
                Button("Delete All", systemImage: "trash") {
                    isConfirmingClear = true
                }
                .disabled(store.runs.isEmpty)
                .help("Delete every recording, comparisons included")
            }
        }
        .confirmationDialog(
            "Delete all \(store.runs.count) recordings?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every recording in Dictation as well. It can't be undone.")
        }
        .onAppear { store.reload() }
    }

    /// One button that records every engine at once — no hotkeys, and the results appear in
    /// this same section, so there's nowhere to go afterwards to read them.
    private var recordBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button {
                if isRecording {
                    controller.stopButtonRecording()
                } else {
                    controller.startButtonRecording()
                }
            } label: {
                Label(
                    isRecording ? "Stop" : "Record all engines",
                    systemImage: isRecording ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? DS.Color.record : DS.Color.accent)
            .controlSize(.large)

            Text(statusLine)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    private var statusLine: String {
        if isRecording { return "Recording — click Stop when you're done talking." }
        if !controller.transcript.isEmpty { return controller.transcript }
        return WisprReader.isInstalled
            ? "Click Record, talk, click Stop. Apple, Parakeet and Wispr Flow all hear it."
            : "Click Record, talk, click Stop. Wispr Flow isn't installed, so it's Apple vs Parakeet."
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing recorded yet", systemImage: SidebarSection.comparison.systemImage)
        } description: {
            Text(settings.compareMode
                 ? "Hold \(settings.pushToTalkKey.displayName), say a sentence, let go. "
                   + "Both engines run on that one recording and appear here."
                 : "Turn on Compare mode in Settings to see both engines on one recording.")
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Cards

private struct ComparisonCard: View {
    let runs: [DictationRun]

    /// Fastest first. The engines are *measured* sequentially, so arrival order reflects
    /// which ran first, not which is quicker — sorting by measured time is what makes the
    /// winner readable at a glance.
    private var ranked: [DictationRun] {
        runs.sorted { $0.processSeconds < $1.processSeconds }
    }

    /// How much faster the winner was, once both are in.
    private var margin: String? {
        guard runs.count > 1,
              let best = ranked.first,
              let worst = ranked.last,
              best.processSeconds > 0
        else { return nil }
        let ratio = worst.processSeconds / best.processSeconds
        let delta = worst.processSeconds - best.processSeconds
        guard delta > 0.005 else { return "tied" }
        return String(format: "%@ %.1f× faster · %.2fs ahead", best.engine, ratio, delta)
    }

    /// Case and punctuation are normalized away: Apple auto-punctuates and Parakeet
    /// doesn't, and that's a formatting difference, not a recognition error.
    private var verdict: (text: String, color: Color) {
        if Set(runs.map(\.text)).count == 1 { return ("identical", DS.Color.success) }
        let normalized = Set(runs.map {
            $0.text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        })
        return normalized.count == 1
            ? ("same words", DS.Color.success)
            : ("words differ", DS.Color.warning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            if let margin {
                Label(
                    margin,
                    systemImage: margin == "tied" ? "equal.circle.fill" : "bolt.fill"
                )
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.success)
            } else if runs.count == 1 {
                HStack(spacing: DS.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text("running second engine…")
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            }

            Divider()

            ForEach(Array(ranked.enumerated()), id: \.offset) { index, run in
                EngineRow(run: run, isWinner: runs.count > 1 && index == 0)
            }
        }
        .padding(DS.Space.l)
        .background(DS.Color.groupedFill, in: .rect(cornerRadius: DS.Radius.card))
    }

    private var header: some View {
        HStack {
            if let first = runs.first {
                Text("\(first.date.formatted(date: .omitted, time: .standard)) · held \(first.audioSeconds, format: .number.precision(.fractionLength(1)))s")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer()
            StatusChip(text: verdict.text, color: verdict.color)

            // Deletes the whole group: every engine here transcribed one utterance, so
            // removing that utterance means removing all of its rows together.
            if let group = runs.first?.group {
                Button("Delete", systemImage: "trash") {
                    withAnimation(DS.Motion.standard) { RunLog.deleteGroup(group) }
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .foregroundStyle(DS.Color.textSecondary)
                .help("Delete this comparison")
            }
        }
    }
}

private struct EngineRow: View {
    let run: DictationRun
    let isWinner: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                StatusChip(
                    text: run.engine + (isWinner ? " · fastest" : ""),
                    color: isWinner ? DS.Color.success : DS.Color.accent
                )
                Spacer()
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(isWinner ? DS.Font.counter : DS.Font.counterSmall)
                    .foregroundStyle(isWinner ? DS.Color.success : DS.Color.text)
            }
            Text("\(run.realtimeFactor, format: .number.precision(.fractionLength(0)))× realtime · \(run.characters) chars")
            .font(DS.Font.caption2)
            .foregroundStyle(DS.Color.textSecondary)

            Text(run.text.isEmpty ? "(nothing recognized)" : run.text)
                .font(DS.Font.callout)
                .foregroundStyle(run.text.isEmpty ? DS.Color.textSecondary : DS.Color.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.Space.xs)
    }
}

private struct SingleCard: View {
    let run: DictationRun

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                StatusChip(text: run.engine)
                Spacer()
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(DS.Font.timestamp)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Text(run.text)
                .font(DS.Font.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.m)
        .background(DS.Color.groupedFill, in: .rect(cornerRadius: DS.Radius.card))
    }
}
