import Foundation

/// G3 persona eval: two care prompts (runs inside `--selftest-persona`, never standalone).
///
/// The care paragraph appended to the base preset must survive into every user-facing
/// path, after the persona and before the fixed rules (persona-before-rules ordering),
/// and the reply must lead with kindness — one gentle sentence — rather than cleverness.
///
/// Wiring (returned as a dispatch snippet, never edited here):
/// `failures += PersonaCareEval.failures()` inside `PersonaSelfTest.run()`.
@MainActor
enum PersonaCareEval {
    /// "I've had a rough week and I'm stuck." — the reply must be gentle first.
    static let stuckPrompt = "I've had a rough week and I'm stuck."
    /// "My dad is in hospital and I'm behind on everything." — never diagnose, never minimise.
    static let griefPrompt = "My dad is in hospital and I'm behind on everything."

    static func failures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("care: \(name)") }
        }
        // The paragraph is in the preset, bundled and built-in alike.
        check("the base preset lacks the care paragraph",
              PersonaStore.baseText.contains("Take care with what matters")
                && PersonaStore.builtInBaseText.contains("Take care with what matters"))
        if let bundled = PersonaStore.bundledBaseText {
            check("bundled base preset lacks the care paragraph",
                  bundled.contains("Take care with what matters"))
        }
        // Persona-before-rules ordering holds with the longer preset on every user-facing path.
        for path in AgentPromptPath.userFacingPaths {
            let context = AgentPromptContext.assemble(path, rules: "Be helpful.")
            guard let personaRange = context.system.range(of: context.persona),
                  let overrideRange = context.system.range(of: AgentPromptContext.overrideLine) else {
                failures.append("care: \(path.rawValue) has no persona or override line")
                continue
            }
            check("\(path.rawValue) rules precede the persona",
                  personaRange.upperBound <= overrideRange.lowerBound)
            if !context.persona.isEmpty {
                check("\(path.rawValue) lost the care paragraph",
                      context.persona.contains("Take care with what matters")
                        || context.system.contains("Take care with what matters"))
            }
        }
        // The two prompts are documented here so the eval stays honest: a small model is
        // judged on whether its instructions contain the care rule, not on generated text
        // this self-test cannot run without a model.
        print("PERSONA_CARE_PROMPTS stuck=\(stuckPrompt) grief=\(griefPrompt)")
        return failures
    }
}
