import SwiftUI

/// The four things a person can do over a meeting that is still running.
///
/// The order is the rail's order, and it is the order of the feature rather than of the
/// alphabet: what you write yourself, what the meeting asked for, what came before, and
/// the one you talk to. `allCases` *is* the rail — `MeetingConsoleSheet` draws one row per
/// case, so reordering this enum reorders the panel, and `MeetingConsoleSelfTest` pins the
/// order rather than letting it drift.
enum MeetingConsoleSection: String, CaseIterable, Identifiable, Sendable {
    case notes, actions, history, ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Notes"
        case .actions: "Actions"
        case .history: "History"
        case .ask: "Ask"
        }
    }

    /// From the set the app already draws, one per section's actual subject: the pencil
    /// you write with, a list of what was agreed, the way back in time, a conversation.
    var symbol: String {
        switch self {
        case .notes: "pencil"
        case .actions: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        case .ask: "message.fill"
        }
    }

    /// Plain words, one sentence, saying what the section *is* rather than what it is
    /// called. A rail row is a title, and a title is a bad place to find out.
    var help: String {
        switch self {
        case .notes: "Write your own notes while the meeting runs"
        case .actions: "What the app heard you agree to do"
        case .history: "Meetings before this one, by the same people or the same subject"
        case .ask: "Ask your assistant something about this meeting"
        }
    }
}

/// The one place the answer to "what is this surface doing right now" is written down.
///
/// It exists so the four sections cannot disagree about it and so `--selftest-…` can pin
/// the table. A section names the work it is doing and the sheet draws it; a section that
/// drew its own orb instead would be free to name work that is not happening, and the rule
/// the whole orb vocabulary rests on is that it may not.
///
/// Every case is a row of the table in `AGENTS.md`, not a choice made here: two tracks
/// braided into one meeting is `weaving`, the model writing prose is `composing`, and
/// reading things this app did not write — the action pass, a look back through past
/// meetings, a turn in flight — is `searching`.
///
/// `CaseIterable` is one conformance beyond the shape the sections were written against,
/// and it is here so `MeetingConsoleSelfTest` can walk the table from the type rather than
/// from a list it typed out beside it. A copy of the list is a list that goes out of date
/// silently: a fifth case would be skipped by the only test that would have noticed it.
enum MeetingConsoleActivity: Equatable, CaseIterable, Sendable {
    case idle
    case transcribing
    case writingNotes
    case findingActions
    case lookingBack
    case thinking

    /// `nil` for the one case that is not work. An orb says which long thing is
    /// happening; a panel that is sitting there is not doing one.
    var orb: OrbGeometry.State? {
        switch self {
        case .idle: nil
        case .transcribing: .weaving
        case .writingNotes: .composing
        case .findingActions: .searching
        case .lookingBack: .searching
        case .thinking: .searching
        }
    }

    var title: String {
        switch self {
        case .idle: "Nothing is running"
        case .transcribing: "Recording both sides of the meeting"
        case .writingNotes: "Writing the notes"
        case .findingActions: "Working out what this meeting needs"
        case .lookingBack: "Looking through earlier meetings"
        case .thinking: "Thinking about your question"
        }
    }

    var isBusy: Bool { self != .idle }
}

/// The panel itself: a rail of four destinations, the one that's showing, and one floating
/// primary action over the top of it.
///
/// `HSplitView` rather than `NavigationSplitView`, for the reason `MeetingsView` gives: a
/// `NavigationSplitView` wants a sidebar and a title bar and fights a sheet for both, and
/// this is four rows beside a column rather than a window's top-level navigation.
///
/// **It must never be shown during a self-test**, which is `MeetingConsolePolicy`'s whole
/// job — see there.
struct MeetingConsoleSheet: View {
    let session: MeetingSession

    /// A single-selection `List` binds to an optional, but the first section must also
    /// appear selected when the panel opens, not merely supply content behind an empty rail.
    @State private var selection: MeetingConsoleSection? = .notes
    /// An unfinished question survives a trip to Notes or History while this sheet stays up.
    @State private var askDraft = ""

    var body: some View {
        HSplitView {
            rail
                .frame(width: DS.Size.meetingConsoleRailWidth)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: DS.Size.meetingConsoleWidth)
        // A height floor and no width floor. The width above is the panel's own, and
        // asking for more than a host has is a demand SwiftUI declines by drawing past the
        // edge — `DS.Size.settingsPaneMinWidth` is the measured version of that story.
        // A long meeting scrolls instead of growing this.
        .frame(minHeight: DS.Size.meetingConsoleMinHeight)
    }

    private var section: MeetingConsoleSection { selection ?? .notes }

    // MARK: - Rail

    private var rail: some View {
        List(selection: $selection) {
            ForEach(MeetingConsoleSection.allCases) { item in
                Label(item.title, systemImage: item.symbol)
                    .font(DS.Font.callout)
                    .tag(item)
                    .help(item.help)
            }
        }
        .listStyle(.sidebar)
        // The stock sidebar style already draws the selected row on an accent-tinted
        // rounded rectangle, in whatever accent and appearance the person chose — which is
        // the whole reason it is a `List` and not four hand-drawn rectangles.
        .environment(\.defaultMinListRowHeight, DS.Size.meetingConsoleRowHeight)
    }

    // MARK: - The showing section

    /// The visible section, its activity, and its action, resolved in one place.
    ///
    /// A `@ViewBuilder` switch over four concrete types gives back an opaque type, and an
    /// opaque type cannot be asked for a third thing. Resolving to a value is smaller than
    /// the pair of switches that would be the alternative, and — unlike them — it cannot
    /// fall out of step with itself.
    private struct Resolved {
        let body: AnyView
        let activity: MeetingConsoleActivity
        let floatingAction: AnyView?
    }

    private var current: Resolved {
        switch section {
        case .notes:
            let view = MeetingConsoleNotesSection(session: session)
            return Resolved(
                body: AnyView(view),
                activity: view.activity,
                floatingAction: view.floatingAction
            )
        case .actions:
            let view = MeetingConsoleActionsSection(session: session)
            return Resolved(
                body: AnyView(view),
                activity: view.activity,
                floatingAction: view.floatingAction
            )
        case .history:
            let view = MeetingConsoleHistorySection(session: session)
            return Resolved(
                body: AnyView(view),
                activity: view.activity,
                floatingAction: view.floatingAction
            )
        case .ask:
            let view = MeetingConsoleAskSection(session: session, draft: $askDraft)
            return Resolved(
                body: AnyView(view),
                activity: view.activity,
                floatingAction: view.floatingAction
            )
        }
    }

    private var pane: some View {
        // Resolved once and threaded down. Reading the property at each of the three uses
        // would build the showing section three times per layout pass, and the sections
        // that replace these four are not placeholders.
        let shown = current
        return VStack(spacing: 0) {
            status(shown)
            if section == .ask {
                // Ask owns a scrolling thread and a fixed composer. Wrapping it in this
                // scroll view would push the field off screen after a few replies.
                shown.body
            } else {
                ScrollView {
                    shown.body
                        .padding(DS.Space.page)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The Notes pill overlays the scroll content. Other sections have
                        // no pill, so they need no empty space under their last row.
                        .padding(.bottom, shown.floatingAction == nil ? 0 : Self.actionClearance)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { floatingAction(shown) }
        // The same texture `MeetingLiveView` and `MeetingDetailView` carry, so the panel
        // reads as another room in this window rather than as a web page pasted into it.
        .dottedField(opacity: DS.Opacity.fieldFaint, fade: .top)
    }

    /// Pinned above the scrolling content rather than drawn inside it.
    ///
    /// The job this row reports on is minutes long, and a status line that scrolls off the
    /// top of a long transcript is the still screen the orb vocabulary exists to avoid.
    /// Nothing is drawn for `.idle`: a shape naming work which is not running is a claim
    /// the app cannot back up.
    @ViewBuilder
    private func status(_ shown: Resolved) -> some View {
        if let orb = shown.activity.orb {
            LabeledOrb(state: orb, title: shown.activity.title, size: DS.Size.orbSmall)
                .padding(.horizontal, DS.Space.page)
                .padding(.vertical, DS.Space.s)
        }
    }

    /// The one primary action, over the content rather than under it.
    ///
    /// The panel owns the slot and a section supplies the button into it, so four sections
    /// cannot end up with four different primary actions in four different corners. Glass
    /// rather than a material, because what is behind it is a dotted field and a pane
    /// with nothing behind it has nothing to refract.
    @ViewBuilder
    private func floatingAction(_ shown: Resolved) -> some View {
        if let action = shown.floatingAction {
            action
                .padding(.horizontal, DS.Space.card)
                .frame(minHeight: DS.Size.meetingConsolePillHeight)
                .glassSurface(cornerRadius: DS.Radius.consolePill)
                .padding(.bottom, DS.Space.xl)
        }
    }

    /// How far the last line of content has to clear the pill: the pill, the margin under
    /// it, and one more step of air so a final line is not sitting against it.
    private static let actionClearance =
        DS.Size.meetingConsolePillHeight + DS.Space.xl + DS.Space.l
}

/// The shared chrome every section draws inside: the section's own heading row, and nothing
/// else. A section must not re-implement a title bar.
///
/// **No orb.** The panel's one animating shape belongs to `MeetingConsoleActivity` and is
/// drawn by the sheet, so that the rule of one orb per screen is a property of this file
/// rather than something four sections each have to remember.
struct MeetingConsoleSectionHeader: View {
    let section: MeetingConsoleSection
    var subtitle: String?
    var accessory: AnyView?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.l) {
            SectionHeading(title: section.title, subtitle: subtitle)
                .lineLimit(2)
            Spacer(minLength: DS.Space.s)
            if let accessory {
                accessory
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Whether the meeting panel may be put on screen. Pure, so the rule is a thing the
/// self-test checks rather than a thing a comment claims.
///
/// The reason is the same one `OnboardingPolicy.shouldPresent` carries: a sheet keeps
/// `NSApp.terminate` from ever completing, so a self-test that raised one would print its
/// result and then hang — and the watchdog would report a timeout for a run that had
/// already finished. Every window the app can put up on its own has to ask.
enum MeetingConsolePolicy {
    static func shouldPresent(isSelfTest: Bool) -> Bool { !isSelfTest }
}
