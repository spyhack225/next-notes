import AppKit
import Foundation
import SwiftUI

/// `--selftest-agent-panes` — the Agent tab row's contract, the sidebar's destinations,
/// and the pane layout rule.
///
/// The switcher is a tab row: one titled tab per pane, in a horizontal scroll. Before it,
/// the toolbar drew a chevron-only pill over an empty popup (a menu-style `Picker` with
/// `labelsHidden()` inside `ToolbarItem(placement: .principal)` has no label to draw
/// there, and the toolbar bridge dropped its items), and the content `Menu` that replaced
/// it named only the current pane. So this pins the naming half — every pane carries a
/// non-empty, unique title the row can draw, and the Reminders pane never borrows Goals'
/// words (or the reverse) — and the drawing half against the hosted row: it must be wider
/// than a label-less control, and at least as wide as all the tab titles side by side.
///
/// The row keeps three tabs — Conversation, Activity, About — and the six panes that used
/// to share it are sidebar destinations of their own. This pins that split: the sidebar
/// draws Agent first and the six between Dictation and Search, each with a title and a
/// mark; and a pane that is both a tab and a row would be two ways to the same place, so
/// the tab list is exactly the three.
///
/// The layout half answers the other visible complaint: every pane capped its content to a
/// ~640pt centred column, so a wide window showed a card floating in empty space. The rule
/// is now `AgentPaneScroll` (full width, adaptive grids and sections), and the old
/// column-cap tokens (`agentAboutMaxWidth` outside the About hero, the removed
/// `agentSkillsMaxWidth`) must not reappear in a pane.
///
/// A value-level test by design: it reads `AgentPane`, `SidebarSection` and the panes' own
/// source files, so it needs no window, no Accessibility grant and no fixtures.
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

        // Exercise the same catalogue lookup the terminal card uses. A failed send or
        // unclassified multi-step run must never get a blind Retry, and a missing artifact
        // is not proof that a write did nothing.
        let failedSend = AgentTask(
            objective: "Send a follow-up", status: .failed, tool: "workspace.send_email",
            failure: "The connection ended before I could confirm the result."
        )
        let sendRisk = AgentWorkingCard.retryRisk(for: failedSend)
        let sendCard = FailureCard.forTask(failedSend, retryRisk: sendRisk, retry: {})
        if sendRisk != .send || sendCard.actions.contains(where: { $0.id == "retry" }) {
            failures.append("a failed send can be retried without checking the effect")
        }
        if sendCard.summary.contains("Nothing was created or sent")
            || sendCard.undo.contains("nothing to undo") {
            failures.append("a failed send without an effect receipt claims nothing changed")
        }
        let unknownTask = AgentTask(
            objective: "Finish several steps", status: .failed,
            failure: "The work stopped."
        )
        let unknownRisk = AgentWorkingCard.retryRisk(for: unknownTask)
        let unknownCard = FailureCard.forTask(unknownTask, retryRisk: unknownRisk, retry: {})
        if unknownRisk != nil || unknownCard.actions.contains(where: { $0.id == "retry" }) {
            failures.append("an unclassified failed task offers a blind retry")
        }

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

        // The split: the row is exactly Conversation, Activity, About, and the six panes
        // that left it are sidebar destinations. A pane in both places is two ways to the
        // same screen; a pane in neither is unreachable.
        let tabs = Set(panes.map(\.rawValue))
        if tabs != ["conversation", "activity", "about"] {
            failures.append("the Agent row lists \(tabs.sorted()) — the layout is "
                            + "Conversation, Activity, About")
        }
        let moved = ["graph", "portrait", "ideas", "goals", "reminders", "skills"]
        let order = SidebarSection.allCases.map(\.rawValue)
        if order.first != "agent" {
            failures.append("Agent is not the first sidebar row")
        }
        for name in moved {
            guard let section = SidebarSection(rawValue: name) else {
                failures.append("\(name) has no sidebar row")
                continue
            }
            if section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("\(name) has no sidebar title")
            }
            if section.systemImage.isEmpty {
                failures.append("\(name) has no sidebar mark")
            }
            guard let index = order.firstIndex(of: name),
                  let dictation = order.firstIndex(of: "dictation"),
                  let search = order.firstIndex(of: "search") else { continue }
            if index < dictation || index > search {
                failures.append("\(name) is not between Dictation and Search in the sidebar")
            }
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

        // The switcher itself, hosted. The tab row draws one titled tab per pane; the
        // toolbar version rendered as a chevron-only circle over an empty popup, and the
        // content menu named only the current pane. Measuring the hosted view is the
        // falsifiable half: a control that shows no text cannot reach
        // `agentSwitcherMinWidth`, and one that names only the selected pane cannot reach
        // the width of every title at once.
        do {
            let host = NSHostingView(rootView: AgentPaneSwitcherBar())
            host.layoutSubtreeIfNeeded()
            let width = host.fittingSize.width
            if width < DS.Size.agentSwitcherMinWidth {
                failures.append("the pane switcher measured \(Int(width))pt "
                                + "(< \(Int(DS.Size.agentSwitcherMinWidth))pt) — it is showing no label")
            }
            var titlesWidth: CGFloat = 0
            for pane in panes {
                let title = NSHostingView(rootView: Text(pane.title).font(DS.Font.callout))
                title.layoutSubtreeIfNeeded()
                titlesWidth += title.fittingSize.width
            }
            if width < titlesWidth {
                failures.append("the pane row measured \(Int(width))pt "
                                + "(< \(Int(titlesWidth))pt for \(panes.count) titles) — "
                                + "it is not drawing every pane's title")
            }
        }

        // The bar's trailing slot, which the Conversation pane's Clear button uses. That
        // button used to be the first row of the history, so a conversation long enough to
        // need clearing had already scrolled the way to clear it out of reach. This pins
        // the half a source scan cannot: the slot draws.
        do {
            let bare = NSHostingView(rootView: AgentPaneSwitcherBar())
            let withAccessory = NSHostingView(rootView: AgentPaneSwitcherBar {
                Button("Clear conversation", systemImage: "trash") {}
            })
            bare.layoutSubtreeIfNeeded()
            withAccessory.layoutSubtreeIfNeeded()
            let growth = withAccessory.fittingSize.width - bare.fittingSize.width
            if growth < DS.Size.agentAvatar {
                failures.append("the pane bar did not draw a trailing accessory "
                                + "(grew \(Int(growth))pt) — the Conversation pane's Clear "
                                + "control would be invisible")
            }
        }

        // P1-20: the composer's one control, and the notice an interrupting send raises.
        for (empty, thinking, expected) in [
            (true, false, ComposerControl.send(enabled: false)),
            (false, false, ComposerControl.send(enabled: true)),
            (false, true, ComposerControl.send(enabled: true)),
            (true, true, ComposerControl.stop),
        ] {
            let got = ComposerControl.state(draftIsEmpty: empty, isThinking: thinking)
            if got != expected {
                failures.append("composer draft=\(empty ? "empty" : "typed") "
                                + "thinking=\(thinking) is \(got), expected \(expected)")
            }
        }
        // The one rule, said as a rule: typing while a turn runs offers Send, not Stop. That is
        // the whole point of the change — a follow-up was previously only sendable by pressing
        // Return, which worked and was invisible.
        if ComposerControl.state(draftIsEmpty: false, isThinking: true).isStop {
            failures.append("typing during a turn offers Stop, so a follow-up cannot be sent")
        }
        // And both states are one size, so the row cannot change width.
        if DS.Size.composerControl.width <= 0 || DS.Size.composerControl.height <= 0 {
            failures.append("the composer's control has no size token")
        }
        // The notice: one sentence, produced only by an interrupting send, and never a message.
        let notice = ComposerNotice.interruptedEarlierRequest(Date())
        if notice.text != "Stopped the earlier request to answer this." {
            failures.append("the interrupting-send notice reads \"\(notice.text)\"")
        }
        for banned in ["interrupt", "cancel", "Agent", "tool", "id:"] where notice.text
            .contains(banned) {
            failures.append("the notice contains \"\(banned)\": \"\(notice.text)\"")
        }
        // A notice is not a message. There is no cast to assert — `ComposerNotice` is an enum
        // and `AgentSession.Message` a struct, so the compiler already forbids one becoming the
        // other — so what is pinned is the *only* way a row reaches the conversation: the view
        // records messages through the session, and nothing about a notice goes near it. That
        // is what keeps it out of the model's history, the knowledge index and `usage.jsonl`.
        if ComposerNotice.interruptedEarlierRequest(notice.at).id != notice.id {
            failures.append("two notices raised at the same instant are not told apart")
        }

        // The draft's storage is a property wrapper, which no runtime check can see: `@State`
        // and `@SceneStorage` are both a `String` by the time anything else runs. So it is read
        // as text — and this is the step-1 finding, which is that the draft **was** `@State` and
        // was therefore lost whenever the view was rebuilt, which is what switching panes does.
        // `if let` rather than `guard … else { } else { }`: Swift's grammar reads the second
        // `else` as a new statement, so that shape does not parse at all. Verified on this
        // toolchain rather than assumed.
        if let view = SourceScan.file("Sources/NextNotes/UI/Agent/AgentView.swift") {
            let draftLine = view.split(separator: "\n")
                .first(where: { $0.contains("agentDraft") })
            if draftLine?.contains("@SceneStorage") != true {
                failures.append("the composer's draft is not kept in @SceneStorage, so it is "
                                + "lost when the pane is rebuilt: "
                                + "\(draftLine.map(String.init) ?? "not found")")
            }
            if view.contains("@State private var draft") {
                failures.append("the composer's draft is still @State as well")
            }
            // And Stop must not clear it. A `draft = ""` inside the stop branch is the bug this
            // rule exists to prevent, and it is invisible to a case that only calls the control.
            // Two things this has to get right, and both were wrong first. Bounded by the
            // composer, not by `send()`: `send()` is *supposed* to clear the draft, and a range
            // that reached it reported a bug that is the intended behaviour. And read from
            // `SourceScan`'s comment-stripped lines, because the Stop branch's own comment names
            // the bug — `no draft = "" here` — and a scan that reads comments fails on it.
            let code = SourceScan.codeLines(of: view).map(\.text).joined(separator: "\n")
            if let stopBranch = code.range(of: "case .stop:"),
               let composerEnd = code.range(of: ".padding(.bottom, DS.Space.m)"),
               stopBranch.lowerBound < composerEnd.lowerBound,
               code[stopBranch.lowerBound..<composerEnd.lowerBound].contains("draft = \"\"") {
                failures.append("the composer's Stop branch clears the draft")
            }
        } else {
            failures.append("could not read AgentView to check where the draft is kept")
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
