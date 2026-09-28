import Foundation

/// `--usage-report`: one line per (feature, model) over this Mac's own `usage.jsonl`.
///
/// A diagnostic in the `--notes-context-live` shape, **not** a `--selftest-*` flag: under
/// the harness `UsageLog.shared` is an empty temp store, so the report has to run before
/// `runRequestedSelfTest` with `SelfTest.isRunning` still false. `NextNotesApp` mirrors
/// every line through `writeSelfTest`, which honours `--selftest-out`, so a
/// LaunchServices launch with no stdout still leaves its rows in a file.
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
    static func lines(for rows: [UsageRecord], files: Int, since: Date) -> [String] {
        let considered = rows.filter { $0.ts >= since }
        guard !considered.isEmpty else { return ["USAGE_REPORT_EMPTY"] }
        let summary = UsageSummary.compute(rows: considered, since: since).sorted { lhs, rhs in
            if lhs.feature != rhs.feature { return lhs.feature < rhs.feature }
            if lhs.n != rhs.n { return lhs.n > rhs.n }
            return lhs.modelID < rhs.modelID
        }
        var lines = summary.map { rowLine($0) }
        lines.append("USAGE_REPORT_OK rows=\(considered.count) files=\(files) "
            + "since=\(dateText(since))")
        return lines
    }

    /// Reads the real `UsageLog.shared` off the main actor, applies `--usage-days N`
    /// (default `defaultDays`) and `--usage-feature <prefix>` (default all), and formats
    /// the report. A `--usage-days` value that is not a positive number falls back to the
    /// default rather than reading nothing.
    static func run(arguments: [String]) async -> [String] {
        if let raw = turnValue(in: arguments), let turnID = UUID(uuidString: raw) {
            return await turnReport(turnID: turnID)
        }
        if let raw = turnValue(in: arguments) {
            return ["USAGE_TURN_BAD_ID: \(raw) is not a uuid"]
        }
        let days = daysValue(in: arguments)
        let feature = featureValue(in: arguments)
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let (rows, files) = await Task.detached(priority: .utility) { () -> ([UsageRecord], Int) in
            let log = UsageLog.shared
            var rows = log.load(since: since)
            if let feature { rows = rows.filter { $0.feature.hasPrefix(feature) } }
            return (rows, fileCount(in: log.directory))
        }.value
        return lines(for: rows, files: files, since: since)
    }

    /// The whole history for one turn, from both files. The audit side is read with its own
    /// store rather than the in-memory list, because this runs outside the harness and the
    /// list holds at most `AgentAuditLog.memoryRows` of whatever this launch has seen.
    private static func turnReport(turnID: UUID) async -> [String] {
        let (usage, audit) = await Task.detached(priority: .utility) { () -> ([UsageRecord], [AgentAuditEntry]) in
            (UsageLog.shared.load(since: nil), AgentAuditLog.loadForReport())
        }.value
        return turnLines(turnID: turnID, usage: usage, audit: audit)
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
