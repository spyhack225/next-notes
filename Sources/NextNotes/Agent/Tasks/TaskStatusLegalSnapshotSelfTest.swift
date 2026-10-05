import Foundation
import SQLite3

/// Stored-state reader/projector coverage only, not a live worker, Gate or cessation proof.
/// The real intake/worker corpus remains separate and unchanged at 285 checks.
@MainActor
enum TaskStatusLegalSnapshotSelfTest {
    private enum Invalid: Error { case scope, unsafe, store }
    static func run() -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil else { return (0, ["status snapshot: INVALID scope"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.deletingLastPathComponent().path == temp.path,
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["status snapshot: INVALID root"]) }
        let owner = SelfTestStoreGuard.take()
        var checks = 0; var failures: [String] = []; var created = false
        func check(_ yes: Bool, _ name: String) { checks += 1; if !yes { failures.append("status snapshot: " + name) } }
        defer { if created { try? FileManager.default.removeItem(at: root) } }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            for state in AgentTaskStatus.allCases {
                let directory = root.appendingPathComponent(state.rawValue, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let writer = AgentTaskStore(fileURL: file, mirror: sql)
                guard writer.allowsHarnessPersistence, writer.save([]).primaryCommitted else { throw Invalid.store }
                var row = AgentTask(objective: "Prepare the agenda", source: "voice", status: state,
                    progress: "Step 2: Read the source", origin: .voice(sessionID: UUID(), turn: TurnID(raw: 1)),
                    userWords: "Owned fixture words must not appear in status.")
                if state == .waitingForInput { row.result = "Which document should I use?" }
                if state == .completed { row.result = "The agenda is ready." }
                if state == .failed { row.failure = "The document could not be read." }
                guard writer.save([row]).primaryCommitted else { throw Invalid.store }
                let actual = try sql.load()
                let reader = AgentTaskStore(fileURL: file, mirror: sql)
                let loaded = try reader.load()
                check(loaded == actual && loaded.count == 1 && loaded[0].status == state,
                    "C01 exact legal saved state did not survive actual reader (\(state.rawValue))")
                let export = try Data(contentsOf: file)
                let changes = try sql.withConnection { sqlite3_total_changes($0) }
                let record = TaskRecord(loaded[0])
                let reply = TaskStatusRenderer.spoken([record])
                let expected: String
                switch state {
                case .queued: expected = "Prepare the agenda is ready to start."
                case .running: expected = "Still on Prepare the agenda — Read the source, start time unavailable."
                case .recovering: expected = "Prepare the agenda is paused after restart."
                case .waitingForPermission: expected = "Prepare the agenda is waiting for your OK."
                case .waitingForCompatibilityCLI: expected = "Prepare the agenda needs your confirmation."
                case .waitingForInput: expected = "Prepare the agenda needs an answer: Which document should I use?"
                case .completed: expected = "Prepare the agenda is done: The agenda is ready."
                case .failed: expected = "Prepare the agenda didn't work: The document could not be read."
                case .cancelled: expected = "Prepare the agenda has a saved stop request."
                }
                check(reply == expected && !reply.contains(row.id) && !reply.contains(row.userWords ?? ""),
                    "F15 exact legal saved-state public copy missing (\(state.rawValue))")
                check(try sql.load() == actual && Data(contentsOf: file) == export
                    && sql.withConnection { sqlite3_total_changes($0) } == changes,
                    "C02 rendering saved state wrote primary/export (\(state.rawValue))")
                print("TASK_STATUS_LEGAL_SNAPSHOT_CASE state=\(state.rawValue) checks=3 readOnly=true")
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C03 owner state changed")
        } catch { failures.append("status snapshot: INVALID \(error)") }
        return (checks, failures)
    }
}
