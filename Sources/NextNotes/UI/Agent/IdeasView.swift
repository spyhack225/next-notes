import SwiftUI

/// Ideas: a static, curated gallery of things to try (G2).
///
/// Consumer words: Ideas, Goals, Reminders, Library, Activity. Never cron, artifact,
/// or tool ids. Tapping an idea opens the setup flow — it never executes anything.
/// `RoutineSuggestion.offer()` rendering is wired in later (see TODO below); this view
/// owns the gallery, not the suggestion engine.
struct IdeasView: View {
    struct Idea: Identifiable {
        let id = UUID()
        let category: String
        let title: String
        let example: String
    }

    /// Static curated gallery by Health / Relationships / Finance / Career / Interests /
    /// Productivity / Something else.
    static let gallery: [Idea] = [
        Idea(category: "Health", title: "Move a little every day",
             example: "Remind me every weekday at 9 to stand up"),
        Idea(category: "Health", title: "Wind down at night",
             example: "Every night at 10, remind me to put the book out"),
        Idea(category: "Relationships", title: "Stay in touch",
             example: "Every Friday at 5, remind me to call Sam"),
        Idea(category: "Finance", title: "Keep the bills calm",
             example: "On the last day of every month at 9, remind me to check the bills"),
        Idea(category: "Career", title: "Start Mondays ready",
             example: "Every Monday at 8, summarise last week’s meetings"),
        Idea(category: "Interests", title: "Keep the hobby alive",
             example: "Every Sunday at 4, remind me to practise for 20 minutes"),
        Idea(category: "Productivity", title: "Plan tomorrow tonight",
             example: "Every night at 9, remind me to plan tomorrow"),
        Idea(category: "Something else", title: "Something of your own",
             example: "Remind me tomorrow at 9 to …"),
    ]

    /// Hook for the suggestion engine. G2 leaves the wiring as a TODO: the Routines view
    /// keeps offering `RoutineSuggestion.offer()` text, and this view will render it here
    /// once the Agent pane hosts Ideas beside Reminders.
    /// TODO(G2): render `MemoryReviewStateStore.shared.openSuggestions` with Set it up /
    /// Dismiss, reusing the Routines view's actions. This gallery stays static; suggestions
    /// appear in a separate section above it and never execute on tap.
    var suggestions: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Ideas").font(DS.Font.title2)
                    Text("Things your assistant can do for you. Pick one and make it yours — "
                         + "nothing runs until you say yes.")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Suggested for you").font(DS.Font.sectionLabel)
                        ForEach(suggestions, id: \.self) { suggestion in
                            Text(suggestion).font(DS.Font.callout)
                                .padding(DS.Space.cardTight)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassSurface(cornerRadius: DS.Radius.card)
                        }
                    }
                }
                ForEach(Dictionary(grouping: Self.gallery, by: \.category).sorted(by: { $0.key < $1.key }),
                        id: \.key) { category, ideas in
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text(category).font(DS.Font.sectionLabel)
                        ForEach(ideas) { idea in
                            Button {
                                // Opens the setup flow; never executes.
                                NavigationState.shared.agentPane = .conversation
                                Task { await RealtimeAgent.shared.handleLive(idea.example, source: .text) }
                            } label: {
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(idea.title).font(DS.Font.headline)
                                    Text("“\(idea.example)”")
                                        .font(DS.Font.callout)
                                        .foregroundStyle(DS.Color.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(DS.Space.cardTight)
                            .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        }
                    }
                }
            }
            .padding(DS.Space.page)
            .frame(maxWidth: DS.Size.agentAboutMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }
}
