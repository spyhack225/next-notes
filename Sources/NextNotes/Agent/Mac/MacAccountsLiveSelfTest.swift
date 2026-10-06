import Foundation

/// `--selftest-mac-accounts-live` — the one check against a real Mac, and it reads **counts and
/// shapes only**: never a sender, a subject, a snippet, a body, an address or a calendar title,
/// because this line lands in a log file. It sends nothing, drafts nothing and creates nothing.
///
/// It answers the four things the generated fixtures cannot: whether Mail's real index spells
/// its columns the way the reader expects, whether the `.emlx` files are where the reader looks,
/// whether the calendar shows a Google account, and what each of those is told by the grants this
/// process actually holds. Run it through LaunchServices
/// (`Scripts/run-selftest.sh --via-open --selftest-mac-accounts-live`), because the grants belong
/// to the app and not to the shell.
///
/// Without Full Disk Access or calendar access it prints `MAC_ACCOUNTS_LIVE_ABSENT` and says which
/// — never `_OK`, because nothing was read.
@MainActor
enum MacAccountsLiveSelfTest {
    static func run() async -> Bool {
        print("MAC_ACCOUNTS_LIVE: counts only")
        let mac = MacAccounts.shared
        let setup = await mac.setup()
        SelfTest.diagnostic("  calendar access: \(setup.calendar)")
        SelfTest.diagnostic("  google calendar found: \(setup.hasGoogleCalendar)")
        SelfTest.diagnostic("  mail access: \(label(setup.mail))")
        SelfTest.diagnostic("  google mail account found: \(setup.hasGoogleMail)")
        SelfTest.diagnostic("  next step: \(setup.nextStep)")

        var read = 0
        if setup.mail == .readable, setup.hasGoogleMail {
            do {
                let started = Date()
                let inbox = try await mac.searchMail(MacMailQuery(gmail: "in:inbox", limit: 25))
                let seconds = Date().timeIntervalSince(started)
                let withSender = inbox.filter { !$0.from.isEmpty && $0.from != "unknown sender" }.count
                let withSubject = inbox.filter { $0.subject != "(no subject)" }.count
                let withDate = inbox.filter { $0.date != nil }.count
                let withSnippet = inbox.filter { !$0.snippet.isEmpty }.count
                let newestFirst = zip(inbox, inbox.dropFirst()).allSatisfy { ($0.date ?? .distantPast) >= ($1.date ?? .distantPast) }
                SelfTest.diagnostic("  inbox: \(inbox.count) messages in \(String(format: "%.2f", seconds)) s; "
                    + "senders \(withSender), subjects \(withSubject), dates \(withDate), previews \(withSnippet); newest first \(newestFirst)")
                var bodies = 0, available = 0
                for message in inbox.prefix(10) {
                    bodies += 1
                    if let full = try? await mac.readMail(ref: message.ref), full.bodyIsAvailable { available += 1 }
                }
                SelfTest.diagnostic("  message text found for \(available) of \(bodies) newest messages")
                for folder in [MacMailQuery.Folder.sent, .drafts] {
                    var query = MacMailQuery(); query.folder = folder; query.limit = 5
                    let count = (try? await mac.searchMail(query).count).map(String.init) ?? "unreadable"
                    SelfTest.diagnostic("  \(folder.rawValue): \(count) (up to 5)")
                }
                read += inbox.count
            } catch {
                SelfTest.diagnostic("  mail read failed: \(type(of: error))")
                SelfTest.diagnostic("MAC_ACCOUNTS_LIVE_FAILED")
                return false
            }
        }
        if setup.calendar == .granted {
            let day = Calendar.current.startOfDay(for: Date())
            let items = (try? await mac.agenda(from: day, to: day.addingTimeInterval(86_400))) ?? []
            SelfTest.diagnostic("  today: \(items.count) calendar items across every calendar on this Mac")
            read += items.count
        }
        if setup.mail != .readable && setup.calendar != .granted {
            SelfTest.diagnostic("MAC_ACCOUNTS_LIVE_ABSENT: neither mail nor the calendar could be read here (\(label(setup.mail)); calendar \(setup.calendar))")
            return true
        }
        if !setup.accountFound {
            SelfTest.diagnostic("MAC_ACCOUNTS_LIVE_ABSENT: no Google account was found on this Mac")
            return true
        }
        SelfTest.diagnostic("MAC_ACCOUNTS_LIVE_OK: read \(read) items")
        return true
    }

    private static func label(_ access: MailDatabase.Access) -> String {
        switch access {
        case .readable: "readable"
        case .needsFullDiskAccess: "needs Full Disk Access"
        case .noMailData: "no Mail data"
        case .unreadable: "unreadable"
        }
    }
}
