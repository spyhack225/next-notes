import Foundation
enum CleanupEvalCases {
    static let target = OutputProfile(
        bundleID: "md.obsidian",
        displayName: "Obsidian",
        capabilities: [.markdown, .bullets, .numbered, .tables, .code]
    )

    struct PlanCase: Sendable {
        let id: String
        /// What the pass is supposed to do, in one line. Read as the grading rubric.
        let expectation: String
        let input: String
        /// Substrings the rendered layout must contain.
        var requires: [String] = []
        /// Substrings the rendered layout must not contain.
        var forbids: [String] = []
    }

    /// Marker-free edge cases: implicit and non-English enumerations, mixed
    /// prose-plus-list passages, and the prose the model must leave alone.
    static let planCases: [PlanCase] = [
        PlanCase(
            id: "P1-bare-sequence-is-prose",
            expectation: "three bare imperatives with no announcement are prose, not a list",
            input: "Ship the installer tonight. Write the release note tomorrow. "
                + "Tell the beta group when both are done.",
            requires: ["Ship the installer", "release note", "beta group"],
            forbids: ["1. ", "2. ", "- "]
        ),
        PlanCase(
            id: "P2-counted-no-envelope",
            expectation: "counted out loud without any envelope still becomes a list",
            input: "The first thing is the installer, it has to go out tonight. "
                + "The second thing is the release note for tomorrow. "
                + "The third thing is telling the beta group when both are done.",
            requires: ["1. ", "2. ", "3. ", "installer", "release note", "beta group"]
        ),
        PlanCase(
            id: "P3-fr-enumeration",
            expectation: "a French enumeration with no markers becomes a list",
            input: "Voici comment je vois la sortie de crise. Premièrement, on gèle les "
                + "embauches jusqu'en janvier. Deuxièmement, on reporte le déménagement du "
                + "bureau. Enfin, on prévient les clients avant vendredi. C'est tout pour moi.",
            requires: ["1. ", "2. ", "3. ", "embauches", "déménagement", "clients"],
            forbids: ["Premièrement,", "Deuxièmement,"]
        ),
        PlanCase(
            id: "P4-fr-announced",
            expectation: "a French announcer plus uncounted items becomes a list",
            input: "J'ai trois points pour toi. D'abord on règle la facturation. "
                + "Ensuite on déplace la réunion de jeudi. Pour finir on appelle le comptable.",
            requires: ["1. ", "2. ", "3. ", "facturation", "jeudi", "comptable"]
        ),
        // The passage behind `corroborationFailure`'s comment: four sentences of
        // ordinary prose that Apple's on-device model laid out as list items, twice out
        // of two. The plan must come back prose, or be turned down to prose.
        PlanCase(
            id: "P5-prose-stays-prose",
            expectation: "ordinary prose with no enumeration is never laid out as a list",
            input: "We finished the review this morning and everyone signed off on the plan. "
                + "The release is scheduled for Friday afternoon as discussed. "
                + "I will send the notes round once the build is green. "
                + "There is nothing else outstanding on my side at the moment.",
            requires: ["Friday afternoon", "build is green"],
            forbids: ["1. ", "2. ", "- "]
        ),
        PlanCase(
            id: "P6-mixed-prose-and-list",
            expectation: "an intro and a sign-off stay prose around the list they frame",
            input: "Okay, a few things that I need to change here. Let's see how we can "
                + "improve the graph first. The second thing is the skills page, it seems "
                + "like it needs more room. Third thing on the setting page, make it more "
                + "sleek and modern. That is it, thanks.",
            requires: ["1. ", "2. ", "3. ", "improve the graph", "That is it"],
            forbids: ["4. ", "5. "]
        ),
    ]

    /// The assertions for one plan case, as lines to print. Empty means it passed.
    static func planFailures(for testCase: PlanCase, rendered: String) -> [String] {
        var failures: [String] = []
        func show(_ text: String) -> String {
            text.replacingOccurrences(of: "\n", with: " \u{21B5} ")
        }
        for needle in testCase.requires
        where !rendered.localizedCaseInsensitiveContains(needle) {
            failures.append(
                "\(testCase.id): rendered layout is missing \(needle.debugDescription)\n"
                    + "      got: \(show(rendered))"
            )
        }
        for needle in testCase.forbids
        where rendered.localizedCaseInsensitiveContains(needle) {
            failures.append(
                "\(testCase.id): rendered layout still contains \(needle.debugDescription)\n"
                    + "      got: \(show(rendered))"
            )
        }
        return failures
    }
}
