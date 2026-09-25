import Foundation

/// `--selftest-usage-log`: the usage log's writer, reader, rotation, age compaction,
/// clear, sanitiser and harness isolation (P0-20a, U1–U7), the meeting passes (P0-20b,
/// M1–M5), the summary and report (P0-20d, R1–R3), the dictation builder (P0-20c, D1),
/// the exit cases (P0-20e, E1–E4) and the meeting model passes M-16b wired behind
/// P0-20b's writer (M6 collapse rows, M7 the live reconcile pass).
///
/// Final marker: `USAGE_LOG_OK: <n> cases` / `USAGE_LOG_FAILED: <n> problem(s)`, with one
/// `USAGE_LOG_WRONG: <case>: <reason>` line per failure. The marker name never changes; a
/// later task adds cases and moves the count.
///
/// **Red-first.** Against the P0-20a seams (a `UsageLog` that records nothing and a
/// `ModelPassRecorder` that writes nothing) U1–U6 fail and U7 passes, because
/// `UsageLog.shared` is already isolated under the harness. Register the flag in
/// `NextNotesApp.runRequestedSelfTest` next to `--selftest-metrics` as
/// `SelfTest.failed = !UsageLogSelfTest.run()`.
///
/// **P0-20b red-first.** M1–M4 exercise the real meeting call paths against no-op seams
/// (a `MeetingTranscribeTally` that returns nil, `NotesGenerator` and `MeetingAgent`
/// writing no rows); each case reports "0 usage rows" until the wrappers land, and M5
/// fails because it has nothing to scan.
///
/// **P0-20e red-first.** E1 drives one run of every feature — a scripted typed turn with
/// one tool through the real `RealtimeAgent.handle`, a scripted notes pass through the real
/// `NotesGenerator`, and `UsageRecord.dictationRows` — into one isolated store; E2 scans
/// every row those legs and M1–M5 and D1 wrote for twelve sentinel strings; E3 proves the
/// owner's real `usage.jsonl` (and the guard's registration of it) is untouched; E4 locks
/// the `UsageRecord` coding keys to the documented schema. E1 fails until P0-20c's
/// `dictationRows` writes rows and E3 fails until the guard knows the file, so the red run
/// is the missing dictation seam plus the missing guard entry.
enum UsageLogSelfTest {
    /// How many cases a green run reports: U1–U7, M1–M7, D1, R1–R3 and E1–E4.
    private static let caseCount = 22

    /// `run()` is async so E1 can await the real main-actor agent path: the old synchronous
    /// runner blocked the main actor on a semaphore while its cases ran, which no
    /// `@MainActor` production path can survive.
    static func run() async -> Bool {
        var failures: [String] = []
        var rows: [UsageRecord] = []
        // E3's before-picture, taken before any case can write anything. `usage.jsonl` is
        // in the guard's list, so the snapshot is the same one `--selftest-store-isolation`
        // reads.
        let realBefore = SelfTestStoreGuard.take()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-usage-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["u1", "u2", "u3", "u4", "u5"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(name, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        } catch {
            failures.append("setup: could not create the self-test directories: \(error.localizedDescription)")
        }

        if failures.isEmpty {
            failures += labelled("U1", checkU1(root: root))
            failures += labelled("U2", checkU2(root: root))
            failures += labelled("U3", checkU3(root: root))
            failures += labelled("U4", checkU4(root: root))
            failures += labelled("U5", checkU5(root: root))
            failures += labelled("U6", checkU6())
            failures += labelled("U7", checkU7())

            let e1 = await checkE1()
            failures += labelled("E1", e1.problems)
            rows += e1.rows

            let meetings = await checkMeetings()
            failures += meetings.problems
            rows += meetings.rows

            let d1 = checkD1()
            failures += labelled("D1", d1.problems)
            rows += d1.rows

            failures += labelled("E2", checkE2(rows: rows))
            failures += labelled("E3", checkE3(before: realBefore))
            failures += labelled("E4", checkE4())
        }

        for failure in failures { print("USAGE_LOG_WRONG: \(failure)") }
        guard failures.isEmpty else {
            print("USAGE_LOG_FAILED: \(failures.count) problem(s)")
            return false
        }
        print("USAGE_LOG_OK: \(caseCount) cases")
        return true
    }

    // MARK: - U1 round trip

    /// A row with every field filled writes and loads back field for field.
    private static func checkU1(root: URL) -> [String] {
        let log = UsageLog(directory: root.appendingPathComponent("u1", isDirectory: true))
        let row = fullyPopulatedRow()
        log.record(row)
        log.flush()
        let loaded = log.load()
        guard loaded.count == 1, let back = loaded.first else {
            return ["wrote 1 row, loaded \(loaded.count)"]
        }
        if back != row {
            return ["the row did not round-trip field for field"]
        }
        return []
    }

    // MARK: - U2 tolerance

    /// An unknown key and missing optionals decode; a `v` the reader does not know and a
    /// corrupt line are skipped without taking the next line with them.
    private static func checkU2(root: URL) -> [String] {
        let dir = root.appendingPathComponent("u2", isDirectory: true)
        let firstID = UUID()
        let skippedID = UUID()
        let lastID = UUID()
        let lines = [
            #"{"v":1,"id":"\#(firstID.uuidString)","ts":"2026-01-01T00:00:00Z","feature":"agent.typed","pass":"answer","provider":"llama","modelID":"M","locality":"local","totalMs":12,"futureKey":true}"#,
            #"{"v":2,"id":"\#(skippedID.uuidString)","ts":"2026-01-01T00:00:00Z","feature":"agent.typed","pass":"answer","provider":"llama","modelID":"M","locality":"local","totalMs":12}"#,
            "this line is not JSON",
            #"{"v":1,"id":"\#(lastID.uuidString)","ts":"2026-01-02T00:00:00Z","feature":"agent.typed","pass":"answer","provider":"llama","modelID":"M","locality":"local","totalMs":34}"#,
        ]
        guard write(lines.joined(separator: "\n") + "\n", to: dir.appendingPathComponent(UsageLog.fileName)) else {
            return ["could not write the fixture file"]
        }
        let loaded = UsageLog(directory: dir).load()
        guard loaded.count == 2 else {
            return ["loaded \(loaded.count) row(s), expected 2: an unknown key decodes, v=2 and a corrupt line are skipped"]
        }
        let ids = Set(loaded.map(\.id))
        if !ids.contains(firstID) {
            return ["the row with an unknown key and missing optionals did not decode"]
        }
        if !ids.contains(lastID) {
            return ["the row after the corrupt line did not load"]
        }
        if ids.contains(skippedID) {
            return ["the v=2 row was not skipped"]
        }
        return []
    }

    // MARK: - U3 rotation

    /// 40 rows of ~650 bytes with a 4 KB cap leave exactly two files, the newest rows in
    /// `usage.jsonl`, `load()` in time order, and the oldest rows gone.
    private static func checkU3(root: URL) -> [String] {
        let dir = root.appendingPathComponent("u3", isDirectory: true)
        let log = UsageLog(directory: dir, maxBytes: 4_096)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let ids = (0..<40).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            log.record(usageRow(id: id, ts: base.addingTimeInterval(Double(index)), padding: 430))
        }
        log.flush()

        let files = Set(usageFiles(in: dir))
        guard files == Set([UsageLog.fileName, UsageLog.rotatedName]) else {
            return ["after 40 rows the usage files were \(files.sorted()), expected usage.jsonl and usage.1.jsonl"]
        }
        let loaded = log.load()
        var problems: [String] = []
        if loaded.count >= ids.count {
            problems.append("rotation kept all \(ids.count) rows")
        }
        if !loaded.contains(where: { $0.id == ids[ids.count - 1] }) {
            problems.append("the newest row is missing from load()")
        }
        if loaded.contains(where: { $0.id == ids[0] }) {
            problems.append("the oldest row survived rotation")
        }
        if loaded.map(\.ts) != loaded.map(\.ts).sorted() {
            problems.append("load() is not in time order")
        }
        let newestText = (try? String(contentsOf: dir.appendingPathComponent(UsageLog.fileName), encoding: .utf8)) ?? ""
        if !newestText.contains(ids[ids.count - 1].uuidString) {
            problems.append("usage.jsonl does not hold the newest row")
        }
        if newestText.contains(ids[0].uuidString) {
            problems.append("usage.jsonl still holds the oldest row")
        }
        return problems
    }

    // MARK: - U4 age

    /// With now 100 days after half the rows' `ts`, `compact()` leaves only rows inside
    /// the 90-day window. The fixture is written straight into `usage.1.jsonl`, the only
    /// file compaction touches.
    private static func checkU4(root: URL) -> [String] {
        let dir = root.appendingPathComponent("u4", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldRows = (0..<3).map { index in
            usageRow(id: UUID(), ts: now.addingTimeInterval(Double(-100 * 86_400 + index)))
        }
        let freshRows = (0..<3).map { index in
            usageRow(id: UUID(), ts: now.addingTimeInterval(Double(-10 * 86_400 + index)))
        }
        guard writeJSONL(oldRows + freshRows, to: dir.appendingPathComponent(UsageLog.rotatedName)) else {
            return ["could not write the rotated fixture file"]
        }
        let log = UsageLog(directory: dir, maxAgeDays: 90, now: { now })
        log.compact()
        log.flush()

        let loaded = log.load()
        let loadedIDs = Set(loaded.map(\.id))
        var problems: [String] = []
        let survivors = oldRows.filter { loadedIDs.contains($0.id) }
        if !survivors.isEmpty {
            problems.append("\(survivors.count) row(s) older than 90 days survived compact()")
        }
        let missing = freshRows.filter { !loadedIDs.contains($0.id) }
        if !missing.isEmpty || loaded.count != freshRows.count {
            problems.append("compact() lost rows inside the age window: \(loaded.count) loaded, \(freshRows.count) expected")
        }
        return problems
    }

    // MARK: - U5 clear

    /// `clear()` removes both files, and the writer still works afterwards.
    private static func checkU5(root: URL) -> [String] {
        let dir = root.appendingPathComponent("u5", isDirectory: true)
        let log = UsageLog(directory: dir, maxBytes: 4_096)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<20 {
            log.record(usageRow(id: UUID(), ts: base.addingTimeInterval(Double(index)), padding: 430))
        }
        log.flush()

        let before = Set(usageFiles(in: dir))
        guard before == Set([UsageLog.fileName, UsageLog.rotatedName]) else {
            return ["before clear() the two files did not exist: \(before.sorted())"]
        }
        log.clear()
        log.flush()
        let after = usageFiles(in: dir)
        if !after.isEmpty {
            return ["clear() left \(after.sorted())"]
        }

        let fresh = usageRow(id: UUID(), ts: Date(timeIntervalSince1970: 1_800_000_000), padding: 0)
        log.record(fresh)
        log.flush()
        let loaded = log.load()
        if loaded.count != 1 || loaded.first?.id != fresh.id {
            return ["the writer did not work after clear(): loaded \(loaded.count) row(s)"]
        }
        return []
    }

    // MARK: - U6 sanitiser

    /// The sanitised message contains none of the quoted, addressed, linked, pathed or
    /// long-digit content, keeps its own words, and fits 160 characters.
    private static func checkU6() -> [String] {
        let raw = #"Could not send "Pricing Q3" to marc@acme.com at https://x.y/z from /Users/s/a.txt ref 12345678"#
        let clean = UsageLog.sanitise(raw)
        var problems: [String] = []
        let banned = ["Pricing", "marc@", "https://", "/Users/", "12345678"]
        let left = banned.filter { clean.contains($0) }
        if !left.isEmpty {
            problems.append("sanitise left \(left.joined(separator: ", ")) in the message")
        }
        if clean.count > 160 {
            problems.append("sanitise returned \(clean.count) characters, expected at most 160")
        }
        if !clean.contains("Could not send") {
            problems.append("sanitise removed the message's own words")
        }
        return problems
    }

    // MARK: - U7 isolation

    /// Under the harness `UsageLog.shared` is a temp directory, never the owner's store.
    private static func checkU7() -> [String] {
        let directory = UsageLog.shared.directory
        if directory == AppIdentity.applicationSupportDirectory {
            return ["UsageLog.shared points at the owner's support directory under the harness"]
        }
        if !directory.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            return ["UsageLog.shared is not under the temporary directory: \(directory.path)"]
        }
        return []
    }

    // MARK: - M1–M5: the meeting passes (P0-20b)

    /// Runs the meeting cases. They write through `UsageLog.shared`, which the harness
    /// points at a per-process temp directory, so nothing here can reach the owner's file;
    /// the clear makes the run independent of anything this process logged earlier.
    private static func checkMeetings() async -> CaseOutcome {
        UsageLog.shared.clear()
        UsageLog.shared.flush()

        var outcome = CaseOutcome()

        let m1 = await checkM1()
        outcome.problems += labelled("M1", m1.problems)
        outcome.rows += m1.rows
        let m2 = await checkM2()
        outcome.problems += labelled("M2", m2.problems)
        outcome.rows += m2.rows
        let m3 = await checkM3()
        outcome.problems += labelled("M3", m3.problems)
        outcome.rows += m3.rows
        let m4 = await checkM4()
        outcome.problems += labelled("M4", m4.problems)
        outcome.rows += m4.rows
        // M-16b: the passes P0-20b left behind. M6 is the task's red-first case — the
        // 90-minute fixture writes exactly `chunks` map rows, `collapsedGroups` collapse
        // rows and one reduce row; M7 pins the live reconcile pass. Both run before M5
        // so the privacy scan sees every meeting row these cases wrote.
        let m6 = await checkM6()
        outcome.problems += labelled("M6", m6.problems)
        outcome.rows += m6.rows
        let m7 = await checkM7()
        outcome.problems += labelled("M7", m7.problems)
        outcome.rows += m7.rows
        outcome.problems += labelled("M5", checkM5(rows: outcome.rows))
        return outcome
    }

    /// M1: a 3-segment transcript through the real single-pass path writes exactly one
    /// `meeting.notes.single` row for the fixture meeting.
    private static func checkM1() async -> CaseOutcome {
        let meeting = fixtureMeeting("Zarquon briefing")
        let provider = ScriptedUsageProvider(contextTokens: 32_768)
        do {
            _ = try await NotesGenerator(provider: provider).notes(
                for: meeting,
                segments: m1Segments()
            )
        } catch {
            return CaseOutcome(problems: ["the single-pass notes call threw: \(error)"])
        }
        let rows = usageRows(meetingID: meeting.id, feature: .meetingNotesSingle)
        guard rows.count == 1, let row = rows.first else {
            return CaseOutcome(
                problems: ["expected exactly 1 meeting.notes.single row, wrote \(rows.count)"],
                rows: rows)
        }
        var problems: [String] = []
        if row.provider != UsageProvider.llama.rawValue {
            problems.append("provider was \(row.provider), expected \(UsageProvider.llama.rawValue)")
        }
        if row.pass != "single" {
            problems.append("pass was \(row.pass), expected single")
        }
        if (row.completionTokens ?? 0) <= 0 {
            problems.append("completionTokens was \(row.completionTokens.map { String($0) } ?? "nil"), expected > 0")
        }
        if row.totalMs <= 0 {
            problems.append("totalMs was \(row.totalMs), expected > 0")
        }
        if row.requestedRole != ModelRole.meetingNotes.rawValue {
            problems.append("requestedRole was \(row.requestedRole ?? "nil"), "
                            + "expected \(ModelRole.meetingNotes.rawValue)")
        }
        return CaseOutcome(problems: problems, rows: rows)
    }

    /// M2: a 40-segment transcript that cannot fit one prompt writes ≥ 2
    /// `meeting.notes.map` rows and one `meeting.notes.reduce` row for the same meeting,
    /// and the reduce row's `chunks` count equals the map rows.
    private static func checkM2() async -> CaseOutcome {
        let meeting = fixtureMeeting("Zephyrquark review")
        let provider = ScriptedUsageProvider(contextTokens: 4_096)
        do {
            _ = try await NotesGenerator(provider: provider).notes(
                for: meeting,
                segments: m2Segments()
            )
        } catch {
            return CaseOutcome(problems: ["the map/reduce notes call threw: \(error)"])
        }
        let maps = usageRows(meetingID: meeting.id, feature: .meetingNotesMap)
        let reduces = usageRows(meetingID: meeting.id, feature: .meetingNotesReduce)
        var problems: [String] = []
        if maps.count < 2 {
            problems.append("expected at least 2 meeting.notes.map rows, wrote \(maps.count)")
        }
        guard reduces.count == 1, let reduce = reduces.first else {
            problems.append("expected exactly 1 meeting.notes.reduce row, wrote \(reduces.count)")
            return CaseOutcome(problems: problems, rows: maps + reduces)
        }
        if reduce.counts?["chunks"] != maps.count {
            problems.append("the reduce row's chunks was "
                            + "\(reduce.counts?["chunks"].map { String($0) } ?? "nil"), "
                            + "expected \(maps.count)")
        }
        if reduce.counts?["facts"] == nil {
            problems.append("the reduce row has no facts count")
        }
        if reduce.pass != "reduce" {
            problems.append("the reduce row's pass was \(reduce.pass), expected reduce")
        }
        if let map = maps.first(where: { $0.pass != "map" }) {
            problems.append("a map row's pass was \(map.pass), expected map")
        }
        if maps.contains(where: { $0.provider != UsageProvider.llama.rawValue }) {
            problems.append("a map row did not carry provider \(UsageProvider.llama.rawValue)")
        }
        return CaseOutcome(problems: problems, rows: maps + reduces)
    }

    /// M3: a window too small for the tool schemas writes one `meeting.proposals` row
    /// before the pass throws `contextTooSmall`, with `reserved` and `budget` counts.
    private static func checkM3() async -> CaseOutcome {
        let meeting = fixtureMeeting("Zarquon planning")
        let provider = ScriptedUsageProvider(contextTokens: 2_048)
        do {
            _ = try await MeetingAgent.shared.proposals(
                for: meeting,
                segments: m1Segments(),
                notes: nil,
                provider: provider,
                policy: .dryRun,
                toolsOverride: []
            )
            return CaseOutcome(problems: ["the pass succeeded; expected AgentError.contextTooSmall"])
        } catch let error as AgentError {
            if error != .contextTooSmall {
                return CaseOutcome(problems: ["the pass threw \(error), expected contextTooSmall"])
            }
        } catch {
            return CaseOutcome(problems: ["the pass threw \(error), expected contextTooSmall"])
        }
        let rows = usageRows(meetingID: meeting.id, feature: .meetingProposals)
        guard rows.count == 1, let row = rows.first else {
            return CaseOutcome(
                problems: ["expected exactly 1 meeting.proposals row after a contextTooSmall "
                           + "failure, wrote \(rows.count)"],
                rows: rows)
        }
        var problems: [String] = []
        if row.errorClass != UsageErrorClass.contextTooSmall.rawValue {
            problems.append("errorClass was \(row.errorClass ?? "nil"), "
                            + "expected \(UsageErrorClass.contextTooSmall.rawValue)")
        }
        if row.counts?["reserved"] == nil {
            problems.append("the row has no reserved count")
        }
        if row.counts?["budget"] == nil {
            problems.append("the row has no budget count")
        }
        return CaseOutcome(problems: problems, rows: rows)
    }

    /// M4: three window outcomes — transcribed 30 s of audio in 1.2 s, a silent skip and a
    /// failure — drain as one row with every window counted and only the transcribed one
    /// contributing audio, compute and lane wait.
    private static func checkM4() async -> CaseOutcome {
        let meeting = fixtureMeeting("Zarquon transcript")
        let tally = MeetingTranscribeTally()
        await tally.note(meetingID: meeting.id, source: .mic, audioSeconds: 30,
                         computeSeconds: 1.2, laneWait: 0.25, outcome: .transcribed)
        await tally.note(meetingID: meeting.id, source: .mic, audioSeconds: 10,
                         computeSeconds: 0, laneWait: 0, outcome: .silentSkipped)
        await tally.note(meetingID: meeting.id, source: .mic, audioSeconds: 20,
                         computeSeconds: 0.3, laneWait: 0, outcome: .failed)
        guard let row = await tally.drain(meetingID: meeting.id, source: .mic) else {
            return CaseOutcome(problems: ["drain returned no row after three window outcomes"])
        }
        var problems: [String] = []
        if row.feature != UsageFeature.meetingTranscribe.rawValue {
            problems.append("feature was \(row.feature)")
        }
        if row.provider != UsageProvider.parakeet.rawValue {
            problems.append("provider was \(row.provider), expected \(UsageProvider.parakeet.rawValue)")
        }
        if row.modelID != MeetingTranscribeTally.parakeetModelID {
            problems.append("modelID was \(row.modelID), expected \(MeetingTranscribeTally.parakeetModelID)")
        }
        if row.pass != AudioSource.mic.rawValue {
            problems.append("pass was \(row.pass), expected \(AudioSource.mic.rawValue)")
        }
        if row.meetingID != meeting.id {
            problems.append("meetingID did not carry the fixture meeting")
        }
        if abs((row.audioSeconds ?? 0) - 30) > 0.001 {
            problems.append("audioSeconds was \(row.audioSeconds.map { String($0) } ?? "nil"), expected 30")
        }
        if !(1_100...1_300).contains(row.totalMs) {
            problems.append("totalMs was \(row.totalMs), expected about 1200 (the transcribed window's compute)")
        }
        if let factor = row.realtimeFactor {
            if abs(factor - 0.04) > 0.005 {
                problems.append("realtimeFactor was \(factor), expected about 0.04")
            }
        } else {
            problems.append("the row has no realtimeFactor")
        }
        if let laneWait = row.stages?["laneWait"] {
            if abs(laneWait - 0.25) > 0.001 {
                problems.append("stages[laneWait] was \(laneWait), expected 0.25")
            }
        } else {
            problems.append("the row has no stages[laneWait]")
        }
        if row.counts?["windows"] != 3 {
            problems.append("windows was \(row.counts?["windows"].map { String($0) } ?? "nil"), expected 3")
        }
        if row.counts?["silentSkipped"] != 1 {
            problems.append("silentSkipped was \(row.counts?["silentSkipped"].map { String($0) } ?? "nil"), expected 1")
        }
        if row.counts?["failed"] != 1 {
            problems.append("failed was \(row.counts?["failed"].map { String($0) } ?? "nil"), expected 1")
        }
        return CaseOutcome(problems: problems, rows: [row])
    }

    // MARK: - M6/M7: the passes M-16b wired (the collapse pass, the live reconcile)

    /// M6 (M-16b, red-first): the 90-minute case through the real map-reduce path writes
    /// exactly `chunks` map rows, `collapsedGroups` collapse rows and one reduce row, all
    /// carrying the same meeting id. Reuses the longform fixture — the worst-case provider
    /// M-05 calibrated, whose collapse pass the P0-20b wrappers did not reach.
    private static func checkM6() async -> CaseOutcome {
        let meeting = fixtureMeeting("Zarquon longform")
        let result: NotesGenerator.Result?
        do {
            result = try await NotesGenerator(provider: LongformNotesProvider(contextTokens: 4_096))
                .notes(
                    for: meeting,
                    segments: NotesLongformSelfTest.longSegments(),
                    brief: NotesLongformSelfTest.bigBrief()
                )
        } catch {
            return CaseOutcome(problems: ["the 90-min notes call threw: \(error)"])
        }
        guard let result else {
            return CaseOutcome(problems: ["the 90-min notes call returned no result"])
        }
        guard result.usedMapReduce, result.collapsedGroups >= 1 else {
            return CaseOutcome(problems: [
                "the 90-min case took no collapse pass (chunks=\(result.chunks) "
                    + "collapsed=\(result.collapsedGroups)), so the row-count check proves nothing",
            ])
        }
        UsageLog.shared.flush()
        let all = UsageLog.shared.load().filter { $0.meetingID == meeting.id }
        let maps = all.filter { $0.feature == UsageFeature.meetingNotesMap.rawValue }
        let collapses = all.filter { $0.feature == UsageFeature.meetingNotesCollapse.rawValue }
        let reduces = all.filter { $0.feature == UsageFeature.meetingNotesReduce.rawValue }
        var problems: [String] = []
        if maps.count != result.chunks {
            problems.append("wrote \(maps.count) meeting.notes.map row(s), expected result.chunks \(result.chunks)")
        }
        if collapses.count != result.collapsedGroups {
            problems.append("wrote \(collapses.count) meeting.notes.collapse row(s), "
                            + "expected result.collapsedGroups \(result.collapsedGroups)")
        }
        if reduces.count != 1 {
            problems.append("wrote \(reduces.count) meeting.notes.reduce row(s), expected 1")
        }
        if all.count != maps.count + collapses.count + reduces.count {
            problems.append("the meeting wrote \(all.count) row(s) across all features, "
                            + "expected only map + collapse + reduce")
        }
        if let collapse = collapses.first(where: { $0.pass != "collapse" }) {
            problems.append("a collapse row's pass was \(collapse.pass), expected collapse")
        }
        if collapses.contains(where: { $0.provider != UsageProvider.appleFM.rawValue }) {
            // The longform fixture's provider is Apple's, unlike M1/M2's scripted llama.
            problems.append("a collapse row did not carry provider \(UsageProvider.appleFM.rawValue)")
        }
        if let reduce = reduces.first {
            if reduce.counts?["chunks"] != result.chunks {
                problems.append("the reduce row's chunks was "
                                + "\(reduce.counts?["chunks"].map { String($0) } ?? "nil"), "
                                + "expected \(result.chunks)")
            }
            if reduce.counts?["facts"] == nil {
                problems.append("the reduce row has no facts count")
            }
        }
        return CaseOutcome(problems: problems, rows: all)
    }

    /// M7 (M-16b): the live reconcile model pass — `MeetingContextReconciler`'s
    /// `ModelCompleter`, previously a bare `provider.complete` — writes one
    /// `meeting.reconcile` row for its meeting. Driven through the same recorded pass
    /// production runs, with the scripted provider `refine` resolves in production.
    private static func checkM7() async -> CaseOutcome {
        let meeting = fixtureMeeting("Zarquon reconcile")
        do {
            _ = try await MeetingContextReconciler.ModelCompleter.recordedComplete(
                system: "Refine a live meeting context for the usage self-test.",
                user: "The recent transcript is not part of this row.",
                provider: ScriptedUsageProvider(contextTokens: 32_768),
                meetingID: meeting.id,
                maxTokens: 400
            )
        } catch {
            return CaseOutcome(problems: ["the reconcile pass threw: \(error)"])
        }
        let rows = usageRows(meetingID: meeting.id, feature: .meetingReconcile)
        guard rows.count == 1, let row = rows.first else {
            return CaseOutcome(
                problems: ["expected exactly 1 meeting.reconcile row, wrote \(rows.count)"],
                rows: rows)
        }
        var problems: [String] = []
        if row.pass != "reconcile" {
            problems.append("pass was \(row.pass), expected reconcile")
        }
        if row.provider != UsageProvider.llama.rawValue {
            problems.append("provider was \(row.provider), expected \(UsageProvider.llama.rawValue)")
        }
        if (row.completionTokens ?? 0) <= 0 {
            problems.append("completionTokens was \(row.completionTokens.map { String($0) } ?? "nil"), expected > 0")
        }
        if row.totalMs <= 0 {
            problems.append("totalMs was \(row.totalMs), expected > 0")
        }
        return CaseOutcome(problems: problems, rows: rows)
    }

    /// M5: every row M1–M4 and M6–M7 produced is scanned for the fixture transcript words.
    /// A run that wrote no rows fails too: an empty scan proves nothing.
    private static func checkM5(rows: [UsageRecord]) -> [String] {
        guard !rows.isEmpty else {
            return ["the meeting cases produced no rows, so there is nothing to scan for transcript text"]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let words = fixtureTranscriptWords
        var problems: [String] = []
        for row in rows {
            guard let data = try? encoder.encode(row),
                  let json = String(data: data, encoding: .utf8)?.lowercased() else {
                problems.append("a \(row.feature) row could not be encoded for the scan")
                continue
            }
            for word in words where json.contains(word) {
                problems.append("the \(row.feature) row leaked the transcript word \"\(word)\"")
            }
        }
        return problems
    }

    // MARK: - M case helpers

    private struct CaseOutcome: Sendable {
        var problems: [String] = []
        var rows: [UsageRecord] = []
    }

    // MARK: - D1: the dictation rows (P0-20c)

    /// The pure builder behind one dictation: two rows sharing a `dictationRunID`, stages
    /// equal to the tail's own numbers, and the timeout finish reason when either leg hit
    /// its deadline. Called twice so the timeout path is pinned as well.
    private static func checkD1() -> CaseOutcome {
        var problems: [String] = []
        var rows: [UsageRecord] = []
        let runID = UUID()

        var cleanup = CleanupRecord()
        cleanup.engine = "s1Mini"
        cleanup.modelRan = true
        cleanup.sessionPrewarmed = false
        cleanup.fallbackReason = "the cleanup model is not downloaded yet sentinel-echo at /Users/fixture/cleanup.txt"
        cleanup.chunks = 3
        let cleanupRecord = cleanup
        let normal = UsageRecord.dictationRows(
            runID: runID,
            engine: .parakeet,
            audioSeconds: 4.5,
            drained: 0.2,
            transcribedAt: 1.4,
            narrowedAt: 1.5,
            cleanedAt: 2.0,
            injectSeconds: 0.12,
            transcribed: true,
            cleanup: cleanupRecord,
            cleanupTimedOut: false
        )
        rows += normal
        guard normal.count == 2 else {
            problems.append("expected 2 rows (asr and cleanup), wrote \(normal.count)")
            return CaseOutcome(problems: problems, rows: rows)
        }
        guard let asr = normal.first(where: { $0.feature == UsageFeature.dictationASR.rawValue }),
              let cleanupRow = normal.first(where: { $0.feature == UsageFeature.dictationCleanup.rawValue })
        else {
            problems.append("the pair was not one dictation.asr and one dictation.cleanup row")
            return CaseOutcome(problems: problems, rows: rows)
        }
        if asr.dictationRunID != runID || cleanupRow.dictationRunID != runID {
            problems.append("the rows do not share the run's dictationRunID")
        }
        if asr.provider != UsageProvider.parakeet.rawValue {
            problems.append("asr provider was \(asr.provider), expected \(UsageProvider.parakeet.rawValue)")
        }
        if asr.modelID != SpeechEngineChoice.parakeet.rawValue {
            problems.append("asr modelID was \(asr.modelID), expected \(SpeechEngineChoice.parakeet.rawValue)")
        }
        if asr.audioSeconds != 4.5 {
            problems.append("asr audioSeconds was \(asr.audioSeconds.map { String($0) } ?? "nil"), expected 4.5")
        }
        if asr.finishReason != "stop" || asr.truncated == true {
            problems.append("a transcribed row said finishReason=\(asr.finishReason ?? "nil") "
                            + "truncated=\(asr.truncated.map { String($0) } ?? "nil")")
        }
        let expectedStages: [String: Double] = [
            "drain": 0.2,
            "transcribe": 1.2,
            "names": 0.1,
            "cleanup": 0.5,
            "inject": 0.12,
        ]
        for (key, expected) in expectedStages {
            guard let actual = asr.stages?[key] else {
                problems.append("the asr row has no stages[\(key)]")
                continue
            }
            if abs(actual - expected) > 0.001 {
                problems.append("stages[\(key)] was \(actual), expected \(expected)")
            }
        }
        if asr.stages?.count != expectedStages.count {
            problems.append("the asr row has \(asr.stages?.count ?? 0) stage(s), expected \(expectedStages.count)")
        }
        if cleanupRow.provider != UsageProvider.s1mini.rawValue {
            problems.append("cleanup provider was \(cleanupRow.provider), expected \(UsageProvider.s1mini.rawValue)")
        }
        if cleanupRow.modelID != "s1Mini" {
            problems.append("cleanup modelID was \(cleanupRow.modelID), expected s1Mini")
        }
        if cleanupRow.warm != false {
            problems.append("cleanup warm was \(cleanupRow.warm.map { String($0) } ?? "nil"), expected false")
        }
        if cleanupRow.counts?["chunks"] != 3 {
            problems.append("cleanup chunks was \(cleanupRow.counts?["chunks"].map { String($0) } ?? "nil"), expected 3")
        }
        if cleanupRow.fallbackReason != UsageFallback.modelUnavailable.rawValue {
            problems.append("cleanup fallbackReason was \(cleanupRow.fallbackReason ?? "nil"), "
                            + "expected \(UsageFallback.modelUnavailable.rawValue)")
        }
        if let reason = cleanupRow.fallbackReason, reason.contains("sentinel") {
            problems.append("the cleanup row kept the free-text fallback reason")
        }

        let timedOut = UsageRecord.dictationRows(
            runID: runID,
            engine: .apple,
            audioSeconds: 2.0,
            drained: 0.1,
            transcribedAt: 0.9,
            narrowedAt: 0.9,
            cleanedAt: 1.4,
            injectSeconds: 0.05,
            transcribed: false,
            cleanup: cleanupRecord,
            cleanupTimedOut: true
        )
        rows += timedOut
        if let timedASR = timedOut.first(where: { $0.feature == UsageFeature.dictationASR.rawValue }) {
            if timedASR.finishReason != "timeout" || timedASR.truncated != true {
                problems.append("a deadline ASR row said finishReason=\(timedASR.finishReason ?? "nil") "
                                + "truncated=\(timedASR.truncated.map { String($0) } ?? "nil")")
            }
        } else {
            problems.append("the deadline run wrote no dictation.asr row")
        }
        if let timedCleanup = timedOut.first(where: { $0.feature == UsageFeature.dictationCleanup.rawValue }) {
            if timedCleanup.finishReason != "timeout" {
                problems.append("a timed-out cleanup row said finishReason="
                                + "\(timedCleanup.finishReason ?? "nil"), expected timeout")
            }
        } else {
            problems.append("the timed-out run wrote no dictation.cleanup row")
        }
        return CaseOutcome(problems: problems, rows: rows)
    }

    // MARK: - E1–E4: the exit cases (P0-20e)

    /// One run of all three features into the harness's isolated store: a scripted typed
    /// turn with one tool through the real agent path, a scripted notes single pass, and
    /// the dictation builder. Each row must carry its own correlation id, and the summary
    /// must see exactly one row per feature.
    @MainActor
    private static func checkE1() async -> CaseOutcome {
        UsageLog.shared.clear()
        UsageLog.shared.flush()

        var problems: [String] = []

        // The typed leg is the real `handle` path. It needs the owner's Agent backend to
        // be the local model; with an external harness chosen, no local rows are written
        // and the honest answer is that the leg did not run.
        if Settings.shared.agentBackend != .local {
            problems.append("the Agent backend is set to an external harness, "
                            + "so the typed local path did not run")
        }
        let agent = RealtimeAgent.shared
        let provider = TypedTurnUsageProvider()
        let previousProvider = agent.localModelProviderForTesting
        agent.localModelProviderForTesting = provider
        defer { agent.localModelProviderForTesting = previousProvider }
        let request = "tell me which app is frontmost " + e1AgentSentinels
        let turn = await withBoundedWait(.seconds(30)) {
            await agent.handle(request, source: .text)
        }
        if turn == nil {
            problems.append("the typed turn did not finish within 30 s")
        }
        let turnID = agent.currentTurnID

        // The meeting leg is the real single-pass notes path.
        let meeting = fixtureMeeting("E1 sentinel briefing")
        do {
            _ = try await NotesGenerator(provider: ScriptedUsageProvider(contextTokens: 32_768)).notes(
                for: meeting,
                segments: e1Segments()
            )
        } catch {
            problems.append("the notes pass threw: \(error)")
        }

        // The dictation leg is P0-20c's pure builder.
        let runID = UUID()
        for row in UsageRecord.dictationRows(
            runID: runID,
            engine: .parakeet,
            audioSeconds: 4.5,
            drained: 0.2,
            transcribedAt: 1.4,
            narrowedAt: 1.5,
            cleanedAt: 1.5,
            injectSeconds: 0.12,
            transcribed: true,
            cleanup: nil,
            cleanupTimedOut: false
        ) {
            UsageLog.shared.record(row)
        }

        UsageLog.shared.flush()
        let all = UsageLog.shared.load()
        let agentRows = all.filter {
            $0.turnID == turnID && $0.feature == UsageFeature.agentTyped.rawValue
        }
        let meetingRows = all.filter {
            $0.meetingID == meeting.id && $0.feature == UsageFeature.meetingNotesSingle.rawValue
        }
        let dictationRows = all.filter {
            $0.dictationRunID == runID && $0.feature == UsageFeature.dictationASR.rawValue
        }

        if !agentRows.contains(where: { $0.pass == "answer" }) {
            problems.append("the typed turn wrote no answer row for its turnID")
        }
        let plannerRows = agentRows.filter { $0.pass == "planner" }
        if let toolRow = plannerRows.first(where: { ($0.toolsProposed ?? []).contains("computer.active_app") }) {
            if toolRow.provider != UsageProvider.llama.rawValue {
                problems.append("the planner row's provider was \(toolRow.provider), "
                                + "expected \(UsageProvider.llama.rawValue)")
            }
            if toolRow.modelID != provider.displayModelName {
                problems.append("the planner row's modelID was \(toolRow.modelID), "
                                + "expected \(provider.displayModelName)")
            }
            if toolRow.requestedRole != ModelRole.agent.rawValue {
                problems.append("the planner row's requestedRole was \(toolRow.requestedRole ?? "nil")")
            }
            if toolRow.toolsExecuted?.count != 1 || toolRow.toolsExecuted?.first?.ok != true {
                problems.append("the planner row did not carry one successful tool run")
            }
            if toolRow.totalMs <= 0 {
                problems.append("the planner row's totalMs was \(toolRow.totalMs), expected > 0")
            }
            if let ttft = toolRow.ttftMs, ttft > toolRow.totalMs {
                problems.append("the planner row's ttftMs \(ttft) is past its totalMs \(toolRow.totalMs)")
            }
        } else {
            problems.append("no planner row proposed computer.active_app")
        }
        if agentRows.contains(where: { $0.conversationID == nil }) {
            problems.append("a typed row carried no conversationID")
        }

        if meetingRows.count != 1 {
            problems.append("expected 1 meeting.notes.single row, wrote \(meetingRows.count)")
        }
        if dictationRows.count != 1 {
            problems.append("expected 1 dictation.asr row, wrote \(dictationRows.count)")
        }

        let e1Rows = agentRows + meetingRows + dictationRows
        let summary = UsageSummary.compute(rows: e1Rows, since: .distantPast)
        let features = summary.map(\.feature)
        for feature in [UsageFeature.agentTyped, .meetingNotesSingle, .dictationASR] {
            if features.filter({ $0 == feature.rawValue }).count != 1 {
                problems.append("the summary saw \(features.filter { $0 == feature.rawValue }.count) "
                                + "\(feature.rawValue) row(s), expected 1")
            }
        }
        if summary.count != 3 {
            problems.append("the summary produced \(summary.count) row(s), expected 3")
        }
        return CaseOutcome(problems: problems, rows: e1Rows)
    }

    /// E2: every row the feature legs wrote is scanned for the twelve sentinel strings
    /// planted in their prompts, transcripts and free-text reasons. An empty scan proves
    /// nothing, so no rows is a failure too.
    private static func checkE2(rows: [UsageRecord]) -> [String] {
        guard !rows.isEmpty else {
            return ["no rows to scan, so the privacy check proves nothing"]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var problems: [String] = []
        for row in rows {
            guard let data = try? encoder.encode(row),
                  let json = String(data: data, encoding: .utf8)?.lowercased() else {
                problems.append("a \(row.feature) row could not be encoded for the scan")
                continue
            }
            for sentinel in e2Sentinels where json.contains(sentinel) {
                problems.append("the \(row.feature) row leaked the sentinel \"\(sentinel)\"")
            }
        }
        return problems
    }

    /// E3: the owner's real `usage.jsonl` is byte-for-byte the same after the whole flag,
    /// and the store guard is registered to watch it. The harness writes its rows to a temp
    /// directory, so the real file must not even appear.
    private static func checkE3(before: SelfTestStoreGuard.StoreSnapshot) -> [String] {
        var problems: [String] = []
        let after = SelfTestStoreGuard.take()
        let beforeState = before.files["usage.jsonl"] ?? "absent"
        let afterState = after.files["usage.jsonl"] ?? "absent"
        if beforeState != afterState {
            problems.append("the real usage.jsonl changed during the run: \(beforeState) -> \(afterState)")
        }
        if !SelfTestStoreGuard.fileNames.contains(UsageLog.fileName) {
            problems.append("SelfTestStoreGuard.fileNames does not watch \(UsageLog.fileName)")
        }
        if UsageLog.shared.directory == AppIdentity.applicationSupportDirectory {
            problems.append("UsageLog.shared points at the owner's support directory under the harness")
        }
        return problems
    }

    /// E4: the `UsageRecord` coding keys are exactly the documented schema. A new field
    /// without a roadmap and AGENTS.md update fails here rather than shipping silently.
    private static func checkE4() -> [String] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(fullyPopulatedRow()),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["the fully populated row could not be encoded"]
        }
        var problems: [String] = []
        let actual = Set(object.keys)
        let documented = documentedUsageCodingKeys
        let missing = documented.subtracting(actual).sorted()
        let extra = actual.subtracting(documented).sorted()
        if !missing.isEmpty {
            problems.append("documented key(s) missing from UsageRecord: \(missing.joined(separator: ", "))")
        }
        if !extra.isEmpty {
            problems.append("UsageRecord has undocumented key(s): \(extra.joined(separator: ", "))")
        }
        if let runs = object["toolsExecuted"] as? [[String: Any]], let run = runs.first {
            let runKeys = Set(run.keys)
            let runMissing = documentedToolCodingKeys.subtracting(runKeys).sorted()
            let runExtra = runKeys.subtracting(documentedToolCodingKeys).sorted()
            if !runMissing.isEmpty {
                problems.append("UsageToolRun is missing key(s): \(runMissing.joined(separator: ", "))")
            }
            if !runExtra.isEmpty {
                problems.append("UsageToolRun has undocumented key(s): \(runExtra.joined(separator: ", "))")
            }
        } else {
            problems.append("the encoded row carried no toolsExecuted object to check")
        }
        return problems
    }

    // MARK: - E and D case helpers

    /// The twelve sentinels E2 plants: prompt words, a tool-argument-shaped value, e-mail
    /// addresses, URLs, file paths and a digit run in the typed request; transcript words
    /// and contact-shaped text in the meeting fixture; and a free-text cleanup fallback
    /// reason. None may appear in any encoded row.
    private static let e2Sentinels: [String] = [
        "sentinelalpha",
        "sentinelbravo",
        "sentinel-delta",
        "qzx@fixture.invalid",
        "https://fixture.invalid/private",
        "/users/fixture/secret-plan.txt",
        "12345678",
        "sentinelcharlie",
        "sentinel-foxtrot",
        "marc@acme.com",
        "/users/fixture/transcript.txt",
        "sentinel-echo",
    ]

    /// The sentinel tail of E1's typed request. It keeps the request on the tool route
    /// (`AgentTurnIntent.resolve` routes anything that is not an explicit on-device ask)
    /// and is what E2 scans the agent rows for.
    private static let e1AgentSentinels = "sentinelalpha sentinelbravo sentinel-delta "
        + "qzx@fixture.invalid https://fixture.invalid/private /Users/fixture/secret-plan.txt 12345678"

    /// The meeting fixture's sentinel segment.
    private static let e1TranscriptSentinels = "sentinelcharlie sentinel-foxtrot "
        + "marc@acme.com https://fixture.invalid/private /Users/fixture/transcript.txt"

    private static func e1Segments() -> [TranscriptSegment] {
        [
            TranscriptSegment(start: 0, end: 3, text: "Zarquon baffled the marmoset with a kazoo today.", source: .mic),
            TranscriptSegment(start: 4, end: 7, text: "Pernicious badgers excavated the turnip patch.", source: .system),
            TranscriptSegment(start: 8, end: 12, text: e1TranscriptSentinels, source: .mic),
        ]
    }

    /// The documented schema, in the order the P0-20 task lists it. The comparison is a set
    /// so a reordering is not a failure — the JSON key order is not a contract — but an
    /// added or removed field is.
    private static let documentedUsageCodingKeys: Set<String> = [
        "v", "id", "ts", "feature", "pass", "round", "provider", "modelID", "locality",
        "requestedRole", "requestedModel", "fallbackReason", "warm", "loadMs",
        "promptTokens", "cachedTokens", "completionTokens", "reasoningTokens",
        "countsEstimated", "ttftMs", "totalMs", "tokensPerSec", "finishReason",
        "truncated", "toolsProposed", "toolsExecuted", "errorClass", "errorMessage",
        "audioSeconds", "realtimeFactor", "stages", "counts",
        "turnID", "conversationID", "workID", "revision", "meetingID",
        "dictationRunID", "scheduleID",
    ]

    private static let documentedToolCodingKeys: Set<String> = ["id", "ok", "ms", "errorClass"]

    /// One row with every field non-nil, so the synthesized encoder writes every coding
    /// key. U1 round-trips it; E4 reads its keys.
    private static func fullyPopulatedRow() -> UsageRecord {
        UsageRecord(
            v: 1,
            id: UUID(),
            ts: Date(timeIntervalSince1970: 1_700_000_123),
            feature: UsageFeature.agentTyped.rawValue,
            pass: "answer",
            round: 2,
            provider: UsageProvider.llama.rawValue,
            modelID: "Scripted Test Model",
            locality: "local",
            requestedRole: ModelRole.agent.rawValue,
            requestedModel: "Installed CPM",
            fallbackReason: UsageFallback.loadFailed.rawValue,
            warm: false,
            loadMs: 1_234,
            promptTokens: 100,
            cachedTokens: 40,
            completionTokens: 55,
            reasoningTokens: 7,
            countsEstimated: false,
            ttftMs: 120,
            totalMs: 2_400,
            tokensPerSec: 22.5,
            finishReason: "stop",
            truncated: false,
            toolsProposed: ["calendar.list"],
            toolsExecuted: [UsageToolRun(id: "calendar.list", ok: true, ms: 12,
                                         errorClass: UsageErrorClass.other.rawValue)],
            errorClass: UsageErrorClass.other.rawValue,
            errorMessage: "Could not load the model",
            audioSeconds: 3.5,
            realtimeFactor: 0.25,
            stages: ["drain": 0.5, "transcribe": 1.25],
            counts: ["proposals": 2, "speakers": 2],
            turnID: UUID(),
            conversationID: UUID(),
            workID: UUID(),
            revision: 3,
            meetingID: UUID(),
            dictationRunID: UUID(),
            scheduleID: UUID()
        )
    }

    /// The scripted model behind E1's typed turn: the same three-step script
    /// `--selftest-toolloop-production` uses — opt into tools, propose one read, answer
    /// from its result — with a distinctive display name so the row proves which model ran.
    private struct TypedTurnUsageProvider: LLMProvider {
        let id = LLMProviderID.appLLM
        let displayModelName = "Scripted Typed Model"
        var contextTokens: Int { 4_096 }
        var unavailableReason: String? { get async { nil } }

        func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            let choosing = system.contains("<use_tools/>")
            let afterTool = user.contains("computer.active_app returned")
            let text: String
            if choosing {
                text = "<use_tools/>"
            } else if !afterTool {
                text = #"<tool_call>{"name":"computer.active_app","arguments":{},"rationale":"e1"}</tool_call>"#
            } else {
                text = "The frontmost application is the one the system reported."
            }
            return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
        }
    }

    private static func fixtureMeeting(_ title: String) -> Meeting {
        Meeting(
            title: title,
            titleSource: .user,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            status: .done
        )
    }

    private static let m1Texts = [
        "Zarquon baffled the marmoset with a kazoo today.",
        "Pernicious badgers excavated the turnip patch.",
        "Wombats negotiated a truce about the quagmire.",
    ]

    private static func m1Segments() -> [TranscriptSegment] {
        m1Texts.enumerated().map { index, text in
            TranscriptSegment(
                start: Double(index * 4),
                end: Double(index * 4 + 3),
                text: text,
                source: .mic
            )
        }
    }

    /// 40 segments of ~700 characters: far past the 4,096-token fixture window's 2,560-token
    /// transcript budget, and cut into three chunks by the generator's own character ratio.
    private static func m2Segments() -> [TranscriptSegment] {
        let filler = "zephyrquark blorptastic kerfuffle marmalade"
        let body = Array(repeating: filler, count: 16).joined(separator: " ")
        return (0..<40).map { index in
            TranscriptSegment(
                start: Double(index * 5),
                end: Double(index * 5 + 5),
                text: body,
                source: index.isMultiple(of: 2) ? .mic : .system
            )
        }
    }

    /// Every fixture word of five or more letters. None of them names a field, a value or
    /// a system message, so any occurrence in a row is transcript text that leaked.
    private static var fixtureTranscriptWords: [String] {
        let text = (m1Texts + [m2Segments().map(\.text).joined(separator: " ")]).joined(separator: " ")
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in word.count >= 5 && word.allSatisfy { $0.isLetter } }
            .map { $0.lowercased() }
        return Array(Set(words)).sorted()
    }

    private static func usageRows(meetingID: UUID, feature: UsageFeature) -> [UsageRecord] {
        UsageLog.shared.flush()
        return UsageLog.shared.load().filter {
            $0.meetingID == meetingID && $0.feature == feature.rawValue
        }
    }

    /// The scripted model behind M1–M3. It never touches a real runtime; `countTokens` is
    /// the same characters / 4 + 1 estimate the notes-context self-test uses, and `complete`
    /// waits 2 ms so a pass's `totalMs` cannot round to zero.
    private final class ScriptedUsageProvider: LLMProvider, @unchecked Sendable {
        let id: LLMProviderID = .appLLM
        let contextTokens: Int
        let displayModelName = "Scripted Usage Model"

        init(contextTokens: Int) {
            self.contextTokens = contextTokens
        }

        var unavailableReason: String? { get async { nil } }

        func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            try await Task.sleep(for: .milliseconds(2))
            if system == NotesPrompts.mapSystem {
                return LLMCompletion(
                    text: "- The zephyrquark export is approved.",
                    generatedTokens: 8,
                    duration: 0.002
                )
            }
            return LLMCompletion(
                text: "## Summary\nThe team settled the revised figures.",
                generatedTokens: 40,
                duration: 0.002
            )
        }
    }

    // MARK: - Helpers

    private static func labelled(_ name: String, _ problems: [String]) -> [String] {
        problems.map { "\(name): \($0)" }
    }

    /// A representative row. Every field is passed explicitly so nothing depends on
    /// memberwise-init defaults.
    private static func usageRow(id: UUID, ts: Date, padding: Int = 0) -> UsageRecord {
        UsageRecord(
            v: 1,
            id: id,
            ts: ts,
            feature: UsageFeature.agentTyped.rawValue,
            pass: "answer",
            round: nil,
            provider: UsageProvider.llama.rawValue,
            modelID: "Scripted Test Model",
            locality: "local",
            requestedRole: nil,
            requestedModel: nil,
            fallbackReason: nil,
            warm: nil,
            loadMs: nil,
            promptTokens: nil,
            cachedTokens: nil,
            completionTokens: nil,
            reasoningTokens: nil,
            countsEstimated: nil,
            ttftMs: nil,
            totalMs: 1,
            tokensPerSec: nil,
            finishReason: nil,
            truncated: nil,
            toolsProposed: nil,
            toolsExecuted: nil,
            errorClass: nil,
            errorMessage: padding > 0 ? String(repeating: "x", count: padding) : nil,
            audioSeconds: nil,
            realtimeFactor: nil,
            stages: nil,
            counts: nil,
            turnID: nil,
            conversationID: nil,
            workID: nil,
            revision: nil,
            meetingID: nil,
            dictationRunID: nil,
            scheduleID: nil
        )
    }

    /// The `usage*` file names in a directory, sorted.
    private static func usageFiles(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("usage") }.sorted()
    }

    @discardableResult
    private static func write(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private static func writeJSONL(_ rows: [UsageRecord], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines: [String] = []
        for row in rows {
            guard let data = try? encoder.encode(row),
                  let line = String(data: data, encoding: .utf8) else { return false }
            lines.append(line)
        }
        return write(lines.joined(separator: "\n") + "\n", to: url)
    }
}
