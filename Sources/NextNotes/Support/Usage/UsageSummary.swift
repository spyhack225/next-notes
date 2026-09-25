import Foundation

/// The pure aggregation behind `--usage-report` and Settings ▸ Models' usage section
/// (P0-20d): one row per (feature, model) over the rows the caller passes.
enum UsageSummary {
    /// One (feature, model) group.
    ///
    /// Percentiles are nearest-rank — the `ceil(p × count)`-th smallest value — over the
    /// non-nil values. A column with fewer than `minimumSamples` values is nil, and the
    /// report prints `-` for it.
    struct Row: Sendable, Equatable {
        /// `UsageFeature.rawValue`.
        var feature: String
        /// The model or engine that actually ran.
        var modelID: String
        var n: Int
        /// First visible token, milliseconds.
        var ttftP50: Int?
        var ttftP90: Int?
        var totalP50: Int
        var totalP90: Int
        /// Cold passes only (`warm == false`).
        var loadP50: Int?
        var promptP50: Int?
        var completionP50: Int?
        var tpsP50: Double?
        /// Rows with `errorClass` ÷ n.
        var errorRate: Double
        /// Rows with `truncated == true` ÷ n.
        var cutoffRate: Double
        /// Rows with a `fallbackReason` ÷ n.
        var fallbackRate: Double
        /// Σ `toolsExecuted.ok` ÷ Σ `toolsExecuted`, nil when no tool ran.
        var toolOKRate: Double?
        /// Speech rows only.
        var rtfP50: Double?
    }

    /// Below this many values a column has nothing worth printing.
    static let minimumSamples = 3

    /// One row per (feature, `modelID`) among `rows` whose `ts` is at or after `since`,
    /// sorted by feature then model. Percentiles use nearest-rank on the non-nil values,
    /// and a column with fewer than `minimumSamples` values is nil.
    static func compute(rows: [UsageRecord], since: Date) -> [Row] {
        var grouped: [String: [UsageRecord]] = [:]
        for row in rows where row.ts >= since {
            grouped[groupKey(row.feature, row.modelID), default: []].append(row)
        }
        return grouped.values
            .compactMap(summarise)
            .sorted {
                $0.feature == $1.feature ? $0.modelID < $1.modelID : $0.feature < $1.feature
            }
    }

    // MARK: - Aggregation

    /// A separator no feature or model name can contain, so two pairs can never collide.
    private static func groupKey(_ feature: String, _ model: String) -> String {
        feature + "\u{1F}" + model
    }

    private static func summarise(_ rows: [UsageRecord]) -> Row? {
        guard let first = rows.first else { return nil }
        let firstWords = rows.compactMap(\.ttftMs)
        let totals = rows.map(\.totalMs)
        return Row(
            feature: first.feature,
            modelID: first.modelID,
            n: rows.count,
            ttftP50: percentile(firstWords, 0.5),
            ttftP90: percentile(firstWords, 0.9),
            totalP50: percentile(totals, 0.5, atLeast: 1) ?? 0,
            totalP90: percentile(totals, 0.9, atLeast: 1) ?? 0,
            loadP50: percentile(rows.filter { $0.warm == false }.compactMap(\.loadMs), 0.5),
            promptP50: percentile(rows.compactMap(\.promptTokens), 0.5),
            completionP50: percentile(rows.compactMap(\.completionTokens), 0.5),
            tpsP50: percentile(rows.compactMap(\.tokensPerSec), 0.5),
            errorRate: rate(rows) { $0.errorClass != nil },
            cutoffRate: rate(rows) { $0.truncated == true },
            fallbackRate: rate(rows) { $0.fallbackReason != nil },
            toolOKRate: toolOKRate(rows),
            rtfP50: percentile(rows.compactMap(\.realtimeFactor), 0.5)
        )
    }

    /// Nearest-rank: the `ceil(p × count)`-th smallest value, or nil when the column has
    /// fewer than `atLeast` values. Totals pass `atLeast: 1` because the column's type
    /// demands a number for a group that exists.
    private static func percentile<T: Comparable>(
        _ values: [T], _ p: Double, atLeast: Int = minimumSamples
    ) -> T? {
        guard values.count >= atLeast else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    private static func rate(_ rows: [UsageRecord], _ matches: (UsageRecord) -> Bool) -> Double {
        guard !rows.isEmpty else { return 0 }
        return Double(rows.filter(matches).count) / Double(rows.count)
    }

    /// Σ `toolsExecuted.ok` ÷ Σ `toolsExecuted` over the group's rows; nil when no tool ran.
    private static func toolOKRate(_ rows: [UsageRecord]) -> Double? {
        let runs = rows.flatMap { $0.toolsExecuted ?? [] }
        guard !runs.isEmpty else { return nil }
        return Double(runs.filter(\.ok).count) / Double(runs.count)
    }
}

// MARK: - The red-first cases

/// P0-20d's red-first cases (R1–R3), riding `--selftest-usage-log` so that flag keeps one
/// marker. `problems()` returns `<case>: <reason>` strings and prints no verdict of its
/// own: `NextNotesApp` writes them as `USAGE_LOG_WRONG` lines, and `UsageLogSelfTest`'s
/// `USAGE_LOG_OK` / `USAGE_LOG_FAILED` stays the last word.
///
/// - **R1** the aggregation: twelve fixture rows over two (feature, model) pairs yield
///   two summary rows with exact n, nearest-rank p50/p90, error rate 1/6, tool ok rate
///   3/4, no column for a value with fewer than three samples, and `since` filtering.
/// - **R2** the report format: the same fixture yields two `USAGE_REPORT_ROW` lines in
///   the documented key order then `USAGE_REPORT_OK rows=12 files=1 since=…`; an empty
///   fixture yields `USAGE_REPORT_EMPTY`.
/// - **R3** plain words: the Settings section's visible strings are non-empty and say
///   none of the developer words, raw feature ids or schema keys.
enum UsageSummarySelfTest {
    /// The problems, already labelled; empty when every case passes.
    static func problems() -> [String] {
        var problems: [String] = []
        problems += labelled("R1", checkR1())
        problems += labelled("R2", checkR2())
        problems += labelled("R3", checkR3())
        return problems
    }

    // MARK: - R1 the aggregation

    private static func checkR1() -> [String] {
        let rows = fixtureRows()
        let summary = UsageSummary.compute(rows: rows, since: fixtureBase)
        guard summary.count == 2 else {
            return ["expected 2 summary row(s), got \(summary.count)"]
        }
        guard let alpha = summary.first(where: { $0.feature == UsageFeature.agentTyped.rawValue
            && $0.modelID == "Alpha" }) else {
            return ["no summary row for agent.typed / Alpha"]
        }
        guard let beta = summary.first(where: { $0.feature == UsageFeature.dictationASR.rawValue
            && $0.modelID == "Beta" }) else {
            return ["no summary row for dictation.asr / Beta"]
        }
        var problems: [String] = []
        if alpha.n != 6 { problems.append("agent.typed n=\(alpha.n), expected 6") }
        if alpha.ttftP50 != 300 { problems.append("agent.typed first-word p50=\(describe(alpha.ttftP50)), expected 300") }
        if alpha.ttftP90 != 600 { problems.append("agent.typed first-word p90=\(describe(alpha.ttftP90)), expected 600") }
        if alpha.totalP50 != 3_000 { problems.append("agent.typed total p50=\(alpha.totalP50), expected 3000") }
        if alpha.totalP90 != 6_000 { problems.append("agent.typed total p90=\(alpha.totalP90), expected 6000") }
        if alpha.loadP50 != nil {
            problems.append("agent.typed load p50=\(describe(alpha.loadP50)) — two cold values is under three, expected no column")
        }
        if alpha.promptP50 != 30 { problems.append("agent.typed prompt p50=\(describe(alpha.promptP50)), expected 30") }
        if alpha.completionP50 != 300 { problems.append("agent.typed completion p50=\(describe(alpha.completionP50)), expected 300") }
        if alpha.tpsP50 != 3.0 { problems.append("agent.typed tokens/sec p50=\(describe(alpha.tpsP50)), expected 3.0") }
        if alpha.errorRate != 1.0 / 6.0 { problems.append("agent.typed error rate=\(alpha.errorRate), expected 1/6") }
        if alpha.cutoffRate != 1.0 / 6.0 { problems.append("agent.typed cut-off rate=\(alpha.cutoffRate), expected 1/6") }
        if alpha.fallbackRate != 0 { problems.append("agent.typed fallback rate=\(alpha.fallbackRate), expected 0") }
        if alpha.toolOKRate != 0.75 { problems.append("agent.typed tool ok rate=\(describe(alpha.toolOKRate)), expected 0.75") }
        if alpha.rtfP50 != nil { problems.append("agent.typed has a speech factor") }
        if beta.n != 6 { problems.append("dictation.asr n=\(beta.n), expected 6") }
        if beta.ttftP50 != nil { problems.append("dictation.asr first-word p50=\(describe(beta.ttftP50)) — two values is under three, expected no column") }
        if beta.rtfP50 != 1.5 { problems.append("dictation.asr speech factor p50=\(describe(beta.rtfP50)), expected 1.5") }
        if beta.errorRate != 0 { problems.append("dictation.asr error rate=\(beta.errorRate), expected 0") }
        if beta.toolOKRate != nil { problems.append("dictation.asr tool ok rate=\(describe(beta.toolOKRate)), expected no column") }

        let later = UsageSummary.compute(rows: rows, since: fixtureBase.addingTimeInterval(9 * 3_600 + 1))
        if later.count != 1 || later.first?.feature != UsageFeature.dictationASR.rawValue {
            problems.append("since did not drop the earlier pair: \(later.count) row(s)")
        }
        return problems
    }

    // MARK: - R2 the report format

    private static func checkR2() -> [String] {
        let rows = fixtureRows()
        var problems: [String] = []
        let report = UsageReport.lines(for: rows, files: 1, since: fixtureBase)
        if report.count == 3,
           let first = report.first,
           let second = report.dropFirst().first,
           let last = report.last,
           first.hasPrefix("USAGE_REPORT_ROW "),
           second.hasPrefix("USAGE_REPORT_ROW "),
           last.hasPrefix("USAGE_REPORT_OK rows=12 files=1 since=") {
            if !first.contains("feature=\(UsageFeature.agentTyped.rawValue)")
                || !first.contains("model=Alpha") || !first.contains("n=6") {
                problems.append("the first line is not agent.typed / Alpha / n=6: \(first)")
            }
            if !second.contains("feature=\(UsageFeature.dictationASR.rawValue)")
                || !second.contains("model=Beta") || !second.contains("n=6") {
                problems.append("the second line is not dictation.asr / Beta / n=6: \(second)")
            }
            problems += keyOrderProblems(in: first)
            problems += keyOrderProblems(in: second)
            if !first.contains("load_p50=-") {
                problems.append("two cold values did not print as load_p50=-: \(first)")
            }
            if !second.contains("ttft_p50=-") || !second.contains("ttft_p90=-") {
                problems.append("two first-word values did not print as ttft_p50=- / ttft_p90=-: \(second)")
            }
        } else {
            problems.append("the 12-row fixture produced \(report.count) line(s), "
                + "expected two USAGE_REPORT_ROW lines then USAGE_REPORT_OK")
        }
        let empty = UsageReport.lines(for: [], files: 0, since: fixtureBase)
        if empty != ["USAGE_REPORT_EMPTY"] {
            problems.append("the empty fixture produced \(empty.count) line(s), expected USAGE_REPORT_EMPTY")
        }
        return problems
    }

    /// The documented column order. Each key must appear after the one before it, so a
    /// reordered or missing column fails; values may contain spaces.
    private static let reportKeys = [
        "feature", "model", "n", "ttft_p50", "ttft_p90", "total_p50", "total_p90",
        "load_p50", "prompt_p50", "completion_p50", "tps_p50", "error_rate",
        "cutoff_rate", "fallback_rate", "tool_ok_rate", "rtf_p50",
    ]

    private static func keyOrderProblems(in line: String) -> [String] {
        var cursor = line.startIndex
        for key in reportKeys {
            guard let range = line.range(of: "\(key)=", range: cursor..<line.endIndex) else {
                return ["the \(key)= column is missing or out of order in: \(line)"]
            }
            cursor = range.upperBound
        }
        return []
    }

    // MARK: - R3 plain words

    private static func checkR3() -> [String] {
        let summary = [
            UsageSummary.Row(
                feature: UsageFeature.agentTyped.rawValue,
                modelID: "Alpha",
                n: 6,
                ttftP50: 300, ttftP90: 600,
                totalP50: 3_000, totalP90: 6_000,
                loadP50: nil,
                promptP50: 30, completionP50: 300, tpsP50: 3.0,
                errorRate: 1.0 / 6.0, cutoffRate: 0, fallbackRate: 0,
                toolOKRate: 0.75, rtfP50: nil
            ),
            UsageSummary.Row(
                feature: UsageFeature.dictationASR.rawValue,
                modelID: "Beta",
                n: 6,
                ttftP50: nil, ttftP90: nil,
                totalP50: 6_000, totalP90: 12_000,
                loadP50: nil,
                promptP50: nil, completionP50: nil, tpsP50: nil,
                errorRate: 0, cutoffRate: 0, fallbackRate: 0,
                toolOKRate: nil, rtfP50: 1.5
            ),
        ]
        let strings = UsageSection.visibleStrings(for: summary)
        let emptyStrings = UsageSection.visibleStrings(for: [])
        var problems: [String] = []
        if strings.isEmpty {
            problems.append("the section has no strings to read for a history that is not empty")
        }
        if emptyStrings.isEmpty {
            problems.append("the section has no empty-state sentence")
        }
        for text in strings + emptyStrings {
            let lowered = text.lowercased()
            for word in bannedWords where lowered.contains(word) {
                problems.append("a visible string says \u{201c}\(word)\u{201d}: \(text)")
            }
            for row in summary where text.contains(row.feature) {
                problems.append("a visible string shows the raw feature id \(row.feature): \(text)")
            }
            for key in schemaKeys where text.contains(key) {
                problems.append("a visible string shows the field name \(key): \(text)")
            }
        }
        return problems
    }

    /// The developer words a person must never read (P0-20d target behaviour and the
    /// `--selftest-ui-strings` rules).
    private static let bannedWords = [
        "token", "provider", "ttft", "p90", "latency", "model pass",
        "usage", "jsonl", "schema", "prompt", "completion",
        "fallback", "truncat", "realtimefactor", "realtime factor",
        "errorclass", "error class",
    ]

    /// Raw row field names, which are never user-visible copy either.
    private static let schemaKeys = [
        "promptTokens", "completionTokens", "tokensPerSec", "ttftMs", "totalMs",
        "loadMs", "realtimeFactor", "errorClass", "fallbackReason", "toolsExecuted",
        "modelID", "locality",
    ]

    // MARK: - The fixture

    private static let fixtureBase = Date(timeIntervalSince1970: 1_780_000_000)

    /// Twelve rows over two (feature, model) pairs.
    ///
    /// `agent.typed / Alpha`: first words 100…600 (p50 300, p90 600), totals 1000…6000
    /// (p50 3000, p90 6000), two cold passes only (the load column has two values),
    /// one row with an error class and `truncated`, four tool runs of which three
    /// succeeded.
    ///
    /// `dictation.asr / Beta`: totals 2000…12000 (p50 6000, p90 12000), two first-word
    /// values only, speech factors 0.5…3.0 (p50 1.5).
    private static func fixtureRows() -> [UsageRecord] {
        var rows: [UsageRecord] = (0..<6).map { (index: Int) -> UsageRecord in
            usageRow(
                ts: fixtureBase.addingTimeInterval(Double(index) * 3_600),
                feature: UsageFeature.agentTyped.rawValue,
                pass: "answer",
                provider: UsageProvider.llama.rawValue,
                modelID: "Alpha",
                warm: index < 2 ? false : true,
                loadMs: index < 2 ? 5_000 + index * 1_000 : nil,
                promptTokens: 10 * (index + 1),
                completionTokens: 100 * (index + 1),
                ttftMs: 100 * (index + 1),
                totalMs: 1_000 * (index + 1),
                tokensPerSec: Double(index + 1),
                truncated: index == 5,
                toolsExecuted: toolRuns(at: index),
                errorClass: index == 5 ? UsageErrorClass.timeout.rawValue : nil
            )
        }
        rows += (0..<6).map { (index: Int) -> UsageRecord in
            usageRow(
                ts: fixtureBase.addingTimeInterval(Double(10 + index) * 3_600),
                feature: UsageFeature.dictationASR.rawValue,
                pass: "engine",
                provider: UsageProvider.parakeet.rawValue,
                modelID: "Beta",
                warm: true,
                loadMs: nil,
                promptTokens: nil,
                completionTokens: nil,
                ttftMs: index < 2 ? 50 + index * 10 : nil,
                totalMs: 2_000 * (index + 1),
                tokensPerSec: nil,
                truncated: false,
                toolsExecuted: nil,
                errorClass: nil,
                audioSeconds: Double(10 * (index + 1)),
                realtimeFactor: 0.5 * Double(index + 1)
            )
        }
        return rows
    }

    /// Four tool runs over the first three `agent.typed` rows, three of which succeeded.
    private static func toolRuns(at index: Int) -> [UsageToolRun]? {
        switch index {
        case 0:
            return [
                UsageToolRun(id: "calendar.list", ok: true, ms: 10, errorClass: nil),
                UsageToolRun(id: "calendar.list", ok: true, ms: 11, errorClass: nil),
            ]
        case 1:
            return [UsageToolRun(id: "calendar.list", ok: true, ms: 12, errorClass: nil)]
        case 2:
            return [UsageToolRun(id: "calendar.list", ok: false, ms: 13,
                                 errorClass: UsageErrorClass.other.rawValue)]
        default:
            return nil
        }
    }

    private static func usageRow(
        ts: Date,
        feature: String,
        pass: String,
        provider: String,
        modelID: String,
        warm: Bool?,
        loadMs: Int?,
        promptTokens: Int?,
        completionTokens: Int?,
        ttftMs: Int?,
        totalMs: Int,
        tokensPerSec: Double?,
        truncated: Bool?,
        toolsExecuted: [UsageToolRun]?,
        errorClass: String?,
        audioSeconds: Double? = nil,
        realtimeFactor: Double? = nil
    ) -> UsageRecord {
        UsageRecord(
            v: 1,
            id: UUID(),
            ts: ts,
            feature: feature,
            pass: pass,
            round: nil,
            provider: provider,
            modelID: modelID,
            locality: "local",
            requestedRole: nil,
            requestedModel: nil,
            fallbackReason: nil,
            warm: warm,
            loadMs: loadMs,
            promptTokens: promptTokens,
            cachedTokens: nil,
            completionTokens: completionTokens,
            reasoningTokens: nil,
            countsEstimated: nil,
            ttftMs: ttftMs,
            totalMs: totalMs,
            tokensPerSec: tokensPerSec,
            finishReason: errorClass == nil ? "stop" : "timeout",
            truncated: truncated,
            toolsProposed: nil,
            toolsExecuted: toolsExecuted,
            errorClass: errorClass,
            errorMessage: nil,
            audioSeconds: audioSeconds,
            realtimeFactor: realtimeFactor,
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

    // MARK: - Helpers

    private static func labelled(_ name: String, _ problems: [String]) -> [String] {
        problems.map { "\(name): \($0)" }
    }

    private static func describe<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "none"
    }
}
