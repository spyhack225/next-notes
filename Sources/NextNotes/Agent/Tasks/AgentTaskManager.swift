import Foundation
import Observation

/// Owns background work so the realtime conversation can keep going.
@MainActor
@Observable
final class AgentTaskManager {
    private static weak var loaded: AgentTaskManager?
    static var sharedIfLoaded: AgentTaskManager? { loaded }
    static let shared: AgentTaskManager = {
        let manager = AgentTaskManager()
        loaded = manager
        return manager
    }()


    @ObservationIgnored private(set) weak var voiceJobOwner: VoiceConversationCoordinator?
    func bindVoiceJobOwner(_ owner: VoiceConversationCoordinator) -> Bool {
        guard voiceJobOwner == nil || voiceJobOwner === owner else { return false }
        voiceJobOwner = owner
        return true
    }
    func hasLiveVoiceCancellationOwner(id: UUID) -> Bool { running[id.uuidString] != nil }

    private(set) var tasks: [AgentTask] = []
    /// A storage failure is visible to diagnostics/UI without claiming both files committed.
    private(set) var lastPersistenceResult: AgentTaskPersistenceResult?
    /// Failed history initialization blocks all record writes and new execution.
    private(set) var historyReadFailure: String?
    struct VoiceWorkerSnapshot {
        let id: UUID
        let work: VoiceConversationWork
        let worker: RealtimeAgent
        var task: Task<Void, Never>?
        weak var coordinator: VoiceConversationCoordinator?
        weak var bridge: TaskBridge?
    }
    struct TypedWorkerSnapshot {
        let id: UUID
        let sessionID: UUID
        let work: VoiceConversationWork
        let worker: RealtimeAgent
        let task: Task<AgentTurn, Never>
        weak var bridge: TaskBridge?
    }
    private enum WorkerHandle {
        case voice(VoiceWorkerSnapshot)
        case typed(TypedWorkerSnapshot)
        case returnedVoice
        case returnedTyped(UUID)
        case worker(Task<Void, Never>)
        case scheduled(Task<ScheduledRunOutcome, Never>)
        var isCancelled: Bool {
            switch self {
            case .voice(let value): value.task?.isCancelled == true
            case .typed(let value): value.task.isCancelled
            case .returnedVoice, .returnedTyped: false
            case .worker(let task): task.isCancelled
            case .scheduled(let task): task.isCancelled
            }
        }
        @MainActor func cancel() {
            switch self {
            case .voice(let value): value.worker.cancelVoiceObjective(); value.task?.cancel()
            case .typed(let value): value.worker.cancelVoiceObjective(); value.task.cancel()
            case .returnedVoice, .returnedTyped: break
            case .worker(let task): task.cancel()
            case .scheduled(let task): task.cancel()
            }
        }
    }
    /// Observation of the SAME sole live map; does not install or retain an owner.
    func voiceOwnedOperationForTesting(id: UUID) -> Task<Void, Never>? {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle" else { return nil }
        return voiceWorkerSnapshot(id: id)?.task
    }
    func voiceWorkHeldForTesting(id: UUID) -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle" else { return false }
        return voiceWorkerSnapshot(id: id) != nil
    }

    private struct RunningWorker {
        var handle: WorkerHandle
        var binding: TaskWorkerBinding? = nil
        var primaryObservation: TaskWorkerPrimaryObservation? = nil
        var toolBackingObservation: TaskWorkerToolBackingObservation? = nil
        weak var acpSession: ACPSession? = nil
    }
    @ObservationIgnored private var running: [String: RunningWorker] = [:]
    /// A one-shot approval is intentionally not persisted as a standing grant. Keep the
    /// approval long enough for the exact queued retry to hand it to ActionOrchestrator.
    @ObservationIgnored private var approvedTaskIDs: Set<String> = []
    /// A separate, in-memory one-shot token for the weaker ACP compatibility path.
    /// It is never persisted or represented as a permission grant.
    @ObservationIgnored private var approvedCompatibilityTaskIDs: Set<String> = []
    @ObservationIgnored private(set) var backendStartsForTesting = 0
    @ObservationIgnored var backendEntryForTesting: (@MainActor () throws -> Void)?
    @ObservationIgnored var backendExitForTesting: (@MainActor () -> Void)?
    /// Nil normally; synchronous metadata acknowledgement on the same scope producer.
    @ObservationIgnored var toolInvocationForTesting: (@MainActor (TaskWorkerToolBackingObservation) -> Void)?
    @ObservationIgnored var announcementForTesting: (@MainActor (String) -> Void)?
    @ObservationIgnored var progressDateForTesting: (@MainActor () -> Date)?
    private var preparedRepairAvailable = false
    @ObservationIgnored private let store: AgentTaskStore
    // Optional: constructing the manager must not load the shared receipt history.
    @ObservationIgnored private let receiptStore: ActionReceiptStore?
    private var projectsActivity: Bool { !SelfTest.isRunning || !store.allowsHarnessPersistence }

    init(store: AgentTaskStore = .shared, receiptStore: ActionReceiptStore? = nil) {
        self.store = store
        self.receiptStore = receiptStore
        do { tasks = try store.load() }
        catch {
            historyReadFailure = AgentTaskPersistenceResult.loadFailed.diagnostic
            lastPersistenceResult = .loadFailed
            preparedRepairAvailable = store.canRepairPreparedHistory
            if let diagnostic = historyReadFailure {
                if SelfTest.isRunning { SelfTest.diagnostic("TASK_HISTORY_DIAGNOSTIC: \(diagnostic)") }
                else { Log.app.error("\(diagnostic, privacy: .public)") }
            }
            return
        }
        holdInterruptedTasks()
    }

    /// Display-only retained source metadata. Empty is unknown/unavailable, never no effect.
    /// Uses only an injected store or the SAME already-loaded singleton; no receipt decode.
    func basedOnReferences(taskID: String) -> [ActionContextReference] {
        guard historyReadFailure == nil, !SelfTest.isRunning || receiptStore != nil,
              let task = task(id: taskID), let durability = task.durability,
              durability.attempt > 0, let owner = durability.leaseOwner, !owner.isEmpty,
              let receipts = receiptStore ?? ActionReceiptStore.sharedIfLoaded,
              let source = receipts.sourceObservation,
              [.missing, .readable, .partial].contains(source.loadQuality) else { return [] }
        // LAST load/admission quality, not CURRENT source or full effect coverage. No drawing I/O.
        // Follow the primary row's retained order and the SAME cached saved receipt objects.
        var references: [ActionContextReference] = []
        for id in durability.receiptIDs {
            guard let actionID = UUID(uuidString: id), actionID.uuidString == id,
                  let receipt = receipts.receipt(for: actionID),
                  receipt.taskID == taskID, receipt.taskAttempt == durability.attempt,
                  receipt.taskLeaseOwner == owner, receipt.preparedAction?.id == actionID,
                  receipt.intentID == receipt.intent.id,
                  receipt.preparedAction?.intentID == receipt.intentID,
                  receipt.preparedAction?.routing.taskID == taskID,
                  receipt.preparedAction?.evidence == receipt.intent.evidence else { continue }
            references.append(contentsOf: receipt.intent.evidence.filter {
                $0.kind == "mail" && $0.source == "mail" && !$0.value.isEmpty && $0.id == "mail:" + $0.value
            })
        }
        return references
    }

    /// Current admitted in-process handle metadata. It supplies no health,
    /// backend-session, effect, process-death or retry authority.
    func workerBinding(taskID: String) -> TaskWorkerBinding? {
        guard let worker = running[taskID], !worker.handle.isCancelled,
              let binding = worker.binding, let current = task(id: taskID),
              ownsWorkerAttempt(current), current.status == .running,
              current.durability?.attempt == binding.attempt,
              current.durability?.leaseOwner == binding.leaseOwner,
              current.durability?.attemptStartedAt == binding.startedAt else { return nil }
        return binding
    }

    /// Last primary check attached to this exact live handle; performs no read.
    /// Unknown/mismatch metadata grants no health, effect or retry authority.
    func workerPrimaryObservation(taskID: String) -> TaskWorkerPrimaryObservation? {
        guard let binding = workerBinding(taskID: taskID),
              let observed = running[taskID]?.primaryObservation,
              observed.expected.taskID == binding.taskID,
              observed.expected.attempt == binding.attempt,
              observed.expected.leaseOwner == binding.leaseOwner,
              observed.expected.status == .running else { return nil }
        return observed
    }

    /// LAST same-handle tool boundary metadata, not complete active-call coverage.
    /// Nil or returned never proves no effect, no active backing, or safe retry.
    /// No SQL/receipt read, save or validity check is performed by this getter.
    func workerToolBackingObservation(taskID: String) -> TaskWorkerToolBackingObservation? {
        guard let binding = workerBinding(taskID: taskID),
              let observed = running[taskID]?.toolBackingObservation,
              observed.binding == binding else { return nil }
        return observed
    }

    /// Sample the exact current owned Session, then reject a released/replaced
    /// binding across its actor hop. No SQL, receipt or LAST-cache health inference.
    func workerACPRuntimeObservation(taskID: String) async -> JSONRPCStdioObservation? {
        guard let binding = workerBinding(taskID: taskID),
              let session = running[taskID]?.acpSession else { return nil }
        let observed = await session.currentRuntimeObservation()
        guard workerBinding(taskID: taskID) == binding,
              running[taskID]?.acpSession === session else { return nil }
        return observed
    }

    /// Current Gate wait for this live task. Missing/released is unavailable;
    /// false covers only Gate approvals, not every kind of person interaction.
    func workerPermissionWait(taskID: String) -> Bool? {
        guard workerBinding(taskID: taskID) != nil else { return nil }
        return PermissionGate.shared.hasWaitingRequest(taskID: taskID)
    }

    /// Explicit off-path diagnostic: an actor sample followed by current primary/source
    /// metadata, not an atomic lease. No execution path waits on this observation.
    /// Unknown health/effect coverage never becomes a stale verdict or retry authority.
    func workerHeartbeatObservation(taskID: String, now: Date = Date()) async -> TaskWorkerHeartbeatObservation? {
        guard !SelfTest.isRunning || store.allowsHarnessPersistence,
              let binding = workerBinding(taskID: taskID) else { return nil }
        let session = running[taskID]?.acpSession
        let runtime: JSONRPCStdioObservation?
        if let session { runtime = await session.currentRuntimeObservation() }
        else { runtime = nil }
        guard workerBinding(taskID: taskID) == binding,
              running[taskID]?.acpSession === session else { return nil }
        // Reuse the existing fail-fast authority/file binding probe; LAST metadata
        // and this manager's in-memory running row are not current SQL authority.
        let expected = TaskWorkerWriteCondition(taskID: taskID, attempt: binding.attempt,
            leaseOwner: binding.leaseOwner, status: .running)
        let primary = store.workerPrimaryObservation(expected)
        let waiting = PermissionGate.shared.hasWaitingRequest(taskID: taskID)
        let receipts: ActionReceiptCurrentSourceObservation?
        if let receiptStore {
            receipts = receiptStore.currentSourceObservation(taskID: taskID, attempt: binding.attempt,
                leaseOwner: binding.leaseOwner, receiptIDs: primary.durability?.receiptIDs ?? [])
        } else if !SelfTest.isRunning {
            receipts = ActionReceiptStore.shared.currentSourceObservation(taskID: taskID, attempt: binding.attempt,
                leaseOwner: binding.leaseOwner, receiptIDs: primary.durability?.receiptIDs ?? [])
        } else { receipts = nil }
        let age: TaskHeartbeatAge?
        if primary.outcome == .accepted, let state = primary.state {
            age = TaskHeartbeat.classify(status: state, runtimeClass: primary.durability?.runtimeClass,
                heartbeatAt: primary.durability?.heartbeatAt, permissionWait: waiting, now: now)
        } else { age = nil }
        var evidence = TaskHeartbeatEvidence()
        if let runtime { evidence.processAlive = runtime.isRunning ? .yes : .no }
        // Only the exact named local backing-await scope supplies a positive tool fact.
        // End/nil is unknown: this slot is not a complete remote/descendant active set.
        if primary.outcome == .accepted,
           let invocation = workerToolBackingObservation(taskID: taskID),
           invocation.binding == binding, invocation.invocationInFlight {
            evidence.toolInFlight = .yes
        }
        // Open transport and pending outgoing requests do not prove session health,
        // and LAST entry/return does not cover every active tool or external effect.
        if receipts?.state == .matchingSource, receipts?.receipts.isEmpty == false {
            evidence.receiptCreated = .yes
        }
        let snapshot = TaskWorkerHeartbeatObservation(binding: binding, observedAt: Date(),
            primary: primary, runtime: runtime, permissionWait: waiting,
            lastToolBoundary: workerToolBackingObservation(taskID: taskID), receiptSource: receipts,
            age: age, evidence: evidence)
        Log.app.debug("Task heartbeat observation: primary \(primary.outcome.rawValue, privacy: .public), age \(age?.diagnosticName ?? "unknown", privacy: .public), process \(evidence.processAlive.rawValue, privacy: .public), receipt \(evidence.receiptCreated.rawValue, privacy: .public)")
        return snapshot
    }

    /// Log-only off-path consumer of the current exact worker observations. No task
    /// state, heartbeat, receipt or retry is changed. Nil normally; metadata only.
    @ObservationIgnored var heartbeatMonitorForTesting:
        (@MainActor (TaskWorkerHeartbeatObservation, String) -> Void)?

    /// Nil normally; admitted owner-beat metadata only, no payload or execution authority.
    @ObservationIgnored var periodicHeartbeatForTesting:
        (@MainActor (TaskWorkerBinding, Bool?) -> Void)?

    func monitorTaskHeartbeats(now: Date) async {
        guard historyReadFailure == nil,
              !SelfTest.isRunning || store.allowsHarnessPersistence else { return }
        // Capture the SAME running map, not another registry or persisted owner PID.
        let bindings = running.keys.sorted().compactMap { workerBinding(taskID: $0) }
        for binding in bindings {
            guard !Task.isCancelled else { return }
            let session = running[binding.taskID]?.acpSession
            guard workerBinding(taskID: binding.taskID) == binding,
                  let observed = await workerHeartbeatObservation(taskID: binding.taskID, now: now),
                  observed.binding == binding,
                  workerBinding(taskID: binding.taskID) == binding,
                  running[binding.taskID]?.acpSession === session else { continue }
            let label = "primary=" + observed.primary.outcome.rawValue
                + " age=" + (observed.age?.diagnosticName ?? "unknown")
                + " process=" + observed.evidence.processAlive.rawValue
                + " session=" + observed.evidence.backendSessionAlive.rawValue
                + " tool=" + observed.evidence.toolInFlight.rawValue
                + " receipt=" + observed.evidence.receiptCreated.rawValue
            Log.app.debug("Task monitor: \(label, privacy: .public)")
            if SelfTest.isRunning { heartbeatMonitorForTesting?(observed, label) }
            let admitted = recordPeriodicHeartbeat(observed, session: session, now: now)
            if SelfTest.isRunning { periodicHeartbeatForTesting?(binding, admitted) }
        }
    }

    /// SAME existing scheduler pass. Nil means no eligible owner beat; no stale,
    /// health, progress, effect, retry or process-death verdict is supplied.
    private func recordPeriodicHeartbeat(_ observed: TaskWorkerHeartbeatObservation,
                                         session: ACPSession?, now: Date) -> Bool? {
        guard !Task.isCancelled, historyReadFailure == nil,
              !SelfTest.isRunning || store.allowsHarnessPersistence,
              workerBinding(taskID: observed.binding.taskID) == observed.binding,
              let session, running[observed.binding.taskID]?.acpSession === session,
              observed.primary.outcome == .accepted, observed.primary.state == .running,
              observed.primary.durability?.runtimeClass == .acpWorker,
              !observed.permissionWait,
              !PermissionGate.shared.hasWaitingRequest(taskID: observed.binding.taskID),
              let runtime = observed.runtime, runtime.processID > 0, runtime.isRunning,
              !runtime.transportClosed, !runtime.outputEOF, runtime.pendingRequestCount > 0,
              let previous = observed.primary.durability?.heartbeatAt,
              let window = TaskHeartbeat.ageWindowSeconds(for: .acpWorker),
              now.timeIntervalSinceReferenceDate.isFinite,
              previous.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSince(previous).isFinite,
              now.timeIntervalSince(previous) >= window / 4,
              let captured = task(id: observed.binding.taskID), ownsTypedACPAttempt(captured),
              let expected = workerCondition(captured, states: [.running]) else { return nil }
        // Preserve the actual progress stamp in the SAME conditioned durability-row
        // transaction. Its exact authority/row check remains primary admission.
        let event = TaskJournalEventDraft(taskID: captured.id, kind: .heartbeat,
            at: now, detail: "acp.periodic", attempt: observed.binding.attempt)
        return update(captured.id, events: [event], worker: expected, activityOnly: true) { item in
            item.durability?.heartbeatAt = now
        }.primaryCommitted
    }

    /// Record the LAST actual admitted entry/return under its captured handle.
    /// Completion is observed before its existing save, so rollback cannot invent an
    /// active backing after it returned. This grants no health/effect/retry authority.
    private func observeToolBacking(_ event: TaskJournalEventDraft, captured: AgentTask) {
        guard let worker = running[captured.id], !worker.handle.isCancelled,
              let binding = worker.binding,
              binding.attempt == captured.durability?.attempt,
              binding.leaseOwner == captured.durability?.leaseOwner,
              binding.startedAt == captured.durability?.attemptStartedAt,
              event.taskID == binding.taskID, event.attempt == binding.attempt,
              let receiptID = event.receiptID else { return }
        let toolID: String
        let state: TaskWorkerToolBackingState
        switch event.kind {
        case .toolStarted:
            guard let detail = event.detail else { return }
            toolID = detail
            state = .entryAdmitted
        case .toolCompleted:
            guard let prior = running[captured.id]?.toolBackingObservation,
                  prior.binding == binding, prior.receiptID == receiptID,
                  prior.state == .entryAdmitted else { return }
            toolID = prior.toolID
            if event.detail == toolID + ":returned" { state = .backingReturned }
            else if event.detail == toolID + ":threw" { state = .backingThrew }
            else { return }
        default: return
        }
        guard let currentWorker = running[captured.id], !currentWorker.handle.isCancelled,
              currentWorker.binding == binding else { return }
        running[captured.id]?.toolBackingObservation = TaskWorkerToolBackingObservation(
            binding: binding, receiptID: receiptID, toolID: toolID, state: state)
        if let observed = running[captured.id]?.toolBackingObservation {
            Log.app.debug("Task backing observation: attempt \(observed.binding.attempt), state \(observed.state.rawValue, privacy: .public)")
        }
    }

    /// Repair reuses the same startup hold transition; no backend or dispatch occurs.
    var canRepairTaskHistory: Bool {
        historyReadFailure != nil && running.isEmpty && preparedRepairAvailable
    }

    @discardableResult
    func repairTaskHistory() -> Bool {
        guard canRepairTaskHistory else { return false }
        do {
            try store.repairPreparedHistory()
            tasks = try store.load()
            approvedTaskIDs.removeAll()
            approvedCompatibilityTaskIDs.removeAll()
            historyReadFailure = nil
            preparedRepairAvailable = false
            lastPersistenceResult = nil
            holdInterruptedTasks()
            return historyReadFailure == nil
        } catch {
            historyReadFailure = AgentTaskPersistenceResult.loadFailed.diagnostic
            lastPersistenceResult = .loadFailed
            preparedRepairAvailable = store.canRepairPreparedHistory
            return false
        }
    }

    private func holdInterruptedTasks() {
        let loadedTasks = tasks
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
        if !events.isEmpty {
            let committed = persist(events: events)
            if !committed.primaryCommitted {
                // A planned launch decision is not committed state. Refuse dispatch
                // until a fresh load can commit it, preserving the saved snapshots.
                for before in loadedTasks {
                    if let index = tasks.firstIndex(where: { $0.id == before.id }) { tasks[index] = before }
                }
                historyReadFailure = committed.diagnostic
            }
        }
    }

    func task(id: String) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    @discardableResult
    func submit(
        objective: String,
        id: String = UUID().uuidString,
        tool: String? = nil,
        arguments: [String: String] = [:],
        contextReferences: [String] = [],
        meetingID: UUID? = nil,
        backend: AgentBackendKind = .local,
        acpCLI: String = "",
        source: String = "user",
        origin: TaskOrigin? = nil, userWords: String? = nil
    ) -> AgentTask {
        var task = AgentTask(
            id: id, objective: objective,
            source: source,
            contextReferences: contextReferences,
            tool: tool,
            arguments: arguments,
            meetingID: meetingID,
            backend: backend.rawValue,
            acpCLI: acpCLI, origin: origin, userWords: userWords
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
        enqueueWorker(task.id)
        return task
    }

    @discardableResult
    func submitVoiceACPObjective(id: UUID, objective: String, userWords: String,
                                 origin: TaskOrigin, cli: String) -> Bool {
        guard case .voice(let session, let turn) = origin, turn.raw > 0,
              AgentCaptureController.shared.isSessionActive,
              AgentCaptureController.shared.sessionID == session,
              voiceJobOwner != nil, task(id: id.uuidString) == nil,
              !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cli.isEmpty else { return false }
        let arguments = permitsTaskBridgeHarness ? voiceACPArgumentsForTesting?(id) ?? [:] : [:]
        let admitted = submit(objective: objective, id: id.uuidString, arguments: arguments, backend: .acp,
            acpCLI: cli, source: "voice", origin: origin, userWords: userWords)
        guard admitted.status != .failed, task(id: id.uuidString) != nil else { return false }
        VoiceSession.shared.send(.task(.accepted(TaskID(id), title: TaskStatusRenderer.title(objective), origin: origin)))
        return true
    }

    /// A routine run (Part 3): a fresh task with source `"scheduled"` and its schedule id.
    /// `ScheduledRunner` executes it; this only keeps the record, so it shows with the other
    /// tasks. It is never announced into the conversation — a routine delivers through its
    /// own notification — and never handed to a backend.
    @discardableResult
    func beginScheduledRun(_ task: AgentTask) -> Bool {
        guard historyReadFailure == nil else { return false }
        tasks.insert(task, at: 0)
        guard persist(events: creationEvents(task)).primaryCommitted else {
            tasks.removeFirst() // SAME synchronous insertion; retain the prior exact order.
            return false
        }
        guard !SelfTest.isRunning else { return true }
        AgentActivityStore.shared.begin(task: task, title: task.objective)
        IslandState.shared.showBackgroundAgentWork(title: task.objective)
        return true
    }

    @discardableResult
    func beginScheduledRun(_ proposed: AgentTask, executionOwner: Task<ScheduledRunOutcome, Never>) -> Bool {
        guard historyReadFailure == nil, !executionOwner.isCancelled,
              proposed.source == AgentTask.scheduledSource, proposed.scheduleID != nil,
              proposed.status == .running, ["local", "apple", "openrouter"].contains(proposed.backend),
              proposed.durability == nil, task(id: proposed.id) == nil else { return false }
        var task = proposed
        let began = progressDate()
        var durability = TaskDurability()
        durability.attempt = 1
        durability.leaseOwner = String(ProcessInfo.processInfo.processIdentifier)
        durability.attemptStartedAt = began
        durability.heartbeatAt = began
        durability.lastProgressAt = began
        durability.runtimeClass = .scheduledResearch
        task.durability = durability
        if task.startedAt == nil { task.startedAt = began }
        let started = TaskJournalEventDraft(taskID: task.id, kind: .workerStarted,
            at: began, attempt: durability.attempt)
        tasks.insert(task, at: 0)
        guard persist(events: creationEvents(task) + [started]).primaryCommitted else {
            tasks.removeFirst()
            return false
        }
        running[task.id] = RunningWorker(handle: .scheduled(executionOwner),
            binding: TaskWorkerBinding(taskID: task.id, attempt: durability.attempt,
                leaseOwner: durability.leaseOwner!, startedAt: began))
        if projectsActivity {
            AgentActivityStore.shared.begin(task: task, title: task.objective)
            IslandState.shared.showBackgroundAgentWork(title: task.objective)
        }
        return true
    }

    /// Test-only retained SAME slot, including terminal rows; no filtered liveness claim.
    func retainsScheduledRunOwnerForTesting(taskID: String) -> Bool? {
        guard SelfTest.isRunning, ["--selftest-task-worker-attempt", "--selftest-island"].contains(SelfTest.requested ?? ""),
              store.allowsHarnessPersistence else { return nil }
        guard let worker = running[taskID] else { return false }
        if case .scheduled = worker.handle { return true }
        return false
    }

    func scheduledJournalContext(taskID: String) -> TaskJournalContext? {
        guard let task = task(id: taskID), ownsScheduledAttempt(task),
              workerBinding(taskID: taskID) != nil else { return nil }
        return journalContext(taskID: taskID)
    }

    func finishScheduledRunAdmitted(id: String, status: AgentTaskStatus, result: String?, failure: String?) -> Bool {
        guard let captured = task(id: id), ownsScheduledAttempt(captured),
              workerBinding(taskID: id) != nil else { return false }
        // A completion callback may carry only an actual terminal outcome.
        // Invalid external state is refused before any cache/primary/activity change.
        guard status.isTerminal else {
            lastPersistenceResult = .invalidCompletion
            return false
        }
        let saved = updateWorker(captured, transitionThrough: status == .cancelled ? .cancelling : nil) { item in
            item.status = status
            item.progress = status == .completed ? "Finished" : "Failed"
            item.result = result
            item.failure = failure
        }
        guard saved.primaryCommitted else { return false }
        if projectsActivity { AgentActivityStore.shared.finish(taskID: id, title: result ?? failure ?? "Finished") }
        return true
    }

    func releaseScheduledRun(_ context: TaskJournalContext?) {
        guard let context, let binding = running[context.taskID]?.binding,
              context.attempt == binding.attempt, context.leaseOwner == binding.leaseOwner,
              let captured = task(id: context.taskID), ownsScheduledAttempt(captured),
              captured.durability?.attemptStartedAt == binding.startedAt else { return }
        running[context.taskID] = nil
    }

    @discardableResult
    func finishScheduledRun(id: String, status: AgentTaskStatus, result: String?, failure: String?) -> Bool {
        // An already returned routine may report again; conflicting late state is
        // expected boundary input, not a new run or a replacement terminal result.
        guard let current = task(id: id) else { return false }
        guard !current.status.isTerminal || current.status == status else {
            lastPersistenceResult = .endedTask
            return false
        }
        guard status.isTerminal else {
            lastPersistenceResult = .invalidCompletion
            return false
        }
        var proposed = current
        proposed.status = status
        guard allowsStateChange(from: current, to: proposed, kinds: [],
                                through: status == .cancelled ? .cancelling : nil) else {
            lastPersistenceResult = .invalidTransition
            return false
        }
        let admitted = update(id, transitionThrough: status == .cancelled ? .cancelling : nil) { task in
            task.status = status
            task.progress = status == .completed ? "Finished" : "Failed"
            task.result = result
            task.failure = failure
        }
        guard admitted.primaryCommitted else { return false }
        if !SelfTest.isRunning { AgentActivityStore.shared.finish(taskID: id, title: result ?? failure ?? "Finished") }
        return true
    }

    /// One existing primary snapshot transaction for the batch. Rejected writes
    /// preserve all cached rows; no audio or recovery authority comes from metadata.
    @discardableResult
    func setTaskDelivery(_ ids: [TaskID], state: TaskDelivery, attempts: Int? = nil) -> Bool {
        guard historyReadFailure == nil, !ids.isEmpty, Set(ids).count == ids.count,
              attempts.map({ $0 >= 0 }) ?? true else { return false }
        var selected: [Int] = []
        for id in ids {
            guard let index = tasks.firstIndex(where: { $0.id == id.raw }) else { return false }
            let row = tasks[index]
            guard [.completed, .failed, .cancelled, .waitingForInput, .waitingForPermission].contains(row.status),
                  TaskDeliveryAdmission.permits(from: row.delivery, to: state),
                  attempts.map({ $0 >= row.deliveryAttempts }) ?? true else { return false }
            selected.append(index)
        }
        if selected.allSatisfy({ tasks[$0].delivery == state && (attempts == nil || tasks[$0].deliveryAttempts == attempts) }) { return true }
        let before = tasks
        for index in selected {
            tasks[index].delivery = state
            if let attempts { tasks[index].deliveryAttempts = attempts }
        }
        let saved = persist()
        if !saved.primaryCommitted { tasks = before }
        return saved.primaryCommitted
    }

    /// Exact isolated output fixture only; default nil never changes ordinary routing.
    @ObservationIgnored var completionDeliveryForTesting: (@MainActor (TaskID) -> Void)?
    @ObservationIgnored var questionDeliveryForTesting: (@MainActor (TaskID) -> Void)?
    /// Instance-only legacy consumer under the same isolated delivery diagnostic.
    @ObservationIgnored var announcementOutputForTesting: OutputScheduler?
    /// Exact isolated ACP voice fixture only; no normal routing payload injection.
    @ObservationIgnored var voiceACPArgumentsForTesting: ((UUID) -> [String: String])?
    func capturedACPVoiceTaskForTesting(id: String) -> Task<Void, Never>? {
        guard permitsTaskBridgeHarness, let row = task(id: id), row.source == "voice",
              case .worker(let task)? = running[id]?.handle else { return nil }
        return task
    }
    /// Captures the SAME existing unbound operation for the confined late-return diagnostic.
    /// No admission, persistence or worker lifetime follows from this getter.
    func capturedACPTaskForTesting(id: String) -> Task<Void, Never>? {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-task-worker-attempt",
              store.allowsHarnessPersistence, let row = task(id: id), isTypedOwner(row),
              row.backend == AgentBackendKind.acp.rawValue, row.scheduleID == nil,
              row.compatibilityCLI == nil, row.compatibilityCommand == nil,
              case .worker(let operation)? = running[id]?.handle else { return nil }
        return operation
    }
    /// SAME local Task, scoped fixture cleanup only; no liveness or effect authority.
    func capturedReceiptMutationWorkerForTesting(id: String) -> Task<Void, Never>? {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-task-worker-attempt",
              store.allowsHarnessPersistence, let row = task(id: id),
              row.backend == AgentBackendKind.local.rawValue, row.source == "selftest", row.scheduleID == nil,
              ["filesystem.write", "filesystem.read", "create_event"].contains(row.tool ?? ""),
              case .worker(let operation)? = running[id]?.handle else { return nil }
        return operation
    }

    func capturedUnboundWorkerForTesting(id: String) -> Task<Void, Never>? {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-task-worker-attempt",
              store.allowsHarnessPersistence, let row = task(id: id), !ownsWorkerAttempt(row),
              case .worker(let operation)? = running[id]?.handle else { return nil }
        return operation
    }

    var permitsTaskBridgeHarness: Bool {
        SelfTest.isRunning && ["--selftest-voice-work-lifecycle", "--selftest-voice-turn-routing", "--selftest-voice-delivery", "--selftest-voice-duplex-work", "--selftest-island", "--selftest-task-recovery"].contains(SelfTest.requested ?? "") && store.allowsHarnessPersistence
    }

    @discardableResult
    func beginVoiceObjective(id: UUID, objective: String, origin: TaskOrigin? = nil,
                             userWords: String? = nil) -> Bool {
        guard historyReadFailure == nil, task(id: id.uuidString) == nil else { return false }
        var task = AgentTask(id: id.uuidString, objective: objective, source: "voice",
                             status: .running, progress: "Working locally", origin: origin,
                             userWords: userWords)
        let admittedEvents = creationEvents(task)
        task.startedAt = admittedEvents.first { $0.kind == .workerStarted }?.at
        tasks.insert(task, at: 0)
        guard persist(events: admittedEvents).primaryCommitted else {
            tasks.removeAll { $0.id == task.id }
            return false
        }
        if !SelfTest.isRunning {
            AgentActivityStore.shared.begin(task: task, title: objective)
            IslandState.shared.showBackgroundAgentWork(title: objective)
        }
        return true
    }

    /// Free-text typed planning enters the existing live map directly. LocalBackend
    /// remains the concrete-tool executor; it never receives a tool-less dispatch.
    func startTypedObjective(work: VoiceConversationWork, worker: RealtimeAgent,
                             bridge: TaskBridge, sessionID: UUID) -> Task<AgentTurn, Never>? {
        guard historyReadFailure == nil, task(id: work.id.uuidString) == nil,
              !work.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let began = progressDate()
        var durability = TaskDurability()
        durability.attempt = 1
        durability.leaseOwner = String(ProcessInfo.processInfo.processIdentifier)
        durability.attemptStartedAt = began
        durability.heartbeatAt = began; durability.lastProgressAt = began
        durability.runtimeClass = .cloudModel
        var row = AgentTask(id: work.id.uuidString, objective: work.original, source: "text",
            status: .running, progress: "Working", origin: .typed, userWords: work.userWords)
        row.startedAt = began; row.durability = durability
        tasks.insert(row, at: 0)
        guard persist(events: creationEvents(row)).primaryCommitted else {
            tasks.removeAll { $0.id == row.id }; return nil
        }
        let captured = row
        worker.typedTaskBridge = bridge
        let operation = Task { @MainActor [weak self] in
            guard let self, let live = self.typedWorkerSnapshot(id: work.id),
                  live.work === work, live.worker === worker, live.bridge === bridge else {
                return AgentTurn(reply: "I couldn't start that task.", delegated: false)
            }
            var finalTurn = AgentTurn(reply: "I stopped that task.", delegated: false)
            var recordInput = true
            while !Task.isCancelled {
                var usageIDs = ModelPassRecorder.correlation ?? UsageCorrelation()
                usageIDs.taskID = UsageLog.sanitiseTaskID(captured.id)
                let turn = await ModelPassRecorder.$correlation.withValue(usageIDs) {
                    await TaskEventJournal.$current.withValue(self.journalContext(taskID: captured.id)) {
                        return await worker.runTypedWorkerTurn(work, recordInput: recordInput)
                    }
                }
                finalTurn = turn
                guard let returned = self.typedWorkerSnapshot(id: work.id), returned.work === work,
                      returned.worker === worker, returned.task == live.task else { return turn }
                guard !Task.isCancelled else { break }
                let outcome = worker.typedTaskOutcome ?? .voiceReply(turn.reply)
                let saved = self.updateWorker(captured, states: [.running, .waitingForPermission]) { next in
                    next.status = outcome.status; next.progress = outcome.progress
                    next.result = outcome.result; next.failure = outcome.failure
                    if outcome.status == .waitingForInput, let question = outcome.result {
                        next.pendingInteraction = .input(TaskInputRequest(taskID: next.id, question: question))
                    } else { next.pendingInteraction = nil }
                }
                if saved.primaryCommitted, outcome.status == .waitingForInput,
                   case .input(let question)? = self.task(id: captured.id)?.pendingInteraction {
                    work.beginTypedQuestion(question.id)
                    worker.publishTypedResult(primaryCommitted: true, diagnostic: nil)
                    await work.waitForTypedQuestion()
                    guard !Task.isCancelled, let current = self.task(id: captured.id), current.status == .running,
                          current.revision == work.revision else { break }
                    recordInput = false
                    continue
                }
                worker.publishTypedResult(primaryCommitted: saved.primaryCommitted, diagnostic: saved.diagnostic)
                if !saved.primaryCommitted {
                    finalTurn = AgentTurn(reply: worker.lastReply, delegated: turn.delegated)
                }
                break
            }
            // Release only after this SAME operation returned, including its held
            // question/model children. Saved cancellation alone is not cessation.
            self.running[captured.id] = RunningWorker(handle: .returnedTyped(sessionID))
            return finalTurn
        }
        running[row.id] = RunningWorker(handle: .typed(TypedWorkerSnapshot(id: work.id,
            sessionID: sessionID, work: work, worker: worker, task: operation, bridge: bridge)),
            binding: TaskWorkerBinding(taskID: row.id, attempt: 1,
                leaseOwner: durability.leaseOwner!, startedAt: began))
        return operation
    }
    func stopTypedReplyOutput(sessionID: UUID) {
        for row in tasks {
            guard let id = UUID(uuidString: row.id), let live = typedWorkerSnapshot(id: id),
                  live.sessionID == sessionID else { continue }
            live.worker.stopTypedReplyOutput()
        }
    }
    func typedWorkerSnapshot(id: UUID) -> TypedWorkerSnapshot? {
        guard case .typed(let snapshot)? = running[id.uuidString]?.handle else { return nil }
        return snapshot
    }
    func typedControlObservation(id: UUID) -> TaskControlObservation {
        if let live = typedWorkerSnapshot(id: id), live.task.isCancelled { return .cancelled }
        if case .returnedTyped? = running[id.uuidString]?.handle { return .returned }
        return .unobserved
    }
    var typedReplyInProgress: AgentSession.Message? {
        tasks.compactMap { row -> AgentSession.Message? in
            guard let id = UUID(uuidString: row.id), let live = typedWorkerSnapshot(id: id),
                  !live.task.isCancelled else { return nil }
            return live.worker.respondingMessage
        }.first
    }
    var hasActiveTypedWork: Bool {
        tasks.contains { row in
            guard let id = UUID(uuidString: row.id), let live = typedWorkerSnapshot(id: id) else { return false }
            return row.status == .running && !live.task.isCancelled
        }
    }
    func cancelNewestTypedObjective(sessionID: UUID) -> Bool {
        guard let row = tasks.first(where: { row in
            guard let id = UUID(uuidString: row.id), let live = typedWorkerSnapshot(id: id) else { return false }
            return live.sessionID == sessionID && !live.task.isCancelled
        }) else { return false }
        cancel(row.id); return true
    }
    func typedWorkers(bridge: TaskBridge, sessionID: UUID) -> [TypedWorkerSnapshot] {
        // Canonical rows are newest-first. Exposed task numbers retain actual
        // admission order without a second index or date-tie sorting authority.
        tasks.reversed().compactMap { row in
            guard let id = UUID(uuidString: row.id), let live = typedWorkerSnapshot(id: id),
                  live.bridge === bridge, live.sessionID == sessionID else { return nil }
            return live
        }
    }
    @discardableResult
    func reviseTypedObjective(id: UUID, correction: String, bridge: TaskBridge, sessionID: UUID) -> Bool {
        guard let live = typedWorkerSnapshot(id: id), live.bridge === bridge,
              live.sessionID == sessionID, !live.task.isCancelled,
              let row = task(id: id.uuidString), row.origin == .typed,
              [.running, .waitingForPermission, .waitingForInput].contains(row.status), row.revision <= live.work.revision,
              !correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let question: TaskInputRequest?
        if row.status == .waitingForInput {
            guard case .input(let request)? = row.pendingInteraction, request.taskID == row.id else { return false }
            question = request
        } else { question = nil }
        // A failed primary save leaves newer local words held, as in voice work.
        live.work.append(correction)
        PermissionGate.shared.cancelPending(taskID: row.id)
        guard let expected = workerCondition(row, states: [.running, .waitingForPermission, .waitingForInput]) else { return false }
        // Only newly admitted local instructions enter the existing journal.
        // A refused earlier primary leaves those local follow-ups pending here.
        let instructions = live.work.followUps.dropFirst(row.revision)
        guard instructions.count == live.work.revision - row.revision else { return false }
        let revisions = instructions.map {
            TaskJournalEventDraft(taskID: row.id, kind: .revisionRecorded,
                detail: $0, attempt: row.durability?.attempt ?? 0)
        }
        let saved = update(row.id, kinds: question == nil ? [] : [.inputProvided], events: revisions, worker: expected) {
            $0.revision = live.work.revision; $0.userWords = correction
            if row.status != .running { $0.status = .running; $0.pendingInteraction = nil; $0.result = nil; $0.progress = "Working" }
        }.primaryCommitted
        if saved {
            if let question { live.work.resolveTypedQuestion(question.id) }
            VoiceSession.shared.send(.task(.revised(TaskID(id), revision: live.work.revision)))
        }
        return saved
    }
    func ownsTypedEffect(work: VoiceConversationWork, worker: RealtimeAgent, bridge: TaskBridge) -> Bool {
        guard let live = typedWorkerSnapshot(id: work.id), live.work === work,
              live.worker === worker, live.bridge === bridge, !live.task.isCancelled,
              let row = task(id: work.id.uuidString), row.origin == .typed, row.source == "text",
              row.status == .running, row.revision == work.revision else { return false }
        return true
    }
    func retainsTypedOperation(work: VoiceConversationWork, worker: RealtimeAgent, bridge: TaskBridge) -> Bool {
        guard let live = typedWorkerSnapshot(id: work.id), live.work === work,
              live.worker === worker, live.bridge === bridge else { return false }
        return true
    }

    /// Cached ownership of the SAME retained Manager operation; no SQL/effect grant.
    private func ownsVoiceProgress(id: UUID, work: VoiceConversationWork, worker: RealtimeAgent,
        coordinator: VoiceConversationCoordinator, bridge: TaskBridge, operationOwner: Task<Void, Never>, generation: Int,
        revision: Int, session: UUID, origin: TaskOrigin) -> Bool {
        guard !Task.isCancelled, AgentCaptureController.shared.isSessionActive,
              AgentCaptureController.shared.sessionID == session,
              let live = voiceWorkerSnapshot(id: id), live.work === work, live.worker === worker,
              live.coordinator === coordinator, live.bridge === bridge,
              let operation = live.task, operation == operationOwner, !operation.isCancelled, worker.currentGeneration == generation,
              work.revision == revision, let row = task(id: id.uuidString),
              row.status == .running, row.source == "voice", row.revision == revision,
              row.origin == origin, case .voice(let owned, _)? = row.origin, owned == session else { return false }
        return true
    }

    /// The actual ordered public step feed is the producer; the SAME canonical row
    /// stores its display projection. No task state, heartbeat or effect claim follows.
    @discardableResult
    func noteVoiceProgress(taskID: String, revision: Int, origin: TaskOrigin,
                           step: Int, title: String) -> Bool {
        guard historyReadFailure == nil, step > 0, revision >= 0,
              let task = task(id: taskID), task.source == "voice", task.status == .running,
              task.revision == revision, task.origin == origin, case .voice = origin,
              AgentActivityProjector.isPublic(title),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let id = UUID(uuidString: taskID), let live = voiceWorkerSnapshot(id: id),
              let operation = live.task, !operation.isCancelled, live.work.revision == revision,
              let scope = AgentWorkPresentationScope.voiceProgress, scope.bridge === live.bridge,
              scope.origin == origin, scope.currentRevision(taskID: taskID) == revision else { return false }
        let steps = AgentActivityStore.shared.steps(taskID: taskID)
        guard steps.count == step, let last = steps.last, !last.isCompleted,
              last.title == title else { return false }
        let publicTitle = title.hasSuffix("…") ? String(title.dropLast()) : title
        let progress = "Step \(step): " + String(publicTitle.prefix(160))
        guard task.progress != progress else { return false }
        let expected = TaskWorkerWriteCondition(taskID: taskID, attempt: 0, leaseOwner: nil,
            status: .running, voiceOrigin: origin, voiceRevision: revision)
        return update(taskID, worker: expected) { $0.progress = progress }.primaryCommitted
    }

    @discardableResult
    func finishVoiceObjective(id: UUID, result: String) -> Bool {
        finishVoiceObjective(id: id, outcome: .voiceReply(result))
    }

    /// The same canonical row consumes the worker's producer-owned outcome.
    @discardableResult
    func finishVoiceObjective(id: UUID, outcome: AgentTaskOutcome) -> Bool {
        guard let current = task(id: id.uuidString), current.source == "voice", current.status == .running,
              [.completed, .failed, .waitingForInput].contains(outcome.status) else { return false }
        let canonicalVoice: Bool = if case .voice? = current.origin { true } else { false }
        let question = outcome.status == .waitingForInput ? outcome.result : nil
        guard outcome.status != .waitingForInput || !(question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else { return false }
        let saved = update(id.uuidString) { task in
            task.status = outcome.status; task.progress = outcome.progress
            task.result = outcome.result; task.failure = outcome.failure
            if !outcome.artifactRecords.isEmpty { task.artifactRecords = outcome.artifactRecords }
            task.pendingInteraction = question.map { .input(TaskInputRequest(taskID: task.id, question: $0)) }
            if question != nil && canonicalVoice {
                // Same admitted question transaction, not another full-history save.
                task.delivery = .pending; task.deliveryAttempts = 0
            }
        }
        guard saved.primaryCommitted else {
            announce(outcome.status == .completed
                ? "The work finished, but I couldn't save its result."
                : "The work stopped, but I couldn't save its status.")
            return false
        }
        let reply = outcome.result ?? outcome.failure ?? ""
        if !SelfTest.isRunning {
            if outcome.status == .waitingForInput {
                AgentActivityStore.shared.update(taskID: id.uuidString, kind: .waiting, title: "Waiting for your answer")
            } else { AgentActivityStore.shared.finish(taskID: id.uuidString, title: reply) }
        }
        let canonicalCompletion = outcome.status == .completed && canonicalVoice
        announce(reply, queueSpeech: !canonicalCompletion && !(canonicalVoice && outcome.status == .waitingForInput))
        if canonicalVoice && outcome.status == .waitingForInput {
            if SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery", store.allowsHarnessPersistence {
                questionDeliveryForTesting?(TaskID(id))
            }
            if projectsActivity { _ = OutputScheduler.shared.enqueueQuestion(TaskID(id)) }
        }
        // Existing completion observer belongs ONLY to admitted completed outcome.
        if outcome.status == .completed {
            if SelfTest.isRunning, ["--selftest-voice-delivery", "--selftest-voice-work-lifecycle", "--selftest-voice-turn-routing"].contains(SelfTest.requested ?? ""), store.allowsHarnessPersistence {
                completionDeliveryForTesting?(TaskID(id))
            }
            if projectsActivity { _ = OutputScheduler.shared.enqueueCompletion(TaskID(id)) }
        }
        return true
    }

    /// Admit this exact proposal on the SAME current worker row before speech or grants.
    @discardableResult
    func presentVoiceApproval(_ request: PermissionRequest, review: ToolCallReview, revision: Int) -> Bool {
        guard let raw = request.taskID, let id = UUID(uuidString: raw),
              managedVoiceApprovalOwner(requestTaskID: raw)?.revision == revision,
              let current = task(id: raw), current.status == .running,
              case .voice(_, let turn)? = current.origin, turn.raw > 0,
              current.pendingInteraction == nil,
              review.id == request.id, review.toolID == request.toolID else { return false }
        let expected = TaskWorkerWriteCondition(taskID: current.id, attempt: 0, leaseOwner: nil,
            status: current.status, voiceOrigin: current.origin, voiceRevision: current.revision)
        return update(id.uuidString, worker: expected) { row in
            row.tool = request.toolID
            row.status = .waitingForPermission
            row.pendingInteraction = .permission(request: request, origin: nil, review: review)
            row.progress = "Waiting for your approval"
            if SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery", store.allowsHarnessPersistence {
                SelfTest.diagnostic("VOICE_APPROVAL_ROW_METADATA toolMissing=\(row.tool == nil) toolMatches=\(row.tool == request.toolID) taskMatches=\(row.id == request.taskID) reviewMatches=\(review.toolID == request.toolID)")
            }
        }.primaryCommitted
    }

    /// Commit the exact saved request AND review snapshot before Gate can issue a token.
    @discardableResult
    func decideVoiceApproval(_ request: PermissionRequest, revision: Int, approved: Bool,
                             via: PermissionAnswerSurface = .card, recipientSession: UUID? = nil) -> Bool {
        guard let raw = request.taskID, let id = UUID(uuidString: raw),
              let current = task(id: raw), current.status == .waitingForPermission,
              current.revision == revision,
              let live = voiceWorkerSnapshot(id: id), live.task?.isCancelled == false,
              live.work.revision == revision, live.bridge != nil,
              case .permission(let pending, _, let review?) = current.pendingInteraction,
              pending == request, review.id == request.id, review.toolID == request.toolID,
              case .voice(_, let turn)? = current.origin, turn.raw > 0,
              PermissionGate.shared.pending == request else { return false }
        if via == .voice {
            guard let recipientSession, AgentCaptureController.shared.isSessionActive,
                  AgentCaptureController.shared.sessionID == recipientSession else { return false }
        }
        // A genuine card decision remains available while the listening session is
        // closed. Its SAME suspended worker and exact proposal still own the effect.
        let expected = TaskWorkerWriteCondition(taskID: current.id, attempt: 0, leaseOwner: nil,
            status: current.status, voiceOrigin: current.origin, voiceRevision: current.revision,
            voicePermission: current.pendingInteraction)
        return update(raw, kinds: [approved ? .permissionApproved : .permissionDenied], worker: expected) { row in
            row.status = .running; row.pendingInteraction = nil
            row.progress = "Working locally"
        }.primaryCommitted
    }

    /// Actual voice worker ownership in the existing running map. Receipt admission
    /// has already committed; exactly one task is created, retained and released here.
    func startVoiceWorker(work: VoiceConversationWork, worker: RealtimeAgent,
                          coordinator: VoiceConversationCoordinator, bridge: TaskBridge,
                          scriptedWorker: (@MainActor (VoiceConversationWork) async -> String)?) -> Bool {
        let id = work.id.uuidString
        guard let row = task(id: id), row.source == "voice", row.status == .running else { return false }
        if let existing = running[id] {
            guard case .voice(let held) = existing.handle,
                  held.work === work, held.worker === worker, held.coordinator === coordinator, held.bridge === bridge,
                  held.task == nil else { return false }
        }
        worker.voiceTaskBridge = bridge
        let operation = Task { @MainActor [weak self, weak coordinator] in
            guard let self, let admitted = self.voiceWorkerSnapshot(id: work.id),
                  admitted.work === work, admitted.worker === worker, admitted.bridge === bridge,
                  let operationOwner = admitted.task else { return }
            let generation = worker.currentGeneration
            let scope: AgentWorkPresentationScope.VoiceProgress? = if let coordinator, let origin = row.origin,
                case .voice(let session, _) = origin {
                .init(taskID: id, bridge: bridge, origin: origin,
                    revision: { [weak self, weak coordinator] in
                        guard let self, let coordinator,
                              self.ownsVoiceProgress(id: work.id, work: work, worker: worker,
                                coordinator: coordinator, bridge: bridge, operationOwner: operationOwner, generation: generation,
                                revision: work.revision, session: session, origin: origin) else { return nil }
                        return work.revision
                    }, isCurrent: { [weak self, weak coordinator] revision in
                        guard let self, let coordinator else { return false }
                        return self.ownsVoiceProgress(id: work.id, work: work, worker: worker,
                            coordinator: coordinator, bridge: bridge, operationOwner: operationOwner, generation: generation,
                            revision: revision, session: session, origin: origin)
                    })
            } else { nil }
            var usageIDs = ModelPassRecorder.correlation ?? UsageCorrelation()
            usageIDs.taskID = UsageLog.sanitiseTaskID(id)
            let outcome = await ModelPassRecorder.$correlation.withValue(usageIDs) {
                await VoiceWorkerScope.$isWorker.withValue(true) {
                    await AgentWorkPresentationScope.$voiceProgress.withValue(scope) {
                        if let scriptedWorker { return AgentTaskOutcome.voiceReply(await scriptedWorker(work)) }
                        return await worker.runVoiceObjectiveOutcome()
                    }
                }
            }
            guard let current = self.voiceWorkerSnapshot(id: work.id),
                  current.work === work, current.worker === worker else { return }
            guard !Task.isCancelled else {
                if let retained = self.task(id: id), [.running, .waitingForInput, .waitingForPermission].contains(retained.status) {
                    self.running[id]?.handle = .returnedVoice
                } else { self.running[id] = nil }
                return
            }
            guard self.finishVoiceObjective(id: work.id, outcome: outcome) else {
                // Exact return is a local observation; the rejected stored result
                // remains uncertain. Release model/work/task references immediately.
                self.running[id]?.handle = .returnedVoice
                return
            }
            if outcome.status == .waitingForInput {
                var pending = current
                pending.task = nil
                self.running[id]?.handle = .voice(pending)
            } else {
                // Completed/failed owners have no resumable work to retain.
                self.running[id] = nil
            }
            coordinator?.voiceWorkerFinished(id: work.id, request: work.original, outcome: outcome)
        }
        running[id] = RunningWorker(handle: .voice(VoiceWorkerSnapshot(id: work.id,
            work: work, worker: worker, task: operation, coordinator: coordinator, bridge: bridge)))
        return true
    }

    /// Retention authority only, including cancellation pending actual return.
    /// This grants no effect, result, permission or health authority.
    func hasRetainedVoiceOperation(work: VoiceConversationWork, worker: RealtimeAgent, bridge: TaskBridge) -> Bool {
        guard let live = voiceWorkerSnapshot(id: work.id), live.work === work,
              live.worker === worker, live.bridge === bridge, live.task != nil else { return false }
        return true
    }

    func voiceWorkerSnapshot(id: UUID) -> VoiceWorkerSnapshot? {
        guard case .voice(let value)? = running[id.uuidString]?.handle else { return nil }
        return value
    }
    /// Payload-free lookup over the SAME live slot, not a second owner/index.
    func liveVoiceRevision(id: UUID) -> Int? {
        guard let live = voiceWorkerSnapshot(id: id), live.task?.isCancelled == false,
              let row = task(id: id.uuidString), row.source == "voice",
              [.running, .waitingForPermission].contains(row.status),
              case .voice(let session, _)? = row.origin,
              AgentCaptureController.shared.isSessionActive,
              AgentCaptureController.shared.sessionID == session,
              live.work.revision == row.revision else { return nil }
        return row.revision
    }
    /// The actual owner appends to the SAME retained work before primary admission.
    /// Refusal keeps newer local revision/current input held; no replacement worker.
    func reviseVoiceWorker(id: UUID, text: String, coordinator: VoiceConversationCoordinator, bridge: TaskBridge, userWords: String? = nil) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ownsVoiceWorker(id: id, coordinator: coordinator, bridge: bridge),
              let live = voiceWorkerSnapshot(id: id), live.task?.isCancelled == false,
              let row = task(id: id.uuidString), [.running, .waitingForPermission].contains(row.status),
              case .voice(let session, _)? = row.origin,
              AgentCaptureController.shared.isSessionActive,
               (AgentCaptureController.shared.sessionID == session
                || (row.status == .waitingForPermission
                    && bridge.pendingApproval(sessionID: AgentCaptureController.shared.sessionID)?.task == TaskID(id))) else { return false }
        let approvalRecipient = row.status == .waitingForPermission
            ? bridge.pendingApproval(sessionID: AgentCaptureController.shared.sessionID)?.recipient : nil
        let obsolete = PermissionGate.shared.pending.flatMap { $0.taskID == row.id ? $0.id : nil }
        let instruction = userWords.map { $0 == text ? text : text + "\n(The person's exact words: " + $0 + ")" } ?? text
        live.work.append(instruction)
        if obsolete != nil { bridge.noteApprovalRevision(TaskID(id)) }
        PermissionGate.shared.cancelPending(taskID: row.id)
        let saved = recordVoiceRevision(id: id, revision: live.work.revision, permissionRecipientSession: approvalRecipient, userWords: userWords)
        if saved { VoiceSession.shared.send(.task(.revised(TaskID(id), revision: live.work.revision))) }
        return saved
    }

    /// Positive approval authority comes from the same current Task/row only.
    func managedVoiceApprovalOwner(requestTaskID: String?) -> (id: TaskID, revision: Int)? {
        guard let requestTaskID, let id = UUID(uuidString: requestTaskID),
              let revision = liveVoiceRevision(id: id) else { return nil }
        return (TaskID(id), revision)
    }

    func ownsVoiceWorker(id: UUID, coordinator: VoiceConversationCoordinator, bridge: TaskBridge) -> Bool {
        guard let live = voiceWorkerSnapshot(id: id) else { return false }
        return live.coordinator === coordinator && live.bridge === bridge
    }
    func voiceWorkerForCoordinator(id: UUID, coordinator: VoiceConversationCoordinator) -> VoiceWorkerSnapshot? {
        guard let live = voiceWorkerSnapshot(id: id), live.coordinator === coordinator else { return nil }
        return live
    }
    func liveVoiceTasks(coordinator: VoiceConversationCoordinator) -> [AgentTask] {
        tasks.filter { row in
            if row.hasVoiceOrigin, row.backend == AgentBackendKind.acp.rawValue,
               voiceJobOwner === coordinator, let live = running[row.id], !live.handle.isCancelled {
                return [.queued, .running, .waitingForPermission, .waitingForCompatibilityCLI, .waitingForInput].contains(row.status)
            }
            guard let id = UUID(uuidString: row.id),
                  let live = voiceWorkerForCoordinator(id: id, coordinator: coordinator), live.task?.isCancelled != true else { return false }
            return [.running, .waitingForInput, .waitingForPermission].contains(row.status)
        }.sorted { $0.createdAt < $1.createdAt }
    }
    /// SAME generic ACP slot; an unrelated Bridge cannot borrow the live conversation.
    func ownsVoiceACPWorker(id: UUID, coordinator: VoiceConversationCoordinator, bridge: TaskBridge) -> Bool {
        guard voiceJobOwner === coordinator, coordinator.taskBridge === bridge,
              let row = task(id: id.uuidString), row.hasVoiceOrigin, row.backend == "acp",
              case .worker? = running[row.id]?.handle else { return false }
        return true
    }
    @discardableResult
    func stopVoiceACPWorker(id: UUID, coordinator: VoiceConversationCoordinator, bridge: TaskBridge) -> Bool {
        guard ownsVoiceACPWorker(id: id, coordinator: coordinator, bridge: bridge),
              let current = task(id: id.uuidString),
              [.queued, .running, .waitingForPermission, .waitingForInput, .waitingForCompatibilityCLI].contains(current.status) else { return false }
        cancel(id.uuidString)
        return task(id: id.uuidString)?.status == .cancelled && lastPersistenceResult?.primaryCommitted == true
    }
    func voiceControlObservation(id: UUID) -> TaskControlObservation? {
        guard let handle = running[id.uuidString]?.handle else { return nil }
        if case .worker = handle, task(id: id.uuidString)?.hasVoiceOrigin == true,
           task(id: id.uuidString)?.backend == "acp", handle.isCancelled { return .cancelled }
        if case .returnedVoice = handle { return .returned }
        if case .voice(let value) = handle, value.task?.isCancelled == true { return .cancelled }
        return nil
    }
    func cancelVoiceWorker(id: UUID) -> Bool {
        guard let current = running[id.uuidString] else { return false }
        switch current.handle {
        case .voice(let value):
            value.worker.cancelVoiceObjective()
            value.task?.cancel()
        case .returnedVoice: break
        default: return false
        }
        let question = task(id: id.uuidString)?.pendingInteraction
        PermissionGate.shared.cancelPending(taskID: id.uuidString)
        // Retain the SAME cancelled operation until its actual return, even if
        // this primary commit fails; no worker may resume from the retained row.
        let saved = cancelVoiceObjective(id: id)
        if case .input(let request)? = question { VoicePlaybackDelivery.shared.withdrawQuestion(TaskID(id), requestID: request.id) }
        if voiceWorkerSnapshot(id: id)?.task == nil { running[id.uuidString] = nil }
        VoiceSession.shared.send(.task(.cancelled(TaskID(id))))
        return saved
    }

    /// A current live voice work revision uses the SAME canonical primary owner.
    @discardableResult
    func recordVoiceRevision(id: UUID, revision: Int, permissionRecipientSession: UUID? = nil, userWords: String? = nil) -> Bool {
        guard let current = task(id: id.uuidString), current.source == "voice",
              [.running, .waitingForPermission].contains(current.status),
              case .voice(let session, _)? = current.origin,
              AgentCaptureController.shared.isSessionActive,
              (AgentCaptureController.shared.sessionID == session
               || (current.status == .waitingForPermission
                   && permissionRecipientSession == AgentCaptureController.shared.sessionID)),
              let live = voiceWorkerSnapshot(id: id), live.task?.isCancelled == false,
              live.work.revision == revision,
              revision > current.revision else { return false }
        if current.status == .waitingForPermission {
            guard case .permission(let pending, _, let review?) = current.pendingInteraction,
                  pending.taskID == current.id, review.id == pending.id,
                  review.toolID == pending.toolID else { return false }
        }
        let expected = TaskWorkerWriteCondition(taskID: current.id, attempt: 0, leaseOwner: nil,
            status: current.status, voiceOrigin: current.origin, voiceRevision: current.revision,
            voicePermission: current.status == .waitingForPermission ? current.pendingInteraction : nil)
        let instructions = live.work.followUps.dropFirst(current.revision)
        guard instructions.count == revision - current.revision else { return false }
        let revisions = instructions.map {
            TaskJournalEventDraft(taskID: current.id, kind: .revisionRecorded, detail: $0, attempt: 0)
        }
        return update(id.uuidString, events: revisions, worker: expected) { row in
            row.revision = revision
            if let userWords { row.userWords = userWords }
            if current.status == .waitingForPermission {
                row.status = .running; row.pendingInteraction = nil; row.progress = "Working locally"
            }
        }.primaryCommitted
    }

    /// Existing unanswered question identity, not a generic instruction to restart.
    @discardableResult
    func resumeVoiceObjective(id: UUID, requestID: String, answer: String, sessionID: UUID? = nil, revision: Int? = nil) -> Bool {
        guard let sessionID, AgentCaptureController.shared.isSessionActive,
              AgentCaptureController.shared.sessionID == sessionID,
              let current = task(id: id.uuidString), current.source == "voice", current.status == .waitingForInput,
              case .voice(let ownerSession, _)? = current.origin, ownerSession == sessionID,
              case .input(let request) = current.pendingInteraction, request.taskID == current.id, request.id == requestID,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let live = voiceWorkerSnapshot(id: id) {
            guard live.task == nil, live.work.revision == current.revision else { return false }
        } else {
            guard voiceJobOwner == nil, running[id.uuidString] == nil else { return false }
        }
        guard revision == nil || (revision ?? 0) > current.revision else { return false }
        let expected = TaskWorkerWriteCondition(taskID: current.id, attempt: 0, leaseOwner: nil,
            status: current.status, voiceOrigin: current.origin, voiceRevision: current.revision,
            voiceInputRequestID: request.id)
        // The exact accepted answer advances one instruction before the Bridge
        // appends it to retained Work. Required facts share this primary commit.
        // Nil/jump compatibility revisions keep their existing metadata contract.
        let revisions: [TaskJournalEventDraft] = revision.map({ $0 > current.revision && $0 - current.revision == 1 }) == true
            ? [.init(taskID: current.id, kind: .revisionRecorded, detail: answer, attempt: 0)] : []
        let saved = update(id.uuidString, kinds: [.inputProvided], events: revisions, worker: expected) { task in
            task.status = .running; task.progress = "Working locally"
            task.pendingInteraction = nil; task.result = nil; task.failure = nil
            task.userWords = answer
            if let revision { task.revision = revision }
            // Reset only the positively owned question delivery in this exact resume.
            if case .voice? = current.origin { task.delivery = TaskDelivery.none; task.deliveryAttempts = 0 }
        }.primaryCommitted
        if saved && !SelfTest.isRunning {
            AgentActivityStore.shared.update(taskID: id.uuidString, kind: .thinking, title: "Continuing your task")
        }
        return saved
    }

    /// The caller stops the exact live worker regardless of this durable result.
    /// Failed persistence retains the prior row; it never authorizes continued work.
    @discardableResult
    func cancelVoiceObjective(id: UUID) -> Bool {
        guard let current = task(id: id.uuidString), current.source == "voice",
              [.running, .waitingForInput, .waitingForPermission].contains(current.status) else { return false }
        let expected: TaskWorkerWriteCondition?
        if current.status == .waitingForPermission {
            guard case .voice? = current.origin,
                  case .permission(let request, _, let review?) = current.pendingInteraction,
                  request.taskID == current.id, review.id == request.id,
                  review.toolID == request.toolID else { return false }
            // Immediate live cancellation already happened. Refusal preserves the exact
            // saved proposal; it never supplies a later grant or resumes this owner.
            expected = TaskWorkerWriteCondition(taskID: current.id, attempt: 0, leaseOwner: nil,
                status: current.status, voiceOrigin: current.origin, voiceRevision: current.revision,
                voicePermission: current.pendingInteraction)
        } else { expected = nil } // Preserve existing running/input cancellation contracts.
        let saved = update(id.uuidString, worker: expected, transitionThrough: .cancelling) { task in
            task.status = .cancelled
            task.pendingInteraction = nil
            task.progress = "Cancelled"
        }
        guard saved.primaryCommitted else { return false }
        if !SelfTest.isRunning { AgentActivityStore.shared.finish(taskID: id.uuidString, title: "Cancelled") }
        return true
    }

    func cancel(_ id: String) {
        // A public stop request cannot replace an already ended result.
        guard let row = task(id: id), !row.status.isTerminal else { return }
        // Immediate live control is independent of history/save admission.
        if let uuid = UUID(uuidString: id), voiceWorkerSnapshot(id: uuid) != nil {
            _ = cancelVoiceWorker(id: uuid)
            return
        }
        // Stop the SAME admitted scheduled operation immediately, even when its
        // durable cancellation is refused. Retain its slot until actual return;
        // a failed save still leaves the primary row's outcome unknown/running.
        let retainingCancelledOwner: Bool
        if case .typed(let live)? = running[id]?.handle {
            live.work.releaseTypedInput(); live.work.releaseTypedQuestion(); live.worker.cancelVoiceObjective(); live.task.cancel()
            retainingCancelledOwner = true
        } else if case .scheduled(let owner)? = running[id]?.handle {
            owner.cancel()
            retainingCancelledOwner = true
        } else if case .worker(let owner)? = running[id]?.handle,
                  let row = task(id: id), row.hasVoiceOrigin, row.backend == "acp" {
            // Existing generic ACP-by-voice operation: stop before even a refused
            // primary save and retain the SAME slot until its real callback return.
            owner.cancel()
            retainingCancelledOwner = true
        } else { retainingCancelledOwner = false }
        guard historyReadFailure == nil else { return }
        if PermissionGate.shared.hasRestoredRequest(taskID: id) {
            // This may be the visible card or a queued card. Its owner commits the
            // denied decision before the gate removes anything from either surface.
            PermissionGate.shared.cancelPending(taskID: id)
            guard let committed = task(id: id), committed.status == .cancelled,
                  committed.pendingInteraction == nil else { return }
            approvedCompatibilityTaskIDs.remove(id)
            approvedTaskIDs.remove(id)
            AgentActivityStore.shared.finish(taskID: id, title: "Cancelled")
            return
        }
        let current = task(id: id)
        let cancelCondition: TaskWorkerWriteCondition?
        if let current, hasWorkerAttemptRecord(current) {
            guard [.queued, .running, .recovering, .waitingForPermission, .waitingForInput].contains(current.status),
                  let durability = current.durability else { return }
            // A user can stop an old-owner saved task. This stored-row predicate
            // authorizes only the cancelled transition, never a live effect.
            if case .typed? = running[id]?.handle {
                // Stop request already reached the SAME Task. The durable stop
                // still requires its current revision and exact saved proposal.
                guard let expected = workerCondition(current, states: [current.status]) else { return }
                cancelCondition = expected
            } else {
                cancelCondition = TaskWorkerWriteCondition(taskID: id, attempt: durability.attempt,
                    leaseOwner: durability.leaseOwner, status: current.status)
            }
        } else { cancelCondition = nil }
        let admitted = update(id, worker: cancelCondition, transitionThrough: .cancelling) { task in
            task.status = .cancelled
            task.progress = "Cancelled"
            task.pendingInteraction = nil
        }
        guard admitted.primaryCommitted else { return }
        running[id]?.handle.cancel()
        if !retainingCancelledOwner { running[id] = nil }
        approvedCompatibilityTaskIDs.remove(id)
        approvedTaskIDs.remove(id)
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
        let admitted = update(taskID, kinds: [.permissionApproved]) { item in
            item.status = .queued
            item.progress = "Starting compatibility CLI once · weaker progress and permissions than ACP"
        }
        // A rejected save rolls back to the exact reviewable waiting row. Keep that
        // card available, and mint the one-shot token only after primary admission.
        guard admitted.primaryCommitted else { return }
        approvedCompatibilityTaskIDs.insert(taskID)
        running[taskID]?.handle.cancel()
        enqueueWorker(taskID)
    }

    func respondPermission(taskID: String, approved: Bool, duration: PermissionDuration = .once) {
        guard historyReadFailure == nil, let task = task(id: taskID),
              task.status == .waitingForPermission,
              case .permission(let request, _, _) = task.pendingInteraction else { return }
        // Restored approvals promise one exact retry. Do not silently turn a requested
        // standing grant into "once" or bypass the review/primary-commit gate.
        if approved, duration != .once { return }
        restorePendingInteractions()
        guard PermissionGate.shared.hasRestoredRequest(taskID: taskID) else { return }
        if approved {
            _ = PermissionGate.shared.respond(id: request.id, approved: true, duration: duration)
        } else {
            PermissionGate.shared.cancelPending(taskID: taskID)
        }
    }

    /// Called by the original task-bound producer before it leaves its permission
    /// request behind. A title alone cannot restore what the person was asked to approve.
    @discardableResult
    func parkPermission(_ request: PermissionRequest, origin: ActionOriginContext? = nil, review: ToolCallReview? = nil) -> Bool {
        guard historyReadFailure == nil, let id = request.taskID,
              let task = task(id: id), task.status == .running,
              request.toolID == task.tool, task.backend == AgentBackendKind.local.rawValue,
              isTypedOwner(task), origin?.isRemote != true,
              review == nil || (review?.id == request.id && review?.toolID == request.toolID) else { return false }
        return update(id) { item in
            item.pendingInteraction = .permission(request: request, origin: origin, review: review)
            item.status = .waitingForPermission
            item.progress = request.title
        }.primaryCommitted
    }

    /// Edits and confirmations are persisted by their existing review producer before
    /// it accepts a new visible value. A failed primary save leaves the old review intact.
    @discardableResult
    func persistPendingReview(taskID: String, requestID: String, review: ToolCallReview) -> Bool {
        guard historyReadFailure == nil, let task = task(id: taskID),
              task.status == .waitingForPermission, isTypedOwner(task),
              case .permission(let request, let origin, _) = task.pendingInteraction,
              request.id == requestID, review.id == requestID, request.taskID == taskID,
              review.toolID == request.toolID else { return false }
        if case .typed(let live)? = running[taskID]?.handle {
            guard !live.task.isCancelled, task.revision == live.work.revision else { return false }
            return updateWorker(task, states: [.waitingForPermission]) { item in
                item.pendingInteraction = .permission(request: request, origin: origin, review: review)
            }.primaryCommitted
        }
        return update(taskID) { item in
            item.pendingInteraction = .permission(request: request, origin: origin, review: review)
        }.primaryCommitted
    }

    /// Retains a question-only payload without guessing what an answer would change.
    /// The bound local-read producer below supplies the schema field for live continuation.
    @discardableResult
    func requestInput(taskID: String, question: String) -> Bool {
        guard historyReadFailure == nil, let task = task(id: taskID), task.status == .running,
              isTypedOwner(task), !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let request = TaskInputRequest(taskID: taskID, question: question)
        return parkInput(request).primaryCommitted
    }

    /// An incomplete bound local read asks its existing review question.
    /// Mutations, approved replays and independent owners keep their original refusal/review.
    @discardableResult
    func requestInput(taskID: String, parameter: String, toolID: String) -> Bool {
        guard let request = missingInputRequest(taskID: taskID, parameter: parameter, toolID: toolID) else { return false }
        return parkInput(request).primaryCommitted
    }

    private func missingInputRequest(taskID: String, parameter: String, toolID: String) -> TaskInputRequest? {
        guard historyReadFailure == nil, let task = task(id: taskID), task.status == .running,
              supportsBoundInput(toolID: toolID, parameter: parameter, arguments: task.arguments),
              isTypedOwner(task), task.backend == AgentBackendKind.local.rawValue,
              task.pendingInteraction == nil, let name = task.tool,
              let tool = AgentToolRegistry.shared.tool(named: name), tool.id == toolID,
              tool.source == .native, tool.risk <= .read,
              tool.parameters.contains(where: { $0.name == parameter && $0.isRequired }),
              (task.arguments[parameter] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard let field = missingInputField(tool: tool, arguments: task.arguments, parameter: parameter),
              !field.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TaskInputRequest(taskID: taskID, question: field.prompt, toolID: tool.id, argumentName: parameter)
    }

    /// Keep exact missing-file/text contracts and permit a typed directory choice.
    /// Never guess the search's default home root or replay a mutating question.
    private func supportsBoundInput(toolID: String, parameter: String, arguments: [String: String]) -> Bool {
        if toolID == "filesystem.read", parameter == "path" { return true }
        if toolID == "filesystem.tree", parameter == "path" { return true }
        return toolID == "filesystem.search" && parameter == "query"
            && !(arguments["folder"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One answer can continue only when that exact gap is the sole blocking issue.
    /// Other missing fields or placeholders need their existing complete review flow.
    private func missingInputField(tool: AgentTool, arguments: [String: String], parameter: String) -> ToolCallField? {
        let review = ToolCallReviewBuilder.review(id: tool.id, tool: tool, arguments: arguments)
        guard review.blockers.count == 1, let field = review.blockers.first,
              field.name == parameter, field.isRequired, field.problem == .missing else { return nil }
        return field
    }

    private func parkInput(_ request: TaskInputRequest) -> AgentTaskPersistenceResult {
        update(request.taskID) { item in
            item.pendingInteraction = .input(request)
            item.status = .waitingForInput
            item.progress = request.question
        }
    }

    /// Existing UI consumers can draw these exact requests and send the matching id
    /// back. Legacy title-only records deliberately supply no invented question.
    var pendingInputs: [TaskInputRequest] {
        guard historyReadFailure == nil else { return [] }
        return tasks.compactMap { task in
            guard task.status == .waitingForInput, isTypedOwner(task),
                  case .input(let request) = task.pendingInteraction,
                  request.taskID == task.id else { return nil }
            return request
        }
    }

    /// Called after application services are ready. The existing gate and review
    /// store remain the single card owner; no continuation from the old process survives.
    func restorePendingInteractions() {
        guard historyReadFailure == nil else { return }
        for task in tasks where task.status == .waitingForPermission {
            guard isTypedOwner(task), task.backend == AgentBackendKind.local.rawValue,
                  case .permission(let request, let origin, let review) = task.pendingInteraction,
                  request.taskID == task.id, request.toolID == task.tool,
                  origin?.isRemote != true else { continue }
            PermissionGate.shared.restore(request, review: review, onReviewChange: { [weak self] edited in
                self?.persistPendingReview(taskID: task.id, requestID: request.id, review: edited) ?? false
            }, onDecision: { [weak self] approved, arguments in
                self?.respondRestoredPermission(taskID: task.id, requestID: request.id,
                    approved: approved, arguments: arguments) ?? false
            })
        }
    }

    /// The card may dismiss itself only after this primary transition commits. A
    /// rejected save retains the original card and supplies no one-shot token.
    @discardableResult
    func respondRestoredPermission(taskID: String, requestID: String, approved: Bool,
                                   arguments: [String: String]) -> Bool {
        guard historyReadFailure == nil, let task = task(id: taskID),
              task.status == .waitingForPermission, isTypedOwner(task),
              task.backend == AgentBackendKind.local.rawValue,
              case .permission(let request, let origin, let review) = task.pendingInteraction,
              request.id == requestID, request.taskID == taskID,
              request.toolID == task.tool, origin?.isRemote != true else { return false }
        let exactArguments = review?.executionArguments(mergedOver: request.arguments) ?? request.arguments
        guard !approved || arguments == exactArguments else { return false }
        let admitted = update(taskID, kinds: [approved ? .permissionApproved : .permissionDenied]) { item in
            if approved {
                // Preserve all authorization pins that do not appear as editable fields.
                item.arguments = arguments.filter { !$0.key.hasPrefix("_") }
                for (key, value) in request.arguments where key.hasPrefix("_") {
                    item.arguments[key] = value
                }
                item.status = .queued
                item.progress = "Ready"
            } else {
                item.status = .cancelled
                item.failure = "Permission denied."
                item.pendingInteraction = nil
            }
        }
        guard admitted.primaryCommitted else { return false }
        if approved {
            approvedTaskIDs.insert(taskID)
            enqueueWorker(taskID)
        }
        return true
    }

    private func isTypedOwner(_ task: AgentTask) -> Bool {
        ["user", "text", "selftest"].contains(task.source) && task.scheduleID == nil
    }

    /// Consumed by the local backend immediately before the exact approved retry fires.
    func hasCompatibilityApprovalForTesting(taskID: String) -> Bool {
        SelfTest.isRunning && store.allowsHarnessPersistence && approvedCompatibilityTaskIDs.contains(taskID)
    }

    func consumePermissionApproval(taskID: String) -> Bool {
        approvedTaskIDs.remove(taskID) != nil
    }

    /// Read-only eligibility for the existing input card. It never supplies a binding
    /// for legacy questions or turns another owner's work into a local retry.
    func canRespondInput(taskID: String, requestID: String) -> Bool {
        inputField(taskID: taskID, requestID: requestID) != nil
    }

    func inputField(taskID: String, requestID: String) -> ToolCallField? {
        guard historyReadFailure == nil, let task = task(id: taskID),
              task.status == .waitingForInput,
              case .input(let request) = task.pendingInteraction,
              request.id == requestID, let tool = inputTool(task: task, request: request),
              let key = request.argumentName else { return nil }
        return missingInputField(tool: tool, arguments: task.arguments, parameter: key)
    }

    func inputAnswerProblem(taskID: String, requestID: String, text: String) -> String? {
        guard historyReadFailure == nil, let task = task(id: taskID),
              task.status == .waitingForInput, case .input(let request) = task.pendingInteraction,
              request.id == requestID, let tool = inputTool(task: task, request: request),
              let key = request.argumentName else { return "This saved question can’t safely continue. You can stop this task." }
        var arguments = task.arguments
        arguments[key] = text
        if let problem = ToolCallValidation.problem(tool: tool, arguments: arguments) { return problem }
        if missingInputField(tool: tool, arguments: task.arguments, parameter: key)?.kind == .folder {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: text, isDirectory: &directory), directory.boolValue else {
                return "Choose a folder that exists."
            }
        }
        return nil
    }

    private func inputTool(task: AgentTask, request: TaskInputRequest) -> AgentTool? {
        guard let boundTool = request.toolID, let key = request.argumentName,
              supportsBoundInput(toolID: boundTool, parameter: key, arguments: task.arguments),
              isTypedOwner(task), task.backend == AgentBackendKind.local.rawValue,
              request.taskID == task.id, let name = task.tool,
              let tool = AgentToolRegistry.shared.tool(named: name), tool.id == boundTool,
              tool.source == .native, tool.risk <= .read,
              tool.parameters.contains(where: { $0.name == key && $0.isRequired }),
              (task.arguments[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              missingInputField(tool: tool, arguments: task.arguments, parameter: key) != nil
        else { return nil }
        if boundTool == "filesystem.tree", request.question != "Which folder?" { return nil }
        return tool
    }

    @discardableResult
    func respondInput(taskID: String, text: String, requestID: String? = nil) -> Bool {
        guard historyReadFailure == nil,
              var task = task(id: taskID), task.status == .waitingForInput,
              case .input(let request) = task.pendingInteraction,
              requestID == request.id, let tool = inputTool(task: task, request: request),
              let key = request.argumentName else { return false }
        task.arguments[key] = text
        guard inputAnswerProblem(taskID: taskID, requestID: request.id, text: text) == nil else { return false }
        task.status = .queued
        task.pendingInteraction = nil
        let admitted = updateRecord(task, kinds: [.inputProvided])
        guard admitted.primaryCommitted else { return false }
        enqueueWorker(taskID)
        return true
    }

    private func ownsLocalAttempt(_ task: AgentTask) -> Bool {
        isTypedOwner(task) && task.backend == AgentBackendKind.local.rawValue
    }

    /// Normal protocol attempts share the same existing slot; compatibility remains unbound.
    private func ownsTypedACPAttempt(_ task: AgentTask) -> Bool {
        (isTypedOwner(task) || task.hasVoiceOrigin) && task.backend == AgentBackendKind.acp.rawValue
            && task.compatibilityCLI == nil && task.compatibilityCommand == nil
    }

    private func ownsScheduledAttempt(_ task: AgentTask) -> Bool {
        task.source == AgentTask.scheduledSource && task.scheduleID != nil
            && ["local", "apple", "openrouter"].contains(task.backend)
            && task.durability?.runtimeClass == .scheduledResearch
    }

    private func ownsWorkerAttempt(_ task: AgentTask) -> Bool {
        ownsLocalAttempt(task) || ownsTypedACPAttempt(task) || ownsScheduledAttempt(task)
    }

    private func hasWorkerAttemptRecord(_ task: AgentTask) -> Bool {
        guard ownsWorkerAttempt(task), let durability = task.durability else { return false }
        return durability.hasTypedLocalAttemptRecord
    }

    private func hasLocalAttemptRecord(_ task: AgentTask) -> Bool {
        guard ownsLocalAttempt(task), let durability = task.durability else { return false }
        return durability.hasTypedLocalAttemptRecord
    }

    private func workerCondition(_ captured: AgentTask, states: [AgentTaskStatus]) -> TaskWorkerWriteCondition? {
        if captured.hasVoiceOrigin, captured.backend == AgentBackendKind.acp.rawValue {
            // Once admitted, background work survives capture/session closure.
            // Its exact captured row and SAME live Task still fence every callback.
            guard self.task(id: captured.id)?.origin == captured.origin,
                  let current = running[captured.id], !current.handle.isCancelled else { return nil }
        }
        guard hasWorkerAttemptRecord(captured), let durability = captured.durability,
              durability.attemptStartedAt != nil,
              durability.leaseOwner == String(ProcessInfo.processInfo.processIdentifier),
              let current = task(id: captured.id), states.contains(current.status),
              current.durability?.attempt == durability.attempt,
              current.durability?.leaseOwner == durability.leaseOwner else { return nil }
        let typedRevision: Int?
        if case .typed(let live)? = running[captured.id]?.handle {
            guard current.source == "text", current.origin == .typed,
                  live.work.id.uuidString == current.id else { return nil }
            typedRevision = current.revision
        } else { typedRevision = nil }
        return TaskWorkerWriteCondition(taskID: captured.id, attempt: durability.attempt,
            leaseOwner: durability.leaseOwner, status: current.status, typedRevision: typedRevision,
            typedPending: typedRevision == nil ? nil : current.pendingInteraction)
    }

    @discardableResult
    private func updateWorker(_ captured: AgentTask, states: [AgentTaskStatus] = [.running],
                              transitionThrough: TaskState? = nil, mutate: (inout AgentTask) -> Void) -> AgentTaskPersistenceResult {
        if !ownsWorkerAttempt(captured) {
            // Expected late callbacks from an entered unbound backend can return
            // after a committed stop. Refuse here before the internal producer
            // assertion; a returned error must not replace the saved terminal row.
            guard let current = task(id: captured.id) else { return .loadFailed }
            guard !current.status.isTerminal else {
                lastPersistenceResult = .endedTask
                return .endedTask
            }
            guard states.contains(current.status) else {
                // A genuine late unbound return cannot finish a parked successor.
                // Reject expected external callback state before the core assertion.
                lastPersistenceResult = .invalidTransition
                return .invalidTransition
            }
            return update(captured.id, transitionThrough: transitionThrough, mutate: mutate)
        }
        guard let expected = workerCondition(captured, states: states) else { return .loadFailed }
        return update(captured.id, worker: expected, transitionThrough: transitionThrough, mutate: mutate)
    }

    private func enqueueWorker(_ id: String) {
        // The same execution slot starts unbound; only primary admission binds it.
        running[id] = RunningWorker(handle: .worker(Task { @MainActor [weak self] in
            await self?.execute(id)
        }))
    }

    private func releaseWorker(_ captured: AgentTask) {
        if !ownsWorkerAttempt(captured) { running[captured.id] = nil; return }
        // A queued explicit continuation may already own the next handle before its
        // asynchronous execute allocates the next attempt. Do not remove that handle.
        guard let current = task(id: captured.id), current.status != .queued,
              current.durability?.attempt == captured.durability?.attempt,
              current.durability?.leaseOwner == captured.durability?.leaseOwner,
              let binding = running[captured.id]?.binding,
              binding.attempt == captured.durability?.attempt,
              binding.leaseOwner == captured.durability?.leaseOwner,
              binding.startedAt == captured.durability?.attemptStartedAt else { return }
        running[captured.id] = nil
    }

    private func execute(_ id: String) async {
        guard historyReadFailure == nil else { return }
        guard var task = task(id: id) else { return }
        guard !Task.isCancelled, task.status == .queued else {
            // A voice ACP operation can be cancelled synchronously before this
            // SAME Task first enters. There is no backend/peer to drain here.
            if Task.isCancelled, task.hasVoiceOrigin, task.backend == AgentBackendKind.acp.rawValue,
               case .worker(let queuedOperation)? = running[id]?.handle, queuedOperation.isCancelled,
               let voiceID = UUID(uuidString: id) {
                running[id] = nil
                if task.status == .cancelled {
                    VoiceSession.shared.send(.task(.cancelled(TaskID(voiceID))))
                } else {
                    voiceJobOwner?.voiceWorkerFinished(id: voiceID, request: task.objective,
                        outcome: .failed("I couldn't confirm the task's saved result."))
                }
            }
            return
        }
        let startCondition: TaskWorkerWriteCondition?
        if ownsWorkerAttempt(task) {
            var durability = task.durability ?? TaskDurability()
            guard durability.attempt < Int.max else { rejectStart(id, result: .sqlFailed); return }
            startCondition = TaskWorkerWriteCondition(taskID: id, attempt: durability.attempt,
                leaseOwner: durability.leaseOwner, status: .queued)
            durability.attempt += 1
            durability.leaseOwner = String(ProcessInfo.processInfo.processIdentifier)
            let began = progressDate()
            durability.attemptStartedAt = began
            durability.heartbeatAt = began
            durability.lastProgressAt = began
            let descriptor = task.tool.flatMap { AgentToolRegistry.shared.tool(named: $0) }
            durability.runtimeClass = ownsTypedACPAttempt(task) ? .acpWorker
                : (descriptor?.source == .native && descriptor?.namespace == .browser
                   ? .browserOrMCP : .localDeterministic)
            durability.resumePolicy = .neverAuto
            task.durability = durability
            if task.startedAt == nil { task.startedAt = began }
        } else { startCondition = nil }
        task.status = .running
        task.finishedAt = nil
        task.progress = "Starting…"
        let started = updateRecord(task, worker: startCondition)
        guard started.primaryCommitted else { rejectStart(id, result: started); return }
        if ownsWorkerAttempt(task), let metadata = task.durability,
           metadata.attempt > 0, let owner = metadata.leaseOwner,
           let began = metadata.attemptStartedAt {
            running[id]?.binding = TaskWorkerBinding(taskID: id, attempt: metadata.attempt,
                leaseOwner: owner, startedAt: began)
            if let observed = workerBinding(taskID: id) {
                Log.app.debug("Task worker admitted: attempt \(observed.attempt), owner \(observed.leaseOwner, privacy: .public)")
            }
        }
        var voiceTerminalObserved = false
        var voiceReturnFailure: String?
        defer {
            releaseWorker(task)
            // This is actual SAME operation return, not merely a cancelled token
            // or a refused SQL write. Stored uncertainty remains on the primary row.
            if task.hasVoiceOrigin, task.backend == AgentBackendKind.acp.rawValue,
               running[id] == nil, !voiceTerminalObserved, let voiceID = UUID(uuidString: id) {
                if self.task(id: id)?.status == .cancelled {
                    VoiceSession.shared.send(.task(.cancelled(TaskID(voiceID))))
                } else if Task.isCancelled || voiceReturnFailure != nil
                    || [.running, .failed].contains(self.task(id: id)?.status ?? .queued) {
                    let reason = voiceReturnFailure ?? self.task(id: id)?.failure
                        ?? "I couldn't confirm the task's saved result."
                    voiceJobOwner?.voiceWorkerFinished(id: voiceID, request: task.objective, outcome: .failed(reason))
                }
            }
            if SelfTest.isRunning && store.allowsHarnessPersistence { backendExitForTesting?() }
        }

        do {
            let outcome: AgentTaskOutcome
            var usageIDs = ModelPassRecorder.correlation ?? UsageCorrelation()
            usageIDs.taskID = UsageLog.sanitiseTaskID(id)
            outcome = try await ModelPassRecorder.$correlation.withValue(usageIDs) {
                try await TaskEventJournal.$current.withValue(journalContext(taskID: id)) {
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
            }
            try Task.checkCancellation()
            // P1-5: nested tool calls park their reference and link on the ledger; fold
            // them in beside whatever the backend itself returned, and keep them on the
            // task so the terminal card can link them after a relaunch.
            if ownsWorkerAttempt(task), workerCondition(task, states: [.running]) == nil { return }
            let captured = AgentArtifactLedger.takeRecords(taskID: id)
            let finished = updateWorker(task) { item in
                item.status = outcome.status
                item.progress = outcome.progress
                item.result = outcome.result
                item.artifactRecords = AgentArtifact.merging(captured, into: outcome.artifactRecords)
                item.failure = outcome.failure
                item.pendingInteraction = nil
            }
            guard finished.primaryCommitted else {
                voiceReturnFailure = finished.diagnostic
                if let diagnostic = finished.diagnostic { announce(diagnostic) }
                return
            }
            if projectsActivity { AgentActivityStore.shared.finish(
                taskID: id,
                title: outcome.status == .completed ? (outcome.result ?? "Done") : (outcome.failure ?? "Failed")
            ) }
            let canonicalVoiceACP = task.hasVoiceOrigin && task.backend == AgentBackendKind.acp.rawValue
            let canonicalVoiceCompletion = canonicalVoiceACP && outcome.status == .completed
            if let result = outcome.result {
                announce(result, queueSpeech: !canonicalVoiceCompletion)
            } else if let failure = outcome.failure {
                announce(failure)
            }
            if canonicalVoiceACP, let voiceID = UUID(uuidString: id) {
                voiceJobOwner?.voiceWorkerFinished(id: voiceID, request: task.objective, outcome: outcome)
                voiceTerminalObserved = [.completed, .failed].contains(outcome.status)
                if canonicalVoiceCompletion {
                    if SelfTest.isRunning, ["--selftest-voice-delivery", "--selftest-voice-work-lifecycle"].contains(SelfTest.requested ?? ""), store.allowsHarnessPersistence {
                        completionDeliveryForTesting?(TaskID(voiceID))
                    }
                    if projectsActivity { _ = OutputScheduler.shared.enqueueCompletion(TaskID(voiceID)) }
                }
            }
            announceArtifacts(taskID: id)
        } catch is CancellationError {
            let cancelled = updateWorker(task, transitionThrough: .cancelling) { $0.status = .cancelled }
            if cancelled.primaryCommitted { announce("Cancelled.") }
        } catch let error as AgentError {
            if ownsWorkerAttempt(task), workerCondition(task, states: [.running, .waitingForPermission]) == nil { return }
            if case .missingArgument(let parameter, let toolID) = error,
               let request = missingInputRequest(taskID: id, parameter: parameter, toolID: toolID) {
                let admitted = updateWorker(task) { item in
                    item.pendingInteraction = .input(request)
                    item.status = .waitingForInput
                    item.progress = request.question
                }
                if admitted.primaryCommitted {
                    if projectsActivity { AgentActivityStore.shared.update(
                        taskID: id, kind: .waiting, title: "Waiting for your answer", detail: request.question
                    ) }
                } else {
                    let failure = admitted.diagnostic ?? "Your question couldn’t be saved. Nothing was run."
                    let failed = updateWorker(task) { item in item.status = .failed; item.failure = failure }
                    guard failed.primaryCommitted else { announce(failure); return }
                    if projectsActivity { AgentActivityStore.shared.finish(taskID: id, title: failure) }
                    announce(failure)
                }
                return
            }
            if case .acpHandshakeUnavailable(let request) = error {
                let parked = updateWorker(task) { item in
                    item.status = .waitingForCompatibilityCLI
                    item.progress = "ACP unavailable · compatibility CLI is optional"
                    item.failure = nil
                    item.compatibilityCommand = request.command
                    item.compatibilityCLI = request.cli
                    item.compatibilityDirectory = request.directory
                }
                guard parked.primaryCommitted else {
                    if let diagnostic = parked.diagnostic { announce(diagnostic) }
                    return
                }
                approvedCompatibilityTaskIDs.remove(id)
                if projectsActivity { AgentActivityStore.shared.update(
                    taskID: id,
                    kind: .waiting,
                    title: "ACP unavailable",
                    detail: "Compatibility mode requires a one-shot approval and has weaker progress and permissions."
                ) }
                return
            }
            if case .needsPermission(let title) = error {
                if ownsLocalAttempt(task), workerCondition(task, states: [.waitingForPermission]) != nil {
                    restorePendingInteractions()
                    return // The exact capture producer already committed this parked row.
                }
                let parked = updateWorker(task) { item in
                    item.status = .waitingForPermission
                    item.progress = title
                }
                guard parked.primaryCommitted else {
                    if let diagnostic = parked.diagnostic { announce(diagnostic) }
                    return
                }
                restorePendingInteractions()
                return
            }
            let failed = updateWorker(task, states: [.running, .waitingForPermission]) { item in
                item.status = .failed
                item.failure = error.localizedDescription
            }
            guard failed.primaryCommitted else {
                if let diagnostic = failed.diagnostic { announce(diagnostic) }
                return
            }
            voiceReturnFailure = error.localizedDescription
            if projectsActivity { AgentActivityStore.shared.finish(taskID: id, title: error.localizedDescription) }
            announce(error.localizedDescription)
        } catch {
            if ownsWorkerAttempt(task), workerCondition(task, states: [.running]) == nil { return }
            let failed = updateWorker(task) { item in
                item.status = .failed
                item.failure = error.localizedDescription
            }
            guard failed.primaryCommitted else {
                if let diagnostic = failed.diagnostic { announce(diagnostic) }
                return
            }
            voiceReturnFailure = error.localizedDescription
            announce(error.localizedDescription)
        }
    }

    /// Consume the existing legal table at the one mutation producer. The stored
    /// queued successor is an admitted input/approval continuation, not a restart.
    private func allowsStateChange(from before: AgentTask, to next: AgentTask,
                                   kinds: [TaskEventKind], through: TaskState?) -> Bool {
        if before.status == next.status { return true }
        if before.status == .recovering {
            // Launch-only held ownership stays unknown; an explicit stop may end it.
            return through == .cancelling && next.status == .cancelled
        }
        guard let old = before.status.contractState, let new = next.status.contractState else { return false }
        if TaskState.legal[old]?.contains(new) == true { return true }
        if through == .cancelling || kinds.contains(.permissionDenied) {
            return new == .cancelled && TaskState.legal[old]?.contains(.cancelling) == true
                && TaskState.legal[.cancelling]?.contains(new) == true
        }
        guard next.status == .queued, TaskState.legal[old]?.contains(.running) == true else { return false }
        if before.status == .waitingForInput, kinds.contains(.inputProvided),
           case .input(let request) = before.pendingInteraction {
            return request.taskID == before.id && next.pendingInteraction == nil
        }
        if before.status == .waitingForPermission, kinds.contains(.permissionApproved),
           case .permission(let request, _, _) = before.pendingInteraction {
            return request.taskID == before.id && next.pendingInteraction == before.pendingInteraction
        }
        return before.status == .waitingForCompatibilityCLI && kinds.contains(.permissionApproved)
            && ACPCompatibilityCLIBackend.request(for: before) != nil
    }

    /// Intentional legal-table probes only over a real admitted isolated voice row.
    /// This does not create work, manufacture a state owner or suppress public errors.
    func transitionForTesting(id: UUID, status: AgentTaskStatus) -> Bool? {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              store.allowsHarnessPersistence, task(id: id.uuidString)?.hasVoiceOrigin == true else { return nil }
        return update(id.uuidString, assertInvalidTransition: false) { $0.status = status }.primaryCommitted
    }

    @discardableResult
    private func update(_ id: String, kinds: [TaskEventKind] = [], events: [TaskJournalEventDraft] = [],
                        worker: TaskWorkerWriteCondition? = nil, activityOnly: Bool = false,
                        assertInvalidTransition: Bool = true, transitionThrough: TaskState? = nil, mutate: (inout AgentTask) -> Void) -> AgentTaskPersistenceResult {
        guard historyReadFailure == nil else { return .loadFailed }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return .loadFailed }
        let before = tasks[index]
        let expected = worker ?? (hasWorkerAttemptRecord(before)
            ? TaskWorkerWriteCondition(taskID: before.id, attempt: before.durability!.attempt,
                leaseOwner: before.durability!.leaseOwner, status: before.status) : nil)
        var proposed = before
        mutate(&proposed)
        guard !before.status.isTerminal || proposed.status == before.status else {
            // Public stale callbacks are checked at their boundary. Reaching this
            // internal fence is a producer programming error; never write it.
            Log.app.error("Refused ended task transition: \(before.status.rawValue, privacy: .public) to \(proposed.status.rawValue, privacy: .public)")
            lastPersistenceResult = .endedTask
            #if DEBUG
            assertionFailure("An ended task cannot change state")
            #endif
            return .endedTask
        }
        guard allowsStateChange(from: before, to: proposed, kinds: kinds, through: transitionThrough) else {
            Log.app.error("Refused task transition: \(before.status.rawValue, privacy: .public) to \(proposed.status.rawValue, privacy: .public)")
            lastPersistenceResult = .invalidTransition
            #if DEBUG
            if assertInvalidTransition { assertionFailure("Task transition is not legal") }
            #endif
            return .invalidTransition
        }
        tasks[index] = proposed
        // Reuse the genuine transition event; display metadata must not consume a
        // second worker/activity clock observation or manufacture another event.
        let transitions = transitionEvents(from: before, to: tasks[index], kinds: kinds)
        if before.status != .running, tasks[index].status == .running, tasks[index].startedAt == nil {
            tasks[index].startedAt = transitions.first { $0.kind == .workerStarted }?.at
        }
        let terminal: Set<AgentTaskStatus> = [.completed, .failed, .cancelled]
        if !terminal.contains(before.status), terminal.contains(tasks[index].status) {
            tasks[index].finishedAt = transitions.first {
                [.jobCompleted, .jobFailed, .jobCancelled].contains($0.kind)
            }?.at
        }
        let result = persist(events: transitions + events,
                             worker: expected, activityBefore: activityOnly ? before : nil)
        if !result.primaryCommitted { tasks[index] = before }
        return result
    }

    @discardableResult
    private func updateRecord(_ task: AgentTask, kinds: [TaskEventKind] = [],
                              worker: TaskWorkerWriteCondition? = nil) -> AgentTaskPersistenceResult {
        update(task.id, kinds: kinds, worker: worker) { $0 = task }
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
        if let row = task(id: id), row.hasVoiceOrigin, row.backend == AgentBackendKind.acp.rawValue,
           let voiceID = UUID(uuidString: id) {
            voiceJobOwner?.voiceWorkerFinished(id: voiceID, request: row.objective,
                outcome: .failed(result.diagnostic ?? "I couldn't start that task."))
        }
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
        var events = result.map { kind in
            var event = TaskJournalEventDraft(taskID: task.id, kind: kind, attempt: attempt)
            if kind == .workerStarted, hasWorkerAttemptRecord(task), let began = task.durability?.attemptStartedAt {
                event.at = began
            }
            return event
        }
        let added = task.artifacts.filter { !before.artifacts.contains($0) }
        if !added.isEmpty {
            events.append(TaskJournalEventDraft(taskID: task.id, kind: .artifactCaptured,
                detail: "count:\(added.count)", attempt: attempt))
        }
        return events
    }

    func journalContext(taskID: String) -> TaskJournalContext? {
        guard let task = task(id: taskID) else { return nil }
        let typedOperation = UUID(uuidString: taskID).flatMap { typedWorkerSnapshot(id: $0)?.task }
        let origin: ActionOriginContext?
        let restoredPermission: PermissionRequest?
        let restoredArguments: [String: String]?
        if case .permission(let request, let savedOrigin, let review) = task.pendingInteraction {
            origin = savedOrigin
            restoredPermission = request
            restoredArguments = review?.executionArguments(mergedOver: request.arguments) ?? request.arguments
        } else {
            origin = nil
            restoredPermission = nil
            restoredArguments = nil
        }
        let capture: (@MainActor @Sendable (PermissionRequest, ActionOriginContext?, ToolCallReview?) -> Bool)?
        if case .typed(let live)? = running[taskID]?.handle {
            capture = { [weak self, weak work = live.work, weak worker = live.worker] request, origin, review in
                guard let self, let work, let worker, request.taskID == taskID,
                      let current = self.task(id: taskID), current.status == .running,
                      let slot = self.typedWorkerSnapshot(id: work.id), slot.work === work,
                      slot.worker === worker, !slot.task.isCancelled,
                      current.revision == work.revision, origin?.isRemote != true,
                      let review, review.id == request.id, review.toolID == request.toolID else { return false }
                guard let typedOperation, slot.task == typedOperation else { return false }
                let saved = self.updateWorker(current) { item in
                    item.tool = request.toolID
                    item.pendingInteraction = .permission(request: request, origin: origin, review: review)
                    item.status = .waitingForPermission; item.progress = request.title
                }.primaryCommitted
                if saved {
                    ToolCallReviewStore.shared.setPersistenceHandler(id: request.id) { [weak self] edited in
                        self?.persistPendingReview(taskID: taskID, requestID: request.id, review: edited) ?? false
                    }
                }
                return saved
            }
        } else if isTypedOwner(task), task.backend == AgentBackendKind.local.rawValue, task.tool != nil {
            capture = { [weak self] request, origin, review in
                guard request.taskID == taskID, let self, let current = self.task(id: taskID) else { return false }
                if self.hasLocalAttemptRecord(task), self.workerCondition(task, states: [.running]) == nil { return false }
                // A nested or independently owned request keeps its existing caller;
                // this hook supplies no storage/recovery proof for that operation.
                guard request.toolID == current.tool, origin?.isRemote != true else { return true }
                if !self.hasLocalAttemptRecord(task) { return self.parkPermission(request, origin: origin, review: review) }
                guard request.toolID == current.tool, request.taskID == taskID,
                      review == nil || (review?.id == request.id && review?.toolID == request.toolID) else { return false }
                return self.updateWorker(task) { item in
                    item.pendingInteraction = .permission(request: request, origin: origin, review: review)
                    item.status = .waitingForPermission
                    item.progress = request.title
                }.primaryCommitted
            }
        } else { capture = nil }
        let validity: (@MainActor @Sendable () -> Bool)?
        if hasWorkerAttemptRecord(task) {
            validity = { [weak self] in
                guard let self, let worker = self.running[taskID], !worker.handle.isCancelled,
                      let binding = worker.binding, binding.taskID == taskID,
                      binding.attempt == task.durability?.attempt,
                      binding.leaseOwner == task.durability?.leaseOwner,
                      binding.startedAt == task.durability?.attemptStartedAt,
                      let expected = self.workerCondition(task, states: [.running]) else { return false }
                if let typedOperation {
                    guard let id = UUID(uuidString: taskID), self.typedWorkerSnapshot(id: id)?.task == typedOperation else { return false }
                }
                if SelfTest.isRunning && !self.store.allowsHarnessPersistence { return true }
                let observed = self.store.workerPrimaryObservation(expected)
                // Primary acceptance is authority only while this exact live handle remains bound.
                guard let currentWorker = self.running[taskID], !currentWorker.handle.isCancelled,
                      currentWorker.binding == binding else { return false }
                self.running[taskID]?.primaryObservation = observed
                if let cached = self.running[taskID]?.primaryObservation {
                    Log.app.debug("Task primary check: attempt \(binding.attempt), outcome \(cached.outcome.rawValue, privacy: .public)")
                }
                return observed.outcome == .accepted
            }
        } else { validity = nil }
        let observeACPSession: (@MainActor @Sendable (ACPSession) -> Void)?
        if ownsTypedACPAttempt(task) {
            observeACPSession = { [weak self] session in
                guard let self, let binding = self.workerBinding(taskID: taskID),
                      binding.attempt == task.durability?.attempt,
                      binding.leaseOwner == task.durability?.leaseOwner,
                      binding.startedAt == task.durability?.attemptStartedAt,
                      self.running[taskID]?.acpSession == nil else { return }
                self.running[taskID]?.acpSession = session
            }
        } else { observeACPSession = nil }
        let observeToolInvocation: (@MainActor @Sendable (UUID, String, Bool) -> Void)?
        if hasLocalAttemptRecord(task) {
            observeToolInvocation = { [weak self] receiptID, toolID, entered in
                guard let self, let binding = self.workerBinding(taskID: taskID),
                      binding.attempt == task.durability?.attempt,
                      binding.leaseOwner == task.durability?.leaseOwner,
                      binding.startedAt == task.durability?.attemptStartedAt,
                      let prior = self.running[taskID]?.toolBackingObservation,
                      prior.binding == binding, prior.receiptID == receiptID,
                      prior.toolID == toolID, prior.state == .entryAdmitted else { return }
                self.running[taskID]?.toolBackingObservation?.invocationInFlight = entered
                if SelfTest.isRunning, self.store.allowsHarnessPersistence,
                   let observed = self.running[taskID]?.toolBackingObservation {
                    self.toolInvocationForTesting?(observed)
                }
            }
        } else { observeToolInvocation = nil }
        return TaskJournalContext(taskID: taskID, attempt: task.durability?.attempt ?? 0, record: { [weak self] event in
            guard event.taskID == taskID, let self, self.task(id: taskID) != nil else { return false }
            if let typedOperation {
                guard let id = UUID(uuidString: taskID), self.typedWorkerSnapshot(id: id)?.task == typedOperation else { return false }
            }
            if self.hasWorkerAttemptRecord(task) {
                if self.ownsScheduledAttempt(task) {
                    guard let worker = self.running[taskID], !worker.handle.isCancelled,
                          let binding = worker.binding, binding.attempt == task.durability?.attempt,
                          binding.leaseOwner == task.durability?.leaseOwner,
                          binding.startedAt == task.durability?.attemptStartedAt else { return false }
                }
                let states: [AgentTaskStatus]
                switch event.kind {
                case .heartbeat:
                    guard self.ownsTypedACPAttempt(task), event.detail == "acp.activity",
                          let worker = self.running[taskID], !worker.handle.isCancelled,
                          let binding = worker.binding, binding.taskID == taskID,
                          binding.attempt == task.durability?.attempt,
                          binding.leaseOwner == task.durability?.leaseOwner,
                          binding.startedAt == task.durability?.attemptStartedAt else { return false }
                    states = [.running]
                case .permissionRequested, .permissionApproved, .permissionDenied:
                    // A primary row alone cannot authorize a released or cancelled
                    // callback. Check its exact existing live handle before the same
                    // worker-conditioned permission transaction, including waiting.
                    guard let worker = self.running[taskID], !worker.handle.isCancelled,
                          let binding = worker.binding, binding.taskID == taskID,
                          binding.attempt == task.durability?.attempt,
                          binding.leaseOwner == task.durability?.leaseOwner,
                          binding.startedAt == task.durability?.attemptStartedAt else { return false }
                    states = [.running, .waitingForPermission]
                default: states = [.running]
                }
                guard event.attempt == task.durability?.attempt,
                      let expected = self.workerCondition(task, states: states) else { return false }
                if case .typed(let live)? = self.running[taskID]?.handle,
                   event.kind == .permissionApproved || event.kind == .permissionDenied {
                    guard let current = self.task(id: taskID), current.status == .waitingForPermission,
                          current.revision == live.work.revision,
                          case .permission(let request, _, _) = current.pendingInteraction,
                          request.taskID == taskID else { return false }
                    return self.update(taskID, events: [event], worker: expected) { item in
                        item.status = .running; item.pendingInteraction = nil; item.progress = "Working"
                    }.primaryCommitted
                }
                if event.kind == .heartbeat {
                    let prior = self.task(id: taskID)?.durability
                    let now = max(self.progressDate(), max(prior?.heartbeatAt ?? .distantPast,
                                                          prior?.lastProgressAt ?? .distantPast))
                    var stamped = event
                    stamped.at = now
                    return self.update(taskID, events: [stamped], worker: expected, activityOnly: true) { item in
                        item.durability?.heartbeatAt = now
                        item.durability?.lastProgressAt = now
                    }.primaryCommitted
                }
                if event.kind == .toolStarted || event.kind == .toolCompleted {
                    let prior = self.task(id: taskID)?.durability
                    if event.kind == .toolStarted {
                        guard let id = event.receiptID,
                              let receipt = (self.receiptStore ?? .shared).receipt(for: id),
                              receipt.taskID == taskID, receipt.taskAttempt == expected.attempt,
                              receipt.taskLeaseOwner == expected.leaseOwner,
                              receipt.status == .fired, receipt.events.last?.stage == .fired,
                              receipt.toolID == event.detail,
                              receipt.preparedAction?.id == id,
                              receipt.preparedAction?.routing.taskID == taskID,
                              receipt.preparedAction?.intentID == receipt.intentID,
                              receipt.preparedAction?.executionPlan.toolID == receipt.toolID,
                              prior?.receiptIDs.contains(id.uuidString) == false else { return false }
                    }
                    let now = max(self.progressDate(), max(prior?.heartbeatAt ?? .distantPast,
                                                          prior?.lastProgressAt ?? .distantPast))
                    var stamped = event
                    stamped.at = now
                    // Return/throw is a live boundary fact even when its save rejects.
                    if event.kind == .toolCompleted { self.observeToolBacking(event, captured: task) }
                    let admitted = self.update(taskID, events: [stamped], worker: expected) { item in
                        item.durability?.heartbeatAt = now
                        item.durability?.lastProgressAt = now
                        if event.kind == .toolStarted, let id = event.receiptID {
                            item.durability?.receiptIDs.append(id.uuidString)
                        }
                    }.primaryCommitted
                    if admitted, event.kind == .toolStarted { self.observeToolBacking(event, captured: task) }
                    return admitted
                }
                return self.persist(events: [event], worker: expected).primaryCommitted
            }
            return self.persist(events: [event]).primaryCommitted
        }, isStillValid: validity, capturePermission: capture, consumePermissionApproval: { [weak self] in
            guard let self else { return false }
            if self.hasWorkerAttemptRecord(task),
               self.workerCondition(task, states: [.running]) == nil { return false }
            return self.consumePermissionApproval(taskID: taskID)
        }, restoredOrigin: origin, restoredPermission: restoredPermission, restoredArguments: restoredArguments,
           receiptStore: receiptStore, leaseOwner: hasWorkerAttemptRecord(task) ? task.durability?.leaseOwner : nil,
           observeACPSession: observeACPSession, observeToolInvocation: observeToolInvocation)
    }

    private func progressDate() -> Date {
        if SelfTest.isRunning, let clock = progressDateForTesting, store.allowsHarnessPersistence {
            return clock()
        }
        return Date()
    }

    @discardableResult
    private func persist(events: [TaskJournalEventDraft] = [], worker: TaskWorkerWriteCondition? = nil,
                         activityBefore: AgentTask? = nil) -> AgentTaskPersistenceResult {
        guard historyReadFailure == nil else { return .loadFailed }
        // Existing uninjected harness simulations never write the owner store. This
        // accepted simulation result is not evidence of a durable production commit.
        guard !SelfTest.isRunning || store.allowsHarnessPersistence else { return .saved }
        let result: AgentTaskPersistenceResult
        if let before = activityBefore, let worker, events.count == 1 {
            result = store.saveActivity(tasks, before: before, event: events[0], worker: worker)
        } else {
            result = store.save(tasks, events: events, worker: worker)
        }
        lastPersistenceResult = result
        if let diagnostic = result.diagnostic {
            if SelfTest.isRunning { SelfTest.diagnostic("TASK_PERSISTENCE_DIAGNOSTIC: \(diagnostic)") }
            else { Log.app.error("\(diagnostic, privacy: .public)") }
        }
        return result
    }

    /// Folds whatever the ledger holds for this run onto the task's artifact list.
    /// Called from `execute` and from `--selftest-tasks`'s browser-run fixture; the
    /// take-on-read keeps a second fold from duplicating the links.
    func foldArtifacts(taskID: String) {
        guard historyReadFailure == nil else { return }
        let captured = AgentArtifactLedger.takeRecords(taskID: taskID)
        guard !captured.isEmpty else { return }
        update(taskID) { item in
            item.artifactRecords = AgentArtifact.merging(captured, into: item.artifactRecords)
        }
    }

    /// Background work used to finish only in the task list. A failure the conversation
    /// never hears is the same shape as a turn that never replied.
    private func announce(_ text: String, queueSpeech: Bool = true) {
        if SelfTest.isRunning && store.allowsHarnessPersistence { announcementForTesting?(text) }
        if SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
           store.allowsHarnessPersistence, queueSpeech,
           let output = announcementOutputForTesting, output.permitsHarness {
            output.enqueue(text)
        }
        guard projectsActivity else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Tagged: a background result is content the user did not write, so the memory review
        // and a compaction summary never read it as the Agent's own words.
        AgentSession.shared.recordAssistant(trimmed, contextKind: AgentSession.backgroundTaskContextKind)
        AgentAuditLog.shared.record(kind: .reply, title: trimmed)
        IslandState.shared.showBackgroundAgentReply(trimmed)
        if queueSpeech { OutputScheduler.shared.enqueue(trimmed) }
    }

    /// The artifact half of a finished run, persisted in the conversation (P1-5).
    /// Never spoken: a URL read out loud is noise, and the links are for the result card.
    private func announceArtifacts(taskID: String) {
        if SelfTest.isRunning && store.allowsHarnessPersistence,
           let task = task(id: taskID), !task.artifacts.isEmpty {
            announcementForTesting?("fixture artifact announcement: \(task.artifacts.count)")
        }
        guard projectsActivity else { return }
        guard let task = task(id: taskID), !task.artifacts.isEmpty else { return }
        let lines = AgentActivityProjector.artifactHeading(for: task) + ":\n"
            + task.artifactRecords.map { "\u{2022} \(AgentActivityProjector.artifactLabel($0))" }.joined(separator: "\n")
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
    var artifactRecords: [AgentArtifact]
    var artifacts: [String] {
        get { artifactRecords.map(\.value) }
        set { artifactRecords = AgentArtifact.replacingValues(newValue, in: artifactRecords) }
    }
    var failure: String?

    init(status: AgentTaskStatus, progress: String, result: String?, artifacts: [String], failure: String?) {
        self.status = status; self.progress = progress; self.result = result
        self.artifactRecords = artifacts.map { AgentArtifact($0) }; self.failure = failure
    }
    static func completed(_ result: String, artifactRecords: [AgentArtifact]) -> AgentTaskOutcome {
        var outcome = completed(result, artifacts: artifactRecords.map(\.value))
        outcome.artifactRecords = artifactRecords
        return outcome
    }

    static func completed(_ result: String, artifacts: [String] = []) -> AgentTaskOutcome {
        AgentTaskOutcome(status: .completed, progress: "Done", result: result, artifacts: artifacts, failure: nil)
    }

    static func voiceReply(_ reply: String) -> AgentTaskOutcome {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let failedPrefixes = ["The tool planner failed", "I stopped the tool plan",
            "The tool planner requested an unavailable tool", "I can’t plan tool use",
            "The local tool catalogue is unavailable."]
        if failedPrefixes.contains(where: { text.hasPrefix($0) })
            || (text.hasPrefix("The tool ") && text.contains(" did not run: ")) {
            return .failed(reply)
        }
        if AgentEntityResolver.askedForAName(text) || (text.count <= 200 && text.hasSuffix("?")) {
            return AgentTaskOutcome(status: .waitingForInput, progress: "Waiting for your answer",
                result: reply, artifacts: [], failure: nil)
        }
        return .completed(reply)
    }

    static func failed(_ reason: String) -> AgentTaskOutcome {
        AgentTaskOutcome(status: .failed, progress: "Failed", result: nil, artifacts: [], failure: reason)
    }
}
