import Foundation
import Darwin

/// P6-08's explicit read-only diagnostic over the SAME existing marked SQL ledger.
/// Saved status/LAST heartbeat never imply current health, completed effects or retry.
/// No Manager/shared store initialization, JSON fallback, schema installation or writes.
enum JobReport {
    static let flag = "--jobs-report"
    static let daysFlag = "--jobs-days"
    static let taskFlag = "--jobs-task"
    static let defaultDays = 30
    private enum SnapshotInputError: Error {
        case isolatedRootRequiresHarness, isolatedRootRefused, ownerUnavailable
    }

    /// Invoked before App.main, so eager owner-backed UI cannot migrate/create stores.
    /// Only the report operation runs: no native/model/voice work exists to drain on exit.
    @MainActor
    static func runStandalone(arguments: [String]) -> Int32 {
        let output = value(after: SelfTest.outputFlag, arguments: arguments)
        if let output {
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            let candidate = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(temporary + "/"),
                  !candidate.pathComponents.contains("Application Support") else {
                print("JOBS_REPORT_FAILED: output must be a temporary diagnostic file")
                return 1
            }
        }
        let lines = read(arguments: arguments)
        for line in lines { print(line) }
        if let output {
            do { try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8) }
            catch {
                print("JOBS_REPORT_FAILED: temporary diagnostic output could not be saved")
                return 1
            }
        }
        return lines.last?.hasPrefix("JOBS_REPORT_FAILED") == true
            || lines.last?.hasPrefix("JOBS_REPORT_MISSING") == true ? 1 : 0
    }

    /// SAME production reader on the existing utility diagnostic lane. A fixture may
    /// inject only a confined system-temp root; ordinary calls select the owner ledger.
    static func run(arguments: [String], root: URL? = nil, now: Date = Date()) async -> [String] {
        await Task.detached(priority: .utility) { read(arguments: arguments, root: root, now: now) }.value
    }

    static func read(arguments: [String], root: URL? = nil, now: Date = Date()) -> [String] {
        do {
            let allowed: Set<String> = [flag, daysFlag, taskFlag, SelfTest.outputFlag, SelfTest.timeoutFlag]
            guard arguments.filter({ $0.hasPrefix("--") }).allSatisfy({ allowed.contains($0) }),
                  arguments.filter({ $0 == flag }).count == 1,
                  allowed.allSatisfy({ item in arguments.filter { $0 == item }.count <= 1 }) else { return ["JOBS_REPORT_FAILED: conflicting or unknown modifier"] }
            // Consume only known flags and their exact values. Stray positional input
            // must not silently turn an invalid invocation into an owner-history read.
            var index = 0
            while index < arguments.count {
                let item = arguments[index]
                guard allowed.contains(item) else { return ["JOBS_REPORT_FAILED: unexpected argument"] }
                if item != flag {
                    guard let raw = value(after: item, arguments: arguments), !raw.isEmpty else {
                        return ["JOBS_REPORT_FAILED: missing modifier value"]
                    }
                    if item == SelfTest.timeoutFlag {
                        guard let seconds = Double(raw), seconds.isFinite, seconds > 0 else {
                            return ["JOBS_REPORT_FAILED: invalid diagnostic budget"]
                        }
                    }
                    index += 1
                }
                index += 1
            }
            let days: Int
            if let raw = value(after: daysFlag, arguments: arguments) {
                guard let parsed = Int(raw), parsed > 0, parsed <= 36_500 else { return ["JOBS_REPORT_FAILED: invalid day window"] }
                days = parsed
            } else {
                guard !arguments.contains(daysFlag) else { return ["JOBS_REPORT_FAILED: missing day window"] }
                days = defaultDays
            }
            let taskID = value(after: taskFlag, arguments: arguments)
            guard !arguments.contains(taskFlag) || (taskID != nil && !(taskID?.isEmpty ?? true)) else {
                return ["JOBS_REPORT_FAILED: missing task filter"]
            }
            guard let snapshot = try readSnapshot(root: root) else { return ["JOBS_REPORT_EMPTY"] }
            guard snapshot.authority != nil else { return ["JOBS_REPORT_FAILED: task history is not admitted"] }
            return lines(snapshot: snapshot, days: days, taskID: taskID, now: now)
        } catch let error as SnapshotInputError {
            switch error {
            case .isolatedRootRequiresHarness: return ["JOBS_REPORT_FAILED: isolated root requires harness"]
            case .isolatedRootRefused: return ["JOBS_REPORT_FAILED: isolated root refused"]
            case .ownerUnavailable: return ["JOBS_REPORT_FAILED: owner history unavailable under harness"]
            }
        } catch { return ["JOBS_REPORT_FAILED: existing task history could not be read; source retained"] }
    }

    /// Same readonly marked-ledger probe used by CLI and the saved-history consumer.
    /// Missing remains absent. Callers must check the authority marker before display.
    static func readSnapshot(root: URL? = nil) throws -> TaskStoreAuthorityProbe? {
        let directory: URL
        if let root {
            guard SelfTest.isRunning else { throw SnapshotInputError.isolatedRootRequiresHarness }
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(temporary + "/"),
                  !canonical.pathComponents.contains("Application Support") else {
                throw SnapshotInputError.isolatedRootRefused
            }
            directory = canonical
        } else {
            guard !SelfTest.isRunning else { throw SnapshotInputError.ownerUnavailable }
            directory = AppIdentity.applicationSupportDirectoryURL
        }
        let store = TaskStore(root: directory)
        defer { store.close() }
        // Do not follow a DB/WAL/SHM alias into another owner. Missing DB is handled
        // by the SAME existing authority probe (including orphan-sibling refusal).
        var present = Set<String>()
        for suffix in ["", "-wal", "-shm"] {
            var attributes = stat()
            let path = store.fileURL.path + suffix
            if lstat(path, &attributes) == 0 {
                guard (attributes.st_mode & S_IFMT) == S_IFREG else { throw TaskStoreError.invalidRecord }
                present.insert(suffix)
            } else if errno != ENOENT { throw TaskStoreError.fileRemoved }
        }
        // A readonly WAL reader may otherwise create its shared-memory sibling.
        // Refuse an unavailable sibling instead of creating it during a report.
        guard !present.contains("-wal") || present.contains("-shm") else { throw TaskStoreError.authorityConflict }
        return try store.probeAuthority(includeTasks: true, includeJournal: true)
    }

    /// Existing diagnostic utility lane; drawing receives only its immutable value.
    static func snapshot(root: URL? = nil) async throws -> TaskStoreAuthorityProbe? {
        let snapshot = try await Task.detached(priority: .utility) { try readSnapshot(root: root) }.value
        guard snapshot == nil || snapshot?.authority != nil else { throw TaskStoreError.authorityConflict }
        return snapshot
    }

    static func lines(snapshot: TaskStoreAuthorityProbe, days: Int, taskID: String?, now: Date) -> [String] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let selected = snapshot.tasks.filter { task in
            guard taskID == nil || task.id == taskID else { return false }
            let terminal = [.completed, .failed, .cancelled].contains(task.status)
            return !terminal || task.createdAt >= since || (snapshot.events[task.id]?.last?.draft.at ?? .distantPast) >= since
        }.sorted { a, b in
            let waits: Set<AgentTaskStatus> = [.waitingForPermission, .waitingForInput, .waitingForCompatibilityCLI]
            if waits.contains(a.status) != waits.contains(b.status) { return waits.contains(a.status) }
            return a.createdAt == b.createdAt ? a.id < b.id : a.createdAt > b.createdAt
        }
        guard !selected.isEmpty else { return ["JOBS_REPORT_EMPTY"] }
        var lines: [String] = []
        var eventCount = 0
        func encoded(_ object: [String: Any]) -> String? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        for task in selected {
            let events = snapshot.events[task.id] ?? []
            // Legacy arbitrary identifiers remain unknown display metadata; never print
            // them as raw content or manufacture a replacement join.
            let safeID: Any = task.id.utf8.count == 36 && UUID(uuidString: task.id) != nil ? task.id : NSNull()
            let attempt: Any = task.durability.flatMap { $0.attempt > 0 ? $0.attempt as Any : nil } ?? NSNull()
            let heartbeat: Any = task.durability?.heartbeatAt.map { $0.ISO8601Format() as Any } ?? NSNull()
            let elapsed: Any
            if let start = task.durability?.attemptStartedAt {
                let terminals: Set<TaskEventKind> = [.jobCompleted, .jobFailed, .jobCancelled]
                let terminal = [.completed, .failed, .cancelled].contains(task.status)
                let savedEnd = events.last { terminals.contains($0.draft.kind)
                    && $0.draft.attempt == task.durability?.attempt }?.draft.at
                // A terminal row without its matching end event has unknown elapsed
                // time. Never extend it to the report clock as though it were active.
                if let end = savedEnd ?? (terminal ? nil : now) {
                    let duration = end.timeIntervalSince(start)
                    elapsed = duration.isFinite && duration >= 0 ? duration as Any : NSNull()
                } else { elapsed = NSNull() }
            } else { elapsed = NSNull() }
            let row: [String: Any] = ["taskID": safeID, "title": AgentActivityProjector.jobTitle(task),
                "status": task.status.rawValue, "state": AgentActivityProjector.jobState(task),
                "attempt": attempt, "elapsedSeconds": elapsed,
                "integrations": AgentActivityProjector.jobIntegrations(events),
                "heartbeat": heartbeat, "heartbeatScope": "LAST", "health": "unknown", "effects": "unknown",
                "result": AgentActivityProjector.jobResult(task)]
            guard let text = encoded(row) else { return ["JOBS_REPORT_FAILED: projection unavailable"] }
            lines.append("JOBS_REPORT_ROW " + text)
            for event in events {
                let eventRow: [String: Any] = ["taskID": safeID, "seq": event.seq,
                    "at": event.draft.at.ISO8601Format(), "kind": event.draft.kind.rawValue,
                    "attempt": event.draft.attempt, "title": AgentActivityProjector.jobEventTitle(event)]
                guard let text = encoded(eventRow) else { return ["JOBS_REPORT_FAILED: journal projection unavailable"] }
                lines.append("JOBS_REPORT_EVENT " + text)
                eventCount += 1
            }
        }
        lines.append("JOBS_REPORT_OK tasks=\(selected.count) events=\(eventCount) health=unknown effects=unknown")
        return lines
    }

    private static func value(after flag: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }
}
