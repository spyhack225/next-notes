import Foundation
import SQLite3

/// Reads Wispr Flow's own result for an utterance out of its local database.
///
/// Wispr is a closed commercial app, so there's no API to ask. But it records every
/// dictation to `~/Library/Application Support/Wispr Flow/flow.sqlite` — including the raw
/// ASR text, the text after its own cleanup pass, and its end-to-end latency. That's the
/// same split this app has (engine vs `TextFormatter`), which is what makes a real
/// side-by-side possible instead of eyeballing two windows.
///
/// Strictly read-only. Wispr owns this file; we never write to it.
enum WisprReader {
    /// Wispr's cleanup runs in the cloud, so its row lands a beat after the key is released
    /// — later than either local engine finishes. Hence polling rather than a single read.
    private static let pollInterval: Duration = .milliseconds(300)

    /// How far *before* the hold began to look for Wispr's row. See `result(after:timeout:)`.
    private static let startStampGrace: TimeInterval = 5

    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wispr Flow/flow.sqlite")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    /// Waits for the first Wispr row recorded after `holdStarted`.
    ///
    /// - Returns: nil if Wispr wasn't triggered for this utterance, isn't installed, or
    ///   didn't finish in time. A missing row is the normal case when only this app's
    ///   hotkey was held, so it's not an error.
    static func result(after holdStarted: Date, timeout: TimeInterval) async -> ComparisonResult? {
        guard isInstalled else { return nil }

        // Wispr stamps a row with the START of the utterance, not the end — and the two
        // hotkeys are never pressed on the same millisecond, so its row is routinely stamped
        // slightly *before* our hold began. Searching forward from the hold start therefore
        // skipped the matching row every time.
        //
        // The window is bounded on both sides rather than just widened backwards: Wispr
        // creates the row (with null text) when the utterance starts and fills the text in
        // afterwards, so an open-ended search would happily return the *previous*
        // dictation's row on the first poll and report it as this one's result.
        let lower = utcStamp(holdStarted.addingTimeInterval(-Self.startStampGrace))
        let upper = utcStamp(holdStarted.addingTimeInterval(Self.startStampGrace))
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let row = fetchRow(between: lower, and: upper) { return row }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    private static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func fetchRow(between lower: String, and upper: String) -> ComparisonResult? {
        var db: OpaquePointer?
        // Read-only, and with the URI flag so the connection can never be upgraded to a
        // writer. `immutable` is deliberately NOT set — it would cache the file and hide
        // the rows Wispr is writing while we poll.
        let uri = "file:\(databaseURL.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // formattedText is Wispr's post-cleanup output and asrText is raw; prefer the
        // former but fall back, since the cleanup can still be in flight.
        let sql = """
            SELECT COALESCE(NULLIF(formattedText, ''), asrText), duration, e2eLatency
            FROM History
            WHERE substr(timestamp, 1, 23) > ?
              AND substr(timestamp, 1, 23) < ?
              AND COALESCE(NULLIF(formattedText, ''), asrText) IS NOT NULL
            ORDER BY timestamp DESC
            LIMIT 1
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (lower as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (upper as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }

        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // e2eLatency is milliseconds and covers a network round trip — it is not comparable
        // to the local engines' compute time, and the UI labels it accordingly.
        return ComparisonResult(
            engine: "Wispr Flow",
            text: text,
            seconds: sqlite3_column_double(statement, 2) / 1000
        )
    }
}
