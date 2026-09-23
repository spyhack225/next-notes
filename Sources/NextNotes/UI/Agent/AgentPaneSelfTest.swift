import AppKit
import Foundation
import SwiftUI

/// `--selftest-agent-panes` — the Agent pane picker's contract, the panes' naming, and the
/// pane layout rule.
///
/// The toolbar used to draw a chevron-only pill over an empty popup: a menu-style `Picker`
/// with `labelsHidden()` inside `ToolbarItem(placement: .principal)` has no label to draw
/// there, and the toolbar bridge dropped its items. So this pins both halves of the fix —
/// every pane carries a non-empty, unique title the control can show, and the Reminders
/// pane never borrows Goals' words (or the reverse).
///
/// The layout half answers the other visible complaint: every pane capped its content to a
/// ~640pt centred column, so a wide window showed a card floating in empty space. The rule
/// is now `AgentPaneScroll` (full width, adaptive grids and sections), and the old
/// column-cap tokens (`agentAboutMaxWidth` outside the About hero, the removed
/// `agentSkillsMaxWidth`) must not reappear in a pane.
///
/// A value-level test by design: it reads `AgentPane` and the panes' own source files, so
/// it needs no window, no Accessibility grant and no fixtures.
@MainActor
enum AgentPaneSelfTest {
    /// Files whose copy belongs to these panes. `UIStringsLint.swift` and this file hold
    /// the rule rather than copy, so they are not scanned.
    private static let copyFiles = [
        "Support/NavigationState.swift",
        "UI/Agent/AgentView.swift",
        "UI/Agent/RoutinesView.swift",
        "UI/Agent/GoalsView.swift",
        "UI/Agent/IdeasView.swift",
        "UI/Agent/PortraitView.swift",
        "UI/Agent/ActivityView.swift",
        "UI/Settings/RemindersSection.swift",
    ]

    /// Every pane that must be laid out on the shared scaffold.
    private static let paneFiles = [
        "UI/Agent/IdeasView.swift",
        "UI/Agent/GoalsView.swift",
        "UI/Agent/RoutinesView.swift",
        "UI/Agent/PortraitView.swift",
        "UI/Agent/ActivityView.swift",
        "UI/Agent/SkillsView.swift",
        "UI/Agent/AgentAboutView.swift",
    ]

    /// The panes this check owns. The others were being relaid in parallel, so until one
    /// contains `AgentPaneScroll` its missing scaffold and leftover column caps are a
    /// `NOTE:` rather than a failure. Once a pane uses the scaffold, the rule binds it —
    /// and these three never get that grace.
    private static let strictPaneFiles: Set<String> = [
        "UI/Agent/IdeasView.swift",
        "UI/Agent/GoalsView.swift",
        "UI/Agent/RoutinesView.swift",
    ]

    /// Column-cap tokens a pane must not keep. `agentAboutMaxWidth` is allowed in
    /// `AgentAboutView.swift` alone, where it caps the hero rather than the pane.
    private static let bannedLayoutTokens = [
        "agentAboutMaxWidth",
        "agentSkillsMaxWidth",
    ]

    /// Files where a banned token is the right token.
    private static let tokenExemptFiles: Set<String> = [
        "UI/Agent/AgentAboutView.swift",
    ]

    /// Words that belong to the other pane: a reminder is what runs and when; a goal is
    /// what you are working toward. Checked inside every literal, not only the four
    /// call sites the UI lint walks, because pane copy is often a continuation fragment.
    private static func namingTokens(in text: String) -> [String] {
        let lowered = text.lowercased()
        return ["routine", "schedule"].filter {
            lowered.range(of: "\\b\($0)s?\\b", options: .regularExpression) != nil
        }
    }

    static func run() -> Bool {
        var failures: [String] = []
        let panes = NavigationState.AgentPane.allCases

        for pane in panes where pane.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("\(pane) has no title for the toolbar to draw")
        }
        var seen = Set<String>()
        for title in panes.map(\.title) where !seen.insert(title).inserted {
            failures.append("“\(title)” titles two panes; the picker would show one of them")
        }
        if !panes.contains(NavigationState.shared.agentPane) {
            failures.append("the pane the app opens on is not in allCases")
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relative in copyFiles {
            let url = root.appendingPathComponent(relative)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                failures.append("cannot read \(relative)")
                continue
            }
            for literal in UIStringsLint.allLiterals(in: source) {
                let tokens = UIStringsLint.forbiddenTokens(in: literal.text)
                    + namingTokens(in: literal.text)
                guard !tokens.isEmpty else { continue }
                failures.append("\(relative):\(literal.line) says "
                                + "\(tokens.joined(separator: ", ")): \(literal.text)")
            }
        }

        // The layout rule: every pane is a full-width `AgentPaneScroll`, and no column-cap
        // token survives in one. Read from source because the rule is what a pane is
        // written as, and a live-view walk would need every pane on screen.
        var notes: [String] = []
        for relative in paneFiles {
            let url = root.appendingPathComponent(relative)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                failures.append("cannot read \(relative)")
                continue
            }
            let relaid = source.contains("AgentPaneScroll")
            let strict = strictPaneFiles.contains(relative)
            if !relaid, !strict {
                notes.append("\(relative): AgentPaneScroll absent — pane not relaid yet")
            } else if !relaid {
                failures.append("\(relative): AgentPaneScroll missing")
                continue
            }
            guard !tokenExemptFiles.contains(relative) else { continue }
            for token in bannedLayoutTokens where source.contains(token) {
                if strict || relaid {
                    failures.append("\(relative): \(token)")
                } else {
                    notes.append("\(relative): \(token) while not yet relaid")
                }
            }
        }

        // The switcher itself, hosted. The toolbar version rendered as a chevron-only
        // circle over an empty popup on macOS 26; a menu in content draws its label.
        // Measuring the hosted view is the falsifiable half: a control that shows no
        // text cannot reach `agentSwitcherMinWidth`.
        do {
            let host = NSHostingView(rootView: AgentPaneSwitcherBar())
            host.layoutSubtreeIfNeeded()
            let width = host.fittingSize.width
            if width < DS.Size.agentSwitcherMinWidth {
                failures.append("the pane switcher measured \(Int(width))pt "
                                + "(< \(Int(DS.Size.agentSwitcherMinWidth))pt) — it is showing no label")
            }
        }

        for note in notes { print("NOTE: \(note)") }
        for failure in failures { print("AGENT_PANES_WRONG: \(failure)") }
        print(failures.isEmpty
              ? "AGENT_PANES_OK: \(panes.count) panes, unique titles, Reminders and Goals say what they are, "
                  + (notes.isEmpty
                     ? "layout on the shared scaffold"
                     : "\(notes.count) layout note(s) — pane(s) not relaid yet (see NOTE)")
              : "AGENT_PANES_FAILED: \(failures.count) problem(s)")
        return failures.isEmpty
    }
}
