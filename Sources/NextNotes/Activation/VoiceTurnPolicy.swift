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

    /// A garbled ASR fragment that must be clarified before any planning round (P0-3).
    ///
    /// All four must hold: short (at most 12 characters or 2 tokens), no verb carrying
    /// an object, nothing `AgentDirectIntent` can act on, and no sound-alike of a known
    /// entity (that is a correction, not a garble). A miss costs one short question; a
    /// false positive would cost a full planning round on `"boys"`.
    static func isUncertainRequest(_ utterance: String, knownEntities: [String] = []) -> Bool {
        let normalized = AgentDirectIntent.normalize(utterance)
        guard !normalized.isEmpty else { return true }
        if AgentDirectIntent.parse(utterance) != nil { return false }
        if AgentEntityResolver.namingTarget(in: utterance) != nil { return false }
        if AgentEntityResolver.correctionTarget(in: utterance) != nil { return false }
        let tokens = AgentEntityResolver.tokens(normalized)
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 12 || tokens.count <= 2 else { return false }
        if hasVerbObjectPair(tokens) { return false }
        if !knownEntities.isEmpty,
           AgentEntityResolver.soundsLike(utterance, knownEntities: knownEntities) != nil { return false }
        return true
    }

    /// A verb from the deterministic tables carrying a later word as its object.
    private static func hasVerbObjectPair(_ tokens: [String]) -> Bool {
        for (index, token) in tokens.enumerated()
        where AgentDirectIntent.actionVerbs.contains(token) {
            if tokens[index...].count > 1 { return true }
        }
        return false
    }

    /// A bare acknowledgment of a pending offer: at most 3 tokens and no action verb.
    /// Only consulted when the coordinator holds a pending intent — without one,
    /// `"Okay."` is a garble, not an answer.
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
        // P0-3 garble gate: the short real utterances from agent-conversation.json.
        for text in ["boys", "Am", "Take it.", "Okay.", "hey win", "Hey we"]
        where !isUncertainRequest(text) {
            failures.append("garbled fragment was not held for clarification: \(text)")
        }
        for text in ["open Safari", "Summarise my emails, list tomorrow's events",
                     "note the four days called next note"]
        where isUncertainRequest(text) {
            failures.append("an actionable or answer-shaped request was held as garble: \(text)")
        }
        if isUncertainRequest("next note", knownEntities: ["Next Notes"]) {
            failures.append("a sound-alike of a known name was held as garble: next note")
        }
        if isUncertainRequest("") != true {
            failures.append("empty input was not held as garble")
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
