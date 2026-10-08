import AppKit
import Foundation
import SwiftUI

/// The catch-up screens' own checks, run inside `--selftest-agent-panes`.
///
/// What a Library card, the "ready" card and the closing buttons say comes from
/// `CatchUpText` and `CatchUpLibrary`, so this pins those against realistic words, injected
/// finished runs and an isolated preferences suite — no model, no audio device, no owner
/// store. The drawn layout is checked by `--settings-sheet` and by
/// `--selftest-agent-panes --catch-up-preview-dir <dir under $TMPDIR>`, which writes the
/// cards through an offscreen host; that is a picture to look at, not a verdict.
@MainActor
enum CatchUpPresentationSelfTest {
    /// A catch-up in the shape the routine's prompt asks for: a greeting, short paragraphs,
    /// most urgent first, one closing question.
    static let sample = """
    Good morning.

    Ms. Rivera\u{2019}s email from Tuesday is still waiting on a reply, and the budget draft is due at noon.

    Yesterday the team agreed to move the launch to the 14th, and Sam sent the revised numbers.

    Today you have the design review at 10 and lunch with Dana at 1. Thursday is clear.

    I already drafted a reply to Ms. Rivera for you.

    Want me to send the reminders?
    """

    /// Records what the closing button hands to the conversation.
    private final class Recorder: CatchUpOfferActing {
        var said: [String] = []
        func say(_ text: String) { said.append(text) }
    }

    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append("catch-up: " + message()) }
        }

        // Sentences: an abbreviation is not the end of one.
        let split = CatchUpText.sentences(of: "Ms. Rivera wrote back at 6 p.m. today. Reply?")
        expect(split == ["Ms. Rivera wrote back at 6 p.m. today.", "Reply?"],
               "sentence split cut an abbreviation: \(split)")

        // Headlines: greeting and question left out, one line per paragraph, short.
        let lines = CatchUpText.headlines(from: sample)
        expect(lines.count == 4, "expected 4 headlines, got \(lines.count): \(lines)")
        expect(lines.first?.hasPrefix("Ms. Rivera") == true, "first headline is \(lines.first ?? "none")")
        expect(!lines.contains { $0.lowercased().hasPrefix("good morning") }, "the greeting is a headline")
        expect(!lines.contains { $0.contains("send the reminders") }, "the closing question is a headline")
        expect(lines.allSatisfy { $0.count <= CatchUpText.headlineLimit + 1 }, "a headline is too long: \(lines)")
        let long = CatchUpText.shortened(String(repeating: "and another thing ", count: 8) + "ends.")
        expect(long.hasSuffix("\u{2026}") && long.count <= CatchUpText.headlineLimit + 1,
               "a long sentence was not cut at a word: \(long)")

        // The closing offer becomes one primary action.
        let offer = CatchUpText.offer(from: sample)
        expect(offer?.actionLabel == "Send the reminders", "label was \(offer?.actionLabel ?? "none")")
        expect(offer?.yesText == "Yes, go ahead and send the reminders.", "yes was \(offer?.yesText ?? "none")")
        expect(CatchUpText.offer(from: "Hello. Shall I draft a reply to Ms. Rivera?")?.actionLabel
               == "Draft a reply to Ms. Rivera", "a Shall-I question did not become a verb phrase")
        expect(CatchUpText.offer(from: "Hi.\n\nDo you want me to move Thursday\u{2019}s lunch?")?.actionLabel
               == "Move Thursday\u{2019}s lunch", "a Do-you-want question did not become a verb phrase")
        let odd = CatchUpText.offer(from: "Hi.\n\nAnything else on your mind?")
        expect(odd?.actionLabel == "Yes, do that" && odd?.yesText.contains("Anything else") == true,
               "an unparseable question has no safe fallback")
        expect(CatchUpText.offer(from: "Good morning.\n\nNothing needs you today.") == nil,
               "a catch-up that ends on a statement got an offer")
        expect(!(CatchUpText.offer(from: sample)?.yesText.lowercased().contains("send it") ?? false),
               "the yes text claims approval to send")

        // Dates in a person's words.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        func at(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        let now = at(5, 9, 30) // a Monday
        func phrase(_ date: Date) -> String {
            CatchUpText.whenPhrase(date, now: now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        expect(phrase(at(5, 7, 2)) == "This morning, 7:02 AM", "same morning: \(phrase(at(5, 7, 2)))")
        expect(phrase(at(5, 9, 10)) == "This morning, 9:10 AM", "just now: \(phrase(at(5, 9, 10)))")
        expect(phrase(at(4, 18, 40)) == "Yesterday, 6:40 PM", "yesterday: \(phrase(at(4, 18, 40)))")
        expect(phrase(at(2, 6, 0)) == "Friday, 6:00 AM", "this week: \(phrase(at(2, 6, 0)))")
        expect(phrase(at(25, 6, 0, month: 9)) == "Sep 25, 6:00 AM", "older: \(phrase(at(25, 6, 0, month: 9)))")
        expect(CatchUpText.lengthPhrase(19) == "Under a minute", "19 s")
        expect(CatchUpText.lengthPhrase(45) == "1 min", "45 s")
        expect(CatchUpText.lengthPhrase(125) == "2 min", "125 s")
        expect(CatchUpText.clock(7.9) == "0:07" && CatchUpText.clock(75) == "1:15", "clock")

        // The Library, from finished runs.
        let routine = UUID()
        let audioDirectory = LongFormRenderer.audioDirectory
        func audio(_ name: String) -> String {
            audioDirectory.appendingPathComponent(name).absoluteString
        }
        func task(_ id: String, minutesAgo: Double, title: String = "Your morning catch-up",
                  status: AgentTaskStatus = .completed, text: String = sample,
                  schedule: UUID? = routine, artifacts: [String] = []) -> AgentTask {
            AgentTask(
                id: id, objective: title, source: AgentTask.scheduledSource,
                createdAt: Date().addingTimeInterval(-minutesAgo * 60), status: status,
                result: text, artifacts: artifacts, scheduleID: schedule,
                finishedAt: Date().addingTimeInterval(-minutesAgo * 60))
        }
        final class Box { var tasks: [AgentTask] = [] }
        let box = Box()
        let suite = "NextNotesCatchUpTest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return failures + ["catch-up: could not make an isolated preferences suite"]
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder()
        var fileChecks = 0
        let library = CatchUpLibrary(
            tasks: { box.tasks }, catchUpScheduleIDs: { [routine] in [routine] },
            fileExists: { _ in fileChecks += 1; return true }, measure: { _ in 19 },
            defaults: defaults, offers: recorder)

        box.tasks = [
            task("older", minutesAgo: 60 * 30, artifacts: [audio("Your morning catch-up 2026-10-04.m4a")]),
            task("newest", minutesAgo: 3),
            task("other", minutesAgo: 5, title: "Water the plants", schedule: UUID()),
            task("failed", minutesAgo: 6, status: .failed),
            task("silent", minutesAgo: 7, text: "  "),
            task("elsewhere", minutesAgo: 8, artifacts: ["file:///tmp/not-the-library.m4a"]),
        ]
        var ready: [String] = []
        library.onReady = { ready.append($0.id) }
        library.start()
        let ids = library.entries.map(\.id)
        expect(ids == ["newest", "elsewhere", "older"],
               "entries should be the completed catch-ups newest first, got \(ids)")
        expect(library.entries.first { $0.id == "older" }?.duration == 19, "audio length was not read")
        expect(library.entries.first { $0.id == "elsewhere" }?.audioURL == nil,
               "a file outside the Library was offered as audio")
        expect(ready.isEmpty, "a catch-up that already existed at launch was announced")

        // A task list that moves without changing a catch-up touches no file.
        let before = fileChecks
        box.tasks.append(task("noise", minutesAgo: 1, title: "Water the plants", schedule: UUID()))
        library.reload()
        expect(fileChecks == before, "an unrelated task made the Library check \(fileChecks - before) files")

        // Preparing, then ready: the audio arriving is the one moment announced, once.
        expect(library.entries.first?.isPreparingAudio(now: Date()) == true, "a fresh catch-up with no audio is not preparing")
        expect(library.entries.first { $0.id == "older" }?.isPreparingAudio(now: Date()) == false,
               "a catch-up with audio claims it is preparing")
        let stale = task("stale", minutesAgo: 40)
        expect(CatchUpText.entry(id: "stale", title: stale.objective, madeAt: stale.createdAt, text: sample,
                                 audioURL: nil, duration: nil)?.isPreparingAudio(now: Date()) == false,
               "a catch-up with no audio after the wait is still described as preparing")
        box.tasks[1] = task("newest", minutesAgo: 3, artifacts: [audio("Your morning catch-up 2026-10-05.m4a")])
        library.reload()
        expect(ready == ["newest"], "the ready moment fired \(ready)")
        library.reload()
        expect(ready == ["newest"], "the ready moment fired twice: \(ready)")

        // The closing question: newest only, closed for good by either answer.
        let newest = library.entries[0]
        expect(library.openOffer(for: newest)?.actionLabel == "Send the reminders", "newest has no open offer")
        expect(library.openOffer(for: library.entries[2]) == nil, "an older catch-up kept its buttons")
        library.closeOffer(newest)
        expect(library.openOffer(for: newest) == nil, "Not now did not close the question")
        expect(recorder.said.isEmpty, "Not now sent something to the conversation: \(recorder.said)")
        let relaunched = CatchUpLibrary(
            tasks: { box.tasks }, catchUpScheduleIDs: { [routine] in [routine] },
            fileExists: { _ in true }, measure: { _ in 19 }, defaults: defaults, offers: recorder)
        relaunched.reload(announce: false)
        expect(relaunched.openOffer(for: relaunched.entries[0]) == nil, "an answered question came back after relaunch")
        let stalePast = CatchUpEntry(id: "x", title: "t", madeAt: Date().addingTimeInterval(-20 * 3_600),
                                     text: sample, audioURL: nil, duration: nil, headlines: [],
                                     offer: CatchUpText.offer(from: sample))
        expect(!stalePast.offerIsFresh(now: Date()), "an offer 20 hours old still has buttons")

        // Yes is one ordinary turn in the person's words, said once, and closes the question.
        let yesSuite = suite + "-yes"
        guard let yesDefaults = UserDefaults(suiteName: yesSuite) else {
            return failures + ["catch-up: could not make a second preferences suite"]
        }
        defer { yesDefaults.removePersistentDomain(forName: yesSuite) }
        let accepting = CatchUpLibrary(
            tasks: { box.tasks }, catchUpScheduleIDs: { [routine] in [routine] },
            fileExists: { _ in true }, measure: { _ in 19 }, defaults: yesDefaults, offers: recorder)
        accepting.reload(announce: false)
        if let top = accepting.entries.first {
            accepting.acceptOffer(top)
            accepting.acceptOffer(top)
            expect(recorder.said == ["Yes, go ahead and send the reminders."],
                   "the button said \(recorder.said)")
            expect(accepting.openOffer(for: top) == nil, "Yes left the question open")
        } else {
            failures.append("catch-up: nothing to accept an offer on")
        }

        // The island's card: idle orb, asks to be seen, one card per catch-up, and nothing in
        // the island starts the audio except the Play button.
        let card = IslandState.Kind.catchUpReady(taskID: "a", title: "Your morning catch-up")
        expect(card.orb == .breathing, "the ready card is not the idle orb")
        expect(card.demandsAttention, "the ready card does not open itself")
        expect(card.identity != IslandState.Kind.catchUpReady(taskID: "b", title: "x").identity,
               "two catch-ups share one card identity")
        if let source = SourceScan.file("Sources/NextNotes/UI/Island/IslandState.swift") {
            let uses = SourceScan.codeLines(of: source).filter { $0.text.contains("CatchUpPlayer") }
            expect(uses.count == 1, "the island reaches the player in \(uses.count) places, expected only Play")
        } else {
            failures.append("catch-up: could not read IslandState to check nothing auto-plays")
        }

        // Nothing in the catch-up screens starts audio except a press: the player is reached
        // from a Play button, and the library never imports it into the list's reload.
        if let source = SourceScan.file("Sources/NextNotes/UI/CatchUp/CatchUpViews.swift") {
            let starts = SourceScan.codeLines(of: source).filter { $0.text.contains("player.toggle(") || $0.text.contains(".play(") }
            expect(starts.count == 1, "the catch-up views start audio in \(starts.count) places, expected the one Play button")
            let code = SourceScan.codeLines(of: source).map(\.text).joined(separator: "\n")
            expect(code.contains("accessibilityReduceMotion"), "the catch-up views ignore Reduce Motion")
            expect(!code.contains("scaleEffect"), "an orb or card is scaled")
        } else {
            failures.append("catch-up: could not read CatchUpViews to check nothing auto-plays")
        }
        if let source = SourceScan.file("Sources/NextNotes/UI/CatchUp/CatchUpSettingsSection.swift") {
            let code = SourceScan.codeLines(of: source).map(\.text).joined(separator: "\n")
            expect(code.contains("Catch me up when I\\u{2019}m back"),
                   "the Settings switch is not worded as the person says it")
            expect(code.contains("DatePicker"), "the Settings section has no time picker")
        } else {
            failures.append("catch-up: could not read the Settings section")
        }

        failures += writePreviewIfRequested()
        return failures
    }

    // MARK: - A picture to look at

    /// `--catch-up-preview-dir <dir>` (with `--selftest-agent-panes`) writes the cards in
    /// their three states, at a narrow and a wide pane, through an offscreen host. It reads
    /// no owner data: the entries and the library are injected. A directory outside the
    /// temporary folder is refused.
    private static func writePreviewIfRequested() -> [String] {
        guard let directory = SelfTest.value(after: "--catch-up-preview-dir") else { return [] }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard root.resolvingSymlinksInPath().path.hasPrefix(temp + "/") else {
            return ["catch-up: the preview folder must be under the temporary folder"]
        }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { return ["catch-up: preview folder: \(error.localizedDescription)"] }

        let routine = UUID()
        let suite = "NextNotesCatchUpPreview-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return ["catch-up: preview defaults"] }
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = LongFormRenderer.audioDirectory.appendingPathComponent("Your morning catch-up 2026-10-08.m4a")
        let words = "Good morning.\n\nI noticed Ms. Rivera\u{2019}s email from Tuesday is still waiting on a reply.\n\nThe design review moved to 10.\n\nWant me to send the reminders?"
        func task(_ id: String, _ minutes: Double, audio: Bool, text: String) -> AgentTask {
            AgentTask(id: id, objective: "Your morning catch-up", source: AgentTask.scheduledSource,
                      createdAt: Date().addingTimeInterval(-minutes * 60), status: .completed, result: text,
                      artifacts: audio ? [audio.absoluteString] : [], scheduleID: routine,
                      finishedAt: Date().addingTimeInterval(-minutes * 60))
        }
        let library = CatchUpLibrary(
            tasks: { [
                task("ready", 90, audio: true, text: words),
                task("preparing", 100, audio: false, text: words),
                task("older", 60 * 30, audio: false, text: "Welcome back.\n\nNothing needs you today."),
            ] },
            catchUpScheduleIDs: { [routine] in [routine] },
            fileExists: { _ in true }, measure: { _ in 96 }, defaults: defaults, offers: Recorder())
        library.refresh()
        var failures: [String] = []
        for (name, width) in [("narrow", 340.0), ("wide", 760.0)] {
            let stack = VStack(alignment: .leading, spacing: DS.Space.card) {
                ForEach(library.entries) { entry in
                    CatchUpCard(entry: entry, animatesOrb: false, library: library)
                }
            }
            .padding(DS.Space.page)
            .frame(width: width, alignment: .topLeading)
            .background(DS.Color.window)
            guard let png = render(stack, width: width) else {
                failures.append("catch-up: preview \(name) did not render")
                continue
            }
            do { try png.write(to: root.appendingPathComponent("catch-up-cards-\(name).png")) }
            catch { failures.append("catch-up: preview write: \(error.localizedDescription)") }
        }
        return failures
    }

    private static func render(_ view: some View, width: CGFloat) -> Data? {
        let hosting = NSHostingView(rootView: view)
        let fitting = hosting.fittingSize
        let size = NSSize(width: width, height: max(fitting.height, 200))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                            backing: .buffered, defer: false)
        defer { panel.close() }
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = hosting
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        return image.representation(using: .png, properties: [:])
    }
}
