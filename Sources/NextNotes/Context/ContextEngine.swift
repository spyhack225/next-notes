import Foundation

/// The one place the realtime agent asks "what is going on". Returns references first,
/// then the structured records those references name.
enum ContextEngine {
    @MainActor
    static var current: AgentContext { AgentContext.current }

    @MainActor
    static func resolve(_ reference: String) -> String {
        switch reference {
        case AgentContextReference.currentMeeting:
            return MeetingContextStore.shared.current?.summary ?? "No meeting is active."
        case AgentContextReference.activeWindow:
            return ComputerContext.current.activeSummary
        case AgentContextReference.currentSelection:
            return ComputerContext.current.selectedText ?? "Nothing is selected."
        case AgentContextReference.activeProject:
            return ComputerContext.current.projectRoot ?? "No project is in the front window."
        case AgentContextReference.currentFile:
            return ScreenContextStore.shared.captured?.candidates
                .first(where: { $0.kind == .activeTab })?.text ?? "No file is focused."
        default:
            return "Unknown reference \(reference)."
        }
    }
}
