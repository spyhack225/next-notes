import AppKit
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
        let before = snapshot()
        if AccessibilitySnapshot.isStub(before) || before.contains("not a browser") {
            return AgentToolResult(summary: before)
        }
        let id = arguments["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, before.contains(id) else {
            return AgentToolResult(summary: "No snapshot id \(id.isEmpty ? "(missing)" : id). Snapshot first. \(before)")
        }
        let acted = try act(arguments)
        let after = snapshot()
        return AgentToolResult(summary: "\(acted.summary)\n---\n\(after)")
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
}
