import Foundation

/// A deliberately narrow conversational backchannel rule. This is text policy,
/// not acoustic or semantic end-of-utterance detection. A local streaming EOU
/// model must be measured with real double-talk before replacing the VAD gate.
enum VoiceTurnPolicy {
    /// Standalone nonsemantic fillers are a request for time, not an executable
    /// instruction. Keep real words, answers and corrections out of this rule.
    static func isHesitation(_ text: String) -> Bool {
        let words = text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
        let fillers: Set<Substring> = ["uh", "um", "erm"]
        return !words.isEmpty && words.allSatisfy { fillers.contains($0) }
    }

    static func isBackchannel(_ text: String, whileAssistantSpeaking: Bool) -> Bool {
        guard whileAssistantSpeaking else { return false }
        let words = text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        guard !words.isEmpty, words.count <= 2 else { return false }
        // Lexical agreement can answer a question or revise an objective.
        // Only nonlexical listener noises are safe to absorb without context.
        return Set(["mm", "mhm", "mmhm", "uh huh", "mm hmm"])
            .contains(words.joined(separator: " "))
    }

    /// These phrases cancel the current objective when committed as a complete
    /// turn. A partial ASR fragment must never cancel work on speech onset.
    static func isExplicitWorkCancellation(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Set([
            "cancel that", "cancel the task", "cancel what you are doing",
            "stop working on that", "never mind", "nevermind", "forget that request"
        ]).contains(normalized)
    }

    // MARK: - Known noise (P0-3, producer-level)

    /// Exact ASR-noise signatures observed in live logs: lowercase, punctuation
    /// removed, whitespace collapsed. **Exact strings, never rules.**
    ///
    /// Producer-level rule, 2026-09-22. The first version of this gate guessed from
    /// *shape* — "at most 12 characters or 2 tokens, no verb-object pair" — and held
    /// "Can you hear me?" for clarification five turns in a row, because `normalize()`
    /// strips the leading fillers "can" and "you" and the remainder looked like a
    /// fragment. The class, not the instance, is the bug: a gate that guesses from shape
    /// will eventually eat a real question, silently, on the one path whose entire job
    /// is to answer people. A list that names its entries can only be wrong in one
    /// visible place, and it is graded against a positive corpus of ordinary speech.
    /// Everything not on this list goes to the model.
    static let knownNoiseFragments: Set<String> = [
        "boys", "am", "did", "take it", "okay", "ok", "hey we", "hey win",
        "um", "uh", "huh", "mm", "hmm",
    ]

    /// The noise key the utterance exactly matches, or nil. Nothing shape-based.
    static func knownNoiseFragment(in utterance: String) -> String? {
        let key = normalizedKey(utterance)
        return knownNoiseFragments.contains(key) ? key : nil
    }

    /// Lowercase, punctuation removed, whitespace collapsed — the list's own key form.
    static func normalizedKey(_ utterance: String) -> String {
        utterance
            .lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .joined(separator: " ")
    }

    /// Whole-turn closing signatures, in this file's own `normalizedKey` form.
    ///
    /// The rule this replaces was `lowered.contains` over a phrase list, and a substring
    /// anywhere in a turn ended the voice session **before the request was handed on** — the
    /// goodbye branch calls `closeSession()` and clears the announcement queue first, so the
    /// answer was probably never spoken and pending announcements were thrown away.
    /// "Is there nothing else on my calendar?", "Remind me to go to sleep at eleven.",
    /// "Tell me when we're done with the deck.", "Is that it for the budget?" and
    /// "Say goodbye to Ana in the email." all matched a fragment.
    ///
    /// No real instance was found — 0 of the audit's requests contain a goodbye phrase — so
    /// this is a **subtractive deterministic gate matched by fragment**, which is the class
    /// AGENTS.md bans on the voice path, and the class rather than the instance is the bug.
    /// Nothing here is a rule, a word count, or a `contains`: a turn closes only when its
    /// normalized key **equals** an entry, or is a closing lead followed by one. A list that
    /// names its entries can only be wrong in one visible place, and `selfTestFailures` grades
    /// it against a positive corpus of ordinary speech.
    static let closingSignatures: Set<String> = [
        "goodbye", "good bye", "bye", "bye bye",
        "that s all", "thats all", "that s it", "thats it",
        "that s it for now", "that s all for now", "that s it for tonight",
        "that s all thanks", "that s all thank you",
        "that s it thanks", "that s it thank you",
        "stop listening", "go to sleep", "nothing else",
        "nothing else thanks", "nothing else thank you",
        "we re done", "we are done", "i m done", "i am done",
    ]

    /// An acknowledgment before the signature: "Thanks, that's all." Closed as `lead + " " +
    /// signature` rather than by a `hasSuffix`, so "Remind me to go to sleep" can never match
    /// "go to sleep" however the list is read.
    static let closingLeads: Set<String> = [
        "thanks", "thank you", "ok", "okay", "great", "perfect", "no",
    ]

    /// Whether this turn closes the voice session. A whole key, or a lead plus a whole key.
    static func isClosingTurn(_ utterance: String) -> Bool {
        let key = normalizedKey(utterance)
        guard key.isEmpty == false else { return false }
        if closingSignatures.contains(key) { return true }
        for lead in closingLeads where key.hasPrefix(lead + " ") {
            if closingSignatures.contains(String(key.dropFirst(lead.count + 1))) { return true }
        }
        return false
    }

    /// Exact signatures that accept a pending offer or a worker's question, in this
    /// file's own `normalizedKey` form (lowercase, punctuation removed).
    ///
    /// This is the **one** acknowledgment vocabulary: P1-07 moved the voice list here and
    /// `PendingAction.isConfirmation` (typed) reads it, so a phrase can only be forgotten
    /// in one place. P3-08's spoken approvals are this set ∪ its approval-only words
    /// ("send it", "approve") — the approval-only half is deliberately *not* here, because
    /// a voice turn must not confirm an irreversible write by saying "do it".
    ///
    /// Membership, never a shape. The previous rule was "at most three tokens with no
    /// action verb", which is the class of bug AGENTS.md names: a shape heuristic on the
    /// conversational path eventually eats a real utterance, silently. Five ordinary
    /// confirmations — "yes please", "yeah sure", "go for it", "sure go ahead",
    /// "yes do it" — missed it and reached the frontend, so a worker's "Shall I set it for
    /// 10 pm?" was answered with a clarification instead of a reminder.
    ///
    /// No entry contains an action verb other than "do", "use" or "go", which is what
    /// keeps "yes send the email to Ana" out: a turn with a new instruction in it is a
    /// new request, and a gate may only resolve a pending offer, never invent one.
    static let acknowledgmentKeys: Set<String> = [
        "yes", "yeah", "yep", "sure", "ok", "okay", "aye",
        "do it", "use them", "use it", "go ahead", "sounds good", "please do",
        "yes please", "yeah sure", "go for it", "sure go ahead", "yes do it", "yes go ahead",
    ]

    /// Whether this utterance is a bare acknowledgment. Exact membership in
    /// `acknowledgmentKeys`; nil answer for anything else, including an instruction.
    ///
    /// Only consulted while a pending action is held — without one, `"Okay."` is noise,
    /// not an answer, and the noise gate answers for it exactly as before.
    static func isBareAcknowledgment(_ utterance: String) -> Bool {
        acknowledgmentKeys.contains(normalizedKey(utterance))
    }

    static func selfTestFailures() -> [String] {
        var failures: [String] = []

        // P1-15: a goodbye is a whole turn, not a fragment of one. Both corpora are pinned, and
        // the second one is the half that matters — a subtractive gate matched by substring is
        // wrong about ordinary speech whether or not it is ever right about a goodbye.
        for text in ["Goodbye.", "Bye!", "That's all.", "Thanks, that's all.",
                     "Okay, that's it for now.", "Stop listening.", "Go to sleep.",
                     "Nothing else, thanks.", "We're done.", "That's all, thank you."] {
            if isClosingTurn(text) == false {
                failures.append("a goodbye did not close the session: \(text)")
            }
        }
        // Every one of these is an ordinary request that the old substring rule closed on, or
        // would have. "Say goodbye to Ana in the email" and "that's all I need to know" are the
        // two that make the class obvious: both contain a goodbye phrase as a fragment of a
        // sentence about something else entirely.
        for text in ["Is there nothing else on my calendar?",
                     "Remind me to go to sleep at eleven.",
                     "Tell me when we're done with the deck.",
                     "Is that it for the budget?",
                     "Say goodbye to Ana in the email.",
                     "What's on my calendar? That's all I need to know",
                     "I'm done with the report, can you send it?",
                     "Thanks for the summary"] {
            if isClosingTurn(text) {
                failures.append("an ordinary request closed the session: \(text)")
            }
        }
        // The list grades itself: an entry nobody can say is a rule, not a signature, and a
        // signature that is only ever reachable as a lead's tail is a lead.
        for signature in closingSignatures {
            if isClosingTurn(signature) == false {
                failures.append("a closing signature does not close on its own: \(signature)")
            }
        }

        // P0-3: the short fragments from agent-conversation.json, by exact signature.
        for text in ["boys", "Am", "Take it.", "Okay.", "hey win", "Hey we", "did", "Uh"]
        where knownNoiseFragment(in: text) == nil {
            failures.append("a logged noise fragment was not recognised: \(text)")
        }
        // The positive corpus — ordinary speech the gate must never touch. Questions
        // first, because they are the class the shape heuristic ate. This half of the
        // fixture set was missing when the gate shipped, which is why it could stay
        // green while the app was unusable.
        for text in ["Can you hear me?", "can you hear me", "How are you doing?",
                     "What time is it?", "Are you there?", "What can you do?",
                     "Thanks, that's all", "yes", "no", "please",
                     "open Safari", "Summarise my emails, list tomorrow's events",
                     "note the four days called next note", "next note"] {
            if let key = knownNoiseFragment(in: text) {
                failures.append("ordinary speech was treated as noise (\(key)): \(text)")
            }
        }
        if knownNoiseFragment(in: "") != nil {
            failures.append("empty input matched the noise list")
        }
        // P0-6 bare acknowledgments resolve only against a pending intent.
        for text in ["yes", "use them", "do it", "Okay", "go ahead"] where !isBareAcknowledgment(text) {
            failures.append("missed bare acknowledgment: \(text)")
        }
        // P1-07: the shared vocabulary grades itself. Every key it publishes must be a
        // confirmation — a key nobody says is a hole in the one list the typed path, the
        // voice path and P3-08 all read — and a turn carrying a new instruction must not be
        // one, however short.
        for key in VoiceTurnPolicy.acknowledgmentKeys.sorted()
        where !isBareAcknowledgment(key) {
            failures.append("a published acknowledgment key is not accepted: \(key)")
        }
        for text in ["yes send the email to Ana", "okay, open Safari", "sure, cancel the last task",
                     "go ahead and delete it"]
        where isBareAcknowledgment(text) {
            failures.append("treated an instruction as a bare acknowledgment: \(text)")
        }
        for text in ["open Safari", "yes and open Safari", "use them to send it", "check my email"]
        where isBareAcknowledgment(text) {
            failures.append("treated an instruction as a bare acknowledgment: \(text)")
        }
        for text in ["Uh", "um...", "Uh, um"] where !isHesitation(text) {
            failures.append("did not retain a standalone hesitation: \(text)")
        }
        for text in ["yes", "no", "okay", "uh check my tools", "um cancel that", ""] where isHesitation(text) {
            failures.append("discarded meaningful or empty input as hesitation: \(text)")
        }
        for text in ["mm-hmm", "uh huh", "mhm"] {
            if !isBackchannel(text, whileAssistantSpeaking: true) {
                failures.append("lost overlapping acknowledgment: \(text)")
            }
        }
        for text in ["yeah", "right", "okay", "yes", "got it", "yeah, but open Safari",
                     "right, stop that", "okay what next", "no", "check mail"] {
            if isBackchannel(text, whileAssistantSpeaking: true) {
                failures.append("suppressed a possible correction: \(text)")
            }
        }
        if isBackchannel("yes", whileAssistantSpeaking: false) {
            failures.append("suppressed an answer when assistant was quiet")
        }
        for phrase in ["Cancel that.", "Never mind", "Stop working on that"] {
            if !isExplicitWorkCancellation(phrase) {
                failures.append("missed explicit work cancellation: \(phrase)")
            }
        }
        for phrase in ["stop talking", "cancel that and open Safari", "never mind the color"] {
            if isExplicitWorkCancellation(phrase) {
                failures.append("cancelled an ambiguous instruction: \(phrase)")
            }
        }
        return failures
    }
}
