import Foundation

/// The table Next Notes ships with, seeded into `formatting.txt` on first launch.
///
/// ## How these were decided
///
/// The test applied to every cell: **when text is inserted the way Next Notes inserts it,
/// does that mark help the person who reads the result, or does it show up as noise?**
///
/// That splits into two questions, and both matter:
///
/// 1. *Does the app convert the mark?* Apps fall into two mechanisms. **Paste-time
///    converters** (Notion, Linear) run a clipboard handler that replaces Markdown with
///    rich blocks. **Render-at-send apps** (Slack, Obsidian) keep the raw syntax in the
///    field and convert when the message is sent or the note is displayed. Apple's apps do
///    neither: Notes' "- " to bullet is a *typing-time* substitution that fires on Return,
///    so it never applies to text that was pasted or written through the accessibility API.
///
/// 2. *If it is not converted, how does it read?* This is the question that decides the
///    list marks, and it is not the same as the first. A line reading `- item` in a Slack
///    message is what a person would have typed by hand and reads as a list whether or not
///    Slack made it one. A line reading `**item**`, or a row of `|---|---|`, reads as
///    debris. So emphasis, headings and tables are switched on only where they are actually
///    rendered, while list marks are also allowed where they merely read correctly.
///
/// That distinction is exactly the case the user described: a spoken list should reach
/// Slack as bullets and Mail as a sentence. Slack messages are written in list marks every
/// day; Mail is prose correspondence, and a hyphen list in a rich-text email reads as
/// something that failed to format.
///
/// Where an app's behaviour could not be established, the answer is no. A capability that
/// is right three times in four is not worth having: it fails as literal punctuation in
/// something already sent to other people, while a missing capability only costs prose that
/// reads perfectly well.
///
/// ## What was checked
///
/// Bundle identifiers for Slack, Mail, Messages, Xcode, Cursor, Terminal, Safari, Chrome
/// and Notes were read off the installed bundles on this machine. Notion, Obsidian, Linear,
/// Visual Studio Code and iTerm were not installed and use their published identifiers —
/// the most likely thing in this file to be wrong, and it fails safe: an identifier that
/// matches nothing simply never resolves, and that app gets plain prose.
///
/// Rendering behaviour was checked against each app's own formatting documentation rather
/// than assumed. Two results overrode the obvious guess and are the reason this comment is
/// long: **Slack has no Markdown headings, no tables, and bold is a *single* asterisk**, so
/// `**bold**` would put four visible asterisks in a sent message; and **Notion's paste
/// parser handles pipe tables unreliably**, dropping them in as a paragraph or a code
/// block, so Notion has tables switched off despite Notion itself having tables.
///
/// One consequence worth knowing when reading this: `TextInjector` tries the accessibility
/// API first and falls back to pasting. Every app in the "converts on paste" group is
/// Electron, and `TextInjector` already documents that Electron accepts an AX write and
/// silently drops it — so those apps always end up on the paste path, which is the path
/// that converts. The two mechanisms line up rather than fighting.
enum OutputProfileDefaults {

    static let all: [OutputProfile] = [
        // MARK: Renders all of it

        // Not a conversion at all: the note *is* a Markdown file, so what is inserted is
        // stored verbatim and rendered by Live Preview and Reading view. The one app where
        // Markdown is unambiguously correct.
        OutputProfile(
            bundleID: "md.obsidian",
            displayName: "Obsidian",
            capabilities: [.markdown, .bullets, .numbered, .tables, .code]
        ),
        // Linear's editor documents that Markdown can be typed or pasted directly and is
        // converted to rich text, and it supports tables natively.
        OutputProfile(
            bundleID: "com.linear",
            displayName: "Linear",
            capabilities: [.markdown, .bullets, .numbered, .tables, .code]
        ),

        // MARK: Renders most of it

        // Notion converts pasted headings, emphasis, both list kinds and fenced code into
        // native blocks. Tables are the exception and are off: the live paste parser often
        // fails to recognise pipe syntax and leaves it as a paragraph or a code block, so a
        // spoken table would arrive as a wall of pipe characters. Notion has tables; this
        // is about what survives a paste, which is the only route text takes to get here.
        OutputProfile(
            bundleID: "notion.id",
            displayName: "Notion",
            capabilities: [.markdown, .bullets, .numbered, .code]
        ),

        // MARK: Renders some of it

        // Slack is the reason this is a set of capabilities rather than one style, and the
        // reason the two questions above are asked separately.
        //
        // Slack's mrkdwn has no headings and no tables, and its bold is `*one asterisk*` —
        // so Markdown emphasis and headings are off, because `**bold**` and `# Heading`
        // would be delivered as visible asterisks and a hash in a sent message. Triple
        // backticks *are* mrkdwn and do become a code block, so code is on.
        //
        // Lists are on for the second reason rather than the first: Slack does not convert
        // pasted `- item` into a list widget, but `- item` on its own line is how Slack
        // messages have always been written and reads as a list to whoever gets it.
        OutputProfile(
            bundleID: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            capabilities: [.bullets, .numbered, .code]
        ),
        // Same reasoning as Slack's lists, and only that. Notes' hyphen-to-bullet is a
        // typing substitution that fires on Return, so it never sees inserted text — but a
        // hyphen list in a personal note reads exactly as intended. Notes has no Markdown
        // emphasis or headings, its tables are a rich object that pipe syntax cannot
        // reach, and it has no fenced code block at all.
        OutputProfile(
            bundleID: "com.apple.Notes",
            displayName: "Notes",
            capabilities: [.bullets, .numbered]
        ),

        // MARK: Renders none of it

        // Mail composes rich text and parses no Markdown of any kind — it does not even
        // have the hyphen-to-list substitution the rest of the system has, so every mark
        // survives into a message that has been sent. Prose, which is what the user asked
        // for by name.
        .plain(bundleID: "com.apple.mail", displayName: "Mail"),
        // Messages parses nothing; its bold and italic arrive through a formatting menu.
        // Asterisks are delivered as asterisks.
        .plain(bundleID: "com.apple.MobileSMS", displayName: "Messages"),

        // Editors and terminals: the text is code, a command or a comment, and a formatting
        // mark is a syntax error or a stray character. A terminal is the sharpest case —
        // every newline in a bulleted list is a line the shell tries to run.
        .plain(bundleID: "com.apple.dt.Xcode", displayName: "Xcode"),
        .plain(bundleID: "com.microsoft.VSCode", displayName: "Visual Studio Code"),
        .plain(bundleID: "com.todesktop.230313mzl4w4u92", displayName: "Cursor"),
        .plain(bundleID: "com.apple.Terminal", displayName: "Terminal"),
        .plain(bundleID: "com.googlecode.iterm2", displayName: "iTerm"),

        // MARK: Browsers — the hard case, and deliberately plain
        //
        // A browser's bundle identifier says nothing about where the text is going. The
        // same Chrome window is a GitHub comment box that renders every mark, a Google Docs
        // document that renders none, a Gmail compose field, a Jira ticket with its own
        // unrelated syntax, and a one-line search box. Nothing available here tells those
        // apart: a tab title is not the focused field, and reading page content to guess
        // would mean inspecting whatever the user happens to have open — which is both a
        // privacy question and still only a guess.
        //
        // So the browsers get the safe answer rather than a coin flip. Plain prose is never
        // wrong in a way anyone can see; Markdown is wrong most of the time, and visibly.
        // A user who dictates into one site all day can widen this row themselves, which is
        // the whole point of the table being editable.
        .plain(bundleID: "com.apple.Safari", displayName: "Safari"),
        .plain(bundleID: "com.google.Chrome", displayName: "Chrome"),
    ]
}
