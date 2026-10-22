import Foundation

/// The meeting self-tests that answer their question without a window.
///
/// The app dispatches every self-test from its delegate, after the scene tree
/// exists — which is right for the tests that need a window, a controller or a
/// panel, and wrong for the tests that need none of them. A pure test (a
/// writer's counters, a pure classifier, a scripted generator) should be
/// answerable from a terminal, in a headless session and in CI, where there is
/// no window server and no bundle.
///
/// This is the same pattern the app already uses for its three standalone
/// diagnostics (`--selftest-usage-report-reader`, `--selftest-task-harness-read`
/// and `--selftest-native-termination`): one implementation, two entry points.
/// The app's own dispatcher calls `run(arguments:write:)`; the headless entry
/// calls the same function before SwiftUI starts, so a flag cannot mean one
/// thing in the app and another in a terminal.
enum MeetingHeadlessSelfTest {
    /// The flags this owns. Each one is pure: no model, no microphone, no
    /// account, and no scene.
    static let flags: Set<String> = [
        "--selftest-meeting-frame-shape",
        "--selftest-meeting-frame-layout",
        "--selftest-audio-conversion-stream",
        "--selftest-meeting-capture-coverage",
        "--selftest-meeting-title-match",
        "--selftest-notes-coverage",
        "--selftest-diarize-eligibility",
        // The meeting regressions this round could have disturbed. They are pure
        // for the same reason the tests above are: no window, no scene, no
        // account.
        "--selftest-meeting-health",
        "--selftest-diarize-assign",
        "--selftest-diarize-hints",
        "--selftest-notes-truncation",
        "--selftest-notes-longform",
        "--selftest-notes-prompt-contract",
        "--selftest-meeting-resume",
        "--selftest-meeting-backlog",
        "--selftest-meeting-tap-retry",
        "--selftest-ui-strings",
        "--selftest-store-isolation",
    ]

    /// Whether the arguments ask for one of these.
    static func isRequested(in arguments: [String]) -> Bool {
        arguments.contains { flags.contains($0) }
    }

    /// Runs the requested test. Returns false when the arguments ask for none.
    ///
    /// The caller owns the failure reporting and the exit: the app path turns a
    /// false result into `SelfTest.failed` and a termination, and the headless
    /// path turns it into an exit code.
    @MainActor
    static func run(arguments: [String], write: (String) -> Void) async -> Bool {
        if arguments.contains("--selftest-meeting-frame-shape") {
            let ok = await MeetingFrameShapeSelfTest.run(write: write)
            write(ok ? "FRAME_SHAPE_OK" : "FRAME_SHAPE_FAILED")
            return true
        }
        if arguments.contains("--selftest-meeting-frame-layout") {
            let failures = AudioFrameLayoutSelfTest.run(write: write)
            for failure in failures { write("FRAME_LAYOUT_WRONG: \(failure)") }
            write(failures.isEmpty
                ? "FRAME_LAYOUT_OK"
                : "FRAME_LAYOUT_FAILED: \(failures.count) check(s) wrong")
            SelfTest.failed = !failures.isEmpty
            return true
        }
        if arguments.contains("--selftest-audio-conversion-stream") {
            let failures = AudioConversionStreamSelfTest.run(write: write)
            for failure in failures { write("CONVERSION_WRONG: \(failure)") }
            write(failures.isEmpty
                ? "CONVERSION_OK"
                : "CONVERSION_FAILED: \(failures.count) check(s) wrong")
            SelfTest.failed = !failures.isEmpty
            return true
        }
        if arguments.contains("--selftest-meeting-capture-coverage") {
            let ok = await MeetingCaptureCoverageSelfTest.run(log: write)
            write(ok ? "COVERAGE_OK" : "COVERAGE_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-meeting-title-match") {
            let failures = MeetingTitleMatcherSelfTest.run(write: write)
            for failure in failures { write("TITLE_MATCH_WRONG: \(failure)") }
            write(failures.isEmpty
                ? "TITLE_MATCH_OK"
                : "TITLE_MATCH_FAILED: \(failures.count) check(s) wrong")
            SelfTest.failed = !failures.isEmpty
            return true
        }
        if arguments.contains("--selftest-notes-coverage") {
            let ok = await NotesCoverageSelfTest.run(write: write)
            write(ok ? "NOTES_COVERAGE_OK" : "NOTES_COVERAGE_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-diarize-eligibility") {
            let failures = DiarizationEligibilitySelfTest.run(write: write)
            for failure in failures { write("DIARIZE_ELIGIBILITY_WRONG: \(failure)") }
            write(failures.isEmpty
                ? "DIARIZE_ELIGIBILITY_OK"
                : "DIARIZE_ELIGIBILITY_FAILED: \(failures.count) check(s) wrong")
            SelfTest.failed = !failures.isEmpty
            return true
        }
        if arguments.contains("--selftest-meeting-health") {
            let ok = await MeetingHealthSelfTest.run(log: write)
            write(ok ? "MEETING_HEALTH_OK" : "MEETING_HEALTH_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-diarize-assign") {
            let failures = DiarizeAssignSelfTest.run(write: write)
            for failure in failures { write("DIARIZE_ASSIGN_WRONG: \(failure)") }
            write(failures.isEmpty
                ? "DIARIZE_ASSIGN_OK"
                : "DIARIZE_ASSIGN_FAILED: \(failures.count) check(s) wrong")
            SelfTest.failed = !failures.isEmpty
            return true
        }
        if arguments.contains("--selftest-diarize-hints") {
            let failures = await DiarizeHintsSelfTest.run(write: write)
            for failure in failures { write("DIARIZE_HINTS_WRONG: \(failure)") }
            write(failures.isEmpty
                ? "DIARIZE_HINTS_OK"
                : "DIARIZE_HINTS_FAILED: \(failures.count) check(s) wrong")
            SelfTest.failed = !failures.isEmpty
            return true
        }
        if arguments.contains("--selftest-notes-truncation") {
            let ok = await NotesTruncationSelfTest.run(write: write)
            write(ok ? "NOTES_TRUNCATION_OK" : "NOTES_TRUNCATION_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-notes-longform") {
            let ok = await NotesLongformSelfTest.run(write: write)
            write(ok ? "NOTES_LONGFORM_OK" : "NOTES_LONGFORM_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-notes-prompt-contract") {
            let ok = await NotesPromptContractSelfTest.run(write: write)
            write(ok ? "NOTES_PROMPT_CONTRACT_OK" : "NOTES_PROMPT_CONTRACT_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-meeting-resume") {
            let ok = await MeetingResumeSelfTest.run(log: write)
            write(ok ? "MEETING_RESUME_OK" : "MEETING_RESUME_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-meeting-backlog") {
            let ok = await MeetingBacklogSelfTest.run(log: write)
            write(ok ? "MEETING_BACKLOG_OK" : "MEETING_BACKLOG_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-meeting-tap-retry") {
            let ok = await MeetingTapRetrySelfTest.run(log: write)
            write(ok ? "MEETING_TAP_RETRY_OK" : "MEETING_TAP_RETRY_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-ui-strings") {
            let ok = UIStringsLint.run()
            write(ok ? "UI_STRINGS_OK" : "UI_STRINGS_FAILED")
            SelfTest.failed = !ok
            return true
        }
        if arguments.contains("--selftest-store-isolation") {
            let verdict = await StoreIsolationSelfTest.run()
            write(verdict)
            SelfTest.failed = verdict.contains("_FAILED")
            return true
        }
        return false
    }

    /// The headless entry: run the requested test and exit with its verdict.
    ///
    /// `dispatchMain()` services the main queue the test's `Task` runs on, and
    /// the test exits the process itself — the same shape as the app's
    /// standalone diagnostics, which are synchronous and return a code.
    static func runStandalone(arguments: [String]) -> Never {
        let output = SelfTest.outputFlag
        let writer: (String) -> Void = { line in
            print(line)
            if let path = SelfTest.value(after: output) {
                let url = URL(fileURLWithPath: path)
                let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? existing.appending(line + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
        Task { @MainActor in
            let handled = await run(arguments: arguments, write: writer)
            if !handled {
                writer("HEADLESS_SELFTEST_INVALID: no headless meeting self-test was requested")
                exit(1)
            }
            exit(SelfTest.failed ? 1 : 0)
        }
        dispatchMain()
        exit(1)
    }
}
