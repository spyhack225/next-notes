import Foundation
import SQLite3

/// `--selftest-mac-accounts` — the Google account already on this Mac, answered with no Mail,
/// no calendar, no grant and no Google.
///
/// What it runs, through the real producers: Mail's index is read through the same read-only
/// opener the iMessage reader uses, from an `Envelope Index` **generated at run time** (no
/// database is committed, every address and subject is invented), including variants that
/// genuinely lack a column or a table; message text is parsed out of generated `.emlx` files;
/// Mail's scripts are built and their answers read exactly as production does, with the process
/// replaced by a fake that also plays Mail by writing the draft into the fixture index; the
/// calendar is an injected fake behind the same seam EventKit sits behind. The tool path is run
/// at the call site that matters — `WorkspaceToolRunner` and `AgentToolExecutor` — with a fake
/// `gws` that fails the run if it is ever called for mail or calendar.
///
/// What it cannot prove, and the packet says so: that Mail's real index spells its columns as
/// the fixture does, where the real `.emlx` files sit, how `save` and `reply` behave with
/// `visible:false`, and whether Automation permission carries from Next Notes to the `osascript`
/// child. `--selftest-mac-accounts-live` is the check against a real Mac.
@MainActor
enum MacAccountsSelfTest {
    typealias Expect = (Bool, String) -> Void

    static func run() async -> Bool {
        print("MAC_ACCOUNTS: the Google account already on this Mac")
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition { SelfTest.diagnostic("  ok   \(message)") }
            else { SelfTest.diagnostic("  FAIL \(message)"); failures.append(message) }
        }
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("NextNotesMacAccounts-\(UUID().uuidString)", isDirectory: true)
        defer {
            // A denied-permission case below removes read access; give it back before deleting.
            if let found = try? fileManager.contentsOfDirectory(atPath: work.path) {
                for name in found { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.appendingPathComponent(name).path) }
            }
            try? fileManager.removeItem(at: work)
        }
        do { try fileManager.createDirectory(at: work, withIntermediateDirectories: true) } catch {
            expect(false, "work folder: \(error)"); return false
        }

        sourceChoiceCases(expect)
        presentationCases(expect)
        queryCases(expect)
        emlxCases(expect)
        await databaseCases(work: work, expect)
        await accessCases(work: work, expect)
        scriptCases(expect)
        await macCases(work: work, expect)
        await toolPathCases(work: work, expect)
        await executorCases(work: work, expect)

        if failures.isEmpty {
            SelfTest.diagnostic("MAC_ACCOUNTS_OK")
            return true
        }
        SelfTest.diagnostic("MAC_ACCOUNTS: \(failures.count) failed")
        SelfTest.diagnostic("MAC_ACCOUNTS_FAILED")
        return false
    }

    // MARK: - The choice

    private static func sourceChoiceCases(_ expect: Expect) {
        expect(GoogleSource.effective(stored: nil, gwsSignedIn: false) == .thisMac, "nothing chosen, nothing signed in: this Mac")
        expect(GoogleSource.effective(stored: nil, gwsSignedIn: true) == .googleSignIn,
               "an existing gws sign-in keeps working without being asked about")
        expect(GoogleSource.effective(stored: .thisMac, gwsSignedIn: true) == .thisMac, "a stored choice beats the facts")
        expect(GoogleSource.effective(stored: .googleSignIn, gwsSignedIn: false) == .googleSignIn, "…in either direction")
        expect(GoogleSource.isThisMac(.signedIn(method: GoogleSource.macMethod)) && !GoogleSource.isThisMac(.signedIn(method: "x"))
               && !GoogleSource.isThisMac(.signedOut), "the Mac's account is told apart by its method")
        // Only the seven mail and calendar tools are answered by this Mac; Docs and Drive are Google's.
        expect(GoogleSource.macTools == ["search_email", "read_email", "draft_email", "send_email", "reply_email", "get_agenda", "create_event"],
               "the Mac answers the mail and calendar tools and no others")
        expect(Set(GoogleSource.allTools) == Set(WorkspaceTools.all.map(\.name)), "every Workspace tool is accounted for in one list")
    }

    // MARK: - Plain words for every step

    private static func presentationCases(_ expect: Expect) {
        let steps: [MacSetup.Step?] = [nil, .allowCalendar, .openCalendarSettings, .addAccount, .allowMailAccess, .turnOnMail, .ready]
        let banned = UIStringsLint.technicalWords + ["scope", "client", "api", "imap", "emlx", "sqlite", "applescript", "osascript", "automation"]
        var spoken: [String] = []
        for step in steps {
            let view = MacAccountModel.presentation(for: step)
            spoken += [view.label, view.detail] + (view.button.map { [$0] } ?? [])
            expect(!view.label.isEmpty && !view.detail.isEmpty, "every step has words: \(String(describing: step))")
        }
        let errors: [MacWorkspaceError] = [
            .needsFullDiskAccess, .noMailAccount, .needsCalendarAccess, .noGoogleCalendar, .cannotInvite, .couldNotSave,
            .messageNotFound, .unsupportedSearch("\u{201c}label:\u{201d}"), .cannotRead("Mail was busy."),
        ]
        spoken += errors.compactMap(\.errorDescription)
        // `automationDenied` names the pane a person must open, so it alone may say "Automation".
        spoken += [MacWorkspaceError.automationDenied.errorDescription ?? ""].map { $0.replacingOccurrences(of: "Automation", with: "") }
        spoken += [MacWorkspaceError.scriptFailed("x").errorDescription ?? ""]
        spoken += MacSetup(calendar: .denied, hasGoogleCalendar: false, mail: .needsFullDiskAccess, hasGoogleMail: false).gaps().values
        for text in spoken {
            for word in banned where text.lowercased().range(
                of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "s?\\b", options: .regularExpression) != nil {
                expect(false, "plain words: \u{201C}\(text)\u{201D} says \u{201C}\(word)\u{201D}")
            }
        }
        expect(MacAccountModel.presentation(for: .ready).button == nil, "a connected account has nothing left to press")
        expect(MacAccountModel.presentation(for: nil).button == "Use your Google account on this Mac",
               "the first button is the plain one, offered first")
        expect(MacAccountModel.presentation(for: .allowMailAccess).detail.contains("Full Disk Access")
               && MacAccountModel.presentation(for: .allowMailAccess).detail.contains("iMessage"),
               "the mail step says it is the same grant the iMessage chat needs")

        // The next step, from facts.
        func step(_ c: MacCalendarAccess, _ gc: Bool, _ m: MailDatabase.Access, _ gm: Bool) -> MacSetup.Step {
            MacSetup(calendar: c, hasGoogleCalendar: gc, mail: m, hasGoogleMail: gm).nextStep
        }
        expect(step(.notAsked, false, .needsFullDiskAccess, false) == .allowCalendar, "not asked about the calendar: ask")
        expect(step(.denied, false, .readable, false) == .openCalendarSettings, "refused: only System Settings can change it")
        expect(step(.granted, false, .needsFullDiskAccess, false) == .allowMailAccess,
               "no Google calendar and mail unreadable: the account may be only in Mail, so the grant comes first")
        expect(step(.granted, false, .readable, false) == .addAccount, "calendar and mail readable and no Google account in either: add one")
        expect(step(.granted, true, .needsFullDiskAccess, false) == .allowMailAccess, "an account with unreadable mail: Full Disk Access")
        expect(step(.granted, true, .readable, false) == .turnOnMail, "an account whose Mail is off: turn Mail on")
        expect(step(.granted, true, .readable, true) == .ready, "everything reachable: ready")
        expect(!MacSetup(calendar: .granted, hasGoogleCalendar: false, mail: .readable, hasGoogleMail: false).accountFound
               && MacSetup(calendar: .granted, hasGoogleCalendar: true, mail: .needsFullDiskAccess, hasGoogleMail: false).accountFound,
               "an account is found by its calendar or by its mail")
        let gaps = MacSetup(calendar: .granted, hasGoogleCalendar: true, mail: .needsFullDiskAccess, hasGoogleMail: false).gaps()
        expect(gaps["search_email"] != nil && gaps["send_email"] != nil && gaps["get_agenda"] == nil,
               "unreadable mail marks the mail tools and only them as needing setup")
        expect(MacSetup(calendar: .granted, hasGoogleCalendar: true, mail: .readable, hasGoogleMail: true).gaps().isEmpty,
               "a ready setup has no gaps")
    }

    // MARK: - Gmail's grammar into Mail's

    private static func queryCases(_ expect: Expect) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func parse(_ text: String) throws -> MacMailQuery {
            try MacMailQuery(gmail: try WorkspaceToolRunner.GmailQuery.normalize(text), now: now, calendar: calendar)
        }
        do {
            let query = try parse("in:inbox from:alice subject:plan is:unread newer_than:2d budget")
            expect(query.folder == .inbox && query.from == ["alice"] && query.subject == ["plan"] && query.unreadOnly
                   && query.text == ["budget"] && query.after == calendar.date(byAdding: .day, value: -2, to: now),
                   "folder, sender, subject, unread, age and a free word are all kept")
            let dated = try parse("in:sent after:2026-09-04 before:2026-09-10")
            expect(dated.folder == .sent && dated.after == calendar.date(from: DateComponents(year: 2026, month: 9, day: 4))
                   && dated.before == calendar.date(from: DateComponents(year: 2026, month: 9, day: 10)),
                   "dates are read as the start of their day (the model's dashes are mended on the way in)")
            expect(try parse("in:drafts").folder == .drafts, "the drafts folder")
            expect(try parse("older_than:1y").before == calendar.date(byAdding: .year, value: -1, to: now), "older_than is a bound")
        } catch { expect(false, "valid queries parse: \(error)") }
        for refused in ["label:work", "has:attachment", "-from:bob", "in:trash", "is:starred", "to:carol@example.com", "category:promotions"] {
            do {
                _ = try parse(refused)
                expect(false, "\u{201c}\(refused)\u{201d} is refused by name rather than ignored")
            } catch let error as MacWorkspaceError {
                if case .unsupportedSearch = error { expect(error.outcomeIsKnown, "\u{201c}\(refused)\u{201d} is refused by name, nothing was run") }
                else { expect(false, "\(refused): wrong error \(error)") }
            } catch { expect(false, "\(refused): wrong error \(error)") }
        }
    }

    // MARK: - Message text

    private static func emlxCases(_ expect: Expect) {
        func emlx(_ message: String) -> Data {
            let bytes = Data(message.utf8)
            return Data("\(bytes.count)\n".utf8) + bytes + Data("<?xml version=\"1.0\"?><plist></plist>".utf8)
        }
        let multipart = "From: a@example.com\r\nContent-Type: multipart/mixed; boundary=\"OUT\"\r\n\r\n--OUT\r\n"
            + "Content-Type: multipart/alternative; boundary=\"IN\"\r\n\r\n--IN\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Transfer-Encoding: quoted-printable\r\n\r\nHello =E2=80=94 the plan is attached.=\r\n Thanks.\r\n"
            + "--IN\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>HTML version</p>\r\n--IN--\r\n"
            + "--OUT\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename=\"plan.pdf\"\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\nSECRETATTACHMENTBYTES\r\n--OUT--\r\n"
        let text = EmlxParser.bodyText(fromEmlx: emlx(multipart))
        expect(text == "Hello \u{2014} the plan is attached. Thanks.", "multipart: the plain part, quoted-printable decoded, attachment skipped: \(text ?? "nil")")
        let latin = Data("Caf".utf8) + Data([0xE9]) + Data(" Friday".utf8)
        let b64 = "From: b@example.com\nContent-Type: text/plain; charset=iso-8859-1\nContent-Transfer-Encoding: base64\n\n"
            + latin.base64EncodedString() + "\n"
        expect(EmlxParser.bodyText(fromEmlx: emlx(b64)) == "Caf\u{e9} Friday", "base64 in a legacy charset reads as the words it was")
        let html = "From: c@example.com\nContent-Type: text/html; charset=utf-8\n\n<html><style>p{}</style><body><p>Big <b>sale</b> &amp; more</p><script>x()</script></body></html>"
        expect(EmlxParser.bodyText(fromEmlx: emlx(html)) == "Big sale & more", "an HTML-only message is reduced to its words")
        expect(EmlxParser.bodyText(fromEmlx: Data()) == nil, "an empty file has no text")
        _ = EmlxParser.bodyText(fromEmlx: Data("999999\nnot a message".utf8))
        _ = EmlxParser.bodyText(fromEmlx: Data([0xFF, 0x00, 0x0A, 0xFE]))
        expect(true, "a damaged file never traps")
        let huge = "From: d@example.com\nContent-Type: text/plain\n\n" + String(repeating: "word ", count: 30_000)
        expect((EmlxParser.bodyText(fromEmlx: emlx(huge))?.count ?? Int.max) <= EmlxParser.maxCharacters,
               "an enormous message is cut at \(EmlxParser.maxCharacters) characters")
    }

    // MARK: - The generated index

    struct Fixture {
        struct Options {
            var summaries = true
            var readColumn = true
            var subjectsTable = true
            var googleAccount = true
        }
        let mailRoot: URL
        let versionRoot: URL
        let index: URL
        static let google = "11111111-AAAA-BBBB-CCCC-GOOGLE000001"
        static let icloud = "22222222-AAAA-BBBB-CCCC-ICLOUD000002"
        static let base: Double = 1_790_000_000

        static func make(in root: URL, name: String, _ options: Options = Options()) throws -> Fixture {
            let mailRoot = root.appendingPathComponent(name, isDirectory: true)
            let version = mailRoot.appendingPathComponent("V10", isDirectory: true)
            let data = version.appendingPathComponent("MailData", isDirectory: true)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let index = data.appendingPathComponent("Envelope Index")
            var db: OpaquePointer?
            guard sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
                throw MacWorkspaceError.cannotRead("fixture database")
            }
            defer { sqlite3_close(db) }
            var sql = """
                CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
                CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
                \(options.subjectsTable ? "CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);" : "")
                \(options.summaries ? "CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);" : "")
                CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, mailbox INTEGER, sender INTEGER, subject INTEGER, \
                \(options.summaries ? "summary INTEGER," : "") date_received REAL, \(options.readColumn ? "read INTEGER," : "") deleted INTEGER);
                INSERT INTO mailboxes VALUES (5, 'imap://\(icloud)/INBOX');
                """
            if options.googleAccount {
                sql += """
                    INSERT INTO mailboxes VALUES (1, 'imap://\(google)/INBOX');
                    INSERT INTO mailboxes VALUES (2, 'imap://\(google)/%5BGmail%5D/Sent%20Mail');
                    INSERT INTO mailboxes VALUES (3, 'imap://\(google)/%5BGmail%5D/Drafts');
                    INSERT INTO mailboxes VALUES (4, 'imap://\(google)/%5BGmail%5D/All%20Mail');
                    """
            }
            sql += """
                INSERT INTO addresses VALUES (1, 'alice@example.com', 'Alice Example');
                INSERT INTO addresses VALUES (2, 'bob@example.com', NULL);
                INSERT INTO addresses VALUES (3, 'me@example.com', 'Me Myself');
                INSERT INTO addresses VALUES (4, 'deals@example.com', 'Deals');
                INSERT INTO addresses VALUES (5, 'icloud.person@example.com', NULL);
                """
            let messages: [(Int, Int, Int, String, String, Double, Int, Int)] = [
                // rowid, mailbox, sender, subject, summary, offset, read, deleted
                (12_345, 1, 1, "Quarterly plan", "Please look at the plan and send thoughts.", 300, 0, 0),
                (2, 1, 2, "Lunch on Friday?", "Are you free?", 200, 1, 0),
                (3, 1, 1, "Re: Quarterly plan", "Thanks", 100, 1, 0),
                (4, 1, 2, "Deleted thing", "gone", 400, 0, 1),
                (5, 5, 5, "Private iCloud mail", "not Google", 500, 0, 0),
                (6, 2, 3, "Sent hello", "hello", 250, 1, 0),
                (7, 3, 3, "My draft", "draft", 260, 1, 0),
                (4_001, 1, 4, "Discount 50% off", "sale", 50, 0, 0),
                (4_002, 1, 4, "Discount 50 percent", "sale", 40, 0, 0),
            ]
            for (offset, row) in messages.enumerated() {
                if options.subjectsTable { sql += "INSERT INTO subjects VALUES (\(offset + 1), '\(row.3)');\n" }
                if options.summaries { sql += "INSERT INTO summaries VALUES (\(offset + 1), '\(row.4)');\n" }
                let subjectColumn = options.subjectsTable ? offset + 1 : 0
                sql += "INSERT INTO messages (ROWID, mailbox, sender, subject, \(options.summaries ? "summary," : "") date_received, "
                    + "\(options.readColumn ? "read," : "") deleted) VALUES (\(row.0), \(row.1), \(row.2), \(subjectColumn), "
                    + "\(options.summaries ? "\(offset + 1)," : "") \(base + row.5), \(options.readColumn ? "\(row.6)," : "") \(row.7));\n"
            }
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw MacWorkspaceError.cannotRead("fixture rows: \(String(cString: sqlite3_errmsg(db)))")
            }
            return Fixture(mailRoot: mailRoot, versionRoot: version, index: index)
        }

        /// Plays Mail writing a message: a row in the named mailbox, now.
        func insert(rowID: Int, mailbox: Int, subject: String, at date: Date) {
            var db: OpaquePointer?
            guard sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return }
            defer { sqlite3_close(db) }
            let next = 1_000 + rowID
            _ = sqlite3_exec(db, """
                INSERT INTO subjects VALUES (\(next), '\(subject.replacingOccurrences(of: "'", with: "''"))');
                INSERT INTO messages (ROWID, mailbox, sender, subject, summary, date_received, read, deleted)
                VALUES (\(rowID), \(mailbox), 3, \(next), NULL, \(date.timeIntervalSince1970), 1, 0);
                """, nil, nil, nil)
        }

        func writeEmlx(rowID: Int, account: String = Fixture.google, folder: String = "INBOX", store: String = "STORE-1",
                       digits: [String]? = nil, message: String) throws {
            let thousands = rowID >= 1_000 ? String(rowID / 1_000).reversed().map { String($0) } : []
            var directory = versionRoot.appendingPathComponent(account).appendingPathComponent(folder + ".mbox")
                .appendingPathComponent(store).appendingPathComponent("Data")
            for part in digits ?? thousands { directory.appendPathComponent(part) }
            directory.appendPathComponent("Messages")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bytes = Data(message.utf8)
            try (Data("\(bytes.count)\n".utf8) + bytes).write(to: directory.appendingPathComponent("\(rowID).emlx"))
        }
    }

    private static func databaseCases(work: URL, _ expect: Expect) async {
        do {
            let fixture = try Fixture.make(in: work, name: "full")
            try fixture.writeEmlx(rowID: 12_345, message: "From: Alice Example <alice@example.com>\r\nSubject: Quarterly plan\r\n"
                + "Content-Type: text/plain; charset=utf-8\r\n\r\nThe plan is attached.\r\n")
            try fixture.writeEmlx(rowID: 2, message: "From: bob@example.com\r\nContent-Type: text/plain\r\n\r\nFriday works.\r\n")
            // The computed place misses this one; the bounded search finds it.
            try fixture.writeEmlx(rowID: 4_001, digits: ["Odd"], message: "From: deals@example.com\nContent-Type: text/html\n\n<p>Big <b>sale</b> &amp; more</p>")

            expect(MailDatabase.probe(mailRoot: fixture.mailRoot) == .readable, "the generated index is found and opens")
            let database = try MailDatabase(mailRoot: fixture.mailRoot)
            expect(database.layout == MailDatabase.Layout(hasRead: true, hasDeleted: true, hasSummary: true, hasComment: true),
                   "the probe reads the columns that are there")
            let boxes = try await database.mailboxes()
            expect(boxes.filter(\.isGoogleAccount).count == 4 && boxes.filter { !$0.isGoogleAccount }.count == 1,
                   "the Google account is recognised by its [Gmail] folders; the iCloud one is not")
            expect(try await database.hasGoogleAccount(), "a Google account in Mail is found")

            // Read-only, read back from a second connection (the same opener, so dropping the pragma goes red).
            let second = try MessagesDatabase.openReadOnly(at: MessagesDatabase.canonicalPath(of: fixture.index))
            let flag = try MessagesDatabase.queryOnlyFlag(on: second)
            var error: UnsafeMutablePointer<CChar>?
            let write = sqlite3_exec(second, "INSERT INTO mailboxes VALUES (99, 'imap://x/INBOX')", nil, nil, &error)
            sqlite3_free(error)
            sqlite3_close(second)
            expect(flag == 1 && write != SQLITE_OK, "Mail's index is opened read-only: query_only reads back 1 and a write is refused")

            let inbox = try await database.search(MacMailQuery())
            expect(inbox.map(\.ref) == ["mac-12345", "mac-2", "mac-3", "mac-4001", "mac-4002"],
                   "the inbox is the Google inbox only, newest first, with no deleted and no iCloud message: \(inbox.map(\.ref))")
            expect(inbox[0].from == "Alice Example <alice@example.com>" && inbox[1].from == "bob@example.com"
                   && inbox[0].snippet.hasPrefix("Please look") && inbox[0].isUnread && !inbox[1].isUnread,
                   "sender with its name, snippet and unread flag come through")
            var query = MacMailQuery(); query.from = ["ALICE"]
            expect(try await database.search(query).map(\.ref) == ["mac-12345", "mac-3"], "from: matches the sender, case-insensitively")
            query = MacMailQuery(); query.subject = ["lunch"]
            expect(try await database.search(query).map(\.ref) == ["mac-2"], "subject: matches the subject")
            query = MacMailQuery(); query.text = ["are you free"]
            expect(try await database.search(query).map(\.ref) == ["mac-2"], "free words are matched against the preview Mail keeps")
            query = MacMailQuery(); query.unreadOnly = true
            expect(try await database.search(query).map(\.ref) == ["mac-12345", "mac-4001", "mac-4002"], "unread only")
            query = MacMailQuery(); query.after = Date(timeIntervalSince1970: Fixture.base + 150); query.before = Date(timeIntervalSince1970: Fixture.base + 250)
            expect(try await database.search(query).map(\.ref) == ["mac-2"], "a date window is honoured at both ends")
            query = MacMailQuery(); query.text = ["50%"]
            expect(try await database.search(query).map(\.ref) == ["mac-4001"], "a % in a search means a percent sign, not a wildcard")
            query = MacMailQuery(); query.limit = 2
            expect(try await database.search(query).count == 2, "the limit is honoured")
            query = MacMailQuery(); query.folder = .sent
            expect(try await database.search(query).map(\.ref) == ["mac-6"], "the sent folder")
            query = MacMailQuery(); query.folder = .drafts
            expect(try await database.search(query).map(\.ref) == ["mac-7"], "the drafts folder")
            query = MacMailQuery(); query.text = ["private icloud"]
            expect(try await database.search(query).isEmpty, "mail from another account is never reachable by any query")

            let plan = try await database.read(ref: "mac-12345")
            expect(plan.body == "The plan is attached." && plan.bodyIsAvailable && plan.subject == "Quarterly plan"
                   && plan.from == "Alice Example <alice@example.com>", "a message is read in full from the file Mail keeps (computed place)")
            expect(try await database.read(ref: "mac-4001").body == "Big sale & more", "…and found by search when the layout is not the expected one")
            let missing = try await database.read(ref: "mac-3")
            expect(!missing.bodyIsAvailable && missing.body.isEmpty, "a body Mail has not downloaded says so, it is not blank")
            for bad in ["mac-5", "mac-999999", "mac-abc", "12345", ""] {
                do { _ = try await database.read(ref: bad); expect(false, "\u{201c}\(bad)\u{201d} is refused") }
                catch let error as MacWorkspaceError { expect(error == .messageNotFound, "\u{201c}\(bad)\u{201d} (not this person's Google mail) is not found") }
                catch { expect(false, "\(bad): wrong error \(error)") }
            }
            let target = try await database.replyTarget(ref: "mac-12345")
            expect(target.mailbox == "INBOX" && target.id == 12_345, "a reply names Mail's own mailbox and number")
            do { _ = try await database.replyTarget(ref: "mac-5"); expect(false, "a reply to another account's mail is refused") }
            catch { expect((error as? MacWorkspaceError) == .messageNotFound, "a reply to another account's mail is refused") }
            expect(try await database.containsMessage(subject: "my draft", folder: .drafts, since: Date(timeIntervalSince1970: Fixture.base)),
                   "\u{201c}is it there?\u{201d} finds a message by its subject")
            expect(!(try await database.containsMessage(subject: "my draft", folder: .sent, since: Date(timeIntervalSince1970: Fixture.base))),
                   "…and only in the folder it was asked about")
            expect(!(try await database.containsMessage(subject: "my draft", folder: .drafts, since: Date(timeIntervalSince1970: Fixture.base + 5_000))),
                   "…and only since the time it was asked about")
        } catch { expect(false, "generated index cases ran: \(error)") }

        // Degraded shapes: the column or table is genuinely not there.
        do {
            let noSummary = try Fixture.make(in: work, name: "no-summary", .init(summaries: false))
            let database = try MailDatabase(mailRoot: noSummary.mailRoot)
            let rows = try await database.search(MacMailQuery())
            expect(rows.count == 5 && rows.allSatisfy { $0.snippet.isEmpty } && !database.layout.hasSummary,
                   "no preview table: the search still answers, with no snippet")
            var query = MacMailQuery(); query.text = ["are you free"]
            expect(try await database.search(query).isEmpty, "…and free words are matched on what is there, not on a preview that is not")

            let noRead = try Fixture.make(in: work, name: "no-read", .init(readColumn: false))
            let readless = try MailDatabase(mailRoot: noRead.mailRoot)
            expect(try await readless.search(MacMailQuery()).count == 5, "no unread flag: an ordinary search still answers")
            query = MacMailQuery(); query.unreadOnly = true
            do { _ = try await readless.search(query); expect(false, "unread cannot be answered without the column") }
            catch let error as MacWorkspaceError {
                if case .unsupportedSearch = error { expect(true, "…and an unread search says it cannot, rather than answering a different question") }
                else { expect(false, "unread without the column: wrong error \(error)") }
            }

            let noSubjects = try Fixture.make(in: work, name: "no-subjects", .init(subjectsTable: false))
            do { _ = try MailDatabase(mailRoot: noSubjects.mailRoot); expect(false, "a missing required table is refused") }
            catch let error as MacWorkspaceError {
                if case .cannotRead(let reason) = error {
                    expect(reason.contains("shape") && error.outcomeIsKnown, "a shape this does not know is refused in plain words: \(reason)")
                } else { expect(false, "missing table: wrong error \(error)") }
            }

            let noGoogle = try Fixture.make(in: work, name: "no-google", .init(googleAccount: false))
            let none = try MailDatabase(mailRoot: noGoogle.mailRoot)
            expect(!(try await none.hasGoogleAccount()), "Mail with only an iCloud account holds no Google account")
            do { _ = try await none.search(MacMailQuery()); expect(false, "no Google account: refused") }
            catch { expect((error as? MacWorkspaceError) == .noMailAccount, "…and a search says so instead of reading the iCloud mail") }
        } catch { expect(false, "degraded index cases ran: \(error)") }
    }

    // MARK: - No grant

    private static func accessCases(work: URL, _ expect: Expect) async {
        let missing = work.appendingPathComponent("no-such-mail")
        expect(MailDatabase.probe(mailRoot: missing) == .noMailData, "no Mail data on the Mac: said so")
        do { _ = try MailDatabase(mailRoot: missing); expect(false, "no Mail data is an error") }
        catch { expect((error as? MacWorkspaceError) == .noMailAccount, "…and a search says to add the account in Internet Accounts") }

        // A real refusal from the file system: the folder exists and may not be opened. That is
        // what a missing Full Disk Access looks like to this process (EPERM there, EACCES here).
        do {
            let fixture = try Fixture.make(in: work, name: "denied")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.versionRoot.appendingPathComponent("MailData").path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.versionRoot.appendingPathComponent("MailData").path) }
            expect(MailDatabase.probe(mailRoot: fixture.mailRoot) == .needsFullDiskAccess, "a refused read is reported as needing Full Disk Access")
            do { _ = try MailDatabase(mailRoot: fixture.mailRoot); expect(false, "a refused read is an error") }
            catch { expect((error as? MacWorkspaceError) == .needsFullDiskAccess && (error as? MacWorkspaceError)?.outcomeIsKnown == true,
                           "…and a search says exactly which switch to flip") }
        } catch { expect(false, "denied-access fixture: \(error)") }
    }

    // MARK: - Mail's scripts

    private static func scriptCases(_ expect: Expect) {
        let hostile = "He said \"hi\" \\ it's \u{201c}fine\u{201d}; tell application \"Finder\" to quit"
        let request = MacComposeRequest(kind: .send, to: ["a@example.com", "b@example.com"], subject: hostile, body: "Body \"quoted\"\nline two \\ end")
        let arguments = MailScripting.arguments(for: request)
        let script = arguments.enumerated().filter { $0.offset % 2 == 1 && arguments[$0.offset - 1] == "-e" }.map(\.element)
        let values = Array(arguments.suffix(5))
        expect(values == ["send", "a@example.com\nb@example.com", hostile, request.body, ""],
               "every value goes in as its own argument, byte for byte (no escaping to get wrong)")
        expect(!script.joined(separator: "\n").contains("Finder") && !script.joined(separator: "\n").contains("fine"),
               "nothing a message says is ever part of the script")
        let reply = MailScripting.arguments(for: MacComposeRequest(kind: .reply(ref: "mac-1"), to: [], subject: "", body: "ok"),
                                            replyTarget: (mailbox: "INBOX", id: 12_345))
        expect(reply.suffix(5).first == "reply" && reply.last == "INBOX\t12345", "a reply carries Mail's own mailbox and number")
        expect(script.joined(separator: "\n").contains("imap.gmail.com") && !script.joined(separator: "\n").contains("default account"),
               "the Google account sends; the Mac's default account is never used instead")

        func output(_ code: Int32, _ out: String, _ err: String = "") -> WorkspaceCLIOutput {
            WorkspaceCLIOutput(standardOutput: Data(out.utf8), standardError: err, exitCode: code)
        }
        func verdict(_ output: WorkspaceCLIOutput) -> MacWorkspaceError? {
            do { try MailScripting.interpret(output); return nil } catch { return error as? MacWorkspaceError }
        }
        expect(verdict(output(0, "ok\n")) == nil, "Mail answering ok is success")
        expect(verdict(output(0, "")) == .scriptFailed("unreadable answer"), "success with no answer is not trusted")
        expect(verdict(output(1, "", "execution error: Not authorized to send Apple events to Mail. (-1743)")) == .automationDenied,
               "a refusal to control Mail is named, and nothing was sent")
        expect(verdict(output(1, "", "execution error: no Google account in Mail (7001)")) == .noMailAccount, "no Google account in Mail is named")
        expect(verdict(output(1, "", "execution error: message not found (7002)")) == .messageNotFound, "a reply target that is gone is named")
        let other = verdict(output(1, "", "execution error: something broke (-10000)\nmore"))
        expect(other == .scriptFailed("execution error: something broke (-10000)") && other?.outcomeIsKnown == false,
               "any other error after Mail was told is \u{201c}not sure\u{201d}, never \u{201c}failed\u{201d}")
        expect(MacWorkspaceError.automationDenied.outcomeIsKnown && MacWorkspaceError.noMailAccount.outcomeIsKnown
               && MacWorkspaceError.cannotInvite.outcomeIsKnown && MacWorkspaceError.needsFullDiskAccess.outcomeIsKnown,
               "every refusal that happens before anything is sent is known")
        expect(ActionOrchestrator.status(forThrown: MacWorkspaceError.scriptFailed("x"), afterFiring: true) == .outcomeUnknown
               && ActionOrchestrator.status(forThrown: MacWorkspaceError.automationDenied, afterFiring: true) == .failed
               && ActionOrchestrator.status(forThrown: WorkspaceCLIError.timedOut(60), afterFiring: true) == .outcomeUnknown,
               "the runtime turns those into \u{201c}not sure\u{201d} and \u{201c}failed\u{201d} exactly as it does for Google")

        // The script is real AppleScript: it compiles against Mail's own dictionary. Compiling
        // runs nothing and reads no mail.
        if FileManager.default.fileExists(atPath: "/System/Applications/Mail.app") {
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesMailScript-\(UUID().uuidString).scpt")
            defer { try? FileManager.default.removeItem(at: target) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", target.path] + script.flatMap { ["-e", $0] }
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            do {
                try process.run(); process.waitUntilExit()
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                expect(process.terminationStatus == 0, "Mail's script compiles against Mail's own scripting dictionary" + (text.isEmpty ? "" : ": \(text.prefix(200))"))
            } catch { expect(false, "osacompile ran: \(error)") }
        } else {
            SelfTest.diagnostic("  note Mail.app is not installed here, so the script was not compiled")
        }
    }

    // MARK: - Fakes

    private final class FakeScript: MailScriptRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var result: Result<WorkspaceCLIOutput, any Error> = .success(WorkspaceCLIOutput(standardOutput: Data("ok\n".utf8), standardError: "", exitCode: 0))
        var playMail: (@Sendable ([String]) -> Void)?
        var identity = "mail-account-1\tme@example.com"
        var calls: [[String]] { lock.withLock { recorded } }
        func run(arguments: [String], timeout: TimeInterval) async throws -> WorkspaceCLIOutput {
            if arguments.last == "account" { return WorkspaceCLIOutput(standardOutput: Data(identity.utf8), standardError: "", exitCode: 0) }
            lock.withLock { recorded.append(arguments) }
            playMail?(arguments)
            return try result.get()
        }
    }

    private final class FakeCalendar: MacCalendarStore, @unchecked Sendable {
        private let lock = NSLock()
        var accessState: MacCalendarAccess = .granted
        var calendarList: [MacCalendarInfo] = []
        var stored: [MacStoredEvent] = []
        var agendaItems: [MacAgendaItem] = []
        var saveError: (any Error)?
        var dropOnSave = false
        private var savedCount = 0
        var saves: Int { lock.withLock { savedCount } }
        func access() async -> MacCalendarAccess { accessState }
        func requestAccess() async -> Bool { accessState == .granted }
        func calendars() async -> [MacCalendarInfo] { calendarList }
        func agenda(from: Date, to: Date) async -> [MacAgendaItem] { agendaItems.filter { $0.start >= from && $0.start < to } }
        func events(calendarID: String, from: Date, to: Date) async -> [MacStoredEvent] {
            lock.withLock { stored.filter { $0.calendarID == calendarID && $0.start >= from && $0.start < to } }
        }
        func save(_ draft: MacEventDraft, calendarID: String) async throws -> String {
            if let saveError { throw saveError }
            return lock.withLock {
                savedCount += 1
                let id = "event-\(savedCount)"
                if !dropOnSave {
                    stored.append(MacStoredEvent(id: id, title: draft.title, start: draft.start, end: draft.end, notes: draft.notes, calendarID: calendarID))
                }
                return id
            }
        }
        func event(id: String) async -> MacStoredEvent? { lock.withLock { stored.first { $0.id == id } } }
    }

    private static let googleCalendar = MacCalendarInfo(id: "g1", title: "me@example.com", sourceTitle: "Google", isWritable: true, looksGoogle: true)
    private static let googleSecondary = MacCalendarInfo(id: "g2", title: "Holidays", sourceTitle: "Google", isWritable: false, looksGoogle: true)
    private static let iCloudCalendar = MacCalendarInfo(id: "i1", title: "Home", sourceTitle: "iCloud", isWritable: true, looksGoogle: false)

    private final class NeverCLI: WorkspaceCLIRunning, @unchecked Sendable {
        private let lock = NSLock(); private var seen: [[String]] = []
        var calls: [[String]] { lock.withLock { seen } }
        func run(_ arguments: [String], timeout: TimeInterval) async throws -> WorkspaceCLIOutput {
            lock.withLock { seen.append(arguments) }
            return WorkspaceCLIOutput(standardOutput: Data("{}".utf8), standardError: "", exitCode: 0)
        }
    }

    // MARK: - MacAccounts

    private static func macCases(work: URL, _ expect: Expect) async {
        do {
            let fixture = try Fixture.make(in: work, name: "mac")
            let script = FakeScript()
            let calendar = FakeCalendar()
            calendar.calendarList = [iCloudCalendar, googleSecondary, googleCalendar]
            let mac = MacAccounts(mailRoot: fixture.mailRoot, calendar: calendar, script: script)

            // Setup and sign-in state from what is there.
            let setup = await mac.setup()
            expect(setup == MacSetup(calendar: .granted, hasGoogleCalendar: true, mail: .readable, hasGoogleMail: true) && setup.nextStep == .ready,
                   "a Google calendar and Google mail that can be read is a ready account: \(setup)")
            expect(await mac.authState() == .signedIn(method: GoogleSource.macMethod), "…and reads as connected, in the one word every screen uses")
            let originalTag = await mac.accountTag()
            expect(originalTag != nil, "the selected Mail sender supplies a real approval tag")
            script.identity = "mail-account-2\tother@example.com"
            expect(await mac.accountTag() != originalTag, "reordering two Mail senders changes the approval tag while Calendar stays fixed")
            script.identity = "mail-account-1\tme@example.com"
            expect(await mac.accountTag() == originalTag, "restoring the exact Mail sender restores its tag")
            script.identity = "mail-account-1\treplacement@example.com"
            expect(await mac.accountTag() != originalTag, "replacing the address in the selected Mail account changes its tag")
            script.identity = "mail-account-1\tme@example.com"
            calendar.accessState = .notAsked
            expect(await mac.setup().nextStep == .allowCalendar, "no calendar access yet: the next step is to ask")
            calendar.accessState = .granted

            // Drafts: Mail is told, and the read-back finds the draft Mail wrote.
            let startedAt = Date()
            script.playMail = { _ in fixture.insert(rowID: 9_001, mailbox: 3, subject: "Hello there", at: Date()) }
            let draft = try await mac.compose(MacComposeRequest(kind: .draft, to: ["x@example.com"], subject: "Hello there", body: "Hi"))
            expect(draft.confirmedInMail && script.calls.count == 1, "a draft is written by Mail and found in Mail's Drafts afterwards, with one script run")
            let boundSender = Array(script.calls[0].suffix(7).prefix(2))
            expect(boundSender == ["mail-account-1", "me@example.com"], "the compose consumer receives the exact selected Mail account and address")
            let told = Array(script.calls[0].suffix(5))
            expect(told.first == "draft" && told[2] == "Hello there", "…with exactly the reviewed subject")
            script.playMail = nil
            let silent = try await mac.compose(MacComposeRequest(kind: .send, to: ["x@example.com"], subject: "Never appears", body: "Hi"))
            expect(!silent.confirmedInMail, "Mail accepted it but nothing shows in Sent: that is said, not claimed")
            expect(try await mac.findComposed(MacComposeRequest(kind: .draft, to: [], subject: "Hello there", body: ""), since: startedAt.addingTimeInterval(-5)),
                   "\u{201c}is it there?\u{201d} finds the draft")
            expect(!(try await mac.findComposed(MacComposeRequest(kind: .send, to: [], subject: "Never appears", body: ""), since: startedAt)),
                   "…and does not invent a send that is not there")

            // A reply is looked up before Mail is told anything.
            let before = script.calls.count
            _ = try await mac.compose(MacComposeRequest(kind: .reply(ref: "mac-12345"), to: [], subject: "", body: "Thanks"))
            expect(script.calls.count == before + 1 && script.calls.last?.last == "INBOX\t12345", "a reply goes to Mail with its own mailbox and number")
            do {
                _ = try await mac.compose(MacComposeRequest(kind: .reply(ref: "mac-5"), to: [], subject: "", body: "x"))
                expect(false, "a reply to another account's mail is refused")
            } catch {
                expect((error as? MacWorkspaceError) == .messageNotFound && script.calls.count == before + 1,
                       "a reply to mail that is not the Google account's is refused and Mail is never told")
            }

            // Failures: what they prove about whether anything was sent.
            script.result = .success(WorkspaceCLIOutput(standardOutput: Data(), standardError: "Not authorized to send Apple events to Mail. (-1743)", exitCode: 1))
            do { _ = try await mac.compose(MacComposeRequest(kind: .send, to: ["x@example.com"], subject: "S", body: "B")); expect(false, "denied is an error") }
            catch { expect((error as? MacWorkspaceError) == .automationDenied, "Automation denied: said plainly, nothing sent") }
            script.result = .failure(WorkspaceCLIError.timedOut(60))
            do { _ = try await mac.compose(MacComposeRequest(kind: .send, to: ["x@example.com"], subject: "S", body: "B")); expect(false, "a timeout is an error") }
            catch let error as WorkspaceCLIError { expect(!error.outcomeIsKnown, "a send that times out is \u{201c}not sure\u{201d}, exactly as for Google") }
            catch { expect(false, "timeout: wrong error \(error)") }

            // Calendar.
            let start = Date(timeIntervalSince1970: Fixture.base + 86_400), end = start.addingTimeInterval(3_600)
            let event = MacEventDraft(title: "Planning", start: start, end: end, notes: "")
            let first = try await mac.createEvent(event)
            expect(!first.alreadyThere && first.verified && calendar.saves == 1, "an event is added to the Google calendar and read back")
            expect(calendar.stored.first?.calendarID == "g1", "…on the account's own writable calendar, not the read-only one and not iCloud")
            let again = try await mac.createEvent(event)
            expect(!again.alreadyThere && again.verified && calendar.saves == 2 && again.reference != first.reference, "an independent identical event has its own saved ID; matching details never claim identity")
            expect(!(try await mac.findEvent(MacEventDraft(title: event.title, start: start, end: end, notes: "Changed reviewed description"))),
                   "a matching title and time with a different description is not the reviewed event")
            expect(try await mac.findEvent(event), "\u{201c}is it there?\u{201d} finds the event")
            expect(!(try await mac.findEvent(MacEventDraft(title: "Other", start: start, end: end, notes: ""))), "…and only that event")
            calendar.dropOnSave = true
            let lost = try await mac.createEvent(MacEventDraft(title: "Lost", start: start.addingTimeInterval(7_200), end: end.addingTimeInterval(7_200), notes: ""))
            expect(!lost.verified, "an event that cannot be read back is not called verified")
            calendar.dropOnSave = false

            calendar.calendarList = [iCloudCalendar]
            do { _ = try await mac.createEvent(MacEventDraft(title: "Nowhere", start: start.addingTimeInterval(9_000), end: end.addingTimeInterval(9_000), notes: "")); expect(false, "no Google calendar is refused") }
            catch { expect((error as? MacWorkspaceError) == .noGoogleCalendar && calendar.saves == 3, "no Google calendar: nothing is created on an iCloud one") }
            calendar.calendarList = [iCloudCalendar, googleCalendar]
            calendar.saveError = NSError(domain: "x", code: 1)
            do { _ = try await mac.createEvent(MacEventDraft(title: "Fails", start: start.addingTimeInterval(11_000), end: end.addingTimeInterval(11_000), notes: "")); expect(false, "a refused save is an error") }
            catch { expect((error as? MacWorkspaceError) == .couldNotSave && (error as? MacWorkspaceError)?.outcomeIsKnown == true, "a refused save says nothing was added") }
            calendar.saveError = nil
            calendar.accessState = .denied
            do { _ = try await mac.agenda(from: start, to: end); expect(false, "no calendar access is an error") }
            catch { expect((error as? MacWorkspaceError) == .needsCalendarAccess, "no calendar access: the one switch is named") }
            calendar.accessState = .granted
            calendar.agendaItems = [
                MacAgendaItem(title: "Standup", start: start.addingTimeInterval(600), end: start.addingTimeInterval(1_200), isAllDay: false, calendar: "Work"),
                MacAgendaItem(title: "Dentist", start: start.addingTimeInterval(1_800), end: start.addingTimeInterval(3_000), isAllDay: false, calendar: "Home"),
            ]
            expect(try await mac.agenda(from: start, to: end).map(\.title) == ["Standup", "Dentist"], "the agenda is every calendar the Mac has, not only Google's")

            expect(MacGoogle.looksLikeGoogle(sourceTitle: "Google", isCalDAV: true, calendarTitles: [])
                   && MacGoogle.looksLikeGoogle(sourceTitle: "Work", isCalDAV: true, calendarTitles: ["me@gmail.com"])
                   && !MacGoogle.looksLikeGoogle(sourceTitle: "iCloud", isCalDAV: false, calendarTitles: ["me@gmail.com"])
                   && !MacGoogle.looksLikeGoogle(sourceTitle: "Exchange", isCalDAV: false, calendarTitles: ["Home"]),
                   "a Google calendar source is told apart by its name or its address")
            expect(MacGoogle.creationTarget(in: [googleSecondary, iCloudCalendar]) == nil
                   && MacGoogle.creationTarget(in: [googleSecondary, googleCalendar])?.id == "g1",
                   "an event goes only to a writable Google calendar, the account's own first")
        } catch { expect(false, "MacAccounts cases ran: \(error)") }
    }

    // MARK: - The tool path

    private static func toolPathCases(work: URL, _ expect: Expect) async {
        do {
            let fixture = try Fixture.make(in: work, name: "tools")
            try fixture.writeEmlx(rowID: 12_345, message: "From: Alice Example <alice@example.com>\r\nContent-Type: text/plain\r\n\r\nThe plan is attached.\r\n")
            let script = FakeScript()
            let calendar = FakeCalendar()
            calendar.calendarList = [googleCalendar]
            let mac = MacAccounts(mailRoot: fixture.mailRoot, calendar: calendar, script: script)
            let cli = NeverCLI()
            GoogleSource.macForTesting = mac
            defer { GoogleSource.macForTesting = nil }

            func proposal(_ tool: String, _ arguments: [String: String]) -> AgentProposal {
                AgentProposal(id: UUID().uuidString, meetingID: UUID(), tool: tool, arguments: arguments, rationale: "",
                              accountTag: nil, startsAt: nil)
            }
            let search = try await WorkspaceToolRunner.run(proposal("search_email", ["query": "from:alice", "maxResults": "5"]), cli: cli)
            let lines = search.summary.split(separator: "\n").map(String.init)
            expect(lines.first?.hasPrefix("1) ") == true && lines.first?.contains("Alice Example <alice@example.com> \u{00B7} Quarterly plan") == true
                   && lines.last == "To read one in full, call read_email with its number.",
                   "search prints the same numbered lines the Google path prints: \(lines.first ?? "")")
            expect(!search.summary.contains("mac-") && search.contextReferences.count == 2 && search.contextReferences.allSatisfy { $0.kind == "mail" },
                   "no internal number reaches the text, and each hit is a verified source")
            let read = try await WorkspaceToolRunner.run(proposal("read_email", ["message": "1"]), cli: cli)
            expect(read.summary.contains("From: Alice Example <alice@example.com>") && read.summary.contains("The plan is attached."),
                   "read_email prints the message by the number the search gave")
            expect(read.contextReferences.count == 1 && read.contextReferences.first?.id.hasPrefix("mail:mac-") == true,
                   "a real Mac mail read retains fetched source metadata for the existing result consumer")

            do { _ = try await WorkspaceToolRunner.run(proposal("read_email", ["message": "9"]), cli: cli); expect(false, "an unprinted number is refused") }
            catch let error as WorkspaceCLIError { expect(error.outcomeIsKnown, "a number nobody printed is a bad argument the model can correct") }
            catch { expect(false, "bad number: wrong error \(error)") }
            let none = try await WorkspaceToolRunner.run(proposal("search_email", ["query": "subject:nothing-like-this"]), cli: cli)
            expect(none.summary == "No message matches subject:nothing-like-this.", "an empty search says so in the same words")
            do { _ = try await WorkspaceToolRunner.run(proposal("search_email", ["query": "label:work"]), cli: cli); expect(false, "label: is refused") }
            catch let error as MacWorkspaceError { expect(error.errorDescription?.contains("label") == true, "an operator Mail cannot answer is refused by name") }
            catch { expect(false, "label: wrong error \(error)") }

            let day = Date(timeIntervalSince1970: Fixture.base)
            let dayText: String = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f.string(from: day) }()
            calendar.agendaItems = [MacAgendaItem(title: "Standup", start: Calendar.current.startOfDay(for: day).addingTimeInterval(36_000),
                                                  end: Calendar.current.startOfDay(for: day).addingTimeInterval(39_600), isAllDay: false, calendar: "Work")]
            let agenda = try await WorkspaceToolRunner.run(proposal("get_agenda", ["date": dayText]), cli: cli)
            expect(agenda.summary.contains("Standup") && agenda.summary.hasPrefix("On "), "get_agenda prints the day in the same shape: \(agenda.summary.prefix(40))")

            // Events: guests are refused before anything is created.
            do {
                _ = try await WorkspaceToolRunner.run(proposal("create_event", [
                    "title": "Sync", "start": "2026-10-05T10:00:00Z", "end": "2026-10-05T11:00:00Z", "attendees": "guest@example.com",
                ]), cli: cli)
                expect(false, "an event with guests is refused")
            } catch {
                expect((error as? MacWorkspaceError) == .cannotInvite && calendar.saves == 0, "an event with guests is refused before anything is created")
            }
            let created = try await WorkspaceToolRunner.run(proposal("create_event", [
                "title": "Sync", "start": "2026-10-05T10:00:00Z", "end": "2026-10-05T11:00:00Z",
            ]), cli: cli)
            expect(created.summary == "Created the event \u{201c}Sync\u{201d}." && created.verification == "Read back the reviewed event details" && calendar.saves == 1,
                   "an event with no guests is created and read back")
            expect(created.reference == calendar.stored.first?.id && created.reference != nil,
                   "the created Mac event retains its exact saved identifier through the real runner")
            do { _ = try await WorkspaceToolRunner.run(proposal("create_event", ["title": "Bad", "start": "later", "end": "never"]), cli: cli); expect(false, "bad times are refused") }
            catch let error as WorkspaceCLIError { expect(error.outcomeIsKnown && calendar.saves == 1, "times that are not times are refused before anything is created") }
            catch { expect(false, "bad times: wrong error \(error)") }

            // Mail writes.
            script.playMail = { _ in fixture.insert(rowID: 9_100, mailbox: 3, subject: "Saved one", at: Date()) }
            let drafted = try await WorkspaceToolRunner.run(proposal("draft_email", ["to": "x@example.com", "subject": "Saved one", "body": "Hi"]), cli: cli)
            expect(drafted.summary == "Saved the draft." && drafted.verification != nil, "a draft says so and carries what was found")
            script.playMail = { _ in fixture.insert(rowID: 9_101, mailbox: 2, subject: "Sent one", at: Date()) }
            let sent = try await WorkspaceToolRunner.run(proposal("send_email", ["to": "x@example.com", "subject": "Sent one", "body": "Hi"]), cli: cli)
            expect(sent.summary == "Sent the email." && sent.verification != nil, "a send says so and carries what was found")
            script.playMail = nil
            let unconfirmed = try await WorkspaceToolRunner.run(proposal("send_email", ["to": "x@example.com", "subject": "Ghost", "body": "Hi"]), cli: cli)
            expect(unconfirmed.summary == "Sent the email." && unconfirmed.verification == nil, "a send nothing confirms carries no verification")
            let replied = try await WorkspaceToolRunner.run(proposal("reply_email", ["message_id": "1", "body": "Thanks"]), cli: cli)
            expect(replied.summary == "Sent the reply." && script.calls.last?.last?.hasSuffix("\t12345") == true,
                   "a reply by the printed number reaches Mail with that message's own number")

            // Drive and Docs are not on the Mac: they go to the Google runner, untouched.
            _ = try? await WorkspaceToolRunner.run(proposal("find_drive_files", ["query": "plan"]), cli: cli)
            expect(cli.calls.first?.first == "drive" && cli.calls.count == 1, "Drive is Google's: it is run through the Google runner and mail and calendar never were")
            // With no Mac source in force, the Google path is exactly what it was.
            GoogleSource.macForTesting = nil
            _ = try? await WorkspaceToolRunner.run(proposal("search_email", ["query": ""]), cli: cli)
            expect(cli.calls.contains { $0.starts(with: ["gmail", "users", "messages", "list"]) }, "with the Google sign-in as the source, mail still goes through gws")
            GoogleSource.macForTesting = nil
            let previousSource = Settings.shared.googleSource
            Settings.shared.googleSource = .thisMac
            GoogleSource.forget()
            let executable = work.appendingPathComponent("gws")
            let marker = work.appendingPathComponent("isolated-cli-ran")
            try "#!/bin/sh\ntouch \"$(dirname \"$0\")/isolated-cli-ran\"\necho '{\"messages\":[]}'\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            do {
                guard let isolated = GoogleWorkspaceCLI.isolatedForTesting(root: work, executable: executable) else { throw WorkspaceCLIError.notInstalled }
                _ = try await WorkspaceToolRunner.run(proposal("search_email", ["query": "subject:fixture"]), cli: isolated)
                expect(FileManager.default.fileExists(atPath: marker.path), "the admitted isolated CLI constructor keeps its executable with the Mac choice stored")
            } catch { expect(false, "the admitted isolated CLI constructor keeps its executable with the Mac choice stored: \(error)") }
            Settings.shared.googleSource = previousSource
            GoogleSource.forget()
            GoogleSource.macForTesting = mac

            // Unknown outcome: asked of Mail and Calendar, loosely.
            let found = await WorkspaceToolRunner.resolveUnknown(tool: "send_email", arguments: ["to": "x@example.com", "subject": "Sent one"],
                                                                 firedAt: Date().addingTimeInterval(-60), cli: cli)
            let missing = await WorkspaceToolRunner.resolveUnknown(tool: "send_email", arguments: ["to": "x@example.com", "subject": "Ghost"],
                                                                   firedAt: Date().addingTimeInterval(-60), cli: cli)
            expect(found == .found(looksLike: true) && missing == .notFound, "a send that never answered is looked for in Mail's Sent folder, and called \u{201c}looks like\u{201d} at most")
            let uncertainEvent = await WorkspaceToolRunner.resolveUnknown(
                tool: "create_event", arguments: ["title": "Planning", "start": "2026-09-30T15:00:00Z", "end": "2026-09-30T16:00:00Z"],
                firedAt: Date(), calendarEventID: "unconfirmed-prepared-id", cli: cli)
            expect(uncertainEvent == .noReliableRead, "a calendar match without the saved event identifier cannot prove the approved event")
        } catch { expect(false, "tool path cases ran: \(error)") }
    }

    private final class UncertainMac: MacWorkspace, @unchecked Sendable {
        let base: MacAccounts
        var saves = 0
        init(_ base: MacAccounts) { self.base = base }
        func accountTag() async -> String? { await base.accountTag() }
        func searchMail(_ query: MacMailQuery) async throws -> [MacMailSummary] { try await base.searchMail(query) }
        func readMail(ref: String) async throws -> MacMailMessage { try await base.readMail(ref: ref) }
        func compose(_ request: MacComposeRequest) async throws -> MacComposeResult { try await base.compose(request) }
        func findComposed(_ request: MacComposeRequest, since: Date) async throws -> Bool { try await base.findComposed(request, since: since) }
        func agenda(from: Date, to: Date) async throws -> [MacAgendaItem] { try await base.agenda(from: from, to: to) }
        func createEvent(_ draft: MacEventDraft) async throws -> MacEventResult {
            saves += 1
            throw WorkspaceCLIError.timedOut(60)
        }
        func findEvent(_ draft: MacEventDraft) async throws -> Bool { try await base.findEvent(draft) }
    }

    // MARK: - The executor call site

    private static func executorCases(work: URL, _ expect: Expect) async {
        do {
            let fixture = try Fixture.make(in: work, name: "executor")
            let script = FakeScript()
            let calendar = FakeCalendar()
            calendar.calendarList = [googleCalendar]
            let mac = MacAccounts(mailRoot: fixture.mailRoot, calendar: calendar, script: script)
            let cli = NeverCLI()
            let oldCLI = AgentToolExecutor.workspaceCLIForTesting, oldPolicy = AgentToolExecutor.policyOverrideForTesting
            AgentToolExecutor.workspaceCLIForTesting = cli
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            GoogleSource.macForTesting = mac
            defer {
                AgentToolExecutor.workspaceCLIForTesting = oldCLI; AgentToolExecutor.policyOverrideForTesting = oldPolicy
                GoogleSource.macForTesting = nil
            }

            // A read through the executor, with the Mac as the source.
            let read = try await AgentToolExecutor.run("search_email", arguments: ["query": "from:bob"], policy: .selfTest, autoApproveReads: true)
            expect(read.summary.contains("bob@example.com") && cli.calls.isEmpty, "the executor answers a mail read from this Mac and never calls gws")

            // An approved send whose script times out: "not sure", with a read behind it, and never run twice.
            let send = AgentProposal(id: UUID().uuidString, meetingID: UUID(), tool: "send_email",
                                     arguments: ["to": "x@example.com", "subject": "Does it go", "body": "Hi"], rationale: "",
                                     accountTag: nil, startsAt: nil)
            script.result = .failure(WorkspaceCLIError.timedOut(60))
            let result = try await AgentToolExecutor.run(send, policy: .selfTest, approvedByUser: true)
            expect(result.outcomeUnknown && result.summary.contains("not sure") && script.calls.count == 1,
                   "an approved send that never answers is \u{201c}not sure\u{201d}, with one read behind it and no second send: \(result.summary)")

            let reviewedTag = await mac.accountTag()
            var reviewedSend = send
            reviewedSend.accountTag = reviewedTag
            for identity in ["mail-account-2\tother@example.com", "mail-account-1\treplacement@example.com"] {
                script.identity = identity
                script.result = .success(WorkspaceCLIOutput(standardOutput: Data("ok".utf8), standardError: "", exitCode: 0))
                let before = script.calls.count
                do {
                    _ = try await AgentToolExecutor.run(reviewedSend, policy: .selfTest, approvedByUser: true)
                    expect(false, "a reviewed send refuses a changed Mail sender")
                } catch {
                    expect(script.calls.count == before, "a changed Mail sender is refused before any compose or send")
                }
            }
            script.identity = "mail-account-1\tme@example.com"
            let uncertainMac = UncertainMac(mac)
            GoogleSource.macForTesting = uncertainMac
            do {
                let unknown = try await AgentToolExecutor.run("create_event", arguments: ["title": "Uncertain", "start": "2026-10-05T10:00:00Z", "end": "2026-10-05T11:00:00Z"],
                    policy: .selfTest, permissionAlreadyGranted: true)
                expect(unknown.outcomeUnknown && unknown.reference == nil && unknown.verification == nil,
                    "a normal prepared Mac calendar error stays uncertain without a fabricated Google resource ID")
                expect(uncertainMac.saves == 1, "an uncertain Mac calendar save is never repeated")
                let receipt = ActionReceiptStore.shared.receipts.last { $0.intent.verb == "create_event" }
                expect(receipt?.status == .outcomeUnknown && receipt?.artifacts.isEmpty == true && receipt?.preparedAction != nil,
                    "the actual prepared Mac calendar receipt retains uncertainty and no invented resource artifact")
            } catch { expect(false, "prepared Mac calendar uncertainty reaches the result consumer: \(error)") }
            GoogleSource.macForTesting = mac

            // Automation denied: a plain failure, and the person is told which switch.
            script.result = .success(WorkspaceCLIOutput(standardOutput: Data(), standardError: "Not authorized to send Apple events to Mail. (-1743)", exitCode: 1))
            do {
                _ = try await AgentToolExecutor.run(send, policy: .selfTest, approvedByUser: true)
                expect(false, "a denied send is an error")
            } catch {
                expect(error.localizedDescription.contains("Automation") && script.calls.count >= 2, "a denied send says which switch to flip: \(error.localizedDescription)")
            }
        } catch { expect(false, "executor cases ran: \(error)") }
    }
}
