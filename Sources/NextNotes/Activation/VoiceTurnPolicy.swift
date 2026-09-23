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

    /// A bare acknowledgment of a pending offer: at most 3 tokens and no action verb.
    /// Only consulted when the coordinator holds a pending intent — without one,
    /// `"Okay."` is noise, not an answer.
    static func isBareAcknowledgment(_ utterance: String) -> Bool {
        let tokens = AgentEntityResolver.tokens(utterance.lowercased())
        guard !tokens.isEmpty, tokens.count <= 3 else { return false }
        if tokens.contains(where: { AgentDirectIntent.actionVerbs.contains($0) }) { return false }
        let joined = tokens.joined(separator: " ")
        return [
            "yes", "yeah", "yep", "sure", "ok", "okay", "aye",
            "do it", "use them", "use it", "go ahead", "sounds good", "please do",
        ].contains(joined)
    }

    static func selfTestFailures() -> [String] {
        var failures: [String] = []
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
