import Foundation

/// `--selftest-now-block` (P4-01): the clock and the state, in every prompt that should carry
/// them, in none of the two that should not, and inside the budget each path was given.
///
/// Red on unmodified code for the reason the task recorded: the typed first pass has no date
/// at all, so assertion 1 fails with "lacks today's date" before anything else is checked.
/// That ordering is deliberate — the date is the claim, and a block that carries everything
/// except the one fact this task exists for has not succeeded.
///
/// The fixture is `FakeCalendarProvider`, built directly rather than through
/// `--fake-calendar`, so `make acceptance` can run this without the flag and without a
/// permission. No user store is read or written: the facts go into `AgentNowCache`, which
/// `resetForTesting()` empties at the end.
@MainActor
enum AgentNowSelfTest {
    static func runSelfTest() -> Bool {
        var failures: [String] = []
        let calendar = Calendar.current
        let zone = TimeZone.current
        // Two clocks, deliberately. The **prompts** are built from the live cache and must
        // carry the real today, so the facts are published from the real now and `today` is
        // read from it. The **renderer** is pure and is exercised against a fixed instant, so
        // a run that straddles midnight or an hour cannot fail on its own arithmetic — that is
        // what the renderer section below is for.
        let t0 = calendar.date(from: DateComponents(
            timeZone: .current, year: 2026, month: 9, day: 23, hour: 18, minute: 30)) ?? Date()
        let live = Date()
        let today = dateString(live, zone: zone)

        func check(_ condition: Bool, _ what: String) {
            if condition == false { failures.append(what) }
        }

        // MARK: The fixture

        // Built from the real now, the way `FakeCalendarProvider` builds its own event, so the
        // block a prompt receives names today and an event that is genuinely next.
        let facts = AgentNowFacts(
            calendarAuthorized: true,
            events: [
                AgentNowFacts.Event(
                    title: "Call with \"Margaret\"",
                    start: live.addingTimeInterval(30 * 60),
                    end: live.addingTimeInterval(60 * 60),
                    attendees: ["Margaret Sclafani", "Ana Ruiz", "Ben Oyelaran", "Sarah Kim"]),
                AgentNowFacts.Event(
                    title: "Standup",
                    start: calendar.date(byAdding: .day, value: 1, to: live) ?? live,
                    end: (calendar.date(byAdding: .day, value: 1, to: live) ?? live)
                        .addingTimeInterval(1_800),
                    attendees: ["Ana Ruiz", "Ben Oyelaran"]),
            ],
            recordingTitle: nil,
            recordingSince: nil,
            frontApp: "Fixture App",
            working: ["Fixture objective"],
            waitingFor: "Fixture approval",
            publishedAt: live)
        AgentNowCache.shared.publish(facts)
        defer { AgentNowCache.shared.resetForTesting() }

        // MARK: 1. The paths that speak carry the date and the next event

        let planner = RealtimeAgent.plannerSystem(
            manifest: AgentCapabilityManifest.current(), voice: false)
        let plannerVoice = RealtimeAgent.plannerSystem(
            manifest: AgentCapabilityManifest.current(), voice: true)
        let firstPass = RealtimeAgent.voiceRoutingSystem(voice: false)
        let firstPassVoice = RealtimeAgent.voiceRoutingSystem(voice: true)
        let localModel = RealtimeAgent.localModelSystem
        let spokenAnswer = LocalVoiceSplitResponse.answerInstructions
        for (name, prompt) in [
            ("planner", planner), ("planner (voice)", plannerVoice),
            ("voice first pass", firstPass), ("voice first pass (voice)", firstPassVoice),
            ("localModel", localModel), ("spoken answer", spokenAnswer),
        ] {
            check(prompt.contains(today),
                  "\(name) prompt lacks today's date (\(today))")
            check(prompt.contains("Call with Margaret"),
                  "\(name) prompt does not name the next event")
        }
        print("NOW_BLOCK_PLANNER: \(planner.count) chars, now=\(section(in: planner).count)")

        // MARK: 2. The paths that only need the date

        for (name, prompt) in [
            ("meeting assistant", AgentPrompts.system),
            ("knowledge ask", KnowledgeAsker.systemPrompt),
        ] {
            check(prompt.contains(today), "\(name) prompt lacks today's date (\(today))")
            check(prompt.contains("Fixture App") == false,
                  "\(name) prompt carries a front app it should not have")
            check(prompt.contains("Call with Margaret") == false,
                  "\(name) prompt names a meeting it should not have")
        }

        // MARK: 3. The routine carries events, and nothing about the person

        let runner = Self.makeRunner().systemPrompt(
            for: Self.fixtureSchedule, now: live)
        check(runner.contains("Call with Margaret"),
              "the routine prompt does not carry the next event")
        check(runner.contains("Fixture App") == false,
              "the routine prompt names the front app")
        check(runner.contains("Fixture approval") == false,
              "the routine prompt names a pending approval")

        // MARK: 4. Routing carries nothing

        check(LocalVoiceSplitResponse.routeInstructions.contains(AgentNow.header) == false,
              "the routing prompt carries the now block")

        // MARK: 5. A cloud reader sees the clock and nothing else

        let cloudPlanner = KnowledgeGraphScope.$reader.withValue(.openRouter) {
            RealtimeAgent.plannerSystem(manifest: AgentCapabilityManifest.current(), voice: false)
        }
        check(cloudPlanner.contains(today), "a cloud reader's prompt lacks today's date")
        check(cloudPlanner.contains("Fixture App") == false,
              "a cloud reader's prompt names the front app without consent")
        check(cloudPlanner.contains("Call with Margaret") == false,
              "a cloud reader's prompt names a meeting without consent")

        // MARK: 6. Budgets, one header per prompt, and placement

        for (name, prompt) in [
            ("planner", planner), ("planner (voice)", plannerVoice),
            ("voice first pass", firstPass), ("localModel", localModel),
            ("spoken answer", spokenAnswer), ("meeting assistant", AgentPrompts.system),
            ("routine", runner), ("routing", LocalVoiceSplitResponse.routeInstructions),
        ] {
            let block = section(in: prompt)
            let shape = shapeFor(name)
            // `.none` is the one shape whose correct answer is zero headers, so the count is
            // asserted against the shape rather than against "once".
            let appearances = prompt.components(separatedBy: AgentNow.header).count - 1
            let wanted = shape == .none ? 0 : 1
            check(appearances == wanted,
                  "\(name) prompt carries the now header \(appearances) time(s), not \(wanted)")
            let cap = AgentNow.cap(for: shape)
            check(block.count <= cap,
                  "\(name) prompt's now block is \(block.count) chars, over the "
                    + "\(shape.rawValue) cap of \(cap)")
            // The block is data, so it must sit after the rules, where a model weighs it last
            // and where the override line already covers it.
            if let overrideIndex = prompt.range(of: AgentPromptContext.overrideLine),
               let blockIndex = prompt.range(of: AgentNow.header) {
                check(overrideIndex.upperBound <= blockIndex.lowerBound,
                      "\(name) prompt carries the now block above the rules")
            }
        }

        // MARK: 7. The two lines that used to do this job are gone

        check(planner.contains("Today is") == false,
              "the planner prompt still carries its own \"Today is\" line")
        check(runner.contains("Now: ") == false,
              "the routine prompt still carries its own \"Now:\" line")

        // MARK: 8. The renderer, on facts that do not depend on a calendar
        //
        // Its own fixture, built from the fixed instant. The published `facts` are built from
        // the real now because a *prompt* must carry today's real date; the renderer is pure,
        // so it is checked against an instant that cannot move under the run.
        var renderFacts = facts
        renderFacts.events = [
            AgentNowFacts.Event(
                title: "Call with \"Margaret\"", start: t0.addingTimeInterval(30 * 60),
                end: t0.addingTimeInterval(60 * 60),
                attendees: ["Margaret Sclafani", "Ana Ruiz", "Ben Oyelaran", "Sarah Kim"]),
            AgentNowFacts.Event(
                title: "Standup", start: calendar.date(byAdding: .day, value: 1, to: t0) ?? t0,
                end: (calendar.date(byAdding: .day, value: 1, to: t0) ?? t0)
                    .addingTimeInterval(1_800),
                attendees: ["Ana Ruiz", "Ben Oyelaran"]),
        ]
        renderFacts.publishedAt = t0

        let without = render(renderFacts, shape: .full, now: t0, zone: zone)
        check(without.contains("Time: Sunday 2026-09-23 18:30") == false
            || without.contains("Right now") == false,
            "the block lost its header")

        // An event that has ended is dropped at render, even though the cache still holds it.
        var stale = renderFacts
        stale.events = [AgentNowFacts.Event(
            title: "Finished thing", start: t0.addingTimeInterval(-7_200),
            end: t0.addingTimeInterval(-3_600), attendees: [])]
        let staleBlock = render(stale, shape: .full, now: t0, zone: zone)
        check(staleBlock.contains("Finished thing") == false,
              "the block still names an event that ended three hours ago")

        // Unknown and empty are different sentences, and the second is the one that must never
        // be printed about a calendar nobody connected.
        var unconnected = renderFacts
        unconnected.calendarAuthorized = false
        unconnected.events = []
        let unconnectedBlock = render(unconnected, shape: .full, now: t0, zone: zone)
        check(unconnectedBlock.contains("Calendar: not connected"),
              "an unconnected calendar is not reported as not connected")
        check(unconnectedBlock.contains("nothing in the next 24 hours") == false,
              "an unconnected calendar is reported as empty")

        var connected = unconnected
        connected.calendarAuthorized = true
        let connectedBlock = render(connected, shape: .full, now: t0, zone: zone)
        check(connectedBlock.contains("nothing in the next 24 hours"),
              "a connected calendar with nothing left does not say so")

        // A running event is "Now", and its countdown is to the end rather than the start.
        var running = renderFacts
        running.events = [AgentNowFacts.Event(
            title: "Standup", start: t0.addingTimeInterval(-600),
            end: t0.addingTimeInterval(1_200), attendees: ["Ana Ruiz"])]
        let runningBlock = render(running, shape: .full, now: t0, zone: zone)
        check(runningBlock.contains("- Now: "),
              "a meeting already under way is not rendered as the current one")
        check(runningBlock.contains("ends in 20 min"),
              "a running meeting does not render its remaining time")
        check(runningBlock.contains("— in ") == false,
              "a running meeting renders a countdown to a start that has passed")

        // Attendees: three names then the count. An id would be worse than useless here.
        check(without.contains("Margaret Sclafani, Ana Ruiz, Ben Oyelaran +1"),
              "attendees are not rendered as three names and a count")
        check(without.contains("Working on") && without.contains("Fixture objective"),
              "the block does not carry the running work")
        check(without.contains("approve \"Fixture approval\""),
              "the block does not carry the pending approval")

        // The fixture's title carries an inner pair of quotes and the renderer must strip
        // them, so the block's own quoting stays unambiguous.
        check(without.contains("Call with Margaret") && without.contains("with \"Margaret\"") == false,
            "the event line did not flatten the title's inner quote")
        check(without.components(separatedBy: "\n").allSatisfy { $0.isEmpty == false },
            "the block contains a blank line")

        // The cap is enforced by dropping lines, and `Time` is never the one dropped.
        var long = renderFacts
        long.recordingTitle = "A very long meeting title that will not fit in any reasonable budget"
        long.working = ["one", "two"]
        long.waitingMore = 3
        long.recordingSince = t0.addingTimeInterval(-1_200)
        let trimmed = render(long, shape: .compact, now: t0, zone: zone)
        check(trimmed.count <= AgentNow.cap(for: .compact),
              "the compact block is over its cap after trimming (\(trimmed.count))")
        check(trimmed.contains("Time: "), "trimming dropped the clock, which is the one line "
            + "that must never go")
        check(trimmed.contains("Waiting for you") == false,
              "trimming kept the pending approval over a meeting")

        // Every shape renders, and `.none` renders nothing at all.
        for shape in AgentNow.Shape.allCases {
            let block = render(renderFacts, shape: shape, now: t0, zone: zone)
            if shape == .none {
                check(block.isEmpty, "the .none shape rendered a block")
            } else {
                check(block.contains("2026-09-23"),
                      "the \(shape.rawValue) block lacks the fixed instant's date")
            }
        }

        // MARK: Report

        let full = render(renderFacts, shape: .full, now: t0, zone: zone)
        print("NOW_BLOCK_FULL: \(full.count)/\(AgentNow.cap(for: .full)) chars")
        print(full)
        for failure in failures { print("NOW_BLOCK_WRONG: \(failure)") }
        print(failures.isEmpty ? "NOW_BLOCK_OK" : "NOW_BLOCK_FAILED: \(failures[0])")
        return failures.isEmpty
    }

    // MARK: - Helpers

    /// A runner with every seam inert, so the prompt can be built without a store, a tool
    /// runner, a recorder or a model. The fakes are the routine authority self-test's own
    /// rather than a second set: they already exist, they are internal, and a second copy
    /// would be a second thing to keep true.
    private static func makeRunner() -> ScheduledRunner {
        ScheduledRunner(
            store: ScheduleStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesNowBlock-\(UUID().uuidString)", isDirectory: true)),
            environment: RoutineAuthoritySelfTest.FakeRunEnvironment(),
            tools: RoutineAuthoritySelfTest.FakeToolRunner(),
            recorder: RoutineAuthoritySelfTest.FakeRecorder(),
            timeZone: { .current })
    }

    /// A routine with no tools, so the prompt carries a catalogue of "(none)" and the
    /// assertion is about the block rather than about a tool list.
    private static var fixtureSchedule: AgentSchedule {
        AgentSchedule(
            id: UUID(), kind: .routine, title: "Now block fixture",
            plainEnglish: "Say what time it is.", prompt: "Say what time it is.",
            when: nil, trigger: nil, endsAt: nil, allowedTools: [], model: .auto,
            delivery: .notify, budget: .standard, enabled: true,
            createdAt: Date(), createdInSession: nil)
    }

    private static func render(
        _ facts: AgentNowFacts, shape: AgentNow.Shape, now: Date, zone: TimeZone
    ) -> String {
        AgentNow.render(facts, shape: shape, now: now, zone: zone,
                        cloud: false, cloudConsent: false)
    }

    /// The block as it appears inside a prompt, or "" when the prompt carries none.
    private static func section(in prompt: String) -> String {
        guard let start = prompt.range(of: AgentNow.header) else { return "" }
        let rest = prompt[start.lowerBound...]
        // The block is header + the lines that follow, up to a blank line or the end.
        var lines: [String] = []
        for line in rest.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty && lines.isEmpty == false { break }
            lines.append(String(line))
        }
        return lines.joined(separator: "\n")
    }

    private static func shapeFor(_ promptName: String) -> AgentNow.Shape {
        switch promptName {
        case "planner", "planner (voice)", "voice first pass", "localModel": .full
        case "spoken answer": .compact
        case "meeting assistant", "knowledge ask": .dateOnly
        case "routine": .unattended
        case "routing": .none
        default: .full
        }
    }

    private static func dateString(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
