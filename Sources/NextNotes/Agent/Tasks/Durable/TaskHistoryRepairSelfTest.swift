import Foundation
import SQLite3

/// Explicit repair uses the retained prepared snapshot and the same bound ledger.
/// All fixtures are injected temporary files; no worker, backend or owner history runs.
@MainActor
enum TaskHistoryRepairSelfTest {
    private enum Failure: Error { case interrupted, wrong(String) }

    @MainActor
    private struct Fixture {
        let root: URL
        let file: URL
        let sql: TaskStore
        var store: AgentTaskStore { AgentTaskStore(fileURL: file, mirror: sql) }
        init(_ parent: URL, _ name: String) throws {
            root = parent.appendingPathComponent(name)
            file = root.appendingPathComponent("agent-tasks.json")
            sql = TaskStore(root: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            guard store.allowsHarnessPersistence else { throw Failure.wrong("unsafe fixture") }
        }
        func prepared(_ tasks: [AgentTask]) throws {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(tasks).write(to: file)
            let pending = store
            pending.migrationBoundaryForTesting = { phase in
                if phase == "prepared" { throw Failure.interrupted }
            }
            do { _ = try pending.load(); throw Failure.wrong("preparation did not stop") }
            catch Failure.interrupted {}
        }
    }

    private static func row(_ id: String = "fixture") -> AgentTask {
        AgentTask(id: id, objective: "Restore this saved task", source: "text",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: .running,
            progress: "Working", tool: "fixture.read", backend: "local")
    }

    static func run() -> String {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesHistoryRepair-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            #if TASK_HISTORY_REPAIR_ORIGINAL
            let fixture = try Fixture(parent, "original-prepared-empty")
            try fixture.prepared([row()])
            let saved = try Data(contentsOf: fixture.file)
            let empty = try Data(contentsOf: fixture.sql.fileURL)
            let fresh = fixture.store
            do {
                try fresh.reconcilePreparedForTesting()
                guard try fresh.load() == [row()] else { throw Failure.wrong("payload changed") }
            } catch {
                guard try Data(contentsOf: fixture.file) == saved,
                      try Data(contentsOf: fixture.sql.fileURL) == empty else {
                    throw Failure.wrong("original refusal changed saved files")
                }
                return "TASK_HISTORY_REPAIR_FAILED: explicit prepared schema-zero repair is unavailable: \(error.localizedDescription)"
            }
            return "TASK_HISTORY_REPAIR_OK: original prepared fixture"
            #else
            return "TASK_HISTORY_REPAIR_FAILED: repair cases not implemented yet"
            #endif
        } catch { return "TASK_HISTORY_REPAIR_FAILED: \(error.localizedDescription)" }
    }
}
