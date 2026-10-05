import Foundation

/// A read-only value view of one canonical AgentTask. No row, worker or delivery owner.
struct TaskRecord: Identifiable, Sendable, Equatable {
    let id: TaskID
    let title: String
    let objective: String
    let userWords: String?
    let origin: TaskOrigin?
    let backend: String
    let status: AgentTaskStatus
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let progress: String
    let result: String?
    let failure: String?
    let delivery: TaskDelivery?
    let deliveryAttempts: Int
    // Populated only by the owning Coordinator from its SAME matching Job handle.
    // This is a transient control observation, never another durable task state.
    var controlObservation: TaskControlObservation = .unobserved

    @MainActor init(_ task: AgentTask) {
        id = TaskID(task.id)
        title = TaskStatusRenderer.title(task.objective)
        objective = task.objective
        userWords = task.userWords
        origin = task.origin
        backend = task.backend
        status = task.status
        createdAt = task.createdAt
        startedAt = task.startedAt
        finishedAt = task.finishedAt
        progress = task.progress
        result = task.result
        failure = task.failure
        delivery = task.delivery
        deliveryAttempts = task.deliveryAttempts
    }
}

enum TaskControlObservation: Sendable, Equatable {
    case unobserved, cancelled, returned
}

enum WorkStatusBudget {
    static let newestResultCharacters = 1_200
    static let otherCharacters = 250
    static let maximumTasks = 5
}

@MainActor
enum TaskStatusRenderer {
    static func title(_ objective: String) -> String {
        let safe = AgentReplyRenderer.scrub(objective, outcome: nil)
        let first = safe.split(whereSeparator: { ".!?;\n".contains($0) }).first.map(String.init) ?? safe
        return cut(first.trimmingCharacters(in: .whitespacesAndNewlines), limit: 60, sentence: false)
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    /// The caller supplies the exact indexed session snapshot used to resolve Task N.
    /// Results are retained evidence; these lines do not infer health or no-effects.
    static func workLines(_ records: [TaskRecord], now: Date = Date()) -> String {
        let selected = Array(records.prefix(WorkStatusBudget.maximumTasks))
        let terminals: Set<AgentTaskStatus> = [.completed, .failed, .cancelled]
        let newestResult = selected.filter {
            terminals.contains($0.status) && !($0.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.max { ($0.finishedAt ?? $0.createdAt) < ($1.finishedAt ?? $1.createdAt) }?.id
        return selected.enumerated().map { index, task in
            let controlLabel: String? = if task.controlObservation == .cancelled {
                // A cancellation request does not prove an entered operation returned,
                // even when the canonical cancellation state was admitted.
                task.status == .cancelled ? "Stopping" : "Stopping; saved status uncertain"
            } else if !terminals.contains(task.status), task.controlObservation == .returned {
                "Finished; saved status uncertain"
            } else { nil }
            var line = "Task \(index + 1) [\(controlLabel ?? task.status.humanState)]: \(task.title)"
            if controlLabel == nil, let started = task.startedAt {
                if terminals.contains(task.status) {
                    // Terminal duration is retained metadata, never an age that grows
                    // as a completed row is rendered again. Unknown finish stays unknown.
                    if let finished = task.finishedAt, finished >= started {
                        let seconds = finished.timeIntervalSince(started)
                        line += seconds < 10 ? " · took less than 10 seconds" : (seconds < 60
                            ? " · took about \(Int((seconds / 5).rounded()) * 5) seconds"
                            : " · took about \(Int((seconds / 60).rounded())) minutes")
                    }
                } else if now >= started {
                    let seconds = now.timeIntervalSince(started)
                    line += seconds < 10 ? " · just started" : (seconds < 60
                        ? " · about \(Int((seconds / 5).rounded()) * 5) seconds in"
                        : " · about \(Int((seconds / 60).rounded())) minutes in")
                }
            }
            if controlLabel == nil, AgentActivityProjector.isPublic(task.progress), !task.progress.isEmpty && task.progress != "Working locally" && task.progress != "Finished" {
                line += " · " + AgentReplyRenderer.scrub(task.progress, outcome: nil)
            }
            if let failure = task.failure, task.status == .failed {
                line += " · " + AgentReplyRenderer.scrub(failure, outcome: nil)
            }
            if task.id == newestResult, let result = task.result {
                return cut(line, limit: WorkStatusBudget.otherCharacters, sentence: false)
                    + "\nResult: " + cut(AgentReplyRenderer.scrub(result, outcome: nil),
                        limit: WorkStatusBudget.newestResultCharacters, sentence: true)
            }
            if let result = task.result, terminals.contains(task.status) {
                let safe = AgentReplyRenderer.scrub(result, outcome: nil)
                line += " · " + cut(safe, limit: 160, sentence: true)
            }
            return cut(line, limit: WorkStatusBudget.otherCharacters, sentence: false)
        }.joined(separator: "\n")
    }

    /// Cached canonical observations in plain words, not health or effect certainty.
    static func spoken(_ records: [TaskRecord], now: Date = Date()) -> String {
        guard !records.isEmpty else { return "Nothing is running right now." }
        func sentence(_ task: TaskRecord) -> String {
            let title = task.title.isEmpty ? "That task" : task.title
            if task.controlObservation == .cancelled { return "Stopping \(title) now." }
            if task.controlObservation == .returned && ![.completed, .failed, .cancelled].contains(task.status) {
                return "\(title)'s saved status is unavailable."
            }
            switch task.status {
            case .running:
                let elapsed: String
                if let started = task.startedAt, now >= started {
                    let seconds = now.timeIntervalSince(started)
                    elapsed = seconds < 10 ? "just started" : (seconds < 60
                        ? "about \(Int((seconds / 5).rounded()) * 5) seconds in"
                        : "about \(Int((seconds / 60).rounded())) minutes in")
                } else { elapsed = "start time unavailable" }
                var step = task.progress.trimmingCharacters(in: .whitespacesAndNewlines)
                if step.hasPrefix("Step "), let separator = step.firstIndex(of: ":") { step = String(step[step.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines) }
                while step.hasSuffix("…") { step.removeLast() }
                if step.hasSuffix("...") { step.removeLast(3) }
                step = step.trimmingCharacters(in: .whitespacesAndNewlines)
                let publicStep = AgentActivityProjector.isPublic(step) && !["", "Working locally", "Working", "Finished"].contains(step)
                    ? cut(AgentReplyRenderer.scrub(step, outcome: nil), limit: 160, sentence: false) : ""
                return "Still on \(title)" + (publicStep.isEmpty ? ", " : " — \(publicStep), ") + elapsed + "."
            case .waitingForPermission: return "\(title) is waiting for your OK."
            case .waitingForInput:
                return "\(title) needs an answer: " + gist(task.result ?? "What would you like me to do?")
            case .completed: return "\(title) is done: " + gist(task.result ?? "Finished.")
            case .failed: return "\(title) didn't work: " + gist(task.failure ?? "The saved result is unavailable.")
            case .cancelled:
                return task.controlObservation == .returned ? "\(title)'s task has stopped." : "\(title) has a saved stop request."
            case .queued: return "\(title) is ready to start."
            case .recovering: return "\(title) is paused after restart."
            case .waitingForCompatibilityCLI: return "\(title) needs your confirmation."
            }
        }
        var reply = records.prefix(2).map(sentence).joined(separator: " Also, ")
        if records.count > 2 {
            if reply.hasSuffix(".") { reply.removeLast() }
            reply += ", and \(records.count - 2) more."
        }
        return RealtimeAgent.voiceSafeReply(reply)
    }

    private static func gist(_ text: String) -> String {
        let safe = AgentReplyRenderer.scrub(text, outcome: nil)
        let clause = AgentSpeechPolicy.spokenClauses(safe).first ?? safe
        return cut(clause, limit: 160, sentence: true)
    }

    private static func cut(_ text: String, limit: Int, sentence: Bool) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(max(0, limit - 1)))
        if sentence, let end = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...end])
        }
        let boundary = prefix.lastIndex(where: { $0.isWhitespace })
        return (boundary.map { String(prefix[..<$0]) } ?? prefix)
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
