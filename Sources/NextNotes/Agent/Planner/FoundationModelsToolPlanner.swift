import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// The planner on Apple's Foundation Models, with one `Tool` per selected entry and a bridge
/// into the same executor the prompt-convention loop uses.
///
/// Apple's framework runs its own call loop: it decides when to call a tool, hands the
/// arguments over, and reads what the call returned. That removes the parse, the repair round
/// and the round bookkeeping — and it is the reason this backend is a whole-turn shape rather
/// than a round shape. What it does not remove is the permission model, which is the entire
/// reason the `Tool.call` body is a bridge and not the call: the framework deciding to invoke
/// a tool is the model *naming* it, and a write still waits for a person.
///
/// Every write in this planner goes through `ToolStepRunner.execute` → `AgentToolExecutor.run`,
/// which is the same path the prose-catalogue loop takes. A second way in would be how a
/// write stopped waiting.
@available(macOS 26.0, iOS 26.0, *)
struct FoundationModelsToolPlanner: AgentWholeTurnPlanner {
    var label: String { "apple-tools" }

    /// The ceiling a set of tools may occupy in Apple's window, in tokens.
    ///
    /// Apple's system model has the shortest window of anything this app asks (4,096 on the
    /// first generation, 8,192 measured since), and a twelve-entry catalogue plus a persona
    /// plus a history is a lot of it. Over the ceiling the session is rebuilt from a compact
    /// catalogue rather than left to fail the way it used to.
    static let toolTokenCeiling = 2_600

    /// One `Tool` per selected entry.
    ///
    /// `Arguments = GeneratedContent` because a catalogue built at runtime cannot supply a
    /// compile-time `@Generable` type per tool — which is the same reason the meeting side
    /// uses `DynamicGenerationSchema`. Every argument stays a string, because
    /// `WorkspaceTool.Parameter.schema` says everything is a string and the executor reads
    /// strings.
    struct ManifestTool: Tool {
        /// The canonical id. Apple's tool names must be identifiers, so a dot becomes a
        /// double underscore and `ToolNameMap` puts it back; the map lives in one place
        /// because a name that cannot be mapped back is a call that cannot be executed.
        let name: String
        let description: String
        let parameters: GenerationSchema
        let canonicalID: String
        let argumentNames: [String]
        /// The executor. Never anything else.
        let bridge: @Sendable (AgentToolCall) async -> ToolStepResult

        func call(arguments: GeneratedContent) async throws -> String {
            var values: [String: String] = [:]
            for key in argumentNames {
                if let value = try? arguments.value(String.self, forProperty: key),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    values[key] = value
                }
            }
            let result = await bridge(AgentToolCall(
                name: canonicalID, arguments: values, rationale: "", evidence: nil))
            return Self.modelText(for: result)
        }

        /// What the model reads next. Never a throw: a throw from `call` aborts the whole
        /// response with `LanguageModelSession.ToolCallError`, so a denial or an exhausted
        /// budget is a `STOP:` sentence the model can act on and the turn ends in the
        /// renderer's own words.
        static func modelText(for result: ToolStepResult) -> String {
            switch result.disposition {
            case .completed(let output):
                return output
            case .repaired(_, let note):
                return note
            case .skipped:
                return "That step was already done. Continue with the next one, or answer."
            case .answerNow:
                return "STOP: out of steps. Answer now with what you have."
            case .outOfTime:
                return "STOP: out of time. Answer now with what you have."
            case .endTurn(let end):
                switch end {
                case .denied(let sentence), .infrastructure(let sentence):
                    return "STOP: \(sentence). Do not call more tools; tell the user this in one sentence."
                case .notReady(let sentence):
                    return "STOP: \(sentence) Do not call more tools; tell the user this in one sentence."
                case .stopped:
                    return "STOP: that request could not be read. Tell the user in one sentence."
                }
            }
        }
    }

    /// The `.` → `_` map, in one place. Apple's tool names are identifiers; a canonical id
    /// like `schedule.create` becomes `schedule_create`, and a name that could not be mapped
    /// back would be a call the executor cannot resolve.
    ///
    /// There is no reverse map because there does not need to be one: `ManifestTool` carries
    /// its own `canonicalID`, so the id travels with the tool rather than being looked up out
    /// of a second table. A store of name → id would be a second roster.
    enum ToolNameMap {
        static func appleName(for id: String) -> String {
            let mapped = id.map { $0 == "." ? "_" : $0 }
            let name = String(mapped)
            return name.isEmpty ? "tool" : name
        }
    }

    /// One `Tool` per selected entry, or nil when Apple's schema builder refuses one.
    ///
    /// A refusal is not fatal: the framework builds schemas by name and a duplicate property
    /// is a real possibility once MCP and Composio entries join the native ones. The caller
    /// drops the entry that would not build rather than losing the turn.
    static func tools(
        for manifest: AgentCapabilityManifest,
        bridge: @escaping @Sendable (AgentToolCall) async -> ToolStepResult
    ) -> [ManifestTool] {
        var built: [ManifestTool] = []
        for entry in manifest.selected {
            guard let schema = generationSchema(for: entry) else {
                Log.agent.info("apple tool schema refused · id=\(entry.id, privacy: .public)")
                continue
            }
            built.append(ManifestTool(
                name: ToolNameMap.appleName(for: entry.id),
                description: entry.modelDescription, parameters: schema,
                canonicalID: entry.id, argumentNames: entry.parameters.map(\.name), bridge: bridge))
        }
        // A collision would make one of two capabilities unreachable under one name, which is
        // the same defect the manifest's "never shadow a native implementation" rule exists
        // to prevent. Drop the later one rather than picking a winner.
        var seen: Set<String> = []
        let unique = built.filter { seen.insert($0.name).inserted }
        return unique
    }

    /// `GenerationSchema(root: DynamicGenerationSchema(...), dependencies: [])`.
    static func generationSchema(
        for entry: AgentCapabilityManifest.Entry
    ) -> GenerationSchema? {
        let properties = entry.parameters.map { parameter in
            DynamicGenerationSchema.Property(
                name: parameter.name, description: parameter.description,
                schema: DynamicGenerationSchema(type: String.self),
                isOptional: !parameter.isRequired)
        }
        let root = DynamicGenerationSchema(
            name: ToolNameMap.appleName(for: entry.id),
            description: entry.modelDescription, properties: properties)
        return try? GenerationSchema(root: root, dependencies: [])
    }

    // MARK: - The turn

    func runTurn(
        system: String, request: String, manifest: AgentCapabilityManifest,
        executor: any ToolStepExecuting, maxTokens: Int
    ) async throws -> String {
        let bridge: @Sendable (AgentToolCall) async -> ToolStepResult = { call in
            await executor.execute(call)
        }
        var tools = Self.tools(for: manifest, bridge: bridge)
        // Below 26.4 the framework cannot count tools; the characters/4 estimate is the same
        // one the manifest's own fit uses, so a catalogue over the ceiling is compacted rather
        // than refused. One retry, because a second compaction of the same set would change
        // nothing.
        if await Self.toolTokens(tools: tools, system: system) > Self.toolTokenCeiling,
           let compact = manifest.compactedForApple() {
            tools = Self.tools(for: compact, bridge: bridge)
        }
        let session = LanguageModelSession(
            tools: tools.map { $0 as any Tool }, instructions: system)
        let began = ContinuousClock.now
        let response: String
        do {
            response = try await session.respond(
                to: request,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens)
            ).content
        } catch {
            throw LlamaGrammarPlanner.roundError(from: error, visible: "")
        }
        // P0-20a: Apple's usage counts are macOS 27's; below that the row carries the elapsed
        // time and an explicit estimate rather than a number this run did not measure.
        let seconds = max(0, began.duration(to: .now).secondsValue)
        ModelPassRecorder.current?.report(
            promptTokens: nil, cachedTokens: nil, completionTokens: nil,
            reasoningTokens: nil, finishReason: nil, estimated: true)
        Log.agent.info(
            "apple tool turn · tools=\(tools.count, privacy: .public) seconds=\(seconds, privacy: .public)")
        // A turn that ended on a denial is not the model's sentence: the renderer owns it.
        // One hop onto the main actor, because the executor is main-actor state and Apple's
        // `respond` is not.
        let terminal = await executor.terminalOutcome
        if case .denied(let sentence)? = terminal {
            return sentence
        }
        return response
    }

    /// Apple's own count where it exists, and the app's estimate below 26.4.
    ///
    /// `SystemLanguageModel` is what carries `tokenCount(for:)` — the session does not — and
    /// the signature is macOS 26.4, so the estimate is the answer on the generations where
    /// the framework cannot count for us.
    static func toolTokens(
        tools: [any Tool], system: String
    ) async -> Int {
        #if compiler(>=6.4)
        if #available(macOS 26.4, *) {
            let model = SystemLanguageModel.default
            let toolCount = (try? await model.tokenCount(for: tools)) ?? 0
            let instructionCount = (try? await model.tokenCount(for: Instructions(system)))
                ?? (system.count / 4)
            return toolCount + instructionCount
        }
        #endif
        return (system.count / 4) + (tools.count * 60)
    }
}
#endif
