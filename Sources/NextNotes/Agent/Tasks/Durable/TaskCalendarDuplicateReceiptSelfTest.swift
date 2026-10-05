import Foundation

/// Normal admitted Manager/Gate/Executor path; only the external Workspace CLI is controlled.
/// No calendar account, recovery, resend or pre-authored receipt is used.
@MainActor
enum TaskCalendarDuplicateReceiptSelfTest {
    private enum FixtureError: Error { case unsafe, missingTask, wrongCLI, timeout }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
    /// Observes the admitted command boundary and forwards every invocation to the real
    /// GoogleWorkspaceCLI actor. Only the external executable's calendar replies are authored.
    @MainActor final class CLI: WorkspaceCLIRunning {
        let runner: GoogleWorkspaceCLI
        let directory: URL
        var inserts = 0
        var reads = 0
        var lists = 0
        let unknownReadback: Bool
        var creates = 0
        var body: [String: Any] = [:]
        var calls = 0
        var returns = 0
        var wireQualified = false
        var beforeInsert: (() throws -> Void)?
        var beforeRead: (() throws -> Void)?
        var afterReadReturn: (@MainActor (WorkspaceCLIOutput) async -> Void)?

        init(mode: String, directory: URL, peer: String? = nil, unknownReadback: Bool = false) throws {
            self.unknownReadback = unknownReadback
            self.directory = directory
            let executable = directory.appendingPathComponent("owned-calendar-cli")
            try (peer ?? Self.peer).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try mode.write(to: directory.appendingPathComponent("peer-mode"), atomically: true, encoding: .utf8)
            guard let runner = GoogleWorkspaceCLI.isolatedForTesting(root: directory, executable: executable)
            else { throw FixtureError.unsafe }
            self.runner = runner
        }

        func run(_ arguments: [String], timeout: TimeInterval) async throws -> WorkspaceCLIOutput {
            if arguments.prefix(3) == ["calendar", "events", "insert"] {
                guard calls == 0, arguments.count == 7, arguments[3] == "--params",
                      arguments[5] == "--json", let data = arguments[6].data(using: .utf8),
                      let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = parsed["id"] as? String, id.count == 32 else { throw FixtureError.wrongCLI }
                body = parsed
                try beforeInsert?()
            } else if unknownReadback && arguments.prefix(3) == ["calendar", "events", "list"] {
                guard arguments.count == 5, arguments[3] == "--params", calls <= 1,
                      let data = arguments[4].data(using: .utf8),
                      let params = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      params["calendarId"] as? String == "primary", params["singleEvents"] as? Bool == true,
                      params["orderBy"] as? String == "startTime" else { throw FixtureError.wrongCLI }
            } else {
                guard arguments.prefix(3) == ["calendar", "events", "get"], calls == 1,
                      arguments.count == 5, arguments[3] == "--params",
                      let data = arguments[4].data(using: .utf8),
                      let params = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      params["calendarId"] as? String == "primary",
                      params["eventId"] as? String == body["id"] as? String
                else { throw FixtureError.wrongCLI }
                try beforeRead?()
            }
            calls += 1
            defer { returns += 1 }
            let output = try await runner.run(arguments, timeout: timeout)
            if unknownReadback, arguments.prefix(3) == ["calendar", "events", "get"], let afterReadReturn {
                // Hold only the actual returned output in this optional fixture callback.
                // Default nil keeps every older mode's existing return path and waits.
                await afterReadReturn(output)
            }
            return output
        }

        /// Read only the owned peer's actual wire log, after the SAME operation has joined.
        /// Missing or malformed evidence refuses qualification instead of substituting a result.
        func qualifyWire() throws {
            if unknownReadback { try qualifyUnknownWire(); return }
            let log = directory.appendingPathComponent("peer-wire.jsonl")
            let records: [[String: Any]]
            if calls == 0 {
                guard !FileManager.default.fileExists(atPath: log.path) else { throw FixtureError.wrongCLI }
                records = []
            } else {
                let text = try String(contentsOf: log, encoding: .utf8)
                records = try text.split(separator: "\n").map {
                    guard let record = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                    else { throw FixtureError.wrongCLI }
                    return record
                }
            }
            let pids = records.compactMap { ($0["pid"] as? NSNumber)?.intValue }
            guard records.count == calls, returns == calls, pids.count == calls,
                  pids.allSatisfy({ $0 > 0 }), Set(pids).count == calls,
                  records.enumerated().allSatisfy({ index, record in
                      record["operation"] as? String == (index == 0 ? "insert" : "get")
                          && record["calendarId"] as? String == "primary"
                          && record["eventId"] as? String == body["id"] as? String
                          && [0, 1].contains((record["exit"] as? NSNumber)?.intValue ?? -1)
                  }) else { throw FixtureError.wrongCLI }
            if calls > 0 {
                let sent = try JSONSerialization.jsonObject(with: Data(contentsOf:
                    directory.appendingPathComponent("peer-event.json"))) as? [String: Any]
                guard let sent, NSDictionary(dictionary: sent).isEqual(to: body)
                else { throw FixtureError.wrongCLI }
            }
            inserts = records.filter { $0["operation"] as? String == "insert" }.count
            reads = records.filter { $0["operation"] as? String == "get" }.count
            creates = records.filter { $0["operation"] as? String == "insert"
                && ($0["exit"] as? NSNumber)?.intValue == 0 }.count
            wireQualified = true
        }

        private func qualifyUnknownWire() throws {
            let log = directory.appendingPathComponent("peer-wire.jsonl")
            let records: [[String: Any]]
            if calls == 0 {
                guard !FileManager.default.fileExists(atPath: log.path) else { throw FixtureError.wrongCLI }
                records = []
            } else {
                records = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
                    guard let record = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                    else { throw FixtureError.wrongCLI }
                    return record
                }
            }
            let pids = records.compactMap { ($0["pid"] as? NSNumber)?.intValue }
            guard records.count == calls, returns == calls, pids.count == calls,
                  pids.allSatisfy({ $0 > 0 }), Set(pids).count == calls,
                  records.allSatisfy({ $0["calendarId"] as? String == "primary"
                      && [0, 1].contains(($0["exit"] as? NSNumber)?.intValue ?? -1) })
            else { throw FixtureError.wrongCLI }
            if !body.isEmpty {
                guard records.first?["operation"] as? String == "insert", calls >= 1, calls <= 2,
                      records.first?["exit"] as? Int == 1,
                      records.first?["eventId"] as? String == body["id"] as? String,
                      let sent = try JSONSerialization.jsonObject(with: Data(contentsOf:
                          directory.appendingPathComponent("peer-event.json"))) as? [String: Any],
                      NSDictionary(dictionary: sent).isEqual(to: body) else { throw FixtureError.wrongCLI }
                if calls == 2 {
                    guard ["get", "list"].contains(records[1]["operation"] as? String ?? "") else { throw FixtureError.wrongCLI }
                    if records[1]["operation"] as? String == "get" {
                        guard records[1]["eventId"] as? String == body["id"] as? String else { throw FixtureError.wrongCLI }
                    }
                }
            } else {
                guard calls <= 1, records.allSatisfy({ $0["operation"] as? String == "list" })
                else { throw FixtureError.wrongCLI }
            }
            inserts = records.filter { $0["operation"] as? String == "insert" }.count
            reads = records.filter { $0["operation"] as? String == "get" }.count
            lists = records.filter { $0["operation"] as? String == "list" }.count
            creates = 0 // Exit1 provides no effect certainty, even though the peer retained the exact request.
            wireQualified = true
        }

        private static let peer = #"""
        #!/usr/bin/python3
        import json, os, pathlib, re, sys
        root = pathlib.Path(__file__).resolve().parent
        mode = (root / 'peer-mode').read_text()
        args = sys.argv[1:]
        def bad():
            print('The owned peer rejected unexpected arguments.', file=sys.stderr)
            sys.exit(3)
        def record(operation, params, event_id, code):
            with (root / 'peer-wire.jsonl').open('a') as log:
                log.write(json.dumps({'operation': operation, 'calendarId': params.get('calendarId'),
                    'eventId': event_id, 'pid': os.getpid(), 'exit': code}) + '\n')
        if len(args) == 7 and args[:4] == ['calendar', 'events', 'insert', '--params'] and args[5] == '--json':
            params = json.loads(args[4]); body = json.loads(args[6]); event_id = body.get('id', '')
            if params != {'calendarId': 'primary'} or re.fullmatch('[0-9a-f]{32}', event_id) is None:
                bad()
            if (root / 'peer-event.json').exists(): bad()
            (root / 'peer-event.json').write_text(json.dumps(body))
            code = 0 if mode == 'inserted-current' else 1
            record('insert', params, event_id, code)
            if code:
                print('Using keyring backend: fixture', file=sys.stderr)
                print('The requested identifier already exists.', file=sys.stderr)
                sys.exit(1)
            print(json.dumps({'id': event_id})); sys.exit(0)
        if len(args) == 5 and args[:4] == ['calendar', 'events', 'get', '--params']:
            params = json.loads(args[4]); body = json.loads((root / 'peer-event.json').read_text())
            if params != {'calendarId': 'primary', 'eventId': body['id']}: bad()
            existing = (root / 'peer-wire.jsonl').read_text().splitlines()
            if len(existing) != 1: bad()
            code = 1 if mode == 'duplicate-read-unavailable' else 0
            record('get', params, body['id'], code)
            if code:
                print('The owned calendar read is unavailable.', file=sys.stderr); sys.exit(1)
            if mode == 'duplicate-wrong-id': body['id'] = ('0' if body['id'] != '0' * 32 else '1') * 32
            if mode == 'duplicate-wrong-title': body['summary'] = 'An unrelated existing event'
            if mode == 'duplicate-wrong-time': body['start'] = {'dateTime': '2026-10-06T10:00:00-04:00'}
            if mode == 'duplicate-wrong-description': body['description'] = 'An older purpose'
            if mode == 'duplicate-wrong-attendees': body['attendees'] = [{'email': 'different@owned.invalid'}]
            print(json.dumps(body)); sys.exit(0)
        bad()
        """#
    }

    static func originalCases(root: URL, check parent: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-task-worker-attempt",
              safe.path.hasPrefix(temporary.path + "/"), !safe.pathComponents.contains("Application Support"),
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else { throw FixtureError.unsafe }
        let ownerBefore = SelfTestStoreGuard.take()
        let grantsBefore = PermissionGrantStore.shared.grants
        let oldCLI = AgentToolExecutor.workspaceCLIForTesting
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.workspaceCLIForTesting = oldCLI
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        AgentToolExecutor.fakeForTesting = nil
        AgentToolExecutor.fireOverrideForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = .selfTest
        // Existing authored Workspace helpers use explicit protocol fakes, never owner auth.
        // Keep their ten case groups separate from the 114 actual CLI caller checks below.
        let helperFailures = await WorkspaceToolRunner.selfTestFailures()
        parent(helperFailures.isEmpty, "calendar workspace helpers: existing ten case groups")
        SelfTest.diagnostic("CALENDAR_WORKSPACE_HELPERS: cases=10 problems=\(helperFailures.count) aggregateChecks=1")
        var checks = 0, problems = 0
        var resourceChecks = 0, resourceProblems = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { problems += 1 }; parent(value, label)
        }
        for mode in ["duplicate-current", "duplicate-wrong-id", "duplicate-wrong-title", "duplicate-wrong-time",
                     "duplicate-read-unavailable", "duplicate-wrong-description", "duplicate-wrong-attendees",
                     "inserted-current", "primary-refused", "receipt-refused"] {
            let directory = safe.appendingPathComponent("calendar-duplicate-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafe }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let cli = try CLI(mode: mode, directory: directory)
            AgentToolExecutor.workspaceCLIForTesting = cli
            let initial = ["title": "Draft owned appointment", "start": "2026-10-05T09:00:00-04:00",
                           "end": "2026-10-05T09:30:00-04:00", "description": "Reviewed meeting purpose",
                           "attendees": "person@owned.invalid"]
            var approved = initial; approved["title"] = "Reviewed owned appointment"
            var operations: [Task<Void, Never>] = []
            var id: String?
            var context: TaskJournalContext?
            var exits = 0
            var delivered: [String] = []
            var fired: ActionReceipt?
            var joined = false
            var stageAtRead: ActionReceiptStatus?
            var retainedBytes: Data?
            var waitPhase = 0
            let retainedFile = directory.appendingPathComponent("retained-fired.json")
            func capture() {
                guard let id, let operation = manager.capturedReceiptMutationWorkerForTesting(id: id) else { return }
                if !operations.contains(operation) { operations.append(operation) }
            }
            manager.announcementForTesting = { delivered.append($0) }
            manager.backendExitForTesting = { exits += 1 }
            manager.backendEntryForTesting = {
                context = TaskEventJournal.current
                capture()
                if mode == "primary-refused", let context, context.attempt > 1 {
                    try sql.withConnection { try TaskStore.exec($0,
                        "CREATE TRIGGER refuse_calendar_start BEFORE INSERT ON task_event WHEN NEW.kind='toolStarted' BEGIN SELECT RAISE(ABORT,'fixture primary refusal'); END") }
                }
            }
            cli.beforeInsert = {
                guard let context, let row = try sql.load().first(where: { $0.id == context.taskID }),
                      let current = ActionReceiptStore(fileURL: receiptFile).receipts.first(where: {
                          $0.taskID == context.taskID && $0.taskAttempt == context.attempt && $0.status == .fired
                      }) else { throw FixtureError.unsafe }
                fired = current
                joined = row.status == .running && row.durability?.attempt == context.attempt
                    && row.durability?.receiptIDs == [current.actionID.uuidString]
                    && current.taskLeaseOwner == row.durability?.leaseOwner
                    && current.preparedAction?.id == current.actionID
                    && current.preparedAction?.executionPlan.toolID == "create_event"
                    && current.preparedAction?.executionPlan.arguments == approved
                    && cli.body["summary"] as? String == approved["title"]
                    && cli.body["id"] as? String != nil
            }
            cli.beforeRead = {
                stageAtRead = fired.flatMap { ActionReceiptStore(fileURL: receiptFile).receipt(for: $0.actionID)?.status }
                if mode == "receipt-refused" {
                    retainedBytes = try Data(contentsOf: receiptFile)
                    try FileManager.default.moveItem(at: receiptFile, to: retainedFile)
                    try FileManager.default.createDirectory(at: receiptFile, withIntermediateDirectories: false)
                }
            }
            do {
                let task = manager.submit(objective: "Create the reviewed owned appointment",
                    tool: "create_event", arguments: initial, source: "selftest")
                id = task.id; capture()
                guard !operations.isEmpty else { throw FixtureError.missingTask }
                waitPhase = 1 // Existing permission wait; no changed deadline or predicate.
                guard await reached({ manager.task(id: task.id)?.status == .waitingForPermission
                    && PermissionGate.shared.pending?.taskID == task.id }) else { throw FixtureError.timeout }
                waitPhase = 2 // Existing first-operation join and review.
                capture(); for operation in operations { await operation.value }
                guard let request = PermissionGate.shared.pending, request.taskID == task.id,
                      request.toolID == "create_event", cli.inserts == 0 else { throw FixtureError.unsafe }
                ToolCallReviewStore.shared.update(id: request.id, field: "title", to: approved["title"]!)
                for field in PermissionGate.shared.pendingReview?.fields ?? [] {
                    ToolCallReviewStore.shared.confirm(id: request.id, field: field.name)
                }
                guard PermissionGate.shared.pendingReview?.isReadyToRun == true else { throw FixtureError.unsafe }
                waitPhase = 3 // Existing approval dispatch.
                manager.respondPermission(taskID: task.id, approved: true)
                capture()
                waitPhase = 4 // Existing backend-exit wait; no changed deadline or predicate.
                guard await reached({ exits == 2 }) else { throw FixtureError.timeout }
                waitPhase = 5 // Existing final-operation join and wire qualification.
                capture(); for operation in operations { await operation.value }
                try cli.qualifyWire()
                waitPhase = 6 // Existing qualified receipt/consumer checks.
                let cached = manager.task(id: task.id)
                let row = try sql.load().first { $0.id == task.id }
                let journal = try sql.journal(taskID: task.id)
                let saved = fired.flatMap { ActionReceiptStore(fileURL: receiptFile).receipt(for: $0.actionID) }
                let denied = mode == "primary-refused"
                let uncertain = ["duplicate-wrong-id", "duplicate-wrong-title", "duplicate-wrong-time", "duplicate-read-unavailable",
                    "duplicate-wrong-description", "duplicate-wrong-attendees"].contains(mode)
                let refused = mode == "receipt-refused"
                check(cli.wireQualified && cli.calls == cli.returns,
                    "calendar receipt C08: actual owned CLI wire/process returns not qualified (\(mode))")
                check(cli.inserts == (denied ? 0 : 1) && cli.creates == (mode == "inserted-current" ? 1 : 0),
                    "calendar receipt C01: original insert/effect count changed (\(mode))")
                check(denied ? fired == nil && row?.durability?.receiptIDs.isEmpty == true : joined,
                    "calendar receipt C02: exact reviewed payload/primary fired join absent (\(mode))")
                check(cli.reads == (denied ? 0 : 1),
                    "calendar receipt F01: duplicate identity bypassed the actual existing readback (\(mode))")
                check(denied || stageAtRead == .fired,
                    "calendar receipt F02: readback was not linked to the exact fired receipt (\(mode))")
                check(denied ? row?.status == .failed : row?.durability?.receiptIDs == fired.map { [$0.actionID.uuidString] },
                    "calendar receipt C03: original primary link changed (\(mode))")
                if denied || refused {
                    check(cached?.status == .failed && row?.status == .failed && cached?.result == nil
                        && !journal.contains { $0.draft.kind == .jobCompleted },
                        "calendar receipt F03: refused primary/receipt admission delivered success (\(mode))")
                    if refused {
                        check(retainedBytes != nil && (try? Data(contentsOf: retainedFile)) == retainedBytes
                            && receipts.receipt(for: fired!.actionID)?.status == .fired
                            && delivered.contains("The action ran, but its result could not be saved. Check it before trying again."),
                            "calendar receipt F04: refused terminal write lost fired evidence/honest failure")
                    }
                } else {
                    check(cached?.status == .completed && row?.status == .completed,
                        "calendar receipt C04: actual task consumer did not finish (\(mode))")
                    check(saved?.status == (uncertain ? .couldNotVerify : .completed),
                        "calendar receipt F05: unverified duplicate was recorded as verified completed (\(mode))")
                    check(uncertain ? saved?.verification == "Unverified; inspect the target before retrying"
                        : saved?.verification == "Read back the reviewed event details",
                        "calendar receipt F06: receipt asserted an unread duplicate's success (\(mode))")
                    check(uncertain ? cached?.result == "I couldn't confirm the reviewed event. Check your calendar before trying again.\nNext Notes could not independently verify the effect. Inspect the target before retrying."
                        : cached?.result == (mode == "inserted-current" ? "Created the event “Reviewed owned appointment”."
                            : "It was already on your calendar."),
                        "calendar receipt F07: actual delivery overstated original read evidence (\(mode))")
                    check(delivered.contains(cached?.result ?? "")
                        && saved?.preparedAction?.id == fired?.actionID
                        && saved?.preparedAction?.executionPlan.arguments == approved
                        && saved?.artifacts == (cli.body["id"] as? String).map { [$0] },
                        "calendar receipt C05: delivered result differs from canonical result (\(mode))")
                }
                check(manager.backendStartsForTesting == 2 && exits == 2
                    && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
                    "calendar receipt C06: repeated or retained work/card appeared (\(mode))")
                // The actual wire resource must be derivable from this exact saved
                // preparation, including when the final receipt save was refused.
                let resourceLinked = denied ? fired == nil && cli.body.isEmpty : fired.map { receipt in
                    receipt.preparedAction?.id == receipt.actionID
                        && (cli.body["id"] as? String) == WorkspaceToolRunner.eventIdentifier(for: receipt.actionID.uuidString)
                } ?? false
                resourceChecks += 1
                if !resourceLinked { resourceProblems += 1 }
                parent(resourceLinked, "calendar prepared resource R01: actual sent resource differs from saved prepared receipt identity (\(mode))")
                SelfTest.diagnostic("CALENDAR_DUPLICATE_RECEIPT_TRACE: mode=\(mode) wireQualified=\(cli.wireQualified) calls=\(cli.calls) returns=\(cli.returns) inserts=\(cli.inserts) creates=\(cli.creates) reads=\(cli.reads) joined=\(joined) readStageFired=\(stageAtRead == .fired) resourceAliasesPrepared=\((cli.body["id"] as? String).map { $0 == fired?.actionID.uuidString.replacingOccurrences(of: "-", with: "").lowercased() } ?? false) completed=\(saved?.status == .completed) unverified=\(saved?.status == .couldNotVerify)")
                _ = AgentArtifactLedger.take(taskID: task.id)
            } catch {
                capture() // Collect the SAME existing operation before cancelling/releasing it.
                let observed = id.flatMap { manager.task(id: $0) }
                let pendingExact = id.map { PermissionGate.shared.pending?.taskID == $0 } ?? false
                let cancelledHandles = operations.filter { $0.isCancelled }.count
                SelfTest.diagnostic("CALENDAR_WAIT_PHASE: mode=\(mode) phase=\(waitPhase) permissionWait=\(waitPhase == 1) backendExitWait=\(waitPhase == 4) cachedPresent=\(observed != nil) cachedWaitingPermission=\(observed?.status == .waitingForPermission) cachedRunning=\(observed?.status == .running) cachedFailed=\(observed?.status == .failed) cachedCompleted=\(observed?.status == .completed) cachedCancelled=\(observed?.status == .cancelled) exits=\(exits) calls=\(cli.calls) returns=\(cli.returns) pendingExact=\(pendingExact) queued=\(PermissionGate.shared.queuedCount) handles=\(operations.count) cancelledHandles=\(cancelledHandles) contextCaptured=\(context != nil) attempt=\(context?.attempt ?? 0) firedCaptured=\(fired != nil) readEntered=\(stageAtRead != nil)")
                if let id {
                    manager.cancel(id)
                    if let request = PermissionGate.shared.pending, request.taskID == id {
                        _ = PermissionGate.shared.respond(id: request.id, approved: false, duration: .once)
                    }
                }
                for operation in operations { await operation.value }
                if let id { _ = AgentArtifactLedger.take(taskID: id) }
                throw error
            }
        }
        check(SelfTestStoreGuard.take() == ownerBefore && PermissionGrantStore.shared.grants == grantsBefore,
            "calendar receipt C07: owner stores/defaults or standing grants changed")
        SelfTest.diagnostic("CALENDAR_DUPLICATE_RECEIPT_CHECKS: \(checks) problems=\(problems)")
        SelfTest.diagnostic("CALENDAR_PREPARED_RESOURCE_CHECKS: \(resourceChecks) problems=\(resourceProblems)")
    }
}
