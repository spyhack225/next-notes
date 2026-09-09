import SwiftUI

/// The main window's sidebar.
///
/// A live "Recording" row sits above the sections whenever capture is running — dictation
/// or a meeting — so the app says what it is doing even when the section you are looking at
/// has nothing to do with recording. It is deliberately not selectable: it is status, not a
/// destination. One row for both, because only one of them can be running at a time.
struct Sidebar: View {
    @Bindable var controller: DictationController
    @Binding var selection: SidebarSection

    @State private var meetings = MeetingController.shared

    var body: some View {
        List(selection: $selection) {
            if isRecording {
                Section {
                    RecordingIndicator(
                        elapsed: meetings.isRecording ? meetings.elapsed : nil,
                        compact: true,
                        label: meetings.isRecording ? "Meeting" : "Recording"
                    )
                    .padding(.vertical, DS.Space.xxs)
                    .selectionDisabled()
                }
            }

            Section {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
        }
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

    private var isRecording: Bool {
        controller.state.isActive || meetings.isRecording
    }
}
