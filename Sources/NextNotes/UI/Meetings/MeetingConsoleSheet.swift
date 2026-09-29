import AppKit
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

/// The window content: a rail of four destinations and the section currently showing.
///
/// `HSplitView` keeps the four destinations beside one content pane without a second
/// navigation title bar inside the window.
///
/// **It must never be shown during a self-test**, which is `MeetingConsolePolicy`'s whole
/// job — see there.
struct MeetingConsoleSheet: View {
    let session: MeetingSession
    let close: () -> Void

    /// A single-selection `List` binds to an optional, but the first section must also
    /// appear selected when the panel opens, not merely supply content behind an empty rail.
    @State private var selection: MeetingConsoleSection?
    /// An unfinished question survives a trip to Notes or History while this sheet stays up.
    @State private var askDraft = ""

    init(session: MeetingSession, initialSection: MeetingConsoleSection = .notes,
         close: @escaping () -> Void) {
        self.session = session
        self.close = close
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        HSplitView {
            rail
                .frame(width: DS.Size.meetingConsoleRailWidth)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: DS.Size.meetingConsoleMinWidth)
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

    /// The visible section and its activity, resolved in one place.
    ///
    /// A `@ViewBuilder` switch over four concrete types gives back an opaque type, and an
    /// opaque type cannot be asked for its activity. Resolving both together keeps the
    /// content and the status row in step.
    private struct Resolved {
        let body: AnyView
        let activity: MeetingConsoleActivity
    }

    private var current: Resolved {
        switch section {
        case .notes:
            let view = MeetingConsoleNotesSection(session: session)
            return Resolved(
                body: AnyView(view),
                activity: view.activity
            )
        case .actions:
            let view = MeetingConsoleActionsSection(session: session)
            return Resolved(
                body: AnyView(view),
                activity: view.activity
            )
        case .history:
            let view = MeetingConsoleHistorySection(session: session)
            return Resolved(
                body: AnyView(view),
                activity: view.activity
            )
        case .ask:
            let view = MeetingConsoleAskSection(session: session, draft: $askDraft)
            return Resolved(
                body: AnyView(view),
                activity: view.activity
            )
        }
    }

    private var pane: some View {
        // Resolve once so the status and content use the same section instance.
        let shown = current
        return VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Text(session.meeting.title)
                    .font(DS.Font.callout)
                    .lineLimit(1)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s)
                Button("Close", systemImage: "xmark", action: close)
                    .buttonStyle(.borderless)
                    .help("Close the meeting window")
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.vertical, DS.Space.s)
            Divider()
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
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
/// The reason is the same one `OnboardingPolicy.shouldPresent` carries: a window raised
/// during a self-test can keep `NSApp.terminate` from completing after a verdict prints.
enum MeetingConsolePolicy {
    static func shouldPresent(isSelfTest: Bool) -> Bool { !isSelfTest }
}

/// A single movable, resizable meeting window. Reopening the button brings the same window
/// forward, including the current editor and Ask draft.
@MainActor
final class MeetingConsoleWindowController: NSObject, NSWindowDelegate {
    static let shared = MeetingConsoleWindowController()

    private var window: NSWindow?
    private var meetingID: UUID?

    func show(session: MeetingSession) {
        guard MeetingConsolePolicy.shouldPresent(isSelfTest: SelfTest.isRunning) else { return }
        if let window, meetingID == session.meeting.id {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        window?.close()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: DS.Size.meetingConsoleWindow),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Meeting notes"
        window.contentMinSize = NSSize(width: DS.Size.meetingConsoleMinWidth,
                                       height: DS.Size.meetingConsoleMinHeight)
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: MeetingConsoleSheet(session: session) {
            MeetingConsoleWindowController.shared.close()
        })
        window.delegate = self
        window.center()
        self.window = window
        meetingID = session.meeting.id
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window = nil
        meetingID = nil
    }
}
