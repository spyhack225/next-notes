import Foundation

/// `--selftest-agent-answers` (P0-14b): the Phase 0 exit harness.
///
/// Three typed turns — "Hi", "What can you do?" and "What's on my calendar today?" — go
/// through the same entry the Agent pane uses (`RealtimeAgent.handle(_:source:.text)`), on
/// the real Agent-role model. Phase 0 is not done until a person's own model answers a
/// plain question and a question that needs the calendar, with no error sentence in either
/// reply and the calendar turn actually routed through tools.
///
/// It reads the owner's saved model choice on purpose (`SelfTest.allowsSavedModelSelection`)
/// and writes nothing: the conversation, audit log, tasks, memory and model library are all
/// the harness's isolated copies, and the run fails if any of the real files or
/// `modelRoles.*` / `modelLibrary.*` keys changed.
@MainActor
enum AgentAnswersSelfTest {
    private enum Outcome {
        case answered(model: String)
        case failed(turn: String, reason: String)
        case absent(reason: String)
    }

    private struct TurnRecord {
        let prompt: String
        let providerID: LLMProviderID?
        let modelName: String
        let route: String?
        let reply: String
    }

    static let prompts = ["Hi", "What can you do?", "What's on my calendar today?"]
    private static let calendarPrompt = "What's on my calendar today?"
    /// A turn that does not finish is a failed turn, not a hung harness. Well past a cold
    /// multi-gigabyte load plus a planner round; the whole run's budget is the flag's 900 s.
    private static let perTurnLimit: Duration = .seconds(240)

    /// Phrases that mean the turn failed, whatever prose surrounds them. Lowercase;
    /// matching is case-insensitive.
    private static let failurePhrases = [
        "tool planner failed",
        "could not be loaded",
        "model could not answer",
        "selected model is unavailable",
        "took too long",
        "invalid response header",
        "invalid tool request",
        "inference could not start",
        "unavailable tool",
    ]

    /// Prints the one final marker and returns whether the phase is answered. `_ABSENT`
    /// returns false: a missing precondition is not a pass.
    static func runSelfTest() async -> Bool {
        switch await run() {
        case .answered(let model):
            SelfTest.diagnostic("AGENT_ANSWERS_OK: \(prompts.count)/\(prompts.count) answered by \(model)")
            return true
        case .failed(let turn, let reason):
            SelfTest.diagnostic("AGENT_ANSWERS_FAILED: \(turn): \(reason)")
            return false
        case .absent(let reason):
            SelfTest.diagnostic("AGENT_ANSWERS_ABSENT: \(reason)")
            return false
        }
    }

    private static func run() async -> Outcome {
        // A missing model is a precondition, not a failure of the plumbing.
        guard await AgentModelRouting.provider(for: "Hi", voice: false) != nil else {
            return .absent(reason: "no model on this Mac can answer")
        }

        // The store comparison runs whatever the turns did — a failed turn must not hide
        // a write to the owner's real conversation, audit log, tasks, memory or model
        // library. (P0-11's shared snapshot helper is not in this tree yet; this is the
        // same check, local to the harness.)
        let before = StoreSnapshot.capture()
        let outcome = await runTurns()
        if let change = StoreSnapshot.firstDifference(before, StoreSnapshot.capture()) {
            return .failed(turn: "stores", reason: "the run changed \(change)")
        }
        return outcome
    }

    private static func runTurns() async -> Outcome {
        let agent = RealtimeAgent.shared
        // Nothing in this run may leave an approval card on screen: an unattended card
        // would hang the harness on a wait nobody can answer.
        agent.denyUnattendedApprovalsForTesting = true
        defer { agent.denyUnattendedApprovalsForTesting = false }

        var records: [TurnRecord] = []
        for (index, prompt) in prompts.enumerated() {
            guard let provider = await AgentModelRouting.provider(for: prompt, voice: false) else {
                return .failed(turn: prompt, reason: "no model resolved for this turn")
            }
            guard let turn = await withBoundedWait(perTurnLimit, {
                await agent.handle(prompt, source: .text)
            }) else {
                return .failed(
                    turn: prompt,
                    reason: "the turn did not finish within \(perTurnLimit) — it is hung, not slow")
            }
            let reply = turn.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let route = RealtimeAgent.lastRouteForTesting
            SelfTest.diagnostic(
                "AGENT_ANSWER \(index + 1): \(provider.id.rawValue) · \(provider.displayModelName)"
                    + " · \(route ?? "unknown") · \(String(reply.prefix(120)))")

            if reply.isEmpty {
                return .failed(turn: prompt, reason: "the reply was empty")
            }
            let lowered = reply.lowercased()
            if let phrase = failurePhrases.first(where: { lowered.contains($0) }) {
                return .failed(turn: prompt, reason: "the reply said “\(phrase)”")
            }
            if prompt == calendarPrompt, route != "model-tools" {
                return .failed(
                    turn: prompt,
                    reason: "the calendar turn was routed as \(route ?? "nothing"), not through tools")
            }
            records.append(TurnRecord(
                prompt: prompt, providerID: provider.id,
                modelName: provider.displayModelName, route: route, reply: reply))
        }

        var names: [String] = []
        for record in records where !names.contains(record.modelName) {
            names.append(record.modelName)
        }
        return .answered(model: names.joined(separator: ", "))
    }

    // MARK: - Store isolation

    /// The real files and UserDefaults keys a self-test must never write. Captured before
    /// and after the run; any difference fails the harness.
    private struct StoreSnapshot {
        var files: [String: String] = [:]
        var defaults: [String: String] = [:]

        static func capture() -> StoreSnapshot {
            var snapshot = StoreSnapshot()
            let support = AppIdentity.applicationSupportDirectory
            let names = [
                "runs.jsonl", "agent-tasks.json", "agent-audit.jsonl",
                "agent-conversation.json", "next-memory.json",
            ]
            for name in names {
                snapshot.files[name] = describe(support.appendingPathComponent(name))
            }
            snapshot.files["library.json"] =
                describe(ModelSpec.directory.appendingPathComponent("library.json"))
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("modelRoles.") || key.hasPrefix("modelLibrary.") {
                snapshot.defaults[key] =
                    String(describing: UserDefaults.standard.object(forKey: key))
            }
            return snapshot
        }

        /// A human-readable description of the first thing that differs, or nil.
        static func firstDifference(_ before: StoreSnapshot, _ after: StoreSnapshot) -> String? {
            for (name, value) in before.files where after.files[name] != value {
                return "\(name) (\(value) → \(after.files[name] ?? "absent"))"
            }
            for (name, value) in after.files where before.files[name] == nil {
                return "\(name) (appeared: \(value))"
            }
            for (key, value) in before.defaults where after.defaults[key] != value {
                return "\(key) (\(value) → \(after.defaults[key] ?? "absent"))"
            }
            for (key, value) in after.defaults where before.defaults[key] == nil {
                return "\(key) (appeared: \(value))"
            }
            return nil
        }

        private static func describe(_ url: URL) -> String {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return "absent"
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size) bytes, mtime \(modified)"
        }
    }
}
