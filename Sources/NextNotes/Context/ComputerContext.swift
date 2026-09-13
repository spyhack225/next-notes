import AppKit
import Foundation

/// What the user is looking at right now. References, not a dump — the agent asks for
/// detail only when a turn needs it.
struct ComputerContext: Sendable {
    var activeApplication: String
    var activeBundleID: String
    var activeWindow: String
    var selectedText: String?
    var currentURL: String?
    var clipboard: String?
    var recentApplications: [String]
    var projectRoot: String?

    var activeSummary: String {
        var lines = ["App: \(activeApplication)"]
        if !activeBundleID.isEmpty { lines.append("Bundle: \(activeBundleID)") }
        if !activeWindow.isEmpty { lines.append("Window: \(activeWindow)") }
        if let projectRoot { lines.append("Project: \(projectRoot)") }
        if let currentURL { lines.append("URL: \(currentURL)") }
        return lines.joined(separator: "\n")
    }

    var windowSummary: String {
        activeWindow.isEmpty ? "No window title." : activeWindow
    }

    @MainActor
    static var current: ComputerContext {
        let app = NSWorkspace.shared.frontmostApplication
        let clipboard = NSPasteboard.general.string(forType: .string)
        let recent = NSWorkspace.shared.runningApplications
            .compactMap(\.localizedName)
            .uniqued()
            .prefix(8)
        return ComputerContext(
            activeApplication: app?.localizedName ?? "Unknown",
            activeBundleID: app?.bundleIdentifier ?? "",
            activeWindow: ScreenContextStore.shared.captured?.candidates
                .first(where: { $0.kind == .windowTitle })?.text ?? "",
            selectedText: nil,
            currentURL: nil,
            clipboard: clipboard.flatMap { $0.count > 400 ? String($0.prefix(400)) + "…" : $0 },
            recentApplications: Array(recent),
            projectRoot: ScreenContextStore.shared.captured?.projectRoot
        )
    }

    var references: [String] {
        var refs = [AgentContextReference.activeWindow]
        if selectedText != nil { refs.append(AgentContextReference.currentSelection) }
        if projectRoot != nil { refs.append(AgentContextReference.activeProject) }
        return refs
    }
}

struct AgentContext: Sendable {
    var meeting: MeetingContext?
    var computer: ComputerContext
    var references: [String]

    @MainActor
    static var current: AgentContext {
        let computer = ComputerContext.current
        let meeting = MeetingContextStore.shared.current
        var refs = computer.references
        if meeting != nil { refs.insert(AgentContextReference.currentMeeting, at: 0) }
        return AgentContext(meeting: meeting, computer: computer, references: refs)
    }

    /// What the model is told before it asks for more. Deliberately short.
    var promptBlock: String {
        var lines = [
            "Context references: \(references.joined(separator: ", "))",
            "Active app: \(computer.activeApplication)",
        ]
        if let meeting {
            lines.append("Meeting: \(meeting.title)")
            if !meeting.actionItems.isEmpty {
                lines.append("Open action items: \(meeting.actionItems.count)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
