import Foundation

/// Actual source-owned row -> same queue -> existing frontend API -> existing audio.
/// The private frontend's generation boundary scripts authored external model output;
/// this proves caller/budget/fallback ownership, not native Apple model grounding.
@MainActor
enum OutputSchedulerPhraseSelfTest {
    private enum Invalid: Error { case unsafe, row }
    static func run(recorder: RecordingSpeechBacking) async -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              AgentSession.shared.fileURL == nil, !AgentCaptureController.shared.isSessionActive,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0,
              !VoiceConversationCoordinator.shared.hasActiveWork else { return (0, ["phrase: INVALID isolated delivery prerequisite"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.deletingLastPathComponent().path == temp.path,
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["phrase: INVALID confined root"]) }
        let capture = AgentCaptureController.shared; let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared; let playback = VoicePlaybackDelivery.shared
        let owner = SelfTestStoreGuard.take()
        var rootCreated = false; var checks = 0; var failures: [String] = []
        var scopedOutputs: [OutputScheduler] = []
        var scopedFrontends: [FrontendResponder] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("phrase: " + label) } }
        defer {
            _ = playback.installOutputForTesting(nil)
            if rootCreated { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); rootCreated = true
            for mode in ["result", "batch", "carry", "failure", "unavailable", "unsafe", "error", "timeout", "question"] {
                let startChecks = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store); let bridge = TaskBridge(manager: manager)
                guard let output = OutputScheduler.isolatedForTesting(bridge), playback.installOutputForTesting(output) else { throw Invalid.unsafe }
                scopedOutputs.append(output)
                await capture.beginSession(captureAudio: false)
                guard let session = capture.sessionID else { throw Invalid.unsafe }
                let now = Date(); output.setNowForTesting(now)
                let id = UUID(); let objective = "Read the owned brief"
                guard bridge.beginVoiceObjective(id: id, objective: objective,
                    origin: .voice(sessionID: session, turn: TurnID(raw: 1)), userWords: objective) else { throw Invalid.row }
                let facts = mode == "failure" ? "The document could not be opened." : "The owned brief describes a Friday meeting."
                let outcome: AgentTaskOutcome = mode == "question" ? .voiceReply("Which brief should I read?")
                    : mode == "failure" ? .failed(facts) : .completed(facts)
                guard bridge.finishVoiceObjective(id: id, outcome: outcome) else { throw Invalid.row }
                let secondID: UUID? = mode == "batch" ? UUID() : nil
                let secondFacts = "Margaret will attend the Friday meeting."
                if let secondID {
                    guard bridge.beginVoiceObjective(id: secondID, objective: "Read the owned guest list",
                        origin: .voice(sessionID: session, turn: TurnID(raw: 2)), userWords: "Read the owned guest list"),
                        bridge.finishVoiceObjective(id: secondID, outcome: .completed(secondFacts)) else { throw Invalid.row }
                }
                let probe = DeliveryPhraseProbe(mode: mode)
                let frontend = FrontendResponder()
                scopedFrontends.append(frontend)
                await frontend.setGenerationForTesting { system, messages, tokens in probe.stream(system, messages, tokens) }
                output.setPhraseForTesting { batch in
                    if mode == "unavailable" { probe.recordUnavailable(); return nil }
                    return await frontend.phrase(batch, carriedOver: batch.contains(where: \.carriedOver))
                }
                let admitted: Bool
                if mode == "question" { admitted = output.enqueueQuestion(TaskID(id)) }
                else {
                    let item = DeliveryItem(task: TaskID(id), kind: mode == "failure" ? .failure : .result,
                        title: TaskStatusRenderer.title(objective), facts: facts, enqueuedAt: now,
                        attempts: 0, carriedOver: mode == "carry")
                    admitted = output.enqueue(item)
                }
                if let secondID {
                    let second = DeliveryItem(task: TaskID(secondID), kind: .result,
                        title: TaskStatusRenderer.title("Read the owned guest list"), facts: secondFacts,
                        enqueuedAt: now.addingTimeInterval(0.001), attempts: 0, carriedOver: false)
                    guard output.enqueue(second) else { throw Invalid.row }
                }
                check(admitted && bridge.record(TaskID(id))?.delivery == .pending
                    && (secondID.map { bridge.record(TaskID($0))?.delivery == .pending } ?? true),
                    "C01 actual source row and same queue admission (\(mode))")
                output.setNowForTesting(now.addingTimeInterval(2)); recorder.reset()
                let began = ContinuousClock.now
                let flushed = await output.flushAndJoinForTesting(userHasFloor: false)
                let phraseElapsed = began.duration(to: .now)
                // The bounded phrase owner cancels the same external generation.
                // Qualify its actual stream termination callback rather than assuming
                // that cancellation and callback publication are synchronous.
                if mode == "timeout", probe.snapshot().calls > 0 {
                    let until = ContinuousClock.now.advanced(by: .seconds(8))
                    while !probe.snapshot().terminated && ContinuousClock.now < until { await Task.yield() }
                }
                let observed = probe.snapshot()
                check(flushed && audio.isSpeaking && speech.isSpeaking && recorder.spoken.count == 1,
                    "C02 actual phrase/fallback entered same existing audio owner (\(mode))")
                if mode == "question" {
                    check(observed.calls == 0 && observed.unavailable == 0 && recorder.spoken == ["Which brief should I read?"],
                        "C03 question must bypass model phrasing")
                } else if mode == "result" || mode == "batch" || mode == "carry" || mode == "failure" {
                    check(observed.calls == 1 && observed.tokens == [120],
                        "F01 actual frontend phrase caller omitted or changed120 token budget (\(mode))")
                    check(observed.systems.first?.contains(AgentDeliveryPrompts.resultRules) == true
                        && observed.users.first?.contains(facts) == true
                        && observed.users.first?.contains("not a new request") == true
                        && observed.users.first?.contains(id.uuidString) == false,
                        "F02 actual result instructions/facts/provider identity lost (\(mode))")
                    let authoredClauses = AgentSpeechPolicy.spokenClauses(probe.answer)
                    print("OUTPUT_PHRASE_CLAUSE_METADATA mode=\(mode) firstAuthored=\(recorder.spoken.first == authoredClauses.first) spokenCount=\(recorder.spoken.count) expectedClauseCount=\(authoredClauses.count) queuedClauses=\(speech.pendingClauseCount) activeClause=\(speech.voiceLifecycleSnapshot.hasClause) fullAnswerAlreadySpoken=\(recorder.spoken.joined(separator: " ") == probe.answer)")
                    check(!authoredClauses.isEmpty && recorder.spoken == [authoredClauses[0]]
                        && speech.voiceLifecycleSnapshot.hasClause
                        && speech.pendingClauseCount == authoredClauses.count - 1,
                        "F03 authored valid frontend phrase lost at actual audio (\(mode))")
                    if mode == "batch" {
                        check(observed.users.first?.contains(secondFacts) == true
                            && observed.users.first?.contains("2. Work:") == true
                            && observed.users.first?.contains(secondID!.uuidString) == false,
                            "F08 actual one-pass model consumer omitted another owned result")
                    }
                    if mode == "carry" {
                        check(observed.systems.first?.contains(AgentDeliveryPrompts.carriedOverRule) == true,
                            "F04 actual carry-over phrase instructions absent")
                    }
                    if mode == "failure" {
                        check(observed.users.first?.contains("Outcome: did not work") == true,
                            "F05 actual unsuccessful work was labeled finished in phrase facts")
                    }
                } else {
                    let item = DeliveryItem(task: TaskID(id), kind: .result,
                        title: TaskStatusRenderer.title(objective), facts: facts, enqueuedAt: now,
                        attempts: 0, carriedOver: false)
                    check(recorder.spoken == [DeliveryFallbackRenderer.spoken([item])],
                        "C04 absent/error/unsafe/timeout preserves deterministic owned facts (\(mode))")
                    if mode == "unavailable" {
                        check(observed.unavailable == 1 && observed.calls == 0,
                            "F06 unavailable phrase path added inference or missed fallback admission")
                    } else {
                        check(observed.calls == 1 && observed.tokens == [120],
                            "F07 actual unsafe/timeout model invocation/budget missing (\(mode))")
                    }
                    if mode == "timeout" {
                        check(observed.terminated || observed.calls == 0,
                            "C05 timeout did not cancel same scripted model stream")
                    }
                }
                speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
                check(bridge.record(TaskID(id))?.delivery == .delivered
                    && (secondID.map { bridge.record(TaskID($0))?.delivery == .delivered } ?? true)
                    && output.activeOutputID == audio.voiceShadowOutputSnapshot?.id,
                    "C06 positive recording receipt lost same row/output identity (\(mode))")
                drain(speech, recorder)
                let expectedFullPhrase = ["result", "batch", "carry", "failure"].contains(mode) && observed.calls > 0
                print("OUTPUT_PHRASE_FINAL_AUDIO mode=\(mode) drained=\(!audio.isSpeaking && !speech.isSpeaking && output.activeOutputID == nil) actualClauseCount=\(recorder.spoken.count) callerEntered=\(observed.calls > 0) fullAuthoredWordsEqual=\(recorder.spoken.joined(separator: " ") == probe.answer)")
                check(!audio.isSpeaking && !speech.isSpeaking && output.activeOutputID == nil
                    && (!expectedFullPhrase || recorder.spoken.joined(separator: " ") == probe.answer),
                    "C07 same owned recording output did not finish (\(mode))")
                print("OUTPUT_PHRASE_CASE mode=\(mode) checks=\(checks-startChecks) calls=\(observed.calls) tokens120=\(observed.tokens.allSatisfy { $0 == 120 }) elapsed=\(phraseElapsed) physicalAudio=false")
                output.setPhraseForTesting(nil)
                await frontend.setGenerationForTesting(nil)
                await capture.endSession(source: .done)
            }
            let race = try await generationRace(root: root, recorder: recorder)
            checks += race.checks; failures += race.failures
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C08 owner store/default invariant")
        } catch {
            failures.append("phrase: INVALID \(error)")
            // Capture SAME existing owners before close clears the visible slot.
            let phraseOwners = scopedOutputs.compactMap { $0.ownedPhraseTaskForTesting }
            for task in phraseOwners { task.cancel() }
            for frontend in scopedFrontends {
                if let task = await frontend.ownedGenerationForTesting() { task.cancel(); await task.value }
                await frontend.setGenerationForTesting(nil)
            }
            await capture.endSession(source: .done)
            for task in phraseOwners { await task.value }
            for output in scopedOutputs { output.setPhraseForTesting(nil) }
        }
        return (checks, failures)
    }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let until = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < until { if await predicate() { return true }; await Task.yield() }
        return await predicate()
    }
    /// Actual frontend request/phrase Tasks over an authored external stream, not C.
    private static func generationRace(root: URL, recorder: RecordingSpeechBacking) async throws -> (checks: Int, failures: [String]) {
        let directory = root.appendingPathComponent("generation-race", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let sql = TaskStore(root: directory); defer { sql.close() }
        let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
        guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
        let manager = AgentTaskManager(store: store); let bridge = TaskBridge(manager: manager)
        let capture = AgentCaptureController.shared; let speech = AgentSpeechSynthesizer.shared
        guard let output = OutputScheduler.isolatedForTesting(bridge),
              VoicePlaybackDelivery.shared.installOutputForTesting(output) else { throw Invalid.unsafe }
        let frontend = FrontendResponder(); let probe = DeliveryGenerationRaceProbe()
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("phrase race: " + label) } }
        let configured = await frontend.setGenerationForTesting({ system, messages, tokens in
            probe.stream(system: system, messages: messages, tokens: tokens)
        }, retainingTaskOwner: true, fixtureRoot: root, onGenerationCapture: { probe.captured($0) })
        guard configured else { throw Invalid.unsafe }
        await capture.beginSession(captureAudio: false)
        guard let session = capture.sessionID else { throw Invalid.unsafe }
        let id = UUID(); let facts = "The owned result is ready."
        let now = Date(); output.setNowForTesting(now)
        guard bridge.beginVoiceObjective(id: id, objective: "Read the owned race document",
            origin: .voice(sessionID: session, turn: TurnID(raw: 1)), userWords: "Read the owned race document"),
              bridge.finishVoiceObjective(id: id, outcome: .completed(facts)), output.enqueueCompletion(TaskID(id)) else { throw Invalid.row }
        output.setPhraseForTesting { batch in
            await frontend.phrase(batch, carriedOver: false)
        }
        let priorStream = await frontend.stream(system: "Owned prior request", messages: [.init(role: .user, content: "Owned prior input")], maxTokens: 24)
        var newerCall: Task<String, Error>?
        var phraseOwner: Task<Void, Never>?
        let priorOwner = await frontend.ownedGenerationForTesting()
        do {
            guard let priorOwner, await reached({ probe.snapshot().held }) else { throw Invalid.row }
            check(probe.snapshot().calls == 1 && probe.snapshot().requestCaptures == 1,
                "C09 actual retained frontend owner input not qualified")
            recorder.reset(); output.setNowForTesting(now.addingTimeInterval(2))
            let flushed = output.flush(userHasFloor: false)
            phraseOwner = output.ownedPhraseTaskForTesting
            if phraseOwner != nil { guard await reached({ probe.snapshot().phraseCaptures == 1 }) else { throw Invalid.row } }
            check(flushed && phraseOwner != nil && probe.snapshot().phraseCaptures == 1,
                "F09 actual result phrase never captured generation before prior-owner drain")
            newerCall = Task {
                let stream = await frontend.stream(system: "Owned newer request",
                    messages: [.init(role: .user, content: "Owned newer input")], maxTokens: 24)
                var reply = ""
                for try await fragment in stream { reply += fragment }
                return reply
            }
            guard await reached({ probe.snapshot().requestCaptures == 2 }), let newerCall else { throw Invalid.row }
            check(probe.snapshot().held && !probe.snapshot().released,
                "C10 newer real request was not admitted before prior-owner release")
            probe.releasePrior()
            await priorOwner.value
            let reply = try await newerCall.value
            await phraseOwner?.value
            guard let latestOwner = await frontend.ownedGenerationForTesting() else { throw Invalid.row }
            await latestOwner.value
            check(reply == DeliveryGenerationRaceProbe.newReply && probe.snapshot().calls == 2,
                "C11 stale phrase entered a third generation or lost newer request consumer")
            let item = DeliveryItem(task: TaskID(id), kind: .result, title: TaskStatusRenderer.title("Read the owned race document"),
                facts: facts, enqueuedAt: now, attempts: 0, carriedOver: false)
            check(recorder.spoken == [DeliveryFallbackRenderer.spoken([item])],
                "C12 stale phrase wording escaped to SAME audio consumer")
            speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
            check(bridge.record(TaskID(id))?.delivery == .delivered
                && output.activeOutputID == RealtimeAudioSession.shared.voiceShadowOutputSnapshot?.id,
                "C13 same actual positive output receipt lost canonical row")
            drain(speech, recorder)
            await capture.endSession(source: .done)
            check(!speech.isSpeaking && !capture.isSessionActive && probe.snapshot().terminated == 2,
                "C14 joined actual frontend/phrase/request owners failed cleanup")
            print("OUTPUT_PHRASE_RACE checks=\(checks) generatorCalls=\(probe.snapshot().calls) requestCaptures=\(probe.snapshot().requestCaptures) phraseCaptures=\(probe.snapshot().phraseCaptures) nativeKernelEvidence=false")
            withExtendedLifetime(priorStream) {}
        } catch {
            probe.releasePrior(); newerCall?.cancel(); phraseOwner?.cancel()
            await priorOwner?.value; _ = try? await newerCall?.value; await phraseOwner?.value
            if let latest = await frontend.ownedGenerationForTesting() { latest.cancel(); await latest.value }
            await capture.endSession(source: .done)
            _ = await frontend.setGenerationForTesting(nil); output.setPhraseForTesting(nil)
            withExtendedLifetime(priorStream) {}
            throw error
        }
        _ = await frontend.setGenerationForTesting(nil); output.setPhraseForTesting(nil)
        return (checks, failures)
    }
    private static func drain(_ speech: AgentSpeechSynthesizer, _ recorder: RecordingSpeechBacking) {
        var count = 0
        while (speech.voiceLifecycleSnapshot.hasClause || speech.pendingClauseCount > 0) && count < 32 {
            recorder.finishNaturallyForTesting(); speech.notifyTestingAudioFinished(token: speech.currentPlaybackToken); count += 1
        }
    }
}
private final class DeliveryPhraseProbe: @unchecked Sendable {
    private enum AuthoredError: Error { case generationFailed }
    struct Snapshot { var calls = 0; var systems: [String] = []; var users: [String] = []; var tokens: [Int] = []; var unavailable = 0; var terminated = false }
    let mode: String
    private let lock = NSLock(); private var value = Snapshot()
    init(mode: String) { self.mode = mode }
    var answer: String {
        switch mode {
        case "carry": "While you were away, I found a Friday meeting in the brief."
        case "batch": "The brief describes a Friday meeting. Margaret will attend."
        case "failure": "The document could not be opened."
        case "unsafe": "The background task is done at https://example.invalid/123456."
        default: "I found a Friday meeting in the brief."
        }
    }
    func snapshot() -> Snapshot { lock.withLock { value } }
    func recordUnavailable() { lock.withLock { value.unavailable += 1 } }
    func stream(_ system: String, _ messages: [LLMChatMessage], _ tokens: Int) -> AsyncThrowingStream<String, Error> {
        lock.withLock { value.calls += 1; value.systems.append(system); value.users.append(messages.last?.content ?? ""); value.tokens.append(tokens) }
        return AsyncThrowingStream { continuation in
            if mode == "timeout" {
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }; self.lock.withLock { self.value.terminated = true }
                }
            } else if mode == "error" {
                continuation.finish(throwing: AuthoredError.generationFailed)
            } else { continuation.yield(answer); continuation.finish() }
        }
    }
}

private final class DeliveryGenerationRaceProbe: @unchecked Sendable {
    static let newReply = "The newer owned reply is ready."
    struct Snapshot { var calls = 0; var requestCaptures = 0; var phraseCaptures = 0; var held = false; var released = false; var terminated = 0 }
    private let lock = NSLock(); private var state = Snapshot()
    private var prior: AsyncThrowingStream<String, Error>.Continuation?
    func snapshot() -> Snapshot { lock.withLock { state } }
    func captured(_ kind: String) {
        lock.withLock { if kind == "request" { state.requestCaptures += 1 }; if kind == "phrase" { state.phraseCaptures += 1 } }
    }
    func releasePrior() {
        let continuation = lock.withLock { state.released = true; state.held = false; let held = prior; prior = nil; return held }
        continuation?.yield("The prior owned reply is ready."); continuation?.finish()
    }
    func stream(system: String, messages: [LLMChatMessage], tokens: Int) -> AsyncThrowingStream<String, Error> {
        lock.withLock { state.calls += 1 }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in guard let self else { return }; self.lock.withLock { self.state.terminated += 1 } }
            if system == "Owned prior request" { lock.withLock { state.held = true; prior = continuation } }
            else { continuation.yield(system == "Owned newer request" ? Self.newReply : "Discarded stale phrase."); continuation.finish() }
        }
    }
}
