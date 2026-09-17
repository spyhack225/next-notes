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

    static func selfTestFailures() -> [String] {
        var failures: [String] = []
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
