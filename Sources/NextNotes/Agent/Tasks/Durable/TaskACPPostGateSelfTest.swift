import Foundation

/// Actual Manager -> ACPBackend -> Session -> owned peer, same original/fixed inputs.
/// Actual post-Gate attempt revalidation; no nested effect is ever executed.
@MainActor
enum TaskACPPostGateSelfTest {
    private enum FixtureError: Error {
        case unsafeRoot, busyGate, missingContext, missingRow, missingReceipt, timeout, invalidPeer
    }

    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    // Match the existing AgentTaskStore canonical ISO export before its SQL save.
    // Live handle identity keeps the exact original in-memory producer timestamp.
    private static func canonicalDate(_ date: Date) throws -> Date {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Date.self, from: encoder.encode(date))
    }

    private static func object(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        guard PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            throw FixtureError.busyGate
        }
        let ownerBefore = SelfTestStoreGuard.take()
        let grantsBefore = PermissionGrantStore.shared.grants
        let priorFake = AgentToolExecutor.fakeForTesting
        let priorFire = AgentToolExecutor.fireOverrideForTesting
        defer {
            AgentToolExecutor.fakeForTesting = priorFake
            AgentToolExecutor.fireOverrideForTesting = priorFire
        }
        AgentToolExecutor.fakeForTesting = nil
        var unexpectedTools = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in
            unexpectedTools += 1
            throw FixtureError.invalidPeer
        }
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        let objective = "Owned ACP nested review fixture: no tools or external effects"
        let marker = "Owned ACP nested fixture finished."
        let sessionID = "fixture-acp-nested-attempt"
        let warning = "\nNext Notes could not independently verify the effect. Inspect the target before retrying."

        for mode in ["accepted", "post-approval-held"] {
            let heldMode = mode == "post-approval-held"
            let directory = safe.appendingPathComponent("acp-post-gate-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let script = directory.appendingPathComponent("owned-peer.py")
            let configFile = directory.appendingPathComponent("config.json")
            let releaseFile = directory.appendingPathComponent("release-permission.json")
            let wireFile = directory.appendingPathComponent("wire-result.json")
            let callsFile = directory.appendingPathComponent("calls.json")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var context: TaskJournalContext?
            var rowAtEntry: AgentTask?
            var bindingAtEntry: TaskWorkerBinding?
            var entryValid = false
            var entered = 0
            var ended = 0
            var announcements: [String] = []
            var holdingSQL: TaskStore?
            var holdingManager: AgentTaskManager?
            defer { holdingSQL?.close() }
            let askBefore = PermissionGate.shared.askCount
            let toolsBefore = unexpectedTools
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendExitForTesting = { ended += 1 }
            manager.backendEntryForTesting = {
                entered += 1
                guard let captured = TaskEventJournal.current else { throw FixtureError.missingContext }
                context = captured
                let reader = TaskStore(root: directory)
                defer { reader.close() }
                guard let row = try reader.load().first(where: { $0.id == captured.taskID }) else {
                    throw FixtureError.missingRow
                }
                rowAtEntry = row
                bindingAtEntry = manager.workerBinding(taskID: captured.taskID)
                entryValid = captured.isStillValid?() == true
                let config: [String: Any] = ["marker": marker, "objective": objective,
                    "taskID": captured.taskID, "taskAttempt": captured.attempt,
                    "taskLeaseOwner": captured.leaseOwner ?? "", "database": sql.fileURL.path,
                    "receipts": receiptFile.path]
                try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
                    .write(to: configFile, options: .atomic)
            }
            // Common original/fixed SelfTest-only switch reaches actual Broker and Gate.
            let submitted = manager.submit(objective: objective, arguments: ["acpFixture": script.path, "acpFixtureAskPermission": "true"],
                backend: .acp, source: "selftest")
            do {
                guard await reached({ FileManager.default.fileExists(atPath:
                    directory.appendingPathComponent("prompt-observed.json").path) }) else { throw FixtureError.timeout }
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-error.json").path),
                      let captured = context, let binding = bindingAtEntry else { throw FixtureError.invalidPeer }
                let startupReceipts = ActionReceiptStore(fileURL:
                    directory.appendingPathComponent("startup-fired-snapshot.json"))
                guard startupReceipts.receipts.count == 1, let fired = startupReceipts.receipts.first else {
                    throw FixtureError.missingReceipt
                }
                let joined = [fired.actionID.uuidString]
                let startup = object(directory.appendingPathComponent("startup-primary.json"))
                let startupDurability = startup["durability"] as? [String: Any] ?? [:]
                let startupEvents = startup["toolStartEvents"] as? [[String: Any]] ?? []
                let prompt = object(directory.appendingPathComponent("prompt-observed.json"))
                // C01
                check(entered == 1 && ended == 0 && manager.backendStartsForTesting == 1,
                    "ACP post-Gate: actual backend was not suspended in its first prompt (\(mode))")
                // C02
                check(rowAtEntry?.status == .running && rowAtEntry?.durability?.attempt == 1
                    && rowAtEntry?.durability?.leaseOwner == owner
                    && rowAtEntry?.durability?.runtimeClass == .acpWorker
                    && rowAtEntry?.durability?.resumePolicy == .neverAuto
                    && rowAtEntry?.durability?.attemptStartedAt != nil,
                    "ACP post-Gate: original backend lacked admitted normal typed ACP ownership (\(mode))")
                let canonicalBindingStart = try canonicalDate(binding.startedAt)
                SelfTest.diagnostic("TASK_ACP_NESTED_ENTRY_TRACE: mode=\(mode) entryValid=\(entryValid) receiptOwner=\(captured.receiptStore === receipts) memoryStart=\(binding.startedAt.timeIntervalSince1970) diskStart=\(rowAtEntry?.durability?.attemptStartedAt?.timeIntervalSince1970 ?? -1) canonicalStart=\(canonicalBindingStart.timeIntervalSince1970)")
                // C03
                check(captured.taskID == submitted.id && captured.attempt == 1 && captured.leaseOwner == owner
                    && captured.receiptStore === receipts && entryValid
                    && binding.taskID == submitted.id && binding.attempt == 1 && binding.leaseOwner == owner
                    && binding.startedAt == manager.task(id: submitted.id)?.durability?.attemptStartedAt
                    && canonicalBindingStart == rowAtEntry?.durability?.attemptStartedAt,
                    "ACP post-Gate: original live context lost exact owning manager/receipt/handle (\(mode))")
                // C04
                check(rowAtEntry?.durability?.receiptIDs.isEmpty == true,
                    "ACP post-Gate: receipt was joined before real preparation (\(mode))")
                // C05
                check(prompt["taskID"] as? String == submitted.id && prompt["sessionID"] as? String == sessionID
                    && prompt["promptCount"] as? Int == 1,
                    "ACP post-Gate: peer did not observe the real exact first prompt (\(mode))")
                // C06
                check(fired.taskID == submitted.id && fired.taskAttempt == 1 && fired.taskLeaseOwner == owner
                    && fired.status == .fired && fired.events.last?.stage == .fired
                    && fired.toolID == "mcp.acp_session" && fired.preparedAction?.id == fired.actionID
                    && fired.preparedAction?.routing.taskID == submitted.id
                    && fired.preparedAction?.intentID == fired.intentID
                    && fired.preparedAction?.executionPlan.toolID == fired.toolID
                    && fired.preparedAction?.executionPlan.arguments["objective"] == objective,
                    "ACP post-Gate: owned process lacked exact actual saved fired preparation (\(mode))")
                // C07
                check(startup["taskID"] as? String == submitted.id && startup["state"] as? String == "running"
                    && startup["actionID"] as? String == fired.actionID.uuidString
                    && startupDurability["attempt"] as? Int == 1
                    && startupDurability["leaseOwner"] as? String == owner
                    && startupDurability["receiptIDs"] as? [String] == joined
                    && startupEvents.count == 1 && startupEvents.first?["detail"] as? String == "mcp.acp_session"
                    && startupEvents.first?["attempt"] as? Int == 1,
                    "ACP post-Gate: actual startup missed exact primary receipt/tool-start join (\(mode))")
                // C08: workerBinding itself refuses a cancelled handle.
                check(manager.workerBinding(taskID: submitted.id) == binding
                    && !FileManager.default.fileExists(atPath: wireFile.path),
                    "ACP post-Gate: original handle was cancelled or permission ran before release (\(mode))")
                try JSONSerialization.data(withJSONObject: ["release": true], options: [.sortedKeys])
                    .write(to: releaseFile, options: .atomic)
                guard await reached({ PermissionGate.shared.pending?.taskID == submitted.id }) else {
                    throw FixtureError.timeout
                }
                let gate = PermissionGate.shared
                guard let request = gate.pending, request.taskID == submitted.id,
                      let initialReview = gate.pendingReview,
                      let taskField = initialReview.fields.first(where: { $0.name == "taskID" }),
                      taskField.value == submitted.id,
                      initialReview.blockers.allSatisfy({ $0.name == "taskID" && $0.problem == .notConfirmed }),
                      taskField.problem == nil || taskField.problem == .notConfirmed else {
                    throw FixtureError.invalidPeer
                }
                let requestEncoder = JSONEncoder()
                requestEncoder.outputFormatting = [.sortedKeys]
                let requestBytes = try requestEncoder.encode(request)
                let initialArguments = initialReview.arguments
                let initialFieldValues = initialReview.fields.map { ($0.name, $0.value) }
                SelfTest.diagnostic("TASK_ACP_POST_GATE_REVIEW_TRACE: mode=\(mode) fields=\(initialReview.fields.count) problems=\(initialReview.fields.filter { $0.problem != nil }.count) taskProblem=\(taskField.problem?.rawValue ?? "none") unverified=\(taskField.unverified.count)")
                // Same prerequisite as n: genuine confirmation of exact taskID ONLY.
                if taskField.problem == .notConfirmed {
                    ToolCallReviewStore.shared.confirm(id: request.id, field: "taskID")
                }
                guard let review = gate.pendingReview, let sameRequest = gate.pending,
                      review.isReadyToRun else { throw FixtureError.invalidPeer }
                let confirmedRequestBytes = try requestEncoder.encode(sameRequest)
                let sameFieldValues = zip(initialFieldValues, review.fields).allSatisfy {
                    $0.0.0 == $0.1.name && $0.0.1 == $0.1.value
                }
                // E01
                check(sameRequest == request && confirmedRequestBytes == requestBytes
                    && review.arguments == initialArguments && review.fields.count == initialFieldValues.count
                    && sameFieldValues && request.arguments["taskID"] == submitted.id,
                    "ACP post-Gate: exact task-only confirmation changed request/arguments/field values (\(mode))")
                let reviewToolID = AgentToolRegistry.shared.tool(named: request.toolID)?.id ?? "mcp." + request.toolID
                let requested = try sql.journal(taskID: submitted.id)
                // C09
                check(gate.askCount == askBefore + 1 && gate.queuedCount == 0
                    && request.toolID == "mcp.acp_nested_tool" && request.arguments["taskID"] == submitted.id
                    && review.id == request.id && review.toolID == reviewToolID && review.isReadyToRun,
                    "ACP post-Gate: actual Session/Broker/Gate request/review control failed (\(mode))")
                // C10
                check(requested.filter { $0.draft.kind == .permissionRequested && $0.draft.attempt == 1 }.count == 1
                    && !requested.contains { $0.draft.kind == .permissionApproved || $0.draft.kind == .permissionDenied }
                    && !FileManager.default.fileExists(atPath: wireFile.path)
                    && manager.workerBinding(taskID: submitted.id) == binding && captured.isStillValid?() == true,
                    "ACP post-Gate: real current pending attempt/request/wire control failed (\(mode))")

                // Synchronous MainActor sequence: NOTHING may await between respond and fresh hold.
                // The suspended Gate.ask continuation cannot run until this fixture yields.
                let decisionAccepted = gate.respond(id: request.id, approved: true, duration: .once)
                let approvalRow = try sql.load().first { $0.id == submitted.id }
                let approvedJournal = try sql.journal(taskID: submitted.id)
                if heldMode {
                    let freshSQL = TaskStore(root: directory)
                    holdingSQL = freshSQL
                    let freshStore = AgentTaskStore(fileURL: export, mirror: freshSQL)
                    guard freshStore.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
                    holdingManager = AgentTaskManager(store: freshStore,
                        receiptStore: ActionReceiptStore(fileURL: receiptFile))
                }
                // C11: approved fact existed BEFORE hold; it is not retroactively erased.
                check(decisionAccepted && gate.pending == nil && gate.queuedCount == 0
                    && approvalRow?.status == .running && approvalRow?.durability?.receiptIDs == joined
                    && approvedJournal.filter { $0.draft.kind == .permissionApproved && $0.draft.attempt == 1 }.count == 1
                    && !approvedJournal.contains { $0.draft.kind == .permissionDenied }
                    && PermissionGrantStore.shared.grants == grantsBefore,
                    "ACP post-Gate: genuine decision did not commit exact approval before hold/yield (\(mode))")
                let wireBoundaryRow = try sql.load().first { $0.id == submitted.id }
                let wireBoundaryJournal = try sql.journal(taskID: submitted.id)
                if heldMode {
                    // H01
                    check(holdingManager?.historyReadFailure == nil
                        && holdingManager?.lastPersistenceResult?.primaryCommitted == true
                        && holdingManager?.task(id: submitted.id)?.status == .recovering
                        && holdingManager?.backendStartsForTesting == 0 && wireBoundaryRow?.status == .recovering,
                        "ACP post-Gate: real synchronous fresh manager did not commit recovering without dispatch")
                    // H02
                    check(manager.task(id: submitted.id)?.status == .running
                        && manager.workerBinding(taskID: submitted.id) == binding && captured.isStillValid?() == false
                        && !FileManager.default.fileExists(atPath: wireFile.path) && ended == 0,
                        "ACP post-Gate: post-approval hold was replaced by cancelled/released task or early wire")
                    // H03
                    check(wireBoundaryRow?.durability?.attempt == 1 && wireBoundaryRow?.durability?.leaseOwner == owner
                        && wireBoundaryRow?.durability?.attemptStartedAt == approvalRow?.durability?.attemptStartedAt
                        && wireBoundaryRow?.durability?.receiptIDs == joined
                        && wireBoundaryJournal.filter { $0.draft.kind == .permissionApproved }.count == 1
                        && wireBoundaryJournal.filter { $0.draft.kind == .recoveryHeld }.count == 1,
                        "ACP post-Gate: hold changed exact approved attempt/receipt or fabricated missing approval")
                    let approvedSeq = wireBoundaryJournal.first { $0.draft.kind == .permissionApproved }?.seq ?? 0
                    let heldSeq = wireBoundaryJournal.first { $0.draft.kind == .recoveryHeld }?.seq ?? 0
                    // H07
                    check(approvedSeq > 0 && heldSeq > approvedSeq
                        && approvedJournal.first { $0.draft.kind == .permissionApproved }?.seq == approvedSeq,
                        "ACP post-Gate: real held event did not follow the same retained prior approved event")
                } else {
                    // A01
                    check(manager.workerBinding(taskID: submitted.id) == binding && captured.isStillValid?() == true
                        && wireBoundaryRow?.status == .running
                        && !wireBoundaryJournal.contains { $0.draft.kind == .recoveryHeld },
                        "ACP post-Gate: accepted control lost exact valid attempt before wire")
                }
                guard await reached({ FileManager.default.fileExists(atPath: wireFile.path) }) else {
                    throw FixtureError.timeout
                }
                let wire = object(wireFile)
                let result = wire["result"] as? [String: Any] ?? [:]
                let outcome = result["outcome"] as? [String: String]
                // C12: held mode is the intended original authorizing-wire failure.
                check(outcome == ["outcome": "selected", "optionId": heldMode ? "fixture-reject-once" : "fixture-allow-once"]
                    && result["optionId"] == nil,
                    "ACP post-Gate: Session returned authorizing wire after approved attempt became held (\(mode))")
                // C13
                check(wire["replyCount"] as? Int == 1 && wire["requestCount"] as? Int == 1
                    && wire["promptCount"] as? Int == 1 && wire["cancelBeforeVerdict"] as? Bool == false
                    && wire["externalEffectCount"] as? Int == 0,
                    "ACP post-Gate: real wire substituted cancellation/duplicate/effect (\(mode))")
                let peerRequest = object(directory.appendingPathComponent("permission-request.json"))
                let offered = peerRequest["options"] as? [[String: String]] ?? []
                // C14
                check(peerRequest["taskID"] as? String == submitted.id && peerRequest["sessionID"] as? String == sessionID
                    && peerRequest["requestID"] as? Int == 900
                    && offered == [["optionId": "fixture-allow-once", "name": "Allow once", "kind": "allow_once"],
                                   ["optionId": "fixture-reject-once", "name": "Reject", "kind": "reject_once"]],
                    "ACP post-Gate: actual peer lost exact offered options/session/request (\(mode))")
                let atWireRow = try sql.load().first { $0.id == submitted.id }
                let atWireJournal = try sql.journal(taskID: submitted.id)
                // C15
                check(atWireRow == wireBoundaryRow && atWireJournal == wireBoundaryJournal && ended == 0
                    && atWireJournal.filter { $0.draft.kind == .permissionRequested && $0.draft.attempt == 1 }.count == 1
                    && atWireJournal.filter { $0.draft.kind == .permissionApproved && $0.draft.attempt == 1 }.count == 1
                    && !atWireJournal.contains { $0.draft.kind == .permissionDenied },
                    "ACP post-Gate: post-approval revalidation changed primary history or duplicated decision (\(mode))")
                try JSONSerialization.data(withJSONObject: ["release": true], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent("release-result.json"), options: .atomic)
                guard await reached({ ended == 1 }) else { throw FixtureError.timeout }
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-error.json").path) else {
                    throw FixtureError.invalidPeer
                }
                let primary = try sql.load().first { $0.id == submitted.id }
                let journal = try sql.journal(taskID: submitted.id)
                let persisted = ActionReceiptStore(fileURL: receiptFile)
                guard persisted.receipts.count == 1, let receipt = persisted.receipts.first else { throw FixtureError.missingReceipt }
                // C16
                check(receipt.actionID == fired.actionID && receipt.preparedAction == fired.preparedAction
                    && receipt.taskID == submitted.id && receipt.taskAttempt == 1 && receipt.taskLeaseOwner == owner
                    && receipt.status == .couldNotVerify && receipt.result == marker && receipt.artifacts == [sessionID],
                    "ACP post-Gate: harmless actual reply lost retained fired/result receipt (\(mode))")
                // C17
                check(entered == 1 && ended == 1 && manager.backendStartsForTesting == 1
                    && manager.workerBinding(taskID: submitted.id) == nil && captured.isStillValid?() == false,
                    "ACP post-Gate: actual owned backend failed to join/release exactly once (\(mode))")
                let calls = (try? JSONSerialization.jsonObject(with: Data(contentsOf: callsFile))) as? [String]
                // C18
                check(calls == ["initialize", "session/new", "session/prompt"]
                    && object(directory.appendingPathComponent("launch.json"))["launchCount"] as? Int == 1,
                    "ACP post-Gate: peer restarted or substituted protocol cancellation (\(mode))")
                // C19
                check(gate.pending == nil && gate.queuedCount == 0 && PermissionGrantStore.shared.grants == grantsBefore
                    && unexpectedTools == toolsBefore,
                    "ACP post-Gate: actual Gate/grants/no-backing contract failed (\(mode))")
                // C20
                check(primary?.durability?.attempt == 1 && primary?.durability?.leaseOwner == owner
                    && primary?.durability?.receiptIDs == joined,
                    "ACP post-Gate: final primary lost exact original approved attempt/receipt (\(mode))")
                if heldMode {
                    // H04
                    check(primary == wireBoundaryRow && journal == wireBoundaryJournal,
                        "ACP post-Gate: old completion changed exact held primary/journal")
                    // H05
                    check(!announcements.contains { $0.contains(marker) || $0.hasPrefix("fixture artifact announcement:") }
                        && !journal.contains { $0.draft.kind == .jobCompleted },
                        "ACP post-Gate: held attempt delivered old task success")
                    // H06
                    check(holdingManager?.task(id: submitted.id)?.status == .recovering
                        && holdingManager?.backendStartsForTesting == 0,
                        "ACP post-Gate: held owner lost recovering or started another worker")
                } else {
                    // A02
                    check(primary?.status == .completed && manager.task(id: submitted.id)?.status == .completed
                        && primary?.result == marker + warning && primary?.artifacts == [sessionID],
                        "ACP post-Gate: unchanged accepted reply failed actual task consumer")
                    // A03
                    check(announcements.contains(marker + warning) && journal.contains { $0.draft.kind == .jobCompleted },
                        "ACP post-Gate: unchanged accepted task success delivery changed")
                }
                ToolCallReviewStore.shared.remove(id: request.id)
                let callBytes = try Data(contentsOf: callsFile)
                let freshSQL = TaskStore(root: directory)
                defer { freshSQL.close() }
                let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: freshSQL),
                    receiptStore: ActionReceiptStore(fileURL: receiptFile))
                for _ in 0..<16 { await Task.yield() }
                let rereadPrimary = try freshSQL.load().first { $0.id == submitted.id }
                let callBytesAfter = try Data(contentsOf: callsFile)
                // C21
                check(fresh.task(id: submitted.id) == primary && rereadPrimary == primary
                    && fresh.backendStartsForTesting == 0 && callBytesAfter == callBytes,
                    "ACP post-Gate: actual fresh reader changed history or replayed peer (\(mode))")
                // C22
                check(journal.filter { $0.draft.kind == .permissionRequested && $0.draft.attempt == 1 }.count == 1
                    && journal.filter { $0.draft.kind == .permissionApproved && $0.draft.attempt == 1 }.count == 1
                    && !journal.contains { $0.draft.kind == .permissionDenied },
                    "ACP post-Gate: final actual request/approval provenance changed (\(mode))")
                SelfTest.diagnostic("TASK_ACP_POST_GATE_TRACE: mode=\(mode) decision=\(decisionAccepted) wire=\(outcome?["optionId"] ?? "absent") primary=\(primary?.status.rawValue ?? "absent") originalMemory=\(manager.task(id: submitted.id)?.status.rawValue ?? "absent") approvals=\(journal.filter { $0.draft.kind == .permissionApproved }.count) held=\(journal.filter { $0.draft.kind == .recoveryHeld }.count) starts=\(manager.backendStartsForTesting) ended=\(ended) joined=\(primary?.durability?.receiptIDs.count ?? 0)")
            } catch {
                try? JSONSerialization.data(withJSONObject: ["release": true]).write(to: releaseFile, options: .atomic)
                try? JSONSerialization.data(withJSONObject: ["release": true]).write(
                    to: directory.appendingPathComponent("release-result.json"), options: .atomic)
                PermissionGate.shared.cancelPending(taskID: submitted.id)
                if ended == 0 {
                    manager.cancel(submitted.id)
                    let drained = await reached { ended == 1 }
                    check(drained, "ACP post-Gate: error cleanup failed to drain exact owned worker (\(mode))")
                }
                throw error
            }
        }
        // O01
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty
            && PermissionGrantStore.shared.grants == grantsBefore,
            "ACP post-Gate: owned fixture changed owner stores/defaults/grants")
    }

    private static let peer = #"""
        import json, pathlib, sqlite3, sys, tempfile, time, urllib.parse
        
        root = pathlib.Path(__file__).resolve().parent
        temporary = pathlib.Path(tempfile.gettempdir()).resolve()
        assert root != temporary and temporary in root.parents
        assert 'Application Support' not in root.parts
        config = json.loads((root / 'config.json').read_text())
        assert pathlib.Path(config['database']).resolve().parent == root
        assert pathlib.Path(config['receipts']).resolve().parent == root
        session = 'fixture-acp-nested-attempt'
        options = [
            {'optionId': 'fixture-allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
            {'optionId': 'fixture-reject-once', 'name': 'Reject', 'kind': 'reject_once'}
        ]
        calls = []
        prompt_id = None
        permission_requests = 0
        permission_replies = 0
        cancel_before_verdict = False
        
        def write(name, value):
            temporary_file = root / (name + '.tmp')
            temporary_file.write_text(json.dumps(value, sort_keys=True))
            temporary_file.replace(root / name)
        
        def send(value):
            sys.stdout.write(json.dumps(value) + '\n')
            sys.stdout.flush()
        
        def primary():
            connection = sqlite3.connect('file:' + urllib.parse.quote(config['database']) + '?mode=ro', uri=True)
            try:
                row = connection.execute('SELECT id,state,durability FROM task WHERE id=?', (config['taskID'],)).fetchone()
                assert row is not None
                events = connection.execute('SELECT kind,detail,attempt FROM task_event WHERE task_id=? ORDER BY seq', (config['taskID'],)).fetchall()
            finally:
                connection.close()
            return {'taskID': row[0], 'state': row[1], 'durability': json.loads(row[2]) if row[2] else {},
                    'toolStartEvents': [{'kind': kind, 'detail': detail, 'attempt': attempt}
                                        for kind, detail, attempt in events if kind == 'toolStarted']}
        
        def main():
            global prompt_id, permission_requests, permission_replies, cancel_before_verdict
            assert not (root / 'launch.json').exists()
            write('launch.json', {'launchCount': 1})
            receipt_bytes = pathlib.Path(config['receipts']).read_bytes()
            receipts = json.loads(receipt_bytes)
            assert len(receipts) == 1
            receipt = receipts[0]
            prepared = receipt['preparedAction']
            assert receipt['taskID'] == config['taskID'] and receipt['taskAttempt'] == config['taskAttempt']
            assert receipt['taskLeaseOwner'] == config['taskLeaseOwner']
            assert receipt['status'] == 'fired' and receipt['events'][-1]['stage'] == 'fired'
            assert receipt['toolID'] == 'mcp.acp_session'
            assert prepared['id'] == receipt['actionID'] and prepared['routing']['taskID'] == config['taskID']
            assert prepared['intentID'] == receipt['intentID']
            assert prepared['executionPlan']['toolID'] == receipt['toolID']
            assert prepared['executionPlan']['arguments']['objective'] == config['objective']
            (root / 'startup-fired-snapshot.json').write_bytes(receipt_bytes)
            snapshot = primary()
            snapshot['actionID'] = receipt['actionID']
            write('startup-primary.json', snapshot)
            for line in sys.stdin:
                message = json.loads(line)
                mid, method = message.get('id'), message.get('method')
                if method is not None:
                    calls.append(method)
                    write('calls.json', calls)
                if method == 'initialize':
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {'protocolVersion': 1, 'agentCapabilities': {}}})
                elif method == 'session/new':
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {'sessionId': session}})
                elif method == 'session/prompt':
                    assert prompt_id is None
                    assert message['params']['sessionId'] == session
                    assert message['params']['prompt'][0]['text'] == config['objective']
                    prompt_id = mid
                    write('prompt-observed.json', {'taskID': config['taskID'], 'sessionID': session, 'promptCount': 1})
                    deadline = time.monotonic() + 10
                    while not (root / 'release-permission.json').exists():
                        if time.monotonic() >= deadline:
                            raise TimeoutError('owned fixture release barrier')
                        time.sleep(0.005)
                    release = json.loads((root / 'release-permission.json').read_text())
                    assert release == {'release': True}
                    write('permission-primary.json', primary())
                    permission_requests += 1
                    write('permission-request.json', {'taskID': config['taskID'], 'sessionID': session,
                            'requestCount': permission_requests, 'requestID': 900, 'options': options})
                    send({'jsonrpc': '2.0', 'id': 900, 'method': 'session/request_permission', 'params': {
                        'sessionId': session,
                        'toolCall': {'toolCallId': 'owned-review-only', 'title': 'Owned fixture review only',
                                     'kind': 'other', 'status': 'pending'}, 'options': options}})
                elif method is None and mid == 900:
                    assert prompt_id is not None and permission_replies == 0
                    permission_replies += 1
                    write('wire-result.json', {'result': message.get('result', {}), 'replyCount': permission_replies,
                            'requestCount': permission_requests, 'cancelBeforeVerdict': cancel_before_verdict,
                            'externalEffectCount': 0, 'promptCount': 1})
                    # Hold only the fixture's prompt completion: observations cannot race terminal saves.
                    deadline = time.monotonic() + 10
                    while not (root / 'release-result.json').exists():
                        if time.monotonic() >= deadline:
                            raise TimeoutError('owned fixture result barrier')
                        time.sleep(0.005)
                    assert json.loads((root / 'release-result.json').read_text()) == {'release': True}
                    # SAME control for old allow and future reject. No tool is executed.
                    send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': session, 'update': {
                        'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': config['marker']}}}})
                    send({'jsonrpc': '2.0', 'id': prompt_id, 'result': {'stopReason': 'end_turn'}})
                elif method == 'session/cancel':
                    if permission_replies == 0:
                        cancel_before_verdict = True
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {}})
                else:
                    raise ValueError('unexpected owned protocol message')
        
        try:
            main()
        except Exception as error:
            write('peer-error.json', {'errorClass': type(error).__name__})
            raise
        """#
}
