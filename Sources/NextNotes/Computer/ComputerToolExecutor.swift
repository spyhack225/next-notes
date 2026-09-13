import AppKit
import ApplicationServices
import Foundation

/// Structured computer control. Accessibility first, screenshots never — the model clicks
/// an id `inspect_ui` already returned, not a pixel it guessed at.
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
            return try click(id: arguments["id"] ?? "")
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
    private static func click(id: String) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        try AccessibilitySnapshot.perform(id: id, action: kAXPressAction as String)
        return AgentToolResult(summary: "Clicked element \(id).")
    }

    @MainActor
    private static func setText(id: String, text: String) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        try AccessibilitySnapshot.setValue(id: id, text: text)
        return AgentToolResult(summary: "Set the text of element \(id).")
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
