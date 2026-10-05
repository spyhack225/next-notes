import Foundation

/// Actual Manager question producer supplies a fresh request; the SAME authoritative
/// Store condition exercises legal transition domains. No worker/effect/retry proof.
@MainActor
enum TaskVoicePrimaryAPIConditionSelfTest {
    private enum Invalid: Error { case unsafe, question }
    static func run() -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil else { return (0, ["voice primary API: INVALID scope"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["voice primary API: INVALID root"]) }
        var checks = 0; var failures: [String] = []; var created = false
        let owner = SelfTestStoreGuard.take()
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("voice primary API: " + label) } }
        defer { if created { try? FileManager.default.removeItem(at: root) } }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            for mode in ["revision-valid", "resume-valid", "resume-revision", "revision-regressed",
                         "wrong-question", "reissued-question", "missing-primary-task", "question-state-mismatch",
                         "missing-input-id", "origin-turn-changed", "SQL-refused", "events-missing", "events-wrong-attempt"] {
                let start = checks
                let dir = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                let sql = TaskStore(root: dir); defer { sql.close() }
                let file = dir.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store)
                let id = UUID(); let origin = TaskOrigin.voice(sessionID: UUID(), turn: TurnID(raw: 29))
                guard manager.beginVoiceObjective(id: id, objective: "Inspect an owned fixture.", origin: origin) else { throw Invalid.unsafe }
                let running = mode.hasPrefix("revision-")
                if !running {
                    guard manager.finishVoiceObjective(id: id, outcome: .voiceReply("Which owned fixture should I read?")) else { throw Invalid.question }
                }
                guard let before = try sql.load().first, before.id == id.uuidString else { throw Invalid.unsafe }
                let request: TaskInputRequest?
                if case .input(let value)? = before.pendingInteraction { request = value } else { request = nil }
                var next = before
                next.status = .running
                next.revision = running || mode == "resume-revision" ? before.revision + 1 : before.revision
                if mode == "revision-regressed" { next.revision = -1 }
                if !running { next.pendingInteraction = nil; next.result = nil; next.failure = nil; next.userWords = "Read the owned fixture." }
                var condition = TaskWorkerWriteCondition(taskID: id.uuidString, attempt: 0, leaseOwner: nil,
                    status: before.status, voiceOrigin: origin, voiceRevision: before.revision,
                    voiceInputRequestID: request?.id)
                var events = running ? [] : [TaskJournalEventDraft(taskID: id.uuidString, kind: .inputProvided),
                    TaskJournalEventDraft(taskID: id.uuidString, kind: .workerStarted)]
                if mode == "wrong-question" { condition.voiceInputRequestID = UUID().uuidString }
                if mode == "missing-input-id" { condition.voiceInputRequestID = nil }
                if mode == "missing-primary-task" { condition = TaskWorkerWriteCondition(taskID: UUID().uuidString, attempt: 0, leaseOwner: nil,
                    status: before.status, voiceOrigin: origin, voiceRevision: before.revision, voiceInputRequestID: request?.id) }
                if mode == "events-missing" { events.removeLast() }
                if mode == "events-wrong-attempt" { events[0].attempt = 1 }
                try sql.withConnection { db in
                    if mode == "reissued-question", let request {
                        let replacement = TaskInputRequest(taskID: request.taskID,
                            question: request.question, createdAt: request.createdAt)
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
                        let data = try encoder.encode(TaskPendingInteraction.input(replacement))
                        try TaskStore.run(db, "UPDATE task SET pending_interaction=? WHERE id=?",
                            [.text(String(decoding: data, as: UTF8.self)), .text(id.uuidString)])
                    }
                    if mode == "question-state-mismatch" { try TaskStore.run(db, "UPDATE task SET state='cancelled' WHERE id=?", [.text(id.uuidString)]) }
                    if mode == "origin-turn-changed", case .voice(let session, _)=origin {
                        let data = try JSONEncoder().encode(TaskOrigin.voice(sessionID: session, turn: TurnID(raw: 30)))
                        try TaskStore.run(db, "UPDATE task SET origin=? WHERE id=?", [.text(String(decoding: data, as: UTF8.self)), .text(id.uuidString)])
                    }
                    if mode == "SQL-refused" { try TaskStore.exec(db, "CREATE TRIGGER reject_current_voice_API BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture API refusal'); END") }
                }
                let rows = try sql.load(); let journal = try sql.journal(taskID: id.uuidString)
                let bytes = try Data(contentsOf: file); let authority = try sql.probeAuthority(includeTasks: false)?.authority
                check(rows.count == 1 && rows.first?.id == id.uuidString && (running || request?.taskID == id.uuidString),
                    "C01 actual primary/question producer did not qualify (\(mode))")
                let saved = store.save([next], events: events, worker: condition)
                let after = try sql.load()
                if ["revision-valid", "resume-valid", "resume-revision"].contains(mode) {
                    check(saved.primaryCommitted && after.first?.status == .running && after.first?.revision == next.revision
                        && after.first?.pendingInteraction == nil, "F01 legal exact voice transition refused (\(mode))")
                    check(try saved.primaryCommitted || (after == rows && Data(contentsOf: file) == bytes),
                        "C02 original refusal changed retained primary/export (\(mode))")
                } else {
                    check(try !saved.primaryCommitted && after == rows && Data(contentsOf: file) == bytes,
                        "C03 stale/question/illegal/refused API condition changed primary/export (\(mode))")
                    check(try sql.journal(taskID: id.uuidString) == journal && sql.probeAuthority(includeTasks: false)?.authority == authority,
                        "C04 refused API condition changed journal/generation (\(mode))")
                }
                print("VOICE_PRIMARY_API_CASE mode=\(mode) checks=\(checks-start) committed=\(saved.primaryCommitted)")
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C05 owner state changed")
        } catch { failures.append("voice primary API: INVALID \(error)") }
        return (checks, failures)
    }
}
