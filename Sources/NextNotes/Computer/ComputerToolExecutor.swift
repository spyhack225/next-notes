import AppKit
import ApplicationServices
import Foundation

/// Structured computer control. Accessibility first, screenshots as a last resort —
/// the model clicks an id `inspect_ui` already returned, not a pixel it guessed at,
/// and `screenshot` runs only after a stub tree or with an explicit reason.
enum ComputerToolExecutor {
    private static let inspectLimit = 80

    @MainActor
    static func run(_ tool: AgentTool, arguments: [String: String]) throws -> AgentToolResult {
        switch tool.name {
        case "active_app":
            return AgentToolResult(summary: ComputerContext.current.activeSummary)
        case "windows":
            return AgentToolResult(summary: ComputerContext.current.windowSummary)
        case "inspect_ui":
            return AgentToolResult(summary: inspectUI())
        case "screenshot":
            return try screenshot(reason: arguments["reason"])
        case "get_selection":
            return AgentToolResult(summary: ComputerContext.current.selectedText ?? "Nothing is selected.")
        case "clipboard":
            let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AgentToolResult(summary: text.isEmpty ? "The clipboard is empty." : String(text.prefix(2_000)))
        case "open_app":
            return try openApp(arguments["name"] ?? "")
        case "open_url":
            return try openURL(arguments["url"] ?? "")
        case "focus":
            return try focusApp(arguments["name"] ?? "")
        case "click":
            return try click(
                id: arguments["id"] ?? "",
                expectedText: arguments["expectedText"],
                expectedURL: arguments["expectedURL"]
            )
        case "press_key":
            return try pressKey(arguments["key"] ?? "", modifiers: arguments["modifiers"])
        case "set_text":
            return try setText(id: arguments["id"] ?? "", text: arguments["text"] ?? "")
        case "type":
            return try type(text: arguments["text"] ?? "", id: arguments["id"])
        default:
            throw AgentError.unknownTool(tool.id)
        }
    }

    @MainActor
    private static func openApp(_ name: String) throws -> AgentToolResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentError.missingArgument(name: "name", tool: "computer.open_app")
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed)
            ?? Self.applicationURL(named: trimmed)
        guard let url else {
            throw AgentError.noIntegration("No application named \(trimmed) is installed.")
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return AgentToolResult(summary: "Opened \(url.deletingPathExtension().lastPathComponent).")
    }

    @MainActor
    private static func focusApp(_ name: String) throws -> AgentToolResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.localizedCaseInsensitiveContains(trimmed) == true
                || $0.bundleIdentifier?.localizedCaseInsensitiveContains(trimmed) == true
        }
        guard let app = apps.first else {
            return try openApp(trimmed)
        }
        app.activate()
        return AgentToolResult(summary: "Focused \(app.localizedName ?? trimmed).")
    }

    @MainActor
    private static func openURL(_ raw: String) throws -> AgentToolResult {
        guard let url = URL(string: raw), url.scheme != nil else {
            throw AgentError.missingArgument(name: "url", tool: "computer.open_url")
        }
        NSWorkspace.shared.open(url)
        return AgentToolResult(summary: "Opened \(url.absoluteString).")
    }

    @MainActor
    private static func applicationURL(named name: String) -> URL? {
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        for directory in directories {
            let exact = directory.appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: exact.path) { return exact }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            if let match = children.first(where: {
                $0.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private static func type(text: String, id: String?) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        let target = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if target.isEmpty, AccessibilitySnapshot.firstTextFieldID() == nil {
            _ = inspectUI()
        }
        let resolved = target.isEmpty ? AccessibilitySnapshot.firstTextFieldID() : target
        guard let resolved, !resolved.isEmpty else {
            throw AgentError.missingArgument(name: "id", tool: "computer.type")
        }
        return try setText(id: resolved, text: text)
    }

    @MainActor
    private static func inspectUI() -> String {
        if !Permissions.hasAccessibility {
            _ = Permissions.promptForAccessibility()
        }
        guard Permissions.hasAccessibility else {
            return "Accessibility is not granted, so the window cannot be inspected."
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "No frontmost application."
        }
        let snapshot = AccessibilitySnapshot.capture(processID: app.processIdentifier, limit: inspectLimit)
        if AccessibilitySnapshot.isStub(snapshot) {
            return "\(app.localizedName ?? "The app"): \(snapshot)"
        }
        return snapshot
    }

    @MainActor
    private static func screenshot(reason: String?) throws -> AgentToolResult {
        // Screenshots are a last resort: a stub tree or an explicit reason licenses one,
        // a healthy tree does not. The capture itself is memory-only and needs no
        // consent; uploading it does, and that gate lives with the vision caller.
        guard ScreenshotPolicy.isNeeded(
            snapshotSummary: AccessibilitySnapshot.lastSnapshot, reason: reason
        ) else {
            return AgentToolResult(
                summary: "The accessibility tree already describes this window, so no screenshot was taken. "
                    + "Inspect_ui is enough; pass a reason if pixels are still needed."
            )
        }
        let image = try ScreenCapture.captureFocusedWindowSync()
        ScreenshotStore.store(image, for: "computer.screenshot")
        return AgentToolResult(
            summary: "Screenshot of the focused window "
                + "(\(image.pixelWidth)x\(image.pixelHeight), memory-only, never stored). "
                + "Parked for a vision call; uploading it needs per-run consent."
        )
    }

    @MainActor
    private static func click(id: String, expectedText: String?, expectedURL: String? = nil) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        let expectation = [expectedText, expectedURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        var lastAfter = ""
        func attempt() throws -> VerifyRetry.Attempt {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  AccessibilitySnapshot.lastProcessID == app.processIdentifier else {
                throw AgentError.backendUnavailable("The inspected window is no longer frontmost. Inspect again.")
            }
            let before = AccessibilitySnapshot.lastSnapshot
            try AccessibilitySnapshot.perform(id: id, action: kAXPressAction as String)
            let afterApp = NSWorkspace.shared.frontmostApplication ?? app
            let after = AccessibilitySnapshot.capture(processID: afterApp.processIdentifier, limit: inspectLimit)
            lastAfter = after
            let changed = !AccessibilitySnapshot.isStub(before)
                && !AccessibilitySnapshot.isStub(after)
                && AccessibilitySnapshot.stableContent(before) != AccessibilitySnapshot.stableContent(after)
            let expectedObserved = expectation.map {
                after.localizedCaseInsensitiveContains($0)
            } ?? false
            return VerifyRetry.Attempt(
                summary: "Clicked element \(id).",
                verification: changed && expectedObserved
                    ? "Computer window reached the expected post-click state" : nil
            )
        }
        // No stated postcondition, no retry: there is nothing to check a second attempt
        // against, and re-pressing a control (a toggle, a submit) can undo the first
        // press. The single attempt keeps the previous contract exactly.
        guard let expectation else {
            let single = try attempt()
            return AgentToolResult(summary: single.summary, verification: single.verification)
        }
        let (attempts, mismatch) = try VerifyRetry.run(
            risk: .modify,
            title: "element \(id)",
            expected: expectation,
            observed: { windowTitle(in: lastAfter) ?? "an unchanged window" },
            reinspect: { _ = inspectUI() },
            act: attempt
        )
        var lines = attempts.map(\.summary)
        if attempts.count > 1, lines.count > 1 {
            lines[1] = lines[1] + " (after re-inspecting)"
        }
        if let mismatch { lines.append(mismatch) }
        return AgentToolResult(
            summary: lines.joined(separator: "\n"),
            verification: attempts.last?.verification
        )
    }

    /// The `Window: …` first line of a snapshot, for the mismatch sentence.
    private static func windowTitle(in snapshot: String) -> String? {
        let first = snapshot.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let prefix = "Window: "
        guard first.hasPrefix(prefix) else { return nil }
        let title = first.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    @MainActor
    private static func setText(id: String, text: String) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              AccessibilitySnapshot.lastProcessID == app.processIdentifier else {
            throw AgentError.backendUnavailable("The inspected window is no longer frontmost. Inspect again.")
        }
        try AccessibilitySnapshot.setValue(id: id, text: text)
        let observed = AccessibilitySnapshot.value(of: id)
        return AgentToolResult(
            summary: "Set the text of element \(id).",
            verification: observed == text ? "Computer field value matches requested text" : nil
        )
    }

    @MainActor
    private static func pressKey(_ key: String, modifiers: String?) throws -> AgentToolResult {
        guard Permissions.hasAccessibility else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        try AccessibilitySnapshot.postKey(key, modifiers: WorkspaceTools.list(modifiers))
        return AgentToolResult(summary: "Pressed \(key).")
    }
}
