import Foundation
import UserNotifications

/// Reminders handed to macOS, so they survive the app being closed.
///
/// Only the *next* occurrence of each reminder is registered, as a
/// `UNCalendarNotificationTrigger` under a stable identifier — well under the system's cap on
/// pending requests. While the app runs, the scheduler withdraws a registration shortly
/// before its slot and delivers the reminder itself, so it can be spoken; if the app is not
/// running, macOS delivers it. Launch reconciles the two (`AgentScheduler.reconcile`).
///
/// A protocol so `--selftest-schedule` can drive the whole path with a recorder and never
/// touch the real notification center.
@MainActor
protocol ReminderSystemRegistering: AnyObject {
    /// Registers `slot` for this schedule, replacing any earlier registration. True once
    /// macOS accepted the request.
    func register(_ schedule: AgentSchedule, slot: Date) async -> Bool
    func withdraw(scheduleID: UUID)
    /// Schedule ids with a registration still pending.
    func pendingScheduleIDs() async -> Set<UUID>
    /// Whether macOS will actually show what is registered.
    func isAuthorized() async -> Bool
}

@MainActor
final class ScheduleNotifications: ReminderSystemRegistering {
    static let shared = ScheduleNotifications()

    nonisolated static let systemIdentifierPrefix = "agent-reminder-next-"

    nonisolated static func systemIdentifier(for id: UUID) -> String {
        systemIdentifierPrefix + id.uuidString
    }

    nonisolated static func scheduleID(fromSystemIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(systemIdentifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(systemIdentifierPrefix.count)))
    }

    private init() {}

    /// Same guard as `Notifications.center`: a process without a bundle identifier traps.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, !SelfTest.isRunning else { return nil }
        return UNUserNotificationCenter.current()
    }

    func register(_ schedule: AgentSchedule, slot: Date) async -> Bool {
        guard let center, let request = Self.request(for: schedule, slot: slot) else { return false }
        do {
            try await center.add(request)
            return true
        } catch {
            Log.app.error("couldn't register reminder with macOS: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func withdraw(scheduleID: UUID) {
        guard let center else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.systemIdentifier(for: scheduleID)])
    }

    func pendingScheduleIDs() async -> Set<UUID> {
        guard let center else { return [] }
        let requests = await center.pendingNotificationRequests()
        return Set(requests.compactMap { Self.scheduleID(fromSystemIdentifier: $0.identifier) })
    }

    func isAuthorized() async -> Bool {
        await Notifications.shared.isAuthorized()
    }

    /// The request for one slot. Pure, so the self-test can check the trigger's components:
    /// wall-clock fields in the schedule's own zone, with the zone attached.
    static func request(for schedule: AgentSchedule, slot: Date) -> UNNotificationRequest? {
        guard let components = triggerComponents(for: schedule, slot: slot) else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = schedule.prompt
        content.categoryIdentifier = Notifications.Category.agentRoutine
        content.userInfo = [
            Notifications.UserInfoKey.scheduleID: schedule.id.uuidString,
            "slot": ISO8601DateFormatter().string(from: slot),
        ]
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: systemIdentifier(for: schedule.id), content: content, trigger: trigger)
    }

    static func triggerComponents(for schedule: AgentSchedule, slot: Date) -> DateComponents? {
        guard let identifier = schedule.when?.timeZone, let zone = TimeZone(identifier: identifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: slot)
        components.calendar = calendar
        components.timeZone = zone
        return components
    }
}
