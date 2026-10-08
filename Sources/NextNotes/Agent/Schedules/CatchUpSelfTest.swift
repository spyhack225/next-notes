import AVFoundation
import FluidAudio
import Foundation

/// `--selftest-catch-up` (PL-11): the one Catch-up routine that replaced the morning podcast
/// and the morning digest. `--selftest-digest` and `--selftest-podcast` still work and run
/// this same suite.
///
/// Scripted and headless: no model, no microphone, no real synthesis, no notification centre,
/// no account. The voice is an injected spy at a known sample rate, the model is scripted, the
/// tools are fixtures. What it proves:
///
/// - **Identity.** A schedule is a catch-up by its stored `templateID`, not its title; schedules
///   saved under "Morning digest" and "Your morning podcast" are migrated in place through the
///   real `ScheduleStore` (same ids, same times, nothing lost or duplicated, one stays on),
///   and every moment title keeps the output budget and the audio step.
/// - **The routine.** Exactly the three reads, no web, one voice, 150–450 words, most urgent
///   first, one closing question that only asks; the real `ScheduledRunner` runs it under
///   `.scheduled` authority with nothing waiting on `PermissionGate`, refuses a write the
///   model tries, and answers silence on an empty day.
/// - **Text first, then one voice.** The text is the result and is handed back before any
///   audio exists; the render then uses one voice, an exact duration, an atomic write and an
///   idle live voice graph, links its file to the same task, and a missing or busy voice
///   never touches the text.
/// - **Triggers.** The presence signal publishes one return per absence and nothing into a
///   call, a recording, a dictation, an agent turn or quiet hours; the event runs once, is
///   skipped when another catch-up just reached the person, and delivery is titled by the
///   moment and spoken without a title in front.
///
/// The ordinary run uses isolated synthesis. A real voice render has a separate opt-in
/// flag; real notifications and the live presence signal require separate acceptance.
@MainActor
enum CatchUpSelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-catchup-\(UUID().uuidString)", isDirectory: true)
        guard SelfTest.isRunning,
              !ScheduleStore.shared.directory.path.hasPrefix(AppIdentity.applicationSupportDirectory.path) else {
            print("CATCH_UP_FAILED: the schedule store is not isolated")
            return false
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: ScheduleStore.shared.directory)
        }

        // The real voice is its own opt-in run (`--selftest-catch-up --real-voice`): it needs model
        // files, takes tens of seconds, and its absence must never read as a scripted failure.
        if CommandLine.arguments.contains("--real-voice") { return await realVoiceRun(root: root) }

        failures += await CatchUpHandoffSelfTest.run()
        failures += identityFailures(root: root)
        failures += templateFailures()
        failures += await routineFailures(root: root)
        failures += await audioFailures(root: root)
        failures += detectorFailures()
        failures += await triggerFailures(root: root)
        failures += artifactAdmissionFailures(root: root)
        failures += await renderOverlapFailures(root: root)
        // Last: quit permanently closes render admission in this process.
        failures += await renderTerminationFailures(root: root)
        for failure in failures { print("CATCH_UP_CHECK_FAILED: \(failure)") }
        print(failures.isEmpty ? "CATCH_UP_OK" : "CATCH_UP_FAILED")
        return failures.isEmpty
    }

    // MARK: - Fixtures

    static let zone = TimeZone(identifier: "America/New_York")!
    /// Monday 2026-10-05 06:00:05 in New York.
    static let mondayMorning = ScheduleSelfTest.date(2026, 10, 5, 6, 0, 5)
    static let tuesdayMorning = ScheduleSelfTest.date(2026, 10, 6, 6, 30)
    static let created = ScheduleSelfTest.date(2026, 10, 2, 9, 0)

    // Invented people and places only, written the way the Voice and personality rules ask:
    // first person, names, "Already drafted…", one question. A scripted model returns it verbatim;
    // the run proves what the product does around it, not what the prose looks like.
    static let sampleText = """
        Morning. One thing needs you before school: the zoo permission slip is due today. I found it in Ms. Rivera's email from Tuesday, and the form is ready to print. Thursday is tight, with swim at five and your call running until a quarter to five. Dan usually confirms pickup by the evening before, so I'll watch for his message.

        Since yesterday, the school sent the new lunch menu and Priya from the swim club confirmed the extra Saturday session. Neither needs an answer. Your mum also sent the photos from Sunday, in case you want them for the fridge.

        Coming up, Maya's birthday is in three weeks. Last year you booked the party place about now, and their calendar fills quickly in the spring. Friday is quiet apart from the dentist at ten, and Saturday has the barbecue and nothing else.

        Already drafted: a yes to the Patels' barbecue on Saturday, ready for you to check. Want me to send it, or check with Dan first?
        """

    static func catchUp(
        id: UUID = UUID(), title: String = "Your morning catch-up", templateID: String? = CatchUpTemplate.identity,
        kind: AgentSchedule.Kind = .routine, trigger: ScheduleTrigger? = nil,
        delivery: AgentSchedule.Delivery = .notifyAndSpeak
    ) -> AgentSchedule {
        var schedule = AgentSchedule(
            id: id, kind: kind, title: title, plainEnglish: "A catch-up.", prompt: CatchUpTemplate.routinePrompt(),
            when: kind == .trigger ? nil : ScheduleWhen(
                repeatRule: .weekdays, time: ScheduleLocalTime(hour: 6, minute: 0), timeZone: zone.identifier),
            trigger: trigger, allowedTools: CatchUpTemplate.allowedTools, model: .auto, delivery: delivery,
            createdAt: created, templateID: templateID)
        schedule.budget.maxOutputTokens = schedule.effectiveMaxOutputTokens
        return schedule
    }

    nonisolated static func call(_ name: String, _ arguments: [String: String] = [:]) -> String {
        RoutineAuthoritySelfTest.call(name, arguments)
    }

    private static func directoryContents(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: - Identity and migration

    private static func identityFailures(root: URL) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append("identity: \(name)") } }

        // Moments: the title follows the day and what started the run.
        func moment(_ date: Date, trigger: ScheduleTrigger? = nil) -> CatchUpTemplate.Moment {
            CatchUpTemplate.moment(trigger: trigger, now: date, zone: zone)
        }
        check("Monday morning is not the Monday catch-up",
              CatchUpTemplate.title(for: moment(mondayMorning)) == "Your Monday catch-up")
        check("Tuesday morning is not the morning catch-up",
              CatchUpTemplate.title(for: moment(tuesdayMorning)) == "Your morning catch-up")
        check("a Monday afternoon is not an afternoon catch-up",
              moment(ScheduleSelfTest.date(2026, 10, 5, 13, 0)) == .afternoon)
        check("an evening is not an evening catch-up", moment(ScheduleSelfTest.date(2026, 10, 6, 19, 0)) == .evening)
        check("coming back is not 'While you were out' at any hour",
              CatchUpTemplate.title(for: moment(tuesdayMorning, trigger: .returned)) == "While you were out"
                && moment(ScheduleSelfTest.date(2026, 10, 6, 22, 0), trigger: .returned) == .whileOut)

        // Identity by stored id, not title. A moment title never breaks it.
        for title in CatchUpTemplate.Moment.allCases.map(CatchUpTemplate.title(for:)) + CatchUpTemplate.legacyTitles {
            let schedule = catchUp(title: title)
            check("\(title) is not a catch-up", schedule.isCatchUp)
            check("\(title) lost its output budget",
                  schedule.effectiveMaxOutputTokens == CatchUpTemplate.maxOutputTokens)
        }
        var renamed = catchUp(title: "Something I renamed it")
        check("a renamed catch-up stopped being one", renamed.isCatchUp)
        renamed.budget.maxOutputTokens = nil
        check("a renamed catch-up lost its budget", renamed.effectiveMaxOutputTokens == CatchUpTemplate.maxOutputTokens)
        check("a plain routine is a catch-up", !catchUp(title: "Inbox check", templateID: nil).isCatchUp)
        check("another template's identity counts as a catch-up",
              !catchUp(title: "Your morning catch-up", templateID: "something-else").isCatchUp)
        check("a legacy title without an identity is not a catch-up", catchUp(title: "Morning digest", templateID: nil).isCatchUp)
        check("the display title is not the moment's",
              catchUp(title: "Your morning catch-up").displayTitle(now: mondayMorning, zone: zone) == "Your Monday catch-up"
                && catchUp(title: "Inbox check", templateID: nil).displayTitle(now: mondayMorning, zone: zone) == "Inbox check"
                && catchUp(title: "While you were out", kind: .trigger, trigger: .returned)
                    .displayTitle(now: mondayMorning, zone: zone) == "While you were out")

        // The new field round-trips and a row without it still decodes.
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stamped = try encoder.encode(catchUp())
            check("the identity was not written", String(data: stamped, encoding: .utf8)?.contains("\"templateID\"") == true)
            check("the identity did not round-trip",
                  try decoder.decode(AgentSchedule.self, from: stamped).templateID == CatchUpTemplate.identity)
            let legacy = try encoder.encode(catchUp(title: "Morning digest", templateID: nil))
            check("a legacy row gained a key", String(data: legacy, encoding: .utf8)?.contains("templateID") == false)
            check("a legacy row did not decode", try decoder.decode(AgentSchedule.self, from: legacy).templateID == nil)
            let trigger = try decoder.decode(ScheduleTrigger.self, from: Data(#"{"returned":{}}"#.utf8))
            check("the return trigger did not decode", trigger == .returned)
            check("the return trigger did not round-trip",
                  try decoder.decode(ScheduleTrigger.self, from: encoder.encode(ScheduleTrigger.returned)) == .returned)
        } catch {
            failures.append("identity: coding threw \(error)")
        }

        // Migration through the real store, from the bytes a legacy file holds.
        let when = ScheduleWhen(repeatRule: .weekdays, time: ScheduleLocalTime(hour: 6, minute: 0), timeZone: zone.identifier)
        let reads = CatchUpTemplate.allowedTools
        func legacy(_ title: String, prompt: String, budget: Int?, enabled: Bool = true, next: Date? = nil) -> AgentSchedule {
            var schedule = AgentSchedule(
                id: UUID(), kind: .routine, title: title, plainEnglish: "Every weekday at 06:00, I'll do it.",
                prompt: prompt, when: when, allowedTools: reads, model: .auto, delivery: .notifyAndSpeak,
                budget: AgentSchedule.Budget(maxSeconds: 180, maxToolCalls: 8, maxOutputTokens: budget),
                enabled: enabled, createdAt: created)
            schedule.nextRunAt = next
            return schedule
        }
        let nextSlot = ScheduleSelfTest.date(2026, 10, 5, 6, 0)
        let digest = legacy("Morning digest", prompt: "You prepare the morning digest. It only reads.", budget: 1_536, next: nextSlot)
        let podcast = legacy("Your morning podcast", prompt: "You prepare a short two-host audio briefing about yesterday and today.",
                             budget: 4_096, next: nextSlot)
        let custom = legacy("Morning digest", prompt: "Summarise my day my way.", budget: nil, enabled: false)
        var plain = legacy("Inbox check", prompt: "Look at my inbox.", budget: nil)
        plain.allowedTools = ["search_email"]
        let directory = root.appendingPathComponent("migrate", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode([digest, podcast, custom, plain]).write(to: directory.appendingPathComponent(ScheduleStore.fileName))

        let migrated = ScheduleStore(directory: directory).schedules
        check("migration lost or added a schedule", migrated.map(\.id) == [digest.id, podcast.id, custom.id, plain.id])
        if migrated.count == 4 {
            check("the digest was not carried over in place",
                  migrated[0].templateID == CatchUpTemplate.identity && migrated[0].title == "Your morning catch-up"
                    && migrated[0].when == when && migrated[0].enabled && migrated[0].nextRunAt == nextSlot
                    && migrated[0].createdAt == created && migrated[0].allowedTools == reads)
            check("the digest kept a prompt that is not the catch-up's", migrated[0].prompt == CatchUpTemplate.routinePrompt())
            check("the digest budget was not replaced", migrated[0].budget.maxOutputTokens == CatchUpTemplate.maxOutputTokens)
            check("the podcast was not carried over",
                  migrated[1].templateID == CatchUpTemplate.identity && migrated[1].prompt == CatchUpTemplate.routinePrompt()
                    && migrated[1].budget.maxOutputTokens == CatchUpTemplate.maxOutputTokens && migrated[1].when == when)
            check("two catch-ups would have run at once", migrated[1].enabled == false && migrated[1].nextRunAt == nil)
            check("a prompt a person wrote was replaced",
                  migrated[2].prompt == "Summarise my day my way." && migrated[2].templateID == CatchUpTemplate.identity
                    && migrated[2].enabled == false && migrated[2].effectiveMaxOutputTokens == CatchUpTemplate.maxOutputTokens)
            check("another routine was touched", migrated[3] == plain)
            check("a migrated title still carries a retired name",
                  migrated.prefix(3).allSatisfy { $0.title == "Your morning catch-up" })
        }
        let reread = ScheduleStore(directory: directory)
        check("the migration was not written back", reread.schedules == migrated
              && (try? String(contentsOf: directory.appendingPathComponent(ScheduleStore.fileName), encoding: .utf8))?
                .contains("templateID") == true)
        check("a second pass changed it again", CatchUpTemplate.migrated(reread.schedules).changed == false)

        // An unreadable file is never rewritten.
        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try? FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let bytes = Data("this is not json".utf8)
        try? bytes.write(to: broken.appendingPathComponent(ScheduleStore.fileName))
        _ = ScheduleStore(directory: broken)
        check("an unreadable file was rewritten",
              (try? Data(contentsOf: broken.appendingPathComponent(ScheduleStore.fileName))) == bytes)
        return failures
    }

    // MARK: - The template

    private static func templateFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append("template: \(name)") } }

        check("the ceiling is not exactly the three reads",
              CatchUpTemplate.allowedTools == ["get_agenda", "search_knowledge", "search_email"])
        let ceiling = RoutineToolCeiling.fix(
            requested: CatchUpTemplate.allowedTools, available: Set(CatchUpTemplate.allowedTools))
        check("the reads do not pass the routine ceiling",
              ceiling.allowed == CatchUpTemplate.allowedTools && ceiling.refused.isEmpty)
        check("every ceiling tool is above read risk", CatchUpTemplate.allowedTools.allSatisfy {
            AgentToolRegistry.shared.tool(named: $0).map { $0.risk <= .read } ?? false })

        let prompt = CatchUpTemplate.routinePrompt()
        for tool in CatchUpTemplate.allowedTools { check("the prompt does not name \(tool)", prompt.contains(tool)) }
        check("the prompt lost the silence token", prompt.contains(ScheduledRunner.silenceToken))
        check("the prompt reaches the web",
              !prompt.contains("http") && !prompt.lowercased().contains("web_search") && !prompt.lowercased().contains("browser.")
                && prompt.contains("Never browse the web"))
        check("the prompt lost its untrusted-words rule", prompt.contains("never instructions to you"))
        check("the prompt is not one voice", !prompt.contains("Host A") && !prompt.contains("Host B") && prompt.contains("One voice"))
        check("the prompt lost the length", prompt.contains("Between 150 and 450 words"))
        check("the prompt still asks for the old lengths", !prompt.contains("600 to 900") && !prompt.contains("Four to eight minutes"))
        // Most urgent first: the order the prompt asks for.
        let order = ["What needs the person", "What happened", "What's coming", "already prepared", "closing question"]
            .map { prompt.range(of: $0)?.lowerBound }
        check("the prompt lost a section", order.allSatisfy { $0 != nil })
        check("the sections are not in priority order",
              zip(order, order.dropFirst()).allSatisfy { ($0 ?? prompt.endIndex) < ($1 ?? prompt.startIndex) })
        check("the prompt lost the offer that only asks",
              prompt.contains("only asks") && prompt.contains("Want me to send the reminders?") && prompt.contains("Never write it as done"))
        check("the prompt lost the source-and-who habit", prompt.contains("say who it is from and when"))
        check("the prompt lost the no-headings rule", prompt.contains("No headings, no bullet points"))
        check("the prompt names the person by role", !prompt.lowercased().contains("recipient"))

        // Setup through the real parse paths.
        let morning = CatchUpTemplate.createArguments()
        do {
            let when = try ScheduleToolExecutor.parseWhen(morning, base: nil, now: created, timeZone: zone)
            check("the default is not weekdays at 06:00 in its zone",
                  when.repeatRule == .weekdays && when.time == ScheduleLocalTime(hour: 6, minute: 0)
                    && when.timeZone == zone.identifier)
            check("the default ends", try ScheduleToolExecutor.parseEndsOn(morning["endsOn"] ?? "", timeZone: zone) == nil)
        } catch {
            failures.append("template: the create arguments do not parse: \(error.localizedDescription)")
        }
        check("the morning arguments are not a routine with the three reads",
              morning["kind"] == "routine" && morning["tools"] == "get_agenda,search_knowledge,search_email"
                && morning["title"] == "Your morning catch-up" && morning["model"] == "auto" && morning["speak"] == nil)
        let back = CatchUpTemplate.createArguments(moment: .whileOut)
        check("the return arguments are not a trigger", back["kind"] == "trigger" && back["on"] == "returned"
              && back["title"] == "While you were out" && back["speak"] == "no" && back["repeat"] == nil)
        check("the return arguments do not parse as the return trigger",
              (try? ScheduleToolExecutor.parseTrigger(back, base: nil)) == .returned)
        check("a return trigger accepted a filter",
              (try? ScheduleToolExecutor.parseTrigger(["on": "returned", "filter": "Acme"], base: nil)) == nil)
        check("a trigger word is not understood",
              ["returned", "back", "welcome back", "back-at-mac"].allSatisfy {
                  (try? ScheduleToolExecutor.parseTrigger(["on": $0], base: nil)) == .returned })
        check("the delivery is not notify-and-speak", CatchUpTemplate.delivery == .notifyAndSpeak && CatchUpTemplate.model == .auto)
        check("the return event reads wrong",
              ScheduleTrigger.returned.describe() == "when you're back at your Mac after a weekend or a long time away"
                && ScheduleTrigger.returned.event == .returned && ScheduleTrigger.returned.filter == nil)

        // Consumer words on every string a person reads.
        let visible = ([CatchUpTemplate.restatement(), CatchUpTemplate.restatement(moment: .whileOut),
                        CatchUpTemplate.plainEnglish(for: catchUp()),
                        CatchUpTemplate.plainEnglish(for: catchUp(kind: .trigger, trigger: .returned))]
            + CatchUpTemplate.Moment.allCases.map(CatchUpTemplate.title(for:))).joined(separator: "\n").lowercased()
        for word in ["cron", "artifact", "tool id", "tool_id", "schema", "agenttask", "transcriptbus", "routine",
                     "schedule", "trigger", "permission", "hermes", "json", "notifyandspeak",
                     "podcast", "briefing", "digest", "get_agenda", "search_email", "search_knowledge"] {
            check("a user-visible string says \(word)", !visible.contains(word))
        }
        let restated = CatchUpTemplate.restatement().lowercased()
        check("the restatement does not name its sources in plain words",
              restated.contains("calendar") && restated.contains("notes") && restated.contains("mail"))
        check("the restatement does not say it stays here and only reads",
              restated.contains("your mac") && restated.contains("never published") && restated.contains("only read"))
        check("the restatement does not end in a question", restated.hasSuffix("shall i set it?"))
        return failures
    }

    // MARK: - The routine, through the real ScheduledRunner

    private static func routineFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append("run: \(name)") } }
        let store = ScheduleStore(directory: root.appendingPathComponent("run", isDirectory: true))
        let environment = RoutineAuthoritySelfTest.FakeRunEnvironment()
        let tools = RoutineAuthoritySelfTest.FakeToolRunner()
        let recorder = RoutineAuthoritySelfTest.FakeRecorder()
        let runner = ScheduledRunner(store: store, environment: environment, tools: tools, recorder: recorder,
                                     timeZone: { zone })
        let gateAsks = PermissionGate.shared.askCount
        let schedule = catchUp()
        store.save(schedule)

        do {
            let text = sampleText
            environment.model = ScriptedMemoryReviewModel { _, user in
                if user.contains("search_email returned") { return text }
                if user.contains("search_knowledge returned") { return call("search_email", ["query": "newer_than:1d"]) }
                if user.contains("get_agenda returned") { return call("search_knowledge", ["query": "open commitments"]) }
                return call("get_agenda", ["date": "2026-10-05"])
            }
            var system = ""
            environment.systemSink = { system = $0 }
            let outcome = await runner.run(schedule, now: mondayMorning)
            print("CATCH_UP_RUN -> \(outcome.status.rawValue) (\(outcome.calls) calls, \(outcome.text.split(whereSeparator: \.isWhitespace).count) words)")
            check("the run did not report the text", outcome.status == .reported && outcome.text == sampleText)
            check("the reads did not run in order under scheduled authority",
                  tools.reads.map(\.0) == ["get_agenda", "search_knowledge", "search_email"]
                    && tools.reads.allSatisfy { $0.1 == .scheduled(schedule.id) })
            check("the closing offer became a draft", outcome.drafts.isEmpty && store.awaitingDrafts.isEmpty)
            check("the system prompt hid the tools or the silence rule",
                  system.contains(ScheduledRunner.silenceToken) && CatchUpTemplate.allowedTools.allSatisfy { system.contains($0) }
                    && !system.contains("schedule.create"))
            check("the three-sentence cap still contradicts the catch-up",
                  !system.contains("at most three sentences") && system.contains("shape and length"))
        }
        check("a read waited on PermissionGate", PermissionGate.shared.askCount == gateAsks && PermissionGate.shared.pending == nil)
        check("the task is not a fresh scheduled task titled by the moment",
              recorder.begun.first?.source == AgentTask.scheduledSource && recorder.begun.first?.scheduleID == schedule.id
                && recorder.begun.first?.objective == "Your Monday catch-up" && recorder.finished.first?.1 == .completed)
        check("an audit entry lacks the schedule id", !recorder.audits.isEmpty && recorder.audits.allSatisfy { $0.scheduleID == schedule.id })
        check("the output budget did not reach the model",
              environment.budgetRequests.allSatisfy { $0.1 == CatchUpTemplate.maxOutputTokens })

        // A legacy title with no identity runs as a catch-up too.
        let old = catchUp(title: "Your morning podcast", templateID: nil)
        var oldSystem = ""
        environment.systemSink = { oldSystem = $0 }
        environment.model = ScriptedMemoryReviewModel { _, _ in ScheduledRunner.silenceToken }
        _ = await runner.run(old, now: tuesdayMorning)
        check("a legacy schedule was not run as a catch-up", oldSystem.contains("shape and length")
              && recorder.begun.last?.objective == "Your morning catch-up")
        // Another routine keeps its own rule.
        let plain = RoutineAuthoritySelfTest.routine(tools: ["search_email"], id: UUID())
        var plainSystem = ""
        environment.systemSink = { plainSystem = $0 }
        _ = await runner.run(plain, now: mondayMorning)
        check("another routine lost its three-sentence rule", plainSystem.contains("at most three sentences"))

        // The ceiling holds: a write the model tries is refused, never drafted or run.
        tools.reads = []
        let personaText = sampleText
        environment.model = ScriptedMemoryReviewModel { _, user in
            if user.contains("send_email was refused") || user.contains("not one of this routine's allowed tools") { return personaText }
            return call("send_email", ["to": "dan@example.com", "subject": "Pickup", "body": "Yes."])
        }
        let refused = await runner.run(schedule, now: mondayMorning)
        check("a write was not refused with a reason",
              refused.refusals.count == 1 && refused.refusals[0].contains("not one of this routine's allowed tools"))
        check("a refused write ran or became a draft",
              tools.reads.isEmpty && tools.executedWrites == 0 && refused.drafts.isEmpty && store.awaitingDrafts.isEmpty)
        check("the run did not still answer after the refusal", refused.status == .reported && refused.text == personaText)

        // An empty day is silence: nothing is delivered and nothing is rendered.
        environment.model = ScriptedMemoryReviewModel { _, _ in ScheduledRunner.silenceToken }
        let silent = await runner.run(schedule, now: mondayMorning)
        check("NOTHING_TO_REPORT was not silent", silent.status == .nothingToReport && silent.text.isEmpty && silent.artifacts.isEmpty)
        return failures
    }

    // MARK: - The audio: text first, then one voice

    private static func audioFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append("audio: \(name)") } }
        check("the live PCM graph was running before rendering", AgentPCMRenderer.shared.isRunning == false)
        let answer = sampleText
        let script = LongFormScript.parse(answer)
        let clauses = script.clauseCount
        check("the script has no clauses", clauses > 10)
        check("a heading or label reached the script",
              script.sections.flatMap(\.clauses).allSatisfy { !$0.text.contains("#") && !$0.text.contains("Host ") })

        func make(_ name: String, spy: SynthesisSpy, container: LongFormRenderer.Container = .m4a,
                  environment: FakeYieldEnvironment = FakeYieldEnvironment(), yieldTimeout: TimeInterval = 1) -> (LongFormRenderer, URL) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            return (LongFormRenderer(directory: directory, container: container, synthesis: spy.closure,
                                     environment: environment,
                                     limits: .init(maxDuration: 600, yieldTimeout: yieldTimeout, yieldPoll: 0.05)), directory)
        }

        // The text is handed back first; the render starts only when its work runs.
        let spy = SynthesisSpy(samplesPerClause: 24_000, sampleRate: 24_000)
        let (renderer, library) = make("audio", spy: spy)
        var spawned: [@MainActor () async -> Void] = []
        var attached: [String] = []
        let transform = CatchUpTemplate.resultTransform(
            renderer: renderer, attach: { attached.append($0) }, spawn: { spawned.append($0) })
        let taskID = "catch-up-\(UUID().uuidString)"
        let answered = await transform(catchUp(), answer, taskID, mondayMorning)
        check("the text was changed", answered.text == answer)
        check("the answer carried a file before any audio existed", answered.artifacts.isEmpty)
        check("the render did not wait for the answer to return",
              spawned.count == 1 && spy.calls.isEmpty && attached.isEmpty && !FileManager.default.fileExists(atPath: library.path))
        await spawned.first?()
        let file = library.appendingPathComponent("Your Monday catch-up 2026-10-05.m4a")
        check("every clause did not go through the voice once", spy.calls.count == clauses)
        check("the voice was asked for two voices", spy.calls.allSatisfy { $0.speaker == nil })
        check("a label or heading was spoken", spy.calls.allSatisfy { !$0.text.contains("Host") && !$0.text.contains("#") })
        check("the file is not at its moment-titled name", directoryContents(library) == [file.lastPathComponent])
        if let asset = Optional(AVURLAsset(url: file)), let seconds = try? await asset.load(.duration).seconds {
            check("the audio length is wrong (\(seconds) s for \(clauses) clauses)", abs(seconds - Double(clauses)) < 1.5)
        } else {
            failures.append("audio: the file is not readable by AVFoundation")
        }
        check("the file was not linked to the same task", attached == [taskID])
        check("the file did not reach the artifact ledger",
              AgentArtifactLedger.take(taskID: taskID) == [file.absoluteString])
        check("the live graph was touched", AgentPCMRenderer.shared.isRunning == false)

        // Exact duration and an atomic write, on a WAV at a known rate.
        let wavSpy = SynthesisSpy(samplesPerClause: 24_000, sampleRate: 24_000)
        let (wavRenderer, wavDirectory) = make("wav", spy: wavSpy, container: .wav)
        do {
            let rendered = try await wavRenderer.render(script, title: "While you were out", edition: "2026-10-05")
            check("the duration is not exactly one second a clause", abs(rendered.duration - Double(clauses)) < 1e-9)
            check("the byte count is wrong", rendered.byteCount == 44 + clauses * 24_000 * 2)
            check("a wavering render left staging files", directoryContents(wavDirectory) == ["While you were out 2026-10-05.wav"])
            check("a catch-up has chapters from headings it does not have", rendered.chapters.isEmpty)
        } catch {
            failures.append("audio: the wav render threw \(error)")
        }
        let failingSpy = SynthesisSpy(samplesPerClause: 24_000, sampleRate: 24_000, failOnCall: 3)
        let (failing, failingDirectory) = make("atomic", spy: failingSpy, container: .wav)
        try? FileManager.default.createDirectory(at: failingDirectory, withIntermediateDirectories: true)
        let previous = failingDirectory.appendingPathComponent("While you were out 2026-10-05.wav")
        try? Data("OLD".utf8).write(to: previous)
        _ = try? await failing.render(script, title: "While you were out", edition: "2026-10-05")
        check("a failed render touched the previous edition", (try? Data(contentsOf: previous)) == Data("OLD".utf8)
              && directoryContents(failingDirectory) == [previous.lastPathComponent])

        // The audio failing never touches the text or the task.
        let failureCases: [(name: String, spy: SynthesisSpy, environment: FakeYieldEnvironment)] = [
            ("no voice", SynthesisSpy(samplesPerClause: 1, sampleRate: 24_000, failure: LongFormRenderError.voiceUnavailable), FakeYieldEnvironment()),
            ("busy mac", SynthesisSpy(samplesPerClause: 1_000, sampleRate: 24_000), FakeYieldEnvironment(recording: true)),
            ("disk full", SynthesisSpy(samplesPerClause: 1, sampleRate: 24_000, failure: LongFormRenderError.diskFull), FakeYieldEnvironment()),
        ]
        for item in failureCases {
            let name = item.name
            let (broken, brokenDirectory) = make("broken-\(name)", spy: item.spy, environment: item.environment, yieldTimeout: 0.2)
            var work: [@MainActor () async -> Void] = []
            var linked: [String] = []
            let id = "catch-up-\(UUID().uuidString)"
            let result = await CatchUpTemplate.resultTransform(
                renderer: broken, attach: { linked.append($0) }, spawn: { work.append($0) })(catchUp(), answer, id, mondayMorning)
            check("\(name): the text was withheld or changed", result.text == answer && result.artifacts.isEmpty)
            await work.first?()
            check("\(name): a file or link appeared", linked.isEmpty && AgentArtifactLedger.peek(taskID: id).isEmpty
                  && directoryContents(brokenDirectory).isEmpty)
        }

        // The render yields to live speech (one audio channel): once the agent starts talking
        // mid-render, no further clause is synthesized until it stops.
        let talkSpy = SynthesisSpy(samplesPerClause: 1_000, sampleRate: 24_000)
        let talking = FakeYieldEnvironment(speakingReads: 3, speakAfterCalls: 2, spy: talkSpy)
        let (talkRenderer, _) = make("talking", spy: talkSpy, container: .wav, environment: talking)
        _ = try? await talkRenderer.render(script, title: "Your morning catch-up", edition: "2026-10-05")
        check("the render did not wait out live speech (clauses synthesized while it spoke: \(talking.callsWhileSpeaking))",
              talking.callsWhileSpeaking == [2, 2, 2] && talkSpy.calls.count == clauses)

        // Only a catch-up is rendered; silence and other routines pass through untouched.
        let before = spy.calls.count
        var extra: [@MainActor () async -> Void] = []
        let guarded = CatchUpTemplate.resultTransform(renderer: renderer, spawn: { extra.append($0) })
        let foreign = await guarded(catchUp(title: "Inbox check", templateID: nil), answer, "t", mondayMorning)
        let silence = await guarded(catchUp(), ScheduledRunner.silenceToken, "t", mondayMorning)
        let blank = await guarded(catchUp(), "  \n ", "t", mondayMorning)
        check("a foreign answer was rewritten or rendered", foreign.text == answer && foreign.artifacts.isEmpty)
        check("silence was rewritten or rendered", silence.text == ScheduledRunner.silenceToken)
        check("an empty answer was rendered", blank.text == "  \n ")
        check("something other than a catch-up spawned audio", extra.isEmpty && spy.calls.count == before)
        // The return moment names its own file.
        let returnSpy = SynthesisSpy(samplesPerClause: 24_000, sampleRate: 24_000)
        let (returnRenderer, returnDirectory) = make("return", spy: returnSpy)
        var returnWork: [@MainActor () async -> Void] = []
        _ = await CatchUpTemplate.resultTransform(renderer: returnRenderer, spawn: { returnWork.append($0) })(
            catchUp(title: "While you were out", kind: .trigger, trigger: .returned), answer, "t2", mondayMorning)
        await returnWork.first?()
        check("the return catch-up is not titled by its moment",
              directoryContents(returnDirectory) == ["While you were out 2026-10-05.m4a"])
        _ = AgentArtifactLedger.take(taskID: "t2")

        // Through the real runner and the real task manager: delivered text first, file linked later.
        let manager = AgentTaskManager.shared
        let taskRecorder = TaskRecorder()
        let runnerSpy = SynthesisSpy(samplesPerClause: 24_000, sampleRate: 24_000)
        let (runnerRenderer, runnerDirectory) = make("runner", spy: runnerSpy)
        var runnerWork: [@MainActor () async -> Void] = []
        let environment = RoutineAuthoritySelfTest.FakeRunEnvironment()
        environment.model = ScriptedMemoryReviewModel { _, _ in answer }
        let runner = ScheduledRunner(
            store: ScheduleStore(directory: root.appendingPathComponent("runner-store", isDirectory: true)),
            environment: environment, tools: RoutineAuthoritySelfTest.FakeToolRunner(), recorder: taskRecorder,
            timeZone: { zone },
            answerTransform: CatchUpTemplate.resultTransform(
                renderer: runnerRenderer, attach: { manager.foldArtifacts(taskID: $0) }, spawn: { runnerWork.append($0) }))
        let outcome = await runner.run(catchUp(), now: mondayMorning)
        let id = outcome.taskID ?? ""
        check("the run did not deliver the text", outcome.status == .reported && outcome.text == answer
              && manager.task(id: id)?.result == answer)
        check("the task had a file before the audio existed", manager.task(id: id)?.artifacts.isEmpty != false
              && runnerSpy.calls.isEmpty)
        await runnerWork.first?()
        let expected = runnerDirectory.appendingPathComponent("Your Monday catch-up 2026-10-05.m4a").absoluteString
        check("the file did not reach the finished task", manager.task(id: id)?.artifacts == [expected])
        check("the live graph was running across the run", AgentPCMRenderer.shared.isRunning == false)
        return failures
    }

    // MARK: - The presence signal

    private static func detectorFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append("presence: \(name)") } }
        let friday = ScheduleSelfTest.date(2026, 10, 2, 18, 0)
        let monday = ScheduleSelfTest.date(2026, 10, 5, 8, 0)
        var detector = AbsenceDetector()
        check("the first sample was a return", detector.observe(now: friday, present: true, blocked: false) == nil)
        check("twenty minutes was a return",
              detector.observe(now: friday.addingTimeInterval(1_200), present: true, blocked: false) == nil)
        check("an absent sample changed anything",
              detector.observe(now: friday.addingTimeInterval(36_000), present: false, blocked: false) == nil
                && detector.lastPresentAt == friday.addingTimeInterval(1_200))
        check("five hours away was a return",
              detector.observe(now: friday.addingTimeInterval(1_200 + 5 * 3_600), present: true, blocked: false) == nil)
        var weekend = AbsenceDetector()
        _ = weekend.observe(now: friday, present: true, blocked: false)
        let returned = weekend.observe(now: monday, present: true, blocked: false)
        check("the weekend return did not publish", returned?.event == .returned
              && returned?.key == "return:\(Int(friday.timeIntervalSince1970))" && returned?.start == friday
              && returned?.observedAt == monday)
        check("the same return published twice",
              weekend.observe(now: monday.addingTimeInterval(30), present: true, blocked: false) == nil
                && weekend.observe(now: monday.addingTimeInterval(3_600), present: true, blocked: false) == nil)

        // A return into a call, a recording, a dictation, an agent turn or quiet hours is held,
        // published at the first free moment inside the window, and dropped after it.
        var held = AbsenceDetector()
        _ = held.observe(now: friday, present: true, blocked: false)
        check("a blocked return published", held.observe(now: monday, present: true, blocked: true) == nil)
        check("a return still blocked ten minutes later published",
              held.observe(now: monday.addingTimeInterval(600), present: true, blocked: true) == nil)
        let late = held.observe(now: monday.addingTimeInterval(1_200), present: true, blocked: false)
        check("a held return was not published once free", late?.key == "return:\(Int(friday.timeIntervalSince1970))")
        check("a held return published twice", held.observe(now: monday.addingTimeInterval(1_230), present: true, blocked: false) == nil)
        var expired = AbsenceDetector()
        _ = expired.observe(now: friday, present: true, blocked: false)
        _ = expired.observe(now: monday, present: true, blocked: true)
        var published = false
        for minute in stride(from: 5, through: 120, by: 5) {
            let blocked = minute < 50
            if expired.observe(now: monday.addingTimeInterval(TimeInterval(minute * 60)), present: true, blocked: blocked) != nil {
                published = true
            }
        }
        check("a return held past its window was published", !published)
        var wandered = AbsenceDetector()
        _ = wandered.observe(now: friday, present: true, blocked: false)
        _ = wandered.observe(now: monday, present: true, blocked: true)
        check("a held return published to someone who left",
              wandered.observe(now: monday.addingTimeInterval(600), present: false, blocked: false) == nil)
        var backwards = AbsenceDetector()
        _ = backwards.observe(now: monday, present: true, blocked: false)
        check("a clock that went backwards published",
              backwards.observe(now: friday, present: true, blocked: false) == nil)
        return failures
    }

    // MARK: - Triggers, delivery and the on-demand run, through the real scheduler

    private final class FakeSystem: ReminderSystemRegistering {
        func register(_ schedule: AgentSchedule, slot: Date) async -> Bool { true }
        func withdraw(scheduleID: UUID) {}
        func pendingScheduleIDs() async -> Set<UUID> { [] }
        func isAuthorized() async -> Bool { true }
    }

    private final class FakeDeliverer: ScheduleDelivering {
        var deliveries: [ScheduleDelivery] = []
        func deliver(_ delivery: ScheduleDelivery) async throws { deliveries.append(delivery) }
        func notifyProblem(scheduleID: UUID, title: String, body: String) {}
        func notifyDrafts(_ drafts: [RoutineDraft], scheduleTitle: String) {}
        func openSchedules() {}
        func speak(_ text: String) {}
    }

    private final class FakeEnvironment: ScheduleEnvironment {
        var isUserPresent = true
        var isRecording = false
        var isDictating = false
        var isCallActive = false
        var isAgentBusy = false
    }

    @MainActor
    private final class ScriptedRunner: ScheduledRunning {
        var runs: [(title: String, prompt: String)] = []
        var outcome = ScheduledRunOutcome(status: .reported, text: sampleText)
        /// The next run does not return until `letGo()`: a model call still in flight.
        var hold = false
        private(set) var holding = false
        private var release: CheckedContinuation<Void, Never>?

        func run(_ schedule: AgentSchedule, now: Date) async -> ScheduledRunOutcome {
            runs.append((schedule.displayTitle(now: now, zone: zone), schedule.prompt))
            if hold {
                hold = false
                holding = true
                await withCheckedContinuation { release = $0 }
                holding = false
            }
            return outcome
        }

        func letGo() {
            release?.resume()
            release = nil
        }
    }

    @MainActor
    private struct Rig {
        let store: ScheduleStore
        let events = AgentTriggerEvents()
        let environment = FakeEnvironment()
        let deliverer = FakeDeliverer()
        let runner = ScriptedRunner()
        let scheduler: AgentScheduler
        let seen = Box()

        final class Box { var occurrences: [ScheduleTriggerOccurrence] = [] }

        init(directory: URL, quiet: Bool = false) {
            store = ScheduleStore(directory: directory)
            let settings = ScheduleSettingsSnapshot(
                enabled: true,
                quietStart: quiet ? ScheduleLocalTime(hour: 21, minute: 0) : nil,
                quietEnd: quiet ? ScheduleLocalTime(hour: 8, minute: 0) : nil, speech: .whenPresent)
            scheduler = AgentScheduler(
                store: store, system: FakeSystem(), deliverer: deliverer, environment: environment,
                settings: { settings }, timeZone: { CatchUpSelfTest.zone }, runner: runner, events: events)
            let box = seen
            events.subscribe { box.occurrences += $0 }
        }
    }

    private static func triggerFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append("trigger: \(name)") } }
        let friday = ScheduleSelfTest.date(2026, 10, 2, 18, 0)
        let monday = ScheduleSelfTest.date(2026, 10, 5, 8, 0)
        var counter = 0
        func rig(quiet: Bool = false) -> Rig {
            counter += 1
            return Rig(directory: root.appendingPathComponent("rig-\(counter)", isDirectory: true), quiet: quiet)
        }

        // The scheduler's own tick publishes one return, from its own presence signal.
        let a = rig()
        await a.scheduler.runOnce(now: friday)
        a.environment.isUserPresent = false
        await a.scheduler.runOnce(now: friday.addingTimeInterval(86_400))
        check("an absent sample or the first sample published", a.seen.occurrences.isEmpty)
        a.environment.isUserPresent = true
        await a.scheduler.runOnce(now: monday)
        await a.scheduler.runOnce(now: monday.addingTimeInterval(30))
        await a.scheduler.runOnce(now: monday.addingTimeInterval(4 * 3_600))
        check("the return was not published exactly once",
              a.seen.occurrences.count == 1 && a.seen.occurrences.first?.key == "return:\(Int(friday.timeIntervalSince1970))")

        // Never into a call, a recording, a dictation, an agent turn or quiet hours.
        let blockers: [(String, (FakeEnvironment, Bool) -> Void)] = [
            ("a call", { $0.isCallActive = $1 }), ("a recording", { $0.isRecording = $1 }),
            ("a dictation", { $0.isDictating = $1 }), ("an agent turn", { $0.isAgentBusy = $1 }),
        ]
        for (name, set) in blockers {
            let b = rig()
            await b.scheduler.runOnce(now: friday)
            set(b.environment, true)
            await b.scheduler.runOnce(now: monday)
            await b.scheduler.runOnce(now: monday.addingTimeInterval(600))
            check("a return was published into \(name)", b.seen.occurrences.isEmpty)
            set(b.environment, false)
            await b.scheduler.runOnce(now: monday.addingTimeInterval(1_200))
            check("a return held through \(name) was not published once it ended", b.seen.occurrences.count == 1)
            let c = rig()
            await c.scheduler.runOnce(now: friday)
            set(c.environment, true)
            await c.scheduler.runOnce(now: monday)
            set(c.environment, false)
            await c.scheduler.runOnce(now: monday.addingTimeInterval(3 * 3_600))
            check("a return held through \(name) for hours was published", c.seen.occurrences.isEmpty)
        }
        let quiet = rig(quiet: true)
        await quiet.scheduler.runOnce(now: friday.addingTimeInterval(-86_400))
        let early = ScheduleSelfTest.date(2026, 10, 5, 7, 40)
        await quiet.scheduler.runOnce(now: early)
        check("a return was published inside quiet hours", quiet.seen.occurrences.isEmpty)
        await quiet.scheduler.runOnce(now: ScheduleSelfTest.date(2026, 10, 5, 8, 5))
        check("a return held through quiet hours was not published when they ended", quiet.seen.occurrences.count == 1)

        // The event runs once, and is delivered titled by the moment, said without the title.
        let r = rig()
        let created = ScheduleSelfTest.date(2026, 10, 1, 9, 0)
        let trigger = catchUp(title: "While you were out", kind: .trigger, trigger: .returned, delivery: .notify)
        if let added = try? await r.scheduler.add(trigger, now: created) {
            check("the trigger was not saved", r.store.schedule(id: added.id) != nil)
            let occurrence = ScheduleTriggerOccurrence.returned(awayFrom: friday, at: monday)
            await r.scheduler.handleTriggerEvents([occurrence], now: monday)
            await r.scheduler.handleTriggerEvents([occurrence], now: monday.addingTimeInterval(60))
            check("one return did not run exactly once", r.runner.runs.count == 1 && r.deliverer.deliveries.count == 1)
            check("the run was not told about the return",
                  r.runner.runs.first?.prompt.contains("back at their Mac after being away since") == true
                    && r.runner.runs.first?.prompt.contains("about 62 hours") == true)
            let delivery = r.deliverer.deliveries.first
            check("the delivery is not titled by the moment", delivery?.title == "While you were out")
            check("the delivery's words changed", delivery?.body == sampleText)
            check("a title was spoken in front of the catch-up", delivery?.spoken == sampleText)
            check("the return catch-up spoke when it was set to notify only", delivery?.speak == false)
            check("the return was not claimed", r.store.schedule(id: added.id)?.hasHandled(occurrence.key) == true)
            let other = ScheduleTriggerOccurrence.returned(awayFrom: monday, at: monday.addingTimeInterval(8 * 3_600))
            await r.scheduler.handleTriggerEvents([other], now: monday.addingTimeInterval(8 * 3_600))
            check("a second absence did not run", r.runner.runs.count == 2)
        } else {
            failures.append("trigger: the return trigger could not be added")
        }

        // Another catch-up just told them: skipped and claimed, not run twice. A quiet one does not count.
        for (told, outcome, wantRuns) in [(true, ScheduleRunRecord.Outcome.completed, 0), (false, .nothingToReport, 1)] {
            let d = rig()
            var morning = catchUp()
            morning.lastRun = ScheduleRunSummary(
                at: ScheduleSelfTest.date(2026, 10, 5, 6, 0), outcome: outcome, detail: told ? "told" : "quiet")
            d.store.save(morning)
            let back = catchUp(title: "While you were out", kind: .trigger, trigger: .returned, delivery: .notify)
            _ = try? await d.scheduler.add(back, now: created)
            let occurrence = ScheduleTriggerOccurrence.returned(awayFrom: friday, at: monday)
            await d.scheduler.handleTriggerEvents([occurrence], now: monday)
            check("a catch-up reaching them 2 hours ago \(told ? "did not skip" : "skipped") the return",
                  d.runner.runs.count == wantRuns)
            if told {
                let record = d.store.schedule(id: back.id)
                check("the skip was not recorded and claimed",
                      record?.lastRun?.outcome == .skipped && record?.lastRun?.detail.contains("caught up") == true
                        && record?.hasHandled(occurrence.key) == true)
            }
        }
        // Reverse cooldown: the real return path at 05:30 must suppress the due 06:00
        // routine, advance its slot, and let it run the next morning. Silence must not
        // suppress it. Keep the original timings so this fails on the one-way packet.
        for reported in [true, false] {
            let reverse = rig()
            let returnAt = ScheduleSelfTest.date(2026, 10, 5, 5, 30)
            let morningAt = ScheduleSelfTest.date(2026, 10, 5, 6, 0)
            let nextMorning = ScheduleSelfTest.date(2026, 10, 6, 6, 0)
            let morning = catchUp()
            let back = catchUp(title: "While you were out", kind: .trigger, trigger: .returned, delivery: .notify)
            guard let added = try? await reverse.scheduler.add(
                morning, now: ScheduleSelfTest.date(2026, 10, 4, 12, 0)),
                  (try? await reverse.scheduler.add(back, now: created)) != nil else {
                failures.append("trigger: the reverse-cooldown rig could not be built")
                continue
            }
            reverse.runner.outcome = ScheduledRunOutcome(
                status: reported ? .reported : .nothingToReport, text: reported ? sampleText : "")
            await reverse.scheduler.handleTriggerEvents(
                [.returned(awayFrom: friday, at: returnAt)], now: returnAt)
            check("the 05:30 return did not run once", reverse.runner.runs.count == 1)
            check("the 05:30 return did not retain its real outcome",
                  reverse.store.schedule(id: back.id)?.lastRun?.outcome == (reported ? .completed : .nothingToReport))
            reverse.runner.outcome = ScheduledRunOutcome(status: .reported, text: sampleText)
            await reverse.scheduler.runOnce(now: morningAt)
            check("the 06:00 catch-up \(reported ? "ran after" : "did not run after") the 05:30 return",
                  reverse.runner.runs.count == (reported ? 1 : 2))
            check("the 06:00 catch-up delivered a duplicate or lost the silence control",
                  reverse.deliverer.deliveries.count == 1)
            let saved = reverse.store.schedule(id: added.id)
            check("the 06:00 slot was not advanced without a retry",
                  saved?.nextRunAt == nextMorning && saved?.pendingDeliveries.isEmpty == true)
            if reported {
                check("the reverse-cooldown skip was not recorded",
                      saved?.lastRun?.outcome == .skipped && saved?.lastRun?.detail.contains("caught up") == true)
                await reverse.scheduler.runOnce(now: morningAt.addingTimeInterval(30))
                check("the suppressed 06:00 catch-up ran on the next pass", reverse.runner.runs.count == 1)
            }
            await reverse.scheduler.runOnce(now: nextMorning)
            check("the next morning stayed suppressed after the cooldown expired",
                  reverse.runner.runs.count == (reported ? 2 : 3)
                    && reverse.deliverer.deliveries.count == 2)
        }

        // The same admission rule applies to scheduled retries and held results. An
        // explicit snooze and an ordinary routine retain their requested delivery.
        for text in [nil, sampleText] as [String?] {
            for control in ["catch-up", "snooze", "ordinary", "reminder"] {
                let retry = rig()
                let returnAt = ScheduleSelfTest.date(2026, 10, 5, 5, 30)
                let morningAt = ScheduleSelfTest.date(2026, 10, 5, 6, 0)
                let nextMorning = ScheduleSelfTest.date(2026, 10, 6, 6, 0)
                guard var morning = try? await retry.scheduler.add(
                    catchUp(), now: ScheduleSelfTest.date(2026, 10, 4, 12, 0)),
                      (try? await retry.scheduler.add(
                        catchUp(title: "While you were out", kind: .trigger, trigger: .returned, delivery: .notify),
                        now: created)) != nil else {
                    failures.append("trigger: the scheduled retry cooldown rig could not be built")
                    continue
                }
                // The local `created` is Thursday: adding then would leave Friday overdue,
                // which correctly reserves a morning catch-up and suppresses the return.
                check("the retry rig did not begin with Monday's future morning slot", morning.nextRunAt == morningAt)
                check("the earlier fixture date did not produce the confirmed overdue slot",
                      morning.when.flatMap(RecurrenceRule.init)?.next(after: created) == ScheduleSelfTest.date(2026, 10, 2, 6, 0))
                await retry.scheduler.handleTriggerEvents([.returned(awayFrom: friday, at: returnAt)], now: returnAt)
                check("the retry rig's return did not reach the person", retry.deliverer.deliveries.count == 1)
                // Retained pending work is the input to the actual scheduled consumer.
                morning.nextRunAt = nextMorning
                morning.pendingDelivery = SchedulePendingDelivery(
                    slot: morningAt, notBefore: morningAt, missed: false,
                    reason: control == "snooze" ? AgentScheduler.snoozeReason : "retry", text: text)
                if control == "ordinary" { morning.templateID = nil; morning.title = "Inbox check" }
                if control == "reminder" { morning.templateID = nil; morning.kind = .reminder }
                check("the scheduled retry fixture did not save", retry.store.save(morning))
                await retry.scheduler.runOnce(now: morningAt)
                let suppressed = control == "catch-up"
                check("scheduled pending \(control) lost its cooldown or explicit control (text=\(text != nil))",
                      retry.runner.runs.count == (suppressed || text != nil || control == "reminder" ? 1 : 2)
                        && retry.deliverer.deliveries.count == (suppressed ? 1 : 2))
                let saved = retry.store.schedule(id: morning.id)
                check("scheduled pending \(control) did not clear without changing its next slot",
                      saved?.pendingDelivery == nil && saved?.nextRunAt == nextMorning)
                if suppressed {
                    check("scheduled pending cooldown did not record its skip",
                          saved?.lastRun?.outcome == .skipped && saved?.lastRun?.detail.contains("caught up") == true)
                }
            }
        }

        // A catch-up that is running, due, or waiting to retry counts as having reached them.
        let due = ScheduleSelfTest.date(2026, 10, 5, 6, 0, 10)
        let sunday = ScheduleSelfTest.date(2026, 10, 4, 12, 0)
        let wake = ScheduleTriggerOccurrence.returned(awayFrom: friday, at: due)
        func withBoth(_ r: Rig) async -> AgentSchedule? {
            _ = try? await r.scheduler.add(catchUp(), now: sunday)
            return try? await r.scheduler.add(
                catchUp(title: "While you were out", kind: .trigger, trigger: .returned, delivery: .notify), now: created)
        }
        let inFlight = rig()
        if let back = await withBoth(inFlight) {
            inFlight.runner.hold = true
            let pass = Task { @MainActor in await inFlight.scheduler.runOnce(now: due) }
            var spins = 0
            while !inFlight.runner.holding, spins < 20_000 { await Task.yield(); spins += 1 }
            await inFlight.scheduler.handleTriggerEvents([wake], now: due.addingTimeInterval(30))
            check("a return ran a second catch-up while the morning one was still running", inFlight.runner.runs.count == 1)
            check("the skipped return was not recorded and claimed",
                  inFlight.store.schedule(id: back.id)?.lastRun?.outcome == .skipped
                    && inFlight.store.schedule(id: back.id)?.hasHandled(wake.key) == true)
            inFlight.runner.letGo()
            await pass.value
            check("the morning catch-up was not delivered exactly once", inFlight.deliverer.deliveries.count == 1)
        } else {
            failures.append("trigger: the in-flight rig could not be built")
        }
        let notClaimed = rig()
        if await withBoth(notClaimed) != nil {
            await notClaimed.scheduler.handleTriggerEvents([wake], now: due.addingTimeInterval(30))
            check("a return ran while the morning catch-up was due and not yet claimed", notClaimed.runner.runs.isEmpty)
        }
        let retrying = rig()
        if await withBoth(retrying) != nil, var morning = retrying.store.schedules.first(where: { $0.kind == .routine }) {
            morning.pendingDelivery = SchedulePendingDelivery(
                slot: due, notBefore: due.addingTimeInterval(60), missed: false, reason: AgentScheduler.skipRetryReason)
            morning.nextRunAt = ScheduleSelfTest.date(2026, 10, 6, 6, 0)
            retrying.store.save(morning)
            await retrying.scheduler.handleTriggerEvents([wake], now: due.addingTimeInterval(30))
            check("a return ran while the morning catch-up was waiting to retry", retrying.runner.runs.isEmpty)
        }
        // The retry path asks again: a return that was skipped for a busy model is not run later
        // if a catch-up reached them in between, and still runs when none did.
        for (reached, wantRuns) in [(true, 0), (false, 1)] {
            let r = rig()
            let back = catchUp(title: "While you were out", kind: .trigger, trigger: .returned, delivery: .notify)
            _ = try? await r.scheduler.add(back, now: created)
            if var saved = r.store.schedule(id: back.id) {
                saved.pendingDeliveries = [SchedulePendingDelivery(
                    slot: nil, notBefore: due, missed: false, reason: AgentScheduler.skipRetryReason, occurrence: wake)]
                r.store.save(saved)
            }
            if reached {
                var morning = catchUp()
                morning.lastRun = ScheduleRunSummary(at: due.addingTimeInterval(-1_800), outcome: .completed, detail: "told")
                r.store.save(morning)
            }
            await r.scheduler.runOnce(now: due.addingTimeInterval(60))
            check("a retried return \(reached ? "ran after" : "did not run without") a catch-up reaching them",
                  r.runner.runs.count == wantRuns)
            if reached {
                check("the retried return was not skipped and cleared",
                      r.store.schedule(id: back.id)?.lastRun?.outcome == .skipped
                        && r.store.schedule(id: back.id)?.pendingDeliveries.isEmpty == true)
            }
        }
        check("the decision is not pure over the cooldown",
              AgentScheduler.triggerDecision(.returned, occurrence: .returned(awayFrom: friday, at: monday),
                                             createdAt: created, now: monday) == .run
                && AgentScheduler.triggerDecision(.returned, occurrence: .returned(awayFrom: friday, at: monday),
                                                  createdAt: created, now: monday, recentCatchUpAt: monday) != .run
                && AgentScheduler.triggerDecision(.returned, occurrence: .returned(awayFrom: friday, at: monday),
                                                  createdAt: monday.addingTimeInterval(3_600), now: monday) == .ignore
                && AgentScheduler.triggerDecision(.callStarted, occurrence: .returned(awayFrom: friday, at: monday),
                                                  createdAt: created, now: monday) == .ignore)
        check("a return is retried for longer than half an hour",
              AgentScheduler.triggerDeadline(for: .returned(awayFrom: friday, at: monday))
                == monday.addingTimeInterval(AgentScheduler.returnedRetryWindow))

        // The morning routine, due Monday at 06:00: titled by the day, said without a title,
        // never spoken into a call, and "catch me up" is the same routine run now.
        let m = rig()
        let routine = catchUp()
        if let added = try? await m.scheduler.add(routine, now: ScheduleSelfTest.date(2026, 10, 4, 12, 0)) {
            let due = ScheduleSelfTest.date(2026, 10, 5, 6, 0, 10)
            await m.scheduler.runOnce(now: due)
            let delivery = m.deliverer.deliveries.first
            check("the Monday catch-up was not delivered by the due slot", m.runner.runs.count == 1 && delivery != nil)
            check("the Monday delivery is not titled by the day", delivery?.title == "Your Monday catch-up"
                  && m.runner.runs.first?.title == "Your Monday catch-up")
            check("a title was spoken in front of the morning catch-up", delivery?.spoken == sampleText
                  && delivery?.body == sampleText)
            check("the morning catch-up did not speak to a present person", delivery?.speak == true)
            m.environment.isCallActive = true
            _ = try? await m.scheduler.runNow(id: added.id, now: tuesdayMorning)
            let onDemand = m.deliverer.deliveries.last
            check("catch me up did not run the same routine now", m.runner.runs.count == 2
                  && onDemand?.title == "Your morning catch-up" && onDemand?.body == sampleText)
            check("a catch-up was spoken into a call", onDemand?.speak == false)
        } else {
            failures.append("trigger: the morning catch-up could not be added")
        }

        // Setup through the real create tool: identity, moment title, budget, reads only.
        let t = rig()
        let create = ScheduleToolCatalogue.all.first { $0.name == "create" }!
        let available = Set(CatchUpTemplate.allowedTools)
        for moment in [CatchUpTemplate.Moment.morning, .whileOut] {
            do {
                _ = try await ScheduleToolExecutor.run(
                    create, arguments: CatchUpTemplate.createArguments(moment: moment), scheduler: t.scheduler,
                    now: created, timeZone: zone, availableTools: available)
            } catch {
                failures.append("trigger: creating the \(moment.rawValue) catch-up threw \(error.localizedDescription)")
            }
        }
        let saved = t.store.schedules
        check("create did not save both catch-ups with their identity",
              saved.count == 2 && saved.allSatisfy { $0.templateID == CatchUpTemplate.identity })
        if let routine = saved.first(where: { $0.kind == .routine }), let back = saved.first(where: { $0.kind == .trigger }) {
            check("the saved morning catch-up is wrong",
                  routine.title == "Your morning catch-up" && routine.when?.repeatRule == .weekdays
                    && routine.when?.time == ScheduleLocalTime(hour: 6, minute: 0) && routine.delivery == .notifyAndSpeak
                    && routine.budget.maxOutputTokens == CatchUpTemplate.maxOutputTokens
                    && routine.allowedTools == CatchUpTemplate.allowedTools
                    && routine.plainEnglish == CatchUpTemplate.plainEnglish(for: routine))
            check("the saved return catch-up is wrong",
                  back.title == "While you were out" && back.trigger == .returned && back.delivery == .notify
                    && back.allowedTools == CatchUpTemplate.allowedTools && back.when == nil
                    && back.plainEnglish == CatchUpTemplate.plainEnglish(for: back))
        } else {
            failures.append("trigger: create did not save a routine and a trigger")
        }
        return failures
    }

    // MARK: - A real voice (opt-in)

    /// `--selftest-catch-up --real-voice [--real-voice-out <file>]`: the production path with no
    /// spy. The voice models are not fetched here: when the files are not already on disk the
    /// run says `CATCH_UP_REAL_VOICE_ABSENT` and stops, so a self-test never downloads a model
    /// nobody chose. Nothing is pre-warmed: `LongFormSynthesisFactory.live()` is pointed at the
    /// voice and the renderer meets the cold model itself, which is the start-up case a morning
    /// catch-up hits. The file must be readable, carry signal and match the renderer's own length.
    private static func realVoiceRun(root: URL) async -> Bool {
        let models = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
        func present(_ directory: URL, _ names: [String]) -> Bool {
            names.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
        let pocketOnDisk = present(models.appendingPathComponent("pocket-tts/v2.1/english", isDirectory: true),
                                   ["flowlm_stepv2.mlmodelc", "flow_decoder_fused.mlmodelc", "mimi_decoder.mlmodelc",
                                    "cond_prefill.mlmodelc", "constants_bin"])
        let kokoroOnDisk = KokoroAgentVoice.isSupportedOS
            && present(models.appendingPathComponent(Repo.kokoroAne.folderName, isDirectory: true),
                       Array(ModelNames.KokoroAne.requiredModels))
        guard pocketOnDisk || kokoroOnDisk else {
            print("CATCH_UP_REAL_VOICE_ABSENT: no Pocket or Kokoro model files under \(models.path); nothing was downloaded")
            return false
        }
        // The harness has its own defaults, so this never touches the person's choice.
        Settings.shared.agentVoiceEngine = pocketOnDisk ? "pocket" : "kokoro"
        let engine = Settings.shared.agentVoiceEngine

        let directory = root.appendingPathComponent("real-voice", isDirectory: true)
        let renderer = LongFormRenderer(
            directory: directory, container: .m4a, synthesis: LongFormSynthesisFactory.live(),
            environment: LiveLongFormEnvironment())
        let script = LongFormScript.parse(sampleText.split(separator: "\n\n").prefix(1).joined(separator: "\n\n"))
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) { if !condition { failures.append(name) } }
        check("the script is too short", script.clauseCount > 3)
        let started = ContinuousClock.now
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        do {
            let rendered = try await renderer.render(script, title: "Your morning catch-up", edition: "2026-10-05")
            let renderTime = seconds(started.duration(to: .now))
            check("the file is not at its moment-titled name",
                  rendered.url.lastPathComponent == "Your morning catch-up 2026-10-05.m4a"
                    && directoryContents(directory) == [rendered.url.lastPathComponent])
            check("the file is empty or its size is not the one reported",
                  rendered.byteCount > 10_000 && ((try? Data(contentsOf: rendered.url).count) ?? 0) == rendered.byteCount)
            var peak: Float = 0
            var length = 0.0
            if let file = try? AVAudioFile(forReading: rendered.url),
               let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) {
                try? file.read(into: buffer)
                length = Double(file.length) / file.processingFormat.sampleRate
                if let channel = buffer.floatChannelData?[0] {
                    for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[index])) }
                }
            } else {
                failures.append("the file cannot be opened as audio")
            }
            check("the audio is silent (peak \(peak))", peak > 0.01)
            check("the audio is too short (\(length) s for \(script.clauseCount) clauses)", length > Double(script.clauseCount) * 0.4)
            check("the reported length (\(rendered.duration) s) is not the file's (\(length) s)", abs(rendered.duration - length) < 0.5)
            check("the live voice graph was started by a render", AgentPCMRenderer.shared.isRunning == false)
            if let out = SelfTest.value(after: "--real-voice-out") {
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(atPath: out)
                do { try FileManager.default.copyItem(at: rendered.url, to: URL(fileURLWithPath: out)) } catch {
                    failures.append("the sample could not be saved to \(out): \(error.localizedDescription)")
                }
            }
            print(String(format: "CATCH_UP_REAL_RENDER: engine=%@ clauses=%d audio=%.2fs peak=%.3f bytes=%d render=%.1fs (cold start included)",
                         engine, script.clauseCount, length, peak, rendered.byteCount, renderTime))
        } catch {
            failures.append("the render threw \(LongFormRenderer.classify(error).localizedDescription)")
        }
        for failure in failures { print("CATCH_UP_REAL_VOICE_CHECK_FAILED: \(failure)") }
        print(failures.isEmpty ? "CATCH_UP_REAL_VOICE_OK" : "CATCH_UP_REAL_VOICE_FAILED")
        return failures.isEmpty
    }

    private enum ArtifactAdmissionError: Error { case refused }

    private static func artifactAdmissionFailures(root: URL) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ value: Bool) { if !value { failures.append("artifact admission: " + name) } }
        let directory = root.appendingPathComponent("artifact-admission", isDirectory: true)
        let sql = TaskStore(root: directory)
        defer { sql.close() }
        let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
        guard store.allowsHarnessPersistence else { return ["artifact admission: unsafe fixture store"] }
        let manager = AgentTaskManager(store: store)
        let task = AgentTask(objective: "Your Monday catch-up", source: AgentTask.scheduledSource,
            createdAt: mondayMorning, status: .running, backend: "local", scheduleID: UUID())
        let first = directory.appendingPathComponent("first.wav").absoluteString
        let second = directory.appendingPathComponent("second.wav").absoluteString
        defer {
            store.migrationBoundaryForTesting = nil
            _ = AgentArtifactLedger.takeRecords(taskID: task.id)
        }
        guard manager.beginScheduledRun(task), manager.finishScheduledRun(id: task.id,
            status: .completed, result: sampleText, failure: nil) else {
            return ["artifact admission: actual scheduled task did not finish"]
        }
        do {
            let beforeSQL = try sql.load()
            let beforeCache = manager.tasks
            let beforeExport = try Data(contentsOf: store.storageURL)
            AgentArtifactLedger.capture(taskID: task.id, artifact: first)
            var refusals = 0
            store.migrationBoundaryForTesting = { phase in
                if phase == "beforePrimaryCommit" { refusals += 1; throw ArtifactAdmissionError.refused }
            }
            manager.foldArtifacts(taskID: task.id)
            check("original primary update was not actually refused",
                  refusals == 1 && manager.lastPersistenceResult?.primaryCommitted == false)
            check("refused fold changed task/cache/witness", try sql.load() == beforeSQL
                && manager.tasks == beforeCache && Data(contentsOf: store.storageURL) == beforeExport)
            check("refused fold consumed the completed audio link", AgentArtifactLedger.peek(taskID: task.id) == [first])
            store.migrationBoundaryForTesting = nil
            // Explicitly retry the same retained link. No render or model is repeated.
            manager.foldArtifacts(taskID: task.id)
            check("accepted fold failed to link the exact retained audio", manager.task(id: task.id)?.artifacts == [first]
                && AgentArtifactLedger.peekRecords(taskID: task.id).isEmpty)
            let reader = TaskStore(root: directory)
            defer { reader.close() }
            check("fresh SQL reader missed the terminal audio link", try reader.load().first { $0.id == task.id }?.artifacts == [first])
            // A producer may append during the existing commit callback. Consume only the
            // captured records, never that later link which was not in this update.
            AgentArtifactLedger.capture(taskID: task.id, artifact: first)
            store.migrationBoundaryForTesting = { phase in
                if phase == "beforePrimaryCommit" { AgentArtifactLedger.capture(taskID: task.id, artifact: second) }
            }
            manager.foldArtifacts(taskID: task.id)
            check("fold consumed a later uncopied link", AgentArtifactLedger.peek(taskID: task.id) == [second]
                && manager.task(id: task.id)?.artifacts == [first])
            store.migrationBoundaryForTesting = nil
            manager.foldArtifacts(taskID: task.id)
            manager.foldArtifacts(taskID: task.id)
            check("accepted folds duplicated or lost ordered links", manager.task(id: task.id)?.artifacts == [first, second]
                && AgentArtifactLedger.peekRecords(taskID: task.id).isEmpty)
        } catch { failures.append("artifact admission: " + error.localizedDescription) }
        return failures
    }

    /// The actual default spawn outlives its text answer; MainActor reentrancy alone
    /// must not admit two renders against the same synthesis and output directory.
    private static func renderOverlapFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ value: Bool) { if !value { failures.append("render overlap: " + name) } }
        var created: [Task<Void, Never>] = []
        guard CatchUpTemplate.observeRenderTasksForTesting(root: root, observer: { created.append($0) }) else {
            return ["render overlap: actual caller observation was refused"]
        }
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        var synthesisCalls = 0
        var linked: [String] = []
        let directory = root.appendingPathComponent("render-overlap", isDirectory: true)
        let renderer = LongFormRenderer(directory: directory, container: .wav, synthesis: { _ in
            synthesisCalls += 1
            if synthesisCalls == 1 {
                entered = true
                await withCheckedContinuation { release = $0 }
            }
            return LongFormRenderer.Audio(samples: [0.1, 0.1], sampleRate: 24_000)
        }, environment: FakeYieldEnvironment())
        let id = "catch-up-overlap-" + UUID().uuidString
        let firstID = id + "-first", secondID = id + "-second", thirdID = id + "-third"
        defer {
            _ = CatchUpTemplate.observeRenderTasksForTesting(root: root, observer: nil)
            for taskID in [firstID, secondID, thirdID] { _ = AgentArtifactLedger.takeRecords(taskID: taskID) }
        }
        let transform = CatchUpTemplate.resultTransform(renderer: renderer, attach: { linked.append($0) })
        let text = "The calendar has one appointment."
        let first = await transform(catchUp(), text, firstID, mondayMorning)
        check("first text withheld or changed", first.text == text && first.artifacts.isEmpty)
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !entered, ContinuousClock.now < firstDeadline { await Task.yield() }
        check("first actual caller did not enter held synthesis", entered && created.count == 1)
        guard entered, created.count == 1 else {
            for task in created { task.cancel() }
            release?.resume(); release = nil
            for task in created { await task.value }
            return failures
        }
        let second = await transform(catchUp(), text, secondID, mondayMorning)
        check("second text waited on audio or changed", second.text == text && second.artifacts.isEmpty && created.count == 2)
        guard created.count == 2 else {
            for task in created { task.cancel() }
            release?.resume(); release = nil
            for task in created { await task.value }
            return failures
        }
        // Join the SAME second default-spawn caller. A bounded yield observes its return
        // while first synthesis is still held; cleanup below releases and joins every caller.
        var secondReturned = false
        let secondJoin = Task { @MainActor in await created[1].value; secondReturned = true }
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !secondReturned, ContinuousClock.now < secondDeadline { await Task.yield() }
        check("second render queued behind held first render", secondReturned)
        check("second render entered synthesis during held first", synthesisCalls == 1)
        check("second render published audio or a link", linked.isEmpty
            && AgentArtifactLedger.peekRecords(taskID: secondID).isEmpty && directoryContents(directory).isEmpty)
        check("refused second render cancelled first caller", !created[0].isCancelled)
        release?.resume(); release = nil
        for task in created { await task.value }
        await secondJoin.value
        let file = directory.appendingPathComponent("Your Monday catch-up 2026-10-05.wav")
        check("released first render did not publish its exact file/link", linked.filter { $0 == firstID }.count == 1
            && AgentArtifactLedger.peek(taskID: firstID) == [file.absoluteString]
            && FileManager.default.fileExists(atPath: file.path))
        let beforeThird = synthesisCalls
        let third = await transform(catchUp(), text, thirdID, mondayMorning)
        check("third text withheld or changed", third.text == text && third.artifacts.isEmpty && created.count == 3)
        for task in created { await task.value }
        check("completed first render did not release admission for third", synthesisCalls == beforeThird + 1
            && linked.filter { $0 == thirdID }.count == 1
            && AgentArtifactLedger.peek(taskID: thirdID) == [file.absoluteString])
        check("file rendering started the live PCM graph", AgentPCMRenderer.shared.isRunning == false)
        return failures
    }

    private static func renderTerminationFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ value: Bool) { if !value { failures.append("render retirement: " + name) } }
        var created: [Task<Void, Never>] = []
        guard CatchUpTemplate.observeRenderTasksForTesting(root: root, observer: { created.append($0) }) else {
            return ["render retirement: actual caller observation was refused"]
        }
        var entered = false
        var returned = false
        var synthesisCalls = 0
        var release: CheckedContinuation<Void, Never>?
        var linked: [String] = []
        let directory = root.appendingPathComponent("render-retirement", isDirectory: true)
        let renderer = LongFormRenderer(directory: directory, container: .wav, synthesis: { _ in
            synthesisCalls += 1
            guard synthesisCalls == 1, !Task.isCancelled else {
                return LongFormRenderer.Audio(samples: [0.1, 0.1], sampleRate: 24_000)
            }
            entered = true
            // Represent already-entered synthesis that ignores caller cancellation until
            // its own backing returns. No fake completion, second owner or extra product hold.
            await withCheckedContinuation { release = $0 }
            returned = true
            return LongFormRenderer.Audio(samples: [0.1, 0.1], sampleRate: 24_000)
        }, environment: FakeYieldEnvironment())
        let id = "catch-up-retirement-" + UUID().uuidString
        let transform = CatchUpTemplate.resultTransform(renderer: renderer, attach: { linked.append($0) })
        let text = "The calendar has one appointment."
        let delivered = await transform(catchUp(), text, id, mondayMorning)
        check("actual transform withheld the text", delivered.text == text && delivered.artifacts.isEmpty)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        check("actual render never entered synthesis", entered && created.count == 1)
        let owned = CatchUpTemplate.beginTermination()
        check("quit did not retain and cancel the SAME caller", owned.count == 1
            && created.count == 1 && owned.first == created.first && owned.first?.isCancelled == true)
        var joined = false
        let join = Task { @MainActor in
            for task in owned { await task.value }
            joined = true
        }
        await Task.yield()
        check("quit returned before entered backing returned", !joined && !returned)
        let before = created.count
        _ = await transform(catchUp(), text, id + "-late", mondayMorning)
        check("quit admitted another render caller", created.count == before)
        // Fixture cleanup retains even ORIGINAL's discarded handle. Actual consumer join
        // remains a separate assertion; cleanup cannot turn its missing owner into a pass.
        for task in created { task.cancel() }
        release?.resume(); release = nil
        for task in created { await task.value }
        await join.value
        check("entered synthesis did not return/join", (!entered || returned) && joined)
        check("cancelled render published audio or its task link", linked.isEmpty
            && AgentArtifactLedger.peekRecords(taskID: id).isEmpty && directoryContents(directory).isEmpty)
        check("render observation did not retire", CatchUpTemplate.observeRenderTasksForTesting(root: root, observer: nil))
        _ = AgentArtifactLedger.takeRecords(taskID: id)
        _ = AgentArtifactLedger.takeRecords(taskID: id + "-late")
        return failures
    }

    // MARK: - Fixtures for the audio

    /// Records every synthesis request and returns quiet sine frames at a known rate.
    @MainActor
    final class SynthesisSpy {
        struct Call: Equatable {
            var text: String
            var speaker: String?
        }

        private(set) var calls: [Call] = []
        let samplesPerClause: Int
        let sampleRate: Double
        let failOnCall: Int?
        let failure: Error?

        init(samplesPerClause: Int, sampleRate: Double, failOnCall: Int? = nil, failure: Error? = nil) {
            self.samplesPerClause = samplesPerClause
            self.sampleRate = sampleRate
            self.failOnCall = failOnCall
            self.failure = failure
        }

        var closure: LongFormRenderer.Synthesis {
            { [self] request in
                calls.append(Call(text: request.text, speaker: request.speaker))
                if let failure { throw failure }
                if let failOnCall, calls.count == failOnCall { throw LongFormRenderError.writeFailed("simulated write failure") }
                let samples = (0..<samplesPerClause).map { Float(sin(2 * .pi * 220 * Double($0) / sampleRate)) * 0.1 }
                return LongFormRenderer.Audio(samples: samples, sampleRate: sampleRate)
            }
        }
    }

    /// A machine that is recording until told otherwise.
    @MainActor
    final class FakeYieldEnvironment: LongFormRenderingEnvironment {
        private let recording: Bool
        /// Live speech starts once `speakAfterCalls` clauses were synthesized and lasts `speakingReads` checks.
        private var speakingReads: Int
        private let speakAfterCalls: Int
        private let spy: SynthesisSpy?
        private(set) var callsWhileSpeaking: [Int] = []

        init(recording: Bool = false, speakingReads: Int = 0, speakAfterCalls: Int = 0, spy: SynthesisSpy? = nil) {
            self.recording = recording
            self.speakingReads = speakingReads
            self.speakAfterCalls = speakAfterCalls
            self.spy = spy
        }

        var isAgentSpeaking: Bool {
            guard speakingReads > 0, (spy?.calls.count ?? 0) >= speakAfterCalls else { return false }
            speakingReads -= 1
            callsWhileSpeaking.append(spy?.calls.count ?? -1)
            return true
        }

        var isRecording: Bool { recording }
        func isASRLaneBusy() async -> Bool { false }
        func isNotesLaneBusy() async -> Bool { false }
        func awaitCleanupIdle() async {}
    }

    /// Mirrors `LiveScheduledRunRecorder`: the task is registered, finished, and its artifacts
    /// folded from the ledger — the production pair the Library depends on.
    private final class TaskRecorder: ScheduledRunRecording {
        func begin(_ task: AgentTask) -> Bool { AgentTaskManager.shared.beginScheduledRun(task) }

        func finish(taskID: String, status: AgentTaskStatus, result: String?, failure: String?) {
            AgentTaskManager.shared.finishScheduledRun(id: taskID, status: status, result: result, failure: failure)
            AgentTaskManager.shared.foldArtifacts(taskID: taskID)
        }

        func audit(kind: AgentAuditEntry.Kind, title: String, detail: String, toolID: String?,
                   taskID: String?, scheduleID: UUID) {}
    }
}
