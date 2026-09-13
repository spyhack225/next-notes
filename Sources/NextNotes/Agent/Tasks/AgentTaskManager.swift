import Foundation
import Observation

/// Owns background work so the realtime conversation can keep going.
@MainActor
@Observable
final class AgentTaskManager {
    static let shared = AgentTaskManager()

    private(set) var tasks: [AgentTask] = []
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]

    private init() {
        tasks = AgentTaskStore.shared.load().map { task in
            var task = task
            if task.status == .running || task.status == .queued {
                task.status = .failed
                task.failure = "Next Notes quit while this task was running."
            }
            return task
        }
    }

    func task(id: String) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    @discardableResult
    func submit(
        objective: String,
        tool: String? = nil,
        arguments: [String: String] = [:],
        contextReferences: [String] = [],
        meetingID: UUID? = nil,
        backend: AgentBackendKind = .local,
        acpCLI: String = "",
        source: String = "user"
    ) -> AgentTask {
        let task = AgentTask(
            objective: objective,
            source: source,
            contextReferences: contextReferences,
            tool: tool,
            arguments: arguments,
            meetingID: meetingID,
            backend: backend.rawValue,
            acpCLI: acpCLI
        )
        tasks.insert(task, at: 0)
        persist()
        AgentActivityStore.shared.begin(task: task, title: objective)
        IslandState.shared.showAgentWork(title: objective)
        running[task.id] = Task { @MainActor [weak self] in
            await self?.execute(task.id)
        }
        return task
    }

    func cancel(_ id: String) {
        running[id]?.cancel()
        running[id] = nil
        update(id) { task in
            task.status = .cancelled
            task.progress = "Cancelled"
        }
        AgentActivityStore.shared.finish(taskID: id, title: "Cancelled")
    }

    func respondPermission(taskID: String, approved: Bool, duration: PermissionDuration = .once) {
        guard var task = task(id: taskID), let tool = task.tool else { return }
        if approved {
            PermissionGrantStore.shared.add(PermissionGrant(
                toolID: tool,
                duration: duration,
                meetingID: task.meetingID,
                taskID: taskID
            ))
            task.status = .queued
            updateRecord(task)
            running[taskID] = Task { @MainActor [weak self] in
                await self?.execute(taskID)
            }
        } else {
            update(taskID) { item in
                item.status = .cancelled
                item.failure = "Permission denied."
            }
        }
    }

    func respondInput(taskID: String, text: String) {
        guard var task = task(id: taskID) else { return }
        task.arguments["input"] = text
        task.status = .queued
        updateRecord(task)
        running[taskID] = Task { @MainActor [weak self] in
            await self?.execute(taskID)
        }
    }

    private func execute(_ id: String) async {
        guard var task = task(id: id) else { return }
        task.status = .running
        task.progress = "Starting…"
        updateRecord(task)

        do {
            let backend = AgentBackendRegistry.shared.backend(named: task.backend)
            let outcome = try await backend.submit(task)
            update(id) { item in
                item.status = outcome.status
                item.progress = outcome.progress
                item.result = outcome.result
                item.artifacts = outcome.artifacts
                item.failure = outcome.failure
            }
            AgentActivityStore.shared.finish(
                taskID: id,
                title: outcome.status == .completed ? (outcome.result ?? "Done") : (outcome.failure ?? "Failed")
            )
            if let result = outcome.result {
                IslandState.shared.showAgentReply(result)
            }
        } catch is CancellationError {
            update(id) { $0.status = .cancelled }
        } catch let error as AgentError {
            if case .needsPermission(let title) = error {
                update(id) { item in
                    item.status = .waitingForPermission
                    item.progress = title
                }
                IslandState.shared.propose(IslandProposal(
                    id: id,
                    title: title,
                    detail: task.objective,
                    meetingID: task.meetingID
                ))
                return
            }
            update(id) { item in
                item.status = .failed
                item.failure = error.localizedDescription
            }
            AgentActivityStore.shared.finish(taskID: id, title: error.localizedDescription)
        } catch {
            update(id) { item in
                item.status = .failed
                item.failure = error.localizedDescription
            }
        }
        running[id] = nil
    }

    private func update(_ id: String, mutate: (inout AgentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
        persist()
    }

    private func updateRecord(_ task: AgentTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        }
        persist()
    }

    private func persist() {
        AgentTaskStore.shared.save(tasks)
    }
}

struct AgentTaskOutcome: Sendable {
    var status: AgentTaskStatus
    var progress: String
    var result: String?
    var artifacts: [String]
    var failure: String?

    static func completed(_ result: String, artifacts: [String] = []) -> AgentTaskOutcome {
        AgentTaskOutcome(status: .completed, progress: "Done", result: result, artifacts: artifacts, failure: nil)
    }

    static func failed(_ reason: String) -> AgentTaskOutcome {
        AgentTaskOutcome(status: .failed, progress: "Failed", result: nil, artifacts: [], failure: reason)
    }
}
