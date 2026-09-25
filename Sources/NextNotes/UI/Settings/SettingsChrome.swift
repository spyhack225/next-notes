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
/// The system sidebar names the pane in one word; the band says which question the pane answers,
/// which is the thing a list row has nowhere to put. It sits *above* the form rather than
/// inside it, so every row below is still a system-drawn `Form` row and nothing about the
/// grouped style has to be reimplemented.
///
/// The orb here is **still**, always. It is the mark for the pane's subject, not a report on
/// anything in flight: ten canvases turning over a window where nothing is happening is
/// the exact cost the one-animating-orb-per-screen rule exists to prevent, and a pane that
/// does have work running says so on the row the work belongs to.
///
/// The pane's `settingsPaneMinWidth` floor lives here rather than on `SettingsWindow`,
/// because this view is the thing both hosts wrap: the standalone window's 800pt minimum
/// leaves it 560, and the main window's detail column leaves it exactly the floor. A
/// minimum larger than that is the clip — see `DS.Size.settingsPaneMinWidth`.
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
                // Every pane's form is the responsive one — see `SettingsFormStyle`.
                // Applied here rather than in each pane so the panes keep writing plain
                // `Form { … }`; a sheet that presents its own `Form` sets
                // `.formStyle(.grouped)` explicitly and keeps it.
                .formStyle(SettingsFormStyle())
        }
        // The floor, not a demand: every host that can show Settings guarantees at least
        // this much pane — the standalone window's 800pt less the system sidebar, and the
        // main window's 560pt detail less the same. Asking for more is how the form used
        // to be drawn past the window's right edge and clipped; asking for exactly this
        // keeps the layout from being squeezed to nothing without ever overreaching.
        .frame(minWidth: DS.Size.settingsPaneMinWidth, maxWidth: .infinity)
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

// MARK: - The responsive grouped form

/// The grouped form every Settings pane is built from — with the width Apple's
/// `GroupedFormStyle` refuses to use.
///
/// macOS 15 changed `GroupedFormStyle` to lay its rows out in a content column that
/// stops at ~744pt and centres the remainder (measured on macOS 27 with an offscreen
/// `NSHostingView`: a 1600pt form drew its rows 684pt wide, 458pt of empty space either
/// side). System Settings does the same thing, and there is no public API to override
/// it — negative `listRowInsets` are ignored, `.formStyle(.columns)` abandons the
/// grouped look entirely, and a hand-built card cannot recover the label/control
/// alignment the grouped style gives every row. So the pane keeps native grouped
/// `Form`s — one per section — and changes only *where width comes from*:
///
/// - the sections of a pane are extracted with `Group(sections:)` (the same container
///   iteration a custom style is allowed), keeping the `Section`/`header`/`footer`
///   syntax every pane already writes;
/// - compact sections flow into an adaptive grid of cards, each card its own native
///   `Form` at `DS.Size.settingsCardMaxWidth` or less, so a card is never wide enough
///   to hit the centring cap;
/// - a section marked `.settingsSectionSpans()` — a table, list or grid that only gets
///   better with room — renders as one full-width card, its rows at the pane's width;
/// - prose footers stay capped at `agentProseMaxWidth`.
///
/// The result is width-adaptive in both directions: the ⌘, window's 560pt pane still
/// gets one column and the same look it has always had, while the same view embedded in
/// a 1600pt window packs its sections into columns and gives a table the whole width.
///
/// Every card's inner `Form` is `.scrollDisabled(true)`: `SettingsFormBody`'s
/// `ScrollView` is the pane's only scrolling surface, because a scroll view nested in a
/// scroll view is the combination the Formatting pane already documents as broken.
struct SettingsFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsFormBody { configuration.content }
    }
}

extension ContainerValues {
    /// Whether a section is table/list/grid content that should span the pane.
    @Entry var settingsSectionSpans: Bool = false
}

extension View {
    /// Marks a section as wide content — a table, a list, an adaptive grid — that should
    /// take the whole pane instead of one card's column. A section of labelled controls
    /// must not carry this: rendered outside `Form`'s row machinery, a `Toggle` puts its
    /// switch beside its label rather than at the trailing edge, which is what the
    /// grouped style is for. Use it where the rows are already full-width content.
    func settingsSectionSpans() -> some View {
        containerValue(\.settingsSectionSpans, true)
    }
}

/// The style's body: one scroll surface, sections in runs of grid cards and wide cards.
///
/// The grid needs no narrow-width clamp of its own: an adaptive column's minimum decides
/// *how many* columns fit, and when the pane is narrower than the minimum the single
/// column takes the pane's width — measured with the pane hosted at
/// `settingsPaneMinWidth` beside the same pane with the minimum pinned at
/// `settingsCardMinWidth`, and the two renders are identical to the pixel. The clipping
/// that was worth fixing was a `frame(minWidth:)` demand, and that is gone.
private struct SettingsFormBody<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            Group(sections: content()) { sections in
                let runs = SettingsSectionRun.runs(Array(sections))
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    ForEach(runs.indices, id: \.self) { index in
                        switch runs[index] {
                        case .cards(let group):
                            LazyVGrid(
                                columns: [GridItem(
                                    .adaptive(
                                        minimum: DS.Size.settingsCardMinWidth,
                                        maximum: DS.Size.settingsCardMaxWidth
                                    ),
                                    spacing: DS.Space.l,
                                    alignment: .top
                                )],
                                // Centred so a lone clamped card (pane wider than one max
                                // card, narrower than two minimums) sits in the pane rather
                                // than against its leading edge with the slack all on one
                                // side. Full rows are unaffected — they already fill.
                                alignment: .center,
                                spacing: DS.Space.l
                            ) {
                                ForEach(group) { section in
                                    SettingsSectionCard(section: section)
                                }
                            }
                        case .spanning(let section):
                            SettingsSpanningSection(section: section)
                        }
                    }
                }
                // No horizontal padding: a native grouped `Form` carries its own ~20pt
                // margins, so adding another would make every row at the ⌘, window's
                // width narrower than it is today. The pane's vertical margins are ours
                // because the forms have no height to give.
                .padding(.vertical, DS.Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Consecutive compact sections grouped so one grid holds them; a spanning section
/// interrupts the grid, so reading order stays the order the pane wrote.
private enum SettingsSectionRun {
    case cards([SectionConfiguration])
    case spanning(SectionConfiguration)

    static func runs(_ sections: [SectionConfiguration]) -> [SettingsSectionRun] {
        var runs: [SettingsSectionRun] = []
        var pending: [SectionConfiguration] = []
        for section in sections {
            if section.containerValues.settingsSectionSpans {
                if !pending.isEmpty {
                    runs.append(.cards(pending))
                    pending = []
                }
                runs.append(.spanning(section))
            } else {
                pending.append(section)
            }
        }
        if !pending.isEmpty { runs.append(.cards(pending)) }
        return runs
    }
}

/// One compact section: a native grouped `Form` at its own card width.
///
/// The extracted section is rebuilt as a `Section` so its header, footer, and every
/// row's grouped row treatment survive; the section's own modifiers (`.disabled`,
/// `.sheet`, lifecycle) are applied by the extraction and still fire.
private struct SettingsSectionCard: View {
    let section: SectionConfiguration

    var body: some View {
        Form {
            Section {
                ForEach(subviews: section.content) { subview in
                    subview
                }
            } header: {
                if !section.header.isEmpty {
                    ForEach(subviews: section.header) { subview in subview }
                }
            } footer: {
                if !section.footer.isEmpty {
                    ForEach(subviews: section.footer) { subview in subview }
                }
            }
        }
        .formStyle(.grouped)
        // One scrolling surface for the whole pane — see `SettingsFormStyle`.
        .scrollDisabled(true)
        // A `Form` is greedy vertically; a grid cell needs its content height.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One wide section: a full-width card whose rows are content rather than controls.
private struct SettingsSpanningSection: View {
    let section: SectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if !section.header.isEmpty {
                ForEach(subviews: section.header) { subview in subview }
                    .font(DS.Font.sectionLabel)
                    .foregroundStyle(DS.Color.textSecondary)
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(subviews: section.content) { subview in
                    subview.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(DS.Space.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DS.Color.groupedFill,
                in: RoundedRectangle(cornerRadius: DS.Radius.card)
            )

            if !section.footer.isEmpty {
                ForEach(subviews: section.footer) { subview in subview }
                    .frame(maxWidth: DS.Size.agentProseMaxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The native cards get this from their `Form`; a spanning card draws its own
        // surface, so it states the same pane margin itself.
        .padding(.horizontal, DS.Space.page)
    }
}

/// Pins the Settings window so it cannot open or be shrunk to sidebar-only.
///
/// `SwiftUI.Settings` on macOS 26 persists a compact inspector frame, and
/// `frame(minWidth:)` on the view does not become `contentMinSize`. The crop
/// that left a Dictation-titled strip of pane names is that frame.
///
/// **The standalone Settings window only.** `SettingsWindow` is embedded in the main
/// window too, and that window declares a larger minimum of its own; an unconditional
/// `contentMinSize =` here would replace the main window's 900×600 with the Settings
/// 800×560 and hand it back the ability to shrink. `pin(_:to:)` therefore raises a
/// window's existing minimum but never lowers it, and `updateNSView` skips the main
/// window outright.
struct SettingsWindowFrame: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // The main window is recognised the same way `AppDelegate.showMainWindow`
            // recognises it: SwiftUI decorates the scene id into the identifier, and the
            // shape is not API, so this is a skip, never a claim. Even if a future OS
            // stops decorating it, `pin` can only raise a minimum, so the main window's
            // own 900×600 survives either way.
            if window.identifier?.rawValue.contains(AppDelegate.mainWindowID) == true { return }
            Self.pin(window, to: minSize)
        }
    }

    /// Raises a window's minimum to `minSize`, never lowers it. A pure function so
    /// `--selftest-settings` can drive it against throwaway windows.
    @MainActor
    static func pin(_ window: NSWindow, to minSize: NSSize) {
        let current = window.contentMinSize
        let pinned = NSSize(
            width: max(current.width, minSize.width),
            height: max(current.height, minSize.height)
        )
        window.contentMinSize = pinned

        let content = window.contentView?.bounds.size ?? .zero
        if content.width + 0.5 < pinned.width || content.height + 0.5 < pinned.height {
            window.setContentSize(NSSize(
                width: max(content.width, pinned.width),
                height: max(content.height, pinned.height)
            ))
        }
    }

    /// What `--selftest-settings` asks of the pin: a window that already has a larger
    /// minimum keeps it, and a window with none is raised to the Settings minimum. Two
    /// throwaway windows, never ordered, so nothing appears on screen. The bug this
    /// pins: the pin used to assign `contentMinSize` outright, which shrank the main
    /// window's 900×600 to the Settings 800×560 when Settings was embedded in it.
    @MainActor
    static func pinFailures() -> [String] {
        var failures: [String] = []

        let sized = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1200, height: 800)),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sized.contentMinSize = NSSize(width: 900, height: 600)
        pin(sized, to: NSSize(width: 800, height: 560))
        if sized.contentMinSize.width != 900 || sized.contentMinSize.height != 600 {
            failures.append(
                "the settings pin overwrote a window's own minimum: "
                    + "\(Int(sized.contentMinSize.width))×\(Int(sized.contentMinSize.height)) "
                    + "instead of keeping 900×600"
            )
        }

        let bare = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 300)),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        bare.contentMinSize = .zero
        pin(bare, to: NSSize(width: 800, height: 560))
        if bare.contentMinSize.width < 800 || bare.contentMinSize.height < 560 {
            failures.append("the settings pin did not raise a window that had no minimum")
        }

        sized.close()
        bare.close()
        return failures
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
