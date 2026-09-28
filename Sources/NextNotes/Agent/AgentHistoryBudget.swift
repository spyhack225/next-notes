import Foundation

/// How much earlier conversation a reader is given, in characters.
///
/// Every one of these numbers used to be a literal at its call site: 2,500 on the first pass,
/// 6,000 in the planner, 3,000 on the local-model path, 1,800 per message, and a 10,000 ceiling
/// on the session context that clipped silently — so a caller asking for more got 10,000 and no
/// word about it. A reader can have a 262,144-token window (OpenRouter on this Mac) and was
/// being handed less than one email listing, which is how "summarise those" lost the list after
/// one more exchange.
///
/// **Scales with the reader's real window**, read through
/// `AgentAnswerBudget.readerContextTokens(for:)` — never `provider.contextTokens`, which for a
/// llama reader is the 32,768 ceiling rather than the loaded model's window. The voice frontend
/// keeps its own 1,400: it is latency-bound, not window-bound, and P4-08 owns it.
enum AgentHistoryBudget {
    /// The largest budget, and the session context's ceiling. One number, so "the caller asked
    /// for the most" and "the session can hold the most" cannot disagree.
    static let maximumCharacters = 24_000

    static func characters(contextTokens: Int) -> Int {
        switch contextTokens {
        case ..<8_000: 2_500
        case ..<32_000: 6_000
        case ..<128_000: 12_000
        default: maximumCharacters
        }
    }

    /// A single message's share of the budget: two fifths, capped at 6,000.
    ///
    /// The cap matters as much as the share. Without it a 24,000 budget would let one long
    /// tool result take 9,600 characters and answer a question that needed the last four
    /// exchanges, and the older ones are exactly the ones a short question like "summarise
    /// those" is about.
    static func perMessageCap(budget: Int) -> Int { min(6_000, budget * 2 / 5) }

    /// What a clipped message ends with. P4-08's marker, kept byte-identical: a model that
    /// can see that a message was cut asks for the rest, and one that cannot will not answer
    /// from a half sentence without saying it is working from part of it.
    static let clippedSuffix = "… (the rest is in the conversation)"
}
