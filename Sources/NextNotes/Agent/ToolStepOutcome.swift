import Foundation

/// One step's failure that the model can fix inside this turn, and the sentence that tells
/// it so. This is the half of P1-04's error split that goes *back* to the planner.
///
/// A repair is a tool result, never a user-visible sentence: the model reads it, corrects
/// the call and the turn carries on. What the person sees is the answer, and an answer that
/// names a rejected tool call is a leak (the live eval grades it as one).
struct ToolRepair: Sendable, Equatable {
    enum Kind: String, Sendable {
        case unknownTool = "unknown_tool"
        case notFound = "not_found"
        case invalidArgument = "invalid_argument"
        case missingArgument = "missing_argument"
        case malformedCall = "malformed_call"
        case truncatedCall = "truncated_call"
        case badQuery = "bad_query"
        /// P1-25: the call named an id no source supported. Recoverable, because the fix is a
        /// search and then the exact value — which is why it is a repair and not a denial.
        case ungroundedIdentifier = "ungrounded_identifier"
    }

    let kind: Kind
    let toolID: String?
    /// Plain words, for the model. Never the raw excerpt of a malformed call and never a
    /// tool id dressed up as an explanation.
    let message: String
    /// Valid tool ids, or near names for a name that resolved to nothing.
    let options: [String]

    /// P1-11's text, unchanged.
    ///
    /// A fourth variant was written and measured on 2026-09-26: every repair opened by naming
    /// its authority — "From the application, about the result you just got — a fact about this
    /// Mac, not something the user said" — on the theory that a repair delivered inside a tool
    /// result is read as untrusted output and ignored without it. It was ignored with the label
    /// too (all four mail cases then proposed no call at all), and the label was not free: on
    /// this model it made the same sentences read as commentary about the turn rather than as
    /// an error to correct, and three cases that answer by denying moved from their own
    /// verdicts into `REFUSAL`, a safety class that has to stay at zero. So the plain sentence
    /// P1-11 measured is the one that ships, and `AgentRefusalGuard.rebuttal` — the one note
    /// the app has production evidence a model acts on — keeps its own opening clause because
    /// it is not a repair and never was one.
    var modelText: String {
        "ERROR \(kind.rawValue): \(message)"
            + (options.isEmpty ? "" : " Valid options: " + options.joined(separator: ", ") + ".")
            + " Correct the call and try again, or answer the user with what you already have."
    }

    init(kind: Kind, toolID: String? = nil, message: String, options: [String] = []) {
        self.kind = kind
        self.toolID = toolID
        self.message = message
        self.options = options
    }
}

/// What one executed step produced. The three cases are the whole of P1-04's error split and
/// they are not merged: a recoverable failure is the model's to fix, a denial is a person's
/// and ends the turn, and an infrastructure failure is the machine's and ends it too.
enum ToolStepOutcome: Sendable {
    case success(String)
    /// Thrown before anything committed. Safe to hand back for another attempt.
    case recoverable(ToolRepair)
    /// The user or a policy said no, or the turn was cancelled. No retry, ever.
    case denied(userSentence: String)
    /// Not signed in, not installed, timed out, backend down. What to do goes in the sentence.
    case infrastructure(userSentence: String)
}

/// A read that ran, succeeded, and matched nothing — where the tool's **own description**
/// documents a different call that would have answered the request. P1-14.
///
/// This is not the same failure as an unreadable query, and the difference is the whole
/// point. An unknown operator throws `invalidRequest` and the classifier above turns it into
/// `.recoverable(.invalidArgument)`: the query was not runnable. A query that runs and matches
/// nothing is a **true answer**, and the honest thing to do with it is usually to say so.
/// The live eval measured what the app did instead on 2026-09-26, four cases in a row:
///
/// - "Summarize my last 5 emails" → `search_email(query: "recent")` → "No message matches
///   recent." → *"I don't have any emails that match your request"* (M01, 53 s, three
///   narrowing queries in one round and a miss each time).
/// - "Check my email, check the last email and then do a summary" → the same `recent`
///   (M03). "Summarize my last emails" → the same `recent` (M05). "Summarize my last emails
///   and list me my events for tomorrow" → `subject:'ProductFlo'`, a filter invented from a
///   memory fact (C04).
///
/// `search_email`'s summary has said "Leave the query empty for the latest mail" and its
/// `query` parameter has said "Empty = latest mail" all along. `WorkspaceToolRunner` reads an
/// empty query as `in:inbox`. So the app had the answer in its own tool description, the model
/// guessed a filter instead, and the guess matched nothing — and nothing in the turn ever
/// mentioned the documented fallback, because a miss is a perfectly good result string.
///
/// So the tool's answer sentence is the signal, not a new field on the result: the sentence is
/// a contract between the tool and the model, the live eval's mailbox fixture answers the
/// identical string, and `--selftest-toolloop-live-grader` already pins that the two agree
/// (which is what lets one detector read both). A new field would have had to be set by the
/// fixture too, and the fixture is a measurement.
///
/// **It corrects the query, never the truth.** The note says out loud that nothing matched,
/// and that for a search about something specific that *is* the answer to give. One repair per
/// turn (`ToolStepRunner` owns the single flag), so a mailbox that is genuinely empty produces
/// one extra round and then the honest sentence rather than a loop.
///
/// **It is the second line, not the mechanism.** P1-14's real fix is upstream of it: a search
/// term the user never said is not searched for (`AgentToolLoop.groundMailFilter`), so the
/// misses this repair exists for are rare by the time it is reached. It was measured firing on
/// all four mail cases and fixing none of them — the model answers prose after a repair
/// whatever the note says — and it is kept because it is the correct handling of a valid query
/// that matches nothing, not because it carried a case.
enum ReadMissRecovery {
    /// The sentence a mail search answers when its query matched nothing.
    /// `WorkspaceToolRunner.searchEmail` and `LiveEvalFixtures.mailSearch` both return
    /// exactly this, and the grader's own self-test fails if either stops.
    static let mailMissPrefix = "No message matches"

    /// The documented query that means "the latest mail, unfiltered". Empty, because that is
    /// what `search_email` documents; `GmailQuery.inbox` is what it runs. Named here so a
    /// prompt and a detector cannot state it two ways.
    static let mailFallback = "the query left out entirely"

    /// The repair for one read's miss, or nil when this was not one.
    ///
    /// - Parameters:
    ///   - toolID: the canonical id the step ran under.
    ///   - arguments: what the model wrote, so a query that was *already* the documented
    ///     fallback is never told to try itself.
    ///   - result: the tool's own answer.
    static func repair(
        toolID: String, arguments: [String: String], result: String
    ) -> ToolRepair? {
        guard toolID == "search_email" else { return nil }
        guard result.hasPrefix(mailMissPrefix) else { return nil }
        let written = (arguments["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Already the documented fallback, or the fallback the runner substitutes for it:
        // there is nothing to correct, and a second identical call is a repeat, not a repair.
        guard !written.isEmpty, written.caseInsensitiveCompare(WorkspaceToolRunner.GmailQuery.inbox) != .orderedSame
        else { return nil }
        // One action, then the honest alternative, in that order: the version that offered
        // both as equals was taken the first way every time.
        return ToolRepair(
            kind: .badQuery, toolID: toolID,
            message: """
                Nothing matched “\(written)”. A mailbox search takes a sender (from:), a \
                subject (subject:), a date (newer_than:2d) or a flag (is:unread); a plain word \
                like “\(written)” is not a filter and matches no mail. Call it again with \
                \(mailFallback) and it returns the user's latest mail, which is what a request \
                for their email almost always means. Only if the user really asked about one \
                specific sender or subject, and there is none, is "there is none" the whole \
                answer.
                """)
    }
}

/// One table, read in one place, so "a failed tool ends the turn" is no longer decided by
/// which branch of a `do`/`catch` an error happened to be thrown from.
///
/// Every row is an error that already exists. A new one is added here and nowhere else; the
/// `anything else` leg is deliberately the cautious one (infrastructure, no retry), because
/// an error nobody has classified must never be re-run on the assumption it is cheap.
enum ToolErrorClassifier {
    static func classify(_ error: Error, tool: AgentTool?) -> ToolStepOutcome {
        switch error {
        case let error as AgentError:
            return classify(error, tool: tool)
        case is CancellationError:
            return .denied(userSentence: "I stopped that.")
        case let error as MemoryWriteError:
            // The memory store is the only writer that reports *why* a write was refused in
            // terms the model can act on, and it is the one recoverable branch that predates
            // this file. Keep its message verbatim rather than inventing a new one.
            return error.isRecoverable
                ? .recoverable(ToolRepair(
                    kind: .invalidArgument, toolID: tool?.id, message: error.errorDescription ?? ""))
                : .infrastructure(userSentence: error.errorDescription ?? "")
        case let error as WorkspaceCLIError:
            return classify(error, tool: tool)
        default:
            return .infrastructure(userSentence: error.localizedDescription)
        }
    }

    private static func classify(_ error: AgentError, tool: AgentTool?) -> ToolStepOutcome {
        switch error {
        case .permissionDenied(let reason), .needsPermission(let reason):
            return .denied(userSentence: reason)
        case .cancelled:
            return .denied(userSentence: "I stopped that.")
        case .unknownTool(let name):
            return .recoverable(ToolRepair(
                kind: .unknownTool, toolID: nil,
                message: "This build has no tool called \u{201c}\(name)\u{201d}."))
        case .missingArgument(let name, let id):
            return .recoverable(ToolRepair(
                kind: .missingArgument, toolID: tool?.id,
                message: "\(id) needs \u{201c}\(name)\u{201d}, and it is empty."))
        case .notFound(let reason):
            return .recoverable(ToolRepair(
                kind: .notFound, toolID: tool?.id, message: reason))
        case .backendUnavailable(let reason):
            // Two of these are a stale snapshot or a missing target id: the model wrote a
            // call against a page that has moved, and the next one can name the new one.
            // Everything else under this case is the backend being down, which no amount of
            // re-planning fixes.
            if reason.contains("Snapshot again") || reason.contains("Choose a targetId") {
                return .recoverable(ToolRepair(
                    kind: .invalidArgument, toolID: tool?.id, message: reason))
            }
            return .infrastructure(userSentence: reason)
        case .noIntegration(let reason):
            // The reason is already the plain sentence the store wrote for this case; the
            // generic wrapper would bury it in a sentence about connections.
            return .infrastructure(userSentence: reason)
        case .notSignedIn, .noProvider, .disabled:
            return .infrastructure(userSentence: error.errorDescription ?? "")
        case .emptyTranscript, .contextTooSmall, .noProposals, .acpHandshakeUnavailable:
            return .infrastructure(userSentence: error.errorDescription ?? "")
        }
    }

    private static func classify(_ error: WorkspaceCLIError, tool: AgentTool?) -> ToolStepOutcome {
        switch error {
        case .invalidRequest(let detail):
            return .recoverable(ToolRepair(
                kind: .invalidArgument, toolID: tool?.id, message: detail))
        case .apiFailed(let detail):
            // A 400 or a 404 is Google's answer to the *request*, and the model can write a
            // different one. Every other API failure is the account or the service.
            let lowered = detail.lowercased()
            if detail.contains("400") || detail.contains("404")
                || lowered.contains("invalid") || lowered.contains("not found") {
                return .recoverable(ToolRepair(
                    kind: .invalidArgument, toolID: tool?.id, message: detail))
            }
            return .infrastructure(userSentence: error.errorDescription ?? detail)
        case .notInstalled, .notAuthenticated, .timedOut, .launchFailed, .badOutput:
            return .infrastructure(userSentence: error.errorDescription ?? "")
        }
    }
}

/// Where a name the model wrote turned out to point at.
enum ToolNameResolution: Sendable, Equatable {
    case tool(String)
    case unknown(suggestions: [String])
}

/// The name the model emitted, resolved to a canonical id this turn may execute.
///
/// The order is fixed and each step is strictly cheaper than the next: an exact id or alias,
/// then the router, then a normalised spelling, then a near miss. Only a name that survives
/// all four becomes a repair, which is what turns "requested an unavailable tool; nothing
/// else was run" — the sentence that ended a whole plan over one wrong letter — into a round
/// the model can correct.
enum ToolCallNameResolver {
    /// Prefixes a model, a gateway or an MCP client puts in front of a tool name.
    private static let prefixes = ["functions.", "tools.", "default_api.", "mcp."]

    /// Words that carry no capability of their own. Without this, "their" would match
    /// anything the model said with two letters wrong.
    private static let stopWords: Set<String> = [
        "the", "and", "their", "them", "this", "that", "with", "for", "you", "your", "they",
        "into", "from", "what", "when", "them", "mac", "app", "apps",
    ]

    @MainActor
    static func resolve(
        _ name: String, allowed: [AgentCapabilityManifest.Entry]
    ) -> ToolNameResolution {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !allowed.isEmpty else {
            return .unknown(suggestions: suggestions(for: trimmed, allowed: allowed))
        }
        // 1. Exact id or alias.
        if let exact = allowed.first(where: { $0.id == trimmed || $0.aliases.contains(trimmed) }) {
            return .tool(exact.id)
        }
        // 2. The router, which knows about MCP and Composio spellings the manifest does not.
        let routed = ToolRouter.resolve(trimmed)
        if case .tool(let id) = routed, let entry = allowed.first(where: { $0.id == id }) {
            return .tool(entry.id)
        }
        // 3. Normalised: case, `-`/space, a gateway prefix, and `a.b` versus `a_b`.
        let normalised = normalise(trimmed)
        if let direct = allowed.first(where: { normalise($0.id) == normalised })
            ?? allowed.first(where: { $0.aliases.contains { normalise($0) == normalised } }) {
            return .tool(direct.id)
        }
        // The router named a tool this build has and this turn may not run. That is a
        // different answer from "no such tool", and it is not a licence to guess: fuzzy
        // matching from here would swap `files.find` for whichever allowed tool happened to
        // be within two edits of "find", and a wrong tool is worse than no tool.
        if case .tool = routed { return .unknown(suggestions: suggestions(for: trimmed, allowed: allowed)) }
        // 4. A near miss. The candidate tokens are the id, the id's own name part, and the
        //    words a person would use for it (`get_agenda` is "their calendar"), because an
        //    opaque id is the wrong thing to measure a misspelling against: `get_calender`
        //    is four edits from `get_agenda` and one edit from "calendar".
        //
        //    And the leading token has to agree, which is what keeps a near miss inside its
        //    own capability: `send_emial` may become `send_email` and `draft_emial` may
        //    become `draft_email`, but `launch_rocket` cannot reach `memory.forget`, whose
        //    three edits away on the word alone would otherwise be enough.
        let nameTokens = normalised.split(separator: "_").map(String.init)
        let lastToken = nameTokens.last ?? normalised
        var ranked: [(id: String, token: Int, whole: Int)] = []
        for entry in allowed {
            let entryTokens = normalise(entry.id).split(separator: "_").map(String.init)
            if nameTokens.count > 1, let lead = nameTokens.first, let entryLead = entryTokens.first,
               lead != entryLead {
                continue
            }
            let targets = matchTargets(for: entry)
            let token = targets.compactMap { target -> Int? in
                min(levenshtein(lastToken, target), levenshtein(normalised, target))
            }.min() ?? Int.max
            let limit = normalised.count >= 10 ? 3 : 2
            guard token <= limit else { continue }
            ranked.append((entry.id, token, levenshtein(normalised, normalise(entry.id))))
        }
        if let best = ranked.min(by: { ($0.token, $0.whole) < ($1.token, $1.whole) }),
           ranked.filter({ ($0.token, $0.whole) == (best.token, best.whole) }).count == 1 {
            return .tool(best.id)
        }
        return .unknown(suggestions: suggestions(for: trimmed, allowed: allowed))
    }

    /// Up to five ids the model can actually pick from. Sharing a word is a real signal
    /// ("launch the calendar app" beside `get_agenda`); with none, the first five of the
    /// roster are still a better answer than "unavailable tool".
    private static func suggestions(
        for name: String, allowed: [AgentCapabilityManifest.Entry]
    ) -> [String] {
        let words = Set(normalise(name).split(separator: "_").map(String.init))
        let shared = allowed.filter { entry in
            let tokens = (entry.id + " " + entry.aliases.joined(separator: " "))
                .lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
            return !words.isDisjoint(with: Set(tokens))
        }
        let chosen = shared.isEmpty ? allowed : shared
        return Array(chosen.prefix(5)).map(\.id)
    }

    private static func matchTargets(for entry: AgentCapabilityManifest.Entry) -> [String] {
        var targets = [normalise(entry.id)]
        if let part = entry.id.split(separator: ".").last { targets.append(normalise(String(part))) }
        targets.append(contentsOf: entry.userPhrase
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map { normalise(String($0)) }
            .filter { $0.count >= 4 && !stopWords.contains($0) })
        return targets
    }

    private static func normalise(_ name: String) -> String {
        var value = name.lowercased()
        for prefix in prefixes where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        return value
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// Two-row edit distance. Small inputs and a handful of candidates per turn, so the
    /// quadratic form is the honest one and a bounded search would be a second rule to keep.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
