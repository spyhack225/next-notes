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
    /// One group of proposals the review dropped, and why, in the words the list shows.
    ///
    /// P1-30: this used to be a list of decisions, each keeping the **text of the proposed
    /// fact** — and a refused fact is often one the review took from somebody else in the
    /// room, which is the case the whole task is about. It also grew without bound, because
    /// 40 refusals that all say the same thing is one line of information.
    ///
    /// So a decision is now a reason and a count, collapsed by reason. The *what* is not lost
    /// to the person: the memory store holds every fact that was saved, and the refusal
    /// reasons are the part that is only visible here.
    struct Decision: Codable, Equatable, Sendable {
        let reason: String
        let count: Int

        init(reason: String, count: Int) {
            self.reason = reason
            self.count = count
        }

        /// A file written before P1-30 has `text` on every decision and no `count`. It reads
        /// as one decision for its reason, which is what it was: the count is the collapse,
        /// and there was nothing to collapse.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reason = try container.decode(String.self, forKey: .reason)
            count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
        }

        var line: String {
            count > 1 ? "\(reason) (\(count)×)" : reason
        }
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
    /// The **ids** of the facts this pass saved, not their text (P1-30).
    ///
    /// The text was the fact itself, written twice — once in the memory store where it
    /// belongs, and once here where it need not be. The Memories sheet reads the count off
    /// this and the fact out of the store, and nothing else needed the words.
    var saved: [UUID] = []
    /// Proposals the code-level skip rules dropped before the store saw them.
    var skipped: [Decision] = []
    /// Calls the guards, the store or the allowlist refused.
    var refused: [Decision] = []
    /// Set when the model call itself failed, so a run that never reached a decision is not
    /// mistaken for one that decided nothing.
    var failure: String?
    /// Whether the model was actually asked. False when the job held nothing the guards would
    /// trust, so a run that proposed nothing for lack of material is distinguishable from one
    /// where a model read the source and decided there was nothing worth saving. Optional so
    /// a file written before it existed still decodes.
    var modelCalled: Bool?

    /// The one sentence the Memories sheet shows, without the date.
    var summary: String {
        if let failure { return "couldn't finish — \(failure)" }
        if !saved.isEmpty { return "saved \(saved.count)" }
        if modelCalled == false { return "nothing of yours to read" }
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
    ///
    /// P1-30: counts and reasons. This used to read "Saved: <the fact>" and "Skipped “<the
    /// proposed fact>”", which is a genuinely useful disclosure and the cost of this task:
    /// the person can no longer read here exactly what the review declined to remember. What
    /// they keep is why, how many, and the facts themselves in the Memories list — which is
    /// where a fact that *was* saved has always lived.
    var details: [String] {
        (saved.isEmpty ? [] : ["Saved \(saved.count) fact(s)."])
            + skipped.map { "Skipped — \($0.line)" }
            + refused.map { "Blocked — \($0.line)" }
    }

    /// The row for a pass that ran, built from its outcome.
    static func make(
        job: MemoryReviewJob, model: String, outcome: MemoryReviewOutcome, now: Date
    ) -> MemoryReviewRun {
        MemoryReviewRun(
            at: now, trigger: job.trigger.rawValue,
            subject: job.label.isEmpty ? "your \(job.trigger.subject)" : "your \(job.trigger.subject) \(job.label)",
            model: model, proposed: outcome.proposed, saved: outcome.saved.map(\.id),
            skipped: Self.decisions(from: outcome.skipped),
            refused: Self.decisions(from: outcome.refused),
            modelCalled: outcome.modelCalled)
    }

    /// The row for a pass whose model call failed, so a failure is as visible as a decision.
    static func failed(job: MemoryReviewJob, model: String, error: String, now: Date) -> MemoryReviewRun {
        var run = make(job: job, model: model, outcome: MemoryReviewOutcome(), now: now)
        run.failure = error
        // The failure is the model call's — the material did reach a model, so this is not
        // an empty job; `modelCalled` stays about whether there was anything to read.
        run.modelCalled = true
        return run
    }

    /// One `Decision` per distinct reason, carrying how many proposals shared it.
    ///
    /// The count is sorted highest-first so the disclosure leads with what happened most, and
    /// the order of the model's own calls is not preserved — it was an accident of ordering,
    /// and nothing read it as a sequence.
    private static func decisions(
        from dropped: [MemoryReviewOutcome.Refusal]
    ) -> [Decision] {
        var counts: [String: Int] = [:]
        for item in dropped { counts[item.reason, default: 0] += 1 }
        // Split from the sort so the type checker does not have to reason about a chained
        // `sorted` + `map` over a dictionary here; it times out on this expression otherwise.
        let ordered = counts.sorted { lhs, rhs -> Bool in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        return ordered.map { Decision(reason: $0.key, count: $0.value) }
    }
}
