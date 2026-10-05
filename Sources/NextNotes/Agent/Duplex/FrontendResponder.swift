import Foundation

/// Compatibility name for the SAME inference actor and singleton. No wrapper,
/// additional actor hop, model context, reservation or drain owner is introduced.
typealias LocalVoiceFrontend = FrontendResponder

extension FrontendDecision {
    /// Resolve only against records captured in the actual outgoing request.
    /// This projects intent; current worker, primary, session and approval checks
    /// still belong to TaskBridge at dispatch. No approval token is manufactured.
    static func decision(from payload: FrontendDecisionPayload, userWords: String,
                         indexed: [TaskRecord]) -> FrontendDecision? {
        func task(_ number: Int?) -> TaskID? {
            guard let number, number > 0, indexed.indices.contains(number - 1) else { return nil }
            return indexed[number - 1].id
        }
        switch payload.intent {
        case "answer": return .answer
        case "capabilities": return .capabilities
        case "not_addressed": return .notAddressed
        case "spawn": return .spawn(objective: payload.objective ?? "", userWords: userWords, backend: nil)
        case "revise":
            guard let id = task(payload.taskNumber) else { return nil }
            return .revise(id, text: payload.objective ?? userWords)
        case "cancel":
            guard let number = payload.taskNumber else { return .cancel(nil) }
            guard let id = task(number) else { return nil }
            return .cancel(id)
        case "status":
            guard let number = payload.taskNumber else { return .status(nil) }
            guard let id = task(number) else { return nil }
            return .status(id)
        case "approval":
            guard let answer = payload.approval, let decision = SpokenPermissionDecision(rawValue: answer),
                  payload.amendment.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != false else { return nil }
            return .respondPermission(requestID: nil, decision: decision, amendment: payload.amendment)
        default: return nil
        }
    }
}
