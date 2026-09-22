import Foundation

/// What the memory review did, every time it ran.
///
/// This exists because of a question that took a day to answer: *why is the agent memory
/// empty?* The review had in fact been running for days and had correctly decided there was
/// nothing in "can you open another note for me" worth remembering — but it recorded that
/// decision nowhere the user or anyone else could see, so an empty list looked identical to a
/// broken one. Every pass now leaves a row here: when it ran, what it read, which model, and
/// what it decided — saved, nothing worth saving, or blocked with the reason.
///
/// The Memories sheet reads the newest row as one line: *Last looked: today 17:40 — saved 2*.
struct MemoryReviewRun: Codable, Identifiable, Equatable, Sendable {
    /// One proposal the review dropped, and why, in the words the list shows.
    struct Decision: Codable, Equatable, Sendable {
        let text: String
        let reason: String
    }

    var id = UUID()
    var at: Date
    /// `MemoryReviewJob.Trigger`, as a string so an older file still decodes.
    var trigger: String
    /// "your dictation on 19 Sep", "your call with Mathieu" — what was read.
    var subject: String
    /// "Local model on this Mac", "Apple Intelligence", "OpenRouter", or why it waited.
    var model: String
    var proposed = 0
    /// The facts this pass saved.
    var saved: [String] = []
    /// Proposals the code-level skip rules dropped before the store saw them.
    var skipped: [Decision] = []
    /// Calls the guards, the store or the allowlist refused.
    var refused: [Decision] = []
    /// Set when the model call itself failed, so a run that never reached a decision is not
    /// mistaken for one that decided nothing.
    var failure: String?

    /// The one sentence the Memories sheet shows, without the date.
    var summary: String {
        if let failure { return "couldn't finish — \(failure)" }
        if !saved.isEmpty { return "saved \(saved.count)" }
        let blocked = skipped.count + refused.count
        if blocked > 0 { return "nothing saved — \(blocked) didn't pass the checks" }
        return "nothing worth saving"
    }

    /// "Last looked: today 17:40 — saved 2."
    func line(now: Date = Date(), calendar: Calendar = .current) -> String {
        let when: String = if calendar.isDateInToday(at) {
            "today " + at.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(at) {
            "yesterday " + at.formatted(date: .omitted, time: .shortened)
        } else {
            at.formatted(date: .abbreviated, time: .shortened)
        }
        return "Last looked: \(when) — \(summary)."
    }

    /// Everything one row decided, for the disclosure under the line.
    var details: [String] {
        saved.map { "Saved: \($0)" }
            + skipped.map { "Skipped “\($0.text)” — \($0.reason)" }
            + refused.map { "Blocked “\($0.text)” — \($0.reason)" }
    }

    /// The row for a pass that ran, built from its outcome.
    static func make(
        job: MemoryReviewJob, model: String, outcome: MemoryReviewOutcome, now: Date
    ) -> MemoryReviewRun {
        MemoryReviewRun(
            at: now, trigger: job.trigger.rawValue,
            subject: job.label.isEmpty ? "your \(job.trigger.subject)" : "your \(job.trigger.subject) \(job.label)",
            model: model, proposed: outcome.proposed, saved: outcome.saved.map(\.text),
            skipped: outcome.skipped.map { Decision(text: shortened($0.call), reason: $0.reason) },
            refused: outcome.refused.map { Decision(text: shortened($0.call), reason: $0.reason) })
    }

    /// The row for a pass whose model call failed, so a failure is as visible as a decision.
    static func failed(job: MemoryReviewJob, model: String, error: String, now: Date) -> MemoryReviewRun {
        var run = make(job: job, model: model, outcome: MemoryReviewOutcome(), now: now)
        run.failure = error
        return run
    }

    /// `memory.remember: The user …` → `The user …`, clipped for a settings row.
    private static func shortened(_ call: String) -> String {
        let text = call.contains(": ") ? String(call.split(separator: ": ", maxSplits: 1).last ?? "") : call
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }
}
