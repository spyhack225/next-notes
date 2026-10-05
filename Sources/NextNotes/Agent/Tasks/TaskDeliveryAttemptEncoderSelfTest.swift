import Foundation

/// Supplementary actual Store canonicalization boundary, not output-delivery authority.
@MainActor
enum TaskDeliveryAttemptEncoderSelfTest {
    private enum Invalid: Error { case unsafe }
    static func run() -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil else { return (0, ["delivery encoder: INVALID scope"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["delivery encoder: INVALID root"]) }
        var checks = 0; var failures: [String] = []; var created = false
        let owner = SelfTestStoreGuard.take()
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("delivery encoder: " + label) } }
        defer { if created { try? FileManager.default.removeItem(at: root) } }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            for count in [-1, 0, 1] {
                let start = checks
                let dir = root.appendingPathComponent("count-\(count)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                let sql = TaskStore(root: dir); defer { sql.close() }
                let file = dir.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let row = AgentTask(objective: "Inspect an owned fixture.", source: "voice", status: .running,
                    origin: .voice(sessionID: UUID(), turn: TurnID(raw: 31)))
                guard store.save([row]).primaryCommitted, let before = try sql.load().first else { throw Invalid.unsafe }
                let rows = try sql.load(); let journal = try sql.journal(taskID: row.id)
                let bytes = try Data(contentsOf: file); let authority = try sql.probeAuthority(includeTasks: false)?.authority
                check(rows.count == 1 && before.id == row.id && before.deliveryAttempts == 0,
                    "C01 actual owned metadata seed did not qualify (\(count))")
                var next = before; next.deliveryAttempts = count
                check(next.delivery == nil && next.deliveryAttempts == count,
                    "C02 nil-delivery authored input changed (\(count))")
                let saved = store.save([next]); let after = try sql.load()
                if count < 0 {
                    check(saved == .jsonFailed, "F01 negative nil-delivery count escaped strict decode")
                    check(try after == rows && Data(contentsOf: file) == bytes
                        && sql.journal(taskID: row.id) == journal
                        && sql.probeAuthority(includeTasks: false)?.authority == authority,
                        "F02 negative nil-delivery count changed primary/export/generation")
                } else {
                    check(saved.primaryCommitted && after.count == 1 && after.first?.delivery == nil
                        && after.first?.deliveryAttempts == count,
                        "C03 zero/positive nil-delivery count compatibility failed (\(count))")
                    check(try sql.journal(taskID: row.id) == journal && after.first?.id == before.id
                        && after.first?.origin == before.origin && after.first?.revision == before.revision,
                        "C04 unrelated canonical identity/journal changed (\(count))")
                }
                print("TASK_DELIVERY_ENCODER_CASE authored=\(count) saved=\(saved.primaryCommitted) jsonFailed=\(saved == .jsonFailed) stored=\(after.first?.deliveryAttempts ?? -999) checks=\(checks-start)")
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C05 owner state changed")
        } catch { failures.append("delivery encoder: INVALID \(error)") }
        return (checks, failures)
    }
}
