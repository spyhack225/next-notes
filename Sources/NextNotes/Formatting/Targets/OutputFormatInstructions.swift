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
/// It carries two axes now, not one: what the app renders, and whether the app resolves a
/// path reference. `CleanupInstructions` appends this block last of all, *after* the list of
/// names harvested off the screen, so the names arrive first and the syntax for writing one
/// arrives immediately before the transcript. Do not move either half of that.
///
/// One interaction worth flagging to whoever wires this up: `CleanupPreferences.formatsLists`
/// already says "turn enumerations of three or more items into Markdown lists". That rule
/// and this one overlap, and this one is the more specific — a target that cannot render
/// bullets must win over a global preference that asks for them. The two should be combined
/// so that lists are produced only when the preference asks for them *and* the target can
/// render them.
enum OutputFormatInstructions {

    /// The rules for one target, as individual lines ready to join a rule list.
    ///
    /// Now also carries the path-reference rule. The plain branch below returns early, so
    /// `pathReferenceRules` has to be appended inside it too — an app can render nothing and
    /// still resolve @-paths, which is exactly Claude Code in a terminal, and it is the case
    /// the second axis exists for. Forgetting that branch would switch file tagging off for
    /// precisely the targets it was built for.
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
            ] + pathReferenceRules(for: profile)
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
        lines += pathReferenceRules(for: profile)
        return lines
    }

    /// How this target wants a resolved file reference written.
    ///
    /// Split out so the grounding block can be tested against it, and so the plain and
    /// non-plain branches of `rules(for:)` cannot drift — the mention rule has to appear in
    /// both, and two copies of a sentence this specific would have diverged the first time
    /// anyone reworded one of them.
    ///
    /// It sits at the *end* of the rule list on purpose, and that ordering is load-bearing.
    /// `CleanupInstructions` puts the list of harvested screen names before these rules, so
    /// the model reads the names first and reads how to write one last — which keeps the
    /// syntax rule attached to the syntax rather than to the list. See
    /// `CleanupInstructions.groundingRules`.
    ///
    /// A target that resolves nothing still gets a line, because the failure it prevents is
    /// real in the other direction: a model told a file name is on screen will reach for the
    /// syntax it saw most recently in training, and a literal `@src/auth/login.ts` in a sent
    /// email points at nothing and reads as a mistake.
    static func pathReferenceRules(for profile: OutputProfile) -> [String] {
        let name = profile.displayName.isEmpty ? "the focused app" : profile.displayName

        guard profile.resolvesPaths else {
            return [
                "\(name) does not resolve file references. Never use "
                    + PathReferenceStyle.plain.prohibition + ".",
            ]
        }

        return [
            "\(name) resolves file references. " + profile.pathReference.instruction,
            "Use that syntax only where the speaker was clearly naming a file, folder or app "
                + "— never on an ordinary noun that happens to appear in the list, and never "
                + "on a word you are unsure about. Never use "
                + profile.pathReference.prohibition + ".",
        ]
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
