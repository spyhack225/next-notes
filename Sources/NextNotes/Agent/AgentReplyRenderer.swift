import Foundation
import FoundationModels

/// The two ends of a tool turn, P1-10: how much of a tool's answer goes back into the
/// prompt, and what a turn is allowed to end with.
///
/// `ToolResultBudget` is the first — a cap that scales with the reader, and a fold for the
/// results a later round will not read. `AgentTurnOutcome` and `AgentReplyRenderer` are the
/// second — one vocabulary for what happened and one place that writes the sentence for it.
/// They live in one file because a turn's result and a turn's reply are the same boundary:
/// too little of the first and the answer is wrong, too much of the first and the answer
/// never arrives, and a sentence that explains either of those belongs to neither the model
/// nor the person.
///
/// Two rules, and both of them exist because a fixed number was wrong in both directions.
///
/// **The cap scales with the reader.** A flat 1,200 characters is right for the 4,096-token
/// Apple path and catastrophic for a 262,144-token OpenRouter reader: a ten-page
/// `read_doc` became 1,200 characters and `skills.read` — which reads 6,000 today — lost
/// four-fifths of a skill. The measured ladder below is the H-audit answer (700 / 1,200 /
/// 4,000 / 12,000), and a document-reading tool gets twice it: 2× is still a cap, and the
/// per-round fitter still runs.
///
/// **Older results fold.** By round four the prompt is carrying four answers, and the two
/// that matter are the last two. Reducing the rest to their first line keeps the newest
/// result whole without dropping the fact that a step happened.
///
/// A result is cut at a line boundary and says how much was not shown, because a tool
/// answer that stops mid-word reads as a complete answer to a small model.
enum ToolResultBudget {
    /// Characters of one tool result the model may read. Scales with the reader's window.
    static func characterCap(readerContextTokens: Int) -> Int {
        switch readerContextTokens {
        case ...4_096: 700
        case ...8_192: 1_200
        case ...32_768: 4_000
        default: 12_000
        }
    }

    /// Tools whose whole job is to read a document. They get twice the reader's cap, and
    /// no more: a mail body and a transcript are the two results a person actually asked
    /// for, so cutting them to a 4K-sized budget loses the answer rather than the noise.
    static let documentReadingToolIDs: Set<String> = [
        "read_doc", "filesystem.read", "skills.read", "meeting.transcript",
    ]

    static func characterCap(readerContextTokens: Int, toolID: String) -> Int {
        characterCap(readerContextTokens: readerContextTokens)
            * (documentReadingToolIDs.contains(toolID) ? 2 : 1)
    }

    /// The reader of the plan in flight. Bound by the planner around execution so a tool
    /// that shapes its own answer (`WorkspaceToolRunner`) sizes it for the model that will
    /// read it, rather than for a constant chosen before any of them were known.
    ///
    /// Nil means "no reader bound" — the meeting agent, a scheduled routine, anything
    /// outside a planned turn — and those callers keep their existing cap.
    @TaskLocal static var readerContextTokens: Int?

    /// The suffix that says the answer was cut, and by how much.
    static func elisionSuffix(hidden: Int) -> String {
        "…(\(hidden) more character\(hidden == 1 ? "" : "s") not shown)"
    }

    /// One result, cut to the reader's cap. Cuts at a line boundary when there is one, so
    /// the model never reads half a line and believes it is the whole row.
    static func cap(_ output: String, readerContextTokens: Int, toolID: String) -> String {
        let limit = characterCap(readerContextTokens: readerContextTokens, toolID: toolID)
        return cap(output, to: limit)
    }

    /// One result, cut to an explicit limit. The other overload is the one production
    /// calls; this is the rule, so the fitter, the renderer and the self-test share it.
    ///
    /// The cut lands on a line boundary, but only on one in the *second half* of the kept
    /// text. That qualification is not a nicety: a result reaches the model wrapped as
    /// `"<name> returned:\n<text>"`, and a body with no newline of its own leaves the
    /// wrapper's newline as the last boundary in the head — so the first version of this cut
    /// at 19 characters, kept the word `read_doc`, and threw away the whole document it was
    /// written to bound.
    static func cap(_ output: String, to limit: Int) -> String {
        guard output.count > limit, limit > 0 else { return output }
        let head = String(output.prefix(limit))
        let tail = head.index(head.startIndex, offsetBy: limit / 2, limitedBy: head.endIndex)
            ?? head.endIndex
        let cut = head[tail...].lastIndex(of: "\n")
            .map { head.distance(from: head.startIndex, to: $0) } ?? limit
        let kept = String(head.prefix(cut))
        return kept + elisionSuffix(hidden: output.count - kept.count)
    }

    /// Results older than the last `keepFull`, reduced to their first line.
    ///
    /// First line, not first `n` characters: a tool answer's first line is its own summary
    /// ("On 2026-09-27:", "3 files found"), and what comes after it is the detail a later
    /// round will not read anyway.
    static func fold(_ results: [String], keepFull: Int = 2) -> [String] {
        guard results.count > keepFull else { return results }
        let foldFrom = results.count - keepFull
        return results.enumerated().map { index, result in
            index < foldFrom ? firstLine(result) : result
        }
    }

    /// One result's first line, at most 160 characters, cut the same way `cap` cuts.
    static func firstLine(_ result: String) -> String {
        let line = result.split(separator: "\n", maxSplits: 1,
                                omittingEmptySubsequences: false).first.map(String.init)
            ?? result
        return cap(line, to: 160)
    }
}

/// What one turn ended on, in the words a person can act on (P1-10b).
///
/// The nine cases are the whole vocabulary, and the split that matters is the one the old
/// code got wrong: a *provider or hand-off* error may say "you have hit your usage limit",
/// an **answer** may not — "What's a sales quota?" and "that file is not downloaded yet"
/// are the user's own topic, and rewriting those answers is how a typed turn learned to
/// claim a limit it never hit. So the sentences live here, keyed on the outcome, and
/// `scrub` never replaces one.
enum AgentTurnOutcome: Sendable {
    /// A real answer. The only case that is not an excuse for something not finishing.
    case answer(String)
    /// The plan's clock ran out. `lastVerified` is what a step actually returned, when one
    /// did — a result is a better thing to lead with than a sentence about the plan.
    case timedOut(lastVerified: String?)
    /// The person stopped it, or a newer turn superseded this one.
    case stopped
    /// A person or a policy said no. The sentence is already plain; it is passed through.
    case denied(String)
    /// Not signed in, not installed, timed out, backend down.
    case infrastructure(String)
    /// The model was asked to correct itself twice and did not.
    case repairLimit(lastVerified: String?)
    /// The prompt did not fit the reader's window even after trimming.
    case contextOverflow(lastVerified: String?)
    /// No model on this Mac can run, or the one this turn chose cannot.
    case modelUnavailable(String)
    /// The model ran and failed. The raw reason goes to the audit log, never to a person.
    case modelFailed(String)
    /// A hand-off to another harness could not do it and the turn ran here instead.
    indirect case handedOffFellBack(note: String, then: AgentTurnOutcome)
    /// J L8 (2026-09-27): the model spent its whole answer allowance and stopped mid-answer.
    /// The partial text is kept, because throwing it away loses a real answer, and the fact
    /// that it stops is said, because showing half a sentence as though it were the whole one
    /// is the failure. Distinct from `.repairLimit`, which is about how the *turn* went rather
    /// than where the tokens ran out, and from `.timedOut`, which is our clock rather than the
    /// model's allowance.
    case cutShort(String)
}

/// The one place a reply is written for a person.
///
/// Two entry points and they do different things. `render` turns an **outcome** into the
/// sentence that outcome deserves, and it is the only code allowed to name a limit, a
/// quota, a missing download or a broken hand-off. `scrub` is the last pass over a
/// reply that already exists: it removes registry ids, "step n/m", raw tool markup and — on
/// a non-answer — URLs, and it removes nothing else. An answer that happens to say "quota"
/// or "not downloaded" comes back byte for byte.
enum AgentReplyRenderer {
    /// The sentence for one outcome. `voice` asks for the shorter, spoken form of the same
    /// meaning; the words a person hears are the words they read.
    @MainActor
    static func render(_ outcome: AgentTurnOutcome, voice: Bool) -> String {
        switch outcome {
        case .answer(let text): return text
        case .timedOut(let last): return withResult(last, timedOut(voice))
        case .stopped: return "Stopped."
        case .denied(let sentence): return sentence
        case .infrastructure(let reason): return infrastructure(reason, voice: voice)
        case .repairLimit(let last): return withResult(last,
            "I couldn't finish that one — try saying it another way.")
        case .contextOverflow(let last): return withResult(last,
            "That was too much to read at once. Ask for something narrower.")
        case .modelUnavailable(let reason): return modelUnavailable(reason, voice: voice)
        case .modelFailed: return "The model didn't finish that answer. Try again."
        case .handedOffFellBack(let note, let then):
            return handoffNote(note) + "\n\n" + render(then, voice: voice)
        case .cutShort(let partial):
            return withResult(partial, "I was cut off there — ask me to go on.")
        }
    }

    /// The last pass over every reply, on every path. `outcome` is the outcome the reply
    /// ended on when the caller knows it, and nil when it does not — in which case this is
    /// an answer as far as the scrub is concerned and **nothing is rewritten**. That is the
    /// whole difference from the rule it replaces: "What's a sales quota?" and "that file
    /// is not downloaded yet" are a person's own topic, and the old voice rule answered
    /// both with a usage-limit notice.
    ///
    /// What is removed is never a word of an answer: registry ids and aliases (word-bounded,
    /// and only the full spellings that carry a `.` or a `_`), "step n/m", raw tool markup,
    /// and — on anything that is not an answer — a URL, which is replaced by the words "that
    /// link" rather than deleted so the sentence still reads.
    @MainActor
    static func scrub(_ text: String, outcome: AgentTurnOutcome?) -> String {
        var clean = text
        // 1. Raw tool markup.
        if let markupRegex {
            clean = markupRegex.stringByReplacingMatches(
                in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "")
        }
        // 2. A step count. Only ever written by the sentence P1-10 removed.
        clean = clean.replacingOccurrences(
            of: #"\bstep \d+\s*/\s*\d+\b"#, with: "", options: .regularExpression)
        // 3. Registry ids and aliases, case-insensitively: a model that writes
        //    `Get_Agenda` has leaked exactly as much as one that writes the canonical case.
        if let pattern = registryIDPattern() {
            clean = clean.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // 4. A URL, on a non-answer only. An answer may legitimately contain one.
        if !isAnswer(outcome) {
            clean = clean.replacingOccurrences(
                of: #"https?://\S+"#, with: "that link", options: .regularExpression)
        }
        // 5. Tidy only what a removal left behind. Internal paragraph breaks survive: the
        //    renderer writes a result and a sentence as two paragraphs, and flattening them
        //    would be the same class of bug as flattening an answer.
        clean = clean.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - What the scrub knows

    /// Whether a reply is an answer, for the rules that differ. nil counts as an answer: the
    /// scrub is the last pass and an unlabelled reply is one.
    private static func isAnswer(_ outcome: AgentTurnOutcome?) -> Bool {
        switch outcome {
        case .answer, nil: true
        default: false
        }
    }

    /// Markup a model emits and a person must never read. Each is a literal so a `.` in a
    /// marker is a dot and not "any character"; the unclosed forms are here because a call
    /// cut off mid-object leaked exactly that on 2026-09-23. One alternation, compiled
    /// once: this runs on every reply and a regex per marker per reply is 20 compiles for
    /// the same answer.
    /// **`\u200B`, not `\u{200B}`.** The braces are Swift's spelling for a code point; ICU
    /// wants the four-hex-digit form, so the pattern as written **did not compile** — and
    /// `try?` turned that into `nil`, which `if let markupRegex` then skipped in silence. The
    /// first step of the scrub on every reply had never run: the 27 September Portrait draft
    /// that was a raw `<tool_call>` block (J L9) went through this exact function. A
    /// self-test now asserts the regex exists, so a second uncompilable pattern is a named
    /// failure rather than a scrub that quietly does nothing.
    private static let markupRegex = try? NSRegularExpression(pattern: [
        #"<\u200B?/?tool_call>"#, #"</\u200B?tool_call>"#,
        #"<use_tools\s*/?>"#, #"<answer\s*/?>"#, #"<think>"#, #"</think>"#,
        #"<function[^>]*>"#, #"</function>"#, #"<parameter[^>]*>"#, #"</parameter>"#,
        #"\[TOOL_CALLS\]"#, #"</?tool_calls>"#, #"<\|[^>]*>"#, #"\|>"#,
        #"name=""#, #"\{"name"""#, #",?"arguments""#, #"\{"arguments"""#,
        #"<\u200B?/?invoke[^>]*>"#, #"</\u200B?invoke>"#,
    ].joined(separator: "|"))

    /// Whether the markup pattern compiled. Nothing may be shown to a person on the strength
    /// of a regex that is silently absent, and a `try?` cannot report its own failure.
    static var markupPatternCompiled: Bool { markupRegex != nil }

    /// Whether `text` carries raw tool markup or a reasoning block at all.
    ///
    /// Distinct from `scrub`, and needed because scrubbing is not always enough. Strip the tags
    /// off a model's `<think>Let me check the graph.</think>` and the sentence is left looking
    /// exactly like an insight; strip them off a call and `{"name":"search_email"}` is left
    /// behind. So a caller that is choosing *lines* — the Portrait pass, which offers a draft
    /// for a person to keep — asks this first and drops the line, rather than offering the
    /// wreckage of a line the model spent on something else.
    static func containsMarkup(_ text: String) -> Bool {
        guard let markupRegex else { return false }
        return markupRegex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Every registry id and alias the scrub removes, from the one registry, so a new tool
    /// is covered the day it is added and none of this has to be kept in step by hand.
    ///
    /// The turn's own manifest is read first, because those are the only spellings a model
    /// was *given* — a reply cannot leak an id it was never offered. The whole registry is
    /// the floor under that, for a reply from a path that never planned a turn. Only the
    /// full spellings are included: a bare alias like "search" or "find" is a word a person
    /// uses about their own work, and scrubbing it would edit an answer (P1-10's own risk
    /// note).
    @MainActor
    private static func registryIDPattern() -> String? {
        var names = Set(
            AgentCapabilityMirror.shared.current?.allowed.flatMap { [$0.id] + $0.aliases } ?? [])
        for tool in AgentToolRegistry.shared.tools(upTo: .privileged) { names.insert(tool.id) }
        let alternatives = names
            .filter { $0.contains(".") || $0.contains("_") }
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        guard !alternatives.isEmpty else { return nil }
        // Longest first, so `get_agenda` is never half-eaten by a shorter alternative, and
        // word-bounded on both sides so `my_get_agenda_note` is left alone.
        return #"(?<![A-Za-z0-9_])("# + alternatives.joined(separator: "|")
            + #")(?![A-Za-z0-9_])"#
    }

    // MARK: - The sentences

    /// A verified result leads, because a result is an answer and a sentence about a plan
    /// is not. The result is capped here too: it is a person reading it now.
    @MainActor private static func withResult(_ last: String?, _ sentence: String) -> String {
        guard let last = last?.trimmingCharacters(in: .whitespacesAndNewlines),
              !last.isEmpty else { return sentence }
        return ToolResultBudget.cap(last, to: 1_200) + "\n\n" + sentence
    }

    private static func timedOut(_ voice: Bool) -> String {
        voice ? "That took longer than I allow, so I stopped. Try one thing at a time."
            : "I ran out of time before finishing the rest."
    }

    /// The hand-off note. P1-12 already made this a plain sentence ("Codex couldn't do
    /// that, so I did it here.", or the one that carries the window it has), and that copy
    /// is better than anything this file could write — so it is used as it stands. What
    /// this guards is the 09-22 shape: a raw harness error with `ERROR:` and a URL in it,
    /// which reached a typed person because only the voice path was filtered.
    @MainActor private static func handoffNote(_ note: String) -> String {
        let clean = scrub(note, outcome: .infrastructure(note))
        let looksRaw = clean.isEmpty
            || clean.contains("ERROR:")
            || clean.contains("http://") || clean.contains("https://")
            || clean.contains("\n")
        return looksRaw ? "Codex couldn't do that, so I did it here." : clean
    }

    /// The four known causes, each with the one action that fixes it. Anything else is
    /// "I couldn't do that:" plus the reason with its ids, markup and urls already removed
    /// — the reason is a person's only clue, and hiding it is worse than showing a long one.
    @MainActor private static func infrastructure(_ reason: String, voice: Bool) -> String {
        let lower = reason.lowercased()
        if lower.contains("not signed in") || lower.contains("not authenticated")
            || lower.contains("sign in") || lower.contains("not connected") {
            return "Google isn't connected. Connect it in Settings ▸ Workspace."
        }
        if lower.contains("not installed") || lower.contains("no such file")
            || (lower.contains("helper") && lower.contains("install")) {
            return "The Google Workspace helper isn't installed. "
                + "Settings ▸ Workspace can install it."
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Google didn't answer in time. Try again in a moment."
        }
        if isUsageLimit(lower) { return usageLimit() }
        let clean = scrub(reason, outcome: .infrastructure(reason))
        return clean.isEmpty ? "I couldn't do that." : "I couldn't do that: " + clean
    }

    private static func usageLimit() -> String {
        "You've hit the usage limit, so I stopped there. "
            + "Check your plan or try again later."
    }

    /// The provider's own words, minus the parts that are not for a person. "isn't
    /// downloaded" stays: a model that is not installed is a thing the person has to fix,
    /// and the fix belongs in the sentence.
    @MainActor private static func modelUnavailable(_ reason: String, voice: Bool) -> String {
        let clean = scrub(reason, outcome: .modelUnavailable(reason))
        let lower = clean.lowercased()
        if isUsageLimit(lower) { return usageLimit() }
        // A model that is not installed is a thing the person has to fix, and the fix
        // belongs in the sentence. "…is not downloaded" is the provider's spelling and
        // names a file, so it is translated rather than repeated — and this is reachable
        // only from `.modelUnavailable`, so "that file is not downloaded yet" in an
        // *answer* is still the person's own words and is left alone.
        if lower.contains("not downloaded") || lower.contains("no longer on this mac") {
            return voice
                ? "The voice model isn't ready yet. Open Settings ▸ Models to get it."
                : "The model isn't ready yet. Open Settings ▸ Models to get it."
        }
        if clean.isEmpty {
            return voice
                ? "I can't answer right now. Choose a model in Settings ▸ Models."
                : "I can't answer right now because no model on this Mac can run. "
                    + "Choose one in Settings ▸ Models."
        }
        return "I can't answer right now: " + clean
    }

    /// Matched on a provider or hand-off **error** only. Never on an answer: see
    /// `AgentTurnOutcome`.
    static func isUsageLimit(_ lower: String) -> Bool {
        lower.contains("usage limit") || lower.contains("you've hit your")
            || lower.contains("you have hit your") || lower.contains("quota")
            || lower.contains("rate limit") || lower.contains("rate-limit")
            || lower.range(of: #"\b429\b"#, options: .regularExpression) != nil
    }
}

extension ToolStepOutcome {
    /// The turn outcome a classified step failure becomes, so `AgentReplyRenderer` stays
    /// the only place a sentence about a failure is written. P1-04's split is the input and
    /// P1-10's vocabulary is the output; nothing between them decides anything.
    func turnOutcome() -> AgentTurnOutcome {
        switch self {
        case .success(let text): return .answer(text)
        // A repair the turn could not use is still the step not having happened, and its
        // message is the plain reason the model wrote — "…needs \u{201c}name\u{201d}, and it is empty."
        case .recoverable(let repair): return .infrastructure(repair.message)
        case .denied(let sentence): return .denied(sentence)
        case .infrastructure(let sentence): return .infrastructure(sentence)
        }
    }
}

extension Error {
    /// The two ways a provider says the prompt did not fit: llama.cpp's own
    /// `inputTooLong`, and Foundation Models' context-window error. Both are the prompt
    /// being too large, and both are P1-10's `.contextOverflow` rather than a planner
    /// failure — the difference is the difference between "ask for something narrower" and
    /// a sentence about the app's insides.
    var isContextOverflow: Bool {
        if let error = self as? LlamaError, case .inputTooLong = error { return true }
        if let error = self as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = error { return true }
        return false
    }
}
