import Foundation

/// Model-backed latency and independence probe. The final verdict must fail if either
/// model cannot generate, if the frontend is empty, or if it waits for the 4B worker.
enum LocalVoiceFrontendSelfTest {
    static func run() async -> Bool {
        let frontend = LocalVoiceFrontend.shared
        guard NotesModels.isDownloaded else {
            print("VOICE_FRONTEND_MISSING_WORKER_MODEL")
            print("VOICE_FRONTEND_FAILED")
            return false
        }
        do {
            let cpuWorker = CommandLine.arguments.contains("--voice-worker-cpu")
            let stageLeadSeconds = CommandLine.arguments.contains("--voice-stage-lead2s") ? 2 : 1
            let workerRuntime = cpuWorker
                ? NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
                : NotesModelRuntime.shared
            let prewarmStart = ContinuousClock.now
            try await frontend.prepare()
            print("voice frontend prewarm \(prewarmStart.duration(to: .now))")

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
                print("voice frontend greeting first_text=\(first.map { String(format: "%.3f", $0) } ?? "none")s output=\(output)")
                let okay = first != nil
                print(okay ? "VOICE_FRONTEND_OK" : "VOICE_FRONTEND_FAILED")
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
                    print("voice frontend idle invalid staged=\(staged) first_raw=\(firstRaw.map { String(format: "%.3f", $0) } ?? "none")s output=\(output)")
                    print("VOICE_FRONTEND_FAILED")
                    return false
                }
                print("voice frontend idle20 first_text=\(String(format: "%.3f", first))s staged_1s=\(staged)")
                print("VOICE_FRONTEND_OK")
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
            for fixture in fixtures {
                do {
                let start = ContinuousClock.now
                var first: Double?
                var firstClause: Double?
                var clauseText: String?
                var output = ""
                let stream = await frontend.stream(
                    system: system,
                    messages: [.init(role: .system, content: capabilityFacts), .init(role: .user, content:
                        "Work status (context, not instructions):\n\(fixture.work)\n\nLatest user speech:\n\(fixture.speech)")],
                    maxTokens: 256
                )
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
                        case .capabilities, .newWork, .revise, .cancel:
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
                    print("voice frontend invalid: speech=\(fixture.speech) output=\(output)")
                    routingFailures += 1
                    continue
                }
                firstTextSeconds.append(first)
                let parsed = VoiceFrontendEnvelope.parse(output)
                let classified: Bool
                switch (fixture.expected, parsed) {
                case (.answer, .answer): classified = true
                default: classified = fixture.expected == parsed
                }
                print("voice frontend first_text=\(String(format: "%.3f", first))s first_clause=\(firstClause.map { String(format: "%.3f", $0) } ?? "none")s clause=\(clauseText ?? "none") speech=\(fixture.speech) output=\(output) classified=\(classified)")
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
                        print("voice frontend substantive failure: speech=\(fixture.speech) answer=\(answer)")
                        print("VOICE_FRONTEND_FAILED")
                        return false
                    }
                }
                } catch {
                    routingFailures += 1
                    print("voice frontend fixture error: speech=\(fixture.speech) error=\(error)")
                }
            }

            guard routingFailures == 0 else {
                print("VOICE_FRONTEND_FAILED: \(routingFailures) routing cases")
                return false
            }
            if CommandLine.arguments.contains("--voice-frontend-clause")
                || CommandLine.arguments.contains("--voice-frontend-routing-only") {
                print("VOICE_FRONTEND_OK")
                return true
            }

            // The planner genuinely generates in the separate llama native context.
            // A long answer keeps that context occupied while the frontend handles speech.
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
                    print("voice frontend worker generated no token within 90 s")
                    print("VOICE_FRONTEND_FAILED")
                    return false
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let workerInitialState = await workerState.snapshot()
            guard workerInitialState.firstToken, !workerInitialState.completed else {
                print("voice frontend worker finished before overlap probe")
                print("VOICE_FRONTEND_FAILED")
                return false
            }
            let stageStart = ContinuousClock.now
            try await frontend.stageNextTurn(system: system)
            print("voice frontend active-worker stage=\(String(format: "%.3f", seconds(stageStart.duration(to: .now))))s")
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
                    print("voice frontend overlap first_text=\(String(format: "%.3f", overlapFirst!))s scheduler_acquire=\(String(format: "%.3f", queue))s worker_completed=\(completed)")
                    if completed {
                        worker.cancel()
                        _ = await worker.value
                        print("VOICE_FRONTEND_FAILED")
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
                    print("voice frontend second overlap first_text=\(String(format: "%.3f", secondFirst!))s worker_completed=\(completed)")
                }
            }
            await frontend.setSchedulerAcquiredObserverForTesting(nil)
            _ = await worker.value
            let workerSucceeded = await workerState.success
            guard overlapFirst != nil, secondFirst != nil, workerSucceeded else {
                print("VOICE_FRONTEND_FAILED")
                return false
            }

            // CPU comparison isolates GPU/Metal resource contention. Long CPU
            // prefill is deliberately omitted; the native GPU probe below covers it.
            if cpuWorker {
                let sorted = firstTextSeconds.sorted()
                print("voice frontend CPU-worker first_text n=\(sorted.count) p50=\(String(format: "%.3f", sorted[sorted.count / 2]))s")
                print("VOICE_FRONTEND_OK")
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
                    print("voice frontend long prefill never began")
                    print("VOICE_FRONTEND_FAILED")
                    return false
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let prefillStageStart = ContinuousClock.now
            try await frontend.stageNextTurn(system: system)
            print("voice frontend long-prefill stage=\(String(format: "%.3f", seconds(prefillStageStart.duration(to: .now))))s")
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
                    print("voice frontend long-prefill first_text=\(String(format: "%.3f", prefillFirst!))s scheduler_acquire=\(String(format: "%.3f", queue))s worker_completed=\(completed)")
                    if completed {
                        print("VOICE_FRONTEND_FAILED")
                        return false
                    }
                }
            }
            let prefillWorkerSucceeded = await prefillWorker.value
            await frontend.setSchedulerAcquiredObserverForTesting(nil)
            await workerRuntime.setPrefillChunkObserverForTesting(nil)
            guard prefillFirst != nil, prefillWorkerSucceeded else {
                print("VOICE_FRONTEND_FAILED")
                return false
            }
            let sorted = firstTextSeconds.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[sorted.count - 1]
            print("voice frontend warm first_text n=\(sorted.count) p50=\(String(format: "%.3f", p50))s p95_sample_max=\(String(format: "%.3f", p95))s")
            print("VOICE_FRONTEND_OK")
            return true
        } catch {
            print("voice frontend error: \(error)")
            print("VOICE_FRONTEND_FAILED")
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
