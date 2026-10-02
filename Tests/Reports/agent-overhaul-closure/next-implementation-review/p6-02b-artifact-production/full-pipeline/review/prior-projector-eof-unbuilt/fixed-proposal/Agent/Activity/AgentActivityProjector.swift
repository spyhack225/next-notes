import AppKit
import Foundation

/// Public titles for the island and sidebar. Never chain-of-thought.
enum AgentActivityProjector {

    static func artifactLabel(_ artifact: AgentArtifact) -> String {
        if let title = artifact.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty, isPublic(title) { return String(title.prefix(160)) }
        return artifact.value
    }
    static func artifactHeading(for task: AgentTask) -> String {
        guard task.status == .completed else { return "Related results" }
        let kinds = task.artifactRecords.map(\.kind)
        if !kinds.isEmpty, kinds.allSatisfy({ ["documentCreated", "documentIDCreated"].contains($0) }) {
            return "What I made"
        }
        if !kinds.isEmpty, kinds.allSatisfy({ ["filePathRead", "fileURLRead", "documentRead", "documentIDRead"].contains($0) }) {
            return "What I read"
        }
        return "Results"
    }
    static func artifactRows(for task: AgentTask) -> [AgentArtifactRow] {
        task.artifactRecords.enumerated().map { ordinal, artifact in
            AgentArtifactRow(taskID: task.id, ordinal: ordinal, artifact: artifact,
                label: artifactLabel(artifact), openURL: artifactURL(artifact))
        }
    }
    private static func artifactURL(_ artifact: AgentArtifact) -> URL? {
        switch artifact.kind {
        case "documentCreated", "documentRead", "webPage":
            guard !artifact.value.contains(where: { $0.isWhitespace }),
                  let url = URL(string: artifact.value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            return url
        case "filePathRead", "filePathSaved":
            guard artifact.value.hasPrefix("/"), !artifact.value.utf8.contains(0) else { return nil }
            return URL(fileURLWithPath: artifact.value)
        case "fileURLRead", "fileURLSaved":
            guard let url = URL(string: artifact.value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { return nil }
            return url
        default: return nil
        }
    }
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
        case (.schedule, "list"):
            return "Checking reminders…"
        case (.schedule, _):
            return "Updating reminders…"
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

struct AgentArtifactRow: Identifiable, Equatable, Sendable {
    let taskID: String
    let ordinal: Int
    let artifact: AgentArtifact
    let label: String
    let openURL: URL?
    var id: String { "\(taskID):\(ordinal)" }
    var valueRole: String {
        switch artifact.kind {
        case "documentIDCreated", "documentIDRead": "Reference"
        case "documentCreated", "documentRead", "webPage": "Link"
        case "filePathRead", "filePathSaved", "fileURLRead", "fileURLSaved": "File location"
        case "receipt": "Action record"
        default: "Details"
        }
    }
    var copyButtonTitle: String {
        switch valueRole {
        case "Reference": "Copy reference"
        case "Link": "Copy link"
        case "File location": "Copy location"
        default: "Copy details"
        }
    }
    var copyAccessibilityLabel: String {
        valueRole == "Link" ? "Copy link to \(label)" : "\(copyButtonTitle) for \(label)"
    }
}
enum AgentArtifactAction: Sendable { case open, copy }

