import Foundation

/// `--selftest-usage-log`: the usage log's writer, reader, rotation, age compaction,
/// clear, sanitiser and harness isolation (P0-20a, U1–U7), plus the meeting passes
/// (P0-20b, M1–M5).
///
/// Final marker: `USAGE_LOG_OK: <n> cases` / `USAGE_LOG_FAILED: <n> problem(s)`, with one
/// `USAGE_LOG_WRONG: <case>: <reason>` line per failure. P0-20e extends this file; the
/// marker name never changes.
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
enum UsageLogSelfTest {
    /// How many cases a green run reports: U1–U7 and M1–M5.
    private static let caseCount = 12

    static func run() -> Bool {
        var failures: [String] = []
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
            failures += checkMeetings()
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
        let row = UsageRecord(
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
            toolsExecuted: [UsageToolRun(id: "calendar.list", ok: true, ms: 12, errorClass: nil)],
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
    private static func checkMeetings() -> [String] {
        UsageLog.shared.clear()
        UsageLog.shared.flush()

        var failures: [String] = []
        var rows: [UsageRecord] = []

        if let outcome = awaitCase({ await checkM1() }) {
            failures += labelled("M1", outcome.problems)
            rows += outcome.rows
        } else {
            failures.append("M1: the case did not finish within 30 s")
        }
        if let outcome = awaitCase({ await checkM2() }) {
            failures += labelled("M2", outcome.problems)
            rows += outcome.rows
        } else {
            failures.append("M2: the case did not finish within 30 s")
        }
        if let outcome = awaitCase({ await checkM3() }) {
            failures += labelled("M3", outcome.problems)
            rows += outcome.rows
        } else {
            failures.append("M3: the case did not finish within 30 s")
        }
        if let outcome = awaitCase({ await checkM4() }) {
            failures += labelled("M4", outcome.problems)
            rows += outcome.rows
        } else {
            failures.append("M4: the case did not finish within 30 s")
        }
        failures += labelled("M5", checkM5(rows: rows))
        return failures
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

    /// M5: every row M1–M4 produced is scanned for the fixture transcript words. A run
    /// that wrote no rows fails too: an empty scan proves nothing.
    private static func checkM5(rows: [UsageRecord]) -> [String] {
        guard !rows.isEmpty else {
            return ["M1–M4 produced no rows, so there is nothing to scan for transcript text"]
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

    /// Bridges one async case onto a detached task. `run()` is called synchronously
    /// (`SelfTest.failed = !UsageLogSelfTest.run()` carries no `await`), so this is the
    /// only way an async production path can be exercised from it. The cases must not need
    /// the main actor — the runner's own thread is blocked here for the case's duration —
    /// and `MeetingAgent` is handed its tool list precisely so it never reaches the
    /// main-actor tool gate.
    private static func awaitCase(
        _ work: @escaping @Sendable () async -> CaseOutcome
    ) -> CaseOutcome? {
        let box = AsyncCaseBox()
        Task.detached(priority: .userInitiated) {
            box.store(await work())
        }
        guard box.gate.wait(timeout: .now() + .seconds(30)) == .success else { return nil }
        return box.value
    }

    private final class AsyncCaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CaseOutcome?
        let gate = DispatchSemaphore(value: 0)

        func store(_ value: CaseOutcome) {
            lock.withLock { stored = value }
            gate.signal()
        }

        var value: CaseOutcome? { lock.withLock { stored } }
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
