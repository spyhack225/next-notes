import Foundation

/// Multi-round tool use for a voice turn. MeetingAgent already had this shape; the
/// realtime path was one completion and the first call. Both providers take one system
/// and one user message, so prior results are appended to the user side rather than
/// sent as a tool-role turn.
enum AgentToolLoop {
    private final class CallbackBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private enum CompletionFailure: Error, Sendable {
        case message(String)
    }

    static let defaultMaxRounds = 4
    static let minRounds = 4
    static let maxRoundsBound = 8
    static let defaultMaxCalls = 8
    static let defaultMaxWallTime: Duration = .seconds(20)

    static func clampedMaxRounds(_ requested: Int) -> Int {
        min(maxRoundsBound, max(minRounds, requested))
    }

    struct Outcome: Sendable, Equatable {
        var reply: String
        var rounds: Int
        var calls: Int
    }

    /// Builds the next user message. Empty results is the original utterance; later
    /// rounds are that utterance plus what the tools already returned.
    ///
    /// The generic/scheduled caller keeps default eager folding and the reader-sized cap.
    /// The ordinary planner passes `foldOlderResults: false` because its existing token
    /// counter and overflow loop own admission there. Already-capped tool results should
    /// reach that measurement before older bodies are reduced to their wrapper's title.
    /// Both planner callers use their shared measured fitter; generic/scheduled callers
    /// retain the default eager folding policy.
    static func userMessage(
        original: String, results: [String], readerContextTokens: Int = 8_192,
        foldOlderResults: Bool = true
    ) -> String {
        guard !results.isEmpty else { return original }
        // A result arrives here as `"<name> returned:\n<text>"`, so this function cannot
        // tell a mail body from a file listing and must not halve one of them: the limit
        // below is the *document* ceiling, and the planner has already applied the tighter
        // per-tool cap where it knew the id. What this buys is the scheduled-routine loop,
        // which appends uncapped results and has no other place to bound them.
        let ceiling = ToolResultBudget.characterCap(readerContextTokens: readerContextTokens) * 2
        let admitted = foldOlderResults ? ToolResultBudget.fold(results) : results
        let carried = admitted.map { ToolResultBudget.cap($0, to: ceiling) }
        return """
            \(original)

            What you have already done:
            \(carried.joined(separator: "\n"))

            Continue. If you have enough to answer, reply in plain language with no tool calls.
            """
    }

    /// A future-action promise or explicit requested-action offer, limited to this turn's class.
    /// This admits one planner continuation; it does not choose or execute a tool.
    static func promisedIntent(
        in reply: String, manifest: AgentCapabilityManifest, request: String = "", repairsUsed: Int = 0,
        acknowledgedReply: String? = nil
    ) -> AgentIntentClass? {
        var trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") {
            // Only an exact repeat of the offer the user just answered qualifies.
            // The existing conversation supplies it; a changed proposal or a new
            // factual/capability question retains the ordinary pending path.
            let question = PendingAction.lastSentence(trimmed)
            let lines = request.split(separator: "\n").map(String.init)
            guard repairsUsed == 0, request.hasPrefix(PendingAction.confirmedPrefix),
                  PendingAction.offerPhrases.contains(where: { question.lowercased().contains($0) }),
                  lines.contains("You then asked: " + question),
                  let answer = lines.first(where: { $0.hasPrefix("The user answered: ") }),
                  PendingAction.isConfirmation(String(answer.dropFirst("The user answered: ".count))),
                  let acknowledgedReply,
                  trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    == acknowledgedReply.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                  let questionRange = trimmed.range(of: question, options: .backwards)
            else { return nil }
            trimmed = String(trimmed[..<questionRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.contains("?") else { return nil }
        }
        let sentence = trimmed.split(whereSeparator: { ".!?".contains($0) })
            .last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "\u{2019}", with: "'") ?? ""
        guard let prefix = ["i'll ", "i will ", "let me ", "i can help ", "i can "].first(where: { sentence.hasPrefix($0) })
        else { return nil }
        let words = AgentAccountRead.words(of: sentence)
        guard !words.contains(where: { word in
            AgentAccountRead.denialStems.contains { stem in
                stem.count <= 3 ? word == stem : word.hasPrefix(stem)
            }
        }) else { return nil }
        let verbs = AgentDirectIntent.actionVerbs.union(AgentAccountRead.readVerbStems).union(["set", "click"])
        // The promised verb owns the action; a later noun such as "email" does not.
        guard let action = AgentAccountRead.words(of: String(sentence.dropFirst(prefix.count))).first,
              verbs.contains(action) else { return nil }
        if prefix.hasPrefix("i can ") {
            // A capability statement is not a requested action. Only this-turn offers
            // referring back to the person's explicit matching imperative continue.
            let offered = AgentAccountRead.words(of: String(sentence.dropFirst(prefix.count)))
            guard repairsUsed == 0, offered.contains(where: { ["that", "this", "it"].contains($0) }),
                  explicitlyRequests(action, in: request)
            else { return nil }
        }
        return AgentCapabilityManifestBuilder.intents(in: sentence)
            .intersection(manifest.selectedIntents)
            .intersection(prefix.hasPrefix("i can ")
                ? AgentCapabilityManifestBuilder.intents(in: request) : manifest.selectedIntents)
            .sorted { $0.rawValue < $1.rawValue }
            .first { intent in manifest.selected.contains { $0.intent == intent } }
    }

    /// Completion is checked from the same turn's actual canonical tool ids.
    /// The default class contract is retained for the original contrast.
    static func promiseIsCompleted(
        intent: AgentIntentClass, reply: String, request: String,
        manifest: AgentCapabilityManifest, completedToolIDs: [String]
    ) -> Bool {
        let completed = completedToolIDs.filter { manifest.entry(named: $0)?.intent == intent }
        guard !completed.isEmpty else { return false }
        // navigate opens a URL, not the explicit second step of an open-and-find
        // request. Keep every other completed-class suppression unchanged. This
        // only admits the existing bounded continuation; it selects no action.
        if intent == .browser, Set(completed) == ["browser.navigate"],
           explicitlyRequests("open", in: request),
           MultiStepPlanRouting.likelyMultiStep(request),
           manifest.selected.contains(where: {
               $0.intent == .browser && $0.risk <= .read
                 && ($0.id == "browser.snapshot" || $0.id == "browser.read_page")
           }),
           reply.range(of: #"\b(?:and|then)\s+(?:find|search|look)\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }
        return true
    }

    /// The first-only subject question asks the person for prose the draft contract
    /// assigns to the model. It shares the existing single repair and call-required round.
    static func draftSubjectRepair(
        in reply: String, request: String, manifest: AgentCapabilityManifest, repairsUsed: Int
    ) -> String? {
        guard repairsUsed == 0,
              reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "what should the subject line be?",
              explicitlyRequests("draft", in: request),
              AgentAccountRead.words(of: AgentCapabilityManifestBuilder.normalized(request)).contains("email"),
              manifest.selectedIDs.contains("draft_email"),
              let entry = manifest.entry(named: "draft_email"),
              let subject = entry.parameters.first(where: { $0.name == "subject" && $0.isRequired })
        else { return nil }
        return ToolRepair(kind: .missingArgument, toolID: entry.id,
            message: "The draft is missing its subject. " + subject.description
                + " Send the complete draft call again. Leave unknown addresses or ids "
                + "missing; never invent them.").modelText
    }

    private static func explicitlyRequests(_ action: String, in request: String) -> Bool {
        let pattern = "^\\s*(?:please\\s+)?(?:(?:can|could|would|will)\\s+you\\s+)?"
            + "(?:please\\s+)?" + NSRegularExpression.escapedPattern(for: action) + "\\b"
        return request.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Strips argument values the model invented to fill a slot it did not know.
    ///
    /// The loop is where a call stops being text and starts being an action, so it is the
    /// last place a stand-in can be removed without also removing the user's chance to see
    /// it. What is left is an incomplete call, which is what it always was — the executor
    /// refuses it for the missing argument, and the approval card asks for the value
    /// instead of showing "[Name]" as though somebody had chosen it.
    @MainActor
    static func grounded(_ call: AgentToolCall) -> AgentToolCall {
        let tool = AgentToolRegistry.shared.tool(named: call.name)
        let cleaned = ToolCallValidation.withoutInventedValues(call.arguments, tool: tool)
        guard cleaned != call.arguments else { return call }
        Log.agent.info("dropped \(call.arguments.count - cleaned.count, privacy: .public) invented argument(s) from \(call.name, privacy: .public)")
        return AgentToolCall(
            name: call.name, arguments: cleaned,
            rationale: call.rationale, evidence: call.evidence
        )
    }

    /// A relative day in the current request is grounded by the device clock, not by a small
    /// model's remembered training date. This validates an already-selected calendar tool; it
    /// does not decide whether to call one.
    ///
    /// "Tomorrow" and "on Tuesday" are here for the same reason "today" was: a 4B model
    /// answered C02 with a date from its training data, and the eval graded it `WRONG_TOOL`
    /// for calling the right tool on the wrong day. Exactly one relative day is grounded —
    /// "today and tomorrow" is two, and guessing which one the person meant is worse than
    /// leaving the model's own answer to be corrected by the card.
    ///
    /// A mail filter is grounded here for the same reason and by the same rule: **a search
    /// term the user did not say is not searched for.** P1-14, measured on 2026-09-26 — the
    /// mail class is the one class with no rule line, and a 4B planner invented a filter for
    /// every mail request that did not name one:
    ///
    /// | Request | Filter the model wrote | What it matched |
    /// |---|---|---|
    /// | "Summarize my last 5 emails" (M01) | `recent`, `subject:.*`, `subject:'summary' OR …` | nothing |
    /// | "Check my email … then do a summary" (M03) | `recent` | nothing |
    /// | "Summarize my last emails" (M05) | `recent` | nothing |
    /// | "Summarize my last emails and list my events for tomorrow" (C04) | `subject:'ProductFlo'` | nothing |
    ///
    /// `subject:'ProductFlo'` is the one that matters: the company name came from a *memory
    /// fact* in the prompt, and the turn reported "No emails related to ProductFlo were
    /// found" about a mailbox holding six messages. A filter nobody asked for does not
    /// produce a wrong answer here — it produces an **invented** one, and it is the one place
    /// the app was letting a model search by something the user never said.
    ///
    /// The rule is provenance, not a keyword list: a clause survives when its content words
    /// are words the user said, so `from:Marcus` survives "Any new emails from Marcus?" and
    /// `subject:dentist` survives "find my email about the dentist", while `recent` and
    /// `subject:'ProductFlo'` do not survive anything. A clause that is dropped takes only
    /// itself, so a query the user did partly ask for is narrowed rather than discarded. When
    /// nothing survives the query is empty, which `search_email` documents as the latest mail
    /// — the answer to "my last emails", and the only answer that is not a filter the user
    /// did not ask for.
    /// One function, one row per tool, both reachable — a chain of guards would have made
    /// the second rule unreachable the day someone added a third.
    static func groundedArguments(
        for tool: String, proposed: [String: String], request: String,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [String: String] {
        switch tool {
        case "get_agenda": return groundCalendarDay(proposed, request: request, now: now, calendar: calendar)
        case "search_email": return groundMailFilter(proposed, request)
        case "schedule.create":
            let dateText = proposed["date"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            // This relative expression means tomorrow, but is not native schedule syntax.
            // Bind it only to matching authored timing below; other nonempty dates retain
            // their existing native validation/repair and never become a different choice.
            guard dateText.isEmpty || dateText == "today+1d"
            else { return proposed }
            var objective = request
            if request.hasPrefix(PendingAction.confirmedPrefix) {
                let lines = request.components(separatedBy: "\n")
                guard lines.count == 4, lines[1].hasPrefix("You then asked: "),
                      lines[2].hasPrefix("The user answered: ") else { return proposed }
                let answer = String(lines[2].dropFirst("The user answered: ".count))
                guard VoiceTurnPolicy.isBareAcknowledgment(answer) else { return proposed }
                objective = String(lines[0].dropFirst(PendingAction.confirmedPrefix.count))
                    .trimmingCharacters(in: .whitespaces)
                let pending = PendingAction(requestText: objective,
                    question: String(lines[1].dropFirst("You then asked: ".count)),
                    capabilityID: nil, origin: .typedQuestion, sessionID: nil, at: now)
                guard pending.confirmedPrompt(acknowledgment: answer) == request else { return proposed }
            }
            let kind = proposed["kind"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let repeatWord = proposed["repeat"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard ["", "reminder"].contains(kind),
                  proposed["inMinutes"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                  !MultiStepPlanRouting.likelyMultiStep(objective),
                  !objective.contains(where: { ";\n\r".contains($0) }) else { return proposed }
            // A single explicit nightly reminder owns its omitted recurrence. Keep the
            // authored clock: a different/ambiguous clock or explicit repeat is not ours.
            if dateText.isEmpty, repeatWord.isEmpty,
               let pattern = try? NSRegularExpression(pattern:
                    #"^\s*(?:please\s+)?every night at (\d{1,2}(?::\d{2})?\s*(?:pm)?)\s*,?\s*remind me to .+$"#,
                    options: .caseInsensitive),
               let match = pattern.firstMatch(in: objective, range: NSRange(objective.startIndex..., in: objective)),
               let clockRange = Range(match.range(at: 1), in: objective) {
                let clock = String(objective[clockRange]).trimmingCharacters(in: .whitespaces).lowercased()
                let nightClock = clock.hasSuffix("pm") || (ScheduleLocalTime.parse(clock)?.hour ?? 0) > 12
                    ? clock : clock + "pm"
                if let timing = ScheduleLocalTime.parse(nightClock), (18...23).contains(timing.hour),
                   let authored = proposed["time"].flatMap(ScheduleLocalTime.parse), authored == timing {
                    var grounded = proposed; grounded["repeat"] = "daily"
                    return grounded
                }
            }
            guard ["", "once"].contains(repeatWord), explicitlyRequests("remind", in: objective)
            else { return proposed }
            // Bind timing before the reminder's "to ..." body, never borrow a date
            // from the words it will say later. The existing single-day rule stays shared.
            let timing = objective.lowercased().components(separatedBy: " to ").first ?? objective
            if !dateText.isEmpty {
                guard let pattern = try? NSRegularExpression(pattern:
                    #"^\s*(?:please\s+)?remind me at (\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s+tomorrow\s*$"#,
                    options: .caseInsensitive),
                      let match = pattern.firstMatch(in: timing, range: NSRange(timing.startIndex..., in: timing)),
                      let clockRange = Range(match.range(at: 1), in: timing),
                      let requestedTime = ScheduleLocalTime.parse(String(timing[clockRange])),
                      proposed["time"].flatMap(ScheduleLocalTime.parse) == requestedTime
                else { return proposed }
            }
            return groundCalendarDay(proposed, request: timing, now: now, calendar: calendar)
        default: return proposed
        }
    }

    /// The relative day, on its own, so the calendar rule and the mail rule read as two rows
    /// of one table rather than as a chain of guards.
    private static func groundCalendarDay(
        _ proposed: [String: String], request: String, now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String: String] {
        guard request.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression) == nil,
              let day = relativeDay(in: request, now: now, calendar: calendar)
        else { return proposed }
        var grounded = proposed
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = components.year, let month = components.month, let dayNumber = components.day else {
            return proposed
        }
        grounded["date"] = String(format: "%04d-%02d-%02d", year, month, dayNumber)
        return grounded
    }

    /// Gmail's own field names, the ones the tool's parameter description advertises plus the
    /// rest of the common set. A field word is *not* content: the model writes `subject:` for
    /// something the user described in their own words, and that is the field doing its job.
    private static let mailFields: Set<String> = [
        "from", "to", "cc", "bcc", "subject", "in", "is", "has", "label", "list", "filename",
        "newer_than", "older_than", "after", "before", "larger", "smaller", "deliveredto",
        "category", "rfc822msgid", "category", "size",
    ]
    /// The fields whose value is a span of time rather than a word, so their value is checked
    /// against what the user said about time instead of token by token.
    private static let mailAgeFields: Set<String> = ["newer_than", "older_than", "after", "before"]
    private static let mailAccountNouns = Set(AgentAccountRead.accountNouns(.mail))
    /// What a person says when they mean a span of time. Deliberately generous: a false
    /// negative here drops a date filter the user did ask for.
    private static let timeWords: [String] = [
        "today", "yesterday", "week", "month", "year", "day", "days", "recent", "latest",
        "last", "past", "since", "before", "after", "earlier", "ago", "tonight", "morning",
        "tonight", "friday", "saturday", "sunday", "monday", "tuesday", "wednesday",
        "thursday", "hour", "hours", "minute", "minutes",
    ]

    private static func groundMailFilter(
        _ proposed: [String: String], _ request: String
    ) -> [String: String] {
        guard let written = proposed["query"] else { return proposed }
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return proposed }
        let said = request.lowercased()
        let kept = mailClauses(of: trimmed).filter { saidClause($0, in: said) }
        var grounded = proposed
        let keptText = kept.joined(separator: " OR ")
        if keptText.isEmpty {
            grounded.removeValue(forKey: "query")
        } else if keptText != trimmed {
            grounded["query"] = keptText
        }
        if grounded["query"] != written {
            Log.agent.info(
                "grounded search_email query “\(String(written.prefix(60)), privacy: .public)” to “\(String(keptText.prefix(60)), privacy: .public)”")
        }

        return grounded
    }

    /// One `OR`-separated clause. Gmail's `OR` is uppercase by convention, so a lowercase
    /// "or" is free text and is left inside the clause.
    private static func mailClauses(of query: String) -> [String] {
        query
            .replacingOccurrences(of: "\n", with: " OR ")
            .components(separatedBy: " OR ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Whether every content word of one clause is a word the user said, and whether a
    /// field the user did not name is being used only as a field.
    private static func saidClause(_ clause: String, in request: String) -> Bool {
        let parts = clause.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let fieldName = parts.count == 2
            ? String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
        // A colon that is not a field we know is part of the words — "Re: contract" is a
        // subject, not a field called "re".
        let isField = parts.count == 2 && mailFields.contains(fieldName)
        if mailAgeFields.contains(fieldName) {
            return timeWords.contains { request.contains($0) }
        }
        let content = isField ? String(parts[1]) : clause
        // P1-31b: “check my email” names the account, not the word to search
        // inside messages. Keep explicit topics/quoted words and Gmail fields.
        let bare = content.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
            .lowercased()
        if !isField, mailAccountNouns.contains(bare) {
            let noun = NSRegularExpression.escapedPattern(for: bare)
            let explicit = "\\b(?:about|containing|matching|word|term|phrase)\\s+"
                + noun + "\\b|[\"'“‘]" + noun + "[\"'”’]"
            guard request.range(of: explicit, options: .regularExpression) != nil else { return false }
        }
        let words = content
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        // A clause of nothing but wildcards and punctuation is a filter that matches
        // everything, which is the same as no filter — `subject:.*` is one.
        guard !words.isEmpty else { return false }
        return words.allSatisfy { request.contains($0) }
    }


    /// The one relative day a request names, or nil. Today, tomorrow, yesterday, or
    /// `on <weekday>` meaning the next such day — today when today is that day.
    private static func relativeDay(in request: String, now: Date, calendar: Calendar) -> Date? {
        let lowered = request.lowercased()
        var candidates: [Date] = []
        for (word, offset) in [("today", 0), ("tomorrow", 1), ("yesterday", -1)]
        where lowered.range(
            of: "\\b\(word)\\b", options: .regularExpression) != nil {
            candidates.append(calendar.date(byAdding: .day, value: offset, to: now) ?? now)
        }
        for (index, name) in calendar.weekdaySymbols.enumerated() {
            let weekday = (index + 1) % 7
            let spoken = name.lowercased()
            guard lowered.contains("on \(spoken)") || lowered.contains("on \(spoken.prefix(3))")
            else { continue }
            // The next such day, counting today as one of them: "on Tuesday" said on a
            // Tuesday is today, which is what a person means.
            let offset = (weekday - calendar.component(.weekday, from: now) + 7) % 7
            candidates.append(calendar.date(byAdding: .day, value: offset, to: now) ?? now)
        }
        // Two different relative days in one sentence is not a grounding question.
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    @MainActor
    static func run(
        user original: String,
        maxRounds: Int = defaultMaxRounds,
        maxCalls: Int = defaultMaxCalls,
        maxWallTime: Duration = defaultMaxWallTime,
        complete: @escaping (String) async throws -> String,
        execute: @escaping (AgentToolCall) async -> String
    ) async throws -> Outcome {
        var results: [String] = []
        var callCount = 0
        let rounds = clampedMaxRounds(maxRounds)
        let clock = ContinuousClock()
        let deadline = clock.now + maxWallTime
        var completedRounds = 0
        let completeBox = CallbackBox(complete)
        let executeBox = CallbackBox(execute)

        for round in 0..<rounds {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero {
                break
            }
            let priorResults = results
            let completionResult: Result<String, CompletionFailure>? = await withBoundedWait(remaining) {
                do {
                    return .success(try await completeBox.value(
                        userMessage(original: original, results: priorResults)
                    ))
                } catch {
                    return .failure(.message(error.localizedDescription))
                }
            }
            guard let completionResult else { break }
            if case .failure(.message(let message)) = completionResult {
                throw AgentError.backendUnavailable("Tool loop completion failed: \(message)")
            }
            guard case .success(let completion) = completionResult else { break }
            let calls = AgentToolCallParser.calls(in: completion)
            if calls.isEmpty {
                completedRounds = round + 1
                let reply = completion.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty {
                    return Outcome(reply: reply, rounds: round + 1, calls: callCount)
                }
                if !results.isEmpty {
                    return Outcome(
                        reply: results.joined(separator: "\n"),
                        rounds: round + 1,
                        calls: callCount
                    )
                }
                return Outcome(reply: "", rounds: round + 1, calls: callCount)
            }

            var roundTimedOut = false
            for call in calls {
                let callRemaining = clock.now.duration(to: deadline)
                if callCount >= maxCalls || callRemaining <= .zero {
                    roundTimedOut = callRemaining <= .zero
                    break
                }
                let call = grounded(call)
                guard let output = await withBoundedWait(callRemaining, {
                    await executeBox.value(call)
                }) else {
                    roundTimedOut = true
                    break
                }
                results.append(AgentPrompts.toolResult(name: call.name, output: output))
                callCount += 1
            }
            // A model response is only a completed round once its proposed tool calls
            // have returned. Do not report a full round when the deadline abandoned an
            // execute child that may still be unwinding.
            if !roundTimedOut { completedRounds = round + 1 }
            if clock.now >= deadline { break }
        }

        return Outcome(
            reply: results.joined(separator: "\n"),
            rounds: completedRounds,
            calls: callCount
        )
    }
}

extension AgentToolLoop {
    /// Inspect → click must make both calls. Not wired to `--selftest-realtime`
    /// and never calls `RunLog.record`.
    @MainActor
    @discardableResult
    static func runSelfTest() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        do {
            var executed: [String] = []
            let loop = try await AgentToolLoop.run(
                user: "Click Run",
                maxRounds: defaultMaxRounds,
                complete: { user in
                    if user.contains("computer.click returned") {
                        return "Done."
                    }
                    if user.contains("computer.inspect_ui returned") {
                        return #"<tool_call>{"name":"computer.click","arguments":{"id":"12"},"rationale":"click"}</tool_call>"#
                    }
                    return #"<tool_call>{"name":"computer.inspect_ui","arguments":{},"rationale":"look"}</tool_call>"#
                },
                execute: { call in
                    executed.append(call.name)
                    switch call.name {
                    case "computer.inspect_ui": return "[12] Run\n[18] Search"
                    case "computer.click": return "Clicked"
                    default: return "unknown"
                    }
                }
            )
            check("inspect→click loop did not finish in plain language", loop.reply == "Done.")
            check("inspect→click loop used the wrong number of rounds", loop.rounds == 3)
            check("inspect→click loop dropped a tool call", loop.calls == 2)
            check(
                "a two-call inspect/click fixture stopped after one call",
                executed == ["computer.inspect_ui", "computer.click"]
            )
        } catch {
            failures.append("tool loop failed: \(error.localizedDescription)")
        }

        do {
            var roundsSeen = 0
            let capped = try await AgentToolLoop.run(
                user: "loop",
                maxRounds: 20,
                maxCalls: 100,
                complete: { _ in
                    roundsSeen += 1
                    return #"<tool_call>{"name":"computer.inspect_ui","arguments":{},"rationale":"look"}</tool_call>"#
                },
                execute: { _ in "ok" }
            )
            check("maxRounds was not bounded to 8", capped.rounds == maxRoundsBound)
            check("a 20-round ask ran more than eight completions", roundsSeen == maxRoundsBound)
        } catch {
            failures.append("round cap failed: \(error.localizedDescription)")
        }

        do {
            let bounded = try await AgentToolLoop.run(
                user: "deadline",
                maxWallTime: .milliseconds(20),
                complete: { _ in
                    try await Task.sleep(for: .milliseconds(200))
                    return "too late"
                },
                execute: { _ in "unreachable" }
            )
            check("completion deadline was not enforced", bounded.rounds == 0 && bounded.calls == 0)
        } catch {
            failures.append("deadline fixture failed: \(error.localizedDescription)")
        }

        do {
            let bounded = try await AgentToolLoop.run(
                user: "tool deadline",
                maxWallTime: .milliseconds(20),
                complete: { _ in
                    #"<tool_call>{"name":"computer.inspect_ui","arguments":{},"rationale":"look"}</tool_call>"#
                },
                execute: { _ in
                    try? await Task.sleep(for: .milliseconds(200))
                    return "too late"
                }
            )
            check(
                "tool execution deadline was not reflected in completed rounds",
                bounded.rounds == 0 && bounded.calls == 0
            )
        } catch {
            failures.append("tool deadline fixture failed: \(error.localizedDescription)")
        }

        for failure in failures {
            print("TOOLLOOP_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "TOOLLOOP_OK" : "TOOLLOOP_FAILED")
        return failures.isEmpty
    }
}
