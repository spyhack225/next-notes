from pathlib import Path
import difflib, hashlib, json
root=Path(__file__).resolve().parent
sources={}
original={}
def read(relative):
    p=Path(relative); original[relative]=p.read_text(); sources[relative]=original[relative]; return sources[relative]
def replace(relative, old, new):
    assert sources[relative].count(old)==1,(relative,old[:100],sources[relative].count(old))
    sources[relative]=sources[relative].replace(old,new)
store='Sources/NextNotes/Agent/Tasks/Durable/TaskStore.swift';read(store)
replace(store,'enum TaskStoreError: LocalizedError {','''/// A predicate on an existing primary task row, checked inside the same commit.
/// It supplies no recovery, liveness or retry authority.
struct TaskWorkerWriteCondition: Sendable {
    let taskID: String
    let attempt: Int
    let leaseOwner: String?
    let status: AgentTaskStatus
}

enum TaskStoreError: LocalizedError {''')
replace(store,'events: [TaskJournalEventDraft]) throws -> TaskStoreAuthority {','events: [TaskJournalEventDraft], worker: TaskWorkerWriteCondition? = nil) throws -> TaskStoreAuthority {')
replace(store,'guard try fileIdentity() == probe.identity,\n                      try Self.authority(in: db) == before else { throw TaskStoreError.authorityConflict }\n                try TaskStoreSchema.installPendingInteractions(on: db)\n                try Self.writeRows(tasks, to: db, preservingChildren: false)','''guard try fileIdentity() == probe.identity,
                      try Self.authority(in: db) == before else { throw TaskStoreError.authorityConflict }
                if let worker {
                    guard try Self.matchesWorker(worker, in: db),
                          let next = tasks.first(where: { $0.id == worker.taskID }) else {
                        throw TaskStoreError.authorityConflict
                    }
                    let starting = worker.status == .queued && next.status == .running
                    guard worker.attempt >= 0, !starting || worker.attempt < Int.max,
                          next.durability?.attempt == worker.attempt + (starting ? 1 : 0),
                          starting || next.durability?.leaseOwner == worker.leaseOwner,
                          events.filter({ $0.taskID == worker.taskID }).allSatisfy({ $0.attempt == next.durability?.attempt }) else {
                        throw TaskStoreError.authorityConflict
                    }
                }
                try TaskStoreSchema.installPendingInteractions(on: db)
                try Self.writeRows(tasks, to: db, preservingChildren: false)''')
# Add an indexed targeted read. Avoid decoding a second full-history snapshot.
anchor='    /// One transaction replaces the canonical JSON snapshot\'s current rows.'
replace(store,anchor,'''    /// Fail-fast existing-only primary read for the final worker validity hook.
    func matchesWorker(_ worker: TaskWorkerWriteCondition, probe: TaskStoreAuthorityProbe) throws -> Bool {
        guard let authority = probe.authority else { return false }
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        return try existing(identity: probe.identity, writable: false) { db in
            try Self.exec(db, "BEGIN")
            defer { try? Self.exec(db, "ROLLBACK") }
            guard try Self.authority(in: db) == authority else { return false }
            return try Self.matchesWorker(worker, in: db)
        }
    }

    private static func matchesWorker(_ worker: TaskWorkerWriteCondition, in db: OpaquePointer) throws -> Bool {
        let statement = try prepare(db, "SELECT state,durability FROM task WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(statement, [.text(worker.taskID)])
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            if code == SQLITE_DONE { return false }
            throw TaskStoreError.sqlite(code)
        }
        guard let state = try text(statement, 0), let status = AgentTaskStatus(rawValue: state) else {
            throw TaskStoreError.invalidRecord
        }
        let durability = try text(statement, 1).map { try decode(TaskDurability.self, $0) }
        guard (durability?.attempt ?? 0) >= 0 else { throw TaskStoreError.invalidRecord }
        return status == worker.status && (durability?.attempt ?? 0) == worker.attempt
            && durability?.leaseOwner == worker.leaseOwner
    }

'''+anchor)
agentstore='Sources/NextNotes/Agent/Tasks/AgentTaskStore.swift';read(agentstore)
replace(agentstore,'func save(_ tasks: [AgentTask], events: [TaskJournalEventDraft] = []) -> AgentTaskPersistenceResult {','func save(_ tasks: [AgentTask], events: [TaskJournalEventDraft] = [],\n              worker: TaskWorkerWriteCondition? = nil) -> AgentTaskPersistenceResult {')
replace(agentstore,'mirror.commitAuthoritative(canonical, probe: probe, events: events)','mirror.commitAuthoritative(canonical, probe: probe, events: events, worker: worker)')
anchor='    @discardableResult\n    func save('
replace(agentstore,anchor,'''    /// No creator/fallback path: the worker's final hook verifies its bound primary row.
    func matchesWorker(_ worker: TaskWorkerWriteCondition) -> Bool {
        guard !failedLoad else { return false }
        guard !SelfTest.isRunning || allowsHarnessPersistence else { return false }
        do {
            guard let probe = try mirror.probeAuthority(includeTasks: false) else { return false }
            try check(probe, witness: try? compatibilityData())
            return try mirror.matchesWorker(worker, probe: probe)
        } catch { return false }
    }

'''+anchor)
journal='Sources/NextNotes/Agent/Tasks/Durable/TaskEventJournal.swift';read(journal)
replace(journal,'let record: @MainActor @Sendable (TaskJournalEventDraft) -> Void','let record: @MainActor @Sendable (TaskJournalEventDraft) -> Bool\n    var isStillValid: (@MainActor @Sendable () async -> Bool)? = nil')
replace(journal,'static func toolStarted(taskID: String?, tool: String) -> TaskJournalContext? {','static func toolStarted(taskID: String?, tool: String) throws -> TaskJournalContext? {')
replace(journal,'''        context.record(TaskJournalEventDraft(taskID: context.taskID, kind: .toolStarted,
            detail: tool, attempt: context.attempt))''','''        let admitted = context.record(TaskJournalEventDraft(taskID: context.taskID, kind: .toolStarted,
            detail: tool, attempt: context.attempt))
        if context.isStillValid != nil, !admitted {
            throw AgentError.backendUnavailable("The action could not be saved. It was not run.")
        }''')
replace(journal,'''        context.record(TaskJournalEventDraft(taskID: context.taskID, kind: .toolCompleted,
            detail: "\\(tool):\\(succeeded ? "returned" : "threw")", attempt: context.attempt))''','''        _ = context.record(TaskJournalEventDraft(taskID: context.taskID, kind: .toolCompleted,
            detail: "\\(tool):\\(succeeded ? "returned" : "threw")", attempt: context.attempt))''')
executor='Sources/NextNotes/Agent/Tools/AgentToolExecutor.swift';read(executor)
replace(executor,'let journal = TaskEventJournal.toolStarted(taskID: taskID, tool: tool.id)','let journal = try TaskEventJournal.toolStarted(taskID: taskID, tool: tool.id)')
backend='Sources/NextNotes/Agent/Backend/LocalAgentBackend.swift';read(backend)
replace(backend,'permissionAlreadyGranted: permissionAlreadyGranted\n','permissionAlreadyGranted: permissionAlreadyGranted,\n            isStillValid: TaskEventJournal.current?.taskID == task.id ? TaskEventJournal.current?.isStillValid : nil\n')
manager='Sources/NextNotes/Agent/Tasks/AgentTaskManager.swift';read(manager)
# Extend existing persistence seam with transaction predicate.
replace(manager,'private func update(_ id: String, kinds: [TaskEventKind] = [], mutate: (inout AgentTask) -> Void) -> AgentTaskPersistenceResult {','private func update(_ id: String, kinds: [TaskEventKind] = [],\n                        worker: TaskWorkerWriteCondition? = nil, mutate: (inout AgentTask) -> Void) -> AgentTaskPersistenceResult {')
replace(manager,'persist(events: transitionEvents(from: before, to: tasks[index], kinds: kinds))','persist(events: transitionEvents(from: before, to: tasks[index], kinds: kinds), worker: worker)')
replace(manager,'private func updateRecord(_ task: AgentTask, kinds: [TaskEventKind] = []) -> AgentTaskPersistenceResult {\n        update(task.id, kinds: kinds) { $0 = task }','private func updateRecord(_ task: AgentTask, kinds: [TaskEventKind] = [],\n                              worker: TaskWorkerWriteCondition? = nil) -> AgentTaskPersistenceResult {\n        update(task.id, kinds: kinds, worker: worker) { $0 = task }')
replace(manager,'private func persist(events: [TaskJournalEventDraft] = []) -> AgentTaskPersistenceResult {','private func persist(events: [TaskJournalEventDraft] = [], worker: TaskWorkerWriteCondition? = nil) -> AgentTaskPersistenceResult {')
replace(manager,'store.save(tasks, events: events)','store.save(tasks, events: events, worker: worker)')
# Worker identity is the task's existing optional durability metadata; no new owner map.
anchor='    private func execute(_ id: String) async {'
replace(manager,anchor,'''    private func ownsLocalAttempt(_ task: AgentTask) -> Bool {
        isTypedOwner(task) && task.backend == AgentBackendKind.local.rawValue
    }

    private func workerCondition(_ captured: AgentTask, states: [AgentTaskStatus]) -> TaskWorkerWriteCondition? {
        guard ownsLocalAttempt(captured), let durability = captured.durability, durability.attempt > 0,
              let current = task(id: captured.id), states.contains(current.status),
              current.durability?.attempt == durability.attempt,
              current.durability?.leaseOwner == durability.leaseOwner else { return nil }
        return TaskWorkerWriteCondition(taskID: captured.id, attempt: durability.attempt,
            leaseOwner: durability.leaseOwner, status: current.status)
    }

    @discardableResult
    private func updateWorker(_ captured: AgentTask, states: [AgentTaskStatus] = [.running],
                              mutate: (inout AgentTask) -> Void) -> AgentTaskPersistenceResult {
        if !ownsLocalAttempt(captured) { return update(captured.id, mutate: mutate) }
        guard let expected = workerCondition(captured, states: states) else { return .loadFailed }
        return update(captured.id, worker: expected, mutate: mutate)
    }

    private func releaseWorker(_ captured: AgentTask) {
        if !ownsLocalAttempt(captured) { running[captured.id] = nil; return }
        // A queued explicit continuation may already own the next handle before its
        // asynchronous execute allocates the next attempt. Do not remove that handle.
        guard let current = task(id: captured.id), current.status != .queued,
              current.durability?.attempt == captured.durability?.attempt,
              current.durability?.leaseOwner == captured.durability?.leaseOwner else { return }
        running[captured.id] = nil
    }

'''+anchor)
replace(manager,'''        task.status = .running
        task.progress = "Starting…"
        let started = updateRecord(task)''','''        let startCondition: TaskWorkerWriteCondition?
        if ownsLocalAttempt(task) {
            var durability = task.durability ?? TaskDurability()
            guard durability.attempt < Int.max else { rejectStart(id, result: .sqlFailed); return }
            startCondition = TaskWorkerWriteCondition(taskID: id, attempt: durability.attempt,
                leaseOwner: durability.leaseOwner, status: .queued)
            durability.attempt += 1
            durability.leaseOwner = String(ProcessInfo.processInfo.processIdentifier)
            durability.attemptStartedAt = Date()
            durability.runtimeClass = .localDeterministic
            durability.resumePolicy = .neverAuto
            task.durability = durability
        } else { startCondition = nil }
        task.status = .running
        task.progress = "Starting…"
        let started = updateRecord(task, worker: startCondition)''')
replace(manager,'guard started.primaryCommitted else { rejectStart(id, result: started); return }\n\n        do {','guard started.primaryCommitted else { rejectStart(id, result: started); return }\n        defer { releaseWorker(task) }\n\n        do {')
# All actual async outcome/error writers use captured task identity and acknowledge SQL admission.
begin=sources[manager].index('    private func execute(_ id: String) async {');end=sources[manager].index('    @discardableResult\n    private func update(',begin)
part=sources[manager][begin:end]
part=part.replace('''            let captured = AgentArtifactLedger.take(taskID: id)
            update(id) { item in''','''            if ownsLocalAttempt(task), workerCondition(task, states: [.running]) == nil { return }
            let captured = AgentArtifactLedger.take(taskID: id)
            let finished = updateWorker(task) { item in''')
part=part.replace('''            if projectsActivity { AgentActivityStore.shared.finish(
                taskID: id,''','''            guard finished.primaryCommitted else {
                if let diagnostic = finished.diagnostic { announce(diagnostic) }
                return
            }
            if projectsActivity { AgentActivityStore.shared.finish(
                taskID: id,''',1)
part=part.replace('''            update(id) { $0.status = .cancelled }
            announce("Cancelled.")''','''            let cancelled = updateWorker(task) { $0.status = .cancelled }
            if cancelled.primaryCommitted { announce("Cancelled.") }''')
part=part.replace('''        } catch let error as AgentError {
            if case''','''        } catch let error as AgentError {
            if ownsLocalAttempt(task), workerCondition(task, states: [.running, .waitingForPermission]) == nil { return }
            if case''')
part=part.replace('let admitted = parkInput(request)','let admitted = updateWorker(task) { item in\n                    item.pendingInteraction = .input(request)\n                    item.status = .waitingForInput\n                    item.progress = request.question\n                }')
part=part.replace('''                    update(id) { item in item.status = .failed; item.failure = failure }
                    if projectsActivity''','''                    let failed = updateWorker(task) { item in item.status = .failed; item.failure = failure }
                    guard failed.primaryCommitted else { announce(failure); return }
                    if projectsActivity''')
part=part.replace('''                update(id) { item in
                    item.status = .waitingForCompatibilityCLI''','''                let parked = updateWorker(task) { item in
                    item.status = .waitingForCompatibilityCLI''')
part=part.replace('''                approvedCompatibilityTaskIDs.remove(id)
                if projectsActivity''','''                guard parked.primaryCommitted else {
                    if let diagnostic = parked.diagnostic { announce(diagnostic) }
                    return
                }
                approvedCompatibilityTaskIDs.remove(id)
                if projectsActivity''')
part=part.replace('''            if case .needsPermission(let title) = error {
                update(id) { item in''','''            if case .needsPermission(let title) = error {
                if ownsLocalAttempt(task), workerCondition(task, states: [.waitingForPermission]) != nil {
                    restorePendingInteractions()
                    return // The exact capture producer already committed this parked row.
                }
                let parked = updateWorker(task) { item in''')
part=part.replace('''                restorePendingInteractions()
                running[id] = nil''','''                guard parked.primaryCommitted else {
                    if let diagnostic = parked.diagnostic { announce(diagnostic) }
                    return
                }
                restorePendingInteractions()
                running[id] = nil''')
part=part.replace('''            update(id) { item in
                item.status = .failed''','''            let failed = updateWorker(task, states: [.running, .waitingForPermission]) { item in
                item.status = .failed''',1)
part=part.replace('''            if projectsActivity { AgentActivityStore.shared.finish(taskID: id, title: error.localizedDescription) }
            announce(error.localizedDescription)''','''            guard failed.primaryCommitted else {
                if let diagnostic = failed.diagnostic { announce(diagnostic) }
                return
            }
            if projectsActivity { AgentActivityStore.shared.finish(taskID: id, title: error.localizedDescription) }
            announce(error.localizedDescription)''')
part=part.replace('''        } catch {
            update(id) { item in''','''        } catch {
            let failed = updateWorker(task) { item in''')
part=part.replace('''            announce(error.localizedDescription)
        }
        running[id] = nil''','''            guard failed.primaryCommitted else {
                if let diagnostic = failed.diagnostic { announce(diagnostic) }
                return
            }
            announce(error.localizedDescription)
        }''')
# Early-branch release handled by defer, preserving later handles.
part=part.replace('                running[id] = nil\n','')
sources[manager]=sources[manager][:begin]+part+sources[manager][end:]
# Cancellation writes remain SQL-first, with exact current primary attempt/status.
replace(manager,'''        let admitted = update(id) { task in
            task.status = .cancelled''','''        let current = task(id: id)
        let cancelCondition: TaskWorkerWriteCondition?
        if let current, ownsLocalAttempt(current), (current.durability?.attempt ?? 0) > 0 {
            guard let condition = workerCondition(current, states: [.running, .waitingForPermission, .waitingForInput]) else { return }
            cancelCondition = condition
        } else { cancelCondition = nil }
        let admitted = update(id, worker: cancelCondition) { task in
            task.status = .cancelled''')
# Context closure captures exact original task and binds all facts/permission/token to it.
replace(manager,'''                guard request.taskID == taskID, let self, let current = self.task(id: taskID) else { return false }
                // A nested''','''                guard request.taskID == taskID, let self, let current = self.task(id: taskID) else { return false }
                if self.ownsLocalAttempt(task), self.workerCondition(task, states: [.running]) == nil { return false }
                // A nested''')
replace(manager,'return self.parkPermission(request, origin: origin, review: review)','''if !self.ownsLocalAttempt(task) { return self.parkPermission(request, origin: origin, review: review) }
                guard request.toolID == current.tool, request.taskID == taskID,
                      review == nil || (review?.id == request.id && review?.toolID == request.toolID) else { return false }
                return self.updateWorker(task) { item in
                    item.pendingInteraction = .permission(request: request, origin: origin, review: review)
                    item.status = .waitingForPermission
                    item.progress = request.title
                }.primaryCommitted''')
replace(manager,'''        return TaskJournalContext(taskID: taskID, attempt: task.durability?.attempt ?? 0, record: { [weak self] event in
            guard event.taskID == taskID, self?.task(id: taskID) != nil else { return }
            self?.persist(events: [event])
        }, capturePermission: capture, consumePermissionApproval: { [weak self] in
            self?.consumePermissionApproval(taskID: taskID) ?? false
        }, restoredOrigin: origin, restoredPermission: restoredPermission, restoredArguments: restoredArguments)''','''        let validity: (@MainActor @Sendable () async -> Bool)?
        if ownsLocalAttempt(task), (task.durability?.attempt ?? 0) > 0 {
            validity = { [weak self] in
                guard let self, let expected = self.workerCondition(task, states: [.running]) else { return false }
                if SelfTest.isRunning && !self.store.allowsHarnessPersistence { return true }
                return self.store.matchesWorker(expected)
            }
        } else { validity = nil }
        return TaskJournalContext(taskID: taskID, attempt: task.durability?.attempt ?? 0, record: { [weak self] event in
            guard event.taskID == taskID, let self, self.task(id: taskID) != nil else { return false }
            if self.ownsLocalAttempt(task), (task.durability?.attempt ?? 0) > 0 {
                let states: [AgentTaskStatus]
                switch event.kind {
                case .permissionRequested, .permissionApproved, .permissionDenied:
                    states = [.running, .waitingForPermission]
                default: states = [.running]
                }
                guard event.attempt == task.durability?.attempt,
                      let expected = self.workerCondition(task, states: states) else { return false }
                return self.persist(events: [event], worker: expected).primaryCommitted
            }
            return self.persist(events: [event]).primaryCommitted
        }, isStillValid: validity, capturePermission: capture, consumePermissionApproval: { [weak self] in
            guard let self else { return false }
            if self.ownsLocalAttempt(task), (task.durability?.attempt ?? 0) > 0,
               self.workerCondition(task, states: [.running]) == nil { return false }
            return self.consumePermissionApproval(taskID: taskID)
        }, restoredOrigin: origin, restoredPermission: restoredPermission, restoredArguments: restoredArguments)''')
# Permission journal admission: bound failure never opens or resumes an approving live waiter.
gate='Sources/NextNotes/Agent/Permissions/PermissionGate.swift';read(gate)
replace(gate,'''                admitted = true
                if let context {
                    context.record(TaskJournalEventDraft(taskID: context.taskID,
                        kind: .permissionRequested, attempt: context.attempt))
                }
                let entry''','''                if let context {
                    let recorded = context.record(TaskJournalEventDraft(taskID: context.taskID,
                        kind: .permissionRequested, attempt: context.attempt))
                    if context.isStillValid != nil, !recorded {
                        continuation.resume(returning: false)
                        return
                    }
                }
                admitted = true
                let entry''')
replace(gate,'''            context.record(TaskJournalEventDraft(taskID: context.taskID,
                kind: approved ? .permissionApproved : .permissionDenied,
                detail: approved ? nil : "notApproved", attempt: context.attempt))''','''            let recorded = context.record(TaskJournalEventDraft(taskID: context.taskID,
                kind: approved ? .permissionApproved : .permissionDenied,
                detail: approved ? nil : "notApproved", attempt: context.attempt))
            if context.isStillValid != nil, !recorded { return false }''')
# One actual fixture constructs a context manually; preserve its meaning with Bool admission.
restoration='Sources/NextNotes/Agent/Tasks/Durable/TaskRestorationProductionSelfTest.swift';read(restoration)
# Verified exact closure syntax on source before replacement below.
if 'record: { _ in }' in sources[restoration]:
    replace(restoration,'record: { _ in }','record: { _ in true }')
else:
    assert 'record: { _ in true }' in sources[restoration], 'check actual restoration context constructor'
# Durable producer fixture updates need own separate live failed task; not covered by core patch.
manifest={'status':'prepare-only candidate; not applied, compiled or executed; original installed fixture result pending','files':{}}
patch=[]
for name,new in sources.items():
    if new==original[name]: continue
    dst=root/('candidate-'+Path(name).name+'.txt');dst.write_text(new)
    manifest['files'][name]={'original_sha256':hashlib.sha256(original[name].encode()).hexdigest(),'candidate':dst.name,'candidate_sha256':hashlib.sha256(new.encode()).hexdigest()}
    patch.extend(difflib.unified_diff(original[name].splitlines(True),new.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
(root/'candidate-worker-producer.patch').write_text(''.join(patch))
(root/'candidate-worker-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Prepared',len(manifest['files']),'candidate files outside Sources; no compiler')
