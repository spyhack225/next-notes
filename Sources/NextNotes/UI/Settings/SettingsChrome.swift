import AppKit
import SwiftUI

/// The two pieces every Settings pane is built out of: the band at the top of a pane, and
/// the footnote under a section.
///
/// Settings stays grouped `Form`s, because that is what macOS Settings is. What the
/// landing page adds here is the *frame* around them — the eyebrow, the heading and the
/// mark that `site/src` gives every section — and one honest orb wherever a row is waiting
/// on work rather than on the user.

/// A Settings tab: the band that says what it is for, then the form itself.
///
/// The sidebar names the pane in one word; the band says which question the pane answers,
/// which is the thing a list row has nowhere to put. It sits *above* the form rather than
/// inside it, so every row below is still a system-drawn `Form` row and nothing about the
/// grouped style has to be reimplemented.
///
/// The orb here is **still**, always. It is the mark for the pane's subject, not a report on
/// anything in flight: ten canvases turning over a window where nothing is happening is
/// the exact cost the one-animating-orb-per-screen rule exists to prevent, and a pane that
/// does have work running says so on the row the work belongs to.
struct SettingsPane<Content: View>: View {
    let tab: SettingsTab
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            // The form scrolls under this band, so the boundary needs a line. Without one
            // the first section's header slides up under the dotted field and the two
            // textures overlap.
            Divider()
            content()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.orbGap) {
            // The column is reserved whether or not the pane has an orb, so the heading does
            // not step sideways as the user walks the sidebar.
            Group {
                if let orb = tab.orb {
                    ThinkingOrb(state: orb, size: DS.Size.orbSmall, isAnimated: false)
                        .accessibilityHidden(true)
                } else {
                    Color.clear
                }
            }
            .frame(width: DS.Size.orbSmall, height: DS.Size.orbSmall)

            SectionHeading(title: tab.heading, eyebrow: tab.title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.page)
        .padding(.vertical, DS.Space.l)
        // Heaviest against the tab bar and gone by the divider, so the band reads as the
        // top of the page settling into it rather than as a panel stuck on top.
        .dottedField(opacity: DS.Opacity.fieldFaint, fade: .top)
    }
}

/// Pushes the selected pane's name onto the Settings window.
///
/// `SwiftUI.Settings` otherwise keeps "Next Notes Settings" for every pane, which is how
/// a clipped sidebar and a Formatting form can look like they belong to Agent.
struct SettingsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.title = title
        }
    }
}

/// The sentence under a section that qualifies it.
///
/// One component rather than the same font-and-colour pair written out under twenty
/// sections — and the place an orb belongs when the note is reporting on work that is
/// genuinely running, which in Settings is nearly always a model being fetched.
///
/// Deliberately not `LabeledOrb`: that is a status line for a row and sets its title at
/// callout. A footer is caption and secondary, and one that jumped to callout the moment a
/// download started would reflow the section under the pointer.
struct SettingsNote: View {
    let text: String
    /// The work this note is describing, while it is running — `nil` the rest of the time.
    /// An orb still turning over a finished job is a claim the app cannot back up.
    var orb: OrbGeometry.State?

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.orbGap) {
            if let orb {
                ThinkingOrb(state: orb, size: DS.Size.orbBadge)
                    // The sentence beside it already says what is happening; a screen
                    // reader announcing the state twice is the orb's own label leaking out.
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
