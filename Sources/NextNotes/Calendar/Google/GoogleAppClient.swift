import Foundation

/// The Google permissions Next Notes asks for, in one place.
///
/// **One list, one consent page** (owner decision, 2026-10-04): the person approves the whole
/// Workspace set once and the agent never sends them back to Google for another permission.
/// The same scopes are declared on the Cloud project `next-notes-mac`, so a scope added here
/// and not there is refused by Google; change both together.
///
/// Gmail's, Drive's and Contacts' scopes are *restricted* or *sensitive*: before this build is
/// given to the public Google has to verify the app, and the restricted ones (Gmail and full
/// Drive) may also need a yearly security assessment when restricted data is accessed from
/// or through a third-party server, including when the app can do so. Until verification,
/// the project is in Testing mode and the people added to it can sign in.
///
/// Google lets a person untick boxes on the consent page, so what comes back is recorded and
/// each capability checks its own scope (`GoogleCapability`); nothing assumes the whole set.
enum GoogleScopes {
    private static let base = "https://www.googleapis.com/auth/"
    /// Read, labels, drafts and send.
    static let mail = base + "gmail.modify"
    static let calendar = base + "calendar"
    static let drive = base + "drive"
    static let documents = base + "documents"
    static let spreadsheets = base + "spreadsheets"
    static let presentations = base + "presentations"
    static let tasks = base + "tasks"
    static let contacts = base + "contacts"
    static let forms = base + "forms.body"
    /// What the older, calendar-only sign-in asked for. Still read, never asked for.
    static let legacyCalendar = base + "calendar.readonly"
    static let legacyCalendarEvents = base + "calendar.events"

    /// What "Connect your Google account" asks for: every scope, in one request.
    static let connect: [String] = [
        mail, calendar, drive, documents, spreadsheets, presentations, tasks, contacts, forms,
    ]

    /// The combined mail/calendar status check. Other capabilities remain usable
    /// independently when their own permission was granted.
    static let required: [String] = [mail, calendar]

    /// Whether `granted` is enough for the agent's mail and calendar tools.
    static func coversWorkspace(_ granted: Set<String>) -> Bool {
        Set(required).isSubset(of: granted)
    }

    /// Whether `granted` is enough to read the calendar (the older token or the new one).
    static func coversCalendar(_ granted: Set<String>) -> Bool {
        granted.contains(calendar) || granted.contains(legacyCalendarEvents)
            || granted.contains(legacyCalendar)
    }
}

/// What a person can ask the agent to do with Google, each backed by exactly one scope.
///
/// The manifest asks `GoogleScopes`-level questions through this type, so a box unticked on
/// Google's page turns into one plain sentence ("Google Docs needs one more permission")
/// instead of a tool that fails halfway.
enum GoogleCapability: String, CaseIterable, Sendable {
    case mail, calendar, drive, documents, spreadsheets, presentations, tasks, contacts, forms

    var scope: String {
        switch self {
        case .mail: GoogleScopes.mail
        case .calendar: GoogleScopes.calendar
        case .drive: GoogleScopes.drive
        case .documents: GoogleScopes.documents
        case .spreadsheets: GoogleScopes.spreadsheets
        case .presentations: GoogleScopes.presentations
        case .tasks: GoogleScopes.tasks
        case .contacts: GoogleScopes.contacts
        case .forms: GoogleScopes.forms
        }
    }

    /// The words a person would use.
    var phrase: String {
        switch self {
        case .mail: "your mail"
        case .calendar: "your calendar"
        case .drive: "Google Drive"
        case .documents: "Google Docs"
        case .spreadsheets: "Google Sheets"
        case .presentations: "Google Slides"
        case .tasks: "Google Tasks"
        case .contacts: "your contacts"
        case .forms: "Google Forms"
        }
    }

    /// The capability a Workspace tool needs. Nil for a tool that is not a Google one.
    static func needed(byTool id: String) -> GoogleCapability? {
        switch id {
        case "search_email", "read_email", "draft_email", "send_email", "reply_email": .mail
        case "get_agenda", "create_event": .calendar
        case "find_drive_files", "upload_to_drive": .drive
        case "read_doc", "create_doc", "append_doc": .documents
        default: nil
        }
    }

    static func needed(byArguments arguments: [String]) -> GoogleCapability? {
        switch arguments.first {
        case "gmail": .mail
        case "calendar": .calendar
        case "drive": .drive
        case "docs": .documents
        case "sheets": .spreadsheets
        case "slides": .presentations
        case "tasks": .tasks
        case "people": .contacts
        case "forms": .forms
        default: nil
        }
    }
    var permissionSentence: String {
        "\(phrase.prefix(1).uppercased() + String(phrase.dropFirst())) needs one more permission. Connect Google again in Settings and leave its box ticked."
    }
    func isGranted(by granted: Set<String>, readOnly: Bool = false) -> Bool {
        if granted.contains(scope) { return true }
        // A calendar-only token from before the full set.
        if self == .calendar {
            return granted.contains(GoogleScopes.legacyCalendarEvents)
                || (readOnly && granted.contains(GoogleScopes.legacyCalendar))
        }
        return false
    }
}

/// The one place the Google OAuth client comes from.
///
/// The person never sees, pastes or creates a client. A build ships one, in `Info.plist`
/// (`NextNotesGoogleClientID` / `NextNotesGoogleClientSecret`). A desktop client's secret is
/// public by construction — it ships inside every copy of the app — but Google's token
/// endpoint still asks for it.
///
/// **Placeholder, on purpose.** The shipped value is `NEXT_NOTES_GOOGLE_CLIENT_ID_NOT_REGISTERED`
/// until the owner registers a project-owned client with Google. Anything that is not a real
/// `….apps.googleusercontent.com` id reads as "not configured", and the app then says so in
/// plain words and offers no button that cannot work (fail closed).
///
/// An advanced person's own client (`Settings.googleClientID`, imported from a file) wins, so
/// existing setups keep working.
struct GoogleAppClient: Equatable, Sendable {
    enum Source: Equatable, Sendable { case app, own }

    let clientID: String
    let clientSecret: String
    let source: Source

    static let plistIDKey = "NextNotesGoogleClientID"
    static let plistSecretKey = "NextNotesGoogleClientSecret"
    static let placeholderID = "NEXT_NOTES_GOOGLE_CLIENT_ID_NOT_REGISTERED"
    private static let overrideIDKey = "googleClientID"
    private static let overrideSecretKey = "googleClientSecret"

    /// A real Google client id looks like this; the placeholder and blanks do not.
    static func isRegisteredID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".apps.googleusercontent.com") && trimmed.count > 30
    }

    static func resolve(defaults: UserDefaults, bundle: Bundle) -> GoogleAppClient? {
        resolve(defaults: defaults, info: { bundle.object(forInfoDictionaryKey: $0) })
    }

    /// `info` reads one `Info.plist` key; a test passes the shipped file's own dictionary.
    static func resolve(defaults: UserDefaults, info: (String) -> Any?) -> GoogleAppClient? {
        let ownID = (defaults.string(forKey: overrideIDKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !ownID.isEmpty {
            return GoogleAppClient(
                clientID: ownID,
                clientSecret: defaults.string(forKey: overrideSecretKey) ?? "",
                source: .own)
        }
        let id = (info(plistIDKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRegisteredID(id) else { return nil }
        return GoogleAppClient(
            clientID: id,
            clientSecret: info(plistSecretKey) as? String ?? "",
            source: .app)
    }

    /// Thread-safe: reads defaults and the bundle, never `Settings`, so the Workspace runner
    /// can ask from its own actor without hopping to the main one.
    static var current: GoogleAppClient? { resolve(defaults: SelfTest.isRunning ? SelfTestHarnessDefaults.suite : .standard, bundle: .main) }

    /// What the person is told when this build has no client.
    static let unavailableMessage =
        "Connecting Google isn\u{2019}t switched on in this copy of Next Notes yet."
}
