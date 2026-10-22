import Foundation

/// Actual RTA intake -> frontend control -> same capture close and retained Manager Task.
/// Only the external frontend chunks and held work result are substituted.
@MainActor
enum NotAddressedProductionSelfTest {
    private enum Invalid: Error { case scope, intake, capture, worker }
    @MainActor private final class Probe {
        var output = "<not_addressed/>"
        var calls = 0
        func stream() -> AsyncThrowingStream<String, Error> {
            calls += 1
            let value = output
            return AsyncThrowingStream { continuation in
                let split = value.index(value.startIndex, offsetBy: value.count / 2)
                continuation.yield(String(value[..<split])); continuation.yield(String(value[split...]))
                continuation.finish()
            }
        }
    }
    static func run() async -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-turn-routing",
              AgentSession.shared.fileURL == nil, !AgentCaptureController.shared.isSessionActive,
              !VoiceConversationCoordinator.shared.hasActiveWork,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            return (0, ["side-talk: INVALID diagnostic scope"])
        }
        let c = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        let session = AgentSession.shared, playback = VoicePlaybackDelivery.shared
        let synth = AgentSpeechSynthesizer.shared, recording = RecordingSpeechBacking()
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["side-talk: INVALID temp scope"]) }
        let oldBridge = c.taskBridgeOverrideForTesting, oldRemember = c.rememberExplicit
        let oldReview = session.onReviewRequest, oldOutput = playback.installedOutputForTesting
        let owner = SelfTestStoreGuard.take()
        var created = false, rootJoined = false, captureOwned = false, cleaning = false
        var manager: AgentTaskManager?, owned: Task<Void, Never>?
        var release: CheckedContinuation<String, Never>?, entered: CheckedContinuation<Void, Never>?
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("side-talk: " + label) } }
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
            manager?.completionDeliveryForTesting = nil
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(oldBridge)
            c.rememberExplicit = oldRemember; session.onReviewRequest = oldReview
            _ = playback.installOutputForTesting(oldOutput); synth.restoreSystemBacking()
            if created && rootJoined { try? FileManager.default.removeItem(at: root) }
        }
        // Same value-level timing inputs characterize the prescribed policy only.
        let at = Date(timeIntervalSince1970: 1000)
        var policy = NotAddressedPolicy()
        policy.open(origin: .wake, at: at)
        check(!policy.closeDue(now: at.addingTimeInterval(61)), "P01 wake silence alone does not side-talk-close")
        policy.note(.notAddressed, at: at)
        check(!policy.closeDue(now: at.addingTimeInterval(59)) && policy.closeDue(now: at.addingTimeInterval(60)), "P02 exact wake60 boundary")
        policy.note(.other, at: at.addingTimeInterval(60))
        check(policy.consecutive == 1 && policy.sinceAddressed == 1, "P03 uncertain turn cannot erase retained side-talk")
        policy.note(.addressed, at: at.addingTimeInterval(60))
        check(!policy.closeDue(now: at.addingTimeInterval(121)) && policy.consecutive == 0, "P04 addressed resets both counts/window")
        policy.open(origin: .shortcut, at: at); policy.note(.notAddressed, at: at)
        check(!policy.closeDue(now: at.addingTimeInterval(61)), "P05 shortcut excludes wake60")
        policy.note(.notAddressed, at: at)
        check(policy.closeDue(now: at), "P06 every origin closes on two consecutive decisions")
        policy.open(origin: .other, at: at)
        check(policy.consecutive == 0 && !policy.closeDue(now: at.addingTimeInterval(61)), "P07 explicit open resets")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            synth.useTestingBacking(recording)
            for mode in ["alias", "typed", "review", "reset", "held"] {
                let beforeChecks = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.scope }
                let current = AgentTaskManager(store: store), bridge = TaskBridge(manager: current); manager = current
                guard let output = OutputScheduler.isolatedForTesting(bridge) else { throw Invalid.scope }
                output.setPhraseForTesting { _ in nil }
                c.resetForTesting(); session.forgetAllConversations()
                guard c.installTaskBridgeForTesting(bridge), playback.installOutputForTesting(output) else { throw Invalid.scope }
                var remembers = 0, reviews = 0, workers = 0, completed = 0
                c.rememberExplicit = { _ in remembers += 1 }; c.prewarmObserverForTesting = {}
                session.onReviewRequest = { request in if request.reason == .turnInterval { reviews += 1 } }
                current.completionDeliveryForTesting = { id in completed += 1; _ = output.enqueueCompletion(id) }
                let probe = Probe()
                c.streamForTesting = { _, _ in await probe.stream() }
                c.workerForTesting = { _ in
                    workers += 1
                    if cleaning { return "" }
                    entered?.resume(); entered = nil
                    return await withCheckedContinuation { release = $0 }
                }
                output.setNowForTesting(Date())
                await capture.beginSession(captureAudio: false, origin: .shortcut); captureOwned = true
                guard let originalSession = capture.sessionID else { throw Invalid.capture }
                var actual: VoiceWorkerTestCapture?
                if mode == "held" {
                    probe.output = "<use_tools/>"
                    _ = await input("Arrange the itinerary for Monday.")
                    guard let row = current.tasks.first, let id = UUID(uuidString: row.id),
                          let retained = c.captureVoiceWorkerForTesting(id: id), let task = retained.task else { throw Invalid.worker }
                    actual = retained; owned = task // BEFORE any qualification await.
                    if release == nil { await withCheckedContinuation { entered = $0 } }
                    guard release != nil && workers == 1 else { throw Invalid.worker }
                    drain(); recording.reset(); remembers = 0; reviews = 0
                }
                probe.output = mode == "typed" ? try FrontendDecisionPayload(intent: "not_addressed").controlChunk() : "<not_addressed/>"
                let initialCalls = probe.calls, historyBefore = session.messages.map(\.id)
                let sideCount = mode == "review" ? AgentSessionBoundary.reviewEveryUserTurns : 2
                var silent = true, sideWords: [String] = []
                for number in 1...sideCount {
                    let words = "The two colleagues are discussing pricing with each other, round \(number)."
                    sideWords.append(words)
                    let turn = await input(words)
                    silent = silent && turn.reply.isEmpty && !turn.delegated
                    drain()
                    if mode == "reset" && number == 1 {
                        probe.output = "<answer>Moonlight reaches the forest between the leaves.</answer>"
                        _ = await input("How does moonlight reach the forest floor?"); drain()
                        probe.output = "<not_addressed/>"
                    }
                }
                check(probe.calls == initialCalls + sideCount + (mode == "reset" ? 1 : 0), "C01 actual frontend intake/chunks (\(mode))")
                check(silent, "F01 actual side-talk returned speech or delegation (\(mode))")
                check(!session.messages.contains { $0.role == "user" && sideWords.contains($0.text) }, "F02 side-talk row reached retained history (\(mode))")
                check(remembers == (mode == "reset" && Settings.shared.agentMemoryEnabled ? 1 : 0) && reviews == 0,
                    "F03 side-talk reached explicit memory/interval admission (\(mode))")
                check(current.tasks.count == (mode == "held" ? 1 : 0) && workers == (mode == "held" ? 1 : 0), "C02 side-talk started another worker (\(mode))")
                check(mode == "reset" ? session.messages.contains { $0.role == "user" && $0.text == "How does moonlight reach the forest floor?" }
                    : historyBefore.allSatisfy { id in session.messages.contains { $0.id == id } }, "C03 independent/addressed history row lost (\(mode))")
                let closed = await capture.considerEndpoint()
                check(mode == "reset" ? !closed && capture.isSessionActive : closed && !capture.isSessionActive && capture.lastEndpoint == .notAddressed,
                    "F04 actual capture endpoint/count policy mismatch (\(mode))")
                if mode == "reset" {
                    check(c.notAddressed.consecutive == 1 && c.lastRouteForTesting == "notAddressed", "F05 addressed did not reset current side-talk count")
                } else {
                    let quietLine: Bool
                    if case .agentReply(let line) = IslandState.shared.kind { quietLine = line == "Going quiet." } else { quietLine = false }
                    check(quietLine && !synth.isSpeaking && !recording.isSpeaking, "F05 closing line absent or spoken (\(mode))")
                }
                if let actual, let task = owned {
                    check(!task.isCancelled && current.voiceWorkerSnapshot(id: actual.id)?.task == task
                        && current.task(id: actual.id.uuidString)?.status == .running, "C04 close lost SAME held background Task")
                    if capture.isSessionActive { await capture.endSession(source: .done) }
                    captureOwned = false
                    release?.resume(returning: "The owned itinerary is ready."); release = nil
                    await task.value; owned = nil
                    let ended = try sql.load().first { $0.id == actual.id.uuidString }
                    check(ended?.status == .completed && ended?.result == "The owned itinerary is ready." && ended?.delivery == .pending
                        && completed == 1 && output.pendingCount == 1 && current.voiceWorkerSnapshot(id: actual.id) == nil,
                        "C05 actual completion after close lost primary/SAME queue/released worker")
                    output.setNowForTesting(Date())
                    await capture.beginSession(captureAudio: false, origin: .shortcut); captureOwned = true
                    check(capture.sessionID != originalSession && c.notAddressed.consecutive == 0, "C06 next session did not reset/reuse retained result")
                    output.setNowForTesting(Date().addingTimeInterval(2))
                    let flushed = await output.flushAndJoinForTesting(userHasFloor: false)
                    let pendingPhrase = output.ownedPhraseTaskForTesting
                    print("SIDETALK_RESULT_AUDIO_METADATA stage=beforeDrain flushed=\(flushed) phrasePending=\(pendingPhrase != nil) primaryDelivering=\(current.task(id: actual.id.uuidString)?.delivery == .delivering) primaryPending=\(current.task(id: actual.id.uuidString)?.delivery == .pending) spokenCount=\(recording.spoken.count) activeClause=\(synth.voiceLifecycleSnapshot.hasClause) queuedClauses=\(synth.pendingClauseCount) activeOutput=\(output.activeOutputID != nil)")
                    drain()
                    print("SIDETALK_RESULT_AUDIO_METADATA stage=afterDrain phrasePending=\(output.ownedPhraseTaskForTesting != nil) primaryDelivered=\(current.task(id: actual.id.uuidString)?.delivery == .delivered) spokenCount=\(recording.spoken.count) fullAuthoredFactsPresent=\(recording.spoken.contains { $0.contains("The owned itinerary is ready.") }) activeClause=\(synth.voiceLifecycleSnapshot.hasClause) queuedClauses=\(synth.pendingClauseCount)")
                    check(flushed && recording.spoken.contains { $0.contains("The owned itinerary is ready.") }
                        && current.task(id: actual.id.uuidString)?.delivery == .delivered, "C07 SAME queue/audio receipts lost carried result")
                }
                print("NOT_ADDRESSED_CASE mode=\(mode) checks=\(checks-beforeChecks) frontendCalls=\(probe.calls) sideTurns=\(sideCount) workers=\(workers) intervalReviews=\(reviews) remembers=\(remembers) physical=false")
                current.completionDeliveryForTesting = nil
                if capture.isSessionActive { await capture.endSession(source: .done) }; captureOwned = false
                c.resetForTesting(); _ = playback.installOutputForTesting(oldOutput); output.setNowForTesting(nil)
                manager = nil; drain(); recording.reset()
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C08 owner state/default invariant")
            rootJoined = true
        } catch {
            failures.append("side-talk: INVALID \(error)"); cleaning = true
            var joins: [Task<Void, Never>] = []
            if let owned { joins.append(owned) }
            if let manager {
                for row in manager.tasks {
                    if let id = UUID(uuidString: row.id), let task = manager.voiceWorkerSnapshot(id: id)?.task,
                       !joins.contains(where: { $0 == task }) { joins.append(task) }
                }
                for row in manager.tasks { if let id = UUID(uuidString: row.id) { _ = c.cancel(id) } }
            }
            release?.resume(returning: ""); release = nil
            for task in joins { await task.value }
            rootJoined = manager?.tasks.allSatisfy { row in
                guard let id = UUID(uuidString: row.id) else { return false }
                return manager?.voiceWorkerSnapshot(id: id)?.task == nil
            } ?? true
            manager?.completionDeliveryForTesting = nil
            if captureOwned { await capture.endSession(source: .done) }
        }
        return (checks, failures)
    }
}
