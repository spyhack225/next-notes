import Foundation

/// One thing a target app can render when plain text is pasted into it.
///
/// Capabilities rather than a single "style" because real apps support different subsets
/// and the differences are not on one axis. Slack takes bullets and fenced code but shows
/// a pipe table as pipes; Mail renders none of it; Obsidian renders all of it. A single
/// enum of styles would have to invent a name for every combination, and would still be
/// wrong for the next app.
enum OutputCapability: String, CaseIterable, Codable, Sendable, Hashable {
    /// Headings, bold, italic, links — the inline and block marks that are not lists.
    case markdown
    case bullets
    case numbered
    case tables
    /// Fenced code blocks.
    case code

    /// What the file calls it. Same as the raw value; named so the parser and the writer
    /// are obviously reading and writing the same vocabulary.
    var token: String { rawValue }

    var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .bullets: "Bullets"
        case .numbered: "Numbered"
        case .tables: "Tables"
        case .code: "Code"
        }
    }

    /// The column header in the Settings table. A symbol rather than a word because five
    /// text headers do not fit the settings window's width.
    var systemImage: String {
        switch self {
        case .markdown: "textformat"
        case .bullets: "list.bullet"
        case .numbered: "list.number"
        case .tables: "tablecells"
        case .code: "curlybraces"
        }
    }

    /// The column header's tooltip, and the closest thing to a definition the user gets.
    var help: String {
        switch self {
        case .markdown: "Headings, bold and links — # and ** marks"
        case .bullets: "Bulleted lists written as \"- item\""
        case .numbered: "Numbered lists written as \"1. item\""
        case .tables: "Pipe tables"
        case .code: "Fenced code blocks"
        }
    }

    /// How the model is told to write this, when the target renders it.
    var instruction: String {
        switch self {
        case .markdown:
            "spoken emphasis or a spoken heading: Markdown (** for bold, # for a heading)"
        case .bullets:
            "a spoken list of items: one \"- item\" per line"
        case .numbered:
            "a spoken numbered sequence: one \"1. item\" per line"
        case .tables:
            "spoken rows and columns: a Markdown pipe table"
        case .code:
            "spoken code, a command, or a file path listing: a ``` fenced block"
        }
    }

    /// How it is named in the prohibition list, when the target does *not* render it.
    var prohibition: String {
        switch self {
        case .markdown: "Markdown headings or emphasis (#, **, __)"
        case .bullets: "bulleted lists or \"-\" line marks"
        case .numbered: "numbered lists"
        case .tables: "tables of any kind"
        case .code: "``` code fences"
        }
    }
}

/// How a target turns a path into something the reader — or the agent — can act on.
///
/// A second axis, separate from `OutputCapability` on purpose. The concrete difference:
/// pasting `/Users/me/app/src/auth/login.ts` into Claude Code gives it a string, and pasting
/// `@src/auth/login.ts` gives it a file it goes and reads. That is not formatting — the
/// characters render identically either way — it is whether the receiving app has a
/// reference syntax. Slack renders code fences and resolves nothing; Claude Code renders no
/// Markdown and resolves everything. A sixth `OutputCapability` case would put those two on
/// one axis and make this file argue with itself.
///
/// Three cases and no more, because each one is an app behaviour somebody checked, and
/// "probably" is not a case.
enum PathReferenceStyle: String, CaseIterable, Codable, Sendable, Hashable {
    /// No reference syntax. Write the name as words. Every unknown app, and the default.
    case plain = "plain"
    /// @-prefixed project-relative path, resolved by the app: Claude Code, Cursor's
    /// composer, Windsurf's Cascade.
    case atRelative = "at-paths"
    /// A backticked relative path — not resolved by anything, but it survives as a path
    /// instead of being read as prose, which is the whole win in Slack and on GitHub.
    case backtickPath = "backtick-paths"

    /// What the file calls it. Same as the raw value, named for the same reason
    /// `OutputCapability.token` is.
    var token: String { rawValue }

    var displayName: String {
        switch self {
        case .plain: "Plain words"
        case .atRelative: "@-paths"
        case .backtickPath: "Backticked paths"
        }
    }

    /// The Settings column tooltip, and the closest thing to a definition the user gets.
    var help: String {
        switch self {
        case .plain:
            "Writes a file name as words. Nothing is resolved."
        case .atRelative:
            "Resolves @src/auth/login.ts into the file itself"
        case .backtickPath:
            "Keeps a path readable as a path, but resolves nothing"
        }
    }

    /// The column cell and header symbol in the Settings table.
    ///
    /// A symbol for the same reason `OutputCapability.systemImage` is one: six columns of
    /// words do not fit the settings window, and a cell wide enough for "backtick-paths"
    /// would be wider than the app-name column it sits beside. The words are still there,
    /// one click away, inside the menu the symbol opens.
    var systemImage: String {
        switch self {
        case .plain: "text.alignleft"
        case .atRelative: "at"
        case .backtickPath: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// How the model is told to write a resolved reference, with an example. Empty for
    /// `.plain`, whose rule is a prohibition instead — see `prohibition`.
    var instruction: String {
        switch self {
        case .plain:
            ""
        case .atRelative:
            "When you write one of those names as a file reference, write it as an "
                + "@-prefixed project-relative path with no space after the @: "
                + "\"@src/auth/login.ts\", not \"the login.ts file\" and not "
                + "\"/Users/me/app/src/auth/login.ts\". Use the path shown in parentheses "
                + "beside the name; where no path is shown, write just the name after the @."
        case .backtickPath:
            "When you write one of those names as a file reference, wrap it in single "
                + "backticks: \"`src/auth/login.ts`\". Use the path shown in parentheses "
                + "beside the name; where no path is shown, backtick just the name."
        }
    }

    /// The syntaxes this target does *not* resolve, named for the prohibition list.
    ///
    /// Every case has one, including the two that do resolve something: an @-path delivered
    /// into Slack arrives as a literal @ and points at nothing, which is the same class of
    /// failure as `**bold**` in Mail and is why `OutputCapability` has this property too.
    var prohibition: String {
        switch self {
        case .plain:
            "@-prefixed paths (@src/auth/login.ts) and backticked paths "
                + "(`src/auth/login.ts`) — write the name as words instead"
        case .atRelative:
            "backticked paths; the @ form is the one this app resolves"
        case .backtickPath:
            "@-prefixed paths, which arrive here as a literal @ and resolve to nothing"
        }
    }
}

/// What one app can be given, keyed by its bundle identifier.
///
/// `id` is the bundle identifier rather than a fresh UUID — unlike a dictionary entry,
/// two profiles for one app are never meaningful, so the app *is* the identity. That is
/// what makes "add the frontmost app" idempotent and what lets the file be deduplicated
/// on load without guessing which of two rows the user meant.
struct OutputProfile: Codable, Identifiable, Sendable, Hashable {
    var bundleID: String
    var displayName: String
    var capabilities: Set<OutputCapability>
    /// Whether this app resolves path references, and in what syntax. A second axis from
    /// `capabilities`; see `PathReferenceStyle`.
    var pathReference: PathReferenceStyle

    var id: String { bundleID }

    init(
        bundleID: String,
        displayName: String,
        capabilities: Set<OutputCapability> = [],
        pathReference: PathReferenceStyle = .plain
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.capabilities = capabilities
        self.pathReference = pathReference
    }

    /// Nothing rendered and nothing resolved — the safe shape, and what every unknown app
    /// resolves to. Unchanged signature, so no existing call site moves.
    static func plain(bundleID: String, displayName: String) -> OutputProfile {
        OutputProfile(bundleID: bundleID, displayName: displayName)
    }

    /// Still `capabilities.isEmpty`, and deliberately *not* widened to include
    /// `pathReference`.
    ///
    /// It drives the "plain" token in field three of `formatting.txt` and the plain branch
    /// of the prompt, and both of those are about rendering. Claude Code in a terminal
    /// renders nothing and resolves everything: it is `isPlain`, and it is the case this
    /// second axis exists for.
    var isPlain: Bool { capabilities.isEmpty }

    /// True when this app resolves references at all.
    ///
    /// The property `OutputFormatInstructions` and the row view branch on, so neither of
    /// them repeats `!= .plain` and neither can drift from the other when a fourth style is
    /// one day argued for.
    var resolvesPaths: Bool { pathReference != .plain }

    /// Capabilities in a stable order, so the file does not churn between saves.
    /// `Set` has no order of its own and writing it unsorted would rewrite rows at random,
    /// which makes the file useless to diff and noisy under the watcher.
    var sortedCapabilities: [OutputCapability] {
        OutputCapability.allCases.filter { capabilities.contains($0) }
    }

    /// One line for the settings list.
    var summary: String {
        let rendering = isPlain
            ? "Plain prose"
            : sortedCapabilities.map(\.displayName).joined(separator: ", ")
        return resolvesPaths ? "\(rendering) · \(pathReference.displayName)" : rendering
    }

    // MARK: - Codable, written by hand

    private enum CodingKeys: String, CodingKey {
        case bundleID, displayName, capabilities, pathReference
    }

    /// Hand-written because the synthesized decoder does not use default values.
    ///
    /// This is the trap worth naming: giving `pathReference` a default in `init` does
    /// nothing for `init(from:)` — Swift synthesizes a `decode(_:forKey:)` for every
    /// non-Optional property and throws `keyNotFound` on a payload written by an older
    /// build, and users have profile files already. Both new-ish keys are therefore
    /// `decodeIfPresent`.
    ///
    /// Both are also decoded as raw strings and mapped, rather than decoded as the enums
    /// directly: a `RawRepresentable` `Codable` enum throws on a raw value it does not know,
    /// so a profile written by a *newer* build would fail to decode whole rather than losing
    /// the one word it could not read. Mapping leniently keeps the same safety direction the
    /// file parser already has — an unrecognised word can only ever remove a capability,
    /// never grant one, and an unrecognised reference style falls back to resolving nothing.
    ///
    /// `encode(to:)` stays synthesized, so the keys on both sides remain the ones above.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = try container.decode(String.self, forKey: .displayName)
        capabilities = Set(
            (try container.decodeIfPresent([String].self, forKey: .capabilities) ?? [])
                .compactMap(OutputCapability.init(rawValue:))
        )
        pathReference = PathReferenceStyle(
            rawValue: try container.decodeIfPresent(String.self, forKey: .pathReference) ?? ""
        ) ?? .plain
    }
}
