import Foundation

/// `--selftest-toolloop-live` (P1-01): the one number that says whether the Agent got
/// better at using tools.
///
/// Thirty canonical requests go through the real `RealtimeAgent.handle(_, source: .text)`
/// on the model the Agent role resolves to, with every tool answered by a fixture — nothing
/// is sent, nothing personal is read, and no approval card appears. Each case gets one
/// verdict; the score is the Phase 1 metric, and `--quick` (the fixed 10-case subset) is the
/// per-task gate.
///
/// It reads the owner's saved Agent-role choice without moving any key. Under the harness
/// `.shared` reads an empty isolated suite, so the stored `modelRoles.agent` token is read
/// directly and read-only — the same read the two allow-listed flags perform — and the
/// resolved file is adopted explicitly through the runtime, because the harness otherwise
/// keeps the built-in spec.
@MainActor
enum ToolLoopLiveEval {
    /// Enabled only by this self-test. The production Agent never asks Needle to plan a turn.
    static var needleFirstForTesting = false
    static var needleTurnsForTesting = 0
    static var needleCallsForTesting = 0
    static var needleErrorsForTesting = 0
    static var needleResponseForTesting: ((String, [FunctionCallTool]) async throws -> NeedleResponse)?

    struct ResolvedModel {
        let provider: any LLMProvider
        let label: String
        let roleChoice: String
        let isFallback: Bool
    }

    struct Options {
        var model: String?
        var contextTokens: Int?
        var only: [String]?
        var report: String?
        var passAt: Int?
        var turnLimit: Duration = .seconds(150)
        var allowCloud = false
        var quick = false
        var needleFirst = false
    }

    struct CaseResult {
        let evalCase: LiveEvalCase
        let verdict: LiveEvalVerdict
        let seconds: Double
        let replies: [String]
        let calls: [LiveEvalLoggedCall]
        let trace: [PlannerTraceEvent]
        let usage: [UsageRecord]
        let infrastructureError: String?
    }

    // MARK: - Entry

    static func runSelfTest() async -> Bool {
        let options = parseOptions()
        if options.quick, options.only != nil {
            SelfTest.diagnostic("TOOLLOOP_LIVE_FAILED: --quick and --only are exclusive")
            return false
        }
        if let unknown = options.only?.first(where: { LiveEvalCases.caseWithID(id: $0) == nil }) {
            SelfTest.diagnostic("TOOLLOOP_LIVE_FAILED: unknown case \(unknown)")
            return false
        }
        let selected = selectCases(options)
        guard !selected.isEmpty else {
            SelfTest.diagnostic("TOOLLOOP_LIVE_FAILED: no cases selected")
            return false
        }
        if options.needleFirst && !NeedleModels.isDownloaded {
            SelfTest.diagnostic("TOOLLOOP_LIVE_ABSENT: Needle 3 is not installed")
            return false
        }
        needleTurnsForTesting = 0
        needleCallsForTesting = 0
        needleErrorsForTesting = 0
        guard let resolved = await resolveModel(
            argument: options.model, allowCloud: options.allowCloud,
            contextTokens: options.contextTokens
        ) else {
            let role = agentRoleChoice().token
            SelfTest.diagnostic(
                "TOOLLOOP_LIVE_ABSENT: no answerable model for the Agent role (role: \(role))")
            return false
        }

        SelfTest.diagnostic(
            "TOOLLOOP_LIVE_MODEL: \(resolved.provider.id.rawValue) "
                + "\"\(resolved.provider.displayModelName)\" ctx=\(resolved.provider.contextTokens) "
                + "role=\(resolved.roleChoice)\(resolved.isFallback ? " FALLBACK" : "")")
        // N02 asks the reply to name the model that is running; the grader can only check
        // that against the model this run actually resolved.
        LiveEvalGrader.modelName = resolved.provider.displayModelName

        // The run must not touch the owner's stores. Capture first; compare after.
        let before = StoreSnapshot.capture()

        do {
            if resolved.provider.id == .appLLM {
                try await NotesModelRuntime.shared.prepareForConversation()
            }
            _ = try await resolved.provider.complete(
                system: "Reply with the single word OK.", user: "Ready?", maxTokens: 4)
        } catch {
            SelfTest.diagnostic(
                "TOOLLOOP_LIVE_FAILED: \(resolved.label) did not answer a warm-up "
                    + "(\(error.localizedDescription))")
            return false
        }

        let began = ContinuousClock.now
        let results = await runCases(
            selected, options: options, fixtures: LiveEvalFixtures(), provider: resolved.provider)
        let elapsed = began.duration(to: .now).secondsValue

        // P1-27: the score counts the thirty and only the thirty. The owner-log set is
        // reported beside it, and the gate that reads it is the Phase 1 exit — so a red owner
        // case is a fact this run records rather than a verdict it withholds.
        let scored = results.filter { $0.evalCase.scored }
        let passed = scored.filter { $0.verdict.isPass }.count
        let owner = LiveEvalCases.ownerLogSubset(of: results.map {
            ($0.evalCase.id, $0.verdict.isPass)
        })
        let baseBar = options.passAt ?? 25
        // The bar scales with the *scored* cases, not the selected ones: appending the owner
        // set to a full run must not move a threshold, and a run that selected owner cases
        // only has no score to gate on at all.
        let bar: Int
        if scored.isEmpty {
            bar = 0
        } else if options.quick || options.only != nil {
            bar = Int(ceil(Double(baseBar) * Double(scored.count) / 30.0))
        } else {
            bar = baseBar
        }
        let tag = options.quick ? " (quick)" : ""
        let interrupted = (options.needleFirst && needleErrorsForTesting > 0
            ? "Needle failed on \(needleErrorsForTesting) turn(s)" : nil)
            ?? results.last?.infrastructureError ??
            (results.last?.verdict == .timeout ? "a model turn exceeded the time limit" : nil)
        if options.needleFirst {
            SelfTest.diagnostic("TOOLLOOP_LIVE_NEEDLE turns=\(needleTurnsForTesting) "
                + "calls=\(needleCallsForTesting) errors=\(needleErrorsForTesting)")
        }

        printClassTally(results)
        if interrupted == nil {
            SelfTest.diagnostic("TOOLLOOP_LIVE_SCORE \(passed)/\(scored.count)\(tag)")
        } else {
            SelfTest.diagnostic("TOOLLOOP_LIVE_PARTIAL \(passed)/\(scored.count)\(tag)")
        }
        if owner.isEmpty == false && interrupted == nil {
            let ownerPassed = owner.filter(\.isPass).count
            SelfTest.diagnostic("TOOLLOOP_LIVE_OWNER \(ownerPassed)/\(owner.count)")
        }
        guard let reportPath = writeReport(
            results: results, model: resolved, bar: bar, options: options, elapsed: elapsed,
            interrupted: interrupted
        ) else { return false }
        SelfTest.diagnostic("TOOLLOOP_LIVE_REPORT \(reportPath)")
        SelfTest.diagnostic("TOOLLOOP_LIVE_ELAPSED \(String(format: "%.1f", elapsed))")

        if let change = StoreSnapshot.firstDifference(before, StoreSnapshot.capture()) {
            SelfTest.diagnostic("TOOLLOOP_LIVE_FAILED: the run changed \(change)")
            return false
        }
        if let interrupted {
            SelfTest.diagnostic("TOOLLOOP_LIVE_INCOMPLETE: \(interrupted); "
                + "\(results.count)/\(selected.count) cases attempted")
            return false
        }
        guard scored.isEmpty == false else {
            // `--only O07` is a diagnostic, not a gate. Saying so in words beats printing
            // `TOOLLOOP_LIVE_OK: 0/0`, which reads like a score of nothing against everything.
            SelfTest.diagnostic(
                "TOOLLOOP_LIVE_OK: no scored case in this selection — the "
                    + "TOOLLOOP_LIVE_OWNER line above is the result")
            return true
        }
        if passed >= bar {
            SelfTest.diagnostic(
                "TOOLLOOP_LIVE_OK: \(passed)/\(scored.count)\(tag) on \(resolved.label)")
            return true
        }
        SelfTest.diagnostic(
            "TOOLLOOP_LIVE_FAILED: \(passed)/\(scored.count)\(tag) on \(resolved.label) — "
                + "below the pass bar \(bar)")
        return false
    }

    // MARK: - Options and cases

    private static func parseOptions() -> Options {
        var options = Options()
        options.model = SelfTest.value(after: "--model")
        options.contextTokens = SelfTest.value(after: "--context-tokens")
            .flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        if let only = SelfTest.value(after: "--only") {
            options.only = only.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        options.report = SelfTest.value(after: "--report")
        options.passAt = SelfTest.value(after: "--pass-at").flatMap(Int.init)
        if let seconds = SelfTest.value(after: "--turn-limit").flatMap(Double.init), seconds > 0 {
            options.turnLimit = .seconds(seconds)
        }
        options.allowCloud = CommandLine.arguments.contains("--allow-cloud")
        options.quick = CommandLine.arguments.contains("--quick")
        options.needleFirst = CommandLine.arguments.contains("--needle-first")
        return options
    }

    private static func selectCases(_ options: Options) -> [LiveEvalCase] {
        if options.quick {
            return LiveEvalCases.quickIDs.compactMap { LiveEvalCases.caseWithID(id: $0) }
        }
        if let only = options.only {
            return only.compactMap { LiveEvalCases.caseWithID(id: $0) }
        }
        // Everything, P1-27: the thirty that are scored and the owner's ten that are only
        // reported. `--quick` is still the fixed scored subset, so the per-task gate costs
        // what it cost before the owner set existed.
        return LiveEvalCases.all
    }

    /// Benchmark only: Needle proposes one first step from the Agent's existing manifest.
    /// The planner passes it directly to `ToolStepRunner`, the one executor seam.
    static func needleFirstCall(
        request: String, manifest: AgentCapabilityManifest
    ) async -> AgentToolCall? {
        guard needleFirstForTesting, SelfTest.isRunning else { return nil }
        guard !manifest.selectedIntents.isEmpty else { return nil }
        needleTurnsForTesting += 1
        // Keep the manifest's matched intent classes intact. If they do not fit Needle's
        // window, leave the first step to the ordinary planner rather than split a class.
        let matched = manifest.selected.filter { manifest.selectedIntents.contains($0.intent) }
        guard !matched.isEmpty, matched.count <= FunctionCallCatalogue.maxTools else {
            SelfTest.diagnostic("TOOLLOOP_LIVE_NEEDLE_TURN none: matched tool class does not fit")
            return nil
        }
        let shortlist = matched
        SelfTest.diagnostic("TOOLLOOP_LIVE_NEEDLE_TOOLS "
            + shortlist.map(\.id).joined(separator: ","))
        let tools = needleTools(shortlist)
        let started = ContinuousClock.now
        do {
            let response: NeedleResponse
            if let override = needleResponseForTesting {
                response = try await override(request, tools)
            } else {
                response = try await NeedleRunner.shared.run(input: request, tools: tools, facts: [])
            }
            let seconds = started.duration(to: .now).secondsValue
            if response.success == false {
                needleErrorsForTesting += 1
                SelfTest.diagnostic("TOOLLOOP_LIVE_NEEDLE_ERROR "
                    + (response.errorCode ?? response.error ?? "engine failed"))
                return nil
            }
            guard let call = validatedNeedleCall(response, request: request, shortlist: shortlist) else {
                SelfTest.diagnostic("TOOLLOOP_LIVE_NEEDLE_TURN none \(String(format: "%.3f", seconds))s")
                return nil
            }
            needleCallsForTesting += 1
            SelfTest.diagnostic("TOOLLOOP_LIVE_NEEDLE_TURN \(call.name) "
                + "confidence=\(String(format: "%.3f", response.confidence ?? 0)) "
                + "\(String(format: "%.3f", seconds))s")
            return call
        } catch {
            needleErrorsForTesting += 1
            SelfTest.diagnostic("TOOLLOOP_LIVE_NEEDLE_ERROR \(error.localizedDescription)")
            return nil
        }
    }

    /// Separate from the passive meeting watcher's catalogue: this seam is pinned by
    /// the production-loop regression test without running either model.
    static func needleTools(_ shortlist: [AgentCapabilityManifest.Entry]) -> [FunctionCallTool] {
        let tools = shortlist.map { entry in
            FunctionCallTool(
                id: entry.id, description: entry.modelDescription,
                parameters: entry.parameters.map { parameter in
                    FunctionCallTool.Parameter(name: parameter.name, description: parameter.description,
                                               isRequired: parameter.isRequired)
                })
        }
        return FunctionCallRelevance.wireTools(for: tools)
    }

    static func validatedNeedleCall(
        _ response: NeedleResponse, request: String, shortlist: [AgentCapabilityManifest.Entry]
    ) -> AgentToolCall? {
        guard response.validation?.negation != true,
              let call = response.functionCalls.first,
              shortlist.contains(where: { $0.id == call.name }) else { return nil }
        let flagged = response.ungroundedArguments(for: call.name)
        return AgentToolCall(name: call.name,
                             arguments: call.arguments.filter { !flagged.contains($0.key) },
                             rationale: "Needle first pass", evidence: nil)
    }

    // MARK: - Model resolution

    /// The Agent role's choice, read without moving any key.
    private static func agentRoleChoice() -> ModelRoleChoice {
        if let token = UserDefaults.standard.string(forKey: "modelRoles.agent"),
           let choice = ModelRoleChoice(token: token) {
            return choice
        }
        return ModelRoleStore.shared.choice(for: .agent)
    }

    static func resolveModel(
        argument: String?, allowCloud: Bool, contextTokens: Int? = nil
    ) async -> ResolvedModel? {
        if argument == "apple" {
            guard FoundationModelFormatter.unavailableReason == nil else { return nil }
            return ResolvedModel(
                provider: FoundationModelLLMProvider(),
                label: "Apple's built-in intelligence",
                roleChoice: "apple", isFallback: false)
        }
        if let argument, argument.hasPrefix("openrouter:") {
            guard allowCloud else { return nil }
            let id = String(argument.dropFirst("openrouter:".count))
            guard !id.isEmpty else { return nil }
            let provider = LLMProviders.make(
                .openRouter, modelID: id, contextTokens: contextTokens ?? 32_768)
            guard let available = await withBoundedWait(.seconds(15), {
                await provider.unavailableReason == nil
            }) else {
                SelfTest.diagnostic("TOOLLOOP_LIVE_CLOUD_UNAVAILABLE: credential lookup timed out")
                return nil
            }
            guard available else {
                SelfTest.diagnostic("TOOLLOOP_LIVE_CLOUD_UNAVAILABLE: OpenRouter key unavailable")
                return nil
            }
            return ResolvedModel(
                provider: provider, label: provider.displayModelName,
                roleChoice: "cloud:\(id)", isFallback: false)
        }
        if let argument, argument.hasPrefix("file:") {
            let path = String(argument.dropFirst("file:".count))
            let url = URL(fileURLWithPath: path)
            guard url.path == path,
                  url.pathExtension.lowercased() == "gguf",
                  // ModelSpec resolves the filename under this directory regardless
                  // of the URL supplied here. Reject paths it would silently ignore.
                  url.deletingLastPathComponent().standardizedFileURL ==
                      ModelSpec.directory.standardizedFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let bytes = (attributes[.size] as? NSNumber)?.int64Value,
                  bytes > 0 else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let model = InstalledLocalModel(
                id: "benchmark/\(name)", displayName: name, fileURL: url,
                parameterBillions: nil, quantization: nil,
                bytes: bytes, isBuiltIn: false)
            return await adopt(model, roleChoice: "file:\(name)", isFallback: false)
        }
        if let id = argument, argument != "agent" {
            guard let model = InstalledModelLibrary.shared.usableModels.first(where: { $0.id == id })
            else { return nil }
            return await adopt(model, roleChoice: "installed:\(id)", isFallback: false)
        }

        let choice = agentRoleChoice()
        switch choice {
        case .installedModel(let id):
            if let model = InstalledModelLibrary.shared.usableModels.first(where: { $0.id == id }),
               let resolved = await adopt(model, roleChoice: choice.token, isFallback: false) {
                return resolved
            }
        case .appleFoundation:
            if FoundationModelFormatter.unavailableReason == nil {
                return ResolvedModel(
                    provider: FoundationModelLLMProvider(),
                    label: "Apple's built-in intelligence",
                    roleChoice: choice.token, isFallback: false)
            }
        case .localServer:
            if let provider = ModelRoleStore.shared.localServerProviderForAgentRole(),
               await provider.unavailableReason == nil {
                return ResolvedModel(
                    provider: provider, label: provider.displayModelName,
                    roleChoice: choice.token, isFallback: false)
            }
        case .builtIn:
            if NotesModels.spec.isDownloaded {
                await NotesModelRuntime.shared.select(nil)
                let provider = LlamaLLMProvider(modelName: NotesModels.spec.displayName)
                if await provider.unavailableReason == nil {
                    return ResolvedModel(
                        provider: provider, label: NotesModels.spec.displayName,
                        roleChoice: choice.token, isFallback: false)
                }
            }
        case .cloud:
            if allowCloud {
                let provider = LLMProviders.make(
                    .openRouter,
                    modelID: Settings.shared.openRouterAgentModelID,
                    contextTokens: Settings.shared.openRouterAgentContextTokens)
                if await provider.unavailableReason == nil {
                    return ResolvedModel(
                        provider: provider, label: provider.displayModelName,
                        roleChoice: choice.token, isFallback: false)
                }
            }
        case .app:
            // An agent app is a separate process, never an LLM provider. It cannot answer
            // this eval even with cloud allowed.
            break
        }

        // Production's fallback semantics: whatever local model can run, then Apple FM.
        if let provider = await LLMProviders.resolve(preferring: .appLLM) {
            return ResolvedModel(
                provider: provider, label: provider.displayModelName,
                roleChoice: choice.token, isFallback: true)
        }
        return nil
    }

    private static func adopt(
        _ model: InstalledLocalModel, roleChoice: String, isFallback: Bool
    ) async -> ResolvedModel? {
        // The harness keeps the built-in spec unless the eval adopts explicitly; `select`
        // completes the switch before `unavailableReason` asks what will answer.
        await NotesModelRuntime.shared.select(model)
        let provider = LlamaLLMProvider(modelName: model.displayName)
        guard await provider.unavailableReason == nil else { return nil }
        return ResolvedModel(
            provider: provider, label: model.displayName,
            roleChoice: roleChoice, isFallback: isFallback)
    }

    // MARK: - Running

    private static func runCases(
        _ cases: [LiveEvalCase], options: Options, fixtures: LiveEvalFixtures,
        provider: any LLMProvider
    ) async -> [CaseResult] {
        let agent = RealtimeAgent.shared
        // The real provider through the production-routing seam: it keeps the eval off the
        // Codex hand-off (which would launch another app) and off the multi-step OpenRouter
        // reroute. Production budgets stay on: `budgetForTesting` stays nil, so every case
        // runs on the real `ToolLoopBudget` this run's turn resolves.
        agent.localModelProviderForTesting = provider
        needleFirstForTesting = options.needleFirst
        agent.budgetForTesting = nil
        agent.fileRetrievalForTesting = fixtures.files
        agent.denyUnattendedApprovalsForTesting = true
        // P1-03 replaced `toolGatesForTesting` with a whole `AgentCapabilityInputs`, so the
        // run pins the roster the way a person would configure it — every switch on except
        // skills, which the eval does not grade — instead of four booleans that could not say
        // anything about consent or readiness.
        var evalInputs = AgentCapabilityInputs.allEnabled(
            tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: .voiceFrontend)
        evalInputs.switches.skills = false
        AgentCapabilityManifestBuilder.inputsOverrideForTesting = evalInputs
        AgentToolExecutor.fakeForTesting = fixtures.run
        defer {
            agent.localModelProviderForTesting = nil
            needleFirstForTesting = false
            agent.budgetForTesting = nil
            agent.fileRetrievalForTesting = nil
            agent.plannerTraceForTesting = nil
            agent.denyUnattendedApprovalsForTesting = false
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = nil
            AgentToolExecutor.fakeForTesting = nil
        }

        var results: [CaseResult] = []
        for evalCase in cases {
            AgentSession.shared.startNewConversation()
            fixtures.beginCase()
            var replies: [String] = []
            var trace: [PlannerTraceEvent] = []
            var turnIDs: [UUID] = []
            agent.plannerTraceForTesting = { trace.append($0) }
            var harnessTimedOut = false
            let began = ContinuousClock.now

            var turns = evalCase.turns
            var index = 0
            var followUpSent = false
            while index < turns.count {
                fixtures.setTurn(index)
                let text = turns[index]
                let turn = await withBoundedWait(options.turnLimit) {
                    await agent.handle(text, source: .text)
                }
                turnIDs.append(agent.currentTurnID)
                guard let turn else {
                    agent.cancel()
                    harnessTimedOut = true
                    replies.append("")
                    break
                }
                replies.append(turn.reply)
                index += 1
                if !followUpSent, index == turns.count,
                   let followUp = evalCase.followUpIfQuestion,
                   turn.reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
                    turns.append(followUp)
                    followUpSent = true
                }
            }
            let seconds = began.duration(to: .now).secondsValue
            agent.plannerTraceForTesting = nil

            UsageLog.shared.flush()
            let usage = UsageLog.shared.load().filter { row in
                guard let turnID = row.turnID else { return false }
                return turnIDs.contains(turnID)
            }
            let failedPass = usage.first { $0.finishReason == "error" }
            let infrastructureError = failedPass?.errorMessage ??
                (failedPass == nil ? nil : "the model provider failed")
            let verdict: LiveEvalVerdict = infrastructureError != nil ? .error :
                (harnessTimedOut ? .timeout : LiveEvalGrader.grade(
                    case: evalCase, replies: replies, calls: fixtures.calls, trace: trace))

            let result = CaseResult(
                evalCase: evalCase, verdict: verdict, seconds: seconds,
                replies: replies, calls: fixtures.calls, trace: trace, usage: usage,
                infrastructureError: infrastructureError)
            results.append(result)
            printCase(result)
            // A timed-out provider may keep decoding despite task cancellation. Starting
            // the next case would make both its time and its answer unreliable.
            if infrastructureError != nil || harnessTimedOut { break }
        }
        return results
    }

    // MARK: - Output

    private static func printCase(_ result: CaseResult) {
        let tools = result.calls.map { call in
            let arguments = call.arguments.keys.sorted()
                .map { "\($0)=\(call.arguments[$0] ?? "")" }
                .joined(separator: ",")
            return arguments.isEmpty ? call.toolID : "\(call.toolID)(\(arguments))"
        }.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        let reply = result.replies.last ?? ""
        SelfTest.diagnostic(
            "TOOLLOOP_LIVE_CASE \(result.evalCase.id) \(result.verdict.rawValue) "
                + "\(String(format: "%.1f", result.seconds))s turns=\(result.replies.count) "
                + "tools=\(tools.isEmpty ? "-" : tools) "
                + "reply=\"\(reply.replacingOccurrences(of: "\n", with: " ").prefix(160))\"")
    }

    private static func printClassTally(_ results: [CaseResult]) {
        let counts = Dictionary(grouping: results, by: \.verdict).mapValues(\.count)
        SelfTest.diagnostic(
            "TOOLLOOP_LIVE_CLASSES pass=\(counts[.pass] ?? 0) error=\(counts[.error] ?? 0) "
                + "timeout=\(counts[.timeout] ?? 0) leak=\(counts[.leak] ?? 0) "
                + "refusal=\(counts[.refusal] ?? 0) wrong_tool=\(counts[.wrongTool] ?? 0) "
                + "fabricated=\(counts[.fabricated] ?? 0) missed_tool=\(counts[.missedTool] ?? 0) "
                + "ungrounded=\(counts[.ungrounded] ?? 0) filler=\(counts[.filler] ?? 0)")
    }

    // MARK: - Report

    private struct ReportRow: Codable {
        var id: String
        var verdict: String
        var seconds: Double
        var turns: Int
        var tools: [String]
        var reply: String
        var evidence: String
        var expectedFix: String
        var rounds: Int
        var lastSystemCharacters: Int?
        var lastUserCharacters: Int?
        var lastMaxTokens: Int?
        var lastRaw: String?
        var usagePasses: [String]
    }

    private static func reportRows(_ results: [CaseResult]) -> [ReportRow] {
        results.map { result in
            let rounds = result.trace.compactMap { event -> PlannerTraceEvent? in
                if case .round = event { return event }
                return nil
            }
            var lastSystem: Int?
            var lastUser: Int?
            var lastMaxTokens: Int?
            var lastRaw: String?
            for event in rounds.reversed() {
                if case .round(_, let system, let user, let maxTokens, let raw, _) = event {
                    lastSystem = system
                    lastUser = user
                    lastMaxTokens = maxTokens
                    lastRaw = raw
                    break
                }
            }
            let tools = result.calls.map { call in
                let arguments = call.arguments.keys.sorted()
                    .map { "\($0)=\(call.arguments[$0] ?? "")" }
                    .joined(separator: ",")
                return arguments.isEmpty ? call.toolID : "\(call.toolID)(\(arguments))"
            }
            let usage = result.usage.map { row in
                "\(row.feature)/\(row.pass) \(row.provider) \(row.modelID) "
                    + "prompt=\(row.promptTokens ?? 0) completion=\(row.completionTokens ?? 0) "
                    + "reasoning=\(row.reasoningTokens ?? 0) ttft=\(row.ttftMs ?? 0)ms "
                    + "total=\(row.totalMs)ms finish=\(row.finishReason ?? "-") "
                    + "proposed=\(row.toolsProposed?.joined(separator: "+") ?? "-") "
                    + "executed=\(row.toolsExecuted?.map(\.id).joined(separator: "+") ?? "-")"
            }
            return ReportRow(
                id: result.evalCase.id,
                verdict: result.verdict.rawValue,
                seconds: (result.seconds * 10).rounded() / 10,
                turns: result.replies.count,
                tools: tools,
                reply: String(result.replies.last?.prefix(300) ?? ""),
                evidence: result.evalCase.evidence,
                expectedFix: result.evalCase.expectedFix,
                rounds: rounds.count,
                lastSystemCharacters: lastSystem,
                lastUserCharacters: lastUser,
                lastMaxTokens: lastMaxTokens,
                lastRaw: lastRaw.map { String($0.prefix(400)) },
                usagePasses: usage)
        }
    }

    private static func writeReport(
        results: [CaseResult], model: ResolvedModel, bar: Int, options: Options, elapsed: Double,
        interrupted: String?
    ) -> String? {
        let rows = reportRows(results)
        let plannedScored = selectCases(options).filter(\.scored).count
        let tag = options.quick ? "quick" : (options.only != nil ? "only" : "full")

        let directory: URL
        let fileURL: URL
        if let path = options.report {
            fileURL = URL(fileURLWithPath: path)
            directory = fileURL.deletingLastPathComponent()
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/NextNotesBuild/toolloop-live", isDirectory: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmm"
            fileURL = directory.appendingPathComponent("\(formatter.string(from: Date())).md")
        }
        var lines: [String] = []
        lines.append("# Tool loop live eval — \(Date())")
        lines.append("")
        lines.append("- Model: `\(model.provider.id.rawValue)` \"\(model.provider.displayModelName)\" "
            + "ctx=\(model.provider.contextTokens) role=`\(model.roleChoice)`"
            + (model.isFallback ? " FALLBACK" : ""))
        lines.append("- Mode: \(tag); pass bar \(bar)/\(plannedScored); elapsed "
            + "\(String(format: "%.1f", elapsed))s")
        lines.append("- Needle first: \(options.needleFirst ? "yes" : "no")")
        if let interrupted {
            lines.append("- Incomplete: \(interrupted). Partial cases are diagnostic, not a score.")
        }
        let ownerRows = rows.filter { LiveEvalCases.ownerLogIDs.contains($0.id) }
        if ownerRows.isEmpty == false {
            let ownerPassed = ownerRows.filter { $0.verdict == LiveEvalVerdict.pass.rawValue }.count
            lines.append("- Owner log (P1-27, not scored): \(ownerPassed)/\(ownerRows.count) pass")
        }
        lines.append("- Classes: " + LiveEvalVerdict.allCases.map { verdict in
            "\(verdict.rawValue.lowercased())=\(results.filter { $0.verdict == verdict }.count)"
        }.joined(separator: " "))
        lines.append("")
        lines.append("| Case | Verdict | Seconds | Turns | Tools | Reply |")
        lines.append("|---|---|---|---|---|---|")
        for row in rows {
            let tools = row.tools.joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
            let reply = row.reply.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
            lines.append("| \(row.id) | \(row.verdict) | \(row.seconds) | \(row.turns) "
                + "| \(tools) | \(reply) |")
        }
        lines.append("")
        lines.append("## Non-PASS detail")
        lines.append("")
        for row in rows where row.verdict != LiveEvalVerdict.pass.rawValue {
            lines.append("### \(row.id) \(row.verdict)")
            lines.append("- evidence: \(row.evidence); expected fix: \(row.expectedFix)")
            lines.append("- rounds: \(row.rounds); last prompt: system=\(row.lastSystemCharacters ?? -1) "
                + "user=\(row.lastUserCharacters ?? -1) maxTokens=\(row.lastMaxTokens ?? -1)")
            if let raw = row.lastRaw {
                lines.append("- last completion:")
                lines.append("```")
                lines.append(raw)
                lines.append("```")
            }
            lines.append("")
        }
        lines.append("## Model passes")
        lines.append("")
        for row in rows {
            lines.append("- \(row.id): " + (row.usagePasses.isEmpty
                ? "(no usage rows)"
                : row.usagePasses.joined(separator: " · ")))
        }
        lines.append("")

        // P1-27: the owner's own failed requests, in their own section so a reader of the
        // report does not have to pick ten rows out of forty to see which of them the gate
        // reads. `expectedFix` is the column that matters — it names the task that turns each
        // one green, which is why it is here and not only in the table above.
        if ownerRows.isEmpty == false {
            lines.append("## Owner log (P1-27)")
            lines.append("")
            lines.append("Not scored, and never inside the thirty. `TOOLLOOP_LIVE_OWNER` counts "
                + "them; the Phase 1 exit gate reads them.")
            lines.append("")
            lines.append("| Case | Verdict | Tools | Expected fix | Reply |")
            lines.append("|---|---|---|---|---|")
            for row in ownerRows {
                let tools = row.tools.joined(separator: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
                let reply = row.reply.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
                lines.append("| \(row.id) | \(row.verdict) | \(tools) | \(row.expectedFix) "
                    + "| \(reply) |")
            }
            lines.append("")
        }

        let markdown = lines.joined(separator: "\n")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonl = rows.compactMap { row -> String? in
            guard let data = try? encoder.encode(row) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            try (jsonl + (jsonl.isEmpty ? "" : "\n"))
                .write(to: URL(fileURLWithPath: fileURL.path + ".jsonl"),
                       atomically: true, encoding: .utf8)
            return fileURL.path
        } catch {
            SelfTest.diagnostic("TOOLLOOP_LIVE_REPORT_FAILED: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Store isolation

    private struct StoreSnapshot {
        var files: [String: String] = [:]
        var defaults: [String: String] = [:]

        static func capture() -> StoreSnapshot {
            var snapshot = StoreSnapshot()
            let support = AppIdentity.applicationSupportDirectory
            let names = [
                "runs.jsonl", "agent-tasks.json", "agent-audit.jsonl",
                "agent-conversation.json", "next-memory.json",
            ]
            for name in names {
                snapshot.files[name] = describe(support.appendingPathComponent(name))
            }
            snapshot.files["library.json"] =
                describe(ModelSpec.directory.appendingPathComponent("library.json"))
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("modelRoles.") || key.hasPrefix("modelLibrary.") {
                snapshot.defaults[key] =
                    String(describing: UserDefaults.standard.object(forKey: key))
            }
            return snapshot
        }

        static func firstDifference(_ before: StoreSnapshot, _ after: StoreSnapshot) -> String? {
            for (name, value) in before.files where after.files[name] != value {
                return "\(name) (\(value) → \(after.files[name] ?? "absent"))"
            }
            for (name, value) in after.files where before.files[name] == nil {
                return "\(name) (appeared: \(value))"
            }
            for (key, value) in before.defaults where after.defaults[key] != value {
                return "\(key) (\(value) → \(after.defaults[key] ?? "absent"))"
            }
            for (key, value) in after.defaults where before.defaults[key] == nil {
                return "\(key) (appeared: \(value))"
            }
            return nil
        }

        private static func describe(_ url: URL) -> String {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return "absent"
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size) bytes, mtime \(modified)"
        }
    }
}
