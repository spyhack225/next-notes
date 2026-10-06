import Foundation

/// Where setting up "my Google account on this Mac" has got to, and the one thing to do next.
///
/// A value, so the Settings card, the permissions row and a self-test all read the same answer
/// and the card can never offer a step that is not the next one. Every step is a single plain
/// action with the reason beside it.
struct MacSetup: Sendable, Equatable {
    var calendar: MacCalendarAccess
    var hasGoogleCalendar: Bool
    var mail: MailDatabase.Access
    var hasGoogleMail: Bool

    enum Step: Sendable, Equatable {
        /// Everything this source reads is reachable.
        case ready
        /// Ask the system for calendar access (one prompt).
        case allowCalendar
        /// Calendar access was refused; only System Settings can change it.
        case openCalendarSettings
        /// Calendar is readable and holds no Google calendar: the account is not on this Mac.
        case addAccount
        /// Mail can't be read until Full Disk Access is on. The same grant covers Messages.
        case allowMailAccess
        /// The account is on the Mac, but Mail is not switched on for it.
        case turnOnMail
    }

    /// A Google account is on this Mac when either place that would show it does.
    var accountFound: Bool { hasGoogleCalendar || hasGoogleMail }

    var nextStep: Step {
        switch calendar {
        case .notAsked: return .allowCalendar
        case .denied: return .openCalendarSettings
        case .granted: break
        }
        guard hasGoogleCalendar else {
            // No Google calendar. If Mail holds a Google account, the account is here and only
            // its calendar is switched off, which is not worth a step of its own: the calendar
            // tools say so when asked.
            if hasGoogleMail { return .ready }
            return mail == .needsFullDiskAccess ? .allowMailAccess : .addAccount
        }
        switch mail {
        case .needsFullDiskAccess: return .allowMailAccess
        case .readable: return hasGoogleMail ? .ready : .turnOnMail
        case .noMailData: return .turnOnMail
        case .unreadable: return .ready
        }
    }

    /// The tools this setup cannot answer yet, each with the one sentence that says why.
    /// Reaches the manifest, so "what can you do" is never a list that overstates.
    func gaps() -> [String: String] {
        var gaps: [String: String] = [:]
        let mailSentence: String? = switch (mail, hasGoogleMail) {
        case (.needsFullDiskAccess, _):
            "Reading your mail needs Full Disk Access for Next Notes in System Settings \u{25B8} Privacy & Security."
        case (.readable, false), (.noMailData, _):
            "Your Google account isn\u{2019}t switched on for Mail on this Mac. Turn it on in System Settings \u{25B8} Internet Accounts."
        case (.unreadable, _):
            "Mail on this Mac couldn\u{2019}t be read just now."
        default: nil
        }
        let calendarSentence: String? = switch (calendar, hasGoogleCalendar) {
        case (.granted, true): nil
        case (.granted, false): "Your Google account isn\u{2019}t switched on for Calendars on this Mac. Turn it on in System Settings \u{25B8} Internet Accounts."
        default: "Next Notes isn\u{2019}t allowed to see your calendar yet. Allow it in System Settings \u{25B8} Privacy & Security \u{25B8} Calendars."
        }
        for tool in ["search_email", "read_email", "draft_email", "send_email", "reply_email"] {
            if let mailSentence { gaps[tool] = mailSentence }
        }
        for tool in ["get_agenda", "create_event"] {
            if let calendarSentence { gaps[tool] = calendarSentence }
        }
        return gaps
    }
}

/// Mail and calendar from the Google account this Mac already holds.
///
/// Reads are local: Mail's own index for mail, EventKit for the calendar. Writes go through
/// the apps that own them — Mail by script, Calendar through EventKit — and every one of them
/// is a tool that already waits for the person's approval before it gets here.
final class MacAccounts: MacWorkspace, Sendable {
    /// The real Mac under the app; an inert one under a self-test, so no test run reads the
    /// owner's mail or calendar by accident. `--selftest-mac-accounts-live` is the one that does.
    static let shared: MacAccounts = {
        if SelfTest.isRunning, SelfTest.requested != "--selftest-mac-accounts-live" {
            return MacAccounts(
                mailRoot: FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesNoMail-\(ProcessInfo.processInfo.processIdentifier)"),
                calendar: InertMacCalendar(), script: InertScriptRunner())
        }
        return MacAccounts(mailRoot: MailDatabase.defaultMailRoot, calendar: EventKitMacCalendar.shared, script: OSAScriptRunner())
    }()

    private let handle: MailHandle
    private let mailRoot: URL
    private let calendar: any MacCalendarStore
    private let script: any MailScriptRunning
    private let now: @Sendable () -> Date

    init(
        mailRoot: URL,
        calendar: any MacCalendarStore,
        script: any MailScriptRunning,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.mailRoot = mailRoot
        self.handle = MailHandle(root: mailRoot)
        self.calendar = calendar
        self.script = script
        self.now = now
    }

    // MARK: - Setup

    func setup() async -> MacSetup {
        let access = await calendar.access()
        let calendars = access == .granted ? await calendar.calendars() : []
        let mail = MailDatabase.probe(mailRoot: mailRoot)
        var hasGoogleMail = false
        if mail == .readable, let database = try? await handle.database() {
            hasGoogleMail = (try? await database.hasGoogleAccount()) ?? false
        }
        return MacSetup(calendar: access, hasGoogleCalendar: calendars.contains { $0.looksGoogle },
                        mail: mail, hasGoogleMail: hasGoogleMail)
    }

    /// The same answer `WorkspaceAuthState` gives for the other source, so every screen that
    /// reads "is Google connected" reads this one for this Mac.
    func authState() async -> WorkspaceAuthState {
        await setup().accountFound ? .signedIn(method: GoogleSource.macMethod) : .signedOut
    }

    func requestCalendarAccess() async -> Bool { await calendar.requestAccess() }

    // MARK: - MacWorkspace

    func accountTag() async -> String? {
        guard let sender = try? await mailSender() else { return nil }
        return GoogleWorkspaceCLI.tag(for: sender.id + "\t" + sender.address)
    }

    func searchMail(_ query: MacMailQuery) async throws -> [MacMailSummary] {
        try await handle.database().search(query)
    }

    func readMail(ref: String) async throws -> MacMailMessage {
        try await handle.database().read(ref: ref)
    }

    func compose(_ request: MacComposeRequest) async throws -> MacComposeResult {
        // A reply is found before Mail is told anything: a message that is not there is a
        // refusal that sends nothing.
        var target: (mailbox: String, id: Int64)?
        if case .reply(let ref) = request.kind { target = try await handle.database().replyTarget(ref: ref) }
        let sender = try await mailSender()
        if let expected = request.expectedAccountTag,
           expected != GoogleWorkspaceCLI.tag(for: sender.id + "\t" + sender.address) {
            throw AgentError.permissionDenied(ApprovalFreshness.Freshness.accountChanged.refusal)
        }
        let started = now()
        let output = try await script.run(
            arguments: MailScripting.arguments(for: request, replyTarget: target,
                                               senderID: sender.id, senderAddress: sender.address),
            timeout: MailScripting.timeout)
        try MailScripting.interpret(output)
        // Read back immediately; Mail indexing must not add fixed sleeps to the user's turn.
        // An absent read-back stays unverified, so a delayed index cannot invite another send.
        if (try? await findComposed(request, since: started)) == true {
            return MacComposeResult(confirmedInMail: true)
        }
        return MacComposeResult(confirmedInMail: false)
    }

    /// The script selects Mail's real Google sender, not a calendar with a similar title.
    /// Selection remains local to this call; the write script rechecks its exact id/address.
    private func mailSender() async throws -> (id: String, address: String) {
        let output = try await script.run(arguments: MailScripting.accountArguments, timeout: MailScripting.timeout)
        if output.exitCode != 0 { try MailScripting.interpret(output) }
        let parts = output.text.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("@"),
              !parts.contains(where: { $0.contains("\n") || $0.contains("\r") }) else {
            throw MacWorkspaceError.noMailAccount
        }
        return (String(parts[0]), String(parts[1]))
    }

    func findComposed(_ request: MacComposeRequest, since: Date) async throws -> Bool {
        let folder: MacMailQuery.Folder
        var subject = request.subject
        switch request.kind {
        case .draft: folder = .drafts
        case .send: folder = .sent
        case .reply: folder = .sent; subject = ""
        }
        return try await handle.database().containsMessage(subject: subject, folder: folder, since: since)
    }

    func agenda(from: Date, to: Date) async throws -> [MacAgendaItem] {
        guard await calendar.access() == .granted else { throw MacWorkspaceError.needsCalendarAccess }
        return await calendar.agenda(from: from, to: to)
    }

    func createEvent(_ draft: MacEventDraft) async throws -> MacEventResult {
        guard await calendar.access() == .granted else { throw MacWorkspaceError.needsCalendarAccess }
        guard let target = MacGoogle.creationTarget(in: await calendar.calendars()) else { throw MacWorkspaceError.noGoogleCalendar }
        // Only the identifier returned by this save identifies this event. Matching content
        // may belong to a different event and cannot establish a completed approved action.
        let id: String
        do { id = try await calendar.save(draft, calendarID: target.id) } catch { throw MacWorkspaceError.couldNotSave }
        let readBack = await calendar.event(id: id)
        let verified = readBack.map { $0.id == id && !id.isEmpty && $0.calendarID == target.id && Self.same($0, draft) } ?? false
        return MacEventResult(reference: id.isEmpty ? nil : id, alreadyThere: false, verified: verified)
    }

    func findEvent(_ draft: MacEventDraft) async throws -> Bool {
        guard await calendar.access() == .granted else { throw MacWorkspaceError.needsCalendarAccess }
        for google in await calendar.calendars() where google.looksGoogle {
            if Self.contains(draft, in: await calendar.events(calendarID: google.id, from: draft.start.addingTimeInterval(-3_600),
                                                               to: draft.end.addingTimeInterval(3_600))) { return true }
        }
        return false
    }

    private static func same(_ event: MacStoredEvent, _ draft: MacEventDraft) -> Bool {
        event.title == draft.title && event.notes == draft.notes
            && abs(event.start.timeIntervalSince(draft.start)) < 1
            && abs(event.end.timeIntervalSince(draft.end)) < 1
    }

    private static func contains(_ draft: MacEventDraft, in events: [MacStoredEvent]) -> Bool {
        events.contains { same($0, draft) }
    }
}

/// Opens Mail's index when first needed and again after a failure, so a Mac where Full Disk
/// Access is granted later starts working without a relaunch.
private actor MailHandle {
    private let root: URL
    private var opened: MailDatabase?
    init(root: URL) { self.root = root }

    func database() throws -> MailDatabase {
        if let opened { return opened }
        let database = try MailDatabase(mailRoot: root)
        opened = database
        return database
    }
}

/// What `MacAccounts.shared` holds under a self-test: nothing to read and nothing to run.
private struct InertMacCalendar: MacCalendarStore {
    func access() async -> MacCalendarAccess { .denied }
    func requestAccess() async -> Bool { false }
    func calendars() async -> [MacCalendarInfo] { [] }
    func agenda(from: Date, to: Date) async -> [MacAgendaItem] { [] }
    func events(calendarID: String, from: Date, to: Date) async -> [MacStoredEvent] { [] }
    func save(_ draft: MacEventDraft, calendarID: String) async throws -> String { throw MacWorkspaceError.noGoogleCalendar }
    func event(id: String) async -> MacStoredEvent? { nil }
}

private struct InertScriptRunner: MailScriptRunning {
    func run(arguments: [String], timeout: TimeInterval) async throws -> WorkspaceCLIOutput {
        throw MacWorkspaceError.automationDenied
    }
}
