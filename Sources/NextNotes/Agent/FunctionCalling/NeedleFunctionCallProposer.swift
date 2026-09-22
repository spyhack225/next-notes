import Foundation

/// The real backend: Needle 3, spawned once per utterance.
///
/// Everything interesting happens in two places that are easy to miss:
///
/// 1. **`validation.ungrounded` is treated as law.** Needle names the arguments it could not
///    find in the input, and those are removed before anything else looks at the call — even
///    when the value is perfectly plausible, which is exactly when it is dangerous.
/// 2. **Confidence is a filter, never a licence.** A call under `minimumConfidence` is
///    dropped rather than shown; a call over it still goes to a person. Measured on this
///    machine: a real request scores 0.86–1.00, and ordinary conversation ("yeah, I totally
///    agree") scores 0.19, so the gate sits between those two populations rather than at a
///    round number somebody liked.
struct NeedleFunctionCallProposer: FunctionCallProposer {
    let backend = FunctionCallBackend.needle

    /// Below this, throw the turn away.
    ///
    /// Deliberately low, and the reason is what the score is for. Cactus's own guidance is
    /// to route on it — act, confirm, or refuse — and **this app never acts**: every call
    /// goes to a person. So the only boundary that matters here is "refuse", not "act".
    ///
    /// It also turns out not to be comparable between tool sets. Measured on the same
    /// sentence on 2026-09-19: 1.00 with two tools declared, 0.93 with fourteen, 0.41 with
    /// the eight this app offers. A gate placed for one catalogue silently empties the
    /// feature when the catalogue changes, which is exactly what 0.65 did — it threw away
    /// two correct proposals scoring 0.41 and 0.42. The grounding rules and the
    /// nothing-survived rule are what actually filter; this only catches the floor.
    static let minimumConfidence = 0.3

    private let runner: NeedleRunner

    init(runner: NeedleRunner = .shared) {
        self.runner = runner
    }

    var unavailableReason: String? {
        get async { await runner.unavailableReason() }
    }

    func prepare() async throws {
        if let reason = await runner.unavailableReason() {
            throw FunctionCallError.notReady(reason)
        }
    }

    func propose(_ request: FunctionCallRequest) async throws -> [ProposedFunctionCall] {
        guard !request.tools.isEmpty else { return [] }
        // Before the engine, not after. A device command cannot map to anything in this
        // catalogue however the model answers, and spawning Needle for it costs a second of
        // a machine that is also running two transcribers.
        if let reason = FunctionCallRelevance.preflightRefusal(request) {
            Log.agent.info("function call not proposed: \(reason, privacy: .public)")
            return []
        }
        let started = Date()
        let response = try await runner.run(
            input: Self.input(for: request),
            // Declared with somewhere to say no. Without it the model is being asked which
            // of eight tools a sentence wants, and "none" is not one of the eight.
            tools: FunctionCallRelevance.wireTools(for: request.tools),
            facts: request.facts
        )
        let latency = Date().timeIntervalSince(started)

        // A turn that produced no call is the normal answer, not a fault — including the
        // truncated one. Measured: "yeah, I totally agree, that makes a lot of sense to me"
        // sends the model looking for a tool that does not exist and the turn dies with
        // `token budget exhausted` at both 256 and 512 tokens, exit code 0, calls empty.
        // Treating that as an error would put a red status on the feature every time
        // somebody agreed with something.
        if response.functionCalls.isEmpty {
            if let code = response.errorCode {
                Log.agent.info("needle produced no call (\(code, privacy: .public))")
            }
            return []
        }
        if response.success == false {
            throw FunctionCallError.engineFailed(response.error ?? "unknown")
        }
        // "Don't send that to anyone" parses as a send with a negation on it. The engine
        // reports the negation; acting on the call would be the opposite of what was asked.
        if response.validation?.negation == true { return [] }

        let confidence = response.confidence ?? 0
        guard confidence >= Self.minimumConfidence else { return [] }

        let byID = Dictionary(uniqueKeysWithValues: request.tools.map { ($0.id, $0) })
        var proposals: [ProposedFunctionCall] = []
        for call in response.functionCalls {
            // The model took the way out. That is the answer, and it ends the turn: a
            // second call beside an abstention is the model hedging both ways.
            if call.name == FunctionCallRelevance.abstentionToolID {
                Log.agent.info("function call not proposed: the model chose no_action")
                return []
            }
            guard let tool = byID[call.name] else {
                // A name nobody offered. Nothing downstream would find a catalogue entry for
                // it, and a proposal that cannot be executed is only a confusing card.
                Log.agent.info("needle named an unknown tool \(call.name, privacy: .public)")
                continue
            }
            let raw = ProposedFunctionCall(
                toolID: tool.id,
                arguments: call.arguments,
                confidence: confidence,
                span: request.span,
                reasoning: response.reasoning ?? "",
                backend: backend,
                latency: latency
            )
            let filtered = FunctionCallGrounding.filter(
                raw,
                tool: tool,
                source: request.groundingText,
                flaggedByBackend: response.ungroundedArguments(for: tool.id),
                utterance: request.utterance
            )
            // A call whose every required argument was invented is not an incomplete
            // proposal, it is a hallucination with a form attached. Measured: "yeah, I
            // totally agree" produced `create_doc` with an ungrounded title and an empty
            // body — a card that asks the user to fill in both is a card about nothing.
            // That rule, and the relevance rules the model cannot apply to itself, are in
            // one place now so both backends get the same answer.
            if let reason = FunctionCallRelevance.refusal(
                for: filtered, tool: tool, request: request
            ) {
                Log.agent.info("needle call dropped: \(reason, privacy: .public)")
                continue
            }
            proposals.append(filtered)
        }
        return proposals
    }

    /// What the engine is asked about.
    ///
    /// The rolling window goes in, not just the sentence. Measured: "alright, send her the
    /// deck then" on its own scored 0.18 and addressed the mail to `me`; with the two lines
    /// before it — one of which contained Sarah's address — the same sentence scored 0.97
    /// and got the address right. A model that is not shown the context cannot ground
    /// anything in it, and everything it writes instead is an invention this file then has
    /// to throw away.
    static func input(for request: FunctionCallRequest) -> String {
        guard !request.window.isEmpty else { return request.utterance }
        return "Earlier:\n\(request.window)\n\nJust said: \(request.utterance)"
    }
}
