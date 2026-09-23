import Foundation

/// The backend for machines where Needle cannot run, or has not been fetched.
///
/// It asks whichever local model `LLMProviders` resolves — local model on disk, Apple's Foundation
/// model otherwise — for the same answer, under a GBNF grammar so the reply parses or the
/// generation failed. It is slower by an order of magnitude (a second or two against 130 ms)
/// and it is worse at the job, which is the whole reason Needle exists. But a feature that
/// only works after a download is a feature most people never see working, and an Intel Mac
/// has no Needle engine at all.
///
/// ## Why the arguments are a list of name/value pairs
///
/// A grammar is built from a fixed shape, and the arguments of `send_email` and
/// `create_event` are not the same shape. Generating one grammar per tool and running the
/// model once per tool would be N generations for a sentence that is usually not a request
/// at all. So the grammar asks for `[{"name": …, "value": …}]`, which is one shape for every
/// tool, and the names are checked against the schema here rather than by the sampler.
struct LocalModelFunctionCallProposer: FunctionCallProposer {
    let backend = FunctionCallBackend.localModel

    /// The model writes a 0–100 score.
    ///
    /// Higher than Needle's gate rather than lower, and for the opposite reason: this number
    /// is not calibrated against anything — it is a general model asked how sure it feels,
    /// and such a model says 90 for almost everything it decides to answer at all. A low
    /// score here is therefore meaningful and a high one is not, so the gate sits where an
    /// actual hedge lands. The grounding rules after it do the real work either way.
    static let minimumConfidence = 0.65

    /// Three calls is the most one sentence has ever legitimately asked for, and a fourth is
    /// a model that has started listing the catalogue back.
    static let maxCalls = 3
    static let maxArguments = 8
    static let maxValueLength = 240
    static let maxTokens = 400

    /// Injected so the self-test can drive the whole shape — prompt, grammar, parsing,
    /// grounding — from a scripted answer, on a machine with no model at all.
    var provider: (@Sendable (String, String, GBNFGrammar) async throws -> String)?

    init(provider: (@Sendable (String, String, GBNFGrammar) async throws -> String)? = nil) {
        self.provider = provider
    }

    /// Which model this backend is allowed to ask, given what the agent is configured to use.
    ///
    /// Not the preference verbatim, and this is the one place in the app where that matters.
    /// `agentModelProvider` is persisted and includes OpenRouter, and `LLMProviders.resolve`
    /// honours an explicit OpenRouter choice by returning the cloud provider. This proposer
    /// runs on a rolling ninety-second transcript window, on every utterance, in the
    /// background, for as long as somebody is talking — so honouring that preference would
    /// be continuous upload of a meeting, switched on from somewhere else, underneath a
    /// Settings row that says the work happens on this Mac. A background listener is exactly
    /// the place where "whatever the agent uses" is the wrong answer.
    ///
    /// The other three are all on-device: local model and Apple's model are in-process, and the
    /// local-server provider refuses any address `LocalRuntimeDiscovery.isLoopback` rejects,
    /// so Ollama and LM Studio stay allowed without a second check here.
    static func onDevicePreference(_ preferred: LLMProviderID) -> LLMProviderID {
        switch preferred {
        case .openRouter: .appLLM
        case .appLLM, .appleFoundation, .localServer: preferred
        }
    }

    /// The provider to ask, or nil when nothing on this Mac can answer.
    ///
    /// `resolve` never *falls back* to OpenRouter — it is filtered out of the chain — so
    /// once the preference is not OpenRouter, no result of this can be a network call.
    private static func onDeviceProvider() async -> (any LLMProvider)? {
        let preferred = await MainActor.run {
            onDevicePreference(Settings.shared.agentModelProvider)
        }
        return await LLMProviders.resolve(preferring: preferred)
    }

    var unavailableReason: String? {
        get async {
            if provider != nil { return nil }
            guard await Self.onDeviceProvider() != nil else {
                return "No on-device model is available yet."
            }
            return nil
        }
    }

    func prepare() async throws {
        if let reason = await unavailableReason { throw FunctionCallError.notReady(reason) }
    }

    func propose(_ request: FunctionCallRequest) async throws -> [ProposedFunctionCall] {
        guard !request.tools.isEmpty else { return [] }
        // Same gate as Needle, in the same place: a sentence the catalogue cannot serve is
        // refused before a model is asked, so the two backends cannot disagree about it.
        if let reason = FunctionCallRelevance.preflightRefusal(request) {
            Log.agent.info("function call not proposed: \(reason, privacy: .public)")
            return []
        }
        let grammar = Self.grammar(for: FunctionCallRelevance.wireTools(for: request.tools))
        let system = Self.systemPrompt(facts: request.facts)
        let user = Self.userPrompt(request)
        let started = Date()

        let text: String
        if let provider {
            text = try await provider(system, user, grammar)
        } else {
            guard let llm = await Self.onDeviceProvider() else {
                throw FunctionCallError.notReady("No on-device model is available yet.")
            }
            let completion = try await llm.complete(
                system: system,
                user: user,
                maxTokens: Self.maxTokens,
                grammar: grammar
            )
            // A provider that cannot constrain decoding generates freely, so the grammar is
            // used as a check instead of a sampler. Anything it would not have allowed is
            // thrown away rather than repaired — a half-parsed tool call is how an argument
            // ends up attached to the wrong name.
            if !llm.enforcesGrammar, !grammar.matches(completion.text) {
                guard let salvaged = Self.firstJSONObject(in: completion.text),
                      grammar.matches(salvaged) else {
                    throw FunctionCallError.badOutput("the answer did not fit the required shape")
                }
                text = salvaged
            } else {
                text = completion.text
            }
        }

        let latency = Date().timeIntervalSince(started)
        return Self.decode(
            text,
            request: request,
            latency: latency
        )
    }

    // MARK: - Prompt and grammar

    static func systemPrompt(facts: [String]) -> String {
        var lines = [
            "You decide whether someone just asked for something an app can do.",
            "Answer with the JSON object only.",
            "Rules you may not break:",
            "- If nothing was asked for, return an empty calls list. Most sentences are not requests.",
            "- Only use a tool from the list.",
            "- Anything about opening an app, a browser or a folder, going to a website, "
                + "clicking, searching or playing media is `no_action`. None of these tools "
                + "can do that, and the nearest one is still wrong.",
            "- A question is `no_action`. Answering is somebody else's job.",
            "- Copy argument values out of what was said. Never invent an email address, "
                + "a phone number, a link or a file name.",
            "- If a value was not said, leave the argument out entirely. Somebody will be "
                + "asked for it.",
            "- quote must be the exact words that asked for it.",
            "- confidence is 0 to 100, how sure you are this was a request.",
        ]
        if !facts.isEmpty {
            lines.append("What you know right now:")
            lines.append(contentsOf: facts.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    static func userPrompt(_ request: FunctionCallRequest) -> String {
        var sections: [String] = []
        sections.append("Tools:")
        // Including the abstention tool. A list with no way to decline is a list the model
        // has to pick from, and the nearest neighbour to "open Chrome" is a document.
        for tool in FunctionCallRelevance.wireTools(for: request.tools) {
            let parameters = tool.parameters.map { parameter in
                "  \(parameter.name)\(parameter.isRequired ? " (needed)" : "") — \(parameter.description)"
            }
            sections.append(([" \(tool.id) — \(tool.description)"] + parameters).joined(separator: "\n"))
        }
        if !request.window.isEmpty {
            sections.append("Earlier in the conversation:\n\(request.window)")
        }
        sections.append("Just said:\n\(request.utterance)")
        return sections.joined(separator: "\n\n")
    }

    /// `{"calls": [{"tool": …, "arguments": [{"name": …, "value": …}], "quote": …, "confidence": …}]}`
    static func grammar(for tools: [FunctionCallTool]) -> GBNFGrammar {
        let argument = GBNFSchema.object([
            ("name", .string(maxLength: 40)),
            ("value", .string(maxLength: maxValueLength)),
        ])
        let call = GBNFSchema.object([
            ("tool", .enumeration(tools.map(\.id))),
            ("arguments", .array(argument, maxItems: maxArguments)),
            ("quote", .string(maxLength: 200)),
            ("confidence", .integer),
        ])
        return GBNFGrammar.json(.object([("calls", .array(call, maxItems: maxCalls))]))
    }

    /// The first `{…}` in free text, for a provider that wrapped its answer in a sentence.
    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Decoding

    private struct Answer: Decodable {
        struct Argument: Decodable {
            let name: String
            let value: String
        }
        struct Call: Decodable {
            let tool: String
            let arguments: [Argument]
            let quote: String
            let confidence: Int
        }
        let calls: [Call]
    }

    static func decode(
        _ text: String,
        request: FunctionCallRequest,
        latency: TimeInterval
    ) -> [ProposedFunctionCall] {
        guard let data = text.data(using: .utf8),
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            return []
        }
        let byID = Dictionary(uniqueKeysWithValues: request.tools.map { ($0.id, $0) })
        var proposals: [ProposedFunctionCall] = []
        for call in answer.calls.prefix(maxCalls) {
            // "Nothing was asked for" is an answer, and it ends the turn.
            if call.tool == FunctionCallRelevance.abstentionToolID { return [] }
            guard let tool = byID[call.tool] else { continue }
            let confidence = min(1, max(0, Double(call.confidence) / 100))
            guard confidence >= minimumConfidence else { continue }

            // Names the schema does not have are dropped rather than passed through: an
            // argument the executor does not recognise becomes a flag nobody validated.
            let known = Set(tool.parameters.map(\.name))
            var arguments: [String: String] = [:]
            for argument in call.arguments where known.contains(argument.name) {
                let value = argument.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { arguments[argument.name] = value }
            }

            let quote = call.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = ProposedFunctionCall(
                toolID: tool.id,
                arguments: arguments,
                confidence: confidence,
                span: TranscriptSpan(
                    text: quote.isEmpty ? request.span.text : quote,
                    start: request.span.start,
                    end: request.span.end
                ),
                reasoning: "",
                backend: .localModel,
                latency: latency
            )
            let filtered = FunctionCallGrounding.filter(
                raw, tool: tool, source: request.groundingText, utterance: request.utterance
            )
            // Same rules as the Needle backend, from the same file: a call with nothing real
            // left in it is a hallucination with a form attached, and a call for a tool the
            // sentence never asked about is a nearest neighbour.
            if let reason = FunctionCallRelevance.refusal(
                for: filtered, tool: tool, request: request
            ) {
                Log.agent.info("local call dropped: \(reason, privacy: .public)")
                continue
            }
            proposals.append(filtered)
        }
        return proposals
    }
}
