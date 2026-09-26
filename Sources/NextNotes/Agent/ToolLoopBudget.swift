import Foundation

/// How much model and read compute one tool plan may spend, and how much of it a single
/// round may spend (P1-06).
///
/// The loop used to hold one number for the whole plan — 18 s for a typed turn — and charge
/// every model round and every read call against it. One local round is seconds of prefill
/// plus its own decode, so "search, then read, then summarise" ran out of clock *after* the
/// reads and before the answer, and the person reading the pane was told "I stopped the tool
/// plan because it took too long" about a plan that was halfway to done. The live eval
/// graded that `TIMEOUT`, and `--selftest-agent-answers` failed the calendar turn on it.
///
/// Three numbers, answering three different questions:
///
/// - `perRound` — one round's deadline. A round is what a person is waiting for, so this is
///   the number that has to fit a prefill and a decode.
/// - `ceiling` — the plan's whole model and read allowance. Time spent waiting for the
///   user's voice floor or for an approval card is never charged here (AGENTS.md: model and
///   read budgets exclude both), so this bounds compute rather than attention.
/// - `coldLoadAllowance` — added to the *first* round only, when the app's own model is not
///   resident yet. A cold 4B load is 11–25 s of weights before the first token, and charging
///   that to the round's own deadline means a correct plan is cut off before it decides
///   anything.
///
/// A write is not bounded by any of them: a write may be sitting on a person's approval, and
/// a deadline there could say "stopped" while the write later commits.
struct ToolLoopBudget: Sendable, Equatable {
    var perRound: Duration
    var perReadCall: Duration
    var ceiling: Duration
    var coldLoadAllowance: Duration

    /// A typed turn on the app's own model, a local server, or Apple's. This is the table the
    /// decision document chose (§3.2 T5: "~30 s per round, ~120 s ceiling").
    static let typedLocal = ToolLoopBudget(
        perRound: .seconds(30), perReadCall: .seconds(20),
        ceiling: .seconds(120), coldLoadAllowance: .seconds(45))
    /// A typed turn on OpenRouter: a network round trip is most of the wait and a reasoning
    /// model may think for a long time, so both deadlines are wider and there is no cold
    /// load to allow for.
    static let typedCloud = ToolLoopBudget(
        perRound: .seconds(45), perReadCall: .seconds(30),
        ceiling: .seconds(150), coldLoadAllowance: .zero)
    /// The voice worker runs a whole objective in the background, so its rounds may be long;
    /// its ceiling is the typed one, because the person is not watching that pane.
    static let voiceWorker = ToolLoopBudget(
        perRound: .seconds(45), perReadCall: .seconds(20),
        ceiling: .seconds(120), coldLoadAllowance: .seconds(45))
    /// The interactive voice path, reachable only by self-tests today.
    static let voiceInteractive = ToolLoopBudget(
        perRound: .seconds(15), perReadCall: .seconds(10),
        ceiling: .seconds(30), coldLoadAllowance: .zero)

    static func forTurn(provider: LLMProviderID, voice: Bool, background: Bool) -> ToolLoopBudget {
        if background { return .voiceWorker }
        if voice { return .voiceInteractive }
        return provider == .openRouter ? .typedCloud : .typedLocal
    }

    // MARK: - The two deadlines the loop asks for

    /// One round's deadline, never more than the ceiling has left.
    ///
    /// The cold allowance rides on round zero only: it pays for weights, and there are
    /// weights once.
    func roundLimit(round: Int, cold: Bool, ceilingRemaining: Duration) -> Duration {
        let allowance: Duration = (round == 0 && cold) ? coldLoadAllowance : .zero
        return min(perRound + allowance, ceilingRemaining)
    }

    /// One read call's deadline, never more than the ceiling has left. The same rule the
    /// round has, at the read's own width.
    func readCallLimit(ceilingRemaining: Duration) -> Duration {
        min(perReadCall, ceilingRemaining)
    }

    // MARK: - Corrections

    /// How long the ceiling must be spent before a correction may refill it (H1 #17).
    ///
    /// A spoken objective is revised by the person mid-flight, and the revision starts the
    /// round clock over. Charging a corrected objective against the budget the *previous*
    /// wording spent is how three follow-ups on 2026-09-14 each ended "The model took too
    /// long to answer." seconds after they arrived.
    static let refillInterval: Duration = .seconds(10)

    /// The refill itself, as a pure rule so a self-test can pin it without a model.
    ///
    /// Returns whether it refilled. At most once per `refillInterval`, so a stream of
    /// corrections cannot buy an unbounded plan.
    @discardableResult
    static func refill(
        ceilingRemaining: inout Duration, budget: ToolLoopBudget,
        lastRefill: ContinuousClock.Instant?, now: ContinuousClock.Instant
    ) -> Bool {
        if let lastRefill, lastRefill.duration(to: now) < refillInterval { return false }
        ceilingRemaining = max(ceilingRemaining, budget.ceiling / 2)
        return true
    }

    // MARK: - The backstop

    /// How many planner rounds one plan may have (H1 #18).
    ///
    /// `AgentToolLoop.clampedMaxRounds` is 4 at fast and balanced, and one rebuttal or one
    /// repair then ends "search, read, summarise" — three tool rounds plus the answer round
    /// it never got to — with nothing to show. Time is bounded by `ceiling`; this is only a
    /// backstop, so two rounds over the call cap is room for the answer and one repair.
    /// `AgentToolLoop`'s own clamp is untouched: the scheduled-routine loop uses it.
    static func plannerMaxRounds(maxCalls: Int) -> Int { maxCalls + 2 }
}
