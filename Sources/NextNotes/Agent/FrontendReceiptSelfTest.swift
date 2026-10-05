import Foundation
import SQLite3

/// Actual shared voice intake -> streamed control -> Bridge primary receipt ->
/// SAME Manager worker. The only substitution is external frontend/worker output.
@MainActor
enum FrontendReceiptSelfTest {
    private enum Invalid: Error { case scope, stream, capture }
    @MainActor private final class FrontendProbe {
        var calls = 0
        let chunk: String
        init(chunk: String) { self.chunk = chunk }
        func stream(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
            calls += 1
            let last = messages.last(where: { $0.role == .user })?.content ?? ""
            let output = last.hasSuffix("What's a good topic?") ? "<answer/>The pricing sheet." : chunk
            return AsyncThrowingStream { continuation in
                // SAME authored split boundary; no early admission or new owner.
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
            return (0, ["frontend receipt: INVALID diagnostic scope"])
        }
        let conversation = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        let synth = AgentSpeechSynthesizer.shared, recording = RecordingSpeechBacking()
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["frontend receipt: INVALID temp scope"]) }
        let priorBridge = conversation.taskBridgeOverrideForTesting
        let priorRemember = conversation.rememberExplicit
        let owner = SelfTestStoreGuard.take()
        var created = false, sessionOwned = false
        var owned: Task<Void, Never>?, release: CheckedContinuation<String, Never>?
        var manager: AgentTaskManager?
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("frontend receipt: " + label) } }
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
            conversation.resetForTesting(); _ = conversation.installTaskBridgeForTesting(priorBridge)
            conversation.rememberExplicit = priorRemember
            synth.restoreSystemBacking()
            if created { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            synth.useTestingBacking(recording)
            for mode in ["faithful", "filler", "identifier", "omitted", "url", "refused", "resolved", "number", "negation"] {
                let start = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.scope }
                let current = AgentTaskManager(store: store); manager = current
                let bridge = TaskBridge(manager: current)
                conversation.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard conversation.installTaskBridgeForTesting(bridge) else { throw Invalid.scope }
                conversation.rememberExplicit = { _ in }; conversation.prewarmObserverForTesting = {}
                await capture.beginSession(captureAudio: false); sessionOwned = true
                guard let session = capture.sessionID else { throw Invalid.scope }
                let raw = mode == "resolved" ? "Give it to Marcus."
                    : mode == "number" ? "Arrange the itinerary for Monday at 7."
                    : mode == "negation" ? "Arrange the itinerary for Monday, no links."
                    : "Arrange the itinerary for Monday."
                let proposed = mode == "resolved" ? "Give the pricing sheet to Marcus."
                    : mode == "omitted" ? "Arrange the itinerary."
                    : mode == "url" ? "Arrange the itinerary for Monday at https://example.test."
                    : mode == "number" ? "Arrange the itinerary for Monday at 8."
                    : mode == "negation" ? "Arrange the itinerary for Monday, links."
                    : "Arrange the itinerary for Monday."
                let ack = mode == "filler" ? "Hold on, I'll get back to you."
                    : mode == "identifier" ? "Arranging /tmp/owned123 for Monday."
                    : mode == "resolved" ? "Giving the pricing sheet to Marcus."
                    : mode == "number" ? "Arranging your itinerary at 8."
                    : mode == "negation" ? "Arranging your itinerary with links."
                    : "Arranging your itinerary for Monday."
                let payload = FrontendDecisionPayload(intent: "spawn", objective: proposed, acknowledgement: ack)
                let chunk = try payload.controlChunk()
                let frontend = FrontendProbe(chunk: chunk)
                var workerCalls = 0, workerText: String?
                var captured: VoiceWorkerTestCapture?
                var enteredWait: CheckedContinuation<Void, Never>?
                conversation.streamForTesting = { _, messages in await frontend.stream(messages) }
                conversation.workerForTesting = { work in
                    workerCalls += 1; workerText = work.original
                    if let enteredCapture = conversation.captureVoiceWorkerForTesting(id: work.id) {
                        captured = enteredCapture
                        if let operation = enteredCapture.task { owned = operation }
                    }
                    enteredWait?.resume(); enteredWait = nil
                    return await withCheckedContinuation { release = $0 }
                }
                if mode == "resolved" {
                    let previous = await input("What's a good topic?")
                    guard previous.reply == "The pricing sheet." && current.tasks.isEmpty else { throw Invalid.stream }
                    drain(); frontend.calls = 0
                }
                if mode == "refused" {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_frontend_receipt BEFORE INSERT ON task BEGIN SELECT RAISE(ABORT,'owned refusal'); END") }
                }
                let turn = await input(raw)
                // Retain the actual admitted operation BEFORE any stream/entry
                // qualification can throw. The callback is not its lifetime owner.
                if let admittedRow = current.tasks.first, let admittedID = UUID(uuidString: admittedRow.id),
                   let admittedCapture = conversation.captureVoiceWorkerForTesting(id: admittedID) {
                    captured = admittedCapture
                    if let operation = admittedCapture.task { owned = operation }
                }
                guard frontend.calls == 1 else { throw Invalid.stream }
                // Yield only to the SAME admitted worker, never manufacture an owner.
                if !current.tasks.isEmpty {
                    if release == nil { await withCheckedContinuation { enteredWait = $0 } }
                    guard release != nil, captured?.task != nil else { throw Invalid.capture }
                }
                drain()
                let row = current.tasks.first
                let rejectedObjective = ["omitted", "url", "number", "negation"].contains(mode)
                let expectedObjective = rejectedObjective ? raw : proposed
                let expectedAck = mode == "filler" || mode == "identifier" || rejectedObjective ? ReceiptAck.fallback : ack
                let refused = mode == "refused"
                if mode == "number" {
                    check(!ObjectiveFidelity.accepts("Email Ann at 8", userWords: "Email Ann at 7"),
                          "F08 exact short numeric source token was omitted by the producer")
                } else if mode == "negation" {
                    check(!ObjectiveFidelity.accepts("Email Ann links", userWords: "Email Ann, no links"),
                          "F08 exact short negation source token was omitted by the producer")
                }
                check(frontend.calls == 1, "C01 same invocation used one actual frontend control stream (\(mode))")
                check(refused ? row == nil : current.tasks.count == 1, "F01 typed spawn admission absent or duplicated (\(mode))")
                check(refused ? turn.reply == "I couldn't save that task, so I haven't started it." : turn.reply == expectedAck,
                      "F02 receipt-first guarded acknowledgement mismatch (\(mode))")
                check(refused || row?.objective == expectedObjective, "F03 accepted objective omitted or added unsafe source meaning (\(mode))")
                check(refused || row?.userWords == raw, "F04 exact user words missing from SAME canonical row (\(mode))")
                let instruction = expectedObjective == raw ? raw : expectedObjective + "\n(The person's exact words: " + raw + ")"
                check(refused || (workerText == expectedObjective && captured?.work.prompt == instruction),
                      "F05 actual worker lost exact objective or raw words in its prompt (\(mode))")
                check(refused ? workerCalls == 0 : (workerCalls == 1 && captured?.id.uuidString == row?.id
                    && captured?.work.original == workerText && captured?.task == owned),
                    "F06 same actual Manager worker/Task receipt ownership mismatch (\(mode))")
                let currentOrigin: Bool
                if case .voice(let ownedSession, let ownedTurn)? = row?.origin {
                    currentOrigin = ownedSession == session && ownedTurn.raw > 0
                } else { currentOrigin = false }
                check(refused || currentOrigin, "F07 actual current positive turn origin missing (\(mode))")
                release?.resume(returning: "The owned itinerary result."); release = nil
                if let owned { await owned.value }; owned = nil
                check(current.tasks.allSatisfy { current.voiceWorkerSnapshot(id: UUID(uuidString: $0.id)!) == nil },
                    "C02 SAME terminal worker retained after actual return (\(mode))")
                print("FRONTEND_RECEIPT_CASE mode=\(mode) checks=\(checks-start) streamCalls=\(frontend.calls) workers=\(workerCalls) rows=\(current.tasks.count) physical=false")
                await capture.endSession(source: .done); sessionOwned = false
                conversation.resetForTesting(); manager = nil; drain()
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C03 owner state/default invariant")
        } catch {
            failures.append("frontend receipt: INVALID \(error)")
            if let manager { for row in manager.tasks { if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) } } }
            release?.resume(returning: ""); release = nil
            if let owned { await owned.value }
            if sessionOwned { await capture.endSession(source: .done) }
        }
        return (checks, failures)
    }
}
