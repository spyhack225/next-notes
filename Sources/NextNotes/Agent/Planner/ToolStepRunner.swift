import Foundation

/// What one executed step did, in terms the planner loop can act on.
///
/// The runner owns the call; the loop owns every sentence a person reads. That split is the
/// reason this type exists: Apple's `Tool.call` runs the step from inside the model framework,
/// where a `return` out of the planner loop is not available, so a runner that returned "here
/// is the sentence" would have to speak from two places.
enum ToolStepDisposition: Sendable, Equatable {
    /// The step ran. `output` is what the model reads next.
    case completed(output: String)
    /// Nothing ran, and the model is told why. `toolID` is the name the result belongs to:
    /// the canonical id for a real step, and the name the model *wrote* for a call that named
    /// a tool this build does not have — which is what the result cap measures.
    case repaired(toolID: String, note: String)
    /// Nothing ran and there is nothing to say.
    case skipped
    /// The plan cannot do anything more, so the turn owes the person an answer. The loop
    /// renders it through P1-06's final-answer round, which is the one thing that answers
    /// rather than excuses.
    case answerNow(ToolStepAnswerReason)
    /// Out of compute. The loop's own timeout sentence, deliberately *not* the final answer
    /// round: a plan cut off by a deadline has said its deadline out loud already.
    case outOfTime
    /// The turn ends here. `kind` picks the renderer; every sentence is already plain words.
    case endTurn(ToolStepEnd)
}

/// Why a plan cannot run another call, so the final answer round can name it in the log.
enum ToolStepAnswerReason: String, Sendable {
    case callsExhausted
    case repeatedCall
}

/// The one thing a tool step may end a turn with, and the renderer it wants. Each case is a
/// plain sentence that already exists somewhere; this is the list, not new copy.
enum ToolStepEnd: Sendable, Equatable {
    /// A tool this build has and this turn may not run. The sentence is the manifest's own
    /// words for the missing setup and it names no id.
    case notReady(String)
    /// A call that could not be read and there is no repair budget left. P1-10b's `.stopped`.
    case stopped(String)
    /// A failure the model could not fix and the machine will not recover from on a retry.
    case infrastructure(String)
    /// A person or a policy said no. No retry, ever.
    case denied(String)
}

/// One call's execution semantics: name resolution, grounded arguments, the signature this
/// turn already ran, the budget, provenance, the executor, and the classified outcome.
///
/// `ToolStepRunner` is the only caller of `AgentToolExecutor.run` inside the planner. That is
/// the invariant, and it is why this is a type rather than a block in the loop: Apple's
/// `Tool.call` body is the second caller the moment native tools exist, and two callers is how
/// a write stops waiting for a person.
@MainActor
final class ToolStepRunner: ToolStepExecuting {
    /// The turn's one manifest. It changes in exactly one place — a call to an allowed tool
    /// outside the schema widens the next round's catalogue, so the model is not asked the
    /// same question twice with the same omission — and the loop reads it when it builds the
    /// next round's prompt.
    private(set) var manifest: AgentCapabilityManifest
    /// P1-06's budget, and what is left of its ceiling. One clock charges everything, so the
    /// rounds and the reads cannot disagree about what the plan has spent. A write is charged
    /// nothing: it may be sitting on a person's approval, and a deadline there could say
    /// "stopped" while the write later commits.
    let budget: ToolLoopBudget
    private(set) var ceilingRemaining: Duration
    /// What the person said this turn, for grounded arguments and provenance. The loop resets
    /// it each round, because a voice objective can be revised mid-flight.
    var request: String
    /// Whether the input this step was planned from is still the current one. P0-07's effect
    /// gate asks the same question, so there is one answer.
    var revisionIsCurrent: @MainActor @Sendable () -> Bool = { true }
    private let agent: RealtimeAgent
    private let owner: Int
    private let workID: String?
    private let maxCalls: Int
    private let maxRepairs: Int
    private let window: Int
    private var provider: any LLMProvider
    private var completedCalls: Set<String> = []
    private var repeatedSignatures = 0

    // MARK: The turn's bookkeeping, which the loop reads

    private(set) var callsUsed = 0
    private(set) var repairs = 0
    private(set) var completedToolIDs: [String] = []
    private(set) var lastVerifiedResult: String?
    private(set) var memoryConfirmations: [String] = []
    private(set) var currentToolID: String?
    /// Tool output this turn has seen, for memory provenance.
    var untrustedOutputs: [String]
    /// Any tool result outside memory and schedule this turn, or a recall that returned
    /// indexed passages: a reminder written after it asks with a card, since the result may
    /// have supplied it.
    var readToolOutput = false
    private(set) var terminalOutcome: ToolStepOutcome?
    /// P1-14: a turn gets **one** read-miss repair, because a mailbox with nothing in it is a
    /// real answer and re-asking is how a plan spends a person's time. After it, a miss is
    /// carried as the result it is.
    private var missRepaired = false

    /// No calls and no repairs left means the plan cannot do anything this round, so it does
    /// not spend one asking. The loop asks this before sending a round (P1-06 step 9).
    var canRunAnother: Bool { callsUsed + repairs < maxCalls }

    init(
        agent: RealtimeAgent, owner: Int, work: VoiceConversationWork?, provider: any LLMProvider,
        manifest: AgentCapabilityManifest, budget: ToolLoopBudget, ceilingRemaining: Duration,
        request: String, maxCalls: Int, readerContextTokens: Int, untrustedOutputs: [String]
    ) {
        self.agent = agent
        self.owner = owner
        self.workID = work?.id.uuidString
        self.provider = provider
        self.manifest = manifest
        self.budget = budget
        self.ceilingRemaining = ceilingRemaining
        self.request = request
        self.maxCalls = maxCalls
        self.maxRepairs = 2
        self.window = readerContextTokens
        self.untrustedOutputs = untrustedOutputs
    }

    /// The turn's provider changed — the one in-turn fallback for a file that failed a real
    /// load. Every `@Sendable` closure below reads it at call time, so this is the same
    /// capture-by-value rule the loop had.
    func adopt(provider: any LLMProvider) {
        self.provider = provider
    }

    /// Charge the plan's own clock. The loop calls this with the wall time a round took, so
    /// one clock charges rounds and reads rather than two disagreeing.
    func charge(_ elapsed: Duration) {
        ceilingRemaining -= elapsed
    }

    /// Charge a round's unreadable calls against the same repair budget an unexecutable one
    /// uses.
    ///
    /// They are one number on purpose. P1-04's rule is that a turn cannot spend more than
    /// two rounds learning it is wrong, whether it learned that from a call that would not
    /// resolve or from a call whose text could not be read — two separate counters is how a
    /// turn gets four.
    func chargeRepairs(_ count: Int) {
        repairs += count
    }

    // MARK: - One call

    /// Resolve, check, run, classify. Never speaks to a person and never returns one.
    func execute(_ call: AgentToolCall) async -> ToolStepResult {
        // One case is not a repair: a tool this build has and this turn may not run. The
        // manifest carries the one plain sentence a person needs for it
        // (`Readiness.reason`), and that sentence is the whole reply — it says what to do and
        // names no id.
        if let registered = AgentToolRegistry.shared.tool(named: call.name),
           let blocked = manifest.unavailable.first(where: { $0.id == registered.id }),
           let sentence = blocked.readiness.reason {
            agent.plannerTraceForTesting?(
                .rejectedCall(name: call.name, reason: "not ready: \(sentence)"))
            return ToolStepResult(
                canonicalID: registered.id, disposition: .endTurn(.notReady(sentence)))
        }
        // P1-04: the name the model wrote is resolved to a canonical id this turn may execute
        // — exact, alias, router, normalised spelling, then a near miss. A name that resolves
        // to nothing used to end the plan with a sentence about the app's insides read by a
        // person who asked a question; it is now a repair, or a plain end.
        let resolution = ToolCallNameResolver.resolve(call.name, allowed: manifest.allowed)
        guard case .tool(let canonicalID) = resolution,
              let tool = AgentToolRegistry.shared.tool(named: canonicalID),
              let entry = manifest.entry(named: canonicalID) else {
            agent.plannerTraceForTesting?(.rejectedCall(name: call.name, reason: "unknown tool"))
            guard case .unknown(let suggestions) = resolution, repairs < maxRepairs else {
                return ToolStepResult(
                    canonicalID: call.name, disposition: .endTurn(
                        .stopped("I couldn't find a way to do that, so I stopped there.")))
            }
            repairs += 1
            return ToolStepResult(canonicalID: call.name, disposition: .repaired(
                toolID: call.name,
                note: ToolRepair(
                    kind: .unknownTool,
                    message: "There is no tool called \(call.name).",
                    options: suggestions).modelText))
        }
        if !manifest.selectedIDs.contains(entry.id) {
            manifest = manifest.widened(toInclude: entry.intent)
        }
        // Bound by this code, not taken from the model: what the user said this turn.
        let arguments = AgentToolLoop.groundedArguments(
            for: canonicalID, proposed: call.arguments, request: request)
        // Keyed on the canonical id, so an alias and its own spelling are one step.
        let signature = canonicalID + "|" + arguments.keys.sorted()
            .map { "\($0)=\(arguments[$0] ?? "")" }.joined(separator: "|")
        guard completedCalls.insert(signature).inserted else {
            // H-audit 2026-09-23 (H1 #20). Small models re-issue a call whose result was long
            // or empty. That is a question, not a loop: the result is already in the round's
            // results, so the note points at it and the plan goes on. One note per turn; the
            // second repeat ends the plan, which still owes the person an answer.
            repeatedSignatures += 1
            if repeatedSignatures == 1, repairs < maxRepairs {
                repairs += 1
                return ToolStepResult(canonicalID: canonicalID, disposition: .repaired(
                    toolID: canonicalID,
                    note: "You already ran \(canonicalID) with these arguments; its result is "
                        + "above. Answer now or choose a different step."))
            }
            return ToolStepResult(canonicalID: canonicalID, disposition: .answerNow(.repeatedCall))
        }
        guard canRunAnother else {
            return ToolStepResult(canonicalID: canonicalID, disposition: .answerNow(.callsExhausted))
        }
        currentToolID = canonicalID
        // P1-06 step 6: what is happening now, in the words the person would use. Set before
        // the call, not after it — a title naming a step which finished while the next one is
        // already running is a claim the app cannot back up.
        agent.beginWork(title: AgentActivityProjector.title(for: tool, arguments: arguments))
        let policy = PermissionPolicy.fromSettings()
        // Bound by this code, not taken from the model: what the user said this turn, and
        // every tool result it has seen so far.
        let provenance = MemoryProvenance(
            origin: .userConversation,
            sessionID: AgentSession.shared.sessionID,
            userText: [request] + AgentSession.shared.recentUserTexts(),
            untrustedText: untrustedOutputs,
            readToolOutputThisTurn: readToolOutput
        )
        // Captured by value: the closures below are `@Sendable`.
        let executingProvider = provider
        let window = self.window
        let workID = self.workID
        let owner = self.owner
        let revisionIsCurrent = self.revisionIsCurrent
        // P0-20a: the timer's clock starts inside the executor's post-approval `fire`, so the
        // recorded `ms` is execution and never the card's wait.
        let executionTimer = ToolExecutionTimer()
        let began = ContinuousClock.now
        // Captured by value: this closure is `@Sendable` and the request can be revised
        // mid-turn, so the call has to be anchored to what the user said when it was planned.
        let request = self.request
        // P1-04: the closure returns the classified outcome rather than a string, so the
        // decision about what a failure *means* is made in one table (`ToolErrorClassifier`)
        // instead of in whichever `catch` leg the error happened to be thrown from.
        let execute: @Sendable () async -> ToolExecution = { [agent] in
            do {
                // P1-10a: the reader this plan resolved, bound around the step so a tool that
                // shapes its own answer — `WorkspaceToolRunner` caps a mail body, a calendar
                // and a Drive listing — sizes it for the model that will read it instead of for
                // a constant chosen before any of them were known. Outside a planned turn
                // nothing is bound and those callers keep today's 2,000.
                let result = try await MemoryProvenance.$current.withValue(provenance) {
                    try await ToolExecutionTimer.$current.withValue(executionTimer) {
                        try await ToolResultBudget.$readerContextTokens.withValue(window) {
                            try await AgentToolExecutor.run(
                                canonicalID, arguments: arguments, policy: policy,
                                taskID: workID,
                                autoApproveReads: true,
                                promptIfNeeded: !agent.denyUnattendedApprovalsForTesting,
                                // P0-07: a write may only commit while the input that planned
                                // it is classified. Reads run through user speech; the loop's
                                // round barrier already decided when this round began. This is
                                // the only place the voice input barrier applies to an effect,
                                // and P3-02 moves it to `TaskBridge` as a one-line change.
                                isStillValid: {
                                    guard await agent.mayCommitEffect(risk: tool.risk) else { return false }
                                    return agent.isCurrent(owner) && revisionIsCurrent()
                                }
                            )
                        }
                    }
                }
                // P1-5 additive hook: a completed step's reference and link are the run's
                // artifacts — keep them so the terminal card can link them.
                AgentArtifactLedger.capture(taskID: workID, result: result)
                // P0.1, the seam the loop was missing: a screenshot step parks its capture in
                // `ScreenshotStore` and returns a park summary. The run's own model — cloud or
                // on-device, under the same `VisionScope` plus per-run consent every provider
                // call enforces — is what describes the pixels, and the description is what the
                // planner reads next round.
                if RealtimeToolSelection.screenshotToolIDs.contains(canonicalID) {
                    let described = await VisionHandoff.describe(
                        provider: executingProvider,
                        toolID: canonicalID,
                        arguments: arguments,
                        parkSummary: result.summary,
                        cloudConsent: Settings.shared.visionCloudConsent,
                        request: request
                    )
                    return ToolExecution(outcome: .success(described))
                }
                return ToolExecution(outcome: .success(result.summary))
            } catch {
                let errorClass: UsageErrorClass = error.isModelUnavailable
                    ? .modelUnavailable : .other
                return ToolExecution(
                    outcome: ToolErrorClassifier.classify(error, tool: tool),
                    errorClass: errorClass)
            }
        }
        // A write may be awaiting human approval or remote confirmation. Never detach it
        // behind a timeout: that could say "stopped" while the write later commits.
        let execution: ToolExecution?
        if tool.risk > .read {
            execution = await execute()
        } else {
            let callBegan = ContinuousClock.now
            let readLimit = budget.readCallLimit(ceilingRemaining: ceilingRemaining)
            execution = await withBoundedWait(readLimit) { await execute() }
            charge(callBegan.duration(to: .now))
        }
        guard let execution else {
            currentToolID = nil
            return ToolStepResult(canonicalID: canonicalID, disposition: .outOfTime)
        }
        let executionMS = executionTimer.executionMs
            ?? ModelPassRecorder.milliseconds(began.duration(to: .now))
        let usage = UsageToolRun(
            id: tool.id, ok: execution.outcome.isSuccess,
            ms: executionMS, errorClass: (execution.errorClass ?? .other).rawValue)
        switch execution.outcome {
        case .success(let output):
            callsUsed += 1
            completedToolIDs.append(canonicalID)
            currentToolID = nil
            var confirmation: String?
            if tool.namespace == .memory, tool.risk > .read {
                let sentence = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                if !sentence.isEmpty {
                    memoryConfirmations.append(sentence)
                    confirmation = sentence
                }
            } else {
                untrustedOutputs.append(output)
                if RealtimeToolSelection.readsUntrustedOutput(
                    namespace: tool.namespace, output: output) {
                    readToolOutput = true
                }
            }
            // A mutation completes one step, not the person's whole objective. Keep its
            // verified result and let the loop plan the remaining work.
            lastVerifiedResult = output
            // P1-14: a read that matched nothing, where the tool's own description documents
            // the call that would have answered it, is carried as a repair rather than as the
            // turn's answer — once per turn. The call is still recorded above: it ran, so a
            // sentence saying it ran is backed, and the honest miss is still what the person
            // is told if the model declines to search again.
            if !missRepaired,
               let repair = ReadMissRecovery.repair(
                toolID: canonicalID, arguments: arguments, result: output) {
                missRepaired = true
                return ToolStepResult(
                    canonicalID: canonicalID, disposition: .repaired(
                        toolID: canonicalID, note: repair.modelText),
                    usage: UsageToolRun(id: tool.id, ok: true, ms: executionMS, errorClass: nil),
                    output: output, readToolOutput: readToolOutput)
            }
            return ToolStepResult(
                canonicalID: canonicalID, disposition: .completed(output: output),
                usage: UsageToolRun(id: tool.id, ok: true, ms: executionMS, errorClass: nil),
                output: output, memoryConfirmation: confirmation, readToolOutput: readToolOutput)
        case .recoverable(let repair):
            guard repairs < maxRepairs else {
                currentToolID = nil
                terminalOutcome = .recoverable(repair)
                return ToolStepResult(
                    canonicalID: canonicalID,
                    disposition: .endTurn(
                        .stopped("I couldn't finish that, so I stopped there.")),
                    usage: usage)
            }
            // A failure thrown *before* anything committed: the signature comes out of
            // `completedCalls` and the corrected call is allowed to be the same call.
            completedCalls.remove(signature)
            callsUsed += 1
            repairs += 1
            currentToolID = nil
            return ToolStepResult(
                canonicalID: canonicalID,
                disposition: .repaired(toolID: canonicalID, note: repair.modelText),
                usage: usage)
        case .denied(let sentence):
            terminalOutcome = .denied(userSentence: sentence)
            currentToolID = nil
            return ToolStepResult(
                canonicalID: canonicalID, disposition: .endTurn(.denied(sentence)), usage: usage)
        case .infrastructure(let sentence):
            // Do not hand a denial back to the model for a possible optimistic rewrite — that
            // is the original rule and it is right. An infrastructure failure is the same
            // shape: a retry would ask the same machine the same question.
            terminalOutcome = .infrastructure(userSentence: sentence)
            currentToolID = nil
            return ToolStepResult(
                canonicalID: canonicalID, disposition: .endTurn(.infrastructure(sentence)),
                usage: usage)
        }
    }
}

/// One step's result, as the loop needs it: what to do next, what the usage log records, and
/// the fields the turn's own bookkeeping moves forward.
struct ToolStepResult: Sendable {
    let canonicalID: String
    let disposition: ToolStepDisposition
    var usage: UsageToolRun?
    /// The tool's output, when it succeeded. The loop carries this into the next round.
    var output: String?
    /// The first line of a memory write, which is said out loud (P1-06).
    var memoryConfirmation: String?
    /// Whether this step's output counts as untrusted for memory provenance.
    var readToolOutput: Bool = false

    init(
        canonicalID: String, disposition: ToolStepDisposition, usage: UsageToolRun? = nil,
        output: String? = nil, memoryConfirmation: String? = nil, readToolOutput: Bool = false
    ) {
        self.canonicalID = canonicalID
        self.disposition = disposition
        self.usage = usage
        self.output = output
        self.memoryConfirmation = memoryConfirmation
        self.readToolOutput = readToolOutput
    }
}

extension ToolStepOutcome {
    /// Whether a usage row should say the call worked. The outcome's own cases are a person's
    /// sentence and a model's repair; this is the boolean `usage.jsonl` records.
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
