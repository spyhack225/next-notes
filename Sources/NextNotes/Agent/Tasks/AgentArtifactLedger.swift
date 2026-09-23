import Foundation

/// What a run produced — a saved file, a URL opened, a doc id, a receipt summary (P1-5).
///
/// `AgentToolResult` already carries `reference` and `link`; `LocalAgentBackend` folds
/// those into `AgentTaskOutcome.artifacts` for single-tool tasks. This ledger is the
/// same capture for the two paths that used to drop them: nested tool calls inside a
/// task or a tool-loop turn, whose results are reduced to a summary string before the
/// outcome is built. Keyed by task id, last-write-wins per key, folded into the task on
/// completion and into the conversation by the tool loop's completion hook.
///
/// Lock-protected rather than `@MainActor`: the tool loop captures from a background
/// execution closure, and the UI reads from the main actor. A lock serves both.
enum AgentArtifactLedger {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byTask: [String: [String]] = [:]

    /// One artifact, kept with the run that produced it. Duplicates are dropped: a URL
    /// opened twice is one link on the result card.
    static func capture(taskID: String?, artifact: String) {
        let trimmed = artifact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let taskID, !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var list = byTask[taskID] ?? []
        guard !list.contains(trimmed) else { return }
        list.append(trimmed)
        byTask[taskID] = list
    }

    /// Mirrors `LocalAgentBackend`'s fold: the reference and the link are the two
    /// artifact shapes a tool result can carry.
    static func capture(taskID: String?, result: AgentToolResult) {
        if let reference = result.reference {
            capture(taskID: taskID, artifact: reference)
        }
        if let link = result.link {
            capture(taskID: taskID, artifact: link.absoluteString)
        }
    }

    /// Removes and returns the artifacts a run produced, if any.
    static func take(taskID: String?) -> [String] {
        guard let taskID else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return byTask.removeValue(forKey: taskID) ?? []
    }

    static func peek(taskID: String?) -> [String] {
        guard let taskID else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return byTask[taskID] ?? []
    }
}
