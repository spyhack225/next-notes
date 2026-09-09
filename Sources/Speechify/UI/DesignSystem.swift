import SwiftUI

/// The design system for Speechify.
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
        // Text
        static let text = SwiftUI.Color.primary
        static let textSecondary = SwiftUI.Color.secondary
        static let textTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        static let placeholder = SwiftUI.Color(nsColor: .placeholderTextColor)

        // Surfaces
        static let window = SwiftUI.Color(nsColor: .windowBackgroundColor)
        static let content = SwiftUI.Color(nsColor: .controlBackgroundColor)
        static let groupedFill = SwiftUI.Color(nsColor: .quaternarySystemFill)
        static let separator = SwiftUI.Color(nsColor: .separatorColor)
        static let selection = SwiftUI.Color(nsColor: .selectedContentBackgroundColor)

        // Accent
        static let accent = SwiftUI.Color.accentColor
        /// The only red in the app.
        static let record = SwiftUI.Color(nsColor: .systemRed)

        /// The notch island's own substrate.
        ///
        /// The one colour in the app that is a literal rather than a semantic value, and it
        /// is a literal on purpose: while the island hugs the notch it is continuous with
        /// the machine's black bezel, which is the same black in every appearance and every
        /// accent. `islandInk` is what sits on it, for the same reason.
        static let island = SwiftUI.Color.black
        static let islandInk = SwiftUI.Color.white

        // Instrumentation only. Never use these for UI chrome.
        static let meterNominal = SwiftUI.Color(nsColor: .systemGreen)
        static let meterHot = SwiftUI.Color(nsColor: .systemYellow)
        static let meterPeak = SwiftUI.Color(nsColor: .systemRed)
        static let meterTrack = SwiftUI.Color(nsColor: .quaternaryLabelColor)
        static let meterNeedle = SwiftUI.Color.primary

        // Status text and badges
        static let success = SwiftUI.Color(nsColor: .systemGreen)
        static let warning = SwiftUI.Color(nsColor: .systemOrange)
        static let info = SwiftUI.Color.secondary

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

    /// System text styles only, so Dynamic Type and the user's font settings apply.
    enum Font {
        static let largeTitle = SwiftUI.Font.largeTitle
        static let title = SwiftUI.Font.title
        static let title2 = SwiftUI.Font.title2
        static let title3 = SwiftUI.Font.title3
        static let headline = SwiftUI.Font.headline
        static let body = SwiftUI.Font.body
        static let callout = SwiftUI.Font.callout
        static let subheadline = SwiftUI.Font.subheadline
        static let footnote = SwiftUI.Font.footnote
        static let caption = SwiftUI.Font.caption
        static let caption2 = SwiftUI.Font.caption2

        /// Transcript text, in lists and the live view.
        static let transcript = SwiftUI.Font.body
        /// Elapsed-time counters. Rounded so it reads as a display, monospaced digits so
        /// it doesn't jitter as it ticks.
        static let counter = SwiftUI.Font.system(.title2, design: .rounded).monospacedDigit()
        static let counterSmall = SwiftUI.Font.system(.body, design: .rounded).monospacedDigit()
        /// Timestamps beside transcript segments.
        static let timestamp = SwiftUI.Font.system(.caption, design: .monospaced)
        static let notesHeading = SwiftUI.Font.title3.weight(.semibold)
        static let notesSubheading = SwiftUI.Font.headline
        static let chip = SwiftUI.Font.caption.weight(.medium)
        static let sectionLabel = SwiftUI.Font.subheadline.weight(.semibold)
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
    }

    // MARK: - Size

    enum Size {
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

        static let meter = CGSize(width: 160, height: 44)
        static let levelBarHeight: CGFloat = 6
        static let levelBarPeakWidth: CGFloat = 2
        static let recordDot: CGFloat = 10
        static let recordDotCompact: CGFloat = 8
        static let speakerDot: CGFloat = 8
        static let statusDot: CGFloat = 8

        /// The meeting list inside the Meetings section. Narrower than the window's own
        /// sidebar: it is a second list in the same window, and two columns of equal
        /// weight read as a split rather than as a list with a detail beside it.
        static let meetingListMin: CGFloat = 220
        static let meetingListIdeal: CGFloat = 260
        static let meetingDetailMin: CGFloat = 360
        /// Keeps the "You" and "Others" labels above the two live meters aligned.
        static let trackLabelWidth: CGFloat = 56

        /// The full text of a message an agent proposal would send, before it scrolls. Tall
        /// enough to read an email without leaving the card, short enough that two proposals
        /// still fit on screen.
        static let messagePreviewHeight: CGFloat = 140

        /// A determinate progress bar in a detail pane. Wide enough to read as progress,
        /// narrow enough not to read as a divider.
        static let progressWidth: CGFloat = 220

        static let settingsWidth: CGFloat = 560
        static let settingsMinHeight: CGFloat = 420
        /// Text fields in a grouped `Form` stretch to the full row otherwise, which reads
        /// as a text area rather than as one value.
        static let settingsFieldWidth: CGFloat = 260
        /// The Google calendar checklist scrolls past this rather than pushing the rest of
        /// the tab off the window — some accounts subscribe to dozens.
        static let calendarListHeight: CGFloat = 132
        static let sheetWidth: CGFloat = 460
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

        /// The two orb sizes, which are separate tunings rather than one design scaled.
        static let orbInline: CGFloat = 20
        static let orbLarge: CGFloat = 64
    }

    // MARK: - Material

    enum Material {
        static let hud = SwiftUI.Material.ultraThin
        static let card = SwiftUI.Material.regular
        static let hudGlass: Glass = .regular
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
    }

    // MARK: - Shadow

    enum Shadow {
        static let card = Spec(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        static let hud = Spec(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)

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
}
