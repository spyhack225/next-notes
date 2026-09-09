import Foundation

/// What one agent pass is allowed to do.
///
/// A value rather than a read of `Settings` inside the actor: the self-test runs the agent
/// with every side effect switched off, and a policy that could only come from the user's
/// defaults would have made that impossible to express.
struct AgentPolicy: Sendable {
    /// Run read tools without asking and feed their answers back for another round. False
    /// means nothing is executed at all — the pass is pure planning.
    var autoRunReadTools = false
    /// The most consequential class of tool the model is even told exists.
    var allowedRisk = AgentRisk.send
    /// How many times the model may look something up before it has to decide. Two is one
    /// lookup and one decision; more than that on a 4B model is a loop.
    var maxRounds = 2

    /// What the app does after a meeting, with the user's own switches applied.
    @MainActor
    static func fromSettings() -> AgentPolicy {
        AgentPolicy(
            autoRunReadTools: Settings.shared.agentAutoRunReadTools,
            allowedRisk: .send,
            maxRounds: 2
        )
    }

    /// Mid-meeting: never looks anything up. A read that takes four seconds while the
    /// conversation moves on is a proposal about the wrong minute.
    static let live = AgentPolicy(autoRunReadTools: false, allowedRisk: .send, maxRounds: 1)
    /// `--selftest-agent`: plans, executes nothing.
    static let dryRun = AgentPolicy(autoRunReadTools: false, allowedRisk: .send, maxRounds: 1)
}

/// Reads a meeting and proposes what to do about it.
///
/// An actor because one generation holds a multi-gigabyte model and two passes racing each
/// other would load it twice — the same reason `NotesService` funnels every summary through
/// one place. It proposes and never performs: everything it returns is a question for a
/// person, and `WorkspaceToolRunner` is the only thing that runs a write.
///
/// The exception is a read tool under `autoRunReadTools`, which is executed here and fed
/// back into the next round. That is the one place the agent touches Workspace by itself,
/// and it is confined to tools that cannot change anything.
actor MeetingAgent {
    static let shared = MeetingAgent()

    /// Room for three tool calls with a body in one of them.
    private static let maxOutputTokens = 900
    /// Held back for the parts of the prompt nothing measures: the user message's own
    /// header — title, date, attendees, the "Notes:" and "Transcript:" labels — and the chat
    /// template the provider wraps around all of it. Everything else in the fixed cost is
    /// counted rather than guessed.
    private static let headroomTokens = 256
    /// Room kept for what a read tool answers, on the passes that may run one. A round that
    /// goes and looks something up appends to a prompt that was already sized, so the space
    /// is taken out of the transcript's budget before the first round rather than after it.
    private static let lookupTokens = 512
    /// Below this there is no meeting left to read, only its last few sentences, and a
    /// proposal made from that is a guess. Better to say the window is too small.
    private static let minimumTranscriptTokens = 500
    /// The share of what is left that the notes may take. The transcript is where a
    /// follow-up is actually asked for; the notes are a summary of it, and on Apple's 4K
    /// window the two cannot both have everything.
    private static let notesShare = 3
    /// Notes are five short sections; anything past this is a transcript with headings on
    /// it, and tokenizing it in full to then throw most of it away costs seconds.
    private static let maxNotesCharacters = 8_000

    /// Plans the follow-ups for a meeting that has finished.
    func proposals(
        for meeting: Meeting,
        segments: [TranscriptSegment],
        notes: String?,
        provider: any LLMProvider,
        policy: AgentPolicy
    ) async throws -> [AgentProposal] {
        let transcript = segments.plainText(speakerNames: meeting.speakerNames)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.emptyTranscript
        }
        let tools = WorkspaceTools.tools(upTo: policy.allowedRisk)
        // Fitted once, before the loop: a second round re-tokenizing an hour of speech to
        // learn the same answer costs more than the round itself.
        let fitted = try await fit(
            notes: notes.map { String($0.prefix(Self.maxNotesCharacters)) },
            transcript: transcript,
            provider: provider,
            tools: tools,
            policy: policy
        )
        return try await plan(
            meeting: meeting,
            provider: provider,
            policy: policy,
            tools: tools,
            source: .review
        ) { results in
            AgentPrompts.review(
                meeting: meeting,
                notes: fitted.notes,
                transcript: fitted.transcript,
                results: results
            )
        }
    }

    /// Plans from the last minutes of a meeting that is still running.
    func liveProposals(
        for meeting: Meeting,
        recent: [TranscriptSegment],
        provider: any LLMProvider,
        policy: AgentPolicy = .live
    ) async throws -> [AgentProposal] {
        let excerpt = recent.plainText(speakerNames: meeting.speakerNames)
        guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.emptyTranscript
        }
        // Fitted like the review pass, and for the same reason: the excerpt is normally two
        // minutes of speech, but a pass that had to wait for the previous one carries every
        // minute since, and the tool schemas take most of Apple's window before it starts.
        let tools = WorkspaceTools.tools(upTo: policy.allowedRisk)
        let fitted = try await fit(
            notes: nil,
            transcript: excerpt,
            provider: provider,
            tools: tools,
            policy: policy
        )
        return try await plan(
            meeting: meeting,
            provider: provider,
            policy: policy,
            tools: tools,
            source: .live
        ) { _ in
            AgentPrompts.live(meeting: meeting, recent: fitted.transcript)
        }
    }

    // MARK: - The loop

    /// One planning pass: generate, run whatever read tools were asked for, generate again.
    ///
    /// The results of a read are appended to the *user* message of the next round rather
    /// than sent as a tool-role turn. Both providers here take one system and one user
    /// message — Apple's `LanguageModelSession` has no tool-result role this app can fill
    /// from outside — so a transcript of the conversation so far is the honest way to say
    /// what has already been looked up.
    private func plan(
        meeting: Meeting,
        provider: any LLMProvider,
        policy: AgentPolicy,
        tools: [WorkspaceTool],
        source: AgentProposalSource,
        user: @Sendable ([String]) -> String
    ) async throws -> [AgentProposal] {
        let system = AgentPrompts.system
        var results: [String] = []

        for round in 0..<max(1, policy.maxRounds) {
            try Task.checkCancellation()
            let completion = try await provider.complete(
                system: system,
                user: user(results),
                maxTokens: Self.maxOutputTokens,
                tools: tools
            )
            let calls = AgentToolCallParser.calls(in: completion.text)
            Log.agent.info("""
                agent round \(round + 1, privacy: .public): \
                \(calls.count, privacy: .public) call(s) in \
                \(completion.generatedTokens, privacy: .public) token(s)
                """)
            guard !calls.isEmpty else { return [] }

            let isLastRound = round == max(1, policy.maxRounds) - 1
            let lookups = calls.filter { WorkspaceTools.tool(named: $0.name)?.risk == .read }
            let actions = calls.filter { WorkspaceTools.tool(named: $0.name)?.risk != .read }

            // A round that only wants to look things up is answered by looking them up —
            // but only while there is a round left to use the answers in. On the last round
            // a read is a proposal like any other, and the user can approve it.
            if actions.isEmpty, !lookups.isEmpty, policy.autoRunReadTools, !isLastRound {
                results.append(contentsOf: await run(lookups, for: meeting))
                results = try await trimmed(results, provider: provider)
                continue
            }
            return proposals(from: calls, meeting: meeting, policy: policy, source: source)
        }
        return []
    }

    /// Runs read tools and collects what they said, failures included: "that search found
    /// nothing" is information the next round needs as much as a list of hits.
    private func run(_ calls: [AgentToolCall], for meeting: Meeting) async -> [String] {
        var results: [String] = []
        for call in calls {
            let proposal = AgentProposal(
                meetingID: meeting.id,
                tool: call.name,
                arguments: call.arguments,
                rationale: call.rationale
            )
            do {
                let result = try await WorkspaceToolRunner.run(proposal)
                results.append(AgentPrompts.toolResult(name: call.name, output: result.summary))
            } catch {
                results.append(AgentPrompts.toolResult(
                    name: call.name,
                    output: "failed — \(error.localizedDescription)"
                ))
            }
        }
        return results
    }

    /// Turns calls into proposals, dropping the ones nobody could approve.
    ///
    /// Three things are refused here rather than in the UI: a tool this build doesn't have,
    /// a class of tool the policy didn't allow — a model can name a tool it was never shown
    /// — and a call missing an argument the tool needs, which would fail the moment it was
    /// approved. Duplicates go too: a model asked for follow-ups often proposes the same
    /// email twice with different wording.
    private func proposals(
        from calls: [AgentToolCall],
        meeting: Meeting,
        policy: AgentPolicy,
        source: AgentProposalSource
    ) -> [AgentProposal] {
        var seen: Set<String> = []
        var proposals: [AgentProposal] = []

        for call in calls {
            guard let tool = WorkspaceTools.tool(named: call.name) else {
                Log.agent.error("model proposed an unknown tool \(call.name, privacy: .public)")
                continue
            }
            guard tool.risk <= policy.allowedRisk else {
                Log.agent.error("model proposed \(call.name, privacy: .public), which isn't allowed")
                continue
            }
            let missing = tool.parameters.filter { parameter in
                parameter.isRequired
                    && (call.arguments[parameter.name]?
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            guard missing.isEmpty else {
                Log.agent.error("""
                    \(call.name, privacy: .public) was proposed without \
                    \(missing.map(\.name).joined(separator: ", "), privacy: .public)
                    """)
                continue
            }

            let fingerprint = "\(tool.name)|\(call.arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|"))"
            guard seen.insert(fingerprint).inserted else { continue }

            proposals.append(AgentProposal(
                meetingID: meeting.id,
                tool: tool.name,
                arguments: call.arguments,
                rationale: call.rationale.isEmpty ? tool.summary : call.rationale,
                source: source
            ))
            if proposals.count == AgentPrompts.maxProposals { break }
        }
        return proposals
    }

    // MARK: - Fitting

    /// The notes and the transcript, each cut to what is actually left of the window.
    ///
    /// The fixed cost is measured rather than reserved: the system message is the rules plus
    /// a JSON schema for every tool the policy allows, which is thousands of characters and
    /// grows every time the catalogue does. A constant here is a prompt that fits the meeting
    /// it was tested on and overflows the next one.
    ///
    /// Both halves are cut, not only the transcript. Apple's 4K window minus eleven schemas
    /// and a 900-token answer leaves about as much room as the notes alone used to take, and
    /// a pass that threw rather than trimmed would mean the second provider could never
    /// review a meeting at all. The transcript gets what the notes don't, because it is where
    /// a follow-up is actually asked for.
    ///
    /// No map-reduce here, unlike the notes: a follow-up is asked for in one sentence, and
    /// the sentences that matter are the ones near the end. Reading the whole meeting in
    /// pieces to find them would cost minutes for a pass whose usual answer is "nothing".
    private func fit(
        notes: String?,
        transcript: String,
        provider: any LLMProvider,
        tools: [WorkspaceTool],
        policy: AgentPolicy
    ) async throws -> (notes: String?, transcript: String) {
        let system = AgentPrompts.system + "\n\n" + AgentPrompts.toolBlock(tools: tools)
        let lookups = policy.autoRunReadTools && policy.maxRounds > 1 ? Self.lookupTokens : 0
        let reserved = try await provider.countTokens(system)
            + Self.maxOutputTokens
            + Self.headroomTokens
            + lookups
        var budget = provider.contextTokens - reserved
        guard budget >= Self.minimumTranscriptTokens else { throw AgentError.contextTooSmall }

        var fittedNotes: String?
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cut = try await cut(
                notes,
                to: budget / Self.notesShare,
                provider: provider,
                keepingTail: false
            )
            fittedNotes = cut.text
            budget -= cut.tokens
        }
        let cut = try await cut(transcript, to: budget, provider: provider, keepingTail: true)
        return (fittedNotes, cut.text)
    }

    /// One piece of text, cut to a token budget and measured on the way.
    ///
    /// The ratio is measured on the text itself rather than assumed — the same trick the
    /// notes generator uses to size a chunk, and accurate to a few percent on prose. Which
    /// end survives is the caller's decision: the last of a transcript is where a request
    /// is made, and the first of a set of notes is where the decisions are.
    private func cut(
        _ text: String,
        to budget: Int,
        provider: any LLMProvider,
        keepingTail: Bool
    ) async throws -> (text: String, tokens: Int) {
        let tokens = try await provider.countTokens(text)
        guard tokens > budget else { return (text, tokens) }
        guard budget > 0 else { return ("", 0) }
        let charactersPerToken = Double(text.count) / Double(max(tokens, 1))
        let characters = max(0, Int(Double(budget) * charactersPerToken))
        return (keepingTail ? String(text.suffix(characters)) : String(text.prefix(characters)), budget)
    }

    /// The read tools' answers, cut to the room `fit` held back for them.
    ///
    /// Whole answers are dropped rather than one long answer truncated: half a search result
    /// reads as a complete one that found nothing, which is the sentence the next round would
    /// act on.
    private func trimmed(_ results: [String], provider: any LLMProvider) async throws -> [String] {
        var results = results
        while results.count > 1,
              try await provider.countTokens(results.joined(separator: "\n")) > Self.lookupTokens {
            results.removeLast()
        }
        return results
    }
}
