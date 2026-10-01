import Foundation

/// IM-17f — `--imessage-report`: what this Mac's remote-access half looks like,
/// in counts, states and durations and nothing else.
///
/// A diagnostic, never a `--selftest-*` flag: it reads the real outbound
/// ledger database, the real `chat.db` and the real `usage.jsonl`, and under
/// the harness all three are swapped away — the trap `--notes-context-live`
/// documents. The formatter is separated from the reader precisely so the
/// no-identifiers rule pins without a grant: the reader may hold a guid (to
/// scope the report), the formatter may never print one.
///
/// Every line comes from a real store — a report line is never the only place
/// a fact exists. States this process cannot observe (no live watcher, bridge
/// or ledger host yet — IM-16) read as `unhosted`, never as a guess.
enum IMessageReport {
    /// How far back usage rows are read, unless `--imessage-days N` says otherwise.
    static let defaultDays = 7

    /// Everything the formatter may print. `pairedChatGUID` travels here so the
    /// reader can scope by it — and the formatter's contract is that it never
    /// appears in the output, which the report self-test holds with a hostile
    /// fixture.
    struct Input: Sendable {
        var databaseReadable: Bool
        var pairedChatGUID: String?
        var watermarkRowID: Int64
        /// Aggregated event counters, already restricted to the closed
        /// vocabulary: unknown keys never reach this type.
        var counts: [IMessageCount: Int]
        var discardedTotal: Int
        var discardedPerRowMax: Int
        var syncToAgentSeconds: [Double]
        var dispatchToVerifySeconds: [Double]
        var policyVersion: Int
        var agentRoleKind: String
        var canarySeen: Int
        var canaryUnreadable: Int
        var scopedRows: Int?
        var days: Int
    }

    /// One line per fact, shapes only. The paired chat prints as presence
    /// (`paired chat`), never as a guid; numbers print as numbers; nothing else
    /// prints at all.
    static func format(_ input: Input) -> [String] {
        var lines: [String] = [
            "IMESSAGE_REPORT_PAIRED: \(input.pairedChatGUID == nil ? "no" : "paired chat")",
            "IMESSAGE_REPORT_DB: \(input.databaseReadable ? "readable" : "unreadable")",
            "IMESSAGE_REPORT_WATCHER: unhosted",
            "IMESSAGE_REPORT_BRIDGE: unhosted",
            "IMESSAGE_REPORT_WATERMARK: \(input.watermarkRowID)",
            "IMESSAGE_REPORT_POLICY: \(input.policyVersion)",
            "IMESSAGE_REPORT_MODEL: \(input.agentRoleKind)",
            "IMESSAGE_REPORT_CANARY: seen \(input.canarySeen), unreadable \(input.canaryUnreadable)",
        ]
        for key in input.counts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            lines.append("IMESSAGE_REPORT_COUNT_\(key.rawValue): \(input.counts[key] ?? 0)")
        }
        lines.append("IMESSAGE_REPORT_DISCARDED: total \(input.discardedTotal), per-row max \(input.discardedPerRowMax)")
        if let sync = percentile(input.syncToAgentSeconds, 0.5) {
            lines.append("IMESSAGE_REPORT_SYNC_P50: \(renderSeconds(sync))")
        }
        if let sync = percentile(input.syncToAgentSeconds, 0.9) {
            lines.append("IMESSAGE_REPORT_SYNC_P90: \(renderSeconds(sync))")
        }
        if let dispatch = percentile(input.dispatchToVerifySeconds, 0.9) {
            lines.append("IMESSAGE_REPORT_DISPATCH_P90: \(renderSeconds(dispatch))")
        }
        lines.append("IMESSAGE_REPORT_BREAKER: unhosted")
        if let scoped = input.scopedRows {
            lines.append("IMESSAGE_REPORT_SCOPED: \(scoped) row(s) in window")
        }
        return lines
    }

    /// Nearest-rank percentile over durations. Nil when there is nothing to
    /// summarise — an absent line, never a zero pretending to be measured.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let rank = max(1, Int((fraction * Double(ordered.count)).rounded(.up)))
        return ordered[min(ordered.count - 1, rank - 1)]
    }

    static func renderSeconds(_ value: Double) -> String {
        String(format: "%.2fs", value)
    }

    /// Marker: `IMESSAGE_REPORT_OK` when there is anything to say,
    /// `IMESSAGE_REPORT_EMPTY` when paired to nothing with no rows — never OK
    /// because it found nothing.
    static func marker(paired: Bool, rowCount: Int, lineCount: Int) -> String {
        (paired || rowCount > 0)
            ? "IMESSAGE_REPORT_OK: \(lineCount) lines"
            : "IMESSAGE_REPORT_EMPTY"
    }
}

/// Reads the real stores into an `Input`. Diagnostic-only: it opens the live
/// database and the owner's usage history, which is exactly what the harness
/// swaps away — so this never runs under a `--selftest-*` flag.
enum IMessageReportReader {
    /// Reads everything the formatter prints. Counts, states and durations
    /// only: a guid accepted for scoping is validated, counted over, and never
    /// printed back.
    static func read(days: Int, chatGUID: String?) async -> (lines: [String], marker: String) {
        let config = RemoteIdentityStore(directory: AppIdentity.applicationSupportDirectory).configuration
        let readable = await MessagesDatabaseHealth.probeNow().isReadable
        let since = Date().addingTimeInterval(-Double(max(1, days)) * 86400)
        let rows = UsageLog.shared.load(since: since).filter {
            $0.feature == UsageFeature.imessageEvent.rawValue
                || $0.feature == UsageFeature.agentIMessage.rawValue
        }
        var counts: [IMessageCount: Int] = [:]
        var discarded: [Int] = []
        var sync: [Double] = []
        var dispatch: [Double] = []
        for row in rows {
            for (key, value) in row.counts ?? [:] {
                // Unknown keys cannot occur — the only writer builds from the
                // same vocabulary — and if one ever does it is dropped here
                // rather than printed.
                guard let count = IMessageCount(rawValue: key) else { continue }
                counts[count, default: 0] += value
                if count == .discardedAttributes { discarded.append(value) }
            }
            if let stages = row.stages {
                if let value = stages[IMessageStage.syncToAgent.rawValue] { sync.append(value) }
                if let value = stages[IMessageStage.dispatchToVerify.rawValue] { dispatch.append(value) }
            }
        }
        var scoped: Int? = nil
        var scopedMissing = false
        if let guid = chatGUID, !guid.isEmpty {
            scopedMissing = true
            if let database = try? MessagesDatabase(),
               let latest = try? await database.latestRowID(),
               let chat = try? await database.chat(guid: guid) {
                _ = chat
                let floor = max(0, latest - 1000)
                if let contents = try? await database.messages(after: floor, chatGUID: guid, limit: 1000) {
                    scoped = contents.count
                    scopedMissing = false
                }
                await database.close()
            }
        }
        let input = IMessageReport.Input(
            databaseReadable: readable,
            pairedChatGUID: config.pairedChatGUID,
            watermarkRowID: config.lastProcessedRowID,
            counts: counts,
            discardedTotal: discarded.reduce(0, +),
            discardedPerRowMax: discarded.max() ?? 0,
            syncToAgentSeconds: sync,
            dispatchToVerifySeconds: dispatch,
            policyVersion: config.remotePolicyVersion,
            agentRoleKind: await Self.roleKind(),
            canarySeen: config.canarySeen,
            canaryUnreadable: config.canaryUnreadable,
            scopedRows: scoped,
            days: days)
        var lines = IMessageReport.format(input)
        if scopedMissing {
            lines.append("IMESSAGE_REPORT_SCOPED: no such conversation")
        }
        let marker = IMessageReport.marker(
            paired: config.pairedChatGUID != nil, rowCount: rows.count, lineCount: lines.count)
        lines.append(marker)
        return (lines, marker)
    }

    /// The agent role's kind word — builtin/apple/installed/server/cloud/app —
    /// never an id. Model file ids are paths; endpoints name machines.
    static func roleKind() async -> String {
        await MainActor.run {
            switch ModelRoleStore.shared.choice(for: .agent) {
            case .builtIn: "builtin"
            case .appleFoundation: "apple"
            case .installedModel: "installed"
            case .localServer: "server"
            case .cloud: "cloud"
            case .app: "app"
            }
        }
    }
}
