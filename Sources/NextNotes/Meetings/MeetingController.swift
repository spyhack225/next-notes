import Foundation
import Observation

/// The one place a meeting recording is started or stopped.
///
/// It exists so that the menu bar, the Meetings section and — from Phase 3 — the scheduler
/// all reach the same session rather than each making one. Only one meeting can be
/// recorded at a time: two would fight over the microphone and the process tap, and the
/// second would silently record nothing.
@MainActor
@Observable
final class MeetingController {
    static let shared = MeetingController()

    private(set) var session: MeetingSession?
    /// The last failure, for the banner in the Meetings section.
    private(set) var problem: String?

    private let store: MeetingStore

    init(store: MeetingStore = .shared) {
        self.store = store
    }

    var isRecording: Bool { session?.isRecording ?? false }

    /// True between Stop and the last transcribed window. The session still exists, so a
    /// new meeting can't start yet — the UI disables the record command instead of letting
    /// it fail into the problem banner.
    var isFinishing: Bool { session != nil && !isRecording }

    /// Elapsed time of the running meeting, for the menu bar and the sidebar.
    var elapsed: TimeInterval { session?.elapsed ?? 0 }

    /// Records something that isn't on any calendar.
    @discardableResult
    func startAdHoc(title: String? = nil) async -> Bool {
        let meeting = Meeting(
            title: title ?? Self.defaultTitle(at: Date()),
            start: Date(),
            status: .recording
        )
        return await start(meeting: meeting)
    }

    /// Records a meeting the scheduler already created. Phase 3 calls this.
    @discardableResult
    func start(meeting: Meeting) async -> Bool {
        guard session == nil else {
            problem = MeetingError.alreadyRecording.localizedDescription
            return false
        }

        let session = MeetingSession(meeting: meeting, store: store)
        self.session = session
        problem = nil

        do {
            try await session.start()
            NavigationState.shared.show(meeting: meeting.id)
            return true
        } catch {
            problem = error.localizedDescription
            self.session = nil
            Log.meeting.error("couldn't start meeting: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func stop() async {
        guard let session else { return }
        await session.stop()
        let id = session.meeting.id
        self.session = nil
        NavigationState.shared.show(meeting: id)
    }

    /// Closes out a running meeting when the app is quitting.
    ///
    /// `applicationWillTerminate` can't await, so this saves what has already been
    /// transcribed and stops the captures synchronously; windows still inside Parakeet are
    /// lost. The alternative — doing nothing — leaves a `meeting.json` that claims to be
    /// recording, and the next launch has to guess.
    func endForTermination() {
        session?.endAbruptly()
        session = nil
    }

    func dismissProblem() {
        problem = nil
    }

    /// "Meeting · 14:30" — enough to tell two ad-hoc recordings apart in a list.
    private static func defaultTitle(at date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return "Meeting · \(time)"
    }
}
