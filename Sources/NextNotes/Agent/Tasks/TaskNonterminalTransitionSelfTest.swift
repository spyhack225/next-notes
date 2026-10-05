import Foundation

/// A genuine admitted worker and question exercise the existing update/recorder.
/// Core edge probes supplement the malformed external completion callback; they
/// do not claim production delegated/finalizing/cancelling phase coverage.
@MainActor
enum TaskNonterminalTransitionSelfTest {
    private enum Invalid: Error { case isolation, worker, primary }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let until = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < until { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared; let capture = AgentCaptureController.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            return (0, ["nonterminal transition: INVALID isolation"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.deletingLastPathComponent().path == temp.path,
              root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: root.path) else {
            return (0, ["nonterminal transition: INVALID root"])
        }
        let oldBridge = c.taskBridgeOverrideForTesting; let oldRemember = c.rememberExplicit
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        var dictionaryInstalled = false, capabilityInstalled = false
        let owner = SelfTestStoreGuard.take()
        var checks = 0; var failures: [String] = []; var created = false; var drained = false; var sessionOwned = false
        var retained: [Task<Void, Never>] = []
        var operation: Task<Void, Never>?; var state: NonterminalTransitionProbe?
        var activeManager: AgentTaskManager?; var activeID: UUID?
        func check(_ ok: Bool, _ label: String) { checks += 1; if !ok { failures.append("nonterminal transition: " + label) } }
        defer {
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(oldBridge); c.rememberExplicit = oldRemember
            if capabilityInstalled { VoiceCapabilitySnapshot.finishContextForTesting(root: root) }
            if dictionaryInstalled { DictionaryStore.finishRootForTesting(root) }
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            if created && drained { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = nil
            for mode in ["running-queued", "running-recovering", "input-queued", "input-completed", "input-permission", "callback-input-completed", "same-running", "actual-input-resume", "actual-cancel"] {
                drained = false
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.isolation }
                let artifact = directory.appendingPathComponent("owned-artifact.txt")
                try Data("Authored artifact boundary bytes".utf8).write(to: artifact)
                let manager = AgentTaskManager(store: store); let bridge = TaskBridge(manager: manager)
                activeManager = manager; activeID = nil; operation = nil; retained = []
                if !dictionaryInstalled {
                    guard DictionaryStore.installRootForTesting(root, bridge: bridge) else { throw Invalid.isolation }
                    dictionaryInstalled = true
                    // Bind the actual singleton while its admitted URL is still live.
                    _ = DictionaryStore.shared.entries
                    guard DictionaryStore.capturedRootMatchesForTesting(root) == true else { throw Invalid.isolation }
                }
                guard VoiceCapabilitySnapshot.installContextForTesting(root: root, bridge: bridge,
                    inputs: RealtimeAgentToolLoopSelfTest.allEnabledFixture()) else { throw Invalid.isolation }
                capabilityInstalled = true
                c.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard c.installTaskBridgeForTesting(bridge) else { throw Invalid.isolation }
                await capture.beginSession(captureAudio: false); sessionOwned = true
                guard let session = capture.sessionID else { throw Invalid.isolation }
                let probe = NonterminalTransitionProbe(); state = probe
                c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}
                c.workerForTesting = { work in
                    if mode == "callback-input-completed" {
                        // Existing producer capture of a real authored fixture file;
                        // this supplies artifact metadata, not a backing/effect receipt.
                        AgentArtifactLedger.capture(taskID: work.id.uuidString, artifact: artifact.path)
                    }
                    return await probe.run()
                }
                c.streamForTesting = { _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("<use_tools/>"); continuation.finish()
                    }
                }
                var announcements: [String] = []
                manager.announcementForTesting = { announcements.append($0) }
                RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
                let reply = await RealtimeAgent.shared.handle("Inspect the owned transition document for " + mode + ".", source: .voice)
                retained = bridge.cachedTasks.compactMap { row in
                    UUID(uuidString: row.id).flatMap { manager.voiceWorkerSnapshot(id: $0)?.task }
                }
                guard let row = bridge.cachedTasks.first, let id = UUID(uuidString: row.id),
                      let captured = c.captureVoiceWorkerForTesting(id: id), let task = captured.task else { throw Invalid.worker }
                operation = task; activeID = id
                guard await reached({ probe.entered == 1 }) else { throw Invalid.worker }
                let originSession: UUID? = if case .voice(let value, _)? = row.origin { value } else { nil }
                check(reply.reply == "I'm on it." && row.status == .running && row.hasVoiceOrigin && originSession == session
                    && manager.voiceOwnedOperationForTesting(id: id) == task && captured.bridge === bridge,
                    "C01 actual admitted SAME worker did not qualify (\(mode))")
                let inputMode = mode.hasPrefix("input-") || mode == "callback-input-completed" || mode == "actual-input-resume"
                if inputMode {
                    probe.question = true; probe.released = true
                    await task.value; operation = nil
                    guard let request = bridge.voiceInputRequest(TaskID(id)), request.question == NonterminalTransitionProbe.questionText,
                          request.taskID == id.uuidString, manager.voiceWorkerSnapshot(id: id)?.task == nil else { throw Invalid.primary }
                }
                guard let before = manager.task(id: id.uuidString),
                      let authority = try sql.probeAuthority(includeJournal: true) else { throw Invalid.primary }
                let export = try Data(contentsOf: store.storageURL); let priorAnnouncements = announcements
                let artifactBefore = AgentArtifactLedger.peekRecords(taskID: id.uuidString)
                if mode == "callback-input-completed" {
                    let artifactBytes = try Data(contentsOf: artifact)
                    check(artifactBefore.map(\.value) == [artifact.path] && before.artifactRecords.isEmpty
                        && artifactBytes == Data("Authored artifact boundary bytes".utf8),
                        "C05 existing bound artifact capture did not qualify")
                }
                let invalid = !["same-running", "actual-input-resume", "actual-cancel"].contains(mode)
                var admitted: Bool?
                switch mode {
                case "running-queued", "input-queued": admitted = manager.transitionForTesting(id: id, status: .queued)
                case "running-recovering": admitted = manager.transitionForTesting(id: id, status: .recovering)
                case "input-completed": admitted = manager.transitionForTesting(id: id, status: .completed)
                case "input-permission": admitted = manager.transitionForTesting(id: id, status: .waitingForPermission)
                case "callback-input-completed":
                    // Actual production recorder with a mismatched external callback ID.
                    // It must not finish another owner's genuine unanswered question.
                    LiveScheduledRunRecorder(taskManager: manager).finish(taskID: id.uuidString,
                        status: .completed, result: "Not an answer to the pending question", failure: nil)
                    admitted = manager.task(id: id.uuidString)?.status == .completed
                case "same-running": admitted = manager.transitionForTesting(id: id, status: .running)
                case "actual-input-resume":
                    guard let request = bridge.voiceInputRequest(TaskID(id)) else { throw Invalid.primary }
                    probe.released = false; probe.question = false
                    admitted = bridge.resumeVoiceObjective(id: id, requestID: request.id,
                        answer: "Use the authored transition document.", sessionID: session)
                    operation = manager.voiceWorkerSnapshot(id: id)?.task
                    if let operation, !retained.contains(operation) { retained.append(operation) }
                    guard operation != nil, await reached({ probe.entered == 2 }) else { throw Invalid.worker }
                case "actual-cancel": admitted = manager.cancelVoiceWorker(id: id)
                default: throw Invalid.primary
                }
                let after = try sql.probeAuthority(includeJournal: true)
                let exportAfter = try Data(contentsOf: store.storageURL)
                if invalid {
                    check(admitted == false && manager.task(id: id.uuidString) == before
                        && after?.tasks == authority.tasks && announcements == priorAnnouncements,
                        "F01 illegal nonterminal transition was admitted (\(mode))")
                    check(after?.authority == authority.authority && after?.identity == authority.identity
                        && after?.events == authority.events && exportAfter == export,
                        "F02 refused transition changed primary generation/events/export (\(mode))")
                    if mode == "callback-input-completed" {
                        check(AgentArtifactLedger.peekRecords(taskID: id.uuidString) == artifactBefore
                            && manager.task(id: id.uuidString)?.artifactRecords == before.artifactRecords,
                            "F03 refused recorder consumed/folded artifacts after admission refusal")
                    }
                } else {
                    let expected: AgentTaskStatus = mode == "actual-cancel" ? .cancelled : .running
                    check(admitted == true && manager.task(id: id.uuidString)?.status == expected
                        && after?.tasks.first(where: { $0.id == id.uuidString })?.status == expected,
                        "C02 genuine metadata/resume/cancellation route was refused (\(mode))")
                    check(mode != "actual-input-resume" || (manager.voiceWorkerSnapshot(id: id)?.work === captured.work
                        && manager.voiceWorkerSnapshot(id: id)?.worker === captured.worker
                        && manager.task(id: id.uuidString)?.pendingInteraction == nil),
                        "C03 admitted answer replaced SAME work/worker or retained old question")
                }
                // Cancel exact retained operation independently of the deliberately
                // malformed original status, then release/join before owner-root cleanup.
                operation?.cancel(); _ = manager.cancelVoiceWorker(id: id); probe.released = true
                for retainedTask in retained { await retainedTask.value }
                operation = nil; retained = []; drained = true
                check(manager.voiceWorkerSnapshot(id: id) == nil && probe.returned == probe.entered,
                    "C04 SAME operation did not return/release (\(mode))")
                _ = AgentArtifactLedger.takeRecords(taskID: id.uuidString)
                manager.announcementForTesting = nil
                await capture.endSession(source: .done); sessionOwned = false
                VoiceCapabilitySnapshot.finishContextForTesting(root: root); capabilityInstalled = false
                c.resetForTesting(); activeManager = nil; activeID = nil; state = nil
            }
            guard SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty else { throw Invalid.isolation }
        } catch {
            for retainedTask in retained { retainedTask.cancel() }
            if let activeID { _ = activeManager?.cancelVoiceWorker(id: activeID) }
            else if let activeManager {
                for row in activeManager.tasks {
                    if let id = UUID(uuidString: row.id) { _ = activeManager.cancelVoiceWorker(id: id) }
                }
            }
            state?.released = true
            for retainedTask in retained { await retainedTask.value }
            if let activeID { _ = AgentArtifactLedger.takeRecords(taskID: activeID.uuidString) }
            if !retained.isEmpty { drained = true }
            if sessionOwned { await capture.endSession(source: .done); sessionOwned = false }
            failures.append("nonterminal transition: INVALID \(error)")
        }
        return (checks, failures)
    }
}

@MainActor
private final class NonterminalTransitionProbe {
    static let questionText = "Which owned transition document should I inspect?"
    var entered = 0; var returned = 0; var released = false; var question = false
    func run() async -> String {
        entered += 1
        while !released { await Task.yield() }
        returned += 1
        return question ? Self.questionText : "The owned transition document is ready."
    }
}
