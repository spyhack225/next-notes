import Foundation

@MainActor
struct TypedWorkerTestCapture {
    let id: UUID
    let work: VoiceConversationWork
    let worker: RealtimeAgent
    let task: Task<AgentTurn, Never>
}

/// The SAME AgentView submission -> text planner -> read -> held model -> card ->
/// final external callback. Only the calendar service is a confined fixture.
@MainActor
enum TypedDuringWorkSelfTest {
    private enum Invalid: Error { case prior, root, store, worker, grammar, context }
    private static func reached(_ body: @MainActor () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < end { if await body() { return true }; await Task.yield() }
        return await body()
    }
    static func run(afterJoinedCases: (@MainActor (URL, TaskBridge) async -> Bool)? = nil) async -> (checks: Int, failures: [String]) {
        let agent = RealtimeAgent.shared, gate = PermissionGate.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-duplex-work",
              AgentSession.shared.fileURL == nil, !AgentCaptureController.shared.isSessionActive,
              gate.pending == nil, gate.queuedCount == 0 else { return (0, ["typed work: INVALID prior owner"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["typed work: INVALID root"]) }
        let oldProvider = agent.localModelProviderForTesting, oldBridge = agent.typedTaskBridgeForTesting
        let oldRemember = agent.rememberExplicit
        let oldFake = AgentToolExecutor.fakeForTesting, oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting, oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        func restoreInheritedOverrides() {
            agent.localModelProviderForTesting = oldProvider; agent.typedTaskBridgeForTesting = oldBridge
            agent.rememberExplicit = oldRemember
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole; ToolLoopLiveEval.needleFirstForTesting = oldNeedle
        }
        let owner = SelfTestStoreGuard.take()
        var contextManager: AgentTaskManager?, contextRejected = false, contextInstalled = false
        var islandBridge: TaskBridge?, meetingRoot: URL?
        var retainedIsland: IslandState?
        let oldOutput = VoicePlaybackDelivery.shared.installedOutputForTesting
        var outputInstalled = false
        var retainedOutput: OutputScheduler?
        var phraseTasks: [Task<Void, Never>] = []
        func joinPhraseTasks() async {
            while !phraseTasks.isEmpty {
                let entered = phraseTasks; phraseTasks.removeAll()
                for task in entered { await task.value }
            }
        }
        var islandInstalled = false
        var scopeRaceEnabled = false, scopeRaceAdmitted = false, scopeRaceMatched = false
        var scopeRaceOwner: TypedWorkerTestCapture?, scopeRaceBridge: TaskBridge?
        var scopeRaceBoundary: TypedSubmissionBoundary?
        var frontendInstalled = false
        var dictionaryInstalled = false, capabilityInstalled = false, activityInstalled = false
        var rootCreated = false, joined = false, probe: TypedCalendarProbe?
        var handoffSafe = true, handoffModes = 0
        var callers: [Task<AgentTurn, Never>] = [], operations: [Task<AgentTurn, Never>] = []
        let eventBoundary = TypedSubmissionBoundary()
        let stream = VoiceSession.shared.events()
        let observer = Task { @MainActor in
            for await event in stream {
                if Task.isCancelled { break }
                if case .task(.revised(let id, let revision)) = event { eventBoundary.revised.append((id, revision)) }
            }
        }
        func retainCurrentOperations() {
            guard let contextManager else { return }
            let bridge = agent.typedTaskBridgeForTesting
            for row in contextManager.tasks {
                if let id = UUID(uuidString: row.id), let live = bridge?.typedWorkerForTesting(id),
                   !operations.contains(live.task) { operations.append(live.task) }
            }
        }
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("typed work: " + label) } }
        defer {
            restoreInheritedOverrides()
            if activityInstalled { NextMemory.finishActivityContextForTesting(root: root) }
            if capabilityInstalled { VoiceCapabilitySnapshot.finishContextForTesting(root: root) }
            if dictionaryInstalled { DictionaryStore.finishRootForTesting(root) }

            if contextInstalled { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            // The explicit mode/outer joins precede this best-effort restoration.
            if let retainedOutput {
                _ = retainedOutput.observePhraseTaskForTesting(nil)
                retainedOutput.setPhraseForTesting(nil)
            }
            if outputInstalled { _ = VoicePlaybackDelivery.shared.installOutputForTesting(oldOutput) }
            if islandInstalled { _ = IslandState.finishSharedContextForTesting(root: root) }
            if rootCreated && joined {
                try? FileManager.default.removeItem(at: root)
                if let meetingRoot { try? FileManager.default.removeItem(at: meetingRoot) }
            }
            _ = islandBridge // Retain the first admitted constructor authority through teardown.
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); rootCreated = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                guard meeting == nil, FileManager.default.fileExists(atPath: root.path),
                      task == nil || contextManager?.task(id: task!)?.source == "text" else {
                    contextRejected = true; return nil
                }
                if scopeRaceEnabled, let held = scopeRaceOwner, let bridge = scopeRaceBridge,
                   task == held.id.uuidString, contextManager?.task(id: task!)?.status == .running {
                    // Actual review construction occurs after the broker/scope await
                    // and before ActionRuntime invokes capturePermission. Admit a
                    // real correction here through the existing SAME live owner.
                    scopeRaceEnabled = false; scopeRaceMatched = true
                    scopeRaceAdmitted = contextManager?.reviseTypedObjective(id: held.id,
                        correction: "make it 3 pm", bridge: bridge,
                        sessionID: AgentSession.shared.sessionID) == true
                    if scopeRaceAdmitted {
                        let reply = agent.finishTypedControl("Got it. I'll use that correction.", userWords: "make it 3 pm")
                        scopeRaceBoundary?.finished.append(reply.reply)
                    }
                }
                return ToolCallContext() // Unbound compatibility never falls through owner context.
            }, root: root) else { throw Invalid.context }
            contextInstalled = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .selfTest
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = nil
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            agent.rememberExplicit = { _ in }
            for mode in ["revise", "cancel", "status", "spawn", "scope-race", "restart-held", "revision-refused"] {
                joined = false; callers = []; operations = []
                AgentSession.shared.forgetAllConversations()
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("agenda.txt")
                try Data(TypedCalendarProbe.agenda.utf8).write(to: target)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.store }
                let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("receipts.json"))
                let manager = AgentTaskManager(store: store, receiptStore: receipts), bridge = TaskBridge(manager: manager)
                contextManager = manager; agent.typedTaskBridgeForTesting = bridge
                if !dictionaryInstalled {
                    guard DictionaryStore.installRootForTesting(root, bridge: bridge) else { throw Invalid.context }
                    dictionaryInstalled = true
                    // Bind the actual singleton while its admitted URL is still live.
                    _ = DictionaryStore.shared.entries
                    guard DictionaryStore.capturedRootMatchesForTesting(root) == true else { throw Invalid.context }
                }
                let fixtureInputs = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
                guard VoiceCapabilitySnapshot.installContextForTesting(root: root, bridge: bridge,
                    inputs: fixtureInputs) else { throw Invalid.context }
                capabilityInstalled = true
                if afterJoinedCases != nil, !islandInstalled {
                    guard let output = OutputScheduler.isolatedForTesting(bridge),
                          VoicePlaybackDelivery.shared.installOutputForTesting(output) else { throw Invalid.context }
                    outputInstalled = true; retainedOutput = output
                    // NONNIL override returns nil: use the existing safe template,
                    // never enter the default model/role/library phraser.
                    output.setPhraseForTesting { _ in nil }
                    guard output.observePhraseTaskForTesting({ task in phraseTasks.append(task) }) else { throw Invalid.context }
                    let url = temp.appendingPathComponent("NextNotesMeetingResumeTest-" + root.lastPathComponent, isDirectory: true)
                    guard !FileManager.default.fileExists(atPath: url.path) else { throw Invalid.root }
                    let meetings = try MeetingStore.isolated(at: url); meetingRoot = url
                    guard IslandState.installSharedContextForTesting(root: root, bridge: bridge, store: meetings) else { throw Invalid.context }
                    islandInstalled = true; islandBridge = bridge
                    retainedIsland = IslandState.shared // Prime exactly once, before the first actual typed turn.
                    guard IslandState.sharedContextMatchesForTesting(root: root, bridge: bridge) else { throw Invalid.context }
                }
                guard NextMemory.installActivityContextForTesting(root: root, bridge: bridge) else { throw Invalid.context }
                activityInstalled = true
                let usageLog = UsageLog.shared // Existing SelfTest log; no second writer or store.
                let usageBefore = Set(usageLog.load().map(\.id))
                let state = TypedCalendarProbe(path: target.path, tools: fixtureInputs.tools); probe = state
                let boundary = TypedSubmissionBoundary()
                agent.localModelProviderForTesting = TypedCalendarProvider(probe: state)
                await LocalVoiceFrontend.shared.setGenerationForTesting { _, messages, _ in
                    let latest = messages.last?.content ?? ""
                    let value = latest.hasSuffix("Latest user speech:\nmake it 3 pm") ? "<revise id=\"1\"/>"
                        : latest.hasSuffix("Latest user speech:\nhow long will that take?") ? "<status id=\"1\"/>"
                        : "<use_tools/>"
                    return AsyncThrowingStream { $0.yield(value); $0.finish() }
                }
                frontendInstalled = true
                var reads = 0, events: [[String: String]] = []
                AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                    if tool.id == "filesystem.read" {
                        guard arguments == ["path": target.path] else { throw Invalid.root }
                        reads += 1; return try FilesystemExecutor.run(tool, arguments: arguments)
                    }
                    guard tool.id == "create_event", arguments["title"] == "Dentist" || arguments["title"] == "Call Dad",
                          arguments["start"]?.hasPrefix("2026-10-06T") == true else { throw Invalid.root }
                    events.append(arguments)
                    return AgentToolResult(summary: TypedCalendarProbe.created)
                }
                let request = "Read the agenda at " + target.path + " and schedule the dentist for 2 pm on October 6."
                let first = agent.submitTypedMessage(request, onInterrupted: { boundary.interrupts += 1 },
                    onReturn: { boundary.finished.append($0.reply) })
                callers.append(first)
                // Capture every admitted operation BEFORE the held qualification.
                let firstRows = bridge.cachedTasks
                for row in firstRows { if let id = UUID(uuidString: row.id), let captured = bridge.typedWorkerForTesting(id) { operations.append(captured.task) } }
                guard await reached({
                    retainCurrentOperations()
                    return await state.heldCount == 1
                }), reads == 1, events.isEmpty,
                      let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.worker }
                let firstRow = bridge.cachedTasks.first
                let retained = firstRow.flatMap { UUID(uuidString: $0.id) }.flatMap { bridge.typedWorkerForTesting($0) }
                if let retained, !operations.contains(retained.task) { operations.append(retained.task) }
                let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: request)
                let readCall = try TypedCalendarProbe.call("filesystem.read", ["path": target.path],
                    parameters: manifest.selected.first(where: { $0.id == "filesystem.read" })?.parameters ?? [])
                let writeCall = try TypedCalendarProbe.call("create_event", TypedCalendarProbe.event(hour: "14", dad: false),
                    parameters: manifest.selected.first(where: { $0.id == "create_event" })?.parameters ?? [])
                // Numeric/schema-only diagnosis of the unchanged fixture qualification.
                let grammar = LlamaGrammarPlanner.grammar(for: manifest)
                let readAllowed = manifest.allowedIDs.contains("filesystem.read")
                let writeAllowed = manifest.allowedIDs.contains("create_event")
                let readMatches = grammar.matches(readCall), writeMatches = grammar.matches(writeCall)
                let readFields = manifest.selected.first(where: { $0.id == "filesystem.read" })?.parameters.map(\.name).joined(separator: ",") ?? "missing"
                let writeFields = manifest.selected.first(where: { $0.id == "create_event" })?.parameters.map(\.name).joined(separator: ",") ?? "missing"
                print("TYPED_WORK_GRAMMAR mode=\(mode) readAllowed=\(readAllowed) writeAllowed=\(writeAllowed) readMatches=\(readMatches) writeMatches=\(writeMatches) readFields=\(readFields) writeFields=\(writeFields)")
                guard manifest.allowedIDs.contains("filesystem.read"), manifest.allowedIDs.contains("create_event"),
                      LlamaGrammarPlanner.grammar(for: manifest).matches(readCall),
                      LlamaGrammarPlanner.grammar(for: manifest).matches(writeCall) else { throw Invalid.grammar }
                check(reads == 1 && events.isEmpty && !contextRejected, "C01 actual read and held planner before effects (\(mode))")
                let initialPrimary = try sql.load().first { $0.id == firstRow?.id }
                check(retained != nil && firstRow?.source == "text" && firstRow?.origin == .typed
                    && firstRow?.status == .running && initialPrimary?.id == retained?.id.uuidString
                    && initialPrimary?.source == "text" && initialPrimary?.origin == .typed
                    && initialPrimary?.status == .running && initialPrimary?.durability?.attempt == 1
                    && initialPrimary?.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier),
                    "F01 same primary typed owner missing (\(mode))")
                let raw: String = switch mode {
                case "revise", "restart-held", "revision-refused": "make it 3 pm"
                case "cancel": "never mind"
                case "status": "how long will that take?"
                default: "also remind me to call Dad"
                }
                var rejectionBefore: (cached: [AgentTask], rows: [AgentTask], journal: [TaskJournalEvent], export: Data)?
                if mode == "revision-refused" {
                    guard let retained else { throw Invalid.worker }
                    rejectionBefore = (manager.tasks, try sql.load(), try sql.journal(taskID: retained.id.uuidString),
                        try Data(contentsOf: directory.appendingPathComponent("agent-tasks.json")))
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "CREATE TRIGGER reject_revision_journal BEFORE INSERT ON task_event WHEN NEW.kind='revisionRecorded' BEGIN SELECT RAISE(FAIL,'owned revision journal refusal'); END")
                    }
                }
                let revisedBefore = eventBoundary.revised.count
                if mode == "scope-race" {
                    guard let retained else { throw Invalid.worker }
                    scopeRaceOwner = retained; scopeRaceBridge = bridge; scopeRaceBoundary = boundary
                    scopeRaceEnabled = true; scopeRaceAdmitted = false; scopeRaceMatched = false
                } else {
                    let followup = agent.submitTypedMessage(raw, onInterrupted: { boundary.interrupts += 1 },
                        onReturn: { boundary.finished.append($0.reply) })
                    callers.append(followup)
                    _ = await reached({ !boundary.finished.isEmpty || bridge.cachedTasks.count == 2 || gate.pending != nil })
                }
                for row in bridge.cachedTasks { if let id = UUID(uuidString: row.id), let capture = bridge.typedWorkerForTesting(id), !operations.contains(capture.task) { operations.append(capture.task) } }
                check(boundary.interrupts == 0, "T5 actual AgentView submission interrupted work (\(mode))")
                if let retained {
                    if mode == "revise" || mode == "restart-held" {
                        let revisedPrimary = try sql.load().first { $0.id == retained.id.uuidString }
                        check(retained.work.revision == 1 && manager.task(id: retained.id.uuidString)?.revision == 1
                            && manager.task(id: retained.id.uuidString)?.userWords == raw
                            && revisedPrimary?.revision == 1 && revisedPrimary?.userWords == raw
                            && revisedPrimary?.durability?.attempt == 1,
                            "T1 accepted exact typed revision")
                        await Task.yield()
                        let revised = eventBoundary.revised.dropFirst(revisedBefore).filter { $0.0 == TaskID(retained.id) && $0.1 == 1 }
                        check(revised.count == 1, "T1 exactly one admitted same-ID revised event")
                    } else if mode == "revision-refused" {
                        guard let rejectionBefore else { throw Invalid.store }
                        let afterRows = try sql.load(), afterJournal = try sql.journal(taskID: retained.id.uuidString)
                        let afterExport = try Data(contentsOf: directory.appendingPathComponent("agent-tasks.json"))
                        let held = await state.heldCount
                        check(manager.tasks == rejectionBefore.cached && afterRows == rejectionBefore.rows
                            && afterJournal == rejectionBefore.journal && afterExport == rejectionBefore.export
                            && retained.work.revision == 1 && held == 1 && events.isEmpty,
                            "RJ03 rejected revision journal rolls back same cache primary export and facts")
                        try sql.withConnection { db in try TaskStore.exec(db, "DROP TRIGGER reject_revision_journal") }
                        // An explicit new user follow-up, not an automatic retry.
                        let retry = agent.submitTypedMessage(raw, onInterrupted: { boundary.interrupts += 1 },
                            onReturn: { boundary.finished.append($0.reply) })
                        callers.append(retry)
                        _ = await reached { boundary.finished.count == 2 }
                        let retried = try sql.load().first { $0.id == retained.id.uuidString }
                        check(retained.work.revision == 2 && retried?.revision == 2 && retried?.userWords == raw
                            && retried?.durability?.attempt == initialPrimary?.durability?.attempt
                            && operations.count == 1 && operations.first == retained.task && !retained.task.isCancelled,
                            "R05 explicit new followup admits pending instructions on SAME positive attempt Task")
                    } else if mode == "cancel" {
                        check(retained.task.isCancelled && manager.task(id: retained.id.uuidString)?.status == .cancelled,
                            "T2 explicit typed cancellation stops SAME operation")
                        if let stopped = manager.task(id: retained.id.uuidString) {
                            check(AgentWorkingCard.statusLabel(task: stopped, isRunning: false, paused: false,
                                control: manager.typedControlObservation(id: retained.id)) == "Stopping · " + stopped.objective,
                                "T2 actual card status says stopping while SAME planner is held")
                        } else { check(false, "T2 actual card status says stopping while SAME planner is held") }
                    } else if mode == "status" {
                        check(manager.task(id: retained.id.uuidString)?.status == .running && !retained.task.isCancelled
                            && boundary.finished.contains(where: { $0.contains("Dentist") || $0.contains("agenda") }),
                            "T3 ledger answer leaves same task running")
                    } else if mode == "scope-race" {
                        check(!retained.task.isCancelled && events.isEmpty && reads == 1,
                            "C10 real pending caller before broker/review race")
                    } else {
                        check(bridge.cachedTasks.count == 2 && operations.count == 2 && !retained.task.isCancelled,
                            "T4 second typed task beside SAME first operation")
                    }
                } else { check(false, "T1-T4 no canonical typed continuation (\(mode))") }
                var restarted: AgentTaskManager?, heldAfterRestart: AgentTask?
                if mode == "restart-held" {
                    guard let retained else { throw Invalid.worker }
                    // A real fresh reader/Manager commits its existing held restart.
                    // The original exact operation stays captured until genuine return.
                    let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql), receiptStore: receipts)
                    restarted = fresh; heldAfterRestart = fresh.task(id: retained.id.uuidString)
                    check(heldAfterRestart?.status == .recovering && heldAfterRestart?.revision == 1
                        && heldAfterRestart?.userWords == raw && fresh.backendStartsForTesting == 0
                        && fresh.typedWorkerSnapshot(id: retained.id) == nil,
                        "R01 actual fresh Manager holds revised work without replay")
                }
                await state.releaseAll()
                // These are real cards produced by the planner/Orchestrator. Only
                // the final calendar callback is confined, and approval is explicit.
                var obsoleteProposals = 0, obsoleteApprovals = 0, restartOffers = 0
                let settled = await reached {
                    if let pending = gate.pending {
                        guard pending.toolID == "create_event", let review = ToolCallReviewStore.shared.review(id: pending.id), review.isReadyToRun else { return false }
                        let obsolete = mode == "scope-race" && pending.arguments["start"] == "2026-10-06T14:00:00-04:00"
                        if obsolete { obsoleteProposals += 1 }
                        if mode == "restart-held" {
                            restartOffers += 1
                            gate.cancelPending(id: pending.id)
                        } else {
                            let granted = gate.respond(id: pending.id, approved: true, duration: .once, scope: pending.scope, via: .card)
                            if obsolete && granted { obsoleteApprovals += 1 }
                        }
                    }
                    let active = await state.activeCalls
                    return boundary.finished.count == (mode == "revision-refused" ? 3 : 2) && active == 0
                }
                if !settled {
                    let metadata = await state.settleMetadata()
                    print("TYPED_WORK_SETTLE mode=\(mode) active=\(metadata.active) heldDentist=\(metadata.heldDentist) heldDad=\(metadata.heldDad) releasedDentist=\(metadata.releasedDentist) releasedDad=\(metadata.releasedDad) sealedReleased=\(metadata.sealedReleased) callers=\(callers.count) operations=\(operations.count) finished=\(boundary.finished.count) cancelled=\(operations.filter { $0.isCancelled }.count) rows=\(manager.tasks.count) running=\(manager.tasks.filter { $0.status == .running }.count) permission=\(manager.tasks.filter { $0.status == .waitingForPermission }.count) gatePending=\(gate.pending != nil) gateQueued=\(gate.queuedCount)")
                }
                guard settled else { throw Invalid.worker }
                for caller in callers { _ = await caller.value }
                for operation in operations { _ = await operation.value }
                joined = true
                if mode == "revise" {
                    check(reads == 1 && events.count == 1 && events.first?["start"] == "2026-10-06T15:00:00-04:00", "T1 retained read and exact 15:00 effect")
                } else if mode == "cancel" { check(events.isEmpty, "T2 zero effects after explicit cancellation") }
                else if mode == "status" { check(events.count == 1, "T3 one eventual effect after status answer") }
                else if mode == "scope-race" {
                    guard let retained else { throw Invalid.worker }
                    let primary = try sql.load().first { $0.id == retained.id.uuidString }
                    let journal = try sql.journal(taskID: retained.id.uuidString)
                    let requested = journal.filter { $0.draft.kind == .permissionRequested }
                    let approved = journal.filter { $0.draft.kind == .permissionApproved }
                    check(scopeRaceMatched && scopeRaceAdmitted && retained.work.revision == 1
                        && primary?.revision == 1 && primary?.userWords == "make it 3 pm"
                        && operations.count == 1, "C11 real review callback admits same Task/work/SQL successor")
                    print("TYPED_PERMISSION_RACE obsoleteProposals=\(obsoleteProposals) obsoleteApprovals=\(obsoleteApprovals) requested=\(requested.count) approved=\(approved.count)")
                    check(obsoleteProposals == 0 && obsoleteApprovals == 0
                        && requested.count == 2 && approved.count == 1
                        && requested[0].seq > 0 && requested[0].seq < requested[1].seq
                        && requested[1].seq < approved[0].seq
                        && requested.allSatisfy { $0.draft.taskID == retained.id.uuidString
                            && $0.draft.attempt == initialPrimary?.durability?.attempt }
                        && approved[0].draft.taskID == retained.id.uuidString
                        && approved[0].draft.attempt == initialPrimary?.durability?.attempt,
                        "F10 obsolete planned proposal never published or granted")
                    check(reads == 1 && events.count == 1 && events.first?["start"] == "2026-10-06T15:00:00-04:00",
                        "C12 old callback runs no effect; successor retains read and fires once")
                }
                else if mode == "revision-refused" {
                    guard let retained else { throw Invalid.worker }
                    let journal = try sql.journal(taskID: retained.id.uuidString)
                    let revisions = journal.filter { $0.draft.kind == .revisionRecorded }
                    check(revisions.map(\.draft.detail) == [raw, raw]
                        && revisions.allSatisfy { $0.draft.taskID == retained.id.uuidString
                            && $0.draft.attempt == initialPrimary?.durability?.attempt }
                        && revisions[0].seq < revisions[1].seq,
                        "RJ04 explicit successor commits every pending instruction once in order")
                    check(reads == 1 && events.count == 1 && events.first?["start"] == "2026-10-06T15:00:00-04:00"
                        && operations.count == 1 && boundary.interrupts == 0,
                        "R06 refused revision supplies no extra read or effect; explicit successor fires once")
                }
                else if mode == "restart-held" {
                    guard let retained else { throw Invalid.worker }
                    let saved = try sql.load().first { $0.id == retained.id.uuidString }
                    let journal = try sql.journal(taskID: retained.id.uuidString)
                    let revisions = journal.filter { $0.draft.kind == .revisionRecorded }
                    check(revisions.count == 1 && revisions.first?.draft.detail == raw
                        && revisions.first?.draft.attempt == initialPrimary?.durability?.attempt,
                        "RJ01 held restart retains exact admitted correction instruction")
                    check(reads == 1 && events.isEmpty && saved == heldAfterRestart
                        && restarted?.task(id: retained.id.uuidString) == heldAfterRestart
                        && restarted?.backendStartsForTesting == 0,
                        "R02 old exact operation cannot effect or overwrite held successor")
                    check(restartOffers == 0 && gate.pending == nil && gate.queuedCount == 0
                        && journal.allSatisfy { ![TaskEventKind.permissionRequested, .permissionApproved].contains($0.draft.kind) }
                        && receipts.receipts.filter { $0.toolID == "create_event" }.allSatisfy { receipt in
                            ![ActionReceiptStatus.fired, .completed, .couldNotVerify, .outcomeUnknown].contains(receipt.status)
                                && receipt.events.allSatisfy { $0.stage != .fired }
                        }, "R03 held restart supplies no write approval or fired receipt")
                }
                else { check(events.count == 2 && Set(events.compactMap { $0["title"] }) == ["Dentist", "Call Dad"], "T4 both tasks finish with two confined effects") }
                if mode == "revise" || mode == "scope-race", let retained {
                    let saved = try sql.load().first { $0.id == retained.id.uuidString }
                    let journal = try sql.journal(taskID: retained.id.uuidString)
                    let revisions = journal.filter { $0.draft.kind == .revisionRecorded }
                    check(revisions.count == 1 && revisions.first?.draft.detail == "make it 3 pm"
                        && revisions.first?.draft.taskID == retained.id.uuidString
                        && revisions.first?.draft.attempt == initialPrimary?.durability?.attempt,
                        "RJ02 exact correction journals in actual admitted transaction (\(mode))")
                    let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql), receiptStore: receipts)
                    let afterFreshJournal = try sql.journal(taskID: retained.id.uuidString)
                    check(saved?.status == .completed && saved?.revision == 1
                        && saved?.result?.isEmpty == false && fresh.task(id: retained.id.uuidString) == saved
                        && fresh.backendStartsForTesting == 0 && fresh.typedWorkerSnapshot(id: retained.id) == nil
                        && afterFreshJournal == journal,
                        "R04 completed output and revision journal survive fresh Manager without replay (\(mode))")
                }
                if mode == "revise" || mode == "spawn" {
                    // Every actual owned operation has joined before inspecting its saved passes.
                    usageLog.flush()
                    let usageRows = usageLog.load().filter { !usageBefore.contains($0.id)
                        && $0.modelID == "Typed Task Usage Fixture" }
                    let ownedIDs = Set(bridge.cachedTasks.filter { $0.source == "text" }.map(\.id))
                    let providerCalls = await state.completedCalls
                    check(usageRows.count == providerCalls && usageRows.count >= 3
                        && usageRows.allSatisfy { $0.workID.map { ownedIDs.contains($0.uuidString) } == true
                            && $0.promptTokens == 11 && $0.completionTokens == 7 },
                        "U01 actual completed scripted passes and owned work IDs qualify (\(mode))")
                    check(usageRows.allSatisfy { $0.taskID == $0.workID?.uuidString },
                        "U02 saved typed planner passes lost exact managed task ID (\(mode))")
                    let unrelatedUsage = UsageSummary.task(rows: usageRows, taskID: UUID().uuidString)
                    check(unrelatedUsage.passes == 0 && unrelatedUsage.promptTokens == nil
                        && unrelatedUsage.completionTokens == nil && unrelatedUsage.totalTokens == nil
                        && unrelatedUsage.countsEstimated == nil && unrelatedUsage.cost == nil
                        && ownedIDs.allSatisfy { id in
                        let passes = usageRows.filter { $0.workID?.uuidString == id }.count
                        let total = UsageSummary.task(rows: usageRows, taskID: id)
                        return passes > 0 && total.passes == passes && total.promptTokens == passes * 11
                            && total.completionTokens == passes * 7 && total.totalTokens == passes * 18
                            && total.cachedTokens == passes * 3 && total.reasoningTokens == passes * 2
                            && total.countsEstimated == false && total.cost == nil
                    }, "U03 actual retained typed task token projection missing or mixed (\(mode))")
                    let encodedUsage = String(decoding: try JSONEncoder().encode(usageRows), as: UTF8.self)
                    check([request, target.path, TypedCalendarProbe.agenda, TypedCalendarProbe.created, raw]
                        .allSatisfy { !encodedUsage.contains($0) },
                        "U04 typed objective/argument/file/result leaked into existing usage log (\(mode))")
                    let usageReport = UsageReport.lines(for: usageRows, files: 1, since: .distantPast, feature: "task.")
                    check(usageRows.filter { UsageReport.matches($0, feature: "task.") }.count == usageRows.count
                        && ownedIDs.allSatisfy { id in usageReport.contains { $0.hasPrefix("USAGE_TASK_ROW task=" + id + " ") } },
                        "U05 existing task report omitted actual typed worker rows (\(mode))")
                    print("TYPED_TASK_USAGE_TRACE mode=\(mode) passes=\(usageRows.count) providerCalls=\(providerCalls) tasks=\(ownedIDs.count) attributed=\(usageRows.filter { $0.taskID != nil }.count) costUnavailable=true")
                }
                check(bridge.cachedTasks.allSatisfy { UUID(uuidString: $0.id).flatMap { bridge.typedWorkerForTesting($0) } == nil }, "C02 actual joined terminal release (\(mode))")
                check(gate.pending == nil && gate.queuedCount == 0 && !contextRejected, "C03 actual card/context cleanup (\(mode))")
                // Feature verdicts never supply lifetime admission. These cached
                // boundaries are required for every mode before its scope retires.
                handoffSafe = handoffSafe && joined && settled && !callers.isEmpty && !operations.isEmpty
                    && bridge.cachedTasks.allSatisfy { UUID(uuidString: $0.id).flatMap { bridge.typedWorkerForTesting($0) } == nil }
                    && gate.pending == nil && gate.queuedCount == 0 && !contextRejected
                    && capabilityInstalled && activityInstalled
                    && VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: root, bridge: bridge)
                    && DictionaryStore.capturedRootMatchesForTesting(root) == true
                handoffModes += 1
                print("TYPED_WORK_CASE mode=\(mode) checks=\(checks) reads=\(reads) effects=\(events.count) interrupts=\(boundary.interrupts) physicalCalendar=false")
                scopeRaceEnabled = false; scopeRaceOwner = nil; scopeRaceBridge = nil; scopeRaceBoundary = nil
                await joinPhraseTasks() // SAME first-output Tasks before this mode's scope ends.
                NextMemory.finishActivityContextForTesting(root: root); activityInstalled = false
                VoiceCapabilitySnapshot.finishContextForTesting(root: root); capabilityInstalled = false
                contextManager = nil; probe = nil
            }
        } catch {
            handoffSafe = false // A cleanup join cannot qualify an interrupted mode.
            failures.append("typed work: INVALID \(error)")
            retainCurrentOperations()
            if let contextManager { for row in contextManager.tasks where row.source == "text" { contextManager.cancel(row.id) } }
            agent.interrupt(); await probe?.releaseAll()
            for caller in callers { _ = await caller.value }; for operation in operations { _ = await operation.value }
            joined = await probe?.activeCalls == 0
        }
        observer.cancel(); await observer.value
        if frontendInstalled { await LocalVoiceFrontend.shared.setGenerationForTesting(nil) }
        await joinPhraseTasks() // Catch/normal typed scope is drained before handoff.
        if let afterJoinedCases, joined, handoffSafe, handoffModes == 7,
           !contextRejected, rootCreated, dictionaryInstalled, contextInstalled,
           islandInstalled, outputInstalled, let islandBridge, let retainedOutput, let retainedIsland,
           DictionaryStore.capturedRootMatchesForTesting(root) == true,
           IslandState.sharedIfLoaded === retainedIsland,
           VoicePlaybackDelivery.shared.installedOutputForTesting === retainedOutput {
            // The original duplex caller shares this already admitted UUID root.
            // All typed caller/worker/observer/native work is joined before handoff.
            restoreInheritedOverrides()

            guard !contextInstalled || ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) else {
                return (checks, failures + ["typed work: INVALID context handoff"])
            }
            contextInstalled = false
            // The continuation returns only after its actual entered Tasks join;
            // a failed feature assertion does not turn a completed drain into absence.
            if !(await afterJoinedCases(root, islandBridge)) { failures.append("typed work: A7 duplex continuation failed") }
        } else if afterJoinedCases != nil {
            failures.append("typed work: INVALID undrained duplex handoff")
        }
        await joinPhraseTasks() // Includes every owner cleared by internal A7 resets/cancels.
        if let retainedOutput {
            _ = retainedOutput.observePhraseTaskForTesting(nil)
            retainedOutput.setPhraseForTesting(nil)
        }
        check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C04 owner/default invariance")
        return (checks, failures)
    }
}
@MainActor
private final class TypedSubmissionBoundary {
    var interrupts = 0
    var finished: [String] = []
    var revised: [(TaskID, Int)] = []
}
private actor TypedCalendarProbe {
    static let agenda = "The authored agenda has the dentist at 14:00."
    static let created = "The confined fake calendar event was created."
    let path: String
    private let tools: [AgentTool]
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var released = Set<String>()
    private var sealedReleased = false
    private(set) var activeCalls = 0
    private(set) var completedCalls = 0
    var heldCount: Int { held.count }
    func settleMetadata() -> (active: Int, heldDentist: Bool, heldDad: Bool, releasedDentist: Bool, releasedDad: Bool, sealedReleased: Bool) {
        (activeCalls, held["Dentist"] != nil, held["Dad"] != nil, released.contains("Dentist"), released.contains("Dad"), sealedReleased)
    }
    init(path: String, tools: [AgentTool]) { self.path = path; self.tools = tools }
    func releaseAll() { sealedReleased = true; let old = held; held = [:]; released.formUnion(old.keys); for hold in old.values { hold.resume() } }
    static func event(hour: String, dad: Bool) -> [String: String] {
        ["title": dad ? "Call Dad" : "Dentist", "start": "2026-10-06T\(hour):00:00-04:00", "end": "2026-10-06T\(hour):30:00-04:00"]
    }
    static func call(_ name: String, _ args: [String: String], parameters: [WorkspaceTool.Parameter]) throws -> String {
        // Match the SAME catalogue's declared grammar order and nullable optionals.
        // NSNull is omitted by the production parser, preserving exact supplied args.
        guard Set(args.keys).isSubset(of: Set(parameters.map(\.name))),
              parameters.filter(\.isRequired).allSatisfy({ args[$0.name] != nil }) else { throw ScopeError.invalidArguments }
        func quoted(_ text: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        let fields = try parameters.map { parameter in
            let value = try args[parameter.name].map { try quoted($0) } ?? "null"
            return try quoted(parameter.name) + ":" + value
        }.joined(separator: ",")
        let result = "<tool_call>{\"name\":" + (try quoted(name)) + ",\"arguments\":{" + fields
            + "},\"rationale\":\"Apply the exact authored temporary calendar request.\"}</tool_call>"
        guard AgentToolCallParser.calls(in: result).first?.arguments == args else { throw ScopeError.invalidArguments }
        return result
    }
    private func call(_ name: String, _ args: [String: String]) throws -> String {
        guard let tool = tools.first(where: { $0.id == name }) else { throw ScopeError.invalidArguments }
        return try Self.call(name, args, parameters: tool.parameters)
    }
    private enum ScopeError: Error { case missingCurrentRequest, invalidArguments }
    func complete(_ user: String) async throws -> String {
        activeCalls += 1; defer { activeCalls -= 1; completedCalls += 1 }
        guard let start = user.range(of: "Current user request:\n", options: .backwards) else { throw ScopeError.missingCurrentRequest }
        let tail = user[start.upperBound...]
        let done = tail.range(of: "\n\nWhat you have already done:\n")
        let current = String(done.map { tail[..<$0.lowerBound] } ?? tail).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { throw ScopeError.missingCurrentRequest }
        let results = done.map { String(tail[$0.upperBound...]) } ?? ""
        if results.contains(Self.created) { return "The calendar request is ready." }
        let dad = current.contains("also remind me to call Dad")
        if !dad && !results.contains(Self.agenda) { return try call("filesystem.read", ["path": path]) }
        let key = dad ? "Dad" : "Dentist"
        if !sealedReleased, !released.contains(key), held[key] == nil { await withCheckedContinuation { held[key] = $0 } }
        return try call("create_event", Self.event(hour: current.contains("make it 3 pm") ? "15" : "14", dad: dad))
    }
}
private struct TypedCalendarProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: TypedCalendarProbe
    var displayModelName: String { "Typed Task Usage Fixture" }
    var contextTokens: Int { 8192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let value = try await probe.complete(user)
        ModelPassRecorder.current?.report(promptTokens: 11, cachedTokens: 3,
            completionTokens: 7, reasoningTokens: 2, finishReason: nil, estimated: false)
        return LLMCompletion(text: value, generatedTokens: value.count, duration: 0)
    }
}
