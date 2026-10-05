import Foundation
import SQLite3

/// Real committed turns -> split typed decision -> SAME retained Manager Work.
/// External frontend output and held worker result are the only substitutions.
@MainActor
enum FrontendRevisionSelfTest {
    private enum Invalid: Error { case scope, admission, stream, capture }
    @MainActor private final class FrontendProbe {
        var calls = 0
        var correction = ""
        func stream() -> AsyncThrowingStream<String, Error> {
            calls += 1
            let output = calls == 1 ? "<use_tools/>" : correction
            return AsyncThrowingStream { continuation in
                let middle = output.index(output.startIndex, offsetBy: output.count / 2)
                continuation.yield(String(output[..<middle])); continuation.yield(String(output[middle...]))
                continuation.finish()
            }
        }
    }
    static func run() async -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-turn-routing",
              AgentSession.shared.fileURL == nil, !AgentCaptureController.shared.isSessionActive,
              !VoiceConversationCoordinator.shared.hasActiveWork,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            return (0, ["frontend revision: INVALID diagnostic scope"])
        }
        let conversation = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        let synth = AgentSpeechSynthesizer.shared, recording = RecordingSpeechBacking()
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["frontend revision: INVALID temp scope"]) }
        let oldBridge = conversation.taskBridgeOverrideForTesting, oldRemember = conversation.rememberExplicit
        let owner = SelfTestStoreGuard.take()
        var created = false, sessionOwned = false, mayRemoveRoot = false, cleanupRequested = false
        var owned: Task<Void, Never>?, release: CheckedContinuation<String, Never>?
        var manager: AgentTaskManager?
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("frontend revision: " + label) } }
        func input(_ words: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(words, source: .voice)
        }
        func drain() {
            for _ in 0..<32 where synth.voiceLifecycleSnapshot.hasClause || synth.pendingClauseCount > 0 {
                let token = synth.currentPlaybackToken
                synth.notifyTestingFirstAudio(token: token)
                recording.finishNaturallyForTesting(); synth.notifyTestingAudioFinished(token: token)
            }
        }
        defer {
            conversation.resetForTesting(); _ = conversation.installTaskBridgeForTesting(oldBridge)
            conversation.rememberExplicit = oldRemember; synth.restoreSystemBacking()
            if created && mayRemoveRoot { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            synth.useTestingBacking(recording)
            for mode in ["resolved", "numeric", "negation", "legacy", "missing", "refused", "outOfRange", "faithful"] {
                let start = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.scope }
                let current = AgentTaskManager(store: store); manager = current
                conversation.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard conversation.installTaskBridgeForTesting(TaskBridge(manager: current)) else { throw Invalid.scope }
                conversation.rememberExplicit = { _ in }; conversation.prewarmObserverForTesting = {}
                await capture.beginSession(captureAudio: false); sessionOwned = true
                guard let session = capture.sessionID else { throw Invalid.scope }
                let initial = "Arrange the itinerary for Monday."
                let raw = mode == "numeric" ? "Adjust it for Marcus at 7."
                    : mode == "negation" ? "Adjust it for Marcus, no links." : "Adjust it for Marcus."
                let proposed = mode == "numeric" ? "Adjust the itinerary for Marcus at 8."
                    : mode == "negation" ? "Adjust the itinerary for Marcus, links."
                    : mode == "faithful" ? raw : "Adjust the itinerary for Marcus."
                let frontend = FrontendProbe()
                if mode == "legacy" { frontend.correction = "<revise id=\"1\"/>" }
                else {
                    frontend.correction = try FrontendDecisionPayload(intent: "revise", taskNumber: mode == "outOfRange" ? 2 : 1,
                        objective: mode == "missing" ? nil : proposed).controlChunk()
                }
                var workers = 0
                var captured: VoiceWorkerTestCapture?
                var enteredWait: CheckedContinuation<Void, Never>?
                conversation.streamForTesting = { _, _ in await frontend.stream() }
                conversation.workerForTesting = { work in
                    workers += 1
                    // A preflight/qualification throw must not leave a late-entering
                    // already-admitted callback suspended after teardown starts.
                    if cleanupRequested { return "" }
                    if let currentCapture = conversation.captureVoiceWorkerForTesting(id: work.id) {
                        captured = currentCapture
                        if let task = currentCapture.task { owned = task }
                    }
                    enteredWait?.resume(); enteredWait = nil
                    return await withCheckedContinuation { release = $0 }
                }
                _ = await input(initial)
                guard let first = current.tasks.first, let id = UUID(uuidString: first.id),
                      let actual = conversation.captureVoiceWorkerForTesting(id: id), let task = actual.task else { throw Invalid.admission }
                captured = actual; owned = task // BEFORE qualification, teardown always joins the admitted operation.
                if release == nil { await withCheckedContinuation { enteredWait = $0 } }
                guard release != nil, workers == 1, actual.work.revision == 0 else { throw Invalid.capture }
                drain()
                if mode == "refused" {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_typed_revision BEFORE UPDATE OF revision ON task WHEN NEW.revision>OLD.revision BEGIN SELECT RAISE(ABORT,'owned refusal'); END") }
                }
                let turn = await input(raw); drain()
                guard frontend.calls == 2 else { throw Invalid.stream }
                let outside = mode == "outOfRange", refused = mode == "refused"
                let legacy = mode == "legacy" || mode == "missing"
                let rejected = mode == "numeric" || mode == "negation"
                let acceptedText = rejected || legacy ? raw : proposed
                let instruction = acceptedText == raw ? raw : acceptedText + "\n(The person's exact words: " + raw + ")"
                let row = current.task(id: first.id)
                let reader = TaskStore(root: directory); defer { reader.close() }
                let fresh = try reader.load().first(where: { $0.id == first.id })
                check(frontend.calls == 2 && workers == 1, "C01 one correction stream and SAME held worker (\(mode))")
                check(captured?.task == task && current.voiceWorkerSnapshot(id: id)?.task == task
                    && current.voiceWorkerSnapshot(id: id)?.work === actual.work,
                    "C02 revision replaced actual Task/Work owner (\(mode))")
                check(actual.work.revision == (outside ? 0 : 1), "F01 actual local revision transport mismatch (\(mode))")
                check(outside ? actual.work.followUps.isEmpty : actual.work.followUps == [instruction],
                    "F02 actual worker lost faithful objective/exact raw words or admitted rejected objective (\(mode))")
                check(row?.userWords == (outside || refused || legacy ? first.userWords : raw),
                    "F03 SAME canonical row lost exact current raw words or changed legacy/refused words (\(mode))")
                check(fresh?.revision == (outside || refused ? 0 : 1) && fresh?.userWords == row?.userWords,
                    "F04 revision/raw words primary admission mismatch (\(mode))")
                check(refused ? current.liveVoiceRevision(id: id) == nil : current.liveVoiceRevision(id: id) == (outside ? 0 : 1),
                    "C03 failed save lost newer local hold/current admitted revision authority (\(mode))")
                check(turn.reply == (outside ? "That task has already finished. What would you like me to do next?"
                    : refused ? "I couldn't save that correction. The task is waiting." : "Got it. I'll use that correction."),
                    "F05 actual correction receipt mismatch (\(mode))")
                let positiveOrigin: Bool
                if case .voice(let rowSession, let rowTurn)? = row?.origin { positiveOrigin = rowSession == session && rowTurn.raw > 0 }
                else { positiveOrigin = false }
                check(current.tasks.count == 1 && row?.objective == initial && positiveOrigin,
                    "C04 correction changed original task identity/objective/current origin (\(mode))")
                release?.resume(returning: "The owned revised itinerary result."); release = nil
                await task.value; owned = nil
                check(current.voiceWorkerSnapshot(id: id) == nil, "C05 SAME actual Task failed to join/release (\(mode))")
                print("FRONTEND_REVISION_CASE mode=\(mode) checks=\(checks-start) streams=\(frontend.calls) workers=\(workers) localRevision=\(actual.work.revision) primaryRevision=\(fresh?.revision ?? -1) physical=false")
                await capture.endSession(source: .done); sessionOwned = false
                conversation.resetForTesting(); manager = nil; drain()
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C06 owner state/default invariant")
            mayRemoveRoot = true // All actual admitted Tasks above have joined.
        } catch {
            failures.append("frontend revision: INVALID \(error)")
            cleanupRequested = true
            // Capture every SAME actual slot before cancel can alter/release it.
            // These are retained fixture references, not new Tasks or owners.
            var joins: [Task<Void, Never>] = []
            if let owned { joins.append(owned) }
            if let manager {
                for row in manager.tasks {
                    if let id = UUID(uuidString: row.id), let operation = manager.voiceWorkerSnapshot(id: id)?.task,
                       !joins.contains(where: { $0 == operation }) { joins.append(operation) }
                }
                for row in manager.tasks { if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) } }
            }
            release?.resume(returning: ""); release = nil
            for operation in joins { await operation.value }
            mayRemoveRoot = manager?.tasks.allSatisfy { row in
                guard let id = UUID(uuidString: row.id) else { return false }
                return manager?.voiceWorkerSnapshot(id: id)?.task == nil
            } ?? true
            if sessionOwned { await capture.endSession(source: .done) }
        }
        return (checks, failures)
    }
}
