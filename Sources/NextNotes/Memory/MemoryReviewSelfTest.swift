import Foundation

/// `--selftest-memory-review [--model scripted|local|cloud] [--fixtures <path>]`
///
/// Scores the review on the labelled sessions in `Tests/Fixtures/memory-review.json` —
/// precision and recall against expected saves and non-saves — and checks the rules around
/// it: the model router, never running while recording, only memory tools, only user and
/// assistant turns, one island notice, the session-end and 10-turn triggers, and routine
/// suggestions that are offered once and never created.
///
/// The default model is scripted, so it needs no model, network, microphone or permission.
/// `--model local` or `--model cloud` is the evaluation hook for a real model: the same
/// labels, the scripted answers ignored. Every store lives in a temporary directory.
@MainActor
enum MemoryReviewSelfTest {
    static let precisionBar = 0.9

    static func run() async -> Bool {
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-memory-review-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let shared = NextMemory.shared.fileURL?.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: shared)
            }
            try? FileManager.default.removeItem(at: MemoryReviewStateStore.shared.directory)
        }
        check(&failures, "the shared review state is not isolated",
              !MemoryReviewStateStore.shared.directory.path.hasPrefix(AppIdentity.applicationSupportDirectory.path))

        let modelName = SelfTest.value(after: "--model") ?? "scripted"
        failures += await fixtureFailures(root: root.appendingPathComponent("fixtures"), modelName: modelName)
        if modelName == "scripted" {
            failures += routerFailures()
            failures += await schedulerFailures(root: root.appendingPathComponent("scheduler"))
            failures += await boundaryFailures(root: root.appendingPathComponent("boundary"))
            failures += suggestionFailures(root: root.appendingPathComponent("suggestions"))
            failures += await productionWriterFailures()
        }

        for failure in failures { print("MEMORY_REVIEW_WRONG: \(failure)") }
        print(failures.isEmpty ? "MEMORY_REVIEW_OK" : "MEMORY_REVIEW_FAILED")
        return failures.isEmpty
    }

    private static func check(_ failures: inout [String], _ name: String, _ condition: Bool) {
        if !condition { failures.append(name) }
    }

    // MARK: - Fixtures

    struct FixtureFile: Decodable {
        let version: Int
        let cases: [FixtureCase]
    }

    struct FixtureCase: Decodable {
        struct Memory: Decodable {
            let kind: String
            let text: String
        }
        struct Turn: Decodable {
            let role: String
            let text: String
            let source: String?
            let contextKind: String?
        }
        struct ExpectedSave: Decodable {
            let kind: String
            let contains: [String]
        }
        struct Expectation: Decodable {
            let saves: [ExpectedSave]
            let absent: [String]
        }
        let id: String
        let label: String
        let memory: [Memory]?
        let turns: [Turn]
        let scripted: String
        let expect: Expectation
    }

    /// `--fixtures <path>`, else the repository's copy next to this source file, else the
    /// working directory's.
    static func fixtureURL() -> URL? {
        if let path = SelfTest.value(after: "--fixtures") { return URL(fileURLWithPath: path) }
        let relative = "Tests/Fixtures/memory-review.json"
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for base in [repository, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            let url = base.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Messages a fixture session is replayed as, one minute apart.
    static func messages(_ turns: [FixtureCase.Turn], sessionID: UUID, start: Date) -> [AgentSession.Message] {
        turns.enumerated().map { index, turn in
            AgentSession.Message(role: turn.role, text: turn.text, contextKind: turn.contextKind,
                                 at: start.addingTimeInterval(Double(index) * 60), source: turn.source ?? "text",
                                 sessionID: sessionID)
        }
    }

    private static func fixtureFailures(root: URL, modelName: String) async -> [String] {
        var failures: [String] = []
        guard let url = fixtureURL(), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FixtureFile.self, from: data) else {
            return ["the fixture file could not be read (pass --fixtures <path>)"]
        }
        let realModel: (any MemoryReviewModel)?
        switch modelName {
        case "scripted":
            realModel = nil
        case "local", "cloud":
            let id: LLMProviderID = modelName == "local" ? .qwen35_4b : .openRouter
            let provider = LLMProviders.make(id, modelID: Settings.shared.openRouterAgentModelID,
                                             contextTokens: Settings.shared.openRouterAgentContextTokens)
            if let reason = await provider.unavailableReason {
                return ["the \(modelName) model is unavailable: \(reason)"]
            }
            realModel = ProviderMemoryReviewModel(provider: provider)
        default:
            return ["unknown --model \(modelName); use scripted, local or cloud"]
        }
        print("MEMORY_REVIEW_FIXTURES \(url.path) cases=\(file.cases.count) model=\(modelName)")

        var correctWrites = 0
        var totalWrites = 0
        var expectedOutcomes = 0
        var metOutcomes = 0
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, fixture) in file.cases.enumerated() {
            let store = NextMemory(directory: root.appendingPathComponent(fixture.id),
                                   now: { start.addingTimeInterval(Double(index) * 3_600) })
            for seed in fixture.memory ?? [] {
                guard let kind = MemoryEntry.Kind(rawValue: seed.kind) else { continue }
                _ = try? store.remember(kind: kind, text: seed.text, source: .manual)
            }
            let seeded = store.entries
            let sessionID = UUID()
            let request = AgentSession.ReviewRequest(
                sessionID: sessionID, reason: .idle,
                messages: messages(fixture.turns, sessionID: sessionID, start: start.addingTimeInterval(Double(index) * 3_600)))
            guard let job = MemoryReviewJob(request, reviewedThrough: nil) else {
                failures.append("\(fixture.id): no reviewable turns")
                continue
            }
            let model = realModel ?? ScriptedMemoryReviewModel { _, _ in fixture.scripted }
            let outcome: MemoryReviewOutcome
            do {
                outcome = try await MemoryReviewer.review(job, model: model, writer: StoreMemoryReviewWriter(store: store))
            } catch {
                failures.append("\(fixture.id): the model failed: \(error.localizedDescription)")
                continue
            }

            // Every write is judged: a save must match an expected save; a removal must be of
            // something expected absent.
            var matched = Set<Int>()
            var wrong: [String] = []
            for entry in outcome.saved {
                let text = entry.text.lowercased()
                if let hit = fixture.expect.saves.indices.first(where: { index in
                    let expected = fixture.expect.saves[index]
                    return !matched.contains(index) && expected.kind == entry.kind.rawValue
                        && expected.contains.allSatisfy { text.contains($0.lowercased()) }
                }) {
                    matched.insert(hit)
                    correctWrites += 1
                } else {
                    wrong.append("saved \"\(entry.text)\"")
                }
                totalWrites += 1
            }
            let removed = seeded.filter { old in !store.entries.contains { $0.id == old.id } }
            for entry in removed where !outcome.saved.contains(where: { $0.supersedes == entry.id }) {
                totalWrites += 1
                if fixture.expect.absent.contains(where: { entry.text.localizedCaseInsensitiveContains($0) }) {
                    correctWrites += 1
                } else {
                    wrong.append("forgot \"\(entry.text)\"")
                }
            }
            let absentMet = fixture.expect.absent.filter { phrase in
                !store.entries.contains { $0.text.localizedCaseInsensitiveContains(phrase) }
            }.count
            expectedOutcomes += fixture.expect.saves.count + fixture.expect.absent.count
            metOutcomes += matched.count + absentMet

            let skipped = outcome.skipped.map { "\($0.reason)" }
            let refused = outcome.refused.map { "\($0.call.prefix(40)) → \($0.reason.prefix(70))" }
            print("MEMORY_REVIEW_CASE \(fixture.id) proposed=\(outcome.proposed) saved=\(outcome.saved.count) "
                  + "expected=\(fixture.expect.saves.count) wrong=\(wrong.count)"
                  + (wrong.isEmpty ? "" : " \(wrong)")
                  + (skipped.isEmpty ? "" : " skipped=\(skipped)")
                  + (refused.isEmpty ? "" : " refused=\(refused)"))
            if fixture.id == "non-memory-tools", realModel == nil {
                check(&failures, "a non-memory call was not refused by the allowlist",
                      outcome.refused.filter { $0.reason.contains("only use memory tools") }.count == 2)
            }
            if fixture.id.hasPrefix("inject-forget"), realModel == nil {
                check(&failures, "\(fixture.id): text the user did not write forgot a memory",
                      store.entries.count == seeded.count)
            }
            if fixture.id == "small-talk", realModel == nil {
                check(&failures, "NONE produced a write", outcome.proposed == 0 && outcome.saved.isEmpty)
            }
        }

        let precision = totalWrites == 0 ? 1 : Double(correctWrites) / Double(totalWrites)
        let recall = expectedOutcomes == 0 ? 1 : Double(metOutcomes) / Double(expectedOutcomes)
        print(String(format: "MEMORY_REVIEW_PRECISION %.3f (%d/%d writes) RECALL %.3f (%d/%d) model=%@ bar=%.2f",
                     precision, correctWrites, totalWrites, recall, metOutcomes, expectedOutcomes,
                     modelName, precisionBar))
        if precision < precisionBar {
            failures.append(String(format: "precision %.3f is below %.2f", precision, precisionBar))
        }
        if totalWrites == 0 { failures.append("the review wrote nothing on the fixture set") }
        return failures
    }

    // MARK: - Router

    private static func routerFailures() -> [String] {
        var failures: [String] = []
        let idle = MemoryReviewLocalState.idle(seconds: 120)
        let fresh = MemoryReviewLocalState.idle(seconds: 20)
        let states: [MemoryReviewLocalState] = [.unavailable, .notLoaded, .busy, fresh, idle]
        for choice in MemoryReviewModelChoice.allCases {
            for local in states {
                for cloud in [false, true] {
                    let route = MemoryReviewRouter.route(choice: choice, isRecording: true, local: local, cloudConfigured: cloud)
                    if case .wait = route {} else {
                        failures.append("router: \(choice.rawValue) ran while recording (\(local), cloud \(cloud))")
                    }
                }
            }
        }
        func expect(_ name: String, _ route: MemoryReviewRoute, _ wanted: MemoryReviewRoute?) {
            if let wanted {
                if route != wanted { failures.append("router: \(name) gave \(route)") }
            } else if case .wait = route {} else {
                failures.append("router: \(name) did not wait (\(route))")
            }
        }
        expect("auto, Qwen idle a minute", .init(choice: .auto, local: idle, cloud: true), .local)
        expect("auto, Qwen busy, cloud set up", .init(choice: .auto, local: .busy, cloud: true), .cloud)
        expect("auto, Qwen idle 20 s, cloud set up", .init(choice: .auto, local: fresh, cloud: true), .cloud)
        expect("auto, Qwen not loaded, cloud set up", .init(choice: .auto, local: .notLoaded, cloud: true), .cloud)
        expect("auto, Qwen busy, no cloud", .init(choice: .auto, local: .busy, cloud: false), nil)
        expect("auto, nothing", .init(choice: .auto, local: .unavailable, cloud: false), nil)
        expect("local, idle", .init(choice: .local, local: idle, cloud: true), .local)
        expect("local, not loaded", .init(choice: .local, local: .notLoaded, cloud: false), nil)
        expect("local, busy with cloud set up", .init(choice: .local, local: .busy, cloud: true), nil)
        expect("local, not downloaded", .init(choice: .local, local: .unavailable, cloud: true), nil)
        expect("cloud, set up", .init(choice: .cloud, local: idle, cloud: true), .cloud)
        expect("cloud, not set up", .init(choice: .cloud, local: idle, cloud: false), nil)
        return failures
    }

    // MARK: - Scheduler: never while recording, one notice, triggers

    final class FakeEnvironment: MemoryReviewEnvironment {
        var isRecording = false
        var isMemoryEnabled = true
        var local: MemoryReviewLocalState = .busy
        var cloud = false
        func localModelState() async -> MemoryReviewLocalState { local }
        func isCloudConfigured() async -> Bool { cloud }
    }

    final class FakeModels: MemoryReviewModelProviding {
        let model: ScriptedMemoryReviewModel
        var routes: [MemoryReviewRoute] = []
        init(_ model: ScriptedMemoryReviewModel) { self.model = model }
        func model(for route: MemoryReviewRoute) async -> (any MemoryReviewModel)? {
            routes.append(route)
            return model
        }
    }

    final class FakeNotifier: MemoryReviewNotifying {
        var notices: [[MemoryEntry]] = []
        func reviewSaved(_ entries: [MemoryEntry]) { notices.append(entries) }
    }

    /// Records every call that reaches the writer, so the allowlist is checked where it bites.
    final class SpyWriter: MemoryReviewWriter {
        let inner: MemoryReviewWriter
        var calls: [String] = []
        init(_ inner: MemoryReviewWriter) { self.inner = inner }
        var store: NextMemory { inner.store }
        func run(_ call: AgentToolCall, provenance: MemoryProvenance) async throws -> AgentToolResult {
            calls.append(call.name)
            guard provenance.origin == .memoryReview else { throw AgentError.permissionDenied("wrong provenance") }
            return try await inner.run(call, provenance: provenance)
        }
    }

    final class PromptCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        var value: String { lock.withLock { text } }
        func set(_ value: String) { lock.withLock { text = value } }
    }

    final class Clock {
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { current }
        func advance(minutes: Double) { current += minutes * 60 }
    }

    private static func schedulerFailures(root: URL) async -> [String] {
        var failures: [String] = []
        let clock = Clock()
        let memory = NextMemory(directory: root.appendingPathComponent("memory"), now: clock.now)
        let session = AgentSession(fileURL: root.appendingPathComponent(AgentSession.fileName), now: clock.now,
                                   idleMinutes: { 30 })
        let state = MemoryReviewStateStore(directory: root.appendingPathComponent("state"))
        let environment = FakeEnvironment()
        let scripted = ScriptedMemoryReviewModel { _, user in
            if user.contains("I prefer short answers") {
                return "<tool_call>{\"name\": \"memory.remember\", \"arguments\": {\"kind\": \"profile\", "
                    + "\"text\": \"The user prefers short answers.\"}}</tool_call>"
                    + "<tool_call>{\"name\": \"filesystem.write\", \"arguments\": {\"path\": \"/tmp/x\", \"text\": \"x\"}}</tool_call>"
            }
            return "NONE"
        }
        let models = FakeModels(scripted)
        let notifier = FakeNotifier()
        let writer = SpyWriter(StoreMemoryReviewWriter(store: memory))
        var choice = MemoryReviewModelChoice.auto
        let scheduler = MemoryReviewScheduler(
            state: state, session: session, environment: environment, models: models, writer: writer,
            notifier: notifier, choice: { choice }, now: clock.now, runsOnEnqueue: false)
        scheduler.connect()

        // A session ends after 30 minutes of silence and is queued, not reviewed on the spot.
        session.recordUser("I prefer short answers.", source: .text)
        session.recordAssistant("Okay.")
        let first = session.sessionID
        clock.advance(minutes: 29)
        check(&failures, "a session ended before the idle window", !session.endSessionIfIdle() && scheduler.pending.isEmpty)
        clock.advance(minutes: 2)
        check(&failures, "an idle session was not handed to the review",
              session.endSessionIfIdle() && scheduler.pending.count == 1
                && scheduler.pending.first?.reason == .idle && scheduler.pending.first?.sessionID == first
                && session.sessionID != first)

        // Never while recording, whatever the model choice.
        environment.isRecording = true
        environment.local = .idle(seconds: 600)
        environment.cloud = true
        for option in MemoryReviewModelChoice.allCases {
            choice = option
            let pass = await scheduler.runOnce()
            check(&failures, "the review ran while recording (\(option.rawValue): \(pass))", {
                if case .waiting = pass { return true } else { return false }
            }())
        }
        check(&failures, "the model was called while recording", scripted.callCount == 0 && models.routes.isEmpty)
        check(&failures, "a waiting review was dropped", scheduler.pending.count == 1)

        // Auto waits for a busy Qwen with no cloud, then runs when Qwen has been idle a minute.
        environment.isRecording = false
        environment.local = .busy
        environment.cloud = false
        choice = .auto
        if case .waiting = await scheduler.runOnce() {} else { failures.append("auto did not wait for a busy Qwen") }
        check(&failures, "the model was called while it had to wait", scripted.callCount == 0)
        environment.local = .idle(seconds: 90)
        let pass = await scheduler.runOnce()
        check(&failures, "the idle review did not save one entry (\(pass))", pass == .reviewed(saved: 1))
        check(&failures, "the review did not use the local route", models.routes == [.local])
        check(&failures, "a non-memory call reached the writer", writer.calls == ["memory.remember"])
        let saved = memory.entries.first { $0.text == "The user prefers short answers." }
        check(&failures, "the review save is not Learned with a New badge",
              saved?.source == .review && saved.map(memory.isNew) == true && saved?.sessionID == first)
        check(&failures, "the review did not post exactly one island notice", notifier.notices.count == 1
              && notifier.notices.first?.count == 1)
        let notice = MemoryReviewNotice.text(for: notifier.notices.first ?? [])
        print("MEMORY_REVIEW_NOTICE \(notice)")
        check(&failures, "the notice does not name the fact", notice.contains("you prefer short answers"))
        check(&failures, "the watermark did not move", state.reviewedThrough != nil && scheduler.pending.isEmpty)

        // Every 10 user turns inside a session.
        for index in 1...9 {
            session.recordUser("Question number \(index) about the roadmap.", source: .text)
            session.recordAssistant("Answer \(index).")
        }
        check(&failures, "the review was queued before 10 user turns", scheduler.pending.isEmpty)
        session.recordUser("Question number 10 about the roadmap.", source: .voice)
        check(&failures, "10 user turns did not queue a review",
              scheduler.pending.count == 1 && scheduler.pending.first?.reason == .turnInterval
                && scheduler.pending.first?.turns.filter { $0.role == "user" }.count == 10)
        // A meeting line does not count as a turn, and a later capture replaces the earlier one.
        session.recordUser("A line from the meeting.", source: .meeting)
        session.clear()
        check(&failures, "Clear conversation did not replace the queued review with the whole session",
              scheduler.pending.count == 1 && scheduler.pending.first?.reason == .cleared
                && scheduler.pending.first?.turns.contains { $0.text.contains("A line from the meeting") } == false)
        let beforeNotices = notifier.notices.count
        if case .reviewed(let count) = await scheduler.runOnce() {
            check(&failures, "a session with nothing to remember saved something", count == 0)
        } else {
            failures.append("the cleared session was not reviewed")
        }
        check(&failures, "a review that saved nothing posted a notice", notifier.notices.count == beforeNotices)
        check(&failures, "a reviewed session is queued again after the watermark",
              MemoryReviewJob(AgentSession.ReviewRequest(sessionID: UUID(), reason: .launch, messages: [
                  AgentSession.Message(role: "user", text: "Old words.", at: clock.now().addingTimeInterval(-3_600))
              ]), reviewedThrough: state.reviewedThrough) == nil)

        // Memory off: nothing runs and nothing piles up.
        clock.advance(minutes: 1)
        session.recordUser("I like tea.", source: .text)
        clock.advance(minutes: 31)
        session.endSessionIfIdle()
        check(&failures, "an idle session with new words was not queued", scheduler.pending.count == 1)
        environment.isMemoryEnabled = false
        let calls = scripted.callCount
        check(&failures, "the review ran with memory off",
              await scheduler.runOnce() == .disabled && scheduler.pending.isEmpty && scripted.callCount == calls)

        // Words said while memory is off are passed over for good: a session that ends while
        // it is off is not queued, and a relaunch with memory back on does not find it.
        clock.advance(minutes: 1)
        session.recordUser("I am vegetarian.", source: .text)
        clock.advance(minutes: 31)
        session.endSessionIfIdle()
        check(&failures, "a session that ended with memory off was queued", scheduler.pending.isEmpty)
        check(&failures, "memory off did not move the watermark past its words",
              state.reviewedThrough.map { $0 >= clock.now() } == true && state.memoryOff)
        environment.isMemoryEnabled = true
        let relaunchedSession = AgentSession(fileURL: root.appendingPathComponent(AgentSession.fileName),
                                             now: clock.now, idleMinutes: { 30 })
        let relaunchedState = MemoryReviewStateStore(directory: state.directory)
        let relaunched = MemoryReviewScheduler(
            state: relaunchedState, session: relaunchedSession, environment: environment, models: models,
            writer: writer, notifier: notifier, choice: { choice }, now: clock.now, runsOnEnqueue: false)
        relaunched.connect()
        relaunched.catchUp()
        check(&failures, "a relaunch with memory back on queued words said while it was off",
              relaunched.pending.isEmpty && !relaunchedState.memoryOff
                && relaunchedSession.endedSessions().contains { $0.messages.contains { $0.text == "I am vegetarian." } })

        // Off and on again inside one session: only what was said after it came back is read.
        clock.advance(minutes: 1)
        relaunchedSession.recordUser("I have two cats.", source: .text)
        environment.isMemoryEnabled = false
        relaunched.syncMemorySetting()
        clock.advance(minutes: 1)
        relaunchedSession.recordUser("I have a secret hobby.", source: .text)
        clock.advance(minutes: 1)
        environment.isMemoryEnabled = true
        relaunched.syncMemorySetting()
        clock.advance(minutes: 1)
        relaunchedSession.recordUser("I play the cello.", source: .text)
        clock.advance(minutes: 31)
        relaunchedSession.endSessionIfIdle()
        let texts = relaunched.pending.first?.turns.map(\.text) ?? []
        check(&failures, "a session reviewed words said while memory was off (\(texts))",
              relaunched.pending.count == 1 && texts == ["I play the cello."])

        // A recording that starts during the model call cancels the review: the job stays
        // pending, the attempt is not counted, and nothing is written.
        let slow = ScriptedMemoryReviewModel(delay: .seconds(5)) { _, _ in
            "<tool_call>{\"name\": \"memory.remember\", \"arguments\": {\"kind\": \"profile\", "
                + "\"text\": \"The user plays the cello.\"}}</tool_call>"
        }
        let interrupted = MemoryReviewScheduler(
            state: relaunchedState, session: relaunchedSession, environment: environment, models: FakeModels(slow),
            writer: writer, notifier: notifier, choice: { .auto }, now: clock.now, runsOnEnqueue: false,
            recordingPollInterval: .milliseconds(20))
        if let request = relaunched.pending.first?.request { interrupted.enqueue(request) }
        environment.local = .idle(seconds: 600)
        environment.isRecording = false
        let began = Date()
        let running = Task { @MainActor in await interrupted.runOnce() }
        try? await Task.sleep(for: .milliseconds(150))
        environment.isRecording = true
        let stopped = await running.value
        let elapsed = Date().timeIntervalSince(began)
        environment.isRecording = false
        check(&failures, "a recording did not stop a running review (\(stopped), \(elapsed) s)", {
            if case .waiting = stopped { return elapsed < 3 } else { return false }
        }())
        check(&failures, "a review stopped by a recording lost its job or counted an attempt",
              slow.callCount == 1 && interrupted.pending.count == 1 && interrupted.pending.first?.attempts == 0)
        check(&failures, "a review stopped by a recording wrote to memory",
              !memory.entries.contains { $0.text.contains("cello") })
        return failures
    }

    // MARK: - What the review sees

    private static func boundaryFailures(root: URL) async -> [String] {
        var failures: [String] = []
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            AgentSession.Message(role: "user", text: "I prefer tea to coffee.", at: start, source: "voice", sessionID: sessionID),
            AgentSession.Message(role: "assistant", text: "SECRET-MAIL the invoice portal is acme.example", contextKind: "mail",
                                 at: start + 60, sessionID: sessionID),
            AgentSession.Message(role: "tool", text: "SECRET-TOOL row", at: start + 61, sessionID: sessionID),
            AgentSession.Message(role: "user", text: "SECRET-MEETING we should cut the budget", at: start + 62,
                                 source: "meeting", sessionID: sessionID),
            AgentSession.Message(role: "assistant", text: "Tea it is.", at: start + 120, sessionID: sessionID),
        ]
        guard let job = MemoryReviewJob(AgentSession.ReviewRequest(sessionID: sessionID, reason: .idle, messages: rows),
                                        reviewedThrough: nil) else {
            return ["boundary: the job was empty"]
        }
        check(&failures, "the review sees tool, meeting or tool-backed rows",
              job.turns.map(\.role) == ["user", "assistant"] && !job.turns.contains { $0.text.contains("SECRET") })
        // What the model is actually sent, captured by the scripted model.
        let captured = PromptCapture()
        let model = ScriptedMemoryReviewModel { system, user in
            captured.set(system + "\n" + user)
            return "NONE"
        }
        let memory = NextMemory(directory: root.appendingPathComponent("memory"))
        _ = try? await MemoryReviewer.review(job, model: model, writer: StoreMemoryReviewWriter(store: memory))
        check(&failures, "the review was not sent the user's words", captured.value.contains("I prefer tea to coffee."))
        check(&failures, "the review prompt carries tool or meeting text", !captured.value.contains("SECRET"))
        check(&failures, "the review prompt does not offer only memory tools",
              MemoryReviewer.system.contains("the only tools that exist here")
                && !MemoryReviewer.system.contains("schedule.") && !MemoryReviewer.system.contains("mail."))
        check(&failures, "the review prompt lacks a skip rule", ["one-off", "did not state about themselves",
                                                                 "environment failures", "already in current memory"]
            .allSatisfy { MemoryReviewer.system.contains($0) })
        // A session with nothing the user said is not sent to a model at all.
        let quiet = AgentSession.ReviewRequest(sessionID: sessionID, reason: .idle, messages: [rows[1], rows[2], rows[4]])
        check(&failures, "a session without user turns became a job", MemoryReviewJob(quiet, reviewedThrough: nil) == nil)
        return failures
    }

    // MARK: - Routine suggestions

    private static func suggestionFailures(root: URL) -> [String] {
        var failures: [String] = []

        // The watermark survives a relaunch exactly: a sub-second row is not reviewed twice.
        let precise = MemoryReviewStateStore(directory: root.appendingPathComponent("precision"))
        let preciseSession = UUID()
        let preciseRequest = AgentSession.ReviewRequest(sessionID: preciseSession, reason: .turnInterval, messages: [
            AgentSession.Message(role: "user", text: "I prefer tea to coffee.",
                                 at: Date(timeIntervalSince1970: 1_800_000_000.7), sessionID: preciseSession),
        ])
        if let job = MemoryReviewJob(preciseRequest, reviewedThrough: precise.reviewedThrough) {
            precise.recordReview(job, now: Date(timeIntervalSince1970: 1_800_000_060))
            let reloaded = MemoryReviewStateStore(directory: precise.directory)
            check(&failures, "suggestions: a reloaded watermark lets a reviewed row be reviewed again",
                  reloaded.reviewedThrough == job.endAt
                    && MemoryReviewJob(preciseRequest, reviewedThrough: reloaded.reviewedThrough) == nil)
        } else {
            failures.append("suggestions: the precision row was not a job")
        }

        let state = MemoryReviewStateStore(directory: root)
        let schedulesBefore = ScheduleStore.shared.schedules.count
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let monday = calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 9, minute: 5))!
        let asks = ["What's on my calendar today?", "Hey, what's on my calendar?", "what’s on my calendar this morning"]
        var sessions: [UUID] = []
        for (day, text) in asks.enumerated() {
            let sessionID = UUID()
            sessions.append(sessionID)
            let at = calendar.date(byAdding: .day, value: day, to: monday)!.addingTimeInterval(Double(day) * 600)
            let rows = [
                AgentSession.Message(role: "user", text: text, at: at, source: "voice", sessionID: sessionID),
                AgentSession.Message(role: "user", text: "Remind me to call Sam at \(day + 2).", at: at + 30, sessionID: sessionID),
                AgentSession.Message(role: "assistant", text: "You have two meetings.", at: at + 60, sessionID: sessionID),
            ]
            guard let job = MemoryReviewJob(AgentSession.ReviewRequest(sessionID: sessionID, reason: .idle, messages: rows),
                                            reviewedThrough: state.reviewedThrough) else {
                failures.append("suggestions: day \(day + 1) was not a job")
                continue
            }
            let found = state.recordReview(job, now: at + 120, zone: calendar.timeZone)
            if day < 2 {
                check(&failures, "suggestions: a routine was suggested after \(day + 1) day(s)", found.isEmpty)
            } else {
                check(&failures, "suggestions: three mornings did not suggest one routine", found.count == 1)
            }
        }
        check(&failures, "suggestions: a reminder command became a suggestion",
              state.suggestions.count == 1 && RoutineSuggestionDetector.key(for: "Remind me to call Sam at 2") == nil)
        check(&failures, "suggestions: the same request said differently has different keys",
              Set(asks.compactMap(RoutineSuggestionDetector.key(for:))).count == 1)
        let offerInSameSession = state.takeOffer(for: sessions[2], now: monday + 3 * 86_400)
        check(&failures, "suggestions: offered in the session that found it", offerInSameSession == nil)
        let next = UUID()
        let offer = state.takeOffer(for: next, now: monday + 3 * 86_400)
        print("MEMORY_REVIEW_SUGGESTION \(offer ?? "none")")
        check(&failures, "suggestions: not offered in the next session",
              offer?.contains("what") == true && offer?.contains("3 different days") == true
                && offer?.contains("around 9:00") == true)
        check(&failures, "suggestions: offered twice", state.takeOffer(for: UUID(), now: monday + 4 * 86_400) == nil)
        check(&failures, "suggestions: a suggestion did not persist as offered",
              MemoryReviewStateStore(directory: root).suggestions.first?.offeredInSession == next)
        check(&failures, "suggestions: a routine was created", ScheduleStore.shared.schedules.count == schedulesBefore)

        // The session offers it once, after the first answer of a later session, as text.
        let clock = Clock()
        let session = AgentSession(fileURL: nil, now: clock.now, idleMinutes: { 30 })
        let offering = MemoryReviewStateStore(directory: root.appendingPathComponent("offer"))
        let found = UUID()
        offering.recordReviewForTesting(RoutineSuggestion(
            id: UUID(), request: "what's on my calendar", key: "calendar",
            occurrences: [clock.now(), clock.now() + 86_400, clock.now() + 172_800],
            detectedInSession: found, createdAt: clock.now()))
        session.routineOfferProvider = { offering.takeOffer(for: $0, now: clock.now()) }
        session.recordUser("Good morning.", source: .voice)
        session.recordAssistant("Good morning.")
        session.recordUser("And the weather?", source: .voice)
        session.recordAssistant("Sunny.")
        let offers = session.messages.filter { $0.contextKind == "routineSuggestion" }
        check(&failures, "suggestions: the session did not offer exactly once after the first answer",
              offers.count == 1 && session.messages.firstIndex { $0.contextKind == "routineSuggestion" } == 2)
        // The offer is not an answer: voice bookkeeping still sees the real last reply.
        let voiced = AgentSession(fileURL: nil, now: clock.now, idleMinutes: { 30 })
        voiced.routineOfferProvider = { _ in "Want a routine?" }
        voiced.recordAssistant("A background task finished.", contextKind: AgentSession.backgroundTaskContextKind)
        check(&failures, "suggestions: a background announcement triggered the offer",
              !voiced.messages.contains { $0.contextKind == "routineSuggestion" })
        voiced.recordUser("What's the weather?", source: .voice)
        let reply = voiced.recordAssistant("Sunny.", source: .voice)
        voiced.updateSpeech(messageID: reply, delivery: VoiceSpeechDelivery(completedText: "", status: "interrupted"))
        check(&failures, "suggestions: the offer hid the duplicate voice turn or the playback context",
              voiced.messages.last?.contextKind == "routineSuggestion"
                && voiced.isRecentDuplicateVoiceTurn("What's the weather?", now: clock.now())
                && voiced.latestVoiceDeliveryContext.contains("not fully played"))
        check(&failures, "suggestions: a routine was created by the offer",
              ScheduleStore.shared.schedules.count == schedulesBefore)
        return failures
    }

    // MARK: - The production writer

    /// The review's writes through `AgentToolExecutor`: `.memoryReview` authority, the
    /// auto-allow exception, receipts — and `NextMemory.shared`, which is temporary here.
    private static func productionWriterFailures() async -> [String] {
        var failures: [String] = []
        let shared = NextMemory.shared
        try? shared.forgetEverything()
        let sessionID = UUID()
        let start = Date()
        let rows = [
            AgentSession.Message(role: "user", text: "I cycle to the office on Fridays.", at: start, sessionID: sessionID),
            AgentSession.Message(role: "assistant", text: "Nice.", at: start + 1, sessionID: sessionID),
        ]
        guard let job = MemoryReviewJob(AgentSession.ReviewRequest(sessionID: sessionID, reason: .idle, messages: rows),
                                        reviewedThrough: nil) else { return ["production: no job"] }
        let model = ScriptedMemoryReviewModel { _, _ in
            "<tool_call>{\"name\": \"memory.remember\", \"arguments\": {\"kind\": \"profile\", \"text\": \"The user cycles to the office on Fridays.\"}}</tool_call>"
                + "<tool_call>{\"name\": \"shell.run\", \"arguments\": {\"command\": \"echo hi\"}}</tool_call>"
        }
        do {
            let outcome = try await MemoryReviewer.review(job, model: model, writer: ExecutorMemoryReviewWriter())
            check(&failures, "production: the review save did not go through the executor",
                  outcome.saved.count == 1 && shared.entries.first?.source == .review
                    && shared.entries.first?.sessionID == sessionID)
            check(&failures, "production: a shell call was not refused",
                  outcome.refused.contains { $0.call == "shell.run" })
            print("MEMORY_REVIEW_EXECUTOR saved=\(outcome.saved.map(\.text)) refused=\(outcome.refused.map(\.call))")
        } catch {
            failures.append("production: the review threw \(error.localizedDescription)")
        }
        try? shared.forgetEverything()
        return failures
    }
}

extension MemoryReviewRoute {
    /// Shorthand for the router table above.
    @MainActor
    init(choice: MemoryReviewModelChoice, local: MemoryReviewLocalState, cloud: Bool) {
        self = MemoryReviewRouter.route(choice: choice, isRecording: false, local: local, cloudConfigured: cloud)
    }
}
