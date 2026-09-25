import Foundation
import SwiftUI

/// Settings ▸ Models ▸ "How your models have been doing" (P0-20d): the last seven days
/// of what ran, in plain words, with a clear button behind a confirmation.
///
/// The words a person reads live in the constants and the three line-building functions
/// below, and `visibleStrings(for:)` returns exactly that copy so `--selftest-usage-log`
/// can check it without a window. Nothing here names a feature id, a schema key or a
/// developer word: the group titles are the whole mapping, and a feature value a newer
/// build invents still lands in the group its prefix belongs to rather than being shown
/// raw.
struct UsageSection: View {
    /// The window the section reports on.
    static let windowDays = 7

    @State private var rows: [UsageSummary.Row]?
    @State private var isConfirmingClear = false

    var body: some View {
        Section {
            if let rows {
                if rows.isEmpty {
                    Text(Self.emptyStateSentence)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                } else {
                    ForEach(Self.groups(for: rows)) { group in
                        groupView(group)
                    }
                    HStack {
                        Spacer()
                        Button(Self.clearTitle, role: .destructive) {
                            isConfirmingClear = true
                        }
                        .confirmationDialog(
                            Self.clearConfirmationTitle,
                            isPresented: $isConfirmingClear
                        ) {
                            Button(Self.clearTitle, role: .destructive, action: clear)
                        } message: {
                            Text(Self.clearConfirmationMessage)
                        }
                    }
                }
            } else {
                Text(Self.loadingSentence)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        } header: {
            Text(Self.sectionTitle)
        } footer: {
            SettingsNote(text: Self.footer)
        }
        .task { await load() }
    }

    // MARK: - Loading and clearing

    private func load() async {
        let since = Date().addingTimeInterval(-Double(Self.windowDays) * 86_400)
        let loaded = await Task.detached(priority: .utility) {
            UsageLog.shared.load(since: since)
        }.value
        rows = UsageSummary.compute(rows: loaded, since: since)
    }

    private func clear() {
        Task {
            await Task.detached(priority: .utility) {
                UsageLog.shared.clear()
                UsageLog.shared.flush()
            }.value
            rows = []
        }
    }

    // MARK: - Drawing

    @ViewBuilder
    private func groupView(_ group: ModelGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(group.title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            ForEach(group.lines) { line in
                Text(Self.lineText(for: line))
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DS.Space.xxs)
    }

    // MARK: - The copy

    /// Every string a person reads in this section, so `--selftest-usage-log` can check
    /// the copy without a window. An empty summary is the "nothing yet" state; neither
    /// list may say a developer word, a raw feature id or a schema key.
    nonisolated static func visibleStrings(for rows: [UsageSummary.Row]) -> [String] {
        let standingCopy = [sectionTitle, loadingSentence, footer]
        guard !rows.isEmpty else { return standingCopy + [emptyStateSentence] }
        let groupCopy = groups(for: rows).flatMap { group in
            [group.title] + group.lines.map { lineText(for: $0) }
        }
        return standingCopy + groupCopy + [clearTitle, clearConfirmationTitle,
                                           clearConfirmationMessage]
    }

    // MARK: - Grouping

    /// Which group a feature belongs to. The three the tab shows, plus a catch-all so a
    /// feature value a newer build added is never printed raw and never silently dropped.
    enum GroupKind: CaseIterable, Sendable {
        case agent, meetings, dictation, other

        var title: String {
            switch self {
            case .agent: "Agent"
            case .meetings: "Meetings"
            case .dictation: "Dictation"
            case .other: "Other work"
            }
        }

        static func of(_ feature: String) -> GroupKind {
            if let known = known[feature] { return known }
            if feature.hasPrefix("agent.") || feature.hasPrefix("memory.")
                || feature.hasPrefix("knowledge.") {
                return .agent
            }
            if feature.hasPrefix("meeting.") { return .meetings }
            if feature.hasPrefix("dictation.") { return .dictation }
            return .other
        }

        /// Known raw values, mapped explicitly. A value this build does not know falls to
        /// the prefix rules above, so adding a feature to a namespace needs no change here.
        private static let known: [String: GroupKind] = [
            UsageFeature.agentTyped.rawValue: .agent,
            UsageFeature.agentVoice.rawValue: .agent,
            UsageFeature.agentWorker.rawValue: .agent,
            UsageFeature.agentRoutine.rawValue: .agent,
            UsageFeature.agentHandoff.rawValue: .agent,
            UsageFeature.memoryReview.rawValue: .agent,
            UsageFeature.knowledgeAsk.rawValue: .agent,
            UsageFeature.meetingTranscribe.rawValue: .meetings,
            UsageFeature.meetingDiarize.rawValue: .meetings,
            UsageFeature.meetingNotesSingle.rawValue: .meetings,
            UsageFeature.meetingNotesMap.rawValue: .meetings,
            UsageFeature.meetingNotesReduce.rawValue: .meetings,
            UsageFeature.meetingProposals.rawValue: .meetings,
            UsageFeature.meetingLive.rawValue: .meetings,
            UsageFeature.meetingNeedle.rawValue: .meetings,
            UsageFeature.dictationASR.rawValue: .dictation,
            UsageFeature.dictationCleanup.rawValue: .dictation,
        ]
    }

    /// One model's line in a group, merged across the passes it ran.
    struct ModelLine: Identifiable, Sendable {
        var id: String { modelID }
        var modelID: String
        var n: Int
        var ttftP50: Int?
        var totalP50: Int
        var failures: Int
    }

    struct ModelGroup: Identifiable, Sendable {
        var id: String { title }
        var title: String
        var lines: [ModelLine]
    }

    /// The rows grouped for display, in the fixed order Agent, Meetings, Dictation, Other.
    nonisolated static func groups(for rows: [UsageSummary.Row]) -> [ModelGroup] {
        GroupKind.allCases.compactMap { kind in
            let kindRows = rows.filter { GroupKind.of($0.feature) == kind }
            guard !kindRows.isEmpty else { return nil }
            return ModelGroup(title: kind.title, lines: modelLines(for: kindRows))
        }
    }

    /// One line per model: the passes are merged, the count and the failure count summed,
    /// and the "typical" times taken from the pass that ran most often.
    private nonisolated static func modelLines(for rows: [UsageSummary.Row]) -> [ModelLine] {
        var byModel: [String: [UsageSummary.Row]] = [:]
        for row in rows { byModel[row.modelID, default: []].append(row) }
        return byModel.map { modelID, modelRows in
            let busiest = modelRows.max { lhs, rhs in
                (lhs.n, lhs.totalP50) < (rhs.n, rhs.totalP50)
            }
            return ModelLine(
                modelID: modelID,
                n: modelRows.reduce(0) { $0 + $1.n },
                ttftP50: busiest?.ttftP50,
                totalP50: busiest?.totalP50 ?? 0,
                failures: modelRows.reduce(0) { $0 + Int(($1.errorRate * Double($1.n)).rounded()) }
            )
        }
        .sorted { lhs, rhs in
            lhs.n != rhs.n
                ? lhs.n > rhs.n
                : lhs.modelID.localizedStandardCompare(rhs.modelID) == .orderedAscending
        }
    }

    /// One model's sentence: how often it ran, how long the first words took, how long it
    /// finished in, and — only when there was one — how often it did not work.
    nonisolated static func lineText(for line: ModelLine) -> String {
        var parts = ["\(line.modelID) · ran \(line.n) \(line.n == 1 ? "time" : "times")"]
        if let ttftP50 = line.ttftP50 {
            parts.append("first words after \(secondsText(ttftP50))")
        }
        parts.append("finished in \(secondsText(line.totalP50))")
        if line.failures > 0 {
            parts.append("didn't work \(line.failures) of \(line.n) "
                + "\(line.n == 1 ? "time" : "times")")
        }
        return parts.joined(separator: " · ")
    }

    private nonisolated static func secondsText(_ milliseconds: Int) -> String {
        String(format: "%.1f s", Double(milliseconds) / 1_000)
    }

    // MARK: - The words

    nonisolated static let sectionTitle = "How your models have been doing"
    nonisolated static let emptyStateSentence = "Nothing yet — this fills in as you use the app."
    nonisolated static let loadingSentence = "Reading what has run so far…"
    nonisolated static let clearTitle = "Clear this history"
    nonisolated static let clearConfirmationTitle = "Clear this history?"
    nonisolated static let clearConfirmationMessage = "This forgets what has run here so far. "
        + "Nothing else on this Mac changes."
    nonisolated static let footer = "Only this Mac keeps this list, and nothing here leaves it. "
        + "Times are typical for each model."
}
