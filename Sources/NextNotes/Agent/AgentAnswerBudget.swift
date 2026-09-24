import Foundation

/// How many visible tokens one model pass may write. Derived from the reader's real window
/// and the user's depth setting; never a fixed constant (P0-05).
enum AgentAnswerBudget {
    enum Kind: Sendable, Equatable {
        /// The typed first pass, and the `.localModel` answers.
        case typedAnswer
        /// A planner round. P1-02 step 6 supplies the wanted value.
        case plannerRound(background: Bool)
        /// P1-06's answer-only round.
        case finalAnswer
        /// The voice branch of `runModelTurn`; reached only by self-tests today.
        case voiceFirstPass

        /// What the budget log line calls this pass.
        var label: String {
            switch self {
            case .typedAnswer: "typedAnswer"
            case .plannerRound(let background):
                background ? "plannerRound(background)" : "plannerRound"
            case .finalAnswer: "finalAnswer"
            case .voiceFirstPass: "voiceFirstPass"
            }
        }
    }

    /// Room kept clear for the model's own overhead. Equal to
    /// `NotesModelRuntime.contextHeadroom`, which is private.
    static let safetyTokens = 256
    static let floorTokens = 64

    static func wanted(_ kind: Kind, depth: AgentResponsiveness) -> Int {
        switch kind {
        case .typedAnswer, .finalAnswer: depth.localAnswerTokenBudget
        case .voiceFirstPass: 112
        case .plannerRound(let background):
            background ? 768 : max(1_024, depth.localAnswerTokenBudget)
        }
    }

    /// How many visible tokens the pass may write. The depth setting is a wish; the
    /// window is the fact, and the room left after the counted prompt wins. The floor
    /// keeps a nearly full window from being asked for zero.
    static func tokens(kind: Kind, contextTokens: Int, promptTokens: Int,
                       depth: AgentResponsiveness) -> Int {
        let room = contextTokens - promptTokens - safetyTokens
        return max(floorTokens, min(wanted(kind, depth: depth), room))
    }

    /// The reader's real window. `LlamaLLMProvider.contextTokens` is the 32,768 ceiling,
    /// not the loaded model's trained window — `NotesModelRuntime.contextTokens` is the
    /// real one once the weights are resident, and it is clamped there already.
    static func readerContextTokens(for provider: any LLMProvider) async -> Int {
        if provider.id == .appLLM, await NotesModelRuntime.shared.isLoaded {
            return await NotesModelRuntime.shared.contextTokens
        }
        return provider.contextTokens
    }
}
