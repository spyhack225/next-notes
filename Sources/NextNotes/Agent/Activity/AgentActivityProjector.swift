import Foundation

/// Public titles for the island and sidebar. Never chain-of-thought.
enum AgentActivityProjector {
    static func title(for tool: AgentTool, arguments: [String: String]) -> String {
        let label = firstLabel(in: arguments)
        switch (tool.namespace, tool.name) {
        case (.computer, "inspect_ui"), (.browser, "snapshot"):
            return "Inspecting…"
        case (.computer, "click"), (.browser, "click"):
            return label.isEmpty ? "Clicking…" : "Clicking \(label)"
        case (.computer, "type"), (.computer, "set_text"), (.browser, "fill"):
            return "Typing…"
        case (.computer, "open_app"), (.computer, "focus"):
            return label.isEmpty ? "Opening…" : "Opening \(label)"
        case (.computer, "open_url"), (.browser, "navigate"):
            return "Opening a page…"
        case (.filesystem, "search"):
            return label.isEmpty ? "Searching…" : "Searching \(label)"
        case (.filesystem, "read"):
            return "Reading a file…"
        case (.filesystem, "write"):
            return "Writing a file…"
        case (.shell, "run"):
            return "Running a command…"
        case (.meeting, _):
            return "Reading the meeting…"
        case (.workspace, _):
            return tool.title(for: arguments)
        default:
            let built = tool.title(for: arguments)
            return built.isEmpty ? "Working…" : built
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
        let keys = ["name", "query", "title", "id", "text"]
        for key in keys {
            let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return String(value.prefix(40)) }
        }
        return ""
    }
}
