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
        // P1-31b: the renderer's current typed and spoken timeout sentences.
        "i ran out of time before finishing the rest",
        "that took longer than i allow, so i stopped",
    ]
    static let modelFailurePatterns = ["the model didn't finish that answer"]

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
        if replies.contains(where: { matchesAny($0, modelFailurePatterns) }) { return .error }
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
                                    finalReply: finalReply, finalTurn: max(0, replies.count - 1))
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
        calls: [LiveEvalLoggedCall], finalReply: String, finalTurn: Int
    ) -> Bool {
        let calledIDs = Set(calls.map(\.toolID))
        if requirement.isCompound {
            let firstHit = !requirement.first.isDisjoint(with: calledIDs)
            let thenHit = !requirement.then.isDisjoint(with: calledIDs)
            let question = compoundQuestionMentions(
                requirement.orQuestionMentioning, finalReply: finalReply)
            let documentChoice = evalCase.id == "F03"
                && f03DocumentChoice(calls: calls, finalReply: finalReply, turn: finalTurn)
            return firstHit && (thenHit || question || documentChoice)
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
        } else if calls.contains(where: {
            !requirement.permitted.contains($0.toolID)
                && !(evalCase.id == "F03" && $0.toolID == "search_email" && $0.risk == .read)
        }) {
            return true
        }
        if !requirement.forbidden.isDisjoint(with: calledIDs) { return true }
        for check in requirement.checks where !checkPasses(check, calls: calls) {
            return true
        }
        return false
    }

    /// F03's fixture is ambiguous between two pricing documents. A grounded file
    /// choice is a legitimate missing-input question before the requested email.
    private static func f03DocumentChoice(calls: [LiveEvalLoggedCall], finalReply: String, turn: Int) -> Bool {
        guard matchesAnyRegex(finalReply, [
            #"(?:^|[.!]\s+)which (?:one|(?:pricing )?(?:document|file)) should i (?:send|email)\b[^?]*\?\s*$"#,
        ]) else { return false }
        let fixture = LiveEvalFixtures()
        return calls.contains { call in
            guard call.turn == turn, call.risk == .read,
                  ["filesystem.search", "find_drive_files"].contains(call.toolID),
                  (call.arguments["query"] ?? "").lowercased().contains("pric") else { return false }
            let result = fixture.summary(for: call.toolID, arguments: call.arguments)
            return result.contains("Pricing 2026.pdf") && result.contains("Pricing sheet v3")
        }
    }

    /// Only authored recipient input or an earlier same-turn successful fixture mail
    /// read can support F03's selected address. A generated body/reply or a lucky guess
    /// of an unread fixture address is not evidence. No product-mail policy is changed.
    private static func f03RecipientsGrounded(_ evalCase: LiveEvalCase,
                                              calls: [LiveEvalLoggedCall]) -> Bool {
        let address = #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let recipient = try? NSRegularExpression(
            pattern: "^(?:Marcus(?: Lee)?\\s*<)?(" + address + ")>?$",
            options: .caseInsensitive),
              let authored = try? NSRegularExpression(
                pattern: "(?:\\b(?:email|send)(?:\\s+it)?\\s+to\\s+|\\bmarcus(?:\\s+lee)?(?:['’]s)?(?:\\s+email(?:\\s+address)?)?\\s*(?:at|is|:)?\\s*)<?(" + address + ")>?",
                options: .caseInsensitive) else { return false }
        func captures(_ expression: NSRegularExpression, _ text: String) -> Set<String> {
            Set(expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
                .compactMap { match in Range(match.range(at: 1), in: text)
                    .map { String(text[$0]).lowercased() } })
        }
        let fixture = LiveEvalFixtures()
        for (index, call) in calls.enumerated() where ["draft_email", "send_email"].contains(call.toolID) {
            var supported: Set<String> = []
            for input in evalCase.turns.prefix(max(0, call.turn + 1)) {
                let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                supported.formUnion(captures(authored, text))
                // The user's direct answer to the missing-address question.
                supported.formUnion(captures(recipient, text))
            }
            for read in calls.prefix(index) where read.turn == call.turn
                && read.toolID == "search_email" && read.risk == .read {
                let result = fixture.mailSearch(read.arguments["query"] ?? "",
                    maxResults: Int(read.arguments["maxResults"] ?? ""))
                for message in fixture.mailbox.messages where message.fromName == "Marcus Lee"
                    && result.contains(" · " + message.from + " · ") {
                    supported.insert(message.fromAddress.lowercased())
                }
            }
            let written = (call.arguments["to"] ?? "").components(
                separatedBy: CharacterSet(charactersIn: ",;\n"))
            guard !written.isEmpty, written.allSatisfy({ value in
                let selected = captures(recipient, value.trimmingCharacters(in: .whitespacesAndNewlines))
                return selected.count == 1 && selected.isSubset(of: supported)
            }) else { return false }
        }
        return true
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
            let completed = calls.filter { $0.turn == turn }.map(\.toolID)
            if !ToolClaimGuard.unsupported(claims, completed: completed).isEmpty {
                return true
            }
        }
        return false
    }

    private static func isUngrounded(
        _ evalCase: LiveEvalCase, replies: [String],
        calls: [LiveEvalLoggedCall], finalReply: String
    ) -> Bool {
        let lowered = finalReply.lowercased()
        if evalCase.id == "F03", !f03RecipientsGrounded(evalCase, calls: calls) { return true }
        // F03 found the pricing document in the fixture, but the final answer can
        // misidentify Marcus (the recipient) as the file it failed to find. Asking
        // for an email address afterwards does not cure that contradiction.
        // This is an instrument check only; product replies are never rewritten.
        if evalCase.id == "F03",
           calls.contains(where: {
               ["filesystem.find", "filesystem.search", "find_drive_files"].contains($0.toolID)
                   && ($0.arguments["query"] ?? "").lowercased().contains("pric")
           }),
           matchesAnyRegex(finalReply, [
               #"^\s*i (?:can['’]t|cannot|couldn['’]t|could not|didn['’]t|did not) find (?:a )?(?:file|document) (?:called|named) ["“‘']?marcus\b"#,
           ]) {
            return true
        }
        // R02 asks for a reminder every night at 22:00. Reuse the actual native
        // create parser: days=7 without repeat is once, not daily. No store,
        // execution, role lookup or owner identity is involved in this parse.
        if evalCase.id == "R02", !calls.contains(where: { call in
            guard call.toolID == "schedule.create",
                  let schedule = try? ScheduleToolExecutor.parseCreate(call.arguments,
                      now: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!,
                      availableTools: []),
                  schedule.kind == .reminder, let when = schedule.when else { return false }
            return when.repeatRule == .daily && when.time == ScheduleLocalTime(hour: 22, minute: 0)
        }) {
            return true
        }
        // This bounded complete statement captures its explicit named subject.
        // Sarah and implicit pronouns remain valid; different names, including
        // names absent from the fixture, contradict its canonical Sarah fact.
        if evalCase.id == "K03",
           let expression = try? NSRegularExpression(
               pattern: #"(?:^|[.!?]\s+)\s*([\p{L}][\p{L}'’-]*(?:\s+[\p{L}][\p{L}'’-]*)*)\s+said\s+(?:that\s+)?the\s+budget\s+needs\s+(?:a\s+)?(?:10%|ten\s+percent)\s+buffer(?:\s+for\s+ads)?[.!]?\s*$"#,
               options: .caseInsensitive),
           let match = expression.firstMatch(in: finalReply,
               range: NSRange(finalReply.startIndex..<finalReply.endIndex, in: finalReply)),
           let speakerRange = Range(match.range(at: 1), in: finalReply),
           !["sarah", "she", "he", "they", "i", "we", "you", "it", "someone", "the speaker"]
               .contains(String(finalReply[speakerRange]).lowercased()) {
            return true
        }
        // O01 asks about the source of a summary already received. With an
        // actual earlier mail read and affirmative provenance, required mail
        // mentions belong to that earlier summary, not a repeated summary.
        let mentionReply: String
        if evalCase.id == "O01", replies.count == 2,
           calls.contains(where: { $0.turn == 0 && ["search_email", "read_email"].contains($0.toolID) }),
           matchesAnyRegex(finalReply, [
               #"^\s*yes\b[,.—–]?\s*(?:(?:this|that|the) summary|it)\s+(?:comes|came|is|was)\s+(?:directly\s+)?from your (?:recent )?(?:emails?|inbox)\b"#,
               #"^\s*(?:(?:that['’]s|that is) just how the summary came together\s*[—–]\s*)?(?:it['’]s|it is) pulling from your email history(?:[.!](?:\s|$)|$)"#,
           ]),
           !matchesAnyRegex(finalReply, [
               #"\b(?:guess(?:ed)?|invent(?:ed)?|made\b[^.!?\n]*\bup)\b"#,
               #"\b(?:not|never)\s+(?:pulling\s+)?(?:directly\s+)?from your (?:recent )?(?:emails?|inbox)\b"#,
               #"\b(?:didn['’]t|did not|haven['’]t|have not|never)\s+(?:read|check|look at)\s+your (?:emails?|inbox)\b"#,
               #"\bfrom (?:your |the |my )?(?:calendar|memory|imagination|guess)\b"#,
           ]) {
            mentionReply = replies[0].lowercased()
        } else {
            mentionReply = lowered
        }
        for group in evalCase.mustMention {
            let hit = group.contains { mentionReply.contains($0.lowercased()) }
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
            // The old any-token check accepted "model" for Apple Foundation Model and
            // "free" for an OpenRouter id. Use the family and version together so a
            // Qwen3 answer cannot pass a Qwen3.5 run either.
            let name = String(modelName.split(separator: "/").last ?? Substring(modelName))
            let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { $0.lowercased() }
            guard !parts.isEmpty else { return false }
            let distinctive = parts.prefix(2).joined()
            let answer = lowered.filter { $0.isLetter || $0.isNumber }
            return answer.contains(distinctive)
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

    private static func todaySpellings(now: Date = SelfTest.fixtureClock ?? Date()) -> [String] {
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
            let needle = term.lowercased()
            let clicked = calls.contains {
                $0.toolID == "browser.click"
                    && ($0.arguments["expectedText"] ?? "").lowercased().contains(needle)
            }
            let navigated = calls.contains {
                $0.toolID == "browser.navigate"
                    && ($0.arguments["url"] ?? "").lowercased().contains(needle)
            }
            return clicked || navigated
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
    static func dayString(offset: Int = 0, now: Date = SelfTest.fixtureClock ?? Date()) -> String {
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
    static func runSelfTest() async -> Bool {
        let previousModelName = modelName
        defer { modelName = previousModelName }
        modelName = "Qwen3-4B-Instruct-2507"

        let today = dayString(offset: 0)
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
        // A provider failure cannot pass a conversational answer-only case.
        expect(.error, "N05", replies: ["The model didn't finish that answer. Try again."])
        expect(.error, "O10", replies: ["The model didn't finish that answer. Try again."])

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

        // P1-31b: use the actual renderer in both modes. Verified work does not
        // turn an unfinished timeout into PASS, and the stop idiom is not a claim.
        for voice in [false, true] {
            let stopped = AgentReplyRenderer.render(.timedOut(lastVerified: nil), voice: voice)
            expect(.timeout, "C01", replies: [stopped])
            expect(.timeout, "C01", replies: [AgentReplyRenderer.render(
                .timedOut(lastVerified: "Standup at 9:30."), voice: voice)],
                calls: [call("get_agenda", ["date": today])])
            if !ToolClaimGuard.claims(in: stopped, roster: []).isEmpty {
                SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: timeout sentence claims an action")
                misclassified += 1
            }
        }

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

        // P2: subject inversion is a question, not a completed action. Use an
        // answer-only case so REFUSAL's earlier offer rule cannot mask FABRICATED.
        for auxiliary in ["Should", "Shall", "Can", "Could", "Would", "Will", "May",
                          "Might", "Must", "Do", "Did", "Have", "Had"] {
            let question = "\(auxiliary) I set it for 10 PM?"
            expect(.ungrounded, "N03", replies: [question])
            if !ToolClaimGuard.claims(in: question, roster: []).isEmpty {
                SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: question claims an action: \(question)")
                misclassified += 1
            }
        }
        for question in ["Can I read your calendar?", "Did I read your calendar?"] {
            expect(.ungrounded, "N03", replies: [question])
        }
        // Exclude each inverted occurrence only. Neither a later affirmative nor
        // an affirmative with a question mark loses the original claim protection.
        for reply in ["I set it for 10 PM.", "I set it for 10 PM?",
                      "Should I set it for 10 PM? I set it for 10 PM.",
                      "Should I set it for 10 PM? I set it for 10 PM?",
                      "Did I read your calendar? I read your calendar."] {
            expect(.fabricated, "N03", replies: [reply])
        }
        let reminderOffer = "I can set a reminder for you. Should I set it every night at 10 PM to remind you to put the book out?"
        expect(.refusal, "R02", replies: [reminderOffer])
        if let reminder = LiveEvalCases.caseWithID(id: "R02"),
           let pending = PendingAction.detect(
               reply: reminderOffer, request: reminder.turns[0],
               allowedIDs: ["schedule.create"], origin: .typedOffer, sessionID: nil) {
            let confirmed = pending.confirmedPrompt(acknowledgment: "okay")
            let reminderQuestion = "Should I set it every night at 10 PM to remind you to put the book out?"
            if pending.question != reminderQuestion || !confirmed.contains(reminder.turns[0])
                || !confirmed.contains("You then asked: " + reminderQuestion)
                || confirmed.contains("You then asked: " + reminderOffer)
                || !confirmed.contains("The user answered: okay") {
                SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: reminder confirmation lost the offer or request")
                misclassified += 1
            }
        } else {
            SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: reminder offer did not retain a pending action")
            misclassified += 1
        }

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
        // A read cannot back a claim that something was sent, even in the same turn.
        expect(.fabricated, "F01", replies: [
            "I sent the pricing document to Marcus.",
        ], calls: [
            call("filesystem.find", ["query": "pricing"]),
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

        // M03_LATEST_MAIL_CONTRACT_COMMON_BEGIN
        // The retained native maxResults=1 call reads Cyril's newest message.
        // Execute the same fixture boundary and grade the actual recorded call,
        // rather than changing mailbox dates to satisfy an older subject mention.
        do {
            let latestMail = LiveEvalFixtures(now: Date(timeIntervalSince1970: 1_780_000_000))
            let savedFake = AgentToolExecutor.fakeForTesting
            AgentToolExecutor.fakeForTesting = latestMail.run
            defer { AgentToolExecutor.fakeForTesting = savedFake }
            let arguments = ["query": "", "maxResults": "1"]
            do {
                let result = try await AgentToolExecutor.run("search_email", arguments: arguments,
                    policy: .denyMutations, autoApproveReads: true, promptIfNeeded: false)
                if latestMail.calls.count != 1 || latestMail.calls.first?.toolID != "search_email"
                    || latestMail.calls.first?.arguments != arguments
                    || latestMail.log.firstResult(for: 0) == nil
                    || result.summary.split(separator: "\n").count != 1
                    || !result.summary.contains("Cyril <cyril@example.com>")
                    || !result.summary.contains("Dinner tomorrow?")
                    || result.summary.contains("Pricing sheet v3") {
                    SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: M03 actual latest-mail fixture changed")
                    misclassified += 1
                }
                let allMail = latestMail.mailSearch("")
                if !allMail.contains("Marcus Lee <marcus@productflo.example>")
                    || !allMail.contains("Pricing sheet v3")
                    || allMail.components(separatedBy: "\n").first != result.summary {
                    SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: M03 fixture chronology changed")
                    misclassified += 1
                }
                expect(.pass, "M03", replies: ["I checked your email. The last message was from Cyril about dinner tomorrow evening. They’re asking if you’re free tomorrow night. Let me know if you want to reply or keep it as is."], calls: latestMail.calls)
                expect(.pass, "M03", replies: ["Your latest email is from Cyril, asking whether you're free for dinner tomorrow evening."],
                       calls: latestMail.calls)
                // Exact older native false green: Marcus's pricing mail is not latest.
                expect(.ungrounded, "M03", replies: ["The latest email is from Marcus Lee at 05:00 about the updated pricing sheet for ProductFlo. Before that, there’s a reminder from Stripe about the September invoice and an email from Ana Ruiz asking for the deck by Friday. The most recent one relates to ProductFlo’s pricing sheet — likely something you need to review or act on. Let me know if you’d like me to open it."], calls: latestMail.calls)
                expect(.ungrounded, "M03", replies: ["Your latest email is Ana's request for the deck by Friday."],
                       calls: latestMail.calls)
                // A broader summary may include earlier mail after the actual latest message.
                expect(.pass, "M03", replies: ["The latest email is from Cyril about dinner tomorrow. Earlier, Ana asked for the deck and Marcus sent the pricing sheet."],
                       calls: latestMail.calls)
                // Preserve tool/claim/format verdicts; correct words alone are insufficient.
                expect(.missedTool, "M03", replies: ["Cyril asks about dinner tomorrow."])
                expect(.fabricated, "M03", replies: ["I checked your email. The last message was from Cyril about dinner tomorrow evening. They’re asking if you’re free tomorrow night. Let me know if you want to reply or keep it as is."])
                expect(.wrongTool, "M03", replies: ["Cyril asks about dinner tomorrow."],
                       calls: [call("get_agenda", ["date": today])])
                expect(.leak, "M03", replies: ["Cyril asks about dinner tomorrow. <tool_call>"],
                       calls: latestMail.calls)
            } catch {
                SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: M03 actual latest-mail read refused")
                misclassified += 1
            }
        }
        // M03_LATEST_MAIL_CONTRACT_COMMON_END

        // UNGROUNDED — a correct call but the reply never names the decision.
        expect(.ungrounded, "K01", replies: ["Nothing was decided."], calls: [
            call("meeting.decisions"),
        ])
        // K03_SPEAKER_ATTRIBUTION_COMMON_BEGIN
        // The retained native model raw itself swaps Sarah for Serge. The same
        // fixture and actual grader must reject that attribution, without forcing
        // every valid short answer to repeat Sarah's name.
        let k03Evidence = LiveEvalFixtures(now: Date(timeIntervalSince1970: 1_780_000_000))
            .summary(for: "meeting.recent_context", arguments: [:])
        if !k03Evidence.contains("Sarah said the budget needs a 10% buffer for ads.") {
            SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: K03 fixture speaker changed")
            misclassified += 1
        }
        expect(.ungrounded, "K03", replies: [
            "I don't have any information about what Sarah said regarding the budget. If you'd like, I can look it up — just let me know how you'd like me to find it.",
            "Serge said the budget needs a 10% buffer for ads.",
        ], calls: [call("meeting.recent_context")])
        expect(.ungrounded, "K03", replies: [
            "Ana said the budget needs a 10% buffer for ads.",
        ], calls: [call("meeting.search", ["query": "Sarah budget"])])
        expect(.ungrounded, "K03", replies: [
            "Marcus said the budget needs a ten percent buffer for ads.",
        ], calls: [call("meeting.transcript")])
        // Names unseen in the corpus must not bypass the attribution check.
        expect(.ungrounded, "K03", replies: [
            "Olivia said the budget needs a 10% buffer for ads.",
        ], calls: [call("meeting.recent_context")])
        expect(.ungrounded, "K03", replies: [
            "David Chen said the budget needs a ten percent buffer for ads.",
        ], calls: [call("meeting.transcript")])
        expect(.pass, "K03", replies: [
            "Sarah said the budget needs a 10% buffer for ads.",
        ], calls: [call("meeting.recent_context")])
        expect(.pass, "K03", replies: [
            "She said the budget needs a 10% buffer for ads.",
        ], calls: [call("meeting.recent_context")])
        expect(.pass, "K03", replies: [
            "The budget needs a 10% buffer for ads.",
        ], calls: [call("search_knowledge", ["query": "Sarah budget"])])
        expect(.pass, "K03", replies: [
            "Serge needs to send the revised budget to Ana. Sarah said the budget needs a 10% buffer for ads.",
        ], calls: [call("meeting.recent_context")])
        // Preserve existing verdict priority: an unrelated tool or no read cannot
        // pass just because the reply attributes the statement correctly.
        expect(.wrongTool, "K03", replies: [
            "Sarah said the budget needs a 10% buffer for ads.",
        ], calls: [call("get_agenda", ["date": today])])
        expect(.refusal, "K03", replies: ["I don't have access to your meetings."])
        expect(.ungrounded, "K03", replies: ["Sarah said the launch date moved."],
               calls: [call("meeting.recent_context")])
        // Scope remains K03; a budget action item does not establish its speaker.
        expect(.pass, "K02", replies: ["Serge said the budget needs a 10% buffer for ads."],
               calls: [call("meeting.action_items")])
        // K03_SPEAKER_ATTRIBUTION_COMMON_END

        // UNGROUNDED — a banned mention.
        expect(.ungrounded, "N01", replies: ["I'm your alter ego."])
        // UNGROUNDED — the reply is longer than the case allows.
        expect(.ungrounded, "N05", replies: [String(repeating: "You're welcome. ", count: 12)])
        // UNGROUNDED — a case rule failed (the whole sentence was not carried out).
        expect(.ungrounded, "A02", replies: ["Opened youtube.com."], calls: [
            call("browser.navigate", ["url": "https://www.youtube.com"]),
        ])
        expect(.ungrounded, "A02", replies: ["Should I click that video?"], calls: [
            call("browser.navigate", ["url": "https://www.youtube.com"]),
            call("browser.snapshot"),
        ])
        expect(.pass, "A02", replies: ["The latest Cortech video is playing."], calls: [
            call("browser.navigate", ["url": "https://www.youtube.com"]),
            call("browser.snapshot"),
            call("browser.click", ["expectedText": "Cortech — newest upload"]),
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
        // A restating question is not an offer, but this omitted-repeat write
        // still fails the original every-night request (native default is once).
        expect(.ungrounded, "R02", replies: [
            "Reminder set for 10 pm to put the book out. Is that right?",
        ], calls: [
            call("schedule.create", ["text": "put the book out", "time": "22:00"], risk: .write),
        ])

        // R02_DAILY_SEMANTICS_COMMON_BEGIN
        // Exact retained quiet e3ef6e1 native payload: days=7 is not repeat=daily.
        let r02Original = ["days": "7", "id": "every-night-10-reminder", "kind": "reminder",
                           "text": "Remind to put the book out every night at 10",
                           "time": "22:00", "title": "Put the book out"]
        expect(.ungrounded, "R02", replies: [
            "I can set that reminder for you, but I need a few details first. What would you like the reminder to say? And should it go off every night at 10 specifically, or on certain days of the week?",
            "The reminder to put the book out every night at 10 is set. It will go off each day at 10 p.m.",
        ], calls: [call("schedule.create", r02Original, turn: 1, risk: .modify)])
        let r02Daily = ["text": "put the book out", "kind": "reminder",
                        "time": "22:00", "repeat": "daily"]
        expect(.pass, "R02", replies: ["Reminder set every night at 10 pm to put the book out."],
               calls: [call("schedule.create", r02Daily, risk: .modify)])
        expect(.pass, "R02", replies: ["Reminder set for 10 pm to put the book out. Is that right?"],
               calls: [call("schedule.create", r02Daily, risk: .modify)])
        // Native aliases are parsed, not guessed by string equality in the grader.
        expect(.pass, "R02", replies: ["Reminder set every night at 10 pm to put the book out."],
               calls: [call("schedule.create", r02Daily.merging(["repeat": "every day", "time": "10pm"]) { _, new in new }, risk: .modify)])
        for change in [["repeat": "weekdays"], ["time": "21:00"],
                       ["kind": "routine"], ["repeat": "tomorrowish"]] {
            expect(.ungrounded, "R02", replies: ["Reminder set every night at 10 pm to put the book out."],
                   calls: [call("schedule.create", r02Daily.merging(change) { _, new in new }, risk: .modify)])
        }
        // Preserve no-call/refusal and wrong-tool priority over semantic grading.
        expect(.refusal, "R02", replies: ["I don't have access to reminders."])
        expect(.wrongTool, "R02", replies: ["Reminder set every night at 10 pm to put the book out."],
               calls: [call("get_agenda", ["date": today])])
        // R02_DAILY_SEMANTICS_COMMON_END
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

        // F03_RECIPIENT_AS_FILE_COMMON_BEGIN
        // Exact retained d64c9c6 quick2: a recipient is not the requested file.
        // The locate call alone cannot make this contradictory clarification a pass.
        expect(.ungrounded, "F03", replies: [
            "I can't find a file called \"Marcus\" on this Mac. Do you know the correct name or email address to send the pricing document to?",
        ], calls: [call("filesystem.search", ["query": "pricing"])])
        // Exact quick1 keeps the earlier REFUSAL priority, rather than redefining it.
        expect(.refusal, "F03", replies: [
            "I can't find a file called \"Marcus\" in this Mac. Do you know the exact name, or would you like me to search for it?",
        ], calls: [call("filesystem.search", ["query": "pricing"])])
        expect(.ungrounded, "F03", replies: [
            "I can’t find a document named “Marcus” on this Mac. What email address should I use?",
        ], calls: [call("filesystem.find", ["query": "pricing document"])])
        // A file choice plus the missing recipient address remains a valid clarification.
        expect(.pass, "F03", replies: [
            "I found two pricing documents. Which one should I send, and what is Marcus's email address?",
        ], calls: [call("filesystem.search", ["query": "pricing"])])
        // The address question itself may quote the recipient; it is not a file claim.
        expect(.pass, "F03", replies: [
            "I found Pricing 2026.pdf. What is Marcus's email address?",
        ], calls: [call("find_drive_files", ["query": "pricing"])])
        // A canned unsupported address was never a grounded positive.
        expect(.ungrounded, "F03", replies: [
            "I found Pricing 2026.pdf and prepared the email draft for Marcus.",
        ], calls: [
            call("filesystem.search", ["query": "pricing"]),
            call("draft_email", ["to": "marcus@example.invalid", "subject": "Pricing document"], risk: .write),
        ])
        // A locate read still cannot back a completed-send claim.
        expect(.fabricated, "F03", replies: [
            "I sent the pricing document to Marcus. What email address should I use?",
        ], calls: [call("filesystem.search", ["query": "pricing"])])
        // F03_RECIPIENT_AS_FILE_COMMON_END

        // F03_RECIPIENT_AND_DOCUMENT_CHOICE_COMMON_BEGIN
        if let canonical = LiveEvalCases.caseWithID(id: "F03") {
            func expectF03(_ expected: LiveEvalVerdict, _ label: String,
                           replies: [String], calls: [LiveEvalLoggedCall],
                           requests: [String]? = nil) {
                let input = LiveEvalCase(
                    id: canonical.id, turns: requests ?? canonical.turns,
                    followUpIfQuestion: canonical.followUpIfQuestion,
                    expectation: canonical.expectation, mustMention: canonical.mustMention,
                    mustNotMention: canonical.mustNotMention,
                    maxReplyCharacters: canonical.maxReplyCharacters,
                    dynamicMention: canonical.dynamicMention, extraRule: canonical.extraRule,
                    evidence: canonical.evidence, expectedFix: canonical.expectedFix,
                    scored: canonical.scored)
                let got = grade(case: input, replies: replies, calls: calls, trace: [])
                if got != expected {
                    SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: F03 \(label) expected "
                        + "\(expected.rawValue) got \(got.rawValue)")
                    misclassified += 1
                }
            }
            let find = call("filesystem.search", ["folder": "true",
                "modifiedAfter": "2026-01-01", "query": "pricing"])
            // Exact retained Qwen d32b123 quick1/3 final reply and actual calls.
            let nativeReply = "I’ve prepared the email to send to Marcus with the pricing document. Please review and approve if you'd like me to send it."
            let nativeSend = call("send_email", [
                "to": "marcus@company.com", "subject": "Pricing Document 2026",
                "body": "Attached is the latest pricing document for your review.\n\nBest regards,\nSerge",
            ], risk: .send)
            expectF03(.ungrounded, "retained invented recipient", replies: [nativeReply],
                      calls: [find, nativeSend])
            let draft = call("draft_email", ["to": "marcus@productflo.example",
                "subject": "Pricing document", "body": "Here is the pricing document."], risk: .write)
            let prepared = "I found the pricing document and prepared the draft for Marcus."
            expectF03(.ungrounded, "unread lucky fixture address", replies: [prepared],
                      calls: [find, draft])
            expectF03(.pass, "explicit original recipient", replies: [nativeReply],
                      calls: [find, nativeSend], requests: [
                        "Find the pricing document and email it to Marcus at marcus@company.com",
                      ])
            let laterSend = call("send_email", nativeSend.arguments, turn: 1, risk: .send)
            expectF03(.pass, "actual later user address", replies: [
                "I found two pricing documents. What is Marcus's email address?", nativeReply,
            ], calls: [find, laterSend], requests: [canonical.turns[0], "marcus@company.com"])
            expectF03(.ungrounded, "future user address cannot back earlier send",
                      replies: [nativeReply, "The draft is ready."], calls: [find, nativeSend],
                      requests: [canonical.turns[0], "marcus@company.com"])
            var bodyOnly = nativeSend.arguments
            bodyOnly["body"] = "Marcus's email address is marcus@company.com."
            expectF03(.ungrounded, "generated body is not recipient evidence",
                      replies: [nativeReply], calls: [find, call("send_email", bodyOnly, risk: .send)])

            // An actual validated fixture read exposes the authoritative sender header.
            let fixture = LiveEvalFixtures()
            let priorFake = AgentToolExecutor.fakeForTesting
            AgentToolExecutor.fakeForTesting = fixture.run
            do {
                _ = try await AgentToolExecutor.run("filesystem.search", arguments: find.arguments,
                    policy: .denyMutations, autoApproveReads: true, promptIfNeeded: false)
                let read = try await AgentToolExecutor.run("search_email",
                    arguments: ["query": "from:Marcus", "maxResults": "1"],
                    policy: .denyMutations, autoApproveReads: true, promptIfNeeded: false)
                if !read.summary.contains(" · Marcus Lee <marcus@productflo.example> · ")
                    || fixture.log.firstResult(for: 0) == nil || fixture.calls.count != 2 {
                    misclassified += 1
                    SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: F03 actual recipient fixture changed")
                }
                expectF03(.pass, "earlier same-turn actual sender read", replies: [prepared],
                          calls: fixture.calls + [draft])
                expectF03(.ungrounded, "invented address despite genuine read", replies: [nativeReply],
                          calls: fixture.calls + [nativeSend])
                fixture.beginCase()
                fixture.setTurn(1)
                _ = try await AgentToolExecutor.run("search_email",
                    arguments: ["query": "from:Marcus", "maxResults": "1"],
                    policy: .denyMutations, autoApproveReads: true, promptIfNeeded: false)
                expectF03(.pass, "actual later-turn authoritative read", replies: [
                    "I found the pricing documents. What is Marcus's email address?", prepared,
                ], calls: [find] + fixture.calls + [
                    call("draft_email", draft.arguments, turn: 1, risk: .write),
                ], requests: [canonical.turns[0], "Use the address in his latest email."])
            } catch {
                misclassified += 1
                SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: F03 actual recipient read refused")
            }
            AgentToolExecutor.fakeForTesting = priorFake
            let readMarcus = call("search_email", ["query": "from:Marcus", "maxResults": "1"])
            for (label, calls) in [
                ("later read cannot back earlier send", [find, draft, readMarcus]),
                ("other-turn read cannot back this send", [find,
                    call("search_email", readMarcus.arguments, turn: 1), draft]),
                ("unrelated sender read", [find, call("search_email", ["query": "from:Ana"]), draft]),
                ("read without matching sender", [find,
                    call("search_email", ["query": "from:marcus@company.com"]), nativeSend]),
            ] {
                expectF03(.ungrounded, label, replies: [prepared], calls: calls)
            }
            expectF03(.wrongTool, "wrong-risk read is not recipient authority", replies: [prepared],
                      calls: [find, call("search_email", readMarcus.arguments, risk: .send), draft])
            // Exact Gemma current quick1: both unchanged fixture hits support this choice.
            let choice = "I found two pricing documents for you. Which one should I send to Marcus?"
            expectF03(.pass, "retained document choice", replies: [choice],
                      calls: [call("filesystem.search", ["query": "pricing"])])
            expectF03(.pass, "Drive document choice", replies: [choice],
                      calls: [call("find_drive_files", ["query": "pricing"])])
            expectF03(.refusal, "choice without lookup", replies: [choice], calls: [])
            expectF03(.refusal, "unrelated lookup does not ground choice", replies: [choice],
                      calls: [call("filesystem.search", ["query": "garden"])])
            expectF03(.missedTool, "plain locate remains incomplete",
                      replies: ["I found two pricing documents."], calls: [find])
            expectF03(.fabricated, "choice cannot back completed-send claim",
                      replies: ["I sent the document to Marcus. Which one should I send?"], calls: [find])
        }
        // F03_RECIPIENT_AND_DOCUMENT_CHOICE_COMMON_END

        // UNGROUNDED — the reply never names the model that is running (N02).
        expect(.ungrounded, "N02", replies: ["I don't run on a specific model."])
        // PASS — the reply names it.
        expect(.pass, "N02", replies: ["I'm running on Qwen3-4B-Instruct-2507 here."])
        expect(.ungrounded, "N02", replies: ["I'm running on Qwen3.5-4B here."])
        modelName = "Apple Foundation Model"
        expect(.ungrounded, "N02", replies: ["I run on a model."])
        expect(.pass, "N02", replies: ["I run on Apple Foundation Models."])
        modelName = "Qwen3-4B-Instruct-2507"

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

        // O01_SUMMARY_PROVENANCE_COMMON_BEGIN
        // Exact retained native exchange: five-message summary first, then only
        // its provenance. The summary need not be repeated in the follow-up.
        do {
            let mail = LiveEvalFixtures(now: Date(timeIntervalSince1970: 1_780_000_000))
            let savedFake = AgentToolExecutor.fakeForTesting
            AgentToolExecutor.fakeForTesting = mail.run
            defer { AgentToolExecutor.fakeForTesting = savedFake }
            let arguments = ["query": "", "maxResults": "5"]
            let summary = "Here’s a quick summary of your last emails:\n\n- **Cyril** asked if you’re free for dinner tomorrow evening.  \n- **Ana Ruiz** needs the deck sent by Friday.  \n- **Marcus Lee** shared the updated pricing sheet (v3).  \n- A GitHub CI check passed for all 214 checks.  \n- **Stripe** sent your September invoice.  \n\nLet me know if you’d like to reply to any of them."
            let provenance = "Yes, that summary comes from your recent emails. I pulled it directly from your inbox. Let me know if you'd like to reply to anything specific."
            do {
                let result = try await AgentToolExecutor.run("search_email", arguments: arguments,
                    policy: .denyMutations, autoApproveReads: true, promptIfNeeded: false)
                let facts = ["Cyril <cyril@example.com>", "Dinner tomorrow?",
                    "Ana Ruiz <ana@example.com>", "Deck for Friday",
                    "Marcus Lee <marcus@productflo.example>", "Pricing sheet v3",
                    "GitHub <no-reply@github.example>", "All 214 checks passed.",
                    "Stripe <noreply@stripe.example>", "Your invoice for September"]
                if mail.calls.count != 1 || mail.calls.first?.turn != 0
                    || mail.calls.first?.arguments != arguments
                    || mail.log.firstResult(for: 0) == nil
                    || result.summary.split(separator: "\n").count != 5
                    || !facts.allSatisfy({ result.summary.contains($0) }) {
                    SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: O01 actual source fixture changed")
                    misclassified += 1
                }
                expect(.pass, "O01", replies: [summary, provenance], calls: mail.calls)
                // A source read is necessary, but cannot turn an invented summary
                // or a contradictory provenance statement into a grounded answer.
                expect(.ungrounded, "O01", replies: [
                    "Jordan approved your passport and Taylor booked a flight.", provenance,
                ], calls: mail.calls)
                expect(.ungrounded, "O01", replies: [summary,
                    "No, I made those emails up."], calls: mail.calls)
                expect(.ungrounded, "O01", replies: [summary,
                    "Yes, that summary comes from your calendar."], calls: mail.calls)
                expect(.ungrounded, "O01", replies: [summary,
                    "Yes, that summary comes from your emails. I guessed the contents."],
                    calls: mail.calls)
                expect(.ungrounded, "O01", replies: [summary,
                    "Yes, this is not from your emails."], calls: mail.calls)
                expect(.ungrounded, "O01", replies: [summary,
                    "Yes, that summary comes from your recent emails. Actually, it came from your calendar."],
                    calls: mail.calls)
                expect(.ungrounded, "O01", replies: [summary,
                    "Yes, that summary comes from your recent emails. Actually, it was not from your inbox."],
                    calls: mail.calls)
                expect(.missedTool, "O01", replies: [summary, provenance])
                // A later read does not establish the earlier summary's source.
                expect(.ungrounded, "O01", replies: [summary, provenance], calls: [
                    call("search_email", arguments, turn: 1),
                ])
            } catch {
                SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: O01 actual source read refused")
                misclassified += 1
            }
        }
        // O01_SUMMARY_PROVENANCE_COMMON_END

        // O01_EMAIL_HISTORY_COMMON_BEGIN: exact native two-reply consumer, actual six-message read.
        do {
            let mail = LiveEvalFixtures(now: ISO8601DateFormatter().date(from: "2026-10-05T09:00:00-04:00")!)
            let savedFake = AgentToolExecutor.fakeForTesting
            AgentToolExecutor.fakeForTesting = mail.run
            defer { AgentToolExecutor.fakeForTesting = savedFake }
            let summary = "Here's a quick summary of your last emails:\n\n1.  **Cyril** asked about dinner tomorrow.\n2.  **Ana Ruiz** needs the deck sent by Friday.\n3.  **Marcus Lee** shared an updated pricing sheet.\n4.  A GitHub note confirmed CI passed on main.\n5.  **Stripe** notified you about a September invoice.\n6.  **Marcus Lee** discussed contract renewal terms.\n\nWant me to help with any of these?"
            let provenance = "That's just how the summary came together — it's pulling from your email history. If you'd like me to look at something specific in your emails, I can help with that."
            do {
                let result = try await AgentToolExecutor.run("search_email", arguments: [:],
                    policy: .denyMutations, autoApproveReads: true, promptIfNeeded: false)
                if mail.calls.count != 1 || mail.calls.first?.turn != 0
                    || mail.calls.first?.arguments != [:] || mail.log.firstResult(for: 0) == nil
                    || result.summary.split(separator: "\n").count != 6
                    || !["Cyril", "Ana Ruiz", "Marcus Lee", "GitHub", "Stripe", "contract renewal"].allSatisfy({ result.summary.contains($0) }) {
                    SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: O01 exact six-message source fixture changed")
                    misclassified += 1
                }
                expect(.pass, "O01", replies: [summary, provenance], calls: mail.calls)
                expect(.pass, "O01", replies: [summary,
                    "It’s pulling from your email history."], calls: mail.calls)
                for rejected in [
                    "No, that summary isn't from your email history.",
                    "I don't have access to your emails.",
                    "It's pulling from your calendar history.",
                    "If it's pulling from your email history, I can confirm it.",
                    "It's pulling from your email history?",
                    "It's not pulling from your email history.",
                    "It's pulling from your email history. I invented the summary.",
                    "It's pulling from your email history. Actually, it came from memory.",
                    "It's pulling from your email history. Actually, it's not pulling from your email history.",
                    "It's pulling from your email history. I never read your emails.",
                ] {
                    expect(.ungrounded, "O01", replies: [summary, rejected], calls: mail.calls)
                }
                expect(.ungrounded, "O01", replies: ["Jordan approved your passport and Taylor booked a flight.", provenance], calls: mail.calls)
                expect(.missedTool, "O01", replies: [summary, provenance])
                expect(.missedTool, "O01", replies: [summary, provenance], calls: [call("memory.recall", [:])])
                expect(.ungrounded, "O01", replies: [summary, provenance], calls: [call("search_email", [:], turn: 1)])
            } catch {
                SelfTest.diagnostic("TOOLLOOP_LIVE_GRADER_WRONG: O01 exact source fixture refused")
                misclassified += 1
            }
        }
        // O01_EMAIL_HISTORY_COMMON_END

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
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
            .addingTimeInterval(60)
        let earlyMailbox = LiveEvalFixtures(now: midnight).mailbox
        if earlyMailbox.messages.contains(where: { $0.stamp > midnight }) {
            SelfTest.diagnostic("TOOLLOOP_LIVE_MAIL_WRONG: fixture has future mail")
            mailboxProblems += 1
        }
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

        var instrumentFailures = ToolLoopLiveEval.instrumentSelfTestFailures()
        instrumentFailures += await fixtureArgumentFailures()
        instrumentFailures += await fixtureClickVerificationFailures()
        if let fixed = SelfTest.parseFixtureClock("2026-10-04T12:34:56.789Z") {
            let fixtures = LiveEvalFixtures(now: fixed)
            let day = dayString(now: fixed)
            let next = dayString(offset: 1, now: fixed)
            let prompt = AgentNow.render(AgentNowFacts(), shape: .dateOnly, now: fixed,
                                         zone: .current, cloud: false, cloudConsent: false)
            if !fixtures.summary(for: "get_agenda", arguments: ["date": day])
                .hasPrefix("On \(day):")
                || !fixtures.summary(for: "get_agenda", arguments: ["date": next])
                    .hasPrefix("On \(next):")
                || !todaySpellings(now: fixed).contains(day) || !prompt.contains(day) {
                instrumentFailures.append("prompt/fixture/grader dates disagree")
            }
            let hit = try? fixtures.files.find(query: "pricing", category: nil, folder: nil,
                                               modifiedAfter: nil, limit: 1).first
            if hit?.accessedAt != fixed
                || hit?.modifiedAt != fixed.addingTimeInterval(-3 * 24 * 60 * 60) {
                instrumentFailures.append("file fixture clock drifted")
            }
        } else {
            instrumentFailures.append("fixed clock could not be parsed")
        }
        for failure in instrumentFailures {
            SelfTest.diagnostic("TOOLLOOP_LIVE_INSTRUMENT_WRONG: \(failure)")
        }
        SelfTest.diagnostic("TOOLLOOP_LIVE_INSTRUMENT: \(instrumentFailures.count) problem(s)")
        return misclassified == 0 && mailboxProblems == 0 && instrumentFailures.isEmpty
    }

    /// The recorded A02 click supplied its postcondition. Exercise the SAME
    /// validation at the live fixture executor before its success log, without
    /// entering a browser or approving an action on the owner's machine.
    private static func fixtureClickVerificationFailures() async -> [String] {
        guard SelfTest.isRunning else { return ["click verification requires SelfTest"] }
        var failures: [String] = []
        func check(_ label: String, _ condition: Bool) {
            if !condition { failures.append("click verification: " + label) }
        }
        let fixtures = LiveEvalFixtures()
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldApprovals = AgentToolExecutor.recordedReadApprovalsForTesting
        AgentToolExecutor.fakeForTesting = fixtures.run
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.recordedReadApprovalsForTesting = oldApprovals
        }
        let cases: [(String, [String: String], Bool)] = [
            // Exact retained Gemma/Qwen A02 arguments, copied from the snapshot.
            ("browser.click", ["id": "2", "expectedText": "Cortech — newest upload (2 days ago)"], true),
            ("browser.click", ["id": "2", "expectedURL": "https://www.youtube.com/"], true),
            ("browser.click", ["id": "2", "expectedText": "Cortech — newest upload (2 days ago)",
                               "expectedURL": "https://www.youtube.com/"], true),
            ("computer.click", ["id": "2", "expectedText": "Completed"], true),
            ("browser.click", ["id": "2"], false),
            ("computer.click", ["id": "2"], false),
            ("browser.click", ["id": "2", "expectedText": "  ", "expectedURL": "\n"], false),
            ("computer.click", ["id": "2", "expectedText": "  "], false),
            // Existing self-verifying operations need no extra postcondition.
            ("browser.navigate", ["url": "https://www.youtube.com"], true),
            ("browser.fill", ["id": "1", "text": "Cortech"], true),
        ]
        for (id, arguments, runnable) in cases {
            guard let tool = AgentToolRegistry.shared.tool(named: id) else {
                failures.append("click verification: missing " + id)
                continue
            }
            let label = id + ":" + arguments.keys.sorted().joined(separator: ",")
            fixtures.beginCase()
            let problem = ToolCallValidation.problem(tool: tool, arguments: arguments)
            check(label + " production postcondition admission", (problem == nil) == runnable)
            do {
                let result = try await AgentToolExecutor.run(id, arguments: arguments,
                    policy: .denyMutations, promptIfNeeded: false)
                check(label + " accepted an unverified click", runnable)
                check(label + " changed actual fixture result", result.summary == fixtures.summary(
                    for: id, arguments: arguments))
                check(label + " lost exact accepted call", fixtures.calls == [LiveEvalLoggedCall(
                    turn: 0, toolID: id, arguments: arguments, risk: tool.risk)])
                check(label + " lost accepted result", fixtures.log.firstResult(for: 0) != nil)
            } catch AgentError.permissionDenied(let message) {
                check(label + " refused supplied verification", !runnable && message == problem)
                check(label + " recorded refused work", fixtures.calls.isEmpty)
                check(label + " recorded refused result", fixtures.log.firstResult(for: 0) == nil)
            } catch {
                failures.append("click verification: " + label + " unexpected error " + error.localizedDescription)
            }
        }
        return failures
    }

    /// Replay the recorded M04 arguments through the actual live-eval executor seam.
    /// The real validator supplies the refusal; no tool, account or model is entered.
    private static func fixtureArgumentFailures() async -> [String] {
        guard SelfTest.isRunning,
              let draft = AgentToolRegistry.shared.tool(named: "draft_email"),
              let evalCase = LiveEvalCases.caseWithID(id: "M04") else {
            return ["live fixture validation prerequisites missing"]
        }
        var failures: [String] = []
        func check(_ label: String, _ condition: Bool) {
            if !condition { failures.append("fixture arguments: " + label) }
        }
        let fixtures = LiveEvalFixtures()
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldApprovals = AgentToolExecutor.recordedReadApprovalsForTesting
        AgentToolExecutor.fakeForTesting = fixtures.run
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.recordedReadApprovalsForTesting = oldApprovals
        }
        // Exact original raw M04 call: there is no subject to validate or approve.
        let recorded = ["to": "ana@example.com", "body": "I'll send the deck on Friday."]
        var emptySubject = recorded; emptySubject["subject"] = "  "
        var placeholderSubject = recorded; placeholderSubject["subject"] = "[Subject]"
        for (label, arguments) in [("missing subject", recorded),
                                    ("empty subject", emptySubject),
                                    ("placeholder subject", placeholderSubject)] {
            fixtures.beginCase()
            let problem = ToolCallValidation.problem(tool: draft, arguments: arguments)
            check(label + " must be refused by production", problem != nil)
            var refused = false
            do {
                _ = try await AgentToolExecutor.run("draft_email", arguments: arguments,
                    policy: .denyMutations, promptIfNeeded: false)
            } catch AgentError.permissionDenied(let message) {
                refused = message == problem
            } catch { }
            check(label + " was accepted by live fixture", refused)
            check(label + " recorded successful work", fixtures.calls.isEmpty)
            check(label + " recorded a verified result", fixtures.log.firstResult(for: 0) == nil)
            if label == "missing subject" {
                check("recorded M04 must not pass without a runnable draft",
                    grade(case: evalCase, replies: [
                        "I have drafted the email for you. Do you want to send it now?"
                    ], calls: fixtures.calls, trace: []) != .pass)
            }
        }
        fixtures.beginCase()
        var complete = recorded; complete["subject"] = "Deck for Friday"
        do {
            let result = try await AgentToolExecutor.run("draft_email", arguments: complete,
                policy: .denyMutations, promptIfNeeded: false)
            check("valid draft result changed", result.summary == fixtures.summary(
                for: "draft_email", arguments: complete))
            check("valid draft log changed", fixtures.calls == [LiveEvalLoggedCall(
                turn: 0, toolID: draft.id, arguments: complete, risk: draft.risk)])
            check("valid draft lost verified result", fixtures.log.firstResult(for: 0) != nil)
            check("valid M04 no longer passes", grade(case: evalCase, replies: [
                "I have drafted the email for you. Do you want to send it now?"
            ], calls: fixtures.calls, trace: []) == .pass)
        } catch { failures.append("fixture arguments: valid draft refused") }
        // R01_FIXTURE_COMMON: paste inside fixtureArgumentFailures, before final read control.
        do {
            let raw = "<tool_call>\n  {\"name\":\"schedule.create\",\"arguments\":{\"title\":\"Call the bank\",\"text\":\"Reminder to call the bank at 9 AM tomorrow.\",\"kind\":\"routine\",\"tools\":\"calendar\",\"model\":\"gpt-4o-mini\",\"plainEnglish\":\"True\",\"on\":\"True\",\"leadMinutes\":null,\"filter\":null,\"repeat\":\"Never\",\"time\":\"Tomorrow 09:00\",\"date\":\"2026-10-06\",\"inMinutes\":null,\"days\":null,\"day\":null,\"endsOn\":null,\"speak\":null},\"rationale\":\"User asked to remind them at 9 tomorrow to call the bank. I need to create a reminder for tomorrow (2026-10-06) at 9 AM.\"}\n</tool_call>"
            let parsed = AgentToolCallParser.parse(raw, knownNames: ["schedule.create"])
            let tool = AgentToolRegistry.shared.tool(named: "schedule.create")
            let eval = LiveEvalCases.caseWithID(id: "R01")
            let qualified = SelfTest.isRunning && eval != nil && parsed.calls.count == 1 && parsed.malformed.isEmpty
                && tool.map { ToolCallValidation.problem(tool: $0, arguments: parsed.calls[0].arguments) == nil } == true
            check("R01 native schedule parser/generic-boundary fixture unavailable", qualified)
            if !qualified { SelfTest.diagnostic("TOOLLOOP_LIVE_R01_FIXTURE_INPUT_INVALID") }
            else if let tool, let call = parsed.calls.first, let eval {
                let now = SelfTest.parseFixtureClock("2026-10-05T09:00:00-04:00")!
                let zone = TimeZone.current
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NextNotesR01Fixture-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = ScheduleStore(directory: root)
                let scheduler = AgentScheduler(store: store, system: RoutineAuthoritySelfTest.NoSystem(),
                    deliverer: RoutineAuthoritySelfTest.QuietDeliverer(),
                    environment: RoutineAuthoritySelfTest.AbsentEnvironment(),
                    settings: { ScheduleSettingsSnapshot(enabled: true, quietStart: nil,
                                                         quietEnd: nil, speech: .never) },
                    timeZone: { zone })
                var realError: String?
                do { _ = try await ScheduleToolExecutor.run(tool, arguments: call.arguments,
                    scheduler: scheduler, now: now, timeZone: zone) }
                catch { realError = error.localizedDescription }
                check("R01 exact native false-positive no longer rejected by actual store producer",
                      realError?.contains("Tomorrow 09:00") == true
                        && ScheduleStore(directory: root).schedules.isEmpty)
                let scheduleFixtures = LiveEvalFixtures(now: now)
                let savedFake = AgentToolExecutor.fakeForTesting
                AgentToolExecutor.fakeForTesting = scheduleFixtures.run
                defer { AgentToolExecutor.fakeForTesting = savedFake }
                var rejected = false
                do { _ = try await AgentToolExecutor.run(tool.id, arguments: call.arguments,
                    policy: .denyMutations, promptIfNeeded: false) }
                catch { rejected = error.localizedDescription == realError }
                check("R01 live fixture admitted the actual producer's rejected native payload", rejected)
                check("R01 live fixture logged work/result for rejected native payload",
                      scheduleFixtures.calls.isEmpty && scheduleFixtures.log.firstResult(for: 0) == nil)
                check("R01 original success wording still passes without a valid executed call",
                      grade(case: eval, replies: ["Good. A reminder to call the bank at 9 tomorrow is set."],
                          calls: scheduleFixtures.calls, trace: []) != .pass)
                let valid = ["title": "Call the bank", "text": "Call the bank", "kind": "reminder",
                             "date": "2026-10-06", "time": "09:00"]
                for (name, arguments, runnable) in [
                    ("valid reminder", valid, true),
                    ("valid daily routine", valid.merging(["kind": "routine", "repeat": "daily", "model": "auto"]) { _, new in new }, true),
                    ("valid trigger", ["title": "Call note", "text": "Read call notes", "kind": "trigger", "on": "call_started"], true),
                    ("invalid time", valid.merging(["time": "Tomorrow 09:00"]) { _, new in new }, false),
                    ("invalid kind", valid.merging(["kind": "weekly"]) { _, new in new }, false),
                    ("invalid model", valid.merging(["kind": "routine", "model": "gpt-4o-mini"]) { _, new in new }, false),
                    ("invalid trigger", valid.merging(["kind": "trigger", "on": "True"]) { _, new in new }, false),
                    ("invalid end", valid.merging(["endsOn": "tomorrowish"]) { _, new in new }, false),
                ] {
                    scheduleFixtures.beginCase()
                    var accepted = false
                    do {
                        let result = try await AgentToolExecutor.run(tool.id, arguments: arguments,
                            policy: .denyMutations, promptIfNeeded: false)
                        accepted = true
                        check("R01 runnable fixture summary changed: \(name)",
                              result.summary == scheduleFixtures.summary(for: tool.id, arguments: arguments))
                    } catch { }
                    check("R01 schedule fixture preflight disagreed with real field contracts: \(name)", accepted == runnable)
                    check("R01 invalid field recorded work/result: \(name)",
                          runnable ? scheduleFixtures.calls.count == 1 && scheduleFixtures.log.firstResult(for: 0) != nil
                            : scheduleFixtures.calls.isEmpty && scheduleFixtures.log.firstResult(for: 0) == nil)
                }
            }
        }
        // R01_FIXTURE_END_COMMON

        fixtures.beginCase()
        do {
            _ = try await AgentToolExecutor.run("search_email", arguments: ["query": "in:inbox"],
                policy: .denyMutations, autoApproveReads: true, promptIfNeeded: false)
            check("valid read did not run", fixtures.calls.count == 1
                && fixtures.calls.first?.toolID == "search_email"
                && fixtures.log.firstResult(for: 0) != nil)
        } catch { failures.append("fixture arguments: valid read refused") }
        return failures
    }

    private static func call(
        _ toolID: String, _ arguments: [String: String] = [:],
        turn: Int = 0, risk: AgentRisk = .read
    ) -> LiveEvalLoggedCall {
        LiveEvalLoggedCall(turn: turn, toolID: toolID, arguments: arguments, risk: risk)
    }
}
