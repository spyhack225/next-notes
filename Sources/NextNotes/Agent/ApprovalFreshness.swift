import Foundation

/// Whether a stored proposal still describes the world it was prepared for.
///
/// A proposal outlives the process on purpose — AGENTS.md, "A proposal outlives the process":
/// the notes land minutes after a meeting ends and are read the next morning. What was never
/// added is a check that the world still matches the card when it is finally approved, so a
/// banner left over from last week, pressed today, ran as-is.
///
/// OpenMuse (`apps/server/src/actions.ts`) binds each stored review to a SHA-256 over the action
/// and the target's version, a **30-minute expiry**, and the connected account, and voids pending
/// work when the account changes. **The binding and the account are taken; the 30 minutes are
/// not.** A short expiry would delete exactly the morning-after approvals this feature exists
/// for — and the same file's own note is that the expiry is a safety bound, not a correctness
/// rule. So: nothing expires, nothing is deleted, and freshness is decided at the moment of
/// approval.
///
/// Pure, and the only place the order is written down. The order is the design: an account that
/// changed means the card is about a different world entirely, and a time that has passed means
/// running it would be worse than useless — so both are refused before age is even looked at.
enum ApprovalFreshness {
    /// The oldest a proposal can be and still fire from a **banner** press, in days. A start
    /// value, not a derived one: the thing being balanced is "a person pressing a notification
    /// from Tuesday's meeting today" against "a person approving on the card they can see".
    ///
    /// A banner carries no title, no arguments and no meeting, so from the banner's own evidence
    /// nobody can tell a four-day-old send from this morning's. Past this age the press opens the
    /// card instead — which is **not** a second confirmation, because the card is where a send
    /// has always been approved from, and a press on the card itself fires as it does now.
    static let bannerAgeLimit = 3

    enum Freshness: Equatable, Sendable {
        /// Today's path, unchanged.
        case fresh
        /// Older than `bannerAgeLimit`, so a banner press shows the card rather than firing.
        case aged(days: Int)
        /// Prepared for a different Google account. Nothing runs.
        case accountChanged
        /// The moment the card names has passed. Nothing runs.
        case timeHasPassed

        /// Whether a **banner** press may fire this directly, or must open the card first.
        var mayFireFromBanner: Bool {
            if case .fresh = self { return true }
            return false
        }

        /// Whether anything may run at all.
        var mayRun: Bool {
            if case .fresh = self { return true }
            if case .aged = self { return true }
            return false
        }

        /// The one plain sentence, for the card. Empty for `.fresh`, which has nothing to say.
        ///
        /// No tool id, no schema key, and not the phrase "account tag" — the word for this in
        /// the app is the account, because that is what a person switched.
        var refusal: String {
            switch self {
            case .fresh: return ""
            case .aged(let days):
                return days <= 1
                    ? "This was prepared yesterday. Open it to check it still looks right."
                    : "This was prepared \(days) days ago. Open it to check it still looks right."
            case .accountChanged:
                return "This was prepared for a different Google account, so nothing was sent."
            case .timeHasPassed:
                return "That time has already passed."
            }
        }
    }

    /// - Parameters:
    ///   - proposal: the stored proposal, with whatever it managed to decode.
    ///   - now: injected, so a case can be five days old without waiting five days.
    ///   - currentAccountTag: the signed-in account's tag, or nil when it could not be read.
    ///     **Nil skips the account check** and says so in the caller's comment: a tag is never
    ///     invented, because an invented tag would refuse every approval on a machine whose
    ///     profile read failed, which is the worst possible failure for a safety check.
    static func evaluate(_ proposal: AgentProposal, now: Date = Date(),
                         currentAccountTag: String?) -> Freshness {
        if let prepared = proposal.accountTag, let current = currentAccountTag,
           prepared != current {
            return .accountChanged
        }
        if let startsAt = proposal.startsAt, startsAt <= now {
            return .timeHasPassed
        }
        let days = calendarDays(from: proposal.createdAt, to: now)
        return days > bannerAgeLimit ? .aged(days: days) : .fresh
    }

    /// Whole days between two dates, in the calendar's own arithmetic rather than 86,400 s
    /// multiples: "prepared on Tuesday, approved on Friday" is three days whatever the clocks say.
    private static func calendarDays(from: Date, to: Date) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}
