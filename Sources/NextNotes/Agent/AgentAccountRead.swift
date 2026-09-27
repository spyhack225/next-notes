import Foundation

/// The tool that reads each of the three accounts, read out of the turn's own manifest.
///
/// It is a manifest lookup and not a table, which is the whole point: a class whose read the
/// manifest did not select this turn returns nil, so the guard cannot propose a tool the turn
/// was never offered. That is the same rule the executor enforces, read through the same value.
enum AccountReadTools {
    static func toolID(for intent: AgentIntentClass, manifest: AgentCapabilityManifest) -> String? {
        let id: String
        switch intent {
        case .mail: id = "search_email"
        case .calendar: id = "get_agenda"
        case .drive: id = "find_drive_files"
        default: return nil
        }
        return manifest.entry(named: id)?.id
    }
}

/// An answer about the person's own mail, calendar or Drive has to come from reading it.
///
/// On 27 September the Agent listed three emails — senders, subjects, all of it — that no read
/// produced, and answered "is this coming from my emails?" with *"I pulled the latest messages
/// directly from your inbox."* Summarising email had succeeded 0 times in about 11 attempts.
/// Nothing failed loudly: the tools were registered, the switches were on, and the reply read
/// like an answer.
///
/// **The obvious fix was built, measured and deleted, and this is designed against its results.**
/// `RealtimeAgent+ToolLoop.swift` still carries the comment: a class-based "answered as though
/// something was looked up" check detected every one of these turns and was a net loss, because
///
/// 1. re-planning with a note did not change the answer — the model answers prose again, whatever
///    the note says (the same measurement as the read-miss repair);
/// 2. it replaced two **correct** answers with "I haven't checked that yet." — K01 after
///    `meeting.decisions` and A04 after `computer.active_app`, because it could not reliably tell
///    a grounded answer from an ungrounded one; and
/// 3. its note turned a round that was about to call `draft_email` into a round that wrote the
///    draft out as text.
///
/// So the three rules this file follows are the inverse of that design. **Narrow**: only the
/// person's own three accounts, never `.meetings` / `.knowledge` / `.screen` / `.memory`, which is
/// where result 2 happened. **The app reads, the model is not asked to**: instead of a re-plan
/// note (result 1) the loop runs the class's own read through `ToolStepRunner` and the always-
/// affordable final round answers from the real result. **Only on a final round** (result 3), so
/// a turn that parsed a call is never touched.
///
/// Everything here is pure. The loop owns when to ask, and the executor owns what runs.
enum AgentAccountRead {
    /// The three accounts this is about, and nothing else. A `Set` so the caller can intersect
    /// it with `manifest.selectedIntents` rather than hand-compare three values.
    static let classes: Set<AgentIntentClass> = [.mail, .calendar, .drive]

    /// The read each class gets when the person asked about it in general, and the tool that
    /// performs it. `nil` for a class with no default read.
    static func defaultRead(for intent: AgentIntentClass, request: String,
                            now: Date = Date()) -> (toolID: String, arguments: [String: String])? {
        switch intent {
        case .mail:
            // P1-09's own default: the newest messages, which is what "summarise my emails"
            // means and what the empty query means. A query is the *model's* to write; this is
            // the floor that answers when the model wrote none.
            return ("search_email", ["query": "in:inbox"])
        case .calendar:
            // The date the request names, else today — through the same grounder the planner's
            // own `get_agenda` arguments go through, so "tomorrow" is resolved by one
            // implementation rather than two. `AgentNow`'s block is what makes "today" a word
            // the model can use without inventing a date for it.
            return ("get_agenda",
                    AgentToolLoop.groundedArguments(
                        for: "get_agenda", proposed: [:], request: request, now: now))
        case .drive:
            // The request's own nouns, because a Drive search with no query answers nothing and
            // a Drive search with a wrong one invents a file.
            let nouns = request
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { $0.lowercased() }
                .filter { $0.count > 3 && !Self.stopWords.contains($0) }
            guard nouns.isEmpty == false else { return nil }
            return ("find_drive_files", ["query": nouns.prefix(3).joined(separator: " ")])
        default:
            return nil
        }
    }

    private static let stopWords: Set<String> = [
        "please", "would", "could", "should", "there", "here", "that", "this", "with",
        "from", "about", "what", "when", "where", "which", "them", "they", "then", "your",
        "have", "does", "show", "find", "list", "give", "tell", "into", "just", "also",
    ]

    /// Whether this turn is one of them. Four conditions, and all four hold or it does not fire.
    ///
    /// - Parameters: `selectedIntents` is the turn's manifest; `completedThisTurn` the runner's
    ///   own list; `completedThisSession` the set `RealtimeAgent` keeps for the conversation.
    ///   The session half is what stops turn 2 of a two-turn conversation from re-reading an
    ///   account turn 1 already read.
    static func pendingRead(
        reply: String, selectedIntents: Set<AgentIntentClass>,
        completedThisTurn: [String], completedThisSession: Set<String>,
        toolIDFor: (AgentIntentClass) -> String?, request: String, now: Date = Date()
    ) -> (intent: AgentIntentClass, toolID: String, arguments: [String: String])? {
        // 1. One of the person's own three accounts, and only those.
        let candidates = selectedIntents.intersection(classes).sorted { $0.rawValue < $1.rawValue }
        guard candidates.isEmpty == false else { return nil }
        // 2. Nothing of that class has run. The class's tool is what decides, not the class:
        //    a `read_email` after a `search_email` is still a read of the same account.
        for intent in candidates {
            guard let toolID = toolIDFor(intent) else { continue }
            if completedThisTurn.contains(toolID) { continue }
            if completedThisSession.contains(toolID) { continue }
            // 3. The reply is final — the loop only asks here, after a round that parsed no
            //    call, so a turn about to call `draft_email` never reaches this.
            // 4. The reply presents that account, in one of two shapes.
            guard presents(intent, reply) else { continue }
            guard let read = defaultRead(for: intent, request: request, now: now) else { continue }
            return (intent, read.toolID, read.arguments)
        }
        return nil
    }

    /// The two shapes a reply can present an account in, and they are both needed.
    ///
    /// Naming it is necessary and **not sufficient** — and the second half is what the task's
    /// own G8 case is about. *"Your calendar is a good place to keep that — somewhere nobody
    /// would move it"* names the calendar, is not a question, and asserts nothing whatsoever
    /// about what is in it; it is advice. A fabricated answer asserts **contents**. So naming
    /// the account has to arrive with a word about what is in it, or with a list shaped like
    /// what is in it.
    ///
    /// The distinction is drawn on words rather than on a shape heuristic because this is a gate
    /// that acts on a model answer: "your inbox" and "emails" are both English, both
    /// case-foldable, and neither can be confused with the other. A length or a token count
    /// would classify "Want to see them?" and "Here are the six" identically, which is the
    /// mistake that silenced the app on 2026-09-22.
    static func presents(_ intent: AgentIntentClass, _ reply: String) -> Bool {
        // A question is not a claim. "Want to see the latest messages?" names the account
        // and asserts nothing, and treating it as one is the gate that silenced the app.
        guard isQuestion(reply) == false else { return false }
        // Two separate questions, because they have separate answers. *Whose* account is being
        // talked about, and *what* is being said about its contents.
        if namesAccount(intent, reply), describesContents(intent, reply) { return true }
        // The second shape is the owner's worst case, which said neither: three bullets, each a
        // sender and a subject. One line is not a fabricated mailbox — a person writes sentences
        // about a single thing, and refusing those would be P1-14's result 2 again.
        return listItems(reply) >= 2 && looksLikeEntries(reply, intent: intent)
    }

    /// The account nouns, one list per class.
    ///
    /// These were **fixed phrases** first — "your inbox", "your emails" — and they missed
    /// *"Checking your latest emails right away"*: O02's own reply on 2026-09-27, which names
    /// the account with a modifier in between and promises a read that never ran. A list of the
    /// modifiers anyone can think of is a list that will be wrong again, so the phrase became a
    /// possessive and a window (see `namesAccount`).
    static func accountNouns(_ intent: AgentIntentClass) -> [String] {
        switch intent {
        case .mail: ["email", "emails", "mail", "inbox", "message", "messages"]
        case .calendar: ["calendar", "schedule", "agenda", "day", "meeting", "meetings",
                         "event", "events"]
        case .drive: ["drive", "files", "folders", "documents", "docs"]
        default: []
        }
    }

    /// Words about what is *in* the account, as opposed to where it is. The account noun itself
    /// is deliberately **not** here: "emails" is both a place and a content word, and letting it
    /// answer both questions is what made G8 fire on *"Your calendar is a good place to keep
    /// that"*. The two questions are kept apart by position instead — the account must be held
    /// by a possessive, the content word may be anywhere.
    static func contentWords(_ intent: AgentIntentClass) -> [String] {
        switch intent {
        case .mail: ["new", "unread", "sent", "draft", "drafts", "latest", "recent", "waiting"]
        case .calendar: ["booked", "scheduled", "free", "busy", "today", "tomorrow",
                         "happening", "coming"]
        case .drive: ["shared", "recent", "newest", "latest", "stored"]
        default: []
        }
    }

    /// Whether the reply holds the account as **the person's**: a possessive, then the account
    /// noun within a small window. Two words is enough for "your latest emails" and short
    /// enough that "your calendar is a good place" cannot reach a mail noun three words on.
    static func namesAccount(_ intent: AgentIntentClass, _ reply: String) -> Bool {
        let words = words(of: reply)
        let nouns = Set(accountNouns(intent))
        let possessives: Set<String> = ["your", "my", "our"]
        for (index, word) in words.enumerated() where possessives.contains(word) {
            for step in 1...2 {
                let next = index + step
                guard next < words.count else { break }
                if nouns.contains(words[next]) { return true }
            }
        }
        return false
    }

    /// Whether the reply says anything about what is *in* the account, as opposed to where the
    /// account is or what it should be used for.
    ///
    /// Three ways to answer yes, and each was added because a real reply on 2026-09-27 needed
    /// it. The first two are content; the third is a **promise**:
    ///
    /// - A content word is present. *"Checking your **latest** emails right away."*
    /// - The account noun appears **more than once**. *"Here are the six **emails** sitting in
    ///   your **inbox**."* has no modifier at all, and the second mention is what says the
    ///   account is being talked *about* rather than *used as a place*.
    /// - The reply **promises to go and look**: a first-person subject and a read verb, with
    ///   the account held by a possessive. *"Of course. I'll check your inbox right away."* and
    ///   *"Yes, I pulled the last few messages."* are the same sentence, and between them they
    ///   are three of the five failures in the 27 September log.
    ///
    /// The promise rule is a verb stem rather than a fixed phrase for the same reason the
    /// possessive is: a list of the ways a model can say it is a list that will be wrong again.
    /// **It is safe to be broad here** in a way it would not be in a gate that removes an answer
    /// — this one only ever *adds a read*, and a read cannot replace a correct sentence. G8
    /// holds because advice makes no first-person promise about reading anything.
    static func describesContents(_ intent: AgentIntentClass, _ reply: String) -> Bool {
        let present = words(of: reply)
        if contentWords(intent).contains(where: { present.contains($0) }) { return true }
        let nouns = Set(accountNouns(intent))
        if present.filter { nouns.contains($0) }.count >= 2 { return true }
        return promisesToRead(present)
    }

    /// The read verbs, as stems, so "check", "checking", "checked" and "'ll check" are one
    /// entry. `fetch`/`grab` are here because "I'll grab those" is the same promise.
    static let readVerbStems: Set<String> = [
        "check", "read", "pull", "look", "fetch", "grab", "open", "search", "review",
    ]

    private static func promisesToRead(_ present: [String]) -> Bool {
        // A promise looks forward and a denial looks back, and the difference is the whole
        // reason this rule does not react to the app's own honest sentence. *"I haven't looked
        // at your email yet."* has a first person and a read verb and is the **output** of this
        // guard's other branch; a rule that read it as a promise would re-read in answer to its
        // own honest sentence, forever. So a negation anywhere in the reply settles it — which
        // is a general property rather than a denylist of the three sentences this file writes.
        //
        // Matched as **stems with a prefix test**, like the verbs, and the reason is the
        // tokenizer: words are split on anything that is not a letter or a digit, so "haven't"
        // arrives here as `"haven"`. A fixed list containing the contraction would not have
        // matched the one sentence this rule exists not to match.
        guard present.contains(where: { word in denialStems.contains { word.hasPrefix($0) } })
            == false else { return false }
        let firstPerson: Set<String> = ["i", "im", "ill", "ive"]
        guard present.contains(where: { firstPerson.contains($0) }) else { return false }
        return present.contains { word in
            readVerbStems.contains { word.hasPrefix($0) }
        }
    }

    /// Stems, because of the apostrophe. `not` is the noisiest and is deliberately there: a
    /// false "this is a denial" only makes the guard quieter, and a read that did not happen is
    /// the cheaper error than one that did.
    static let denialStems: Set<String> = [
        "haven", "hasn", "hadn", "didn", "doesn", "don", "won", "wouldn", "isn", "aren",
        "cannot", "cant", "couldn", "shouldn", "never", "not", "no",
    ]

    /// Lowercased word tokens. Punctuation is the separator and nothing else.
    static func words(of text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Two or more lines that begin like a list item.
    static func listItems(_ text: String) -> Int {
        text.split(separator: "\n").reduce(into: 0) { count, line in
            if isListItem(line.trimmingCharacters(in: .whitespaces)) { count += 1 }
        }
    }

    /// A sender-and-subject line, or a time range. Both are shapes a person's calendar and inbox
    /// actually have and a model inventing them imitates; neither is a shape a person writes
    /// advice in, which is what keeps G8 ("your calendar is a good place to keep that") out.
    static func looksLikeEntries(_ text: String, intent: AgentIntentClass) -> Bool {
        var sender = false
        var timeRange = false
        for line in text.split(separator: "\n") {
            let lowered = line.lowercased()
            if lowered.contains("@") { sender = true }
            // A clock time followed by an en dash and another one, or a " - " range.
            if lowered.range(of: #"\d{1,2}:\d{2}\s*[–-]\s*\d{1,2}:\d{2}"#,
                             options: .regularExpression) != nil { timeRange = true }
            if intent == .mail, lowered.contains("subject:") { sender = true }
        }
        return sender || timeRange
    }

    /// Whether the reply is *asking* rather than telling.
    ///
    /// Read off the last non-empty **line**, and a line that is a list item is not the reply's
    /// own sentence. That detail is not cosmetic: the owner's fabricated mailbox ended
    /// `- Cyril <cyril@example.com> — Dinner tomorrow?`, so a rule that looked at the last
    /// character of the whole text read a three-line invention as a question and exempted the
    /// exact turn this guard exists for. A person's sentence and a message subject are not the
    /// same object, and only one of them is a question.
    static func isQuestion(_ text: String) -> Bool {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard isListItem(line) == false else { return false }
        return line.hasSuffix("?") && line.contains("?")
    }

    /// A leading `-`, `•`, `*`, or a number followed by `.` or `)`.
    static func isListItem(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if "-•*".contains(first) { return true }
        let digits = line.prefix { $0.isNumber }
        if digits.isEmpty == false,
           let mark = line.dropFirst(digits.count).first, ".)".contains(mark) { return true }
        return false
    }

    // MARK: - The provenance question

    /// "Is this coming from my emails?" asked after an answer nothing was read for. The whole
    /// answer is in the record, not in another model round, and the record is short: a read ran
    /// in this conversation or it did not.
    ///
    /// Matched by exact signature rather than by a topic, because this is a gate that *removes* a
    /// model answer, and AGENTS.md's rule for those is a fixed list — never a length, a token
    /// count or a shape heuristic.
    static let provenanceQuestions = [
        "is this from", "is this coming from", "did you actually",
        "where did you get", "where does that come from", "how do you know that",
        "is that real", "did you read",
    ]

    static func asksProvenance(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return provenanceQuestions.contains { lowered.contains($0) }
    }

    /// What the person is told when a read is not allowed to run by itself. A statement, not a
    /// question, so a pending action can carry it and "yes" can run the read — and it says what
    /// has not happened rather than what has.
    static let notReadYet = "I haven't looked at your email yet."

    static func notReadYet(_ intent: AgentIntentClass) -> String {
        switch intent {
        case .mail: notReadYet
        case .calendar: "I haven't looked at your calendar yet."
        case .drive: "I haven't looked at your Drive yet."
        default: "I haven't looked yet."
        }
    }
}
