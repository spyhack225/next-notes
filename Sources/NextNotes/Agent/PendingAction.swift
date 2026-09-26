import Foundation

/// An offer or a confirmation question the agent is waiting on. A bare "yes" resolves to
/// it without a model deciding what "yes" meant. Shared by typed turns (P1-02) and voice
/// (P1-07), which today has its own `PendingIntent`.
///
/// 2026-09-22 00:58–01:01Z: "Summarize my last emails and list me my events for tomorrow"
/// got *"I don't have access to your email or calendar data without a tool call … would you
/// like me to do that?"*, and "yes", "use them" and "i am telling you to use your tools" got
/// the same sentence back — five times — with `gws` signed in. The typed path had no pending
/// slot, so a confirmation was re-read as a fresh request with the denial in its history.
struct PendingAction: Equatable, Sendable {
    /// Where the offer came from. `typedOffer` / `typedQuestion` are this task's two typed
    /// shapes; the other two are P1-07's, so one type carries all of them.
    enum Origin: String, Sendable { case typedOffer, typedQuestion, workerQuestion, frontendOffer }

    /// The user's own words, kept verbatim: the confirmation re-runs *this*, not whatever
    /// the model made of it.
    let requestText: String
    /// The assistant's final sentence, ending in "?".
    let question: String
    /// The tool id the request names, when the roster has one. Nil is not "no capability":
    /// it is "we could not tell", and the offer phrase is then the only reason to wait.
    let capabilityID: String?
    let origin: Origin
    let sessionID: UUID?
    let at: Date

    /// An offer goes stale after three minutes of other conversation.
    static let lifetime: TimeInterval = 180

    func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(at) < Self.lifetime }

    /// The first line of a confirmed prompt. Exported because the confirmation must reach
    /// the planner and *not* the direct-intent shortcut, which reads one sentence.
    static let confirmedPrefix = "Earlier request from the user:"

    /// The planner prompt for a confirmed action. States the confirmation so the model does
    /// not ask again, and keeps the user's own words as the instruction.
    func confirmedPrompt(acknowledgment: String) -> String {
        """
        \(Self.confirmedPrefix) \(requestText)
        You then asked: \(question)
        The user answered: \(acknowledgment)
        That answer confirms it. Carry out the earlier request now, with the tools it needs. Do not ask again.
        """
    }

    /// The questions that are an offer or a confirmation rather than a question about
    /// something new. "Anything else?" is deliberately not here: it is not an action.
    static let offerPhrases = ["would you like me to", "do you want me to", "shall i", "should i",
                              "want me to", "is that right", "is that okay", "is that ok", "okay?", "ok?"]

    // MARK: - Detect

    /// Nil unless the reply's last sentence is a question AND (it is an offer/confirmation,
    /// or the request itself names a capability the roster has).
    ///
    /// The second half is what keeps a model that ends every answer with "Anything else?"
    /// from creating a pending action on every turn: a bare "yes" only re-runs the earlier
    /// request when that request named a capability the planner could actually call.
    static func detect(reply: String, request: String, allowedIDs: Set<String>,
                       origin: Origin, sessionID: UUID?, now: Date = Date()) -> PendingAction? {
        let question = lastSentence(reply)
        guard question.hasSuffix("?") else { return nil }
        let normalized = AgentDirectIntent.normalize(request)
        let capabilityID = AgentDirectIntent.toolShapeMatch(in: normalized, allowedIDs: allowedIDs)
            ?? AgentDirectIntent.capabilityMention(in: normalized, allowedIDs: allowedIDs)
        let lowered = question.lowercased()
        guard offerPhrases.contains(where: { lowered.contains($0) }) || capabilityID != nil
        else { return nil }
        return PendingAction(
            requestText: request, question: question, capabilityID: capabilityID,
            origin: origin, sessionID: sessionID, at: now)
    }

    /// The reply's last non-empty sentence, terminator included.
    static func lastSentence(_ reply: String) -> String {
        var sentence = ""
        for character in reply {
            sentence.append(character)
            guard character == "." || character == "!" || character == "?" else { continue }
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentence = trimmed }
        }
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The answer

    /// "yes", "yeah", "yep", "sure", "ok", "okay", "please", "please do", "go ahead",
    /// "do it", "use them", "use it", "use your tools", optionally followed by ≤ 5 words
    /// with no action verb other than "use"/"do". Typed only; voice keeps
    /// `VoiceTurnPolicy.isBareAcknowledgment` (exact list) until P1-07.
    static func isConfirmation(_ text: String) -> Bool {
        matches(text, phrases: [
            "yes", "yeah", "yep", "yea", "aye", "sure", "ok", "okay", "please", "please do",
            "go ahead", "do it", "use them", "use it", "use your tools",
        ])
    }

    /// "no", "nope", "don't", "do not", "cancel", "never mind", "nevermind", "stop", "not now".
    static func isNegative(_ text: String) -> Bool {
        matches(text, phrases: [
            "no", "nope", "don't", "do not", "cancel", "never mind", "nevermind", "stop", "not now",
        ])
    }

    /// A typed acknowledgment is the phrase and at most five more words, none of which is
    /// an instruction. "yes and open Safari" is a new request, not a confirmation — the
    /// gate may only *resolve* a pending action, never invent one.
    private static func matches(_ text: String, phrases: [String]) -> Bool {
        let tokens = AgentEntityResolver.tokens(text)
        guard !tokens.isEmpty else { return false }
        // Longest phrase first, so "never mind" is not read as "never" plus a trailing word.
        for phrase in phrases.sorted(by: {
            AgentEntityResolver.tokens($0).count > AgentEntityResolver.tokens($1).count
        }) {
            let words = AgentEntityResolver.tokens(phrase)
            guard !words.isEmpty, tokens.count >= words.count,
                  Array(tokens.prefix(words.count)) == words else { continue }
            let trailing = Array(tokens.dropFirst(words.count))
            guard trailing.count <= 5,
                  !trailing.contains(where: { AgentDirectIntent.actionVerbs.contains($0) })
            else { continue }
            return true
        }
        return false
    }
}
