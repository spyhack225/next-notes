import AVFoundation
import Foundation

/// `--selftest-podcast`: the long-form audio decision (roadmap §8.3, Option B).
///
/// Scripted and headless: no model, no microphone, no real synthesis, no notification
/// center. The voice is an injected spy at a known sample rate, so the duration math,
/// the chapters and the atomic write are measured rather than hoped for.
///
/// What it proves:
/// - The template: exactly the three read tools, weekday-06:00 defaults through the real
///   `ScheduleToolExecutor` parse paths, `.notifyAndSpeak` with no `speak` key, and
///   consumer words on every user-visible string.
/// - The script: headings become chapters, `Host A:` / `Host B:` labels become speakers
///   and never reach the spoken text, stage directions are dropped, and clause splitting
///   is `AgentSpeechPolicy`'s own.
/// - The renderer: a file appears at its deterministic name with the exact duration of
///   the frames it was given, chapters at section boundaries, a WAV the decoder reads
///   back, an m4a `AVURLAsset` can open, no staging leftovers, an existing edition
///   intact after a failed render, cancellation and a busy machine writing nothing.
/// - The run: script → file → announcement → `AgentTask.artifacts`, with silence
///   producing no file and no delivery, and the announcement — never the script and
///   never the file — being the only thing the live voice path could speak.
///
/// The live-graph guarantee is asserted through the injected seam plus
/// `AgentPCMRenderer.shared.isRunning == false` across every render.
/// `AgentSpeechSynthesizer.shared` is deliberately not constructed here: touching that
/// singleton can start a Pocket model prepare based on the user's settings, which is
/// exactly the kind of machine dependence a headless test must not have.
@MainActor
enum PodcastSelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-podcast-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        failures += templateFailures()
        failures += scriptFailures()
        failures += await rendererFailures(root: root)
        failures += await runFailures(root: root)

        for failure in failures { print("PODCAST_CHECK_FAILED: \(failure)") }
        print(failures.isEmpty ? "PODCAST_OK" : "PODCAST_FAILED")
        return failures.isEmpty
    }

    // MARK: - Fixtures

    static let zone = TimeZone(identifier: "America/New_York")!
    /// 2026-09-21 10:13 in New York; a Monday, so the edition stamp is `2026-09-21`.
    static let runDate = Date(timeIntervalSince1970: 1_790_000_000)
    static let edition = "2026-09-21"

    /// Seven clauses across three sections, with a stage direction and markdown emphasis
    /// to prove both are handled. Synthetic; no real person, place or project.
    ///
    /// No phrasing that `AgentSpeechPolicy.isTaskDone` would treat as a finished-task
    /// announcement ("moved ", "saved the", "created the"…): this script must be
    /// *unspeakable* by the live voice path, which is one of the assertions below.
    static let fixtureScript = """
        ## What happened
        Host A: Yesterday was busy. The Acme call shifts to Friday.
        Host B: Right — and the contract draft is still open.
        [theme music]
        ## Decisions
        Host A: *We decided* to keep the SSO work on the critical path.
        ## What's next
        Host A: Today starts with design review at nine.
        Host B: Then the dentist at ten.
        """

    static func podcastSchedule(id: UUID = UUID()) -> AgentSchedule {
        AgentSchedule(
            id: id, kind: .routine, title: PodcastTemplate.title,
            plainEnglish: PodcastTemplate.restatement(), prompt: PodcastTemplate.routinePrompt(),
            when: ScheduleWhen(repeatRule: .weekdays, time: ScheduleLocalTime(hour: 6, minute: 0),
                               timeZone: zone.identifier),
            allowedTools: PodcastTemplate.allowedTools, model: .auto,
            delivery: .notifyAndSpeak, createdAt: runDate)
    }

    static func renderer(
        directory: URL, container: LongFormRenderer.Container, spy: SynthesisSpy,
        environment: FakeYieldEnvironment = FakeYieldEnvironment()
    ) -> LongFormRenderer {
        LongFormRenderer(
            directory: directory, container: container, synthesis: spy.closure,
            environment: environment,
            limits: .init(maxDuration: 60, yieldTimeout: 1, yieldPoll: 0.05))
    }

    // MARK: - Template

    private static func templateFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("template: \(name)") }
        }
        check("the ceiling is not exactly the three reads",
              PodcastTemplate.allowedTools == ["get_agenda", "search_knowledge", "search_email"])
        let prompt = PodcastTemplate.routinePrompt()
        for tool in PodcastTemplate.allowedTools {
            check("the prompt does not name \(tool)", prompt.contains(tool))
        }
        check("the prompt lost the silence token", prompt.contains(ScheduledRunner.silenceToken))
        check("the prompt lost the two hosts",
              prompt.contains("Host A:") && prompt.contains("Host B:"))
        for heading in ["## What happened", "## Decisions", "## What's next"] {
            check("the prompt lost \(heading)", prompt.contains(heading))
        }
        check("the prompt lost the never-publish rule", prompt.contains("never published"))
        check("the prompt reaches the web", !prompt.contains("http") && !prompt.lowercased().contains("web_search"))

        // Defaults through the real parse paths: weekdays 06:00 in the schedule's zone,
        // no end date, auto model, notify-and-speak with no speak override.
        let arguments = PodcastTemplate.createArguments()
        do {
            let when = try ScheduleToolExecutor.parseWhen(
                arguments, base: nil, now: runDate, timeZone: zone)
            check("the default is not weekdays at 06:00 in its zone",
                  when.repeatRule == .weekdays && when.time == ScheduleLocalTime(hour: 6, minute: 0)
                    && when.timeZone == zone.identifier)
            let ends = try ScheduleToolExecutor.parseEndsOn(arguments["endsOn"] ?? "", timeZone: zone)
            check("the default ends", ends == nil)
        } catch {
            failures.append("template: the create arguments do not parse: \(error.localizedDescription)")
        }
        check("the model choice is not auto", arguments["model"] == "auto")
        check("a speak override was written", arguments["speak"] == nil)
        check("delivery does not let quiet hours and presence apply",
              PodcastTemplate.delivery == .notifyAndSpeak)
        check("model is not auto", PodcastTemplate.model == .auto)

        // The confirmed ceiling resolves through the real fixer: all three reads, none refused.
        let ceiling = RoutineToolCeiling.fix(
            requested: PodcastTemplate.allowedTools, available: Set(PodcastTemplate.allowedTools))
        check("the reads do not pass the routine ceiling",
              ceiling.allowed == PodcastTemplate.allowedTools && ceiling.refused.isEmpty)

        // Consumer words on every user-visible string.
        let visible = [
            PodcastTemplate.title,
            PodcastTemplate.restatement(),
            PodcastTemplate.announce(duration: 252),
            PodcastTemplate.failureText(for: LongFormRenderError.diskFull),
            PodcastTemplate.failureText(for: LongFormRenderError.voiceUnavailable),
        ].joined(separator: "\n").lowercased()
        for word in ["cron", "artifact", "tool id", "tool_id", "schema", "agenttask",
                     "transcriptbus", "routine", "schedule", "trigger", "permission",
                     "hermes", "json", "notifyandspeak"] {
            check("a user-visible string says \(word)", !visible.contains(word))
        }
        let restated = PodcastTemplate.restatement().lowercased()
        check("the restatement does not name its sources in plain words",
              restated.contains("calendar") && restated.contains("notes") && restated.contains("mail"))
        check("the restatement does not say the audio stays here",
              restated.contains("library") && restated.contains("your mac") && restated.contains("never published"))

        // The Library envelope.
        let rendered = LongFormRenderer.RenderedFile(
            url: URL(fileURLWithPath: "/tmp/Your morning podcast 2026-09-21.m4a"),
            duration: 252, chapters: [], container: .m4a, byteCount: 1)
        let result = PodcastResult(rendered: rendered, edition: edition)
        check("the Library key is wrong", result.libraryKey == "Your morning podcast · 2026-09-21")
        check("the announcement is wrong", result.text == "Ready — 4 minutes 12 seconds, saved in your Library.")
        check("durations read wrong",
              PodcastTemplate.spokenDuration(48) == "48 seconds"
                && PodcastTemplate.spokenDuration(252) == "4 minutes 12 seconds"
                && PodcastTemplate.spokenDuration(300) == "5 minutes"
                && PodcastTemplate.spokenDuration(61) == "1 minute 1 second")
        return failures
    }

    // MARK: - Script parsing

    private static func scriptFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("script: \(name)") }
        }
        let script = LongFormScript.parse(fixtureScript)
        check("three sections", script.sections.map(\.title) == ["What happened", "Decisions", "What's next"])
        check("clause count is seven", script.clauseCount == 7)
        check("first clause", script.sections.first?.clauses.first?.text == "Yesterday was busy.")
        check("emphasis is read aloud",
              script.sections[1].clauses.first?.text == "We decided to keep the SSO work on the critical path.")
        let clauses = script.sections.flatMap(\.clauses)
        check("stage directions were read", clauses.allSatisfy { !$0.text.lowercased().contains("theme music") })
        check("headings were read", clauses.allSatisfy { !$0.text.contains("#") })
        check("speaker labels were read", clauses.allSatisfy { !$0.text.contains("Host ") && !$0.text.contains("*") })
        check("speakers were lost",
              script.sections[0].clauses.map(\.speaker) == [
                  LongFormScript.hostA, LongFormScript.hostA,
                  LongFormScript.hostB, LongFormScript.hostB,
              ])
        check("an empty script is not empty", LongFormScript.parse("").isEmpty)
        check("clauses do not reuse the policy splitter",
              LongFormScript.parse("## X\nHost A: One. Two.").clauseCount == 2)
        return failures
    }

    // MARK: - Renderer

    private static func rendererFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("renderer: \(name)") }
        }
        let script = LongFormScript.parse(fixtureScript)
        check("the live PCM graph was running before rendering",
              AgentPCMRenderer.shared.isRunning == false)

        // WAV at a known rate: 1000 samples per clause at 1 kHz is exactly one second each.
        let wavDirectory = root.appendingPathComponent("wav", isDirectory: true)
        let wavSpy = SynthesisSpy(samplesPerClause: 1_000, sampleRate: 1_000)
        let wavRenderer = renderer(directory: wavDirectory, container: .wav, spy: wavSpy)
        var progress: [Double] = []
        wavRenderer.onProgress = { progress.append($0) }
        do {
            let rendered = try await wavRenderer.render(
                script, title: PodcastTemplate.title, edition: edition)
            check("the file name is not deterministic",
                  rendered.url.lastPathComponent == "Your morning podcast \(edition).wav")
            check("wav duration math", abs(rendered.duration - 7.0) < 1e-9)
            check("wav byte count", rendered.byteCount == 44 + 7 * 1_000 * 2)
            check("chapters do not map to headings",
                  rendered.chapters.map(\.title) == ["What happened", "Decisions", "What's next"])
            check("chapter starts are wrong", rendered.chapters.map(\.start) == [0, 4, 5])
            check("every clause did not go through the synthesis seam", wavSpy.calls.count == 7)
            check("speakers are wrong in the seam",
                  wavSpy.calls.map(\.speaker) == [
                      LongFormScript.hostA, LongFormScript.hostA,
                      LongFormScript.hostB, LongFormScript.hostB,
                      LongFormScript.hostA, LongFormScript.hostA,
                      LongFormScript.hostB,
                  ])
            check("progress did not finish at 1", progress.count == 7 && progress.last == 1.0)
            check("the live graph was touched",
                  AgentPCMRenderer.shared.isRunning == false)

            // The decoder round-trips the writer.
            let data = try Data(contentsOf: rendered.url)
            let decoded = try LongFormSynthesisFactory.decodeWAV(data)
            check("wav decode lost samples", decoded.samples.count == 7_000)
            check("wav decode rate", decoded.sampleRate == 1_000)
        } catch {
            failures.append("renderer: wav render threw \(error)")
        }

        // m4a at the engines' own rate, 0.2 s per clause.
        let m4aDirectory = root.appendingPathComponent("m4a", isDirectory: true)
        let m4aSpy = SynthesisSpy(samplesPerClause: 4_800, sampleRate: 24_000)
        let m4aRenderer = renderer(directory: m4aDirectory, container: .m4a, spy: m4aSpy)
        do {
            let rendered = try await m4aRenderer.render(
                script, title: PodcastTemplate.title, edition: edition)
            check("m4a container lost", rendered.container == .m4a)
            check("m4a duration math", abs(rendered.duration - 1.4) < 1e-9)
            check("m4a chapter starts are wrong", rendered.chapters.map(\.start) == [0, 0.8, 1.0])
            let asset = AVURLAsset(url: rendered.url)
            let duration = try await asset.load(.duration).seconds
            check("m4a is not readable by AVFoundation", abs(duration - 1.4) < 0.5)
            check("m4a byte count missing", rendered.byteCount > 0)
            check("the live graph was touched by m4a",
                  AgentPCMRenderer.shared.isRunning == false)
        } catch {
            failures.append("renderer: m4a render threw \(error)")
        }

        // Atomicity: an existing edition survives a failed render untouched.
        let atomicDirectory = root.appendingPathComponent("atomic", isDirectory: true)
        try? FileManager.default.createDirectory(at: atomicDirectory, withIntermediateDirectories: true)
        let destination = atomicDirectory.appendingPathComponent("Your morning podcast \(edition).wav")
        try? Data("OLD".utf8).write(to: destination)
        let failingSpy = SynthesisSpy(samplesPerClause: 1_000, sampleRate: 1_000, failOnCall: 3)
        let failingRenderer = renderer(directory: atomicDirectory, container: .wav, spy: failingSpy)
        do {
            _ = try await failingRenderer.render(script, title: PodcastTemplate.title, edition: edition)
            failures.append("renderer: a render that should have failed returned a file")
        } catch {
            check("a failed render truncated the previous edition",
                  (try? Data(contentsOf: destination)) == Data("OLD".utf8))
            check("a failed render left staging files",
                  directoryContents(atomicDirectory) == ["Your morning podcast \(edition).wav"])
        }
        let replaceSpy = SynthesisSpy(samplesPerClause: 1_000, sampleRate: 1_000)
        let replaceRenderer = renderer(directory: atomicDirectory, container: .wav, spy: replaceSpy)
        do {
            let replaced = try await replaceRenderer.render(
                script, title: PodcastTemplate.title, edition: edition)
            let head = (try? Data(contentsOf: replaced.url))?.prefix(4)
            check("a successful render did not replace the edition", head == Data("RIFF".utf8))
            check("a successful render left staging files",
                  directoryContents(atomicDirectory) == ["Your morning podcast \(edition).wav"])
        } catch {
            failures.append("renderer: replacement render threw \(error)")
        }

        // Cancellation: nothing is left behind.
        let cancelDirectory = root.appendingPathComponent("cancel", isDirectory: true)
        let cancelSpy = SynthesisSpy(samplesPerClause: 1_000, sampleRate: 1_000, delay: .milliseconds(30))
        let cancelRenderer = renderer(directory: cancelDirectory, container: .wav, spy: cancelSpy)
        let cancelTask = Task { try await cancelRenderer.render(
            script, title: PodcastTemplate.title, edition: edition) }
        try? await Task.sleep(for: .milliseconds(80))
        cancelTask.cancel()
        switch await cancelTask.result {
        case .success:
            failures.append("renderer: a cancelled render returned a file")
        case .failure(let error):
            check("cancellation did not surface as CancellationError", error is CancellationError)
            check("a cancelled render wrote a file", directoryContents(cancelDirectory).isEmpty)
        }
        check("the cancelled render never reached the voice", !cancelSpy.calls.isEmpty)

        // Empty script.
        do {
            _ = try await wavRenderer.render(LongFormScript.parse(""), title: "Empty", edition: edition)
            failures.append("renderer: an empty script rendered a file")
        } catch let error as LongFormRenderError {
            check("empty script error is wrong", error == .emptyScript)
        } catch {
            failures.append("renderer: empty script threw \(error)")
        }

        // Yielding: a busy machine waits, then proceeds; a machine that never clears fails.
        let clearedEnvironment = FakeYieldEnvironment(recording: true, clearAfterReads: 2)
        let clearedSpy = SynthesisSpy(samplesPerClause: 1_000, sampleRate: 1_000)
        let clearedRenderer = renderer(
            directory: root.appendingPathComponent("cleared", isDirectory: true),
            container: .wav, spy: clearedSpy, environment: clearedEnvironment)
        do {
            _ = try await clearedRenderer.render(script, title: PodcastTemplate.title, edition: edition)
            check("rendering did not wait for cleanup", clearedEnvironment.cleanupWaits > 0)
        } catch {
            failures.append("renderer: render did not wait out a recording: \(error)")
        }
        let busyEnvironment = FakeYieldEnvironment(recording: true)
        let busyRenderer = LongFormRenderer(
            directory: root.appendingPathComponent("busy", isDirectory: true),
            container: .wav, synthesis: SynthesisSpy(samplesPerClause: 1_000, sampleRate: 1_000).closure,
            environment: busyEnvironment,
            limits: .init(maxDuration: 60, yieldTimeout: 0.2, yieldPoll: 0.05))
        do {
            _ = try await busyRenderer.render(script, title: PodcastTemplate.title, edition: edition)
            failures.append("renderer: a render returned while the machine was recording")
        } catch let error as LongFormRenderError {
            if case .busy = error {} else { failures.append("renderer: busy error is \(error)") }
            check("a busy render wrote a file",
                  directoryContents(root.appendingPathComponent("busy", isDirectory: true)).isEmpty)
        } catch {
            failures.append("renderer: busy render threw \(error)")
        }

        // Disk-full classification: the two ways Foundation reports it.
        check("cocoa disk-full is not mapped",
              LongFormRenderer.classify(CocoaError(.fileWriteOutOfSpace)) as? LongFormRenderError == .diskFull)
        check("posix disk-full is not mapped",
              LongFormRenderer.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
                as? LongFormRenderError == .diskFull)
        check("a disk-full sentence does not say what happened",
              PodcastTemplate.failureText(for: LongFormRenderError.diskFull).contains("room"))

        check("the live PCM graph was running after rendering",
              AgentPCMRenderer.shared.isRunning == false)
        return failures
    }

    // MARK: - The scripted run

    private static func runFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("run: \(name)") }
        }
        let store = ScheduleStore(directory: root.appendingPathComponent("run-schedules", isDirectory: true))
        let library = root.appendingPathComponent("run-library", isDirectory: true)
        let spy = SynthesisSpy(samplesPerClause: 24_000, sampleRate: 24_000)
        let renderer = LongFormRenderer(
            directory: library, container: .m4a, synthesis: spy.closure,
            environment: FakeYieldEnvironment(),
            limits: .init(maxDuration: 60, yieldTimeout: 1, yieldPoll: 0.05))
        let environment = PodcastRunEnvironment()
        let tools = PodcastToolRunner()
        let recorder = PodcastRecorder()
        let runner = ScheduledRunner(
            store: store, environment: environment, tools: tools, recorder: recorder,
            timeZone: { zone },
            answerTransform: PodcastTemplate.resultTransform(renderer: renderer))

        let scheduleID = UUID()
        let schedule = podcastSchedule(id: scheduleID)
        store.save(schedule)
        // Hoisted: a `@Sendable` closure cannot read the main-actor-isolated constant.
        let script = fixtureScript
        environment.model = ScriptedMemoryReviewModel { _, _ in script }
        let outcome = await runner.run(schedule, now: runDate)
        let expectedFile = library.appendingPathComponent("Your morning podcast \(edition).m4a")
        print("PODCAST_RUN -> \(outcome.status.rawValue) (\(outcome.calls) calls) \(outcome.text)")
        check("the run did not report", outcome.status == .reported)
        check("the announcement is wrong", outcome.text == "Ready — 7 seconds, saved in your Library.")
        check("the run carried no artifact", outcome.artifacts == [expectedFile.absoluteString])
        check("the file does not exist", FileManager.default.fileExists(atPath: expectedFile.path))
        check("the artifact did not reach the task",
              AgentTaskManager.shared.task(id: outcome.taskID ?? "")?.artifacts == outcome.artifacts)
        check("the task is not a scheduled task for this schedule",
              recorder.begun.count == 1 && recorder.begun.first?.source == AgentTask.scheduledSource
                && recorder.begun.first?.scheduleID == scheduleID
                && recorder.finished.first?.1 == .completed)
        check("an audit entry lacks the schedule id",
              !recorder.audits.isEmpty && recorder.audits.allSatisfy { $0 == scheduleID })
        check("a tool ran in a podcast routine", tools.reads == 0)
        let system = environment.systems.first ?? ""
        check("the runner hid the tools or the silence rule",
              system.contains(ScheduledRunner.silenceToken)
                && PodcastTemplate.allowedTools.allSatisfy { system.contains($0) })
        check("the script reached the announcement text",
              !outcome.text.contains("Host ") && !outcome.text.contains("##"))
        check("the announcement is not speakable", !AgentSpeechPolicy.spokenForm(outcome.text).isEmpty)
        check("the live voice would have read the whole script", AgentSpeechPolicy.spokenForm(fixtureScript).isEmpty)
        check("the live graph was running across the run", AgentPCMRenderer.shared.isRunning == false)

        // A foreign schedule's answer passes through untouched.
        let foreign = AgentSchedule(
            id: UUID(), kind: .routine, title: "Morning digest",
            plainEnglish: "A digest.", prompt: "Make a digest.",
            when: ScheduleWhen(repeatRule: .weekdays, time: ScheduleLocalTime(hour: 6, minute: 0),
                               timeZone: zone.identifier),
            allowedTools: [], model: .auto, delivery: .notifyAndSpeak, createdAt: runDate)
        let passedThrough = await PodcastTemplate.resultTransform(renderer: renderer)(
            foreign, fixtureScript, "task", runDate)
        check("a foreign schedule was rewritten",
              passedThrough.text == fixtureScript && passedThrough.artifacts.isEmpty)

        // Silence: no model answer, no transform, no file, nothing delivered.
        let spyCountBeforeSilence = spy.calls.count
        environment.model = ScriptedMemoryReviewModel { _, _ in ScheduledRunner.silenceToken }
        let silent = await runner.run(schedule, now: runDate)
        check("NOTHING_TO_REPORT was not silent", silent.status == .nothingToReport && silent.text.isEmpty)
        check("silence rendered audio", spy.calls.count == spyCountBeforeSilence)
        check("silence left more than the one edition",
              directoryContents(library) == ["Your morning podcast \(edition).m4a"])
        check("silence recorded artifacts",
              AgentTaskManager.shared.task(id: silent.taskID ?? "")?.artifacts.isEmpty != false)
        check("the live graph was running after the run", AgentPCMRenderer.shared.isRunning == false)
        return failures
    }

    // MARK: - Fixtures

    private static func directoryContents(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// Records every synthesis request and returns quiet sine frames at a known rate.
    /// `@MainActor` because `Synthesis` is: a non-isolated `self` cannot be sent into it.
    @MainActor
    final class SynthesisSpy {
        struct Call: Equatable {
            var text: String
            var speaker: String?
        }

        private(set) var calls: [Call] = []
        let samplesPerClause: Int
        let sampleRate: Double
        let delay: Duration
        let failOnCall: Int?

        init(samplesPerClause: Int, sampleRate: Double, delay: Duration = .zero, failOnCall: Int? = nil) {
            self.samplesPerClause = samplesPerClause
            self.sampleRate = sampleRate
            self.delay = delay
            self.failOnCall = failOnCall
        }

        var closure: LongFormRenderer.Synthesis {
            { [self] request in
                calls.append(Call(text: request.text, speaker: request.speaker))
                if let failOnCall, calls.count == failOnCall {
                    throw LongFormRenderError.writeFailed("simulated write failure")
                }
                if delay > .zero { try await Task.sleep(for: delay) }
                let samples = (0..<samplesPerClause).map { index in
                    Float(sin(2 * .pi * 220 * Double(index) / sampleRate)) * 0.1
                }
                return LongFormRenderer.Audio(samples: samples, sampleRate: sampleRate)
            }
        }
    }

    /// A machine that is recording until told otherwise. `clearAfterReads` lets a test
    /// observe the wait end without a clock.
    final class FakeYieldEnvironment: LongFormRenderingEnvironment {
        private var recording: Bool
        private let clearAfterReads: Int?
        private var recordingReads = 0
        var asrBusy = false
        var notesBusy = false
        private(set) var cleanupWaits = 0

        init(recording: Bool = false, clearAfterReads: Int? = nil) {
            self.recording = recording
            self.clearAfterReads = clearAfterReads
        }

        var isRecording: Bool {
            recordingReads += 1
            if let clearAfterReads, recordingReads > clearAfterReads { return false }
            return recording
        }

        func isASRLaneBusy() async -> Bool { asrBusy }
        func isNotesLaneBusy() async -> Bool { notesBusy }
        func awaitCleanupIdle() async { cleanupWaits += 1 }
    }

    private final class SystemCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var systems: [String] = []
        func add(_ system: String) {
            lock.lock()
            defer { lock.unlock() }
            systems.append(system)
        }
        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return systems
        }
    }

    private struct CapturingModel: MemoryReviewModel {
        let inner: any MemoryReviewModel
        let capture: SystemCapture

        var label: String { inner.label }

        func complete(system: String, user: String) async throws -> String {
            capture.add(system)
            return try await inner.complete(system: system, user: user)
        }
    }

    private final class PodcastRunEnvironment: ScheduledRunEnvironment {
        var model: any MemoryReviewModel = ScriptedMemoryReviewModel { _, _ in ScheduledRunner.silenceToken }
        let capture = SystemCapture()
        var systems: [String] { capture.snapshot() }

        var isRecording: Bool { false }
        func localModelState() async -> MemoryReviewLocalState { .idle(seconds: 120) }
        func isCloudConfigured() async -> Bool { true }
        func model(for route: RoutineModelRoute) async -> (any MemoryReviewModel)? {
            if case .skip = route { return nil }
            return CapturingModel(inner: model, capture: capture)
        }
    }

    private final class PodcastToolRunner: ScheduledToolRunning {
        var reads = 0

        func read(_ tool: AgentTool, arguments: [String: String], authority: ActionAuthority,
                  taskID: String) async throws -> AgentToolResult {
            reads += 1
            throw ScheduleError.invalid("\(tool.id) is not a podcast tool.")
        }
    }

    /// Mirrors `LiveScheduledRunRecorder` exactly: the task is registered, finished, and
    /// its artifacts folded from the ledger — the production pair the Library depends on.
    private final class PodcastRecorder: ScheduledRunRecording {
        var begun: [AgentTask] = []
        var finished: [(String, AgentTaskStatus, String?)] = []
        var audits: [UUID] = []

        func begin(_ task: AgentTask) {
            begun.append(task)
            AgentTaskManager.shared.beginScheduledRun(task)
        }

        func finish(taskID: String, status: AgentTaskStatus, result: String?, failure: String?) {
            finished.append((taskID, status, result))
            AgentTaskManager.shared.finishScheduledRun(id: taskID, status: status, result: result, failure: failure)
            AgentTaskManager.shared.foldArtifacts(taskID: taskID)
        }

        func audit(kind: AgentAuditEntry.Kind, title: String, detail: String, toolID: String?,
                   taskID: String?, scheduleID: UUID) {
            audits.append(scheduleID)
        }
    }
}
