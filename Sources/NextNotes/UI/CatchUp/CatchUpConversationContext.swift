import Foundation

@MainActor
extension AgentSession {
    /// A retained background result grounds an ordinary follow-up in this session.
    /// End an idle session BEFORE the result, so recordUser does not orphan it.
    /// Deduplicate by producer identity on the existing rows, never by matching words.
    func recordBackgroundTask(_ text: String, taskID: String) {
        endSessionIfIdle()
        guard !currentSessionMessages.contains(where: {
            $0.contextKind == Self.backgroundTaskContextKind && $0.contextTaskID == taskID
        }) else { return }
        recordAssistant(text, contextKind: Self.backgroundTaskContextKind, contextTaskID: taskID)
    }
}
