import Foundation

/// What to walk, and where, for one app.
///
/// There is no generic answer. Cursor's file tree is rows of an outline under a group with a
/// known identifier; VS Code's is the same widget one release apart; a general tree walk
/// finds both plus every tooltip, badge and status-bar segment in the window. A per-bundle
/// table is how Wispr Flow scopes this too — Cursor, Windsurf and VS Code, with VS Code
/// Insiders explicitly excluded — and that is a statement about what was hand-tested, not
/// about what is possible.
struct AXAppAdapter: Sendable, Hashable {
    let bundleID: String
    let displayName: String
    /// Whether this app needs "editor.accessibilitySupport": "on" before its tree contains
    /// anything. True for all three editors, and the reason `stubTree` exists.
    let needsAccessibilitySupportSetting: Bool
    /// AX identifiers of the containers worth descending into. Empty means "the focused
    /// window", which is only ever right for a native app.
    let interestingIdentifiers: Set<String>
    /// AX identifiers never descended into: status bars, notification toasts, the terminal
    /// panel, the settings editor.
    let ignoredIdentifiers: Set<String>
    let maxDepth: Int
    /// What to tell the user when the tree comes back a stub. Surfaced in Settings, not
    /// logged and forgotten.
    let remediation: String?
}

enum AXAppAdapters {
    /// The three editors, keyed by bundle identifier.
    ///
    /// Every identifier in the two sets below is one of VS Code's workbench part ids, which
    /// Cursor and Windsurf inherit because they are forks of it rather than lookalikes. They
    /// are matched as substrings by the harvester, not compared exactly, because the same
    /// part shows up as `workbench.parts.sidebar` in one release and with a suffix in the
    /// next; a substring survives that and an equality test does not.
    ///
    /// What is *not* here is as considered as what is. `com.microsoft.VSCodeInsiders` is
    /// absent deliberately: Insiders ships the workbench a month ahead of stable, so its tree
    /// differs from the one these identifiers were read against, and an adapter for it would
    /// be a guess wearing a table's clothes. Adding an app here is a claim that somebody
    /// opened it, turned the accessibility setting on and watched a harvest come back with
    /// real file names in it — nothing else earns a row.
    static let all: [String: AXAppAdapter] = [
        // The identifier is the one already in `OutputProfileDefaults` for Cursor, which is
        // where it was read off a real installed bundle. It looks like a typo and is not:
        // Cursor ships under a ToDesktop identifier because that is what builds it.
        "com.todesktop.230313mzl4w4u92": AXAppAdapter(
            bundleID: "com.todesktop.230313mzl4w4u92",
            displayName: "Cursor",
            needsAccessibilitySupportSetting: true,
            interestingIdentifiers: editorWorkbenchInteresting,
            ignoredIdentifiers: editorWorkbenchIgnored,
            maxDepth: 12,
            remediation: cursorRemediation
        ),
        "com.exafunction.windsurf": AXAppAdapter(
            bundleID: "com.exafunction.windsurf",
            displayName: "Windsurf",
            needsAccessibilitySupportSetting: true,
            interestingIdentifiers: editorWorkbenchInteresting,
            ignoredIdentifiers: editorWorkbenchIgnored,
            maxDepth: 12,
            remediation: windsurfRemediation
        ),
        "com.microsoft.VSCode": AXAppAdapter(
            bundleID: "com.microsoft.VSCode",
            displayName: "Visual Studio Code",
            needsAccessibilitySupportSetting: true,
            interestingIdentifiers: editorWorkbenchInteresting,
            ignoredIdentifiers: editorWorkbenchIgnored,
            maxDepth: 12,
            remediation: vsCodeRemediation
        ),
    ]

    static func adapter(for bundleID: String) -> AXAppAdapter? { all[bundleID] }

    /// The editor, the file tree and the tab strip — the three regions that hold names the
    /// user says out loud.
    private static let editorWorkbenchInteresting: Set<String> = [
        "workbench.parts.editor",
        "workbench.parts.sidebar",
        "workbench.parts.titlebar",
        "workbench.view.explorer",
        "breadcrumbs",
    ]

    /// Regions skipped whole, and each for a reason worth having in writing.
    ///
    /// The terminal panel and the output view are the important two: they are enormous, they
    /// change every keystroke, and their contents are program output rather than names the
    /// user can refer to — a harvest that spends its node budget there comes back with a
    /// stack trace and no file names. The status bar and the notification toasts are the
    /// cheap two: "Prettier: ✓" and "Do you want to install the recommended extensions?" are
    /// exactly the kind of plausible-looking noise a scoring function cannot reject.
    private static let editorWorkbenchIgnored: Set<String> = [
        "workbench.parts.statusbar",
        "workbench.parts.panel",
        "workbench.parts.activitybar",
        "workbench.parts.banner",
        "workbench.panel.output",
        "workbench.panel.terminal",
        "workbench.panel.repl",
        "workbench.panel.markers",
        "notifications-toasts",
        "notifications-center",
        "workbench.editor.settings2",
    ]

    /// One sentence the user can act on, naming the setting and where it lives.
    ///
    /// Written per app rather than shared because the words on the screen differ — Cursor and
    /// Windsurf both renamed the settings UI — and a remediation that names a menu the app
    /// does not have reads as a bug in Next Notes rather than a setting the user has to flip.
    private static let cursorRemediation = """
        Cursor is not exposing its file tree. In Cursor, open Settings (⌘,), search for \
        "accessibility support" and set Editor: Accessibility Support to "on", then try again.
        """

    private static let windsurfRemediation = """
        Windsurf is not exposing its file tree. In Windsurf, open Settings (⌘,), search for \
        "accessibility support" and set Editor: Accessibility Support to "on", then try again.
        """

    private static let vsCodeRemediation = """
        Visual Studio Code is not exposing its file tree. In Code, open Settings (⌘,), search \
        for "accessibility support" and set Editor: Accessibility Support to "on", then try \
        again.
        """
}
