import Foundation

/// Where "my Google account" comes from (PL-09, owner decision 2026-10-04).
///
/// **`thisMac` is the default.** The person's Google account is already on the Mac
/// (System Settings ▸ Internet Accounts), so mail and calendar are read from what the Mac
/// already holds and nothing is signed in again: no client, no key, no browser round trip.
/// `googleSignIn` is the opt-in backup — Google's own page in the browser (the app's own
/// client) or the person's own `gws` setup — and goes through the one `GoogleWorkspaceCLI`
/// runner exactly as before. Composio is a third, separate way and stays an MCP gateway.
///
/// The choice lives in `Settings.googleSource` (nil until the person picks one). Nothing
/// asks them to choose: an unset choice resolves from facts — an existing `gws` sign-in keeps
/// working, anything else is this Mac.
///
/// **Docs, Sheets, Slides, Drive, Tasks and Forms are not on the Mac.** They need Google's own
/// API, which is the sign-in. So with `thisMac` chosen, mail and calendar come from the Mac and
/// those come from Google's sign-in when the person has made one.
enum GoogleSource: String, Sendable, CaseIterable {
    case thisMac
    case googleSignIn

    /// The word `WorkspaceAuthState.signedIn(method:)` carries for this source. It is how
    /// the manifest, the executor and the first-use consent tell the two apart without a new
    /// type travelling beside the one every screen already reads.
    static let macMethod = "your Google account on this Mac"

    static func isThisMac(_ state: WorkspaceAuthState) -> Bool {
        if case .signedIn(let method) = state { return method == macMethod }
        return false
    }

    /// The choice in force. Pure, so a test can read every row.
    static func effective(stored: GoogleSource?, gwsSignedIn: Bool) -> GoogleSource {
        if let stored { return stored }
        return gwsSignedIn ? .googleSignIn : .thisMac
    }

    /// What `effective` resolved to the last time it had to ask `gws`, so a tool call does not
    /// spawn a probe each time. Thirty seconds, like the status the Settings pane shows.
    private static let cache = EffectiveCache()

    static func effective(cli: GoogleWorkspaceCLI = .shared) async -> GoogleSource {
        let (stored, fixture) = await MainActor.run { (Settings.shared.googleSource, macForTesting != nil) }
        if let stored { return stored }
        // A self-test answers from its fixture and never asks the owner's `gws`.
        if SelfTest.isRunning { return fixture ? .thisMac : .googleSignIn }
        if let cached = cache.value() { return cached }
        let gws = await cli.authState().isSignedIn
        let resolved = effective(stored: nil, gwsSignedIn: gws)
        cache.set(resolved)
        return resolved
    }

    /// A change of choice, a sign-in or a sign-out makes the next call look again.
    static func forget() { cache.clear() }

    /// Is Google connected, how, and what the manifest must not promise.
    struct Status: Sendable, Equatable {
        let state: WorkspaceAuthState
        /// Tool id to the one sentence that says why it can't run yet.
        let gaps: [String: String]
    }

    /// The one producer of "is Google connected, and how". `AgentService`, the connect card,
    /// the first-use consent and the permissions row all read this, so they cannot disagree.
    static func status(cli: GoogleWorkspaceCLI = .shared) async -> Status {
        let source = await effective(cli: cli)
        let workspace = await cli.authState()
        switch source {
        case .googleSignIn:
            return Status(state: workspace, gaps: [:])
        case .thisMac:
            let setup = await MacAccounts.shared.setup()
            let state: WorkspaceAuthState = setup.accountFound ? .signedIn(method: macMethod) : .signedOut
            var gaps = setup.gaps()
            if !workspace.isSignedIn {
                for tool in googleOnlyTools { gaps[tool] = needsGoogleSignInSentence(for: "") }
            }
            return Status(state: state, gaps: gaps)
        }
    }

    static func authState(cli: GoogleWorkspaceCLI = .shared) async -> WorkspaceAuthState {
        await status(cli: cli).state
    }

    static let allTools = Array(macTools) + googleOnlyTools
    static let googleOnlyTools = ["find_drive_files", "upload_to_drive", "read_doc", "create_doc", "append_doc"]

    /// The same gap, when what is missing is the whole sign-in rather than one permission.
    private static func needsGoogleSignInSentence(for _: String) -> String {
        "Google Docs and Drive need Google\u{2019}s own sign-in. Press \u{201c}Connect Google Docs, Sheets and Drive too\u{201d} in Settings \u{25B8} Workspace."
    }

    /// The account tag for the source in force, so an approval card notices the account moved.
    static func accountTag(cli: GoogleWorkspaceCLI = .shared) async -> String? {
        switch await effective(cli: cli) {
        case .thisMac: return await MacAccounts.shared.accountTag()
        case .googleSignIn: return await cli.accountTag()
        }
    }

    /// The Mac's own mail and calendar, when this is the source in force and the runner in hand
    /// is the real one. A fixture runner (a fake `WorkspaceCLIRunning`) keeps meaning "run these
    /// commands", so every existing self-test still exercises the `gws` path it was written for.
    @MainActor static var macForTesting: (any MacWorkspace)?

    static func macWorkspace(forTool tool: String, cli: any WorkspaceCLIRunning) async -> (any MacWorkspace)? {
        guard macTools.contains(tool) else { return nil }
        if SelfTest.isRunning, let fixture = await MainActor.run(body: { macForTesting }) { return fixture }
        guard let realCLI = cli as? GoogleWorkspaceCLI,
              !realCLI.hasIsolatedTestingExecutable,
              await effective(cli: realCLI) == .thisMac else { return nil }
        return MacAccounts.shared
    }

    /// The seven tools this Mac can answer. The rest (Drive, Docs) are Google's.
    static let macTools: Set<String> = [
        "search_email", "read_email", "draft_email", "send_email", "reply_email",
        "get_agenda", "create_event",
    ]

    private final class EffectiveCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (GoogleSource, Date)?
        func value() -> GoogleSource? {
            lock.withLock {
                guard let stored, Date().timeIntervalSince(stored.1) < 30 else { return nil }
                return stored.0
            }
        }
        func set(_ source: GoogleSource) { lock.withLock { stored = (source, Date()) } }
        func clear() { lock.withLock { stored = nil } }
    }
}

// MARK: - Plain failures

/// Why this Mac could not answer, in a person's words. Every case says what to do next, and
/// every one of them except `.scriptFailed` happens **before** anything is sent or created —
/// which is the fact `ActionRuntime.status(forThrown:)` reads (P1-21): an error after Mail was
/// told to send is "not sure", never "failed", so a person is not invited to send twice.
enum MacWorkspaceError: LocalizedError, Equatable {
    case needsFullDiskAccess
    case noMailAccount
    case needsCalendarAccess
    case noGoogleCalendar
    case cannotInvite
    /// Calendar refused to save the event, so nothing was added.
    case couldNotSave
    case automationDenied
    case messageNotFound
    case unsupportedSearch(String)
    case cannotRead(String)
    /// Mail was told to do it and answered with an error, or with nothing readable.
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .needsFullDiskAccess:
            "To read your mail, Next Notes needs Full Disk Access. Switch it on for Next Notes in "
                + "System Settings \u{25B8} Privacy & Security \u{25B8} Full Disk Access."
        case .noMailAccount:
            "I couldn\u{2019}t find your Google account in Mail on this Mac. Add it in System Settings "
                + "\u{25B8} Internet Accounts, with Mail switched on."
        case .needsCalendarAccess:
            "Next Notes isn\u{2019}t allowed to see your calendar yet. Allow it in System Settings "
                + "\u{25B8} Privacy & Security \u{25B8} Calendars."
        case .noGoogleCalendar:
            "I couldn\u{2019}t find a Google calendar on this Mac to put that on, so I didn\u{2019}t add it. "
                + "Add your Google account in System Settings \u{25B8} Internet Accounts with Calendars switched on."
        case .cannotInvite:
            "I can\u{2019}t invite people from the calendars on this Mac. Nothing was added. I can add the "
                + "event without inviting anyone, or you can connect Google\u{2019}s own sign-in in Settings to send invitations."
        case .couldNotSave:
            "Calendar wouldn\u{2019}t save that event, so nothing was added."
        case .automationDenied:
            "Next Notes isn\u{2019}t allowed to control Mail yet. Allow it in System Settings \u{25B8} Privacy & "
                + "Security \u{25B8} Automation. Nothing was sent."
        case .messageNotFound:
            "I couldn\u{2019}t find that message in Mail any more. Search again, then use one of the numbers it prints."
        case .unsupportedSearch(let what):
            "On this Mac I can search mail by sender, subject, date, folder and unread. Try again without \(what)."
        case .cannotRead(let reason):
            "I couldn\u{2019}t read your mail on this Mac: \(reason)"
        case .scriptFailed:
            "Mail didn\u{2019}t confirm that it went through."
        }
    }

    /// Does this error prove nothing was sent or created? See the type's comment.
    var outcomeIsKnown: Bool {
        if case .scriptFailed = self { return false }
        return true
    }
}

// MARK: - What the Mac can answer

/// A mail search, already reduced from Gmail's grammar to what Mail's local index can answer.
struct MacMailQuery: Sendable, Equatable {
    enum Folder: String, Sendable, Equatable { case inbox, sent, drafts }
    var folder: Folder = .inbox
    var from: [String] = []
    var subject: [String] = []
    /// Free words: matched against sender, subject and the short preview Mail keeps.
    var text: [String] = []
    var after: Date?
    var before: Date?
    var unreadOnly = false
    var limit = 10

    init() {}

    /// Reads a (normalised) Gmail query. What Mail's index cannot answer is **refused by name**
    /// rather than quietly dropped: a search that ignored `label:` would answer a different
    /// question and read as a confident one.
    init(gmail query: String, limit: Int = 10, now: Date = Date(), calendar: Calendar = .current) throws {
        self.limit = limit
        for token in WorkspaceToolRunner.GmailQuery.tokens(of: query) {
            if token.hasPrefix("-") { throw MacWorkspaceError.unsupportedSearch("\u{201c}\(token)\u{201d}") }
            guard let colon = token.firstIndex(of: ":"), !token.hasPrefix("\"") else {
                let word = Self.unquoted(token)
                if !word.isEmpty { text.append(word) }
                continue
            }
            let name = String(token[..<colon]).lowercased()
            let value = Self.unquoted(String(token[token.index(after: colon)...]))
            switch name {
            case "in":
                switch value.lowercased() {
                case "inbox": folder = .inbox
                case "sent": folder = .sent
                case "drafts", "draft": folder = .drafts
                default: throw MacWorkspaceError.unsupportedSearch("\u{201c}in:\(value)\u{201d}")
                }
            case "from": from.append(value)
            case "subject": subject.append(value)
            case "is":
                guard value.lowercased() == "unread" else {
                    throw MacWorkspaceError.unsupportedSearch("\u{201c}is:\(value)\u{201d}")
                }
                unreadOnly = true
            case "after", "before":
                guard let date = Self.day(value, calendar: calendar) else {
                    throw MacWorkspaceError.unsupportedSearch("\u{201c}\(name):\(value)\u{201d}")
                }
                if name == "after" { after = date } else { before = date }
            case "newer_than", "older_than":
                guard let date = Self.ago(value, from: now, calendar: calendar) else {
                    throw MacWorkspaceError.unsupportedSearch("\u{201c}\(name):\(value)\u{201d}")
                }
                if name == "newer_than" { after = date } else { before = date }
            default:
                throw MacWorkspaceError.unsupportedSearch("\u{201c}\(name):\u{201d}")
            }
        }
    }

    private static func unquoted(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)
    }

    /// `YYYY/MM/DD` (what `GmailQuery.normalize` writes) or `YYYY-MM-DD`, at the start of that day.
    private static func day(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.replacingOccurrences(of: "-", with: "/").split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// `2d`, `3h`, `1m` (months), `1y`.
    private static func ago(_ value: String, from now: Date, calendar: Calendar) -> Date? {
        guard let unit = value.last, let count = Int(value.dropLast()), count >= 0 else { return nil }
        let component: Calendar.Component
        switch unit.lowercased() {
        case "h": component = .hour
        case "d": component = .day
        case "m": component = .month
        case "y": component = .year
        default: return nil
        }
        return calendar.date(byAdding: component, value: -count, to: now)
    }
}

struct MacMailSummary: Sendable, Equatable {
    /// Opaque, `mac-<number>`. Never shown; `MailReferenceCache` maps a printed number to it.
    let ref: String
    let from: String
    let subject: String
    let date: Date?
    let snippet: String
    let isUnread: Bool
}

struct MacMailMessage: Sendable, Equatable {
    let from: String
    let date: Date?
    let subject: String
    /// Text only, already bounded. Empty when Mail has not downloaded the body yet.
    let body: String
    let bodyIsAvailable: Bool
}

struct MacComposeRequest: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case draft, send, reply(ref: String) }
    var kind: Kind
    var to: [String]
    var subject: String
    var body: String
    var expectedAccountTag: String? = nil
}

struct MacComposeResult: Sendable, Equatable {
    /// Whether a read-back found the message in Mail's own Drafts or Sent afterwards.
    let confirmedInMail: Bool
}

struct MacAgendaItem: Sendable, Equatable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendar: String
}

struct MacEventDraft: Sendable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var notes: String
}

struct MacEventResult: Sendable, Equatable {
    /// The actual identifier returned by EventKit, retained for the existing receipt consumer.
    var reference: String? = nil
    /// The event existed already, exactly as reviewed.
    let alreadyThere: Bool
    /// Read back from the calendar after saving, with the same title, start and end.
    let verified: Bool
}

/// Everything the agent's mail and calendar tools need from the Mac's own accounts.
///
/// One seam, so `WorkspaceToolRunner` can run the same tool ids against the Mac or against
/// `gws`, and a self-test can answer the whole tool path with no Mail, no calendar and no grant.
protocol MacWorkspace: Sendable {
    /// A tag for the account, so an approval card notices the account moved. Never the address.
    func accountTag() async -> String?
    func searchMail(_ query: MacMailQuery) async throws -> [MacMailSummary]
    func readMail(ref: String) async throws -> MacMailMessage
    /// Drafts, sends and replies go through Mail itself; the approval card has already run.
    func compose(_ request: MacComposeRequest) async throws -> MacComposeResult
    /// "Is it there?" for a write that never answered. True only for a real find.
    func findComposed(_ request: MacComposeRequest, since: Date) async throws -> Bool
    func agenda(from: Date, to: Date) async throws -> [MacAgendaItem]
    func createEvent(_ draft: MacEventDraft) async throws -> MacEventResult
    func findEvent(_ draft: MacEventDraft) async throws -> Bool
}
