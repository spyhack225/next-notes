import Foundation

/// Runs a task on this Mac through `AgentToolExecutor`. Immediate tools run here; the
/// conversational loop stays free because `AgentTaskManager` already called us off-turn.
struct LocalAgentBackend: AgentBackend {
    func describe() async -> AgentBackendDescription {
        AgentBackendDescription(
            id: AgentBackendKind.local.rawValue,
            displayName: AgentBackendKind.local.displayName,
            capabilities: ["tools", "filesystem", "shell", "computer", "meeting"]
        )
    }

    func start() async throws {}

    func health() async -> String { "ready" }

    func submit(_ task: AgentTask) async throws -> AgentTaskOutcome {
        guard let tool = task.tool else {
            return .failed(
                "Nothing local can do that. Name a coding agent in Settings ▸ Agent, "
                    + "or ask me to check mail, the calendar, this window, or a file."
            )
        }
        let permissionAlreadyGranted = await MainActor.run {
            AgentTaskManager.shared.consumePermissionApproval(taskID: task.id)
        }
        let result = try await AgentToolExecutor.run(
            tool,
            arguments: task.arguments,
            policy: await MainActor.run { PermissionPolicy.fromSettings() },
            meetingID: task.meetingID,
            taskID: task.id,
            permissionAlreadyGranted: permissionAlreadyGranted
        )
        var artifacts: [String] = []
        if let reference = result.reference { artifacts.append(reference) }
        if let link = result.link { artifacts.append(link.absoluteString) }
        return .completed(result.summary, artifacts: artifacts)
    }

    func status(taskID: String) async -> AgentTaskStatus? {
        await MainActor.run { AgentTaskManager.shared.task(id: taskID)?.status }
    }

    func cancel(taskID: String) async {
        await MainActor.run { AgentTaskManager.shared.cancel(taskID) }
    }

    func respondPermission(taskID: String, approved: Bool) async {
        await MainActor.run { AgentTaskManager.shared.respondPermission(taskID: taskID, approved: approved) }
    }

    func respondInput(taskID: String, text: String) async {
        await MainActor.run { AgentTaskManager.shared.respondInput(taskID: taskID, text: text) }
    }
}
