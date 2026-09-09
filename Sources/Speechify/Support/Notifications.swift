import Foundation
import UserNotifications

/// System notifications, and the buttons on them.
///
/// Two so far: "this meeting is about to be recorded", with a way to say no, and "its notes
/// are ready", with a way to read them. Both are real `UNUserNotification`s rather than
/// windows because the whole point is to reach the user in the video call they have already
/// switched to — or in whatever they moved on to twenty minutes after it ended.
///
/// Three categories now, and the island answers the same questions inside the app that
/// these answer outside it — which is why the action identifiers live here rather than
/// inside the scheduler, and why `observe` takes a list of observers rather than one
/// closure. The scheduler and the island both listen; an assignment would have meant one
/// of them silently replacing the other.
@MainActor
final class Notifications {
    static let shared = Notifications()

    /// What a notification button did, once the user pressed it.
    enum Action: Sendable, Equatable {
        case recordNow(meetingID: UUID)
        case skip(meetingID: UUID)
        /// The body was clicked rather than a button.
        case open(meetingID: UUID)
        /// An agent proposal was approved or waved away from the notification. Carries the
        /// proposal's own identifier rather than a meeting's: the meeting is on the
        /// proposal, and the two are not interchangeable.
        case approveProposal(id: String)
        case dismissProposal(id: String)
    }

    /// Everything that wants to hear about a pressed button.
    ///
    /// A list rather than one closure because there are two listeners with different jobs:
    /// the scheduler, which starts or abandons a recording, and the island, which takes the
    /// answered card down. A single assignment meant whichever registered second won.
    private var observers: [(Action) -> Void] = []

    /// Registers a listener for the life of the process. Nothing unregisters — both
    /// listeners are singletons created at launch — so there is no token to hand back.
    func observe(_ observer: @escaping (Action) -> Void) {
        observers.append(observer)
    }

    private let router = NotificationRouter()
    private var isConfigured = false

    private init() {}

    /// The one entry point the delegate calls back into, on the main actor.
    fileprivate func handle(_ action: Action) {
        for observer in observers { observer(action) }
    }

    // MARK: - Setup

    /// Registers the categories and takes over the delegate.
    ///
    /// Must run before the app finishes launching: a notification the user actioned while
    /// the app was closed is delivered immediately at launch, and a delegate installed
    /// afterwards never sees it.
    func configure() {
        guard !isConfigured, let center = Self.center else { return }
        isConfigured = true

        center.delegate = router
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.meetingArmed,
                actions: [
                    UNNotificationAction(
                        identifier: ActionID.recordNow,
                        title: "Record now",
                        options: [.foreground]
                    ),
                    UNNotificationAction(
                        identifier: ActionID.skip,
                        title: "Skip",
                        options: [.destructive]
                    ),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.notesReady,
                actions: [
                    UNNotificationAction(
                        identifier: ActionID.openNotes,
                        title: "Open notes",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: []
            ),
            // Registered before anything posts one. Categories are declared once per
            // launch, and a notification whose category the center has never heard of
            // arrives with no buttons at all — so the agent's category is set up here
            // rather than at the point where Phase 7 starts proposing things.
            UNNotificationCategory(
                identifier: Category.agentProposal,
                actions: [
                    UNNotificationAction(
                        identifier: ActionID.approveProposal,
                        title: "Approve",
                        options: [.foreground]
                    ),
                    UNNotificationAction(
                        identifier: ActionID.dismissProposal,
                        title: "Dismiss",
                        options: [.destructive]
                    ),
                ],
                intentIdentifiers: []
            ),
            // A send is approved on the card that shows the whole message, so this category
            // offers no way to say yes from the banner — only a way to go and read it.
            UNNotificationCategory(
                identifier: Category.agentReview,
                actions: [
                    UNNotificationAction(
                        identifier: ActionID.reviewProposal,
                        title: "Review\u{2026}",
                        options: [.foreground]
                    ),
                    UNNotificationAction(
                        identifier: ActionID.dismissProposal,
                        title: "Dismiss",
                        options: [.destructive]
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    /// Asks once. A refusal is not an error: the scheduler still records, it just does so
    /// without announcing itself.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center = Self.center else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.app.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whether the user has already answered the authorization prompt, for the checklist.
    ///
    /// Asked rather than remembered: the answer can be changed in System Settings at any
    /// time, and a stored copy would say "granted" for a build whose notifications the user
    /// turned off last week.
    func isAuthorized() async -> Bool {
        guard let center = Self.center else { return false }
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    // MARK: - Posting

    /// "Recording <title> in a minute", with Record now / Skip.
    func postMeetingArmed(meeting: Meeting, startsAt start: Date) {
        let content = UNMutableNotificationContent()
        content.title = meeting.title
        content.body = Self.leadDescription(until: start)
        content.categoryIdentifier = Category.meetingArmed
        content.userInfo = [UserInfoKey.meetingID: meeting.id.uuidString]
        content.sound = .default
        post(content, identifier: Self.armedIdentifier(for: meeting.id))
    }

    /// "Notes are ready", with a button that opens them.
    ///
    /// Posted rather than shown in the window because of how long the work takes: a meeting
    /// stops, the Record button comes back, and minutes later the notes exist. By then the
    /// user is somewhere else, and a badge on a window they aren't looking at tells nobody.
    func postNotesReady(meeting: Meeting, model: String?) {
        let content = UNMutableNotificationContent()
        content.title = meeting.title
        content.body = model.map { "Notes written by \($0)." } ?? "Notes are ready."
        content.categoryIdentifier = Category.notesReady
        content.userInfo = [UserInfoKey.meetingID: meeting.id.uuidString]
        post(content, identifier: "meeting-notes-\(meeting.id.uuidString)")
    }

    /// "Speechify would like to send this", with Approve / Dismiss.
    ///
    /// Carries the proposal's id rather than the meeting's, because two proposals for one
    /// meeting are the normal case and the buttons have to answer one of them. The meeting
    /// id rides along so that clicking the body — which is not an approval — still opens the
    /// meeting the proposal belongs to.
    /// - Parameter canApprove: whether the banner may carry an Approve button at all. False
    ///   for anything that speaks in the user's name: the body is one sentence of rationale,
    ///   and approving a message from a card that never showed it is how the wrong email
    ///   gets sent.
    func postAgentProposal(_ proposal: AgentProposal, canApprove: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = proposal.title
        content.body = proposal.rationale
        content.categoryIdentifier = canApprove ? Category.agentProposal : Category.agentReview
        content.userInfo = [
            UserInfoKey.proposalID: proposal.id,
            UserInfoKey.meetingID: proposal.meetingID.uuidString,
        ]
        post(content, identifier: Self.proposalIdentifier(for: proposal.id))
    }

    /// Takes a proposal's notification down once it has been answered anywhere else — the
    /// island, the Actions tab, or the meeting being deleted.
    func withdrawAgentProposal(id: String) {
        guard let center = Self.center else { return }
        let identifier = Self.proposalIdentifier(for: id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Withdraws the armed notification once the question it asks has been answered by
    /// the meeting starting, being skipped, or the window passing.
    func withdrawMeetingArmed(meetingID: UUID) {
        guard let center = Self.center else { return }
        let identifier = Self.armedIdentifier(for: meetingID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func post(_ content: UNNotificationContent, identifier: String) {
        guard let center = Self.center else { return }
        // No trigger: deliver now. The scheduler already decided the moment.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Log.meeting.error("couldn't post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func armedIdentifier(for id: UUID) -> String {
        "meeting-armed-\(id.uuidString)"
    }

    private static func proposalIdentifier(for id: String) -> String {
        "agent-proposal-\(id)"
    }

    private static func leadDescription(until start: Date) -> String {
        let seconds = start.timeIntervalSinceNow
        if seconds <= 5 { return "Speechify is about to start recording." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Speechify will start recording \(formatter.localizedString(for: start, relativeTo: Date()))."
    }

    /// `UNUserNotificationCenter.current()` traps in a process without a bundle identifier
    /// — which is how the executable runs straight out of the build directory. Everything
    /// here degrades to doing nothing rather than taking the app down with it.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    enum Category {
        static let meetingArmed = "meetingArmed"
        static let notesReady = "notesReady"
        static let agentProposal = "agentProposal"
        /// The same question, without an Approve button. Used for anything that would speak
        /// in the user's name, where the only honest answer from a banner is "come and look".
        static let agentReview = "agentReview"
    }

    enum ActionID {
        static let recordNow = "meeting.recordNow"
        static let skip = "meeting.skip"
        static let openNotes = "notes.open"
        static let approveProposal = "agent.approve"
        static let dismissProposal = "agent.dismiss"
        static let reviewProposal = "agent.review"
    }

    enum UserInfoKey {
        static let meetingID = "meetingID"
        static let proposalID = "proposalID"
    }
}

/// The `UNUserNotificationCenterDelegate`.
///
/// Separate from `Notifications` because the delegate callbacks are not main-actor
/// isolated — the center calls them on whatever thread it likes — while everything they
/// steer (the scheduler, the meeting controller, the window) is. Each callback therefore
/// copies the identifiers it needs out of the response and hops.
private final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Shown even when Speechify is frontmost: the user is usually looking at the
        // conferencing app, and "frontmost" is not the same as "watching this window".
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let identifier = response.actionIdentifier
        let proposalID = userInfo[Notifications.UserInfoKey.proposalID] as? String
        let meetingID = (userInfo[Notifications.UserInfoKey.meetingID] as? String)
            .flatMap(UUID.init(uuidString:))

        let action: Notifications.Action? = switch identifier {
        case Notifications.ActionID.recordNow: meetingID.map { .recordNow(meetingID: $0) }
        case Notifications.ActionID.skip: meetingID.map { .skip(meetingID: $0) }
        // Opening the notes and clicking the body are the same thing: both mean "show me
        // this meeting", which is what the one action the app has does.
        case Notifications.ActionID.openNotes: meetingID.map { .open(meetingID: $0) }
        // "Review…" is the same thing again: the proposal is answered in the meeting, on the
        // card that shows the whole of what would be sent.
        case Notifications.ActionID.reviewProposal: meetingID.map { .open(meetingID: $0) }
        case Notifications.ActionID.approveProposal: proposalID.map { .approveProposal(id: $0) }
        case Notifications.ActionID.dismissProposal: proposalID.map { .dismissProposal(id: $0) }
        // A proposal notification's body is not an approval — clicking through to the app
        // is how the user goes and looks at what is being proposed.
        case UNNotificationDefaultActionIdentifier: meetingID.map { .open(meetingID: $0) }
        default: nil
        }

        // Answered before the hop rather than after it: the completion handler is an
        // Objective-C block that can't be carried across an isolation boundary, and the
        // system only wants to know the response was taken, not what it led to.
        completionHandler()
        guard let action else { return }
        Task { @MainActor in Notifications.shared.handle(action) }
    }
}
