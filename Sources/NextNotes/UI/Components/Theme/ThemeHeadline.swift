import SwiftUI

/// The site's headline shape as a native text view (spec §2, UX-11 treatment 1).
///
/// The site sets every display headline in a sans face with exactly one serif-italic
/// accent span inside it — `Be present. *Keep your promises.*` — never a full serif
/// headline and never a standalone serif line. This builder is that pairing: a sans
/// `lead` span plus a serif-italic `accent` span, composed into one `Text` so it stays
/// one accessible element. The emphasis is style-only — the span carries no color of
/// its own, exactly as the site's span sets no color class and inherits the ink.
///
/// Spec → token map (values in `DS.Theme`):
/// - H1 sans medium, display tracking/leading → `Typography.sans(Headline.displaySize,
///   .medium)` + `Typography.trackingDisplay` + leading derived from `Typography.leadingDisplay`.
/// - H2 sans → `Typography.sans(Headline.sectionSize, .medium)` + `Typography.trackingSection`.
/// - Accent span, real serif italic → `Typography.serifItalic(size)` (explicit
///   InstrumentSerif-Italic face when registered, never synthesized slant).
/// - Ink → `DS.Theme.Palette.foreground` (one ink; the serif span differs by style,
///   not color).
///
/// Static type on purpose: entrances (fade + rise, spec §7) belong to the adoption
/// slices over `DS.Theme.Motion` tokens, not to the headline itself. No orb, no avatar,
/// no red: a headline never reports recording state.
struct ThemeHeadline: View {
    /// Which scale the headline is set at. Display is the hero H1 shape; section is
    /// the H2 shape every section header uses.
    enum Level {
        case display
        case section
        /// Compact headline in the existing 460-point onboarding shell.
        case onboarding
        /// Compact static pane headlines in the existing native content floor.
        case pane
    }

    /// The sans span that opens the headline ("Be present.").
    let lead: String
    /// The serif-italic span that closes it ("Keep your promises."). Always italic,
    /// always inside the otherwise-sans headline — never set on its own.
    let accent: String
    var level: Level = .display
    var ink: Color = DS.Theme.Palette.foreground

    var body: some View {
        text
            .tracking(tracking)
            .lineSpacing(lineSpacing)
            .foregroundStyle(ink)
    }

    /// The composed headline as one accessible element.
    var text: Text {
        Text(lead)
            .font(leadFont)
            + Text(Self.wordSeparator)
            .font(leadFont)
            + Text(accent)
            .font(accentFont)
    }

    /// The word space between the two spans. A structural separator, not content:
    /// the words themselves always come from the caller.
    private static let wordSeparator = " "

    private var size: CGFloat {
        switch level {
        case .display: DS.Theme.Headline.displaySize
        case .section: DS.Theme.Headline.sectionSize
        case .onboarding, .pane: DS.Theme.Typography.h2Min
        }
    }

    private var leadFont: Font {
        DS.Theme.Typography.sans(size, weight: .medium)
    }

    private var accentFont: Font {
        DS.Theme.Typography.serifItalic(size)
    }

    private var tracking: CGFloat {
        switch level {
        case .display: DS.Theme.Typography.trackingDisplay
        case .section, .onboarding, .pane: DS.Theme.Typography.trackingSection
        }
    }

    /// Spec leading is a multiplier (1.02/1.05); SwiftUI's `lineSpacing` is extra
    /// points, so the token math lives here rather than as a second number.
    private var lineSpacing: CGFloat {
        switch level {
        case .display: size * (DS.Theme.Typography.leadingDisplay - 1)
        case .section, .onboarding, .pane: size * (DS.Theme.Typography.leadingSection - 1)
        }
    }
}
