import AVFoundation
import AppKit
import FluidAudio
import SwiftUI

@main
struct SpeechifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window(AppDelegate.mainWindowTitle, id: AppDelegate.mainWindowID) {
            MainWindow(controller: delegate.controller)
        }
        .defaultSize(width: DS.Size.windowMin.width, height: DS.Size.windowMin.height)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                MeetingCommands()
                Divider()
            }
            CommandGroup(after: .appInfo) {
                Button("Reveal Dictionary File") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }

        // Fully qualified: this app has its own `Settings` type, which otherwise shadows
        // SwiftUI's settings scene.
        SwiftUI.Settings {
            SettingsWindow(controller: delegate.controller)
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.state.isActive ? "waveform.circle.fill" : "waveform")
        }

    }
}

/// Whether the process was launched to run one of the `--selftest-…` flags.
///
/// The scene graph is declarative, so the main window is still built during a self-test even
/// though `applicationDidFinishLaunching` returns early. Anything that would put a modal on
/// screen has to check this: a sheet keeps `NSApp.terminate` from ever completing, and the
/// test then prints its result and hangs forever instead of exiting.
enum SelfTest {
    /// The flag the process was launched with, if any.
    static let requested = CommandLine.arguments.dropFirst().first {
        $0.hasPrefix("--selftest")
    }

    static var isRunning: Bool { requested != nil }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    /// Meetings run from a singleton because the menu bar, the Meetings section and the
    /// scheduler all have to reach the same session. The delegate holds it so a running
    /// recording is closed out when the app quits.
    let meetings = MeetingController.shared
    private var hud: HUDPanel?
    /// The notch island. Created once and kept for the life of the process: it is a window
    /// that shows and hides itself, not one that is made and thrown away.
    private var island: IslandPanel?
    private var stateObservation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the self-test check: a notification the user actioned while Speechify was
        // closed is delivered the instant the app launches, and a delegate installed after
        // that never sees it.
        Notifications.shared.configure()

        if runRequestedSelfTest() { return }

        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        hud = HUDPanel(controller: controller)
        // Both exist whatever `hudPlacement` says. The island announces meetings and
        // finished notes either way — those are notifications, not a readout of a key being
        // held — and the setting only decides which of the two shows dictation.
        island = IslandPanel()
        IslandState.shared.start(dictation: controller)

        if !controller.activate() {
            Permissions.promptForAccessibility()
            // The tap can only be created once the user grants Accessibility, and there's
            // no notification for that — poll until it takes.
            retryActivation()
        }

        // Parakeet's models take ~20s to load from disk, and that cost lands on whichever
        // dictation touches them first — so the first hold after every launch would stall
        // with the HUD showing nothing. Warm them in the background instead, but only when
        // they're actually going to be used and are already downloaded.
        let willUseParakeet = Settings.shared.compareMode || Settings.shared.engine == .parakeet
        if willUseParakeet, ParakeetModels.isDownloaded {
            LocalModelStore.shared.prepareParakeet()
        }
        if Settings.shared.cleanupEnabled,
           Settings.shared.cleanupEngine == .s1Mini,
           S1MiniModels.isDownloaded {
            LocalModelStore.shared.prepareS1Mini()
        }

        // A meeting still marked as running was interrupted by a crash or a force-quit.
        // Say so, rather than leaving a row that claims to be recording forever. Runs
        // before the scheduler starts: it must not find a meeting that claims to be live.
        MeetingStore.shared.repairInterruptedMeetings()

        // Reading the calendar and acting on it are two jobs on purpose — the service only
        // ever answers "what is coming up", and the scheduler is the only thing that turns
        // an answer into a recording.
        CalendarService.shared.start()
        MeetingScheduler.shared.start()
        // After the scheduler, and for the same reason it comes after the store: the agent
        // registers a notification observer and the island's decision handler, and both of
        // those have to exist before a proposal from a previous session is delivered.
        AgentService.shared.start()
        Task { await Notifications.shared.requestAuthorization() }

        observeState()
        observeMeetingBadge()
        Log.app.info("Speechify ready — hold \(Settings.shared.pushToTalkKey.displayName) to dictate")
    }

    /// Model-only smoke tests that avoid microphone, Accessibility, and text injection.
    /// They make the two large local runtimes testable after installation and in support.
    private func runRequestedSelfTest() -> Bool {
        guard SelfTest.isRunning else { return false }
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--selftest-s1") {
            Task { @MainActor in
                do {
                    let output = try await S1MiniRuntime.shared.normalize(
                        "so um i need to send the report by friday no wait make that thursday",
                        preferences: CleanupPreferences(
                            tone: .semiFormal,
                            formatsLists: true,
                            context: .general
                        )
                    )
                    writeSelfTest("S1_MINI_OK: \(output)")
                } catch {
                    writeSelfTest("S1_MINI_FAILED: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-systemaudio") {
            runSystemAudioSelfTest()
            return true
        }
        if arguments.contains("--selftest-calendar") {
            runCalendarSelfTest()
            return true
        }
        if let path = Self.value(after: "--selftest-transcribe") {
            runTranscribeSelfTest(path: path)
            return true
        }
        if let path = Self.value(after: "--selftest-notes") {
            runNotesSelfTest(path: path, diarize: arguments.contains("--diarize"))
            return true
        }
        if arguments.contains("--selftest-llm-metal") {
            runMetalSelfTest()
            return true
        }
        if arguments.contains("--selftest-island") {
            runIslandSelfTest()
            return true
        }
        if arguments.contains("--selftest-orb") {
            runOrbSelfTest()
            return true
        }
        if arguments.contains("--selftest-gws") {
            runWorkspaceCLISelfTest()
            return true
        }
        if let path = Self.value(after: "--selftest-agent") {
            runAgentSelfTest(directory: path)
            return true
        }
        if arguments.contains("--selftest-cleanup") {
            runCleanupSelfTest(engine: Self.value(after: "--selftest-cleanup") ?? "all")
            return true
        }
        if arguments.contains("--selftest-dictation") {
            runDictationSelfTest()
            return true
        }
        if arguments.contains("--selftest-parakeet") {
            Task { @MainActor in
                do {
                    let manager = try await ParakeetModels.shared.manager()
                    var decoderState = try TdtDecoderState()
                    let result = try await manager.transcribe(
                        [Float](repeating: 0, count: 16_000),
                        decoderState: &decoderState
                    )
                    writeSelfTest("PARAKEET_OK: inference completed (\(result.text))")
                } catch {
                    writeSelfTest("PARAKEET_FAILED: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
            return true
        }

        // Reached only when a `--selftest-…` flag was given that no branch above claimed —
        // in practice one whose required argument was left off, since `value(after:)`
        // returns nil for a trailing flag. Falling through to `return false` would launch
        // the app instead, which looks exactly like a self-test that hangs forever: it took
        // ten minutes to diagnose once. Say so and exit non-zero.
        writeSelfTest("SELFTEST_FAILED: \(SelfTest.requested ?? "unknown") needs an argument, "
                      + "or is not a self-test this build knows.")
        NSApp.terminate(nil)
        return true
    }

    /// Runs `CleanupEvalCases` through one or more formatters and prints what each did,
    /// with the latency of every single pass.
    ///
    /// This is the only honest way to compare them. `runs.jsonl` records `processSeconds`
    /// from key release to injected text, which bundles transcription, cleanup and the
    /// dictionary together — a number in which a Parakeet batch decode can hide a cleanup
    /// pass entirely. This harness times the cleanup call and nothing else.
    ///
    /// `--selftest-cleanup rules|apple|apple-grammar|s1|qwen|all`. The first case a
    /// model-backed formatter sees pays its cold start and is reported separately, because
    /// on a machine where the model has idled out that is the latency a real dictation gets.
    private func runCleanupSelfTest(engine: String) {
        Task { @MainActor in
            let preferences = CleanupPreferences(
                tone: .balanced,
                formatsLists: true,
                context: .general
            )
            let requested: [String]
            switch engine {
            case "all": requested = ["guard", "rules", "apple", "apple-grammar", "s1", "qwen"]
            default: requested = [engine]
            }

            if requested.contains("guard") {
                var failures = 0
                writeSelfTest("=== guard ===")
                for vector in CleanupGuardVectors.all + CleanupGuardVectors.regressions {
                    let reason = CleanupGuard.rejection(
                        original: vector.original,
                        cleaned: vector.cleaned,
                        mode: vector.mode
                    )
                    let accepted = reason == nil
                    if accepted != vector.accepted {
                        failures += 1
                        writeSelfTest("""
                              GUARD_WRONG \(vector.name): expected \
                            \(vector.accepted ? "accept" : "reject"), got \
                            \(accepted ? "accept" : "reject: \(reason ?? "")")
                              in  : \(vector.original)
                              out : \(Self.oneLine(vector.cleaned))
                            """)
                    } else {
                        writeSelfTest("  \(vector.name)\t\(vector.accepted ? "accept" : "reject")\t"
                                      + (reason.map { "(\($0))" } ?? ""))
                    }
                }
                if failures > 0 {
                    writeSelfTest("CLEANUP_FAILED: \(failures) guard vector(s) wrong")
                    NSApp.terminate(nil)
                    return
                }
                writeSelfTest("  \(CleanupGuardVectors.all.count + CleanupGuardVectors.regressions.count) guard vectors correct")
            }

            for name in requested where name != "guard" {
                let formatter: (any TextFormatter)?
                let mode: CleanupGuard.Mode
                switch name {
                case "rules":
                    formatter = RuleBasedFormatter()
                    mode = .punctuationOnly
                case "apple":
                    formatter = FoundationModelFormatter(preferences: preferences, fixesGrammar: false)
                    mode = .punctuationOnly
                case "apple-grammar":
                    formatter = FoundationModelFormatter(preferences: preferences, fixesGrammar: true)
                    mode = .grammar
                case "s1":
                    formatter = S1MiniFormatter(preferences: preferences)
                    mode = .punctuationOnly
                case "qwen":
                    formatter = QwenCleanupFormatter(preferences: preferences, fixesGrammar: true)
                    mode = .grammar
                default:
                    formatter = nil
                    mode = .punctuationOnly
                }
                guard let formatter else {
                    writeSelfTest("CLEANUP_FAILED: unknown engine \(name)")
                    continue
                }

                writeSelfTest("")
                writeSelfTest("=== \(name) ===")
                var timings: [Double] = []
                var rejections = 0
                for testCase in CleanupEvalCases.all {
                    let began = Date()
                    let output = await formatter.format(testCase.input)
                    let seconds = Date().timeIntervalSince(began)
                    timings.append(seconds)

                    // The formatters fall back internally, so a rejected model answer looks
                    // from out here exactly like a model that decided to change nothing.
                    // Asking the model again *without* the guard is the only way to tell
                    // those two apart, and the difference is the whole argument for or
                    // against a prompt — so the harness pays for a second call that
                    // production never makes.
                    let raw = await Self.rawCleanup(
                        name,
                        testCase.input,
                        preferences: preferences
                    )
                    var verdict = "ok"
                    if let raw {
                        if let reason = CleanupGuard.rejection(
                            original: testCase.input,
                            cleaned: raw,
                            mode: mode
                        ) {
                            verdict = "REJECTED \(reason)"
                            rejections += 1
                        } else if raw != output {
                            verdict = "drifted"
                        }
                    }

                    writeSelfTest("""
                        \(testCase.id)\t\(String(format: "%.3f", seconds))s\t\(verdict)
                          want: \(testCase.expectation)
                          in  : \(testCase.input)
                          out : \(Self.oneLine(output))
                        """)
                    if let raw, raw != output {
                        writeSelfTest("  raw : \(Self.oneLine(raw))")
                    }
                }
                if rejections > 0 {
                    writeSelfTest("  \(rejections) of \(CleanupEvalCases.all.count) model answers "
                                  + "were rejected and replaced by rule-based output.")
                }

                let sorted = timings.sorted()
                let cold = timings.first ?? 0
                let warm = Array(timings.dropFirst()).sorted()
                let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                let warmMedian = warm.isEmpty ? 0 : warm[warm.count / 2]
                let warmMax = warm.max() ?? 0
                writeSelfTest("""
                    CLEANUP_SUMMARY \(name): n=\(timings.count) \
                    cold=\(String(format: "%.3f", cold))s \
                    median=\(String(format: "%.3f", median))s \
                    warm-median=\(String(format: "%.3f", warmMedian))s \
                    warm-max=\(String(format: "%.3f", warmMax))s
                    """)
            }
            writeSelfTest("CLEANUP_OK")
            NSApp.terminate(nil)
        }
    }

    /// The model's answer with no guard in front of it. nil for engines that have no
    /// separable model step. Harness only.
    private static func rawCleanup(
        _ engine: String,
        _ text: String,
        preferences: CleanupPreferences
    ) async -> String? {
        switch engine {
        case "apple":
            return try? await FoundationModelFormatter.clean(
                text, preferences: preferences, fixesGrammar: false
            )
        case "apple-grammar":
            return try? await FoundationModelFormatter.clean(
                text, preferences: preferences, fixesGrammar: true
            )
        case "qwen":
            return try? await QwenCleanupFormatter.generate(
                text, preferences: preferences, fixesGrammar: true
            )
        default:
            return nil
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " \u{21B5} ")
    }

    /// Listens to the Mac's own output for three seconds and reports what it heard.
    ///
    /// The first run of this is what triggers the system-audio TCC prompt, which is the
    /// point: it makes the grant answerable from a terminal instead of only by starting a
    /// real meeting. Play something before running it — silence is a valid, useless result.
    private func runSystemAudioSelfTest() {
        Task { @MainActor in
            let capture = SystemAudioCapture()
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: ChunkedTranscriber.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                writeSelfTest("SYSTEM_AUDIO_FAILED: no capture format")
                NSApp.terminate(nil)
                return
            }

            let meter = SelfTestMeter()
            do {
                try capture.start(
                    outputFormat: format,
                    onBuffer: { chunk in meter.add(AudioConversion.samples(of: chunk.buffer)) },
                    onLevel: { _ in }
                )
            } catch {
                writeSelfTest("SYSTEM_AUDIO_FAILED: \(error.localizedDescription)")
                NSApp.terminate(nil)
                return
            }

            let tapFormat = capture.currentTapFormat
            try? await Task.sleep(for: .seconds(3))
            capture.stop()

            let (frames, rms, peak) = meter.summary()
            let description = tapFormat.map {
                "\($0.sampleRate)Hz \($0.channelCount)ch"
            } ?? "unknown"
            let measurements = """
                tap \(description) → \(Int(format.sampleRate))Hz mono, \
                \(frames) frames, rms \(String(format: "%.5f", rms)), \
                peak \(String(format: "%.5f", peak))
                """
            // Digital silence is reported as its own result, never as success: a tap the
            // user hasn't granted behaves exactly like this — every call succeeds, the
            // IOProc runs, and every sample is zero.
            if peak == 0 {
                // Frames *and* silence separates the two causes this used to report as one.
                // A tap with no grant still runs: the aggregate device is built, the IOProc
                // fires on schedule, and every sample it hands over is zero. So frames
                // arriving with nothing in them is the permission signature; no frames at
                // all is a machine that genuinely wasn't playing anything.
                let cause = frames > 0
                    ? "frames arrived but every sample is zero, which is what a tap without "
                        + "the grant does — allow Speechify under Privacy & Security ▸ "
                        + "Screen & System Audio Recording"
                    : "no frames arrived at all, so nothing was playing"
                writeSelfTest("SYSTEM_AUDIO_SILENT: \(measurements) — \(cause).")
            } else {
                writeSelfTest("SYSTEM_AUDIO_OK: \(measurements)")
            }
            NSApp.terminate(nil)
        }
    }

    /// Reads every enabled calendar once and prints what the scheduler would do with it.
    ///
    /// Two halves, because they fail for different reasons: the providers half needs an
    /// account and a TCC grant, and the decision half needs neither — it runs the real
    /// `shouldAutoRecord` over invented events, so a change that quietly starts recording
    /// declined invitations or all-day blocks is caught without a calendar at all.
    /// Pair it with `--fake-calendar` to see the invented meeting come through the service.
    private func runCalendarSelfTest() {
        Task { @MainActor in
            let service = CalendarService.shared
            await service.refresh()

            for id in CalendarProviderID.allCases {
                let state = service.providerStates[id] ?? .needsAuthorization
                let detail = state.detail.map { " — \($0)" } ?? ""
                writeSelfTest("  \(id.rawValue): \(state.displayName)\(detail)")
            }
            for event in service.upcoming.prefix(20) {
                let record = MeetingScheduler.shared.willAutoRecord(event) ? "record" : "skip"
                writeSelfTest("""
                      \(event.start.formatted(date: .abbreviated, time: .shortened)) \
                    \(event.title) [\(event.providerID.rawValue)] \
                    \(event.attendees.count) attendee(s)\
                    \(event.conferenceURL == nil ? "" : " video") → \(record)
                    """)
            }

            let failures = Self.autoRecordDecisionFailures()
            for failure in failures { writeSelfTest("  DECISION_WRONG: \(failure)") }

            if failures.isEmpty {
                writeSelfTest("""
                    CALENDAR_OK: \(service.upcoming.count) upcoming event(s), \
                    decision rules behave
                    """)
            } else {
                writeSelfTest("CALENDAR_FAILED: \(failures.count) decision rule(s) wrong")
            }
            NSApp.terminate(nil)
        }
    }

    /// The auto-record rules, stated as cases. Returns the ones that came out wrong.
    private static func autoRecordDecisionFailures() -> [String] {
        func event(
            attendees: [String] = [],
            conference: Bool = false,
            allDay: Bool = false,
            accepted: Bool = true
        ) -> MeetingEvent {
            MeetingEvent(
                id: UUID().uuidString,
                providerID: .fake,
                title: "Case",
                start: Date(),
                end: Date().addingTimeInterval(1800),
                attendees: attendees,
                isOrganizerOrSelfAccepted: accepted,
                conferenceURL: conference ? URL(string: "https://meet.google.com/x") : nil,
                calendarName: "Test",
                isAllDay: allDay
            )
        }

        let cases: [(String, Bool, MeetingEvent, Bool, Bool?)] = [
            ("a call with a video link records", true, event(conference: true), true, nil),
            ("a meeting with another person records", true, event(attendees: ["Sam"]), true, nil),
            ("a solo block does not", false, event(), true, nil),
            ("an all-day block does not", false, event(attendees: ["Sam"], allDay: true), true, nil),
            ("a declined invitation does not", false, event(conference: true, accepted: false), true, nil),
            ("the global switch off stops it", false, event(conference: true), false, nil),
            ("an explicit yes beats the global switch", true, event(), false, true),
            ("an explicit no beats the heuristic", false, event(conference: true), true, false),
            ("an explicit yes never overrides all-day", false, event(allDay: true), true, true),
            ("an explicit yes never overrides a decline", false, event(accepted: false), true, true),
        ]

        return cases.compactMap { name, expected, event, global, override in
            let actual = MeetingScheduler.shouldAutoRecord(
                event,
                globallyEnabled: global,
                override: override
            )
            return actual == expected ? nil : name
        }
    }

    /// Runs a WAV file through the meeting transcriber and prints the segments as JSON.
    ///
    /// The audio is fed a second at a time rather than in one call, so the windowing and
    /// silence detection are exercised exactly as they are during a live meeting.
    private func runTranscribeSelfTest(path: String) {
        Task { @MainActor in
            do {
                let run = try await Self.transcribeFile(at: path)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(run.segments),
                   let json = String(data: data, encoding: .utf8) {
                    writeSelfTest(json)
                }
                writeSelfTest("""
                    TRANSCRIBE_OK: \(run.segments.count) segment(s), \
                    \(String(format: "%.1f", run.audioSeconds))s audio in \
                    \(String(format: "%.1f", run.elapsed))s \
                    (\(String(format: "%.1f", run.audioSeconds / max(run.elapsed, 0.0001)))x realtime)
                    """)
            } catch {
                writeSelfTest("TRANSCRIBE_FAILED: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    /// Transcribes a WAV the way a live meeting does — a second of audio at a time, through
    /// the same `ChunkedTranscriber` — so the windowing and silence detection are exercised
    /// rather than bypassed. Shared by `--selftest-transcribe` and `--selftest-notes`.
    private static func transcribeFile(
        at path: String
    ) async throws -> (segments: [TranscriptSegment], audioSeconds: Double, elapsed: TimeInterval) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let samples = try AudioConversion.monoSamples(
            fromFileAt: url,
            sampleRate: ChunkedTranscriber.sampleRate
        )
        let audioSeconds = Double(samples.count) / ChunkedTranscriber.sampleRate

        let collector = SelfTestSegments()
        let transcriber = ChunkedTranscriber(source: .system) { segment in
            await collector.add(segment)
        }

        let began = Date()
        let step = Int(ChunkedTranscriber.sampleRate)
        var index = 0
        while index < samples.count {
            let end = min(index + step, samples.count)
            await transcriber.append(Array(samples[index..<end]))
            index = end
        }
        await transcriber.flush()
        return (await collector.all(), audioSeconds, Date().timeIntervalSince(began))
    }

    /// Transcribes a WAV and writes notes from it, printing the markdown and what it cost.
    ///
    /// The end-to-end shape of the feature in one command: whatever a meeting would do
    /// between the last buffer and the Notes tab, minus the microphone. Peak resident memory
    /// is printed because the number that decides whether this is viable on a 16 GB Mac is
    /// Parakeet and the notes model both being resident, which only happens in this order.
    private func runNotesSelfTest(path: String, diarize: Bool) {
        Task { @MainActor in
            do {
                let run = try await Self.transcribeFile(at: path)
                guard !run.segments.isEmpty else {
                    writeSelfTest("NOTES_FAILED: nothing was transcribed from \(path)")
                    NSApp.terminate(nil)
                    return
                }

                // Before the provider check, not after: diarization is the thing `--diarize`
                // was run to see, and it should be answered even on a machine where the notes
                // model isn't downloaded.
                let segments = diarize
                    ? await Self.diarize(run.segments, fileAt: path, log: writeSelfTest)
                    : run.segments

                let preferred = Settings.shared.notesProvider
                guard let provider = await LLMProviders.resolve(preferring: preferred) else {
                    let reasons = await Self.providerReasons()
                    writeSelfTest("NOTES_FAILED: no provider available — \(reasons)")
                    NSApp.terminate(nil)
                    return
                }
                if provider.id != preferred {
                    let reason = await LLMProviders.make(preferred).unavailableReason ?? ""
                    writeSelfTest("  note: \(preferred.displayName) unavailable (\(reason))")
                }

                let meeting = Meeting(
                    title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    start: Date(),
                    status: .transcribing
                )
                let generator = NotesGenerator(provider: provider)
                let result = try await generator.notes(for: meeting, segments: segments) { step in
                    FileHandle.standardError.write(Data("  \(step.message)\n".utf8))
                }

                writeSelfTest(result.markdown)
                let missing = NotesPrompts.headings.filter { !result.markdown.contains("## \($0)") }
                let peak = Double(Self.peakResidentBytes()) / 1_048_576
                writeSelfTest("""
                    NOTES_OK: \(provider.id.rawValue)\(result.usedMapReduce ? " (map-reduce)" : ""), \
                    \(run.segments.count) segment(s) from \
                    \(String(format: "%.1f", run.audioSeconds))s audio, \
                    \(result.generatedTokens) tokens in \
                    \(String(format: "%.1f", result.duration))s \
                    (\(String(format: "%.1f", result.tokensPerSecond)) tok/s), \
                    peak RSS \(String(format: "%.0f", peak)) MB
                    """)
                if !missing.isEmpty {
                    writeSelfTest("NOTES_HEADINGS_MISSING: \(missing.joined(separator: ", "))")
                }
            } catch {
                writeSelfTest("NOTES_FAILED: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    /// Runs the diarizer over the same file and labels the segments with what it found.
    ///
    /// The whole file rather than one channel: this takes a plain recording, not a meeting's
    /// two-channel `audio.caf`, so there is no system track to isolate — every segment
    /// `transcribeFile` produced is already marked `.system`, which is what `assign` labels.
    ///
    /// - Returns: the labelled segments, or the originals when nothing could be identified.
    ///   A diarization that fails is reported and then stepped over: the point of the flag is
    ///   to see the labels, and losing the notes as well would answer one question with two
    ///   failures.
    private static func diarize(
        _ segments: [TranscriptSegment],
        fileAt path: String,
        log: (String) -> Void
    ) async -> [TranscriptSegment] {
        do {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let samples = try AudioConversion.monoSamples(
                fromFileAt: url,
                sampleRate: ChunkedTranscriber.sampleRate
            )
            let began = Date()
            let runs = try await MeetingDiarizer.shared.speakerRuns(in: samples)
            let labelled = MeetingDiarizer.assign(segments, to: runs)
            let speakers = MeetingDiarizer.labels(in: labelled)

            log(labelled.plainText())
            log("""
                DIARIZE_OK: \(speakers.count) speaker(s) over \(runs.count) run(s), \
                \(labelled.filter { $0.speaker != nil }.count)/\(labelled.count) segment(s) labelled \
                in \(String(format: "%.1f", Date().timeIntervalSince(began)))s
                """)
            return labelled
        } catch {
            log("DIARIZE_FAILED: \(error.localizedDescription)")
            return segments
        }
    }

    /// The R1 gate: a Metal runtime and a CPU runtime alive in one process.
    ///
    /// `GGML_METAL_DEVICES=0` used to be set process-wide because the Metal backend wedged
    /// MTLCompilerService on some macOS 26 builds, which meant no model here could ever use
    /// the GPU. This proves the shared `LlamaBackend` lets the notes model onto Metal while
    /// S1-mini keeps running on the CPU — the whole reason Phase 0 existed. If it hangs or
    /// crashes, `Settings.llmMetalEnabled = false` restores the old behaviour.
    ///
    /// When the notes model isn't downloaded the Metal half runs against S1-mini's own GGUF
    /// instead: what is being tested is coexistence, not which weights are loaded, and a
    /// 2.7 GB download is not a precondition for answering that question.
    private func runMetalSelfTest() {
        Task { @MainActor in
            let usingNotesModel = NotesModels.isDownloaded
            let spec = usingNotesModel ? NotesModels.spec : S1MiniModels.spec
            guard spec.isDownloaded else {
                writeSelfTest("""
                    LLM_METAL_FAILED: neither \(NotesModels.spec.displayName) nor \
                    \(S1MiniModels.spec.displayName) is downloaded — nothing to load on the GPU.
                    """)
                NSApp.terminate(nil)
                return
            }
            if !usingNotesModel {
                writeSelfTest("""
                      note: \(NotesModels.spec.displayName) is not downloaded \
                    (\(NotesModels.spec.displaySize)); running the GPU half on \
                    \(spec.displayName) instead.
                    """)
            }

            let metalEnabled = Settings.shared.llmMetalEnabled
            let runtime = NotesModelRuntime(
                spec: spec,
                gpuLayers: NotesModelRuntime.allGPULayers
            )
            let probe = Self.metalProbe(for: spec)
            do {
                let completion = try await runtime.complete(
                    system: probe.system,
                    user: probe.user,
                    maxTokens: Self.metalProbeTokens
                )
                await LlamaBackend.shared.initialize()
                let offload = await LlamaBackend.shared.supportsGPUOffload
                let backends = await LlamaBackend.shared.systemInfo
                writeSelfTest("  backends: \(backends)")
                writeSelfTest("  gpu offload supported: \(offload)")
                writeSelfTest("""
                      GPU: \(spec.displayName) generated \(completion.generatedTokens) token(s) \
                    in \(String(format: "%.2f", completion.duration))s \
                    (\(String(format: "%.1f", completion.tokensPerSecond)) tok/s) \
                    \u{2192} \(completion.text.prefix(Self.metalProbeEcho))
                    """)
                // A run that emits nothing has proved the model loads, not that it decodes.
                // The wedge this gate exists to catch shows up mid-generation, so a probe
                // that generates no tokens is a failed probe, not a passed one.
                guard completion.generatedTokens > 0 else {
                    writeSelfTest("""
                        LLM_METAL_FAILED: \(spec.displayName) loaded on the GPU but generated \
                        no tokens.
                        """)
                    await runtime.shutdown()
                    NSApp.terminate(nil)
                    return
                }
                // Freed before S1-mini loads: the point is that both *can* run, not that a
                // self-test should hold two models resident on a 16 GB machine.
                await runtime.shutdown()

                let normalized = try await S1MiniRuntime.shared.normalize(
                    "so um i need to send the report by friday no wait make that thursday",
                    preferences: CleanupPreferences(
                        tone: .semiFormal,
                        formatsLists: true,
                        context: .general
                    )
                )
                writeSelfTest("  CPU: S1-mini normalised \u{2192} \(normalized)")

                let peak = Double(Self.peakResidentBytes()) / 1_048_576
                writeSelfTest("""
                    LLM_METAL_OK: metal \(metalEnabled ? "on" : "off"), \
                    GPU runtime and CPU runtime both ran in one process, \
                    peak RSS \(String(format: "%.0f", peak)) MB
                    """)
            } catch {
                await runtime.shutdown()
                writeSelfTest("LLM_METAL_FAILED: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    /// Prints what the island measured off every attached display, then walks its states.
    ///
    /// Two halves that fail for different reasons. The geometry half needs a screen and is
    /// the only way to see, from a terminal, whether this Mac's notch was found and what the
    /// island would be sized to — the numbers are otherwise invisible behind a panel that
    /// never takes focus. The state half needs nothing at all: it pushes notices at a fresh
    /// `IslandState` and checks that a question outranks a readout, which is the one rule
    /// the island has.
    /// Drives `DictationController` through the ways a hold can go wrong, and checks that
    /// every one of them comes back to `.idle`.
    ///
    /// This is the self-test for the report that reads "the transcription does not arrive
    /// in context, it looks like it's stuck, it keeps recording in the background". That is
    /// what the controller looks like from outside when an await in the tail never returns:
    /// the state machine parks in `.finishing`, which the HUD and the island both draw as a
    /// live recording, and the next press is refused because the state is still active.
    ///
    /// The microphone is real — there is no seam for `AudioCapture` and inventing one would
    /// test a fake. The engine, the formatter and the text injector are not: a self-test
    /// that used the real injector would type its fixtures into the terminal that started
    /// it, and one that used the real engine would be testing Parakeet.
    private func runDictationSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            // Short enough that a deadline can be observed to fire, in the same order of
            // magnitude as the real ones.
            let limits = DictationController.Limits(
                startup: .seconds(3),
                drain: .seconds(1),
                transcribe: .seconds(2),
                cleanup: .seconds(2),
                command: .seconds(2)
            )

            /// Holds the key for `held`, lets go, and waits for the controller to come to
            /// rest. Returns nil if it never does.
            @MainActor
            func hold(
                _ controller: DictationController,
                held: Duration,
                settle: TimeInterval
            ) async -> DictationController.State? {
                controller.startButtonRecording()
                try? await Task.sleep(for: held)
                let heldState = controller.state
                controller.stopButtonRecording()

                let deadline = Date().addingTimeInterval(settle)
                while Date() < deadline {
                    if case .idle = controller.state { return heldState }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                writeSelfTest("  DICTATION_STUCK: still \(controller.state) after \(settle)s")
                return nil
            }

            @MainActor
            func makeController(
                _ shape: SelfTestEngine.Shape,
                inbox: SelfTestInbox
            ) -> DictationController {
                DictationController(
                    formatter: RuleBasedFormatter(),
                    makeEngine: { SelfTestEngine(shape: shape) },
                    limits: limits,
                    insert: { inbox.append($0) },
                    // Discarded, not filed. These are fixtures, and the Dictation list is the
                    // user's own history — a self-test has no business appearing in it.
                    record: { _ in }
                )
            }

            // 1. The ordinary hold. Establishes that the microphone and the state machine
            //    work at all here — without it every other check below passes vacuously.
            let plain = SelfTestInbox()
            let controllerA = makeController(.prompt(delay: .zero), inbox: plain)
            let heldState = await hold(controllerA, held: .milliseconds(600), settle: 6)
            if heldState == nil {
                failures.append("an ordinary hold never came back to idle")
            } else if heldState != .listening {
                failures.append("an ordinary hold was \(heldState!) rather than listening — "
                                + "microphone access may be missing, so nothing below was really tested")
            }
            // Compared loosely on purpose: cleanup and the dictionary both run on the way
            // out, so the text that lands is not the text the engine produced.
            if plain.contents().count != 1 || plain.contents().first?.contains("transcript") != true {
                failures.append("an ordinary hold injected \(plain.contents()) rather than the transcript")
            }

            // 2. `finish()` that never returns — the engine wedged on a model load, or on a
            //    queue a meeting is holding. Bounded, this must give up and say so.
            let hung = SelfTestInbox()
            let controllerB = makeController(.hangsOnFinish, inbox: hung)
            if await hold(controllerB, held: .milliseconds(400), settle: 8) == nil {
                failures.append("a wedged finish() left the controller recording forever")
            }
            if !hung.contents().isEmpty {
                failures.append("a wedged finish() injected \(hung.contents())")
            }

            // 3. A transcript stream nobody closes. This is the shape the single-slot
            //    engine/consumeTask pair used to produce on its own, and the reason the
            //    controller now carries a session number.
            let open = SelfTestInbox()
            let controllerC = makeController(.leavesStreamOpen, inbox: open)
            if await hold(controllerC, held: .milliseconds(400), settle: 8) == nil {
                failures.append("an unfinished transcript stream left the controller recording forever")
            }

            // 4. Released while the engine is still starting, then held again straight
            //    away — two start-ups in flight against one set of slots. The first hold is
            //    lost, and must say so rather than going quiet; the second must still work.
            let raced = SelfTestInbox()
            let controllerD = makeController(.prompt(delay: .seconds(2)), inbox: raced)
            controllerD.startButtonRecording()
            try? await Task.sleep(for: .milliseconds(200))
            controllerD.stopButtonRecording()
            if case .error = controllerD.state {} else {
                failures.append("a hold released during start-up went quiet (\(controllerD.state)) "
                                + "instead of saying the recording was lost")
            }

            let settled = Date().addingTimeInterval(10)
            while Date() < settled, controllerD.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if controllerD.state != .idle {
                failures.append("a hold released during start-up never came back to idle")
            }
            // The abandoned start-up is still in flight here; the second hold has to be
            // unaffected by it.
            if await hold(controllerD, held: .seconds(3), settle: 8) == nil {
                failures.append("the hold after an abandoned start-up never came back to idle")
            }
            if raced.contents().count != 1 || raced.contents().first?.contains("transcript") != true {
                failures.append("the hold after an abandoned start-up injected \(raced.contents())")
            }

            failures.append(contentsOf: Self.selectionPolicyFailures())

            for failure in failures { writeSelfTest("  DICTATION_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                ? "DICTATION_OK: every hold came back to idle"
                : "DICTATION_FAILED: \(failures.count) problem(s)")
            NSApp.terminate(nil)
        }
    }

    /// Checks the rules behind selecting and deleting several transcriptions at once.
    ///
    /// The clicking itself cannot be tested — Speechify is blocked from UI automation on this
    /// machine — so what is asserted here is every rule that behaviour rests on.
    private static func selectionPolicyFailures() -> [String] {
        var failures: [String] = []

        let a = DictationRun(date: .now, engine: "e", audioSeconds: 1, processSeconds: 1, text: "first")
        let b = DictationRun(date: .now, engine: "e", audioSeconds: 1, processSeconds: 1, text: "second")
        let c = DictationRun(date: .now, engine: "e", audioSeconds: 1, processSeconds: 1, text: "third")
        let runs = [a, b, c]

        // One row is not worth a dialog; several are, because there is no undo.
        if DictationSelectionPolicy.needsConfirmation([a.id]) {
            failures.append("deleting one transcription asked for confirmation")
        }
        if !DictationSelectionPolicy.needsConfirmation([a.id, b.id]) {
            failures.append("deleting two transcriptions did not ask for confirmation")
        }

        // A Set has no order, so a multi-row copy has to take the list's.
        let copied = DictationSelectionPolicy.copyText(for: [c.id, a.id], from: runs)
        if copied != "first\n\nthird" {
            failures.append("copying two transcriptions gave \(copied.debugDescription), "
                            + "not the two in list order")
        }
        if !DictationSelectionPolicy.copyText(for: [], from: runs).isEmpty {
            failures.append("copying nothing produced text")
        }

        // A row can be deleted out from under the selection.
        let pruned = DictationSelectionPolicy.pruned([a.id, b.id], existing: [a, c])
        if pruned != [a.id] {
            failures.append("a selection holding a deleted transcription was not pruned")
        }

        return failures
    }

    private func runIslandSelfTest() {
        Task { @MainActor in
            for screen in NSScreen.screens {
                let metrics = IslandGeometry.metrics(for: screen)
                let notch = IslandGeometry.notchWidth(of: screen)
                    .map { "\(Int($0))pt wide" } ?? "none"
                writeSelfTest("""
                      \(screen.localizedName): \(Int(screen.frame.width))x\
                    \(Int(screen.frame.height)) at \(Int(screen.frame.minX)),\
                    \(Int(screen.frame.minY)) — safe-area top \
                    \(Int(screen.safeAreaInsets.top))pt, notch \(notch)
                    """)
                writeSelfTest("""
                        \(metrics.hugsNotch ? "hugs the notch" : "floats below the menu bar"), \
                    collapsed \(Int(metrics.collapsedSize.width))x\
                    \(Int(metrics.collapsedSize.height)), expanded \
                    \(Int(metrics.expandedSize.width))x\(Int(metrics.expandedSize.height)), \
                    panel at \(Int(metrics.bounds.minX)),\(Int(metrics.bounds.minY))
                    """)
            }

            var failures = Self.islandStateFailures()

            // The one property this panel must never lose. A key island would take focus
            // away from the text field `TextInjector` is about to type into.
            let state = IslandState()
            let panel = IslandPanel(state: state)
            if panel.canBecomeKey { failures.append("the island panel can become key") }
            if panel.canBecomeMain { failures.append("the island panel can become main") }
            if panel.level != .statusBar { failures.append("the island is not at status-bar level") }
            if !panel.ignoresMouseEvents {
                failures.append("a hidden island is taking mouse events")
            }

            // Actually put it on screen for a moment. Everything above this is arithmetic;
            // this is the part that fails when the hosting view, the frame or the tracking
            // loop is wrong, and none of it is visible from a terminal otherwise.
            state.announceNotesReady(Meeting(title: "Self-test", start: Date(), status: .done))
            try? await Task.sleep(for: .seconds(Self.islandSettle))
            if !panel.isVisible { failures.append("an island with something to say never appeared") }
            if panel.ignoresMouseEvents {
                failures.append("an expanded island is ignoring the mouse it has buttons for")
            }
            if let screen = IslandGeometry.screenUnderMouse(),
               panel.frame != IslandGeometry.metrics(for: screen).bounds {
                failures.append("the island is not where its own geometry puts it")
            }
            state.dismissNotice()
            try? await Task.sleep(for: .seconds(Self.islandSettle))
            if panel.isVisible { failures.append("an island with nothing to say stayed up") }

            for failure in failures { writeSelfTest("  ISLAND_WRONG: \(failure)") }
            if failures.isEmpty {
                writeSelfTest("""
                    ISLAND_OK: \(NSScreen.screens.count) display(s), \
                    \(IslandGeometry.hasNotch ? "notched" : "no notch"), \
                    placement \(Settings.shared.hudPlacement.rawValue), state machine behaves
                    """)
            } else {
                writeSelfTest("ISLAND_FAILED: \(failures.count) rule(s) wrong")
            }
            NSApp.terminate(nil)
        }
    }

    /// Long enough for the observation hop, the fade and the order-out to have happened.
    private static let islandSettle: TimeInterval = 1

    /// The island's priority rules, stated as cases. Returns the ones that came out wrong.
    private static func islandStateFailures() -> [String] {
        let state = IslandState()
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        check("a fresh island is hidden", state.kind == .hidden)
        check("a hidden island is not expanded", !state.isExpanded)

        let event = MeetingEvent(
            id: "selftest",
            providerID: .fake,
            title: "Self-test",
            start: Date().addingTimeInterval(60),
            end: Date().addingTimeInterval(1_860),
            attendees: ["Sam"],
            isOrganizerOrSelfAccepted: true,
            conferenceURL: URL(string: "https://meet.google.com/x"),
            calendarName: "Test",
            isAllDay: false
        )
        state.announceArmed(event)
        check("an armed meeting shows", state.kind == .meetingArmed(event))
        check("an armed meeting opens the island by itself", state.isExpanded)
        state.clearArmed(event)
        check("answering an armed meeting takes it down", state.kind == .hidden)

        let meeting = Meeting(title: "Self-test", start: Date(), status: .done)
        state.announceNotesReady(meeting)
        check(
            "finished notes show",
            state.kind == .notesReady(meetingID: meeting.id, title: meeting.title)
        )
        check("finished notes open the island by itself", state.isExpanded)
        state.dismissNotice()
        check("dismissing finished notes takes them down", state.kind == .hidden)

        let proposal = IslandProposal(
            id: "selftest",
            title: "Send the notes",
            detail: "Email the action items to Sam.",
            meetingID: meeting.id
        )
        state.propose(proposal)
        check("an agent proposal shows", state.kind == .agentProposal(proposal))
        state.dismissNotice()

        // Readouts stay collapsed until the pointer arrives; questions do not wait for it.
        check("a readout stays collapsed", !IslandState.Kind.transcribing.demandsAttention)
        check("a recording readout stays collapsed", !IslandState.Kind.dictating(
            transcript: "", level: 0, isCapturing: true
        ).demandsAttention)
        check("a question opens itself", IslandState.Kind.notesReady(
            meetingID: meeting.id, title: ""
        ).demandsAttention)

        // An orb never replaces the red dot, it sits beside it: a recording meeting draws
        // both, the dot for "this is being recorded" and `weaving` for the two channels
        // being braided into one transcript. Only half of that rule is visible from here —
        // the dot is `IslandView.badge`'s, and it is drawn unconditionally for this state.
        check("a recording meeting weaves", IslandState.Kind.meetingRecording(
            elapsed: 0, micLevel: 0, systemLevel: 0
        ).orb == .weaving)
        check("dictation listens", IslandState.Kind.dictating(
            transcript: "", level: 0, isCapturing: true
        ).orb == .listening)
        // A held key and a finished one must not look the same. This is the island half of
        // the "it looks like it is still recording" report: while the engine works, the
        // island says so instead of going on listening.
        check("a finished hold stops listening", IslandState.Kind.dictating(
            transcript: "", level: 0, isCapturing: false
        ).orb == .working)
        check("transcribing works", IslandState.Kind.transcribing.orb == .working)
        check("summarizing composes", IslandState.Kind.summarizing(progress: nil).orb == .composing)

        return failures
    }

    /// Builds every orb at both sizes and checks the frames are drawable and moving.
    ///
    /// The geometry is trigonometry over tuned constants, and the failure mode of getting it
    /// wrong is not a crash but a blank patch or a single dot in the corner — which nobody
    /// notices in a 20pt badge. This asks the four questions a screenshot would answer:
    /// are there dots, are they finite, are they inside the frame, and do they move.
    private func runOrbSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            let times: [Double] = [0, 0.37, 1.7, 9.2]

            for state in OrbGeometry.State.allCases {
                for inline in [true, false] {
                    let side = inline ? DS.Size.orbInline : DS.Size.orbLarge
                    let name = "\(state.rawValue) \(inline ? "inline" : "large")"
                    var frames: [[OrbGeometry.Dot]] = []
                    for time in times {
                        frames.append(
                            OrbGeometry.frame(for: state, size: side, time: time, inline: inline)
                        )
                    }

                    guard let first = frames.first, !first.isEmpty else {
                        failures.append("\(name) draws nothing")
                        continue
                    }
                    for dots in frames {
                        if dots.contains(where: {
                            !$0.x.isFinite || !$0.y.isFinite || !$0.radius.isFinite
                                || $0.radius <= 0 || $0.opacity < 0 || $0.opacity > 1
                        }) {
                            failures.append("\(name) produced an undrawable dot")
                            break
                        }
                    }
                    // Generously outside the box: several modes deliberately swell past the
                    // radius, and what matters is that nothing has flown off to infinity.
                    let bounds = CGRect(x: -side, y: -side, width: side * 3, height: side * 3)
                    if first.contains(where: { !bounds.contains(CGPoint(x: $0.x, y: $0.y)) }) {
                        failures.append("\(name) drew outside its frame")
                    }
                    // A frozen orb is the bug this catches: a mode whose time term was
                    // dropped renders perfectly and never moves.
                    let moved = zip(first, frames[2]).contains { $0.x != $1.x || $0.y != $1.y }
                    if !moved { failures.append("\(name) does not move") }

                    writeSelfTest("  \(name): \(first.count) dots at \(Int(side))pt")
                }
            }

            for failure in failures { writeSelfTest("  ORB_WRONG: \(failure)") }
            if failures.isEmpty {
                writeSelfTest("""
                    ORB_OK: \(OrbGeometry.State.allCases.count) state(s) at two sizes, \
                    all drawable and animating
                    """)
            } else {
                writeSelfTest("ORB_FAILED: \(failures.count) problem(s)")
            }
            NSApp.terminate(nil)
        }
    }

    /// Finds the Workspace CLI and says where its own setup has got to.
    ///
    /// Reads and never writes: `--version` and `auth status` are the two commands `gws` will
    /// answer without touching Google, which is the whole point — this has to be runnable on
    /// a machine that has never signed in without doing anything to an account.
    private func runWorkspaceCLISelfTest() {
        Task { @MainActor in
            let cli = GoogleWorkspaceCLI.shared
            guard let binary = await cli.binaryURL() else {
                writeSelfTest("""
                    GWS_FAILED: no gws binary found. Install it from the Workspace tab, \
                    or with `brew install googleworkspace-cli`.
                    """)
                NSApp.terminate(nil)
                return
            }
            let version = await cli.version() ?? "unknown"
            let state = await cli.authState()
            writeSelfTest("  binary: \(binary.path)")
            writeSelfTest("  version: \(version)")
            writeSelfTest("  auth: \(state.displayName) — \(state.detail)")
            writeSelfTest("  client config: \(GoogleWorkspaceCLI.clientConfigURL.path)")

            if case .failed(let reason) = state {
                writeSelfTest("GWS_FAILED: \(reason)")
            } else {
                writeSelfTest("GWS_OK: \(version) at \(binary.path), \(state.displayName.lowercased())")
            }
            NSApp.terminate(nil)
        }
    }

    /// Runs the agent over a meeting folder and prints what it would propose.
    ///
    /// Nothing is executed: the policy is `dryRun`, so no read tool runs either, and every
    /// proposal is printed rather than performed. Two halves again — the catalogue and the
    /// parser are checked without a model, so a build whose tool schemas stopped being valid
    /// JSON is caught on a machine with no 2.7 GB download and no Google account.
    ///
    /// - Parameter directory: a meeting folder under
    ///   `Application Support/Speechify/Meetings/`.
    private func runAgentSelfTest(directory path: String) {
        Task { @MainActor in
            var failures = Self.agentStaticFailures()

            // The gate that stands between a half-written proposal and a send: it refuses
            // before the CLI is even located, so asking the question here executes nothing.
            do {
                _ = try await WorkspaceToolRunner.run(AgentProposal(
                    meetingID: UUID(),
                    tool: "send_email",
                    arguments: ["to": "a@x.com", "subject": "Hi"],
                    rationale: ""
                ))
                failures.append("an email with no body was accepted")
            } catch AgentError.missingArgument {
                // Correct.
            } catch {
                failures.append("an incomplete proposal failed for the wrong reason")
            }
            for failure in failures { writeSelfTest("  AGENT_WRONG: \(failure)") }

            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let meeting = Self.loadMeeting(from: url) else {
                writeSelfTest("AGENT_FAILED: \(url.path) has no \(MeetingStore.recordFile)")
                NSApp.terminate(nil)
                return
            }
            let segments = Self.loadTranscript(from: url)
            let notes = try? String(
                contentsOf: url.appendingPathComponent(MeetingStore.notesFile),
                encoding: .utf8
            )
            writeSelfTest("""
                  meeting: "\(meeting.title)" — \(segments.count) segment(s), \
                notes \(notes == nil ? "absent" : "present")
                """)

            guard !segments.isEmpty else {
                writeSelfTest("AGENT_FAILED: nothing was transcribed in \(url.path)")
                NSApp.terminate(nil)
                return
            }
            guard let provider = await LLMProviders.resolve(
                preferring: Settings.shared.notesProvider
            ) else {
                let reasons = await Self.providerReasons()
                writeSelfTest("AGENT_FAILED: no provider available — \(reasons)")
                NSApp.terminate(nil)
                return
            }

            do {
                let began = Date()
                let proposals = try await MeetingAgent.shared.proposals(
                    for: meeting,
                    segments: segments,
                    notes: notes,
                    provider: provider,
                    policy: .dryRun
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(proposals),
                   let json = String(data: data, encoding: .utf8) {
                    writeSelfTest(json)
                }
                // A proposal naming a tool that can't run, or missing an argument, would be
                // an Approve button that fails on press.
                for proposal in proposals where proposal.definition == nil {
                    failures.append("proposed the unknown tool \(proposal.tool)")
                }
                writeSelfTest("""
                    AGENT_\(failures.isEmpty ? "OK" : "FAILED"): \(provider.id.rawValue) \
                    proposed \(proposals.count) action(s) in \
                    \(String(format: "%.1f", Date().timeIntervalSince(began)))s, \
                    nothing was executed
                    """)
            } catch {
                writeSelfTest("AGENT_FAILED: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    /// The tool catalogue and the tool-call parser, checked without a model or an account.
    private static func agentStaticFailures() -> [String] {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let names = WorkspaceTools.all.map(\.name)
        check("two tools share a name", Set(names).count == names.count)
        check("the catalogue is empty", !WorkspaceTools.all.isEmpty)

        // Every schema line has to be JSON: the model is handed these verbatim, and a
        // description with an unescaped quote in it produces a block it reads as truncated.
        let lines = WorkspaceTools.schemaJSON(for: WorkspaceTools.all)
            .split(separator: "\n")
            .map(String.init)
        check("a tool produced no schema", lines.count == WorkspaceTools.all.count)
        for line in lines where (try? JSONSerialization.jsonObject(with: Data(line.utf8))) == nil {
            failures.append("a tool schema isn't valid JSON")
        }

        // The risk gate is the permission model, so it is checked rather than assumed.
        check(
            "a send tool is offered to a write-only pass",
            WorkspaceTools.tools(upTo: .write).allSatisfy { $0.risk != .send }
        )
        check(
            "reads are not offered to a read-only pass",
            !WorkspaceTools.tools(upTo: .read).isEmpty
        )

        // The parser, over the two shapes a model actually emits.
        let output = """
            Here is what I would do.
            <tool_call>{"name": "send_email", "arguments": {"to": ["a@x.com", "b@x.com"], \
            "subject": "Notes", "body": "Attached."}, "rationale": "They asked."}</tool_call>
            <tool_call>{"name": "create_doc", "arguments": "{\\"title\\": \\"Standup\\"}"}</tool_call>
            """
        let calls = AgentToolCallParser.calls(in: output)
        check("the parser lost a tool call", calls.count == 2)
        check("the parser dropped the prose it should ignore", calls.first?.name == "send_email")
        check(
            "a list argument didn't come back comma-separated",
            calls.first?.arguments["to"] == "a@x.com, b@x.com"
        )
        check("the rationale was lost", calls.first?.rationale == "They asked.")
        check(
            "arguments encoded as a string weren't parsed",
            calls.last?.arguments["title"] == "Standup"
        )
        check("prose alone produced a call", AgentToolCallParser.calls(in: "I would send an email.").isEmpty)

        // Fail-closed: a proposal whose tool this build doesn't have must never be treated
        // as something harmless enough to run without asking.
        let unknown = AgentProposal(
            meetingID: UUID(),
            tool: "delete_everything",
            arguments: [:],
            rationale: ""
        )
        check("an unknown tool isn't treated as the most dangerous class", unknown.risk == .send)

        return failures
    }

    /// One meeting folder's record, read without going through the store — the self-test is
    /// pointed at a directory, which may not be one the running app has loaded.
    private static func loadMeeting(from directory: URL) -> Meeting? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStore.recordFile))
        else { return nil }
        return try? decoder.decode(Meeting.self, from: data)
    }

    private static func loadTranscript(from directory: URL) -> [TranscriptSegment] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStore.transcriptFile))
        else { return [] }
        return (try? decoder.decode([TranscriptSegment].self, from: data)) ?? []
    }

    /// Enough tokens to prove the GPU path decodes, few enough to finish in seconds.
    private static let metalProbeTokens = 32
    /// How much of the probe's answer is echoed, so a garbled GPU decode is visible.
    private static let metalProbeEcho = 80

    /// A prompt the loaded model will actually answer.
    ///
    /// S1-mini is a normalizer, not an assistant: asked a general question it returns the
    /// empty string immediately, which would make the substitute run prove nothing. Given
    /// its own control-line protocol it generates properly.
    private static func metalProbe(for spec: ModelSpec) -> (system: String, user: String) {
        guard spec.fileName == S1MiniModels.spec.fileName else {
            return (
                "You answer in one short sentence.",
                "Name three things you would find in a kitchen."
            )
        }
        return (
            "You are a text normalizer for speech-to-text transcripts. The input begins with "
                + "a control line specifying the styling, structure, and context settings; "
                + "clean the transcript to match those settings and output only the cleaned text.",
            "[Styling: semi-formal] [Structure: lists] [Context: general]\n"
                + "um so the meeting is on tuesday no sorry wednesday at three"
        )
    }

    private static func providerReasons() async -> String {
        var parts: [String] = []
        for id in LLMProviderID.allCases {
            let reason = await LLMProviders.make(id).unavailableReason ?? "available"
            parts.append("\(id.rawValue): \(reason)")
        }
        return parts.joined(separator: "; ")
    }

    /// High-water resident memory for this process.
    ///
    /// `resident_size_max` rather than a sample of current usage: the peak is what decides
    /// whether Parakeet and a 2.7 GB model can both be alive on this machine, and it happens
    /// somewhere in the middle of the run rather than at the end.
    private static func peakResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size_max : 0
    }

    /// The argument following `flag`, for self-tests that take a path.
    private static func value(after flag: String) -> String? {
        let arguments = Array(CommandLine.arguments)
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func writeSelfTest(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }

    /// `speechify://show` — a scriptable way to raise the window on the comparison
    /// section. It used to open a second window; now it just steers the one that exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "speechify" {
            switch url.host {
            case "show":
                RunStore.shared.reload()
                NavigationState.shared.show(.comparison)
                Self.showMainWindow()
            default:
                break
            }
        }
    }

    /// Raises the main window without needing SwiftUI's `openWindow` environment value —
    /// usable from the app delegate, the menu bar, and the URL handler.
    ///
    /// Not matched on title: each sidebar section sets its own `navigationTitle`, so the
    /// window is called "Dictation" or "Dictionary" depending on where you left it. SwiftUI
    /// does decorate the scene id into the window identifier, but that shape isn't API —
    /// hence the fallback to the first window that can actually become main, which excludes
    /// the HUD panel by construction.
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.identifier?.rawValue.contains(mainWindowID) == true }
            ?? NSApp.windows.first { $0.canBecomeMain }
        window?.makeKeyAndOrderFront(nil)
    }

    static let mainWindowTitle = "Speechify"
    static let mainWindowID = "main"

    func applicationWillTerminate(_ notification: Notification) {
        controller.deactivate()
        // Termination can't await, so the meeting is closed with what has already been
        // transcribed; windows still in flight are lost. Better than a meeting whose file
        // says it is still recording.
        meetings.endForTermination()
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
            _ = Settings.shared.hudPlacement
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // The island takes dictation instead whenever it is the chosen placement,
                // and it derives that for itself — this only has to stay out of its way.
                if self.controller.state.shouldShowHUD,
                   Settings.shared.hudPlacement == .bottom {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeState()
            }
        }
    }

    /// Keeps the Dock badge in step with a running meeting.
    ///
    /// The window is usually behind the call being recorded and the menu-bar item is a 16pt
    /// glyph, so the Dock icon is the only place "Speechify is listening to this" is visible
    /// from across the desk. The badge is red without being asked, which is the one colour
    /// rule this app has.
    private func observeMeetingBadge() {
        NSApp.dockTile.badgeLabel = meetings.isRecording ? Self.recordingBadge : nil
        withObservationTracking {
            _ = meetings.isRecording
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeMeetingBadge()
            }
        }
    }

    private static let recordingBadge = "REC"

    private func retryActivation() {
        Task { @MainActor in
            // A stale TCC entry can make the toggle look enabled while event-tap creation
            // still fails. Keep checking the operation itself, not just the displayed grant.
            while true {
                if Permissions.hasAccessibility, controller.activate() { break }
                try? await Task.sleep(for: .seconds(1))
            }
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }
}

/// The main menu's meeting command, and the keyboard shortcut that goes with it.
///
/// Its own view rather than a plain `Button` in the `CommandGroup` so the title can follow
/// the controller: a menu item that says "Record Meeting" while one is recording is a menu
/// item that lies. Application menus are only live while Speechify is frontmost — starting a
/// meeting from inside the call you are in is what the menu-bar item is for.
private struct MeetingCommands: View {
    @State private var meetings = MeetingController.shared

    var body: some View {
        Button(meetings.isRecording ? "Stop Meeting" : "Record Meeting") {
            Task {
                if meetings.isRecording {
                    await meetings.stop()
                } else {
                    await meetings.startAdHoc()
                }
            }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(meetings.isFinishing)
    }
}

/// The menu-bar menu.
///
/// Status and the two ways out of it — nothing configurable. Every setting used to be
/// duplicated here and in the Settings window, which meant two places to look and two
/// places to keep in step; the menu now points at the one that owns them.
private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var meetings = MeetingController.shared
    @State private var calendar = CalendarService.shared
    @State private var scheduler = MeetingScheduler.shared

    var body: some View {
        Text(statusLine)

        // The next meeting, and whether Speechify intends to record it. This is the whole
        // reason to look at the menu while a call is about to start.
        if let next = calendar.next, !meetings.isRecording {
            Text(nextMeetingLine(next))
        }

        Divider()

        // The reason the menu still exists: starting a meeting from whatever app you are
        // actually in, without raising a window over the call you are joining.
        Button(meetingCommand) {
            Task {
                if meetings.isRecording {
                    await meetings.stop()
                } else {
                    await meetings.startAdHoc()
                }
            }
        }
        .disabled(meetings.isFinishing)

        Divider()

        Button("Open Speechify") { AppDelegate.showMainWindow() }
            .keyboardShortcut("o")

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Speechify") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "Standup · 14:30 · will record" — the answer to "is this being taken care of?"
    private func nextMeetingLine(_ event: MeetingEvent) -> String {
        let time = event.start.formatted(date: .omitted, time: .shortened)
        let intent = scheduler.willAutoRecord(event) ? "will record" : "won\u{2019}t record"
        return "\(event.title) \u{00B7} \(time) \u{00B7} \(intent)"
    }

    private var meetingCommand: String {
        if meetings.isFinishing { return "Finishing meeting\u{2026}" }
        return meetings.isRecording
            ? "Stop meeting \u{00B7} \(meetings.elapsed.counterText)"
            : "Record meeting now"
    }

    private var statusLine: String {
        switch controller.state {
        case .idle:
            controller.hotkeyReady
                ? "Hold \(settings.pushToTalkKey.displayName) to dictate"
                : "Push-to-talk is not armed"
        case .starting, .listening: "Listening…"
        case .finishing: "Transcribing…"
        case .error(let message): message
        }
    }
}


/// Accumulates level statistics from the audio thread during `--selftest-systemaudio`.
private final class SelfTestMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var sumOfSquares: Double = 0
    private var peak: Float = 0

    func add(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            sumOfSquares += Double(sample) * Double(sample)
            peak = max(peak, abs(sample))
        }
        frames += samples.count
    }

    func summary() -> (frames: Int, rms: Double, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        let rms = frames > 0 ? (sumOfSquares / Double(frames)).squareRoot() : 0
        return (frames, rms, peak)
    }
}

/// Collects segments from `ChunkedTranscriber`'s handler, which runs off the main actor.
private actor SelfTestSegments {
    private var segments: [TranscriptSegment] = []

    func add(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    func all() -> [TranscriptSegment] { segments }
}

/// Collects what a self-test's `DictationController` would have typed.
///
/// A class rather than a captured `var`: the injector closure is stored on the controller
/// and called from inside its own task, so the self-test needs a reference to read
/// afterwards.
@MainActor
final class SelfTestInbox {
    private var texts: [String] = []
    func append(_ text: String) { texts.append(text) }
    func contents() -> [String] { texts }
}

/// A transcription engine that can be asked to misbehave in each of the ways a real one
/// has been observed to.
///
/// Nothing here is a mock of Parakeet — it makes no attempt to transcribe. It exists to
/// put the *controller* in the situations that used to wedge it: a slow start, a `finish()`
/// that never returns, and a transcript stream nobody closes.
actor SelfTestEngine: TranscriptionEngine {
    static let transcript = "self test transcript"

    enum Shape: Sendable {
        /// Starts after `delay`, then yields the fixture and closes cleanly.
        case prompt(delay: Duration)
        /// `finish()` never returns — a model load, or a queue a meeting is holding.
        case hangsOnFinish
        /// Yields the fixture but never closes the stream, so anything awaiting the
        /// consuming task waits forever.
        case leavesStreamOpen
    }

    private let shape: Shape
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    init(shape: Shape) { self.shape = shape }

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        if case .prompt(let delay) = shape, delay > .zero {
            try await Task.sleep(for: delay)
        }
        return stream
    }

    func feed(_ chunk: AudioChunk) async {}

    func finish() async {
        switch shape {
        case .hangsOnFinish:
            // Deliberately unbounded. `Task.sleep` throws on cancellation, and the point is
            // to stay here even when the caller has given up, exactly as a CoreML inference
            // or a llama.cpp decode would.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
                if Task.isCancelled { break }
            }
        case .leavesStreamOpen:
            continuation?.yield(TranscriptionChunk(text: Self.transcript, isFinal: true))
        case .prompt:
            continuation?.yield(TranscriptionChunk(text: Self.transcript, isFinal: true))
            continuation?.finish()
            continuation = nil
        }
    }
}
