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

    static let claimPatterns: [String] = [
        "i ran", "i've run", "i have run", "i searched", "i've searched", "i checked",
        "i've checked", "i looked at your", "i looked through your", "i listed", "i opened",
        "i read your",
    ]
    static let claimRegexPatterns: [String] = [
        #"\b\d[\d,]* (files|emails|messages|events|results) (searched|checked|found|listed)\b"#,
    ]

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

    private static func isFabricated(replies: [String], calls: [LiveEvalLoggedCall]) -> Bool {
        for (turn, reply) in replies.enumerated() {
            let claims = matchesAny(reply, claimPatterns)
                || matchesAnyRegex(reply, claimRegexPatterns)
            guard claims else { continue }
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
    static func toolIDLeakPatterns() -> [String] {
        if let cached = cachedToolIDLeakPatterns { return cached }
        var ids = AgentToolRegistry.shared.tools(upTo: .privileged).map(\.id)
        ids.append(contentsOf: FileToolCatalogue.aliasIDs)
        ids.append(contentsOf: WorkspaceTools.all.map { "workspace.\($0.name)" })
        let patterns = Array(Set(ids.filter { $0.contains(".") || $0.contains("_") })).sorted()
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

    /// No model, no network: canned replies and calls, one per verdict class. Fails if any
    /// single branch stops matching.
    static func runSelfTest() -> Bool {
        let previousModelName = modelName
        defer { modelName = previousModelName }
        modelName = "Qwen3-4B-Instruct-2507"

        let today = dayString(offset: 0)
        let tomorrow = dayString(offset: 1)
        var misclassified = 0

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

        return misclassified == 0
    }

    private static func call(
        _ toolID: String, _ arguments: [String: String] = [:],
        turn: Int = 0, risk: AgentRisk = .read
    ) -> LiveEvalLoggedCall {
        LiveEvalLoggedCall(turn: turn, toolID: toolID, arguments: arguments, risk: risk)
    }
}
