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
        // The preset is prose wrapped across lines, so the sentence is looked for with
        // whitespace folded: a plain `contains` misses "Take care with what\nmatters" and
        // reported the paragraph missing from a preset that plainly had it.
        func folded(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let care = "Take care with what matters"
        // The paragraph is in the preset, bundled and built-in alike.
        check("the base preset lacks the care paragraph",
              folded(PersonaStore.baseText).contains(care)
                && folded(PersonaStore.builtInBaseText).contains(care))
        if let bundled = PersonaStore.bundledBaseText {
            check("bundled base preset lacks the care paragraph", folded(bundled).contains(care))
        }
        // Every path is assembled against a throwaway store seeded from the base preset.
        // The shared store may hold the self-test's own edit, and the live `persona.md` is
        // free text the person wrote — a care eval run against either proves nothing about
        // the preset and, on a machine with a real persona, can never pass.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-persona-care-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonaStore(directory: directory)
        for path in AgentPromptPath.userFacingPaths {
            let context = AgentPromptContext.assemble(path, rules: "Be helpful.", personaStore: store)
            guard let personaRange = context.system.range(of: context.persona),
                  let overrideRange = context.system.range(of: AgentPromptContext.overrideLine) else {
                failures.append("care: \(path.rawValue) has no persona or override line")
                continue
            }
            check("\(path.rawValue) rules precede the persona",
                  personaRange.upperBound <= overrideRange.lowerBound)
            if !context.persona.isEmpty {
                check("\(path.rawValue) lost the care paragraph",
                      folded(context.persona).contains(care) || folded(context.system).contains(care))
            }
        }
        // The two prompts are documented here so the eval stays honest: a small model is
        // judged on whether its instructions contain the care rule, not on generated text
        // this self-test cannot run without a model.
        print("PERSONA_CARE_PROMPTS stuck=\(stuckPrompt) grief=\(griefPrompt)")
        return failures
    }
}
