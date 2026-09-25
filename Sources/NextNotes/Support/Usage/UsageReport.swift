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
    static let defaultDays = 30

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
