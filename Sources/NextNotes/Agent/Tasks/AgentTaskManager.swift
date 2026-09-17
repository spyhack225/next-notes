import Foundation
import Observation

/// Owns background work so the realtime conversation can keep going.
@MainActor
@Observable
final class AgentTaskManager {
    static let shared = AgentTaskManager()

    private(set) var tasks: [AgentTask] = []
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    /// A one-shot approval is intentionally not persisted as a standing grant. Keep the
    /// approval long enough for the exact queued retry to hand it to ActionOrchestrator.
    @ObservationIgnored private var approvedTaskIDs: Set<String> = []
    /// A separate, in-memory one-shot token for the weaker ACP compatibility path.
    /// It is never persisted or represented as a permission grant.
    @ObservationIgnored private var approvedCompatibilityTaskIDs: Set<String> = []

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
        IslandState.shared.showBackgroundAgentWork(title: objective)
        running[task.id] = Task { @MainActor [weak self] in
            await self?.execute(task.id)
        }
        return task
    }

    func beginVoiceObjective(id: UUID, objective: String) {
        let task = AgentTask(id: id.uuidString, objective: objective, source: "voice",
                             status: .running, progress: "Working locally")
        tasks.insert(task, at: 0)
        guard !SelfTest.isRunning else { return }
        persist()
        AgentActivityStore.shared.begin(task: task, title: objective)
        IslandState.shared.showBackgroundAgentWork(title: objective)
    }

    func finishVoiceObjective(id: UUID, result: String) {
        update(id.uuidString) { task in
            task.status = .completed
            task.progress = "Finished"
            task.result = result
        }
        if !SelfTest.isRunning { AgentActivityStore.shared.finish(taskID: id.uuidString, title: result) }
        announce(result)
    }

    func cancelVoiceObjective(id: UUID) {
        update(id.uuidString) { task in
            task.status = .cancelled
            task.progress = "Cancelled"
        }
        if !SelfTest.isRunning { AgentActivityStore.shared.finish(taskID: id.uuidString, title: "Cancelled") }
    }

    func cancel(_ id: String) {
        if let uuid = UUID(uuidString: id),
           VoiceConversationCoordinator.shared.jobs.contains(where: { $0.id == uuid && $0.status == "running" }) {
            VoiceConversationCoordinator.shared.cancel(uuid)
            return
        }
        running[id]?.cancel()
        running[id] = nil
        approvedCompatibilityTaskIDs.remove(id)
        update(id) { task in
            task.status = .cancelled
            task.progress = "Cancelled"
        }
        AgentActivityStore.shared.finish(taskID: id, title: "Cancelled")
    }

    /// Approves exactly one already parked ACP handshake failure. The backend will consume
    /// this token before entering ActionOrchestrator; it cannot authorize another run.
    func approveCompatibilityCLI(taskID: String) {
        guard let task = task(id: taskID),
              task.status == .waitingForCompatibilityCLI,
              ACPCompatibilityCLIBackend.request(for: task) != nil
        else { return }
        approvedCompatibilityTaskIDs.insert(taskID)
        update(taskID) { item in
            item.status = .queued
            item.progress = "Starting compatibility CLI once · weaker progress and permissions than ACP"
        }
        running[taskID]?.cancel()
        running[taskID] = Task { @MainActor [weak self] in
            await self?.execute(taskID)
        }
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
            approvedTaskIDs.insert(taskID)
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

    /// Consumed by the local backend immediately before the exact approved retry fires.
    func consumePermissionApproval(taskID: String) -> Bool {
        approvedTaskIDs.remove(taskID) != nil
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
        guard !Task.isCancelled, task.status != .cancelled else { return }
        task.status = .running
        task.progress = "Starting…"
        updateRecord(task)

        do {
            let outcome: AgentTaskOutcome
            if task.backend == AgentBackendKind.acp.rawValue,
               approvedCompatibilityTaskIDs.remove(id) != nil {
                outcome = try await ACPCompatibilityCLIBackend.submit(task, explicitApproval: true)
            } else {
                let backend = AgentBackendRegistry.shared.backend(named: task.backend)
                outcome = try await backend.submit(task)
            }
            try Task.checkCancellation()
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
                announce(result)
            } else if let failure = outcome.failure {
                announce(failure)
            }
        } catch is CancellationError {
            update(id) { $0.status = .cancelled }
            announce("Cancelled.")
        } catch let error as AgentError {
            if case .acpHandshakeUnavailable(let request) = error {
                update(id) { item in
                    item.status = .waitingForCompatibilityCLI
                    item.progress = "ACP unavailable · compatibility CLI is optional"
                    item.failure = nil
                    item.compatibilityCommand = request.command
                    item.compatibilityCLI = request.cli
                    item.compatibilityDirectory = request.directory
                }
                approvedCompatibilityTaskIDs.remove(id)
                AgentActivityStore.shared.update(
                    taskID: id,
                    kind: .waiting,
                    title: "ACP unavailable",
                    detail: "Compatibility mode requires a one-shot approval and has weaker progress and permissions."
                )
                running[id] = nil
                return
            }
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
            announce(error.localizedDescription)
        } catch {
            update(id) { item in
                item.status = .failed
                item.failure = error.localizedDescription
            }
            announce(error.localizedDescription)
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
        guard !SelfTest.isRunning else { return }
        AgentTaskStore.shared.save(tasks)
    }

    /// Background work used to finish only in the task list. A failure the conversation
    /// never hears is the same shape as a turn that never replied.
    private func announce(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AgentSession.shared.recordAssistant(trimmed)
        AgentAuditLog.shared.record(kind: .reply, title: trimmed)
        IslandState.shared.showBackgroundAgentReply(trimmed)
        VoiceAnnouncementQueue.shared.enqueue(trimmed)
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
