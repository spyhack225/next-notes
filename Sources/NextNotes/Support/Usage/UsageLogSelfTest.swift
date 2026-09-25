import Foundation

/// `--selftest-usage-log` (P0-20a): the usage log's writer, reader, rotation, age
/// compaction, clear, sanitiser and harness isolation.
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
enum UsageLogSelfTest {
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
        }

        for failure in failures { print("USAGE_LOG_WRONG: \(failure)") }
        guard failures.isEmpty else {
            print("USAGE_LOG_FAILED: \(failures.count) problem(s)")
            return false
        }
        print("USAGE_LOG_OK: 7 cases")
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
