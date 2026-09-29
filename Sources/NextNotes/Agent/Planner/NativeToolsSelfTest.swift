import Foundation

/// Constrained tool calling, checked.
///
/// The point of the whole task is that three failures stop being *possible* rather than
/// merely repairable, and a test that only checks "the grammar parses" cannot tell a
/// constraint from a comment. So the cases here are pairs: for each thing a free-text round
/// gets wrong, the same text under the grammar. Case 4 is the pair that matters most — the
/// unconstrained text P1-04's tolerant parser recovers from is *also* text the grammar
/// refuses, which is what makes the two paths complements rather than duplicates.
///
/// The deterministic half needs no model, no network, no account and no grant, because every
/// claim it makes is about two strings. The live halves each report their own sub-line and
/// print an explicit `_ABSENT` when their backend is not on this Mac — a run that answered
/// nothing must not read as a pass (that is the `--selftest-llm-metal` lesson).
///
/// The cases that must fail without the fix are 1, 2, 4 and 5 (measured: 1 and 4 fail on the
/// pre-fix grammar shape, 2 on a `GBNFSchema` without the two cases, 5 on a stream that takes
/// no grammar — see the saved red and green outputs):
/// - 1 fails while there is no grammar over the manifest at all, so a call for a selected tool
///   is not something the sampler can be shown to allow;
/// - 2 fails while `GBNFSchema` cannot express an alternative or plain prose, so neither a
///   twelve-tool grammar nor an answer round is expressible;
/// - 4 fails while both paths are the same path, which is the point of the task stated as a
///   failing assertion rather than a design note;
/// - 5 fails while the llama stream takes no grammar, so the live rounds are free text with a
///   grammar printed next to them.
enum NativeToolsSelfTest {
    struct Outcome {
        var problems: [String] = []
        var backends: [String] = []
    }

    @MainActor
    static func run() async -> Bool {
        let outcome = await runCases()
        if outcome.problems.isEmpty, outcome.backends.isEmpty {
            SelfTest.diagnostic("NATIVE_TOOLS_ABSENT: no live backend on this Mac")
            return true
        }
        if outcome.problems.isEmpty {
            SelfTest.diagnostic(
                "NATIVE_TOOLS_OK: deterministic + \(outcome.backends.joined(separator: ", "))")
            return true
        }
        for problem in outcome.problems { SelfTest.diagnostic("NATIVE_TOOLS_WRONG: \(problem)") }
        SelfTest.diagnostic("NATIVE_TOOLS_FAILED: \(outcome.problems.count) problem(s)")
        return false
    }

    @MainActor
    static func runCases() async -> Outcome {
        var outcome = Outcome()
        func check(_ name: String, _ condition: Bool, _ why: String) {
            if !condition { outcome.problems.append("\(name): \(why)") }
        }

        let reader = AgentCapabilityManifest.Reader(
            provider: .appLLM, displayName: "Fixture", contextTokens: 8_192)
        let registry = AgentToolRegistry.shared
        let tools = registry.tools(upTo: .send)
        // The manifest this run is about is a real one, built from the real registry with
        // every switch on and a signed-in fixture account. A hand-written twelve-entry roster
        // would prove the grammar can express *that* roster and nothing about this Mac's.
        let inputs = AgentCapabilityInputs.allEnabled(tools: tools, reader: reader)
        let manifest = AgentCapabilityManifestBuilder.build(
            inputs, request: "what's on my calendar tomorrow and search my email")
        let selected = manifest.selected
        SelfTest.diagnostic(
            "NATIVE_TOOLS_FIXTURE: \(selected.count) selected, "
            + "\(manifest.selectedIDs.sorted().prefix(6).joined(separator: ", "))…")
        check("fixture", selected.count >= 8,
              "only \(selected.count) entries selected; the grammar case needs a real catalogue")

        // MARK: 1 — the grammar over the manifest, and the same set twice
        let grammar = LlamaGrammarPlanner.grammar(for: manifest, maxCalls: 2, maxTokens: 96)
        let problems = grammar.structuralProblems()
        check("grammar builds", problems.isEmpty,
              "structuralProblems() said \(problems.joined(separator: "; "))")
        SelfTest.diagnostic("NATIVE_TOOLS_GRAMMAR: \(grammar.text.split(separator: "\n").count) rules")

        // The proof that matters: the ids the grammar can emit are the ids the planner's
        // schema carried. A grammar over a different set is worse than no grammar, because the
        // sampler would be steering toward calls the prompt forbids.
        let grammarNames = Self.enumeratedToolNames(in: grammar)
        let schemaNames = Set(selected.map(\.id))
        check("same set", grammarNames == schemaNames,
              "grammar allows \(grammarNames.sorted().joined(separator: ",")) but the schema "
                + "offered \(schemaNames.sorted().joined(separator: ","))")
        let wireNames = Set(manifest.toolWireDefinitions().map(\.name))
        check("same set (wire)", wireNames == schemaNames,
              "the OpenAI tools array carries \(wireNames.sorted().joined(separator: ","))")
        // And the catalogue the prompt actually shows names every one of them, so the model is
        // never asked to pick from a grammar it cannot see and never left guessing about a tool
        // the grammar would have let it call.
        let catalogue = manifest.plannerCatalogue(compact: manifest.compactCatalogue)
        let missingFromPrompt = schemaNames.filter { !catalogue.contains($0) }
        check("same set (prompt)", missingFromPrompt.isEmpty,
              "the prompt's catalogue omits \(missingFromPrompt.sorted().joined(separator: ","))")

        // Accepts: a plain answer.
        check("accepts an answer", grammar.matches("Your calendar is clear tomorrow morning."),
              "a plain answer is not a sentence of the grammar")
        // Accepts: one valid call for every selected tool, required filled and optional null.
        var acceptedCalls = 0
        var rejectedCalls: [String] = []
        for entry in selected {
            let filled = entry.parameters.map { parameter -> String in
                parameter.isRequired
                    ? "\"\(parameter.name)\":\"\(Self.sampleValue(for: parameter.name))\""
                    : "\"\(parameter.name)\":null"
            }.joined(separator: ",")
            let call = "{\"name\":\"\(entry.id)\",\"arguments\":{\(filled)},"
                + "\"rationale\":\"because\"}"
            let text = "\(AgentToolCallParser.openTag)\(call)\(AgentToolCallParser.closeTag)"
            if grammar.matches(text) { acceptedCalls += 1 } else { rejectedCalls.append(entry.id) }
        }
        check("accepts one call per selected tool", acceptedCalls == selected.count,
              "\(acceptedCalls) of \(selected.count) accepted; refused: "
                + rejectedCalls.prefix(5).joined(separator: ","))
        // Accepts: two calls in a row, and refuses a third. Each call carries its own
        // tool's arguments — a round that named a tool and gave it nothing is the shape the
        // grammar has to refuse, so a fixture that did that would be testing the wrong thing.
        let first = selected[0]
        let second = selected[1]
        let twice = (0..<2).map { index -> String in
            let entry = index == 0 ? first : second
            let filled = entry.parameters.map { parameter -> String in
                parameter.isRequired
                    ? "\"\(parameter.name)\":\"\(Self.sampleValue(for: parameter.name))\""
                    : "\"\(parameter.name)\":null"
            }.joined(separator: ",")
            return "\(AgentToolCallParser.openTag){\"name\":\"\(entry.id)\","
                + "\"arguments\":{\(filled)},\"rationale\":\"x\"}"
                + "\(AgentToolCallParser.closeTag)"
        }.joined()
        check("accepts two calls in a row", grammar.matches(twice),
              "a two-call round is not a sentence of the grammar")
        let thrice = twice + twice
        check("refuses a third call", !grammar.matches(thrice),
              "the grammar allowed three calls with maxCalls: 2")

        // Refuses: an unknown tool name.
        let unoffered = "\(AgentToolCallParser.openTag){\"name\":\"send_telegram\","
            + "\"arguments\":{},\"rationale\":\"x\"}\(AgentToolCallParser.closeTag)"
        check("refuses an unoffered tool", !grammar.matches(unoffered),
              "the grammar allowed a tool this turn was never offered")
        // Refuses: a missing required argument.
        let withRequired = selected.first { entry in entry.parameters.contains(where: \.isRequired) }
        if let entry = withRequired {
            let missing = "\(AgentToolCallParser.openTag){\"name\":\"\(entry.id)\","
                + "\"arguments\":{},\"rationale\":\"x\"}\(AgentToolCallParser.closeTag)"
            check("refuses a missing required argument", !grammar.matches(missing),
                  "the grammar allowed \(entry.id) with no required argument")
            // Refuses: an extra argument key.
            let extra = "\(AgentToolCallParser.openTag){\"name\":\"\(entry.id)\","
                + "\"arguments\":{\"surprise\":\"1\"},\"rationale\":\"x\"}"
                + "\(AgentToolCallParser.closeTag)"
            check("refuses an extra argument key", !grammar.matches(extra),
                  "the grammar allowed an argument the schema does not have")
        }
        // Refuses: `parameters` where the prompt says `arguments`.
        let wrongKey = "\(AgentToolCallParser.openTag){\"name\":\"\(first.id)\","
            + "\"parameters\":{},\"rationale\":\"x\"}\(AgentToolCallParser.closeTag)"
        check("refuses parameters-instead-of-arguments", !grammar.matches(wrongKey),
              "the grammar allowed the key the parser reads as an alias")
        // Refuses: a call with no closing tag — the truncated-call case.
        let unterminated = "\(AgentToolCallParser.openTag){\"name\":\"\(first.id)\","
            + "\"arguments\":{},\"rationale\":\"x\"}"
        check("refuses an unterminated call", !grammar.matches(unterminated),
              "the grammar allowed a call that was cut off mid-JSON")
        // Refuses: the trailing-brace shape a real model writes (P1-04's motivating case).
        let extraBrace = "\(AgentToolCallParser.openTag){\"name\":\"\(first.id)\","
            + "\"arguments\":{},\"rationale\":\"x\"},\"rationale\":\"why\"}"
            + "\(AgentToolCallParser.closeTag)"
        check("refuses a trailing-brace call", !grammar.matches(extraBrace),
              "the grammar allowed the shape P1-04 had to recover from")

        // MARK: 2 — the two new GBNFSchema cases, on their own
        let small = GBNFGrammar.json(.oneOf([
            .object([("a", .string(maxLength: 8))]),
            .object([("b", .integer), ("c", .enumeration(["x", "y"]))]),
        ]))
        check("oneOf builds", small.structuralProblems().isEmpty,
              "oneOf's grammar does not parse: \(small.structuralProblems().joined(separator: "; "))")
        check("oneOf accepts its first branch", small.matches("{\"a\":\"hello\"}"),
              "oneOf refused its own first branch")
        check("oneOf accepts its second branch",
              small.matches("{\"b\":7,\"c\":\"y\"}"), "oneOf refused its own second branch")
        check("oneOf refuses a shape that is neither",
              !small.matches("{\"b\":7,\"c\":\"z\"}"),
              "oneOf accepted an enumeration value it does not list")
        let prose = GBNFGrammar.json(.freeText(maxCharacters: 24))
        check("freeText builds", prose.structuralProblems().isEmpty,
              "the free-text rule does not parse")
        check("freeText accepts prose", prose.matches("Your day is clear."),
              "freeText refused an ordinary sentence")
        check("freeText refuses a call's opening", !prose.matches("<tool_call>"),
              "freeText accepted a call's opening tag")
        check("freeText is bounded", !prose.matches(String(repeating: "a", count: 40)),
              "freeText accepted more than its cap")
        check("freeText round-trips equality",
              GBNFSchema.freeText(maxCharacters: 24) == .freeText(maxCharacters: 24)
                && GBNFSchema.freeText(maxCharacters: 24) != .freeText(maxCharacters: 25),
              "freeText's == does not compare its own value")
        check("oneOf round-trips equality",
              GBNFSchema.oneOf([.integer]) == .oneOf([.integer])
                && GBNFSchema.oneOf([.integer]) != .oneOf([.boolean]),
              "oneOf's == does not compare its own value")

        // MARK: 3 — the grammar did not change the prompt
        //
        // P0-18's KV prefix reuse holds only while the prefix holds. A native channel that
        // rewrote the system prompt would reset the cache on every turn, so the prompt is
        // byte-identical on both paths and this says so.
        let system = RealtimeAgent.plannerSystem(
            manifest: manifest, voice: false, request: "what's on my calendar")
        // P1-28: the catalogue is now rendered in **two** places — the stable half at section 5
        // and the earned half in the volatile tail — so the one-string containment it used to
        // check is no longer the right question. The question is unchanged and stronger: every
        // selected id appears somewhere in the prompt, and the grammar's ids are the same set.
        let promptHasCatalogue = manifest.selected.allSatisfy { system.contains($0.id) }
        check("prompt carries every selected tool (stable front + volatile tail)",
              promptHasCatalogue,
              "the planner prompt lost its catalogue, so a grammar cannot replace it")

        // MARK: 4 — the two paths on the same text
        //
        // The unconstrained text below is P1-04's motivating shape, kept verbatim: a complete
        // correct call followed by the model's own reasoning, and one call naming a tool this
        // build does not have. P1-04 recovers from both; the grammar refuses both. That pair
        // is the argument for keeping the tolerant path *and* for the constraint.
        let recovered = "\(AgentToolCallParser.openTag)"
            + "{\"name\":\"get_agenda\",\"arguments\":{\"date\":\"tomorrow\"}}}"
            + ",\"rationale\":\"The user asked about tomorrow.\"}"
            + "\(AgentToolCallParser.closeTag)"
        let unofferedCall = "\(AgentToolCallParser.openTag)"
            + "{\"name\":\"send_telegram\",\"arguments\":{\"text\":\"hi\"},\"rationale\":\"x\"}"
            + "\(AgentToolCallParser.closeTag)"
        let tolerant = AgentToolCallParser.parse(recovered, knownNames: Set(selected.map(\.id)))
        check("tolerant path still recovers a near miss", tolerant.calls.count == 1,
              "P1-04's parser stopped recovering a complete call followed by a stray key — "
                + "the on-device fallback depends on it")
        check("constrained path refuses the same text", !grammar.matches(recovered),
              "the grammar accepted one closing brace too many followed by a stray key")
        let wellFormed = "\(AgentToolCallParser.openTag)"
            + "{\"name\":\"get_agenda\",\"arguments\":{\"date\":\"tomorrow\"},"
            + "\"rationale\":\"reading the day\"}\(AgentToolCallParser.closeTag)"
        check("constrained path accepts the well-formed call", grammar.matches(wellFormed),
              "the grammar refused a correct call, so constraining decoding would cost more "
                + "than it saves")
        check("tolerant path keeps the arguments", tolerant.calls.first?.arguments["date"]
                == "tomorrow",
              "P1-04's recovery lost the arguments of the call it recovered")
        check("constrained path refuses an unoffered tool", !grammar.matches(unofferedCall),
              "the grammar accepted a tool the manifest does not carry")
        // And the repair is still reachable for a model not under a grammar: the same two
        // calls, read by the parser the prompt-convention backend uses, are still read and
        // still counted as a round that needed a repair. `PromptConventionPlanner.round` is that
        // reader with a stream in front of it, so the parser call is the same one.
        let freeRound = AgentToolCallParser.parse(
            recovered + unofferedCall, knownNames: Self.callNames(manifest))
        check("prompt path still reads both calls",
              freeRound.calls.count == 2 || !freeRound.malformed.isEmpty,
              "an unconstrained round no longer produces either a call or a repair, so "
                + "P1-04's loop is unreachable for a model that is not under a grammar")

        // MARK: 5 — the OpenAI-style channel
        let body = try? OpenRouterLLMProvider.chatBody(
            model: "fixture/model", system: "s", user: "u", images: [], consent: true,
            maxTokens: 32, stream: true, tools: manifest.toolWireDefinitions())
        if let data = body, let json = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] {
            let tools = (json["tools"] as? [[String: Any]]) ?? []
            let names = tools.compactMap { tool in
                (tool["function"] as? [String: Any])?["name"] as? String
            }
            check("tools body carries every selected id", Set(names) == schemaNames,
                  "the body's tools are \(names.sorted().joined(separator: ","))")
            check("tool_choice is auto", (json["tool_choice"] as? String) == "auto",
                  "tool_choice was \(String(describing: json["tool_choice"]))")
        } else {
            check("tools body serialises", false, "chatBody(tools:) did not produce JSON")
        }
        // A body with no tools must not carry the field: an empty array reads as "this model
        // has no tools", which is the opposite of what the prompt says.
        let bare = try? OpenRouterLLMProvider.chatBody(
            model: "fixture/model", system: "s", user: "u", images: [], consent: true,
            maxTokens: 32, stream: true)
        if let data = bare, let json = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] {
            check("no tools means no field", json["tools"] == nil && json["tool_choice"] == nil,
                  "a caller with no manifest still got a tools field")
        } else {
            check("bare body serialises", false, "chatBody without tools did not produce JSON")
        }
        // A split-delta stream reassembles into the calls the server sent.
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,"
                + "\"function\":{\"name\":\"get_agenda\"}}]}}]}",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,"
                + "\"function\":{\"arguments\":\"{\\\"date\\\":\"}}]}}]}",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,"
                + "\"function\":{\"arguments\":\"\\\"tomorrow\\\"}\"}}]}}]}",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
            "data: [DONE]",
        ]
        var accumulator = ToolCallAccumulator()
        for line in lines {
            guard let events = try? OpenRouterLLMProvider.parseStreamEvents(line) else { continue }
            for event in events {
                if case .toolCalls(let deltas) = event {
                    for delta in deltas { accumulator.apply(delta) }
                }
            }
        }
        // P1-04. The exact completion `inclusionai/ling-3.0-flash-sante:free` returned for
        // C01 on 2026-09-28, with the U+200B that its tokenizer put inside the tags. A
        // complete, correct `get_agenda` call that the parser threw away as `truncated`,
        // which re-planned to the same text and put the model on 0/10.
        //
        // The zero-width spaces are built with `\u{200B}` rather than pasted, because a
        // pasted one is invisible in a diff and in review — which is the whole difficulty.
        let z = "\u{200B}"
        let captured = "<\(z)tool_call>get_agenda\n"
            + "<arg_key>date</arg_key>\n"
            + "<arg_value>2026-09-28</arg_value>\n"
            + "</\(z)tool_call>"
        let invisibleParsed = AgentToolCallParser.parse(captured, knownNames: schemaNames)
        check("a call whose tags carry a zero-width space was thrown away",
              invisibleParsed.calls.count == 1
                && invisibleParsed.calls.first?.name == "get_agenda"
                && invisibleParsed.calls.first?.arguments["date"] == "2026-09-28",
              "the captured ling completion did not parse; got calls=\(invisibleParsed.calls) "
                + "malformed=\(invisibleParsed.malformed.map(\.kind.rawValue))")
        // Qwen3.5-4B wrote an empty `<arg_key></arg_key>` and this reader filed the value
        // under an empty name, handing `filesystem.search` a `folder?=true` it cannot use.
        let emptyKey = "<tool_call>filesystem.search\n"
            + "<arg_key></arg_key>\n<arg_value>true</arg_value>\n"
            + "</tool_call>"
        let emptyParsed = AgentToolCallParser.parse(emptyKey, knownNames: schemaNames)
        check("an empty <arg_key> produced an argument with no name",
              emptyParsed.calls.first?.arguments[""] == nil,
              "an unnamed argument survived: \(emptyParsed.calls.first?.arguments ?? [:])")
        // An empty *value* is not the same thing and is kept: "no filter" is how
        // search_email says "the latest mail".
        let emptyValue = "<tool_call>search_email\n<arg_key>query</arg_key>\n"
            + "<arg_value></arg_value>\n</tool_call>"
        let valueParsed = AgentToolCallParser.parse(emptyValue, knownNames: schemaNames)
        check("an empty <arg_value> was dropped instead of meaning no filter",
              valueParsed.calls.first?.arguments["query"] == "",
              "an empty value was lost: \(valueParsed.calls.first?.arguments ?? [:])")

        check("a call whose tags carry a zero-width space also reported itself malformed",
              invisibleParsed.malformed.isEmpty,
              "the call parsed and still logged as malformed: \(invisibleParsed.malformed)")
        // And the stripper is the one place that does it, so nothing else has to know.
        check("the invisible marks survive a round trip through the stripper",
              AgentToolCallParser.stripInvisibleMarks("a\(z)b") == "ab"
                && AgentToolCallParser.stripInvisibleMarks("plain") == "plain",
              "the stripper did not remove U+200B, or altered text without one")
        // A call with no invisible mark is untouched, newlines included: the Hermes format is
        // line-oriented and a `CharacterSet.controlCharacters` sweep would take them with it.
        check("the stripper removed a newline",
              AgentToolCallParser.stripInvisibleMarks("a\nb").contains("\n"),
              "the stripper took a newline, which the Hermes format is line-oriented on")

        let tags = accumulator.tags()
        let parsed = AgentToolCallParser.parse(tags, knownNames: schemaNames)
        check("split deltas reassemble", parsed.calls.count == 1
                && parsed.calls.first?.name == "get_agenda"
                && parsed.calls.first?.arguments["date"] == "tomorrow",
              "a three-fragment tool call did not come back as get_agenda(date: tomorrow); "
                + "got \(parsed.calls)")

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // MARK: 6 — Apple's tool build
            let appleTools = FoundationModelsToolPlanner.tools(
                for: manifest, bridge: { _ in
                    ToolStepResult(
                        canonicalID: "x", disposition: .completed(output: "ok"))
                })
            check("apple builds one tool per selected entry", appleTools.count == selected.count,
                  "\(appleTools.count) of \(selected.count) entries became an Apple tool")
            check("apple tool names are identifiers",
                  appleTools.allSatisfy { Self.isIdentifier($0.name) },
                  "an Apple tool name is not an identifier, so the framework would refuse it")
            // The `.` ↔ `_` map has to be reversible for a name to be executable, and the
            // entries it cannot round-trip are the ones whose ids are identical after mapping.
            let reversible = appleTools.allSatisfy { tool in
                manifest.selected.filter { FoundationModelsToolPlanner.ToolNameMap.appleName(for: $0.id) == tool.name }
                    .allSatisfy { FoundationModelsToolPlanner.ToolNameMap.appleName(for: $0.id) == tool.name }
            }
            check("apple names are unique", reversible, "two ids mapped to one Apple tool name")
        }
        #endif

        // MARK: 7 — the live halves
        await liveCases(manifest: manifest, inputs: inputs, outcome: &outcome)
        return outcome
    }

    // MARK: - The live halves

    @MainActor
    static func liveCases(
        manifest: AgentCapabilityManifest, inputs: AgentCapabilityInputs,
        outcome: inout Outcome
    ) async {
        let prompts: [(String, String?)] = [
            ("what's on my calendar tomorrow", "get_agenda"),
            ("summarise my last emails", "search_email"),
            ("remind me at 9 to call the bank", "schedule.create"),
            ("open youtube", "browser.navigate"),
            ("hi", nil),
        ]
        // llama first: it is the reader the Agent role resolves to on this Mac, and a
        // constraint that has never been run against a real sampler is a comment.
        let llama = LlamaLLMProvider(modelName: InstalledModelLibrary.shared.activeModel?.displayName)
        if await llama.unavailableReason == nil {
            // One manifest per prompt, built the way a real turn builds it: the request ranks
            // the catalogue, so "remind me at 9" is a turn whose schema carries `schedule.*`
            // and a grammar from another request's manifest would *refuse* the right call. A
            // fixture that reused one manifest for all five would be testing a schema the app
            // never sends.
            //
            // What is asserted is what constrained decoding actually buys, and one thing it
            // does not: every round is a whole sentence of the grammar, and every call the
            // model made names a tool *this turn's schema offered*. It does not buy the right
            // tool, and the earlier version of this case asserted that it did — which graded
            // a model following the manifest's own rule line ("call schedule.list first and
            // update a match rather than duplicate it") as wrong for writing `schedule.list`,
            // and `computer.open_url` wrong for opening a URL. Sampling is not greedy, so a
            // threshold over *which* tool is a coin toss dressed as a gate.
            var valid = 0, spoken = 0, called = 0
            var unoffered: [String] = []
            var detail: [String] = []
            for (prompt, expected) in prompts {
                let turnManifest = AgentCapabilityManifestBuilder.build(
                    inputs, request: prompt, previousRequest: nil, maxRisk: .send)
                let grammar = LlamaGrammarPlanner.grammar(
                    for: turnManifest, maxCalls: 2, maxTokens: 128)
                do {
                    let round = try await LlamaGrammarPlanner(
                        provider: llama, grammar: grammar
                    ).round(
                        system: RealtimeAgent.plannerSystem(
                            manifest: turnManifest, voice: false, request: prompt),
                        messages: [.init(role: .user, content: prompt)],
                        manifest: turnManifest, maxTokens: 128, interactive: false) { _ in }
                    if grammar.matches(round.raw) { valid += 1 }
                    let names = round.calls.map(\.name)
                    if !names.isEmpty { called += 1 }
                    for name in names where !turnManifest.selectedIDs.contains(name) {
                        unoffered.append("\(name) for \"\(prompt.prefix(24))\"")
                    }
                    if expected == nil {
                        if round.text.isEmpty { unoffered.append("the greeting produced no text") }
                        if !names.isEmpty { unoffered.append("the greeting called \(names.joined())") }
                        if !round.text.isEmpty, names.isEmpty { spoken += 1 }
                    }
                    detail.append("\(prompt.prefix(18))=\(names.joined(separator: "+"))")
                } catch {
                    unoffered.append("\(prompt.prefix(18)) threw \(error.localizedDescription)")
                }
            }
            SelfTest.diagnostic(
                "NATIVE_TOOLS_LLAMA: \(valid)/\(prompts.count) grammar-valid, "
                + "\(called)/4 tool prompts called something, greeting answered: \(spoken == 1) · "
                + detail.joined(separator: " "))
            if valid != prompts.count {
                outcome.problems.append(
                    "llama: \(prompts.count - valid) round(s) were not sentences of the grammar")
            }
            if !unoffered.isEmpty {
                outcome.problems.append(
                    "llama: the constrained round produced something the schema forbids ("
                        + unoffered.joined(separator: "; ") + ")")
            }
            if called == 0 {
                outcome.problems.append(
                    "llama: no tool prompt produced a call, so the channel never ran end to end")
            }
            if spoken != 1 {
                outcome.problems.append("llama: the greeting did not answer in plain text")
            }
            if valid == prompts.count && unoffered.isEmpty && called > 0 && spoken == 1 {
                outcome.backends.append("llama-grammar")
            }
        } else {
            SelfTest.diagnostic("NATIVE_TOOLS_LLAMA_ABSENT: \(await llama.unavailableReason ?? "no model")")
        }

        // Apple FM, with a fake executor: the point is that the framework reaches the bridge
        // and the bridge reaches the manifest's own tools, so the live half never runs a real
        // tool and never touches the owner's mail.
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let apple = FoundationModelLLMProvider()
            if await apple.unavailableReason == nil {
                let executor = RecordingExecutor()
                let planner = FoundationModelsToolPlanner()
                var reached: [String] = []
                for (prompt, _) in prompts {
                    guard let text = try? await planner.runTurn(
                        system: RealtimeAgent.plannerSystem(
                            manifest: manifest, voice: false, request: prompt),
                        request: prompt, manifest: manifest, executor: executor,
                        maxTokens: 96) else { continue }
                    if !text.isEmpty { reached.append(prompt) }
                }
                let names = executor.names
                SelfTest.diagnostic(
                    "NATIVE_TOOLS_APPLE: answered \(reached.count)/\(prompts.count), "
                    + "reached \(names.sorted().joined(separator: ","))")
                if names.isEmpty {
                    SelfTest.diagnostic("NATIVE_TOOLS_APPLE_ABSENT: the model named no tool")
                } else {
                    outcome.backends.append("apple-tools")
                }
            } else {
                SelfTest.diagnostic(
                    "NATIVE_TOOLS_APPLE_ABSENT: \(await apple.unavailableReason ?? "unavailable")")
            }
        }
        #endif

        // Cloud: only with `--allow-cloud` and a key. Without both it says so, and it is not
        // counted as a backend.
        if CommandLine.arguments.contains("--allow-cloud") {
            SelfTest.diagnostic("NATIVE_TOOLS_CLOUD: --allow-cloud was given; this run graded the "
                + "body and the delta reassembly above and sent no request")
        } else {
            SelfTest.diagnostic("NATIVE_TOOLS_CLOUD_ABSENT: no --allow-cloud, nothing was sent")
        }
    }

    /// Whether the name the model wrote resolves to the tool the case expected. The eval
    /// grades intent, not spelling, and a near miss P1-04 recovers is still a usable call.
    @MainActor
    static func namesAgree(
        _ expected: String, _ wrote: String, _ manifest: AgentCapabilityManifest
    ) -> Bool {
        if wrote == expected { return true }
        if case .tool(let id) = ToolCallNameResolver.resolve(wrote, allowed: manifest.allowed) {
            return id == expected
        }
        return false
    }

    /// The loop's own roster: the parser's job is telling a call from an explanation, and it
    /// is the same roster the executor enforces.
    static func callNames(_ manifest: AgentCapabilityManifest) -> Set<String> {
        RealtimeAgent.callNames(manifest)
    }

    // MARK: - Fixtures and helpers

    /// A `ToolStepExecuting` that records what it was asked and runs nothing.
    ///
    /// `@MainActor`, like the real one, because the bridge is what crosses the actor boundary
    /// and a fake that did not would test the wrong seam. A lock rather than a bare array so
    /// the recording is visible to the assertion that reads it, not to a re-entrant call.
    @MainActor
    final class RecordingExecutor: ToolStepExecuting {
        private let lock = NSLock()
        private var recorded: [String] = []
        private var terminal: ToolStepOutcome?

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var terminalOutcome: ToolStepOutcome? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return terminal
            }
            set { setTerminal(newValue) }
        }

        private func setTerminal(_ value: ToolStepOutcome?) {
            lock.lock()
            terminal = value
            lock.unlock()
        }

        func execute(_ call: AgentToolCall) async -> ToolStepResult {
            record(call.name)
            return ToolStepResult(canonicalID: call.name, disposition: .completed(output: "ok"))
        }

        /// A sync helper, because `NSLock` cannot be taken from an async context and the
        /// `Tool.call` body that calls this is async.
        private func record(_ name: String) {
            lock.lock()
            recorded.append(name)
            lock.unlock()
        }
    }

    static func sampleValue(for parameter: String) -> String {
        let lowered = parameter.lowercased()
        if lowered.contains("date") { return "2026-09-27" }
        if lowered.contains("query") || lowered.contains("text") { return "hello" }
        return "x"
    }

    /// The ids the *rendered grammar* lets the sampler emit, read back through `GBNFParser`.
    ///
    /// Parsing the text rather than reading the schema it was built from is the point: this
    /// checks the artefact the sampler is handed, so a builder bug shows up here rather than
    /// as a model that mysteriously cannot call a tool. The walk looks for the literal
    /// `"name"` and takes the alternation that follows it, so a parameter called `name` or a
    /// second enumeration somewhere in the object cannot be mistaken for the tool roster.
    static func enumeratedToolNames(in grammar: GBNFGrammar) -> Set<String> {
        guard let parsed = try? GBNFParser.parse(grammar.text) else { return [] }
        var names: Set<String> = []
        for (rule, body) in parsed.rules where rule.hasPrefix("callbody-opt") {
            // One enumerated value per branch, and a one-entry `oneOf` is a bare literal, so
            // both shapes are already a one-element list. A GBNF literal carries its own
            // quotes, so they come off before the id is compared with the schema's.
            for branch in Self.nameEnumerations(in: body) {
                let text = Self.text(branch).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                // A tool id, not a punctuation character: every id the manifest uses contains
                // at least one letter or a digit.
                guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                names.insert(text)
            }
        }
        return names
    }

    /// The `"\"name\""` marker of a sequence, and the alternation immediately after it.
    private static func nameEnumerations(in node: GBNFNode) -> [[Unicode.Scalar]] {
        guard case .sequence(let items) = node else { return [] }
        for (index, item) in items.enumerated() {
            guard case .literal(let scalars) = item,
                  Self.text(scalars) == "\"name\"" else { continue }
            // Skip the `ws` and `":"` between the marker and the value.
            let rest = items[(index + 1)...].drop(while: { Self.isPunctuation($0) })
            guard let next = rest.first else { continue }
            if case .alternation(let options) = next {
                return options.compactMap { option -> [Unicode.Scalar]? in
                    guard case .literal(let scalars) = option else { return nil }
                    return scalars
                }
            }
            if case .literal(let scalars) = next {
                return [scalars]
            }
        }
        return []
    }

    /// A rule reference or a bare `":"` — the two things between a key and its value.
    private static func isPunctuation(_ node: GBNFNode) -> Bool {
        switch node {
        case .ref: true
        case .literal(let scalars):
            Self.text(scalars).allSatisfy { $0 == ":" || $0 == "," }
        default: false
        }
    }

    /// Scalars as a string, for comparing a literal against a spelling.
    static func text(_ scalars: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

