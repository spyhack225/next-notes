import Foundation
import FoundationModels

/// The Apple Intelligence memory review: guided generation, not parsed prose.
///
/// Why this file exists. The review used to hand every provider the same prompt and
/// parse `<tool_call>` XML out of the answer. That works for llama.cpp (its GBNF
/// grammar constrains the shape) and it worked for OpenRouter's larger models — but the
/// on-device Foundation Model does not answer in somebody else's markup, so the parser
/// found no calls on every run. Measured on the fixture set, 2026-09-22: **0 saves on
/// all 17 cases, including "my name is …"**, while the ledger recorded `modelCalled:
/// true` — which is exactly why memory stayed empty through hundreds of sources.
///
/// Foundation Models offers the same guarantee llama's grammar does: `@Generable`, a
/// response whose shape the runtime enforces. This model asks for a typed answer and
/// serialises it back into the same `<tool_call>` text the existing parser and the
/// provenance guards already consume — so exactly one place still decides what may be
/// saved, and the guards are untouched.
@Generable(description: "What, if anything, from this material belongs in the user's long-term memory.")
struct AppleMemoryReviewAnswer {
    @Guide(description: "Zero or more calls. Leave empty when nothing here is worth saving.")
    var calls: [AppleMemoryReviewCall]
}

@Generable(description: "One memory tool call.")
struct AppleMemoryReviewCall {
    @Guide(description: "remember, update or forget.")
    var tool: String
    @Guide(description: "For remember only: profile (a fact or preference about the user, e.g. \"The user prefers short answers.\") or note (a working arrangement — which app to use, where notes, files or documents go — e.g. \"The user's standup notes go to the team Drive folder.\").")
    var kind: String
    @Guide(description: "For remember or update: one declarative sentence that starts with \"The user\", using only the user's own words — add nothing they did not say. Never a command.")
    var text: String
    @Guide(description: "For update or forget: a unique part of the existing fact. Empty otherwise.")
    var match: String
}

/// `MemoryReviewModel` over Foundation Models' guided generation.
struct AppleMemoryReviewModel: MemoryReviewModel {
    let label = "Apple Intelligence"

    func complete(system: String, user: String) async throws -> String {
        guard FoundationModelFormatter.unavailableReason == nil else {
            throw AppleMemoryReviewError.unavailable(
                FoundationModelFormatter.unavailableReason ?? "The on-device model is unavailable.")
        }
        let session = LanguageModelSession(instructions: system)
        let response = try await session.respond(
            to: user,
            generating: AppleMemoryReviewAnswer.self,
            // Greedy, not temperature 0: the review is a classification task, and measured
            // on the fixture set temperature 0 still sampled — two runs of the same case
            // produced different calls ("The user is unrestricted now." in one, NONE in the
            // next), which made every graded number unrepeatable. Greedy is one answer.
            options: GenerationOptions(samplingMode: .greedy)
        )
        return Self.toolCallText(response.content.calls)
    }

    /// The typed answer, written as the `<tool_call>` text the shared parser reads.
    /// A call with nothing to act on is dropped here rather than handed on as a
    /// half-formed proposal the guards would have to refuse.
    static func toolCallText(_ calls: [AppleMemoryReviewCall]) -> String {
        let lines = calls.compactMap(toolCallLine)
        return lines.isEmpty ? "NONE" : lines.joined(separator: "\n")
    }

    private static func toolCallLine(_ call: AppleMemoryReviewCall) -> String? {
        // The model reads the tool names as `memory.remember` in the instructions and
        // answers with that whole name — measured on the fixture set: the first version
        // accepted only the bare verb and dropped every call, which read as "nothing to
        // save" on all 17 cases.
        let tool = call.tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "memory.", with: "")
            .replacingOccurrences(of: "memory_", with: "")
        let arguments: [String: String]
        switch tool {
        case "remember":
            arguments = ["kind": call.kind, "text": call.text]
        case "update":
            arguments = ["match": call.match, "text": call.text]
        case "forget":
            arguments = ["match": call.match]
        default:
            return nil
        }
        let cleaned = arguments
            .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        switch tool {
        case "remember":
            guard cleaned["kind"] != nil, cleaned["text"] != nil else { return nil }
        case "update":
            guard cleaned["match"] != nil, cleaned["text"] != nil else { return nil }
        case "forget":
            guard cleaned["match"] != nil else { return nil }
        default:
            return nil
        }
        let body: [String: Any] = ["name": "memory.\(tool)", "arguments": cleaned]
        guard let data = try? JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "<tool_call>\(json)</tool_call>"
    }
}

enum AppleMemoryReviewError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}
