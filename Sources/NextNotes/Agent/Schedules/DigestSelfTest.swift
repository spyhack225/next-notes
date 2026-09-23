import Foundation

/// `--selftest-digest`: the P2-3 morning digest (Option A, no web).
///
/// - The template: exactly the three read tools, no web/news/feed surface,
///   weekday-06:00 default with no end date, consumer words on every
///   user-visible string, and the runner's own silence token.
/// - The fixture: a scripted run of the real `ScheduledRunner` over fixture
///   calendar + knowledge + mail. The scripted model makes the three digest
///   calls, then answers with the assembled digest; the test checks the reads
///   ran under `.scheduled` authority, nothing waited on `PermissionGate`,
///   and the reported text carries every anatomy section. A second run over
///   an empty fixture answers exactly `NOTHING_TO_REPORT` with nothing
///   delivered.
/// - Quiet hours, presence and delivery are the scheduler's and are not
///   re-tested here: the template asserts its defaults (`.notifyAndSpeak`,
///   `.auto`) so the existing path applies.
///
/// No model, network, microphone, notification center or account. The schedule
/// store lives in a temporary directory; the user's schedules are never read
/// or written.
@MainActor
enum DigestSelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-digest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: ScheduleStore.shared.directory)
        }
        if ScheduleStore.shared.directory.path.hasPrefix(AppIdentity.applicationSupportDirectory.path) {
            failures.append("isolation: the shared schedule store is the user's")
        }

        failures += templateFailures()
        failures += fixtureFailures()
        failures += await runFailures(root: root)

        for failure in failures { print("DIGEST_CHECK_FAILED: \(failure)") }
        print(failures.isEmpty ? "DIGEST_OK" : "DIGEST_FAILED")
        return failures.isEmpty
    }

    // MARK: - Fixtures

    static let zone = TimeZone(identifier: "America/New_York")!

    /// A full Tuesday morning: every anatomy section has something.
    static func fullFixture() -> DigestFixture {
        DigestFixture(
            edition: "2026-09-22", timeZone: zone.identifier, weather: nil,
            days: [
                .init(date: "Tue 22", events: [
                    .init(time: "09:00", title: "Design review", people: ["Kim"]),
                    .init(time: "09:30", title: "1:1 with Ana", people: ["Ana"]),
                    .init(time: "19:00", title: "Dinner", people: ["Ana"], place: "Carbone"),
                ], overlap: "Design review and 1:1 with Ana overlap from 09:30 to 10:00."),
                .init(date: "Wed 23", events: [.init(time: "10:00", title: "Dentist")]),
                .init(date: "Thu 24", events: []),
                .init(date: "Fri 25", events: [.init(time: "15:00", title: "Acme renewal call", people: ["Sam"])]),
                .init(date: "Sat 26", events: []),
                .init(date: "Sun 27", events: [.init(time: "08:00", title: "Flight to Lisbon")]),
                .init(date: "Mon 28", events: [.init(time: "09:00", title: "Sprint planning")]),
            ],
            desks: [
                .init(person: "Sam", lines: ["Acme renewal Friday — the contract draft is in your notes."]),
                .init(person: "Ana", lines: ["1:1 moved to 09:30 Tuesday."]),
            ],
            watch: [
                "Acme contract draft due Thursday 24 Sep.",
                "Dentist form to fill before Wednesday.",
            ],
            mail: [
                .init(from: "sam@acme.com", subject: "Re: renewal", date: "2026-09-21",
                      snippet: "Can we move Friday's call 30 minutes later?"),
                .init(from: "ana", subject: "1:1 notes", date: "2026-09-20",
                      snippet: "Moved our 1:1 to 9:30."),
            ],
            knowledge: [
                .init(title: "Acme renewal prep", date: "2026-09-18",
                      text: "Acme wants SSO before renewing 120 seats."),
                .init(title: "Lisbon flights", date: "2026-09-15",
                      text: "Outbound Sunday 08:00, return Friday."),
            ],
            aroundTown: ["Dinner at Carbone, Tuesday 19:00 — reservation for two."],
            questions: [
                "Should Friday's Acme call move 30 minutes later?",
                "What is the one thing the Design review must decide?",
                "Is the dentist form filled?",
            ])
    }

    /// Nothing anywhere: the silence case.
    static func emptyFixture() -> DigestFixture {
        DigestFixture(
            edition: "2026-09-22", timeZone: zone.identifier, weather: nil,
            days: (22...28).map { .init(date: "Sep \($0)", events: []) },
            desks: [], watch: [], mail: [], knowledge: [], aroundTown: [], questions: [])
    }

    static func digestSchedule(prompt: String, id: UUID = UUID()) -> AgentSchedule {
        AgentSchedule(
            id: id, kind: .routine, title: DigestTemplate.title,
            plainEnglish: DigestTemplate.restatement(), prompt: prompt,
            when: ScheduleWhen(repeatRule: .weekdays, time: ScheduleLocalTime(hour: 6, minute: 0),
                               timeZone: zone.identifier),
            allowedTools: DigestTemplate.allowedTools, model: .auto,
            delivery: .notifyAndSpeak, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    nonisolated static func call(_ name: String, _ arguments: [String: String] = [:]) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: ["name": name, "arguments": arguments, "rationale": "digest step"],
            options: [.sortedKeys])
        return "<tool_call>\(String(data: data ?? Data(), encoding: .utf8) ?? "")</tool_call>"
    }

    // MARK: - Template

    private static func templateFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("template: \(name)") }
        }
        check("the ceiling is not exactly the three digest reads",
              DigestTemplate.allowedTools == ["get_agenda", "search_knowledge", "search_email"])
        let prompt = DigestTemplate.routinePrompt()
        for tool in DigestTemplate.allowedTools {
            check("the prompt does not name \(tool)", prompt.contains(tool))
        }
        check("the prompt reaches the web, news tools, or a feed",
              !(prompt.contains("news.") || prompt.contains("browser.") || prompt.contains("http")
                || prompt.lowercased().contains("web_search") || prompt.lowercased().contains("websearch")))
        check("the prompt lost its never-browse rule", prompt.contains("Never browse the web"))
        check("the prompt lost the silence token", prompt.contains(ScheduledRunner.silenceToken))
        check("the prompt lost the source-and-date rule", prompt.contains("source and date"))

        // Defaults: weekday 06:00 through the existing parse path, no end date,
        // notify-and-speak so quiet hours and presence apply, model auto.
        let arguments = DigestTemplate.createArguments()
        do {
            let when = try ScheduleToolExecutor.parseWhen(
                arguments, base: nil, now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: zone)
            check("the default is not weekdays at 06:00 in its zone",
                  when.repeatRule == .weekdays && when.time == ScheduleLocalTime(hour: 6, minute: 0)
                    && when.timeZone == zone.identifier)
            let ends = try ScheduleToolExecutor.parseEndsOn(arguments["endsOn"] ?? "", timeZone: zone)
            check("the default ends", ends == nil)
        } catch {
            failures.append("template: the create arguments do not parse: \(error.localizedDescription)")
        }
        check("delivery does not let quiet hours and presence apply",
              DigestTemplate.delivery == .notifyAndSpeak)
        check("the model choice is not auto", DigestTemplate.model == .auto)

        // Consumer words on every user-visible string: title and restatement.
        let visible = "\(DigestTemplate.title)\n\(DigestTemplate.restatement())".lowercased()
        for word in ["cron", "artifact", "tool id", "tool_id", "schema", "agenttask",
                     "transcriptbus", "to-do", "routine", "schedule", "trigger",
                     "permission", "hermes", "json"] {
            check("a user-visible string says \(word)", !visible.contains(word))
        }
        let restated = DigestTemplate.restatement().lowercased()
        check("the restatement does not name the sources in plain words",
              restated.contains("calendar") && restated.contains("notes") && restated.contains("mail"))

        // The city comes from the zone id, locally.
        check("city derivation wrong",
              DigestTemplate.city(forZoneID: "America/New_York") == "New York"
                && DigestTemplate.city(forZoneID: "UTC") == nil)

        // The Library envelope: title plus a path-or-URL slot, nothing else new.
        let result = DigestResult.make(edition: "2026-09-22", text: "Hello.")
        check("the result envelope lost its title or library key",
              result.title == "Morning digest · 2026-09-22"
                && result.libraryKey == "Morning digest · 2026-09-22"
                && result.artifactReference == nil)
        return failures
    }

    // MARK: - Fixture rendering

    private static func fixtureFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("fixture: \(name)") }
        }
        let digest = DigestAssembler.assemble(fullFixture())
        print("DIGEST_FIXTURE (\(digest.count) chars):\n\(digest)")
        for section in ["Morning digest", "Edition: Tuesday, 22 September 2026 · New York",
                        "Today", "The Week Ahead", "For Sam", "For Ana", "Watch these",
                        "Around Town", "From your mail and notes", "Talk at the Table"] {
            check("missing section \(section)", digest.contains(section))
        }
        check("the week grid is not seven day lines",
              fullFixture().days.allSatisfy { digest.contains("- \($0.date):") })
        check("the overlap callout is missing", digest.contains("Overlap:"))
        check("mail items lack source and date",
              digest.contains("[mail · sam@acme.com · 2026-09-21]")
                && digest.contains("[mail · ana · 2026-09-20]"))
        check("knowledge items lack source and date",
              digest.contains("[notes · Acme renewal prep · 2026-09-18]")
                && digest.contains("[notes · Lisbon flights · 2026-09-15]"))
        check("talk questions are missing",
              digest.contains("Should Friday's Acme call move 30 minutes later?"))
        check("unknown weather was invented", !digest.contains("Weather:"))

        // Weather renders only when a tool returned it.
        var withWeather = fullFixture()
        withWeather.weather = "Sunny, 21°C."
        check("known weather did not render one line",
              DigestAssembler.assemble(withWeather).contains("Weather: Sunny, 21°C."))

        // Nothing new anywhere: exactly the silence token, nothing else.
        check("the empty morning was not silent",
              DigestAssembler.assemble(emptyFixture()) == ScheduledRunner.silenceToken)
        return failures
    }

    // MARK: - Scripted run over the fixture

    private static func runFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("run: \(name)") }
        }
        let store = ScheduleStore(directory: root.appendingPathComponent("digest", isDirectory: true))
        let environment = DigestEnvironment()
        let tools = DigestToolRunner()
        let recorder = DigestRecorder()
        let runner = ScheduledRunner(
            store: store, environment: environment, tools: tools, recorder: recorder,
            timeZone: { TimeZone(identifier: "America/New_York")! })
        let gateAsks = PermissionGate.shared.askCount
        let expected = DigestAssembler.assemble(fullFixture())

        let scheduleID = UUID()
        let schedule = digestSchedule(prompt: DigestTemplate.routinePrompt(), id: scheduleID)
        store.save(schedule)
        environment.model = ScriptedMemoryReviewModel { _, user in
            if user.contains("search_email returned") { return expected }
            if user.contains("search_knowledge returned") {
                return call("search_email", ["query": "newer_than:1d"])
            }
            if user.contains("get_agenda returned") {
                return call("search_knowledge", ["query": "open commitments and deadlines"])
            }
            return call("get_agenda", ["date": "2026-09-22"])
        }
        let outcome = await runner.run(schedule, now: Date(timeIntervalSince1970: 1_790_000_000))
        print("DIGEST_RUN -> \(outcome.status.rawValue) (\(outcome.calls) calls)")
        check("the digest run did not report its text",
              outcome.status == .reported && outcome.text == expected)
        check("the reads did not run in order under scheduled authority",
              tools.reads.map(\.0) == ["get_agenda", "search_knowledge", "search_email"]
                && tools.reads.allSatisfy { $0.1 == .scheduled(scheduleID) })
        check("the run waited on PermissionGate", PermissionGate.shared.askCount == gateAsks)
        check("the task is not a fresh scheduled task with the schedule id",
              recorder.begun.count == 1 && recorder.begun.first?.source == AgentTask.scheduledSource
                && recorder.begun.first?.scheduleID == scheduleID
                && recorder.finished.first?.1 == .completed)
        check("an audit entry lacks the schedule id",
              !recorder.audits.isEmpty && recorder.audits.allSatisfy { $0 == scheduleID })
        let system = environment.systems.first ?? ""
        check("the runner hid the digest tools or offered schedule tools",
              system.contains(ScheduledRunner.silenceToken)
                && DigestTemplate.allowedTools.allSatisfy { system.contains($0) }
                && !system.contains("schedule.create"))

        // The empty morning through the same path: silent, nothing delivered.
        environment.model = ScriptedMemoryReviewModel { _, _ in ScheduledRunner.silenceToken }
        let silent = await runner.run(schedule, now: Date(timeIntervalSince1970: 1_790_000_000))
        check("NOTHING_TO_REPORT was not silent",
              silent.status == .nothingToReport && silent.text.isEmpty)
        return failures
    }

    // MARK: - Recorders

    private final class SystemCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var systems: [String] = []
        func add(_ system: String) {
            lock.withLock { systems.append(system) }
        }
        func snapshot() -> [String] {
            lock.withLock { systems }
        }
    }

    /// Forwards to the scripted model while recording the system prompt. A struct, not a
    /// `ScriptedMemoryReviewModel`: its closure is synchronous, and the forward has to
    /// await the inner model.
    private struct CapturingModel: MemoryReviewModel {
        let inner: any MemoryReviewModel
        let capture: SystemCapture

        var label: String { inner.label }

        func complete(system: String, user: String) async throws -> String {
            capture.add(system)
            return try await inner.complete(system: system, user: user)
        }
    }

    private final class DigestEnvironment: ScheduledRunEnvironment {
        var model: any MemoryReviewModel = ScriptedMemoryReviewModel { _, _ in "NOTHING_TO_REPORT" }
        let capture = SystemCapture()
        var systems: [String] {
            capture.snapshot()
        }

        var isRecording: Bool { false }
        func localModelState() async -> MemoryReviewLocalState { .idle(seconds: 120) }
        func isCloudConfigured() async -> Bool { true }
        func model(for route: RoutineModelRoute) async -> (any MemoryReviewModel)? {
            if case .skip = route { return nil }
            return CapturingModel(inner: model, capture: capture)
        }
    }

    private final class DigestToolRunner: ScheduledToolRunning {
        var reads: [(String, ActionAuthority)] = []

        func read(_ tool: AgentTool, arguments: [String: String], authority: ActionAuthority,
                  taskID: String) async throws -> AgentToolResult {
            reads.append((tool.id, authority))
            switch tool.id {
            case "get_agenda":
                return AgentToolResult(summary: "Tue 22: Design review 09:00, 1:1 with Ana 09:30, "
                    + "Dinner at Carbone 19:00; Wed 23: Dentist 10:00; Fri 25: Acme renewal call 15:00; "
                    + "Sun 27: Flight to Lisbon 08:00; Mon 28: Sprint planning 09:00.")
            case "search_knowledge":
                return AgentToolResult(summary: "Acme renewal prep (2026-09-18); "
                    + "Lisbon flights (2026-09-15).")
            case "search_email":
                return AgentToolResult(summary: "sam@acme.com Re: renewal (2026-09-21); "
                    + "ana 1:1 notes (2026-09-20).")
            default:
                throw ScheduleError.invalid("\(tool.id) is not a digest tool.")
            }
        }
    }

    private final class DigestRecorder: ScheduledRunRecording {
        var begun: [AgentTask] = []
        var finished: [(String, AgentTaskStatus)] = []
        var audits: [UUID] = []

        func begin(_ task: AgentTask) { begun.append(task) }

        func finish(taskID: String, status: AgentTaskStatus, result: String?, failure: String?) {
            finished.append((taskID, status))
        }

        func audit(kind: AgentAuditEntry.Kind, title: String, detail: String, toolID: String?,
                   taskID: String?, scheduleID: UUID) {
            audits.append(scheduleID)
        }
    }
}
