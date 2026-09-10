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

    var id: String { bundleID }

    init(bundleID: String, displayName: String, capabilities: Set<OutputCapability> = []) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.capabilities = capabilities
    }

    /// Nothing rendered — the safe shape, and what every unknown app resolves to.
    static func plain(bundleID: String, displayName: String) -> OutputProfile {
        OutputProfile(bundleID: bundleID, displayName: displayName)
    }

    var isPlain: Bool { capabilities.isEmpty }

    /// Capabilities in a stable order, so the file does not churn between saves.
    /// `Set` has no order of its own and writing it unsorted would rewrite rows at random,
    /// which makes the file useless to diff and noisy under the watcher.
    var sortedCapabilities: [OutputCapability] {
        OutputCapability.allCases.filter { capabilities.contains($0) }
    }

    /// One line for the settings list.
    var summary: String {
        isPlain
            ? "Plain prose"
            : sortedCapabilities.map(\.displayName).joined(separator: ", ")
    }
}
