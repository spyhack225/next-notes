import Foundation
import SQLite3

/// `--selftest-imessage-db` — NextNotes-iMessage IM-04.
///
/// A read-only `chat.db`, its capability probes and `PRAGMA query_only`, proved against
/// the sanitised corpus in `Tests/Fixtures/chatdb/`. **No Full Disk Access, no iPhone and
/// no grant**: the database root is injected, so every case here is a fixture built into
/// this process's own temporary directory by `make-chatdb-fixture.sh` and thrown away
/// afterwards. That injectability is the whole reason the task is runnable today.
///
/// **The load-bearing case is `query_only`.** `PRAGMA query_only = ON` is the only thing
/// between a bug and a write to a database iCloud syncs and Messages owns, and "the code
/// sets it" is a claim rather than a check. So it is read back from a **second**
/// connection opened through the same routine the actor opens with — which is what fails
/// the moment somebody drops the pragma — and a third connection opened *without* the
/// pragma has to answer `0`, so the positive answer is known to be the pragma's doing
/// rather than SQLite's default. A read-only open alone would not prove it: that is the
/// open flag, not the pragma, and the two are separate defences.
///
/// The final line is `IMESSAGE_DB_OK: <n> cases` or `IMESSAGE_DB_FAILED: <reason>`. The
/// per-case diagnostic lines are `IMESSAGE_DB_WRONG: …`, which is not a verdict token.
///
/// **IM-04a's six cases are the tail of the same list**, and they are about a grant rather
/// than about SQLite. The probe reads a row out of the database, so case 21 is the only one
/// in this file allowed to conclude the grant exists; cases 19 and 20 are the two ways it
/// does not — a file that is not there, and a file that is there and still cannot be read —
/// and case 20 is what separates a probe from a `stat`, since the owner's own `chat.db` is
/// world-readable and answers `authorization denied` anyway. Case 23 is the one that
/// matters, because it asserts the **absence** of a ✓ on a failure: a check that a
/// successful read draws one passes on any version of this feature, and a check that a
/// failure draws none is the only thing here that has never existed before this task.
@MainActor
enum MessagesDatabaseSelfTest {
    static func run() async -> String {
        var failures: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () async throws -> String?) async rethrows {
            caseCount += 1
            do {
                if let problem = try await body() { failures.append("\(name): \(problem)") }
            } catch {
                failures.append("\(name): threw \(error)")
            }
        }

        do {
            let corpus = try FixtureCorpus.build()
            defer { corpus.discard() }

            // 1. The path is resolved with realpath(3), so it agrees with
            // FileManager.enumerator about /private. Foundation's URL version does not,
            // and a prefix test between the two spellings matches nothing.
            var basic: MessagesDatabase?
            do { basic = try MessagesDatabase(root: corpus.url("basic-text")) } catch {
                failures.append("open: basic-text fixture did not open — \(error)")
            }

            if let basic {
                let raw = basic.root.path
                let resolved = basic.path
                if resolved != MessagesDatabase.canonicalPath(of: basic.root) {
                    failures.append("canonical_path: resolved \(resolved) is not the realpath of \(raw)")
                }
                if raw.hasPrefix("/var/"), !resolved.hasPrefix("/private/var/") {
                    failures.append("canonical_path: \(raw) resolved to \(resolved); "
                                    + "URL.resolvingSymlinksInPath would have left /var there")
                }
                caseCount += 1

                // 2. The pragma, read back from a second connection.
                try await check("query_only") {
                    let second = try MessagesDatabase.openReadOnly(at: resolved)
                    defer { sqlite3_close(second) }
                    guard let flag = try MessagesDatabase.queryOnlyFlag(on: second) else {
                        return "a second connection could not read PRAGMA query_only"
                    }
                    return flag == 1 ? nil : "a second connection read \(flag), not 1"
                }

                // 3. …and it is the pragma's doing, not SQLite's default.
                try await check("query_only_is_not_a_default") {
                    guard let flag = Self.readQueryOnlyWithoutPragma(at: resolved) else {
                        return "a bare read-only connection could not read PRAGMA query_only"
                    }
                    return flag == 0 ? nil : "a connection that never set the pragma already read \(flag)"
                }

                // 4. A write is refused, and the file is unchanged when read back through
                // a fresh connection. The write attempt is against a temporary fixture and
                // cannot succeed while either defence is in place.
                try await check("read_only_write_refused") {
                    let second = try MessagesDatabase.openReadOnly(at: resolved)
                    defer { sqlite3_close(second) }
                    let refused = Self.writeAttemptFails(on: second)
                    let count = Self.messageCount(at: resolved)
                    if !refused { return "an INSERT into a read-only chat.db was accepted" }
                    return count == 2 ? nil : "expected 2 messages in the fixture, found \(count)"
                }

                // 5. All nine capabilities on a complete schema.
                try await check("capabilities") {
                    let absent = MessagesCapability.allCases
                        .filter { basic.capabilities.flag(for: $0) == false }
                        .map(\.rawValue)
                    return absent.isEmpty ? nil : "absent from a complete fixture: \(absent.joined(separator: ", "))"
                }

                // 6. The watermark the watcher starts from.
                try await check("latest_row_id") {
                    let id = try await basic.latestRowID()
                    return id == 2 ? nil : "expected ROWID 2, got \(id)"
                }

                // 7. Both rows of basic-text, in row order, and the NULL text that makes
                // it IM-05's `.absent` case.
                try await check("messages") {
                    let rows = try await basic.messages(after: 0, chatGUID: FixtureCorpus.basicTextChatGUID)
                    guard rows.count == 2 else { return "expected 2 rows, got \(rows.count)" }
                    guard rows.map(\.rowID) == [1, 2] else { return "row order is \(rows.map(\.rowID))" }
                    guard rows[0].text == "FIXTURE-BODY-1" else { return "row 1 text is \(rows[0].text ?? "nil")" }
                    guard rows[1].text == nil else { return "row 2 was supposed to have no text" }
                    guard rows[0].guid == "FIXTURE-MSG-0001" else { return "row 1 guid is \(rows[0].guid)" }
                    return nil
                }

                // 8. The watermark half of the same query.
                try await check("messages_after") {
                    let rows = try await basic.messages(after: 1, chatGUID: FixtureCorpus.basicTextChatGUID)
                    guard rows.count == 1, rows[0].rowID == 2 else {
                        return "after ROWID 1 expected row 2 alone, got \(rows.map(\.rowID))"
                    }
                    return nil
                }

                // 9. One row by guid, and an honest nil for a guid that is not there.
                try await check("message_by_guid") {
                    let found = try await basic.message(guid: "FIXTURE-MSG-0001")
                    guard let found, found.rowID == 1 else { return "FIXTURE-MSG-0001 was not found" }
                    let missing = try await basic.message(guid: "FIXTURE-NOT-THERE")
                    return missing == nil ? nil : "an unknown guid returned a row"
                }

                // 10. One chat by guid, with its participants, and an honest nil.
                try await check("chat_by_guid") {
                    let chat = try await basic.chat(guid: FixtureCorpus.basicTextChatGUID)
                    guard let chat else { return "the fixture's own chat was not found" }
                    guard chat.chatIdentifier == "+15550000001" else {
                        return "chat identifier is \(chat.chatIdentifier ?? "nil")"
                    }
                    guard chat.participants == ["+15550000001"] else {
                        return "participants are \(chat.participants)"
                    }
                    let missing = try await basic.chat(guid: "iMessage;-;+15559999999")
                    return missing == nil ? nil : "an unknown chat guid returned a chat"
                }

                // 11. The list, and that the limit is a limit.
                try await check("chats") {
                    let all = try await basic.chats(limit: 5)
                    guard all.count == 1 else { return "expected 1 chat, got \(all.count)" }
                    let none = try await basic.chats(limit: 0)
                    return none.isEmpty ? nil : "limit 0 returned \(none.count) chats"
                }
            }

            // 12. The join methods: a DM joined to two handles, so "the first one" and
            // "both of them" are different answers.
            do {
                let direct = try MessagesDatabase(root: corpus.url("direct-message"))
                try await check("direct_message_participants") {
                    let chats = try await direct.chats(limit: 5)
                    guard let chat = chats.first else { return "the DM fixture has no chat" }
                    guard chat.participants == ["+15550000000", "+15550000001"] else {
                        return "participants are \(chat.participants)"
                    }
                    return nil
                }
            } catch {
                failures.append("direct_message_participants: the fixture did not open — \(error)")
            }

            // 13. Both directions decode as rows. Which one is a user command is IM-08's
            // question and IM-01's answer; here the only claim is that neither throws.
            do {
                let self_ = try MessagesDatabase(root: corpus.url("self-message"))
                try await check("self_message_rows") {
                    let rows = try await self_.messages(after: 0, chatGUID: FixtureCorpus.selfChatGUID)
                    guard rows.count == 2 else { return "expected 2 rows, got \(rows.count)" }
                    let directions = rows.map(\.isFromMe)
                    guard directions.contains(true), directions.contains(false) else {
                        return "expected one is_from_me=1 and one =0, got \(directions)"
                    }
                    guard rows.allSatisfy({ $0.text?.isEmpty == false }) else {
                        return "a self-chat row decoded with no text"
                    }
                    return nil
                }
            } catch {
                failures.append("self_message_rows: the fixture did not open — \(error)")
            }

            // 14/15/16/17. A database whose message table genuinely has no
            // attributedBody and no payload_data column. The probes must say so and the
            // queries must degrade rather than throw — that is the whole point of
            // carrying a capability value into every projection.
            do {
                let degraded = try MessagesDatabase(root: corpus.url("basic-text-degraded"))
                try await check("degraded_capabilities") {
                    // Exactly the two columns `--degraded` removes, and no others: the
                    // README is explicit that a degraded fixture is this database with two
                    // columns missing, not a smaller database, so a seventh missing
                    // capability would be the probe lying rather than the fixture.
                    let lost = Set(MessagesCapability.allCases
                        .filter { !degraded.capabilities.flag(for: $0) }
                        .map(\.rawValue))
                    let expected: Set<String> = [MessagesCapability.attributedBody.rawValue,
                                                 MessagesCapability.payloadData.rawValue]
                    return lost == expected
                        ? nil
                        : "absent capabilities are \(lost.sorted()), expected \(expected.sorted())"
                }

                try await check("degraded_messages") {
                    let rows = try await degraded.messages(after: 0, chatGUID: FixtureCorpus.basicTextChatGUID)
                    guard rows.count == 2 else { return "expected 2 rows, got \(rows.count)" }
                    guard rows.allSatisfy({ $0.attributedBody == nil && $0.payloadData == nil }) else {
                        return "a row carried body data from a database that has no such column"
                    }
                    guard rows[0].text == "FIXTURE-BODY-1" else { return "the text column degraded too" }
                    return nil
                }

                // The invariant behind all of it, in the only direction that is true: a
                // capability that is **off** guarantees the field reads nil, in every row
                // of both databases. The converse is not a claim — a database can have a
                // column and a row can leave it empty, which is the case that makes a
                // decoder say "absent" rather than "empty".
                try await check("capability_drives_projection") {
                    for (name, url) in [("basic-text", corpus.url("basic-text")),
                                        ("basic-text-degraded", corpus.url("basic-text-degraded"))] {
                        let db = try MessagesDatabase(root: url)
                        let rows = try await db.messages(after: 0, chatGUID: FixtureCorpus.basicTextChatGUID)
                        for row in rows {
                            if !db.capabilities.hasAttributedBody, row.attributedBody != nil {
                                return "\(name) row \(row.rowID): a body on a database "
                                    + "whose capability says it has no attributedBody column"
                            }
                            if !db.capabilities.hasBalloonBundleID, row.balloonBundleID != nil {
                                return "\(name) row \(row.rowID): a bundle id on a database "
                                    + "whose capability says it has no balloon_bundle_id column"
                            }
                        }
                    }
                    return nil
                }
            } catch {
                failures.append("degraded: the fixture did not open — \(error)")
            }

            // 18. A path that is not there is an answer, not a crash.
            try await check("unreadable") {
                let absent = corpus.directory.appendingPathComponent("no-such-chat.sqlite")
                do {
                    _ = try MessagesDatabase(root: absent)
                    return "opening a database that does not exist returned an actor"
                } catch let error as MessagesDatabase.OpenError {
                    guard case .unreadable = error else { return "\(error) is not .unreadable" }
                    return nil
                }
            }

            // 19. IM-04a: the Full Disk Access probe against a path that is not there.
            //
            // This is the case that makes the probe honest, and it is the one that has to
            // exist at all: a probe whose failure mode was a throw would take a `Settings`
            // row down with it, and a probe that could only say "granted" would be the
            // named mistake this roadmap opens IM-04a with. `.unreadable` is a value to
            // degrade to, and degrading is the designed response to everything this file
            // can hit.
            await check("fda_probe_missing_path_is_unreadable") {
                let absent = corpus.directory.appendingPathComponent("no-messages-here.sqlite")
                let state = await MessagesDatabaseHealth.probeNow(databaseAt: absent)
                guard case .unreadable(let reason) = state else {
                    return "a database that does not exist probed as \(state)"
                }
                // It reached the failure and came back with a sentence, rather than
                // answering nothing at all.
                guard !reason.isEmpty else { return ".unreadable carried no reason" }
                return state.isReadable ? ".unreadable also claims it is readable" : nil
            }

            // 20. A file that *is* there and still cannot be read. This is the case that
            // separates a probe from a `stat`, and it is the reason the probe exists: the
            // owner's own `chat.db` is mode `-rw-r--r--` and answers `authorization denied`
            // without the grant, so "the file exists" is the one answer this feature must
            // never draw. A four-line text file stands in for it — present, readable by
            // everybody, and not a database.
            await check("fda_probe_ignores_a_file_it_cannot_read") {
                let notADatabase = corpus.directory.appendingPathComponent("not-a-chat-db.sqlite")
                try? "this is not a database".write(to: notADatabase, atomically: true, encoding: .utf8)
                guard FileManager.default.fileExists(atPath: notADatabase.path) else {
                    return "the control file was not written"
                }
                let state = await MessagesDatabaseHealth.probeNow(databaseAt: notADatabase)
                return state.isReadable
                    ? "a file that is not a database probed as readable"
                    : nil
            }

            // 21. …and against a real database, which is the only thing that may say
            // "granted". The fixture is a file with rows in it, so the open, the schema
            // probe and the one row all succeed — the same three steps the owner's own
            // `chat.db` goes through, with no grant involved.
            await check("fda_probe_reads_a_row") {
                let state = await MessagesDatabaseHealth.probeNow(
                    databaseAt: corpus.url("basic-text"))
                guard state.isReadable else { return "the basic-text fixture probed as \(state)" }
                return state.reason == nil
                    ? nil
                    : ".readable also carried a reason: \(state.reason ?? "")"
            }

            // 22. There is no way to ask for this grant, and the row has to say so rather
            // than offer a button that does nothing. A `true` here would mean the checklist
            // could claim a prompt exists; it does not, and cannot.
            await check("fda_cannot_be_requested") {
                MessagesDatabaseHealth.canRequest
                    ? "the probe says Full Disk Access can be requested from inside the app"
                    : nil
            }

            // 23. The row cannot show a ✓ on a failure.
            //
            // Asserted as the **absence**, because presence is the easy half: every version
            // of this feature that shows a ✓ shows one for `.readable`. What has never
            // existed is a check that a failure draws none, and that is the claim the whole
            // task is. Every state the probe can return other than `.readable` is fed in,
            // so a new `.someOtherFailure` added later without a row here fails too.
            await check("the_check_mark_needs_a_successful_read") {
                let failures: [MessagesDatabaseHealth.State] = [
                    .unreadable(reason: "there is no Messages database at /nowhere on this Mac."),
                    .unreadable(reason: "macOS would not let Next Notes read your Messages database."),
                    .unreadable(reason: "")
                ]
                for state in failures {
                    let verdict = MessagesAccessVerdict.verdict(for: state)
                    if verdict.mark == "✓" {
                        return "\(state) drew a ✓"
                    }
                    if verdict.isGranted {
                        return "\(state) claimed the grant"
                    }
                    if verdict.mark != "○" {
                        return "\(state) drew \(verdict.mark), not the ○ a failure should show"
                    }
                }
                // …and the positive half, so the case above is not passing because the
                // glyph was never drawn at all.
                let granted = MessagesAccessVerdict.verdict(for: .readable)
                guard granted.mark == "✓", granted.isGranted else {
                    return "a successful read drew \(granted.mark), not a ✓"
                }
                // The two states must not share a rendering. Two states rendering the same
                // thing is how a row ends up green for a reason nobody chose.
                return granted.mark == MessagesAccessVerdict.verdict(for: .unreadable(reason: "x")).mark
                    ? "granted and not granted draw the same glyph"
                    : nil
            }

            // 24. IM-03's sentence, in one piece. The second half is the promise that makes
            // the ask reasonable, so a shortened paraphrase is a different sentence and not
            // the same one said more briefly.
            await check("messages_copy_is_im03s_verbatim") {
                let expected = "Next Notes needs Full Disk Access to read the iMessage "
                    + "conversation you choose for remote access. Messages are processed on "
                    + "this Mac."
                return MessagesAccessVerdict.purpose == expected
                    ? nil
                    : "the copy reads \"\(MessagesAccessVerdict.purpose)\""
            }

            // 25. The advice line has to change. Full Disk Access is the only pane in the
            // checklist where the app is not already listed, so the first press needs the
            // instruction everybody misses — that the `+` button is the whole task — and after
            // a press the remaining explanation is a stale entry, which has a different fix.
            // One string for both would leave somebody stuck with no idea which they have.
            await check("messages_advice_changes_after_a_press") {
                let first = MessagesAccessVerdict.advice(hasPressed: false)
                let later = MessagesAccessVerdict.advice(hasPressed: true)
                if first == later { return "both states say \"\(first)\"" }
                if first != Permissions.fdaAddAdvice { return "before a press it is not the add advice" }
                if later != Permissions.fdaRepairAdvice { return "after a press it is not the repair advice" }
                return nil
            }

            // 26. The add advice must actually name the action. This is the case the whole
            // row exists for: a button that opens a list with no Next Notes in it and no
            // switch to flip, described in words that do not mention adding anything, is the
            // same as no advice at all. Asserted on the words, not on the punctuation.
            await check("messages_add_advice_names_the_button_to_press") {
                let advice = Permissions.fdaAddAdvice
                let lowered = advice.lowercased()
                guard lowered.contains("+") || lowered.contains("plus") else {
                    return "the add advice never says which control to press: \"\(advice)\""
                }
                guard lowered.contains("next notes") else {
                    return "the add advice never says what to add: \"\(advice)\""
                }
                return nil
            }

            // 27. Neither sentence may be the kind of thing that makes somebody hand the app
            // to somebody else. `fdaRepairAdvice` is the one a person reads *after* the grant
            // looks correct and still does not work, so it is the one most likely to drift
            // into "TCC", "signature" or "requirement".
            await check("messages_advice_is_plain_words") {
                let jargon = ["tcc", "signature", "requirement", "cdhash", "csreq", "entitlement",
                              "sqlite", "database", "posix", "sandbox"]
                for advice in [Permissions.fdaAddAdvice, Permissions.fdaRepairAdvice] {
                    let lowered = advice.lowercased()
                    for word in jargon where lowered.contains(word) {
                        return "\"\(advice)\" says \"\(word)\""
                    }
                }
                return nil
            }
        } catch {
            failures.append("fixtures: \(error)")
        }

        // One string, marker last. `writeSelfTest` writes it in a single call while
        // `print` goes through a buffered stream, so printing the diagnostics separately
        // and returning the marker puts the verdict *before* them on stdout — and a
        // reader, or `Scripts/acceptance.sh`, reads the last line.
        var lines = failures.map { "IMESSAGE_DB_WRONG: \($0)" }
        lines.append(failures.isEmpty
            ? "IMESSAGE_DB_OK: \(caseCount) cases"
            : "IMESSAGE_DB_FAILED: \(failures[0])")
        return lines.joined(separator: "\n")
    }
}

// MARK: - The fixture corpus

/// `Tests/Fixtures/chatdb/make-chatdb-fixture.sh`, built into a temporary directory.
///
/// The corpus is a set of text files and a generator on purpose: a committed `.sqlite` is
/// a binary no diff can review, and a stale one that disagreed with `cases.sh` would fail
/// a test for the wrong reason. Generated `.sqlite` files land here and are deleted with
/// the directory; nothing is written into the repository and no `.sqlite` is committed.
private struct FixtureCorpus {
    /// The chat guid in `basic-text` and `direct-message`.
    static let basicTextChatGUID = "iMessage;-;+15550000001"
    /// The self-conversation's guid in `self-message`.
    static let selfChatGUID = "iMessage;-;+15550000000"

    let directory: URL
    private let cases: [(name: String, fixture: String, degraded: Bool)] = [
        ("basic-text", "basic-text", false),
        ("basic-text-degraded", "basic-text", true),
        ("self-message", "self-message", false),
        ("direct-message", "direct-message", false)
    ]

    init(directory: URL) { self.directory = directory }

    func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).sqlite")
    }

    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func build() throws -> FixtureCorpus {
        guard let script = generatorScript() else {
            throw CorpusError.generatorMissing
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-imessage-db-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corpus = FixtureCorpus(directory: directory)
        for entry in corpus.cases {
            var arguments = [script.path, entry.fixture, "--outdir", directory.path]
            if entry.degraded { arguments.append("--degraded") }
            let result = run(arguments)
            guard result.status == 0 else {
                corpus.discard()
                throw CorpusError.buildFailed(
                    "\(entry.fixture)\(entry.degraded ? " --degraded" : ""): "
                        + "\(result.reason.isEmpty ? "exit \(result.status)" : result.reason)")
            }
        }
        return corpus
    }

    enum CorpusError: Error {
        case generatorMissing
        case buildFailed(String)
    }

    /// The checkout this build was compiled from, found the way `BrowserToolExecutor`
    /// finds `Tests/Fixtures/seat-grid.html`: `#filePath` walks up until the file is
    /// there, so the test runs wherever the checkout lives rather than under cwd.
    static func generatorScript() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Tests")
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("chatdb")
                .appendingPathComponent("make-chatdb-fixture.sh")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func run(_ arguments: [String]) -> (status: Int32, reason: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        do { try process.run() } catch {
            return (127, "could not run the generator: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reason = String(data: data, encoding: .utf8)?
            .split(separator: "\n").map(String.init).joined(separator: " ") ?? ""
        return (process.terminationStatus, reason)
    }
}

// MARK: - Two connections this test opens itself

private extension MessagesDatabaseSelfTest {
    /// A connection opened exactly the way SQLite opens one when nobody has told it
    /// otherwise: read-only, no pragma.
    ///
    /// This is the negative control for the `query_only` case. If it answered `1`, the
    /// positive case would be true of any database on any machine and would be proving
    /// nothing — a probe that cannot fail is worse than no probe.
    static func readQueryOnlyWithoutPragma(at path: String) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA query_only", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Whether an `INSERT` through an already-open connection is refused.
    ///
    /// Never pointed at a real database: the fixture is a temporary file, and the write
    /// cannot succeed while either the read-only open or the pragma is in place.
    static func writeAttemptFails(on db: OpaquePointer) -> Bool {
        let sql = "INSERT INTO message (ROWID, guid) VALUES (9999, 'NEXTNOTES-WRITE-PROBE')"
        return sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK
    }

    /// `SELECT count(*) FROM message` through a fresh connection, so the number is what
    /// is on disk rather than what a connection that just failed a write believes.
    static func messageCount(at path: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return -1
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM message", -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(statement, 0))
    }
}
