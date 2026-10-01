import SwiftUI

/// The main window's sidebar.
///
/// A live "Recording" row sits above the sections whenever capture is running — dictation
/// or a meeting — so the app says what it is doing even when the section you are looking at
/// has nothing to do with recording. It is deliberately not selectable: it is status, not a
/// destination. One row for both, because only one of them can be running at a time.
///
/// The column carries the dotted field as its ground, and the live row carries an orb. That
/// is the whole of the landing page's vocabulary a spine has room for: the section rows stay
/// standard `Label`s, because a macOS sidebar is the one place in this app where the
/// system's own idiom cannot be improved on and a house style would only make it stranger.
struct Sidebar: View {
    @Bindable var controller: DictationController
    @Binding var selection: SidebarSection

    @State private var meetings = MeetingController.shared
    @State private var settings = Settings.shared

    var body: some View {
        List(selection: $selection) {
            if isRecording {
                Section {
                    liveRow
                        .padding(.vertical, DS.Space.xxs)
                        .selectionDisabled()
                }
            }

            Section {
                ForEach(visibleSections) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }

            // Settings sits below the group rather than in it: it is a way into the app's
            // own controls, not one of the places dictation and meetings live. The row
            // opens the same Settings view the ⌘, window shows, inside this window.
            Section {
                Label(SidebarSection.settings.title, systemImage: SidebarSection.settings.systemImage)
                    .tag(SidebarSection.settings)
            }
        }
        // Finer than the default step, because the column is a quarter of the window wide:
        // at `DS.Field.spacing` there are barely a dozen columns of lattice to read and it
        // comes out as scattered specks rather than as texture. Heaviest at the top, where
        // the live row and the first section are, so the spine has a head rather than an
        // even wash.
        .dottedField(
            opacity: DS.Opacity.fieldFaint,
            spacing: DS.Field.spacingTight,
            fade: .top
        )
        .navigationSplitViewColumnWidth(
            min: DS.Size.sidebarMin,
            ideal: DS.Size.sidebarIdeal,
            max: DS.Size.sidebarMax
        )
        // The live row pushes the whole section list down as it appears. A spring carries
        // that better than a curve does, and it is the same motion the island uses for the
        // same event.
        .animation(DS.Motion.fluid, value: isRecording)
        .animation(DS.Motion.fluid, value: selection)
    }

    /// The red dot says *that* something is being recorded; the orb beside it says what
    /// kind, exactly as it does in the HUD and on the island.
    ///
    /// It is the only badge-sized orb in the app and it exists only while capture is
    /// running, so it costs nothing on a screen that is idle: at `DS.Size.orbBadge` the
    /// inline tuning draws a few dozen dots, an order of magnitude under a working orb and
    /// two under a backdrop. It runs at full speed rather than an ambient one because it is
    /// naming live work rather than decorating a screen.
    private var liveRow: some View {
        HStack(spacing: DS.Space.s) {
            RecordingIndicator(
                elapsed: meetingIsRecording ? meetings.elapsed : nil,
                compact: true,
                label: meetingIsRecording ? "Meeting" : "Recording"
            )

            Spacer(minLength: DS.Space.xs)

            ThinkingOrb(state: liveState, size: DS.Size.orbBadge)
                .accessibilityHidden(true)
        }
    }

    /// Which of the nine this capture is, read off the same two facts the row's label is.
    ///
    /// A meeting braids two tracks into one transcript, which is `weaving`. A dictation hold
    /// is one voice being heard, which is `listening` — until the key comes up and the wait
    /// stops being about hearing and starts being about text.
    private var liveState: OrbGeometry.State {
        if meetingIsRecording { return .weaving }
        return controller.state == .finishing ? .working : .listening
    }

    /// The sections that get a row. Comparison moved into Settings and the Settings row is
    /// drawn below the group, so neither belongs here; both stay in `allCases` so a stored
    /// raw value keeps decoding. Every module and Search follow the same policy that
    /// resolves restored, requested and live detail selections.
    private var visibleSections: [SidebarSection] {
        ModulePolicy.visibleSections(
            for: Set(AppModule.allCases.filter { settings.isModuleEnabled($0) }),
            knowledgeIndexEnabled: settings.knowledgeIndexEnabled)
    }

    private var meetingIsRecording: Bool {
        settings.isModuleEnabled(.meetings) && meetings.isRecording
    }

    private var dictationIsRecording: Bool {
        settings.isModuleEnabled(.dictation) && controller.state.isActive
    }

    private var isRecording: Bool {
        dictationIsRecording || meetingIsRecording
    }
}
