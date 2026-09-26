import Foundation

/// `--imessage-self-flow`: IM-01's data, read off this Mac's own Messages database.
///
/// **A diagnostic, not a `--selftest-*` flag**, and for two reasons that are different from
/// each other. It needs a grant and a real database, so it has no honest fixture version —
/// the fixtures are sanitised placeholders, which is the whole point of them. And it must
/// run *outside* `SelfTest.isRunning`: the harness swaps in temp stores and an isolated
/// index, and a diagnostic answering a question about the owner's own messages must not be
/// one of the things it swaps. So `NextNotesApp` dispatches it before
/// `runRequestedSelfTest`, in the `--notes-context-live` / `--usage-report` shape, and it
/// returns its lines for `writeSelfTest` to print, so a LaunchServices launch with no stdout
/// still leaves them in a file.
///
/// Read-only in the strong sense: the only write anywhere in here is one text file of its
/// own under `~/Library/Caches/NextNotesBuild/imessage/`, and the database is opened through
/// `MessagesDatabase` — `SQLITE_OPEN_READONLY`, `PRAGMA query_only`, `realpath(3)`.
@MainActor
enum MessagesSelfFlowReport {
    static let flag = "--imessage-self-flow"

    /// How many of the newest rows to describe. Ten, because Q2 asks about *kinds* of row
    /// (a plain text row, a typedstream body, an effect bubble, a voice note) and ten
    /// consecutive rows of one busy conversation is enough to see the kinds.
    static let newestRowCount = 10

    /// The three questions IM-01 exists to answer, in the order a person can act on them:
    /// can this app read anything at all; which conversation is the one to talk to it in;
    /// and what does a real body actually look like.
    static func run() async -> [String] {
        // Uncached on purpose. The person running this has just switched the grant on in
        // System Settings — or has not, and needs to be told — and a cached answer from
        // before that click is the one answer worth nothing.
        let state = await MessagesDatabaseHealth.probeNow()
        guard state.isReadable else {
            return needsFullDiskAccess(reason: state.reason ?? "the read did not succeed")
        }

        var lines = ["IMESSAGE_SELF_FLOW_FDA: granted — Next Notes read a row out of "
            + "\(MessagesDatabase.defaultDatabase.path) just now"]

        let database: MessagesDatabase
        do {
            database = try MessagesDatabase(root: MessagesDatabase.defaultDatabase)
        } catch {
            // The probe already proved the file reads, so a failure here is a second opinion
            // disagreeing with the first, which deserves its own line rather than silence.
            lines.append("IMESSAGE_SELF_FLOW_FAILED: the probe read a row but the report's own "
                + "open did not — \(plain(error))")
            lines.append("IMESSAGE_SELF_FLOW_DONE")
            return lines
        }

        do {
            let chats = try await database.chats(limit: MessagesDatabase.defaultChatPage)
            let rows = try await newestRows(in: database)
            // Closed before anything is formatted: this process is about to exit either way,
            // but an open handle on somebody's live Messages database is not something to
            // hand to a `return` on a path that could be taken twice.
            await database.close()
            lines += chatLines(chats)
            lines += messageLines(rows)
            lines.append(fixtureLine(rows: rows, chat: selfChat(chats)))
        } catch {
            lines.append("IMESSAGE_SELF_FLOW_FAILED: \(plain(error))")
        }

        lines.append("IMESSAGE_SELF_FLOW_DONE")
        return lines
    }

    // MARK: - Full Disk Access

    /// The one action to take, and then stop. Everything else this flag prints needs a read
    /// it cannot have, so continuing would print a confident empty answer to questions
    /// nobody asked — the failure mode `--notes-context-live` documents for a diagnostic
    /// run under the harness.
    private static func needsFullDiskAccess(reason: String) -> [String] {
        [
            "IMESSAGE_SELF_FLOW_NEEDS_FDA: \(reason)",
            "IMESSAGE_SELF_FLOW_ACTION: open System Settings → Privacy & Security → "
                + "Full Disk Access, add Next Notes, turn its switch on, then run this again.",
            "IMESSAGE_SELF_FLOW_DONE",
        ]
    }

    // MARK: - Chats

    /// One line per conversation, newest first, and which of them looks like the
    /// self-conversation — the one a person messages themselves, and therefore the one IM-07
    /// pairs.
    private static func chatLines(_ chats: [ChatRow]) -> [String] {
        var lines = ["IMESSAGE_SELF_FLOW_CHATS: \(chats.count)"]
        for chat in chats {
            let who = chat.participants.isEmpty
                ? "nobody named"
                : chat.participants.joined(separator: ", ")
            let name = chat.displayName ?? "no name"
            let kind = isSelfChat(chat)
                ? "this looks like a conversation with yourself"
                : "a conversation with someone else"
            lines.append("IMESSAGE_SELF_FLOW_CHAT guid=\(chat.guid) name=\"\(name)\" "
                + "who=[\(who)] — \(kind)")
        }
        lines.append("IMESSAGE_SELF_FLOW_SELF_CHAT: "
            + (selfChat(chats)?.guid ?? "none of the conversations above looks like one"))
        return lines
    }

    /// A direct self-conversation is one with a single participant whose address is also the
    /// conversation's own identifier.
    ///
    /// A guess from shape, and labelled as one: `Tests/Reports/imessage-self-flow.md`
    /// question Q1 is the measurement. This exists so the human has something concrete to
    /// confirm or correct rather than a column of guids to squint at.
    private static func isSelfChat(_ chat: ChatRow) -> Bool {
        guard chat.participants.count == 1,
              let identifier = chat.chatIdentifier else { return false }
        return identifier.compare(chat.participants[0], options: .caseInsensitive) == .orderedSame
    }

    private static func selfChat(_ chats: [ChatRow]) -> ChatRow? {
        chats.first(where: isSelfChat)
    }

    // MARK: - Messages

    /// The newest rows this database will hand over.
    ///
    /// The only ascending reader `MessagesDatabase` has is `messages(after:)`, so the newest
    /// rows are the ones above a watermark just below the highest ROWID. ROWIDs have gaps —
    /// rows get deleted — so this asks for a window rather than an exact count.
    private static func newestRows(in database: MessagesDatabase) async throws -> [MessageRow] {
        let latest = try await database.latestRowID()
        guard latest > 0 else { return [] }
        let window = Int64(newestRowCount)
        let rows = try await database.messages(after: max(0, latest - window), limit: newestRowCount)
        return Array(rows.suffix(newestRowCount))
    }

    /// The shape of the newest rows, in the order IM-01's Q2 asks for it: was `text` there,
    /// was `attributedBody` there, what did its first bytes look like, how long was it, and
    /// were `payload_data` / `balloon_bundle_id` involved.
    private static func messageLines(_ rows: [MessageRow]) -> [String] {
        guard !rows.isEmpty else {
            return ["IMESSAGE_SELF_FLOW_MESSAGES: this database holds no messages yet, so there "
                + "is nothing to look at"]
        }
        var lines = ["IMESSAGE_SELF_FLOW_MESSAGES: the \(rows.count) newest"]
        for row in rows {
            lines.append("IMESSAGE_SELF_FLOW_MESSAGE row=\(row.rowID) age=\(ageText(row.date)) "
                + "fromMe=\(row.isFromMe) text=\(textShape(row.text)) "
                + "attributedBody=\(blobShape(row.attributedBody)) "
                + "payload_data=\(blobShape(row.payloadData)) "
                + "balloon_bundle_id=\(row.balloonBundleID ?? "absent")")
        }
        if let last = rows.last {
            lines.append("IMESSAGE_SELF_FLOW_NEWEST: row \(last.rowID) landed \(ageText(last.date))")
        }
        return lines
    }

    /// `540 bytes, first 16: 04 0B 14 00 04 00 00 10 0E 00 02 4E 53 4D 75 74`
    ///
    /// The first sixteen bytes are what `TYPEDSTREAM-NOTES.md` §2.3 says to capture, and the
    /// length is what settles bytes-versus-characters. Both, never one.
    private static func blobShape(_ blob: Data?) -> String {
        guard let blob, !blob.isEmpty else { return "absent" }
        return "\(blob.count) bytes, first 16: " + blob.prefix(16).map(byteHex).joined(separator: " ")
    }

    /// Whether the `text` column carried anything, and how much of it. **Never the text
    /// itself**: this output is destined for a committed report, and a message body has no
    /// business in one.
    private static func textShape(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "NULL" }
        return "\(text.count) characters"
    }

    /// Apple's epoch, not Unix: `message.date` is nanoseconds since 2001-01-01, which is
    /// 978307200 seconds after the Unix epoch. A zero or an absent date reads as "unknown"
    /// rather than 1970, because a fabricated instant in a report is worse than a missing
    /// one.
    ///
    /// The corpus's fixed base (`EPOCH_BASE = 1700000000000000000`) lands *before* 2001, so a
    /// fixture prints a date in 1992 and reads as decades old. That is the conversion being
    /// right about a synthetic number, not a bug — the same arithmetic on a real row gives
    /// "3 minutes ago".
    private static func ageText(_ appleNanoseconds: Int64?) -> String {
        guard let appleNanoseconds, appleNanoseconds > 0 else { return "unknown" }
        let seconds = TimeInterval(appleNanoseconds / 1_000_000_000) - 978_307_200
        guard seconds > 0 else { return "in the future (raw \(appleNanoseconds))" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSinceNow: -seconds),
                                         relativeTo: Date())
    }

    // MARK: - The fixture block

    /// Where the ready-to-paste case goes. A cache directory and not `Tests/Fixtures/`:
    /// this block is written from the owner's own messages, and the tracked corpus is not
    /// where bytes that came from a real conversation land — even with the identifiers
    /// replaced, the body is the owner's words.
    static var fixtureDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NextNotesBuild/imessage", isDirectory: true)
    }

    private static func fixtureLine(rows: [MessageRow], chat: ChatRow?) -> String {
        let file = fixtureDirectory.appendingPathComponent("self-flow-case.sh")
        do {
            try FileManager.default.createDirectory(
                at: fixtureDirectory, withIntermediateDirectories: true)
            try fixtureCase(rows: rows, chat: chat)
                .write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return "IMESSAGE_SELF_FLOW_FIXTURE_FAILED: \(plain(error))"
        }
        return "IMESSAGE_SELF_FLOW_FIXTURE: \(file.path) — paste that one block into "
            + "Tests/Fixtures/chatdb/cases.sh instead of copying hex by hand"
    }

    /// The block itself, in `Tests/Fixtures/chatdb/cases.sh`'s own shape so it can be pasted
    /// straight into that file.
    ///
    /// Sanitisation is not optional and not a matter of care: a real self-conversation's
    /// `chat.guid` contains the owner's own phone number or email address, and
    /// `make-chatdb-fixture.sh` has a guard that refuses to emit a fixture carrying one. So
    /// every identifying value is written as a `REDACTED-*` placeholder and the header says
    /// which lines a human may replace — the guard keeps holding, and the block cannot be
    /// committed in a state that leaks a contact.
    static func fixtureCase(rows: [MessageRow], chat: ChatRow?) -> String {
        var out: [String] = [
            "# self-flow-case.sh — IM-01's real row, ready to paste into",
            "# Tests/Fixtures/chatdb/cases.sh.",
            "#",
            "# Generated by `\(flag)`. Add `self-flow-real` to ALL_CASES in cases.sh and a",
            "# `case_purpose` line for it, then run make-chatdb-fixture.sh self-flow-real.",
            "#",
            "# Every identifying value below is a REDACTED-* placeholder on purpose: a real",
            "# self-conversation's chat guid carries your own phone number or email address,",
            "# and make-chatdb-fixture.sh refuses to emit a fixture containing one. Replace",
            "# the REDACTED-* values with the ones from the IMESSAGE_SELF_FLOW_CHAT line above",
            "# if you need a real chat — and do not commit the result. Nothing else here",
            "# identifies anybody.",
            "",
            "# The body, as the generator's own `blob:` prefix plus hex. This is the one line",
            "# worth reading before pasting: the first 16 bytes are the version header",
            "# TYPEDSTREAM-NOTES.md §2.3 is waiting on, and the length is what settles",
            "# bytes-versus-characters.",
            "BLOBBODY_REAL=\"\(firstBlobLiteral(rows))\"",
            "",
            "case_self_flow_real() {",
            "    handle_row ROWID=1 id=REDACTED-HANDLE-1 \\",
            "        uncanonicalized_id=REDACTED-HANDLE-1 person_centric_id=REDACTED-PERSON-1",
            "    chat_row ROWID=1 guid='iMessage;-;REDACTED-HANDLE-1' \\",
            "        chat_identifier=REDACTED-HANDLE-1 display_name=REDACTED-PERSON-1",
            "    chat_handle 1 1",
            "",
        ]

        // The first body is referenced through `BLOBBODY_REAL`, so there is exactly one
        // place in the block a human copies hex into. A case is nearly always one row, and
        // two spellings of the same idea is one too many.
        var firstBlobUsed = false
        for (offset, row) in rows.enumerated() {
            let rowID = offset + 1
            out.append("    # row \(row.rowID) · \(textShape(row.text)) · \(blobShape(row.attributedBody))")
            var fields = ["        handle_id=1", "        is_from_me=\(row.isFromMe ? 1 : 0)"]
            if let date = row.date, date > 0 {
                // The generator's own `date` default is a fixed base; a real instant goes
                // through as `sql:` so nothing is invented here.
                fields.append("        date=sql:\(date)")
            }
            if let body = row.attributedBody, !body.isEmpty {
                if firstBlobUsed {
                    fields.append("        attributedBody=blob:\(body.hexLiteral)")
                } else {
                    fields.append("        attributedBody=\"$BLOBBODY_REAL\"")
                    firstBlobUsed = true
                }
            }
            if let payload = row.payloadData, !payload.isEmpty {
                fields.append("        payload_data=blob:\(payload.hexLiteral)")
            }
            if let balloon = row.balloonBundleID {
                fields.append("        balloon_bundle_id=\(balloon)")
            }
            out.append("    msg ROWID=\(rowID) guid=FIXTURE-MSG-\(String(format: "%04d", rowID)) \\")
            out.append(fields.joined(separator: " \\\n"))
            // Every row joined, not only the first: a fixture whose rows are invisible to
            // `messages(after:chatGUID:)` would test nothing at all.
            out.append("    chat_message 1 \(rowID)")
        }

        out.append("}")
        return out.joined(separator: "\n") + "\n"
    }

    /// The first row that carries a body, as the generator's own `blob:` prefix plus hex —
    /// the one value in the whole roadmap that does not exist yet without a human.
    private static func firstBlobLiteral(_ rows: [MessageRow]) -> String {
        rows.first { !($0.attributedBody ?? Data()).isEmpty }?.attributedBody
            .map { "blob:\($0.hexLiteral)" } ?? "blob:PASTE-REAL-BODY-HERE"
    }

    // MARK: - Plumbing

    private static func byteHex(_ byte: UInt8) -> String {
        let digits = "0123456789ABCDEF"
        return String([
            digits[digits.index(digits.startIndex, offsetBy: Int(byte >> 4))],
            digits[digits.index(digits.startIndex, offsetBy: Int(byte & 0x0F))],
        ])
    }

    private static func plain(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? (error as? CustomStringConvertible)?.description
            ?? error.localizedDescription
    }
}

private extension Data {
    /// Uppercase hex, no separators: the `X'…'` literal SQLite wants, which is what
    /// `make-chatdb-fixture.sh`'s `blob:` prefix is emitted as.
    var hexLiteral: String {
        map { byte in
            let digits = "0123456789ABCDEF"
            return String([
                digits[digits.index(digits.startIndex, offsetBy: Int(byte >> 4))],
                digits[digits.index(digits.startIndex, offsetBy: Int(byte & 0x0F))],
            ])
        }.joined()
    }
}
