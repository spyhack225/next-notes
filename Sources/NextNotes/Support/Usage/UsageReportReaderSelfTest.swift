import Foundation

/// Actual report reader on a disposable corpus. No App/delegate/shared owner is built.
enum UsageReportReaderSelfTest {
    static let flag = "--selftest-usage-report-reader"

    static func runStandalone(arguments: [String]) -> Int32 {
        guard arguments == [flag] else {
            print("USAGE_READER_INVALID: conflicting diagnostic or modifier")
            return 1
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("NextNotesUsageReportTest-\(UUID().uuidString)", isDirectory: true)
        var count = 0; var failures: [String] = []
        func check(_ okay: Bool, _ label: String) {
            count += 1
            if !okay { failures.append(label); print("USAGE_READER_WRONG: \(label)") }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let now = Date(timeIntervalSince1970: 1_893_456_000) // 2030-01-01
            let turn = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
            let task = "B0000000-0000-0000-0000-000000000001"
            let old = UsageRecord(id: UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!, ts: Date(timeIntervalSince1970: 1_577_836_800),
                feature: "agent.worker", pass: "answer", provider: "rules", modelID: "reader-fixture",
                locality: "local", promptTokens: 10, completionTokens: 5, totalMs: 10,
                turnID: turn, taskID: task)
            var current = old
            current.id = UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!; current.ts = Date(timeIntervalSince1970: 1_609_459_200)
            current.promptTokens = 20; current.completionTokens = nil
            var unbound = current
            unbound.id = UUID(uuidString: "C0000000-0000-0000-0000-000000000003")!; unbound.feature = "knowledge.ask"; unbound.turnID = nil
            unbound.taskID = "PRIVATE_INVALID_TASK_SENTINEL"
            var future = old; future.v = UsageLog.schemaVersion + 1
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            func encoded<T: Encodable>(_ row: T) throws -> Data {
                var data = try encoder.encode(row); data.append(0x0A); return data
            }
            let rotated = root.appendingPathComponent(UsageLog.rotatedName)
            let active = root.appendingPathComponent(UsageLog.fileName)
            let auditURL = root.appendingPathComponent("agent-audit.jsonl")
            var rotatedBytes = try encoded(old)
            rotatedBytes.append(Data("{invalid-line}\n".utf8)); rotatedBytes.append(try encoded(future))
            var activeBytes = try encoded(current); activeBytes.append(try encoded(unbound))
            let audit = AgentAuditEntry(id: "D0000000-0000-0000-0000-000000000001", at: old.ts, kind: .request, title: "Synthetic reader request", turnID: turn)
            let auditBytes = try encoded(audit)
            try rotatedBytes.write(to: rotated); try activeBytes.write(to: active); try auditBytes.write(to: auditURL)
            func metadata(_ url: URL) throws -> [String] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return [.systemFileNumber, .size, .modificationDate].map { String(describing: attributes[$0]) }
            }
            let originalRotatedMetadata = try metadata(rotated)
            let originalActiveMetadata = try metadata(active)
            let originalAuditMetadata = try metadata(auditURL)
            let args = [UsageReport.flag, UsageReport.daysFlag, "36500"]
            let output = root.appendingPathComponent("cli-output.log")
            let cliStatus = UsageReport.runStandalone(arguments: args + [UsageReport.rootFlag, root.path,
                                                                         SelfTest.outputFlag, output.path])
            let all = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
            check(cliStatus == 0 && !all.isEmpty, "C15 actual early CLI and output consumer completed")
            check(try Data(contentsOf: rotated) == rotatedBytes && metadata(rotated) == originalRotatedMetadata,
                  "F01 diagnostic rewrote rotated source bytes or identity/metadata")
            check(all.last?.hasPrefix("USAGE_REPORT_OK rows=3 files=2 ") == true,
                  "F02 long-window actual report lost retained old rows")
            let tasks = UsageReport.read(arguments: args + [UsageReport.featureFlag, "task."], directory: root, now: now)
            check(tasks.contains { $0.hasPrefix("USAGE_TASK_ROW task=\(task) passes=2 prompt_tokens=30 completion_tokens=- total_tokens=- cost=- ") },
                  "F03 actual task report lost historical sum or unknown counts")
            let joined = UsageReport.read(arguments: [UsageReport.flag, UsageReport.turnFlag, turn.uuidString], directory: root, now: now)
            check(joined.last?.hasSuffix("audit=1 passes=2") == true,
                  "F04 actual turn report lost old usage pass")
            let missing = root.appendingPathComponent("absent", isDirectory: true)
            let empty = UsageReport.read(arguments: args, directory: missing, now: now)
            check(!FileManager.default.fileExists(atPath: missing.path),
                  "F05 diagnostic created missing source directory")
            check(empty == ["USAGE_REPORT_EMPTY"], "C01 missing source is empty")
            check(all.contains { $0.hasPrefix("USAGE_REPORT_ROW feature=knowledge.ask model=reader-fixture n=1 ") },
                  "C02 existing feature/model report identity preserved")
            check(try Data(contentsOf: active) == activeBytes && metadata(active) == originalActiveMetadata,
                  "C03 current source bytes and metadata retained")
            check(try Data(contentsOf: auditURL) == auditBytes && metadata(auditURL) == originalAuditMetadata,
                  "C04 same audit source bytes and metadata retained")
            check(!tasks.joined().contains("PRIVATE_INVALID_TASK_SENTINEL")
                && tasks.filter { $0.hasPrefix("USAGE_TASK_ROW ") }.count == 1,
                  "C05 malformed attribution remains unbound")
            check(UsageReport.read(arguments: [UsageReport.flag, "--usage-days=0"], directory: root, now: now) == ["USAGE_REPORT_EMPTY"],
                  "C06 invalid days retain default fallback")
            check(UsageReport.read(arguments: args + ["--usage-feature=knowledge."], directory: root, now: now).last?.hasPrefix("USAGE_REPORT_OK rows=1 ") == true,
                  "C07 equals-form feature filter preserved")
            check(UsageReport.read(arguments: [UsageReport.flag, UsageReport.daysFlag, UsageReport.featureFlag, "agent."], directory: root, now: now) == ["USAGE_REPORT_EMPTY"],
                  "C08 missing days retains default fallback")
            check(UsageReport.read(arguments: [UsageReport.flag, UsageReport.turnFlag, "not-a-uuid"], directory: root, now: now) == ["USAGE_TURN_BAD_ID: not-a-uuid is not a uuid"],
                  "C09 existing malformed turn verdict preserved")
            let retained = try Data(contentsOf: rotated)
            check(UsageReport.read(arguments: args + ["--jobs-report"], directory: root, now: now) == ["USAGE_REPORT_FAILED: conflicting or unknown modifier"],
                  "C10 mixed diagnostic refused")
            check(try Data(contentsOf: rotated) == retained, "C11 refused arguments never touch source")
            let unsafe = root.deletingLastPathComponent().appendingPathComponent("unowned-usage-source-\(UUID().uuidString)")
            check(UsageReport.read(arguments: args, directory: unsafe, now: now) == ["USAGE_REPORT_FAILED: isolated source refused"]
                && !FileManager.default.fileExists(atPath: unsafe.path), "C12 arbitrary injected source refused without creation")
            check(joined.filter { $0.hasPrefix("USAGE_TURN_AUDIT ") }.count == 1,
                  "C13 actual existing audit turn consumer used")
            let rotatedRetained = try Data(contentsOf: rotated) == rotatedBytes
            let missingRetained = !FileManager.default.fileExists(atPath: missing.path)
            let total = all.last?.split(separator: " ").first { $0.hasPrefix("rows=") }.map(String.init) ?? "rows=unknown"
            try FileManager.default.removeItem(at: root)
            check(!FileManager.default.fileExists(atPath: root.path), "C14 owned corpus cleanup complete")
            print("USAGE_READER_TRACE checks=\(count) \(total) rotatedRetained=\(rotatedRetained) missingRetained=\(missingRetained)")
        } catch {
            print("USAGE_READER_INVALID: corpus setup or measurement failed")
            return 1
        }
        print(failures.isEmpty ? "USAGE_READER_OK: \(count) checks" : "USAGE_READER_FAILED: \(failures.count)/\(count)")
        return failures.isEmpty ? 0 : 1
    }
}
