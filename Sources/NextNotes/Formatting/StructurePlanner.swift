import Foundation
import FoundationModels

/// The plan, in the shape Apple's guided generation can be asked for directly.
///
/// A separate type from `StructurePlan` on purpose. `@Generable` describes what the sampler
/// is allowed to emit; `StructurePlan` describes what this app is willing to render, and the
/// step between them is where a plan is checked. Collapsing the two would mean the validator
/// and the schema could only ever agree.
@Generable(description: "A layout plan for a passage of dictated speech. Blocks must cover every sentence exactly once, in order.")
struct StructurePlanDraft {

    @Generable(description: "What to do with one run of consecutive sentences.")
    enum Kind {
        case prose
        case numbered
        case bulleted
        case quote
        case code
    }

    @Generable(description: "One run of consecutive sentences.")
    struct Block {
        @Guide(description: "prose for ordinary paragraphs; numbered when the speaker counted things out loud; bulleted for an uncounted list; quote for a spoken quotation; code for a dictated command.")
        var kind: Kind

        @Guide(description: "The first sentence number in this block, 1-based.")
        var from: Int

        @Guide(description: "The last sentence number in this block, 1-based and not before 'from'.")
        var to: Int

        @Guide(description: "For numbered or bulleted only: the sentence number each item begins on, in order, starting with 'from'. At least two. Leave empty for every other kind.")
        var itemStarts: [Int]

        @Guide(description: "For numbered or bulleted only: for each item, how many words at the start of its first sentence are only the spoken announcement and not content. 0 when the item starts straight into content, never more than 8. Leave empty for every other kind.")
        var stripWords: [Int]
    }

    @Guide(description: "The blocks, in sentence order, covering every sentence exactly once.")
    var blocks: [Block]
}

extension StructurePlanDraft {
    var plan: StructurePlan {
        StructurePlan(blocks: blocks.map { block in
            StructurePlan.Block(
                kind: block.kind.kind,
                from: block.from,
                to: block.to,
                itemStarts: block.itemStarts,
                stripWords: block.stripWords
            )
        })
    }
}

extension StructurePlanDraft.Kind {
    var kind: StructurePlan.Kind {
        switch self {
        case .prose: .prose
        case .numbered: .numbered
        case .bulleted: .bulleted
        case .quote: .quote
        case .code: .code
        }
    }
}

// MARK: - Apple's on-device model

/// The plan pass on Apple Intelligence, with guided generation doing the shape checking.
///
/// ## The budget, and why a flat three seconds was the wrong number
///
/// It used to be `.seconds(3)` for every passage, and on 2026-09-20T20:47:25Z a forty-one
/// second dictation hit it exactly: `structurePlanSeconds: 3.01`, `structurePlanRejected:
/// "the layout pass ran out of time"`. A flat ceiling is a ceiling on the *shortest* thing
/// the pass is ever asked to do, because generation time grows with the number of sentences
/// — there is one block boundary to consider per sentence — while the deadline did not.
///
/// So the budget scales with what is being asked, and the cap is a property of the user's
/// patience rather than of the model: six seconds on a passage long enough to need them,
/// which is a wait that only ever happens on a dictation that has already been talking for
/// most of a minute.
///
/// Three things pay for that budget rather than merely spending it:
/// - the session is staged at key-down beside the cleanup session (`CleanupSessionWarmer`),
///   so the pass does not open with the model waking up;
/// - `CleanupRouter` starts it *beside* the grammar chunks rather than after them, so its
///   seconds overlap a wait the user was already having;
/// - the prompt elides the middle of long sentences (`StructurePlanPrompt.abbreviated`),
///   because a boundary is never in the middle of a sentence.
struct AppleStructurePlanner: StructurePlanning {
    var planName: String { "apple" }
    /// Overridden by `budget(forSentences:)` unless a caller pins it.
    var budget: Duration?
    /// False shows the model every sentence whole. The probe uses it to check that the
    /// elision costs no accuracy; production never turns it off.
    var elides = true

    /// Three tenths of a second per sentence, floored at three and a half and capped at six.
    ///
    /// The floor is calibrated on the failure rather than on a round number: the twelve
    /// sentences of 2026-09-20T20:47:25Z spent 3.01 s and had not finished, so any floor at
    /// or under three seconds is the same bug with a different constant. The cap is a
    /// property of the user's patience and not of the model, and it is affordable only
    /// because this pass now runs *beside* the cleanup pass — six seconds of layout inside
    /// seven seconds of grammar costs nothing.
    static func budget(forSentences count: Int) -> Duration {
        .seconds(min(6.0, max(3.5, 0.3 * Double(count))))
    }

    func plan(for sentences: [String]) async -> StructurePlanOutcome {
        let began = Date()
        guard FoundationModelFormatter.isAvailable else {
            return .failed(
                FoundationModelFormatter.unavailableReason
                    ?? "Apple\u{2019}s on-device model is unavailable",
                seconds: 0
            )
        }
        // Named apart from the property on purpose: `let budget = budget ?? …` reads as a
        // variable initialised from itself.
        let deadline = budget ?? Self.budget(forSentences: sentences.count)
        do {
            let draft = try await withThrowingTaskGroup(of: StructurePlanDraft.self) { group in
                group.addTask {
                    // The session staged while the key was still down, if there is one for
                    // exactly this prompt. Same trade as the cleanup pass, and the same
                    // measurement behind it: the first call in a process pays the model
                    // waking up, and that is most of the three seconds this pass used to
                    // spend before it timed out.
                    let session = await CleanupSessionWarmer.shared
                        .take(instructions: StructurePlanPrompt.system)
                        ?? LanguageModelSession(instructions: StructurePlanPrompt.system)
                    let response = try await session.respond(
                        to: StructurePlanPrompt.user(sentences: sentences, eliding: elides),
                        generating: StructurePlanDraft.self,
                        options: GenerationOptions(
                            // A layout is not a creative task; the same passage should be
                            // laid out the same way twice.
                            temperature: 0.1,
                            maximumResponseTokens: 500
                        )
                    )
                    return response.content
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    throw PlanError.timedOut
                }
                guard let first = try await group.next() else { throw PlanError.timedOut }
                group.cancelAll()
                return first
            }
            let plan = draft.plan
            let seconds = Date().timeIntervalSince(began)
            if let problem = plan.rejection(sentenceCount: sentences.count) {
                return .failed(problem, seconds: seconds)
            }
            return StructurePlanOutcome(plan: plan, rejection: nil, seconds: seconds)
        } catch {
            return .failed(
                Self.describe(error, budget: deadline),
                seconds: Date().timeIntervalSince(began)
            )
        }
    }

    private static func describe(_ error: Error, budget: Duration) -> String {
        if error is PlanError {
            return String(
                format: "the layout pass ran out of time after %.1fs",
                Double(budget.components.seconds)
                    + Double(budget.components.attoseconds) / 1e18
            )
        }
        guard let error = error as? LanguageModelSession.GenerationError else {
            return error.localizedDescription
        }
        switch error {
        case .exceededContextWindowSize: return "the passage was too long to lay out in one piece"
        case .assetsUnavailable: return "model assets unavailable"
        case .guardrailViolation: return "blocked by safety guardrails"
        case .unsupportedGuide: return "unsupported generation guide"
        case .unsupportedLanguageOrLocale: return "unsupported language"
        case .decodingFailure: return "the layout plan did not parse"
        case .rateLimited: return "rate limited"
        case .concurrentRequests: return "concurrent request on one session"
        case .refusal: return "the model declined to lay the passage out"
        @unknown default: return error.localizedDescription
        }
    }

    private enum PlanError: Error { case timedOut }
}

// MARK: - Any other local model

/// The same pass through `LLMProvider`, so the local model can do it where Apple
/// Intelligence is off.
///
/// Constrained decoding is the whole reason this is viable on a 4B model: `GBNFGrammar`
/// makes the answer parse or fail to generate, rather than parse-if-we-are-lucky. A provider
/// that cannot enforce a grammar still works — the plan is validated either way — it is just
/// likelier to waste the call.
///
/// Not wired into production. Loading the notes model costs gigabytes of residency and
/// seconds of load, which is the wrong trade inside a dictation the user is waiting on; this
/// exists so that trade is a decision someone makes rather than a door that was never built.
struct LLMStructurePlanner: StructurePlanning {
    let provider: any LLMProvider
    var budget: Duration = .seconds(6)

    var planName: String { provider.id.rawValue }

    func plan(for sentences: [String]) async -> StructurePlanOutcome {
        let began = Date()
        if let reason = await provider.unavailableReason {
            return .failed(reason, seconds: Date().timeIntervalSince(began))
        }
        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await provider.complete(
                        system: StructurePlanPrompt.system,
                        user: StructurePlanPrompt.user(sentences: sentences),
                        maxTokens: 500,
                        grammar: StructurePlanPrompt.grammar()
                    ).text
                }
                group.addTask {
                    try await Task.sleep(for: budget)
                    throw PlanError.timedOut
                }
                guard let first = try await group.next() else { throw PlanError.timedOut }
                group.cancelAll()
                return first
            }
            let seconds = Date().timeIntervalSince(began)
            guard let json = Self.firstJSONObject(in: text) else {
                return .failed("the layout plan was not JSON", seconds: seconds)
            }
            guard let plan = try? JSONDecoder().decode(StructurePlan.self, from: Data(json.utf8))
            else {
                return .failed("the layout plan did not parse", seconds: seconds)
            }
            if let problem = plan.rejection(sentenceCount: sentences.count) {
                return .failed(problem, seconds: seconds)
            }
            return StructurePlanOutcome(plan: plan, rejection: nil, seconds: seconds)
        } catch {
            let seconds = Date().timeIntervalSince(began)
            if error is PlanError { return .failed("the layout pass ran out of time", seconds: seconds) }
            return .failed(error.localizedDescription, seconds: seconds)
        }
    }

    /// The first balanced `{…}` in the answer. A provider that cannot be given a grammar
    /// tends to wrap the object in a fence or a sentence of explanation.
    static func firstJSONObject(in text: String) -> String? {
        let characters = Array(text)
        guard let open = characters.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in open..<characters.count {
            let character = characters[index]
            if escaped { escaped = false; continue }
            if character == "\\" , inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(characters[open...index]) }
            }
        }
        return nil
    }

    private enum PlanError: Error { case timedOut }
}

// MARK: - For the self-tests

/// A planner that answers from a script. The self-tests use it to check the plan path end to
/// end — validation, rendering, the router's fallback — with no model on the machine.
struct ScriptedStructurePlanner: StructurePlanning {
    let planName: String
    /// Async so a scripted planner can also stand in for a *slow* one, which is what a
    /// test of the overlap between this pass and the cleanup pass needs. A synchronous
    /// closure still satisfies it.
    let answer: @Sendable ([String]) async -> StructurePlanOutcome

    init(
        planName: String = "scripted",
        answer: @escaping @Sendable ([String]) async -> StructurePlanOutcome
    ) {
        self.planName = planName
        self.answer = answer
    }

    init(planName: String = "scripted", plan: StructurePlan) {
        self.init(planName: planName) { _ in
            StructurePlanOutcome(plan: plan, rejection: nil, seconds: 0)
        }
    }

    func plan(for sentences: [String]) async -> StructurePlanOutcome {
        await answer(sentences)
    }
}
