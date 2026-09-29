import Foundation

/// One canonical request, its expectation and the words the final reply must (not) contain.
///
/// Data only. The live eval (`--selftest-toolloop-live`) sends `turns` in order through
/// `RealtimeAgent.handle(_, source: .text)` on the real Agent-role model; the grader reads
/// `expectation`, the mention lists and the case-specific rule. Nothing here is user data:
/// every fixture answer lives in `ToolLoopLiveEvalFixtures`.
struct LiveEvalCase: Sendable {
    let id: String
    /// Sent in order through `handle(_, source: .text)`.
    let turns: [String]
    /// Sent once more, only when the last reply's final non-space character is "?".
    let followUpIfQuestion: String?
    let expectation: Expectation
    /// Every group needs at least one case-insensitive hit in the final reply.
    let mustMention: [[String]]
    let mustNotMention: [String]
    let maxReplyCharacters: Int?
    let dynamicMention: DynamicMention?
    let extraRule: ExtraRule?
    /// Where the case comes from (a real turn, a report section, a control).
    let evidence: String
    /// The task that should turn it green.
    let expectedFix: String
    /// False for cases later phases append: they print their own line and never change the
    /// `n/30` score or the pass bar. The 30 canonical cases are all scored.
    let scored: Bool

    init(
        id: String,
        turns: [String],
        followUpIfQuestion: String? = nil,
        expectation: Expectation,
        mustMention: [[String]] = [],
        mustNotMention: [String] = [],
        maxReplyCharacters: Int? = nil,
        dynamicMention: DynamicMention? = nil,
        extraRule: ExtraRule? = nil,
        evidence: String,
        expectedFix: String,
        scored: Bool = true
    ) {
        self.id = id
        self.turns = turns
        self.followUpIfQuestion = followUpIfQuestion
        self.expectation = expectation
        self.mustMention = mustMention
        self.mustNotMention = mustNotMention
        self.maxReplyCharacters = maxReplyCharacters
        self.dynamicMention = dynamicMention
        self.extraRule = extraRule
        self.evidence = evidence
        self.expectedFix = expectedFix
        self.scored = scored
    }
}

/// A fact the final reply should name that only the live machine knows.
enum DynamicMention: Sendable {
    /// The account holder's first name, from `AgentGroundingFacts.userFullName()`.
    case userFirstName
    /// A three-letter-or-longer token of the answering model's name.
    case modelName
    /// Today (P1-27's O07). The date is read when the case is **graded**, not when this list
    /// was built, so a run that crosses local midnight is not judged against yesterday.
    case todayDate
}

/// A case-specific rule the general pattern lists cannot express.
enum ExtraRule: Sendable {
    /// M05: the turn-2 reply must differ from the turn-1 reply.
    case distinctReplies
    /// A01: the term must appear in a navigate url or in a `browser.fill` value.
    case searchTermReached(String)
    /// A02: click the named video, or navigate directly to its URL.
    case browserFollowThrough(String)
    /// P1-27's O06: nothing ran from the second turn on. `answerOnly` is judged over the whole
    /// case, so a two-turn case cannot say "the first turn may look, the second must not" —
    /// permitting the first turn's find in `allowed` would permit it in the greeting too.
    case noToolFromSecondTurn
}

/// What a case needs the fixture log to show. Every set names canonical tool ids.
enum Expectation: Sendable {
    /// At least one of `anyOf`, and every one of `allOf`, must have been called.
    case tools(
        anyOf: Set<String>,
        allOf: Set<String> = [],
        allowed: Set<String> = [],
        forbidden: Set<String> = [],
        checks: [ArgumentCheck] = []
    )
    /// No tool, except the ones in `allowed`.
    case answerOnly(allowed: Set<String> = [])
    /// A find tool, then either an email tool or a question asking for the address.
    case compound(first: Set<String>, then: Set<String>, orQuestionMentioning: [String])
}

/// One argument the fixture log must show on one call.
struct ArgumentCheck: Sendable {
    let toolID: String
    /// The argument name, or "*" for any argument value of that call.
    let key: String
    let rule: Rule

    enum Rule: Sendable {
        case equalsToday
        case equalsTomorrow
        /// Any value of the call (key "*") or the named key contains one of these,
        /// case-insensitively.
        case containsAny([String])
    }
}

/// The 30 canonical requests (P1-01 step 8), then the owner-log set (P1-27).
///
/// The thirty are frozen: later phases append `scored: false` cases beside them, never inside
/// them, and a full run executes both. `TOOLLOOP_LIVE_SCORE` counts only the thirty; the
/// owner set is reported by `TOOLLOOP_LIVE_OWNER` and gated by the Phase 1 exit.
enum LiveEvalCases {
    /// Tools tolerated in every case: a model checking context first is not wrong.
    static let toleratedToolIDs: Set<String> = ["memory.recall", "schedule.list", "meeting.current"]

    /// The fixed per-task subset (P1-01 step 8b). Never edit this list to make a gate pass.
    static let quickIDs = ["C01", "C04", "M03", "M04", "M05", "K01", "R02", "F03", "A02", "N04"]

    /// The owner-log set (P1-27), in the order the `TOOLLOOP_LIVE_OWNER` line counts them.
    ///
    /// Named here rather than derived from `!scored`, so this line's denominator is a fixed
    /// list: a later phase appends its own unscored set beside it (P4-04's extra five) and
    /// must not move this number. Never edit it to make a gate pass either — the same rule
    /// `quickIDs` lives under.
    static let ownerLogIDs = [
        "O01", "O02", "O03", "O04", "O05", "O06", "O07", "O08", "O09", "O10",
    ]

    /// What the eval's mailbox can be summarised from. One group, not one per sender: the
    /// question a mail case asks is "did the reply come from something only a read could have
    /// produced", and six senders *and* six subjects in one list is that question. Splitting
    /// it per sender would be a claim about which message the model happened to lead with.
    static let mailWords = [
        "marcus", "ana", "cyril", "github", "stripe",
        "pricing", "deck", "invoice", "dinner", "contract", "ci passed",
    ]

    static let all: [LiveEvalCase] = [
        LiveEvalCase(
            id: "C01",
            turns: ["What's on my calendar today?"],
            expectation: .tools(
                anyOf: ["get_agenda"],
                checks: [ArgumentCheck(toolID: "get_agenda", key: "date", rule: .equalsToday)]),
            mustMention: [["standup", "budget review", "marcus"]],
            evidence: "B §1 core tool",
            expectedFix: "baseline should pass"),

        LiveEvalCase(
            id: "C02",
            turns: ["What do I have tomorrow?"],
            expectation: .tools(
                anyOf: ["get_agenda"],
                checks: [ArgumentCheck(toolID: "get_agenda", key: "date", rule: .equalsTomorrow)]),
            mustMention: [["dentist", "design sync", "cyril"]],
            evidence: "relative dates",
            expectedFix: "P1-04"),

        LiveEvalCase(
            id: "C03",
            turns: ["Am I free at 3pm tomorrow?"],
            expectation: .tools(
                anyOf: ["get_agenda"],
                checks: [ArgumentCheck(toolID: "get_agenda", key: "date", rule: .equalsTomorrow)]),
            mustMention: [["design sync"]],
            evidence: "relative dates",
            expectedFix: "P1-04"),

        LiveEvalCase(
            id: "C04",
            turns: ["Summarize my last emails and list me my events for tomorrow"],
            expectation: .tools(
                anyOf: [],
                allOf: ["search_email", "get_agenda"],
                allowed: ["read_email"],
                checks: [ArgumentCheck(toolID: "get_agenda", key: "date", rule: .equalsTomorrow)]),
            mustMention: [["pricing", "deck", "invoice"], ["dentist", "design sync"]],
            evidence: "09-22 00:58Z",
            expectedFix: "P1-02, P1-06"),

        LiveEvalCase(
            id: "M01",
            turns: ["Summarize my last 5 emails"],
            expectation: .tools(anyOf: ["search_email"], allowed: ["read_email"]),
            mustMention: [["pricing"], ["deck", "ana"]],
            evidence: "B D11",
            expectedFix: "P1-09"),

        LiveEvalCase(
            id: "M02",
            turns: ["Any new emails from Marcus?"],
            expectation: .tools(
                anyOf: ["search_email"],
                allowed: ["read_email"],
                checks: [ArgumentCheck(toolID: "search_email", key: "query",
                                       rule: .containsAny(["marcus"]))]),
            mustMention: [["pricing", "contract"]],
            evidence: "B D7 phrasing",
            expectedFix: "P1-02/P1-03"),

        LiveEvalCase(
            id: "M03",
            turns: ["Check my email, check the last email and then do a summary"],
            expectation: .tools(anyOf: ["search_email"], allowed: ["read_email"]),
            mustMention: [["pricing"]],
            evidence: "09-15 01:13Z",
            expectedFix: "P1-06, P1-09"),

        LiveEvalCase(
            id: "M04",
            turns: ["Draft an email to ana@example.com saying I'll send the deck on Friday"],
            expectation: .tools(
                anyOf: ["draft_email"],
                forbidden: ["send_email"],
                checks: [ArgumentCheck(toolID: "draft_email", key: "to",
                                       rule: .containsAny(["ana@example.com"]))]),
            mustMention: [["draft", "approv", "ready", "review"]],
            evidence: "write token cap",
            expectedFix: "P1-02/P1-04"),

        LiveEvalCase(
            id: "M05",
            turns: ["Summarize my last emails", "yes"],
            expectation: .tools(anyOf: ["search_email"], allowed: ["read_email"]),
            mustMention: [["pricing", "deck"]],
            extraRule: .distinctReplies,
            evidence: "09-22 five-denial loop",
            expectedFix: "P1-02"),

        LiveEvalCase(
            id: "K01",
            turns: ["What did we decide in the last meeting?"],
            expectation: .tools(
                anyOf: ["meeting.decisions", "meeting.recent_context", "meeting.search", "search_knowledge"],
                allowed: ["timeline", "expand_node", "meeting.transcript"]),
            mustMention: [["october 14", "oct 14", "14 october"]],
            evidence: "B D8",
            expectedFix: "P1-03"),

        LiveEvalCase(
            id: "K02",
            turns: ["What action items do I have from my last meeting?"],
            expectation: .tools(
                anyOf: ["meeting.action_items", "meeting.recent_context", "search_knowledge",
                        "meeting.search"]),
            mustMention: [["budget"]],
            evidence: "meeting action items",
            expectedFix: "P1-03"),

        LiveEvalCase(
            id: "K03",
            turns: ["What did Sarah say about the budget?"],
            expectation: .tools(
                anyOf: ["meeting.search", "search_knowledge", "meeting.transcript",
                        "meeting.recent_context"]),
            mustMention: [["10%", "ten percent", "buffer"]],
            evidence: "B D8 \"Sarah said\"",
            expectedFix: "P1-03"),

        LiveEvalCase(
            id: "R01",
            turns: ["Remind me at 9 tomorrow to call the bank"],
            followUpIfQuestion: "yes",
            expectation: .tools(
                anyOf: ["schedule.create"],
                checks: [ArgumentCheck(toolID: "schedule.create", key: "*",
                                       rule: .containsAny(["bank"]))]),
            mustMention: [["bank"]],
            evidence: "T8/Q6",
            expectedFix: "P1-02 (typed pending)"),

        LiveEvalCase(
            id: "R02",
            turns: ["Every night at 10, remind me to put the book out"],
            followUpIfQuestion: "okay",
            expectation: .tools(
                anyOf: ["schedule.create"],
                checks: [ArgumentCheck(toolID: "schedule.create", key: "*",
                                       rule: .containsAny(["book"]))]),
            mustMention: [["book", "10"]],
            evidence: "09-23 06:37Z leak",
            expectedFix: "P0-04, P1-04"),

        LiveEvalCase(
            id: "R03",
            turns: ["What's on my to-do list for today?"],
            expectation: .tools(
                anyOf: ["schedule.list", "get_agenda", "meeting.action_items", "search_knowledge"]),
            mustMention: [["budget", "standup", "reminder", "nothing"]],
            evidence: "09-14 14:28Z",
            expectedFix: "P1-03"),

        LiveEvalCase(
            id: "Y01",
            turns: ["Remember that my brother's name is Cyril"],
            expectation: .tools(
                anyOf: ["memory.remember", "memory.update"],
                checks: [ArgumentCheck(toolID: "memory.remember", key: "*",
                                       rule: .containsAny(["cyril"])),
                         ArgumentCheck(toolID: "memory.update", key: "*",
                                       rule: .containsAny(["cyril"]))]),
            mustMention: [["cyril"]],
            evidence: "memory write",
            expectedFix: "baseline"),

        LiveEvalCase(
            id: "Y02",
            turns: ["What do you know about me?"],
            expectation: .tools(anyOf: ["memory.recall", "search_knowledge"]),
            mustMention: [["cyril", "productflo", "ceo"]],
            evidence: "09-23 06:39Z",
            expectedFix: "P1-03"),

        LiveEvalCase(
            id: "F01",
            turns: ["Find the pricing document"],
            expectation: .tools(
                anyOf: ["filesystem.find", "filesystem.search", "find_drive_files"],
                allowed: ["filesystem.reveal"]),
            mustMention: [["pricing"]],
            evidence: "shortcut regression guard",
            expectedFix: "baseline"),

        LiveEvalCase(
            id: "F02",
            turns: ["What projects am I working on?"],
            expectation: .tools(
                anyOf: ["filesystem.tree", "filesystem.find", "filesystem.search",
                        "search_knowledge", "memory.recall"]),
            mustMention: [["next notes", "garden"]],
            evidence: "09-20 20:43Z",
            expectedFix: "P1-03"),

        LiveEvalCase(
            id: "F03",
            turns: ["Find the pricing document and email it to Marcus"],
            expectation: .compound(
                first: ["filesystem.find", "filesystem.search", "find_drive_files"],
                then: ["draft_email", "send_email"],
                orQuestionMentioning: ["address", "email"]),
            evidence: "B D9",
            expectedFix: "P1-08"),

        LiveEvalCase(
            id: "A01",
            turns: ["Open youtube and search cats"],
            expectation: .tools(
                anyOf: ["browser.navigate"],
                allowed: ["browser.fill", "browser.click", "browser.snapshot", "computer.open_app"],
                checks: [ArgumentCheck(toolID: "browser.navigate", key: "url",
                                       rule: .containsAny(["youtube.com"]))]),
            extraRule: .searchTermReached("cats"),
            evidence: "T10",
            expectedFix: "P1-08"),

        LiveEvalCase(
            id: "A02",
            turns: ["Open youtube and play the latest Cortech video"],
            expectation: .tools(
                anyOf: ["browser.navigate"],
                allowed: ["browser.snapshot", "browser.click", "browser.fill", "computer.open_app"]),
            extraRule: .browserFollowThrough("cortech"),
            evidence: "T10 \"Opened youtube.com.\"",
            expectedFix: "P1-08"),

        LiveEvalCase(
            id: "A03",
            turns: ["Open Safari"],
            expectation: .tools(
                anyOf: ["computer.open_app"],
                checks: [ArgumentCheck(toolID: "computer.open_app", key: "name",
                                       rule: .containsAny(["safari"]))]),
            evidence: "shortcut regression guard",
            expectedFix: "baseline"),

        LiveEvalCase(
            id: "A04",
            turns: ["Which app is frontmost?"],
            expectation: .tools(anyOf: ["computer.active_app"]),
            mustMention: [["safari"]],
            evidence: "baseline",
            expectedFix: "baseline"),

        LiveEvalCase(
            id: "N01",
            turns: ["Who am I?"],
            expectation: .answerOnly(),
            mustNotMention: ["alter ego", "i'm {assistant}", "i am {assistant}"],
            dynamicMention: .userFirstName,
            evidence: "09-23 17:18Z",
            expectedFix: "P4-03 (may stay red in Phase 1)"),

        LiveEvalCase(
            id: "N02",
            turns: ["What model are you running on?"],
            expectation: .answerOnly(),
            dynamicMention: .modelName,
            evidence: "Q4",
            expectedFix: "expected red until P4-03"),

        LiveEvalCase(
            id: "N03",
            turns: ["What's the capital of Australia?"],
            expectation: .answerOnly(),
            mustMention: [["canberra"]],
            evidence: "control",
            expectedFix: "baseline"),

        LiveEvalCase(
            id: "N04",
            turns: ["What can you do?"],
            expectation: .answerOnly(),
            mustMention: [["email", "mail"], ["calendar"]],
            evidence: "Q13",
            expectedFix: "P1-03"),

        LiveEvalCase(
            id: "N05",
            turns: ["Thanks, that's all for now."],
            expectation: .answerOnly(),
            maxReplyCharacters: 160,
            evidence: "filler control",
            expectedFix: "baseline"),

        LiveEvalCase(
            id: "P01",
            turns: ["Ask the agent what's on my calendar tomorrow"],
            expectation: .tools(
                anyOf: ["get_agenda"],
                checks: [ArgumentCheck(toolID: "get_agenda", key: "date", rule: .equalsTomorrow)]),
            mustMention: [["dentist", "design sync"]],
            evidence: "T11",
            expectedFix: "P1-08"),

        // MARK: P1-27 — the owner's own failed requests
        //
        // Ten cases the gate reads **beside** the thirty, never inside them. They exist
        // because the thirty were written from reports, and none of them is the two-turn
        // "summarise my emails" → "is this coming from my emails?" the owner actually typed on
        // 27 September — when the Agent listed three emails, with senders and subjects, that no
        // read produced, and said it had pulled them from the inbox.
        //
        // `scored: false` is load-bearing in two directions. They stay out of the `n/30` and
        // out of the pass bar, so a red owner case can never be tuned away by editing the
        // thirty — and the flag's own verdict stays a statement about the thirty. What reads
        // them is `TOOLLOOP_LIVE_OWNER` and the Phase 1 exit gate, both of which are recorded
        // in `STATUS.md` rather than asserted here.
        //
        // Two things these cases are **not**. They add no rows to the mailbox or the calendar:
        // the corpus is the six messages the thirty have always been answered from, because a
        // corpus fitted to these turns would make the gate a description of the fixtures. And
        // they introduce no new verdict class — O01's invented list is caught by
        // `MISSED_TOOL`, which is the honest reading of "answered as though something was read"
        // and not a new one.

        LiveEvalCase(
            id: "O01",
            turns: ["Summarise my last emails", "Is this coming from my emails?"],
            expectation: .tools(anyOf: ["search_email"], allowed: ["read_email"]),
            mustMention: [mailWords],
            evidence: "J L1 — invented mail, then asked about its provenance",
            expectedFix: "P1-24",
            scored: false),

        LiveEvalCase(
            id: "O02",
            turns: ["Check my emails"],
            followUpIfQuestion: "go for it",
            expectation: .tools(anyOf: ["search_email"], allowed: ["read_email"]),
            mustMention: [mailWords],
            evidence: "J L2, L5 — 'go for it' had no pending action to carry",
            expectedFix: "P1-24",
            scored: false),

        LiveEvalCase(
            id: "O03",
            turns: ["Can you tell me what's on tomorrow?"],
            expectation: .tools(
                anyOf: ["get_agenda"],
                checks: [ArgumentCheck(toolID: "get_agenda", key: "date", rule: .equalsTomorrow)]),
            mustMention: [["dentist", "design sync", "dinner"]],
            evidence: "J L11 — an agenda for the wrong day",
            expectedFix: "P1-24, P4-01",
            scored: false),

        LiveEvalCase(
            id: "O04",
            turns: ["Can you look at my inbox?"],
            expectation: .tools(anyOf: ["search_email"], allowed: ["read_email"]),
            mustMention: [mailWords],
            evidence: "J L3 — 'I don't have access to your email' five times",
            expectedFix: "P1-24",
            scored: false),

        LiveEvalCase(
            id: "O05",
            turns: ["Open my Gmail in Chrome"],
            // The URL tools carry the requirement; the app is the *other* half of the
            // sentence, not the subject of it. A first baseline run opened Google Chrome and
            // navigated to mail.google.com — did the whole thing — and this expectation graded
            // it WRONG_TOOL, because `computer.open_app` sat in `anyOf` and its `name` check
            // wanted "gmail" in an app the person had named as Chrome. A case that punishes a
            // correct answer measures the case.
            expectation: .tools(
                anyOf: ["browser.navigate", "computer.open_url"],
                allowed: ["computer.open_app", "browser.snapshot", "browser.click",
                          "browser.fill"],
                // One check per tool that can carry the request, because a check asks about
                // one tool id — and the check is skipped for a tool that never ran.
                checks: [
                    ArgumentCheck(toolID: "browser.navigate", key: "url",
                                  rule: .containsAny(["mail.google.com"])),
                    ArgumentCheck(toolID: "computer.open_url", key: "url",
                                  rule: .containsAny(["mail.google.com"])),
                ]),
            evidence: "J (owner's turn) — a site and an app in one sentence",
            expectedFix: "P1-13 (done) — a regression guard, not a gap",
            scored: false),

        LiveEvalCase(
            id: "O06",
            turns: ["Find the pricing document", "Hi"],
            // The find is the setup, so it is permitted — and `noToolFromSecondTurn` is what
            // stops that permission from reaching the greeting, which is the whole case.
            expectation: .answerOnly(
                allowed: ["filesystem.find", "filesystem.search", "find_drive_files",
                          "filesystem.reveal"]),
            mustNotMention: ["pricing", "productflo"],
            maxReplyCharacters: 200,
            extraRule: .noToolFromSecondTurn,
            evidence: "J (owner's turn) — a greeting answered with the previous result",
            expectedFix: "P1-11, P1-18",
            scored: false),

        LiveEvalCase(
            id: "O07",
            turns: ["What's today's date?"],
            expectation: .answerOnly(),
            dynamicMention: .todayDate,
            evidence: "J L13 — 'the clock reads 1:45 AM on 2026-09-23', three and a half hours off",
            expectedFix: "P4-01 (now runs in Phase 1)",
            scored: false),

        LiveEvalCase(
            id: "O08",
            turns: ["Add 'bring passports' to my trip doc"],
            // The find, then the append — or the find and a question about which document,
            // which on today's fixtures is the *correct* answer: `find_drive_files` promises
            // ids and the eval's own answer carries none, so an `append_doc` with an invented
            // id is the thing P1-25 refuses. The id half of this case is P1-25's I2, not here.
            expectation: .compound(
                first: ["find_drive_files", "filesystem.find", "filesystem.search"],
                then: ["append_doc"],
                orQuestionMentioning: ["document", "which one"]),
            evidence: "J L13, L22 — approved with document_id 'You open Google Chrome'",
            expectedFix: "P1-25",
            scored: false),

        LiveEvalCase(
            id: "O09",
            turns: ["Summarise my recent emails and list tomorrow's events"],
            expectation: .tools(
                anyOf: [],
                allOf: ["search_email", "get_agenda"],
                allowed: ["read_email"],
                checks: [ArgumentCheck(toolID: "get_agenda", key: "date", rule: .equalsTomorrow)]),
            mustMention: [mailWords, ["dentist", "design sync", "dinner"]],
            evidence: "J L1, L11 — two accounts in one turn",
            expectedFix: "P1-24 (multi-class)",
            scored: false),

        // Recorded, not gated: O10's fix is P4-03, which is Phase 4. It is in the set so the
        // number it prints is honest about where the answer still is wrong.
        LiveEvalCase(
            id: "O10",
            turns: ["Can you hear me?"],
            expectation: .answerOnly(),
            // Both apostrophes, because a model writes either and a case decided by
            // typography measures the model's keyboard rather than its answer.
            mustNotMention: [
                "can't hear", "can’t hear", "cannot hear", "can not hear",
                "my ears", "ears are", "mic is off", "microphone is off",
            ],
            evidence: "J (owner's turn) — typed, not voice",
            expectedFix: "P4-03 (tracked, not gated)",
            scored: false),
    ]

    static func caseWithID(id: String) -> LiveEvalCase? {
        all.first { $0.id == id }
    }

    /// The unscored cases a run actually selected, in `ownerLogIDs` order. A `--quick` run
    /// selects none, which is the point: the owner set is not a per-task gate.
    static func ownerLogSubset(of results: [(id: String, isPass: Bool)]) -> [(id: String, isPass: Bool)] {
        ownerLogIDs.compactMap { id in
            results.first { $0.id == id }.map { (id, $0.isPass) }
        }
    }
}
