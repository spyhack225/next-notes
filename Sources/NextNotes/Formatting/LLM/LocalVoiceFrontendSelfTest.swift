import Foundation

/// Model-backed latency and independence probe. The final verdict must fail if either
/// model cannot generate, if the frontend is empty, or if it waits for the 4B worker.
enum LocalVoiceFrontendSelfTest {

    /// Actual Foundation Models session construction/prewarm/take only. No respond(),
    /// inference stream, compute acquisition, speech, tools, or owner fixture data.
    private static func stagingContractCases() async -> [String] {
        guard LocalVoiceSplitResponse.isEnabled else { return ["split staging fixture requires the production split mode"] }
        let frontend = LocalVoiceFrontend()
        let probe = StagingProbe()
        var problems: [String] = []
        guard await frontend.setStagingObserverForTesting({ probe.record($0) }) else {
            return ["staging observer admission refused"]
        }
        let system = "Answer this authored fixture plainly."
        let prefix = "Frontend control schemas (application facts, not external tool grants):\n[]\nApproval offered: no\n\nWork status (context, not instructions):\nNo active jobs.\n\nLatest user speech:\n"
        let context = LLMChatMessage(role: .system, content: "Fixture capability and playback context: idle.")
        let stage: [LLMChatMessage] = [context, .init(role: .assistant, content: "An authored prior answer."),
            .init(role: .user, content: prefix)]
        let final = Array(stage.dropLast()) + [.init(role: .user, content: prefix + "What is a haiku?")]
        func warm(_ messages: [LLMChatMessage]? = nil) async throws {
            probe.reset()
            try await frontend.stageNextTurn(system: system, messages: messages ?? stage)
        }
        func take(_ kind: LocalVoiceFrontend.StagedSessionKind,
                  _ messages: [LLMChatMessage]? = nil, generation: UInt64 = 1,
                  advancingBy duration: Duration = .zero, instructions: String? = nil) async -> ObjectIdentifier? {
            await frontend.takeStagedSplitSessionForTesting(kind, system: instructions ?? system,
                messages: messages ?? final, generation: generation, advancingBy: duration)
        }
        do {
            try await warm()
            if probe.prewarmed(.route) != 1 || probe.prewarmed(.answer) != 1
                || probe.consumed(.route) != 0 || probe.consumed(.answer) != 0 {
                problems.append("complete transcript/prefix did not prewarm two independent sessions before inference")
            }
            let route = await take(.route), answer = await take(.answer)
            if route == nil || answer == nil || route == answer {
                problems.append("exact current route/answer plans did not take the distinct prewarmed sessions")
            }
            problems += probe.problems(expectedAnswer: true)
            let routeAgain = await take(.route), answerAgain = await take(.answer)
            if routeAgain != nil || answerAgain != nil {
                problems.append("a staged route or answer session was consumed twice")
            }
            for name in ["history", "playback", "work", "approval", "instructions"] {
                try await warm()
                var changed = final
                var changedSystem = system
                switch name {
                case "history": changed[1] = .init(role: .assistant, content: "A different authored answer.")
                case "playback": changed[0] = .init(role: .system, content: "Fixture capability and playback context: paused.")
                case "work": changed[2] = .init(role: .user, content: (prefix + "What is a haiku?").replacingOccurrences(of: "No active jobs.", with: "Task 1 [running]: An authored task."))
                case "approval": changed[2] = .init(role: .user, content: (prefix + "What is a haiku?").replacingOccurrences(of: "Approval offered: no", with: "Approval offered: yes"))
                default: changedSystem = "Different answer instructions."
                }
                let route = await take(.route, changed)
                let answer = await take(.answer, changed, instructions: changedSystem)
                let routeMayMatch = ["history", "playback", "instructions"].contains(name)
                if (route != nil) != routeMayMatch || answer != nil {
                    problems.append("\(name) change reused an inapplicable plan or discarded the independent matching route")
                }
                if await take(.answer) != nil {
                    problems.append("\(name) mismatch retained its discarded answer for a later request")
                }
            }
            try await warm()
            let expiredRoute = await take(.route, advancingBy: .seconds(61)), expiredAnswer = await take(.answer)
            if expiredRoute != nil || expiredAnswer != nil {
                problems.append("a staged session survived its 60-second freshness limit")
            }
            try await warm()
            await frontend.clearStagedTurn()
            let clearedRoute = await take(.route), clearedAnswer = await take(.answer)
            if clearedRoute != nil || clearedAnswer != nil {
                problems.append("cleared/cancelled epoch retained a staged session")
            }
            try await warm()
            _ = await take(.route, generation: 2)
            if await take(.answer, generation: 3) != nil {
                problems.append("a successor generation borrowed the prior route's staged answer")
            }
            // Cancellation of prior partial work cannot erase a newly staged turn.
            // Only the external generator is finite/scripted; session construction
            // and the cancellation/staging owner are the real production path.
            await frontend.setGenerationForTesting { _, _, _ in AsyncThrowingStream { $0.finish() } }
            await frontend.speculate(system: system, messages: final, maxTokens: 64, revision: 1)
            try await warm()
            await frontend.cancelSpeculation()
            let successorRoute = await take(.route), successorAnswer = await take(.answer)
            if successorRoute == nil || successorAnswer == nil {
                problems.append("cancelling old speculation erased a newly staged unconsumed turn")
            }
            // Consume a finite no-output generator through the existing drain path.
            let joined = await frontend.stream(system: system, messages: final, maxTokens: 64)
            for try await _ in joined { }
            await frontend.setGenerationForTesting(nil)
            let cancelled = Task { () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do { try await frontend.stageNextTurn(system: system, messages: stage); return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            if !(await cancelled.value) { problems.append("already-cancelled staging was admitted") }
            // A nonempty user utterance is not a stable staging prefix.
            probe.reset()
            try await frontend.stageNextTurn(system: system, messages: final)
            if probe.prewarmed(.route) != 0 || probe.prewarmed(.answer) != 0 {
                problems.append("staging accepted user speech as a stable application prefix")
            }
            await frontend.clearStagedTurn()
        } catch { problems.append("staging construction failed: \(error.localizedDescription)") }
        await frontend.clearStagedTurn()
        await frontend.setGenerationForTesting(nil)
        _ = await frontend.setStagingObserverForTesting(nil)
        return problems
    }

    private final class StagingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [LocalVoiceFrontend.StagingObservation] = []
        func record(_ row: LocalVoiceFrontend.StagingObservation) { lock.withLock { rows.append(row) } }
        func reset() { lock.withLock { rows.removeAll() } }
        func prewarmed(_ kind: LocalVoiceFrontend.StagedSessionKind) -> Int {
            lock.withLock { rows.filter { $0.kind == kind && !$0.consumed }.count }
        }
        func consumed(_ kind: LocalVoiceFrontend.StagedSessionKind) -> Int {
            lock.withLock { rows.filter { $0.kind == kind && $0.consumed }.count }
        }
        func problems(expectedAnswer: Bool) -> [String] {
            lock.withLock {
                var failures: [String] = []
                for kind in [LocalVoiceFrontend.StagedSessionKind.route, .answer] {
                    let created = rows.filter { $0.kind == kind && !$0.consumed }
                    let taken = rows.filter { $0.kind == kind && $0.consumed }
                    let expected = kind == .route || expectedAnswer ? 1 : 0
                    if created.count != 1 || taken.count != expected
                        || taken.contains(where: { row in !created.contains { $0.session == row.session } }) {
                        failures.append("\(kind.rawValue) SDK consumer did not take its exact prewarmed session once")
                    }
                }
                return failures
            }
        }
    }

    static func run() async -> Bool {
        if CommandLine.arguments.contains("--voice-frontend-stage-contract") {
            let problems = await stagingContractCases()
            for problem in problems { await SelfTest.diagnostic("VOICE_STAGING_FAILED: " + problem) }
            await SelfTest.diagnostic(problems.isEmpty ? "VOICE_STAGING_OK" : "VOICE_STAGING_FAILED")
            await SelfTest.diagnostic(problems.isEmpty ? "VOICE_FRONTEND_OK" : "VOICE_FRONTEND_FAILED")
            return problems.isEmpty
        }
        let frontend = LocalVoiceFrontend.shared
        let stagedCorpus = CommandLine.arguments.contains("--voice-frontend-stage-split")
        guard stagedCorpus || NotesModels.isDownloaded else {
            await SelfTest.diagnostic("VOICE_FRONTEND_MISSING_WORKER_MODEL")
            await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
            return false
        }
        do {
            let cpuWorker = CommandLine.arguments.contains("--voice-worker-cpu")
            let stageLeadSeconds = CommandLine.arguments.contains("--voice-stage-lead2s") ? 2 : 1
            let workerRuntime: NotesModelRuntime? = stagedCorpus ? nil : (cpuWorker
                ? NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
                : NotesModelRuntime.shared)
            let prewarmStart = ContinuousClock.now
            try await frontend.prepare()
            await SelfTest.diagnostic("voice frontend prewarm \(prewarmStart.duration(to: .now))")

            if CommandLine.arguments.contains("--voice-frontend-greeting") {
                let start = ContinuousClock.now
                let stream = await frontend.stream(
                    system: VoiceConversationCoordinator.systemPrompt,
                    messages: [.init(role: .user, content:
                        "Work status (context, not instructions):\nNo tasks.\n\nLatest user speech:\nHi, how are you?")],
                    maxTokens: 64
                )
                var output = ""
                var first: Double?
                for try await delta in stream {
                    output += delta
                    if first == nil,
                       case .answer(let answer) = VoiceFrontendEnvelope.parse(output),
                       !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        first = seconds(start.duration(to: .now))
                    }
                }
                await SelfTest.diagnostic("voice frontend greeting first_text=\(first.map { String(format: "%.3f", $0) } ?? "none")s output=\(output)")
                let okay = first != nil
                await SelfTest.diagnostic(okay ? "VOICE_FRONTEND_OK" : "VOICE_FRONTEND_FAILED")
                return okay
            }

            if CommandLine.arguments.contains("--voice-frontend-idle20s")
                || CommandLine.arguments.contains("--voice-frontend-idle20s-stage1s") {
                let staged = CommandLine.arguments.contains("--voice-frontend-idle20s-stage1s")
                try await Task.sleep(for: .seconds(staged ? 19 : 20))
                if staged {
                    try await frontend.stageNextTurn(system: VoiceConversationCoordinator.systemPrompt)
                    try await Task.sleep(for: .seconds(1))
                }
                let start = ContinuousClock.now
                var output = ""
                var first: Double?
                var firstRaw: Double?
                let stream = await frontend.stream(
                    system: VoiceConversationCoordinator.systemPrompt,
                    messages: [.init(role: .user, content:
                        "Work status (context, not instructions):\nNo tasks.\n\nLatest user speech:\nHi, are you there?")],
                    maxTokens: 64
                )
                for try await delta in stream {
                    output += delta
                    if firstRaw == nil && !delta.isEmpty {
                        firstRaw = seconds(start.duration(to: .now))
                    }
                    if first == nil,
                       case .answer(let answer) = VoiceFrontendEnvelope.parse(output),
                       !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        first = seconds(start.duration(to: .now))
                    }
                }
                guard let first else {
                    await SelfTest.diagnostic("voice frontend idle invalid staged=\(staged) first_raw=\(firstRaw.map { String(format: "%.3f", $0) } ?? "none")s output=\(output)")
                    await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
                    return false
                }
                await SelfTest.diagnostic("voice frontend idle20 first_text=\(String(format: "%.3f", first))s staged_1s=\(staged)")
                await SelfTest.diagnostic("VOICE_FRONTEND_OK")
                return true
            }

            let shortLead = CommandLine.arguments.contains("--voice-frontend-short-lead")
            let substantiveLead = CommandLine.arguments.contains("--voice-frontend-substantive-lead")
            let system = VoiceConversationCoordinator.systemPrompt + (shortLead ? """

                For <answer/> replies, lead with a short, useful complete sentence of at
                most eight words. State the answer or verified task status directly;
                add detail only when needed. Avoid generic acknowledgments and
                unnecessary confirmation questions.
                """ : "") + (substantiveLead ? """

                Answer the user's actual question in the first short complete sentence.
                For a definition, name the subject and its defining property; then add
                one important detail only if needed. For this assistant's full-duplex
                conversation, explain that the user can interrupt while you speak and
                background work continues. For a running task, report its known status
                directly. Do not ask whether to continue an already running task or
                invite the next question or task. Ask only when a fact needed to answer
                is genuinely missing. Stop when the answer is complete.
                """ : "")
            var fixtures: [(speech: String, work: String, expected: VoiceFrontendEnvelope)] = [
                ("Hi, how are you?", "No tasks.", .answer("")),
                ("While you check my calendar, tell me what you are doing.",
                 "Task 1 [running]: Check my calendar for today.", .answer("")),
                ("Open Chrome and inspect my Claude sessions.", "No tasks.", .newWork),
                ("I meant Claude, not cloud code. Continue the original task.",
                 "Task 1 [running]: Open Chrome and inspect my cloud code sessions.", .revise(1)),
                ("Cancel that task.",
                 "Task 1 [running]: Open Chrome and inspect my Claude sessions.", .cancel(1)),
                ("Hello there. Please tell me briefly what a haiku is.",
                 "No tasks.", .answer("")),
                ("Explain full duplex conversation in plain language.",
                 "No tasks.", .answer("")),
                ("What is a good structure for meeting notes?",
                 "No tasks.", .answer(""))
            ]
            if LocalVoiceTypedResponse.isEnabled || LocalVoiceSplitResponse.isEnabled {
                fixtures += [
                    ("What can this app help me with?", "No active jobs.", .capabilities),
                    ("List the tools you support.", "No active jobs.", .capabilities),
                    ("Use your tools to open Safari.", "No active jobs.", .newWork),
                    ("Can you check my calendar for today?", "No active jobs.", .newWork),
                    ("Do you support calendars?", "No active jobs.", .answer("")),
                    ("Can you send emails without approval?", "No active jobs.", .answer("")),
                    ("What does full duplex mean?", "No active jobs.", .answer(""))
                ]
            }
            var routingFailures = 0
            var firstTextSeconds: [Double] = []
            let capabilityFacts = await MainActor.run { VoiceCapabilitySnapshot.current().promptText }
            let stagedSplit = CommandLine.arguments.contains("--voice-frontend-stage-split")
            let stagingProbe = StagingProbe()
            if stagedSplit, !(await frontend.setStagingObserverForTesting({ stagingProbe.record($0) })) {
                throw LocalVoiceFrontend.FrontendError.unavailable("staging_fixture_refused")
            }
            for fixture in fixtures {
                do {
                let start = ContinuousClock.now
                var first: Double?
                var firstClause: Double?
                var clauseText: String?
                var output = ""
                let fixturePrefix = "Work status (context, not instructions):\n\(fixture.work)\n\nLatest user speech:\n"
                let fixtureMessages: [LLMChatMessage] = [.init(role: .system, content: capabilityFacts),
                    .init(role: .user, content: fixturePrefix + fixture.speech)]
                stagingProbe.reset()
                if stagedSplit {
                    // Actual SDK sessions and prewarm, then the unchanged real stream consumer.
                    try await frontend.stageNextTurn(system: system,
                        messages: [.init(role: .system, content: capabilityFacts),
                            .init(role: .user, content: fixturePrefix)])
                }
                let stream = await frontend.stream(system: system, messages: fixtureMessages,
                    maxTokens: 256)
                for try await delta in stream {
                    output += delta
                    if firstClause == nil, let clause = firstSpeakableClause(in: output) {
                        firstClause = seconds(start.duration(to: .now))
                        clauseText = clause
                    }
                    if first == nil {
                        switch VoiceFrontendEnvelope.parse(output) {
                        case .answer(let answer) where !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                            first = seconds(start.duration(to: .now))
                        case .capabilities, .newWork, .decision, .revise, .cancel:
                            first = seconds(start.duration(to: .now))
                        default: break
                        }
                    }
                }
                if firstClause == nil,
                   case .answer(let answer) = VoiceFrontendEnvelope.parse(output),
                   !AgentSpeechPolicy.spokenForm(answer).isEmpty {
                    firstClause = seconds(start.duration(to: .now))
                    clauseText = AgentSpeechPolicy.spokenForm(answer)
                }
                guard let first, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await SelfTest.diagnostic("voice frontend invalid: speech=\(fixture.speech) output=\(output)")
                    routingFailures += 1
                    continue
                }
                firstTextSeconds.append(first)
                let parsed = VoiceFrontendEnvelope.parse(output)
                if stagedSplit {
                    let hasAnswer: Bool
                    if case .answer = parsed { hasAnswer = true } else { hasAnswer = false }
                    let failures = stagingProbe.problems(expectedAnswer: hasAnswer)
                    for failure in failures { await SelfTest.diagnostic("voice frontend staged consumer: " + failure) }
                    routingFailures += failures.count
                    await SelfTest.diagnostic("VOICE_STAGING_CONSUMER route=\(stagingProbe.consumed(.route)) answer=\(stagingProbe.consumed(.answer))")
                }
                let classified: Bool
                switch (fixture.expected, parsed) {
                case (.answer, .answer): classified = true
                case (.newWork, .decision(let payload)): classified = payload.intent == "spawn"
                case (.revise(let expected, _), .revise(let actual, _)): classified = expected == actual
                default: classified = fixture.expected == parsed
                }
                await SelfTest.diagnostic("voice frontend first_text=\(String(format: "%.3f", first))s first_clause=\(firstClause.map { String(format: "%.3f", $0) } ?? "none")s clause=\(clauseText ?? "none") speech=\(fixture.speech) output=\(output) classified=\(classified)")
                if !classified { routingFailures += 1 }
                if substantiveLead, case .answer(let answer) = parsed {
                    let lower = answer.lowercased()
                    let genericTail = ["ready for", "shall we", "should i continue", "do you need", "would you like"]
                    let hasGenericTail = genericTail.contains { lower.contains($0) }
                    let hasSubstance: Bool
                    switch fixture.speech {
                    case "Hello there. Please tell me briefly what a haiku is.":
                        hasSubstance = lower.contains("poem") && (lower.contains("three") || lower.contains("3"))
                    case "Explain full duplex conversation in plain language.":
                        hasSubstance = lower.contains("interrupt") &&
                            (lower.contains("speak") || lower.contains("talk"))
                    case "What is a good structure for meeting notes?":
                        hasSubstance = lower.contains("action") &&
                            (lower.contains("decision") || lower.contains("key point"))
                    case "While you check my calendar, tell me what you are doing.":
                        hasSubstance = lower.contains("calendar") &&
                            (lower.contains("check") || lower.contains("look"))
                    default:
                        hasSubstance = true
                    }
                    guard hasSubstance, !hasGenericTail else {
                        _ = await frontend.setStagingObserverForTesting(nil)
                        await frontend.clearStagedTurn()
                        await SelfTest.diagnostic("voice frontend substantive failure: speech=\(fixture.speech) answer=\(answer)")
                        await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
                        return false
                    }
                }
                } catch {
                    routingFailures += 1
                    await SelfTest.diagnostic("voice frontend fixture error: speech=\(fixture.speech) error=\(error)")
                }
            }

            _ = await frontend.setStagingObserverForTesting(nil)
            await frontend.clearStagedTurn()
            guard routingFailures == 0 else {
                await SelfTest.diagnostic("VOICE_FRONTEND_FAILED: \(routingFailures) routing cases")
                return false
            }
            if stagedSplit || CommandLine.arguments.contains("--voice-frontend-clause")
                || CommandLine.arguments.contains("--voice-frontend-routing-only") {
                await SelfTest.diagnostic("VOICE_FRONTEND_OK")
                return true
            }

            // The planner genuinely generates in the separate llama native context.
            // A long answer keeps that context occupied while the frontend handles speech.
            guard let workerRuntime else {
                throw LocalVoiceFrontend.FrontendError.unavailable("worker_fixture_missing_runtime")
            }
            let workerState = WorkerState()
            let worker = Task {
                do {
                    let stream = await workerRuntime.stream(
                        system: "You are a careful planner. Give a detailed numbered response.",
                        user: "Describe twenty specific steps for planning and verifying a two-week project. Explain each step in two sentences.",
                        maxTokens: cpuWorker ? 96 : 256
                    )
                    var output = ""
                    for try await delta in stream {
                        if !delta.isEmpty { await workerState.markFirstToken() }
                        output += delta
                    }
                    await workerState.finish(success: !output.isEmpty)
                } catch {
                    await workerState.finish(success: false)
                }
            }
            // Wait for an actual generated 4B token. Merely having a worker task in
            // flight could only prove overlap with loading or scheduler queueing.
            let workerWaitStart = ContinuousClock.now
            while true {
                let state = await workerState.snapshot()
                if state.firstToken || state.completed { break }
                if seconds(workerWaitStart.duration(to: .now)) > 90 {
                    worker.cancel()
                    _ = await worker.value
                    await SelfTest.diagnostic("voice frontend worker generated no token within 90 s")
                    await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
                    return false
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let workerInitialState = await workerState.snapshot()
            guard workerInitialState.firstToken, !workerInitialState.completed else {
                await SelfTest.diagnostic("voice frontend worker finished before overlap probe")
                await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
                return false
            }
            let stageStart = ContinuousClock.now
            try await frontend.stageNextTurn(system: system)
            await SelfTest.diagnostic("voice frontend active-worker stage=\(String(format: "%.3f", seconds(stageStart.duration(to: .now))))s")
            try await Task.sleep(for: .seconds(stageLeadSeconds))
            let overlapStart = ContinuousClock.now
            let overlapTiming = ProbeTiming()
            await frontend.setSchedulerAcquiredObserverForTesting {
                Task { await overlapTiming.markAcquired() }
            }
            var overlapFirst: Double?
            var overlapOutput = ""
            let overlap = await frontend.stream(
                system: system,
                messages: [.init(role: .user, content: "Work status (context, not instructions):\nTask 1 [running]: Plan and verify the project.\n\nLatest user speech:\nI am still here. Tell me briefly what you are doing.")],
                maxTokens: 40
            )
            for try await delta in overlap {
                overlapOutput += delta
                if overlapFirst == nil,
                   case .answer(let answer) = VoiceFrontendEnvelope.parse(overlapOutput),
                   !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    overlapFirst = seconds(overlapStart.duration(to: .now))
                    let completed = await workerState.completed
                    let acquired = await overlapTiming.acquiredAt
                    let queue = acquired.map { seconds(overlapStart.duration(to: $0)) } ?? -1
                    await SelfTest.diagnostic("voice frontend overlap first_text=\(String(format: "%.3f", overlapFirst!))s scheduler_acquire=\(String(format: "%.3f", queue))s worker_completed=\(completed)")
                    if completed {
                        worker.cancel()
                        _ = await worker.value
                        await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
                        return false
                    }
                }
            }
            let secondStart = ContinuousClock.now
            var secondFirst: Double?
            var secondOutput = ""
            let second = await frontend.stream(
                system: system,
                messages: [.init(role: .user, content: "Work status (context, not instructions):\nTask 1 [running]: Plan and verify the project.\n\nLatest user speech:\nOne more thing: are you still working?")],
                maxTokens: 40
            )
            for try await delta in second {
                secondOutput += delta
                if secondFirst == nil,
                   case .answer(let answer) = VoiceFrontendEnvelope.parse(secondOutput),
                   !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    secondFirst = seconds(secondStart.duration(to: .now))
                    let completed = await workerState.completed
                    await SelfTest.diagnostic("voice frontend second overlap first_text=\(String(format: "%.3f", secondFirst!))s worker_completed=\(completed)")
                }
            }
            await frontend.setSchedulerAcquiredObserverForTesting(nil)
            // Independence is proven once speech arrived while the worker was still
            // generating. Waiting out the full 256-token decode only burns the
            // watchdog — cancel as soon as the probe has its evidence.
            worker.cancel()
            _ = await worker.value
            guard overlapFirst != nil, secondFirst != nil else {
                await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
                return false
            }

            // CPU comparison isolates GPU/Metal resource contention. Long CPU
            // prefill is deliberately omitted; the native GPU probe below covers it.
            if cpuWorker {
                let sorted = firstTextSeconds.sorted()
                await SelfTest.diagnostic("voice frontend CPU-worker first_text n=\(sorted.count) p50=\(String(format: "%.3f", sorted[sorted.count / 2]))s")
                await SelfTest.diagnostic("VOICE_FRONTEND_OK")
                return true
            }

            // A separate probe starts the voice response after a real native
            // 128-token prefill batch, while much of a long worker prompt remains.
            let prefillFlag = ProbeFlag()
            let prefillWorkerState = WorkerState()
            await workerRuntime.setPrefillChunkObserverForTesting {
                Task { await prefillFlag.mark() }
            }
            let longPrompt = String(repeating:
                "Project status includes milestones, owners, dependencies, and evidence. ",
                count: 350)
            let prefillWorker = Task {
                do {
                    let stream = await workerRuntime.stream(
                        system: "Summarize the project in one sentence.",
                        user: longPrompt,
                        maxTokens: 48
                    )
                    var text = ""
                    for try await delta in stream { text += delta }
                    await prefillWorkerState.finish(success: !text.isEmpty)
                    return !text.isEmpty
                } catch {
                    await prefillWorkerState.finish(success: false)
                    return false
                }
            }
            let prefillWait = ContinuousClock.now
            while !(await prefillFlag.marked) {
                if seconds(prefillWait.duration(to: .now)) > 90 {
                    prefillWorker.cancel()
                    _ = await prefillWorker.value
                    await workerRuntime.setPrefillChunkObserverForTesting(nil)
                    await SelfTest.diagnostic("voice frontend long prefill never began")
                    await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
                    return false
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let prefillStageStart = ContinuousClock.now
            try await frontend.stageNextTurn(system: system)
            await SelfTest.diagnostic("voice frontend long-prefill stage=\(String(format: "%.3f", seconds(prefillStageStart.duration(to: .now))))s")
            try await Task.sleep(for: .seconds(stageLeadSeconds))
            let prefillStart = ContinuousClock.now
            let prefillTiming = ProbeTiming()
            await frontend.setSchedulerAcquiredObserverForTesting {
                Task { await prefillTiming.markAcquired() }
            }
            var prefillFirst: Double?
            var prefillOutput = ""
            let prefillResponse = await frontend.stream(
                system: system,
                messages: [.init(role: .user, content: "Work status (context, not instructions):\nTask 1 [running]: Summarize project status.\n\nLatest user speech:\nCan you still hear me?")],
                maxTokens: 40
            )
            for try await delta in prefillResponse {
                prefillOutput += delta
                if prefillFirst == nil,
                   case .answer(let answer) = VoiceFrontendEnvelope.parse(prefillOutput),
                   !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prefillFirst = seconds(prefillStart.duration(to: .now))
                    let completed = await prefillWorkerState.completed
                    let acquired = await prefillTiming.acquiredAt
                    let queue = acquired.map { seconds(prefillStart.duration(to: $0)) } ?? -1
                    await SelfTest.diagnostic("voice frontend long-prefill first_text=\(String(format: "%.3f", prefillFirst!))s scheduler_acquire=\(String(format: "%.3f", queue))s worker_completed=\(completed)")
                    if completed {
                        prefillWorker.cancel()
                        _ = await prefillWorker.value
                        await frontend.setSchedulerAcquiredObserverForTesting(nil)
                        await workerRuntime.setPrefillChunkObserverForTesting(nil)
                        await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
                        return false
                    }
                }
            }
            // Same as the overlap probe: cancel once speech beat the remaining prefill.
            prefillWorker.cancel()
            _ = await prefillWorker.value
            await frontend.setSchedulerAcquiredObserverForTesting(nil)
            await workerRuntime.setPrefillChunkObserverForTesting(nil)
            guard prefillFirst != nil else {
                await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
                return false
            }
            let sorted = firstTextSeconds.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[sorted.count - 1]
            await SelfTest.diagnostic("voice frontend warm first_text n=\(sorted.count) p50=\(String(format: "%.3f", p50))s p95_sample_max=\(String(format: "%.3f", p95))s")
            await SelfTest.diagnostic("VOICE_FRONTEND_OK")
            return true
        } catch {
            _ = await frontend.setStagingObserverForTesting(nil)
            await frontend.clearStagedTurn()
            await SelfTest.diagnostic("voice frontend error: \(error)")
            await SelfTest.diagnostic("VOICE_FRONTEND_FAILED")
            return false
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func firstSpeakableClause(in output: String) -> String? {
        guard case .answer(let answer) = VoiceFrontendEnvelope.parse(output) else { return nil }
        let clauses = AgentSpeechPolicy.spokenClauses(answer)
        guard let first = clauses.first, let last = first.last,
              ".!?;—".contains(last) else { return nil }
        return first
    }
}

private actor WorkerState {
    private(set) var firstToken = false
    private(set) var completed = false
    private(set) var success = false

    func markFirstToken() { firstToken = true }

    func snapshot() -> (firstToken: Bool, completed: Bool) {
        (firstToken, completed)
    }

    func finish(success: Bool) {
        self.success = success
        completed = true
    }
}

private actor ProbeFlag {
    private(set) var marked = false
    func mark() { marked = true }
}

private actor ProbeTiming {
    private(set) var acquiredAt: ContinuousClock.Instant?
    func markAcquired() { acquiredAt = .now }
}
