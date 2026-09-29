import AppKit
import CryptoKit
import Foundation

/// `--selftest-dictation-hygiene` — the things dictation leaves behind (D-15a, D-15b).
///
/// **D-15a, the history file.** `runs.jsonl` grew to 226 rows and 177 KB with nothing
/// pruning it, and every recorded hold re-read the whole file on the main actor before the
/// Dictation list could show the new row. Three things are checked, and none of them can
/// pass by looking at the list alone:
///
/// 1. **Recording appends in memory.** Three `RunLog.record` calls must put three runs in
///    `RunStore` *and* leave the reload counter at zero; one `update` must still rewrite
///    and reload, because a correction changes a line in place and nothing else can do it.
/// 2. **Retention selects.** `toPrune` is pure, so 5,002 runs and a fixed date are asked
///    about without writing a file.
/// 3. **Retention reaches the file.** `prune` is then run over a real temp file: the run it
///    selects is gone from the file, from the store and from a fresh `load()`, the runs
///    inside the window stay, and a second sweep with nothing to select writes nothing.
///
/// Everything happens inside one `RunLog.directoryOverride` scope over a temp directory.
/// The owner's `runs.jsonl` is read once — to compare its size, mtime and digest before and
/// after — and never written, which is the same rule `AGENTS.md` states for the controller
/// ("a self-test must never call `RunLog.record`") enforced from the other side.
///
/// **D-15b, the clipboard.** The pasteboard path restores the user's old clipboard ~500 ms
/// after typing, and a copy made inside that window is theirs; see `clipboardFailures`.
///
/// The final line is `DICTATION_HYGIENE_OK` or
/// `DICTATION_HYGIENE_FAILED: <n> problem(s)`, written by `NextNotesApp` from the array
/// this returns.
@MainActor
enum DictationHygieneSelfTest {
    /// Every problem found, in the order the cases ran. Empty is the pass.
    static func run() async -> [String] {
        var problems: [String] = []
        problems += historyFailures()
        problems += await clipboardFailures()
        return problems
    }

    // MARK: - D-15a · the history file

    private static func historyFailures() -> [String] {
        var problems: [String] = []
        let ownerRuns = AppIdentity.applicationSupportDirectory.appendingPathComponent("runs.jsonl")
        let ownerBefore = stamp(of: ownerRuns)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NextNotesBuild/dictation-hygiene-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        RunLog.$directoryOverride.withValue(temp) {
            problems += inMemoryAppendFailures()
            problems += retentionSelectionFailures()
            problems += retentionPruneFailures()
        }

        // The whole point of the scope above. A history self-test that reached the owner's
        // file would be indistinguishable from the production path it is testing — and
        // `--selftest-store-isolation` is the flag that watches the same file from outside.
        if let ownerBefore, ownerBefore != stamp(of: ownerRuns) {
            problems.append("the owner's runs.jsonl changed during the run")
        }
        return problems
    }

    /// Three recorded runs, no file re-read; one edit, exactly one.
    private static func inMemoryAppendFailures() -> [String] {
        var problems: [String] = []
        let store = RunStore.shared
        store.resetReloadCountForSelfTest()
        let before = store.runs.count

        let recorded = (0..<3).map { index in
            DictationRun(
                date: Date(),
                engine: "selftest",
                audioSeconds: 1.5,
                processSeconds: 0.5,
                text: "hygiene row \(index)"
            )
        }
        for run in recorded { RunLog.record(run) }

        if store.runs.count != before + 3 {
            problems.append(
                "3 recorded runs left the store holding \(store.runs.count - before), expected 3"
            )
        }
        if Array(store.runs.suffix(3).map(\.id)) != recorded.map(\.id) {
            problems.append("the 3 recorded runs did not reach the store newest-last")
        }
        if store.reloadCount != 0 {
            problems.append(
                "recording 3 runs re-read runs.jsonl \(store.reloadCount) time(s), expected none"
            )
        }
        // The file is still written — appending in memory is about the *read*, not the write.
        if RunLog.load().suffix(3).map(\.id) != recorded.map(\.id) {
            problems.append("the 3 recorded runs did not reach the file")
        }

        var edited = recorded[0]
        edited.editedText = "hygiene row 0, corrected"
        store.resetReloadCountForSelfTest()
        RunLog.update(edited)
        if store.reloadCount != 1 {
            problems.append(
                "editing a run re-read runs.jsonl \(store.reloadCount) time(s), expected 1"
            )
        }
        if RunLog.load().first { $0.id == edited.id }?.editedText != edited.editedText {
            problems.append("the edit did not reach the file")
        }
        if store.runs.first { $0.id == edited.id }?.editedText != edited.editedText {
            problems.append("the edit did not reach the store")
        }
        return problems
    }

    /// The pure selection: 90 days prunes one old run, 5,000 rows prunes the oldest two,
    /// and forever prunes nothing whatever the input looks like.
    private static func retentionSelectionFailures() -> [String] {
        var problems: [String] = []
        let now = Date()
        func run(daysAgo: Double, text: String) -> DictationRun {
            DictationRun(
                date: now.addingTimeInterval(-daysAgo * 86_400),
                engine: "selftest",
                audioSeconds: 1,
                processSeconds: 1,
                text: text
            )
        }

        let old = run(daysAgo: 100, text: "a hundred days old")
        let recent = run(daysAgo: 10, text: "ten days old")
        let ninetyDay = RunLog.toPrune([old, recent], policy: .days90, now: now)
        if ninetyDay != [old.id] {
            problems.append(
                "90-day retention selected \(ninetyDay.count) of 2 runs, expected only the 100-day-old one"
            )
        }

        // Newest first on purpose: "the oldest 2" has to come from the dates rather than
        // from dropping the head of the array. `runs.jsonl` is append order, and a run
        // written by a machine with a wrong clock is still the older one.
        let many = (0..<5_002).map { index in
            run(daysAgo: Double(5_002 - index), text: "row \(index)")
        }.reversed()
        let expected = Set(many.suffix(2).map(\.id))
        let byCount = RunLog.toPrune(Array(many), policy: .rows5000, now: now)
        if byCount != expected {
            problems.append(
                "5,000-row retention selected \(byCount.count) of 5,002 runs, expected the 2 oldest"
            )
        }
        if !RunLog.toPrune(Array(many), policy: .forever, now: now).isEmpty {
            problems.append("forever selected runs to prune")
        }
        return problems
    }

    /// `prune` over a real temp file: the run it selects is gone from the file, from the
    /// store and from a fresh load, and the runs inside the window stay.
    private static func retentionPruneFailures() -> [String] {
        var problems: [String] = []
        let now = Date()
        let old = DictationRun(
            date: now.addingTimeInterval(-100 * 86_400),
            engine: "selftest",
            audioSeconds: 1,
            processSeconds: 1,
            text: "pruned by the 90-day policy"
        )
        let kept = DictationRun(
            date: now.addingTimeInterval(-3 * 86_400),
            engine: "selftest",
            audioSeconds: 1,
            processSeconds: 1,
            text: "kept by the 90-day policy"
        )
        RunLog.record(old)
        RunLog.record(kept)

        guard RunLog.prune(policy: .days90, now: now) >= 1 else {
            problems.append("prune removed nothing")
            return problems
        }
        let remaining = RunLog.load()
        if remaining.map(\.id).contains(old.id) {
            problems.append("the 100-day-old run is still in the file after pruning")
        }
        if !remaining.map(\.id).contains(kept.id) {
            problems.append("pruning removed a run inside the 90-day window")
        }
        if RunStore.shared.runs.map(\.id).contains(old.id) {
            problems.append("the 100-day-old run is still in the store after pruning")
        }
        // Nothing selected, nothing written: the steady state must not rewrite a file the
        // user has not added to since the last sweep.
        let runsURL = RunLog.directory.appendingPathComponent("runs.jsonl")
        let stampBefore = stamp(of: runsURL)
        if RunLog.prune(policy: .days90, now: now) != 0 {
            problems.append("a second prune with nothing to remove reported removals")
        }
        if stampBefore != stamp(of: runsURL) {
            problems.append("prune rewrote runs.jsonl with nothing selected")
        }
        return problems
    }

    // MARK: - Helpers

    /// The pasteboard, D-15b.
    ///
    /// The pasteboard path writes the dictated text, posts ⌘V, and puts the user's old
    /// clipboard back about 500 ms later. A copy made inside that window used to be
    /// silently overwritten, because the restore was unconditional: the user pressed ⌘C
    /// while their dictation was still being typed and lost whatever they had copied.
    ///
    /// Two cases on a private pasteboard, so nothing here touches `NSPasteboard.general`,
    /// posts a real ⌘V, or can disturb what the user has on the real one: case 1 does
    /// nothing and the saved contents must come back; case 2 copies "C" inside the window
    /// and that copy must survive. Case 1 is the one that would break if the guard were
    /// wrong in the other direction — a restore that never runs leaves the dictated text on
    /// the clipboard, which is how the AX path's `couldNotReturn` rescue is chosen.
    private static func clipboardFailures() async -> [String] {
        var problems: [String] = []
        let pasteboard = NSPasteboard(name: .init("ai.pivotstudio.nextnotes.selftest"))
        // Claimed and released rather than left registered, so a run cannot outlive itself
        // holding a pasteboard name the next one wants.
        pasteboard.releaseGlobally()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("A", forType: .string)
        let first = await TextInjector.insertViaPasteboard(
            "B",
            pasteboard: pasteboard,
            postPaste: {},
            restoreDelay: .milliseconds(50)
        )
        await first?.value
        if pasteboard.string(forType: .string) != "A" {
            problems.append(
                "the saved clipboard was not restored: it reads \(read(pasteboard))"
            )
        }

        pasteboard.clearContents()
        pasteboard.setString("A", forType: .string)
        let second = await TextInjector.insertViaPasteboard(
            "B",
            pasteboard: pasteboard,
            postPaste: {},
            restoreDelay: .milliseconds(200)
        )
        try? await Task.sleep(for: .milliseconds(20))
        pasteboard.clearContents()
        pasteboard.setString("C", forType: .string)
        await second?.value
        if pasteboard.string(forType: .string) != "C" {
            problems.append(
                "a copy made during the restore window was overwritten: the pasteboard reads \(read(pasteboard))"
            )
        }

        // Cancel during the 40 ms pasteboard handoff: the old hold must not
        // post ⌘V after a newer hold has taken the microphone, and the saved
        // clipboard must come back because no paste was made.
        pasteboard.clearContents()
        pasteboard.setString("A", forType: .string)
        var current = true
        var posted = false
        let canceled = Task { @MainActor in
            await TextInjector.insertViaPasteboard(
                "B",
                pasteboard: pasteboard,
                postPaste: { posted = true },
                restoreDelay: .milliseconds(50),
                whileCurrent: { current }
            )
        }
        let handoffBy = Date().addingTimeInterval(0.1)
        while Date() < handoffBy, pasteboard.string(forType: .string) != "B" {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if pasteboard.string(forType: .string) != "B" {
            problems.append("the canceled insertion never entered the pasteboard handoff")
        }
        current = false
        let canceledRestore = await canceled.value
        await canceledRestore?.value
        if posted || pasteboard.string(forType: .string) != "A" {
            problems.append("a canceled insertion posted paste or left its text on the clipboard")
        }
        return problems
    }

    private static func read(_ pasteboard: NSPasteboard) -> String {
        pasteboard.string(forType: .string).map { "\"\($0)\"" } ?? "nothing"
    }

    /// `"size|mtime|digest"`, or nil when the file is absent. The digest as well as the
    /// mtime, for the reason `SelfTestStoreGuard` gives: an atomic write can replace a file
    /// with the same size inside the same second, and this is the only assertion standing
    /// between a self-test and the owner's history.
    private static func stamp(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(size)|\(modified)|\(digest)"
    }
}
