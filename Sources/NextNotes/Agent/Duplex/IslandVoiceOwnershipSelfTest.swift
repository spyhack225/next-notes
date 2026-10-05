import AppKit
import Foundation

/// Actual RTA admission -> SAME retained Manager workers -> real confined reads/Gate
/// -> existing Island consumer, plus current backend onset. No effect is approved.
@MainActor enum IslandVoiceOwnershipSelfTest {
    private enum Invalid: Error { case root, owner, context, worker, proposal }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < end { if await predicate() { return true }; await Task.yield() }
        return await predicate()
    }
    private static func drain(_ synth: AgentSpeechSynthesizer, _ backing: RecordingSpeechBacking) {
        var bound = 32
        while (synth.voiceLifecycleSnapshot.hasClause || synth.pendingClauseCount > 0) && bound > 0 {
            synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
            backing.finishNaturallyForTesting()
            synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
            bound -= 1
        }
    }
    static func run() async -> [String] {
        let c = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        let synth = AgentSpeechSynthesizer.shared, gate = PermissionGate.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-island",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive, !c.hasActiveWork,
              ActivationController.shared.mode == .idle,
              !RealtimeAudioSession.shared.isSpeaking, !synth.isSpeaking,
              !synth.voiceLifecycleSnapshot.hasClause, synth.pendingClauseCount == 0,
              gate.pending == nil, gate.queuedCount == 0,
              VoiceSession.shared.state.phase == .closed, !DictionaryStore.hasRootAdmissionForTesting,
              IslandState.sharedIfLoaded == nil else {
            return ["island ownership: INPUT_INVALID foreign owner"]
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return ["island ownership: INPUT_INVALID root"] }
        let previousBridge = c.taskBridgeOverrideForTesting
        let previousRemember = c.rememberExplicit
        let previousFake = AgentToolExecutor.fakeForTesting, previousFire = AgentToolExecutor.fireOverrideForTesting
        let previousPolicy = AgentToolExecutor.policyOverrideForTesting
        let previousWhole = PlannerBackends.wholeTurnOverrideForTesting
        let previousNeedle = ToolLoopLiveEval.needleFirstForTesting
        let previousInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let previousOutput = VoicePlaybackDelivery.shared.installedOutputForTesting
        let previousEngine = synth.engineOverrideForTesting
        let watcher = SelfTestStoreGuard.take(), grants = PermissionGrantStore.shared.grants
        var sql: TaskStore?, manager: AgentTaskManager?, bridge: TaskBridge?, queue: OutputScheduler?
        var workers: [Task<Void, Never>] = [], foreground: Task<AgentTurn, Never>?
        var phraseTasks: [Task<Void, Never>] = [], phraseObserverInstalled = false
        var recordedBacking: RecordingSpeechBacking?
        func joinPhraseTasks() async {
            var index = 0
            while index < phraseTasks.count { let task = phraseTasks[index]; index += 1; await task.value }
            phraseTasks.removeAll()
        }
        var typedOperation: Task<AgentTurn, Never>?, typedProbe: IslandTypedPlanner?
        var scheduledJoined = true
        var acpOperation: Task<Void, Never>?, acpID: UUID?, acpRelease: URL?
        let oldAvailability = AgentHarnessRouter.shared.availabilityProbe
        let oldACPActivity = ACPAgentBackend.activityHandledForTesting
        let activityObservation = IslandACPObservation()
        var probe: IslandOwnershipPlanner?, front: IslandOwnershipFrontend?
        var joined = false, created = false, dictionary = false, context = false, activity = false, review = false
        var islandContext = false, meetingRoot: URL?, sharedIsland: IslandState?
        var requestID: String?, rejectedContext = false, reads: [String] = [], fires = 0
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures.append("island ownership: " + name) } }
        func retainWorkers() {
            guard let bridge else { return }
            for row in bridge.cachedTasks {
                if let id = UUID(uuidString: row.id), let task = c.captureVoiceWorkerForTesting(id: id)?.task,
                   !workers.contains(task) { workers.append(task) }
            }
        }
        defer {
            if joined {
                if phraseObserverInstalled { _ = queue?.observePhraseTaskForTesting(nil) }
                queue?.setPhraseForTesting(nil)
                c.resetForTesting(); _ = c.installTaskBridgeForTesting(previousBridge)
                _ = VoicePlaybackDelivery.shared.installOutputForTesting(previousOutput)
                if let requestID { ToolCallReviewStore.shared.remove(id: requestID) }
                if activity { NextMemory.finishActivityContextForTesting(root: root) }
                if context { VoiceCapabilitySnapshot.finishContextForTesting(root: root) }
                if dictionary { DictionaryStore.finishRootForTesting(root) }
                sql?.close()
                if created && !review && !islandContext { try? FileManager.default.removeItem(at: root) }
                if !islandContext, let meetingRoot { try? FileManager.default.removeItem(at: meetingRoot) }
                synth.restoreSystemBacking(); synth.engineOverrideForTesting = previousEngine
            }
            AgentHarnessRouter.shared.availabilityProbe = oldAvailability
            ACPAgentBackend.activityHandledForTesting = oldACPActivity
            manager?.voiceACPArgumentsForTesting = nil
            c.rememberExplicit = previousRemember
            AgentToolExecutor.fakeForTesting = previousFake; AgentToolExecutor.fireOverrideForTesting = previousFire
            AgentToolExecutor.policyOverrideForTesting = previousPolicy
            PlannerBackends.wholeTurnOverrideForTesting = previousWhole; ToolLoopLiveEval.needleFirstForTesting = previousNeedle
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = previousInputs
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
            try Data(IslandOwnershipPlanner.contents.utf8).write(to: first)
            try Data(IslandOwnershipPlanner.contents.utf8).write(to: second)
            let primary = TaskStore(root: root); sql = primary
            let store = AgentTaskStore(fileURL: root.appendingPathComponent("agent-tasks.json"), mirror: primary)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.owner }
            let receipts = ActionReceiptStore(fileURL: root.appendingPathComponent("action-receipts.json"))
            let current = AgentTaskManager(store: store, receiptStore: receipts); manager = current
            let supplied = TaskBridge(manager: current); bridge = supplied
            guard c.installTaskBridgeForTesting(supplied),
                  let output = OutputScheduler.isolatedForTesting(supplied),
                  VoicePlaybackDelivery.shared.installOutputForTesting(output) else { throw Invalid.owner }
            queue = output
            // NONNIL confined phraser uses saved fallback words, never the owner model.
            output.setPhraseForTesting { _ in nil }
            guard output.observePhraseTaskForTesting({ entered in
                if !phraseTasks.contains(entered) { phraseTasks.append(entered) }
            }) else { throw Invalid.context }
            phraseObserverInstalled = true
            guard DictionaryStore.installRootForTesting(root, bridge: supplied) else { throw Invalid.context }
            dictionary = true; _ = DictionaryStore.shared.entries
            guard DictionaryStore.capturedRootMatchesForTesting(root) == true,
                  VoiceCapabilitySnapshot.installContextForTesting(root: root, bridge: supplied,
                    inputs: RealtimeAgentToolLoopSelfTest.allEnabledFixture()) else { throw Invalid.context }
            context = true
            let meetingsURL = temp.appendingPathComponent("NextNotesMeetingResumeTest-" + root.lastPathComponent, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: meetingsURL.path) else { throw Invalid.root }
            let meetings = try MeetingStore.isolated(at: meetingsURL); meetingRoot = meetingsURL
            guard IslandState.installSharedContextForTesting(root: root, bridge: supplied, store: meetings) else { throw Invalid.context }
            islandContext = true
            let island = IslandState.shared; sharedIsland = island
            guard IslandState.sharedContextMatchesForTesting(root: root, bridge: supplied) else { throw Invalid.context }
            check(!IslandState.installSharedContextForTesting(root: root, bridge: supplied, store: meetings)
                    && IslandState.shared === island && IslandState.sharedContextMatchesForTesting(root: root, bridge: supplied),
                "C09 late installation refuses without rebinding SAME confined Island")
            guard NextMemory.installActivityContextForTesting(root: root, bridge: supplied) else { throw Invalid.context }
            activity = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                guard meeting == nil, let task, ["voice", "text", "scheduled"].contains(current.task(id: task)?.source ?? ""),
                      VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: root, bridge: supplied) else {
                    rejectedContext = true; return nil
                }
                return ToolCallContext()
            }, root: root) else { throw Invalid.context }
            review = true
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = nil
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = PermissionPolicy(autoObserve: true, autoRead: true,
                autoSearchFiles: true, autoComputerControl: false, grants: [])
            let planned = IslandOwnershipPlanner(first: first.path, second: second.path); probe = planned
            let frontend = IslandOwnershipFrontend(); front = frontend
            c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}; c.workerForTesting = nil
            c.workerProviderForTesting = IslandOwnershipProvider(probe: planned)
            c.streamForTesting = { _, messages in frontend.stream(messages) }
            // The real confined read reaches Executor activity/Island publication.
            // A refusing write override is installed only after both actual read rounds
            // are held, before the first key proposal can enter its backing boundary.
            AgentToolExecutor.fireOverrideForTesting = nil
            let recording = RecordingSpeechBacking(); recordedBacking = recording; synth.useTestingBacking(recording)
            IslandOwnership.resetCountersForTesting()
            await capture.beginSession(captureAudio: false)
            guard let session = capture.sessionID else { throw Invalid.owner }
            check(VoiceSession.shared.state.phase == .open && island.voiceProjection == .listening
                    && island.voiceProjectionSessionID == session && island.avatarState == .listening,
                "F01 actual sessionOpened publishes matching listening consumer")
            for file in [first, second] {
                let request = "Read the owned document at " + file.path + (file == first ? " and press escape after checking it." : " and report what it says.")
                RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
                _ = await RealtimeAgent.shared.handle(request, source: .voice)
                retainWorkers() // BEFORE any held/read/grammar qualification.
                drain(synth, recording)
            }
            guard workers.count == 2, await reached({ retainWorkers(); return await planned.heldCount == 2 }) else { throw Invalid.worker }
            guard let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.worker }
            let authored = "Read the owned document at " + first.path + " and press escape after checking it."
            let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: authored)
            guard manifest.allowedIDs.contains("filesystem.read"), manifest.allowedIDs.contains("computer.press_key"),
                  LlamaGrammarPlanner.grammar(for: manifest).matches(try IslandOwnershipPlanner.readCall(first.path)),
                  LlamaGrammarPlanner.grammar(for: manifest).matches(IslandOwnershipPlanner.keyCall) else { throw Invalid.proposal }
            check(supplied.cachedTasks.count == 2 && workers.allSatisfy { !$0.isCancelled } && reads.isEmpty && fires == 0,
                "C01 two actual Manager-owned planners held before confined backing")
            check(island.sessionTaskIndicator?.count == 2 && island.sessionTaskIndicator?.label == "2 things in progress",
                "F02 canonical current-session multiple-task still indicator")
            // Same current positive input producer: a partial is drawn without a direct legacy write.
            capture.simulateSpeech("Still listening to the owned turn.", level: 0.25)
            check(capture.transcript == "Still listening to the owned turn." && capture.level == 0.25,
                "C03 real Capture feed preserves reducer projection and exact input")
            // Actual named ACP intake and retained Manager operation. The owned
            // protocol peer can only publish authored activity and return a reply.
            let acpRoot = root.appendingPathComponent("acp", isDirectory: true)
            try FileManager.default.createDirectory(at: acpRoot, withIntermediateDirectories: false)
            let acpScript = try IslandACPObservation.writePeer(root: acpRoot)
            acpRelease = acpRoot.appendingPathComponent("release.json")
            current.voiceACPArgumentsForTesting = { _ in ["acpFixture": acpScript.path] }
            AgentHarnessRouter.shared.availabilityProbe = { _ in true }
            ACPAgentBackend.activityHandledForTesting = { task, admitted, _ in
                activityObservation.events.append((task, admitted))
            }
            let acpRaw = "Use Claude Code to inspect the owned fixture."
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            _ = await RealtimeAgent.shared.handle(acpRaw, source: .voice)
            guard let acpRow = supplied.cachedTasks.first(where: { $0.userWords == acpRaw }),
                  let ownedACP = UUID(uuidString: acpRow.id),
                  let operation = current.capturedACPVoiceTaskForTesting(id: acpRow.id) else { throw Invalid.worker }
            acpID = ownedACP; acpOperation = operation; joined = false
            guard await reached({ FileManager.default.fileExists(atPath: acpRoot.appendingPathComponent("ready.json").path) }) else { throw Invalid.worker }
            drain(synth, recording)
            check(acpRow.backend == "acp" && acpRow.origin != nil && !operation.isCancelled
                    && current.workerBinding(taskID: acpRow.id)?.attempt == 1,
                "BC01 actual named ACP peer uses SAME positive Manager operation")

            // Actual typed .text worker remains independent of the voice frontend.
            let typedFile = root.appendingPathComponent("typed.txt")
            try Data(IslandTypedPlanner.contents.utf8).write(to: typedFile)
            let typedWords = "Read the owned document at " + typedFile.path + " and report what it says."
            let typedWork = VoiceConversationWork(typedWords)
            let typedWorker = RealtimeAgent(typedWorker: typedWork)
            let typed = IslandTypedPlanner(path: typedFile.path); typedProbe = typed
            typedWorker.localModelProviderForTesting = IslandTypedProvider(probe: typed)
            typedWorker.rememberExplicit = { _ in }
            guard let typedTask = current.startTypedObjective(work: typedWork, worker: typedWorker,
                bridge: supplied, sessionID: AgentSession.shared.sessionID) else { throw Invalid.worker }
            typedOperation = typedTask; joined = false
            guard await reached({ await typed.initialHeld }) else { throw Invalid.worker }
            check(current.typedWorkerSnapshot(id: typedWork.id)?.task == typedTask
                    && current.task(id: typedWork.id.uuidString)?.source == "text"
                    && current.task(id: typedWork.id.uuidString)?.durability?.attempt == 1,
                "BC02 actual text planner owns SAME admitted typed Task")
            capture.simulateSilence()
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            foreground = Task { @MainActor in await RealtimeAgent.shared.handle(IslandOwnershipFrontend.request, source: .voice) }
            guard await reached({ frontend.held }) else { throw Invalid.worker }
            check(VoiceSession.shared.state.island == .thinking && island.voiceProjection == .thinking
                    && island.avatarState == .thinking && ActivationController.shared.mode == .agentWorking,
                "F03 real parked frontend owns Thinking character")
            let rejectedBefore = IslandOwnership.rejected.values.reduce(0, +)
            // Real ACP notification subscriber reaches the background Island writer.
            try Data("{\"release\":true}".utf8).write(to: acpRelease!, options: .atomic)
            guard await reached({ activityObservation.events.contains(where: { $0.0 == acpID!.uuidString && $0.1 == true }) }) else { throw Invalid.worker }
            check(island.voiceProjection == .thinking && island.avatarState == .thinking
                    && IslandOwnership.rejected.values.reduce(0, +) > rejectedBefore,
                "BF01 admitted ACP activity is refused at the real Island writer")
            guard c.cancel(acpID!) else { throw Invalid.worker }
            await acpOperation!.value; acpOperation = nil
            check(current.capturedACPVoiceTaskForTesting(id: acpID!.uuidString) == nil
                    && !activityObservation.events.isEmpty && fires == 0,
                "BC03 actual ACP operation and process returned before scope reset")
            AgentHarnessRouter.shared.availabilityProbe = oldAvailability
            ACPAgentBackend.activityHandledForTesting = oldACPActivity
            current.voiceACPArgumentsForTesting = nil

            let typedRejectedBefore = IslandOwnership.rejected.values.reduce(0, +)
            await typed.releaseInitial()
            guard await reached({ await typed.resultHeld }) else { throw Invalid.worker }
            check(await typed.readObserved && current.typedWorkerSnapshot(id: typedWork.id)?.task == typedTask,
                "BC04 actual typed read result reaches SAME held text planner")
            check(island.voiceProjection == .thinking && island.avatarState == .thinking
                    && IslandOwnership.rejected.values.reduce(0, +) > typedRejectedBefore,
                "BF02 actual typed tool publication cannot replace conversation")
            current.cancel(typedWork.id.uuidString)
            guard typedTask.isCancelled else { throw Invalid.worker }
            await typed.releaseAll(); await typedTask.value; typedOperation = nil
            check(current.typedWorkerSnapshot(id: typedWork.id) == nil && fires == 0,
                "BC05 cancelled typed operation returned without foreground takeover")

            // Actual Scheduler/Runner/retained per-run Task uses the same supplied
            // Manager and real read backing; no row or completion event is seeded.
            scheduledJoined = false
            try await TaskScheduledRunOwnerSelfTest.islandBackgroundCase(root: root,
                input: typedFile, manager: current, receipts: receipts, didDrain: { scheduledJoined = true }) { value, label in check(value, label) }
            await planned.releaseInitial()
            guard await reached({ retainWorkers(); let observed = await planned.readObservation; reads = observed.paths; return reads.count == 2 && observed.held == 2 }) else { throw Invalid.worker }
            check(reads.sorted() == [first.path, second.path].sorted() && fires == 0,
                "C02 both actual confined reads complete while foreground remains parked")
            check(island.voiceProjection == .thinking && island.avatarState == .thinking
                    && island.kind == .agentWorking(steps: [IslandState.conversationThinkingTitle], current: 1, total: 1),
                "F04 worker read title and global reading pose never replace conversation")
            check(IslandOwnership.workerAttemptTotal == 0,
                "F05 actual inherited worker Task attempts zero Island/Activation writes")
            AgentToolExecutor.fireOverrideForTesting = { _, _ in
                fires += 1; throw Invalid.proposal // No unconfined write backing can run.
            }
            await planned.releaseFirst()
            guard await reached({ gate.pending != nil }), let request = gate.pending,
                  let task = request.taskID, supplied.cachedTasks.contains(where: { $0.id == task }),
                  let approvedReview = ToolCallReviewStore.shared.review(id: request.id), approvedReview.isReadyToRun,
                  let keyID = UUID(uuidString: task), let keyTask = c.captureVoiceWorkerForTesting(id: keyID)?.task else { throw Invalid.proposal }
            requestID = request.id
            check(request.arguments["key"] == "escape" && fires == 0 && !rejectedContext,
                "C04 real reviewed planned key is held with no effect")
            check(island.kind == .agentProposal(gate.islandProposal(for: request)) && island.sessionTaskIndicator?.label == "Waiting for your OK",
                "F06 actual proposal outranks readout and canonical indicator names waiting approval")
            guard gate.respond(id: request.id, approved: false, via: .card) else { throw Invalid.proposal }
            await keyTask.value // Actual returned first worker before single-task chip qualification.
            // Return only the actual frontend stream, never an invented response event.
            frontend.finish()
            let answer = await foreground!.value; foreground = nil
            check(answer.reply == IslandOwnershipFrontend.answer && fires == 0 && PermissionGrantStore.shared.grants == grants,
                "C05 actual foreground reply and real card denial retain zero effects/grants")
            check(VoiceSession.shared.state.island != .speaking,
                "C06 queued backend answer alone is not speaking")
            guard synth.voiceLifecycleSnapshot.hasClause else { throw Invalid.worker }
            let token = synth.currentPlaybackToken
            synth.notifyTestingFirstAudio(token: token)
            check(VoiceSession.shared.state.island == .speaking && island.voiceProjection == .speaking
                    && island.kind == .agentListening(transcript: "", level: 0) && island.avatarState == .listening,
                "F07 actual current backend onset reaches speaking Island consumer")
            let currentProjection = island.voiceProjection
            synth.notifyTestingFirstAudio(token: token &- 1)
            check(island.voiceProjection == currentProjection, "C07 obsolete token cannot replace current speaking consumer")
            guard let secondRow = supplied.cachedTasks.first(where: { $0.userWords?.contains(second.path) == true }),
                  let secondID = UUID(uuidString: secondRow.id),
                  let secondTask = c.captureVoiceWorkerForTesting(id: secondID)?.task,
                  c.cancel(secondID) else { throw Invalid.worker }
            let heldAfterStop = await planned.afterReadCount
            check(secondTask.isCancelled && c.captureVoiceWorkerForTesting(id: secondID)?.task == secondTask
                    && supplied.voiceControlObservation(secondID) == .cancelled && heldAfterStop == 1,
                "C11 actual stop request retains SAME held worker until return")
            check(island.sessionTaskIndicator == IslandTaskIndicator(label: "Stopping", count: 1)
                    && island.voiceProjection == .speaking && fires == 0,
                "F10 retained cancelled worker stays visible without stealing speaking character")
            drain(synth, recording)
            await capture.endSession(source: .done)
            check(VoiceSession.shared.state.phase == .closed && island.voiceProjection == nil
                    && island.sessionTaskIndicator == nil && !capture.isSessionActive,
                "F08 actual close releases projection and indicator before legacy closing notice")
            await planned.releaseAll()
            for task in workers { await task.value }
            workers.removeAll(); joined = scheduledJoined
            // Public closed-session/typed legacy scalar callers remain usable. These
            // are compatibility controls, not a fabricated worker completion event.
            island.dismissNotice(); ActivationController.shared.markWorking()
            island.showAgentWork(title: "Preparing the saved reply")
            check(island.kind == .agentWorking(steps: ["Preparing the saved reply"], current: 1, total: 1)
                    && ActivationController.shared.mode == .agentWorking,
                "C08 genuinely closed legacy work writers remain admitted")
            ActivationController.shared.finishAgent(); island.dismissNotice(); island.refresh()
            check(IslandOwnership.workerAttemptTotal == 0 && SelfTestStoreGuard.diff(watcher, SelfTestStoreGuard.take()).isEmpty,
                "F09 full actual worker drain leaves zero attempted writes and owner writes unchanged")
        } catch {
            failures.append("island ownership: INPUT_INVALID \(error)")
            retainWorkers() // capture fallback before cancellation/reset.
            if acpOperation == nil, let manager,
               let row = manager.tasks.first(where: { $0.backend == "acp" && $0.source == "voice" }) {
                acpID = UUID(uuidString: row.id)
                acpOperation = manager.capturedACPVoiceTaskForTesting(id: row.id)
            }
            if let bridge { for row in bridge.cachedTasks { if let id = UUID(uuidString: row.id) { _ = c.cancel(id) } } }
            if let acpID { _ = c.cancel(acpID) }
            acpOperation?.cancel()
            if let acpRelease { try? Data("{\"release\":true}".utf8).write(to: acpRelease, options: .atomic) }
            typedOperation?.cancel(); await typedProbe?.releaseAll()
            await typedOperation?.value; typedOperation = nil
            await acpOperation?.value; acpOperation = nil
            foreground?.cancel(); front?.finish(); await probe?.releaseAll()
            RealtimeAgent.shared.cancel(); synth.stop()
            if capture.isSessionActive { await capture.endSession(source: .done) }
            await foreground?.value; foreground = nil
            for task in workers { await task.value }; workers.removeAll(); joined = scheduledJoined
        }
        if joined { await joinPhraseTasks() }
        // SAME authored scope survives original32 through actual Capture endpoint/RTA
        // and mounted panel consumption. The unmeasured close hypothesis is separate.
        if joined, let bridge, let sharedIsland, let recordedBacking {
            let endpoint = await endpointPanelFailures(root: root, bridge: bridge,
                island: sharedIsland, recording: recordedBacking)
            failures.append(contentsOf: endpoint.failures); joined = joined && endpoint.drained
        }
        if joined {
            await joinPhraseTasks()
            if phraseObserverInstalled, queue?.observePhraseTaskForTesting(nil) == true { phraseObserverInstalled = false }
            else if phraseObserverInstalled {
                joined = false
                failures.append("island ownership: INPUT_INVALID live panel phrase observer teardown")
            }
        }
        if joined && review {
            if ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) { review = false }
            else { failures.append("island ownership: INPUT_INVALID review context teardown") }
        }
        if joined && islandContext {
            if IslandState.finishSharedContextForTesting(root: root) {
                islandContext = false
                check(IslandState.shared === sharedIsland, "C10 scope removal retains SAME confined Island constructor")
            }
            else { failures.append("island ownership: INPUT_INVALID Island context teardown") }
        }
        SelfTest.diagnostic("ISLAND_VOICE_OWNERSHIP_CHECKS: \(checks)")
        return failures
    }

    /// Actual Capture tick/emitTurn -> retained Task -> RTA/Coordinator -> audio
    /// receipt -> SAME confined IslandView in a visible NSPanel. No handler bypass.
    private static func endpointPanelFailures(root: URL, bridge: TaskBridge, island: IslandState,
        recording: RecordingSpeechBacking) async -> (failures: [String], drained: Bool) {
        let capture = AgentCaptureController.shared, c = VoiceConversationCoordinator.shared
        let synth = AgentSpeechSynthesizer.shared, host = RealtimeAgent.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-island", IslandOwnership.isEnabled,
              bridge.permitsHarness, c.taskBridgeOverrideForTesting === bridge,
              IslandState.sharedContextMatchesForTesting(root: root, bridge: bridge),
              VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: root, bridge: bridge),
              DictionaryStore.capturedRootMatchesForTesting(root) == true,
              AgentSession.shared.fileURL == nil, capture.turnHandlerForTesting == nil,
              !capture.isSessionActive, !c.hasActiveWork, !host.isThinking,
              !RealtimeAudioSession.shared.isSpeaking, !synth.voiceLifecycleSnapshot.hasClause,
              synth.pendingClauseCount == 0, PermissionGate.shared.pending == nil,
              PermissionGate.shared.queuedCount == 0 else {
            return (["island ownership: INPUT_INVALID endpoint panel prior owner"], true)
        }
        guard !NSScreen.screens.isEmpty else {
            return (["island ownership: INPUT_INVALID endpoint panel ABSENT display"], true)
        }
        let oldStream = c.streamForTesting, oldPrewarm = c.prewarmObserverForTesting
        let oldRemember = c.rememberExplicit
        let before = SelfTestStoreGuard.take(), grants = PermissionGrantStore.shared.grants
        let initialRows = bridge.cachedTasks, workerAttempts = IslandOwnership.workerAttemptTotal
        let request = "Describe a quiet sunrise in one sentence."
        let reply = "A soft sunrise lights the quiet shore."
        let probe = IslandEndpointPanelProbe(island: island, request: request, reply: reply)
        var panel: IslandPanel?
        var observerInstalled = false
        var drained = false
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("island endpoint panel: " + label) }
        }
        defer {
            panel?.close()
            c.streamForTesting = oldStream; c.prewarmObserverForTesting = oldPrewarm
            c.rememberExplicit = oldRemember
        }
        do {
            guard capture.observeIslandTurnForTesting(root: root, bridge: bridge, { task, text, admitted in
                probe.capture(task: task, text: text, admitted: admitted)
            }) else { throw Invalid.owner }
            observerInstalled = true
            island.dismissNotice(); c.resetForTesting()
            c.prewarmObserverForTesting = {}; c.rememberExplicit = { _ in }
            c.streamForTesting = { _, messages in await probe.stream(messages) }
            await capture.beginSession(captureAudio: false)
            guard let session = capture.sessionID, VoiceSession.shared.state.sessionID == session,
                  VoiceSession.shared.state.phase == .open else { throw Invalid.owner }
            let actualPanel = IslandPanel(state: island); panel = actualPanel
            guard await reached({ actualPanel.isVisible && actualPanel.alphaValue >= 0.99 }) else {
                throw Invalid.context
            }
            check(island.voiceProjectionSessionID == session && island.voiceProjection == .listening
                && island.avatarState == .listening && !actualPanel.canBecomeKey && !actualPanel.canBecomeMain,
                "C01 current listening capture reaches SAME visible nonactivating panel")
            let spokenBefore = recording.spoken.count
            capture.simulateSpeech(request); capture.simulateSilence()
            let emitted = await capture.considerEndpoint()
            guard let owned = probe.operation, probe.turnAdmitted, probe.capturedCount == 1 else { throw Invalid.worker }
            check(emitted && probe.turnText == request && capture.turnHandlerForTesting == nil
                && VoiceSession.shared.state.lastCommittedTurn != nil,
                "C02 real tick/emitTurn commits exact authored speech without handler bypass")
            guard await reached({ probe.calls == 1 && synth.voiceLifecycleSnapshot.hasClause }) else { throw Invalid.worker }
            let token = synth.currentPlaybackToken, output = VoiceSession.shared.state.output
            check(probe.calls == 1 && probe.exactRequest && probe.thinkingObserved && actualPanel.isVisible
                && VoiceSession.shared.state.sessionID == session,
                "C03 actual RTA/frontend consumes one exact current request after thinking publication")
            check(!synth.voiceLifecycleSnapshot.rendered && island.voiceProjection != .speaking
                && output?.heard == false && recording.spoken.count == spokenBefore + 1,
                "C04 queued native clause is not speaking before first-audio receipt")
            synth.notifyTestingFirstAudio(token: token)
            check(synth.voiceLifecycleSnapshot.rendered && synth.currentPlaybackToken == token
                && VoiceSession.shared.state.output?.id == output?.id
                && VoiceSession.shared.state.output?.heard == true
                && island.voiceProjection == .speaking && island.avatarState == .listening
                && island.kind == .agentListening(transcript: "", level: 0)
                && island.voiceProjectionSessionID == session && actualPanel.isVisible,
                "C05 SAME actual first-audio token reaches current speaking panel consumer")
            await owned.value
            drain(synth, recording)
            guard await reached({ island.voiceProjection == .listening && VoiceSession.shared.state.output == nil }) else {
                throw Invalid.worker
            }
            check(host.lastReply == reply && Array(recording.spoken.dropFirst(spokenBefore)) == [reply]
                && !host.isThinking && !synth.voiceLifecycleSnapshot.hasClause && synth.pendingClauseCount == 0
                && island.avatarState == .listening && actualPanel.isVisible,
                "C06 exact reply/full audio drain returns current panel to listening")
            check(bridge.cachedTasks == initialRows && IslandOwnership.workerAttemptTotal == workerAttempts
                && PermissionGate.shared.pending == nil && PermissionGrantStore.shared.grants == grants,
                "C07 answer path creates no worker/grant or attributed task effect")
            await capture.endSession(source: .done)
            // Cleanup only: let the original panel remove its pointer monitors through
            // its existing hidden/dismiss path AFTER all endpoint/audio assertions.
            island.dismissNotice(); island.refresh()
            guard await reached({ !actualPanel.isVisible }) else { throw Invalid.context }
            actualPanel.close()
            guard capture.observeIslandTurnForTesting(root: root, bridge: bridge, nil) else { throw Invalid.owner }
            observerInstalled = false; drained = true
            check(!capture.isSessionActive && VoiceSession.shared.state.phase == .closed
                && island.voiceProjection == nil && island.sessionTaskIndicator == nil && !actualPanel.isVisible
                && SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).isEmpty,
                "C08 actual capture close/drained panel preserves owner files/defaults")
        } catch {
            failures.append("island ownership: INPUT_INVALID endpoint panel \(error)")
            for entered in probe.operations { entered.cancel() }; host.cancel(); synth.stop()
            // Before endSession clears the capture slot, join its existing current
            // operation as well as the positively captured handle (if present).
            await capture.waitForActiveTurnForTesting()
            for entered in probe.operations { await entered.value }
            if capture.isSessionActive { await capture.endSession(source: .done) }
            island.dismissNotice(); island.refresh()
            let hidden = await reached({ panel?.isVisible != true })
            panel?.close()
            let observerCleared = !observerInstalled || capture.observeIslandTurnForTesting(root: root, bridge: bridge, nil)
            if observerCleared { observerInstalled = false }
            drained = hidden && observerCleared && !capture.isSessionActive && !synth.voiceLifecycleSnapshot.hasClause
        }
        SelfTest.diagnostic("ISLAND_ENDPOINT_PANEL_CHECKS: \(checks) frontendCalls=\(probe.calls) handlerBypass=false drained=\(drained)")
        if !drained { failures.append("island ownership: INPUT_INVALID endpoint panel undrained") }
        return (failures, drained)
    }

}
/// The Sendable frontend callback enters this existing MainActor through its
/// original async stream seam; no captured mutable state or added held pass.
@MainActor
private final class IslandEndpointPanelProbe {
    let island: IslandState
    let request: String
    let reply: String
    private(set) var calls = 0
    private(set) var exactRequest = false
    private(set) var thinkingObserved = false
    private(set) var operations: [Task<Void, Never>] = []
    var operation: Task<Void, Never>? { operations.first }
    private(set) var turnText: String?
    private(set) var turnAdmitted = false
    private(set) var capturedCount = 0
    init(island: IslandState, request: String, reply: String) {
        self.island = island; self.request = request; self.reply = reply
    }
    func capture(task: Task<Void, Never>, text: String, admitted: Bool) {
        capturedCount += 1
        operations.append(task); turnText = text; turnAdmitted = admitted
    }
    func stream(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        calls += 1
        exactRequest = messages.last?.content.hasSuffix("Latest user speech:\n" + request) == true
        thinkingObserved = island.voiceProjection == .thinking
            && island.kind == .agentWorking(steps: [IslandState.conversationThinkingTitle], current: 1, total: 1)
        let answer = reply
        return AsyncThrowingStream { next in
            next.yield("<answer>"); next.yield(answer); next.yield("</answer>"); next.finish()
        }
    }
}

private final class IslandOwnershipFrontend: @unchecked Sendable {
    static let request = "Tell me a haiku about the quiet shore."
    static let answer = "A quiet shore rests."
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var holding = false
    private var finished = false
    var held: Bool { lock.withLock { holding } }
    func stream(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        let latest = messages.last?.content ?? ""
        guard latest.hasSuffix("Latest user speech:\n" + Self.request) else {
            return AsyncThrowingStream { $0.yield("<use_tools/>"); $0.finish() }
        }
        return AsyncThrowingStream { next in
            let closed = lock.withLock { () -> Bool in
                guard !finished else { return true }
                continuation = next; holding = true; return false
            }
            if closed { next.finish() } else { next.yield("<answer>") }
        }
    }
    func finish() {
        let value = lock.withLock { () -> AsyncThrowingStream<String, Error>.Continuation? in
            let result = continuation; continuation = nil; holding = false; finished = true; return result
        }
        value?.yield(Self.answer + "</answer>"); value?.finish()
    }
}
private actor IslandOwnershipPlanner {
    nonisolated static let contents = "The owned island document is ready."
    let first: String; let second: String
    private var initial: [String: CheckedContinuation<Void, Never>] = [:]
    private var afterRead: [String: CheckedContinuation<Void, Never>] = [:]
    private var cleanup = false
    private var rounds: [String: Int] = [:]
    private var observedReads: [String] = []
    init(first: String, second: String) { self.first = first; self.second = second }
    var heldCount: Int { initial.count }
    var afterReadCount: Int { afterRead.count }
    var readObservation: (paths: [String], held: Int) { (observedReads, afterRead.count) }
    func releaseInitial() { let old = initial; initial.removeAll(); for value in old.values { value.resume() } }
    func releaseFirst() { afterRead.removeValue(forKey: first)?.resume() }
    func releaseAll() { cleanup = true; releaseInitial(); let old = afterRead; afterRead.removeAll(); for value in old.values { value.resume() } }
    func complete(_ user: String) async throws -> String {
        guard let start = user.range(of: "Current user request:\n", options: .backwards) else { throw Invalid.scope }
        let tail = user[start.upperBound...], done = tail.range(of: "\n\nWhat you have already done:\n")
        let request = String(done.map { tail[..<$0.lowerBound] } ?? tail)
        let results = done.map { String(tail[$0.upperBound...]) } ?? ""
        let path: String
        if request.contains(first) { path = first } else if request.contains(second) { path = second } else { throw Invalid.scope }
        let count = rounds[path, default: 0]; rounds[path] = count + 1
        if count == 0 {
            if !cleanup { await withCheckedContinuation { initial[path] = $0 } }
            return try Self.readCall(path)
        }
        guard results.contains(Self.contents) else { throw Invalid.scope }
        if count == 1 {
            observedReads.append(path) // Only after actual tool result content qualified.
            if !cleanup { await withCheckedContinuation { afterRead[path] = $0 } }
            if path == first && !cleanup {
                return Self.keyCall
            }
        }
        return "The owned island document is ready."
    }
    nonisolated static func readCall(_ path: String) throws -> String {
        let args = try JSONSerialization.data(withJSONObject: ["path": path], options: [.sortedKeys])
        return "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":" + String(decoding: args, as: UTF8.self)
            + ",\"rationale\":\"Read the owned Island document.\"}</tool_call>"
    }
    nonisolated static let keyCall = "<tool_call>{\"name\":\"computer.press_key\",\"arguments\":{\"key\":\"escape\",\"modifiers\":null},\"rationale\":\"Apply the owned key only after review.\"}</tool_call>"
    private enum Invalid: Error { case scope }
}
private struct IslandOwnershipProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: IslandOwnershipPlanner
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

@MainActor private final class IslandACPObservation {
    var events: [(String, Bool?)] = []
    static func writePeer(root: URL) throws -> URL {
        let script = root.appendingPathComponent("owned-peer.py")
        let code = """
        import json, sys, pathlib, time
        root = pathlib.Path(__file__).parent
        def send(v):
            sys.stdout.write(json.dumps(v)+'\\n'); sys.stdout.flush()
        for raw in sys.stdin:
            m=json.loads(raw); mid=m.get('id'); method=m.get('method')
            if method=='initialize': send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':1,'agentCapabilities':{}}})
            elif method=='session/new': send({'jsonrpc':'2.0','id':mid,'result':{'sessionId':'owned-island'}})
            elif method=='session/prompt':
                (root/'ready.json').write_text('{"ready":true}')
                deadline=time.monotonic()+8
                while not (root/'release.json').exists():
                    if time.monotonic()>=deadline: raise TimeoutError('owned island release')
                    time.sleep(0.005)
                assert json.loads((root/'release.json').read_text())=={'release':True}
                send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'owned-island','update':{'sessionUpdate':'tool_call_update','title':'Owned ACP observation'}}})
                # Remain held until the SAME Manager cancellation closes this peer.
            elif method=='session/cancel':
                if mid is not None: send({'jsonrpc':'2.0','id':mid,'result':{}})
            elif mid is not None: send({'jsonrpc':'2.0','id':mid,'result':{}})
        """
        try code.write(to: script, atomically: true, encoding: .utf8)
        return script
    }
}
private actor IslandTypedPlanner {
    nonisolated static let contents = "The owned typed Island document is ready."
    let path: String
    private var initial: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Void, Never>?
    private var cleanup = false
    private(set) var readObserved = false
    var initialHeld: Bool { initial != nil }
    var resultHeld: Bool { result != nil }
    init(path: String) { self.path = path }
    func releaseInitial() { let c = initial; initial = nil; c?.resume() }
    func releaseAll() { cleanup = true; releaseInitial(); let c = result; result = nil; c?.resume() }
    func complete(_ user: String) async throws -> String {
        guard let start = user.range(of: "Current user request:\n", options: .backwards) else { throw Failure.scope }
        let tail = user[start.upperBound...]
        let done = tail.range(of: "\n\nWhat you have already done:\n")
        let request = String(done.map { tail[..<$0.lowerBound] } ?? tail)
        let results = done.map { String(tail[$0.upperBound...]) } ?? ""
        guard request.contains(path) else { throw Failure.scope }
        if results.contains(Self.contents) {
            readObserved = true
            if !cleanup { await withCheckedContinuation { result = $0 } }
            try Task.checkCancellation()
            return "The owned typed document is ready."
        }
        if !cleanup { await withCheckedContinuation { initial = $0 } }
        try Task.checkCancellation()
        return try IslandOwnershipPlanner.readCall(path)
    }
    private enum Failure: Error { case scope }
}
private struct IslandTypedProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: IslandTypedPlanner
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}
