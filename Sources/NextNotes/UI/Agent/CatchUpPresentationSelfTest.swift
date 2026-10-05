import Foundation

/// The catch-up screens' own checks, run inside `--selftest-agent-panes`.
///
/// What a Library row, the "ready" card and the closing buttons say comes from
/// `CatchUpText` and `CatchUpLibrary`, so this pins those against realistic words, injected
/// finished runs and an isolated preferences suite — no model, no audio device, no owner
/// store. The drawn layout is checked by `--settings-sheet` and by eye.
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
        let library = CatchUpLibrary(
            tasks: { box.tasks }, catchUpScheduleIDs: { [routine] in [routine] },
            fileExists: { _ in true }, measure: { _ in 19 }, defaults: defaults)

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
        let relaunched = CatchUpLibrary(
            tasks: { box.tasks }, catchUpScheduleIDs: { [routine] in [routine] },
            fileExists: { _ in true }, measure: { _ in 19 }, defaults: defaults)
        relaunched.reload(announce: false)
        expect(relaunched.openOffer(for: relaunched.entries[0]) == nil, "an answered question came back after relaunch")
        let stalePast = CatchUpEntry(id: "x", title: "t", madeAt: Date().addingTimeInterval(-20 * 3_600),
                                     text: sample, audioURL: nil, duration: nil, headlines: [],
                                     offer: CatchUpText.offer(from: sample))
        expect(!stalePast.offerIsFresh(now: Date()), "an offer 20 hours old still has buttons")

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
        return failures
    }
}
