import AppKit
import SwiftUI

/// The design system for Next Notes.
///
/// Direction: a native macOS app. Sidebar navigation, system materials, the system font,
/// standard controls. The app should look like it shipped with the OS, and it should
/// inherit every appearance, accent and accessibility setting the user has chosen without
/// a line of code here knowing about them — which is why nearly every token below resolves
/// to a semantic system value rather than a literal.
///
/// The rule that survives from the previous design: **views contain no literal values.**
/// If a view needs a number or a color that isn't a token, add the token.
///
/// Two colour rules are not negotiable:
/// - **Red means recording.** Nothing else in the app is red.
/// - **Green, yellow and red on a meter are instrumentation only** — level meters, never
///   UI chrome. Status colours for text use `success` / `warning`, not the meter tokens.
enum DS {

    // MARK: - Color

    enum Color {
        // Text — fixed light ink. Every name below resolves into `Theme.Palette`;
        // nothing here reads the Mac's appearance any more (owner decision 2026-10-01).
        static let text = Theme.Palette.foreground
        static let textSecondary = Theme.Palette.mutedForeground
        /// Tertiary system text would be unreadably faint on the fixed light
        /// substrate, so it resolves to the same readable muted ink as secondary.
        /// `graphTopic` follows it there; that is a reviewed consequence, not an accident.
        static let textTertiary = Theme.Palette.mutedForeground
        static let placeholder = Theme.Palette.mutedForeground

        // Surfaces
        static let window = Theme.Palette.background
        static let content = Theme.Palette.card
        static let groupedFill = Theme.Palette.muted
        static let separator = Theme.Palette.border
        /// Active selection. Dark ink; the system draws alternate selected text over
        /// it, so selected rows stay readable without a blue accent anywhere.
        static let selection = Theme.Palette.foreground

        // Accent — the fixed control colour (ink), not the Mac's accent. The site's
        // teal survives only as `Theme.Palette.accent` for explicitly sparing use.
        static let accent = Theme.Palette.primary
        /// The only red in the app.
        static let record = SwiftUI.Color(nsColor: .systemRed)

        /// The notch island's own substrate. Fixed light per the owner every-surface
        /// decision: the bezel-continuity exception is retired, so the island wears
        /// the shared background with shared ink like every other surface. Notched-Mac
        /// live review of the result remains open (geometry/camera gap untouched).
        static let island = Theme.Palette.background
        static let islandInk = Theme.Palette.foreground

        // Instrumentation only. Never use these for UI chrome.
        static let meterNominal = SwiftUI.Color(nsColor: .systemGreen)
        static let meterHot = SwiftUI.Color(nsColor: .systemYellow)
        static let meterPeak = SwiftUI.Color(nsColor: .systemRed)
        static let meterTrack = SwiftUI.Color(nsColor: .quaternaryLabelColor)
        static let meterNeedle = Theme.Palette.foreground

        // Status text and badges. Words and icons carry the meaning; on the fixed
        // light substrate the ink is dark rather than orange-on-white.
        static let success = Theme.Palette.foreground
        static let warning = Theme.Palette.foreground
        static let info = Theme.Palette.foreground

        // Knowledge graph node inks (Search → Graph). Not chrome — canvas dots only.
        /// Person identity keeps the site teal explicitly: `accent` above is now the
        /// fixed control ink, and folding a person node into it would erase the one
        /// data encoding this colour carries.
        static let graphPerson = Theme.Palette.accent
        static let graphMeeting = text
        /// Decision identity keeps its green explicitly for the same reason: status
        /// *text* moved to dark ink, but a decision dot is data, not a status word.
        static let graphDecision = SwiftUI.Color(nsColor: .systemGreen)
        static let graphWork = SwiftUI.Color(nsColor: .systemBlue)       // Project, Organization, Goal
        static let graphLife = SwiftUI.Color(nsColor: .systemTeal)       // Activity, Place, Event
        static let graphPreference = SwiftUI.Color(nsColor: .systemPurple)
        static let graphTopic = textTertiary
        /// Folders the user shared with the assistant.
        static let graphFolder = SwiftUI.Color(nsColor: .systemOrange)
        /// Individual files, a shade quieter than the folder that holds them.
        static let graphFile = SwiftUI.Color(nsColor: .systemBrown)
        /// Core memories the user saved. Drawn by `MemoryGraphOverlay`, not the extractor.
        static let graphMemory = SwiftUI.Color(nsColor: .systemIndigo)

        /// Ink for a graph node by ontology type.
        static func graphNode(_ type: String) -> SwiftUI.Color {
            switch type {
            case "Person": graphPerson
            case "Meeting": graphMeeting
            case "Decision", "ActionItem", "OpenQuestion", "Artifact": graphDecision
            case "Project", "Organization", "Goal": graphWork
            case "Activity", "Place", "Event": graphLife
            case "Preference": graphPreference
            case "Topic": graphTopic
            case "Folder": graphFolder
            case "File": graphFile
            case "Memory": graphMemory
            default: textTertiary
            }
        }

        /// Diarized speakers, in assignment order. "You" is always `accent`.
        static let speakers: [SwiftUI.Color] = [
            SwiftUI.Color(nsColor: .systemBlue),
            SwiftUI.Color(nsColor: .systemTeal),
            SwiftUI.Color(nsColor: .systemIndigo),
            SwiftUI.Color(nsColor: .systemOrange),
            SwiftUI.Color(nsColor: .systemPurple),
            SwiftUI.Color(nsColor: .systemBrown),
        ]

        static func speaker(at index: Int) -> SwiftUI.Color {
            speakers[index % speakers.count]
        }

        /// The colour a speaker label always gets, wherever it is drawn.
        ///
        /// Folded by hand rather than through `hashValue`: Swift seeds string hashing per
        /// process, so the palette would reshuffle itself on every launch and the person who
        /// was teal yesterday would be brown today.
        static func speaker(named label: String) -> SwiftUI.Color {
            let fold = label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 }
            return speaker(at: fold)
        }
    }

    // MARK: - Type

    /// The site’s Inter family at existing native text-style sizes. Relative text
    /// styles preserve semantic scaling; numeric counters/timestamps retain their
    /// existing rounded/monospaced metrics. Computed aliases do not permanently
    /// latch system fallback if evaluated before launch registers bundled fonts.
    enum Font {
        static var largeTitle: SwiftUI.Font { Theme.Typography.sans(.largeTitle) }
        static var title: SwiftUI.Font { Theme.Typography.sans(.title) }
        static var title2: SwiftUI.Font { Theme.Typography.sans(.title2) }
        static var title3: SwiftUI.Font { Theme.Typography.sans(.title3) }
        static var headline: SwiftUI.Font { Theme.Typography.sans(.headline, weight: .semibold) }
        static var body: SwiftUI.Font { Theme.Typography.sans(.body) }
        static var callout: SwiftUI.Font { Theme.Typography.sans(.callout) }
        static var subheadline: SwiftUI.Font { Theme.Typography.sans(.subheadline) }
        static var footnote: SwiftUI.Font { Theme.Typography.sans(.footnote) }
        static var caption: SwiftUI.Font { Theme.Typography.sans(.caption) }
        static var caption2: SwiftUI.Font { Theme.Typography.sans(.caption2) }

        /// Transcript text, in lists and the live view.
        static var transcript: SwiftUI.Font { Theme.Typography.sans(.body) }
        /// Elapsed-time counters. Rounded so it reads as a display, monospaced digits so
        /// it doesn't jitter as it ticks.
        static let counter = SwiftUI.Font.system(.title2, design: .rounded).monospacedDigit()
        static let counterSmall = SwiftUI.Font.system(.body, design: .rounded).monospacedDigit()
        /// Timestamps beside transcript segments.
        static let timestamp = SwiftUI.Font.system(.caption, design: .monospaced)
        static var notesHeading: SwiftUI.Font { Theme.Typography.sans(.title3, weight: .semibold) }
        static var notesSubheading: SwiftUI.Font { Theme.Typography.sans(.headline, weight: .semibold) }
        static var chip: SwiftUI.Font { Theme.Typography.sans(.caption, weight: .medium) }
        static var sectionLabel: SwiftUI.Font { Theme.Typography.sans(.subheadline, weight: .semibold) }
        /// A small capitalised label above or beside a thing, rather than a heading for it —
        /// the landing page's card labels. Letterspaced, because capitals set at caption
        /// size and default tracking read as one long word. Must stay non-negative: a
        /// negative figure is what collapses “Talk to your computer” into one glyph-run.
        static var eyebrow: SwiftUI.Font { Theme.Typography.sans(.caption2, weight: .medium) }
        static let eyebrowTracking: CGFloat = 1.4
        /// Headings and sentences. Zero is the system default; it is a token so a title
        /// cannot inherit eyebrow letterspacing and lose its word spaces.
        static let wordTracking: CGFloat = 0
        /// An empty state's heading. Matches `ContentUnavailableView`'s own, so the two
        /// vocabularies can sit on the same screen without arguing.
        static var emptyStateTitle: SwiftUI.Font { Theme.Typography.sans(.title3, weight: .semibold) }
        static var emptyStateMessage: SwiftUI.Font { Theme.Typography.sans(.callout) }
    }

    // MARK: - Spacing

    /// A 4pt grid.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48

        /// A screen's own margin inside the detail pane. Larger than a list row's inset,
        /// because a screen that carries a backdrop needs the content to sit off the edge
        /// far enough that the backdrop reads as *behind* it rather than as a border.
        static let page: CGFloat = 20
        /// Between two sections of one screen.
        static let section: CGFloat = 28
        /// Inside a glass card, all round.
        static let card: CGFloat = 14
        /// Inside a small glass card or a glass chip.
        static let cardTight: CGFloat = 10
        /// Between an orb and the text it labels. Wider than `s`: an orb is a busy shape
        /// and its dots reach its own edge, so text set at `s` from one reads as touching.
        static let orbGap: CGFloat = 10
    }

    // MARK: - Radius

    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 10
        static let sheet: CGFloat = 14
        static let hud: CGFloat = 22
        /// The island's bottom corners, matching the curve the notch itself ends on so the
        /// two read as one shape. Its top corners are the screen edge and have no radius.
        static let island: CGFloat = 14
        /// All four corners, once the island is floating below the menu bar instead.
        static let islandFloating: CGFloat = 18
        /// A glass surface in a window. Larger than `card`: glass has no border, so the
        /// corner is the only thing that says where the pane ends.
        static let glass: CGFloat = 16
        /// The same treatment on something the size of a chip or a single row.
        static let glassSmall: CGFloat = 10
        /// A dotted field used as a panel background rather than as a whole screen.
        static let field: CGFloat = 12
        /// Hover label chip floating above a global-graph node.
        static let graphHoverChip: CGFloat = 8
        /// Glass chrome floating over the map — toolbar, legend, detail card.
        static let graphChrome: CGFloat = 12
    }

    // MARK: - Size

    enum Size {
        /// Maximum catalog rows shown before a search or filter narrows the result.
        static let openRouterVisibleModels = 25
        static let voiceChoiceBorder: CGFloat = 1
        static let sidebarMin: CGFloat = 200
        static let sidebarIdeal: CGFloat = 230
        static let sidebarMax: CGFloat = 320
        static let windowMin = CGSize(width: 900, height: 600)
        static let detailMin: CGFloat = 560
        static let contentListMin: CGFloat = 260
        static let contentListIdeal: CGFloat = 300

        static let hud = CGSize(width: 360, height: 72)
        /// Distance from the bottom of the visible screen area to the HUD.
        static let hudBottomInset: CGFloat = 96
        /// The level bar inside the HUD capsule.
        static let hudBarWidth: CGFloat = 72

        /// P1-20: the composer row's trailing control. One size in every state, so the row does
        /// not change width when a turn starts or ends — which it did, twice a turn, with a Stop
        /// button appearing beside a Send button.
        static let composerControl = CGSize(width: 74, height: 28)

        static let meter = CGSize(width: 160, height: 44)
        static let levelBarHeight: CGFloat = 6
        static let levelBarPeakWidth: CGFloat = 2
        static let recordDot: CGFloat = 10
        static let recordDotCompact: CGFloat = 8
        static let speakerDot: CGFloat = 8
        static let statusDot: CGFloat = 8

        // MARK: Meetings

        /// The meeting list inside the Meetings section. Narrower than the window's own
        /// sidebar: it is a second list in the same window, and two columns of equal
        /// weight read as a split rather than as a list with a detail beside it.
        static let meetingListMin: CGFloat = 220
        static let meetingListIdeal: CGFloat = 260
        static let meetingDetailMin: CGFloat = 360
        /// Keeps the "You" and "Others" labels above the two live meters aligned.
        static let trackLabelWidth: CGFloat = 56

        /// The movable meeting window and its content minimum.
        static let meetingConsoleWindow = NSSize(width: 860, height: 680)
        static let meetingConsoleMinWidth: CGFloat = 680
        /// Floor for its content. A long transcript scrolls.
        static let meetingConsoleMinHeight: CGFloat = 520
        /// The section rail down the left side — four destinations, each a symbol and a
        /// word, so it reads as a list rather than as a toolbar.
        static let meetingConsoleRailWidth: CGFloat = 168
        /// One rail row. A macOS list row is 20-something points, which is a badge's worth
        /// of a target; this is the 44 a pointer expects from anything it can miss.
        static let meetingConsoleRowHeight: CGFloat = 44
        /// The hand-typed notes field. Tall enough to write a line and a half of a thought
        /// without the keyboard covering the next one, short enough that the transcript
        /// above it still has somewhere to be.
        static let meetingConsoleNoteEditorHeight: CGFloat = 132
        static let meetingConsoleDocumentMinHeight: CGFloat = 420
        /// One past meeting in the look-back list, with its preview under it.
        static let meetingConsoleHistoryRowHeight: CGFloat = 56
        /// How many lines of that meeting a row shows before the rest is one press away.
        static let meetingConsoleHistoryPreviewLines = 3

        /// The full text of a message an agent proposal would send, before it scrolls. Tall
        /// enough to read an email without leaving the card, short enough that two proposals
        /// still fit on screen.
        static let messagePreviewHeight: CGFloat = 140
        /// A conversation bubble stays readable on a wide desktop detail pane.
        static let agentBubbleMaxWidth: CGFloat = 620
        static let agentChatMaxWidth: CGFloat = 760
        static let agentEventMaxWidth: CGFloat = 520
        /// Chat header / thinking-row Notion avatar.
        static let agentAvatar: CGFloat = 28
        /// Agent → About hero avatar.
        static let agentAvatarHero: CGFloat = 96
        /// Thumbnail in the avatar part chooser.
        static let agentAvatarThumb: CGFloat = 56
        /// Pencil affordance overlapping the About avatar.
        static let agentAvatarEdit: CGFloat = 28
        /// Agent pane layout. Every pane (Conversation, Ideas, Goals, Reminders,
        /// Activity, Graph, Skills, About) is a full-width pane: a header, then cards
        /// and lists that use the window they were given. A centred 640pt column in a
        /// 2000pt window is the complaint these tokens replaced. Prose is capped so a
        /// sentence never runs the whole window; grids and lists fill.
        ///
        /// The shared pieces live in `UI/Agent/AgentPaneLayout.swift` — use them rather
        /// than adding a new column cap to a pane.
        static let agentProseMaxWidth: CGFloat = 760
        /// Minimum width of one card in an adaptive pane grid. Below it the grid drops
        /// a column instead of squeezing every card.
        static let agentCardMinWidth: CGFloat = 300
        /// A two-column pane (list plus rail) only forms at or above this width; below
        /// it the rail stacks under the list — same content, same order.
        static let agentWideMinWidth: CGFloat = 960
        /// The rail column in a two-column pane: login card, approvals, heartbeat.
        static let agentRailWidth: CGFloat = 340
        /// The smallest the pane switcher may measure once hosted: the current pane's
        /// name plus its chevron. A chevron-only toolbar circle is ~44pt, so
        /// `--selftest-agent-panes` fails when the selector renders without its label.
        static let agentSwitcherMinWidth: CGFloat = 160
        /// About hero avatar block. The hero stays a centred column by design; the
        /// SOUL / MEMORY / data cards below it fill the pane like every other pane's.
        /// `--selftest-agent-panes` allows this one cap here and bans it in every pane.
        static let agentAboutMaxWidth: CGFloat = 640
        /// The avatar editor's part-picker cap. The SOUL / MEMORY pair used to share this
        /// as a grid minimum; it does not any more — see `agentAboutCardsMinWidth`.
        static let agentAboutCardIdeal: CGFloat = 280
        /// At or above this width the SOUL and MEMORY cards sit side by side and split the
        /// pane evenly; below it they stack, each full width. Two `agentCardMinWidth` cards
        /// plus the gap between them.
        ///
        /// The pair deliberately does not use `AgentCardGrid`: `LazyVGrid` chooses its
        /// column count from the minimum, not from how many cards there are, so with
        /// exactly two cards every column past the second is left empty — and a fixed
        /// minimum can only trade a wide pane's empty space for a narrow pane's stack,
        /// never fill both. `AgentAboutView` uses a `ViewThatFits` pair instead: side by
        /// side sharing the width, or stacked.
        static let agentAboutCardsMinWidth: CGFloat = agentCardMinWidth * 2 + DS.Space.card
        /// SOUL / MEMORY access tiles.
        static let agentAccessCardMinHeight: CGFloat = 140
        /// Minimum width of one skill card in the pane grid.
        static let skillCardMin: CGFloat = 320
        /// A skill card's minimum height, so a row of cards with short and long descriptions
        /// still lines up its bottom row (See what it says / page count) across the row.
        static let skillCardMinHeight: CGFloat = 156
        /// The bring-memory-in / download-memory sheet. Wide enough for a proposed memory
        /// to sit on one line beside its checkbox, tall enough to show several at once.
        static let memoryPortabilitySheetWidth: CGFloat = 600
        static let memoryPortabilitySheetHeight: CGFloat = 540
        /// The paste box on the guided import step, and the scroll height of the review
        /// list — both scroll rather than growing the sheet.
        static let memoryPasteBoxHeight: CGFloat = 160
        static let memoryReviewListHeight: CGFloat = 280
        /// A determinate progress bar in a detail pane. Wide enough to read as progress,
        /// narrow enough not to read as a divider.
        static let progressWidth: CGFloat = 220

        /// The system Settings sidebar's share of the window. We do not draw this
        /// column; we size around it so a compact inspector frame cannot clip the form.
        static let settingsSidebarWidth: CGFloat = 240
        /// The grouped form column, not the window.
        static let settingsWidth: CGFloat = 560
        /// One section card in the responsive settings grid.
        ///
        /// `GroupedFormStyle` lays its rows out in a content column that stops at ~744pt
        /// and then centres — measured on macOS 27, `--selftest-settings` pins it. A card
        /// wider than `settingsCardMaxWidth` would run back into that cap and centre its
        /// rows inside itself, which is the bug at a smaller scale, so the grid never
        /// grows a native card past it. `settingsCardMinWidth` is the width the panes were
        /// designed against — `settingsWidth` — and it decides *how many* columns fit: one
        /// below `settingsCardMinWidth * 2`, two above. It is not a floor on the drawn
        /// card. Measured on macOS 27: a pane narrower than the minimum renders one column
        /// at the pane's own width, and pinning the column's minimum at this width in a
        /// 320pt pane renders pixel-for-pixel the same view. The clipping worth fixing was
        /// a `frame(minWidth:)` demand, never the grid.
        static let settingsCardMinWidth: CGFloat = 560
        static let settingsCardMaxWidth: CGFloat = 720
        /// The narrowest pane that has to render without clipping.
        ///
        /// Settings is embedded in the main window as well as standing alone, and there
        /// the detail pane's own minimum (`detailMin`) is shared with the system Settings
        /// sidebar — so this is what is left for the form. A pane that asks for more than
        /// its host has is not honoured by SwiftUI; it is drawn past the window's right
        /// edge and clipped, which is the four screenshots `--selftest-settings` pins.
        /// Every host that can show Settings provides at least this much: the standalone
        /// window's 800pt minimum leaves the form 560, and the main window's detail leaves
        /// it exactly this.
        static let settingsPaneMinWidth: CGFloat = detailMin - settingsSidebarWidth
        /// Sidebar plus form. Narrower than this is the cropped strip: ten names, no pane,
        /// and it is the **standalone window's** minimum — `SettingsWindowFrame.pin`
        /// raises the window to it. The embedded copy is laid out at whatever the main
        /// window's detail column has, down to `settingsPaneMinWidth`.
        static let settingsWindowMinWidth: CGFloat = settingsSidebarWidth + settingsWidth
        /// First-open size. Same as the min so a persisted inspector frame cannot return
        /// narrower than the form.
        static let settingsWindowWidth: CGFloat = settingsWindowMinWidth
        /// Tall enough for the sidebar list and a grouped form heading.
        static let settingsWindowMinHeight: CGFloat = 560
        static let settingsMinHeight: CGFloat = settingsWindowMinHeight
        /// An app's own icon, beside its name in the formatting picker.
        static let appIcon: CGFloat = 20
        /// Text fields in a grouped `Form` stretch to the full row otherwise, which reads
        /// as a text area rather than as one value.
        static let settingsFieldWidth: CGFloat = 260
        /// One capability checkbox column in the output-formatting table. Wide enough for a
        /// checkbox and the gap that keeps five of them from reading as one control.
        static let formatCapabilityColumn: CGFloat = 34
        /// The output-formatting app list scrolls inside this height rather than growing
        /// the pane.
        static let formatListHeight: CGFloat = 240
        /// The Google calendar checklist scrolls past this rather than pushing the rest of
        /// the tab off the window — some accounts subscribe to dozens.
        static let calendarListHeight: CGFloat = 132
        static let sheetWidth: CGFloat = 460
        /// Agent → About's SOUL and MEMORY editor sheets. `sheetWidth` above is a
        /// one-question sheet that sizes to its sentence; these two host a text editor and
        /// a long list, so they open at this comfortable size where the pane has room and
        /// clamp to the pane where it does not — the form inside scrolls either way, so
        /// neither a large window nor a small one clips the sheet.
        static let sheetEditorWidth: CGFloat = 720
        static let sheetEditorHeight: CGFloat = 640
        static let onboardingWidth: CGFloat = 520

        /// The fixed leading column that keeps chips in a list aligned with each other.
        static let chipColumn: CGFloat = 52

        static let iconSmall: CGFloat = 12
        static let iconMedium: CGFloat = 16
        static let iconLarge: CGFloat = 24
        static let emptyStateIcon: CGFloat = 36

        // MARK: Island

        /// How far the collapsed island reaches past each side of the notch. The badges
        /// live in these two strips; the notch itself is a hole between them.
        static let islandFlank: CGFloat = 72
        /// The expanded card. Wide enough for a meeting title and two buttons on one row,
        /// and wider than the collapsed island on a notched Mac by enough that the card
        /// visibly grows sideways as well as down.
        static let islandExpandedWidth: CGFloat = 480
        /// How far the expanded card drops below the menu bar.
        static let islandExpandedDrop: CGFloat = 108
        /// The collapsed height on a display without a notch, where there is no menu-bar
        /// inset to borrow. Roughly a menu bar, so the two look like the same object.
        static let islandCapsuleHeight: CGFloat = 30
        /// Gap between the menu bar and the floating capsule on a display without a notch.
        static let islandFloatingInset: CGFloat = 6
        static let islandBarWidth: CGFloat = 44
        static let islandExpandedBarWidth: CGFloat = 120

        // MARK: Orbs

        /// The orb at each scale it is drawn.
        ///
        /// These are canvas sides, not scale factors: `OrbGeometry` is a pure function of
        /// size, so an orb is *asked for* the size it will occupy rather than drawn once
        /// and transformed. A `scaleEffect` on an orb is always a mistake — it magnifies
        /// the dot radii along with the sphere and turns a lattice into a smear.
        ///
        /// Two tunings back these, not one: below `orbInlineCeiling` the inline preset is
        /// correct (a tenth of the dots at twice the radius) and above it the large one is.
        /// `ThinkingOrb` picks for itself when it is given an explicit size.

        /// Beside a single line of text in a list row.
        static let orbBadge: CGFloat = 16
        /// The default, beside a status line. Matches the HUD and the island.
        static let orbInline: CGFloat = 20
        /// Labelling a card, the way the landing page labels its hero cards.
        static let orbSmall: CGFloat = 28
        /// A section header's mark, where it is the heading's companion rather than a badge.
        static let orbMedium: CGFloat = 44
        /// The large tuning's home size: the one orb a working screen is allowed.
        static let orbLarge: CGFloat = 64
        /// An empty state's mark, where the orb *is* the illustration.
        static let orbFeature: CGFloat = 96
        /// A screen's ambient backdrop, behind the content.
        static let orbBackdrop: CGFloat = 320
        /// The same, on a full-width screen with room for it. The landing page's hero size.
        static let orbBackdropWide: CGFloat = 520
        /// The size at and above which the large tuning is drawn. Below it the large
        /// design's several hundred dots overlap into grey mud, which is the whole reason
        /// the library ships two designs rather than one and a scale factor.
        static let orbInlineCeiling: CGFloat = 96

        // MARK: Agent avatar

        /// The avatar beside an agent state on the island. Smaller than the chat avatar
        /// because the collapsed island is only as tall as the notch — one pixel taller
        /// and the face would touch the bezel.
        static let islandAvatar: CGFloat = 24
        /// The live portrait on the first-run welcome card, beside the name field. Big
        /// enough to show a generated face, small enough to stay a row.
        static let avatarOnboarding: CGFloat = 44
        /// Below this side a state's gadget is a smudge rather than a symbol, so the body
        /// language carries the animation alone.
        static let avatarPropMinimum: CGFloat = 36
        /// A gadget badge, as a fraction of the avatar's side, and how far its centre sits
        /// from the portrait's centre along each axis. Together they land it on the lower
        /// trailing rim — the badge is deliberately not clipped to the portrait's circle,
        /// so its edge reaches just past the face and no further than the frame.
        static let avatarPropFraction: CGFloat = 0.32
        static let avatarPropOffsetFraction: CGFloat = 0.32
        /// The symbol inside the badge, as a fraction of the badge.
        static let avatarPropGlyphFraction: CGFloat = 0.55
        /// Stroke width of a listening ring, in points.
        static let avatarRingWidth: CGFloat = 1.25

        // MARK: Empty states and cards

        /// How wide an empty state's message is allowed to run before it wraps. Narrower
        /// than the pane on purpose — a sentence centred under an orb reads as a caption
        /// only while it is short enough to take in at a glance.
        static let emptyStateWidth: CGFloat = 340
        /// Keeps an empty state vertically centred in a pane that is otherwise short,
        /// rather than clinging to the top of it.
        static let emptyStateMinHeight: CGFloat = 260
        /// A glass card in a grid, before the grid decides how many fit.
        static let cardMin: CGFloat = 240
        static let cardIdeal: CGFloat = 300

        /// How far prose is allowed to run before it wraps — notes, a transcript, a long
        /// explanation. A detail pane on a wide display is far wider than a comfortable
        /// line, and nothing about the window's width is an argument for a 1400pt measure.
        static let readingWidth: CGFloat = 680
        /// A screen's header strip, when it carries a field or a backdrop of its own rather
        /// than sitting on the window like a toolbar.
        static let headerBand: CGFloat = 140
        /// The dictation status band. Pinned so the list beneath it does not jump as the
        /// band's content changes between states — the meter used to set this height, and
        /// removing it left the band free to resize on every transition.
        static let statusBandMinHeight: CGFloat = 44

        // MARK: Knowledge graph

        // A node used to be one of four fixed dot sizes. It is now sized by how many things
        // it is joined to, between `graphDotMin` and `graphDotMax` below — those are the
        // live tokens, and the four fixed ones are gone so nobody reaches for both sets.

        /// Gap between the filled dot and its selection ring.
        static let graphNodeRingPad: CGFloat = 4
        /// Hit target around a graph node — larger than the drawn dot so clicks land.
        static let graphNodeHitRadius: CGFloat = 22
        /// A graph canvas's inset from the pane edge, so node labels never clip.
        static let graphCanvasInset: CGFloat = 32
        /// Minimum height for a force-layout canvas in the Search detail.
        static let graphCanvasMinHeight: CGFloat = 360
        /// Cap on a node label under its dot.
        static let graphLabelMaxWidth: CGFloat = 128
        /// Hover chip on the global map — slightly wider than a local label.
        static let graphHoverLabelMaxWidth: CGFloat = 168
        /// Node rows in the graph's side list before it scrolls.
        static let graphNodeListHeight: CGFloat = 280
        /// Type-colour swatch beside a rail row.
        static let graphRailSwatch: CGFloat = 8

        // MARK: Knowledge map (the whole-map canvas)

        /// The smallest a dot on the map gets. A node's size is how many things it is
        /// joined to, so this is the size of something mentioned once.
        static let graphDotMin: CGFloat = 7
        /// The largest. The busiest node on a map is this wide and no wider, however many
        /// edges it has — past a point a bigger dot stops meaning "more" and starts
        /// meaning "in the way".
        static let graphDotMax: CGFloat = 26
        /// At and above this diameter a dot carries its SF Symbol instead of being plain.
        static let graphGlyphThreshold: CGFloat = 15
        /// The glyph inside a dot, as a fraction of the dot.
        static let graphGlyphRatio: CGFloat = 0.52
        /// At and above this diameter a node keeps its name on screen without being
        /// pointed at. Everything smaller shows its name on hover or when zoomed in.
        static let graphLabelThreshold: CGFloat = 16
        /// How far an edge bows away from the straight line between its two nodes, as a
        /// fraction of their distance. A straight line between every pair reads as a
        /// diagram; a slight, consistent bow reads as a map.
        static let graphEdgeBow: CGFloat = 0.13
        /// The soft glow around the selected node — added to its diameter.
        static let graphSelectionGlow: CGFloat = 24
        /// The floating glass chrome's distance from the canvas edge.
        static let graphChromeInset: CGFloat = 14
        /// A control glyph in that chrome.
        static let graphChromeIcon: CGFloat = 12
        /// The card that floats over the map describing the selected node.
        static let graphDetailCardWidth: CGFloat = 250
        /// Zoom limits, and one press of the zoom buttons.
        static let graphZoomMin: CGFloat = 0.4
        static let graphZoomMax: CGFloat = 4
        static let graphZoomStep: CGFloat = 1.35
        /// How much of the zoom reaches the dots themselves. Well under 1 on purpose: the
        /// map spreads apart as you zoom in, but a dot that grew with it would swallow the
        /// space the zoom just made.
        static let graphZoomDotExponent: CGFloat = 0.34
        /// Drag distance before a press on the canvas is a pan rather than a selection.
        static let graphPanThreshold: CGFloat = 4
        /// Scroll distance, in points, for one doubling of the zoom.
        static let graphScrollZoomRate: CGFloat = 320
        /// The whole map, edge to edge under the pane.
        static let graphMapMinHeight: CGFloat = 440
        /// A colour swatch in the map's legend.
        static let graphLegendSwatch: CGFloat = 7
        /// The floating heading over the map, before its sentence wraps.
        static let graphHeaderMaxWidth: CGFloat = 320
        /// The filter chips, before they wrap onto another row.
        static let graphChipsMaxWidth: CGFloat = 400
        /// How far past the frame a node is still drawn. Anything further out cannot be
        /// seen, and skipping it is what keeps a zoomed-in map cheap.
        static let graphCullMargin: CGFloat = 64
        /// The frame is rounded down to this step before a layout is asked for, so
        /// dragging a window edge does not restart the simulation on every frame.
        static let graphLayoutSizeStep: CGFloat = 24
        /// How long a name on the map runs before it is cut. A label that wraps into a
        /// paragraph has stopped being a label.
        static let graphLabelCharacters = 28
        /// How many names the map shows without being asked. Past this the picture is
        /// text rather than a shape, so the rest arrive on hover and on zoom.
        static let graphRestingLabels = 14
        /// The widest a person timeline row runs before it wraps.
        static let timelineRowMaxWidth: CGFloat = 560
        /// Vertical rail beside person-timeline moments.
        static let timelineSpineWidth: CGFloat = 2
        /// Moment marker on that spine.
        static let timelineMarker: CGFloat = 10
        /// Leading column that holds the spine + marker.
        static let timelineGutter: CGFloat = 28
    }

    // MARK: - Field

    /// The dotted matrix: the landing page's texture, as a background.
    ///
    /// The same ink as an orb and the same lattice logic, flattened. It is drawn **once**,
    /// not per frame — a full-window field is thousands of dots, and a `TimelineView` over
    /// that would cost more than every orb in the app put together for a texture nobody
    /// looks directly at.
    enum Field {
        static let dotFine: CGFloat = 1
        static let dot: CGFloat = 1.5
        static let dotBold: CGFloat = 2.5

        static let spacingTight: CGFloat = 9
        static let spacing: CGFloat = 14
        static let spacingWide: CGFloat = 22

        /// How finely the fade is quantized. Each level is one `Path` and one fill, so this
        /// is the number of draw calls a whole field costs.
        static let inkLevels = 8
        /// The exponent on a radial fade. Above 1 the centre holds its weight and the fall
        /// happens late, which is what keeps a field from reading as a vignette.
        static let falloff: Double = 1.6
        /// How far out the radial fade reaches, as a fraction of the half-diagonal. Under 1
        /// so the field dies before the edge and has no boundary to see.
        static let reach: Double = 0.92
    }

    // MARK: - Material

    enum Material {
        static let hud = SwiftUI.Material.ultraThin
        static let card = SwiftUI.Material.regular
        static let thin = SwiftUI.Material.thin
        static let hudGlass: Glass = Theme.Glass.tinted
        /// A glass pane inside a window — the app's equivalent of the landing page's
        /// `.liquid-glass`. The rim light that CSS draws by hand is not ported: the system
        /// glass draws its own specular edge, and it draws it against whatever is
        /// actually behind the pane. Consumes the theme tuning (owner decision
        /// 2026-10-01); the fixed light substrate is what the specular edge draws
        /// against now.
        static let surfaceGlass: Glass = Theme.Glass.tinted
    }

    // MARK: - Opacity

    enum Opacity {
        static let recordIdle: Double = 0.25
        static let recordPulseLow: Double = 0.35
        static let disabled: Double = 0.4
        static let chipFill: Double = 0.14
        static let meterActiveTint: Double = 0.08
        static let secondaryFill: Double = 0.5
        /// The bottom of the orb's breath, while it stands in for a spinner.
        static let orbBreathLow: Double = 0.62
        /// Secondary text on the island's black substrate, where `.secondary` would be
        /// resolved against the window's appearance rather than against the bezel.
        static let islandInkSecondary: Double = 0.68

        // MARK: Backdrop and field

        /// A backdrop orb behind a screen's content.
        ///
        /// An order of magnitude fainter than the landing page's 0.5, and that is not
        /// timidity. The page draws white ink on pure black and nothing else is on it; this
        /// draws `.primary` on a window that already carries text, a sidebar and controls,
        /// in whichever appearance the user chose. At 0.5 it would be a second thing to
        /// read. The test is that you notice it only once you look for it.
        static let orbBackdrop: Double = 0.08
        /// The same, on a screen that is otherwise empty and can carry more.
        static let orbBackdropStrong: Double = 0.14
        /// A backdrop that sits under text rather than beside it.
        static let orbWatermark: Double = 0.05

        static let fieldFaint: Double = 0.06
        static let field: Double = 0.10
        static let fieldStrong: Double = 0.18

        /// An empty state's orb. Held just off full ink so it reads as an illustration
        /// rather than as a control.
        static let emptyStateOrb: Double = 0.85

        /// A gadget badge behind the avatar's shoulder — a tint of the same ink, so it
        /// survives the island's black substrate and a light window alike.
        static let avatarPropFill: Double = 0.14
        /// The loudest a listening ring gets before it falls off towards the centre.
        static let avatarRing: Double = 0.30

        /// Nodes outside the hovered neighbourhood on a local graph: still there, not the
        /// thing being looked at (Phase F).
        static let graphDimmed: Double = 0.18
        /// Edges that do not touch the hovered node.
        static let graphEdgeDimmed: Double = 0.08
        /// Edges that touch the hovered / focus neighbourhood.
        static let graphEdgeActive: Double = 0.42
        /// Selection ring around the focus node.
        static let graphFocusRing: Double = 0.55
        /// Lighter ring while the pointer is over a neighbour.
        static let graphHoverRing: Double = 0.32
        /// Edges on the whole map with nothing being pointed at. Above `graphEdgeDimmed`
        /// and below `graphEdgeActive`: at rest the lines are the shape of the map, and
        /// they only recede once one neighbourhood is being looked at.
        static let graphEdgeResting: Double = 0.2
        /// The SF Symbol inside a dot, against that dot's own fill.
        static let graphNodeGlyph: Double = 0.95
        /// The dotted ground under the map. Fainter than a page's field: it is behind a
        /// hundred dots of its own, not behind text.
        static let graphFieldInk: Double = 0.07
        /// The soft glow a selected node sits in.
        static let graphSelectionGlow: Double = 0.2
        /// A kind whose filter chip is switched off. Not hidden — a map that silently
        /// drops half its nodes is a different map, and you cannot tell which.
        static let graphFilteredOut: Double = 0.07
        /// Plate behind a node's name, so a label crossing an edge stays readable.
        static let graphLabelPlate: Double = 0.55
        /// Timeline spine behind person moments.
        static let timelineSpine: Double = 0.22
    }

    // MARK: - Scale

    /// Multipliers for anything that grows or shrinks in place.
    enum Scale {
        /// The top of the orb's breath.
        static let orbBreath: CGFloat = 1.08
        /// Where the expanded island's keyframed growth starts, before it overshoots and
        /// settles — the card arrives from inside the notch rather than fading in on top.
        static let islandArrive: CGFloat = 0.9
        /// The overshoot at the top of that growth.
        static let islandOvershoot: CGFloat = 1.02
    }

    // MARK: - Border

    enum Border {
        static let hairline: CGFloat = 1
        static let needle: CGFloat = 1.5
        /// Active edge on a local graph (hover / focus neighbourhood).
        static let graphEdgeActive: CGFloat = 1.5
        /// Quiet edges everywhere else on the canvas.
        static let graphEdgeQuiet: CGFloat = 0.75
        /// Dimmed edges on the global map while a neighbourhood is highlighted.
        static let graphEdgeFaint: CGFloat = 0.4
        /// Selection / hover ring around a graph node.
        static let graphRing: CGFloat = 1.5
        /// The ring around the one selected node on the map — heavier than a hover ring,
        /// because selection survives the pointer leaving.
        static let graphSelectionRing: CGFloat = 2
    }

    // MARK: - Shadow

    enum Shadow {
        static let card = Spec(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        static let hud = Spec(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        /// A **material** card that has to float over a backdrop rather than sit on the
        /// window. Softer and lower than `card`. Not for glass: a glass pane separates
        /// itself by refraction, and a shadow under one only muddies what it is refracting.
        static let raised = Spec(color: .black.opacity(0.16), radius: 14, x: 0, y: 4)

        struct Spec {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    // MARK: - Motion

    enum Motion {
        static let standard = Animation.snappy(duration: 0.2)
        static let emphasis = Animation.smooth(duration: 0.3)
        static let recordPulse = Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)
        static let hudFade: TimeInterval = 0.16

        /// The app's default for anything that changes shape or position rather than
        /// merely appearing: a spring, so a change that lands while another is still
        /// settling continues from where it is instead of restarting.
        static let fluid = Animation.spring(response: 0.45, dampingFraction: 0.78)
        /// Same spring, under-damped, for something that has just arrived and wants to be
        /// noticed once. Never used for anything the user is dragging or reading.
        static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.62)
        /// The island growing out of the notch, and collapsing back into it. Expanding is
        /// the gesture the eye follows, so it overshoots; collapsing gets out of the way.
        static let islandExpand = Animation.spring(response: 0.42, dampingFraction: 0.72)
        static let islandCollapse = Animation.spring(response: 0.32, dampingFraction: 0.9)
        /// How long the island's expand keyframes run. Matches `islandExpand`'s settle so
        /// the keyed scale and the sprung size finish together.
        static let islandExpandDuration: TimeInterval = 0.42
        static let islandFade: TimeInterval = 0.18
        /// How long an island notice that nobody answers stays up. Long enough to read a
        /// meeting title across a desk, short enough not to sit over the menu bar.
        static let islandNotice: TimeInterval = 8
        /// One in-and-out of the orb's breath, while it is collapsed to a badge.
        static let orbBreath: TimeInterval = 2.4
        static let copiedFeedback: TimeInterval = 1.4
        /// How often the permissions checklist re-reads TCC. There is no notification for
        /// a grant, so a visible checklist has to look.
        static let permissionPoll: TimeInterval = 2

        /// VU ballistics. A real VU meter reaches 99% of a step in ~300ms and overshoots
        /// slightly; that lag *is* the instrument's character, so the needle is damped
        /// rather than tracking the signal directly.
        static let needleAttack: TimeInterval = 0.30
        static let needleRelease: TimeInterval = 0.42
        /// Peak overshoot as a fraction of the step, before settling.
        static let needleOvershoot: Double = 0.06
        /// How long a meter keeps drawing after capture stops, so the fall to rest is
        /// animated rather than cut off. Longer than the release: the damping is
        /// exponential, so the last of the travel takes several time constants.
        static let needleSettle: TimeInterval = 1.6

        /// Bar meters are faster than a needle, and hold their peak briefly.
        static let barAttack: TimeInterval = 0.05
        static let barRelease: TimeInterval = 0.25
        static let peakHold: TimeInterval = 1.0
        /// Release plus the peak-hold decay, for the same reason as `needleSettle`.
        static let barSettle: TimeInterval = 2.0

        // MARK: Ambient orbs

        /// How fast a backdrop orb runs against its own clock.
        ///
        /// A backdrop is decoration in the corner of the eye, and decoration that moves at
        /// working speed reads as something demanding attention. Quartering the clock also
        /// quarters how often the picture meaningfully changes, which is what makes the
        /// reduced redraw rate below invisible.
        static let orbBackdropScale: Double = 0.25
        /// The same idea, one step less slowed, for an orb that is decorative but sits in
        /// the reading path — an empty state's mark.
        static let orbAmbientScale: Double = 0.5

        /// Redraw cap for a backdrop orb, in place of the display's own cadence.
        ///
        /// A 320pt canvas of five hundred dots is the most expensive thing this app draws,
        /// and at a quarter speed there is nothing in it that 20 frames a second loses.
        static let orbBackdropFrameInterval: TimeInterval = 1.0 / 20
        /// The same cap for an ambient orb at reading size.
        static let orbAmbientFrameInterval: TimeInterval = 1.0 / 30

        // MARK: Agent avatar

        /// The redraw cap for an avatar in an ambient state — idle, waiting, asleep. These
        /// can sit in a window all afternoon; a working avatar follows the display, the way
        /// a working orb does.
        static let avatarAmbientFrameInterval: TimeInterval = 1.0 / 20
        /// How long with no agent activity before the avatar stops attending. Ten minutes:
        /// long enough that nobody catches it napping mid-thought, short enough that a
        /// window left open over lunch is asleep when its owner comes back.
        static let avatarSleepAfter: TimeInterval = 600

        /// Content arriving over a backdrop. Slower than `standard` and without a spring:
        /// something appearing in front of a slowly moving field should not also bounce.
        static let reveal = Animation.smooth(duration: 0.35)
        /// The meeting panel changing what it is about. One curve, quick, and its own
        /// value: the rail's selection moves and the content crossfades, and if those two
        /// ran on different curves they would arrive at the same time as two animations
        /// fighting over the same pixels.
        static let consoleSectionChange = Animation.smooth(duration: 0.22)
        /// A backdrop or a field crossfading as a screen changes what it is about.
        static let ambient = Animation.easeInOut(duration: 1.2)

        /// The map recentring on a node that was just clicked. A spring rather than a
        /// curve, so clicking a second node while the first is still arriving continues
        /// from where the map is instead of snapping back and starting again.
        static let graphFocus = Animation.spring(response: 0.42, dampingFraction: 0.84)
        /// A dot growing, an edge lighting up, a label arriving. Short: this runs on every
        /// node the pointer crosses.
        static let graphHover = Animation.easeOut(duration: 0.14)
    }

    // MARK: - Meter geometry

    enum Meter {
        /// Total sweep of the needle, centered on vertical.
        static let needleSweep: Angle = .degrees(96)
        /// Where 0 VU sits along the scale, 0...1 — the red zone begins here.
        static let zeroPoint: Double = 0.72
        /// Where a bar meter turns from nominal to hot.
        static let hotPoint: Double = 0.7
        /// Where a bar meter turns from hot to peak.
        static let peakPoint: Double = 0.9
        static let tickMajorInset: CGFloat = 0.78
        static let tickMinorInset: CGFloat = 0.86
        static let needleLength: CGFloat = 0.98
    }

    // MARK: - First run

    /// The first-run window. One question per screen, centred, with nothing else on it —
    /// so its measurements are its own rather than a settings form's, and live together.
    enum Onboarding {
        /// The window. Fixed: every screen is centred in it, and a resizable window would
        /// let one screen's card stretch to a width no other screen's content justifies.
        static let window = CGSize(width: 720, height: 600)
        /// How wide the centred column runs — headline, sentence, card and button.
        static let contentWidth: CGFloat = 460
        /// The tinted symbol above the headline.
        static let icon: CGFloat = 30
        /// Between the icon, the headline and the grey sentence.
        static let headerSpacing: CGFloat = 10
        /// Between the header, the card and the button.
        static let blockSpacing: CGFloat = 26
        /// One permission or setting row inside the card.
        static let rowMinHeight: CGFloat = 44
        /// The primary pill.
        static let pillHeight: CGFloat = 32
        static let pillWidth: CGFloat = 200
        /// The small "Allow" pill at the end of a row.
        static let allowPillWidth: CGFloat = 62
        static let allowPillHeight: CGFloat = 22
        /// A progress dot under the button, and the gap between two of them.
        static let dot: CGFloat = 5
        static let dotSpacing: CGFloat = 6
        /// The back / forward chevrons in the top corner.
        static let chevron: CGFloat = 26
        /// The card's own rows scroll past this rather than growing the window.
        static let listHeight: CGFloat = 180
        /// The setup-progress bar on the assistant screen.
        static let barWidth: CGFloat = 300
        /// How long a user may stare at an ungranted Accessibility toggle before the screen
        /// offers the stale-signature explanation. Long enough to cross to System Settings
        /// and flip a switch; short enough that nobody sits there believing it is broken.
        static let staleGrantHint: TimeInterval = 14
        /// How often the screens re-read a grant while nothing has told them to.
        static let poll: TimeInterval = 1.5
    }

    // MARK: - Fixed site theme (UX-11)

    /// The site's fixed light theme as tokens. Normative spec: `site/DESIGN-SYSTEM.md`
    /// §§1-4,7 (verified against `site/src/index.css` `:root.light`, tracking/leading
    /// scale, `.liquid-glass`, and `site/src/lib/motion.ts` during UX-11).
    ///
    /// Tokens only: adding these changes no rendered surface by itself. Later slices
    /// consume them; no view reads them yet. Existing semantic tokens above (`Color`,
    /// `Font`, `Space`, `Radius`, `Material`, `Motion`) are untouched, so nothing that
    /// renders today moves. Reconciliation of old-vs-new values (e.g. `Font.eyebrowTracking`)
    /// belongs to the slice that paints, not to this foundation.
    ///
    /// Two rules from the spec that bind every consumer:
    /// - Fixed light, set by the app rather than inherited (see `ThemeFixed.apply()`).
    ///   Dark mode and the user's accent colour do not apply in-app.
    /// - Status colour does not exist on the site: red still means recording and meters
    ///   stay instrumentation (`Color.record`, `meterNominal/Hot/Peak`), unchanged.
    enum Theme {

        // MARK: Palette (§1 — `:root.light` HSL triplets, rendered here as sRGB)

        enum Palette {
            /// `0 0% 100%` — page substrate.
            static let background = SwiftUI.Color(red: 1, green: 1, blue: 1)
            /// `0 0% 4%` — ink.
            static let foreground = SwiftUI.Color(red: 10.0 / 255.0, green: 10.0 / 255.0, blue: 10.0 / 255.0)
            /// `0 0% 97%` — card fill.
            static let card = SwiftUI.Color(red: 247.0 / 255.0, green: 247.0 / 255.0, blue: 247.0 / 255.0)
            /// `0 0% 4%` — ink on cards.
            static let cardForeground = foreground
            /// `0 0% 4%` — filled buttons, active pills.
            static let primary = foreground
            /// `0 0% 100%` — ink on filled elements.
            static let primaryForeground = background
            /// `0 0% 92%` — user message bubbles, muted fills.
            static let secondary = SwiftUI.Color(red: 235.0 / 255.0, green: 235.0 / 255.0, blue: 235.0 / 255.0)
            /// `0 0% 25%` — ink on secondary.
            static let secondaryForeground = SwiftUI.Color(red: 64.0 / 255.0, green: 64.0 / 255.0, blue: 64.0 / 255.0)
            /// `0 0% 94%` — quiet fills.
            static let muted = SwiftUI.Color(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 240.0 / 255.0)
            /// `0 0% 40%` — secondary text, captions.
            static let mutedForeground = SwiftUI.Color(red: 102.0 / 255.0, green: 102.0 / 255.0, blue: 102.0 / 255.0)
            /// `170 20% 32%` — sparing highlights. The only chromatic token.
            static let accent = SwiftUI.Color(red: 65.0 / 255.0, green: 98.0 / 255.0, blue: 92.0 / 255.0)
            /// `0 0% 100%` — ink on accent. In the spec's table by omission; present in
            /// `:root.light` as `--accent-foreground`, same value as `primaryForeground`.
            static let accentForeground = background
            /// `0 0% 86%` — hairlines, used at 40–60% opacity (see `Layout`).
            static let border = SwiftUI.Color(red: 219.0 / 255.0, green: 219.0 / 255.0, blue: 219.0 / 255.0)
            /// `0 0% 84%` — field edges. In `:root.light` as `--input`; not in the
            /// spec's table, carried because a text field needs an edge distinct from `border`.
            static let input = SwiftUI.Color(red: 214.0 / 255.0, green: 214.0 / 255.0, blue: 214.0 / 255.0)
            /// `0 0% 60%` — focus rings.
            static let ring = SwiftUI.Color(red: 153.0 / 255.0, green: 153.0 / 255.0, blue: 153.0 / 255.0)
            /// `210 10% 20%` — hero sub-copy.
            static let heroSubtitle = SwiftUI.Color(red: 46.0 / 255.0, green: 51.0 / 255.0, blue: 56.0 / 255.0)
            /// `0 0% 4%` — the ONE orb ink. Depth comes from radius + opacity, never hue.
            static let orbInk = foreground
        }

        // MARK: Type (§2)

        enum Typography {
            /// Bundled theme fonts, registered at launch by `ThemeFixed` (see
            /// `FontResources`). Each helper below uses the real face when its
            /// PostScript name is in `ThemeFixed.registeredPostScriptNames` and
            /// falls back to the system face otherwise — so a missing bundle,
            /// a bare self-test binary, or a failed registration degrades to
            /// legible system type instead of a missing-font pass.
            static func sans(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
                if let name = FontResources.interName(for: weight),
                   ThemeFixed.registeredPostScriptNames.contains(name) {
                    return SwiftUI.Font.custom(name, size: size)
                }
                return SwiftUI.Font.system(size: size, weight: weight)
            }

            /// Inter at a semantic native text style, preserving the existing size
            /// and relative scaling instead of imposing the site's 18pt prose size on
            /// compact controls. Uses the same registered faces as the display helper.
            /// No file read or registration happens here; launch owns both.
            static func sans(
                _ style: SwiftUI.Font.TextStyle,
                weight: SwiftUI.Font.Weight = .regular
            ) -> SwiftUI.Font {
                let nativeStyle: NSFont.TextStyle
                switch style {
                case .largeTitle: nativeStyle = .largeTitle
                case .title: nativeStyle = .title1
                case .title2: nativeStyle = .title2
                case .title3: nativeStyle = .title3
                case .headline: nativeStyle = .headline
                case .subheadline: nativeStyle = .subheadline
                case .body: nativeStyle = .body
                case .callout: nativeStyle = .callout
                case .footnote: nativeStyle = .footnote
                case .caption: nativeStyle = .caption1
                case .caption2: nativeStyle = .caption2
                default:
                    // Unmapped styles retain their native metrics, never a guessed size.
                    return SwiftUI.Font.system(style, weight: weight)
                }
                guard let name = FontResources.interName(for: weight),
                      ThemeFixed.registeredPostScriptNames.contains(name) else {
                    return SwiftUI.Font.system(style, weight: weight)
                }
                let nativeSize = NSFont.preferredFont(forTextStyle: nativeStyle, options: [:]).pointSize
                return SwiftUI.Font.custom(name, size: nativeSize, relativeTo: style)
            }

            /// Instrument Serif 400. Real face when registered, else system serif.
            /// Always an italic span inside an otherwise-sans headline — use
            /// `serifItalic(_:)` for the accent span rather than synthesizing slant.
            static func serif(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
                if ThemeFixed.registeredPostScriptNames.contains(FontResources.instrumentSerifRegular),
                   weight == .regular {
                    return SwiftUI.Font.custom(FontResources.instrumentSerifRegular, size: size)
                }
                return SwiftUI.Font.system(size: size, weight: weight, design: .serif)
            }

            /// The headline accent span: the real InstrumentSerif-Italic face when
            /// registered, else system serif with true italic styling (never a
            /// faux-slanted regular).
            static func serifItalic(_ size: CGFloat) -> SwiftUI.Font {
                if ThemeFixed.registeredPostScriptNames.contains(FontResources.instrumentSerifItalic) {
                    return SwiftUI.Font.custom(FontResources.instrumentSerifItalic, size: size)
                }
                return SwiftUI.Font.system(size: size, design: .serif).italic()
            }

            /// Tracking scale, in points (CSS px == pt on macOS). `caption` is relative:
            /// use `captionTracking(for:)` with the point size.
            static let trackingDisplay: CGFloat = -2
            static let trackingSection: CGFloat = -1.5
            static let trackingHeadline: CGFloat = -1
            static let trackingEyebrow: CGFloat = 3
            static let trackingCaptionFactor: CGFloat = 0.14

            static func captionTracking(for pointSize: CGFloat) -> CGFloat {
                pointSize * trackingCaptionFactor
            }

            /// Leading scale, as multipliers.
            static let leadingDisplay: CGFloat = 1.02
            static let leadingSection: CGFloat = 1.05

            /// Usage-pattern sizes. H1/H2 are ranges (48→96, 36→72) across breakpoints;
            /// a slice picks the size for its surface, never a value outside the range.
            /// Body leading ("relaxed") has no numeric value in the spec — a slice must
            /// not invent one here; the number, when chosen, lands in this enum with its
            /// evidence cited.
            static let eyebrowSize: CGFloat = 12
            static let microSize: CGFloat = 11
            static let buttonSize: CGFloat = 14
            static let bodySize: CGFloat = 18
            static let h1Min: CGFloat = 48
            static let h1Max: CGFloat = 96
            static let h2Min: CGFloat = 36
            static let h2Max: CGFloat = 72

            // MARK: Bundled font resources (UX-11 font plan)

            enum FontResources {
                /// Resource subdirectory inside the app bundle, populated by the
                /// Makefile resource-copy stanza. Absent in bare self-test binaries —
                /// registration then reports every file missing and type stays system.
                static let subdirectory = "ThemeFonts"
                static let interRegular = "Inter-Regular"
                static let interMedium = "Inter-Medium"
                static let interSemiBold = "Inter-SemiBold"
                static let interBold = "Inter-Bold"
                static let instrumentSerifRegular = "InstrumentSerif-Regular"
                static let instrumentSerifItalic = "InstrumentSerif-Italic"

                /// The six bundled files, in PostScript-name form. The UI root owns
                /// the copy; these names must match `Resources/ThemeFonts/*.ttf`
                /// exactly or registration reports them missing (honestly, not silently).
                static let bundledPostScriptNames = [
                    interRegular, interMedium, interSemiBold, interBold,
                    instrumentSerifRegular, instrumentSerifItalic,
                ]

                /// Inter file for a UI weight. Weights outside the four bundled
                /// files (light, black, …) deliberately return nil so callers fall
                /// back to system rather than approximating with a wrong cut.
                static func interName(for weight: SwiftUI.Font.Weight) -> String? {
                    switch weight {
                    case .regular: interRegular
                    case .medium: interMedium
                    case .semibold: interSemiBold
                    case .bold: interBold
                    default: nil
                    }
                }
            }
        }

        // MARK: Layout (§3)

        enum Layout {
            /// Page gutters across breakpoints: 24 → 32 → 64 → 112.
            static let gutterCompact: CGFloat = 24
            static let gutterMedium: CGFloat = 32
            static let gutterLarge: CGFloat = 64
            static let gutterFull: CGFloat = 112
            /// Section rhythm, vertical: 112 → 160.
            static let sectionRhythmMin: CGFloat = 112
            static let sectionRhythmMax: CGFloat = 160
            /// Content width cap; prose caps for wide / mid / narrow measures.
            static let contentMaxWidth: CGFloat = 1280
            static let proseWide: CGFloat = 672
            static let proseMid: CGFloat = 576
            static let proseNarrow: CGFloat = 512
            /// Radii: inner cards 16; panels and hero card 24. Pills and buttons are
            /// fully round — a `Capsule` at the use site, not a number, so there is no
            /// pill-radius token to drift.
            static let radiusInnerCard: CGFloat = 16
            static let radiusPanel: CGFloat = 24
            static let radiusHeroCard: CGFloat = 24
            /// Borders: 1px theme border at 40–60% opacity between regions. Cards carry
            /// their edge via the glass rim (`Glass`), not via border strokes.
            static let borderWidth: CGFloat = 1
            static let borderOpacityLow: Double = 0.4
            static let borderOpacityHigh: Double = 0.6
            /// Primary button: filled ink pill, 28 horizontal × 16 vertical padding,
            /// lifts 3 on hover.
            static let primaryButtonPadH: CGFloat = 28
            static let primaryButtonPadV: CGFloat = 16
            static let primaryButtonHoverLift: CGFloat = 3
        }

        // MARK: Glass (§4 — `liquid-glass`, the one surface treatment)

        enum Glass {
            /// Fill: black at 2% opacity. Backdrop blur 4.
            static let fill = SwiftUI.Color.black.opacity(0.02)
            static let blurRadius: CGFloat = 4
            /// Top/bottom inner highlight at 8%.
            static let highlightOpacity: Double = 0.08
            /// Rim light, not a stroke: 1.4 masked edge, full strength at the top/bottom
            /// lips fading to transparent at 40–60% height, 20% strength with an 8% echo.
            static let rimWidth: CGFloat = 1.4
            static let rimOpacity: Double = 0.2
            static let rimSoftOpacity: Double = 0.08
            static let rimFadeStart: Double = 0.4
            static let rimFadeEnd: Double = 0.6

            /// Swift mapping, per the spec: reproduce with the system glass material
            /// tuned to these values, never a CSS-style gradient stroke. Under Reduce
            /// Transparency: solid theme surfaces (`Palette.card` / `Palette.background`),
            /// never the system material that would break the fixed look.
            /// Closest expressible tuning of the spec's 2% fill + 4px blur: regular
            /// glass with a whisper of ink tint. The `Glass` API exposes no blur or
            /// fill numbers, so this is the approximation, stated as one.
            static let tinted = SwiftUI.Glass.regular.tint(
                Palette.foreground.opacity(0.05))
            /// Solid theme surface under Reduce Transparency (spec rule). Never a
            /// system material here — that would break the fixed look.
            static let solidFallback = Palette.card
        }

        // MARK: Motion (§7)

        enum Motion {
            /// Entrances: fade + 20 rise, 0.6 ease-out, staggered ~0.1 down the page.
            /// Never animate text layout; never move an action button under the pointer;
            /// entrance reveals fire once. Under Reduce Motion: opacity only.
            static let entranceDuration: TimeInterval = 0.6
            static let entranceRise: CGFloat = 20
            static let entranceStagger: TimeInterval = 0.1
            static let entrance = Animation.easeOut(duration: 0.6)

            /// The hero demo's 16s appear → hold → leave loop and its ~46ms/char typing
            /// are storytelling devices, deliberately NOT tokens: production answer text
            /// streams in real chunks, and completed text is never replayed per-character.
        }

        // MARK: Headline sizes (§2 usage patterns)

        enum Headline {
            /// Range midpoints of the spec's H1 48→96 and H2 36→72. A slice picks the
            /// size for its surface from the spec range; these defaults are the middle
            /// of each range, not tuned values. Onboarding H2 uses `sectionSize`.
            static let displaySize: CGFloat = 72
            static let sectionSize: CGFloat = 54
        }

        /// Ambient backdrop from site spec §5; inline marks retain their existing sizes.
        enum Orb {
            static let backdropSize: CGFloat = 560
            static let backdropOpacity: Double = 0.2
        }

        // MARK: Border beam (§6, library defaults where the site is silent)

        enum Beam {
            /// Hairline edge opacity: spec §3 border range midpoint.
            static let edgeOpacity: Double = 0.5
            /// Beam stroke width: site `size "md"`.
            static let lineWidth: CGFloat = 2
            /// Layer opacity class: site `strength 0.7`.
            static let strength: Double = 0.7
            /// Full travel loop: the `border-beam` package default for borders.
            static let period: TimeInterval = 1.96
            /// Comet span: one quarter turn.
            static let arcFraction: Double = 0.25
            /// Glow spread of the blurred copy.
            static let glowRadius: CGFloat = 12
            /// Redraw cadence (ambient class, not display rate).
            static let frameInterval: TimeInterval = 1.0 / 30.0
            /// Parked head under Reduce Motion / paused: top of the card.
            static let stillPhase: Double = -0.25
            /// Colorful-family anchors, tail → head. Preset values (the package's
            /// exact stops are unpublished): blue → violet → pink. No anchor
            /// sustains record red, so a travelling glow can never read as status.
            static let inkA = SwiftUI.Color(red: 59.0 / 255.0, green: 130.0 / 255.0, blue: 246.0 / 255.0)
            static let inkB = SwiftUI.Color(red: 168.0 / 255.0, green: 85.0 / 255.0, blue: 247.0 / 255.0)
            static let inkC = SwiftUI.Color(red: 236.0 / 255.0, green: 72.0 / 255.0, blue: 153.0 / 255.0)
        }

        // MARK: Voice glow (§6, preset defaults)

        enum Voice {
            /// Single theme ink, shared with the beam family (one definition).
            static let ink = Beam.inkB
            /// Master opacity class: site `strength 0.7`.
            static let strength: Double = 0.7
            /// Band thickness on the composer's bottom lip.
            static let edgeHeight: CGFloat = 3
            /// Gathered-beam sweep: the beam line default.
            static let workPeriod: TimeInterval = 2.4
            /// Level-to-shimmer gain: full voice reaches full band.
            static let shimmerGain: Double = 0.75
            /// Quiet edge presence at rest.
            static let idleOpacity: Double = 0.25
            /// Redraw cadence (ambient class, not display rate).
            static let frameInterval: TimeInterval = 1.0 / 30.0
            /// Parked sweep under Reduce Motion / paused.
            static let stillPhase: Double = 0.0
            /// Gathered beam width as a fraction of the edge.
            static let beamFraction: Double = 0.5
        }
    }
}
