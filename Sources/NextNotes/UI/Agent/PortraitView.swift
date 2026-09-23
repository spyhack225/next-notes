import SwiftUI

/// Portrait and Corners: what the assistant's picture of this person's week looks like (P2-1,
/// P2-2).
///
/// Two sections, one pass behind them. **Corners** group the life graph into cards — work,
/// people, home, wellbeing, learning, goals — each carrying the one freshest fact in it; it
/// needs no model and never writes. **Insights** are the Portrait pass's prose sentences:
/// each arrives as a draft, is read here, and is only stored when the person keeps it —
/// which is why the kept list and the waiting list are two sections, and why every row on
/// either carries its own delete. A sentence the person cannot remove is not a portrait, it
/// is a file they were given.
struct PortraitView: View {
    @State private var store = PortraitInsightStore.shared
    @State private var service = PortraitService.shared
    @State private var status: String?

    var body: some View {
        AgentPaneScroll {
            AgentPaneHeader(
                title: "Portrait",
                subtitle: "What your assistant notices, in its own words. Nothing is kept "
                    + "until you say so, and you can cross out any line."
            )
            cornersSection
            insightsSection
            if let status {
                Text(status)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .onAppear {
            store.reload()
            look()
        }
    }

    // MARK: - Corners

    @ViewBuilder
    private var cornersSection: some View {
        let corners = LifeCorners.corners(graph: KnowledgeIndexer.shared.graph)
        if corners.isEmpty {
            AgentPaneSection(title: "Corners") {
                Text("Nothing yet — the picture builds as meetings and notes are read.")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            AgentPaneSection(title: "Corners", count: corners.count) {
                AgentCardGrid {
                    ForEach(corners) { corner in
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(corner.area.name).font(DS.Font.headline)
                            Text("\(corner.count)").font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                                .monospacedDigit()
                            if let latest = corner.latest {
                                Text("Latest: \(latest)")
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .agentCardSurface()
                    }
                }
            }
        }
    }

    // MARK: - Insights

    @ViewBuilder
    private var insightsSection: some View {
        if store.drafts.isEmpty && store.saved.isEmpty {
            OrbUnavailableView(
                .breathing,
                title: "Nothing written yet",
                message: "Once the picture has something to say, it will show up here first — "
                    + "and only stay if you keep it."
            )
        } else {
            if !store.drafts.isEmpty {
                AgentPaneSection(title: "Waiting for you", count: store.drafts.count) {
                    AgentCardGrid {
                        ForEach(store.drafts) { draft in
                            draftCard(draft)
                        }
                    }
                }
            }
            if !store.saved.isEmpty {
                AgentPaneSection(title: "Kept", count: store.saved.count) {
                    AgentCardGrid {
                        ForEach(store.saved) { insight in
                            keptCard(insight)
                        }
                    }
                }
            }
        }
    }

    private func draftCard(_ draft: PortraitInsight.Draft) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(draft.text)
                .font(DS.Font.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                Button("Keep this") { service.store.keep(draft) }
                Button("Not now", role: .destructive) { service.store.discard(draft.id) }
                    .buttonStyle(.borderless)
            }
            .font(DS.Font.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentCardSurface()
    }

    private func keptCard(_ insight: PortraitInsight) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(insight.text)
                .font(DS.Font.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                Text(insight.createdAt, format: .dateTime.day().month(.abbreviated))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: 0)
                Button("Cross out", role: .destructive) { service.store.delete(insight.id) }
                    .buttonStyle(.borderless)
            }
            .font(DS.Font.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentCardSurface()
    }

    /// The pass runs when the pane is opened, on its own week-long cadence — never while a
    /// meeting or dictation is recording (the router handles that), and never writing
    /// anything by itself.
    private func look() {
        Task { @MainActor in
            let outcome = await service.runIfDue()
            switch outcome.result {
            case .drafted(let count):
                status = count == 1 ? "Wrote one sentence to look over."
                    : "Wrote \(count) sentences to look over."
            case .nothing:
                status = "Looked, and nothing new stood out."
            case .waited(let reason):
                status = "Not looking yet: \(reason)."
            case .failed(let reason):
                status = "The last look could not finish: \(reason)"
            }
        }
    }
}
