import Foundation

/// What Codex said when it ran out of allowance, and when it will have some again.
///
/// ## Why this exists
///
/// Codex's allowance is not ours to manage: it runs out on OpenAI's schedule, the CLI says
/// so in one line and exits, and `CodexComputerUse` has nothing else to go on. Turn M1 of
/// 2026-09-23 was the shape — "open chrome" was handed over, the hand-off came back
/// `ERROR: You've hit your usage limit … or try again at Sep 26th, 2026 3:43 PM.`, and the
/// next nine seconds were spent being told about it. Every following request repeated the
/// whole sequence, because nothing remembered.
///
/// So one date is remembered, parsed out of the sentence Codex actually wrote, and until it
/// passes the hand-off is not started at all: no process, no approval card, and one plain
/// sentence the first time, so the person knows why this one was done here rather than
/// watching it happen again.
///
/// ## What is stored
///
/// The reset date and nothing else. Not the output, not the URL, not the transcript — the
/// date is the whole fact, and a preference that holds someone else's error text is a
/// liability rather than a feature.
@MainActor
final class CodexQuotaStore {
    /// The store the turn and the Settings row both read. The harness gets its own suite
    /// under a self-test, so a run cannot open or close the owner's window.
    static let shared = CodexQuotaStore(defaults: sharedSuite)

    /// The defaults `.shared` reads and writes — see `ModelRoleStore.sharedDefaults` for
    /// the same rule and the same reason.
    nonisolated static var sharedSuite: UserDefaults {
        SelfTest.isRunning ? SelfTestHarnessDefaults.suite : .standard
    }

    nonisolated private static let windowKey = "codex.quotaExhaustedUntil"
    nonisolated private static let announcedKey = "codex.quotaAnnouncedFor"

    /// How long to stay out of the way when Codex named no reset time. An estimate, and the
    /// one thing here that is not measured: the Settings row says the allowance is used up
    /// and offers a button, so a wrong guess costs one press rather than a wrong answer.
    nonisolated static let assumedWindow: TimeInterval = 6 * 60 * 60

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// The window Codex's own answer named, or nil when nothing is remembered or the moment
    /// has passed. A `Date` in the past is the same as no window at all — the allowance is
    /// back, and the next request goes to Codex without asking anybody anything.
    var exhaustedUntil: Date? { Self.exhaustedUntil(defaults: defaults, now: now()) }

    /// Whether this hand-off's output was Codex saying it has no allowance left, and if so
    /// remembers until when. False for every other failure, which changes nothing — a
    /// timeout, a crash and a refusal are not a quota.
    func recordFailure(output: String) -> Bool {
        let moment = now()
        guard let parsed = Self.parseUsageLimit(output, now: moment, calendar: .current)
        else { return false }
        let until = parsed ?? moment.addingTimeInterval(Self.assumedWindow)
        defaults.set(until, forKey: Self.windowKey)
        // A new window has not been announced, whoever announced the one before it. Equal
        // dates mean the same window, so the stored announcement survives.
        if defaults.object(forKey: Self.announcedKey) as? Date != until {
            defaults.removeObject(forKey: Self.announcedKey)
        }
        return true
    }

    /// Forgets the window, so the next request is handed to Codex whatever the app thinks.
    /// What the Settings button calls.
    func clear() {
        defaults.removeObject(forKey: Self.windowKey)
        defaults.removeObject(forKey: Self.announcedKey)
    }

    /// The one sentence for this window, then nil until the window changes. Once per quota
    /// window and remembered across launches, so "I told you" stays true between runs.
    func announcementIfNew() -> String? {
        guard let until = exhaustedUntil else { return nil }
        if defaults.object(forKey: Self.announcedKey) as? Date == until { return nil }
        defaults.set(until, forKey: Self.announcedKey)
        return Self.turnSentence(until: until)
    }

    // MARK: - Reading and parsing

    /// The same answer as `exhaustedUntil`, without the main actor and without the store —
    /// for `CodexComputerUse.probe`, which runs off it.
    nonisolated static func exhaustedUntil(defaults: UserDefaults, now: Date) -> Date? {
        guard let until = defaults.object(forKey: windowKey) as? Date, until > now else {
            return nil
        }
        return until
    }

    /// Whether an output was a usage-limit failure, and until when.
    ///
    /// `nil` (no answer at all) is not a quota failure. `.some(nil)` is one with no readable
    /// date, which is a different thing from `.some(.some(date))`: the first gets the
    /// assumed window, the second is what Codex actually said.
    nonisolated static func parseUsageLimit(
        _ output: String, now: Date, calendar: Calendar
    ) -> Date?? {
        let isQuota = output.range(of: "usage limit", options: .caseInsensitive) != nil
            || output.range(of: "hit your limit", options: .caseInsensitive) != nil
        guard isQuota else { return nil }
        for phrase in resetPhrases {
            guard let range = output.range(of: phrase, options: .caseInsensitive) else { continue }
            // Searched case-insensitively in the original string rather than in a lowercased
            // copy, so the slice below is the author's own characters.
            let tail = String(output[range.upperBound...])
            if let until = parseResetDate(tail, now: now, calendar: calendar) {
                return .some(until)
            }
        }
        return .some(nil)
    }

    /// The words after which Codex has put a time in its answer. Read from the sentence
    /// captured on 2026-09-23, not invented: `…or try again at Sep 26th, 2026 3:43 PM.`
    nonisolated static let resetPhrases = ["try again at", "try again after", "resets at"]

    /// Shapes read out of that one sentence, plus the two obvious variations of it. The
    /// ordinal is stripped before this, because `26th` is prose and no date format has a
    /// pattern for it.
    nonisolated private static let dateFormats = [
        "MMM d yyyy h:mm a", "MMM d yyyy H:mm", "MMM d yyyy h:mm", "MMM d yyyy",
        "d MMM yyyy h:mm a", "d MMM yyyy H:mm", "d MMM yyyy",
    ]

    nonisolated private static let timeFormats = ["h:mm a", "H:mm"]

    /// The first two or three words after a reset phrase, read as a moment.
    ///
    /// Longest first, so `Sep 26 2026 3:43 PM` is never mistaken for a bare `3:43 PM` on
    /// today. A time with no date is taken as the next one to happen, which is the only
    /// honest reading of "resets at 3:43 PM" and is why a bare time can never be in the
    /// past. Anything else is nil, and the caller falls back to the assumed window.
    nonisolated private static func parseResetDate(
        _ tail: String, now: Date, calendar: Calendar
    ) -> Date? {
        let words = tail.split(whereSeparator: \.isWhitespace).map(normaliseWord)
        guard !words.isEmpty else { return nil }
        let longest = min(words.count, 5)
        for count in stride(from: longest, through: 1, by: -1) {
            let candidate = words.prefix(count).joined(separator: " ")
            if let date = date(from: candidate, now: now, calendar: calendar) { return date }
        }
        return nil
    }

    /// One word out of Codex's sentence: the punctuation around it dropped, and an English
    /// ordinal suffix off the end of a day. `26th,` becomes `26`.
    nonisolated private static func normaliseWord(_ word: Substring) -> String {
        var text = String(word)
        while let first = text.first, ".,;:’'".contains(first) {
            text.removeFirst()
        }
        while let last = text.last, ".,;:’'".contains(last) {
            text.removeLast()
        }
        for suffix in ["st", "nd", "rd", "th"] where text.lowercased().hasSuffix(suffix) {
            if text.dropLast(suffix.count).allSatisfy(\.isNumber), text.count > suffix.count {
                text = String(text.dropLast(suffix.count))
            }
            break
        }
        return text
    }

    /// A candidate string as a date, by trying the date shapes then the time-only ones. A
    /// time is anchored to the next occurrence rather than to midnight, so "3:43 PM" means
    /// this afternoon and never yesterday.
    nonisolated private static func date(
        from text: String, now: Date, calendar: Calendar
    ) -> Date? {
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        for format in timeFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            guard let time = formatter.date(from: text),
                  let sameDay = calendar.date(
                    bySettingHour: calendar.component(.hour, from: time),
                    minute: calendar.component(.minute, from: time),
                    second: 0, of: now)
            else { continue }
            return sameDay > now
                ? sameDay : calendar.date(byAdding: .day, value: 1, to: sameDay)
        }
        return nil
    }

    /// The window as a person would say it out loud: "Tuesday at 3:43 PM". No date maths and
    /// no `DateFormatter` in a view.
    nonisolated static func resetPhrase(_ until: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE 'at' h:mm a"
        return formatter.string(from: until)
    }

    /// The sentence the Settings row shows. The date is in it because the person's next move
    /// is to know when to come back — and because a misread date is the one way this can
    /// keep Codex out for longer than it should.
    nonisolated static func settingsSentence(until: Date?) -> String {
        guard let until else {
            return "Codex has used up its allowance. Next Notes does these itself until it resets."
        }
        return "Codex has used up its allowance until \(resetPhrase(until)). "
            + "Next Notes does these itself until then."
    }

    /// The one sentence a turn carries when it has done the job here instead. It says what
    /// happened and until when, and nothing else: no error code, no link, nothing a person
    /// would have to read twice.
    nonisolated static func turnSentence(until: Date) -> String {
        "Codex can’t take this until \(resetPhrase(until)), so I did it here."
    }

    /// What any other hand-off failure reads. The raw output goes to the audit log and
    /// nowhere else — it is Codex talking to its operator, not to the person who asked.
    nonisolated static let otherFailureSentence = "Codex couldn’t do that, so I did it here."

    /// The raw output, to the one place that is not a conversation. The last 300 characters
    /// only: the beginning of a Codex transcript is a banner and a workdir, and the end is
    /// the sentence that failed. Under a self-test `AgentAuditLog` keeps entries in memory
    /// and writes no file, so this is safe to call from a test.
    @MainActor
    static func auditHandOffFailure(output: String) {
        AgentAuditLog.shared.record(
            kind: .reply,
            title: "Codex hand-off failed",
            detail: String(output.suffix(300))
        )
    }
}
