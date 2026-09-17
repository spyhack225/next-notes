import AppKit
import Foundation

/// Public titles for the island and sidebar. Never chain-of-thought.
enum AgentActivityProjector {
    @MainActor
    static func title(for tool: AgentTool, arguments: [String: String]) -> String {
        let label = firstLabel(in: arguments)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
            .flatMap { safeLabel($0) }
        switch (tool.namespace, tool.name) {
        case (.computer, "inspect_ui"):
            return app.map { "Looking at \($0)…" } ?? "Looking at the front window…"
        case (.browser, "snapshot"):
            return "Looking at the browser tab…"
        case (.computer, "click"), (.browser, "click"):
            return app.map { "Clicking in \($0)…" } ?? "Clicking…"
        case (.computer, "type"), (.computer, "set_text"), (.browser, "fill"):
            return "Entering text…"
        case (.computer, "open_app"), (.computer, "focus"):
            return label.isEmpty ? "Opening…" : "Opening \(label)"
        case (.computer, "open_url"), (.browser, "navigate"):
            return "Opening a page…"
        case (.filesystem, "search"):
            return label.isEmpty ? "Finding files…" : "Finding files matching “\(label)”…"
        case (.filesystem, "read"):
            return "Reading a file…"
        case (.filesystem, "write"):
            return "Writing a file…"
        case (.shell, "run"):
            return "Running a command…"
        case (.meeting, _):
            return "Reading the meeting…"
        case (.memory, "recall"):
            return "Checking memory…"
        case (.memory, "forget"):
            return "Forgetting…"
        case (.memory, _):
            return "Remembering…"
        case (.workspace, _):
            let built = tool.title(for: arguments)
            return isPublic(built) ? built : "Working in Google Workspace…"
        default:
            return "Working…"
        }
    }

    static func kind(for tool: AgentTool) -> AgentActivityKind {
        switch tool.namespace {
        case .filesystem: return tool.name == "search" ? .searching : .reading
        case .shell: return .executing
        case .computer, .browser: return tool.risk <= .read ? .reading : .executing
        case .meeting, .workspace: return .searching
        default: return .executing
        }
    }

    static func isPublic(_ title: String) -> Bool {
        let lowered = title.lowercased()
        let leaked = ["chain of thought", "secret chain", "i am reasoning", "let's think"]
        return !leaked.contains { lowered.contains($0) }
    }

    private static func firstLabel(in arguments: [String: String]) -> String {
        let keys = ["name", "query", "title"]
        for key in keys {
            let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let label = safeLabel(value) { return label }
        }
        return ""
    }

    private static func safeLabel(_ value: String) -> String? {
        let label = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return label.isEmpty || !isPublic(label) ? nil : label
    }
}
