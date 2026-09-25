import AppKit
import SwiftUI

/// The Agent tab row: Conversation, Activity, About across the top of the section's content.
///
/// The control has been through four shapes. It began as a toolbar `Picker`, then a
/// toolbar `Menu`; both rendered as a chevron-only circle over an empty popup on
/// macOS 26, because the toolbar bridge does not draw a menu's text label in
/// `ToolbarItem(placement: .principal)`, so the control said nothing about where you
/// were. A menu in ordinary content drew its label but kept the panes behind a click, and
/// the tab row that replaced it listed all nine. The Agent keeps three tabs now: the other
/// six panes are sidebar sections of their own, because they are places to go rather than
/// modes of the conversation.
///
/// Three titles fit almost anywhere, but the row still scrolls horizontally and brings the
/// selected tab into view, so the layout survives a very narrow window. The trailing
/// accessory (the Conversation pane's Clear button, the inspector toggle) sits outside the
/// scroll, so a narrow window scrolls the tabs rather than pushing the accessory off the
/// edge.
///
/// `--selftest-agent-panes` hosts this view headlessly and fails if it is narrower than
/// `DS.Size.agentSwitcherMinWidth` — a chevron-only control cannot pass — and again if
/// it is narrower than every tab's title set side by side, which a control that names
/// only the selected pane cannot pass either.
struct AgentPaneSwitcherBar<Accessory: View>: View {
    var navigation: NavigationState = .shared
    /// A pane's own control, drawn at the trailing edge of the bar.
    ///
    /// The Conversation pane puts Clear here. As the first row of the history it scrolled
    /// away with the history, so the one control that acts on a long conversation could
    /// only be reached from the top of it — the bar is the part of the pane that never
    /// scrolls.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(NavigationState.AgentPane.allCases) { pane in
                            AgentPaneTab(
                                pane: pane,
                                isSelected: pane == navigation.agentPane
                            ) {
                                navigation.agentPane = pane
                            }
                            .id(pane.id)
                        }
                    }
                    .padding(.vertical, DS.Space.xxs)
                }
                // The tabs take the width the accessory leaves. The accessory keeps its
                // own size and stays pinned to the trailing edge however narrow the
                // window gets, because the scroll's minimum width is zero.
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: navigation.agentPane) { _, pane in
                    withAnimation(DS.Motion.standard) { proxy.scrollTo(pane.id) }
                }
                .onAppear {
                    // A pane can be chosen from outside this view — a notification opens
                    // Reminders, a deep link opens About — before the bar is first drawn,
                    // so the first layout scrolls the stored selection into view too.
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(navigation.agentPane.id)
                    }
                }
            }

            accessory()
        }
        .padding(.horizontal, DS.Space.page)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One pane's tab: a real button carrying the pane's own title, accent ink over a faint
/// accent fill while it is the pane on screen, and the app's grouped fill while the
/// pointer is over it.
private struct AgentPaneTab: View {
    let pane: NavigationState.AgentPane
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            Text(pane.title)
                .font(DS.Font.callout)
                .foregroundStyle(isSelected ? DS.Color.accent : DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.xs)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(fill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(pane.title)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { return DS.Color.accent.opacity(DS.Opacity.chipFill) }
        if isHovering { return DS.Color.groupedFill }
        return .clear
    }
}

extension AgentPaneSwitcherBar where Accessory == EmptyView {
    init(navigation: NavigationState = .shared) {
        self.init(navigation: navigation, accessory: { EmptyView() })
    }
}
