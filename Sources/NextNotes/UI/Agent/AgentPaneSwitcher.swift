import AppKit
import SwiftUI

/// The Agent pane switcher, in the content area rather than the toolbar.
///
/// This began as a toolbar `Picker`, then a toolbar `Menu`; both rendered as a
/// chevron-only circle over an empty popup on macOS 26 — the toolbar bridge does not
/// draw a menu's text label in `ToolbarItem(placement: .principal)`, so the control
/// said nothing about where you were. A menu in ordinary content draws its label
/// reliably, so the switcher lives in a bar at the top of the pane: the current pane's
/// name is always visible, and choosing another pane is one click.
///
/// `--selftest-agent-panes` hosts this view headlessly and fails if it is narrower
/// than `DS.Size.agentSwitcherMinWidth` — a chevron-only control cannot pass.
struct AgentPaneSwitcherBar: View {
    var navigation: NavigationState = .shared

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Menu {
                ForEach(NavigationState.AgentPane.allCases) { pane in
                    Button {
                        navigation.agentPane = pane
                    } label: {
                        if pane == navigation.agentPane {
                            Label(pane.title, systemImage: "checkmark")
                        } else {
                            Text(pane.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Text(navigation.agentPane.title)
                        .font(DS.Font.headline)
                    Image(systemName: "chevron.down")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose what the Agent shows")
            .accessibilityLabel("Choose what the Agent shows")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.page)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
