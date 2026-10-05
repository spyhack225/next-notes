import Foundation

/// SAME normal Manager/Gate and direct approved caller, real owned CLI Process, exact read and receipt.
/// No account, second send, saved identity guess, or effect-retry authority is supplied.
@MainActor
enum TaskCalendarUnknownOutcomeSelfTest {
    private enum FixtureError: Error { case unsafe, missingTask, timeout, wire }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < end {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
    private static let initial = ["title": "Draft owned uncertain appointment",
        "start": "2026-10-05T09:00:00-04:00", "end": "2026-10-05T09:30:00-04:00",
        "description": "Draft purpose", "attendees": "person@owned.invalid"]
    private static var approved: [String: String] {
        var args = initial; args["title"] = "Reviewed owned uncertain appointment"
        args["description"] = "Reviewed purpose"; return args
    }
    private struct Wire {
        let records: [[String: Any]]
        let body: [String: Any]
        var inserts: Int { records.filter { $0["operation"] as? String == "insert" }.count }
        var gets: Int { records.filter { $0["operation"] as? String == "get" }.count }
        var lists: Int { records.filter { $0["operation"] as? String == "list" }.count }
    }
    /// Observes actual returned Process messages; the fixture never fabricates a CLI result.
    private static func wire(_ directory: URL, allowsWrite: Bool) throws -> Wire {
        let log = directory.appendingPathComponent("peer-wire.jsonl")
        let records: [[String: Any]]
        if FileManager.default.fileExists(atPath: log.path) {
            records = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
                guard let record = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                else { throw FixtureError.wire }; return record
            }
        } else { records = [] }
        let pids = records.compactMap { ($0["pid"] as? NSNumber)?.intValue }
        guard pids.count == records.count, pids.allSatisfy({ $0 > 0 }), Set(pids).count == records.count,
              records.allSatisfy({ $0["calendarId"] as? String == "primary"
                && [0, 1].contains(($0["exit"] as? NSNumber)?.intValue ?? -1) }) else { throw FixtureError.wire }
        let body: [String: Any]
        if allowsWrite {
            guard records.count == 1 || records.count == 2,
                  records.first?["operation"] as? String == "insert",
                  records.first?["exit"] as? Int == 1,
                  let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf:
                    directory.appendingPathComponent("peer-event.json"))) as? [String: Any],
                  let id = parsed["id"] as? String, id.count == 32,
                  records.first?["eventId"] as? String == id else { throw FixtureError.wire }
            if records.count == 2 {
                guard ["get", "list"].contains(records[1]["operation"] as? String ?? "") else { throw FixtureError.wire }
                if records[1]["operation"] as? String == "get" {
                    guard records[1]["eventId"] as? String == id else { throw FixtureError.wire }
                }
            }
            body = parsed
        } else {
            guard records.count <= 1, records.allSatisfy({ $0["operation"] as? String == "list" })
                else { throw FixtureError.wire }
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-event.json").path)
                else { throw FixtureError.wire }
            body = [:]
        }
        return Wire(records: records, body: body)
    }
    private static func payload(_ body: [String: Any]) -> Bool {
        body["summary"] as? String == approved["title"]
            && body["description"] as? String == approved["description"]
            && (body["start"] as? [String: String])?["dateTime"] == WorkspaceToolRunner.rfc3339(approved["start"]!)
            && (body["end"] as? [String: String])?["dateTime"] == WorkspaceToolRunner.rfc3339(approved["end"]!)
            && (body["attendees"] as? [[String: String]]) == [["email": "person@owned.invalid"]]
    }
    static func originalCases(root: URL, check parent: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-task-worker-attempt",
              safe.path.hasPrefix(temp.path + "/"), !safe.pathComponents.contains("Application Support"),
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else { throw FixtureError.unsafe }
        let ownerBefore = SelfTestStoreGuard.take()
        let grantsBefore = PermissionGrantStore.shared.grants
        let oldCLI = AgentToolExecutor.workspaceCLIForTesting
        let oldFake = AgentToolExecutor.fakeForTesting, oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.workspaceCLIForTesting = oldCLI
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.fireOverrideForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = .selfTest
        var checks = 0, problems = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { problems += 1 }; parent(value, "calendar unknown " + label)
        }
        var legacyReceipt: ActionReceipt?
        for mode in ["normal-current", "normal-wrong-id", "normal-wrong-description", "normal-unavailable", "normal-receipt-refused"] {
            let directory = safe.appendingPathComponent("calendar-unknown-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafe }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let cli = try TaskCalendarDuplicateReceiptSelfTest.CLI(mode: mode, directory: directory,
                peer: peer, unknownReadback: true)
            AgentToolExecutor.workspaceCLIForTesting = cli
            var handles: [Task<Void, Never>] = [], id: String?, context: TaskJournalContext?
            var exits = 0, deliveries: [String] = [], fired: ActionReceipt?, primaryLinked = false
            var readStage: ActionReceiptStatus?, unknownBytes: Data?
            let retained = directory.appendingPathComponent("retained-unknown.json")
            func capture() {
                if let id, let task = manager.capturedReceiptMutationWorkerForTesting(id: id), !handles.contains(task) {
                    handles.append(task)
                }
            }
            manager.backendEntryForTesting = { context = TaskEventJournal.current; capture() }
            manager.backendExitForTesting = { exits += 1 }
            manager.announcementForTesting = { deliveries.append($0) }
            cli.beforeInsert = {
                guard let context, let row = try sql.load().first(where: { $0.id == context.taskID }),
                      let saved = ActionReceiptStore(fileURL: receiptFile).receipts.first(where: {
                        $0.taskID == context.taskID && $0.taskAttempt == context.attempt && $0.status == .fired
                      }) else { throw FixtureError.unsafe }
                fired = saved
                primaryLinked = row.status == .running && context.attempt > 0
                    && row.durability?.attempt == context.attempt && row.durability?.receiptIDs == [saved.actionID.uuidString]
                    && saved.taskLeaseOwner == row.durability?.leaseOwner
                    && saved.preparedAction?.id == saved.actionID && saved.preparedAction?.executionPlan.arguments == approved
            }
            cli.beforeRead = {
                readStage = fired.flatMap { receipts.receipt(for: $0.actionID)?.status }
                if mode == "normal-receipt-refused" {
                    unknownBytes = try Data(contentsOf: receiptFile)
                    try FileManager.default.moveItem(at: receiptFile, to: retained)
                    try FileManager.default.createDirectory(at: receiptFile, withIntermediateDirectories: false)
                }
            }
            do {
                let task = manager.submit(objective: "Create the reviewed uncertain appointment", tool: "create_event",
                    arguments: initial, source: "selftest")
                id = task.id; capture(); guard !handles.isEmpty else { throw FixtureError.missingTask }
                guard await reached({ manager.task(id: task.id)?.status == .waitingForPermission
                    && PermissionGate.shared.pending?.taskID == task.id }) else { throw FixtureError.timeout }
                capture(); for task in handles { await task.value }
                guard let request = PermissionGate.shared.pending, request.taskID == task.id,
                      request.toolID == "create_event" else { throw FixtureError.unsafe }
                for field in ["title", "description"] {
                    ToolCallReviewStore.shared.update(id: request.id, field: field, to: approved[field]!)
                }
                for field in PermissionGate.shared.pendingReview?.fields ?? [] {
                    ToolCallReviewStore.shared.confirm(id: request.id, field: field.name)
                }
                guard PermissionGate.shared.pendingReview?.isReadyToRun == true else { throw FixtureError.unsafe }
                manager.respondPermission(taskID: task.id, approved: true); capture()
                guard await reached({ exits == 2 }) else { throw FixtureError.timeout }
                capture(); for task in handles { await task.value }
                try cli.qualifyWire()
                let observed = try wire(directory, allowsWrite: true)
                let row = try sql.load().first { $0.id == task.id }, cached = manager.task(id: task.id)
                let journal = try sql.journal(taskID: task.id)
                let saved = fired.flatMap { ActionReceiptStore(fileURL:
                    mode == "normal-receipt-refused" && unknownBytes != nil ? retained : receiptFile).receipt(for: $0.actionID) }
                let positive = mode == "normal-current", refused = mode == "normal-receipt-refused"
                check(cli.wireQualified && cli.calls == cli.returns && payload(observed.body), "C01 actual returned CLI received reviewed fields (\(mode))")
                check(primaryLinked && row?.durability?.receiptIDs == fired.map { [$0.actionID.uuidString] }
                    && fired?.preparedAction?.executionPlan.arguments == approved, "C02 actual positive attempt/prepared receipt link (\(mode))")
                check(observed.inserts == 1 && cli.inserts == 1, "C03 no second insert or automatic resend (\(mode))")
                check(observed.gets == 1 && observed.lists == 0, "F01 exact sent event ID GET replaces absent/fuzzy read (\(mode))")
                check(readStage == .outcomeUnknown, "F02 read starts from exact retained unknown receipt (\(mode))")
                if positive {
                    check(saved?.status == .completed && saved?.verification == "Found by a read after the fact"
                        && saved?.events.suffix(2).map(\.stage) == [.outcomeUnknown, .completed], "F03 positive read requires saved ordered verification (\(mode))")
                    check(cached?.status == .completed && row?.status == .completed && cached?.result == "It went out."
                        && deliveries.contains("It went out."), "F04 definitive reply follows required receipt commit (\(mode))")
                } else if refused {
                    check(unknownBytes != nil && (try? Data(contentsOf: retained)) == unknownBytes
                        && receipts.receipt(for: fired!.actionID)?.status == .outcomeUnknown
                        && receipts.receipt(for: fired!.actionID)?.verification == nil, "F05 refused terminal save preserves committed unknown evidence")
                    check(cached?.status == .failed && row?.status == .failed && cached?.result == nil
                        && deliveries.contains("The action ran, but its result could not be saved. Check it before trying again.")
                        && !journal.contains { $0.draft.kind == .jobCompleted }, "F06 refused receipt supplies honest failure and no task success")
                } else {
                    check(saved?.status == .outcomeUnknown && saved?.verification == nil
                        && saved?.events.last?.stage == .outcomeUnknown, "F07 mismatch/unavailable retains unknown receipt (\(mode))")
                    check(cached?.result == "I’m not sure the event went out. Check it before trying again."
                        && deliveries.contains(cached?.result ?? ""), "F08 mismatch/unavailable never claims exact success or absence (\(mode))")
                }
                check(saved?.preparedAction == fired?.preparedAction && saved?.actionID == fired?.actionID
                    && saved?.taskAttempt == fired?.taskAttempt && saved?.taskLeaseOwner == fired?.taskLeaseOwner,
                    "C04 original immutable preparation/task ownership preserved (\(mode))")
                check(manager.backendStartsForTesting == 2 && exits == 2 && handles.count == 2
                    && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
                    "C05 actual owned Tasks and card drain exactly once (\(mode))")
                if mode == "normal-unavailable" { legacyReceipt = saved }
                SelfTest.diagnostic("CALENDAR_UNKNOWN_TRACE: mode=\(mode) calls=\(cli.calls) returns=\(cli.returns) inserts=\(observed.inserts) gets=\(observed.gets) lists=\(observed.lists) primaryLinked=\(primaryLinked) unknownAtRead=\(readStage == .outcomeUnknown) savedCompleted=\(saved?.status == .completed) savedUnknown=\(saved?.status == .outcomeUnknown) failed=\(row?.status == .failed)")
                _ = AgentArtifactLedger.take(taskID: task.id)
            } catch {
                capture(); if let id {
                    manager.cancel(id)
                    if let request = PermissionGate.shared.pending, request.taskID == id {
                        _ = PermissionGate.shared.respond(id: request.id, approved: false, duration: .once)
                    }
                }
                for task in handles { await task.value }
                if let id { _ = AgentArtifactLedger.take(taskID: id) }; throw error
            }
        }
        for mode in ["direct-current", "direct-wrong-id", "direct-wrong-description", "direct-unavailable"] {
            let directory = safe.appendingPathComponent("calendar-unknown-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let cli = try TaskCalendarDuplicateReceiptSelfTest.CLI(mode: mode, directory: directory,
                peer: peer, unknownReadback: true)
            let proposal = AgentProposal(id: UUID().uuidString, meetingID: UUID(), tool: "create_event",
                arguments: approved, rationale: "The supplied payload was already reviewed")
            let operation = Task { @MainActor in
                try await AgentToolExecutor.run(proposal, policy: .selfTest, cli: cli.runner,
                    approvedByUser: true, receiptStore: receipts)
            }
            do {
                let result = try await operation.value
                let observed = try wire(directory, allowsWrite: true)
                guard let saved = ActionReceiptStore(fileURL: receiptFile).receipts.first else { throw FixtureError.unsafe }
                let positive = mode == "direct-current"
                check(payload(observed.body) && saved.preparedAction?.executionPlan.arguments == approved,
                    "C06 actual direct supplied approved payload/receipt retained (\(mode))")
                check(observed.inserts == 1 && saved.preparedAction?.id == saved.actionID,
                    "C07 direct one insert/same prepared receipt (\(mode))")
                check(observed.body["id"] as? String == WorkspaceToolRunner.eventIdentifier(for: proposal.id),
                    "C08 direct resource retains proposal identity without fabricated prepared alias (\(mode))")
                check(observed.gets == 1 && observed.lists == 0, "F09 direct exact sent ID read replaces fuzzy title list (\(mode))")
                check(result.outcomeUnknown == !positive && result.verification == (positive ? "Found by a read after the fact" : nil),
                    "F10 direct current evidence classification (\(mode))")
                check(saved.status == (positive ? .completed : .outcomeUnknown)
                    && saved.verification == (positive ? "Found by a read after the fact" : nil),
                    "F11 direct positive reply has required saved verification (\(mode))")
                check(result.summary == (positive ? "It went out." : "I’m not sure the event went out. Check it before trying again."),
                    "F12 direct mismatch/unavailable truthful consumer copy (\(mode))")
                check(saved.events.contains { $0.stage == .fired } && saved.events.contains { $0.stage == .outcomeUnknown }
                    && saved.taskID == nil && saved.taskAttempt == nil,
                    "C09 direct unbound receipt remains unbound, fired history retained (\(mode))")
                SelfTest.diagnostic("CALENDAR_UNKNOWN_TRACE: mode=\(mode) inserts=\(observed.inserts) gets=\(observed.gets) lists=\(observed.lists) savedCompleted=\(saved.status == .completed) resultUnknown=\(result.outcomeUnknown)")
            } catch { operation.cancel(); _ = await operation.result; throw error }
        }
        guard let legacyReceipt, legacyReceipt.status == .outcomeUnknown,
              let prepared = legacyReceipt.preparedAction, let eventID = legacyReceipt.intent.arguments["title"].map({ _ in
                  WorkspaceToolRunner.eventIdentifier(for: legacyReceipt.actionID.uuidString) }) else { throw FixtureError.unsafe }
        for mode in ["legacy-missing-alias", "legacy-missing-preparation"] {
            let directory = safe.appendingPathComponent("calendar-unknown-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let cli = try TaskCalendarDuplicateReceiptSelfTest.CLI(mode: mode, directory: directory,
                peer: peer, unknownReadback: true)
            let proposal = AgentProposal(id: UUID().uuidString, meetingID: UUID(), tool: "create_event",
                arguments: approved, rationale: "Retained unknown receipt only; no repeat authority")
            let result = await WorkspaceToolRunner.unknownOutcomeResult(proposal,
                preparedAction: mode == "legacy-missing-alias" ? prepared : nil,
                calendarEventID: mode == "legacy-missing-preparation" ? eventID : nil, cli: cli.runner)
            let observed = try wire(directory, allowsWrite: false)
            check(observed.inserts == 0 && observed.gets == 0 && observed.lists == 0,
                "F13 missing identity/preparation stays unknown without guessing or effect (\(mode))")
            check(result.outcomeUnknown && result.verification == nil && result.reference == nil
                && result.summary == "I’m not sure the event went out. Check it before trying again.",
                "F14 legacy unknown never supplies absence/repeat certainty (\(mode))")
            SelfTest.diagnostic("CALENDAR_UNKNOWN_TRACE: mode=\(mode) inserts=\(observed.inserts) gets=\(observed.gets) lists=\(observed.lists) resultUnknown=\(result.outcomeUnknown)")
        }
        check(SelfTestStoreGuard.take() == ownerBefore && PermissionGrantStore.shared.grants == grantsBefore,
            "C10 owner stores/defaults and standing grants unchanged")
        SelfTest.diagnostic("CALENDAR_UNKNOWN_CHECKS: \(checks) problems=\(problems)")
    }
    /// Actual Process GET returns first; the same injected CLI holds that unchanged return
    /// while current primary ownership or the exact retained Task is changed.
    static func postReadOwnerCases(root: URL, check parent: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-task-worker-attempt",
              safe.path.hasPrefix(temp.path + "/"), !safe.pathComponents.contains("Application Support"),
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else { throw FixtureError.unsafe }
        let ownerBefore = SelfTestStoreGuard.take(), grantsBefore = PermissionGrantStore.shared.grants
        let oldCLI = AgentToolExecutor.workspaceCLIForTesting
        let oldFake = AgentToolExecutor.fakeForTesting, oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.workspaceCLIForTesting = oldCLI
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.fireOverrideForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = .selfTest
        var checks = 0, problems = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { problems += 1 }; parent(value, "calendar post-read " + label)
        }
        for mode in ["held-current", "held-primary", "held-cancel"] {
            let directory = safe.appendingPathComponent("calendar-postread-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafe }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let cli = try TaskCalendarDuplicateReceiptSelfTest.CLI(mode: mode, directory: directory,
                peer: peer, unknownReadback: true)
            AgentToolExecutor.workspaceCLIForTesting = cli
            defer { cli.afterReadReturn = nil; cli.beforeRead = nil; cli.beforeInsert = nil }
            var handles: [Task<Void, Never>] = [], id: String?, context: TaskJournalContext?
            var exits = 0, deliveries: [String] = [], fired: ActionReceipt?, joined = false
            var readHold: CheckedContinuation<Void, Never>?, heldReturns = 0
            var returnedPositive = false, beforeValid = false, afterValid = false
            var unknownBytes: Data?, primaryAtHold: AgentTask?, journalAtHold: [TaskJournalEvent]?
            var freshSQL: TaskStore?, freshManager: AgentTaskManager?
            defer { freshSQL?.close() }
            func capture() {
                if let id, let operation = manager.capturedReceiptMutationWorkerForTesting(id: id), !handles.contains(operation) {
                    handles.append(operation)
                }
            }
            manager.backendEntryForTesting = { context = TaskEventJournal.current; capture() }
            manager.backendExitForTesting = { exits += 1 }
            manager.announcementForTesting = { deliveries.append($0) }
            cli.beforeInsert = {
                guard let context, let row = try sql.load().first(where: { $0.id == context.taskID }),
                      let saved = ActionReceiptStore(fileURL: receiptFile).receipts.first(where: {
                        $0.taskID == context.taskID && $0.taskAttempt == context.attempt && $0.status == .fired
                      }) else { throw FixtureError.unsafe }
                fired = saved
                joined = row.status == .running && context.attempt > 0
                    && row.durability?.attempt == context.attempt && row.durability?.receiptIDs == [saved.actionID.uuidString]
                    && saved.taskLeaseOwner == row.durability?.leaseOwner
                    && saved.preparedAction?.id == saved.actionID && saved.preparedAction?.executionPlan.arguments == approved
            }
            cli.beforeRead = {
                guard fired.flatMap({ receipts.receipt(for: $0.actionID)?.status }) == .outcomeUnknown else { throw FixtureError.unsafe }
                unknownBytes = try Data(contentsOf: receiptFile)
            }
            cli.afterReadReturn = { [weak cli] output in
                heldReturns += 1
                let returned = try? JSONSerialization.jsonObject(with: output.standardOutput) as? [String: Any]
                if let cli, let returned {
                    returnedPositive = output.exitCode == 0 && NSDictionary(dictionary: returned).isEqual(to: cli.body)
                } else { returnedPositive = false }
                beforeValid = context?.isStillValid?() == true
                await withCheckedContinuation { continuation in readHold = continuation }
            }
            do {
                let task = manager.submit(objective: "Create the reviewed uncertain appointment", tool: "create_event",
                    arguments: initial, source: "selftest")
                id = task.id; capture(); guard !handles.isEmpty else { throw FixtureError.missingTask }
                guard await reached({ manager.task(id: task.id)?.status == .waitingForPermission
                    && PermissionGate.shared.pending?.taskID == task.id }) else { throw FixtureError.timeout }
                capture(); for operation in handles { await operation.value }
                guard let request = PermissionGate.shared.pending, request.taskID == task.id,
                      request.toolID == "create_event" else { throw FixtureError.unsafe }
                for field in ["title", "description"] {
                    ToolCallReviewStore.shared.update(id: request.id, field: field, to: approved[field]!)
                }
                for field in PermissionGate.shared.pendingReview?.fields ?? [] {
                    ToolCallReviewStore.shared.confirm(id: request.id, field: field.name)
                }
                guard PermissionGate.shared.pendingReview?.isReadyToRun == true else { throw FixtureError.unsafe }
                manager.respondPermission(taskID: task.id, approved: true); capture()
                // The absent original feature qualifies its actual one-INSERT/return; it
                // fails mandatory read-entry assertions, never substitutes a held result.
                guard await reached({ readHold != nil || exits == 2 }) else { throw FixtureError.timeout }
                capture(); guard handles.count == 2, let operation = handles.last else { throw FixtureError.missingTask }
                let entered = readHold != nil
                var ownerChangeAdmitted = mode != "held-primary", cancelRequested = false
                if entered {
                    if mode == "held-primary" {
                        let fresh = TaskStore(root: directory); freshSQL = fresh
                        let freshStore = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: fresh)
                        guard freshStore.allowsHarnessPersistence else { throw FixtureError.unsafe }
                        let held = AgentTaskManager(store: freshStore, receiptStore: receipts); freshManager = held
                        ownerChangeAdmitted = held.lastPersistenceResult?.primaryCommitted == true
                    } else if mode == "held-cancel" {
                        cancelRequested = true; operation.cancel() // Exact captured caller, after actual GET already returned.
                    }
                    afterValid = context?.isStillValid?() == true
                    primaryAtHold = try sql.load().first { $0.id == task.id }
                    journalAtHold = try sql.journal(taskID: task.id)
                } else {
                    unknownBytes = try Data(contentsOf: receiptFile)
                }
                readHold?.resume(); readHold = nil
                guard await reached({ exits == 2 }) else { throw FixtureError.timeout }
                capture(); for handle in handles { await handle.value }
                try cli.qualifyWire()
                let observed = try wire(directory, allowsWrite: true)
                let row = try sql.load().first { $0.id == task.id }, cached = manager.task(id: task.id)
                let journal = try sql.journal(taskID: task.id)
                let saved = fired.flatMap { ActionReceiptStore(fileURL: receiptFile).receipt(for: $0.actionID) }
                let current = mode == "held-current"
                check(joined && payload(observed.body) && fired?.preparedAction?.executionPlan.arguments == approved,
                    "C01 actual approved wire/prepared/positive primary link (\(mode))")
                check(entered && heldReturns == 1 && returnedPositive,
                    "F15 actual exact GET return was never held at resolver hop (\(mode))")
                let changedPrimaryQualified = mode != "held-primary" || (ownerChangeAdmitted
                    && primaryAtHold?.status == .recovering && primaryAtHold?.durability?.attempt == context?.attempt
                    && freshManager?.backendStartsForTesting == 0)
                check(!entered || (beforeValid && changedPrimaryQualified
                    && (current ? afterValid : !afterValid)
                    && (mode == "held-cancel" ? cancelRequested && operation.isCancelled : !operation.isCancelled)),
                    "C02 exact original/current context and actual owner/cancel change qualified (\(mode))")
                check(observed.inserts == 1 && observed.gets == 1 && observed.lists == 0
                    && cli.calls == cli.returns, "F16 no resend and exactly one returned real GET (\(mode))")
                check(current ? saved?.status == .completed && saved?.verification == "Found by a read after the fact"
                    : saved?.status == .outcomeUnknown && saved?.verification == nil
                        && saved?.events.last?.stage == .outcomeUnknown,
                    "F17 late invalid readback admitted definitive completed receipt (\(mode))")
                check(current ? cached?.result == "It went out." && deliveries.contains("It went out.")
                        && journal.contains { $0.draft.kind == .jobCompleted }
                    : cached?.result == nil && !deliveries.contains("It went out.")
                        && !journal.contains { $0.draft.kind == .jobCompleted },
                    "F18 late invalid readback delivered definitive task success (\(mode))")
                check(current || (unknownBytes != nil && (try? Data(contentsOf: receiptFile)) == unknownBytes
                    && saved?.result.isEmpty == true && saved?.completedAt == nil),
                    "C03 late invalid read retains exact committed unknown evidence (\(mode))")
                let primaryPreserved: Bool
                if !entered { primaryPreserved = true } // Mandatory F15/F16 grade absent feature separately.
                else if mode == "held-primary" { primaryPreserved = row == primaryAtHold && journal == journalAtHold }
                else if mode == "held-cancel" { primaryPreserved = row?.status == .cancelled
                    && row?.durability?.attempt == context?.attempt && !journal.contains { $0.draft.kind == .jobCompleted } }
                else { primaryPreserved = row?.status == .completed }
                check(primaryPreserved && saved?.preparedAction == fired?.preparedAction
                    && saved?.taskAttempt == fired?.taskAttempt && saved?.taskLeaseOwner == fired?.taskLeaseOwner,
                    "C04 owner primary and immutable prepared identity preserved after return (\(mode))")
                check(handles.count == 2 && manager.backendStartsForTesting == 2 && exits == 2
                    && readHold == nil, "C05 exact retained operations return and hold drains (\(mode))")
                check(PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
                    "C06 no stale approval/card or successor dispatch appears (\(mode))")
                SelfTest.diagnostic("CALENDAR_POSTREAD_TRACE: mode=\(mode) entered=\(entered) heldReturns=\(heldReturns) returnedPositive=\(returnedPositive) beforeValid=\(beforeValid) afterValid=\(afterValid) primaryChanged=\(ownerChangeAdmitted && mode == "held-primary") cancelled=\(operation.isCancelled) inserts=\(observed.inserts) gets=\(observed.gets) lists=\(observed.lists) savedCompleted=\(saved?.status == .completed) savedUnknown=\(saved?.status == .outcomeUnknown) primaryPreserved=\(primaryPreserved)")
                _ = AgentArtifactLedger.take(taskID: task.id)
            } catch {
                capture(); if let id {
                    manager.cancel(id)
                    if let request = PermissionGate.shared.pending, request.taskID == id {
                        _ = PermissionGate.shared.respond(id: request.id, approved: false, duration: .once)
                    }
                }
                readHold?.resume(); readHold = nil
                for handle in handles { await handle.value }
                if let id { _ = AgentArtifactLedger.take(taskID: id) }; throw error
            }
        }
        check(SelfTestStoreGuard.take() == ownerBefore && PermissionGrantStore.shared.grants == grantsBefore,
            "C07 owner stores/defaults and standing grants unchanged")
        SelfTest.diagnostic("CALENDAR_POSTREAD_CHECKS: \(checks) problems=\(problems)")
    }

    private static let peer = #"""
    #!/usr/bin/python3
    import json, os, pathlib, re, sys
    root = pathlib.Path(__file__).resolve().parent
    mode = (root / 'peer-mode').read_text()
    args = sys.argv[1:]
    def bad():
        print('The owned unknown-calendar peer rejected the command.', file=sys.stderr)
        sys.exit(3)
    def log(operation, params, event_id, code):
        with (root / 'peer-wire.jsonl').open('a') as f:
            f.write(json.dumps({'operation': operation, 'calendarId': params.get('calendarId'),
                'eventId': event_id, 'pid': os.getpid(), 'exit': code}) + '\n')
    if len(args) == 7 and args[:4] == ['calendar', 'events', 'insert', '--params'] and args[5] == '--json':
        params = json.loads(args[4]); body = json.loads(args[6]); event_id = body.get('id', '')
        if params != {'calendarId': 'primary'} or re.fullmatch('[0-9a-f]{32}', event_id) is None: bad()
        if (root / 'peer-event.json').exists(): bad()
        (root / 'peer-event.json').write_text(json.dumps(body))
        log('insert', params, event_id, 1)
        print('The owned write returned without its answer.', file=sys.stderr); sys.exit(1)
    if len(args) == 5 and args[:4] == ['calendar', 'events', 'get', '--params']:
        params = json.loads(args[4]); body = json.loads((root / 'peer-event.json').read_text())
        if params != {'calendarId': 'primary', 'eventId': body['id']}: bad()
        if len((root / 'peer-wire.jsonl').read_text().splitlines()) != 1: bad()
        code = 1 if mode.endswith('unavailable') else 0
        log('get', params, body['id'], code)
        if code:
            print('The owned read is unavailable.', file=sys.stderr); sys.exit(1)
        if mode.endswith('wrong-id'): body['id'] = '0' * 32 if body['id'] != '0' * 32 else '1' * 32
        if mode.endswith('wrong-description'): body['description'] = 'An older description'
        print(json.dumps(body)); sys.exit(0)
    if len(args) == 5 and args[:4] == ['calendar', 'events', 'list', '--params']:
        params = json.loads(args[4])
        if params.get('calendarId') != 'primary' or params.get('singleEvents') != True or params.get('orderBy') != 'startTime': bad()
        source = root / 'peer-event.json'
        body = json.loads(source.read_text()) if source.exists() else None
        if body and mode.endswith('wrong-id'): body['id'] = '0' * 32 if body['id'] != '0' * 32 else '1' * 32
        if body and mode.endswith('wrong-description'): body['description'] = 'An older description'
        code = 1 if mode.endswith('unavailable') else 0
        log('list', params, body['id'] if body else '', code)
        if code:
            print('The owned read is unavailable.', file=sys.stderr); sys.exit(1)
        print(json.dumps({'items': [body] if body else []})); sys.exit(0)
    bad()
    """#
}
