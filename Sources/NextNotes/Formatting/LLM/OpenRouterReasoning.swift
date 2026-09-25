import Foundation

/// How an OpenRouter request treats a model's reasoning pass (P0-17).
///
/// A reasoning model spends completion tokens thinking before it writes any visible text.
/// On 2026-09-23 ling-3.0 spent 105 of its 112 allowed tokens thinking and ended the stream
/// with `finish_reason: "length"`; the turn then surfaced as "The model returned an
/// incomplete response." (G N1). `capped` asks for cheap reasoning and pays a bounded
/// allowance on top of the caller's visible budget; `off` leaves the body exactly as it was
/// before reasoning control existed.
enum OpenRouterReasoningPolicy: Sendable, Equatable {
    case off
    case capped(allowance: Int)

    /// An estimate, not a measurement: ling-3.0 spent 105 tokens thinking on a short prompt,
    /// and planner prompts are longer.
    static let defaultAllowance = 1_024

    /// The policy for a model id. A model recorded as not reasoning gets `.off`; a model
    /// recorded as reasoning — and one whose status is unknown, because OpenRouter ignores
    /// the parameter for models without reasoning — gets the capped policy.
    @MainActor
    static func policy(for modelID: String) -> OpenRouterReasoningPolicy {
        if let reasons = Settings.shared.openRouterModelReasons[modelID] {
            return reasons ? .capped(allowance: defaultAllowance) : .off
        }
        return .capped(allowance: defaultAllowance)
    }

    /// The extra completion tokens this policy pays on top of the caller's visible budget.
    var allowance: Int {
        switch self {
        case .off: 0
        case .capped(let allowance): max(0, allowance)
        }
    }

    /// The one retry a pass that hit the answer limit before writing anything visible is
    /// allowed: the allowance doubles, bounded by a quarter of the reader's window and
    /// 4,096 tokens.
    func doubled(contextTokens: Int) -> OpenRouterReasoningPolicy {
        guard case .capped(let allowance) = self else { return self }
        let grown = min(
            allowance * 2,
            max(OpenRouterReasoningPolicy.defaultAllowance, contextTokens / 4),
            4_096
        )
        return .capped(allowance: grown)
    }

    /// `visible + allowance` may never overrun the room left in the reader's window. With
    /// room to spare the total is exactly visible + allowance; a nearly full window never
    /// eats into the caller's own visible budget.
    func bounded(room: Int, visible: Int) -> OpenRouterReasoningPolicy {
        guard case .capped(let allowance) = self else { return self }
        let total = min(visible + allowance, max(visible, room))
        return .capped(allowance: max(0, total - visible))
    }
}

/// The usage object of one streamed response. Every field is optional: a provider that omits
/// a detail must not make the whole response unreadable.
struct OpenRouterUsage: Sendable, Equatable {
    var promptTokens: Int?
    var cachedTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
}

/// One decoded SSE line, in the order the line carried it. Reasoning text is counted, never
/// yielded: it is the model thinking, not the answer.
enum OpenRouterStreamEvent: Sendable, Equatable {
    case content(String)
    case reasoning(characters: Int)
    case finish(String)
    case usage(OpenRouterUsage)
}

/// What one streamed pass produced. `visibleCharacters` is what the user saw;
/// `reasoningCharacters` is only a number.
struct OpenRouterStreamSummary: Sendable, Equatable {
    var visibleCharacters = 0
    var reasoningCharacters = 0
    var finishReason: String?
    var usage: OpenRouterUsage?
}
