import Foundation

/// Turns a target app's profile into prompt-ready instruction text.
///
/// ## The integration seam
///
/// This is the one function the cleanup pass needs. It returns a block of rules, already
/// worded for a model, that says which formatting syntax the app about to receive the text
/// can actually render — and, just as importantly, which it cannot.
///
/// The intended call site is `CleanupInstructions.system(for:fixesGrammar:)`, appending
/// this block to the rule list:
///
/// ```swift
/// rules += OutputFormatInstructions.rules(
///     for: OutputProfileStore.shared.capturedProfile
/// )
/// ```
///
/// `rules(for:)` hands back an array of bare rule strings so it drops straight into that
/// existing `[String]` and gets the same `- ` bullet treatment as every other rule.
/// `block(for:)` is the same content as one pre-formatted string, for any caller that is
/// not building a list.
///
/// It is deliberately a pure function of a profile, with no reference to `Settings` or to
/// any formatter, so it can be wired in from either side without the two edits colliding.
///
/// One interaction worth flagging to whoever wires this up: `CleanupPreferences.formatsLists`
/// already says "turn enumerations of three or more items into Markdown lists". That rule
/// and this one overlap, and this one is the more specific — a target that cannot render
/// bullets must win over a global preference that asks for them. The two should be combined
/// so that lists are produced only when the preference asks for them *and* the target can
/// render them.
enum OutputFormatInstructions {

    /// The rules for one target, as individual lines ready to join a rule list.
    static func rules(for profile: OutputProfile) -> [String] {
        let name = profile.displayName.isEmpty ? "the focused app" : profile.displayName

        guard !profile.isPlain else {
            return [
                "The cleaned text will be typed into \(name), which shows formatting marks "
                    + "literally rather than rendering them. Write plain prose only.",
                "Use none of the following: "
                    + OutputCapability.allCases.map(\.prohibition).joined(separator: "; ")
                    + ". Write a spoken list as a sentence.",
                Self.neverInvent,
            ]
        }

        let supported = profile.sortedCapabilities
        let unsupported = OutputCapability.allCases.filter { !profile.capabilities.contains($0) }

        var lines = [
            "The cleaned text will be typed into \(name). It renders some formatting marks "
                + "and shows the rest literally.",
            "Where — and only where — the speaker actually spoke that structure, write it "
                + "like this: "
                + supported.map(\.instruction).joined(separator: "; ") + ".",
        ]

        if !unsupported.isEmpty {
            lines.append(
                "Never use the following, because \(name) shows the marks literally: "
                    + unsupported.map(\.prohibition).joined(separator: "; ") + "."
            )
        }

        lines.append(Self.neverInvent)
        return lines
    }

    /// The same content as one block, for a caller that is not assembling a rule list.
    static func block(for profile: OutputProfile) -> String {
        rules(for: profile).map { "- \($0)" }.joined(separator: "\n")
    }

    /// The rule that stops the capability list being read as an instruction to use it.
    ///
    /// Without this a target that supports tables gets three sentences of prose turned into
    /// a table, which is a far worse failure than leaving the text alone: the model treats
    /// "you may use X" as "X is wanted". Reflect the structure that was spoken, in the
    /// syntax the target understands — never add structure that was not.
    private static let neverInvent =
        "Never invent structure. Reflect only the structure the speaker actually spoke: "
        + "prose stays prose, and a spoken list stays a list. Do not turn sentences into a "
        + "list, a table, or a heading merely because the app can render one."
}
