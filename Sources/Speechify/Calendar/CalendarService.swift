import AppKit
import EventKit
import Foundation
import Observation

/// Every enabled calendar, merged into one list of what is coming up.
///
/// The scheduler and the UI both read `upcoming`, and neither knows or cares which account
/// an entry came from — that is the point of having a `CalendarProvider` protocol at all.
/// Refreshes are polled rather than pushed because only EventKit has a change
/// notification; Google would need a webhook and a public URL to deliver one.
@MainActor
@Observable
final class CalendarService {
    static let shared = CalendarService()

    /// Everything starting inside the look-ahead window that hasn't ended yet, soonest
    /// first, with duplicates across accounts already collapsed.
    private(set) var upcoming: [MeetingEvent] = []
    private(set) var providerStates: [CalendarProviderID: CalendarAuthorizationState] = [:]
    private(set) var lastRefresh: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    /// The Google calendars available to tick in Settings.
    private(set) var googleCalendars: [GoogleCalendarListEntry] = []

    /// How far ahead to look. A day is enough for "what's next" and small enough that a
    /// busy account is a couple of hundred events rather than a couple of thousand.
    static let lookAhead: TimeInterval = 24 * 60 * 60
    /// How far back, so a meeting that started while the Mac was asleep is still armable.
    static let lookBehind: TimeInterval = 60 * 60
    /// Google has no change notification and EventKit's fires only for local edits, so the
    /// list is re-read on a timer. Five minutes is well inside the default lead time.
    static let pollInterval: TimeInterval = 5 * 60

    private let eventKit = EventKitCalendarProvider()
    private let google = GoogleCalendarProvider()
    private let fake: FakeCalendarProvider?

    private var poll: Task<Void, Never>?
    /// The last refresh queued, if any. Each new one waits for it, so the reads stay
    /// serialised — the timer, the wake notification, the Meetings section and Settings all
    /// ask for one — while every caller still gets a pass that ran after it asked.
    private var inFlight: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    private init() {
        fake = FakeCalendarProvider.isEnabled ? FakeCalendarProvider() : nil
    }

    // MARK: - Lifecycle

    func start() {
        guard poll == nil else { return }

        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }

        // Waking is the one moment the cached list is guaranteed stale: the Mac may have
        // been shut for a day, and the next meeting may already have started.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in await CalendarService.shared.refresh() }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in await CalendarService.shared.refresh() }
        })
    }

    func stop() {
        poll?.cancel()
        poll = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    // MARK: - Reading

    /// The soonest thing that hasn't started yet, for the menu bar.
    var next: MeetingEvent? {
        let now = Date()
        return upcoming.first { $0.end > now && !$0.isAllDay }
    }

    func event(withOverrideKey key: String) -> MeetingEvent? {
        upcoming.first { $0.overrideKey == key }
    }

    /// Reads every enabled calendar, behind whatever read is already running.
    ///
    /// Chained forward rather than joined to the running pass: a caller that ticks a
    /// calendar and then asks for a refresh has to be answered by a read that happened
    /// *after* its change. Awaiting the in-flight pass would hand back a list built from
    /// the configuration as it was before — the newly ticked calendar simply missing, with
    /// nothing scheduled to go and fetch it until the five-minute poll came round.
    func refresh() async {
        let previous = inFlight
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performRefresh()
        }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let settings = Settings.shared
        await google.configure(
            clientID: settings.googleClientID,
            clientSecret: settings.googleClientSecret,
            calendarIDs: settings.googleCalendarIDs
        )

        let from = Date().addingTimeInterval(-Self.lookBehind)
        let to = Date().addingTimeInterval(Self.lookAhead)

        var collected: [MeetingEvent] = []
        var states: [CalendarProviderID: CalendarAuthorizationState] = [:]
        var failures: [String] = []

        for provider in activeProviders() {
            let state = await provider.authorizationState()
            states[provider.id] = state
            guard state.isAuthorized else { continue }
            do {
                collected.append(contentsOf: try await provider.events(from: from, to: to))
            } catch {
                states[provider.id] = .failed(error.localizedDescription)
                failures.append("\(provider.id.displayName): \(error.localizedDescription)")
            }
        }

        // Providers that are switched off still get a state, so Settings can say "Off"
        // rather than showing nothing at all.
        for id in CalendarProviderID.allCases where states[id] == nil {
            states[id] = disabledState(for: id)
        }

        providerStates = states
        upcoming = Self.deduplicated(collected)
        lastRefresh = Date()
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")

        Log.calendar.info("""
            calendar refresh: \(self.upcoming.count, privacy: .public) upcoming event(s) \
            from \(states.values.filter(\.isAuthorized).count, privacy: .public) provider(s)
            """)
    }

    // MARK: - Authorization

    @discardableResult
    func authorizeEventKit() async -> CalendarAuthorizationState {
        let state = await eventKit.authorize()
        providerStates[.eventKit] = state
        await refresh()
        return state
    }

    @discardableResult
    func connectGoogle() async -> CalendarAuthorizationState {
        let settings = Settings.shared
        await google.configure(
            clientID: settings.googleClientID,
            clientSecret: settings.googleClientSecret,
            calendarIDs: settings.googleCalendarIDs
        )
        let state = await google.authorize()
        providerStates[.google] = state
        if state.isAuthorized {
            await refreshGoogleCalendars()
            await refresh()
        }
        return state
    }

    func disconnectGoogle() async {
        await google.signOut()
        googleCalendars = []
        // The state is recomputed rather than assigned: with the provider still switched
        // on, signing out means "not connected", not "off".
        await refresh()
    }

    func refreshGoogleCalendars() async {
        guard Settings.shared.calendarGoogleEnabled else { return }
        do {
            googleCalendars = try await google.calendars()
        } catch {
            googleCalendars = []
            Log.calendar.error("couldn't list Google calendars: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internals

    private func activeProviders() -> [any CalendarProvider] {
        // The fake provider replaces the real ones rather than joining them: a test run
        // must never arm a recording of a meeting that is actually happening.
        if let fake { return [fake] }

        let settings = Settings.shared
        var providers: [any CalendarProvider] = []
        if settings.calendarEventKitEnabled { providers.append(eventKit) }
        if settings.calendarGoogleEnabled { providers.append(google) }
        return providers
    }

    private func disabledState(for id: CalendarProviderID) -> CalendarAuthorizationState {
        // In fake mode the real providers are not off, they are stood down — saying
        // "switched off" would send someone to a setting that is still on.
        if fake != nil, id != .fake {
            return .disabled("Replaced by the test calendar while --fake-calendar is set.")
        }
        switch id {
        case .eventKit: return .disabled("Apple Calendar is switched off.")
        case .google: return .disabled("Google Calendar is switched off.")
        case .fake: return .disabled("Only active with --fake-calendar.")
        }
    }

    /// Collapses the same meeting seen through two accounts.
    ///
    /// A Google invitation that is also subscribed to in Apple Calendar arrives twice, with
    /// different ids and usually only one of them carrying the conference link. Matching on
    /// title plus start minute is crude, but the alternative — matching on iCalUID — fails
    /// exactly where it matters, because EventKit and Google normalise it differently.
    /// The copy with a conference URL wins; ties go to the one with more attendees.
    static func deduplicated(_ events: [MeetingEvent]) -> [MeetingEvent] {
        var best: [String: MeetingEvent] = [:]
        for event in events {
            let key = event.identityKey
            guard let existing = best[key] else {
                best[key] = event
                continue
            }
            if isBetter(event, than: existing) { best[key] = event }
        }
        return best.values.sorted { left, right in
            left.start == right.start ? left.title < right.title : left.start < right.start
        }
    }

    private static func isBetter(_ candidate: MeetingEvent, than existing: MeetingEvent) -> Bool {
        if (candidate.conferenceURL != nil) != (existing.conferenceURL != nil) {
            return candidate.conferenceURL != nil
        }
        return candidate.attendees.count > existing.attendees.count
    }
}
