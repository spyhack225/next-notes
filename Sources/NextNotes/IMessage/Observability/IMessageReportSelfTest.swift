import Foundation

/// `--selftest-imessage-observe` — IM-17e: the canary over decode outcomes.
///
/// No grant, no pairing, no model: the canary is a pure value over counts and
/// a clock, and the copy is linted, not shown. The final line is
/// `IMESSAGE_OBSERVE_OK: <n> cases`; per-case lines are
/// `IMESSAGE_OBSERVE_WRONG: …`, which is not a verdict token.
///
/// (This file is `IMessageReportSelfTest.swift` because IM-17f's formatter test
/// joins it here: one observability file, two suites.)
enum IMessageObserveSelfTest {
    static func run() -> String {
        var failures: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () -> String?) {
            caseCount += 1
            if let problem = body() { failures.append("\(name): \(problem)") }
        }

        func noted(_ outcomes: [IMessageCanary.RowOutcome]) -> IMessageCanary {
            var canary = IMessageCanary()
            for outcome in outcomes { canary.note(outcome) }
            return canary
        }

        // Ordinary rows never count: photos, tapbacks, SMS bodies, our own
        // bounds and parsed-but-wordless streams move `seen` and nothing else.
        check("ordinary_rows_never_count") {
            let canary = noted([
                .nonText, .nonText,
                .unreadable(.truncated(offset: 4)),
                .unreadable(.tooLarge(bytes: 1 << 20)),
                .unreadable(.notAString(offset: 9)),
                .readable,
            ])
            guard canary.seen == 6 else {
                return "six rows moved seen to \(canary.seen)"
            }
            return canary.unreadable == 0 ? nil : "ordinary rows counted \(canary.unreadable)"
        }

        // The three format cases do.
        check("format_cases_count") {
            let canary = noted([
                .unreadable(.unsupportedStreamVersion(found: 4, system: nil)),
                .unreadable(.notATypedStream(offset: 0)),
                .unreadable(.structureUnreadable(offset: 12)),
            ])
            guard canary.unreadable == 3 else {
                return "three format failures counted \(canary.unreadable)"
            }
            return nil
        }

        // Nine unreadable never fires, whatever the denominator.
        check("nine_never_fires") {
            var canary = IMessageCanary()
            canary.seen = 50
            canary.unreadable = 9
            guard !canary.isBroken else { return "9 of 50 reads broken" }
            return canary.shouldNotify(now: Date()) ? "9 of 50 notifies" : nil
        }

        // Ten of fifty fires; ten of two hundred is a rate, not a break.
        check("ten_of_fifty_fires") {
            var canary = IMessageCanary()
            canary.seen = 50
            canary.unreadable = 10
            guard canary.isBroken else { return "10 of 50 does not read broken" }
            return canary.shouldNotify(now: Date()) ? nil : "10 of 50 does not notify"
        }
        check("ten_of_two_hundred_does_not") {
            var canary = IMessageCanary()
            canary.seen = 200
            canary.unreadable = 10
            guard !canary.isBroken else { return "10 of 200 reads broken" }
            return nil
        }

        // One notification per window: silence inside the cooldown, voice after.
        check("cooldown_holds_then_releases") {
            var canary = IMessageCanary()
            canary.seen = 50
            canary.unreadable = 10
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            canary.markNotified(at: start)
            guard !canary.shouldNotify(now: start.addingTimeInterval(3600)) else {
                return "a second notification inside the cooldown"
            }
            guard canary.shouldNotify(now: start.addingTimeInterval(25 * 3600)) else {
                return "no notification after the cooldown"
            }
            return nil
        }

        // Every canary sentence passes the consumer-naming lint and names no
        // agent: "Next" appears only inside "Next Notes", never alone.
        check("copy_is_plain_words") {
            let lines = [IMessageCanaryCopy.notificationTitle,
                         IMessageCanaryCopy.notificationBody,
                         IMessageCanaryCopy.settingsRow,
                         IMessageCanaryCopy.settingsNote]
            for line in lines {
                guard UIStringsLint.forbiddenTokens(in: line).isEmpty else {
                    return "a canary sentence trips the lint: \(line)"
                }
                guard line.range(of: "You are ") == nil else {
                    return "a canary sentence names the agent: \(line)"
                }
                var rest = line[...]
                while let found = rest.range(of: "Next") {
                    let after = rest[found.upperBound...]
                    guard after.hasPrefix(" Notes") else {
                        return "a canary sentence spells the agent's name: \(line)"
                    }
                    rest = after
                }
            }
            return nil
        }

        // The formatter shares this flag: its wrong-lines merge below, under the
        // one marker, so a run never prints two verdicts for one flag.
        let format = IMessageReportFormatSelfTest.runChecks()
        caseCount += format.count
        failures += format.wrong.map { "format: \($0)" }

        var lines = failures.map { "IMESSAGE_OBSERVE_WRONG: \($0)" }
        lines.append(failures.isEmpty
            ? "IMESSAGE_OBSERVE_OK: \(caseCount) cases"
            : "IMESSAGE_OBSERVE_FAILED: \(failures[0])")
        return lines.joined(separator: "\n")
    }
}

/// IM-17f — the formatter test: a hostile fixture through `IMessageReport.format`,
/// asserting none of it appears in the output.
///
/// The fixture carries a real-shaped chat guid, a promo URL and a message body —
/// the three things a report must never print. The guid rides the input because
/// scoping needs it; the URL and the body have no input field at all, which is
/// the enforcement. What is asserted is the output: presence without identity
/// (`paired chat`, never the guid), counts as numbers, and nothing else.
enum IMessageReportFormatSelfTest {
    /// Wrong-lines plus the count, for the observe flag to merge under its one
    /// marker. No verdict of its own: one flag, one marker.
    static func runChecks() -> (wrong: [String], count: Int) {
        var failures: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () -> String?) {
            caseCount += 1
            if let problem = body() { failures.append("\(name): \(problem)") }
        }

        func hostileInput() -> IMessageReport.Input {
            IMessageReport.Input(
                databaseReadable: true,
                pairedChatGUID: "iMessage;-;+15550000001",
                watermarkRowID: 99,
                counts: [.detected: 3, .sent: 1],
                discardedTotal: 5,
                discardedPerRowMax: 5,
                syncToAgentSeconds: [1.0, 3.0],
                dispatchToVerifySeconds: [12.0],
                policyVersion: 1,
                agentRoleKind: "apple",
                canarySeen: 50,
                canaryUnreadable: 0,
                scopedRows: 4,
                days: 7)
        }

        // A guid in, no guid out — but the pairing presence survives. Phone-like
        // digit runs and URLs are absent too: the only free-text-adjacent input
        // is the role kind, and the reader builds it from a fixed mapping.
        check("guid_in_presence_out") {
            let lines = IMessageReport.format(hostileInput())
            for line in lines {
                if line.contains("iMessage;-;") {
                    return "a guid reached the output: \(line)"
                }
                if line.range(of: "\\+\\d{7,}", options: .regularExpression) != nil {
                    return "a phone-like digit run reached the output: \(line)"
                }
                if line.contains("http") {
                    return "a URL reached the output: \(line)"
                }
                if !line.hasPrefix("IMESSAGE_REPORT_") {
                    return "a line escaped the report vocabulary: \(line)"
                }
            }
            guard lines.contains(where: { $0.contains("paired chat") }) else {
                return "the pairing presence is missing"
            }
            return nil
        }

        // Counts print as numbers under stable names; percentiles print.
        check("numbers_print_stably") {
            let lines = IMessageReport.format(hostileInput())
            for want in ["IMESSAGE_REPORT_COUNT_detected: 3",
                         "IMESSAGE_REPORT_DISCARDED: total 5, per-row max 5",
                         "IMESSAGE_REPORT_SYNC_P50: 1.00s",
                         "IMESSAGE_REPORT_SYNC_P90: 3.00s",
                         "IMESSAGE_REPORT_DISPATCH_P90: 12.00s",
                         "IMESSAGE_REPORT_SCOPED: 4 row(s) in window"] {
                guard lines.contains(want) else {
                    return "missing line: \(want)"
                }
            }
            return nil
        }

        // Empty percentiles are absent lines, never zeros pretending to measure.
        check("absent_percentiles_are_absent") {
            var input = hostileInput()
            input.syncToAgentSeconds = []
            input.dispatchToVerifySeconds = []
            let lines = IMessageReport.format(input)
            for line in lines where line.contains("SYNC_P") || line.contains("DISPATCH_P") {
                return "an unmeasured percentile printed: \(line)"
            }
            return nil
        }

        // The marker: OK with anything to say, EMPTY for paired-to-nothing with
        // no rows — never OK because it found nothing.
        check("marker_honesty") {
            guard IMessageReport.marker(paired: false, rowCount: 0, lineCount: 3) == "IMESSAGE_REPORT_EMPTY" else {
                return "an empty report reads OK"
            }
            guard IMessageReport.marker(paired: true, rowCount: 0, lineCount: 3).hasPrefix("IMESSAGE_REPORT_OK") else {
                return "a paired report does not read OK"
            }
            return nil
        }

        var lines = failures.map { "IMESSAGE_OBSERVE_WRONG: \($0)" }
        lines.append(failures.isEmpty
            ? "IMESSAGE_OBSERVE_OK: \(caseCount) cases"
            : "IMESSAGE_OBSERVE_FAILED: \(failures[0])")
        return (wrong: failures, count: caseCount)
    }
}
