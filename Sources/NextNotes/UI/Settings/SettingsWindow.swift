import AppKit
import SwiftUI

/// Settings, as a system `TabView` of grouped forms.
///
/// The system draws the sidebar (`.sidebarAdaptable`). A hand-rolled `HStack` + `List`
/// looked like the main window; `NavigationSplitView` collapsed to an unlabeled icon
/// and placeholder bars; a toolbar `TabView` in a `settingsWidth` window put
/// Integrations, Models and Permissions behind a chevron that did not list them.
///
/// The **standalone** window's minimum size is sidebar plus form, and it is the window's
/// own (`SettingsWindowFrame.pin`), not this view's: without it macOS 26 opens Settings as
/// a compact inspector — a Dictation-titled strip of names and no pane. This view is also
/// the main window's Settings detail, where sidebar plus form is more than the detail has,
/// so a minimum on the view itself would be a demand the host cannot meet and the form
/// would be drawn clipped past the window's right edge.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    /// The minimum width the host guarantees, when it guarantees one.
    ///
    /// The ⌘, scene pins its window to `settingsWindowMinWidth` (`SettingsWindowFrame`)
    /// and passes it here, so its copy may state that minimum. The main window's detail
    /// column is only `detailMin` wide and passes nothing. The view cannot tell the two
    /// hosts apart for itself, and a minimum in the embedded case is a demand the host
    /// cannot meet — SwiftUI does not shrink it, it draws the form past the window's right
    /// edge and clips it.
    var hostMinimumWidth: CGFloat?

    @State private var models = LocalModelStore.shared
    /// Shared, so that a screen which found the problem can open the pane that fixes it.
    @State private var navigation = NavigationState.shared

    var body: some View {
        TabView(selection: $navigation.selectedSettingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    content(for: tab)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Without this, `.sidebarAdaptable` reserves a "large title" band: the window
        // title floats alone on its own row, the sidebar toggle sits below the traffic
        // lights on a second row, and only then does the sidebar/content start. Inline
        // display keeps the title on the same compact row as the toggle, like System
        // Settings, so the sidebar and each pane's own header start right under it.
        .toolbarTitleDisplayMode(.inline)
        // The host's guarantee, not a wish: `nil` in the main window, where the detail
        // column can be as narrow as `detailMin`. The pane's own floor lives in
        // `SettingsPane`, and every host that can show Settings provides it — see
        // `DS.Size.settingsPaneMinWidth`.
        .frame(minWidth: hostMinimumWidth)
        .frame(minHeight: DS.Size.settingsWindowMinHeight)
        .background(SettingsWindowFrame(minSize: SettingsTab.windowMinSize))
        .onAppear { models.refresh() }
    }

    /// Every tab gets the same band above it, so the ten of them read as one book with
    /// chapters rather than as unrelated forms that happen to share a window.
    private func content(for tab: SettingsTab) -> some View {
        SettingsPane(tab: tab) { Self.pane(for: tab, controller: controller) }
    }

    /// Static so the narrow-width self-test can host any single pane without rebuilding
    /// the `TabView` and its system sidebar around it.
    @ViewBuilder
    static func pane(for tab: SettingsTab, controller: DictationController) -> some View {
        switch tab {
        case .general: GeneralSettingsTab(controller: controller)
        case .dictation: DictationSettingsTab()
        // A view rather than a `<Name>SettingsTab`: it keeps its own scroll, cards and
        // Delete All item, and draws no window title of its own so the pane cannot
        // retitle whichever window is hosting Settings.
        case .comparison: ComparisonView(controller: controller)
        case .formatting: FormattingSettingsTab()
        case .meetings: MeetingsSettingsTab()
        case .calendar: CalendarSettingsTab()
        case .workspace: WorkspaceSettingsTab()
        case .agent: AgentSettingsTab()
        case .computer: ComputerBrowserReadiness()
        case .integrations: IntegrationsSettingsTab()
        case .models: ModelsSettingsTab()
        case .permissions: PermissionsSettingsTab()
        }
    }
}

/// The panes, in the order they appear in the system sidebar.
///
/// Adding one is a case here plus a `<Name>SettingsTab.swift` beside this file, or an
/// existing view as Comparison is; the `TabView` is driven from `allCases`, so nothing
/// else has to change.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case dictation
    case comparison
    case formatting
    case meetings
    case calendar
    case workspace
    case agent
    case computer
    case integrations
    case models
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .comparison: "Comparison"
        case .formatting: "Formatting"
        case .meetings: "Meetings"
        case .calendar: "Calendar"
        case .workspace: "Workspace"
        case .agent: "Agent"
        case .computer: "Computer & browser"
        case .integrations: "Integrations"
        case .models: "Models"
        case .permissions: "Permissions"
        }
    }

    /// The question the pane answers, which is a different thing from its name. The
    /// sidebar already says "Models"; the band says what you came here to settle.
    var heading: String {
        switch self {
        case .general: "The keys you hold"
        case .dictation: "Which engine hears you"
        case .comparison: "How the engines compare on one recording"
        case .formatting: "How the text lands in each app"
        case .meetings: "When a meeting records itself"
        case .calendar: "Where meetings are read from"
        case .workspace: "What Next Notes may do in your account"
        case .agent: "How you wake it and what it may do"
        case .computer: "Whether the agent can act on the Mac and the browser"
        case .integrations: "Other apps it can reach"
        case .models: "Local and cloud models"
        case .permissions: "What macOS has agreed to"
        }
    }

    /// The mark for the pane's subject, from the vocabulary in `AGENTS.md`. Six distinct
    /// states over the panes, and none of them borrowed to fill a hole: Permissions has
    /// none because no state in the vocabulary means "a grant", and inventing one — or
    /// bending `connecting`, which means Google — would cost the table its meaning.
    /// Computer & browser shares that hole: its rows are a grant, a grant macOS refuses
    /// to answer, a detection and a port probe, and no state in the vocabulary means
    /// "ready". Comparison shares it too: no state means "two engines held side by side",
    /// and borrowing `working` — audio being turned into text — would say the pane is
    /// transcribing when it is only showing what already was.
    ///
    /// The rest are read straight off it. `breathing` for General because a push-to-talk
    /// app between holds is exactly present-and-idle; `listening` for Dictation, one voice
    /// being heard; `composing` for Formatting, which is the shape the prose comes out in;
    /// `weaving` for Meetings, two tracks braided into one; `searching` for Calendar, which
    /// reads a diary it did not write to find what is worth recording; `connecting` for
    /// Workspace; `shaping` for Models, fetched and assembled out of nothing.
    var orb: OrbGeometry.State? {
        switch self {
        case .general: .breathing
        case .dictation: .listening
        case .comparison: nil
        case .formatting: .composing
        case .meetings: .weaving
        case .calendar: .searching
        case .workspace: .connecting
        case .agent: .searching
        case .computer: nil
        case .integrations: .connecting
        case .models: .shaping
        case .permissions: nil
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "waveform"
        case .comparison: SidebarSection.comparison.systemImage
        case .formatting: "text.alignleft"
        case .meetings: SidebarSection.meetings.systemImage
        case .calendar: "calendar"
        case .workspace: "point.3.connected.trianglepath.dotted"
        case .agent: "ear"
        case .computer: "cursorarrow.click"
        case .integrations: "link"
        case .models: "shippingbox"
        case .permissions: "lock.shield"
        }
    }

    /// Panes a toolbar overflow hid, and panes a compact Settings frame cropped off.
    /// `--selftest-settings` fails if any drop out of `allCases`.
    static let requiredPanes: [SettingsTab] = [
        .general, .dictation, .comparison, .formatting, .meetings, .calendar, .workspace,
        .agent, .computer, .integrations, .models, .permissions,
    ]

    static var windowMinSize: NSSize {
        NSSize(
            width: DS.Size.settingsWindowMinWidth,
            height: DS.Size.settingsWindowMinHeight
        )
    }

    /// What `--selftest-settings` answers: every pane is listed, Formatting is one of
    /// them, every heading still contains U+0020, letter-spacing is not collapsing
    /// words, each pane's real form can be built, a captured output profile
    /// actually reaches the cleanup prompt, the auto-send policy matches the
    /// four combinations a toggle and an app list can produce, the Settings frame
    /// pin keeps a window's own minimum — a `NavigationSplitView` inside `Settings`
    /// drew ten gray bars instead, and an unused `OutputProfileStore` wrote
    /// `formatting.txt` that dictation never read — and a pane asks for no more width
    /// than the narrowest host that can show it has. The visual side of that last one is
    /// `--settings-sheet`, which renders every pane at the widths it meets.
    @MainActor
    static func catalogFailures() -> [String] {
        var failures: [String] = []

        for pane in requiredPanes where !allCases.contains(pane) {
            failures.append("\(pane.rawValue) is missing from allCases")
        }

        if !allCases.contains(.formatting) {
            failures.append("formatting is missing from allCases")
        }
        if allCases.first(where: { $0 == .formatting })?.title != "Formatting" {
            failures.append("formatting sidebar title is not Formatting")
        }

        if allCases.map(\.title).contains(where: \.isEmpty) {
            failures.append("a sidebar row has an empty title")
        }

        for tab in allCases {
            if spaceCount(in: tab.heading) == 0 {
                failures.append("\(tab.rawValue) heading has no spaces: \(tab.heading.debugDescription)")
            }
            if tab.title.contains("  ") || tab.heading.contains("  ") {
                failures.append("\(tab.rawValue) has a doubled space")
            }
        }

        if spaceCount(in: AgentView.headingTitle) == 0 {
            failures.append("Agent heading has no spaces: \(AgentView.headingTitle.debugDescription)")
        }
        if DS.Font.eyebrowTracking < 0 {
            failures.append("eyebrow tracking \(DS.Font.eyebrowTracking) collapses letters")
        }
        if DS.Font.wordTracking != 0 {
            failures.append("word tracking \(DS.Font.wordTracking) is not the system default")
        }

        if DS.Size.settingsWindowMinWidth < DS.Size.settingsSidebarWidth + DS.Size.settingsWidth {
            failures.append(
                "window min width \(Int(DS.Size.settingsWindowMinWidth))pt is narrower than "
                    + "sidebar \(Int(DS.Size.settingsSidebarWidth))pt plus form "
                    + "\(Int(DS.Size.settingsWidth))pt"
            )
        }

        failures.append(contentsOf: SettingsWindowFrame.pinFailures())

        failures.append(contentsOf: OutputProfileStore.captureFailures())
        failures.append(contentsOf: AutoSendPolicy.selfTestFailures())

        return failures
    }

    /// Hosts `SettingsWindow` on every pane, at its own minimum size. Fails if a body
    /// cannot be built — the skeleton-bar window was a body that never produced the
    /// form. The two width questions are asked next door: `narrowFailures` for a pane
    /// that asks for more than the narrowest host it will meet, and `widthFailures` for
    /// content that does not grow with the window.
    @MainActor
    static func renderFailures(controller: DictationController) -> [String] {
        var failures: [String] = []
        let navigation = NavigationState.shared
        let previous = navigation.selectedSettingsTab
        let size = windowMinSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        for tab in allCases {
            navigation.selectedSettingsTab = tab
            let hosting = NSHostingView(rootView: SettingsWindow(controller: controller))
            hosting.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            if hosting.bounds.isEmpty {
                failures.append("\(tab.rawValue) hosted in an empty frame")
            }
        }

        navigation.selectedSettingsTab = previous
        failures.append(contentsOf: narrowFailures(controller: controller))
        failures.append(contentsOf: widthFailures())
        return failures
    }

    /// The narrow half of the width contract, and the half the screenshots had wrong:
    /// hosted at the least width its window can hand it, a pane must lay out *inside* the
    /// host rather than asking for more and being clipped at the right edge.
    ///
    /// `settingsPaneMinWidth` is the main window's own detail minimum less the system
    /// Settings sidebar, so the embedded copy can genuinely be this narrow when the window
    /// is at 900pt. Every pane is hosted there, and the window as a whole at `detailMin`.
    /// A `frame(minWidth:)` anywhere in the chain — the pane's `settingsWidth`, or the
    /// `TabView`'s `settingsWindowMinWidth` — makes the fitting width exceed the host, and
    /// that is the clip. This has to be a fitting-size question rather than an ink scan:
    /// an offscreen host clips whatever crosses its edge, so a bitmap can never see the
    /// overflow it is supposed to report.
    @MainActor
    static func narrowFailures(controller: DictationController) -> [String] {
        var failures: [String] = []

        let paneWidth = DS.Size.settingsPaneMinWidth
        for tab in allCases {
            let paneView = SettingsPane(tab: tab) {
                SettingsWindow.pane(for: tab, controller: controller)
            }
            let fitting = fittingWidth(of: paneView, proposed: paneWidth)
            SelfTest.diagnostic(String(
                format: "  settings narrow: %@ pane wants %.0fpt in %.0fpt",
                tab.rawValue, fitting, paneWidth
            ))
            if fitting > paneWidth + 0.5 {
                failures.append(
                    "\(tab.rawValue) pane wants \(Int(fitting.rounded()))pt in a "
                        + "\(Int(paneWidth))pt host — it is drawn clipped there"
                )
            }
        }

        // The embedded copy: no host minimum, so it must fit the main window's detail.
        let windowWidth = DS.Size.detailMin
        let fitting = fittingWidth(
            of: SettingsWindow(controller: controller),
            proposed: windowWidth
        )
        SelfTest.diagnostic(String(
            format: "  settings narrow: window wants %.0fpt in %.0fpt",
            fitting, windowWidth
        ))
        if fitting > windowWidth + 0.5 {
            failures.append(
                "settings wants \(Int(fitting.rounded()))pt in the main window's "
                    + "\(Int(windowWidth))pt detail — the sidebar squeezes the pane off"
            )
        }

        // The standalone copy states the window's own minimum — the same value the ⌘,
        // scene pins and `windowResizability(.contentMinSize)` reads — so it must ask for
        // it in a narrower host. Without that, the Settings window could be shrunk to the
        // pane floor and the pinned minimum would be fighting the content's.
        let standalone = fittingWidth(
            of: SettingsWindow(
                controller: controller,
                hostMinimumWidth: DS.Size.settingsWindowMinWidth
            ),
            proposed: windowWidth
        )
        if standalone <= windowWidth + 0.5 {
            failures.append(
                "the standalone settings copy did not state the window's "
                    + "\(Int(DS.Size.settingsWindowMinWidth))pt minimum"
            )
        }

        return failures
    }

    /// What a view asks for when offered `width` — measured rather than assumed. An
    /// `NSHostingView` clips to the frame it is given, so the bitmap cannot answer this;
    /// `NSHostingController.sizeThatFits(in:)` answers with the width the view would lay
    /// out at, which for a `frame(minWidth: 800)` view offered 320 says so. Never ordered.
    @MainActor
    static func fittingWidth(of view: some View, proposed width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(in: NSSize(
            width: width,
            height: DS.Size.settingsWindowMinHeight
        )).width
    }

    /// The width question, answered by pixels: does the Formatting pane's drawn content
    /// grow with the window it is hosted in?
    ///
    /// `GroupedFormStyle` on macOS 15+ lays its rows out in a content column that stops
    /// at ~744pt and centres the rest (measured on macOS 27 with an offscreen
    /// `NSHostingView`: rows 684pt wide in a 1600pt form, 458pt of empty space either
    /// side). So before the responsive form the widest thing this pane drew measured
    /// ~684pt at *any* hosting width — the narrow centred column in the screenshot.
    /// This hosts the pane offscreen at a narrow size and at twice that, scans each
    /// bitmap for the horizontal span of pixels that differ from the pane's own
    /// background, and fails unless the wide span grew by at least one full form width
    /// (`DS.Size.settingsWidth`).
    ///
    /// What it proves: the pane's drawn content responds to the width it is given, and a
    /// regression back to the centred grouped form (or any fixed content cap) fails it.
    /// What it does not prove: that every row or every section stretched, or which one
    /// did — a screenshot is the only thing that answers those. The scan is stride-2 and
    /// classifies a pixel as content when it differs from a sampled corner by more than
    /// a JPEG-grade threshold, so a hairline may be missed; a pane that drew only its
    /// background reads as no content and fails, which is the honest direction.
    ///
    /// The pane is hosted inside its real `SettingsPane`, because that is where the
    /// responsive `Form` style is applied — hosting the bare tab would measure the
    /// system grouped form and fail the app's own layout. The scan skips the top 30% of
    /// the bitmap so the subject band (whose dotted field spans the window at any width)
    /// cannot answer the question by itself.
    @MainActor
    static func widthFailures() -> [String] {
        let narrow = NSSize(
            width: DS.Size.settingsWindowMinWidth,
            height: DS.Size.settingsWindowMinHeight * 2
        )
        let wide = NSSize(width: narrow.width * 2, height: narrow.height)

        let pane = { SettingsPane(tab: .formatting) { FormattingSettingsTab() } }
        guard let narrowInk = inkExtent(of: pane(), size: narrow, below: 0.3),
              let wideInk = inkExtent(of: pane(), size: wide, below: 0.3) else {
            return ["formatting pane drew no measurable content to size"]
        }

        SelfTest.diagnostic(String(
            format: "  settings width: formatting ink %.0fpt at %.0fpt host, %.0fpt at %.0fpt host",
            narrowInk, narrow.width, wideInk, wide.width
        ))

        guard wideInk - narrowInk >= DS.Size.settingsWidth else {
            return [
                "formatting content did not grow with the window: "
                    + "\(Int(narrowInk))pt at \(Int(narrow.width))pt, "
                    + "\(Int(wideInk))pt at \(Int(wide.width))pt"
            ]
        }
        return []
    }

    /// The horizontal span of a view's drawn content, in points, or nil when the bitmap
    /// is empty. Never ordered on screen — `cacheDisplay` renders an offscreen panel.
    /// `below` is the fraction of the height to skip, for panes whose own header band is
    /// full-width furniture rather than content.
    @MainActor
    private static func inkExtent(
        of view: some View,
        size: NSSize,
        below fraction: CGFloat
    ) -> CGFloat? {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
              let data = representation.bitmapData else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)

        let pixelsWide = representation.pixelsWide
        let pixelsHigh = representation.pixelsHigh
        let rowBytes = representation.bytesPerRow
        let samples = representation.samplesPerPixel

        func colour(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * rowBytes + x * samples
            return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
        }
        let background = colour(2, 2)
        var minX = pixelsWide
        var maxX = -1
        for y in stride(from: Int(CGFloat(pixelsHigh) * fraction), to: pixelsHigh, by: 2) {
            for x in stride(from: 0, to: pixelsWide, by: 2) {
                let pixel = colour(x, y)
                if abs(pixel.0 - background.0) > 24
                    || abs(pixel.1 - background.1) > 24
                    || abs(pixel.2 - background.2) > 24 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        let scale = CGFloat(pixelsWide) / max(hosting.bounds.width, 1)
        return CGFloat(maxX - minX) / scale
    }

    static func spaceCount(in string: String) -> Int {
        string.unicodeScalars.filter { $0 == " " }.count
    }
}
