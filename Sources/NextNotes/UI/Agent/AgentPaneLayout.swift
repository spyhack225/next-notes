import SwiftUI

/// The shared layout of every Agent pane (Ideas, Goals, Reminders, Activity, Skills,
/// About, Graph).
///
/// The panes each used to cap their content to a ~640pt column and centre it, so on a
/// wide window the content floated in the middle of empty space — the visible complaint
/// this file answers. The rule now, and the only one:
///
/// - a pane is a full-width scroll of sections (`AgentPaneScroll`),
/// - a header fills the width while its sentence stays readable (`AgentPaneHeader`),
/// - cards go in an adaptive grid that adds columns as the window grows (`AgentCardGrid`),
/// - list-plus-rail panes use `AgentSplit`, which stacks the rail when there is no room.
///
/// A pane must not re-introduce a centred column cap; the previous tokens
/// (`agentAboutMaxWidth` as a column, `agentSkillsMaxWidth`) are gone. Everything here
/// is a DS token — a view never states a number.
enum AgentPaneLayout {
    /// Outer padding for a pane's content. On top of this, sections space themselves
    /// with `DS.Space.xl` and cards with `DS.Space.card`.
    static let insets = EdgeInsets(
        top: DS.Space.page,
        leading: DS.Space.page,
        bottom: DS.Space.page,
        trailing: DS.Space.page
    )
}

/// The scrolling body every pane uses: full width, page padding, section spacing.
struct AgentPaneScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.xl) {
                content()
            }
            .padding(AgentPaneLayout.insets)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Title, one qualifying sentence, and an optional trailing control. The header fills
/// the width; the sentence is capped at `agentProseMaxWidth` so it stays readable.
struct AgentPaneHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Font.title2)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: DS.Size.agentProseMaxWidth, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AgentPaneHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

/// One titled section of a pane, with an optional count beside the label.
struct AgentPaneSection<Content: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(title)
                    .font(DS.Font.sectionLabel)
                if let count {
                    Text("\(count)")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card grid that adds columns as the window grows and drops them as it shrinks.
/// Use it instead of a row of fixed-width cards or a single-column stack.
struct AgentCardGrid<Content: View>: View {
    var minimum: CGFloat = DS.Size.agentCardMinWidth
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: minimum), spacing: DS.Space.card, alignment: .top)
            ],
            alignment: .leading,
            spacing: DS.Space.card
        ) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A list with a narrow rail. A wide pane puts the rail beside the list; a narrow one
/// stacks it under the list — the same content in the same reading order, no overflow.
///
/// `railLeading` puts the rail first (About's data card, a sidebar-style rail); the
/// default is rail-trailing (Activity's approvals beside its history).
struct AgentSplit<ListContent: View, RailContent: View>: View {
    var railLeading = false
    @ViewBuilder var list: () -> ListContent
    @ViewBuilder var rail: () -> RailContent

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DS.Space.card) {
                if railLeading { railColumn }
                list()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !railLeading { railColumn }
            }
            .frame(minWidth: DS.Size.agentWideMinWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Space.xl) {
                if railLeading { rail() }
                list()
                if !railLeading { rail() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var railColumn: some View {
        rail()
            .frame(width: DS.Size.agentRailWidth, alignment: .leading)
    }
}

extension View {
    /// The pane card surface: grouped fill, card radius, card padding. One surface, so a
    /// card in Goals and a card in Ideas read as the same material.
    func agentCardSurface() -> some View {
        padding(DS.Space.cardTight)
            .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
}
