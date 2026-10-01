import Foundation
import Observation

/// Owns background work so the realtime conversation can keep going.
@MainActor
@Observable
final class AgentTaskManager {
    static let shared = AgentTaskManager()

    private(set) var tasks: [AgentTask] = []
    /// A storage failure is visible to diagnostics/UI without claiming both files committed.
    private(set) var lastPersistenceResult: AgentTaskPersistenceResult?
    /// Failed history initialization blocks all record writes and new execution.
    private(set) var historyReadFailure: String?
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    /// A one-shot approval is intentionally not persisted as a standing grant. Keep the
    /// approval long enough for the exact queued retry to hand it to ActionOrchestrator.
    @ObservationIgnored private var approvedTaskIDs: Set<String> = []
    /// A separate, in-memory one-shot token for the weaker ACP compatibility path.
    /// It is never persisted or represented as a permission grant.
    @ObservationIgnored private var approvedCompatibilityTaskIDs: Set<String> = []
    @ObservationIgnored private(set) var backendStartsForTesting = 0
    @ObservationIgnored var backendEntryForTesting: (@MainActor () throws -> Void)?
    @ObservationIgnored private let store: AgentTaskStore
    private var projectsActivity: Bool { !SelfTest.isRunning || !store.allowsHarnessPersistence }

    init(store: AgentTaskStore = .shared) {
        self.store = store
        do { tasks = try store.load() }
        catch {
            historyReadFailure = AgentTaskPersistenceResult.loadFailed.diagnostic
            lastPersistenceResult = .loadFailed
            if let diagnostic = historyReadFailure {
                if SelfTest.isRunning { SelfTest.diagnostic("TASK_HISTORY_FAILED: \(diagnostic)") }
                else { Log.app.error("\(diagnostic, privacy: .public)") }
            }
            return
        }
        let now = Date()
        var events: [TaskJournalEventDraft] = []
        for index in tasks.indices {
            let before = tasks[index]
            guard before.status == .running || before.status == .queued else { continue }
            // The actual typed producer uses text; default and older records use user.
            // Voice/routine/remote/unknown owners keep their interrupted-history baseline.
            let typed = ["user", "text", "selftest"].contains(before.source)
                && before.scheduleID == nil && ["local", "acp"].contains(before.backend)
            if typed {
                let plan = TaskRecoveryPlanner.plan(TaskRecoveryInput(task: before, now: now))
                switch plan.action {
                case .holdForReview:
                    tasks[index].status = .recovering
                    tasks[index].progress = plan.reason
                case .reportFailed:
                    tasks[index].status = .failed
                    tasks[index].failure = plan.reason
                case .noAction, .restoreCard: continue
                }
            } else {
                tasks[index].status = .failed
                tasks[index].failure = "Next Notes quit while this task was running."
            }
            events += transitionEvents(from: before, to: tasks[index], kinds: [])
        }
        if !events.isEmpty { persist(events: events) }
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
        var task = AgentTask(
            objective: objective,
            source: source,
            contextReferences: contextReferences,
            tool: tool,
            arguments: arguments,
            meetingID: meetingID,
            backend: backend.rawValue,
            acpCLI: acpCLI
        )
        guard historyReadFailure == nil else {
            task.status = .failed
            task.failure = historyReadFailure
            return task // Not inserted, persisted, presented as working or dispatched.
        }
        tasks.insert(task, at: 0)
        let admission = persist(events: creationEvents(task))
        guard admission.primaryCommitted else {
            tasks.removeAll { $0.id == task.id }
            task.status = .failed
            task.failure = admission.diagnostic
            return task
        }
        if projectsActivity {
            AgentActivityStore.shared.begin(task: task, title: objective)
            IslandState.shared.showBackgroundAgentWork(title: objective)
        }
        running[task.id] = Task { @MainActor [weak self] in
            await self?.execute(task.id)
        }
        return task
    }

    /// A routine run (Part 3): a fresh task with source `"scheduled"` and its schedule id.
    /// `ScheduledRunner` executes it; this only keeps the record, so it shows with the other
    /// tasks. It is never announced into the conversation — a routine delivers through its
    /// own notification — and never handed to a backend.
    func beginScheduledRun(_ task: AgentTask) {
        guard historyReadFailure == nil else { return }
        tasks.insert(task, at: 0)
        persist(events: creationEvents(task))
        guard !SelfTest.isRunning else { return }
        AgentActivityStore.shared.begin(task: task, title: task.objective)
        IslandState.shared.showBackgroundAgentWork(title: task.objective)
    }

    func finishScheduledRun(id: String, status: AgentTaskStatus, result: String?, failure: String?) {
        update(id) { task in
            task.status = status
            task.progress = status == .completed ? "Finished" : "Failed"
            task.result = result
            task.failure = failure
        }
        guard !SelfTest.isRunning else { return }
        AgentActivityStore.shared.finish(taskID: id, title: result ?? failure ?? "Finished")
    }

    func beginVoiceObjective(id: UUID, objective: String) {
        guard historyReadFailure == nil else { return }
        let task = AgentTask(id: id.uuidString, objective: objective, source: "voice",
                             status: .running, progress: "Working locally")
        tasks.insert(task, at: 0)
        persist(events: creationEvents(task))
        guard !SelfTest.isRunning else { return }
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
        guard historyReadFailure == nil else { return }
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
        guard historyReadFailure == nil else { return }
        guard let task = task(id: taskID),
              task.status == .waitingForCompatibilityCLI,
              ACPCompatibilityCLIBackend.request(for: task) != nil
        else { return }
        approvedCompatibilityTaskIDs.insert(taskID)
        let admitted = update(taskID, kinds: [.permissionApproved]) { item in
            item.status = .queued
            item.progress = "Starting compatibility CLI once · weaker progress and permissions than ACP"
        }
        guard admitted.primaryCommitted else { rejectStart(taskID, result: admitted); return }
        running[taskID]?.cancel()
        running[taskID] = Task { @MainActor [weak self] in
            await self?.execute(taskID)
        }
    }

    func respondPermission(taskID: String, approved: Bool, duration: PermissionDuration = .once) {
        guard historyReadFailure == nil else { return }
        guard var task = task(id: taskID), task.status == .waitingForPermission,
              let tool = task.tool else { return }
        if approved {
            task.status = .queued
            let admitted = updateRecord(task, kinds: [.permissionApproved])
            guard admitted.primaryCommitted else { rejectStart(taskID, result: admitted); return }
            // The durable approval transition must commit before a new reusable grant.
            PermissionGrantStore.shared.add(PermissionGrant(
                toolID: tool, duration: duration, meetingID: task.meetingID, taskID: taskID
            ))
            approvedTaskIDs.insert(taskID)
            running[taskID] = Task { @MainActor [weak self] in
                await self?.execute(taskID)
            }
        } else {
            update(taskID, kinds: [.permissionDenied]) { item in
                item.status = .cancelled
                item.failure = "Permission denied."
            }
        }
    }

    /// Consumed by the local backend immediately before the exact approved retry fires.
    func hasCompatibilityApprovalForTesting(taskID: String) -> Bool {
        SelfTest.isRunning && store.allowsHarnessPersistence && approvedCompatibilityTaskIDs.contains(taskID)
    }

    func consumePermissionApproval(taskID: String) -> Bool {
        approvedTaskIDs.remove(taskID) != nil
    }

    func respondInput(taskID: String, text: String) {
        guard historyReadFailure == nil else { return }
        guard var task = task(id: taskID), task.status == .waitingForInput else { return }
        task.arguments["input"] = text
        task.status = .queued
        let admitted = updateRecord(task, kinds: [.inputProvided])
        guard admitted.primaryCommitted else { rejectStart(taskID, result: admitted); return }
        running[taskID] = Task { @MainActor [weak self] in
            await self?.execute(taskID)
        }
    }

    private func execute(_ id: String) async {
        guard historyReadFailure == nil else { return }
        guard var task = task(id: id) else { return }
        guard !Task.isCancelled, task.status == .queued else { return }
        task.status = .running
        task.progress = "Starting…"
        let started = updateRecord(task)
        guard started.primaryCommitted else { rejectStart(id, result: started); return }

        do {
            let outcome: AgentTaskOutcome
            outcome = try await TaskEventJournal.$current.withValue(journalContext(taskID: id)) {
                if SelfTest.isRunning && store.allowsHarnessPersistence {
                    backendStartsForTesting += 1
                    try backendEntryForTesting?()
                }
                if task.backend == AgentBackendKind.acp.rawValue,
                   approvedCompatibilityTaskIDs.remove(id) != nil {
                    return try await ACPCompatibilityCLIBackend.submit(task, explicitApproval: true)
                } else {
                    let backend = AgentBackendRegistry.shared.backend(named: task.backend)
                    return try await backend.submit(task)
                }
            }
            try Task.checkCancellation()
            // P1-5: nested tool calls park their reference and link on the ledger; fold
            // them in beside whatever the backend itself returned, and keep them on the
            // task so the terminal card can link them after a relaunch.
            let captured = AgentArtifactLedger.take(taskID: id)
            update(id) { item in
                item.status = outcome.status
                item.progress = outcome.progress
                item.result = outcome.result
                item.artifacts = outcome.artifacts + captured.filter { !outcome.artifacts.contains($0) }
                item.failure = outcome.failure
            }
            if projectsActivity { AgentActivityStore.shared.finish(
                taskID: id,
                title: outcome.status == .completed ? (outcome.result ?? "Done") : (outcome.failure ?? "Failed")
            ) }
            if let result = outcome.result {
                announce(result)
            } else if let failure = outcome.failure {
                announce(failure)
            }
            announceArtifacts(taskID: id)
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
                if projectsActivity { AgentActivityStore.shared.update(
                    taskID: id,
                    kind: .waiting,
                    title: "ACP unavailable",
                    detail: "Compatibility mode requires a one-shot approval and has weaker progress and permissions."
                ) }
                running[id] = nil
                return
            }
            if case .needsPermission(let title) = error {
                update(id) { item in
                    item.status = .waitingForPermission
                    item.progress = title
                }
                if projectsActivity { IslandState.shared.propose(IslandProposal(
                    id: id,
                    title: title,
                    detail: task.objective,
                    meetingID: task.meetingID
                )) }
                return
            }
            update(id) { item in
                item.status = .failed
                item.failure = error.localizedDescription
            }
            if projectsActivity { AgentActivityStore.shared.finish(taskID: id, title: error.localizedDescription) }
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

    @discardableResult
    private func update(_ id: String, kinds: [TaskEventKind] = [], mutate: (inout AgentTask) -> Void) -> AgentTaskPersistenceResult {
        guard historyReadFailure == nil else { return .loadFailed }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return .loadFailed }
        let before = tasks[index]
        mutate(&tasks[index])
        return persist(events: transitionEvents(from: before, to: tasks[index], kinds: kinds))
    }

    @discardableResult
    private func updateRecord(_ task: AgentTask, kinds: [TaskEventKind] = []) -> AgentTaskPersistenceResult {
        update(task.id, kinds: kinds) { $0 = task }
    }

    private func rejectStart(_ id: String, result: AgentTaskPersistenceResult) {
        // One-shot approvals cannot survive a rejected admission/start as a later grant.
        approvedTaskIDs.remove(id)
        approvedCompatibilityTaskIDs.remove(id)
        running[id] = nil
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].status = .failed
            tasks[index].failure = result.diagnostic
        }
        if projectsActivity { AgentActivityStore.shared.finish(taskID: id, title: result.diagnostic ?? "Could not start") }
        if let diagnostic = result.diagnostic { announce(diagnostic) }
    }

    private func creationEvents(_ task: AgentTask) -> [TaskJournalEventDraft] {
        let attempt = task.durability?.attempt ?? 0
        var events = [TaskJournalEventDraft(taskID: task.id, kind: .jobCreated, attempt: attempt)]
        // A scheduled/voice producer can hand us work already started; no invented
        // terminal event for an imported completed history row.
        if task.status == .running { events.append(TaskJournalEventDraft(taskID: task.id, kind: .workerStarted, attempt: attempt)) }
        return events
    }

    private func transitionEvents(from before: AgentTask, to task: AgentTask,
                                  kinds: [TaskEventKind]) -> [TaskJournalEventDraft] {
        var result = kinds
        if task.status != before.status {
            switch task.status {
            case .running: result.append(.workerStarted)
            case .recovering: result.append(.recoveryHeld)
            case .waitingForPermission, .waitingForCompatibilityCLI: result.append(.permissionRequested)
            case .waitingForInput: result.append(.inputRequested)
            case .completed: result.append(.jobCompleted)
            case .failed: result.append(.jobFailed)
            case .cancelled: result.append(.jobCancelled)
            case .queued: break // Approval/input producers supply their factual reason.
            }
        }
        let attempt = task.durability?.attempt ?? 0
        var events = result.map { TaskJournalEventDraft(taskID: task.id, kind: $0, attempt: attempt) }
        let added = task.artifacts.filter { !before.artifacts.contains($0) }
        if !added.isEmpty {
            events.append(TaskJournalEventDraft(taskID: task.id, kind: .artifactCaptured,
                detail: "count:\(added.count)", attempt: attempt))
        }
        return events
    }

    func journalContext(taskID: String) -> TaskJournalContext? {
        guard let task = task(id: taskID) else { return nil }
        return TaskJournalContext(taskID: taskID, attempt: task.durability?.attempt ?? 0, record: { [weak self] event in
            guard event.taskID == taskID, self?.task(id: taskID) != nil else { return }
            self?.persist(events: [event])
        })
    }

    @discardableResult
    private func persist(events: [TaskJournalEventDraft] = []) -> AgentTaskPersistenceResult {
        guard historyReadFailure == nil else { return .loadFailed }
        // Existing uninjected harness simulations never write the owner store. This
        // accepted simulation result is not evidence of a durable production commit.
        guard !SelfTest.isRunning || store.allowsHarnessPersistence else { return .saved }
        let result = store.save(tasks, events: events)
        lastPersistenceResult = result
        if let diagnostic = result.diagnostic {
            if SelfTest.isRunning { SelfTest.diagnostic("TASK_PERSISTENCE_FAILED: \(diagnostic)") }
            else { Log.app.error("\(diagnostic, privacy: .public)") }
        }
        return result
    }

    /// Folds whatever the ledger holds for this run onto the task's artifact list.
    /// Called from `execute` and from `--selftest-tasks`'s browser-run fixture; the
    /// take-on-read keeps a second fold from duplicating the links.
    func foldArtifacts(taskID: String) {
        guard historyReadFailure == nil else { return }
        let captured = AgentArtifactLedger.take(taskID: taskID)
        guard !captured.isEmpty else { return }
        update(taskID) { item in
            for artifact in captured where !item.artifacts.contains(artifact) {
                item.artifacts.append(artifact)
            }
        }
    }

    /// Background work used to finish only in the task list. A failure the conversation
    /// never hears is the same shape as a turn that never replied.
    private func announce(_ text: String) {
        guard projectsActivity else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Tagged: a background result is content the user did not write, so the memory review
        // and a compaction summary never read it as the Agent's own words.
        AgentSession.shared.recordAssistant(trimmed, contextKind: AgentSession.backgroundTaskContextKind)
        AgentAuditLog.shared.record(kind: .reply, title: trimmed)
        IslandState.shared.showBackgroundAgentReply(trimmed)
        VoiceAnnouncementQueue.shared.enqueue(trimmed)
    }

    /// The artifact half of a finished run, persisted in the conversation (P1-5).
    /// Never spoken: a URL read out loud is noise, and the links are for the result card.
    private func announceArtifacts(taskID: String) {
        guard projectsActivity else { return }
        guard let task = task(id: taskID), !task.artifacts.isEmpty else { return }
        let lines = "What I made for you:\n"
            + task.artifacts.map { "\u{2022} \($0)" }.joined(separator: "\n")
        AgentSession.shared.recordAssistant(lines, contextKind: AgentSession.backgroundTaskContextKind)
        AgentAuditLog.shared.record(kind: .reply, title: "Saved \(task.artifacts.count) result\(task.artifacts.count == 1 ? "" : "s")")
        IslandState.shared.showBackgroundAgentReply(
            task.artifacts.count == 1 ? "Saved 1 result." : "Saved \(task.artifacts.count) results."
        )
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
