import AppKit
import ApplicationServices
import Foundation

/// Local browser automation. Eveclaw drives Chromium in a Vercel sandbox; that is not a
/// local Mac. Here the frontmost browser is inspected through Accessibility and URLs are
/// opened with `NSWorkspace` — navigate → snapshot → element id → click/fill.
enum BrowserToolExecutor {
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
    ]

    @MainActor
    static func run(_ tool: AgentTool, arguments: [String: String]) throws -> AgentToolResult {
        switch tool.name {
        case "navigate", "download":
            return try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.open_url")
                    ?? AgentTool.native(
                        namespace: .computer,
                        name: "open_url",
                        description: "",
                        risk: .modify
                    ),
                arguments: ["url": arguments["url"] ?? ""]
            )
        case "snapshot":
            return AgentToolResult(summary: snapshot())
        case "click":
            return try refLoop(arguments: arguments) { args in
                try ComputerToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "computer.click")
                        ?? AgentTool.native(namespace: .computer, name: "click", description: "", risk: .modify),
                    arguments: args
                )
            }
        case "fill":
            return try refLoop(arguments: arguments) { args in
                try ComputerToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "computer.set_text")
                        ?? AgentTool.native(namespace: .computer, name: "set_text", description: "", risk: .modify),
                    arguments: ["id": args["id"] ?? "", "text": args["text"] ?? ""]
                )
            }
        case "select":
            return try refLoop(arguments: arguments) { args in
                try ComputerToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "computer.set_text")
                        ?? AgentTool.native(namespace: .computer, name: "set_text", description: "", risk: .modify),
                    arguments: ["id": args["id"] ?? "", "text": args["value"] ?? ""]
                )
            }
        default:
            throw AgentError.unknownTool(tool.id)
        }
    }

    /// Eve loop: snapshot → act on an id from that snapshot → snapshot. A stub tree
    /// never invents ids to click.
    @MainActor
    static func refLoop(
        arguments: [String: String],
        act: ([String: String]) throws -> AgentToolResult
    ) throws -> AgentToolResult {
        // Re-capturing here would invalidate the element ids returned to the model by
        // the preceding snapshot call. Compare against that frozen snapshot instead.
        let before = AccessibilitySnapshot.lastSnapshot
        if AccessibilitySnapshot.isStub(before) || before.contains("not a browser") {
            return AgentToolResult(summary: before)
        }
        let id = arguments["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, before.contains(id) else {
            return AgentToolResult(summary: "No snapshot id \(id.isEmpty ? "(missing)" : id). Snapshot first. \(before)")
        }
        let acted = try act(arguments)
        let observedValue = AccessibilitySnapshot.value(of: id)
        let after = snapshot()
        let requestedValue = arguments["text"] ?? arguments["value"]
        let verified: String?
        if let requestedValue {
            verified = observedValue == requestedValue
                ? "Browser field value matches requested text" : nil
        } else {
            let changed = !AccessibilitySnapshot.isStub(after)
                && AccessibilitySnapshot.stableContent(before) != AccessibilitySnapshot.stableContent(after)
            let expectedText = arguments["expectedText"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedURL = arguments["expectedURL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatches = expectedText.flatMap { $0.isEmpty ? nil : $0 }.map {
                after.localizedCaseInsensitiveContains($0)
            } ?? true
            let urlMatches = expectedURL.flatMap { $0.isEmpty ? nil : $0 }.map {
                currentURL() == $0
            } ?? true
            verified = changed
                && (expectedText?.isEmpty == false || expectedURL?.isEmpty == false)
                && textMatches && urlMatches
                ? "Browser page reached the expected post-click state" : nil
        }
        return AgentToolResult(
            summary: "\(acted.summary)\n---\n\(after)", verification: verified
        )
    }

    @MainActor
    private static func snapshot() -> String {
        guard Permissions.hasAccessibility else {
            return "Accessibility is not granted, so the browser cannot be inspected."
        }
        let app = NSWorkspace.shared.frontmostApplication
        guard let app, let bundle = app.bundleIdentifier, browserBundleIDs.contains(bundle) else {
            let name = app?.localizedName ?? "The frontmost app"
            return "\(name) is not a browser. stub tree, 0 names. No elements were invented."
        }
        let body = AccessibilitySnapshot.capture(processID: app.processIdentifier, limit: 80)
        if AccessibilitySnapshot.isStub(body) {
            return "\(app.localizedName ?? "The browser"): \(body)"
        }
        return body
    }

    /// Returns the focused browser document URL for permission scoping when CDP is
    /// unavailable. Accessibility trees expose this on the web area/document node;
    /// the walk is deliberately bounded because it runs before every browser action.
    @MainActor
    static func currentURL() -> String? {
        guard Permissions.hasAccessibility,
              let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier,
              browserBundleIDs.contains(bundle)
        else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success,
              let windowRef
        else { return nil }
        let window = windowRef as! AXUIElement
        return documentURL(in: window, depth: 0)
    }

    private static func documentURL(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        var roleRef: CFTypeRef?
        let hasRole = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRef
        ) == .success
        let role = hasRole ? roleRef as? String : nil
        if role == "AXWebArea" || role == "AXDocument" {
            // Links also expose AXURL. Only a web document's own URL is the
            // domain of the page we are about to inspect or change.
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef) == .success,
               let url = urlRef as? URL, !url.absoluteString.isEmpty {
                return url.absoluteString
            }
            if let url = urlRef as? String, !url.isEmpty { return url }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }
        for child in children.prefix(80) {
            if let url = documentURL(in: child, depth: depth + 1) { return url }
        }
        return nil
    }
}
