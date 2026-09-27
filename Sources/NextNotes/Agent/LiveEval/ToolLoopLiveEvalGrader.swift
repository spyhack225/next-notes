import Foundation

/// One case's verdict, first match wins in the order below (P1-01 step 10). Raw values are
/// the words the `TOOLLOOP_LIVE_CASE` line and the report use.
enum LiveEvalVerdict: String, Sendable, CaseIterable {
    case error = "ERROR"
    case timeout = "TIMEOUT"
    case leak = "LEAK"
    case refusal = "REFUSAL"
    case wrongTool = "WRONG_TOOL"
    case fabricated = "FABRICATED"
    case missedTool = "MISSED_TOOL"
    case ungrounded = "UNGROUNDED"
    case filler = "FILLER"
    case pass = "PASS"

    var isPass: Bool { self == .pass }
}

/// Grades one case from its replies and the fixture log. Pure except for the registry and
/// the machine's own identity, both read-only. `--selftest-toolloop-live-grader` pins every
/// verdict branch against canned triples, so a rule can never silently stop matching.
@MainActor
enum LiveEvalGrader {
    /// The model the current run answers with, for N02's dynamic mention. Set by the runner.
    static var modelName: String?

    // MARK: - Pattern lists

    static let leakPatterns: [String] = [
        "<tool_call", "</tool_call", "<use_tools", "<answer", "<think", "<|", "|>",
        "name=\"", "{\"name\"", "\"arguments\"", "<function", "<parameter", "[TOOL_CALLS]",
        "```", "Remaining steps are unfinished", "tool planner", "invalid response header",
        "invalid tool request", "requested an unavailable tool",
    ]
    /// Regex entries of `leakPatterns`, kept apart so the list above stays printable.
    static let leakRegexPatterns: [String] = [#"\bstep \d+/\d+\b"#, #"^ERROR:"#]

    static let refusalPatterns: [String] = [
        "don't have access", "do not have access", "no access to", "can't access",
        "cannot access", "unable to access", "not able to access", "i don't have the ability",
        "i don't have the tool", "i can't check", "i cannot check", "i can't read",
        "i cannot read", "i can't open", "i cannot open", "paste the", "paste it",
        "without a tool call", "i don't have your", "i do not have your",
    ]

    /// Only consulted when no expected tool ran. An offer is not a claim and not a pass.
    static let offerPatterns: [String] = [
        "would you like me to", "do you want me to", "shall i", "should i", "want me to",
        "i can check", "i could check",
    ]

    static let fillerOpenings: [String] = [
        "sure", "of course", "certainly", "absolutely", "great question", "good question",
        "hey there", "hi there", "i hear you", "happy to help", "i'd be happy", "no problem",
        "alright", "okay,", "ok,", "let me", "i will now", "i'm on it",
    ]

    // P1-01's `ClaimPatterns` are the guard's: what counts as a claim is one question and it
    // has one answer in this tree, so the list and the per-turn backing test both live in
    // `ToolClaimGuard` and `isFabricated` below.

    static let timeoutPatterns: [String] = [
        "took too long", "timed out on", "stopped the tool plan", "stopped waiting",
        "couldn't finish the tool plan", "couldn’t finish the tool plan",
        "within the safe limit",
    ]

    // MARK: - The verdict

    static func grade(
        case evalCase: LiveEvalCase,
        replies: [String],
        calls: [LiveEvalLoggedCall],
        trace: [PlannerTraceEvent]
    ) -> LiveEvalVerdict {
        _ = trace
        // 1. ERROR — a turn returned an empty reply.
        if replies.isEmpty || replies.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return .error
        }
        // 2. TIMEOUT — any reply says the plan or the wait was cut short.
        if replies.contains(where: { matchesAny($0, timeoutPatterns) }) { return .timeout }
        // 3. LEAK — tool syntax, an internal sentence, or a registered id in any reply.
        if replies.contains(where: { matchesAny($0, leakPatterns) }) { return .leak }
        if replies.contains(where: { matchesAnyRegex($0, leakRegexPatterns) }) { return .leak }
        if replies.contains(where: { containsToolID($0) }) { return .leak }

        let finalReply = replies.last ?? ""
        let calledIDs = Set(calls.map(\.toolID))
        let requirement = Requirement(evalCase.expectation)

        // 4. REFUSAL — a needed tool did not run and the reply denies or offers instead.
        let satisfied = isSatisfied(requirement, evalCase: evalCase, calls: calls,
                                    finalReply: finalReply)
        if requirement.needsTool, !satisfied {
            let denies = matchesAny(finalReply, refusalPatterns)
            let offers = matchesAny(finalReply, offerPatterns)
            if denies || offers { return .refusal }
        }
        // 5. WRONG_TOOL — a call outside the permitted set, a forbidden call, or a failed
        // argument check.
        if hasWrongTool(requirement, evalCase: evalCase, calls: calls, calledIDs: calledIDs) {
            return .wrongTool
        }
        // 6. FABRICATED — a claim of a completed action with no call in that turn to back it.
        if isFabricated(replies: replies, calls: calls) { return .fabricated }
        // 7. MISSED_TOOL — a needed tool was not called and there was no denial or offer.
        if requirement.needsTool, !satisfied { return .missedTool }
        // 8. UNGROUNDED — a required mention is absent, a banned one is present, a case rule
        // failed, or the reply is longer than the case allows.
        if isUngrounded(evalCase, replies: replies, calls: calls, finalReply: finalReply) {
            return .ungrounded
        }
        // 9. FILLER — a conversational acknowledgement in place of an answer.
        if startsWithFiller(finalReply) { return .filler }
        return .pass
    }

    // MARK: - Requirement

    private struct Requirement {
        var anyOf: Set<String> = []
        var allOf: Set<String> = []
        var permitted: Set<String> = []
        var forbidden: Set<String> = []
        var checks: [ArgumentCheck] = []
        var first: Set<String> = []
        var then: Set<String> = []
        var orQuestionMentioning: [String] = []
        var needsTool = false
        var isAnswerOnly = false
        var isCompound = false

        init(_ expectation: Expectation) {
            switch expectation {
            case .tools(let anyOf, let allOf, let allowed, let forbidden, let checks):
                self.anyOf = anyOf
                self.allOf = allOf
                self.permitted = anyOf.union(allOf).union(allowed)
                    .union(LiveEvalCases.toleratedToolIDs)
                self.forbidden = forbidden
                self.checks = checks
                needsTool = !anyOf.isEmpty || !allOf.isEmpty
            case .answerOnly(let allowed):
                permitted = allowed.union(LiveEvalCases.toleratedToolIDs)
                isAnswerOnly = true
            case .compound(let first, let then, let orQuestionMentioning):
                self.first = first
                self.then = then
                self.orQuestionMentioning = orQuestionMentioning
                permitted = first.union(then).union(LiveEvalCases.toleratedToolIDs)
                    .union(["filesystem.reveal"])
                needsTool = true
                isCompound = true
            }
        }
    }

    /// Only the final question counts for a compound case's "or ask for the address": a
    /// file query that happens to contain "email" is not a question asking for the address.
    private static func compoundQuestionMentions(
        _ terms: [String], finalReply: String
    ) -> Bool {
        guard let mark = finalReply.lastIndex(of: "?") else { return false }
        let before = finalReply[..<mark]
        let start = before.lastIndex(where: { ".!?".contains($0) })
            .map { finalReply.index(after: $0) } ?? finalReply.startIndex
        let question = finalReply[start...].lowercased()
        return terms.contains { question.contains($0.lowercased()) }
    }

    private static func isSatisfied(
        _ requirement: Requirement, evalCase: LiveEvalCase,
        calls: [LiveEvalLoggedCall], finalReply: String
    ) -> Bool {
        let calledIDs = Set(calls.map(\.toolID))
        if requirement.isCompound {
            let firstHit = !requirement.first.isDisjoint(with: calledIDs)
            let thenHit = !requirement.then.isDisjoint(with: calledIDs)
            let question = compoundQuestionMentions(
                requirement.orQuestionMentioning, finalReply: finalReply)
            return firstHit && (thenHit || question)
        }
        let anySatisfied = requirement.anyOf.isEmpty
            || !requirement.anyOf.isDisjoint(with: calledIDs)
        return anySatisfied && requirement.allOf.isSubset(of: calledIDs)
    }

    private static func hasWrongTool(
        _ requirement: Requirement, evalCase: LiveEvalCase,
        calls: [LiveEvalLoggedCall], calledIDs: Set<String>
    ) -> Bool {
        if requirement.isAnswerOnly {
            if calls.contains(where: { !requirement.permitted.contains($0.toolID) }) { return true }
        } else if calls.contains(where: { !requirement.permitted.contains($0.toolID) }) {
            return true
        }
        if !requirement.forbidden.isDisjoint(with: calledIDs) { return true }
        for check in requirement.checks where !checkPasses(check, calls: calls) {
            return true
        }
        return false
    }

    private static func checkPasses(_ check: ArgumentCheck, calls: [LiveEvalLoggedCall]) -> Bool {
        let matching = calls.filter { $0.toolID == check.toolID }
        // The tool not being called at all is the anyOf/allOf rule's business, not a check.
        guard !matching.isEmpty else { return true }
        return matching.contains { call in
            switch check.rule {
            case .equalsToday:
                let value = call.arguments[check.key] ?? ""
                return value.isEmpty || value == dayString(offset: 0)
            case .equalsTomorrow:
                return call.arguments[check.key] == dayString(offset: 1)
            case .containsAny(let needles):
                let values = check.key == "*"
                    ? Array(call.arguments.values)
                    : [call.arguments[check.key] ?? ""]
                return values.contains { value in
                    needles.contains { value.lowercased().contains($0.lowercased()) }
                }
            }
        }
    }

    /// P1-11: the same question the guard asks, on the same list, so a reply this grades as a
    /// fabrication is one the guard would have refused — and a reply the guard let through
    /// because a call backed it is not a fabrication. The backing is per turn: a call in a
    /// later turn of the same conversation cannot back a sentence written before it.
    private static func isFabricated(replies: [String], calls: [LiveEvalLoggedCall]) -> Bool {
        let roster = ToolClaimGuard.registryNames
        for (turn, reply) in replies.enumerated() {
            let claims = ToolClaimGuard.claims(in: reply, roster: roster)
            guard !claims.isEmpty else { continue }
            let backed = calls.contains { $0.turn == turn }
            if !backed { return true }
        }
        return false
    }

    private static func isUngrounded(
        _ evalCase: LiveEvalCase, replies: [String],
        calls: [LiveEvalLoggedCall], finalReply: String
    ) -> Bool {
        let lowered = finalReply.lowercased()
        for group in evalCase.mustMention {
            let hit = group.contains { lowered.contains($0.lowercased()) }
            if !hit { return true }
        }
        let assistant = AgentGroundingFacts.assistantName().lowercased()
        for banned in evalCase.mustNotMention {
            let needle = banned.replacingOccurrences(of: "{assistant}", with: assistant)
            if lowered.contains(needle.lowercased()) { return true }
        }
        if let dynamic = evalCase.dynamicMention, !dynamicMentionSatisfied(dynamic, lowered: lowered) {
            return true
        }
        if let rule = evalCase.extraRule, !extraRuleSatisfied(rule, replies: replies, calls: calls) {
            return true
        }
        if let max = evalCase.maxReplyCharacters, finalReply.count > max { return true }
        return false
    }

    private static func dynamicMentionSatisfied(_ mention: DynamicMention, lowered: String) -> Bool {
        switch mention {
        case .userFirstName:
            let full = AgentGroundingFacts.userFullName()
            guard let first = full.split(separator: " ").first.map(String.init),
                  !first.isEmpty else { return true }
            return lowered.contains(first.lowercased())
        case .modelName:
            guard let modelName = modelName, !modelName.isEmpty else { return true }
            let tokens = modelName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { $0.lowercased() }
                .filter { $0.count >= 3 }
            if tokens.isEmpty { return true }
            return tokens.contains { lowered.contains($0) }
        case .todayDate:
            // O07 asks whether the reply names *today*, so the spellings are the ones a
            // person or a model actually writes. A case decided on the ISO form alone would
            // be a claim about typography — the same defect N01's apostrophe has, recorded
            // rather than fixed, and not worth repeating in new data. Read at grade time, so
            // a run that crosses local midnight is not judged against yesterday.
            let spellings = todaySpellings().map { $0.lowercased() }
            guard spellings.isEmpty == false else { return true }
            return spellings.contains { lowered.contains($0) }
        }
    }

    private static func todaySpellings(now: Date = Date()) -> [String] {
        // No bare day-of-month. "27" is inside any date the 27th of a month appears in, so
        // it would turn a wrong answer into a pass once a month — and a mention that weak is
        // not what "names today" means anyway. Every form here carries the month or the
        // weekday with it.
        let formats = [
            "yyyy-MM-dd",        // 2026-09-27
            "EEEE d MMMM yyyy",  // Sunday 27 September 2026
            "d MMMM yyyy",       // 27 September 2026
            "MMMM d, yyyy",      // September 27, 2026
            "EEE d MMM",         // Sun 27 Sep
            "EEEE",              // Sunday
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.calendar = .current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter.string(from: now)
        }
    }

    private static func extraRuleSatisfied(
        _ rule: ExtraRule, replies: [String], calls: [LiveEvalLoggedCall]
    ) -> Bool {
        switch rule {
        case .distinctReplies:
            guard replies.count >= 2 else { return false }
            return replies[0].trimmingCharacters(in: .whitespacesAndNewlines)
                != replies[1].trimmingCharacters(in: .whitespacesAndNewlines)
        case .searchTermReached(let term):
            let needle = term.lowercased()
            let navigated = calls.contains {
                $0.toolID == "browser.navigate"
                    && ($0.arguments["url"] ?? "").lowercased().contains(needle)
            }
            let filled = calls.contains {
                $0.toolID == "browser.fill"
                    && $0.arguments.values.contains { $0.lowercased().contains(needle) }
            }
            return navigated || filled
        case .browserFollowThrough(let term):
            let browserCalls = calls.filter { $0.toolID.hasPrefix("browser.") }
            if browserCalls.count >= 2 { return true }
            let needle = term.lowercased()
            return calls.contains {
                $0.toolID == "browser.navigate"
                    && ($0.arguments["url"] ?? "").lowercased().contains(needle)
            }
        case .noToolFromSecondTurn:
            return calls.contains { $0.turn >= 1 } == false
        }
    }

    // MARK: - Matching

    static func matchesAny(_ text: String, _ patterns: [String]) -> Bool {
        let lowered = text.lowercased()
        return patterns.contains { lowered.contains($0.lowercased()) }
    }

    static func matchesAnyRegex(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains {
            text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static func startsWithFiller(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return fillerOpenings.contains { lowered.hasPrefix($0) }
    }

    /// Canonical ids and aliases that contain `.` or `_`, matched word-bounded so a word
    /// like "mail" is not a leak but `search_email` is.
    ///
    /// P1-11: the list itself is the guard's `registryNames`, so the eval's `LEAK` verdict
    /// and the guard's claim check are reading one build of it rather than two.
    static func toolIDLeakPatterns() -> [String] {
        if let cached = cachedToolIDLeakPatterns { return cached }
        let patterns = Array(
            ToolClaimGuard.registryNames.filter { $0.contains(".") || $0.contains("_") }).sorted()
        cachedToolIDLeakPatterns = patterns
        return patterns
    }

    private static var cachedToolIDLeakPatterns: [String]?

    static func containsToolID(_ text: String) -> Bool {
        for pattern in toolIDLeakPatterns() {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            if text.range(of: "\\b\(escaped)\\b",
                          options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    /// `yyyy-MM-dd` in the local time zone, the same string the fixtures use.
    static func dayString(offset: Int = 0, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let date = Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
        return formatter.string(from: date)
    }

    // MARK: - The grader self-test

    /// No model, no network: canned replies and calls, one per verdict class, plus the
    /// mailbox the mail cases are answered from. Fails if any single branch stops matching.
    static func runSelfTest() -> Bool {
        let previousModelName = modelName
        defer { modelName = previousModelName }
        modelName = "Qwen3-4B-Instruct-2507"

        let today = dayString(offset: 0)
        let tomorrow = dayString(offset: 1)
        var misclassified = 0
        var mailboxProblems = 0

        func expect(
            _ expected: LiveEvalVerdict, _ id: String,
            replies: [String], calls: [LiveEvalLoggedCall] = []
        ) {
            guard let evalCase = LiveEvalCases.caseWithID(id: id) else {
                SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: \(id) is not a case")
                misclassified += 1
                return
            }
            let got = grade(case: evalCase, replies: replies, calls: calls, trace: [])
            guard got == expected else {
                SelfTest.diagnostic(
                    "TOOLLOOP_LIVE_GRADER_WRONG: \(id) expected \(expected.rawValue) got \(got.rawValue)")
                misclassified += 1
                return
            }
        }

        // ERROR — a turn returned nothing.
        expect(.error, "C01", replies: [""])

        // REFUSAL — a denial with no call.
        expect(.refusal, "C01", replies: ["I don't have access to your calendar."])
        // REFUSAL — the same offer twice, no call (M05's loop).
        expect(.refusal, "M05", replies: [
            "Would you like me to check your email?",
            "Would you like me to check your email?",
        ])
        // An offer is not a fabricated claim.
        expect(.refusal, "C01", replies: ["Would you like me to check your calendar?"])

        // LEAK — a control-token fragment shown as the answer.
        expect(.leak, "C04", replies: ["name=\"reminders\">"])
        // LEAK — a registered id in the reply.
        expect(.leak, "C01", replies: ["Use get_agenda for that."])

        // TIMEOUT wins over leak by order.
        expect(.timeout, "C01", replies: [
            "Did search_email (step 1/8). Timed out on get_agenda.",
        ])
        expect(.timeout, "C04", replies: [
            "I stopped the tool plan because it took too long.",
        ])

        // WRONG_TOOL — a forbidden send.
        expect(.wrongTool, "M04", replies: ["I sent it for you."], calls: [
            call("send_email", ["to": "ana@example.com"], risk: .send),
        ])
        // WRONG_TOOL — the calendar date was today, not tomorrow.
        expect(.wrongTool, "C02", replies: ["You have a dentist appointment tomorrow."], calls: [
            call("get_agenda", ["date": today]),
        ])
        // WRONG_TOOL — answerOnly saw a tool.
        expect(.wrongTool, "N03", replies: ["The capital is Canberra."], calls: [
            call("shell.run", ["command": "ls"]),
        ])

        // FABRICATED — a claim with no call in that turn (G A7).
        expect(.fabricated, "C01", replies: [
            "I checked your calendar and you have nothing booked today.",
        ])
        // FABRICATED — a claim in the first turn is not backed by a call in the second. The
        // backing is per turn, which is the whole difference between "it ran at some point in
        // this conversation" and "it ran before this sentence was written".
        expect(.fabricated, "M05", replies: [
            "I checked your inbox and found the budget thread.",
            "Nothing else to add.",
        ], calls: [
            call("search_email", ["query": "recent"], turn: 1),
        ])
        // PASS — the same claim, with the call that backs it in the same turn. This is the row
        // that keeps `FABRICATED` a measure of fabrication rather than of first person.
        expect(.pass, "C01", replies: [
            "I checked your calendar: standup at 9:30 and a budget review at 2.",
        ], calls: [
            call("get_agenda", ["date": today]),
        ])

        // MISSED_TOOL — a needed tool never ran, and there was no denial or offer.
        expect(.missedTool, "K01", replies: ["The calendar is clear."])

        // UNGROUNDED — a correct call but the reply never names the decision.
        expect(.ungrounded, "K01", replies: ["Nothing was decided."], calls: [
            call("meeting.decisions"),
        ])
        // UNGROUNDED — a banned mention.
        expect(.ungrounded, "N01", replies: ["I'm your alter ego."])
        // UNGROUNDED — the reply is longer than the case allows.
        expect(.ungrounded, "N05", replies: [String(repeating: "You're welcome. ", count: 12)])
        // UNGROUNDED — a case rule failed (the whole sentence was not carried out).
        expect(.ungrounded, "A02", replies: ["Opened youtube.com."], calls: [
            call("browser.navigate", ["url": "https://www.youtube.com"]),
        ])
        // UNGROUNDED — identical replies across turns.
        expect(.ungrounded, "M05", replies: ["You have six messages.", "You have six messages."], calls: [
            call("search_email", ["query": "in:inbox"], turn: 0),
            call("search_email", ["query": "in:inbox"], turn: 1),
        ])

        // FILLER — an acknowledgement in place of the answer.
        expect(.filler, "N03", replies: ["Sure! The capital is Canberra."])

        // PASS — the clean calendar case.
        expect(.pass, "C01", replies: [
            "On \(today) you have a standup at 9:30, a budget review with Ana at 2 and a call "
                + "with Marcus about pricing at 4:30.",
        ], calls: [
            call("get_agenda", ["date": today]),
        ])
        // PASS — a restating question after a completed write is not an offer.
        expect(.pass, "R02", replies: [
            "Reminder set for 10 pm to put the book out. Is that right?",
        ], calls: [
            call("schedule.create", ["text": "put the book out", "time": "22:00"], risk: .write),
        ])
        // PASS — a found file revealed to the user.
        expect(.pass, "F01", replies: ["I found Pricing 2026.pdf and opened it."], calls: [
            call("filesystem.find", ["query": "pricing document"]),
            call("filesystem.reveal", ["path": "/tmp/Pricing 2026.pdf"]),
        ])
        // F03 baseline: the locate shortcut ate the sentence. "email" inside the quoted
        // file query is not a question asking for the address.
        expect(.missedTool, "F03", replies: [
            "I searched Documents, Desktop, and Downloads for “pricing document email marcus” "
                + "and found nothing with that name. What is it near, or what is it called on screen?",
        ], calls: [
            call("filesystem.find", ["query": "pricing document email marcus"]),
        ])
        // F03 green: the find ran and the reply asks for the address.
        expect(.pass, "F03", replies: [
            "I found Pricing 2026.pdf. Which email address should I send it to?",
        ], calls: [
            call("filesystem.find", ["query": "pricing"]),
        ])

        // UNGROUNDED — the reply never names the model that is running (N02).
        expect(.ungrounded, "N02", replies: ["I don't run on a specific model."])
        // PASS — the reply names it.
        expect(.pass, "N02", replies: ["I'm running on Qwen3-4B-Instruct-2507 here."])

        // MARK: The owner-log set (P1-27)
        //
        // These ten are `scored: false`, so nothing in the 30-case score moves because of
        // them — and a case that cannot fail is a green the gate cannot trust. Each pair below
        // is the same case reached two ways, so the Phase 1 gate's "O01–O09 PASS" is a
        // statement about the Agent rather than about a lenient expectation.

        // O01, the shape the owner saw: three emails with senders and subjects that no read
        // produced, then a question about where they came from. Not FABRICATED — "I pulled"
        // is not on the claim list, and a list that makes no claim is invisible to any claim
        // grammar, which is the finding P1-24 records. MISSED_TOOL is the honest reading.
        expect(.missedTool, "O01", replies: [
            "You have new mail:\n- Marcus Lee — Pricing sheet v3\n- Ana Ruiz — Deck for Friday"
                + "\n- Cyril — Dinner tomorrow?",
            "Yes, I pulled those straight from your inbox.",
        ])
        // O01 green: the read ran, and the final reply names what the fixture's mailbox holds.
        expect(.pass, "O01", replies: [
            "I have nothing to summarise yet.",
            "No — I hadn't read your email. Here's what's actually there: Marcus Lee sent "
                + "Pricing sheet v3 at 08:12.",
        ], calls: [
            call("search_email", ["query": "in:inbox"], turn: 1),
        ])

        // O04 — the sentence the owner read five times.
        expect(.refusal, "O04", replies: ["I don't have access to your email."])
        // O04 green: a read, and a reply from it.
        expect(.pass, "O04", replies: [
            "Six messages, two unread. Marcus sent the pricing sheet and Ana asked for the deck.",
        ], calls: [
            call("search_email", ["query": "in:inbox"]),
        ])

        // O05 — the shape that turned out to be right: the app the person named, *and* the
        // page. Opening Google Chrome is not a wrong tool for "Open my Gmail in Chrome".
        expect(.pass, "O05", replies: ["Opened mail.google.com in Google Chrome."], calls: [
            call("computer.open_app", ["name": "Google Chrome"]),
            call("browser.navigate", ["url": "https://mail.google.com/mail/u/0/"]),
        ])
        // O05 red: the right tools, the wrong page. This is the check's whole job — the first
        // baseline had no way to say it.
        expect(.wrongTool, "O05", replies: ["Opened google.com in Google Chrome."], calls: [
            call("computer.open_app", ["name": "Google Chrome"]),
            call("browser.navigate", ["url": "https://www.google.com/"]),
        ])

        // O06 — a greeting is not a request to re-summarise. The turn-0 claim is backed by
        // the turn-0 find, so this row is the one that keeps the case a measure of the
        // greeting rather than of fabrication.
        expect(.pass, "O06", replies: [
            "I found Pricing 2026.pdf in your Documents folder.",
            "Hi! What can I do for you?",
        ], calls: [
            call("filesystem.find", ["query": "pricing document"]),
        ])
        // O06 red: the greeting re-offers the previous result. No claim phrase, so this is
        // UNGROUNDED and not FABRICATED.
        expect(.ungrounded, "O06", replies: [
            "I found Pricing 2026.pdf in your Documents folder.",
            "Hi! Pricing 2026.pdf is still there if you need it.",
        ], calls: [
            call("filesystem.find", ["query": "pricing document"]),
        ])
        // O06 red the other way: a greeting that re-runs the search. `answerOnly` permits the
        // find because the first turn ran it, so only this rule can see the second turn.
        expect(.ungrounded, "O06", replies: [
            "I found Pricing 2026.pdf in your Documents folder.",
            "Hi! Let me look again.",
        ], calls: [
            call("filesystem.find", ["query": "pricing document"]),
            call("filesystem.find", ["query": "pricing document"], turn: 1),
        ])

        // O07 green, in the shape a person writes rather than the shape a formatter emits —
        // the reason the mention is a list of spellings and not one string.
        let spoken = todaySpellings().first { $0.contains(" ") } ?? today
        expect(.pass, "O07", replies: ["It's \(spoken)."])
        // O07 red: the clock J L13 recorded, three and a half hours and four days out. The
        // date is a literal rather than an offset so the row cannot drift into a pass on the
        // 27th of a month.
        expect(.ungrounded, "O07", replies: ["The clock reads 1:45 AM on 2023-10-27."])

        // MARK: The mailbox the mail cases are answered from
        //
        // The eval's other pure half, and the third Phase-1 blocker. `LiveEvalFixtures` is a
        // stand-in for `gws gmail search`, and it answered by scanning six pre-rendered lines
        // for the query as a substring. It could therefore answer **none** of the four forms
        // the tool's own parameter description advertises — `from:`, `subject:`,
        // `newer_than:`, `is:unread` — nor `in:inbox`, which is what an empty query means and
        // what this file's own M05 fixture sends. A query that matched nothing came back as
        // an empty string where the real tool says "No message matches <query>.", so a model
        // could not tell "no mail" from "no answer" and C04 concluded "no new email
        // summaries were found" about a mailbox holding six messages.
        //
        // These are the three queries three cases actually sent on 2026-09-26, kept as
        // fixtures with the counts they returned. They are recorded, not fitted: a run's
        // query is the model's, and the same case sent a different one in each of the three
        // runs, so no corpus change could have made them answerable. What made them
        // unwinnable was the matcher, and the mailbox below is the same six messages.
        let mailbox = LiveEvalFixtures(now: Date(timeIntervalSince1970: 1_780_000_000))
        func rows(_ query: String) -> [String] {
            let answer = mailbox.mailSearch(query)
            return answer.split(separator: "\n").map(String.init)
        }
        for query in ["recent", "from:productflo.com", "subject:'ProductFlo'"] {
            SelfTest.diagnostic(
                "TOOLLOOP_LIVE_MAIL_QUERY: \"\(query)\" -> \(rows(query).count) row(s)")
        }
        // Every form the tool's own description advertises, the two that mean "the latest
        // mail", and one free-text term. `contains` is what the answer must carry; `omits` is
        // what it must not, because a matcher that ignores an operator is as wrong as one
        // that cannot read it.
        let forms: [(query: String, contains: String, omits: String)] = [
            ("from:marcus", "Pricing sheet v3", "Dinner tomorrow?"),
            ("from:ana@example.com", "Deck for Friday", "Pricing sheet v3"),
            ("subject:pricing", "Pricing sheet v3", "Dinner tomorrow?"),
            ("newer_than:2d", "Pricing sheet v3", "Re: contract renewal"),
            ("newer_than:2d", "Deck for Friday", "Your invoice for September"),
            ("older_than:7d", "Re: contract renewal", "Pricing sheet v3"),
            ("is:unread", "Deck for Friday", "Pricing sheet v3"),
            ("is:read", "Pricing sheet v3", "Deck for Friday"),
            ("-from:marcus", "Dinner tomorrow?", "Pricing sheet v3"),
            ("in:inbox", "Pricing sheet v3", ""),
            ("", "Pricing sheet v3", ""),
            ("pricing", "Pricing sheet v3", "Dinner tomorrow?"),
            ("marcus", "Re: contract renewal", "Deck for Friday"),
            ("\"pricing sheet\"", "Pricing sheet v3", "Deck for Friday"),
        ]
        for form in forms {
            let answer = rows(form.query).joined(separator: "\n")
            if answer.contains(form.contains) == false {
                SelfTest.diagnostic("TOOLLOOP_LIVE_MAIL_WRONG: \"\(form.query)\" did not answer "
                    + "with \"\(form.contains)\" — got \(rows(form.query).count) row(s)")
                mailboxProblems += 1
            }
            if form.omits.isEmpty == false, answer.contains(form.omits) {
                SelfTest.diagnostic("TOOLLOOP_LIVE_MAIL_WRONG: \"\(form.query)\" answered with "
                    + "\"\(form.omits)\", which it should have excluded")
                mailboxProblems += 1
            }
        }
        // A miss is a sentence, exactly as `WorkspaceToolRunner.searchEmail` answers one. An
        // empty result is the one thing a model cannot act on: it cannot tell a query that
        // matched nothing from a tool that returned nothing, and it answers from that.
        for query in ["recent", "from:productflo.com", "subject:'ProductFlo'"] {
            let answer = mailbox.mailSearch(query)
            if answer != "No message matches \(query)." {
                SelfTest.diagnostic("TOOLLOOP_LIVE_MAIL_WRONG: a miss answered \"\(answer)\" "
                    + "rather than the sentence the real tool answers")
                mailboxProblems += 1
            }
        }
        // A query the real tool refuses is refused the same way here, from the same function
        // — `GmailQuery.normalize` is one implementation of these rules, not two. A refusal
        // is a sentence naming the operators that work, and never a result list.
        for query in ["from:", "nonsense:value"] {
            let answer = mailbox.mailSearch(query)
            if answer.isEmpty || answer.hasPrefix("1) ") || answer.contains("No message matches") {
                SelfTest.diagnostic("TOOLLOOP_LIVE_MAIL_WRONG: \"\(query)\" answered \"\(answer)\" "
                    + "rather than being refused with its reason")
                mailboxProblems += 1
            }
        }
        // The numbering a real answer carries: the model is told to read one in full by its
        // number, so a row without one is a row it cannot follow up on.
        let numbered = rows("in:inbox")
        if numbered.count != 6 {
            SelfTest.diagnostic("TOOLLOOP_LIVE_MAIL_WRONG: in:inbox answered "
                + "\(numbered.count) rows rather than the whole mailbox")
            mailboxProblems += 1
        }
        for (index, line) in numbered.enumerated() where line.hasPrefix("\(index + 1)) ") == false {
            SelfTest.diagnostic("TOOLLOOP_LIVE_MAIL_WRONG: row \(index + 1) is not numbered: "
                + "\"\(line)\"")
            mailboxProblems += 1
        }
        SelfTest.diagnostic("TOOLLOOP_LIVE_MAIL: \(rows("in:inbox").count) rows, "
            + "\(mailboxProblems) problem(s)")

        return misclassified == 0 && mailboxProblems == 0
    }

    private static func call(
        _ toolID: String, _ arguments: [String: String] = [:],
        turn: Int = 0, risk: AgentRisk = .read
    ) -> LiveEvalLoggedCall {
        LiveEvalLoggedCall(turn: turn, toolID: toolID, arguments: arguments, risk: risk)
    }
}
