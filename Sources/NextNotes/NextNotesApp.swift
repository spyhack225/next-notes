import AVFoundation
import AppKit
import Darwin
import FluidAudio
import NextNotesDictionary
import os
import SwiftUI

@main
struct NextNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        //
        // `.presented` is load-bearing on macOS 26+: without it, a restored-or-suppressed
        // window plus a failed menu-bar extra lets SwiftUI decide no scene is keeping the
        // process alive, and the app exits voluntarily in about a second with no crash log.
        Window(AppDelegate.mainWindowTitle, id: AppDelegate.mainWindowID) {
            MainWindow(controller: delegate.controller)
        }
        .defaultSize(width: DS.Size.windowMin.width, height: DS.Size.windowMin.height)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
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
            // The one host that guarantees `settingsWindowMinWidth`: the window is pinned
            // to it by `SettingsWindowFrame`, and `windowResizability(.contentMinSize)`
            // reads this minimum as the window's own. The main window's copy passes
            // nothing, because its detail column is narrower than this.
            SettingsWindow(
                controller: delegate.controller,
                hostMinimumWidth: DS.Size.settingsWindowMinWidth
            )
        }
        .defaultSize(width: DS.Size.settingsWindowWidth, height: DS.Size.settingsWindowMinHeight)
        .windowResizability(.contentMinSize)
        // Unified compact keeps the sidebar toggle on the same row as the traffic
        // lights instead of the tall large-title bar `.automatic` picks for a
        // `.sidebarAdaptable` TabView. Paired with `.toolbarTitleDisplayMode(.inline)`
        // in SettingsWindow.
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        // Menu bar item is an AppKit `NSStatusItem` owned by `AppDelegate`, not a
        // `MenuBarExtra`. On macOS 26 MenuBarAgent can accept the SwiftUI extra and then
        // report "No server elements for status item"; SwiftUI tears the scene down and the
        // whole process exits. A manual status item stays alive when the icon is hidden.
    }
}

/// Whether the process was launched to run one of the `--selftest-…` flags.
///
/// The scene graph is declarative, so the main window is still built during a self-test even
/// though `applicationDidFinishLaunching` returns early. Anything that would put a modal on
/// screen has to check this: a sheet keeps `NSApp.terminate` from ever completing, and the
/// test then prints its result and hangs forever instead of exiting.
enum SelfTest {
    /// AppKit's normal termination status is zero. A named failed verdict must
    /// survive `NSApp.terminate(nil)` so scripts cannot mistake it for success.
    @MainActor static var failed = false
    /// The flag the process was launched with, if any.
    ///
    /// The harness's own flags are excluded. They share the `--selftest` prefix but are
    /// settings rather than tests, and either can precede the test's flag on the command
    /// line — put `--selftest-timeout` first and the process would otherwise decide the
    /// test it had been asked to run was "--selftest-timeout".
    static let requested = CommandLine.arguments.dropFirst().first {
        $0.hasPrefix("--selftest") && !harnessFlags.contains($0)
    }

    static var isRunning: Bool { requested != nil }

    /// Preserve model/audio probe detail when LaunchServices has no stdout.
    @MainActor static func diagnostic(_ line: String) {
        print(line)
        guard isRunning, let path = outputPath else { return }
        let text = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// See the dispatch site for why this is a modifier and not a self-test.
    static let downloadNotesModelFlag = "--download-notes-model"

    /// "4.7 GB" rather than "4977171584", in the same formatter the Models tab uses, so a
    /// line in a log reads like the card the person would have seen.
    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
    static let outputFlag = "--selftest-out"
    static let timeoutFlag = "--selftest-timeout"

    /// Flags that configure a run rather than name one.
    private static let harnessFlags: Set<String> = [outputFlag, timeoutFlag]

    /// The argument following `flag`, or nil when there isn't one.
    ///
    /// **A flag is never a value.** Without that rule
    /// `--selftest-cleanup --selftest-timeout 2400` reads "--selftest-timeout" as the engine
    /// name, reports `unknown engine`, runs nothing, and still exits 0 — a green result for a
    /// suite that never executed, which is the worst kind of test failure there is.
    static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        let next = arguments[index + 1]
        guard !next.hasPrefix("--") else { return nil }
        return next
    }

    /// How long a self-test may run before it is declared hung.
    ///
    /// A self-test that never finishes never fails, because the process falls through into
    /// the AppKit run loop and waits for events that are not coming. `--selftest-cleanup app-llm`
    /// did exactly that on 2026-09-09: it printed its header and then sat for three hours on
    /// 2 seconds of CPU, holding megabytes against a multi-gigabyte model it had not loaded. Nothing
    /// reported it, because from the outside it looked like a running app.
    ///
    /// Generous on purpose. The slowest honest test loads a multi-gigabyte model from cold.
    /// Override with `--selftest-timeout <seconds>`.
    static let timeout: Double = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: timeoutFlag),
              index + 1 < arguments.count,
              let seconds = Double(arguments[index + 1]), seconds > 0
        else { return defaultTimeout }
        return seconds
    }()

    /// A flat budget suits a test that does a fixed piece of work — load a model, run one
    /// utterance, report. The cleanup eval is not that shape: it runs every fixture in
    /// `CleanupEvalCases.all` through every requested engine, and one model-backed fixture
    /// takes about a minute on this hardware. `--selftest-cleanup all` is five model passes
    /// over every fixture, so the flat 300s stopped it at the fourth fixture of twenty and
    /// called it hung — for a run that had been asked for roughly two hours of work and was
    /// proceeding normally. Sized from the fixtures instead, so adding a case moves the
    /// budget with it.
    private static var defaultTimeout: Double {
        let flat: Double = 300
        // P1-01: a live eval case can spend its 150 s turn limit plus a cold multi-gigabyte
        // load, and the flat budget would kill a healthy run at the second case. Sized from
        // the cases the run will actually take: the whole list for a full run (P1-27 appended
        // the owner's ten to the thirty, and a full run executes both), 10 quick, or the
        // `--only` subset.
        if requested == "--selftest-toolloop-live" {
            let caseCount: Int
            if CommandLine.arguments.contains("--quick") {
                caseCount = LiveEvalCases.quickIDs.count
            } else if let only = value(after: "--only") {
                caseCount = only.split(separator: ",").filter { !$0.isEmpty }.count
            } else {
                caseCount = LiveEvalCases.all.count
            }
            return max(flat, Double(caseCount) * 300 + 300)
        }
        guard requested == "--selftest-cleanup" else { return flat }

        let modelBacked: Set<String> = ["apple", "apple-grammar", "s1", "chain", "app-llm"]
        let choice = value(after: "--selftest-cleanup") ?? "all"
        let passes = choice == "all"
            ? modelBacked.count
            : (modelBacked.contains(choice) ? 1 : 0)
        // "guard" and "rules" are pure computation and finish in milliseconds.
        guard passes > 0 else { return flat }

        let perFixture: Double = 90
        return max(flat, Double(passes * CleanupEvalCases.all.count) * perFixture)
    }

    /// Where to mirror output, for a run that has no stdout to write to.
    ///
    /// That is not a hypothetical: TCC answers can depend on which process it holds
    /// responsible, and the only way to run a self-test with the app itself responsible —
    /// rather than the shell that spawned it — is through LaunchServices:
    ///
    ///     open -n -a NextNotes --args --selftest-systemaudio --selftest-out /tmp/out.txt
    ///
    /// which discards stdout entirely.
    static let outputPath: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: outputFlag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    /// The running delegate, for code that must read dictation state from outside the view
    /// tree (the reminder presence rule). The SwiftUI adaptor hides it from `NSApp.delegate`.
    private(set) static weak var current: AppDelegate?
    /// Meetings run from a singleton because the menu bar, the Meetings section and the
    /// scheduler all have to reach the same session. The delegate holds it so a running
    /// recording is closed out when the app quits.
    let meetings = MeetingController.shared
    private var hud: HUDPanel?
    /// The notch island. Created once and kept for the life of the process: it is a window
    /// that shows and hides itself, not one that is made and thrown away.
    private var island: IslandPanel?
    private var stateObservation: NSObjectProtocol?
    /// Menu-bar icon. Held strongly: AppKit will not keep it alive for us, and SwiftUI's
    /// `MenuBarExtra` is unsafe on macOS 26 when MenuBarAgent hosts no server elements.
    private var statusItem: NSStatusItem?
    /// D-06: the wake observer that re-warms Apple's cleanup model after sleep. Held so
    /// the token stays addressable, the way `CalendarService` holds its observers.
    private var warmObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        // Before the self-test check: a notification the user actioned while Next Notes was
        // closed is delivered the instant the app launches, and a delegate installed after
        // that never sees it.
        Notifications.shared.configure()

        // A diagnostic, not a self-test: it reads the live stores, which the self-test
        // harness deliberately replaces with empty ones. Runs before `runRequestedSelfTest`
        // so `SelfTest.isRunning` stays false and the real stores load.
        if CommandLine.arguments.contains("--notes-context-live") {
            runNotesContextLiveProbe()
            return
        }

        // P0-20d: the same shape, for the same reason. `--usage-report` reads this
        // machine's real `usage.jsonl`, which the harness replaces with an empty temp
        // store, so it runs before `runRequestedSelfTest` and is a diagnostic, never a
        // `--selftest-*` flag.
        if CommandLine.arguments.contains("--usage-report") {
            runUsageReport()
            return
        }

        // `--download-notes-model`: a **modifier**, not a `--selftest-*` flag, in the shape of
        // `--fake-calendar` and `--wake-mic-record` — it changes the machine rather than
        // answering a question about it.
        //
        // It exists because the only other path to the built-in model is the Models tab, and
        // driving that needs Accessibility, which an agent on this machine is refused
        // (`AXIsProcessTrusted()` answers false even through LaunchServices). The model is
        // also the thing the Agent role is meant to use, so every model-dependent gate —
        // `--selftest-tool-awareness`, `--selftest-voice-grounding`, and the Phase 1 exit
        // score — is unreachable without it. That is AGENTS.md's own case for a flag: most of
        // this app needs a permission, a model or an account a coding agent cannot obtain.
        //
        // It prints one line per 5% and a final `NOTES_MODEL_DOWNLOAD_*`, and it reports the
        // digest the spec is waiting to pin rather than pinning it itself.
        if CommandLine.arguments.contains(SelfTest.downloadNotesModelFlag) {
            runNotesModelDownload()
            return
        }

        // NextNotes-iMessage IM-02 / gate G2: the same shape and the same two reasons — it needs
        // an Automation grant no agent can obtain, and its answer is a read of the *real* Messages
        // scripting interface rather than anything the harness stands in for. Read-only: it sends
        // nothing, and the grant it provokes is the one IM-09's `send` would need.
        if CommandLine.arguments.contains(MessagesSendPathProbe.flag) {
            runIMessageSendPath()
            return
        }

        // NextNotes-iMessage IM-04a: the same shape, for the same reason. It needs a real
        // grant and a real Messages database, so it can never be a `--selftest-*` flag, and
        // it reads the owner's own history rather than a temp store, so it must run before
        // `runRequestedSelfTest` with `SelfTest.isRunning` still false.
        if CommandLine.arguments.contains(MessagesSelfFlowReport.flag) {
            runIMessageSelfFlow()
            return
        }

        // M-16a: the same shape, for the same reason. The quality report reads
        // the real `MeetingStore.shared`, which the harness must not touch and
        // should not be replaced under `SelfTest.isRunning` either — it exists
        // to read real meetings, so it runs before `runRequestedSelfTest` and
        // is a diagnostic, never a `--selftest-*` flag.
        if CommandLine.arguments.contains("--meeting-quality-report") {
            runMeetingQualityReport()
            return
        }

        // The same shape, for the same reason: `--avatar-sheet` reads the saved face and
        // draws every state with `ImageRenderer`, which needs no Screen Recording grant —
        // so the character can be reviewed by eye on a machine where the real UI cannot be
        // screenshotted at all.
        if CommandLine.arguments.contains("--avatar-sheet") {
            runAvatarSheet()
            return
        }

        // The same shape again, for the same reason: `--settings-sheet` renders every
        // Settings pane at the widths it meets, which is the only way to review a layout
        // fix by eye on a machine that cannot screenshot the real window.
        if CommandLine.arguments.contains("--settings-sheet") {
            runSettingsSheet()
            return
        }

        // Interactive, not a self-test: records real-room wake-phrase captures into the
        // LiveFixtures directory `--selftest-wake-live` grades. Returns before every other
        // subsystem, so no scheduler, wake monitor or agent starts behind the microphone.
        if WakeWordRoomRecorder.isRequested {
            WakeWordRoomRecorder.runAndExit()
            return
        }

        if runRequestedSelfTest() { return }

        // P0-03: a stored role can outlive the file it names. If the file the everyday
        // assistant is pointed at cannot answer on this Mac any more, repair it once here
        // and say so — never silently, and never more than once per (role, file).
        Task { @MainActor in
            _ = await ModelRoleStore.shared.repairUnanswerableRoles()
        }

        // Once per install, and never under the self-test harness: earlier builds let
        // `URLSession.shared` write model replies and account details into the on-disk URL
        // cache (G N4). This removes what is already there and records that it ran.
        _ = PrivateURLSession.purgeLegacyCache()

        // D-15a: retention is opt-in, and when it is on this is the one place it runs —
        // at launch, at most once a day (`pruneIfDue`'s own gate). `.forever` answers
        // before the file is read, so a machine that never opts in pays nothing, and a
        // self-test never reaches here because the harness returned above.
        let retention = Settings.shared.dictationHistoryRetention
        if retention != .forever {
            let pruned = RunLog.pruneIfDue(policy: retention)
            if pruned > 0 {
                Log.app.info("Dictation history · pruned \(pruned) old run(s) under the \(retention.rawValue) limit")
            }
        }

        // Dictation, the island and the menu bar must outlive an empty window list. Without
        // this, macOS 26's MenuBarExtra failure path ends in a voluntary exit (~1 s, no
        // crash report) once AppKit decides nothing is keeping the process open.
        ProcessInfo.processInfo.disableAutomaticTermination("Next Notes stays armed")

        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        installStatusItem()

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
        // D-06: one launch decision, one place. S1-mini loads only when it is the engine
        // a real hold would reach (grammar off — with it on, `CleanupRouter` routes every
        // cleanup to Apple, and 484 MB of residency behind that routing bought nothing);
        // Apple's model warms a few seconds after launch and again after every wake, at
        // `.utility`, never while a hold or a voice turn is running.
        AppleModelWarmth.dictation = controller
        let warmup = LaunchWarmup.plan(
            cleanupEnabled: Settings.shared.cleanupEnabled,
            choice: Settings.shared.cleanupEngine,
            fixesGrammar: Settings.shared.cleanupFixesGrammar,
            s1Downloaded: S1MiniModels.isDownloaded,
            appleAvailable: FoundationModelFormatter.isAvailable
        )
        if warmup.contains(.loadS1Mini) {
            LocalModelStore.shared.prepareS1Mini()
        }
        if warmup.contains(.warmApple) {
            warmObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in await AppleModelWarmth.warmProcess() }
            }
            // After the Parakeet prepare above, and at `.utility`: the warm-up must not
            // race the first hold, so it also skips itself from inside `warmProcess`.
            Task(priority: .utility) {
                try? await Task.sleep(for: .seconds(5))
                await AppleModelWarmth.warmProcess()
            }
        }

        // Setup tells the user their assistant is being fetched and that an unfinished
        // transfer will be picked up. This is what picks it up — only for a Mac that was
        // actually shown that screen, and never during a self-test.
        OnboardingModelResume.start()

        // Skills the user already has, from this app and from every other agent on this Mac.
        // A few hundred small files, read-only, off the main actor.
        Task { await SkillLibrary.shared.rescan() }

        // A meeting still marked as running was interrupted by a crash or a force-quit.
        // Repair plans each one at its stage rather than writing it off, and the resumer
        // below works the plan once launch settles. Runs before the scheduler starts:
        // it must not find a meeting that claims to be live.
        let resumePlan = MeetingStore.shared.repairInterruptedMeetings()
        if !SelfTest.isRunning {
            Task { @MainActor in
                await MeetingResumer(
                    store: .shared,
                    finalPass: { FinalTranscriptService.shared.process($0, store: .shared) },
                    afterTranscript: { _ = MeetingPipeline.afterFinalPass($0, store: .shared) },
                    diarize: { DiarizationService.shared.process($0) },
                    notes: { NotesService.shared.summarize($0, announce: true) },
                    isBusy: {
                        LiveKnowledgeIndexEnvironment.isForegroundBusy
                            || LiveKnowledgeIndexEnvironment.isVoiceBusy
                            || MeetingController.shared.isRecording
                    }
                ).resume(resumePlan)
            }
        }

        // Reading the calendar and acting on it are two jobs on purpose — the service only
        // ever answers "what is coming up", and the scheduler is the only thing that turns
        // an answer into a recording.
        CalendarService.shared.start()
        MeetingScheduler.shared.start()
        // After the scheduler, and for the same reason it comes after the store: the agent
        // registers a notification observer and the island's decision handler, and both of
        // those have to exist before a proposal from a previous session is delivered.
        AgentService.shared.start()
        // After the agent, because the watcher hands its proposals to the approval card the
        // agent's `start()` has just wired up, and a card raised before that handler exists
        // is a card whose buttons do nothing.
        FunctionCallWatcher.shared.start()
        // Composio is an MCP gateway: saving the key alone used to leave zero tools in the
        // registry. Refresh after the agent is up so meta-tools exist before the first ask.
        Task { @MainActor in
            guard ComposioProvider.isConfigured else { return }
            do {
                _ = try await ComposioProvider.connectAndRefresh()
            } catch {
                Log.agent.error("Composio refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Reminders start after the agent, for the same reason the agent starts after the
        // meeting scheduler: its notification observer must exist before a Snooze pressed
        // while the app was closed is delivered.
        AgentScheduler.shared.start()
        // P4-01: the front app is one of the block's facts, and nothing else in the app
        // observes `didActivateApplication` for it. Started after the agent because it reads
        // the agent's own frontmost check, and publishing once here means the first prompt of
        // the session already carries a correct block.
        AgentNowPublisher.startObserving()
        // Sessions end and are reviewed for memories in the background, never while recording.
        MemoryReviewScheduler.shared.start()
        // After the review scheduler: both hook the conversation, and the indexer only reads
        // what the review has already been handed. Does nothing until the index is turned on.
        KnowledgeIndexer.shared.start()
        // The file index watches the folders the user shared. Does nothing — and asks macOS
        // for nothing — until one has been added and the switch is on.
        if IndexedFoldersStore.shared.isEnabled {
            FileIndexer.shared.start()
            FileIndexer.shared.scanAll()
        }
        // Touch the registry so native tools exist before the first utterance, then arm
        // the agent shortcut. Wake-word audio is not started until the user turns it on.
        _ = AgentToolRegistry.shared
        NextMemory.shared.refreshFromActivity()
        ActivationController.shared.start()
        Task { await Notifications.shared.requestAuthorization() }

        observeState()
        observeMeetingBadge()
        // Bring the main window onto a real Space. Restored frames can land with a null
        // workspace id on a multi-display layout, which AppKit then treats as "no windows
        // open" — the other half of the silent-exit pair with MenuBarExtra.
        Self.showMainWindow()
        Log.app.info("Next Notes ready — hold \(Settings.shared.pushToTalkKey.displayName) to dictate")
    }

    /// Status and the hotkey while you're working in another app.
    ///
    /// Built as an AppKit status item rather than SwiftUI `MenuBarExtra` because on macOS 26
    /// MenuBarAgent can accept the client, log "No server elements for status item", and then
    /// invalidate the workspace — after which SwiftUI exits the process voluntarily. An
    /// `NSStatusItem` we own simply becomes invisible when the system hides it.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusItemImage(active: controller.state.isActive)
        item.menu = NSHostingMenu(rootView: MenuContent(controller: controller))
        statusItem = item
        observeStatusItemIcon()
    }

    private func observeStatusItemIcon() {
        withObservationTracking {
            _ = controller.state.isActive
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem?.button?.image = self.statusItemImage(active: self.controller.state.isActive)
                self.observeStatusItemIcon()
            }
        }
    }

    private func statusItemImage(active: Bool) -> NSImage? {
        let name = active ? "waveform.circle.fill" : "waveform"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Next Notes")
        image?.isTemplate = true
        return image
    }

    /// Model-only smoke tests that avoid microphone, Accessibility, and text injection.
    /// They make the two large local runtimes testable after installation and in support.
    private func runRequestedSelfTest() -> Bool {
        guard SelfTest.isRunning else { return false }
        startSelfTestWatchdog()
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--selftest-model-roles") {
            Task { @MainActor in
                let failures = await ModelRoleSelfTest.run()
                for failure in failures { SelfTest.diagnostic("model-roles · \(failure)") }
                writeSelfTest(failures.isEmpty
                    ? "MODEL_ROLES_OK: fallback, routing, call paths, discovery and tool-call bridging verified"
                    : "MODEL_ROLES_FAILED: \(failures.count) problem(s)")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-usage-log") {
            Task { @MainActor in
                // P0-20d's R1–R3 ride this flag's one marker: `UsageLogSelfTest`'s
                // `USAGE_LOG_OK` / `USAGE_LOG_FAILED` is the verdict, the summary cases
                // print as `USAGE_LOG_WRONG` lines, and a combined verdict is written
                // last when they fail.
                let coreOK = await UsageLogSelfTest.run()
                let summaryProblems = UsageSummarySelfTest.problems()
                for problem in summaryProblems { writeSelfTest("USAGE_LOG_WRONG: \(problem)") }
                if !summaryProblems.isEmpty {
                    writeSelfTest("USAGE_LOG_FAILED: \(summaryProblems.count) problem(s) in the summary cases")
                }
                SelfTest.failed = !coreOK || !summaryProblems.isEmpty
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-llm-prefix-cache") {
            Task { @MainActor in
                SelfTest.failed = !(await PrefixCacheSelfTest.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-chat-template") {
            Task { @MainActor in
                SelfTest.failed = !(await ChatTemplateSelfTest.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-store-isolation") {
            Task { @MainActor in
                writeSelfTest(await StoreIsolationSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-model-unopenable") {
            Task { @MainActor in
                SelfTest.failed = !(await ModelSupportSelfTest.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-agent-answers") {
            Task { @MainActor in
                SelfTest.failed = !(await AgentAnswersSelfTest.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-private-network") {
            Task { @MainActor in
                SelfTest.failed = !(await PrivateNetworkingSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-tool-review") {
            Task { @MainActor in
                SelfTest.failed = !(await ToolCallReviewSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-openrouter-contract") {
            SelfTest.failed = !OpenRouterContractSelfTest.run()
            writeSelfTest(SelfTest.failed ? "OPENROUTER_CONTRACT_FAILED" : "OPENROUTER_CONTRACT_OK")
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-openrouter") {
            Task { @MainActor in
                do {
                    let details = try await OpenRouterSelfTest.run()
                    writeSelfTest("OPENROUTER_OK: \(details)")
                } catch {
                    SelfTest.failed = true
                    writeSelfTest("OPENROUTER_FAILED: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-openrouter-speed") {
            Task { @MainActor in
                do {
                    let details = try await OpenRouterSpeedSelfTest.run()
                    writeSelfTest("OPENROUTER_SPEED_OK: \(details)")
                } catch {
                    SelfTest.failed = true
                    writeSelfTest("OPENROUTER_SPEED_FAILED: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
            return true
        }
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
        if arguments.contains("--selftest-acoustic-measure") {
            guard let path = SelfTest.value(after: "--selftest-acoustic-measure") else {
                SelfTest.failed = true
                writeSelfTest("ACOUSTIC_MEASURE_FAILED: supply a speech audio file path")
                NSApp.terminate(nil)
                return true
            }
            Task { @MainActor in
                do {
                    let result = try await AcousticEchoProbe.run(fileURL: URL(fileURLWithPath: path))
                    writeSelfTest("ACOUSTIC_MEASURE_OK: \(result)")
                } catch {
                    SelfTest.failed = true
                    writeSelfTest("ACOUSTIC_MEASURE_FAILED: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-systemaudio-timeout") {
            Task { @MainActor in
                SelfTest.failed = !(await SystemAudioCapture.runStartTimeoutSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-calendar") {
            runCalendarSelfTest()
            return true
        }
        if let path = SelfTest.value(after: "--selftest-transcribe") {
            runTranscribeSelfTest(path: path)
            return true
        }
        if let path = SelfTest.value(after: "--selftest-notes") {
            runNotesSelfTest(path: path, diarize: arguments.contains("--diarize"))
            return true
        }
        if arguments.contains("--selftest-notes-context") {
            runNotesContextSelfTest()
            return true
        }
        if arguments.contains("--selftest-llm-metal") {
            runMetalSelfTest()
            return true
        }
        if arguments.contains("--selftest-calls") {
            runCallsSelfTest()
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
        if let path = SelfTest.value(after: "--selftest-agent") {
            runAgentSelfTest(directory: path)
            return true
        }
        if arguments.contains("--selftest-cleanup") {
            runCleanupSelfTest(engine: SelfTest.value(after: "--selftest-cleanup") ?? "all")
            return true
        }
        if arguments.contains("--selftest-cleanup-router") {
            Task { @MainActor in
                // `SelfTest.failed`, not `_`. This branch is reached before the second
                // `--selftest-cleanup-router` block further down, so the discarded result was
                // the only one that ran: the flag reported every failure on stdout and still
                // exited 0, which is a green suite that never passed.
                SelfTest.failed = !(await CleanupRouter.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-cleanup-structure") {
            Task { @MainActor in
                SelfTest.failed = !SpokenStructure.runSelfTest()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-commandkey") {
            Task { @MainActor in
                SelfTest.failed = !(await CommandKeySelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-learn") {
            runLearnSelfTest()
            return true
        }
        if arguments.contains("--selftest-axreadback") {
            runAXReadbackSelfTest()
            return true
        }
        if arguments.contains("--selftest-context") {
            runScreenContextSelfTest(
                bundleID: SelfTest.value(after: "--selftest-context") ?? Self.defaultContextBundleID
            )
            return true
        }
        if arguments.contains("--selftest-dictation") {
            runDictationSelfTest()
            return true
        }
        if arguments.contains("--selftest-dictation-hygiene") {
            // D-15a/D-15b: the history file and the clipboard. No microphone, no grant and
            // no model — everything it touches is behind an injected directory or a private
            // pasteboard, which is why this is INTEGRATION rather than CORE.
            Task { @MainActor in
                let problems = await DictationHygieneSelfTest.run()
                for problem in problems { writeSelfTest("DICTATION_HYGIENE_WRONG: \(problem)") }
                writeSelfTest(problems.isEmpty
                    ? "DICTATION_HYGIENE_OK: history appends in memory, retention is opt-in, the clipboard survives"
                    : "DICTATION_HYGIENE_FAILED: \(problems.count) problem(s)")
                SelfTest.failed = !problems.isEmpty
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-tools") {
            runToolsSelfTest()
            return true
        }
        if arguments.contains("--selftest-action-runtime") {
            Task { @MainActor in
                let ok = await ActionOrchestrator.runSelfTest()
                writeSelfTest(ok ? "ACTION_RUNTIME_OK" : "ACTION_RUNTIME_FAILED: lifecycle")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-memory") {
            Task { @MainActor in
                SelfTest.failed = !(await MemorySelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-memory-review") {
            Task { @MainActor in
                SelfTest.failed = !(await MemoryReviewSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-memory-portability") {
            Task { @MainActor in
                SelfTest.failed = !(await MemoryPortabilitySelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-schedule") {
            Task { @MainActor in
                SelfTest.failed = !(await ScheduleSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-routine-authority") {
            Task { @MainActor in
                SelfTest.failed = !(await RoutineAuthoritySelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-digest") {
            Task { @MainActor in
                SelfTest.failed = !(await DigestSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-podcast") {
            Task { @MainActor in
                SelfTest.failed = !(await PodcastSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-guided") {
            Task { @MainActor in
                SelfTest.failed = !GuidedFirstSuccessSelfTest.run()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-ui-strings") {
            SelfTest.failed = !UIStringsLint.run()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-agent-panes") {
            Task { @MainActor in
                SelfTest.failed = !AgentPaneSelfTest.run()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-index") {
            Task { @MainActor in
                SelfTest.failed = !(await KnowledgeIndexSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-embed") {
            Task { @MainActor in
                SelfTest.failed = !(await KnowledgeEmbedSelfTest.run(text: SelfTest.value(after: "--selftest-embed")))
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-search") {
            Task { @MainActor in
                SelfTest.failed = !(await KnowledgeSearchSelfTest.run(query: SelfTest.value(after: "--selftest-search")))
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-ask") {
            Task { @MainActor in
                SelfTest.failed = !(await KnowledgeAskSelfTest.run(question: SelfTest.value(after: "--selftest-ask")))
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-extract") {
            Task { @MainActor in
                SelfTest.failed = !(await KnowledgeExtractSelfTest.run(path: SelfTest.value(after: "--selftest-extract")))
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-resolve") {
            Task { @MainActor in
                SelfTest.failed = !(await EntityResolveSelfTest.run(path: SelfTest.value(after: "--selftest-resolve")))
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-graph-layout") {
            Task { @MainActor in
                SelfTest.failed = !(await GraphLayoutSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-assemble") {
            Task { @MainActor in
                SelfTest.failed = !(await AssemblerSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-portrait") {
            Task { @MainActor in
                SelfTest.failed = !(await PortraitSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-file-index") {
            Task { @MainActor in
                SelfTest.failed = !(await FileIndexSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-persona") {
            Task { @MainActor in
                SelfTest.failed = !PersonaSelfTest.run()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-now-block") {
            Task { @MainActor in
                SelfTest.failed = !AgentNowSelfTest.runSelfTest()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-onboarding") {
            Task { @MainActor in
                SelfTest.failed = !OnboardingSelfTest.run()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-avatar") {
            Task { @MainActor in
                SelfTest.failed = !AgentAvatarSelfTest.run()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-skills") {
            Task { @MainActor in
                SelfTest.failed = !(await SkillsSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-wake") {
            runWakeSelfTest()
            return true
        }
        if arguments.contains("--selftest-wake-live") {
            Task { @MainActor in
                let result = WakeWordLiveSelfTest.run(
                    fixtureDirectory: SelfTest.value(after: "--selftest-wake-live")
                        .map { URL(fileURLWithPath: $0) }
                )
                SelfTest.failed = !result.passed
                for line in result.summary { writeSelfTest(line) }
                writeSelfTest(
                    result.passed
                        ? "WAKE_LIVE_OK: \(result.headline)"
                        : "WAKE_LIVE_FAILED: \(result.headline)"
                )
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-tasks") {
            runTasksSelfTest()
            return true
        }
        if arguments.contains("--selftest-meeting-context") {
            runMeetingContextSelfTest()
            return true
        }
        if arguments.contains("--selftest-realtime") {
            runRealtimeSelfTest()
            return true
        }
        if arguments.contains("--selftest-computer") {
            runComputerSelfTest()
            return true
        }
        if arguments.contains("--selftest-computer-vision") {
            SelfTest.failed = !ComputerVisionSelfTest.run()
            writeSelfTest(
                SelfTest.failed
                    ? "COMPUTER_VISION_FAILED"
                    : "COMPUTER_VISION_OK: stub-gated screenshots, consent gate, pixel budget and one-retry policy verified"
            )
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-computer-actions") {
            Task { @MainActor in
                let ok = ComputerActionsSelfTest.run()
                SelfTest.failed = !ok
                writeSelfTest(
                    ok
                        ? "COMPUTER_ACTIONS_OK: scroll moved the text view both ways, double_click selected a word, "
                            + "wait_for found its text and timed out honestly, and drag and right_click reported what they could not verify"
                        : "COMPUTER_ACTIONS_FAILED"
                )
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-click-coordinate") {
            Task { @MainActor in
                let ok = ClickCoordinateSelfTest.run()
                SelfTest.failed = !ok
                writeSelfTest(
                    ok
                        ? "CLICK_COORDINATE_OK: the fraction grammar refused out-of-range and missing values, the element id "
                            + "outranked the coordinate, and the target-line parser held against canned completions"
                        : "CLICK_COORDINATE_FAILED"
                )
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-computer-yield") {
            Task { @MainActor in
                // P1-23. The live half needs the Accessibility grant, which a shell-launched
                // run is denied (AGENTS.md: TCC keys a grant to the responsible process), so
                // this is a `via-open` flag like `--selftest-computer-actions`. The grant-free
                // half is what INTEGRATION runs, and it is here too so one flag answers both
                // questions rather than printing a half-answer.
                let free = ComputerYieldSelfTest.grantFreeFailures()
                guard free.isEmpty else {
                    ComputerYieldSelfTest.report(free, marker: "unused")
                    SelfTest.failed = true
                    NSApp.terminate(nil)
                    return
                }
                let live = await ComputerYieldLiveSelfTest.run()
                let all = free + live
                if all.isEmpty {
                    // Broken up rather than one nested ternary: the type checker gives up on the
                    // combined string, and a self-test flag that does not compile is a flag
                    // nobody runs.
                    var summary = "COMPUTER_YIELD_OK: \(ComputerYieldSelfTest.grantFreeCount) "
                        + "grant-free cases, and "
                    if live.isEmpty {
                        summary += "the live half was not run (no Accessibility grant)"
                    } else {
                        let ms = ComputerYieldLiveSelfTest.lastLatencyMilliseconds
                        summary += "\(live.count) live cases; yield latency \(ms) ms"
                    }
                    writeSelfTest(summary)
                } else {
                    ComputerYieldSelfTest.report(all, marker: "unused")
                    SelfTest.failed = true
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-seat-grid") {
            Task { @MainActor in
                let ok = SeatGridSelfTest.run()
                SelfTest.failed = !ok
                writeSelfTest(
                    ok
                        ? "SEAT_GRID_OK: snapshot, screenshot gate, click retry, cap check, consent block and receipt verified"
                        : "SEAT_GRID_FAILED"
                )
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-mcp") {
            runMCPSelfTest()
            return true
        }
        if arguments.contains("--selftest-composio") {
            runComposioSelfTest()
            return true
        }
        if arguments.contains("--selftest-acp") {
            runACPSelfTest()
            return true
        }
        if arguments.contains("--selftest-acp-live") {
            runACPProviderSelfTest()
            return true
        }
        if arguments.contains("--selftest-activity") {
            runActivitySelfTest()
            return true
        }
        if arguments.contains("--selftest-fs") {
            runFilesystemSelfTest()
            return true
        }
        if arguments.contains("--selftest-browser") {
            runBrowserSelfTest()
            return true
        }
        if arguments.contains("--selftest-cdp") {
            // P2-A: CDP end to end against a real Chromium binary. No TCC grant is
            // involved — the browser is launched headless on an ephemeral port with a
            // temp profile, so the only thing the test can fail on is the thing it
            // names: the debugger answering, the snapshot coming back, the page being
            // read, and a wait that must both succeed and time out honestly.
            Task { @MainActor in
            var failures: [String] = []
            // The name of a `check` here is the **failure description**, not the pass. So
            // "no row recorded that a card was shown" is passed `titles.contains("Approval asked")`
            // — false is the failure. P1-29's first draft had three of its four assertions
            // backwards against this convention and reported a leak, a miscount and a
            // wrong-answer that had not happened; the code was right and the test was lying.
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }
                do {
                    for (id, risk) in [
                        ("browser.cdp_status", AgentRisk.observe),
                        ("browser.relaunch_debug", AgentRisk.modify),
                        ("browser.read_page", AgentRisk.observe),
                        ("browser.wait", AgentRisk.observe),
                    ] {
                        guard let tool = AgentToolRegistry.shared.tool(named: id) else {
                            check("\(id) is not registered", false)
                            continue
                        }
                        check("\(id) registered with the wrong risk (\(tool.risk.rawValue))", tool.risk == risk)
                    }

                    guard let browser = DebugBrowser.installed() else {
                        SelfTest.failed = true
                        writeSelfTest("CDP_ABSENT: no Chromium-family browser installed")
                        NSApp.terminate(nil)
                        return
                    }
                    let marker = "CDP-SELFTEST-MARKER-9182"
                    let tempRoot = FileManager.default.temporaryDirectory
                        .appendingPathComponent("nextnotes-cdp-selftest-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: tempRoot) }
                    let fixture = tempRoot.appendingPathComponent("cdp-fixture.html")
                    try """
                        <!doctype html>
                        <html><head><title>CDP fixture page</title></head>
                        <body><h1>CDP fixture heading</h1><p>Marker: \(marker)</p>
                        <button>OK</button></body></html>
                        """.write(to: fixture, atomically: true, encoding: .utf8)
                    func freePort() -> Int? {
                        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                        guard fd >= 0 else { return nil }
                        defer { close(fd) }
                        var address = sockaddr_in()
                        address.sin_family = sa_family_t(AF_INET)
                        address.sin_port = 0
                        address.sin_addr = in_addr(s_addr: INADDR_ANY)
                        let bound = withUnsafePointer(to: &address) { pointer in
                            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                        guard bound == 0, listen(fd, 1) == 0 else { return nil }
                        var boundAddress = sockaddr_in()
                        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                getsockname(fd, $0, &length)
                            }
                        }
                        guard named == 0 else { return nil }
                        return Int(UInt16(bigEndian: boundAddress.sin_port))
                    }
                    guard let port = freePort() else {
                        throw NSError(
                            domain: "CDPSelfTest", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "no ephemeral port could be bound"]
                        )
                    }
                    let process = try DebugBrowser.launch(browser.url, arguments: [
                        "--headless=new",
                        "--remote-debugging-port=\(port)",
                        "--user-data-dir=\(tempRoot.appendingPathComponent("profile", isDirectory: true).path)",
                        "--no-first-run",
                        "--no-default-browser-check",
                        fixture.absoluteString,
                    ])
                    defer {
                        if process.isRunning { process.terminate() }
                        let deadline = Date().addingTimeInterval(5)
                        while process.isRunning && Date() < deadline {
                            usleep(100_000)
                        }
                        if process.isRunning {
                            Darwin.kill(process.processIdentifier, SIGKILL)
                        }
                    }
                    var probe: BrowserCDPClient.Probe?
                    let deadline = Date().addingTimeInterval(25)
                    while probe == nil && Date() < deadline {
                        probe = await BrowserCDPClient.probe(host: "127.0.0.1", port: port)
                        if probe == nil { try? await Task.sleep(for: .milliseconds(250)) }
                    }
                    guard let probe else {
                        throw NSError(
                            domain: "CDPSelfTest", code: 2,
                            userInfo: [NSLocalizedDescriptionKey:
                                "the headless debugger never answered on port \(port)"]
                        )
                    }
                    check(
                        "probe reported no browser",
                        probe.browser.isEmpty == false
                    )
                    let targets = try await BrowserCDPClient.listTargets(
                        baseURL: URL(string: "http://127.0.0.1:\(port)")!
                    )
                    guard let fixtureTarget = targets.first(where: {
                        $0.url.contains("cdp-fixture.html")
                    }) else {
                        throw NSError(
                            domain: "CDPSelfTest", code: 3,
                            userInfo: [NSLocalizedDescriptionKey:
                                "the target list never advertised the fixture page "
                                + "(saw \(targets.map(\.url).joined(separator: ", ")))"]
                        )
                    }
                    check(
                        "the fixture tab was not in the probe",
                        probe.targets.contains { $0.id == fixtureTarget.id }
                    )
                    let snapshot = try await BrowserCDPClient.run(
                        AgentToolRegistry.shared.tool(named: "browser.snapshot")!,
                        arguments: ["targetId": fixtureTarget.id],
                        host: "127.0.0.1",
                        port: port
                    )
                    check(
                        "the CDP snapshot did not name the fixture tab",
                        snapshot.summary.contains("CDP targetId:")
                            && snapshot.summary.contains("cdp-fixture.html")
                            && snapshot.summary.contains("DOM:")
                    )
                    let read = try await BrowserCDPClient.run(
                        AgentToolRegistry.shared.tool(named: "browser.read_page")!,
                        arguments: ["targetId": fixtureTarget.id],
                        host: "127.0.0.1",
                        port: port
                    )
                    check(
                        "read_page did not return the marker text",
                        read.summary.contains(marker)
                    )
                    check(
                        "read_page did not return the fixture title",
                        read.summary.contains("CDP fixture page")
                    )
                    let waited = try await BrowserCDPClient.run(
                        AgentToolRegistry.shared.tool(named: "browser.wait")!,
                        arguments: [
                            "expectedURL": "cdp-fixture.html",
                            "targetId": fixtureTarget.id,
                        ],
                        host: "127.0.0.1",
                        port: port
                    )
                    check(
                        "wait claimed nothing about a URL that was already there",
                        waited.verification != nil
                            && waited.summary.contains(fixtureTarget.id)
                    )
                    let impossibleAt = Date()
                    do {
                        let impossible = try await BrowserCDPClient.run(
                            AgentToolRegistry.shared.tool(named: "browser.wait")!,
                            arguments: [
                                "expectedURL": "never-appears-cdp-selftest",
                                "timeoutSeconds": "2",
                                "targetId": fixtureTarget.id,
                            ],
                            host: "127.0.0.1",
                            port: port
                        )
                        let took = Date().timeIntervalSince(impossibleAt)
                        check(
                            "an impossible wait claimed success",
                            impossible.verification == nil
                                && impossible.summary.contains("never-appears-cdp-selftest")
                        )
                        check(
                            "the impossible wait gave up in \(String(format: "%.1f", took))s instead of roughly its 2s timeout",
                            took >= 1.5 && took < 8
                        )
                    } catch {
                        failures.append(
                            "the impossible wait threw instead of reporting honestly: "
                                + error.localizedDescription
                        )
                    }
                } catch {
                    failures.append(error.localizedDescription)
                }
                for failure in failures { writeSelfTest("  CDP_WRONG: \(failure)") }
                writeSelfTest(failures.isEmpty
                              ? "CDP_OK: real Chromium debugger answered targets, snapshot, read_page, "
                                  + "a waited URL and an honest timeout"
                              : "CDP_FAILED: \(failures.count) leg(s) wrong")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-settings") {
            runSettingsSelfTest()
            return true
        }
        if arguments.contains("--selftest-metrics") {
            SelfTest.failed = !LatencyTrace.runSelfTest()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-meeting-quality") {
            let failures = MeetingQualityProbe.runSelfTest()
            for failure in failures { writeSelfTest("MEETING_QUALITY_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                ? "MEETING_QUALITY_OK"
                : "MEETING_QUALITY_FAILED: \(failures.count) check(s) wrong")
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-notes-longform") {
            runNotesLongformSelfTest()
            return true
        }
        if arguments.contains("--selftest-notes-truncation") {
            runNotesTruncationSelfTest()
            return true
        }
        if arguments.contains("--selftest-meeting-finals") {
            runMeetingFinalsSelfTest()
            return true
        }
        if arguments.contains("--selftest-meeting-resume") {
            runMeetingResumeSelfTest()
            return true
        }
        if arguments.contains("--selftest-meeting-backlog") {
            runMeetingBacklogSelfTest()
            return true
        }
        if arguments.contains("--selftest-meeting-tap-retry") {
            runMeetingTapRetrySelfTest()
            return true
        }
        if arguments.contains("--selftest-audio-retention") {
            runAudioRetentionSelfTest()
            return true
        }
        if arguments.contains("--selftest-meeting-scratchpad") {
            Task { @MainActor in
                SelfTest.failed = !MeetingScratchpadSelfTest.run()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-meeting-tidier") {
            Task { @MainActor in
                SelfTest.failed = !MeetingScratchpadTidierSelfTest.run()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-meeting-recall") {
            Task { @MainActor in
                SelfTest.failed = !(await MeetingRecallSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-meeting-console") {
            Task { @MainActor in
                SelfTest.failed = !MeetingConsoleSelfTest.run()
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-diarize-assign") {
            let failures = DiarizeAssignSelfTest.run { writeSelfTest($0) }
            for failure in failures { writeSelfTest("DIARIZE_ASSIGN_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                ? "DIARIZE_ASSIGN_OK"
                : "DIARIZE_ASSIGN_FAILED: \(failures.count) check(s) wrong")
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-diarize-hints") {
            Task { @MainActor in
                let failures = await DiarizeHintsSelfTest.run { writeSelfTest($0) }
                for failure in failures { writeSelfTest("DIARIZE_HINTS_WRONG: \(failure)") }
                writeSelfTest(failures.isEmpty
                    ? "DIARIZE_HINTS_OK"
                    : "DIARIZE_HINTS_FAILED: \(failures.count) check(s) wrong")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-cleanup-router") {
            Task { @MainActor in
                SelfTest.failed = !(await CleanupRouter.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-meeting-live") {
            SelfTest.failed = !MeetingLiveAgent.runSelfTest()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-meeting-live-tools") {
            Task { @MainActor in
                SelfTest.failed = !(await MeetingLiveToolSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-tts") {
            SelfTest.failed = !AgentSpeechPolicy.runSelfTest()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-tts-stream") {
            SelfTest.failed = !AgentSpeechPolicy.runStreamSelfTest()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-tts-pocket") {
            Task { @MainActor in
                SelfTest.failed = !(await PocketAgentVoice.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-tts-kokoro") {
            Task { @MainActor in
                SelfTest.failed = !(await KokoroAgentVoice.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-local-model-stream") {
            Task { @MainActor in
                SelfTest.failed = !(await RealtimeAgentLocalModelSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-toolloop") {
            Task { @MainActor in
                SelfTest.failed = !(await AgentToolLoop.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-concurrent-voice") {
            Task { @MainActor in
                SelfTest.failed = !(await ConcurrentVoiceSelfTest.run())
                writeSelfTest(SelfTest.failed ? "CONCURRENT_VOICE_FAILED" : "CONCURRENT_VOICE_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-prompt-probe") {
            Task { @MainActor in
                SelfTest.failed = !(await LocalVoicePromptProbe.run())
                writeSelfTest(SelfTest.failed ? "VOICE_PROMPT_PROBE_FAILED" : "VOICE_PROMPT_PROBE_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-capabilities")
            || arguments.contains("--selftest-voice-capabilities-live") {
            Task { @MainActor in
                let live = arguments.contains("--selftest-voice-capabilities-live")
                let passed = live
                    ? await VoiceCapabilityConversationSelfTest.runLive()
                    : await VoiceCapabilityConversationSelfTest.run()
                SelfTest.failed = SelfTest.failed || !passed
                writeSelfTest(SelfTest.failed ? "VOICE_CAPABILITIES_FAILED" : "VOICE_CAPABILITIES_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-speculation") {
            Task { @MainActor in
                SelfTest.failed = !(await LocalVoiceFrontendSpeculationSelfTest.run())
                writeSelfTest(SelfTest.failed ? "VOICE_SPECULATION_FAILED" : "VOICE_SPECULATION_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-tts-pocket-session") {
            Task { @MainActor in
                SelfTest.failed = !(await PocketTtsSessionSelfTest.run())
                writeSelfTest(SelfTest.failed ? "POCKET_SESSION_FAILED" : "POCKET_SESSION_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-rapid") {
            Task { @MainActor in
                let args = CommandLine.arguments
                guard let index = args.firstIndex(of: "--selftest-voice-rapid"),
                      index + 2 < args.count,
                      !args[index + 1].hasPrefix("--"), !args[index + 2].hasPrefix("--") else {
                    SelfTest.failed = true
                    writeSelfTest("VOICE_RAPID_FAILED: first and second WAV paths required")
                    NSApp.terminate(nil)
                    return
                }
                let failures = await AgentCaptureController.runVoiceRapidTurnsSelfTest(
                    first: URL(fileURLWithPath: args[index + 1]),
                    second: URL(fileURLWithPath: args[index + 2]))
                for failure in failures { writeSelfTest("VOICE_RAPID_WRONG: \(failure)") }
                SelfTest.failed = !failures.isEmpty
                writeSelfTest(SelfTest.failed ? "VOICE_RAPID_FAILED" : "VOICE_RAPID_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-pcm-reconfiguration") {
            Task { @MainActor in
                let passed = await AgentPCMRenderer.runConfigurationRecoverySelfTest()
                SelfTest.failed = SelfTest.failed || !passed
                writeSelfTest(SelfTest.failed ? "PCM_RECONFIGURATION_FAILED" : "PCM_RECONFIGURATION_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-pcm-callback") {
            Task { @MainActor in
                SelfTest.failed = !(await AgentPCMRenderer.runReverseCallbackIsolationSelfTest())
                writeSelfTest(SelfTest.failed ? "PCM_CALLBACK_FAILED" : "PCM_CALLBACK_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-pcm-source") {
            Task { @MainActor in
                guard let path = SelfTest.value(after: "--selftest-pcm-source") else {
                    SelfTest.failed = true
                    writeSelfTest("PCM_SOURCE_FAILED: far speech WAV required")
                    NSApp.terminate(nil)
                    return
                }
                let result = await AgentPCMSourceProbe.run(farURL: URL(fileURLWithPath: path))
                SelfTest.failed = !result.0
                writeSelfTest(result.1)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-acoustic-hybrid") {
            Task { @MainActor in
                guard let path = SelfTest.value(after: "--selftest-acoustic-hybrid") else {
                    SelfTest.failed = true
                    writeSelfTest("ECHO_HYBRID_FAILED: near speech WAV required")
                    NSApp.terminate(nil)
                    return
                }
                let result = await AcousticHybridProbe.run(voice: "selected", nearURL: URL(fileURLWithPath: path))
                SelfTest.failed = !result.0
                writeSelfTest(result.1)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-suspend") {
            Task { @MainActor in
                let failures = AgentSpeechSynthesizer.runSuspendSelfTest()
                for failure in failures { writeSelfTest("VOICE_SUSPEND_WRONG: \(failure)") }
                SelfTest.failed = !failures.isEmpty
                writeSelfTest(SelfTest.failed ? "VOICE_SUSPEND_FAILED" : "VOICE_SUSPEND_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-suspend-live") {
            Task { @MainActor in
                let result = await AgentSpeechSynthesizer.runLiveSuspendSelfTest()
                SelfTest.failed = !result.0
                writeSelfTest(result.1)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-acoustic-int16") || arguments.contains("--selftest-acoustic-cold") {
            Task { @MainActor in
                let cold = arguments.contains("--selftest-acoustic-cold")
                let flag = cold ? "--selftest-acoustic-cold" : "--selftest-acoustic-int16"
                guard let path = SelfTest.value(after: flag) else {
                    SelfTest.failed = true
                    writeSelfTest("ECHO_INT16_FAILED: far WAV path required")
                    NSApp.terminate(nil)
                    return
                }
                let result = cold
                    ? AcousticEchoProcessor.runColdFarOnlySelfTest(farURL: URL(fileURLWithPath: path))
                    : AcousticEchoProcessor.runInt16ReplaySelfTest(farURL: URL(fileURLWithPath: path))
                SelfTest.failed = !result.0
                writeSelfTest(result.1)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-acoustic-live") {
            Task { @MainActor in
                let result = await AcousticLiveProbe.run(
                    voice: SelfTest.value(after: "--selftest-acoustic-live") ?? "selected")
                SelfTest.failed = !result.0
                writeSelfTest(result.1)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-acoustic-speech") || arguments.contains("--selftest-acoustic-early")
            || arguments.contains("--selftest-acoustic-speech-tail")
            || arguments.contains("--selftest-acoustic-aec3-speech") {
            Task { @MainActor in
                let args = CommandLine.arguments
                let early = args.contains("--selftest-acoustic-early")
                let tail = args.contains("--selftest-acoustic-speech-tail")
                let aec3 = args.contains("--selftest-acoustic-aec3-speech")
                let flag = aec3 ? "--selftest-acoustic-aec3-speech" : tail ? "--selftest-acoustic-speech-tail"
                    : (early ? "--selftest-acoustic-early" : "--selftest-acoustic-speech")
                guard let index = args.firstIndex(of: flag), index + 2 < args.count,
                      !args[index + 1].hasPrefix("--"), !args[index + 2].hasPrefix("--") else {
                    SelfTest.failed = true
                    writeSelfTest("ECHO_SPEECH_FAILED: far and near WAV paths required")
                    NSApp.terminate(nil)
                    return
                }
                let far = URL(fileURLWithPath: args[index + 1])
                let near = URL(fileURLWithPath: args[index + 2])
                let result = aec3
                    ? AcousticEchoProcessor.runAEC3SpeechReplaySelfTest(farURL: far, nearURL: near)
                    : (tail
                        ? AcousticEchoProcessor.runSpeechTailSelfTest(farURL: far, nearURL: near)
                        : (early
                        ? AcousticEchoProcessor.runEarlyDoubleTalkSelfTest(farURL: far, nearURL: near)
                        : AcousticEchoProcessor.runSpeechReplaySelfTest(farURL: far, nearURL: near)))
                SelfTest.failed = !result.0
                writeSelfTest(result.1)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-echo-live") {
            Task { @MainActor in
                let result = await VoiceEchoLiveProbe.run()
                SelfTest.failed = SelfTest.failed || !result.0
                writeSelfTest(result.1)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-frontend") {
            Task { @MainActor in
                SelfTest.failed = !(await LocalVoiceFrontendSelfTest.run())
                writeSelfTest(SelfTest.failed ? "VOICE_FRONTEND_FAILED" : "VOICE_FRONTEND_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-barge") {
            Task { @MainActor in
                guard let path = SelfTest.value(after: "--selftest-voice-barge") else {
                    SelfTest.failed = true
                    writeSelfTest("VOICE_BARGE_FAILED: WAV path required")
                    NSApp.terminate(nil)
                    return
                }
                let failures = await AgentCaptureController.runVoiceBargeSelfTest(
                    wav: URL(fileURLWithPath: path),
                    appleFastResults: !arguments.contains("--voice-apple-standard"))
                for failure in failures { writeSelfTest("VOICE_BARGE_WRONG: \(failure)") }
                SelfTest.failed = SelfTest.failed || !failures.isEmpty
                writeSelfTest(SelfTest.failed ? "VOICE_BARGE_FAILED" : "VOICE_BARGE_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-pipeline") {
            Task { @MainActor in
                guard let path = SelfTest.value(after: "--selftest-voice-pipeline") else {
                    SelfTest.failed = true
                    writeSelfTest("VOICE_PIPELINE_FAILED: WAV path required")
                    NSApp.terminate(nil)
                    return
                }
                let failures = await AgentCaptureController.runVoicePipelineSelfTest(
                    wav: URL(fileURLWithPath: path),
                    appleFastResults: !arguments.contains("--voice-apple-standard"))
                for failure in failures { writeSelfTest("VOICE_PIPELINE_WRONG: \(failure)") }
                SelfTest.failed = SelfTest.failed || !failures.isEmpty
                writeSelfTest(SelfTest.failed ? "VOICE_PIPELINE_FAILED" : "VOICE_PIPELINE_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-latency") {
            Task { @MainActor in
                // P2-01. The marker is the run's own verdict, including the ABSENT form, so
                // the acceptance runner can classify a missing precondition as a skip
                // without reading anything else.
                let result = await VoiceLatencySelfTest.run()
                SelfTest.failed = SelfTest.failed || !result.ok
                writeSelfTest(result.marker)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-eou") {
            Task { @MainActor in
                guard let path = SelfTest.value(after: "--selftest-voice-eou") else {
                    SelfTest.failed = true
                    writeSelfTest("VOICE_EOU_FAILED: WAV path required")
                    NSApp.terminate(nil)
                    return
                }
                let failures = await LocalVoiceTurnDetector.selfTest(wav: URL(fileURLWithPath: path))
                for failure in failures { writeSelfTest("VOICE_EOU_WRONG: \(failure)") }
                SelfTest.failed = !failures.isEmpty
                writeSelfTest(SelfTest.failed ? "VOICE_EOU_FAILED" : "VOICE_EOU_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-acoustic-tail") {
            Task { @MainActor in
                let result = AcousticEchoProcessor.runStopTailSelfTest()
                SelfTest.failed = !result.0
                writeSelfTest(result.1)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-acoustic-replay") {
            Task { @MainActor in
                let result = AcousticEchoProcessor.runReplaySelfTest()
                SelfTest.failed = !result.0
                writeSelfTest(result.1)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-conversation") {
            Task { @MainActor in
                SelfTest.failed = !(await VoiceConversationSelfTest.run())
                if SelfTest.outputPath != nil {
                    writeSelfTest(SelfTest.failed ? "VOICE_CONVERSATION_FAILED" : "VOICE_CONVERSATION_OK")
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-work-lifecycle") {
            Task { @MainActor in
                SelfTest.failed = !(await VoiceWorkLifecycleSelfTest.run())
                if SelfTest.outputPath != nil {
                    writeSelfTest(SelfTest.failed ? "VOICE_WORK_LIFECYCLE_FAILED" : "VOICE_WORK_LIFECYCLE_OK")
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-delivery") {
            Task { @MainActor in
                SelfTest.failed = !(await VoiceDeliverySelfTest.run())
                if SelfTest.outputPath != nil {
                    writeSelfTest(SelfTest.failed ? "VOICE_DELIVERY_FAILED" : "VOICE_DELIVERY_OK")
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-turns") {
            Task { @MainActor in
                var failures = AgentCaptureController.turnPolicySelfTestFailures()
                failures += await AgentCaptureController.overlappingBackchannelSelfTestFailures()
                failures += await AgentCaptureController.reversibleListeningSelfTestFailures()
                failures += await AgentCaptureController.disownSelfTestFailures()
                for failure in failures { print("VOICE_TURNS_WRONG: \(failure)") }
                SelfTest.failed = !failures.isEmpty
                writeSelfTest(failures.isEmpty ? "VOICE_TURNS_OK" : "VOICE_TURNS_FAILED")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-turn-routing") {
            Task { @MainActor in
                SelfTest.failed = !(await VoiceCapabilityConversationSelfTest.runTurnRouting())
                writeSelfTest(SelfTest.failed ? "VOICE_TURN_ROUTING_FAILED" : "VOICE_TURN_ROUTING_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-playback-ledger") {
            Task { @MainActor in
                let failures = AgentSpeechSynthesizer.runPlaybackLedgerSelfTest()
                for failure in failures { print("PLAYBACK_LEDGER_WRONG: \(failure)") }
                SelfTest.failed = !failures.isEmpty
                writeSelfTest(failures.isEmpty ? "PLAYBACK_LEDGER_OK" : "PLAYBACK_LEDGER_FAILED")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-scheduling") {
            Task { @MainActor in
                SelfTest.failed = !(await NotesModelRuntime.conversationSchedulingSelfTest())
                writeSelfTest(SelfTest.failed ? "VOICE_SCHEDULING_FAILED" : "VOICE_SCHEDULING_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-local") {
            Task { @MainActor in
                SelfTest.failed = !(await VoiceConversationSelfTest.runLocalBenchmark())
                if SelfTest.outputPath != nil {
                    writeSelfTest(SelfTest.failed ? "VOICE_LOCAL_FAILED" : "VOICE_LOCAL_OK")
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-toolloop-production") {
            Task { @MainActor in
                SelfTest.failed = !(await RealtimeAgentToolLoopSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-toolloop-live-grader") {
            Task { @MainActor in
                SelfTest.failed = !LiveEvalGrader.runSelfTest()
                writeSelfTest(SelfTest.failed
                    ? "TOOLLOOP_LIVE_GRADER_FAILED"
                    : "TOOLLOOP_LIVE_GRADER_OK")
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-toolloop-live") {
            Task { @MainActor in
                SelfTest.failed = !(await ToolLoopLiveEval.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-native-tools") {
            Task { @MainActor in
                SelfTest.failed = !(await NativeToolsSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-capability-manifest") {
            Task { @MainActor in
                SelfTest.failed = !(await AgentCapabilityManifestSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-voice-grounding") {
            Task { @MainActor in
                SelfTest.failed = !(await RealtimeAgentToolLoopSelfTest.runVoiceGrounding())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-tool-awareness") {
            Task { @MainActor in
                SelfTest.failed = !(await RealtimeAgentToolLoopSelfTest.runToolAwareness())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-acp-confirm") {
            SelfTest.failed = !ACPConfirmation.runSelfTest()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-scheduler") {
            Task { @MainActor in
                SelfTest.failed = !(await ComputeScheduler.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-capture") {
            Task { @MainActor in
                SelfTest.failed = !(await AudioCaptureHub.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-microphone") || arguments.contains("--selftest-microphone-sink") {
            Task { @MainActor in
                let (passed, report) = await AudioCaptureHub.runLiveMicrophoneSelfTest()
                SelfTest.failed = !passed
                writeSelfTest(report)
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-meeting-reconcile") {
            SelfTest.failed = !MeetingActionReconciler.runSelfTest()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-meeting-reconcile-llm") {
            SelfTest.failed = !MeetingContextReconciler.runSelfTest()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-stream") {
            SelfTest.failed = !StreamingASR.runSelfTest()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-model-fit") {
            Task { @MainActor in
                SelfTest.failed = !(await ModelLibrarySelfTests.runModelFitSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-hf-search") {
            Task { @MainActor in
                SelfTest.failed = !(await ModelLibrarySelfTests.runSearchSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-model-library") {
            SelfTest.failed = !ModelLibrarySelfTests.runModelLibrarySelfTest()
            NSApp.terminate(nil)
            return true
        }
        if arguments.contains("--selftest-transcript-bus") {
            Task { @MainActor in
                SelfTest.failed = !(await TranscriptBus.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-function-calls") {
            Task { @MainActor in
                SelfTest.failed = !(await FunctionCallSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-duplex") {
            Task { @MainActor in
                SelfTest.failed = !(await RealtimeAudioSession.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-contention") {
            Task { @MainActor in
                SelfTest.failed = !(await ContentionSelfTests.runSelfTest())
                NSApp.terminate(nil)
            }
            return true
        }
        if arguments.contains("--selftest-residency") {
            Task { @MainActor in
                SelfTest.failed = !(await ModelResidencyPolicy.runSelfTest())
                NSApp.terminate(nil)
            }
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
                    // D-04: 0.2 s of audio must transcribe, not throw the model's
                    // 0.3 s floor. Prefers the fixture's first 0.2 s; silence
                    // still exercises the padding. Needs the model on disk like
                    // the inference above; an absent model keeps that failure.
                    let shortSamples = parakeetShortFixtureSamples(count: 3_200)
                        ?? [Float](repeating: 0, count: 3_200)
                    let shortEngine = ParakeetEngine()
                    let shortStream = try await shortEngine.start()
                    let shortConsumer = Task { () throws -> String? in
                        var final: String?
                        for try await chunk in shortStream {
                            if chunk.isFinal { final = chunk.text }
                        }
                        return final
                    }
                    if let shortFormat = await shortEngine.preferredInputFormat(),
                       let shortBuffer = AVAudioPCMBuffer(
                           pcmFormat: shortFormat,
                           frameCapacity: AVAudioFrameCount(shortSamples.count)) {
                        shortBuffer.frameLength = AVAudioFrameCount(shortSamples.count)
                        if let channel = shortBuffer.floatChannelData?.pointee {
                            for (index, sample) in shortSamples.enumerated() {
                                channel[index] = sample
                            }
                        }
                        await shortEngine.feed(AudioChunk(buffer: shortBuffer))
                    }
                    await shortEngine.finish()
                    let shortText = (try await shortConsumer.value) ?? ""
                    writeSelfTest("PARAKEET_SHORT: \(shortText.isEmpty ? "empty" : shortText)")
                    writeSelfTest("PARAKEET_OK: inference completed (\(result.text))")
                } catch {
                    writeSelfTest("PARAKEET_FAILED: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
            return true
        }

        // NextNotes-iMessage IM-04: a read-only chat.db. No TCC grant required — it runs
        // entirely against the sanitised fixtures in Tests/Fixtures/chatdb/, which is why it
        // is not a `via-open` entry. IM-04a adds the FDA probe cases to the same flag.
        if arguments.contains("--selftest-imessage-db") {
            Task { @MainActor in
                writeSelfTest(await MessagesDatabaseSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }

        // NextNotes-iMessage IM-05: the `attributedBody` decoder. Runs against the same
        // generated fixtures — and the corpus holds no real typedstream yet, so the
        // decode-identically assertion is reported as blocked on IM-01 rather than faked.
        if arguments.contains("--selftest-imessage-decode") {
            Task { @MainActor in
                writeSelfTest(await MessagesDecoderSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }

        // NextNotes-iMessage IM-08a: the classification, as a pure function. No grant, no
        // pairing, no model and no store — it decides what a turn *is*, which is the one
        // decision the whole remote path rests on and the one worth pinning on its own.
        if arguments.contains("--selftest-imessage-class") {
            Task { @MainActor in
                writeSelfTest(await MessagesClassSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }

        // NextNotes-iMessage IM-08b: the outbound ledger, and the breaker that stops a
        // message Next Notes itself sent from coming back as a command. CORE, because
        // replying to yourself is the failure the whole ledger exists to prevent.
        if arguments.contains("--selftest-imessage-loop") {
            Task { @MainActor in
                writeSelfTest(await MessagesLedgerSelfTest.run())
                NSApp.terminate(nil)
            }
            return true
        }

        // NextNotes-iMessage IM-06: the WAL watcher. Every case runs against a fixture copy
        // of chat.db, so no live database and no grant — it is CORE because it is the one
        // flag that proves the watcher is event-driven rather than a poll.
        if arguments.contains("--selftest-imessage-watch") {
            Task { @MainActor in
                writeSelfTest(await MessagesWatcherSelfTest.run())
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
    /// `--selftest-cleanup rules|apple|apple-grammar|s1|chain|app-llm|all`. The first case a
    /// model-backed formatter sees pays its cold start and is reported separately, because
    /// on a machine where the model has idled out that is the latency a real dictation gets.
    /// Does correcting a transcript teach the right thing, and refuse the wrong thing?
    ///
    /// `CorrectionLearner` is a pure function of two strings, so this is the one part of the
    /// learning pipeline that can be tested without a microphone, a grant, or another app.
    /// The rejections matter more than the acceptances: a dictionary rule fires on every
    /// future transcript, so learning "I think" -> "we should" from someone rewriting a
    /// sentence is far worse than learning nothing at all.
    private func runLearnSelfTest() {
        Task { @MainActor in
            struct Case {
                let name: String
                let before: String
                let after: String
                /// nil means "learn nothing from this".
                let expect: (hear: String, write: String)?
            }

            let cases: [Case] = [
                .init(name: "misheard-name",
                      before: "I spoke to Kajo about the release.",
                      after: "I spoke to Kadjo about the release.",
                      expect: ("Kajo", "Kadjo")),
                .init(name: "product-name",
                      before: "let's ask cloud code to do it",
                      after: "let's ask Claude Code to do it",
                      expect: ("cloud code", "Claude Code")),
                .init(name: "capitalisation",
                      before: "we deployed to vercel last night",
                      after: "we deployed to Vercel last night",
                      expect: ("vercel", "Vercel")),
                .init(name: "homophone",
                      before: "put it over their",
                      after: "put it over there",
                      expect: ("their", "there")),
                .init(name: "rewrite-is-not-a-correction",
                      before: "I think we should ship it on Friday",
                      after: "We are shipping Thursday morning instead",
                      expect: nil),
                .init(name: "pure-deletion-teaches-nothing",
                      before: "so basically the build is green",
                      after: "the build is green",
                      expect: nil),
                .init(name: "punctuation-only",
                      before: "the build is green",
                      after: "The build is green.",
                      expect: nil),
                .init(name: "common-word-never-learned",
                      before: "send it to the team",
                      after: "send it to a team",
                      expect: nil),
                .init(name: "identical",
                      before: "nothing changed here",
                      after: "nothing changed here",
                      expect: nil),
                // D-10: the bad rule on disk must never be learned again.
                .init(name: "of-a-product",
                      before: "a nice jump plugin of a product",
                      after: "an Altium plugin for ProductFlo",
                      expect: nil),
                .init(name: "of-the",
                      before: "send the file of the day",
                      after: "send the file for the day",
                      expect: nil),
                // D-10: real corrections that must keep their answers.
                .init(name: "model-name-with-version",
                      before: "quen 2.54b is quick",
                      after: "Qwen 3.5 4b is quick",
                      expect: ("quen 2.54b", "Qwen 3.5 4b")),
                .init(name: "shouted-name",
                      before: "we use olama here",
                      after: "we use Ollama here",
                      expect: ("olama", "Ollama")),
            ]

            var failures: [String] = []
            var total = 0
            for test in cases {
                total += 1
                let got = CorrectionLearner.candidates(from: test.before, to: test.after)
                switch test.expect {
                case .none:
                    if !got.isEmpty {
                        failures.append("\(test.name): expected nothing, learned "
                                        + got.map { "\($0.hear)→\($0.write)" }.joined(separator: ", "))
                    }
                case .some(let want):
                    guard let first = got.first else {
                        failures.append("\(test.name): expected \(want.hear)→\(want.write), learned nothing")
                        continue
                    }
                    if first.hear.lowercased() != want.hear.lowercased()
                        || first.write.lowercased() != want.write.lowercased() {
                        failures.append("\(test.name): expected \(want.hear)→\(want.write), "
                                        + "got \(first.hear)→\(first.write)")
                    }
                }
            }

            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                total += 1
                if !ok { failures.append(detail.isEmpty ? name : "\(name): \(detail)") }
            }

            // D-10: automatic mode files only single-token or case-only changes.
            check("auto-add-olama",
                  CorrectionLearner.isAutoAddable(LearnedCorrection(hear: "OLAMA", write: "Ollama")))
            check("auto-add-case-only",
                  CorrectionLearner.isAutoAddable(
                    LearnedCorrection(hear: "claude code", write: "Claude Code")))
            check("auto-add-version-stays-manual",
                  !CorrectionLearner.isAutoAddable(
                    LearnedCorrection(hear: "quen 2.54b", write: "Qwen 3.5 4b")))
            // D-10: re-saving an unchanged edit teaches nothing new.
            check("re-edit-teaches-nothing",
                  CorrectionLearner.newCandidates(
                    original: "we use olama here",
                    previousEdit: "we use Ollama here",
                    edited: "we use Ollama here today"
                  ).isEmpty)
            // D-10: adding is idempotent on the trimmed, case-insensitive pair —
            // even when the existing entry is switched off.
            check("duplicate-trimmed-case",
                  DictionaryStore.isDuplicate(
                    .correction(hear: "OLAMA", write: "Ollama"),
                    in: [.correction(hear: "olama ", write: "ollama")]))
            check("duplicate-disabled-still-counts",
                  DictionaryStore.isDuplicate(
                    .correction(hear: "OLAMA", write: "Ollama"),
                    in: [DictionaryEntry(
                        kind: .correction, write: "Ollama", hear: "OLAMA", isEnabled: false)]))
            // D-10: the review list names the bad rule and the second copy, nothing else.
            let fixture: [DictionaryEntry] = [
                .correction(hear: "of a product", write: "for ProductFlo"),
                .correction(hear: "OLAMA", write: "Ollama"),
                .correction(hear: "OLAMA", write: "Ollama"),
            ]
            let suspicious = DictionaryStore.suspiciousRules(in: fixture)
            check("suspicious-rules",
                  suspicious.count == 2, "expected 2, got \(suspicious.count)")

            if failures.isEmpty {
                writeSelfTest("LEARN_OK: \(total) case(s), corrections learned and rejections held")
            } else {
                for failure in failures { writeSelfTest("  \(failure)") }
                writeSelfTest("LEARN_FAILED: \(failures.count) of \(total)")
            }
            NSApp.terminate(nil)
        }
    }

    /// Can the text we just inserted be read back out of the app it landed in?
    ///
    /// This exists to answer one question before a feature is built on the assumption: to
    /// learn corrections from the edits a user makes after a dictation, the field has to be
    /// *readable*, not merely writable. `TextInjector` already documents that Electron apps
    /// and terminals accept an AX write and silently drop it — but writing and reading are
    /// different attributes, and Chromium in particular only builds its accessibility tree
    /// once something asks for it. Guessing either way would be guessing.
    ///
    /// Walks each running app's AX tree for text elements and reports whether their value and
    /// selection range can actually be read. Bounded hard: a tree walk over a large Electron
    /// app is unbounded in principle and this must not become the hang it is measuring.
    private func runAXReadbackSelfTest() {
        Task { @MainActor in
            guard Permissions.hasAccessibility else {
                writeSelfTest("AXREADBACK_FAILED: no Accessibility grant, so nothing is readable")
                NSApp.terminate(nil)
                return
            }

            let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
            var rows: [String] = []

            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.bundleIdentifier != AppIdentity.bundleIdentifier {
                let name = app.localizedName ?? app.bundleIdentifier ?? "?"
                let root = AXUIElementCreateApplication(app.processIdentifier)

                var found = 0, readableValue = 0, readableRange = 0
                var queue: [(AXUIElement, Int)] = [(root, 0)]
                var visited = 0

                while let (element, depth) = queue.first {
                    queue.removeFirst()
                    visited += 1
                    // 3000 nodes and 14 levels is enough to reach a text field in every app
                    // tried, and shallow enough that a pathological tree cannot stall this.
                    if visited > 3000 || depth > 14 { break }

                    var roleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                    let role = (roleRef as? String) ?? ""

                    if textRoles.contains(role) {
                        found += 1
                        var value: CFTypeRef?
                        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                           value as? String != nil {
                            readableValue += 1
                        }
                        var range: CFTypeRef?
                        if AXUIElementCopyAttributeValue(
                            element, kAXSelectedTextRangeAttribute as CFString, &range
                        ) == .success, range != nil {
                            readableRange += 1
                        }
                    }

                    var childrenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                       let children = childrenRef as? [AXUIElement] {
                        for child in children.prefix(200) { queue.append((child, depth + 1)) }
                    }
                }

                let verdict = found == 0
                    ? "no text elements exposed"
                    : (readableValue > 0 && readableRange > 0
                        ? "READABLE — value and range"
                        : (readableValue > 0 ? "value only, no range" : "elements but no readable value"))
                rows.append(String(
                    format: "  %-26s fields=%-3d value=%-3d range=%-3d  %@",
                    (name as NSString).utf8String!, found, readableValue, readableRange, verdict
                ))
            }

            writeSelfTest("=== AX readback by app ===")
            for row in rows.sorted() { writeSelfTest(row) }
            writeSelfTest("AXREADBACK_OK: \(rows.count) app(s) probed")
            NSApp.terminate(nil)
        }
    }

    /// Cursor, because it is the editor this feature was read against and the one whose
    /// sidebar produces the 200 names every cap in `AXHarvester.Budget` was chosen for.
    private static let defaultContextBundleID = "com.todesktop.230313mzl4w4u92"

    /// Does a harvest of a real editor come back with real file names, and in how many
    /// milliseconds?
    ///
    /// The one question this feature cannot be believed without, and the one nothing else can
    /// answer: CI cannot build this target at all, the only test target sees the platform-neutral
    /// scoring and not the walk, and the log line that carries these numbers requires a
    /// microphone, a hotkey, the Accessibility grant and grammar-repair cleanup all working at
    /// once. Reading it needs `editor.accessibilitySupport` flipped inside a third-party app,
    /// which is precisely why it has to be one command instead of a paragraph of instructions.
    ///
    /// Fails on a stub tree, a denied bundle, a missing adapter and a harvest with no names, on
    /// the `--selftest-systemaudio` principle: on this machine a probe that cannot reach the
    /// thing it is named after must say so rather than pass. It also prints the grounding block
    /// verbatim, because with a hundred names in a prompt "which names did the model actually
    /// see" is the only debuggable question and no other surface answers it.
    ///
    /// Does not go through `ScreenContextStore`: the store gates on the kill switch and on the
    /// frontmost app, and this probe wants to name its target and be told what happened.
    private func runScreenContextSelfTest(bundleID: String) {
        Task { @MainActor in
            guard Permissions.hasAccessibility else {
                writeSelfTest("CONTEXT_FAILED: no Accessibility grant, so no tree is readable")
                NSApp.terminate(nil)
                return
            }
            guard AXHarvester.supports(bundleID: bundleID) else {
                writeSelfTest("CONTEXT_FAILED: \(bundleID) has no adapter, or is on the deny list")
                NSApp.terminate(nil)
                return
            }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                writeSelfTest("CONTEXT_FAILED: \(bundleID) is not running — open it, with a project, and retry")
                NSApp.terminate(nil)
                return
            }

            let context = AXHarvester.harvest(bundleID: bundleID, processID: app.processIdentifier)
            let reasons = context.truncation.reasons
            writeSelfTest("=== screen context: \(context.appName) (\(bundleID)) ===")
            writeSelfTest("""
                  \(context.candidates.count) name(s) in \
                \(context.elapsed.milliseconds)ms, root \(context.projectRoot ?? "—")\
                \(reasons.isEmpty ? "" : ", stopped by: " + reasons.joined(separator: ", "))
                """)
            for candidate in context.candidates.prefix(40) {
                writeSelfTest(String(
                    format: "  %-3d %-14s %@%@",
                    candidate.rank,
                    (candidate.kind.rawValue as NSString).utf8String!,
                    candidate.text,
                    candidate.path.map { " (\($0))" } ?? ""
                ))
            }
            if context.candidates.count > 40 {
                writeSelfTest("  … \(context.candidates.count - 40) more")
            }

            // The prompt as it would actually be built, for the app the names came from. The
            // narrowing is done against a sentence a person would say, so the score ordering is
            // exercised rather than the rank ordering the raw harvest already has.
            let spoken = "open the login handler file and put the config next to it"
            let profile = OutputProfileStore.shared.resolved(
                for: OutputTarget(bundleID: bundleID, displayName: context.appName)
            )
            writeSelfTest("")
            writeSelfTest("=== grounding block for \"\(spoken)\" ===")
            let rules = CleanupInstructions.groundingRules(
                for: context.narrowed(toMentionsIn: spoken),
                target: profile
            )
            for rule in rules { writeSelfTest("  - \(rule)") }
            if rules.isEmpty { writeSelfTest("  (empty)") }

            // Every ceiling shrunk at once, which is what `AXHarvester.Budget` is a struct for
            // and the only thing that exercises the truncation reporting on a healthy tree.
            //
            // Its reasons are printed rather than asserted, deliberately. At eight nodes the
            // node-floor inference in `harvest` reports `.stubTree` no matter what, and so does a
            // walk that never got a focused window at all — measured here against Cursor, where
            // a 25 ms per-call timeout is enough to lose that read — so no reason set tells those
            // two apart. What *is* worth asserting is the candidate ceiling, below: a walk that
            // returns more names than it was allowed is a cap nothing enforces, and that cannot
            // be a false positive.
            let pinched = AXHarvester.harvest(
                bundleID: bundleID,
                processID: app.processIdentifier,
                budget: AXHarvester.Budget(deadline: .milliseconds(20), maxNodes: 8, maxDepth: 2, maxCandidates: 2)
            )
            writeSelfTest("")
            writeSelfTest("""
                  shrunk budget: \(pinched.candidates.count) name(s) in \
                \(pinched.elapsed.milliseconds)ms, \
                stopped by: \(pinched.truncation.reasons.joined(separator: ", "))
                """)

            if context.truncation.contains(.stubTree) {
                writeSelfTest("""
                    CONTEXT_FAILED: \(context.appName) answered with a stub tree. \
                    \(AXAppAdapters.adapter(for: bundleID)?.remediation ?? "")
                    """)
            } else if context.candidates.isEmpty {
                writeSelfTest("CONTEXT_FAILED: the walk finished and found no names")
            } else if pinched.candidates.count > 2 {
                writeSelfTest("""
                    CONTEXT_FAILED: a budget of two candidates returned \
                    \(pinched.candidates.count)
                    """)
            } else {
                writeSelfTest("CONTEXT_OK: \(context.candidates.count) name(s) from \(context.appName)")
            }
            NSApp.terminate(nil)
        }
    }

    private func runCleanupSelfTest(engine: String) {
        Task { @MainActor in
            let preferences = CleanupPreferences(
                tone: .balanced,
                formatsLists: true,
                context: .general
            )
            // What a real hold would use, printed before any fixture runs. The eval below
            // exercises engines by name; this line is the only thing that says which of them
            // the app is actually configured to reach for.
            let live = Settings.shared
            writeSelfTest("""
                  live dictation config: cleanup \(live.cleanupEnabled ? "on" : "off"), \
                engine \(live.cleanupEngine.displayName), \
                grammar \(live.cleanupFixesGrammar
                    ? (live.cleanupEngine == .s1Mini
                        ? "on, as a second Apple pass"
                        : "on, in the same pass")
                    : "off")
                """)

            // Stage C, before any model runs. It is deterministic and engine-independent, so
            // a suite that loads no model at all still fails when a spoken list stops
            // becoming a list — which is the regression this whole flag exists over.
            let structureFailures = SpokenStructure.selfTestFailures()
            if !structureFailures.isEmpty {
                for failure in structureFailures { writeSelfTest("  \(failure)") }
                writeSelfTest("CLEANUP_FAILED: \(structureFailures.count) spoken-structure case(s)")
                NSApp.terminate(nil)
                return
            }
            writeSelfTest("  spoken structure: lists, quotations, code and tables all render")

            let requested: [String]
            switch engine {
            case "all": requested = ["guard", "rules", "apple", "apple-grammar", "s1", "chain", "app-llm"]
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

            // What the eval actually asserts, as opposed to prints. Collected across every
            // engine so one flag reports them all.
            var assertionFailures: [String] = []

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
                case "chain":
                    // The historical S1-then-Apple path, kept so the two-pass score is still
                    // measurable. A real hold with grammar on now uses Apple alone. Judged
                    // as `.grammar`, because the second pass is allowed to change words.
                    formatter = ChainedFormatter(
                        first: S1MiniFormatter(preferences: preferences),
                        second: FoundationModelFormatter(
                            preferences: preferences,
                            fixesGrammar: true,
                            fallback: KeepAsIsFormatter()
                        )
                    )
                    mode = .grammar
                case "app-llm", "qwen":
                    formatter = AppLLMCleanupFormatter(preferences: preferences, fixesGrammar: true)
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

                    // Graded, not just printed. The text asserted against is what the app
                    // would inject — the engine's answer with the router's deterministic
                    // structure stage around it — so a case fails only where the shipped
                    // dictation would have been wrong.
                    let shipped = CleanupEvalCases.shippedText(
                        input: testCase.input,
                        modelAnswer: output
                    )
                    assertionFailures += CleanupEvalCases.failures(
                        for: testCase,
                        shipped: shipped,
                        fixesGrammar: mode == .grammar
                    ).map { "\(name): \($0)" }

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
                    // What the app would type, once the deterministic structure stage has
                    // run. This is the line the assertions grade, so it is the line to read.
                    if shipped != output {
                        writeSelfTest("  ship: \(Self.oneLine(shipped))")
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
            guard assertionFailures.isEmpty else {
                writeSelfTest("")
                for failure in assertionFailures { writeSelfTest("  \(failure)") }
                writeSelfTest("CLEANUP_FAILED: \(assertionFailures.count) assertion(s)")
                NSApp.terminate(nil)
                return
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
        case "app-llm", "qwen":
            return try? await AppLLMCleanupFormatter.generate(
                text, preferences: preferences, fixesGrammar: true
            )
        case "chain":
            // The punctuation stage runs guarded, exactly as it does in production — it is
            // not the stage under test. Only the grammar stage is taken raw, so a rejection
            // there is visible instead of being absorbed by `KeepAsIsFormatter` and reported
            // as a pass. Without this case the chain scored 28/28, which was not a result.
            let punctuated = await S1MiniFormatter(preferences: preferences).format(text)
            return try? await FoundationModelFormatter.clean(
                punctuated, preferences: preferences, fixesGrammar: true
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
                try await capture.start(
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
                        + "the grant does. Before changing any setting, check how this was "
                        + "launched: TCC grants the *responsible* process, and a binary run "
                        + "straight from a shell is the shell's responsibility, not "
                        + "Next Notes's. Re-run it through LaunchServices — "
                        + "open -n -a NextNotes --args --selftest-systemaudio --selftest-out "
                        + "/tmp/out.txt — and only if that is silent too, allow Next Notes "
                        + "under Privacy & Security ▸ Screen & System Audio Recording"
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

            for id in CalendarProviderID.calendars {
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

            let decisionFailures = Self.autoRecordDecisionFailures()
            let nextFailures = Self.nextEventSelectionFailures()
            let callFailures = Self.calendarCallFailures()
            for failure in decisionFailures { writeSelfTest("  DECISION_WRONG: \(failure)") }
            for failure in nextFailures { writeSelfTest("  NEXT_WRONG: \(failure)") }
            for failure in callFailures { writeSelfTest("  CALENDAR_CALL_WRONG: \(failure)") }

            let failures = decisionFailures + nextFailures + callFailures
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

    /// What the menu bar calls "next": the soonest timed meeting that has not ended.
    ///
    /// Kept next to the auto-record cases so a filter that starts treating all-day
    /// blocks or already-finished meetings as current is caught without a calendar.
    private static func nextEventSelectionFailures() -> [String] {
        let now = Date()
        func event(
            title: String,
            startOffset: TimeInterval,
            duration: TimeInterval,
            allDay: Bool = false
        ) -> MeetingEvent {
            MeetingEvent(
                id: title,
                providerID: .fake,
                title: title,
                start: now.addingTimeInterval(startOffset),
                end: now.addingTimeInterval(startOffset + duration),
                attendees: [],
                isOrganizerOrSelfAccepted: true,
                conferenceURL: nil,
                calendarName: "Test",
                isAllDay: allDay
            )
        }

        let ended = event(title: "Ended", startOffset: -3600, duration: 1800)
        let current = event(title: "Current", startOffset: -600, duration: 1800)
        let future = event(title: "Future", startOffset: 3600, duration: 1800)
        let allDay = event(title: "All day", startOffset: 0, duration: 86400, allDay: true)

        let cases: [(String, MeetingEvent?, [MeetingEvent])] = [
            ("empty list is nothing", nil, []),
            ("ended and all-day are skipped", nil, [ended, allDay]),
            ("an in-progress meeting is next", current, [ended, current, future]),
            ("all-day is skipped in favour of a timed meeting", future, [allDay, future]),
        ]

        return cases.compactMap { name, expected, events in
            let actual = CalendarService.nextEvent(in: events, now: now)
            return actual == expected ? nil : name
        }
    }

    /// What a call that has just settled does about the calendar, and what ends a
    /// recording afterwards (M-11).
    ///
    /// Four pure rules with no clock, no calendar and no microphone behind them, which is
    /// the only way a self-test can reach them: a call six minutes before a meeting is the
    /// thing this rule exists for, and there is no way to arrange one from a terminal.
    /// Every case states the instant it is about, because each of these decisions is about
    /// a distance from an end time and a wrong answer is one second from a right one.
    private static func calendarCallFailures() -> [String] {
        let now = Date()
        func event(
            id: String = "auto",
            startOffset: TimeInterval,
            duration: TimeInterval = 1800,
            allDay: Bool = false
        ) -> MeetingEvent {
            MeetingEvent(
                id: id,
                providerID: .fake,
                title: "Auto meeting",
                start: now.addingTimeInterval(startOffset),
                end: now.addingTimeInterval(startOffset + duration),
                attendees: ["Sam"],
                isOrganizerOrSelfAccepted: true,
                conferenceURL: nil,
                calendarName: "Test",
                isAllDay: allDay
            )
        }
        func candidate(_ event: MeetingEvent, auto: Bool = true) -> CallPolicy.CalendarCandidate {
            CallPolicy.CalendarCandidate(event: event, isAutoRecord: auto)
        }

        // A call six minutes before a meeting is the whole use case; twelve is not a call
        // for this meeting, and an all-day block is not a meeting at all. Every offset here
        // is measured from now to the event's *start*, so a positive number is a call
        // before the meeting and a negative one is a meeting already under way.
        let matchCases: [(String, CallPolicy.CalendarMatch, [CallPolicy.CalendarCandidate])] = [
            ("joining six minutes early starts the event",
             .startCalendar(eventID: "auto"),
             [candidate(event(startOffset: 360))]),
            ("twelve minutes early is outside the correlation window",
             .none,
             [candidate(event(startOffset: 720))]),
            ("a meeting already under way is that meeting",
             .startCalendar(eventID: "auto"),
             [candidate(event(startOffset: -600))]),
            ("a meeting that ended five minutes ago still covers a call",
             .startCalendar(eventID: "auto"),
             [candidate(event(startOffset: -3000, duration: 2700))]),
            ("an event that is not agreed to is asked about, not started",
             .askCalendar(eventID: "manual"),
             [candidate(event(id: "manual", startOffset: 360), auto: false)]),
            ("an all-day block is never the meeting",
             .none,
             [candidate(event(startOffset: 0, duration: 86_400, allDay: true))]),
            ("with no events near, it is an ad-hoc call",
             .none,
             [candidate(event(startOffset: 3600))]),
            ("the nearest of two overlapping events wins",
             .startCalendar(eventID: "near"),
             [candidate(event(id: "far", startOffset: 540)),
              candidate(event(id: "near", startOffset: 120))]),
        ]

        var failures = matchCases.compactMap { name, expected, candidates in
            CallPolicy.calendarMatch(at: now, candidates: candidates) == expected ? nil : name
        }

        // The end time the overrun rule reads. Every case states its own instant as an
        // offset from it, because each of these decisions is a distance from an end time
        // and a wrong answer is one second away from a right one.
        let end = now.addingTimeInterval(3600)
        let overrunCases: [
            (String, CallPolicy.OverrunDecision, TimeInterval?, TimeInterval, TimeInterval?)
        ] = [
            // (name, expected, offset from the end, seconds since the last word, since the call went)
            ("well inside the end keeps recording", .keep, -600, 5, nil),
            ("five minutes past the end, mid-sentence, keeps recording", .keep, 300, 30, nil),
            ("five minutes past the end in a quiet room stops", .stop(.quiet), 300, 180, nil),
            ("five minutes past the end after a hang-up stops", .stop(.callEnded), 300, 30, 61),
            ("an hour past the end stops whatever is happening", .stop(.ceiling), 3600, 5, nil),
            ("just under the hour, talking, stays on", .keep, 3500, 5, nil),
            ("a detected call has no schedule to overrun", .keep, nil, 7200, nil),
        ]

        failures += overrunCases.compactMap { name, expected, offset, speechAgo, callEndedAgo in
            let at = offset.map { end.addingTimeInterval($0) } ?? now
            let decision = CallPolicy.overrunDecision(
                now: at,
                end: offset == nil ? nil : end,
                lastSpeechAt: at.addingTimeInterval(-speechAgo),
                coveringCallEndedAt: callEndedAgo.map { at.addingTimeInterval(-$0) }
            )
            return decision == expected ? nil : name
        }

        // The hang-up grace, read against one fixed instant. `endedAgo` is how long ago
        // the call that covered this meeting went.
        let hangUpCases: [
            (String, Bool, String?, String?, TimeInterval, String?)
        ] = [
            (name: "a minute after the hang-up the meeting stops",
             expected: true, covering: "call-1", ended: "call-1", endedAgo: 61, live: nil),
            ("inside the grace it is still recording",
             false, "call-1", "call-1", 30, nil),
            ("the same call coming back cancels the stop",
             false, "call-1", "call-1", 61, "call-1"),
            ("a meeting with no call is not a hang-up",
             false, nil, "call-1", 600, nil),
            ("another call's hang-up says nothing about this one",
             false, "call-1", "call-2", 600, nil),
            ("a meeting whose call never ended is not a hang-up",
             false, "call-1", nil, 600, "call-1"),
        ]

        failures += hangUpCases.compactMap { name, expected, covering, ended, endedAgo, live in
            let stop = CallPolicy.shouldStopAfterHangUp(
                coveringCallID: covering,
                endedCallID: ended,
                endedAt: now.addingTimeInterval(-endedAgo),
                liveCallID: live,
                now: now
            )
            return stop == expected ? nil : name
        }

        // The failure row a meeting that is *being recorded* must never get.
        let armed = Meeting(
            title: "Quarterly",
            start: now,
            end: now.addingTimeInterval(1800),
            calendarEventID: "quarterly",
            providerID: CalendarProviderID.fake.rawValue,
            status: .armed
        )
        var recording = armed
        recording.status = .recording
        let other = Meeting(
            title: "Something else",
            start: now,
            calendarEventID: "other",
            providerID: CalendarProviderID.fake.rawValue
        )
        let missedCases: [(String, MeetingScheduler.MissedReason?, Meeting?)] = [
            ("the running session is the meeting's own recording", nil, recording),
            ("a different recording is a real conflict", .anotherMeetingWasRecording, other),
            ("nothing running means the app was not there", .appWasNotRunning, nil),
        ]
        failures += missedCases.compactMap { name, expected, running in
            MeetingScheduler.missedReason(running: running, meeting: armed) == expected ? nil : name
        }

        return failures
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

                // The seam production uses, not a legacy setting: resolving
                // `Settings.notesProvider` tested a path nothing takes, so a machine whose
                // notes run on an installed model reported a different one here.
                let resolution = ModelRoleStore.shared.resolution(for: .meetingNotes)
                guard let provider = await ModelRoleStore.shared.provider(for: .meetingNotes) else {
                    let reasons = await Self.providerReasons()
                    writeSelfTest("NOTES_FAILED: no provider available — \(reasons)")
                    NSApp.terminate(nil)
                    return
                }
                if resolution.effective != resolution.requested, let note = resolution.note {
                    writeSelfTest("  note: \(note)")
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
                    NOTES_OK: \(provider.displayModelName)\(result.usedMapReduce ? " (map-reduce)" : ""), \
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

    /// `--selftest-notes-context`: fixture sources only, so it answers on a machine with no
    /// memory, no index and no model downloaded.
    private func runNotesContextSelfTest() {
        Task { @MainActor in
            _ = await MeetingNotesContextSelfTest.run { writeSelfTest($0) }
            NSApp.terminate(nil)
        }
    }

    /// `--selftest-notes-longform`: the map-reduce path keeps every fact (M-05), with a
    /// collapse pass and a visible line on the last-resort path. No model, no store.
    private func runNotesLongformSelfTest() {
        Task { @MainActor in
            SelfTest.failed = !(await NotesLongformSelfTest.run { writeSelfTest($0) })
            NSApp.terminate(nil)
        }
    }

    /// `--selftest-notes-truncation`: a cut-off answer says so on the page instead of
    /// claiming there was nothing to say (M-13). No model, no store.
    private func runNotesTruncationSelfTest() {
        Task { @MainActor in
            SelfTest.failed = !(await NotesTruncationSelfTest.run { writeSelfTest($0) })
            NSApp.terminate(nil)
        }
    }

    /// `--selftest-meeting-finals [<fixtures-dir>]`: the M-01 long-window final tier
    /// against the M-16a fixtures (default `$NEXTNOTES_FIXTURES/meetings`). Needs
    /// Parakeet on disk; uses no store (segments in memory). `--finals-window
    /// <min>:<max>` overrides the cut config for measurement (M-01 step 1).
    private func runMeetingFinalsSelfTest() {
        Task { @MainActor in
            let dir = SelfTest.value(after: "--selftest-meeting-finals")
            SelfTest.failed = !(await MeetingFinalsSelfTest.run(dir: dir) { writeSelfTest($0) })
            NSApp.terminate(nil)
        }
    }

    /// `--selftest-meeting-resume`: the M-08 resume planner, the isolated-store
    /// resume run (3/3 seeded interruptions reach `.done` with notes), the
    /// stall watchdog, and the M-16c debounced `transcript.json` write. No model,
    /// no microphone, never the user's `Meetings/`.
    private func runMeetingResumeSelfTest() {
        Task { @MainActor in
            SelfTest.failed = !(await MeetingResumeSelfTest.run { writeSelfTest($0) })
            NSApp.terminate(nil)
        }
    }

    /// `--selftest-meeting-backlog`: the M-07 live backlog — bounded by audio seconds,
    /// merged while the lane is behind, and nothing dropped below the bound. A fake
    /// transcriber sleeps behind the queue; no model, no store, no microphone.
    private func runMeetingBacklogSelfTest() {
        Task { @MainActor in
            SelfTest.failed = !(await MeetingBacklogSelfTest.run { writeSelfTest($0) })
            NSApp.terminate(nil)
        }
    }

    /// `--selftest-meeting-tap-retry`: the M-09 late tap join — the retry loop, the
    /// origin placement for the track that joins mid-meeting, and the stop
    /// cancellation, over an injected capture and transcriber. No microphone, no real
    /// tap, no model; every meeting lives in `MeetingStore.isolated()`.
    private func runMeetingTapRetrySelfTest() {
        Task { @MainActor in
            SelfTest.failed = !(await MeetingTapRetrySelfTest.run { writeSelfTest($0) })
            NSApp.terminate(nil)
        }
    }

    /// `--selftest-audio-retention`: M-10 — temporary audio kept 72 hours past the
    /// pipeline end or until the speakers are confirmed, the 5 GB retention and
    /// 1 GB start disk guards, the sweeper's exclusions, and the writer's
    /// stop-on-error. Everything is seeded in `MeetingStore.isolated()`; the clock
    /// and free space are injected, so it never reads this Mac's disk or touches
    /// the user's `Meetings/`.
    private func runAudioRetentionSelfTest() {
        Task { @MainActor in
            SelfTest.failed = !(await AudioRetentionSelfTest.run { writeSelfTest($0) })
            NSApp.terminate(nil)
        }
    }

    /// `--notes-context-live`: the same brief against this machine's own memory, index,
    /// graph and folders. Read-only; prints `_EMPTY` rather than failing when there is
    /// legitimately nothing to connect. Must not be renamed to a `--selftest-*` flag — the
    /// harness isolates the stores and would print an empty brief that proves nothing.
    private func runNotesContextLiveProbe() {
        Task { @MainActor in
            _ = await MeetingNotesContextLiveProbe.run { writeSelfTest($0) }
            NSApp.terminate(nil)
        }
    }

    /// `--imessage-send-path`: gate G2, task IM-02. **Read-only, and it sends nothing.**
    ///
    /// Asks the one question that decides whether the remote feature is possible at all: can
    /// Next Notes address a conversation in Messages.app, and can the conversation with yourself
    /// be addressed? The read is what provokes the Automation prompt, so this must be launched
    /// through LaunchServices (`--via-open`) or TCC blames Terminal and the refusal means nothing.
    private func runIMessageSendPath() {
        Task { @MainActor in
            for line in await MessagesSendPathProbe.run() { writeSelfTest(line) }
            NSApp.terminate(nil)
        }
    }

    /// `--imessage-self-flow`: IM-01's three questions, answered off this Mac's own
    /// Messages database.
    ///
    /// A diagnostic, not a `--selftest-*` flag, for the two reasons its own file gives: it
    /// needs a grant and a real `chat.db`, and the harness would swap both away.
    /// `writeSelfTest` honours `--selftest-out`, so a LaunchServices launch with no stdout
    /// still leaves its rows in a file.
    private func runIMessageSelfFlow() {
        Task { @MainActor in
            for line in await MessagesSelfFlowReport.run() { writeSelfTest(line) }
            NSApp.terminate(nil)
        }
    }

    /// `--usage-report [--usage-days N] [--usage-feature <prefix>]`: one line per model
    /// or engine that ran, read from this machine's own `usage.jsonl`.
    ///
    /// A diagnostic, not a `--selftest-*` flag, for the reason AGENTS.md documents for
    /// `--notes-context-live`: under the harness `UsageLog.shared` is an empty temp store,
    /// so the report would prove nothing. It therefore runs before
    /// `runRequestedSelfTest`, while `SelfTest.isRunning` is still false. `writeSelfTest`
    /// honours `--selftest-out`, so a LaunchServices launch with no stdout still leaves
    /// its rows in a file.
    /// Downloads the built-in notes/Agent model through the app's own `ModelDownloader`,
    /// which is the only path that gets the resume, the size check and the digest.
    ///
    /// The disk guard is `LocalModelStore`'s own arithmetic, copied rather than re-derived:
    /// the file plus `ModelDownloader.minimumFreeBytesAfterDownload`. A download that fills
    /// the disk is the one failure this app must not cause, and a second copy of the rule is
    /// a second answer to it.
    private func runNotesModelDownload() {
        Task { @MainActor in
            if NotesModels.isDownloaded {
                writeSelfTest("NOTES_MODEL_DOWNLOAD_ALREADY: \(NotesModels.spec.displayName) is on disk")
                NSApp.terminate(nil)
                return
            }
            let free = ModelDownloader.availableDiskBytes()
            let needed = NotesModels.spec.expectedBytes
                + ModelDownloader.minimumFreeBytesAfterDownload
            guard free >= needed else {
                writeSelfTest("""
                    NOTES_MODEL_DOWNLOAD_NO_ROOM: \(SelfTest.byteText(free)) free, \
                    \(SelfTest.byteText(needed)) needed
                    """)
                NSApp.terminate(nil)
                return
            }
            writeSelfTest("""
                NOTES_MODEL_DOWNLOAD_START: \(NotesModels.spec.displayName) \
                \(NotesModels.spec.displaySize) from \
                \(NotesModels.spec.url.host ?? "the hub")
                """)
            // The progress callback is `@Sendable` and runs off the main actor, so the
            // "have I printed this 5% band yet" latch is a lock rather than a captured `var` —
            // the same `OSAllocatedUnfairLock` the wake telemetry uses for its throttle.
            let printed = OSAllocatedUnfairLock(initialState: -1)
            do {
                try await NotesModels.download { fraction in
                    let percent = Int((fraction * 100).rounded())
                    guard printed.withLock({ seen -> Bool in
                        guard seen != percent / 5 else { return false }
                        seen = percent / 5
                        return true
                    }) else { return }
                    // The callback is synchronous, so the hop is a detached task rather than
                    // `MainActor.run` — and a progress line is not worth an await the
                    // downloader would have to wait on.
                    Task { @MainActor in
                        self.writeSelfTest("NOTES_MODEL_DOWNLOAD: \(percent)%")
                    }
                }
                // The spec's digest is still `nil`, and AGENTS.md's instruction is that the
                // downloader computes it and **the next agent pins it** — so it is reported
                // here rather than written, because a flag that edits a source file is a
                // second way for a build to change.
                let url = NotesModels.spec.fileURL
                writeSelfTest("""
                    NOTES_MODEL_DOWNLOAD_OK: \(NotesModels.spec.displayName) at \
                    \(url.lastPathComponent) bytes=\(ModelDownloader.fileSize(at: url)) \
                    sha256=\(((try? ModelDownloader.sha256(of: url)) ?? "unavailable"))
                    """)
                InstalledModelLibrary.shared.refresh()
            } catch {
                writeSelfTest("NOTES_MODEL_DOWNLOAD_FAILED: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    private func runUsageReport() {
        Task { @MainActor in
            for line in await UsageReport.run(arguments: CommandLine.arguments) {
                writeSelfTest(line)
            }
            NSApp.terminate(nil)
        }
    }

    /// `--meeting-quality-report`: one `MeetingQualityProbe.line(…)` per finished
    /// meeting, newest last, then `MEETING_QUALITY_REPORT_DONE`.
    ///
    /// Read-only: it calls no `save`, no `repairInterruptedMeetings` and no
    /// pipeline, and it loads no model. Like `--notes-context-live` it must run
    /// outside `SelfTest.isRunning`, because the harness isolates the stores
    /// and a report over an empty harness store would prove nothing.
    /// `writeSelfTest` honours `--selftest-out`, so a LaunchServices launch
    /// with no stdout still leaves its rows in a file.
    private func runMeetingQualityReport() {
        Task { @MainActor in
            let meetings = MeetingStore.shared.meetings
                .filter { $0.status == .done }
                .sorted { $0.start < $1.start }
            for meeting in meetings {
                let segments = MeetingStore.shared.transcript(for: meeting.id)
                var row = MeetingQualityProbe.line(
                    for: meeting,
                    quality: MeetingQualityProbe.measure(meeting: meeting, segments: segments)
                )
                // M-01: when the final pass ran, the live tier it replaced is the
                // before number every improvement is measured against.
                let live = MeetingStore.shared.liveTranscript(for: meeting.id)
                if !live.isEmpty {
                    let liveQuality = MeetingQualityProbe.measure(meeting: meeting, segments: live)
                    row += " live-wrong=\(Int((liveQuality.wrongLanguageShare * 100).rounded()))%"
                }
                writeSelfTest(row)
            }
            writeSelfTest("MEETING_QUALITY_REPORT_DONE: \(meetings.count) meeting(s)")
            NSApp.terminate(nil)
        }
    }

    /// `--avatar-sheet [path]` — every avatar state at three instants, into one PNG.
    ///
    /// Takes its path with `SelfTest.value(after:)`, which refuses a value that starts with
    /// `--`: without that rule a missing path would be read as the next flag and the sheet
    /// would be written to a file named `--selftest-avatar`.
    private func runAvatarSheet() {
        Task { @MainActor in
            let path = SelfTest.value(after: "--avatar-sheet")
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("nextnotes-avatar-sheet.png").path
            if AgentAvatarSheet.write(to: path) {
                writeSelfTest("AVATAR_SHEET_OK \(path)")
                SelfTest.failed = false
            } else {
                writeSelfTest("AVATAR_SHEET_FAILED")
                SelfTest.failed = true
            }
            NSApp.terminate(nil)
        }
    }

    /// `--settings-sheet [dir] [--width <pt>]` — every Settings pane at the widths it
    /// meets, one PNG each. The same path rule as `--avatar-sheet`: a value beginning
    /// with `--` is never read as an argument.
    private func runSettingsSheet() {
        Task { @MainActor in
            let directory = SelfTest.value(after: "--settings-sheet")
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("nextnotes-settings-sheet", isDirectory: true).path
            var widths = SettingsSheet.widths
            if let value = SelfTest.value(after: "--width"), let width = Double(value) {
                widths = [CGFloat(width)]
            }
            if SettingsSheet.write(to: directory, controller: controller, widths: widths) {
                writeSelfTest("SETTINGS_SHEET_OK \(directory)")
                SelfTest.failed = false
            } else {
                writeSelfTest("SETTINGS_SHEET_FAILED")
                SelfTest.failed = true
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
    /// multi-gigabyte download is not a precondition for answering that question.
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

                // P0-02's agent-role leg: the model the Agent role would actually answer
                // with, tried on its own file. Read-only — no role, setting or library
                // entry is written. The trial decodes with that exact file, so a file that
                // opens but cannot answer (an MTP draft head, an architecture this build
                // cannot run) fails here instead of on the person's next turn. Apple's
                // model is informational: there is no local file to try.
                let agentChoice = ModelRoleStore.shared.choice(for: .agent)
                var agentModel: InstalledLocalModel?
                if case .installedModel(let id) = agentChoice {
                    agentModel = InstalledModelLibrary.shared.model(withID: id)
                }
                if let agentModel {
                    let result = await NotesModelRuntime.shared.trial(agentModel)
                    let tokens: Int
                    let detail: String
                    switch result {
                    case .answered(let count, let seconds):
                        tokens = count
                        detail = String(format: " in %.2fs", seconds)
                    case .opensButCannotAnswer(let reason):
                        tokens = 0
                        detail = " \u{2014} \(reason)"
                    case .cannotOpen(let reason):
                        tokens = 0
                        detail = " \u{2014} \(reason)"
                    }
                    writeSelfTest("""
                        LLM_METAL_AGENT_ROLE: \(agentModel.displayName) generated \
                        \(tokens) token(s)\(detail)
                        """)
                    guard tokens > 0 else {
                        writeSelfTest("""
                            LLM_METAL_FAILED: the model the Agent role uses did not answer a trial
                            """)
                        NSApp.terminate(nil)
                        return
                    }
                } else if agentChoice == .appleFoundation {
                    writeSelfTest("LLM_METAL_AGENT_ROLE: apple")
                }

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
            // D-01b: every hold's outcome, filed through the sink the controllers
            // below are built with. `holdsStarted` counts every press that began a
            // hold (never a refused one); case g pins the two numbers equal.
            let sink = SelfTestOutcomeSink()
            var holdsStarted = 0
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
                let wasIdle = !controller.state.isActive
                controller.startButtonRecording()
                if wasIdle, controller.state.isActive { holdsStarted += 1 }
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
                inbox: SelfTestInbox,
                speechDetector: @escaping @Sendable (AVAudioPCMBuffer) -> Int = defaultSpeechDetector
            ) -> DictationController {
                DictationController(
                    formatter: RuleBasedFormatter(),
                    makeEngine: { SelfTestEngine(shape: shape) },
                    limits: limits,
                    insert: { text, _ in
                        inbox.append(text)
                        return .inserted
                    },
                    // Discarded, not filed. These are fixtures, and the Dictation list is the
                    // user's own history — a self-test has no business appearing in it.
                    record: { _ in },
                    // D-15c: this run injects the deadlines on purpose, so its failures are
                    // written at info in a `selftest` category rather than into the error log.
                    log: .selfTest,
                    // The hold outcomes land here, never in the user's usage.jsonl: the
                    // harness runs against a temp store, and the assertions below read
                    // the sink rather than any file.
                    outcome: { sink.append($0) },
                    speechDetector: speechDetector
                )
            }

            // 1. The ordinary hold. Establishes that the microphone and the state machine
            //    work at all here — without it every other check below passes vacuously.
            //    Held 4 s because the FIRST hold of the process pays the microphone
            //    permission call and the input-device open before it can listen: measured
            //    key-down → capture 1.10 s (2026-09-25 earlier run) and 2.131 s
            //    (2026-09-25 17:57, log: `dictation.keyDown_to_capture`), with every later
            //    hold at ≤ 0.06 s. D-02 moved the hub subscribe ahead of the engine start,
            //    so that one-time cost sits inside the hold rather than behind the model
            //    load — and a 2 s hold sampled it mid-start and read `.starting`. 4 s is
            //    ~2× the worst first hold measured; later cases hold far less and are
            //    unaffected.
            let plain = SelfTestInbox()
            let caseABefore = sink.count
            let controllerA = makeController(.prompt(delay: .zero), inbox: plain)
            let heldState = await hold(controllerA, held: .seconds(4), settle: 6)
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

            // D-01b a. Exactly one `dictation.hold` outcome for the ordinary hold:
            // inserted, the held time counted, key-up → outcome present.
            let caseA = sink.outcomes(from: caseABefore)
            if heldState != nil {
                if caseA.count != 1 {
                    failures.append("the ordinary hold filed \(caseA.count) outcome(s), expected 1")
                } else {
                    let outcome = caseA[0]
                    if outcome.result != .inserted {
                        failures.append("the ordinary hold's outcome was \(outcome.result), expected inserted")
                    }
                    if let holdMs = outcome.counts["holdMs"], holdMs < 500 {
                        failures.append("the ordinary hold's holdMs was \(holdMs), expected ≥ 500")
                    } else if outcome.counts["holdMs"] == nil {
                        failures.append("the ordinary hold filed no holdMs")
                    }
                    if outcome.keyUpToOutcome == nil {
                        failures.append("the ordinary hold carried no key-up → outcome time")
                    }
                    if outcome.counts["keyDownToCaptureMs"] == nil {
                        failures.append("the ordinary hold carried no key-down → capture time")
                    }
                }
            }

            // 2. `finish()` that never returns — the engine wedged on a model load, or on a
            //    queue a meeting is holding. Bounded, this must give up and say so.
            let hung = SelfTestInbox()
            let caseBBefore = sink.count
            let controllerB = makeController(.hangsOnFinish, inbox: hung)
            if await hold(controllerB, held: .milliseconds(400), settle: 8) == nil {
                failures.append("a wedged finish() left the controller recording forever")
            }
            if !hung.contents().isEmpty {
                failures.append("a wedged finish() injected \(hung.contents())")
            }
            // D-03d. A transcribe timeout keeps the hold for retry.
            if !controllerB.canRetryLastHold {
                failures.append("a transcribe timeout kept nothing for retry")
            }

            // D-01b b. Exactly one outcome for the wedged finish: failed:transcribeTimeout.
            let caseB = sink.outcomes(from: caseBBefore)
            if caseB.count != 1 {
                failures.append("the wedged finish filed \(caseB.count) outcome(s), expected 1")
            } else if caseB[0].result != .failed(.transcribeTimeout) {
                failures.append("the wedged finish's outcome was \(caseB[0].result), "
                                + "expected failed(transcribeTimeout)")
            }

            // 3. A transcript stream nobody closes. This is the shape the single-slot
            //    engine/consumeTask pair used to produce on its own, and the reason the
            //    controller now carries a session number.
            let open = SelfTestInbox()
            let controllerC = makeController(.leavesStreamOpen, inbox: open)
            if await hold(controllerC, held: .milliseconds(400), settle: 8) == nil {
                failures.append("an unfinished transcript stream left the controller recording forever")
            }

            // 4. Released while the engine is still starting, then held again
            //    straight away — two start-ups in flight against one set of slots.
            //    D-02 inverts this case on purpose (STATUS.md → Decisions and
            //    deviations): the first hold is KEPT in the key-down pre-roll and
            //    transcribed once the engine has started, instead of failing with
            //    "still starting up". The second half is unchanged: the next hold
            //    still works.
            let raced = SelfTestInbox()
            let caseCBefore = sink.count
            let controllerD = makeController(.prompt(delay: .seconds(2)), inbox: raced)
            controllerD.startButtonRecording()
            holdsStarted += 1
            try? await Task.sleep(for: .milliseconds(200))
            controllerD.stopButtonRecording()
            if case .finishing = controllerD.state {} else {
                failures.append("a hold released during start-up went \(controllerD.state) "
                                + "instead of .finishing for the pre-roll tail")
            }

            let settled = Date().addingTimeInterval(10)
            while Date() < settled, controllerD.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if controllerD.state != .idle {
                failures.append("a hold released during start-up never came back to idle")
            }
            if raced.contents().count != 1 || raced.contents().first?.contains("transcript") != true {
                failures.append("a hold released during start-up injected \(raced.contents()) "
                                + "instead of its pre-roll transcript")
            }

            // D-01b c. D-02 inverted the original lost-at-startup case on purpose: the
            // released hold's pre-roll is transcribed, so its one outcome is inserted,
            // not lostAtStartup. The vocabulary keeps the class; the row the stats
            // script counts is this one.
            let caseC = sink.outcomes(from: caseCBefore)
            if caseC.count != 1 {
                failures.append("the released-during-start-up hold filed \(caseC.count) outcome(s), expected 1")
            } else if caseC[0].result != .inserted {
                failures.append("the released-during-start-up hold's outcome was \(caseC[0].result), "
                                + "expected inserted (D-02 transcribes the pre-roll)")
            }
            // The abandoned start-up is still in flight here; the second hold has to be
            // unaffected by it.
            if await hold(controllerD, held: .seconds(3), settle: 8) == nil {
                failures.append("the hold after an abandoned start-up never came back to idle")
            }
            if raced.contents().count != 2 || raced.contents().last?.contains("transcript") != true {
                failures.append("the hold after an abandoned start-up injected \(raced.contents())")
            }

            failures.append(contentsOf: Self.selectionPolicyFailures())

            // D-05: a press during `.error` starts a new hold. `makeEngine` reads a
            // mutable box so the hold after the failure gets a different engine.
            final class MutableEngineShape: @unchecked Sendable {
                var shape: SelfTestEngine.Shape
                init(_ shape: SelfTestEngine.Shape) { self.shape = shape }
            }
            @MainActor
            func makeRetryController(
                box: MutableEngineShape,
                inbox: SelfTestInbox,
                speechDetector: @escaping @Sendable (AVAudioPCMBuffer) -> Int = defaultSpeechDetector
            ) -> DictationController {
                DictationController(
                    formatter: RuleBasedFormatter(),
                    makeEngine: { SelfTestEngine(shape: box.shape) },
                    limits: limits,
                    insert: { text, _ in
                        inbox.append(text)
                        return .inserted
                    },
                    // Discarded, not filed: fixtures, not the user's history.
                    record: { _ in },
                    // D-15c: this run injects the deadlines on purpose, so its failures are
                    // written at info in a `selftest` category rather than into the error log.
                    log: .selfTest,
                    outcome: { sink.append($0) },
                    speechDetector: speechDetector
                )
            }

            // D-02: the controller owns the engine, so a test that wants the fed
            // frame count holds the instance through a box set inside `makeEngine`.
            final class EngineHolder: @unchecked Sendable {
                var engine: SelfTestEngine?
            }
            @MainActor
            func makePrerollController(
                box: MutableEngineShape,
                holder: EngineHolder,
                inbox: SelfTestInbox
            ) -> DictationController {
                DictationController(
                    formatter: RuleBasedFormatter(),
                    makeEngine: {
                        let engine = SelfTestEngine(shape: box.shape)
                        holder.engine = engine
                        return engine
                    },
                    limits: limits,
                    insert: { text, _ in
                        inbox.append(text)
                        return .inserted
                    },
                    // Discarded, not filed: fixtures, not the user's history.
                    record: { _ in },
                    // D-15c: this run injects the deadlines on purpose, so its failures are
                    // written at info in a `selftest` category rather than into the error log.
                    log: .selfTest,
                    outcome: { sink.append($0) }
                )
            }

            // 5. A failing hold, then 500 ms later a press with a good engine
            //    behind it: `.listening` within 1 s, and the hold injects.
            let retryBox = MutableEngineShape(.failsStart("boom"))
            let retryInbox = SelfTestInbox()
            let caseEBefore = sink.count
            let controllerE = makeRetryController(box: retryBox, inbox: retryInbox)
            controllerE.startButtonRecording()
            holdsStarted += 1
            let firstErrorBy = Date().addingTimeInterval(8)
            while Date() < firstErrorBy {
                if case .error = controllerE.state { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if case .error = controllerE.state {
                try? await Task.sleep(for: .milliseconds(500))
                retryBox.shape = .prompt(delay: .zero)

                // D-01b e. The failing hold filed exactly one failed:startup outcome.
                let failedOutcome = sink.outcomes(from: caseEBefore)
                if failedOutcome.count != 1 {
                    failures.append("the failing start filed \(failedOutcome.count) outcome(s), expected 1")
                } else if failedOutcome[0].result != .failed(.startup) {
                    failures.append("the failing start's outcome was \(failedOutcome[0].result), "
                                    + "expected failed(startup)")
                }

                controllerE.startButtonRecording()
                holdsStarted += 1
                let listeningBy = Date().addingTimeInterval(1)
                var heardListening = false
                while Date() < listeningBy {
                    if controllerE.state == .listening { heardListening = true; break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if !heardListening {
                    failures.append("a press 500 ms after a failure stayed \(controllerE.state) "
                        + "instead of starting a new hold")
                } else {
                    controllerE.stopButtonRecording()
                    let retryDone = Date().addingTimeInterval(8)
                    while Date() < retryDone, controllerE.state != .idle {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if controllerE.state != .idle {
                        failures.append("the hold started from the error card never came back to idle")
                    } else if retryInbox.contents().count != 1
                        || retryInbox.contents().first?.contains("transcript") != true {
                        failures.append("the hold started from the error card injected \(retryInbox.contents())")
                    }
                }
            } else {
                failures.append("a failing engine did not put the controller into .error (\(controllerE.state))")
            }

            // 6. Two failures 1 s apart: the first 3 s timer must clear neither a
            //    new hold nor the newer error, so the second plain message is still
            //    shown 2.5 s after it was raised (D-04 maps both raw errors to the
            //    same plain sentence; the token timing is what this pins).
            let tokenBox = MutableEngineShape(.failsStart("first failure"))
            let tokenInbox = SelfTestInbox()
            let controllerF = makeRetryController(box: tokenBox, inbox: tokenInbox)
            controllerF.startButtonRecording()
            holdsStarted += 1
            let tokenFirstBy = Date().addingTimeInterval(8)
            while Date() < tokenFirstBy {
                if case .error = controllerF.state { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if case .error = controllerF.state {
                try? await Task.sleep(for: .seconds(1))
                tokenBox.shape = .failsStart("second failure")
                controllerF.startButtonRecording()
                holdsStarted += 1
                try? await Task.sleep(for: .seconds(2.5))
                if case .error(let message) = controllerF.state {
                    if message != DictationErrorText.unrecognized {
                        failures.append("the second error was not the plain sentence: \(message)")
                    }
                } else {
                    failures.append("the second error was cleared early "
                        + "(state is \(controllerF.state) 2.5 s after it was raised)")
                }
            } else {
                failures.append("the first of two failures never reached .error (\(controllerF.state))")
            }

            // 7. D-04: a raw engine error must never reach the user. A finish()
            //    that throws FluidAudio's short-audio refusal shows the plain
            //    sentence, not the developer string.
            let rawShortAudio = "Invalid audio data provided. Must be at least 300ms of 16kHz audio."
            let rawInbox = SelfTestInbox()
            let controllerG = makeController(.throwsOnFinish(rawShortAudio), inbox: rawInbox)
            controllerG.startButtonRecording()
            holdsStarted += 1
            try? await Task.sleep(for: .milliseconds(400))
            controllerG.stopButtonRecording()
            // The error card shows for 3 s; read it while it is up.
            var shortError: String?
            let shortErrorBy = Date().addingTimeInterval(8)
            while Date() < shortErrorBy {
                if case .error(let message) = controllerG.state { shortError = message; break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let message = shortError {
                for banned in ["Invalid audio", "16kHz", "ms of"] where message.contains(banned) {
                    failures.append("engine error shown raw: \(message)")
                    break
                }
            } else {
                failures.append("a throwing finish() never showed an error card (state \(controllerG.state))")
            }
            if !rawInbox.contents().isEmpty {
                failures.append("a throwing finish() injected \(rawInbox.contents())")
            }
            let shortIdleBy = Date().addingTimeInterval(8)
            while Date() < shortIdleBy, controllerG.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if controllerG.state != .idle {
                failures.append("a throwing finish() never came back to idle")
            }

            // D-04 pure checks: the padding helper pads to the model floor and
            // leaves longer audio alone. Callers gate on minimumCapturedSamples.
            let paddedShort = ParakeetInput.padded([Float](repeating: 0.5, count: 3_200))
            if paddedShort.count != ParakeetInput.minimumModelSamples {
                failures.append("padded 3,200 samples gave \(paddedShort.count), not 4,800")
            } else if paddedShort.prefix(3_200).contains(where: { $0 != 0.5 }) {
                failures.append("padding rewrote the real samples")
            } else if paddedShort.suffix(1_600).contains(where: { $0 != 0 }) {
                failures.append("padding is not zero")
            }
            let paddedLong = ParakeetInput.padded([Float](repeating: 0.5, count: 6_000))
            if paddedLong.count != 6_000 {
                failures.append("padded 6,000 samples gave \(paddedLong.count), not 6,000")
            }
            let paddedNone = ParakeetInput.padded([])
            if paddedNone.count != ParakeetInput.minimumModelSamples
                || paddedNone.contains(where: { $0 != 0 }) {
                failures.append("padded 0 samples gave \(paddedNone.count) samples, not 4,800 zeros")
            }
            if ParakeetInput.minimumCapturedSamples != 1_600
                || ParakeetInput.minimumModelSamples != 4_800 {
                failures.append("ParakeetInput thresholds moved")
            }

            // D-02a. Pre-roll kept: a slow-start engine held past its start still
            // feeds (nearly) the whole hold, not just the audio after the start.
            // Threshold 24,000 = 1.5 s of audio, measured, not 0.8 × the hold:
            // the debug build takes ~0.5 s from hub subscribe to the first fed
            // buffer (D-02-diag.txt delivery curve), so a 2.5 s hold typically
            // feeds ~30k; the old code fed ~8k (only the ~0.5 s after its 1.5 s
            // start). 24k is 3× the old ceiling and 0.8× the typical new count.
            let holderA = EngineHolder()
            let inboxA = SelfTestInbox()
            let controllerH = makePrerollController(
                box: MutableEngineShape(.countsFrames(startDelay: .milliseconds(1500))),
                holder: holderA, inbox: inboxA)
            let caseHBefore = sink.count
            controllerH.startButtonRecording()
            holdsStarted += 1
            try? await Task.sleep(for: .seconds(2.5))
            let fedA = await holderA.engine?.framesFed() ?? -1
            controllerH.stopButtonRecording()
            let idleABy = Date().addingTimeInterval(8)
            while Date() < idleABy, controllerH.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if fedA < 24_000 {
                failures.append("pre-roll lost: fed \(fedA) frames of ~40000")
            } else {
                writeSelfTest("  DICTATION_NOTE: pre-roll fed \(fedA) frames of ~40000 with a 1.5 s start")
            }
            if inboxA.contents().count != 1 || inboxA.contents().first?.contains("transcript") != true {
                failures.append("a hold past a slow start injected \(inboxA.contents())")
            }
            if controllerH.state != .idle {
                failures.append("a hold past a slow start never came back to idle")
            }

            // D-02c. Capture latency: key-down → capture no longer includes the
            // model load, so it stays ≤ 150 ms although the start took 1.5 s.
            // (D-01b files the same number as counts["keyDownToCaptureMs"] on the
            // hold row; the controller read here is the same measurement.)
            if let captureSeconds = controllerH.keyDownToCaptureSeconds {
                if captureSeconds > 0.15 {
                    failures.append("key-down to capture took \(captureSeconds)s with a 1.5 s start")
                } else {
                    writeSelfTest("  DICTATION_NOTE: key-down to capture \(captureSeconds)s with a 1.5 s start")
                }
            } else {
                failures.append("no key-down to capture time recorded for a 2.5 s hold")
            }
            let caseH = sink.outcomes(from: caseHBefore)
            if caseH.count != 1 {
                failures.append("the pre-roll hold filed \(caseH.count) outcome(s), expected 1")
            } else if caseH[0].counts["keyDownToCaptureMs"] == nil {
                failures.append("the pre-roll hold's outcome carried no keyDownToCaptureMs")
            }

            // D-02b. Release during start-up transcribes: the state goes to
            // `.finishing` (not `.error`) and the pre-roll comes back as text.
            let holderB = EngineHolder()
            let inboxB = SelfTestInbox()
            let controllerI = makePrerollController(
                box: MutableEngineShape(.countsFrames(startDelay: .milliseconds(1500))),
                holder: holderB, inbox: inboxB)
            controllerI.startButtonRecording()
            holdsStarted += 1
            try? await Task.sleep(for: .seconds(1))
            controllerI.stopButtonRecording()
            if case .finishing = controllerI.state {} else {
                failures.append("a hold released during start-up went \(controllerI.state) "
                                + "instead of .finishing for the pre-roll tail")
            }
            let idleBBy = Date().addingTimeInterval(8)
            while Date() < idleBBy, controllerI.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if inboxB.contents().count != 1 || inboxB.contents().first?.contains("transcript") != true {
                failures.append("a hold released during start-up injected \(inboxB.contents()) "
                                + "instead of its pre-roll transcript")
            }
            if controllerI.state != .idle {
                failures.append("a hold released during start-up never came back to idle")
            }

            // D-02d. Supersede safety: hold 1 cancelled mid-start must not cut
            // hold 2's microphone when its late start-up unwinds. Hold 2 stays
            // capturing past hold 1's 2 s start, so an `unsubscribe` there would
            // show up as missing frames. Threshold as in D-02a (24,000): a whole
            // hold feeds ~32k here, a mic cut at hold 1's unwind ~14k.
            let supBox = MutableEngineShape(.countsFrames(startDelay: .seconds(2)))
            let holderD = EngineHolder()
            let inboxD = SelfTestInbox()
            let controllerJ = makePrerollController(box: supBox, holder: holderD, inbox: inboxD)
            let caseJBefore = sink.count
            controllerJ.startButtonRecording()
            holdsStarted += 1
            try? await Task.sleep(for: .milliseconds(500))
            controllerJ.cancelDictation()
            try? await Task.sleep(for: .milliseconds(200))
            supBox.shape = .countsFrames(startDelay: .zero)
            controllerJ.startButtonRecording()
            holdsStarted += 1
            if await hold(controllerJ, held: .milliseconds(2_500), settle: 8) == nil {
                failures.append("the hold after a cancelled start-up never came back to idle")
            }
            let fedD = await holderD.engine?.framesFed() ?? -1
            if fedD < 24_000 {
                failures.append("a superseded start-up cut the next hold's microphone: "
                                + "fed \(fedD) frames of ~40000")
            }
            if inboxD.contents().count != 1 || inboxD.contents().first?.contains("transcript") != true {
                failures.append("the hold after a cancelled start-up injected \(inboxD.contents())")
            }
            // D-01b: the cancelled hold filed its one row as cancelled, and the hold
            // after it as inserted — the pair the counters read for T5.
            let caseJ = sink.outcomes(from: caseJBefore)
            if caseJ.count == 2 {
                if caseJ[0].result != .cancelled {
                    failures.append("the cancelled start-up's outcome was \(caseJ[0].result), expected cancelled")
                }
                if caseJ[1].result != .inserted {
                    failures.append("the hold after a cancelled start-up filed \(caseJ[1].result), expected inserted")
                }
            } else {
                failures.append("the cancelled start and its successor filed \(caseJ.count) outcome(s), expected 2")
            }

            // D-02e. Tap faster than the subscribe: the release lands before the
            // microphone even opened (no await sits between the two button calls,
            // so the start Task cannot have run yet). The hold must still come
            // back to idle with its transcript — never stuck in `.finishing`.
            let tapInbox = SelfTestInbox()
            let controllerK = makeController(.prompt(delay: .zero), inbox: tapInbox)
            controllerK.startButtonRecording()
            holdsStarted += 1
            controllerK.stopButtonRecording()
            if case .finishing = controllerK.state {} else {
                failures.append("an immediate release went \(controllerK.state) instead of .finishing")
            }
            let idleEBy = Date().addingTimeInterval(8)
            while Date() < idleEBy, controllerK.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if tapInbox.contents().count != 1 || tapInbox.contents().first?.contains("transcript") != true {
                failures.append("a tap faster than the subscribe injected \(tapInbox.contents())")
            }
            if controllerK.state != .idle {
                failures.append("a tap faster than the subscribe never came back to idle")
            }

            // D-03a. Empty transcript over speech: the hold must say so on the
            // error card and keep its audio for retry — never go quietly idle.
            let speechBox = MutableEngineShape(.emptyTranscript)
            let speechInbox = SelfTestInbox()
            let caseLSpeechBefore = sink.count
            let controllerL = makeRetryController(
                box: speechBox, inbox: speechInbox, speechDetector: { _ in 100 })
            controllerL.startButtonRecording()
            holdsStarted += 1
            try? await Task.sleep(for: .milliseconds(800))
            controllerL.stopButtonRecording()
            var speechMessage: String?
            var sawSpeechIdle = false
            let speechBy = Date().addingTimeInterval(8)
            while Date() < speechBy {
                if case .error(let message) = controllerL.state { speechMessage = message; break }
                if controllerL.state == .idle { sawSpeechIdle = true; break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let message = speechMessage {
                // The app's apostrophe is typographic, and this pins the card the user
                // actually reads rather than a straight-quoted approximation of it.
                if !message.contains("couldn\u{2019}t make out") {
                    failures.append("empty transcript over speech showed the wrong card: \(message)")
                }
            } else if sawSpeechIdle {
                failures.append("empty transcript over speech went quietly idle with nothing kept")
            } else {
                failures.append("empty transcript over speech never settled (state \(controllerL.state))")
            }
            if !controllerL.canRetryLastHold {
                failures.append("empty transcript over speech kept nothing for retry")
            }
            if !speechInbox.contents().isEmpty {
                failures.append("empty transcript over speech injected \(speechInbox.contents())")
            }
            // D-01b: speech with no words files emptySpeech — the countable half of T5.
            let caseL = sink.outcomes(from: caseLSpeechBefore)
            if caseL.count != 1 {
                failures.append("the empty-over-speech hold filed \(caseL.count) outcome(s), expected 1")
            } else if caseL[0].result != .emptySpeech {
                failures.append("the empty-over-speech hold's outcome was \(caseL[0].result), expected emptySpeech")
            }
            let speechIdleBy = Date().addingTimeInterval(8)
            while Date() < speechIdleBy, controllerL.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }

            // D-03b. Empty transcript over silence stays quiet: idle, no card,
            // nothing kept. Passes before the fix too — it pins the silence half
            // so a later change cannot start nagging over room tone.
            let silentInbox = SelfTestInbox()
            let caseDBefore = sink.count
            let controllerM = makeController(
                .emptyTranscript, inbox: silentInbox, speechDetector: { _ in 0 })
            controllerM.startButtonRecording()
            holdsStarted += 1
            try? await Task.sleep(for: .milliseconds(800))
            controllerM.stopButtonRecording()
            var silentError: String?
            let silentBy = Date().addingTimeInterval(8)
            while Date() < silentBy {
                if case .error(let message) = controllerM.state { silentError = message; break }
                if controllerM.state == .idle { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let message = silentError {
                failures.append("empty transcript over silence showed an error card: \(message)")
            }
            if controllerM.state != .idle {
                failures.append("empty transcript over silence never came back to idle")
            }
            if controllerM.canRetryLastHold {
                failures.append("empty transcript over silence kept audio for retry")
            }
            if !silentInbox.contents().isEmpty {
                failures.append("empty transcript over silence injected \(silentInbox.contents())")
            }

            // D-01b d. Silence over a real hold goes quietly idle and files exactly one
            // empty row — the hold the island used to show nothing about.
            let caseD = sink.outcomes(from: caseDBefore)
            if caseD.count != 1 {
                failures.append("the silent hold filed \(caseD.count) outcome(s), expected 1")
            } else if caseD[0].result != .empty {
                failures.append("the silent hold's outcome was \(caseD[0].result), expected empty")
            }

            // D-03c. Retry: after a, swap the engine box and retry the kept
            // hold — the inbox gets the transcript and the slot clears.
            speechBox.shape = .prompt(delay: .zero)
            controllerL.retryLastFailedHold()
            holdsStarted += 1
            let retryIdleBy = Date().addingTimeInterval(10)
            while Date() < retryIdleBy, controllerL.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if controllerL.state != .idle {
                failures.append("a retried hold never came back to idle")
            } else if speechInbox.contents().count != 1
                || speechInbox.contents().first?.contains("transcript") != true {
                failures.append("a retried hold injected \(speechInbox.contents())")
            }
            if controllerL.canRetryLastHold {
                failures.append("a retried hold left its audio kept")
            }

            // D-01b f. A press while the tail is still running is refused, and the
            // refusal is filed against the hold it arrived during — which still ends
            // with exactly one inserted row. The slow formatter keeps the hold in
            // `.finishing` for about a second, so the press below lands inside it.
            let slowInbox = SelfTestInbox()
            let caseFBefore = sink.count
            let controllerN = DictationController(
                formatter: SlowSelfTestFormatter(),
                makeEngine: { SelfTestEngine(shape: .prompt(delay: .zero)) },
                limits: limits,
                insert: { text, _ in
                    slowInbox.append(text)
                    return .inserted
                },
                // Discarded, not filed: fixtures, not the user's history.
                record: { _ in },
                // D-15c: this run injects the deadlines on purpose, so its failures are
                // written at info in a `selftest` category rather than into the error log.
                log: .selfTest,
                outcome: { sink.append($0) }
            )
            controllerN.startButtonRecording()
            holdsStarted += 1
            // Let the hold reach `.listening` before releasing, so the press below is
            // unambiguously refused in `.finishing` and not in `.starting`.
            let listeningNBy = Date().addingTimeInterval(4)
            while Date() < listeningNBy, controllerN.state != .listening {
                try? await Task.sleep(for: .milliseconds(20))
            }
            controllerN.stopButtonRecording()
            // The tail now runs the one-second formatter. A press here is refused and
            // files a `dictation.press_refused` row against this hold; it starts nothing.
            try? await Task.sleep(for: .milliseconds(200))
            if controllerN.state == .finishing {
                controllerN.startButtonRecording()
            } else {
                failures.append("the hold's tail was \(controllerN.state) when the refused "
                                + "press was due, expected finishing")
            }
            let idleNBy = Date().addingTimeInterval(8)
            while Date() < idleNBy, controllerN.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if controllerN.state != .idle {
                failures.append("the hold whose tail refused a press never came back to idle")
            }
            let caseF = sink.outcomes(from: caseFBefore)
            if caseF.count != 1 {
                failures.append("the hold with the refused press filed \(caseF.count) outcome(s), expected 1")
            } else if caseF[0].result != .inserted {
                failures.append("the hold with the refused press filed \(caseF[0].result), expected inserted")
            }
            // The refused row itself: read back through the harness temp store, which
            // is where the controller's usage rows go under the self-test.
            UsageLog.shared.flush()
            let refusedRows = UsageLog.shared.load().filter {
                $0.feature == UsageFeature.dictationPressRefused.rawValue
                    && $0.errorClass == "finishing"
            }
            if refusedRows.count != 1 {
                failures.append("the finishing refused press filed \(refusedRows.count) row(s), expected 1")
            } else if refusedRows[0].counts?["sinceKeyUpMs"] == nil {
                failures.append("the finishing refused press carried no sinceKeyUpMs")
            } else if refusedRows[0].dictationRunID == nil {
                failures.append("the refused press row carried no correlation id for the hold it hit")
            }

            // D-12. A hold whose transcript grows while the key is down: the sentences that
            // stopped changing are tidied *during* the hold, and the pass at key-up tidies
            // only what came after them. One fake for both halves of the cleanup, so which
            // of the two ran, and on what, is a fact about the calls rather than an
            // inference from the text.
            //
            // The two sentences are 15 and 12 words because `minClose` is 15 in production
            // and this case deliberately uses the shipping number: the first group has to
            // close on its own, with nothing else making it close.
            let growingInbox = SelfTestInbox()
            let recorder = SelfTestCleanupRecorder()
            let fake = SelfTestTidyFormatter(recorder: recorder)
            let firstSentence = "We are shipping the installer on Friday and the release note "
                + "the day after that."
            let secondSentence = "Support will keep watching the forum for the first week "
                + "of the rollout."
            let growingFinal = firstSentence + " " + secondSentence
            let growing = DictationController(
                makeEngine: {
                    SelfTestEngine(shape: .partials(
                        [firstSentence, growingFinal],
                        every: .milliseconds(300)
                    ))
                },
                limits: limits,
                insert: { text, _ in
                    growingInbox.append(text)
                    return .inserted
                },
                // Discarded, not filed: fixtures, not the user's history.
                record: { _ in },
                // D-15c: this run injects the deadlines on purpose, so its failures are
                // written at info in a `selftest` category rather than into the error log.
                log: .selfTest,
                outcome: { sink.append($0) },
                cleanupPieces: {
                    CleanupPieces(
                        preclean: fake,
                        // The real router, so the head is matched, joined and recorded the
                        // way production does it rather than by a stand-in for it.
                        pass: { head in
                            CleanupRouter(semantic: fake, engine: .apple, head: head)
                        }
                    )
                }
            )
            growing.startButtonRecording()
            holdsStarted += 1
            // Wait for the last partial to be the live transcript: a hold released before
            // the transcript has grown would test nothing, and a case that passed on it
            // would be a lie.
            let growingBy = Date().addingTimeInterval(10)
            while Date() < growingBy, growing.transcript != growingFinal {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if growing.transcript != growingFinal {
                failures.append("the growing-transcript hold never reached its last partial")
            }
            // ...and for the pre-clean to land, so the call count below is about the key-up
            // pass rather than about how fast the fake is.
            let tidiedBy = Date().addingTimeInterval(4)
            while Date() < tidiedBy, await recorder.calls().count == 0 {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let beforeRelease = await recorder.calls()
            if beforeRelease != [firstSentence] {
                failures.append(
                    "while the key was still down the finished sentence was tidied "
                        + "\(beforeRelease.count) time(s) (\(beforeRelease.count == 0 ? "none" : "the wrong text")), "
                        + "expected the one finished sentence"
                )
            }

            growing.stopButtonRecording()
            let growingIdleBy = Date().addingTimeInterval(10)
            while Date() < growingIdleBy, growing.state != .idle {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if growing.state != .idle {
                failures.append("the growing-transcript hold never came back to idle")
            }
            let atKeyUp = await recorder.calls()
            if atKeyUp.count != beforeRelease.count + 1 {
                failures.append(
                    "the key-up pass made \(atKeyUp.count - beforeRelease.count) tidying call(s), "
                        + "expected 1 — only the tail should reach the model"
                )
            }
            if atKeyUp.last != secondSentence {
                failures.append(
                    "the key-up pass tidied \(atKeyUp.last.map { "\"\($0)\"" } ?? "nothing"), "
                        + "expected only the unfinished tail"
                )
            }
            // And the text is byte-for-byte what one pass over the whole transcript gives.
            let onePass = await CleanupRouter(semantic: fake, engine: .apple)
                .format(growingFinal)
            if growingInbox.contents().count != 1 {
                failures.append("the growing-transcript hold injected \(growingInbox.contents())")
            } else if growingInbox.contents().first != onePass {
                failures.append(
                    "the growing-transcript hold typed \(growingInbox.contents().first ?? "nothing"), "
                        + "not what one pass produces (\"\(onePass)\")"
                )
            }

            // D-01b g. Every hold started filed exactly one outcome: no path reports
            // twice, and no path loses a hold without a row.
            if sink.count != holdsStarted {
                failures.append("holds started \(holdsStarted) but \(sink.count) outcome row(s) were filed")
            }

            for failure in failures { writeSelfTest("  DICTATION_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                ? "DICTATION_OK: every hold came back to idle"
                : "DICTATION_FAILED: \(failures.count) problem(s)")
            NSApp.terminate(nil)
        }
    }

    /// Checks the rules behind selecting and deleting several transcriptions at once.
    ///
    /// The clicking itself cannot be tested — Next Notes is blocked from UI automation on this
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

    /// `--selftest-calls` — what Core Audio says is holding the microphone and the speakers
    /// right now, and every rule `CallPolicy` applies to it.
    ///
    /// The table is the half a person reads: start a Zoom call and it should show Zoom with
    /// both flags; dictate and it should show Next Notes with input only. The assertions are
    /// the half a machine reads, and they are the reason `CallPolicy` is a separate file —
    /// the Core Audio subscription needs a real call to exercise it, the rules do not.
    ///
    /// Reads only. Nothing here starts the detector, so no listener is installed, nothing is
    /// armed and nothing is written.
    private func runCallsSelfTest() {
        Task { @MainActor in
            let processes = CallDetector.audioProcesses()
            let ownPID = getpid()

            if processes.isEmpty {
                writeSelfTest("  no process is holding input or output")
            }
            for process in processes.sorted(by: { $0.pid < $1.pid }) {
                let flags = [
                    process.isRunningInput ? "input" : nil,
                    process.isRunningOutput ? "output" : nil,
                ].compactMap { $0 }.joined(separator: "+")
                let verdict = CallPolicy.isCall(process, ownPID: ownPID) ? "call" : "not a call"
                // Whether it earns a row in the Meetings tab's app list, which is a
                // different question: that list wants the microphone alone, and wants a
                // bundle id to key the answer to.
                let listed = CallPolicy.isMicrophoneApp(process, ownPID: ownPID)
                    ? "listed in Settings" : "not listed"
                writeSelfTest("""
                      pid \(process.pid) \(flags) — \(process.name) \
                    [\(process.bundleID ?? "no bundle id")] → \(verdict), \(listed)
                    """)
                if let reported = process.reportedBundleID {
                    writeSelfTest(
                        "  pid \(process.pid) reported \(reported) → owner "
                            + "\(process.bundleID ?? "no bundle id")"
                    )
                }
            }
            let ownerScore = Self.ownerTableResults()
            writeSelfTest("  owner table: \(ownerScore.passed)/\(ownerScore.total)")
            if let candidate = CallPolicy.candidate(in: processes, ownPID: ownPID, preferring: nil) {
                writeSelfTest("  live verdict: \(candidate.name) is on a call")
            } else {
                writeSelfTest("  live verdict: nobody is on a call")
            }

            // What the arming half would do with the machine as it stands. The microphone
            // line covers your own half of a call. The far end rides on the system-audio
            // tap, which has no query API at all, so it is reported as unreadable rather
            // than guessed at — `--selftest-systemaudio` is the only thing that can answer,
            // and only while something is playing.
            let readiness = CallPolicy.RecordingReadiness(hasMicrophone: Permissions.hasMicrophone)
            writeSelfTest("""
                  microphone grant: \(readiness.hasMicrophone ? "yes" : "no") — \
                system audio: not readable, run --selftest-systemaudio with audio playing
                """)
            writeSelfTest("""
                  settings: detection \
                \(Settings.shared.callDetectionEnabled ? "on" : "off"), \
                auto-record \(Settings.shared.callDetectionAutoRecord ? "on" : "off"), \
                \(Settings.shared.callAppAnswers.count) per-app answer(s), \
                \(Settings.shared.callAppsSeen.count) app(s) seen using the microphone
                """)
            for (bundleID, name) in Settings.shared.callAppsSeen.sorted(by: { $0.value < $1.value }) {
                let effective = CallPolicy.effectiveAnswer(
                    forApp: bundleID,
                    autoRecord: Settings.shared.callDetectionAutoRecord,
                    stored: Settings.shared.callAnswer(forApp: bundleID)
                )
                writeSelfTest("  \(name) [\(bundleID)] → \(effective.displayName.lowercased())")
            }
            let live = CallPolicy.armDecision(
                enabled: Settings.shared.callDetectionEnabled,
                answer: nil,
                readiness: readiness,
                meetings: MeetingStore.shared.meetings.compactMap { meeting in
                    guard !meeting.isDetectedCall,
                          meeting.status == .armed || meeting.status.isActive else { return nil }
                    return CallPolicy.MeetingWindow(
                        isActive: meeting.status.isActive,
                        start: meeting.start,
                        end: meeting.end
                    )
                },
                now: Date()
            )
            switch live {
            case .arm: writeSelfTest("  a call detected right now would arm and ask")
            case .attach: writeSelfTest("  a call detected right now would attach to a meeting already in hand")
            case .decline(let reason): writeSelfTest("  a call detected right now would be declined — \(reason.explanation)")
            }

            let failures = Self.callPolicyFailures()
            for failure in failures { writeSelfTest("  CALLS_WRONG: \(failure)") }
            if failures.isEmpty {
                writeSelfTest("""
                    CALLS_OK: \(processes.count) process(es) holding audio, \
                    own pid \(ownPID), rules behave
                    """)
            } else {
                writeSelfTest("CALLS_FAILED: \(failures.count) rule(s) wrong")
            }
            NSApp.terminate(nil)
        }
    }

    /// Every `CallPolicy` rule stated as a case, with fabricated processes so the answers do
    /// not depend on what happens to be running. Returns the ones that came out wrong.
    private static func callPolicyFailures() -> [String] {
        var failures: [String] = []
        let ownPID: pid_t = 501

        func process(
            _ pid: pid_t,
            _ bundleID: String?,
            input: Bool,
            output: Bool
        ) -> CallPolicy.AudioProcess {
            CallPolicy.AudioProcess(
                pid: pid,
                bundleID: bundleID,
                reportedBundleID: nil,
                name: bundleID ?? "pid \(pid)",
                isRunningInput: input,
                isRunningOutput: output
            )
        }

        // The both-flags rule, which is the whole discriminator.
        let zoom = process(900, "us.zoom.xos", input: true, output: true)
        let dictating = process(901, "com.apple.TextEdit", input: true, output: false)
        let watching = process(902, "com.apple.Safari", input: false, output: true)
        if !CallPolicy.isCall(zoom, ownPID: ownPID) {
            failures.append("a process holding both the microphone and the speakers is not a call")
        }
        if CallPolicy.isCall(dictating, ownPID: ownPID) {
            failures.append("a microphone-only process counted as a call")
        }
        if CallPolicy.isCall(watching, ownPID: ownPID) {
            failures.append("a speakers-only process counted as a call")
        }

        // Self-exclusion, by pid and by identifier.
        let ourselves = process(ownPID, AppIdentity.bundleIdentifier, input: true, output: true)
        if CallPolicy.isCall(ourselves, ownPID: ownPID) {
            failures.append("Next Notes's own process counted as a call")
        }
        let ourHelper = process(903, AppIdentity.bundleIdentifier, input: true, output: true)
        if CallPolicy.isCall(ourHelper, ownPID: ownPID) {
            failures.append("a second Next Notes process counted as a call")
        }

        // The daemon denylist. `corespeechd` was measured holding the microphone with no
        // call in progress, repeatedly.
        let coreSpeech = process(904, "com.apple.CoreSpeech", input: true, output: true)
        if CallPolicy.isCall(coreSpeech, ownPID: ownPID) {
            failures.append("com.apple.CoreSpeech counted as a call")
        }

        // A process with no bundle id at all — `afplay` had none — must still be judged on
        // its flags rather than dropped for being anonymous.
        let anonymous = process(905, nil, input: true, output: true)
        if !CallPolicy.isCall(anonymous, ownPID: ownPID) {
            failures.append("a process with no bundle id was refused for having none")
        }

        // Picking one out of a crowd.
        let crowd = [watching, coreSpeech, zoom, dictating, ourselves]
        if CallPolicy.candidate(in: crowd, ownPID: ownPID, preferring: nil)?.pid != zoom.pid {
            failures.append("the only real call in the list was not the one picked")
        }
        if CallPolicy.candidate(in: [watching, dictating], ownPID: ownPID, preferring: nil) != nil {
            failures.append("a candidate was found where nothing holds both flags")
        }
        let second = process(800, "net.whatsapp.WhatsApp", input: true, output: true)
        if CallPolicy.candidate(in: [second, zoom], ownPID: ownPID, preferring: zoom.pid)?.pid
            != zoom.pid {
            failures.append("a live call lost its place to another process that also qualified")
        }
        if CallPolicy.candidate(in: [second, zoom], ownPID: ownPID, preferring: nil)?.pid
            != second.pid {
            failures.append("the candidate with no incumbent was not the deterministic one")
        }

        // The debounce machine, driven through more than a minute of behaviour instantly.
        let step = CallPolicy.onThreshold / 2
        var state = CallPolicy.next(.quiet, observing: zoom, elapsed: step)
        if state.call != nil {
            failures.append("a call was announced the instant it was first seen")
        }
        state = CallPolicy.next(state, observing: zoom, elapsed: step / 2)
        if state.call != nil {
            failures.append("a call was announced before it held for onThreshold")
        }
        state = CallPolicy.next(state, observing: zoom, elapsed: CallPolicy.onThreshold)
        guard case .live(let settled) = state, settled.pid == zoom.pid else {
            failures.append("a call that held for onThreshold never settled")
            return failures
        }

        // The measured flicker: gone for a sample, back the next one, and the call never
        // stopped as far as the rest of the app is concerned.
        var flicker = CallPolicy.next(state, observing: nil, elapsed: step)
        if flicker.call?.pid != zoom.pid {
            failures.append("a live call ended on the first sample that missed it")
        }
        flicker = CallPolicy.next(flicker, observing: zoom, elapsed: step)
        if case .live = flicker {} else {
            failures.append("a call that came back after a flicker had to earn its threshold again")
        }

        // The same flicker with somebody else in the same call. Fathom is deliberately not
        // on the denylist and a browser tab beside a Zoom window behaves the same way, so
        // two processes holding both flags at once is the ordinary case rather than the
        // exotic one — and the sample where Zoom's input drops must not become a handover.
        let fathom = process(400, "video.fathom.electron", input: true, output: true)
        let zoomFlickering = process(zoom.pid, "us.zoom.xos", input: false, output: true)
        if CallPolicy.candidate(
            in: [fathom, zoomFlickering], ownPID: ownPID, preferring: zoom.pid
        ) != nil {
            failures.append("a live call whose flag flickered was answered with another process")
        }
        var crowded = CallPolicy.next(state, observing: fathom, elapsed: step)
        if crowded.call?.pid != zoom.pid {
            failures.append("a live call was dropped for another process that also qualified")
        }
        crowded = CallPolicy.next(crowded, observing: zoom, elapsed: step)
        if crowded != .live(zoom) {
            failures.append("a live call did not come back from a flicker beside a second call")
        }

        // The newcomer's turn still comes — after the call it was beside has really gone,
        // which is the wait this costs and the only thing it costs.
        var handover = CallPolicy.next(state, observing: fathom, elapsed: CallPolicy.offThreshold)
        handover = CallPolicy.next(handover, observing: fathom, elapsed: CallPolicy.offThreshold)
        if handover != .quiet {
            failures.append("a live call never faded out while another process qualified")
        }
        handover = CallPolicy.next(handover, observing: fathom, elapsed: CallPolicy.onThreshold)
        handover = CallPolicy.next(handover, observing: fathom, elapsed: CallPolicy.onThreshold)
        if handover.call?.pid != fathom.pid {
            failures.append("a second call never settled once the first had faded out")
        }

        // And a call that really is over.
        var ending = CallPolicy.next(state, observing: nil, elapsed: CallPolicy.offThreshold)
        if ending.call == nil {
            failures.append("a call ended before it had been gone for offThreshold")
        }
        ending = CallPolicy.next(ending, observing: nil, elapsed: CallPolicy.offThreshold)
        if ending.call != nil {
            failures.append("a call that had been gone for offThreshold was still reported")
        }

        // A candidate that never settled leaves nothing to fade out.
        let abandoned = CallPolicy.next(
            CallPolicy.next(.quiet, observing: zoom, elapsed: step),
            observing: nil,
            elapsed: step
        )
        if abandoned != .quiet {
            failures.append("a candidate that never settled was faded out instead of dropped")
        }

        failures.append(contentsOf: callArmingFailures())
        failures.append(contentsOf: callOwnerFailures())
        return failures
    }

    /// Phase 2's rules: correlation with a meeting already in hand, the recording grant, and
    /// ask-versus-record. Fabricated throughout, so the answers do not depend on what is on
    /// the machine's calendar or which permissions it happens to hold.
    private static func callArmingFailures() -> [String] {
        var failures: [String] = []
        let now = Date()
        let granted = CallPolicy.RecordingReadiness(hasMicrophone: true)
        let denied = CallPolicy.RecordingReadiness(hasMicrophone: false)

        func decide(
            enabled: Bool = true,
            answer: CallPolicy.AppAnswer? = nil,
            readiness: CallPolicy.RecordingReadiness = granted,
            meetings: [CallPolicy.MeetingWindow] = []
        ) -> CallPolicy.ArmDecision {
            CallPolicy.armDecision(
                enabled: enabled,
                answer: answer,
                readiness: readiness,
                meetings: meetings,
                now: now
            )
        }

        // Nothing in hand and every switch on: the ordinary case.
        if decide() != .arm {
            failures.append("a detected call with nothing in its way did not arm")
        }
        if decide(enabled: false) != .decline(.detectionOff) {
            failures.append("a call was armed with detection switched off")
        }
        if decide(answer: .never) != .decline(.appNever) {
            failures.append("a call was armed for an app set never to record")
        }

        // The grant guard. Detection needs no permission; recording does, and a call armed
        // without it is a recording that cannot happen.
        if decide(readiness: denied) != .decline(.noMicrophone) {
            failures.append("a call was armed with no Microphone grant")
        }
        if decide(answer: .always, readiness: denied) != .decline(.noMicrophone) {
            failures.append("an always-record app got past the missing Microphone grant")
        }

        // Calendar correlation. A Zoom call that is on the calendar must produce exactly one
        // meeting, so anything already armed or recording over this stretch of clock wins.
        let recording = CallPolicy.MeetingWindow(
            isActive: true,
            start: now.addingTimeInterval(-30 * 60),
            end: now.addingTimeInterval(-25 * 60)
        )
        if decide(meetings: [recording]) != .attach {
            failures.append("a call detected during a live recording tried to start a second one")
        }
        let armed = CallPolicy.MeetingWindow(
            isActive: false,
            start: now.addingTimeInterval(60),
            end: now.addingTimeInterval(30 * 60)
        )
        if decide(meetings: [armed]) != .attach {
            failures.append("a call detected next to an armed meeting was armed a second time")
        }
        let joinedEarly = CallPolicy.MeetingWindow(
            isActive: false,
            start: now.addingTimeInterval(CallPolicy.correlationWindow / 2),
            end: now.addingTimeInterval(CallPolicy.correlationWindow / 2 + 30 * 60)
        )
        if decide(meetings: [joinedEarly]) != .attach {
            failures.append("a call joined before its meeting's start time was not correlated with it")
        }
        let unrelated = CallPolicy.MeetingWindow(
            isActive: false,
            start: now.addingTimeInterval(4 * 60 * 60),
            end: now.addingTimeInterval(5 * 60 * 60)
        )
        if decide(meetings: [unrelated]) != .arm {
            failures.append("a call attached itself to a meeting hours away")
        }
        let over = CallPolicy.MeetingWindow(
            isActive: false,
            start: now.addingTimeInterval(-3 * 60 * 60),
            end: now.addingTimeInterval(-2 * 60 * 60)
        )
        if decide(meetings: [over]) != .arm {
            failures.append("a call attached itself to a meeting that finished hours ago")
        }
        // Refusing the app is the user's answer and outranks correlation, which is only ever
        // the app guessing that two things are the same thing.
        if decide(answer: .never, meetings: [recording]) != .decline(.appNever) {
            failures.append("an app set never to record was overruled by a meeting already running")
        }

        // Ask versus record. The default is to ask, and that is a consent decision.
        if CallPolicy.recordsWithoutAsking(
            bundleID: "us.zoom.xos", autoRecord: false, answer: nil
        ) {
            failures.append("a detected call recorded itself without being asked to")
        }
        if !CallPolicy.recordsWithoutAsking(
            bundleID: "us.zoom.xos", autoRecord: true, answer: nil
        ) {
            failures.append("auto-record was switched on and the call still only asked")
        }
        if !CallPolicy.recordsWithoutAsking(
            bundleID: "us.zoom.xos", autoRecord: false, answer: .always
        ) {
            failures.append("an app set to always record still only asked")
        }
        if CallPolicy.recordsWithoutAsking(
            bundleID: "net.whatsapp.WhatsApp", autoRecord: true, answer: .never
        ) {
            failures.append("an app-level refusal lost to the global auto-record switch")
        }
        // R1: a browser holding both flags might be a Meet call and might be anything.
        if CallPolicy.recordsWithoutAsking(
            bundleID: "com.google.Chrome", autoRecord: true, answer: .always
        ) {
            failures.append("a plain browser tab was recorded without being asked about")
        }
        // The Meet web app carries its own identifier, so the precise case stays precise.
        if !CallPolicy.recordsWithoutAsking(
            bundleID: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
            autoRecord: true,
            answer: nil
        ) {
            failures.append("the Google Meet web app was treated as an ordinary browser tab")
        }

        // The synthesised event, which is what makes the whole arm / skip / island path
        // reusable. Two calls in the same app are two events; one call is one event however
        // often it is looked at.
        let call = CallDetector.CallActivity(
            bundleID: "us.zoom.xos",
            pid: 910,
            displayName: "zoom.us",
            since: now,
            hasInput: true,
            hasOutput: true
        )
        let event = CallDetector.event(for: call)
        if event.providerID != .detectedCall {
            failures.append("a detected call was not marked as coming from the detector")
        }
        if event.id != CallDetector.event(for: call).id {
            failures.append("the same call produced two different events")
        }
        var later = call
        later.since = now.addingTimeInterval(3600)
        if event.id == CallDetector.event(for: later).id {
            failures.append("two separate calls in one app shared an event id")
        }
        if !CalendarProviderID.calendars.isEmpty,
           CalendarProviderID.calendars.contains(.detectedCall) {
            failures.append("the detector was listed as a calendar provider")
        }

        failures.append(contentsOf: callAppListFailures())
        return failures
    }

    /// Phase 3's rules: which apps reach the settings list, and what the three-way answer
    /// on each row means. The list is the half of this feature a person operates, and every
    /// way it can lie is a rule here.
    private static func callAppListFailures() -> [String] {
        var failures: [String] = []
        let ownPID: pid_t = 501

        func process(_ pid: pid_t, _ bundleID: String?, input: Bool, output: Bool)
        -> CallPolicy.AudioProcess {
            CallPolicy.AudioProcess(
                pid: pid,
                bundleID: bundleID,
                reportedBundleID: nil,
                name: bundleID ?? "pid \(pid)",
                isRunningInput: input,
                isRunningOutput: output
            )
        }

        // What earns a row. The microphone alone is enough — the point of the list is to be
        // answerable before the first call in an app, not after it.
        if !CallPolicy.isMicrophoneApp(
            process(920, "us.zoom.xos", input: true, output: false), ownPID: ownPID
        ) {
            failures.append("an app holding the microphone was not offered a per-app answer")
        }
        if CallPolicy.isMicrophoneApp(
            process(921, "com.apple.Music", input: false, output: true), ownPID: ownPID
        ) {
            failures.append("an app that only plays audio was listed as a microphone app")
        }
        if CallPolicy.isMicrophoneApp(
            process(ownPID, AppIdentity.bundleIdentifier, input: true, output: true),
            ownPID: ownPID
        ) {
            failures.append("Next Notes listed itself as an app to answer for")
        }
        if CallPolicy.isMicrophoneApp(
            process(922, "com.apple.CoreSpeech", input: true, output: true), ownPID: ownPID
        ) {
            failures.append("a system speech daemon was offered as an app to answer for")
        }
        // Answers are stored against the app. A pid names a different program next reboot,
        // so an anonymous process gets no row rather than a row that goes stale.
        if CallPolicy.isMicrophoneApp(
            process(923, nil, input: true, output: true), ownPID: ownPID
        ) {
            failures.append("a process with no bundle id was given a per-app answer")
        }

        // R1, the ambiguous browser. "Always record" is not on offer, because
        // `recordsWithoutAsking` would refuse to honour it.
        if CallPolicy.availableAnswers(forApp: "com.google.Chrome").contains(.always) {
            failures.append("a browser was offered Always record")
        }
        if !CallPolicy.availableAnswers(forApp: "com.google.Chrome").contains(.never) {
            failures.append("a browser could not be refused")
        }
        if CallPolicy.availableAnswers(
            forApp: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        ) != CallPolicy.AppAnswer.allCases {
            failures.append("the Google Meet web app was restricted like a plain browser tab")
        }

        // What a row shows. An app nobody has answered for shows what the global switch
        // does to it, which is the only honest thing a control can say.
        func effective(_ bundleID: String, autoRecord: Bool, stored: CallPolicy.AppAnswer?)
        -> CallPolicy.AppAnswer {
            CallPolicy.effectiveAnswer(forApp: bundleID, autoRecord: autoRecord, stored: stored)
        }
        if effective("us.zoom.xos", autoRecord: false, stored: nil) != .ask {
            failures.append("an unanswered app read as something other than Ask with auto-record off")
        }
        if effective("us.zoom.xos", autoRecord: true, stored: nil) != .always {
            failures.append("an unanswered app read as Ask while auto-record was on")
        }
        if effective("us.zoom.xos", autoRecord: true, stored: .never) != .never {
            failures.append("an app answered Never read as recording anyway")
        }
        if effective("com.google.Chrome", autoRecord: true, stored: nil) != .ask {
            failures.append("a browser read as recording by itself")
        }
        if effective("com.google.Chrome", autoRecord: false, stored: .always) != .ask {
            failures.append("a browser reported an Always it would not honour")
        }

        // The state a `Bool?` could not hold, and the reason the storage changed: ask about
        // this one app while everything else records itself.
        if CallPolicy.recordsWithoutAsking(
            bundleID: "us.zoom.xos", autoRecord: true, answer: .ask
        ) {
            failures.append("an app answered Ask recorded itself because the global switch was on")
        }

        return failures
    }

    /// M-02: the installed apps the owner table resolves against. A fixture map, not a
    /// probe: the point is what the rule does with a known path, not what happens to be
    /// in `/Applications` on the machine running the test.
    private static let ownerTableBundleIDs: [String: String] = [
        "/Applications/Google Chrome.app": "com.google.Chrome",
        "/Applications/Cursor.app": "com.todesktop.230313mzl4w4u92",
        "/Applications/Firefox.app": "org.mozilla.firefox",
        "/Users/owner/Applications/Chrome Apps.localized/Google Meet.app":
            "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
    ]

    /// M-02: the 8 helper-to-owner resolutions the target promises at 100 %.
    private static let ownerTableCases: [(reported: String?, path: String?, expected: String?)] = [
        (
            "com.google.Chrome.helper",
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/146.0.0.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            "com.google.Chrome"
        ),
        (
            "com.google.Chrome.helper",
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/146.0.0.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            "com.google.Chrome"
        ),
        (
            "com.todesktop.230313mzl4w4u92.helper",
            "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper",
            "com.todesktop.230313mzl4w4u92"
        ),
        (
            "org.mozilla.firefox",
            "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container",
            "org.mozilla.firefox"
        ),
        (
            "com.apple.avconferenced",
            "/usr/libexec/avconferenced",
            "com.apple.avconferenced"
        ),
        (
            "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
            "/Users/owner/Applications/Chrome Apps.localized/Google Meet.app/Contents/MacOS/app_mode_loader",
            "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
        ),
        ("com.google.Chrome", nil, "com.google.Chrome"),
        (
            "com.unknown.helper",
            "/Applications/Unknown.app/Contents/MacOS/Unknown Helper",
            "com.unknown.helper"
        ),
    ]

    /// Grades the owner table, so the live run can print the passed/total score beside
    /// `CALLS_OK`. Pure and instant; the fake map above is the whole world it sees.
    private static func ownerTableResults() -> (passed: Int, total: Int, failures: [String]) {
        var failures: [String] = []
        var passed = 0
        for (index, entry) in ownerTableCases.enumerated() {
            let actual = AudioProcessOwner.owner(
                reportedBundleID: entry.reported,
                executablePath: entry.path,
                bundleIDAt: { ownerTableBundleIDs[$0] }
            )
            if actual == entry.expected {
                passed += 1
            } else {
                failures.append(
                    "owner table case \(index) (\(entry.reported ?? "nil")) resolved to "
                        + "\(actual ?? "nil"), expected \(entry.expected ?? "nil")"
                )
            }
        }
        return (passed, ownerTableCases.count, failures)
    }

    /// M-02's rules: helper processes resolve to their owning app before any policy runs,
    /// `replayd` is never a call, helper-keyed answers migrate once, and WebKit engine
    /// processes are ask-only. Fabricated throughout, like every other list here.
    private static func callOwnerFailures() -> [String] {
        var failures: [String] = []

        // a. The path rule: the outermost `.app` scanning from the root.
        let pathCases: [(path: String, expected: String?)] = [
            (
                "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/146.0.0.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                "/Applications/Google Chrome.app"
            ),
            (
                "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/146.0.0.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
                "/Applications/Google Chrome.app"
            ),
            (
                "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper",
                "/Applications/Cursor.app"
            ),
            (
                "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container",
                "/Applications/Firefox.app"
            ),
            ("/usr/libexec/avconferenced", nil),
            (
                "/Users/owner/Applications/Chrome Apps.localized/Google Meet.app/Contents/MacOS/app_mode_loader",
                "/Users/owner/Applications/Chrome Apps.localized/Google Meet.app"
            ),
        ]
        for entry in pathCases {
            let actual = AudioProcessOwner.outermostAppPath(executablePath: entry.path)
            if actual != entry.expected {
                failures.append(
                    "outermostAppPath(\(entry.path)) is \(actual ?? "nil"), "
                        + "expected \(entry.expected ?? "nil")"
                )
            }
        }

        // b. The 8-case owner table.
        let ownerResults = ownerTableResults()
        failures.append(contentsOf: ownerResults.failures)

        // c. A resolved Chrome helper is a browser: Ask/Never only, never unasked.
        let chromeOwner = AudioProcessOwner.owner(
            reportedBundleID: "com.google.Chrome.helper",
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/146.0.0.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            bundleIDAt: { ownerTableBundleIDs[$0] }
        ) ?? "com.google.Chrome.helper"
        if CallPolicy.availableAnswers(forApp: chromeOwner).contains(.always) {
            failures.append("a resolved Chrome helper was offered Always record")
        }
        if CallPolicy.recordsWithoutAsking(bundleID: chromeOwner, autoRecord: true, answer: nil) {
            failures.append("a resolved Chrome helper recorded without being asked about")
        }

        // d. Screen recording is never a call and never an app-list row.
        let replayd = CallPolicy.AudioProcess(
            pid: 930,
            bundleID: "com.apple.replayd",
            reportedBundleID: nil,
            name: "replayd",
            isRunningInput: true,
            isRunningOutput: true
        )
        if CallPolicy.isCall(replayd, ownPID: 501) {
            failures.append("com.apple.replayd counted as a call")
        }
        if CallPolicy.isMicrophoneApp(replayd, ownPID: 501) {
            failures.append("com.apple.replayd was listed as an app to answer for")
        }

        // e. Migration over this Mac's real dictionaries, copied as literals.
        let answers: [String: String] = [
            "com.google.Chrome.helper": "ask",
            "com.google.Chrome.helper.renderer": "always",
            "com.apple.replayd": "ask",
            "com.openai.codex.helper": "ask",
            "com.todesktop.230313mzl4w4u92": "always",
            "com.todesktop.230313mzl4w4u92.helper": "never",
            "net.whatsapp.WhatsApp": "ask",
        ]
        let seen: [String: String] = [
            "com.google.Chrome.helper": "Google Chrome Helper",
            "com.apple.replayd": "replayd",
        ]
        // Codex has no installed owner here; Chrome and Cursor do.
        let installed: (String) -> Bool = {
            ["com.google.Chrome", "com.todesktop.230313mzl4w4u92"].contains($0)
        }
        let migrated = AudioProcessOwner.migrate(
            answers: answers, seen: seen, installedApp: installed
        )
        if migrated.answers["com.google.Chrome"] != "ask" {
            failures.append("a Chrome helper answer did not move to com.google.Chrome as ask")
        }
        if migrated.answers["com.apple.replayd"] != nil {
            failures.append("com.apple.replayd kept an answer after migration")
        }
        if migrated.answers["com.openai.codex.helper"] != "ask" {
            failures.append("a helper with no installed owner was moved anyway")
        }
        if migrated.answers["com.todesktop.230313mzl4w4u92"] != "never" {
            failures.append("an always+never collision did not keep the more cautious answer")
        }
        if migrated.seen["com.google.Chrome"] != "Google Chrome" {
            failures.append("a Chrome helper seen-row did not move to com.google.Chrome")
        }
        if migrated.seen["com.apple.replayd"] != nil {
            failures.append("com.apple.replayd kept a seen-row after migration")
        }
        let twice = AudioProcessOwner.migrate(
            answers: migrated.answers, seen: migrated.seen, installedApp: installed
        )
        if twice.answers != migrated.answers || twice.seen != migrated.seen {
            failures.append("running the migration twice changed something")
        }

        // f. A WebKit engine process is ask-only: it could be Safari or any app's web view.
        if CallPolicy.recordsWithoutAsking(
            bundleID: "com.apple.WebKit.GPU", autoRecord: true, answer: .always
        ) {
            failures.append("a WebKit engine process recorded without being asked about")
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

            var failures = await Self.islandStateFailures()
            failures.append(contentsOf: Self.islandViewFailures())
            failures.append(contentsOf: AgentWorkingCard.scriptedFourStepFailures())

            // The one property this panel must never lose. A key island would take focus
            // away from the text field `TextInjector` is about to type into.
            let state = IslandState()
            let panel = IslandPanel(state: state)
            if panel.canBecomeKey { failures.append("the island panel can become key") }
            if panel.canBecomeMain { failures.append("the island panel can become main") }
            if panel.level.rawValue <= NSWindow.Level.statusBar.rawValue {
                failures.append("the island sits at or below the menu bar")
            }
            if !panel.ignoresMouseEvents {
                failures.append("a hidden island is taking mouse events")
            }

            // Actually put it on screen for a moment. Everything above this is arithmetic;
            // this is the part that fails when the hosting view, the frame or the tracking
            // loop is wrong, and none of it is visible from a terminal otherwise.
            state.announceNotesReady(Meeting(title: "Self-test", start: Date(), status: .done))
            try? await Task.sleep(for: .seconds(Self.islandSettle))
            if !panel.isVisible { failures.append("an island with something to say never appeared") }
            if panel.alphaValue < 0.99 {
                failures.append("a visible island never finished fading in")
            }
            if panel.ignoresMouseEvents {
                failures.append("an expanded island is ignoring the mouse it has buttons for")
            }
            // Compare against the screen the panel actually occupies — not
            // `screenUnderMouse()` at check time. On a multi-display desk the
            // pointer can move during the settle wait, and that would fail a
            // correctly placed island. Allow one point of rounding: Retina
            // frames often land a fraction off the pure arithmetic.
            let panelCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(panelCenter) })
                ?? IslandGeometry.screenUnderMouse() {
                let expected = IslandGeometry.metrics(for: screen).bounds
                let dx = abs(panel.frame.minX - expected.minX)
                let dy = abs(panel.frame.minY - expected.minY)
                let dw = abs(panel.frame.width - expected.width)
                let dh = abs(panel.frame.height - expected.height)
                if dx > 1 || dy > 1 || dw > 1 || dh > 1 {
                    let got = "\(Int(panel.frame.minX)),\(Int(panel.frame.minY)) \(Int(panel.frame.width))x\(Int(panel.frame.height))"
                    let want = "\(Int(expected.minX)),\(Int(expected.minY)) \(Int(expected.width))x\(Int(expected.height))"
                    failures.append(
                        "the island is not where its own geometry puts it (got \(got); expected \(want) on \(screen.localizedName))"
                    )
                }
            } else {
                failures.append("the island is on no screen")
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
    /// P1-16 against the **real** gate, including the path that matters most: the Needle
    /// watcher's 180 s expiry, which today leaves a card holding its only slot while nothing
    /// on screen says it is there.
    ///
    /// Only `cancelPending(id:)` is used to end an ask. `respond(approved: true)` on a request
    /// whose tool exists would *execute* it, and a self-test must never do that — so the
    /// expiry is reproduced the way the watcher produces it, by cancelling the asker.
    @MainActor
    private static func pendingApprovalGateFailures() async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        guard let tool = AgentToolRegistry.shared.tool(named: "schedule.list") else {
            return ["P1-16: the fixture tool is not registered"]
        }
        // Built the way `FunctionCallWatcher.request(for:tool:trigger:)` builds one, which is
        // `static` and pure — so this is the shape that actually reaches the gate, not a
        // convenient one.
        let request = PermissionRequest(
            toolID: tool.id, title: "Reminder for 9", detail: "Set a reminder", risk: tool.risk,
            arguments: [:], scope: .any, meetingID: nil, taskID: nil,
            trigger: .youSaid("set a reminder"))
        let ask = Task { _ = await PermissionGate.shared.ask(request) }
        // The gate presents synchronously on the main actor, so one turn of the loop is enough;
        // the second attempt waits so a slow machine does not read as a failure.
        for _ in 0..<40 where PermissionGate.shared.pending == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard let pending = PermissionGate.shared.pending else {
            ask.cancel()
            return failures + ["P1-16: ask() did not present the request"]
        }
        check("the gate presented a different request than it was asked",
              pending.id == request.id)
        let live = IslandState()
        live.dismissNotice()
        if case .pendingApproval(let proposal, let waiting) = live.kind {
            check("the badge shows a different proposal than the gate's",
                  proposal.id == request.id)
            check("the badge counted something other than the one pending",
                  waiting == 1)
        } else {
            failures.append("P1-16: a default IslandState() does not show a pending approval "
                + "(\(live.kind))")
        }
        // The watcher's expiry: the asker is cancelled, and the badge must go with it.
        ask.cancel()
        for _ in 0..<40 where PermissionGate.shared.pending != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        check("cancelling the asker did not clear the gate", PermissionGate.shared.pending == nil)
        live.refresh()
        if case .pendingApproval = live.kind {
            failures.append("P1-16: the badge outlived the request it was showing")
        }
        return failures
    }

    private static func islandStateFailures() async -> [String] {
        // P1-16's fixture: a pending-approval source a case can move, so the whole live-state
        // machine is driven without a real `PermissionGate.ask` — which would need a
        // continuation resumed by a person who is not there. The *real* gate is exercised
        // separately, in `pendingApprovalGateFailures` below, including the expiry that clears it.
        final class PendingBox: @unchecked Sendable {
            var value: (IslandProposal, Int)?
        }
        let box = PendingBox()
        let state = IslandState(pendingApproval: { box.value })
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        check("a fresh island is hidden", state.kind == .hidden)

        // --- P1-16: the approval outlives its notice -------------------------------
        let p = IslandProposal(
            id: "selftest-approval", title: "Send the deck to Ana", detail: "The deck is ready.",
            meetingID: nil)
        state.propose(p)
        check("the notice shows the card as a notice", state.kind == .agentProposal(p))
        box.value = (p, 1)
        // Stands in for the eight-second lapse.
        state.dismissNotice()
        check("an approval vanished when its notice lapsed",
              state.kind == .pendingApproval(p, waiting: 1))
        check("the pending badge opened by itself", state.isExpanded == false)
        check("the pending badge has no identity of its own",
              state.kind.identity == "pending:selftest-approval:1")
        state.isHovered = true
        check("hovering did not expand a pending badge", state.isExpanded)
        state.isHovered = false
        check("hovering left the badge collapsed again", state.isExpanded == false)
        check("hovering changed the badge's kind", state.kind == .pendingApproval(p, waiting: 1))
        box.value = (p, 2)
        state.refresh()
        check("a second request is not counted", state.kind == .pendingApproval(p, waiting: 2))
        check("the count did not change the badge's identity",
              state.kind.identity == "pending:selftest-approval:2")
        box.value = nil
        state.refresh()
        check("the badge did not clear when the gate emptied", state.kind != .pendingApproval(p, waiting: 2))
        check("the badge left the island showing something else",
              state.kind == .hidden || state.kind == .agentProposal(p))

        // The priority table, graded directly. `liveKind` cannot be driven into a pending
        // approval *and* a meeting session in one test, and the order is the whole decision.
        func winner(working: Bool = false, listening: Bool = false, dictating: Bool = false,
                    pending: Bool = false, recording: Bool = false) -> IslandState.LiveSource {
            IslandState.liveWinner(working: working, listening: listening, dictating: dictating,
                                   pending: pending, recording: recording)
        }
        check("a working agent loses to a pending approval",
              winner(working: true, pending: true) == .pendingApproval)
        check("listening wins over a pending approval",
              winner(listening: true, pending: true) == .listening)
        check("dictation wins over a pending approval",
              winner(dictating: true, pending: true) == .dictating)
        check("a pending approval wins over a recording",
              winner(pending: true, recording: true) == .pendingApproval)
        check("a working agent is a working agent when nothing is pending",
              winner(working: true) == .working)
        check("a recording is still a recording",
              winner(recording: true) == .recording)
        check("nothing live is nothing", winner() == .none)

        failures.append(contentsOf: await pendingApprovalGateFailures())
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
        check("an armed meeting's card identity names it", state.cardIdentity == "armed:\(event.id)")
        state.clearArmed(event)
        check("answering an armed meeting takes it down", state.kind == .hidden)
        check("answering an armed meeting hides the card", state.cardIdentity == "hidden")

        let meeting = Meeting(title: "Self-test", start: Date(), status: .done)
        state.announceNotesReady(meeting)
        check(
            "finished notes show",
            state.kind == .notesReady(meetingID: meeting.id, title: meeting.title)
        )
        check("finished notes open the island by itself", state.isExpanded)
        state.dismissNotice()
        check("dismissing finished notes takes them down", state.kind == .hidden)
        check("dismissing finished notes hides the card", state.cardIdentity == "hidden")

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
        // The panel keys off identity, not Equatable: a louder buffer must not look like
        // a different card, or `present()` restarts the fade and the island blinks.
        check("a louder dictation is still dictating", IslandState.Kind.dictating(
            transcript: "a", level: 0.1, isCapturing: true
        ).identity == IslandState.Kind.dictating(
            transcript: "ab", level: 0.9, isCapturing: true
        ).identity)
        check("letting go is a different card", IslandState.Kind.dictating(
            transcript: "", level: 0, isCapturing: true
        ).identity != IslandState.Kind.dictating(
            transcript: "", level: 0, isCapturing: false
        ).identity)

        // An orb never replaces the red dot, it sits beside it: a recording — dictation
        // or a meeting — draws both. Only the orb half is visible from here; the dot is
        // `IslandView.badge`'s, and it is drawn while the microphone is open.
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

        // A recording with no session, and a listen with no reply, must still have words.
        // Reaching into MeetingController / AgentCaptureController from IslandView.content
        // is what SIGSEGV'd the process (`assumeIsolated` on a view-body getter).
        let bare = IslandState()
        bare.apply(.meetingRecording(elapsed: 0, micLevel: 0, systemLevel: 0))
        check("a recording with no session still titles itself", bare.cardTitle == "Recording")
        check(
            "a listen with a transcript uses it",
            bare.listeningDetail("hello") == "hello"
        )
        check("an empty listen still has a line", !bare.listeningDetail("").isEmpty)

        // M-06: a detected call's question outlives its 8 s notice as a collapsed pill
        // until the call ends or is answered. Title is the current `event.title` path;
        // the M-02 owner name arrives with that task.
        let callEvent = MeetingEvent(
            id: "selftest-call",
            providerID: .detectedCall,
            title: "WhatsApp call",
            start: Date().addingTimeInterval(-30),
            end: Date().addingTimeInterval(-30),
            attendees: [],
            isOrganizerOrSelfAccepted: true,
            conferenceURL: nil,
            calendarName: "WhatsApp",
            isAllDay: false
        )
        let callState = IslandState()
        callState.announceArmed(callEvent)
        check("a detected call shows its card", callState.kind == .meetingArmed(callEvent))
        check("a detected call card opens by itself", callState.isExpanded)
        callState.expireNotice()
        check("kind == .callQuestion", callState.kind == .callQuestion(callEvent))
        check("the call pill stays collapsed", !callState.isExpanded)
        check("the call pill breathes", callState.kind.orb == .breathing)
        check("the call pill asks nothing red", callState.cardTitle == callEvent.title)
        check(
            "the call pill does not demand attention",
            !IslandState.Kind.callQuestion(callEvent).demandsAttention
        )
        check(
            "the call pill identity names it",
            callState.cardIdentity == "call-question:\(callEvent.id)"
        )
        callState.isHovered = true
        check("hovering the call pill expands it", callState.isExpanded)
        callState.isHovered = false

        // b. A later notice covers the pill; when it goes away the question is back.
        callState.announceNotesReady(meeting)
        check(
            "notes cover the call pill",
            callState.kind == .notesReady(meetingID: meeting.id, title: meeting.title)
        )
        callState.dismissNotice()
        check("the call pill returns after notes", callState.kind == .callQuestion(callEvent))

        // c. Answering takes the pill down for good.
        callState.clearArmed(callEvent)
        check("answering a call takes the pill down", callState.kind == .hidden)
        check("answering a call forgets it", callState.armedCall == nil)

        // d. Calendar meetings get no pill: expiry leaves nothing behind.
        let calendarState = IslandState()
        calendarState.announceArmed(event)
        calendarState.expireNotice()
        check("a calendar card leaves no pill", calendarState.kind == .hidden)
        check("a calendar card is forgotten", calendarState.armedCall == nil)

        return failures
    }

    /// Evaluates `IslandView.body` for every card, including kinds that have no session
    /// and no agent. The crash was `content.getter` — a body that cannot be built must
    /// not print `ISLAND_OK`.
    @MainActor
    private static func islandViewFailures() -> [String] {
        let floating = IslandGeometry.Metrics(
            bounds: NSRect(x: 0, y: 0, width: 400, height: 180),
            collapsedSize: CGSize(width: 200, height: 32),
            expandedSize: CGSize(width: 400, height: 180),
            notchWidth: 0,
            hugsNotch: false
        )
        let hugging = IslandGeometry.Metrics(
            bounds: NSRect(x: 0, y: 0, width: 400, height: 180),
            collapsedSize: CGSize(width: 200, height: 32),
            expandedSize: CGSize(width: 400, height: 180),
            notchWidth: 80,
            hugsNotch: true
        )

        let armed = MeetingEvent(
            id: "island-view",
            providerID: .fake,
            title: "Standup",
            start: Date().addingTimeInterval(60),
            end: Date().addingTimeInterval(1_860),
            attendees: ["Sam"],
            isOrganizerOrSelfAccepted: true,
            conferenceURL: nil,
            calendarName: "Test",
            isAllDay: false
        )
        let kinds: [IslandState.Kind] = [
            .hidden,
            .dictating(transcript: "hello", level: 0.4, isCapturing: true),
            .dictating(transcript: "", level: 0, isCapturing: false),
            .meetingArmed(armed),
            .meetingRecording(elapsed: 12, micLevel: 0.2, systemLevel: 0),
            .transcribing,
            .diarizing(progress: 0.3),
            .summarizing(progress: nil),
            .notesReady(meetingID: UUID(), title: "Weekly"),
            .agentProposal(IslandProposal(
                id: "view",
                title: "Send",
                detail: "Email Sam.",
                meetingID: nil
            )),
            .agentListening(transcript: "", level: 0.1),
            .agentWorking(title: "Searching mail"),
            .agentReply("Done."),
            .problem("No microphone audio reached dictation."),
            // P1-16: the live approval badge, at both waiting counts, because "1 waiting" and
            // "2 waiting" are different layouts and a card that only ever renders the first is
            // a card that has never been checked in the state it spends most of its life in.
            .pendingApproval(IslandProposal(
                id: "view-pending",
                title: "Send the deck to Ana",
                detail: "Email Sam with the deck.",
                meetingID: nil
            ), waiting: 1),
            .pendingApproval(IslandProposal(
                id: "view-pending",
                title: "Send the deck to Ana",
                detail: "Email Sam with the deck.",
                meetingID: nil
            ), waiting: 3),
        ]

        var failures: [String] = []
        let state = IslandState()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: floating.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        for metrics in [floating, hugging] {
            for kind in kinds {
                state.apply(kind)
                state.isHovered = true
                let hosting = NSHostingView(rootView: IslandView(state: state, metrics: metrics))
                hosting.frame = NSRect(origin: .zero, size: metrics.expandedSize)
                panel.contentView = hosting
                panel.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
                if hosting.bounds.isEmpty {
                    failures.append("\(kind.identity) hosted in an empty frame")
                }
            }
        }

        return failures
    }

    /// Builds every orb at both sizes and checks the frames are drawable and moving.
    ///
    /// The geometry is trigonometry over tuned constants, and the failure mode of getting it
    /// wrong is not a crash but a blank patch or a single dot in the corner — which nobody
    /// notices in a 20pt badge. This asks the four questions a screenshot would answer:
    /// are there dots, are they finite, are they inside the frame, and do they move.
    /// `--selftest-settings` — every Settings pane is reachable, every heading
    /// still contains U+0020, and no pane asks for more width than the narrowest host
    /// that can show it has. A toolbar `TabView` hid Integrations, Models and
    /// Permissions behind a chevron; a compact Settings frame cropped the form off;
    /// and a view-level minimum wider than the main window's detail column drew the
    /// form past the right edge of a narrow window, clipped. The visual companion is
    /// `--settings-sheet`, which renders each pane at the widths it meets.
    private func runSettingsSelfTest() {
        Task { @MainActor in
            var failures = SettingsTab.catalogFailures()
            failures.append(contentsOf: SettingsTab.renderFailures(controller: controller))
            for tab in SettingsTab.allCases {
                let titleSpaces = SettingsTab.spaceCount(in: tab.title)
                let headingSpaces = SettingsTab.spaceCount(in: tab.heading)
                writeSelfTest(
                    "  \(tab.rawValue): title \(tab.title.debugDescription) "
                    + "(\(titleSpaces) U+0020) heading \(tab.heading.debugDescription) "
                    + "(\(headingSpaces) U+0020)"
                )
            }
            writeSelfTest(
                "  agent: title \(AgentView.headingTitle.debugDescription) "
                + "(\(SettingsTab.spaceCount(in: AgentView.headingTitle)) U+0020)"
            )
            writeSelfTest(
                "  tracking: eyebrow \(DS.Font.eyebrowTracking) word \(DS.Font.wordTracking)"
            )
            for failure in failures { writeSelfTest("  SETTINGS_WRONG: \(failure)") }
            if failures.isEmpty {
                writeSelfTest(
                    "SETTINGS_OK: \(SettingsTab.allCases.count) pane(s), "
                    + "Formatting listed, "
                    + "headings contain U+0020, each form built, profile captured, "
                    + "auto-send policy, every pane fits the narrowest host"
                )
            } else {
                writeSelfTest("SETTINGS_FAILED: \(failures.count) problem(s)")
            }
            NSApp.terminate(nil)
        }
    }

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

    /// The Workspace tool layer, checked in two halves.
    ///
    /// The fixture half first, and it needs nothing: the rules worth pinning about the runner
    /// — what it asks Gmail for, what it reads back, which invented operator it refuses — are
    /// about arguments and JSON, and a fake CLI answers both without a binary, a keyring, an
    /// account or a model. It prints `GWS_FIXTURES_OK` before anything is launched, so a build
    /// whose mailbox contract is wrong is caught on a machine that has never signed in, and a
    /// run whose fixtures failed says so even when the binary half would have passed.
    ///
    /// The binary half then answers what only this Mac can: is `gws` installed, and how far
    /// along is its own setup. It reads and never writes — `--version` and `auth status` are
    /// the two commands `gws` answers without touching Google, so the second half is still
    /// runnable on a machine that has never signed in.
    private func runWorkspaceCLISelfTest() {
        Task { @MainActor in
            // Printed through `writeSelfTest` and not `print`, so the `_WRONG` lines and the
            // marker keep their order: the two write to different buffers, and a mixed run
            // puts the marker before the reasons it is reporting.
            let fixtureFailures = await WorkspaceToolRunner.selfTestFailures()
            for failure in fixtureFailures { writeSelfTest("GWS_FIXTURES_WRONG: \(failure)") }
            if fixtureFailures.isEmpty {
                writeSelfTest("GWS_FIXTURES_OK: 10 cases")
            } else {
                writeSelfTest("GWS_FIXTURES_FAILED: \(fixtureFailures.count) problem(s) in 10 cases")
            }

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
            } else if !fixtureFailures.isEmpty {
                // The fixtures are the part this run can be held to, so a failed one is the
                // run's verdict even when the binary answered.
                writeSelfTest("GWS_FAILED: \(fixtureFailures.count) fixture case(s) failed")
            } else {
                writeSelfTest("GWS_OK: \(version) at \(binary.path), \(state.displayName.lowercased())")
            }
            // A read against the real account, for the one number the fixtures cannot give:
            // how long ten messages actually take. Counts and a duration only — a subject, a
            // sender or a snippet on this line would put the owner's mail in a log file.
            if CommandLine.arguments.contains("--live-mail") {
                await writeLiveMailReading()
            }
            NSApp.terminate(nil)
        }
    }

    /// `GWS_LIVE_MAIL: <n> messages, <n> senders parsed, <s>s` — and nothing else.
    ///
    /// The runner's own summary is never printed. A count of lines that contain a sender and
    /// a subject is the whole claim: it says the shape was understood without saying what
    /// was in the mailbox. A failure prints the error class, not the error text, because a
    /// `gws` refusal can quote the query back.
    private func writeLiveMailReading() async {
        let started = Date()
        do {
            let result = try await WorkspaceToolRunner.run(AgentProposal(
                meetingID: UUID(), tool: "search_email",
                arguments: ["maxResults": "3"], rationale: ""),
                cli: GoogleWorkspaceCLI.shared)
            let lines = result.summary.split(separator: "\n").filter { $0.contains(") ") }
            let withSender = lines.filter { !$0.contains("unknown sender") }.count
            let withSubject = lines.filter { $0.contains(" · ") }.count
            let seconds = Date().timeIntervalSince(started)
            writeSelfTest("GWS_LIVE_MAIL: \(lines.count) messages, "
                + "\(withSender) senders parsed, \(withSubject) subjects parsed, "
                + String(format: "%.2fs", seconds))
        } catch {
            writeSelfTest("GWS_LIVE_MAIL_FAILED: "
                + String(describing: type(of: error)))
        }
    }

    /// Runs the agent over a meeting folder and prints what it would propose.
    ///
    /// Nothing is executed: the policy is `dryRun`, so no read tool runs either, and every
    /// proposal is printed rather than performed. Two halves again — the catalogue and the
    /// parser are checked without a model, so a build whose tool schemas stopped being valid
    /// JSON is caught on a machine with no multi-gigabyte download and no Google account.
    ///
    /// - Parameter directory: a meeting folder under
    ///   `Application Support/Next Notes/Meetings/`.
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
            guard let provider = await ModelRoleStore.shared.provider(for: .agent) else {
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
                    AGENT_\(failures.isEmpty ? "OK" : "FAILED"): \(provider.displayModelName) \
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
    /// whether Parakeet and a multi-gigabyte model can both be alive on this machine, and it happens
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
    /// Fails a self-test that stops making progress, instead of letting it hang forever.
    ///
    /// Dies with the process, so a test that finishes normally never sees it. Exits non-zero
    /// rather than calling `NSApp.terminate`, because a timeout is a failure and a script
    /// that runs these needs to be able to tell.
    /// Registry, router and broker — no model, no account, no execution of a write.
    private func runToolsSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }

            let registry = AgentToolRegistry.shared
            check("workspace tools are missing", registry.tool(named: "search_email") != nil)
            check("canonical workspace alias is missing", registry.tool(named: "workspace.search_email") != nil)
            check("meeting context tool is missing", registry.tool(named: "meeting.action_items") != nil)
            check("computer inspect is missing", registry.tool(named: "computer.inspect_ui") != nil)
            check("computer type is missing", registry.tool(named: "computer.type") != nil)
            check("computer click is missing", registry.tool(named: "computer.click") != nil)
            check("filesystem search is missing", registry.tool(named: "filesystem.search") != nil)
            check("shell run is missing", registry.tool(named: "shell.run") != nil)
            check("browser snapshot is missing", registry.tool(named: "browser.snapshot") != nil)

            if case .tool(let id) = ToolRouter.resolve("search_email") {
                check("router did not prefer native Gmail", id == "search_email")
            } else {
                failures.append("router lost search_email")
            }

            guard let write = registry.tool(named: "send_email") else {
                failures.append("send_email vanished")
                writeSelfTest("TOOLS_FAILED: \(failures.joined(separator: "; "))")
                NSApp.terminate(nil)
                return
            }
            let denied = await PermissionBroker.shared.authorize(
                write,
                arguments: ["to": "a@x.com", "subject": "x", "body": "y"],
                policy: .denyMutations
            )
            if case .ask = denied {
                // The broker must stop a send.
            } else {
                failures.append("a send was not held for confirmation")
            }

            let observe = registry.tool(named: "computer.active_app")!
            let allowed = await PermissionBroker.shared.authorize(
                observe,
                arguments: [:],
                policy: PermissionPolicy(autoObserve: true, autoRead: false)
            )
            check("observe was not automatic", allowed == .allow)

            do {
                _ = try await AgentToolExecutor.run(
                    "send_email",
                    arguments: ["to": "a@x.com", "subject": "x", "body": "y"],
                    policy: .denyMutations
                )
                failures.append("a send executed without the broker allowing it")
            } catch AgentError.needsPermission, AgentError.permissionDenied {
                // Expected.
            } catch {
                failures.append("send failed for the wrong reason: \(error.localizedDescription)")
            }

            check("unknown tools are not the most dangerous class", AgentProposal(
                meetingID: UUID(), tool: "delete_everything", arguments: [:], rationale: ""
            ).risk == .send)

            let click = registry.tool(named: "computer.click")!
            let chrome = PermissionScope(kind: .application, value: "com.google.Chrome")
            let safari = PermissionScope(kind: .application, value: "com.apple.Safari")
            var scoped = PermissionPolicy.denyMutations
            scoped.grants = [
                PermissionGrant(toolID: click.id, duration: .alwaysThisAction, scope: chrome)
            ]
            let chromeOK = await PermissionBroker.shared.authorize(
                click,
                arguments: ["app": "com.google.Chrome"],
                policy: scoped,
                scope: chrome
            )
            let safariHeld = await PermissionBroker.shared.authorize(
                click,
                arguments: ["app": "com.apple.Safari"],
                policy: scoped,
                scope: safari
            )
            check("a Chrome grant did not cover Chrome", chromeOK == .allow)
            if case .ask = safariHeld {
                // Expected — Safari is a different app.
            } else {
                failures.append("a Chrome grant covered Safari")
            }
            check(
                "an unrestricted grant covered an unresolved browser target",
                !PermissionScope.any.covers(
                    PermissionScope(kind: .unresolved, value: "browser-target")
                )
            )

            check(
                "canonical github mapping",
                CanonicalToolName.resolve(raw: "GITHUB_CREATE_ISSUE", server: "Composio").id
                    == "github.create_issue"
            )
            check(
                "prefixed Composio mapping",
                CanonicalToolName.resolve(raw: "mcp.Composio.GITHUB_CREATE_ISSUE", server: "Composio").id
                    == "github.create_issue"
            )
            check(
                "create_issue is not a write",
                MCPRiskHint.risk(name: "github.create_issue", annotations: [:]) == .write
            )
            check(
                "slack send is not communicate",
                MCPRiskHint.risk(name: "slack.send_message", annotations: [:]) == .send
            )
            check(
                "filesystem delete is not destructive",
                MCPRiskHint.risk(name: "filesystem.delete", annotations: [:]) == .destructive
            )
            check(
                "read_file is not a read",
                MCPRiskHint.risk(name: "filesystem.read_file", annotations: [:]) == .read
            )

            for failure in failures { writeSelfTest("  TOOLS_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                          ? "TOOLS_OK: registry, router and broker hold"
                          : "TOOLS_FAILED: \(failures.count) rule(s) wrong")
            NSApp.terminate(nil)
        }
    }

    /// Accent variants. These are the difference between a wake phrase that works for
    /// one accent and one that works for the person who reported this.
    private func wakeVariantFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let heyWill = ["HH", "EY1", "W", "IH1", "L"]
        let deep = WakeWordVariants.variants(forPhones: heyWill, depth: 6)
        check("no accent variants were generated for Hey Will", !deep.isEmpty)
        check(
            "the dropped-h pronunciation is missing — the commonest form of this accent",
            deep.contains { $0.phones == ["EY1", "W", "IH1", "L"] }
        )
        check(
            "the softened final consonant is missing",
            deep.contains { $0.phones == ["HH", "EY1", "W", "IH1"] }
        )
        check(
            "the tense-vowel pronunciation is missing",
            deep.contains { $0.phones == ["HH", "EY1", "W", "IY1", "L"] }
        )
        check("a variant repeats the canonical pronunciation", !deep.contains { $0.phones == heyWill })
        check("variants are not unique", Set(deep.map(\.phones)).count == deep.count)
        check(
            "a variant is short enough to fire on ordinary speech",
            deep.allSatisfy { $0.phones.count >= WakeWordVariants.minimumPhones }
        )
        check("depth 0 still produced variants", WakeWordVariants.variants(forPhones: heyWill, depth: 0).isEmpty)
        check("depth is not honoured", WakeWordVariants.variants(forPhones: heyWill, depth: 2).count == 2)
        check(
            "the first variant is not the most useful one for this accent",
            WakeWordVariants.variants(forPhones: heyWill, depth: 1).first?.phones == ["EY1", "W", "IH1", "L"]
        )
        check(
            "variants grow with depth",
            WakeWordVariants.variants(forPhones: heyWill, depth: 6).count
                >= WakeWordVariants.variants(forPhones: heyWill, depth: 3).count
        )
        check("every variant states a reason", deep.allSatisfy { !$0.rule.isEmpty })
        check("stress digits are lost when a vowel is rewritten",
              WakeWordVariants.tensingLastVowel(heyWill) == ["HH", "EY1", "W", "IY1", "L"])
        check("ARPAbet vowels are not recognised", WakeWordVariants.isVowel("IH1") && !WakeWordVariants.isVowel("W"))

        // The keywords file is what sherpa actually reads.
        let sensitive = WakeWordTuning.forSensitivity(1)
        guard let text = WakeWordKeywords.file(for: "Hey Will", tuning: sensitive) else {
            return failures + ["Hey Will produced no keywords file"]
        }
        let lines = text.split(separator: "\n").map(String.init)
        check("the keywords file lost the canonical pronunciation", lines.first == "HH EY1 W IH1 L @HEY_WILL")
        check("the keywords file has no accent variants at maximum sensitivity", lines.count > 1)
        check(
            "every keyword line must name the same phrase",
            lines.allSatisfy { $0.hasSuffix("@HEY_WILL") }
        )
        check(
            "variant lines carry no threshold of their own",
            lines.dropFirst().allSatisfy { $0.contains("#") }
        )
        check(
            "the canonical line must not carry a per-keyword threshold",
            !(lines.first ?? "").contains("#")
        )
        // A letter-spelled fallback here is what aborted the sherpa dylib.
        check(
            "an unpronounceable phrase produced a keywords file",
            WakeWordKeywords.file(for: "Hey Xyzzy", tuning: sensitive) == nil
        )
        check(
            "the conservative end still writes variants",
            (WakeWordKeywords.file(for: "Hey Will", tuning: .forSensitivity(0)) ?? "")
                .split(separator: "\n").count == 1
        )
        // The diagnostic file must name each pronunciation separately, or the Settings
        // test cannot say which one matched.
        guard let diagnostic = WakeWordKeywords.diagnosticFile(for: "Hey Will", tuning: sensitive) else {
            return failures + ["no diagnostic keywords file for Hey Will"]
        }
        let tags = diagnostic.text.split(separator: "\n").compactMap { line in
            line.split(separator: "@").last.map(String.init)
        }
        check("diagnostic keyword tags are not unique", Set(tags).count == tags.count)
        check("a diagnostic tag has no rule attached", tags.allSatisfy { diagnostic.rules[$0] != nil })
        return failures
    }

    /// The Sensitivity slider. It used to move one number that this model ignores.
    private func wakeTuningFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let quiet = WakeWordTuning.forSensitivity(0)
        let middle = WakeWordTuning.forSensitivity(0.5)
        let loud = WakeWordTuning.forSensitivity(1)

        check("sensitivity does not lower the threshold", loud.threshold < quiet.threshold)
        check("the conservative end is not conservative", quiet.threshold > middle.threshold)
        // Below 0.15 recall is flat and false accepts are not, so the slider stops there.
        check("maximum sensitivity does not reach the measured recall ceiling", loud.threshold <= 0.15)
        check("sensitivity pushed the threshold past the useful floor", loud.threshold >= 0.15)
        check("the conservative end does not reach a strict threshold", quiet.threshold >= 0.40)
        check("sensitivity does not add pronunciations", loud.variantDepth > quiet.variantDepth)
        check("the conservative end listens for variants", quiet.variantDepth == 0)
        check("maximum sensitivity does not reach the measured best variant count",
              loud.variantDepth == 4)
        // The beam is the knob that makes variants worth having at all: with sherpa's
        // stock width of 4 they evict each other and recall falls. The measured plateau
        // is 16 — beam 24 held the same recall on the committed corpus while letting two
        // more near-misses through (`--selftest-wake-live`).
        check("sensitivity does not widen the decoder beam", loud.maxActivePaths > quiet.maxActivePaths)
        check("the beam is too narrow to hold the variants", loud.maxActivePaths == 16)
        check("the conservative end does not fall back to the stock beam", quiet.maxActivePaths == 4)
        check("variants are held to a looser bar than the phrase itself",
              loud.variantThreshold >= loud.threshold)
        // Two trailing blanks beat sherpa's default of one everywhere in the grid, so
        // this is a constant rather than a slider position.
        check("trailing blanks fell back to the sherpa default",
              quiet.numTrailingBlanks == 2 && loud.numTrailingBlanks == 2)
        check("tuning is not monotonic in sensitivity",
              WakeWordTuning.forSensitivity(0.1).threshold > WakeWordTuning.forSensitivity(0.4).threshold)
        check("the beam does not grow monotonically",
              WakeWordTuning.forSensitivity(0.25).maxActivePaths < middle.maxActivePaths
                  && middle.maxActivePaths < loud.maxActivePaths)
        check("out-of-range sensitivity is not clamped",
              WakeWordTuning.forSensitivity(4) == loud && WakeWordTuning.forSensitivity(-2) == quiet)
        return failures
    }

    /// The phonetic second stage: “hey we need” is the phrase, a sentence is not.
    private func wakeConfirmationFailures() -> [String] {
        var failures: [String] = []
        func accepts(_ transcript: String) -> Bool {
            WakePhraseConfirmation.check(transcript: transcript, phrase: "Hey Will").accepted
        }
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // The ASR heard this user's wake phrase as “hey we need”. Requiring the literal
        // words is why the transcript wake path never fired for him.
        check("“hey we need” was not accepted as the phrase", accepts("hey we need"))
        check("the phrase as written was not accepted", accepts("hey will"))
        check("a dropped h was not accepted", accepts("ey will"))
        check("a tense vowel was not accepted", accepts("hey weel"))
        check("a spelling variant was not accepted", accepts("hey wil"))
        check("the phrase with a request after it was not accepted", accepts("hey will open chrome"))
        // Heard clearly, so the length of the request that follows is none of this
        // stage's business.
        check(
            "a clear phrase was refused for having a long request after it",
            accepts("hey will open chrome and go to youtube and search for cats")
        )

        // Long sentences are not someone addressing the agent.
        check("a whole sentence was accepted", !accepts("hey we need to talk about the budget"))
        check("a longer sentence was accepted", !accepts("hey we need to talk about the budget tomorrow"))
        check("a greeting was accepted", !accepts("hey there how are you doing today"))
        check("unrelated speech was accepted", !accepts("let me know if you still want the report"))
        check("a sentence mentioning the name was accepted", !accepts("the meeting with william is at four"))
        check("an unrelated short phrase was accepted", !accepts("hello"))

        let withRequest = WakePhraseConfirmation.check(transcript: "hey will open chrome", phrase: "Hey Will")
        check("the request after the phrase was lost", withRequest.remainder == "open chrome")
        check("the matched word count is wrong", withRequest.matchedWords == 2)
        check("an exact match did not score 1", withRequest.closeness > 0.99)
        check(
            "closeness does not rank a near miss below an exact match",
            WakePhraseConfirmation.check(transcript: "hey we need", phrase: "Hey Will").closeness
                < withRequest.closeness
        )
        check("empty speech was accepted", !accepts(""))
        check(
            "a same-class vowel swap costs as much as a different consonant",
            WakePhraseConfirmation.substitutionCost("IH1", "IY1")
                < WakePhraseConfirmation.substitutionCost("IH1", "K")
        )
        check(
            "the same phone with different stress is treated as a mismatch",
            WakePhraseConfirmation.substitutionCost("EY1", "EY0") == 0
        )
        check(
            "an unknown word is not spelled out into phones",
            WakePhraseConfirmation.spelledOut("ey") == ["EY"]
        )

        // The transcript wake path is what carries this into meetings and dictation.
        let configuration = WakeWordConfiguration(phrase: "Hey Will", sensitivity: 1, listenWhileSleeping: true)
        check(
            "the transcript path still needs the literal phrase",
            WakeWordDetector.spot(in: "Hey we need", configuration: configuration) != nil
        )
        let literal = WakeWordDetector.spot(
            in: "Hey Will, open Chrome and go to YouTube",
            configuration: configuration
        )
        check("the literal phrase stopped being spotted", literal != nil)
        check("the literal path lost the request", literal?.remainder.lowercased().hasPrefix("open chrome") == true)
        check(
            "a sound-alike is as confident as the words themselves",
            (WakeWordDetector.spot(in: "Hey we need", configuration: configuration)?.confidence ?? 1) < 1
        )
        check(
            "the transcript path accepted a whole sentence",
            WakeWordDetector.spot(
                in: "hey we need to talk about the budget tomorrow",
                configuration: configuration
            ) == nil
        )
        let system = TranscriptSegment(start: 0, end: 1, text: "Hey we need", source: .system)
        check(
            "system audio authorised a sound-alike command",
            WakeWordDetector.command(in: system, configuration: configuration) == nil
        )
        let mic = TranscriptSegment(start: 0, end: 1, text: "Hey we need", source: .mic)
        check(
            "the microphone could not authorise a sound-alike command",
            WakeWordDetector.command(in: mic, configuration: configuration) != nil
        )
        return failures
    }

    /// The watchdog state machine: believe the microphone, not the flag.
    private func wakeWatchdogFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        func restarts(
            voiceWake: Bool = true,
            sleepListening: Bool = true,
            idle: Bool = true,
            believes: Bool = true,
            seat: Bool = true,
            suspended: Bool = false
        ) -> Bool {
            WakeWordAudioMonitor.watchdogShouldRestart(
                voiceWakeEnabled: voiceWake,
                listenWhileSleeping: sleepListening,
                agentIsIdle: idle,
                believesItIsListening: believes,
                hubHasWakeSeat: seat,
                suspended: suspended
            )
        }

        check("a healthy listener was restarted", !restarts())
        // The failure the user actually hit: the flag says listening, the microphone
        // is gone, and nothing ever looked again.
        check("a lost microphone seat was not noticed", restarts(seat: false))
        check("a stopped listener was not restarted", restarts(believes: false))
        check("a suspended listener was left suspended while idle", restarts(suspended: true))
        check("wake restarted with voice wake off", !restarts(voiceWake: false))
        check("wake restarted with sleep listening off", !restarts(sleepListening: false))
        check("wake restarted while the agent was mid-conversation", !restarts(idle: false, seat: false))
        check("the watchdog interval is not set", WakeWordAudioMonitor.watchdogInterval > 0)

        check(
            "the status line does not name the phrase",
            WakeWordAudioMonitor.Status.listening(phrase: "Hey Will").plainWords.contains("Hey Will")
        )
        let plain: [WakeWordAudioMonitor.Status] = [
            .listening(phrase: "Hey Will"), .busyWithAgent, .voiceWakeOff,
            .sleepListeningOff, .modelMissing("x"), .phraseUnusable, .failed("x"),
        ]
        check("a status has no plain-words form", plain.allSatisfy { !$0.plainWords.isEmpty })
        check(
            "a paused state reads as listening",
            !WakeWordAudioMonitor.Status.busyWithAgent.plainWords.hasPrefix("Listening")
        )
        return failures
    }

    private func runWakeSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }

            check("normalize collapsed spaces", WakeWordConfiguration.normalize("  Hey   Next  ") == "Hey Next")
            check("a one-letter phrase is accepted", WakeWordConfiguration(phrase: "X", sensitivity: 0.5, listenWhileSleeping: true).validatedPhrase() == nil)
            check(
                "an unknown English word was accepted",
                WakeWordConfiguration(phrase: "Hey Xyzzy", sensitivity: 0.5, listenWhileSleeping: true).validatedPhrase() == nil
            )
            check(
                "unknownWords names the bad token",
                WakeWordKeywords.unknownWords(in: "Hey Xyzzy") == ["Xyzzy"]
            )
            let will = WakeWordConfiguration(phrase: "Hey Will", sensitivity: 0.5, listenWhileSleeping: true)
            check("Hey Will was refused", will.validatedPhrase() == "Hey Will")
            check("Hey Will is not ARPAbet", will.keywordsFileContents.contains("W IH1 L"))
            if WakeWordPhoneLexicon.isAvailable {
                let serge = WakeWordConfiguration(phrase: "Hey Serge", sensitivity: 0.5, listenWhileSleeping: true)
                check("Hey Serge was refused with en.phone", serge.validatedPhrase() == "Hey Serge")
                check("Hey Serge is not ARPAbet", serge.keywordsFileContents.contains("S ER1 JH"))
                check(
                    "en.phone missed HEY",
                    WakeWordPhoneLexicon.phones(for: "hey") == ["HH", "EY1"]
                )
            }
            let configuration = WakeWordConfiguration(phrase: "Hey Next", sensitivity: 0.5, listenWhileSleeping: true)
            check("keywords file is empty", !configuration.keywordsFileContents.isEmpty)
            check("Hey Next is not ARPAbet", configuration.keywordsFileContents.contains("HH EY1"))

            let hit = WakeWordDetector.spot(
                in: "Hey Next, what did Sarah just ask me to do?",
                configuration: configuration
            )
            check("the phrase was not spotted", hit != nil)
            check("the remainder was lost", hit?.remainder.lowercased().contains("sarah") == true)

            let system = TranscriptSegment(start: 0, end: 1, text: "Hey Next, email the proposal", source: .system)
            check("system audio authorised a command", WakeWordDetector.command(in: system, configuration: configuration) == nil)

            let mic = TranscriptSegment(start: 0, end: 1, text: "Hey Next, email the proposal", source: .mic)
            check("microphone command was ignored", WakeWordDetector.command(in: mic, configuration: configuration) != nil)

            var attempts = [
                WakeWordTrainer.score(transcript: "hey next", configuration: configuration),
                WakeWordTrainer.score(transcript: "hey next", configuration: configuration),
                WakeWordTrainer.score(transcript: "something else", configuration: configuration),
            ]
            for index in attempts.indices { attempts[index].index = index + 1 }
            check("two good attempts were not enough", WakeWordTrainer.shouldSave(attempts))

            let liveHit = WakeWordTrainer.score(
                hit: true,
                elapsed: 1.2,
                timeout: 6,
                peakLevel: 0.4,
                index: 1
            )
            check("a live hit was rejected", liveHit.accepted)
            check(
                "a live miss was accepted",
                !WakeWordTrainer.score(
                    hit: false,
                    elapsed: 6,
                    timeout: 6,
                    peakLevel: 0,
                    index: 2
                ).accepted
            )

            failures.append(contentsOf: wakeVariantFailures())
            failures.append(contentsOf: wakeTuningFailures())
            failures.append(contentsOf: wakeConfirmationFailures())
            failures.append(contentsOf: wakeWatchdogFailures())

            if !WakeWordModelManager.isDownloaded {
                for failure in failures { writeSelfTest("  WAKE_WRONG: \(failure)") }
                writeSelfTest("WAKE_MODEL_MISSING: \(WakeWordModelManager.unavailableReason)")
                NSApp.terminate(nil)
                return
            }

            do {
                // Never the live `keywords.txt`. Writing the test's own phrase there
                // replaced the user's configured “Hey Will” with “Hey Next” on disk,
                // which is a silent way to stop a wake word from ever firing again.
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nextnotes-selftest-keywords.txt")
                let liveKeywords = WakeWordModelManager.keywordsURL
                let before = try? Data(contentsOf: liveKeywords)
                try WakeWordModelManager.writeKeywords(configuration, to: scratch)
                let spotter = try WakeWordModelManager.loadSpotter(
                    keywords: scratch,
                    tuning: configuration.tuning
                )
                writeSelfTest("  WAKE_LOADED: \(WakeWordModels.encoderFile)")
                let after = try? Data(contentsOf: liveKeywords)
                if before != after {
                    failures.append("the self-test overwrote the configured wake phrase on disk")
                }
                if FileManager.default.fileExists(atPath: WakeWordModelManager.testEnglishWavURL.path),
                   FileManager.default.fileExists(atPath: WakeWordModelManager.testKeywordsURL.path) {
                    let probe = try WakeWordModelManager.loadSpotter(
                        keywords: WakeWordModelManager.testKeywordsURL,
                        tuning: .forSensitivity(1)
                    )
                    if let keyword = try probe.spot(wav: WakeWordModelManager.testEnglishWavURL) {
                        writeSelfTest("  WAKE_SPOTTED: \(keyword)")
                    } else {
                        failures.append("the loaded model did not spot the bundled English test wav")
                    }
                }
                _ = spotter
            } catch {
                failures.append("model did not load: \(error.localizedDescription)")
            }

            // ---- P1-29: a near miss is a row, with a score and without the words ----
            //
            // The text path computed a closeness score and discarded it on every rejection,
            // so "it nearly sounded right" was a number the machine knew and threw away. The
            // row carries the score and the reason; the transcript must never appear, because
            // this is written while a person is talking to their computer.
            do {
                let before = AgentAuditLog.shared.entries.count
                // A real rejection through the real detector, so this proves the feed is live
                // and not only that the writer works. This phrase is the interesting rejection:
                // it *opens* with something that sounds like the wake word and scores 0.667 —
                // above the bar — and is still refused because it arrived inside a longer
                // sentence. "hey we need" is not usable here: it scores 0.900 and is **accepted**,
                // which is the accent tolerance working, so it never reaches the rejection path.
                let rejected = WakeWordDetector.spot(
                    in: "hey world this is a long sentence about the weather",
                    configuration: will)
                check("a sound-alike inside a sentence was accepted", rejected == nil)
                // The row is written on the main actor, deliberately: the detector is
                // nonisolated real-time code and must not hop to decide whether to log, so
                // only a row that will actually be written crosses over. A test that asserted
                // in the same breath as the `spot` call was reading the list before the write
                // landed — which is not a race in production, where nothing reads it that fast.
                try? await Task.sleep(for: .milliseconds(150))
                let missRows = AgentAuditLog.shared.entries
                    .filter { $0.kind == .wakeMiss }
                check("a near miss wrote no row at all", !missRows.isEmpty)
                if let row = missRows.first(where: { $0.title == "Wake near miss" }) {
                    check(
                        "the near-miss row carried no score",
                        row.detail.contains("closeness=")
                    )
                    // The reason may name the configured phrase — that is the person's own
                    // setting, not what was said. What must never appear is the utterance.
                    let carriedWords = row.detail.contains("weather")
                        || row.detail.contains("hey world")
                    check("the near-miss row carried the transcript", !carriedWords)
                } else {
                    failures.append("no near-miss row for a rejected near phrase")
                }
                // The throttle: a second rejection inside the interval is not a second row.
                let afterFirst = AgentAuditLog.shared.entries.count
                _ = WakeWordDetector.spot(
                    in: "hey there we should probably talk about this later on",
                    configuration: will)
                try? await Task.sleep(for: .milliseconds(150))
                check(
                    "the near-miss throttle did not hold",
                    AgentAuditLog.shared.entries.count <= afterFirst + 1
                )
                // And the floor, checked with the score **ordinary conversation actually
                // scores** rather than a round zero — 0.333 is what idle chit-chat measured,
                // and a floor that let it through would turn the row into "the wake word is
                // armed", which the Settings screen already shows.
                let beforeChitChat = AgentAuditLog.shared.entries.count
                WakeWordTelemetry.recordNearMiss(
                    closeness: 0.333, reason: "the weather is nice today")
                try? await Task.sleep(for: .milliseconds(150))
                check("unrelated speech was recorded as a near miss",
                      AgentAuditLog.shared.entries.count <= beforeChitChat)
                check("the audit lost rows while a near miss was written",
                      AgentAuditLog.shared.entries.count >= before)
            } catch {
                failures.append("p1-29 near miss: \(error.localizedDescription)")
            }

            for failure in failures { writeSelfTest("  WAKE_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                          ? "WAKE_OK: model loaded; phrase spotting and authority split hold"
                          : "WAKE_FAILED: \(failures.count) rule(s) wrong")
            NSApp.terminate(nil)
        }
    }

    private func runTasksSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }

            let task = AgentTaskManager.shared.submit(
                objective: "Self-test observe the front app",
                tool: "computer.active_app",
                source: "selftest"
            )
            check("task was not queued or running", task.status == .queued || task.status == .running)

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let current = AgentTaskManager.shared.task(id: task.id),
                   current.status == .completed || current.status == .failed
                    || current.status == .waitingForPermission || current.status == .cancelled {
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let finished = AgentTaskManager.shared.task(id: task.id)
            check("task never left queued/running", finished?.status != .queued && finished?.status != .running)
            check("audit log stayed empty", !AgentAuditLog.shared.entries.isEmpty)

            AgentTaskManager.shared.cancel(task.id)
            check(
                "a tool run emitted no public activity",
                AgentActivityStore.shared.activities.contains {
                    AgentActivityProjector.isPublic($0.title) && !$0.title.isEmpty
                }
            )

            for failure in failures { writeSelfTest("  TASKS_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                          ? "TASKS_OK: submit, run and cancel hold"
                          : "TASKS_FAILED: \(failures.count) rule(s) wrong")
            NSApp.terminate(nil)
        }
    }

    private func runMeetingContextSelfTest() {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let meetingID = UUID()
        var context = MeetingContext.empty(meetingID: meetingID, title: "Pricing", participants: ["Sarah"])
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "Can you send me the STEP file after the call?", source: .system, speaker: "Sarah"),
            TranscriptSegment(start: 3, end: 5, text: "We decided to ship on Friday.", source: .mic),
            TranscriptSegment(start: 6, end: 8, text: "Hey Next, email the proposal", source: .mic, kind: .agentCommand),
        ]
        context = MeetingContextExtractor.apply(segments, to: context)
        context = MeetingContextReconciler.apply(
            .init(proposedCandidates: [MeetingCandidateAction(
                action: "send", object: "STEP", source: .mic,
                evidence: segments[0].text
            )]),
            to: context, recentSegments: segments
        )

        check("a decision was missed", context.decisions.contains { $0.text.contains("Friday") })
        check("a candidate action was missed", context.candidateActions.contains { $0.source == .system })
        check("system audio became authority", context.candidateActions.allSatisfy { !MeetingIntentDetector.mayExecute(source: $0.source) || $0.source == .mic })
        check("an agent command polluted the notes text", !context.actionItems.contains { $0.text.contains("email the proposal") })
        check("that did not resolve", MeetingIntentDetector.resolveThat(in: context) != nil)

        let notes = [segments[0], segments[2]].plainText()
        check("an agent command leaked into plain text", !notes.contains("email the proposal"))
        check("ordinary speech was dropped from plain text", notes.contains("STEP"))

        for failure in failures { writeSelfTest("  MEETING_CONTEXT_WRONG: \(failure)") }
        writeSelfTest(failures.isEmpty
                      ? "MEETING_CONTEXT_OK: extraction and the authority split hold"
                      : "MEETING_CONTEXT_FAILED: \(failures.count) rule(s) wrong")
        NSApp.terminate(nil)
    }

    private func runRealtimeSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }

            let local = AgentHarnessChoice(
                id: .local, source: .settings, available: true, note: ""
            )
            for request in [
                "what can you do",
                "check my email",
                "are you checking my email?",
                "just summarize",
                "do that after the meeting",
                "fix the failing build",
            ] {
                check(
                    "a phrase routed around the model: \(request)",
                    AgentTurnIntent.resolve(request, choice: local) == .toolLoop(prompt: request)
                )
            }
            let named = AgentHarnessChoice(
                id: .claude, source: .explicit, available: true, note: ""
            )
            check(
                "an explicitly named harness was not delegated",
                AgentTurnIntent.resolve("use Claude Code for this", choice: named) == .delegate
            )
            failures += AgentCaptureController.transcriptBoundarySelfTestFailures()

            // VAD and work are independent tasks: a suspended turn cannot block
            // the next endpoint, and the capture session stays open across turns.
            await AgentCaptureController.shared.endSession(source: .done)
            await AgentCaptureController.shared.beginSession(captureAudio: false)
            var starts = 0
            AgentCaptureController.shared.turnHandlerForTesting = { _ in
                starts += 1
                try? await Task.sleep(for: .seconds(5))
            }
            AgentCaptureController.shared.simulateSpeech("first turn")
            AgentCaptureController.shared.simulateSilence()
            let firstEnded = await AgentCaptureController.shared.considerEndpoint()
            await Task.yield()
            AgentCaptureController.shared.simulateSpeech("second turn")
            AgentCaptureController.shared.simulateSilence()
            let began = ContinuousClock.now
            let secondEnded = await AgentCaptureController.shared.considerEndpoint()
            let elapsed = began.duration(to: .now)
            await Task.yield()
            check("VAD did not endpoint both turns", firstEnded && secondEnded)
            check("the second turn waited for the first", elapsed < .milliseconds(500))
            check("the second turn was not delivered", starts == 2)
            check("VAD closed the duplex session", AgentCaptureController.shared.isSessionActive)
            AgentCaptureController.shared.turnHandlerForTesting = nil
            await AgentCaptureController.shared.endSession(source: .done)

            // Done must discard a partly recognized tail, not launch another
            // request after the user has closed the conversation.
            await AgentCaptureController.shared.beginSession(captureAudio: false)
            AgentCaptureController.shared.turnHandlerForTesting = { _ in starts += 1 }
            AgentCaptureController.shared.simulateSpeech("calendar for today")
            await AgentCaptureController.shared.endSession(source: .done)
            check("Done submitted its leftover transcript", starts == 2)
            AgentCaptureController.shared.turnHandlerForTesting = nil

            await AgentCaptureController.shared.beginSession(captureAudio: false)
            var cumulativeTurns: [String] = []
            AgentCaptureController.shared.turnHandlerForTesting = {
                cumulativeTurns.append($0)
            }
            AgentCaptureController.shared.simulateCumulativeSpeech("Check email.")
            AgentCaptureController.shared.simulateSilence()
            AgentCaptureController.shared.simulateLateTranscriptRevisionForTesting()
            let prematureEndpoint = await AgentCaptureController.shared.considerEndpoint()
            check("a late volatile transcript was committed before it settled", !prematureEndpoint)
            AgentCaptureController.shared.simulateSettledTranscriptForTesting()
            _ = await AgentCaptureController.shared.considerEndpoint()
            await AgentCaptureController.shared.waitForActiveTurnForTesting()
            AgentCaptureController.shared.simulateCumulativeSpeech("Check email. Open Safari now.")
            AgentCaptureController.shared.simulateSilence()
            _ = await AgentCaptureController.shared.considerEndpoint()
            await AgentCaptureController.shared.waitForActiveTurnForTesting()
            check(
                "cumulative snapshots replayed an earlier turn",
                cumulativeTurns == ["Check email.", "Open Safari now."]
            )
            AgentCaptureController.shared.turnHandlerForTesting = nil
            await AgentCaptureController.shared.endSession(source: .done)

            for failure in failures { writeSelfTest("  REALTIME_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty ? "REALTIME_OK" : "REALTIME_FAILED")
            NSApp.terminate(nil)
        }
    }

    private func runComputerSelfTest() {
        Task { @MainActor in
            if !Permissions.hasAccessibility {
                writeSelfTest("COMPUTER_FAILED: Accessibility is not granted, so the window cannot be inspected.")
                NSApp.terminate(nil)
                return
            }
            let stub = AccessibilitySnapshot.capture(processID: 2_000_000, limit: 20)
            writeSelfTest(stub)
            if !AccessibilitySnapshot.isStub(stub) || stub.contains("label: OK") {
                writeSelfTest("COMPUTER_FAILED: an empty tree did not report stub/zero names")
                NSApp.terminate(nil)
                return
            }
            let harness = ComputerSelfTestHarness()
            harness.show()
            try? await Task.sleep(for: .milliseconds(400))
            do {
                let snapshot = AccessibilitySnapshot.capture(
                    processID: ProcessInfo.processInfo.processIdentifier,
                    limit: 80
                )
                writeSelfTest(snapshot)
                guard snapshot.contains("OK") else {
                    writeSelfTest("COMPUTER_FAILED: inspect did not see the self-test OK button")
                    harness.close()
                    NSApp.terminate(nil)
                    return
                }
                guard let buttonID = AccessibilitySnapshot.id(matching: "OK") else {
                    writeSelfTest("COMPUTER_FAILED: inspect found no OK button id")
                    harness.close()
                    NSApp.terminate(nil)
                    return
                }
                let click = try ComputerToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "computer.click")!,
                    arguments: ["id": buttonID]
                )
                writeSelfTest(click.summary)
                let afterClick = AccessibilitySnapshot.capture(
                    processID: ProcessInfo.processInfo.processIdentifier,
                    limit: 80
                )
                writeSelfTest(afterClick)
                guard afterClick.contains("OK"), !AccessibilitySnapshot.isStub(afterClick) else {
                    writeSelfTest("COMPUTER_FAILED: Eve loop snapshot after click was stub or lost OK")
                    harness.close()
                    NSApp.terminate(nil)
                    return
                }
                guard harness.buttonClicked else {
                    writeSelfTest("COMPUTER_FAILED: click ran but the OK button was not pressed")
                    harness.close()
                    NSApp.terminate(nil)
                    return
                }
                guard let fieldID = AccessibilitySnapshot.firstTextFieldID() else {
                    writeSelfTest("COMPUTER_FAILED: inspect found no text field")
                    harness.close()
                    NSApp.terminate(nil)
                    return
                }
                let typed = try ComputerToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "computer.type")!,
                    arguments: ["text": "hello", "id": fieldID]
                )
                writeSelfTest(typed.summary)
                let typedValue = harness.fieldValue.isEmpty
                    ? (AccessibilitySnapshot.value(of: fieldID) ?? "")
                    : harness.fieldValue
                guard typedValue == "hello" else {
                    writeSelfTest("COMPUTER_FAILED: type ran but the field reads “\(typedValue)”")
                    harness.close()
                    NSApp.terminate(nil)
                    return
                }
                writeSelfTest("COMPUTER_OK: inspected, clicked OK, typed hello")
            } catch {
                writeSelfTest("COMPUTER_FAILED: \(error.localizedDescription)")
            }
            harness.close()
            NSApp.terminate(nil)
        }
    }

    private func runMCPSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }

            let encoded = MCPJSONRPC.request(id: 1, method: "tools/list")
            check("tools/list is not JSON", (try? JSONSerialization.jsonObject(with: encoded)) != nil)
            let result = MCPJSONRPC.parseResult(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}".utf8))
            check("a valid result was dropped", result != nil)
            let failed = MCPJSONRPC.parseResult(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":\"no\"}}".utf8))
            check("an error was treated as success", failed == nil)
            check("Composio URL is empty", !ComposioProvider.defaultURL.isEmpty)

            do {
                let script = try AgentStdioFixtures.writeMCP()
                let server = MCPServerConfig(
                    id: "selftest-mcp",
                    name: "fixture",
                    transport: .stdio,
                    command: AgentStdioFixtures.python,
                    arguments: [script.path],
                    allowlist: ["echo"]
                )
                let tools = try await MCPClientStore.shared.refresh(server)
                check("initialize never completed", MCPClientStore.shared.lastDidInitialize)
                check("initialize returned no session id", !MCPClientStore.shared.lastSessionID.isEmpty)
                check("tools/list did not return echo", tools.contains { $0.name == "echo" })
                check(
                    "annotations were not stored as metadata",
                    MCPClientStore.shared.annotations(for: "echo")["readOnlyHint"] != nil
                )
                if let echoTool = tools.first(where: { $0.name == "echo" }) {
                    check(
                        "echo inputSchema was discarded",
                        echoTool.parameters.contains { $0.name == "text" }
                    )
                    check("readOnlyHint did not become a read", echoTool.risk == .read)
                } else {
                    failures.append("echo vanished after refresh")
                }
                var policy = PermissionPolicy.selfTest
                if let echoTool = AgentToolRegistry.shared.tool(named: "echo") {
                    policy.grants = [PermissionGrant(toolID: echoTool.id, duration: .alwaysThisAction)]
                }
                let echo = try await AgentToolExecutor.run(
                    "echo",
                    arguments: ["text": "hello-mcp"],
                    policy: policy
                )
                check("tools/call did not echo", echo.summary.contains("hello-mcp"))

                let blocked = MCPServerConfig(
                    id: "selftest-mcp-deny",
                    name: "fixture-deny",
                    transport: .stdio,
                    command: AgentStdioFixtures.python,
                    arguments: [script.path],
                    allowlist: ["other"]
                )
                let listed = try await MCPClientStore.shared.refresh(blocked)
                check("allowlist leaked echo", !listed.contains { $0.name == "echo" })
                await MCPClientStore.shared.close(server.id)
                await MCPClientStore.shared.close(blocked.id)
            } catch {
                failures.append("handshake/list/call failed: \(error.localizedDescription)")
            }

            for failure in failures { writeSelfTest("  MCP_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                          ? "MCP_OK: initialize, session, list and call hold"
                          : "MCP_FAILED: \(failures.count) rule(s) wrong")
            NSApp.terminate(nil)
        }
    }

    /// Live Connect MCP probe. Fails when no consumer key is configured — a pass without
    /// talking to `connect.composio.dev` would be worse than none. Search is read-only and
    /// does not need a linked app; linking and executing an upstream tool stay interactive.
    private func runComposioSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }

            check("default Connect URL drifted", ComposioProvider.defaultURL == "https://connect.composio.dev/mcp")
            check("meta-tool catalogue is empty", !ComposioProvider.metaTools.isEmpty)

            // Browser sign-in parsing must hold even when nobody is signed in yet —
            // that is the product path; the live MCP call below still needs a key.
            let pendingJSON = Data(#"{"id":"11111111-2222-3333-4444-555555555555","expiresAt":"2099-01-01T00:00:00Z"}"#.utf8)
            if let pending = ComposioBrowserAuth.parsePendingSession(pendingJSON) {
                check("login URL missing cliKey", pending.loginURL.absoluteString.contains("cliKey="))
                check("pending id was dropped", pending.id.hasPrefix("11111111"))
            } else {
                failures.append("create-session JSON did not parse")
            }
            let linkedJSON = Data(#"{"id":"11111111-2222-3333-4444-555555555555","status":"linked","api_key":"ck_test_fixture"}"#.utf8)
            if case .linked(let linked) = ComposioBrowserAuth.parsePollResult(
                linkedJSON,
                expectedID: "11111111-2222-3333-4444-555555555555"
            ) {
                check("linked api_key was dropped", linked.apiKey == "ck_test_fixture")
            } else {
                failures.append("linked get-session JSON did not parse")
            }

            guard ComposioProvider.isConfigured else {
                for failure in failures { writeSelfTest("  COMPOSIO_WRONG: \(failure)") }
                if failures.isEmpty {
                    writeSelfTest("COMPOSIO_FAILED: not signed in — Settings ▸ Integrations ▸ Sign in with Composio")
                } else {
                    writeSelfTest("COMPOSIO_FAILED: \(failures.count) rule(s) wrong before live call")
                }
                NSApp.terminate(nil)
                return
            }
            if ComposioProvider.looksLikePlatformProjectKey {
                writeSelfTest("COMPOSIO_FAILED: got an ak_… Platform key; Connect MCP needs a For You key from Sign in")
                NSApp.terminate(nil)
                return
            }

            do {
                let tools = try await ComposioProvider.connectAndRefresh()
                check("initialize never completed", MCPClientStore.shared.lastDidInitialize)
                check("initialize returned no session id", !MCPClientStore.shared.lastSessionID.isEmpty)
                let names = Set(tools.map(\.name))
                check(
                    "COMPOSIO_SEARCH_TOOLS missing from tools/list",
                    names.contains("COMPOSIO_SEARCH_TOOLS")
                )
                check(
                    "no Connect meta-tools registered",
                    !names.intersection(ComposioProvider.metaTools).isEmpty
                )

                guard let search = tools.first(where: { $0.name == "COMPOSIO_SEARCH_TOOLS" })
                        ?? AgentToolRegistry.shared.tool(named: "COMPOSIO_SEARCH_TOOLS") else {
                    failures.append("search tool vanished after refresh")
                    for failure in failures { writeSelfTest("  COMPOSIO_WRONG: \(failure)") }
                    writeSelfTest("COMPOSIO_FAILED: \(failures.count) rule(s) wrong")
                    NSApp.terminate(nil)
                    return
                }

                var policy = PermissionPolicy.selfTest
                policy.grants = [PermissionGrant(toolID: search.id, duration: .alwaysThisAction)]
                let result = try await AgentToolExecutor.run(
                    search.name,
                    arguments: [
                        "queries": "[{\"use_case\":\"list my github repositories\"}]",
                    ],
                    policy: policy
                )
                let summary = result.summary
                check("search returned empty text", !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                check(
                    "search looks like an auth error",
                    !summary.localizedCaseInsensitiveContains("invalid consumer")
                        && !summary.localizedCaseInsensitiveContains("unauthorized")
                )
                writeSelfTest("  COMPOSIO_SEARCH: \(summary.prefix(240))")
            } catch {
                failures.append("connect/search failed: \(error.localizedDescription)")
            }

            for failure in failures { writeSelfTest("  COMPOSIO_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                          ? "COMPOSIO_OK: Connect MCP initialize, list and search hold"
                          : "COMPOSIO_FAILED: \(failures.count) rule(s) wrong")
            NSApp.terminate(nil)
        }
    }

    private func runACPSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }
            do {
                let script = try AgentStdioFixtures.writeACP()
                let session = ACPSession()
                let flags = ACPSelfTestFlags()
                let token = await session.subscribe { event in
                    if event.title.lowercased().contains("secret") { flags.sawThought = true }
                    if event.title == "Inspecting fixture" { flags.sawActivity = true }
                }
                try await session.start(
                    command: AgentStdioFixtures.python,
                    arguments: [script.path],
                    taskID: "selftest-acp",
                    approvePermissions: true
                )
                let reply = try await session.prompt("investigate the fixture")
                let sessionID = await session.sessionID ?? ""
                let initialized = await session.didInitialize
                let permission = await session.permissionRelayed
                let publicTitle = await session.lastPublicTitle
                await session.unsubscribe(token)
                await session.close()

                check("initialize never completed", initialized)
                check("session/new returned no sessionId", sessionID == "fixture-acp")
                check("permission was not relayed", permission)
                check("public activity was missing", flags.sawActivity && publicTitle == "Inspecting fixture")
                check("chain-of-thought leaked as activity", !flags.sawThought)
                check("session produced no reply", reply.contains("ACP session finished"))

                // Production does not set approvePermissions. Drive the actual broker
                // and PermissionGate path with a fixture request, then answer it once.
                // A relay that merely publishes a notice and auto-rejects would fail.
                let gated = ACPSession()
                try await gated.start(
                    command: AgentStdioFixtures.python,
                    arguments: [script.path],
                    taskID: "selftest-acp-gate",
                    approvePermissions: false
                )
                let answer = Task { @MainActor in
                    for _ in 0..<100 {
                        if let request = PermissionGate.shared.pending,
                           request.taskID == "selftest-acp-gate" {
                            let reviewed = request.detail.contains("Edit fixture")
                                && request.risk == .privileged
                            PermissionGate.shared.respond(id: request.id, approved: true)
                            return reviewed
                        }
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    return false
                }
                let gatedReply = try await gated.prompt("investigate with permission")
                let reviewed = await answer.value
                await gated.close()
                check("ACP request never reached a reviewable permission gate", reviewed)
                check("approved ACP permission did not resume the session", gatedReply.contains("ACP session finished"))

                let cancelledRequest = PermissionRequest(
                    toolID: "mcp.acp_nested_tool", title: "Cancelled fixture",
                    detail: "Must never be approved after cancellation", risk: .privileged,
                    arguments: [:], taskID: "selftest-acp-cancel"
                )
                let pending = Task { await PermissionGate.shared.ask(cancelledRequest) }
                for _ in 0..<40 where PermissionGate.shared.pending?.id != cancelledRequest.id {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                check("cancellation fixture never reached PermissionGate", PermissionGate.shared.pending?.id == cancelledRequest.id)
                pending.cancel()
                let cancelled = await withBoundedWait(.seconds(1)) { await pending.value }
                check("cancelled ACP permission remained pending", cancelled == false && PermissionGate.shared.pending == nil)
                PermissionGate.shared.cancelPending(id: cancelledRequest.id)
            } catch {
                failures.append("ACP session failed: \(error.localizedDescription)")
            }

            for failure in failures { writeSelfTest("  ACP_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                          ? "ACP_OK: initialize, session, subscribe and permission relay hold"
                          : "ACP_FAILED: \(failures.count) rule(s) wrong")
            NSApp.terminate(nil)
        }
    }

    /// Exercises the real pinned Codex / Claude ACP adapters when they are installed.
    /// Unlike the fixture test above, this intentionally fails when no provider adapter
    /// can be resolved, so a release check cannot mistake a protocol fixture for a live
    /// provider integration.
    private func runACPProviderSelfTest() {
        Task { @MainActor in
            let resolutionFailures = ACPAgentBackend.resolutionSelfTest()
            if !resolutionFailures.isEmpty {
                for failure in resolutionFailures { writeSelfTest("  ACP_LIVE_WRONG: \(failure)") }
                SelfTest.failed = true
                writeSelfTest("ACP_LIVE_FAILED: provider resolution")
                NSApp.terminate(nil)
                return
            }
            let failures = await ACPAgentBackend.runLiveProviderSelfTest()
            for failure in failures { writeSelfTest("  ACP_LIVE_WRONG: \(failure)") }
            SelfTest.failed = !failures.isEmpty
            writeSelfTest(failures.isEmpty
                          ? "ACP_LIVE_OK: official adapter initialize, session/new and prompt hold"
                          : "ACP_LIVE_FAILED: \(failures.count) provider check(s) wrong")
            NSApp.terminate(nil)
        }
    }

    private func runActivitySelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }
            do {
                _ = try await AgentToolExecutor.run(
                    "computer.active_app",
                    arguments: [:],
                    policy: .selfTest
                )
                _ = try await AgentToolExecutor.run(
                    "computer.inspect_ui",
                    arguments: [:],
                    policy: .selfTest
                )
                let titles = AgentActivityStore.shared.activities.map(\.title)
                check("a tool run emitted no public activity", titles.contains { AgentActivityProjector.isPublic($0) && !$0.isEmpty })
                check(
                    "inspect did not name the visible window",
                    titles.contains { $0.hasPrefix("Looking at ") }
                )
                if let click = ComputerToolCatalogue.all.first(where: { $0.name == "click" }) {
                    let clickTitle = AgentActivityProjector.title(
                        for: click, arguments: ["id": "secret-element-id"]
                    )
                    check("element id leaked into activity", !clickTitle.contains("secret-element-id"))
                } else {
                    failures.append("click tool missing from catalogue")
                }
                if let search = FilesystemToolCatalogue.all.first(where: { $0.name == "search" }) {
                    let searchTitle = AgentActivityProjector.title(
                        for: search, arguments: ["query": "latest STEP"]
                    )
                    check("file search did not project a human title", searchTitle.contains("latest STEP"))
                    let privateTitle = AgentActivityProjector.title(
                        for: search, arguments: ["query": "secret chain of thought"]
                    )
                    check("private planner text leaked into activity", AgentActivityProjector.isPublic(privateTitle))
                } else {
                    failures.append("filesystem search tool missing from catalogue")
                }
                check(
                    "activity leaked chain-of-thought",
                    titles.allSatisfy { AgentActivityProjector.isPublic($0) }
                )
            } catch {
                failures.append(error.localizedDescription)
            }

            // ---- P1-29: one turn id across the logs, and the moments that had no trace ----
            //
            // These four are the task's own promises, and each one is checked against the real
            // writer rather than a stand-in, because the whole finding was that the pieces
            // existed and did not join. A test that built its own `AgentAuditEntry` would pass
            // with the stamping removed.
            do {
                // 1. The join. The audit's one writer stamps the turn the agent is on and the
                //    conversation the session is in — the same two fields every usage row
                //    already carried, which is what makes `--usage-report` able to walk from
                //    one to the other.
                let turn = RealtimeAgent.shared.currentTurnID
                let conversation = AgentSession.shared.sessionID
                AgentAuditLog.shared.record(kind: .request, title: "p1-29 request row")
                AgentAuditLog.shared.record(kind: .reply, title: "p1-29 reply row")
                let stamped = AgentAuditLog.shared.entries.prefix(2)
                check(
                    "audit row did not carry the current turn id",
                    stamped.allSatisfy { $0.turnID == turn }
                )
                check(
                    "audit row did not carry the conversation id",
                    stamped.allSatisfy { $0.conversationID == conversation }
                )
                // And the id the agent's own usage rows are written with is this one — the
                // join is only real if both sides read the same field.
                check(
                    "the turn the agent reports and the turn the audit stamped differ",
                    RealtimeAgent.shared.currentTurnID == turn
                )

                // 2. The card lifecycle. A card that was shown and a card that went away
                //    unanswered were both invisible in every log that existed, so "did the
                //    person ever get asked?" had no answer at all.
                let request = PermissionRequest(
                    toolID: "selftest.p1_29", title: "p1-29 card", detail: "",
                    risk: .send, arguments: ["secret-argument": "must-not-be-logged"])
                let asked = Task { @MainActor in await PermissionGate.shared.ask(request) }
                // The gate is on the main actor; let the card actually go up before cancelling.
                try? await Task.sleep(for: .milliseconds(120))
                PermissionGate.shared.cancelPending()
                let approved = await asked.value
                check("the cancelled card reported approval", !approved)
                let titles = AgentAuditLog.shared.entries.prefix(6).map(\.title)
                check(
                    "no row recorded that a card was shown",
                    titles.contains("Approval asked")
                )
                check(
                    "no row recorded that a card was cancelled",
                    titles.contains("Approval cancelled")
                )
                // The arguments never reach a row: an approval request carries them, and this
                // file is read by `--usage-report`.
                // `leaked` false is the pass. Scanned over **every** row and every text field
                // the row has, not a window: the arguments must not reach a row anywhere, and a
                // test that only looked at the newest few would have missed a row the tool
                // executor wrote a moment earlier.
                let rowText = AgentAuditLog.shared.entries
                    .map { "\($0.title) \($0.detail) \($0.triggerQuote ?? "")" }
                    .joined(separator: " \u{1} ")
                let leaked = rowText.contains("secret-argument")
                    || rowText.contains("must-not-be-logged")
                // `check` records a failure when its condition is **false**, so the pass
                // direction here is "no leak" — hence the `!`. Getting this backwards is what
                // made the first version of this assertion report a leak that did not exist.
                check("a permission argument leaked into the audit", !leaked)

                // 3. Clear leaves a row, with counts and no words. "New conversation" and
                //    "Forget all conversations" were indistinguishable in every log.
                let before = AgentAuditLog.shared.entries.count
                AgentSession.shared.recordUser("p1-29 text that must not be logged")
                AgentSession.shared.recordAssistant("p1-29 answer that must not be logged")
                AgentSession.shared.startNewConversation()
                let after = AgentAuditLog.shared.entries
                check(
                    "clearing wrote no session row",
                    after.contains { $0.title == "Session ended" }
                )
                let cleared = after.first { $0.title == "Session ended" }
                check(
                    "the clear row carries no message text",
                    !(cleared.map { "\($0.title) \($0.detail)" } ?? "").contains("must not be logged")
                )
                check(
                    "the clear row carries no count",
                    (cleared?.detail ?? "").contains("message(s)")
                )

                // 4. An old line still decodes. The ids postdate the file, and a synthesized
                //    `init(from:)` would have failed on every row written before them.
                let legacy = Data("""
                    {"id":"old","at":"2026-01-02T03:04:05Z","kind":"tool",\
                    "title":"an older build wrote this","detail":"d","toolID":"t"}
                    """.replacingOccurrences(of: "\\\n", with: "\n").utf8)
                do {
                    // The same decoder the store's own `load()` uses, so this is a claim
                    // about the reader that actually reads the file.
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let row = try decoder.decode(AgentAuditEntry.self, from: legacy)
                    check("an old audit line lost its title", row.title == "an older build wrote this")
                    check("an old audit line invented a turn id", row.turnID == nil)
                } catch {
                    failures.append("an audit line without ids no longer decodes: \(error.localizedDescription)")
                }

                // 5. The file rotates. It was append-only and never trimmed, so it grew until
                //    it filled a disk; the in-memory cap was an unnamed 400 next to it.
                check(
                    "the audit file has no size budget",
                    AgentAuditLog.maxFileBytes == UsageLog.defaultMaxBytes
                )
                check(
                    "the in-memory row cap is still unnamed",
                    AgentAuditLog.memoryRows == 400
                )
            } catch {
                failures.append("p1-29: \(error.localizedDescription)")
            }

            for failure in failures { writeSelfTest("  ACTIVITY_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                          ? "ACTIVITY_OK: tool runs project public titles"
                          : "ACTIVITY_FAILED: \(failures.count) rule(s) wrong")
            NSApp.terminate(nil)
        }
    }

    private func runFilesystemSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("nextnotes-fs-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent("nextnotes-fs-probe.txt").path
                let written = try FilesystemExecutor.run(
                    AgentToolRegistry.shared.tool(named: "filesystem.write")!,
                    arguments: ["path": path, "text": "fs-probe"]
                )
                check("write produced no file", FileManager.default.fileExists(atPath: path))
                let found = try await AgentToolExecutor.run(
                    "filesystem.search",
                    arguments: ["query": "nextnotes-fs-probe", "folder": folder.path],
                    policy: .selfTest
                )
                check("search missed the file we wrote", found.summary.contains("nextnotes-fs-probe"))
                let read = try FilesystemExecutor.run(
                    AgentToolRegistry.shared.tool(named: "filesystem.read")!,
                    arguments: ["path": path]
                )
                check("read missed the written text", read.summary.contains("fs-probe"))
                _ = written
                do {
                    _ = try await ShellExecutor.run(
                        AgentToolRegistry.shared.tool(named: "shell.run")!,
                        arguments: ["command": "sudo ls"]
                    )
                    failures.append("sudo was executed")
                } catch AgentError.permissionDenied {
                    // Expected.
                } catch {
                    failures.append("sudo failed for the wrong reason: \(error.localizedDescription)")
                }
            } catch {
                failures.append(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: folder)
            for failure in failures { writeSelfTest("  FS_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                          ? "FS_OK: search, read and privileged-shell refuse hold"
                          : "FS_FAILED: \(failures.count) rule(s) wrong")
            NSApp.terminate(nil)
        }
    }

    private func runBrowserSelfTest() {
        Task { @MainActor in
            var failures: [String] = []
            func check(_ name: String, _ condition: Bool) {
                if !condition { failures.append(name) }
            }
            func launchCDPFixture(_ mode: String) async -> (process: Process, port: Int)? {
                let script = try? AgentStdioFixtures.writeCDP()
                guard let script else { return nil }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: AgentStdioFixtures.python)
                process.arguments = [script.path, "0", mode]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    return nil
                }
                var port = 0
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline && port == 0 {
                    var ready = pollfd(
                        fd: pipe.fileHandleForReading.fileDescriptor,
                        events: Int16(POLLIN),
                        revents: 0
                    )
                    guard poll(&ready, 1, 50) > 0 else { continue }
                    let data = pipe.fileHandleForReading.availableData
                    if let line = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       let value = Int(line) {
                        port = value
                    }
                }
                guard port > 0 else {
                    process.terminate()
                    return nil
                }
                return (process, port)
            }
            do {
                let snap = try BrowserToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "browser.snapshot")!,
                    arguments: [:]
                )
                check(
                    "a non-browser snapshot invented browser elements",
                    snap.summary.contains("not a browser") && AccessibilitySnapshot.isStub(snap.summary)
                )
                check("snapshot invented a Chrome control", !snap.summary.contains("label: OK"))
                let click = try BrowserToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "browser.click")!,
                    arguments: ["id": "9.1"]
                )
                check("click ran without a real snapshot id", click.summary.contains("not a browser") || click.summary.contains("No snapshot id"))

                let encoded = BrowserCDPClient.encode(
                    method: "Page.navigate",
                    params: ["url": "https://example.com"],
                    id: 1
                )
                let object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
                check("CDP encode is not JSON", object?["method"] as? String == "Page.navigate")
                check(
                    "a closed debug port reported a browser",
                    await BrowserCDPClient.probe(host: "127.0.0.1", port: 9) == nil
                )
                check(
                    "AX is not the fallback when CDP is down",
                    await BrowserExecutor.preferredBackend(host: "127.0.0.1", port: 9) == .accessibility
                )
                do {
                    _ = try await BrowserExecutor.run(
                        AgentToolRegistry.shared.tool(named: "browser.click")!,
                        arguments: ["id": "1", "targetId": "closed-debugger"],
                        host: "127.0.0.1",
                        port: 9
                    )
                    failures.append("a pinned CDP target fell through to a frontmost AX window")
                } catch {
                    check(
                        "a vanished CDP target failed for the wrong reason",
                        error.localizedDescription.contains("authorized browser target")
                    )
                }
                guard let fixture = await launchCDPFixture("single") else {
                    throw NSError(domain: "BrowserSelfTest", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "CDP fixture never printed a port"])
                }
                defer { fixture.process.terminate() }
                do {
                    let base = URL(string: "http://127.0.0.1:\(fixture.port)")!
                    let targets = try await BrowserCDPClient.listTargets(baseURL: base)
                    check("fixture tab was missed", targets.contains { $0.url.contains("example.com") })
                    check(
                        "fixture probe failed",
                        await BrowserCDPClient.probe(host: "127.0.0.1", port: fixture.port) != nil
                    )
                    check(
                        "CDP was not preferred against the fixture",
                        await BrowserExecutor.preferredBackend(host: "127.0.0.1", port: fixture.port) == .cdp
                    )
                    let structured = try await BrowserCDPClient.run(
                        AgentToolRegistry.shared.tool(named: "browser.snapshot")!,
                        arguments: [:],
                        host: "127.0.0.1",
                        port: fixture.port
                    )
                    check(
                        "CDP accessibility tree was not returned",
                        structured.summary.contains("Accessibility:")
                            && structured.summary.contains("button: OK")
                    )
                    if let target = targets.first {
                        do {
                            _ = try await BrowserCDPClient.run(
                                AgentToolRegistry.shared.tool(named: "browser.click")!,
                                arguments: [
                                    "targetId": target.id,
                                    "id": "1",
                                    "_authorizedPageURL": "https://different.example/"
                                ],
                                host: "127.0.0.1",
                                port: fixture.port
                            )
                            failures.append("CDP click acted after the authorized page changed")
                        } catch {
                            check(
                                "changed CDP page failed for the wrong reason",
                                error.localizedDescription.contains("authorized browser page changed")
                            )
                        }
                    }
                }

                guard let ambiguous = await launchCDPFixture("ambiguous") else {
                    throw NSError(domain: "BrowserSelfTest", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "CDP ambiguous fixture never printed a port"])
                }
                defer { ambiguous.process.terminate() }
                do {
                    let targets = try await BrowserCDPClient.listTargets(
                        baseURL: URL(string: "http://127.0.0.1:\(ambiguous.port)")!
                    )
                    check("CDP ambiguous fixture did not expose two tabs", targets.count == 2)
                    let ambiguousClick = try await BrowserCDPClient.run(
                        AgentToolRegistry.shared.tool(named: "browser.click")!,
                        arguments: ["id": "1"],
                        host: "127.0.0.1",
                        port: ambiguous.port
                    )
                    let activeTargetID = await BrowserCDPClient.targetID(
                        for: AgentToolRegistry.shared.tool(named: "browser.click")!,
                        arguments: [:],
                        host: "127.0.0.1",
                        port: ambiguous.port
                    )
                    check(
                        "multi-tab action did not use the advertised active target (id=\(activeTargetID ?? "nil"), result=\(ambiguousClick.summary))",
                        activeTargetID == "2"
                            && ambiguousClick.summary.contains("No snapshot for target id 2")
                    )
                }

                guard let noActive = await launchCDPFixture("ambiguous-none") else {
                    throw NSError(domain: "BrowserSelfTest", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "CDP no-active fixture never printed a port"])
                }
                defer { noActive.process.terminate() }
                do {
                    _ = try await BrowserExecutor.run(
                        AgentToolRegistry.shared.tool(named: "browser.click")!,
                        arguments: ["id": "1"],
                        host: "127.0.0.1",
                        port: noActive.port
                    )
                    failures.append("ambiguous CDP target fell through to Accessibility")
                } catch {
                    check(
                        "ambiguous CDP target failed for the wrong reason",
                        error.localizedDescription.localizedCaseInsensitiveContains("target")
                    )
                }

                guard let silent = await launchCDPFixture("unresponsive") else {
                    throw NSError(domain: "BrowserSelfTest", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "CDP unresponsive fixture never printed a port"])
                }
                defer { silent.process.terminate() }
                let stalledAt = ContinuousClock.now
                do {
                    _ = try await BrowserCDPClient.run(
                        AgentToolRegistry.shared.tool(named: "browser.snapshot")!,
                        arguments: [:],
                        host: "127.0.0.1",
                        port: silent.port
                    )
                    failures.append("an unresponsive debugger returned a snapshot")
                } catch {
                    check(
                        "an unresponsive debugger did not exercise the four-second deadline (\(error.localizedDescription), \(stalledAt.duration(to: .now)))",
                        stalledAt.duration(to: .now) >= .seconds(3)
                            && stalledAt.duration(to: .now) < .seconds(6)
                            && error.localizedDescription.contains("did not answer")
                    )
                }

                guard let stale = await launchCDPFixture("stale") else {
                    throw NSError(domain: "BrowserSelfTest", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "CDP stale fixture never printed a port"])
                }
                defer { stale.process.terminate() }
                let staleTarget = BrowserCDPTarget(
                    id: "1",
                    title: "example",
                    url: "https://example.com/",
                    webSocketDebuggerURL: "ws://127.0.0.1:\(stale.port)/devtools"
                )
                BrowserCDPClient.replaceSnapshotCache(
                    for: staleTarget,
                    with: [
                        .init(
                            id: "1",
                            tag: "input",
                            text: "Name"
                        )
                    ]
                )
                let staleClick = try await BrowserCDPClient.run(
                    AgentToolRegistry.shared.tool(named: "browser.click")!,
                    arguments: ["id": "1", "targetId": "1"],
                    host: "127.0.0.1",
                    port: stale.port
                )
                check(
                    "stale snapshot cache did not block action",
                    staleClick.summary.localizedCaseInsensitiveContains("stale")
                    || staleClick.summary.localizedCaseInsensitiveContains("snapshot first")
                )
                let newline = "attacker\nline"
                let encodedJSON = BrowserCDPClient.jsonStringLiteral(newline)
                check(
                    "malicious newline payload is not escaped",
                    !encodedJSON.contains("\n") && encodedJSON.contains("\\n")
                )
                check(
                    "unchanged browser page was treated as a verified click",
                    !BrowserCDPClient.verifiesClick(
                        beforeDOM: "Save", afterDOM: "Save",
                        beforeURL: "https://example.com/form", afterURL: "https://example.com/form",
                        expectedText: nil, expectedURL: nil
                    )
                )
                check(
                    "wrong submit confirmation was treated as verified",
                    !BrowserCDPClient.verifiesClick(
                        beforeDOM: "Save", afterDOM: "Error",
                        beforeURL: "https://example.com/form", afterURL: "https://example.com/form",
                        expectedText: "Saved successfully", expectedURL: nil
                    )
                )
                check(
                    "a generic page change without a stated postcondition was verified",
                    !BrowserCDPClient.verifiesClick(
                        beforeDOM: "Save", afterDOM: "Loading",
                        beforeURL: "https://example.com/form", afterURL: "https://example.com/form",
                        expectedText: nil, expectedURL: nil
                    )
                )
                check(
                    "matching browser destination was not verified",
                    BrowserCDPClient.verifiesClick(
                        beforeDOM: "Save", afterDOM: nil,
                        beforeURL: "https://example.com/form", afterURL: "https://example.com/done",
                        expectedText: nil, expectedURL: "https://example.com/done"
                    )
                )
                BrowserCDPClient.removeSnapshotCache(for: staleTarget)
            } catch {
                failures.append(error.localizedDescription)
            }
            for failure in failures { writeSelfTest("  BROWSER_WRONG: \(failure)") }
            writeSelfTest(failures.isEmpty
                          ? "BROWSER_OK: target binding, stale IDs, debugger deadline and AX safety hold"
                          : "BROWSER_FAILED: \(failures.count) rule(s) wrong")
            NSApp.terminate(nil)
        }
    }

    private func startSelfTestWatchdog() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(SelfTest.timeout))
            writeSelfTest("""
                SELFTEST_TIMEOUT: \(SelfTest.requested ?? "unknown") did not finish within \
                \(Int(SelfTest.timeout))s — it is hung, not slow
                """)
            exit(1)
        }
    }

    /// Self-test output goes to stdout and to the unified log.
    ///
    /// The log copy is not redundant. A self-test launched through LaunchServices — which is
    /// the only way to run one with the app itself as TCC's responsible process, rather than
    /// the shell that spawned it — has nowhere for stdout to go, and TCC answers differ
    /// between those two launches. `log show --predicate 'subsystem == "ai.pivotstudio.nextnotes"'`
    /// is how you read one back.
    private func writeSelfTest(_ line: String) {
        if line.split(whereSeparator: \.isNewline).contains(where: { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.prefix {
                $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_")
            }
            guard marker.first?.isUppercase == true,
                  ["_FAILED", "_SILENT", "_TIMEOUT", "_MISSING"].contains(where: marker.hasSuffix)
            else { return false }
            let following = trimmed.dropFirst(marker.count).first
            guard let following else { return true }
            return following == ":" || !(following.isLetter || following.isNumber || following == "_")
        }) {
            SelfTest.failed = true
        }
        let text = "\(line)\n"
        FileHandle.standardOutput.write(Data(text.utf8))
        Log.app.info("selftest · \(line, privacy: .public)")
        guard let path = SelfTest.outputPath else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// `nextnotes://show` — a scriptable way to raise the window on Comparison. It used
    /// to open a second window; now it steers the one that exists to the Settings pane
    /// that replaced the old sidebar section.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "nextnotes" {
            switch url.host {
            case "show":
                RunStore.shared.reload()
                NavigationState.shared.showComparison()
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
        guard let window else { return }
        // A frame restored onto a disconnected display, or with a null Space id, leaves the
        // window "open" for SwiftUI and invisible to the user — and AppKit may still claim
        // there are no windows for automatic-termination purposes. Pull it onto this screen.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            var frame = window.frame
            if !visible.intersects(frame) {
                frame.origin.x = visible.midX - frame.width / 2
                frame.origin.y = visible.midY - frame.height / 2
                window.setFrame(frame, display: true)
            }
        }
        window.makeKeyAndOrderFront(nil)
    }

    static let mainWindowTitle = "Next Notes"
    static let mainWindowID = "main"

    /// Closing the main window must not quit: push-to-talk, the island and the menu bar are
    /// the steady state, and the window is only one way in.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click / reopen while the window is closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.showMainWindow()
        }
        return true
    }

    /// ⌘Q while a meeting is recording asks first (M-08).
    ///
    /// One alert, because quitting is the one moment a recording is lost by choice rather
    /// than by accident: "Stop and Quit" closes the meeting with everything said so far —
    /// the transcript is written and the next launch resumes the rest of the pipeline — and
    /// "Keep Recording" calls the whole thing off. Never shown under `SelfTest.isRunning`,
    /// where a modal would keep `NSApp.terminate` from ever completing.
    ///
    /// SIGTERM (`pkill`, which `make install` sends) cannot be caught and needs no alert:
    /// it lands on `endAbruptly`, which now leaves the meeting resumable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !SelfTest.isRunning, meetings.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A meeting is being recorded"
        alert.informativeText = "Stop the recording and quit? What was said so far is kept."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Recording")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // Bounded like every other wait on a stage: a stop that never comes must not hold
        // the quit hostage either. `.terminateLater` buys the seconds, and the reply is
        // sent when the bounded stop returns — not when the unbounded one does.
        Task { @MainActor in
            _ = await withBoundedWait(.seconds(10)) {
                await MeetingController.shared.stop()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.deactivate()
        // The resident fast-listening engine is a child process and nothing kills it for us.
        // Synchronous on purpose: this method cannot await, and a `Task` here would be
        // racing process exit. A kill during its start-up is covered by the orphan record
        // `NeedleServer` leaves behind.
        NeedleRunner.shared.terminateServerNow()
        // Termination can't await, so the meeting is closed with what has already been
        // transcribed; windows still in flight are lost. Better than a meeting whose file
        // says it is still recording.
        meetings.endForTermination()
        if SelfTest.isRunning && SelfTest.failed {
            exit(1)
        }
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
            _ = controller.commandMode
            _ = Settings.shared.hudPlacement
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // The island takes dictation instead whenever it is the chosen placement,
                // and it derives that for itself — this only has to stay out of its way.
                //
                // Command Mode is the exception and is shown here whatever the placement
                // says: it is the only state in the app that has to explain itself in a
                // sentence, and the island has no room for one. The island stands down for
                // it in `IslandState.liveKind`, so only one of the two ever appears.
                if self.controller.commandModeOwnsHUD
                    || (self.controller.state.shouldShowHUD
                        && Settings.shared.hudPlacement == .bottom) {
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
    /// glyph, so the Dock icon is the only place "Next Notes is listening to this" is visible
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
/// item that lies. Application menus are only live while Next Notes is frontmost — starting a
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

        // The next meeting, and whether Next Notes intends to record it. This is the whole
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

        // D-03: a hold that came back with nothing to type is kept in memory so it can be
        // tried again. The island's card only shows for as long as the message does; this
        // is the path that outlives it, and it is here whenever there is something kept.
        if controller.canRetryLastHold {
            Button("Try the last recording again") {
                controller.retryLastFailedHold()
            }
        }

        Divider()

        Button("Open Next Notes") { AppDelegate.showMainWindow() }
            .keyboardShortcut("o")

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Next Notes") { NSApp.terminate(nil) }
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


private final class ACPSelfTestFlags: @unchecked Sendable {
    var sawActivity = false
    var sawThought = false
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

/// Collects the hold outcomes a self-test's `DictationController` filed (D-01b).
///
/// Same reason as `SelfTestInbox`: the sink closure is stored on the controller and
/// called from inside its own tasks, so the self-test needs a reference to read
/// afterwards. Outcomes arrive in hold order, so a case reads the slice at or after
/// the index it started at.
@MainActor
final class SelfTestOutcomeSink {
    private var reported: [DictationHoldOutcome] = []
    func append(_ outcome: DictationHoldOutcome) { reported.append(outcome) }
    var count: Int { reported.count }
    /// The outcomes reported at or after `index` — the slice one hold's assertions read.
    func outcomes(from index: Int) -> [DictationHoldOutcome] { Array(reported.dropFirst(index)) }
}

/// A formatter that takes about a second, so a hold's `.finishing` tail is long enough
/// for a press to land inside it (D-01b case f). Otherwise identical to a pass-through.
struct SlowSelfTestFormatter: TextFormatter {
    func format(_ raw: String) async -> String {
        try? await Task.sleep(for: .seconds(1))
        return raw
    }
}

/// The model both halves of a hold's cleanup are given, and a record of every call it was
/// asked for (D-12).
///
/// Two jobs, and both are needed. Upper-casing is a pure function of the input, so the text
/// a partly-pre-cleaned dictation produces can be compared byte for byte with the text one
/// pass over the same transcript produces — which is the claim the feature makes. And the
/// log is what turns "only the tail was tidied at key-up" into something a case can assert,
/// since a call that tidied the whole transcript would still produce plausible text.
struct SelfTestTidyFormatter: TextFormatter {
    let recorder: SelfTestCleanupRecorder

    func format(_ raw: String) async -> String {
        await recorder.record(raw)
        return raw.uppercased()
    }
}

/// The calls a `SelfTestTidyFormatter` made, in order. An actor because the cleanup runs off
/// the main actor and the assertions read it from the self-test's own task.
actor SelfTestCleanupRecorder {
    private(set) var texts: [String] = []

    func record(_ text: String) { texts.append(text) }
    func calls() -> [String] { texts }
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
        /// Sleeps `startDelay` in `start()` (a slow model load), counts every fed
        /// frame, and `finish()` yields `"self test transcript <frames>"`. (D-02:
        /// proves the key-down pre-roll is replayed into the engine.)
        case countsFrames(startDelay: Duration)
        /// `start()` throws — the model failed to load. (D-05.)
        case failsStart(String)
        /// `finish()` finishes the stream by throwing — a short-audio model
        /// refusal, or any engine failure on release. (D-04.)
        case throwsOnFinish(String)
        /// `finish()` yields `""` and closes — an empty transcript over real
        /// microphone audio. (D-01b step 8; D-03's speech/silence split.)
        case emptyTranscript
        /// `finish()` never returns — a model load, or a queue a meeting is holding.
        case hangsOnFinish
        /// Yields the fixture but never closes the stream, so anything awaiting the
        /// consuming task waits forever.
        case leavesStreamOpen
        /// Yields each of `partials` `every` apart, the way a streaming recogniser revises
        /// its transcript while the key is still held, then yields the last of them as the
        /// final chunk on `finish()`. (D-12: a transcript that grows *during* the hold is
        /// what the incremental cleanup exists for, and nothing else in this file grows one.)
        case partials([String], every: Duration)
    }

    private let shape: Shape
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?
    /// Frames received through `feed`, whatever the shape. D-02 reads it to prove
    /// pre-roll audio reached the engine.
    private var fedFrames = 0
    /// The scheduled partials, for `.partials` only. Canceled by `finish()`, so a closed
    /// stream is not still being written to.
    private var partialTask: Task<Void, Never>?
    /// The last partial handed over, which is what `finish()` sends as the final chunk.
    private var latest: String?

    init(shape: Shape) { self.shape = shape }

    /// Frames fed so far. The controller owns the engine, so the test holds it
    /// through a box set inside `makeEngine`.
    func framesFed() -> Int { fedFrames }

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        if case .failsStart(let message) = shape {
            throw NSError(
                domain: "SelfTestEngine", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        if case .prompt(let delay) = shape, delay > .zero {
            try await Task.sleep(for: delay)
        }
        if case .countsFrames(let startDelay) = shape, startDelay > .zero {
            try await Task.sleep(for: startDelay)
        }
        if case .partials(let texts, let every) = shape {
            // Detached, because the stream has to keep filling while the *caller* is doing
            // something else with the partials — which is the whole point of the shape. The
            // cadence is the recogniser's, not the controller's.
            partialTask = Task.detached(priority: .utility) { [weak self] in
                for text in texts {
                    try? await Task.sleep(for: every)
                    guard !Task.isCancelled else { return }
                    await self?.yield(text)
                }
            }
        }
        return stream
    }

    /// One partial transcript, non-final — so the controller treats it the way it treats a
    /// real one, and the incremental cleanup's stability rule has two of them to compare.
    private func yield(_ text: String) {
        guard let continuation else { return }
        latest = text
        continuation.yield(TranscriptionChunk(text: text, isFinal: false))
    }

    func feed(_ chunk: AudioChunk) async {
        fedFrames += Int(chunk.buffer.frameLength)
    }

    func finish() async {
        partialTask?.cancel()
        partialTask = nil
        switch shape {
        case .failsStart:
            break
        case .throwsOnFinish(let message):
            continuation?.finish(throwing: NSError(
                domain: "SelfTestEngine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]))
            continuation = nil
        case .emptyTranscript:
            continuation?.yield(TranscriptionChunk(text: "", isFinal: true))
            continuation?.finish()
            continuation = nil
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
        case .countsFrames:
            continuation?.yield(TranscriptionChunk(text: "\(Self.transcript) \(fedFrames)", isFinal: true))
            continuation?.finish()
            continuation = nil
        case .prompt:
            continuation?.yield(TranscriptionChunk(text: Self.transcript, isFinal: true))
            continuation?.finish()
            continuation = nil
        case .partials:
            // Whatever the recogniser last said is the final transcript, which is what a
            // real streaming engine does: `finish()` closes the session, it does not retype
            // the dictation from somewhere else.
            continuation?.yield(TranscriptionChunk(text: latest ?? Self.transcript, isFinal: true))
            continuation?.finish()
            continuation = nil
        }
    }
}

/// First `count` mono samples of the D-04 `yes16k.wav` fixture, or nil when it is
/// missing or unreadable (the `--selftest-parakeet` short-audio check then falls
/// back to silence, which still exercises the padding).
///
/// File scope rather than a method so the shared `NextNotesApp.swift` edit stays
/// an append: the `--selftest-parakeet` block is the only caller.
func parakeetShortFixtureSamples(count: Int) -> [Float]? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/NextNotesBuild/dictation-meetings/fixtures/yes16k.wav")
    guard let file = try? AVAudioFile(forReading: url),
          file.fileFormat.sampleRate == 16_000, file.length > 0 else { return nil }
    let frames = min(count, Int(file.length))
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: file.fileFormat.sampleRate,
        channels: file.fileFormat.channelCount,
        interleaved: false),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    guard (try? file.read(into: buffer)) != nil,
          let channel = buffer.floatChannelData?.pointee
    else { return nil }
    return (0..<frames).map { channel[$0] }
}
