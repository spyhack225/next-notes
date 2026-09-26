import Foundation

/// The planner on the app's own runtime, with decoding constrained by a GBNF grammar built
/// from the turn's manifest.
///
/// The point is that three failures stop being possible. A 4B model writing free text can name
/// a tool this turn was not offered, can write an argument object of the wrong shape, and can
/// be cut off mid-JSON; each costs a repair round, and a repair round is 2.5–5.2 s of prefill
/// on this machine (report B §1). Under a grammar the sampler cannot reach any of the three, so
/// they are not repaired — they cannot be written.
///
/// ## Why the prompt does not change
///
/// The grammar is a *sampler* parameter, not a prompt. The catalogue stays prose, because the
/// grammar constrains the shape of a call and not which tool is right, and a model given
/// twelve names and no descriptions is a model guessing. So the prompt is byte-identical to the
/// prompt-convention backend's, which is what keeps P0-18's KV prefix reuse holding rather than
/// resetting on every turn. `--selftest-llm-prefix-cache` measures it rather than assuming it.
///
/// ## Why P1-04's parser still reads the output
///
/// The output is Hermes JSON between `<tool_call>` tags — the shape the prompt describes and
/// the shape `AgentToolCallParser` reads, and the grammar's tag literals are the parser's own
/// two strings, so the two cannot drift. Grammar-valid text cannot fail that parse, and routing
/// it through the tolerant parser anyway means one reader rather than two, and keeps the repair
/// path reachable for a model that is not under a grammar.
struct LlamaGrammarPlanner: AgentPlannerBackend {
    let provider: any LLMProvider
    /// Built once per turn from the manifest, and only after `structuralProblems()` passed.
    let grammar: GBNFGrammar

    var label: String { "llama-grammar" }

    /// A grammar over `manifest.selected`: either plain answer text, or 1–`maxCalls` Hermes
    /// call blocks whose `name` is one selected id and whose `arguments` object matches that
    /// tool's own parameters, in declaration order.
    ///
    /// Built with `GBNFSchema` so the shape the sampler enforces and the shape the loop decodes
    /// cannot drift; the only part composed here is the tag wrapper, which is not JSON at all.
    static func grammar(
        for manifest: AgentCapabilityManifest, maxCalls: Int = 3, maxTokens: Int = 256
    ) -> GBNFGrammar {
        let entries = manifest.selected
        return GBNFGrammar.composed { builder in
            let answer = builder.rule(
                for: .freeText(maxCharacters: max(16, 4 * maxTokens)), name: "answer")
            guard !entries.isEmpty else {
                // Nothing to call is a grammar that only answers, not one with an empty
                // alternative: an empty `oneOf` matches nothing, which would make every round
                // a refusal.
                builder.add("no-calls", "\"\"")
                return "\(answer) | no-calls"
            }
            let body = builder.rule(for: .oneOf(entries.map(callBody)), name: "callbody")
            let open = GBNFBuilder.literal(AgentToolCallParser.openTag)
            let close = GBNFBuilder.literal(AgentToolCallParser.closeTag)
            builder.add("call", "\(open) ws \(body) ws \(close)")
            let more = max(0, maxCalls - 1)
            builder.add("calls", "call\(more > 0 ? " (ws call){0,\(more)}" : "")")
            return "\(answer) | calls"
        }
    }

    /// One branch of the `oneOf`: the call object for a single selected tool, which is the
    /// Hermes shape the prompt describes — `name`, `arguments`, `rationale`, in that order.
    static func callBody(for entry: AgentCapabilityManifest.Entry) -> GBNFSchema {
        .object([
            ("name", .enumeration([entry.id])),
            ("arguments", argumentsSchema(for: entry)),
            ("rationale", .string(maxLength: rationaleCap)),
        ])
    }

    /// The parameters of one entry, in declaration order, as the executor reads them.
    ///
    /// Everything is a string, because everything is a string at the boundary
    /// (`WorkspaceTool.Parameter.schema`: the model writes command-line arguments). An optional
    /// parameter is `.nullable`, so the model may say "not supplied" explicitly rather than
    /// leaving the key out — the shape the prompt's example shows.
    static func argumentsSchema(for entry: AgentCapabilityManifest.Entry) -> GBNFSchema {
        var fields: [(String, GBNFSchema)] = []
        for parameter in entry.parameters {
            let value = GBNFSchema.string(
                maxLength: parameter.kind == .multiline ? multilineCap : valueCap)
            fields.append((parameter.name, parameter.isRequired ? value : .nullable(value)))
        }
        return .object(fields)
    }

    /// The caps. Both are the builder's own rule rather than a number typed into a prompt: an
    /// unbounded string is how a small model spends its whole budget on one field, and a
    /// 4,000-character reason for a choice is never read.
    static let valueCap = 240
    static let multilineCap = 2_000
    static let rationaleCap = 200

    // MARK: - The round

    func round(
        system: String, messages: [LLMChatMessage], manifest: AgentCapabilityManifest,
        maxTokens: Int, interactive: Bool,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> PlannerRound {
        var assembled = ""
        do {
            let stream = await self.stream(
                system: system, messages: messages, maxTokens: maxTokens,
                interactive: interactive, grammar: grammar)
            for try await chunk in stream {
                try Task.checkCancellation()
                if chunk.isEmpty { continue }
                assembled += chunk
                await onText(assembled)
            }
        } catch {
            throw Self.roundError(from: error, visible: assembled)
        }
        // A constrained round that ended without a whole sentence is the one way a llama round
        // can be cut off: the sampler will not let the model stop mid-call, so it ran out of
        // allowance. The grammar says so, rather than a second signal guessing at it.
        let cutOff = !assembled.isEmpty && !grammar.matches(assembled)
        let parsed = AgentToolCallParser.parse(
            cutOff ? Self.firstCompleteCallPrefix(of: assembled) : assembled,
            knownNames: Self.callNames(manifest))
        return PlannerRound(
            text: parsed.prose, calls: parsed.calls, malformed: parsed.malformed,
            raw: assembled, cutOff: cutOff)
    }

    /// Everything up to the first complete `</tool_call>`, for a round cut off after a call
    /// but before its second one. P1-04's parser then sees a whole call rather than a
    /// truncated one, which is the difference between a step running and a repair round.
    static func firstCompleteCallPrefix(of text: String) -> String {
        guard let end = text.range(of: AgentToolCallParser.closeTag) else { return text }
        return String(text[text.startIndex..<end.upperBound])
    }

    /// Every spelling this turn's manifest accepts.
    ///
    /// A *spelling* of the loop's own roster, not a second list: `RealtimeAgent.callNames` is
    /// the one answer, and the grammar, the parser and `ToolClaimGuard` all read it. A grammar
    /// whose accepted names came from a different list would accept a call the executor
    /// refuses, which is the exact defect the manifest exists to prevent.
    static func callNames(_ manifest: AgentCapabilityManifest) -> Set<String> {
        RealtimeAgent.callNames(manifest)
    }

    /// The round failures, mapped once so every backend agrees on what a failure means.
    static func roundError(from error: Error, visible: String) -> PlannerRoundError {
        // `cutOff` carries whether the provider had visible text to keep, not the text itself.
        if case OpenRouterError.cutOff(let hadVisibleText) = error {
            return hadVisibleText ? .failed(
                OpenRouterError.cutOff(visibleText: false).localizedDescription) : .cutOff
        }
        let message = error.localizedDescription
        if error.isModelUnavailable { return .modelUnavailable(message) }
        if error.isContextOverflow { return .contextOverflow(message) }
        return .failed(message)
    }
}
