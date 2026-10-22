import Foundation
import AppKit
import SwiftUI

/// Actual isolated Manager/backends/read/input producers -> SAME marked SQL journal ->
/// production JobReport.read/run. No owner seed, model, Gate approval or renderer substitute.
@MainActor
enum JobReportSelfTest {
    private enum InputError: Error { case invalid, timeout }
    static func problems() async -> [String] {
        guard SelfTest.isRunning else { return ["J-C00 harness required"] }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesJobsReport-\(UUID().uuidString)", isDirectory: true)
        var producersExited = false
        defer {
            // A failed input qualification must not delete files beneath a still-owned
            // backend. Retain this synthetic root for the runner's failure diagnostics.
            if producersExited { try? FileManager.default.removeItem(at: root) }
        }
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures.append(label) }
        }
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let active = root.appendingPathComponent("actual", isDirectory: true)
            try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
            let input = active.appendingPathComponent("jobs-private-file.txt")
            let secret = "jobs-private-file-body"
            try secret.write(to: input, atomically: true, encoding: .utf8)
            let sql = TaskStore(root: active)
            defer { sql.close() }
            let receipts = ActionReceiptStore(fileURL: active.appendingPathComponent("action-receipts.json"))
            let store = AgentTaskStore(fileURL: active.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw InputError.invalid }
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var exits = 0
            manager.backendExitForTesting = { exits += 1 }
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.fireOverrideForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            let completed = manager.submit(objective: "Read the fixture", tool: "filesystem.read",
                arguments: ["path": input.path], source: "selftest")
            guard await reached({ exits == 1 }) else { manager.cancel(completed.id); throw InputError.timeout }
            let failed = manager.submit(objective: "secret chain of thought", tool: "filesystem.read",
                arguments: ["path": active.appendingPathComponent("jobs-private-missing.txt").path], source: "selftest")
            guard await reached({ exits == 2 }) else { manager.cancel(failed.id); throw InputError.timeout }
            let waiting = manager.submit(objective: "Read another fixture", tool: "filesystem.read", source: "selftest")
            guard await reached({ exits == 3 }) else { manager.cancel(waiting.id); throw InputError.timeout }
            producersExited = true
            check(manager.task(id: completed.id)?.status == .completed
                && manager.task(id: completed.id)?.result?.contains(secret) == true
                && manager.task(id: failed.id)?.status == .failed
                && manager.task(id: waiting.id)?.status == .waitingForInput
                && manager.backendStartsForTesting == 3 && receipts.receipts.count == 2,
                "J-C01 actual read/error/missing-input flows did not qualify")
            guard let before = try sql.probeAuthority(includeTasks: true, includeJournal: true), before.authority != nil else {
                throw InputError.invalid
            }
            // The real store canonicalizes the full snapshot with its ISO8601 codec;
            // compare that persisted time domain, preserving all fields and order.
            check(try before.tasks == canonicalTasks(manager.tasks) && before.events.count == 3
                && before.events[completed.id]?.contains { $0.draft.kind == .toolCompleted } == true
                && before.events[waiting.id]?.contains { $0.draft.kind == .inputRequested } == true,
                "J-C02 SAME actual marked primary/journal snapshot missing")
            let bytes = try retainedBytes(active)
            let now = Date()
            let lines = await JobReport.run(arguments: [JobReport.flag], root: active, now: now)
            // Safe synthetic diagnostic rows retain the ACTUAL consumer output for
            // paired native review; no owner task, body or arguments are supplied.
            for line in lines { SelfTest.diagnostic("JOBS_REPORT_CAPTURE " + line) }
            let rows = try objects(lines, prefix: "JOBS_REPORT_ROW ")
            let events = try objects(lines, prefix: "JOBS_REPORT_EVENT ")
            check(rows.count == 3 && lines.last == "JOBS_REPORT_OK tasks=3 events=\(before.events.values.reduce(0) { $0 + $1.count }) health=unknown effects=unknown",
                "J-F01 actual jobs report lacks admitted task/journal projection")
            check(rows.first?["taskID"] as? String == waiting.id
                && rows.first?["state"] as? String == "Waiting for your answer",
                "J-F02 actual report fails needs-you-first saved input state")
            let completedRow = rows.first { $0["taskID"] as? String == completed.id }
            check(completedRow?["attempt"] as? Int == 1
                && completedRow?["heartbeatScope"] as? String == "LAST"
                && completedRow?["health"] as? String == "unknown"
                && completedRow?["effects"] as? String == "unknown"
                && completedRow?["result"] as? String == "Saved reply",
                "J-F03 actual report loses exact attempt/LAST metadata or invents health/effect certainty")
            let completedEvents = events.filter { $0["taskID"] as? String == completed.id }
            check(completedEvents.compactMap { $0["seq"] as? Int64 }
                == (before.events[completed.id] ?? []).map(\.seq)
                && events.count == before.events.values.reduce(0) { $0 + $1.count },
                "J-F04 actual report invents/drops/reorders real timeline facts")
            let failedRow = rows.first { $0["taskID"] as? String == failed.id }
            let text = lines.joined(separator: "\n")
            check(completedRow?["integrations"] as? [String] == ["Files"]
                && failedRow?["title"] as? String == "Background task"
                && ![secret, "jobs-private", "filesystem.read", "secret chain", input.path].contains { text.contains($0) },
                "J-F05 actual report bypasses public projector or exposes body/arguments/raw tool detail")
            let one = await JobReport.run(arguments: [JobReport.flag, JobReport.taskFlag, completed.id], root: active, now: now)
            check(try objects(one, prefix: "JOBS_REPORT_ROW ").map { $0["taskID"] as? String } == [completed.id]
                && objects(one, prefix: "JOBS_REPORT_EVENT ").allSatisfy { $0["taskID"] as? String == completed.id },
                "J-F06 actual task filter crosses another job")
            let other = await JobReport.run(arguments: [JobReport.flag, JobReport.taskFlag, UUID().uuidString], root: active, now: now)
            check(other == ["JOBS_REPORT_EMPTY"], "J-C03 absent task filter fabricated a row")
            check(try retainedBytes(active) == bytes, "J-C04 readonly report changed DB/WAL/export/input/receipt bytes")
            let after = try sql.probeAuthority(includeTasks: true, includeJournal: true)
            check(after?.authority == before.authority && after?.tasks == before.tasks && after?.events == before.events
                && manager.task(id: waiting.id)?.status == .waitingForInput
                && manager.backendStartsForTesting == 3 && exits == 3,
                "J-C05 report mutated authority/tasks/journal or dispatched waiting work")
            check(AgentActivityProjector.jobTitle(manager.task(id: failed.id)!) == "Background task"
                && AgentActivityProjector.jobResult(manager.task(id: failed.id)!) == "No saved reply"
                && before.events.values.flatMap { $0 }.allSatisfy { AgentActivityProjector.isPublic(AgentActivityProjector.jobEventTitle($0)) },
                "J-C06 common projector metadata/private-text controls")
            try await savedTimelineCases(snapshot: before, root: active, manager: manager, exits: exits, check: check)
            try await refusalCases(root: root, check: check)
            // Damage one REAL retained event after all successful consumers ran. The
            // report must refuse the same source, never fall back to task-only success.
            try sql.withConnection {
                try TaskStore.exec($0, "UPDATE task_event SET kind='unrecognized-job-event' WHERE seq=(SELECT MIN(seq) FROM task_event)")
            }
            let damagedBytes = try retainedBytes(active)
            let damaged = await JobReport.run(arguments: [JobReport.flag], root: active, now: now)
            check(try damaged.last?.hasPrefix("JOBS_REPORT_FAILED") == true
                && retainedBytes(active) == damagedBytes
                && sql.withConnection { try TaskStore.integer($0, "SELECT COUNT(*) FROM task_event WHERE kind='unrecognized-job-event'") } == 1,
                "J-C17 malformed actual journal silently skipped, erased or reported as admitted")
            var refusedTimeline = false
            do { _ = try await JobReport.snapshot(root: active) }
            catch { refusedTimeline = true }
            check(try refusedTimeline && retainedBytes(active) == damagedBytes,
                "T-C06 saved Timeline refuses malformed real journal without changing source")
            let noReplay = manager.backendStartsForTesting == 3 && exits == 3
            let unknownMetadata = rows.count == before.tasks.count
                && rows.allSatisfy { $0["health"] as? String == "unknown" && $0["effects"] as? String == "unknown" }
            SelfTest.diagnostic("JOBS_REPORT_TRACE: checks=\(checks) actualTasks=\(before.tasks.count) actualEvents=\(before.events.values.reduce(0) { $0 + $1.count }) reportRows=\(rows.count) noReplay=\(noReplay) healthEffectsUnknown=\(unknownMetadata)")
        } catch { failures.append("J-C99 input/cleanup failed: \(error)") }
        return failures
    }

    /// Mount only the actual immutable Activity child, never the owner-backed pane.
    /// Synchronous hosted body checkpoints qualify real consumer evaluation; they do
    /// not establish pixels, focus, accessibility interaction or live health.
    private static func savedTimelineCases(snapshot: TaskStoreAuthorityProbe, root: URL,
        manager: AgentTaskManager, exits: Int, check: (Bool, String) -> Void) async throws {
        let bytes = try retainedBytes(root)
        let loaded = try await JobReport.snapshot(root: root)
        check(snapshot.tasks.count == 3 && snapshot.events.values.reduce(0, { $0 + $1.count }) == 14
            && loaded?.authority == snapshot.authority && loaded?.tasks == snapshot.tasks
            && loaded?.events == snapshot.events,
            "T-C01 saved Timeline reads SAME admitted actual tasks and journal")
        var observed: [[AgentSavedJobRow]] = []
        var observedCopy: [[String]] = []
        let host = NSHostingView(rootView: ActivityView.SavedJobs(snapshot: loaded,
            observedCopyForTesting: { observedCopy.append($0) }, observedRowsForTesting: { observed.append($0) }).frame(width: 560))
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        check(!observed.isEmpty, "T-C02 actual SavedJobs SwiftUI body not evaluated")
        let rows = observed.last ?? []
        guard let task = snapshot.tasks.first,
              let event = snapshot.events[task.id]?.first else { throw InputError.invalid }
        let qualifier = AgentAuditEntry(id: task.id + ":" + String(event.seq), at: event.draft.at,
            kind: .task, title: AgentActivityProjector.jobEventTitle(event), taskID: task.id)
        var qualified: [AgentAuditEntry] = []
        let rowHost = NSHostingView(rootView: ActivityView.HistoryRow(entry: qualifier,
            observedEntryForTesting: { qualified.append($0) }).frame(width: 560))
        rowHost.layoutSubtreeIfNeeded()
        _ = rowHost.fittingSize
        check(qualified.contains(qualifier), "T-C03 actual HistoryRow body qualification failed")
        let order = snapshot.tasks.sorted { a, b in
            let waits: Set<AgentTaskStatus> = [.waitingForPermission, .waitingForInput, .waitingForCompatibilityCLI]
            if waits.contains(a.status) != waits.contains(b.status) { return waits.contains(a.status) }
            return a.createdAt == b.createdAt ? a.id < b.id : a.createdAt > b.createdAt
        }
        check(rows.count == 3 && rows.map(\.id) == order.map(\.id)
            && rows.first?.state == "Waiting for your answer",
            "T-F01 actual SavedJobs body lacks three tasks in saved needs-you-first order")
        check(rows.count == order.count && zip(rows, order).allSatisfy { row, task in
            row.title == AgentActivityProjector.jobTitle(task)
                && row.state == AgentActivityProjector.jobState(task)
                && observedCopy.last?.contains("Last saved: " + row.state) == true
        }, "T-F02 actual SavedJobs title/state bypasses public production labels")
        let expectedCount = snapshot.events.values.reduce(0) { $0 + $1.count }
        check(rows.flatMap(\.timeline).count == expectedCount
            && rows.allSatisfy { row in
                let events = snapshot.events[row.id] ?? []
                return row.timeline.map(\.id) == events.map { row.id + ":" + String($0.seq) }
                    && zip(row.timeline, events).allSatisfy { entry, event in
                        entry.at == event.draft.at && entry.taskID == row.id
                            && entry.title == AgentActivityProjector.jobEventTitle(event)
                    }
            }, "T-F03 actual SavedJobs loses/reorders/crosses committed journal steps")
        var rendered: [AgentAuditEntry] = []
        var renderedDates: [String] = []
        for entry in rows.flatMap(\.timeline) {
            let eventHost = NSHostingView(rootView: ActivityView.SavedStep(entry: entry,
                observedEntryForTesting: { rendered.append($0) },
                observedDateForTesting: { renderedDates.append($0) }).frame(width: 560))
            eventHost.layoutSubtreeIfNeeded()
            _ = eventHost.fittingSize
        }
        check(!rendered.isEmpty && rows.flatMap(\.timeline).allSatisfy {
            rendered.contains($0) && renderedDates.contains(ActivityView.SavedStep.dateLabel($0.at))
        },
            "T-F04 actual HistoryRow consumers did not receive saved Timeline entries")
        let labels = rows.flatMap { [$0.title, $0.state, $0.result] + $0.integrations + $0.timeline.map(\.title) }.joined(separator: "\n")
        check(!rows.isEmpty && !["jobs-private", "secret chain", "filesystem.read", root.path].contains { labels.contains($0) }
            && rows.flatMap(\.timeline).allSatisfy { $0.detail.isEmpty && $0.toolID == nil && $0.kind == .task },
            "T-F05 actual saved labels disclose body/path/raw tool detail")
        check(rows.count == order.count && zip(rows, order).allSatisfy { row, task in
            row.result == AgentActivityProjector.jobResult(task)
                && row.integrations == AgentActivityProjector.jobIntegrations(snapshot.events[task.id] ?? [])
        }, "T-F06 actual saved result/integration labels imply a different outcome")
        let after = try await JobReport.snapshot(root: root)
        check(try retainedBytes(root) == bytes && after?.authority == snapshot.authority
            && after?.tasks == snapshot.tasks && after?.events == snapshot.events
            && manager.backendStartsForTesting == 3 && exits == 3,
            "T-C04 saved Timeline drawing changed source or dispatched work")
        var empty: [[AgentSavedJobRow]] = []
        let emptyHost = NSHostingView(rootView: ActivityView.SavedJobs(snapshot: nil,
            observedRowsForTesting: { empty.append($0) }).frame(width: 560))
        emptyHost.layoutSubtreeIfNeeded()
        _ = emptyHost.fittingSize
        check(!empty.isEmpty && empty.allSatisfy(\.isEmpty),
            "T-C05 missing snapshot fabricated saved Timeline authority")
        var messages: [[String]] = []
        for mode in ["loading", "unavailable", "missing"] {
            let messageHost = NSHostingView(rootView: ActivityView.SavedJobs(snapshot: nil,
                isLoading: mode == "loading", isUnavailable: mode == "unavailable",
                observedCopyForTesting: { messages.append($0) }).frame(width: 560))
            messageHost.layoutSubtreeIfNeeded()
            _ = messageHost.fittingSize
        }
        check(messages.contains(["Loading saved tasks…"])
            && messages.contains(["Saved task history is unavailable."])
            && messages.contains(["No saved tasks."])
            && observedCopy.last?.first == "",
            "T-C07 actual saved snapshot loading/error/missing/populated messages ambiguous")
        // Supplemental drawing-only date cases: no primary task/event time is changed.
        var dated: [String] = []
        let dates = [Date(timeIntervalSince1970: 1_800_000_000), Date(timeIntervalSince1970: 1_800_172_800)]
        for date in dates {
            var entry = qualifier; entry.at = date
            let dateHost = NSHostingView(rootView: ActivityView.SavedStep(entry: entry,
                observedDateForTesting: { dated.append($0) }).frame(width: 560))
            dateHost.layoutSubtreeIfNeeded()
            _ = dateHost.fittingSize
        }
        check(dates.allSatisfy { date in
            let label = ActivityView.SavedStep.dateLabel(date)
            return dated.contains(label) && label.contains(date.formatted(.dateTime.year()))
        } && Set(dated).count == 2,
            "T-C08 actual saved-only step bodies lack absolute cross-day date context")
        SelfTest.diagnostic("SAVED_TIMELINE_TRACE tasks=\(rows.count) events=\(rows.flatMap(\.timeline).count) bodyObserved=\(!observed.isEmpty) rowObserved=\(qualified.contains(qualifier)) historical=true health=unknown effects=unknown")
    }

    private static func refusalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        check(await JobReport.run(arguments: [JobReport.flag], root: missing) == ["JOBS_REPORT_EMPTY"]
            && !FileManager.default.fileExists(atPath: missing.path), "J-C07 missing history recreated a directory/database")
        let corrupt = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: false)
        let corruptFile = corrupt.appendingPathComponent(TaskStore.fileName)
        let corruptBytes = Data("jobs-retained-corrupt-history".utf8)
        try corruptBytes.write(to: corruptFile)
        let corruptVerdict = await JobReport.run(arguments: [JobReport.flag], root: corrupt)
        check(try corruptVerdict.last?.hasPrefix("JOBS_REPORT_FAILED") == true
            && Data(contentsOf: corruptFile) == corruptBytes, "J-C08 corrupt history erased or reported empty")
        let unmarked = root.appendingPathComponent("unmarked", isDirectory: true)
        let unmarkedSQL = TaskStore(root: unmarked)
        defer { unmarkedSQL.close() }
        try unmarkedSQL.replaceSnapshot([AgentTask(objective: "Retained unmarked history", source: "selftest")])
        let unmarkedBytes = try retainedBytes(unmarked)
        let unmarkedVerdict = await JobReport.run(arguments: [JobReport.flag], root: unmarked)
        check(try unmarkedVerdict.last?.hasPrefix("JOBS_REPORT_FAILED") == true
            && retainedBytes(unmarked) == unmarkedBytes, "J-C09 unmarked history upgraded/marked/erased or reported empty")
        let orphan = root.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        let orphanFile = orphan.appendingPathComponent(TaskStore.fileName + "-wal")
        let orphanBytes = Data("owned orphan".utf8)
        try orphanBytes.write(to: orphanFile)
        let orphanVerdict = await JobReport.run(arguments: [JobReport.flag], root: orphan)
        check(try orphanVerdict.last?.hasPrefix("JOBS_REPORT_FAILED") == true
            && Data(contentsOf: orphanFile) == orphanBytes
            && !FileManager.default.fileExists(atPath: orphan.appendingPathComponent(TaskStore.fileName).path),
            "J-C10 orphan WAL recreated authority or erased retained source")
        let future = root.appendingPathComponent("future", isDirectory: true)
        let futureSQL = TaskStore(root: future)
        defer { futureSQL.close() }
        try futureSQL.replaceSnapshot([])
        try futureSQL.withConnection { try TaskStore.exec($0, "PRAGMA user_version=999") }
        let futureBytes = try retainedBytes(future)
        let futureVerdict = await JobReport.run(arguments: [JobReport.flag], root: future)
        check(try futureVerdict.last?.hasPrefix("JOBS_REPORT_FAILED") == true
            && retainedBytes(future) == futureBytes, "J-C11 newer schema changed or reported empty")
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias.appendingPathComponent(TaskStore.fileName), withDestinationURL: corruptFile)
        let aliasVerdict = await JobReport.run(arguments: [JobReport.flag], root: alias)
        check(try aliasVerdict.last?.hasPrefix("JOBS_REPORT_FAILED") == true
            && Data(contentsOf: corruptFile) == corruptBytes, "J-C12 symlink source followed or rewritten")
        check(await JobReport.run(arguments: [JobReport.flag]).last?.hasPrefix("JOBS_REPORT_FAILED") == true,
            "J-C13 harness read default owner ledger")
        let badDays = await JobReport.run(arguments: [JobReport.flag, JobReport.daysFlag, "0"], root: missing)
        let badTask = await JobReport.run(arguments: [JobReport.flag, JobReport.taskFlag], root: missing)
        check(badDays.last?.hasPrefix("JOBS_REPORT_FAILED") == true
            && badTask.last?.hasPrefix("JOBS_REPORT_FAILED") == true,
            "J-C14 malformed report modifiers accepted")
        check(await JobReport.run(arguments: [JobReport.flag, "--selftest-native-termination"], root: missing).last?.hasPrefix("JOBS_REPORT_FAILED") == true,
            "J-C15 mixed native/live modifier admitted")
        let missingOutput = await JobReport.run(arguments: [JobReport.flag, SelfTest.outputFlag], root: missing)
        let badBudget = await JobReport.run(arguments: [JobReport.flag, SelfTest.timeoutFlag, "nan"], root: missing)
        let stray = await JobReport.run(arguments: [JobReport.flag, "unowned-input"], root: missing)
        check(missingOutput.last?.hasPrefix("JOBS_REPORT_FAILED") == true
            && badBudget.last?.hasPrefix("JOBS_REPORT_FAILED") == true
            && stray.last?.hasPrefix("JOBS_REPORT_FAILED") == true,
            "J-C16 malformed harness/positional modifiers admitted")
    }

    private static func canonicalTasks(_ tasks: [AgentTask]) throws -> [AgentTask] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentTask].self, from: encoder.encode(tasks))
    }

    /// SHM contains SQLite's shared read marks, not authoritative content; this control
    /// pins DB/WAL and owned export/input/receipt bytes. Native runner records SHM metadata.
    private static func retainedBytes(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where !file.lastPathComponent.hasSuffix("-shm") {
            if (try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular {
                result[file.lastPathComponent] = try Data(contentsOf: file)
            }
        }
        return result
    }
    private static func objects(_ lines: [String], prefix: String) throws -> [[String: Any]] {
        try lines.filter { $0.hasPrefix(prefix) }.map { line in
            guard let value = try JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8)) as? [String: Any] else { throw InputError.invalid }
            return value
        }
    }
    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
}
