import Foundation

/// `--usage-report`: one line per (feature, model) over this Mac's own `usage.jsonl`.
///
/// Runs before App/delegate construction. The report selects the same stored rows,
/// uses the existing formatter, and honours explicit temporary diagnostic output.
/// No writer, model, meeting or voice owner is needed to produce this projection.
enum UsageReport {
    static let daysFlag = "--usage-days"
    static let featureFlag = "--usage-feature"
    /// P1-29: print one turn across both logs by id — the audit row that asked, and the
    /// model passes that answered. A row that carries a `turnID` and nothing else to
    /// connect it to is an id nobody can use, and this is what makes it usable.
    static let turnFlag = "--usage-turn"
    static let defaultDays = 30

    /// One turn, from `agent-audit.jsonl` and `usage.jsonl` at once.
    ///
    /// The finding this answers was that the audit could not say which model answered a given
    /// request: the pieces existed — the audit row, the usage rows, both with an id on the
    /// usage side — and did not join. They join on `turnID` now, and this is the reader.
    ///
    /// Read-only and outside the harness like every other report here, because both stores are
    /// isolated under `SelfTest.isRunning` and a report over empty temp stores would print a
    /// confident "no such turn" for a turn that happened. The audit side reads
    /// `AgentAuditLog.loadForReport()` rather than `.entries`, which under the harness starts
    /// empty by design.
    static func turnLines(
        turnID: UUID,
        usage: [UsageRecord],
        audit: [AgentAuditEntry]
    ) -> [String] {
        let passes = usage.filter { $0.turnID == turnID }
            .sorted { $0.ts < $1.ts }
        let rows = audit.filter { $0.turnID == turnID }.sorted { $0.at < $1.at }
        guard !passes.isEmpty || !rows.isEmpty else {
            return ["USAGE_TURN_ABSENT: \(turnID.uuidString)"]
        }
        var lines: [String] = []
        for row in rows {
            lines.append("USAGE_TURN_AUDIT \(row.at.ISO8601Format()) [\(row.kind.rawValue)] "
                + "\(row.title) tool=\(row.toolID ?? "-")")
        }
        for pass in passes {
            // The outcome is the two fields the row actually carries — a finish reason or an
            // error class — rather than a single invented "outcome" column, so a line printed
            // here is the same line a pass wrote.
            let outcome = pass.errorClass.map { "error=\($0)" }
                ?? pass.finishReason.map { "finish=\($0)" } ?? "ok"
            lines.append("USAGE_TURN_PASS \(pass.ts.ISO8601Format()) "
                + "feature=\(pass.feature) model=\(pass.modelID) "
                + "locality=\(pass.locality) \(outcome) "
                + "in=\(pass.promptTokens ?? 0) out=\(pass.completionTokens ?? 0) "
                + "ttft=\(pass.ttftMs ?? 0)ms total=\(pass.totalMs)ms")
        }
        let conversation = rows.first?.conversationID ?? passes.first?.conversationID
        lines.append("USAGE_TURN_OK turn=\(turnID.uuidString) "
            + "conversation=\(conversation?.uuidString ?? "-") "
            + "audit=\(rows.count) passes=\(passes.count)")
        return lines
    }

    /// The report for `rows`, in the documented key order: one `USAGE_REPORT_ROW` per
    /// (feature, model), sorted by feature then how often it ran, then
    /// `USAGE_REPORT_OK rows=<total> files=<k> since=<date>`. No rows at all is
    /// `USAGE_REPORT_EMPTY`, which is not a failure.
    static func lines(for rows: [UsageRecord], files: Int, since: Date, feature: String? = nil) -> [String] {
        let considered = rows.filter { row in
            row.ts >= since && (feature.map { matches(row, feature: $0) } ?? true)
        }
        guard !considered.isEmpty else { return ["USAGE_REPORT_EMPTY"] }
        let summary = UsageSummary.compute(rows: considered, since: since).sorted { lhs, rhs in
            if lhs.feature != rhs.feature { return lhs.feature < rhs.feature }
            if lhs.n != rhs.n { return lhs.n > rhs.n }
            return lhs.modelID < rhs.modelID
        }
        var lines = summary.map { rowLine($0) }
        if feature == "task." {
            // Same reader and rows; sums are a retained projection, not a stored balance.
            for id in Set(considered.compactMap(\.taskID)).sorted() {
                let task = UsageSummary.task(rows: considered, taskID: id)
                lines.append("USAGE_TASK_ROW task=\(id) passes=\(task.passes) "
                    + "prompt_tokens=\(intText(task.promptTokens)) "
                    + "completion_tokens=\(intText(task.completionTokens)) "
                    + "total_tokens=\(intText(task.totalTokens)) cost=- coverage=retained")
            }
        }
        lines.append("USAGE_REPORT_OK rows=\(considered.count) files=\(files) "
            + "since=\(dateText(since))")
        return lines
    }

    static let flag = "--usage-report"
    /// Explicit public test corpus; never a fallback for an invalid owner invocation.
    static let rootFlag = "--usage-root"

    /// Read on the existing diagnostic utility lane. No foreground model path uses this.
    static func run(arguments: [String], directory: URL? = nil, now: Date = Date()) async -> [String] {
        await Task.detached(priority: .utility) {
            read(arguments: arguments, directory: directory, now: now)
        }.value
    }

    /// The actual report producer, also called by the early standalone CLI.
    static func read(arguments: [String], directory: URL? = nil, now: Date = Date()) -> [String] {
        let arguments = arguments.first?.hasPrefix("--") == false ? Array(arguments.dropFirst()) : arguments
        guard validArguments(arguments) else { return ["USAGE_REPORT_FAILED: conflicting or unknown modifier"] }
        let selected: URL
        if let root = directory ?? value(after: rootFlag, in: arguments).map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            guard isolatedRoot(root) else { return ["USAGE_REPORT_FAILED: isolated source refused"] }
            selected = root.standardizedFileURL
        } else {
            guard !SelfTest.isRunning else { return ["USAGE_REPORT_FAILED: owner history unavailable under harness"] }
            selected = AppIdentity.applicationSupportDirectoryURL
        }
        if let raw = turnValue(in: arguments), UUID(uuidString: raw) == nil {
            return ["USAGE_TURN_BAD_ID: \(raw) is not a uuid"]
        }
        do {
            if let raw = turnValue(in: arguments), let turnID = UUID(uuidString: raw) {
                return try turnLines(turnID: turnID, usage: UsageLog.loadForReport(directory: selected),
                                     audit: AgentAuditLog.loadForReport(directory: selected))
            }
            let since = now.addingTimeInterval(-Double(daysValue(in: arguments)) * 86_400)
            return try lines(for: UsageLog.loadForReport(directory: selected, since: since),
                             files: fileCount(in: selected), since: since, feature: featureValue(in: arguments))
        } catch { return ["USAGE_REPORT_FAILED: existing usage history could not be read; source retained"] }
    }

    /// Runs before SwiftUI/delegate owner construction. Output stays available to
    /// LaunchServices through the existing explicit temporary diagnostic output option.
    static func runStandalone(arguments: [String]) -> Int32 {
        let output = value(after: SelfTest.outputFlag, in: arguments)
        if let output {
            let candidate = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
            let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            guard candidate.path.hasPrefix(temp + "/"),
                  !candidate.pathComponents.contains("Application Support") else {
                print("USAGE_REPORT_FAILED: output must be a temporary diagnostic file")
                return 1
            }
        }
        let rows = read(arguments: arguments)
        for row in rows { print(row) }
        if let output {
            do { try (rows.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8) }
            catch { print("USAGE_REPORT_FAILED: temporary diagnostic output could not be saved"); return 1 }
        }
        return rows.last?.hasPrefix("USAGE_REPORT_FAILED") == true
            || rows.last?.hasPrefix("USAGE_TURN_BAD_ID") == true ? 1 : 0
    }

    private static func validArguments(_ arguments: [String]) -> Bool {
        let allowed: Set<String> = [flag, daysFlag, featureFlag, turnFlag, rootFlag, SelfTest.outputFlag, SelfTest.timeoutFlag]
        guard arguments.filter({ $0 == flag }).count == 1 else { return false }
        var seen = Set<String>(); var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard allowed.contains(key), seen.insert(key).inserted else { return false }
            if key == flag { guard parts.count == 1 else { return false } }
            else if parts.count == 1 {
                // Existing days/feature/turn missing values keep their original fallback.
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") { index += 1 }
                else if [rootFlag, SelfTest.outputFlag, SelfTest.timeoutFlag].contains(key) { return false }
            }
            if key == rootFlag, value(after: key, in: arguments)?.isEmpty != false { return false }
            if key == SelfTest.timeoutFlag {
                guard let raw = value(after: key, in: arguments), let seconds = Double(raw),
                      seconds.isFinite, seconds > 0 else { return false }
            }
            index += 1
        }
        return true
    }

    /// Only the explicitly named fresh system-temp corpus namespace is injectable.
    /// No symlink alias, owner support directory, or arbitrary path is accepted.
    private static func isolatedRoot(_ root: URL) -> Bool {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let standard = root.standardizedFileURL
        guard standard.path == standard.resolvingSymlinksInPath().path,
              standard.path.hasPrefix(temp + "/") else { return false }
        let first = String(standard.path.dropFirst(temp.count + 1)).split(separator: "/").first.map(String.init) ?? ""
        let prefix = "NextNotesUsageReportTest-"
        return first.hasPrefix(prefix) && UUID(uuidString: String(first.dropFirst(prefix.count))) != nil
    }

    /// `task.` is a projection filter, not a second feature namespace/log. Keep actual
    /// feature/model provenance so existing report columns and historical readers agree.
    static func matches(_ row: UsageRecord, feature: String) -> Bool {
        feature == "task." ? UsageLog.sanitiseTaskID(row.taskID) != nil : row.feature.hasPrefix(feature)
    }

    /// `--usage-turn <uuid>`. A value that is absent, empty or begins with `--` is nil —
    /// `SelfTest.value(after:)`'s rule, so `--usage-turn --usage-days 3` cannot read the
    /// next flag as a turn id and report a turn that does not exist.
    static func turnValue(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: turnFlag),
              arguments.index(after: index) < arguments.endIndex else { return nil }
        let value = arguments[arguments.index(after: index)]
        guard !value.hasPrefix("--") else { return nil }
        return value
    }

    // MARK: - Formatting

    /// The documented column order. A column with fewer than `minimumSamples` values has
    /// no number and prints `-`.
    private static func rowLine(_ row: UsageSummary.Row) -> String {
        [
            "USAGE_REPORT_ROW",
            "feature=\(row.feature)",
            "model=\(row.modelID)",
            "n=\(row.n)",
            "ttft_p50=\(intText(row.ttftP50))",
            "ttft_p90=\(intText(row.ttftP90))",
            "total_p50=\(row.totalP50)",
            "total_p90=\(row.totalP90)",
            "load_p50=\(intText(row.loadP50))",
            "prompt_p50=\(intText(row.promptP50))",
            "completion_p50=\(intText(row.completionP50))",
            "tps_p50=\(numberText(row.tpsP50, decimals: 1))",
            "error_rate=\(numberText(row.errorRate, decimals: 3))",
            "cutoff_rate=\(numberText(row.cutoffRate, decimals: 3))",
            "fallback_rate=\(numberText(row.fallbackRate, decimals: 3))",
            "tool_ok_rate=\(numberText(row.toolOKRate, decimals: 3))",
            "rtf_p50=\(numberText(row.rtfP50, decimals: 2))",
        ].joined(separator: " ")
    }

    private static func intText(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    private static func numberText(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "-" }
        return String(format: "%.\(decimals)f", value)
    }

    private static func dateText(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Arguments

    private static func daysValue(in arguments: [String]) -> Int {
        guard let raw = value(after: daysFlag, in: arguments),
              let days = Int(raw), days > 0 else { return defaultDays }
        return days
    }

    private static func featureValue(in arguments: [String]) -> String? {
        guard let raw = value(after: featureFlag, in: arguments) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The argument following `flag`, or the tail of `--flag=value`. A flag is never a
    /// value: `--usage-days --usage-feature agent.` reads no number and keeps the default.
    private static func value(after flag: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count {
                let next = arguments[index + 1]
                return next.hasPrefix("--") ? nil : next
            }
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    /// How many of the two usage files on disk hold rows: what `files=<k>` counts.
    private static func fileCount(in directory: URL) -> Int {
        [UsageLog.fileName, UsageLog.rotatedName].reduce(into: 0) { count, name in
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber, size.intValue > 0 else { return }
            count += 1
        }
    }
}
