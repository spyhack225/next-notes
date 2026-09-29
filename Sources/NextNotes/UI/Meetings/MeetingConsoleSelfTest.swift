import Foundation

/// `--selftest-meeting-console` — the meeting panel's table, its wiring, and the rule that
/// keeps a view file out of literal values.
///
/// A value-level test by design, like `AgentPaneSelfTest`: it reads the enums and the
/// sources, so it needs no window, no grant, no meeting and no model. What it cannot take
/// on trust is the honesty of the orb table, because "the panel says a turn is in flight"
/// is exactly the kind of claim that reads as a feature and is a lie when the work is not
/// running — so the mapping is asserted against the vocabulary in `AGENTS.md` row by row,
/// and a section's headline capability is asserted rather than assumed.
///
/// The literal scan is checked against a source that *does* contain an offender, so a
/// matcher that has quietly stopped catching anything fails here rather than passing on
/// five clean files.
@MainActor
enum MeetingConsoleSelfTest {
    /// The five files this check owns, relative to `Sources/NextNotes/`. The tokens they
    /// use live in `DesignSystem.swift`, which is why that file is not here: a token's own
    /// value is a number on purpose.
    private static let ownedFiles = [
        "UI/Meetings/MeetingConsoleSheet.swift",
        "UI/Meetings/MeetingConsoleNotesSection.swift",
        "UI/Meetings/MeetingConsoleActionsSection.swift",
        "UI/Meetings/MeetingConsoleHistorySection.swift",
        "UI/Meetings/MeetingConsoleAskSection.swift",
    ]

    /// Read for the wiring below rather than for its layout: the live view is older than
    /// this feature and its own `VStack(spacing: 0)` predates it, so scanning it would
    /// report a pre-existing house pattern as this feature's mistake.
    private static let liveViewFile = "UI/Meetings/MeetingLiveView.swift"

    /// The calls whose arguments are values rather than words. A `spacing:` label is here
    /// for the same reason: `HStack(spacing: 7)` looks nothing like a layout bug and is
    /// one.
    private static let valueSites = [
        ".frame(", ".padding(", ".cornerRadius(", ".spacing(", ".font(", "font:", "spacing:",
    ]

    static func run() -> Bool {
        var failures: [String] = []
        var checks = 0

        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            checks += 1
            if condition {
                SelfTest.diagnostic("  ok   \(message())")
            } else {
                let text = message()
                SelfTest.diagnostic("  FAIL \(text)")
                failures.append(text)
            }
        }

        // MARK: The activity table

        // Every case is walked, not sampled: the failure this test exists to catch is a
        // case nobody exercised, so `allCases` has to be the loop and the expected
        // mapping has to be exhaustive over it.
        let activities: [MeetingConsoleActivity] = [
            .idle, .transcribing, .writingNotes, .findingActions, .lookingBack, .thinking,
        ]
        // Read off the type, not off a list typed out here. The count check below is what
        // makes the two worth having: a case added to the enum and not to `activities` is a
        // case the mapping loop never walks, and that is the only failure this file exists
        // to catch.
        let allCases = MeetingConsoleActivity.allCases
        expect(allCases.count == activities.count,
               "the table has \(activities.count) cases and \(allCases.count) were written down")

        // Which orb each case must carry, from the vocabulary table in `AGENTS.md`. `nil`
        // is a real answer here and is the only one: an orb says which long thing is
        // happening, and a panel that is sitting there is not doing one.
        let expectedOrbs: [MeetingConsoleActivity: OrbGeometry.State?] = [
            .idle: nil,
            .transcribing: .weaving,
            .writingNotes: .composing,
            .findingActions: .searching,
            .lookingBack: .searching,
            .thinking: .searching,
        ]
        let orbStates = Set(OrbGeometry.State.allCases)
        for activity in activities {
            guard let expected = expectedOrbs[activity] else {
                expect(false, "\(activity) has no orb written down")
                continue
            }
            expect(activity.orb == expected,
                   "\(activity) draws \(expected.map { String(describing: $0) } ?? "no orb")")
            if let orb = activity.orb {
                // Typed, so this cannot fail to compile — which is the point of stating
                // it: a tenth state added to the geometry has to be noticed here, because
                // the table above is the app's claim that there are nine.
                expect(orbStates.contains(orb), "\(activity)'s orb is one of the nine states")
            }
        }

        expect(allCases.filter { $0.orb == nil } == [.idle],
               "idle is the only activity without an orb")
        expect(allCases.filter { !$0.isBusy } == [.idle],
               "idle is the only activity that is not busy")

        let ownTurn = UUID()
        let otherTurn = UUID()
        expect(MeetingConsoleAskWork.owns(activeTurnID: ownTurn, currentTurnID: ownTurn,
                                          isThinking: true),
               "Ask reports work only while its own turn is active")
        expect(!MeetingConsoleAskWork.owns(activeTurnID: ownTurn, currentTurnID: otherTurn,
                                           isThinking: true),
               "another Agent or voice turn is not Ask's work")
        expect(!MeetingConsoleAskWork.owns(activeTurnID: ownTurn, currentTurnID: ownTurn,
                                           isThinking: false),
               "a finished Ask turn is not still in progress")

        var busyTitles: [String: MeetingConsoleActivity] = [:]
        for activity in allCases where activity.isBusy {
            expect(!activity.title.isEmpty, "\(activity) has a title for the status row")
            if let other = busyTitles[activity.title] {
                expect(false, "\(activity) and \(other) are both called "
                        + "\u{201C}\(activity.title)\u{201D} — the status row cannot say which")
            } else {
                busyTitles[activity.title] = activity
                expect(true, "\(activity) is the only activity called "
                        + "\u{201C}\(activity.title)\u{201D}")
            }
        }

        // MARK: The sections, in rail order

        // `allCases` *is* the rail: `MeetingConsoleSheet` draws one row per case. So the
        // order below is the order on screen, and asserting it is asserting the rail.
        expect(MeetingConsoleSection.allCases == [.notes, .actions, .history, .ask],
               "the rail is Notes, Actions, History, Ask")

        var ids: Set<String> = []
        var titles: Set<String> = []
        var symbols: Set<String> = []
        for section in MeetingConsoleSection.allCases {
            expect(ids.insert(section.id).inserted, "\(section.id) is a unique identifier")
            expect(titles.insert(section.title).inserted, "\(section.title) names one section")
            expect(symbols.insert(section.symbol).inserted,
                   "\(section.symbol) is one mark per section")
            expect(!section.title.isEmpty, "\(section) has a rail title")
            expect(!section.symbol.isEmpty, "\(section) has a mark")
            let help = section.help.trimmingCharacters(in: .whitespacesAndNewlines)
            expect(!help.isEmpty, "\(section) says what it is in its help")
            expect(!help.contains("\n"), "\(section)'s help is one sentence")
        }

        // MARK: The section each capability got

        // Asserted, not assumed. The whole feature is four promises, and "the ask surface
        // ended up in History" compiles, runs, and is the bug nobody would file a report
        // about — so each row names the section the promise was made about.
        let promised: [MeetingConsoleSection: (capability: String, symbol: String)] = [
            .notes: ("the hand-written surface", "pencil"),
            .actions: ("what the meeting agreed to do", "list.bullet.rectangle"),
            .history: ("the look back at earlier meetings", "clock.arrow.circlepath"),
            .ask: ("the assistant", "message.fill"),
        ]
        expect(promised.count == MeetingConsoleSection.allCases.count,
               "every section is a promise this test knows about")
        for section in MeetingConsoleSection.allCases {
            guard let promise = promised[section] else {
                expect(false, "\(section) is not one of the four promised sections")
                continue
            }
            expect(section.symbol == promise.symbol,
                   "\(section) is \(promise.capability) — it is marked \(section.symbol)")
        }

        // MARK: The window is not presentable under a self-test

        // A window can keep `NSApp.terminate` from completing, so a self-test that raised
        // one could print its result and then hang. Both directions: the policy refuses
        // here and still allows the window in the app.
        expect(!MeetingConsolePolicy.shouldPresent(isSelfTest: true),
               "the panel is never presented during a self-test")
        expect(MeetingConsolePolicy.shouldPresent(isSelfTest: false),
               "…and is presented in the app")
        expect(!MeetingConsolePolicy.shouldPresent(isSelfTest: SelfTest.isRunning),
               "…which is the answer this run got")

        // MARK: The files

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var sources: [String: String] = [:]
        for relative in ownedFiles + [liveViewFile] {
            let url = root.appendingPathComponent(relative)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                expect(false, "cannot read \(relative)")
                continue
            }
            sources[relative] = source
        }

        // MARK: It is actually wired in

        // A policy nothing calls is a comment with a type on it — the same trap as the
        // finished feature with no call site. So the two ends of the wire are read out of
        // the source rather than assumed: the button, and the sheet it puts up.
        if let live = sources[liveViewFile] {
            expect(live.contains("MeetingConsolePolicy.shouldPresent"),
                   "the live meeting view asks whether a panel may be presented")
            expect(live.contains("MeetingConsoleWindowController.shared.show(session: session)"),
                   "the live meeting view opens the movable window")
            // The button is gated on the same rule as the sheet, not the sheet alone. A
            // self-test that drew the control with no panel behind it would carry a button
            // that does nothing, which is the one state this gate exists to prevent — and
            // that is exactly what the first version of the wiring did.
            expect(live.contains("if showsConsole { consoleButton }"),
                   "the panel's own button is gated on the same rule as the panel")
        }
        if let sheet = sources["UI/Meetings/MeetingConsoleSheet.swift"] {
            expect(sheet.contains("styleMask: [.titled, .closable, .miniaturizable, .resizable]"),
                   "the meeting window can move, close, and resize")
            expect(sheet.contains("Button(\"Close\", systemImage: \"xmark\""),
                   "the meeting window has a visible Close button")
            for section in MeetingConsoleSection.allCases {
                let capitalised = String(section.rawValue.prefix(1)).uppercased()
                    + String(section.rawValue.dropFirst())
                let type = "MeetingConsole\(capitalised)Section"
                expect(sheet.contains("\(type)(session: session"),
                       "the panel draws \(section.title) from \(type)")
            }
            // The rail is the whole of `allCases`, and one shape per screen.
            expect(sheet.contains("ForEach(MeetingConsoleSection.allCases)"),
                   "the rail draws one row per section")
            // One shape per screen, and the panel's is the app's own status line rather
            // than a canvas drawn here: `LabeledOrb` exists so an orb is never set down
            // without the sentence that names it.
            expect(!sheet.contains("ThinkingOrb("),
                   "the panel builds no orb of its own — the one it draws is LabeledOrb's")
            expect(sheet.contains("LabeledOrb("),
                   "…and it draws that one through LabeledOrb")
        }
        if let notes = sources["UI/Meetings/MeetingConsoleNotesSection.swift"] {
            expect(notes.contains("MeetingRichEditor(html: documentHTML, markdown: document)"),
                   "the notes page uses the direct rich editor")
            expect(notes.contains("richHTML: html") && notes.contains("documentHTML = saved.richHTML"),
                   "rich formatting is saved and restored through the scratchpad")
        }
        if let resources = MeetingRichEditor.resourceDirectory {
            let html = resources.appendingPathComponent("index.html")
            let css = resources.appendingPathComponent("style.css")
            let script = resources.appendingPathComponent("editor.js")
            expect(FileManager.default.fileExists(atPath: html.path)
                   && FileManager.default.fileExists(atPath: css.path)
                   && FileManager.default.fileExists(atPath: script.path),
                   "the rich editor's local page, styles, and script are bundled")
            let page = (try? String(contentsOf: html, encoding: .utf8)) ?? ""
            expect(page.contains("connect-src 'none'"),
                   "the local editor page blocks network connections")
        } else {
            expect(false, "the rich editor's local files can be found")
        }

        // MARK: No literal values in a view

        for relative in ownedFiles {
            guard let source = sources[relative] else { continue }
            let offenders = literalValueOffenders(in: source)
            expect(offenders.isEmpty,
                   offenders.isEmpty
                       ? "\(relative) uses tokens for every value it draws"
                       : "\(relative): " + offenders.map(\.description).joined(separator: "; "))
        }

        // …and the matcher itself, in all three directions. A scan that cannot fail is not a
        // scan: the canary carries one offender per line and the rule's own examples, so a
        // matcher that stopped catching them fails here instead of passing on five clean
        // files.
        let canary = """
        Text("a").frame(width: 520)
        Text("b").padding(20)
        HStack(spacing: 7) { Text("c") }
        Text("d").font(.system(size: 12))
        Text("e").cornerRadius(8)
        VStack(spacing: 0) { Divider() }
        """
        let caught = literalValueOffenders(in: canary)
        expect(caught.map(\.line) == [1, 2, 3, 4, 5],
               "the scan finds one offender on each of the canary's five offending lines "
                   + "(found lines \(caught.map(\.line)))")
        // The second canary: the same shapes spelled through `DS`, which is what the clean
        // files look like. Without this half a matcher that flagged *everything* would pass
        // the check above.
        let tokenised = """
        Text("a").frame(width: DS.Size.meetingConsoleMinWidth)
        VStack(spacing: DS.Space.l) { Text("b").padding(.horizontal, DS.Space.page) }
        """
        expect(literalValueOffenders(in: tokenised).isEmpty,
               "…and does not mistake a token for one")
        // Line 6 of the canary is the exemption, and it is checked here rather than left to
        // the clean files: `VStack(spacing: 0)` means *no gap*, which is the absence of a
        // value and the modifier's own default, and `DS.Space` has no token for it because
        // the 4pt grid starts at 2. Without this line the exemption would be a hole with
        // nothing standing in it.
        let zero = """
        VStack(spacing: 0) { Divider() }
        Text("z").padding(0)
        """
        expect(literalValueOffenders(in: zero).isEmpty,
               "…and reads a zero as the absence of a value rather than as a magnitude")
        // Comments name numbers on purpose, and so do strings.
        let prose = """
        // the panel is 520 wide and a row is 44
        /* .frame(width: 20) */
        let caption = "20 minutes"
        Text("x").frame(width: DS.Size.meetingConsoleMinWidth)
        """
        expect(literalValueOffenders(in: prose).isEmpty,
               "…and reads neither a comment nor a string as a value")

        // MARK: Verdict

        if failures.isEmpty {
            SelfTest.diagnostic("MEETING_CONSOLE_OK")
            return true
        }
        for failure in failures { SelfTest.diagnostic("MEETING_CONSOLE_FAILED: \(failure)") }
        SelfTest.diagnostic("MEETING_CONSOLE_FAILED")
        return false
    }
    // MARK: - The literal scan

    /// One place a number reached a layout without a token behind it.
    private struct LiteralValue {
        let line: Int
        let site: String
        let argument: String

        var description: String { "line \(line): \(site)\(argument)" }
    }

    /// Every `.frame(…)`, `.padding(…)`, `spacing:` and the rest whose argument carries a
    /// number and does not come from `DS`.
    ///
    /// The rule is the design system's own — *views must not contain literal values* — so
    /// it is read out of the source rather than out of a rendered view: the offending value
    /// is usually inside a modifier whose result nobody can measure, and a rendered frame
    /// would report the symptom rather than the cause.
    ///
    /// Comments come off first, so a comment that names a number (`520`, a "44pt" target)
    /// is not an offender. What is left is a judgement about the argument text:
    /// `.padding(.horizontal, DS.Space.page)` has no number in it and is not a value at
    /// all, and `.frame(width: DS.Size.meetingConsoleMinWidth)` spells where its number came
    /// from. A bare `.frame(width: 520)` is the shape being hunted.
    private static func literalValueOffenders(in source: String) -> [LiteralValue] {
        let text = strippingComments(source)
        var offenders: [LiteralValue] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let site = valueSites.first(where: { text[cursor...].hasPrefix($0) }) else {
                cursor = text.index(after: cursor)
                continue
            }
            let start = cursor
            let argument = argumentText(in: text, from: text.index(start, offsetBy: site.count))
            cursor = text.index(start, offsetBy: site.count)
            guard let argument else {
                // A source that never closes its call: report the rest of the line rather
                // than skipping the site, so a truncated file cannot read as a clean one.
                offenders.append(LiteralValue(
                    line: line(of: start, in: text), site: site, argument: "…unterminated"
                ))
                continue
            }
            guard argument.rangeOfCharacter(from: .decimalDigits) != nil,
                  !argument.contains("DS."), carriesMagnitude(argument) else {
                cursor = text.index(cursor, offsetBy: argument.count)
                continue
            }
            offenders.append(LiteralValue(
                line: line(of: start, in: text), site: site, argument: argument
            ))
            cursor = text.index(cursor, offsetBy: argument.count)
        }
        return offenders
    }

    /// Whether an argument holds a *magnitude* rather than nothing at all.
    ///
    /// A bare zero is the absence of a value, not a distance: `VStack(spacing: 0)` is what
    /// a stack that draws its own separators asks for, and `DS.Space` has no token for it
    /// because the 4pt grid starts at 2. So a zero is not an offender on its own, while
    /// `10`, `20` and `0.5` are — which is what deleting the zeros and looking for a digit
    /// left says.
    private static func carriesMagnitude(_ argument: String) -> Bool {
        argument.replacingOccurrences(of: "0", with: "")
            .rangeOfCharacter(from: .decimalDigits) != nil
    }

    /// The one argument that begins at `from`, with its nesting respected.
    ///
    /// Depth, not the next comma and not the next line: `HStack(spacing: 7)` and
    /// `HStack(alignment: .leading, spacing: 7)` have to agree, and neither may swallow the
    /// next modifier — the first version of this matched parens from a site's last
    /// character, which for a `spacing:` label is a colon, so the walk started outside any
    /// call and ran on to the *following* line's closing bracket. It reported one offender
    /// for two, and hid the second inside the first one's text.
    private static func argumentText(in text: String, from: String.Index) -> String? {
        var index = from
        var depth = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth > 0 { depth -= 1 }
                return String(text[from...index])
            } else if character == "," && depth == 0 {
                return String(text[from..<index])
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func line(of index: String.Index, in text: String) -> Int {
        text[text.startIndex..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// Source with `// …` and `/* … */` removed and the line breaks they occupied kept, so
    /// a reported line is the line a person would open. String literals are kept as they
    /// are: a `"520"` in a title is copy, and a view that renders one has not put a
    /// layout value in a string.
    private static func strippingComments(_ source: String) -> String {
        let characters = Array(source)
        var out = ""
        out.reserveCapacity(characters.count)
        var index = 0
        var inString = false
        var inBlock = false

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if inBlock {
                if character == "*", next == "/" { inBlock = false; index += 2; continue }
                if character == "\n" { out.append(character) }
                index += 1
                continue
            }
            if inString {
                out.append(character)
                if character == "\\", let next, next != "\n" {
                    out.append(next)
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" { inString = true; out.append(character); index += 1; continue }
            if character == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", next == "*" { inBlock = true; index += 2; continue }
            out.append(character)
            index += 1
        }
        return out
    }
}
