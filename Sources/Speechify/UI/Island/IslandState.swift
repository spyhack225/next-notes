import Foundation
import Observation

/// One thing an agent has offered to do, reduced to what the island can show.
///
/// Deliberately not Phase 7's `AgentProposal`: the island shows a title, a sentence and two
/// buttons, and coupling it to a tool catalogue that doesn't exist yet would mean the
/// island couldn't be finished until the agent was. Phase 7 maps its proposals onto this.
struct IslandProposal: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let meetingID: UUID?
    /// Whether this card may only send the user to the meeting. Set for anything that would
    /// speak in their name: two lines under the notch cannot show the message that would go
    /// out, and a button that approves what it doesn't show is not a permission model.
    var needsReview = false
}

/// What the island is saying, and the only thing that decides it.
///
/// Everything on screen at the top of the display comes from `kind`. The panel is a window
/// that draws it; this is the state machine, and it is deliberately separable from AppKit
/// so `--selftest-island` can walk it without a screen.
///
/// Two kinds of state get in: **live** ones, recomputed from what the app is doing — you
/// are dictating, a meeting is recording, notes are being written — and **notices**, pushed
/// in by whoever raised them and answered by a button. A notice outranks a live state
/// because it is a question; a live state is only a readout.
@MainActor
@Observable
final class IslandState {
    static let shared = IslandState()

    enum Kind: Equatable {
        case hidden
        case dictating(transcript: String, level: Float)
        case meetingArmed(MeetingEvent)
        case meetingRecording(elapsed: TimeInterval, micLevel: Float, systemLevel: Float)
        case transcribing
        /// Identifying speakers. Not in the original list of states because diarization
        /// arrived a phase later; it sits between transcribing and summarizing exactly as
        /// `MeetingStatus.diarizing` does.
        case diarizing(progress: Double?)
        case summarizing(progress: Double?)
        case notesReady(meetingID: UUID, title: String)
        case agentProposal(IslandProposal)

        var isHidden: Bool { self == .hidden }

        /// What the island is saying, with the numbers left out.
        ///
        /// The state itself carries a level and an elapsed time, so it changes several times
        /// a second while anything is recording — and animating the card on `kind` would
        /// restart a spring on every audio buffer. Views animate on this instead, which
        /// only moves when the island has actually changed its mind.
        var identity: String {
            switch self {
            case .hidden: "hidden"
            case .dictating: "dictating"
            case .meetingArmed(let event): "armed:\(event.id)"
            case .meetingRecording: "recording"
            case .transcribing: "transcribing"
            case .diarizing: "diarizing"
            case .summarizing: "summarizing"
            case .notesReady(let id, _): "notes:\(id)"
            case .agentProposal(let proposal): "proposal:\(proposal.id)"
            }
        }

        /// Whether this state carries a question, and therefore opens by itself. The live
        /// readouts stay collapsed until the pointer arrives; a card with buttons on it is
        /// no use as a badge.
        var demandsAttention: Bool {
            switch self {
            case .meetingArmed, .notesReady, .agentProposal: true
            default: false
            }
        }

        /// Which orb stands in for this state.
        ///
        /// Each one is chosen for what the app is *doing*, not for variety — the nine
        /// upstream animations are distinct enough that a wrong one reads as a lie:
        ///
        /// - `listening` — a waveform rolling through rings, while one voice is captured.
        /// - `weaving` — three strands plaiting, while two tracks are captured at once.
        ///   You and the room arrive on separate channels and are braided into one
        ///   transcript, which is the thing this animation literally depicts.
        /// - `working` — particles on orbits, while Parakeet grinds through windows.
        /// - `solving` — bands scrambling and clicking back, while diarization decides who
        ///   spoke. It is a clustering problem resolving, and it looks like one.
        /// - `composing` — an undulating sash, while the notes are written.
        /// - `searching` — a meridian sweeping the globe, while the agent reads your mail
        ///   and calendar to work out what to propose.
        /// - `breathing` — a slow face-on ring, while an armed meeting waits for an answer.
        ///   Nothing is being processed; it is idling, on purpose.
        ///
        /// The red dot is not replaced by any of them. Red still means recording and only
        /// recording; the orb says what *kind* of work is going on beside it.
        var orb: OrbGeometry.State? {
            switch self {
            case .dictating: .listening
            case .meetingRecording: .weaving
            case .meetingArmed: .breathing
            case .transcribing: .working
            case .diarizing: .solving
            case .summarizing: .composing
            case .agentProposal: .searching
            case .hidden, .notesReady: nil
            }
        }
    }

    private(set) var kind: Kind = .hidden
    /// Set by the panel when the pointer is over the island.
    var isHovered = false {
        didSet { if isHovered != oldValue { rearmNotice() } }
    }

    var isExpanded: Bool { !kind.isHidden && (isHovered || kind.demandsAttention) }

    // MARK: - Notices

    /// A pushed state and when it stops being true. Notices are answered, not recomputed:
    /// nothing about the app's state says whether the user has read "notes are ready".
    private struct Notice {
        let kind: Kind
        /// Moved forward, not merely counted down: see `rearmNotice`.
        var expires: Date?
    }

    private var notice: Notice?
    private var expiry: Task<Void, Never>?

    /// Phase 7 sets this to hear the island's Approve / Dismiss buttons.
    var onProposalDecision: ((IslandProposal, Bool) -> Void)?

    // MARK: - Sources

    @ObservationIgnored private weak var dictation: DictationController?
    @ObservationIgnored private let meetings: MeetingController
    @ObservationIgnored private let notes: NotesService
    @ObservationIgnored private let diarization: DiarizationService
    @ObservationIgnored private var isObserving = false

    init(
        meetings: MeetingController = .shared,
        notes: NotesService = .shared,
        diarization: DiarizationService = .shared
    ) {
        self.meetings = meetings
        self.notes = notes
        self.diarization = diarization
    }

    /// Starts following the app. Called once, from the app delegate.
    func start(dictation: DictationController) {
        self.dictation = dictation
        guard !isObserving else { return }
        isObserving = true

        // The island takes down a card the user answered from the notification instead —
        // pressing Skip on the banner and then finding the same question still hanging
        // under the notch is the bug this exists to prevent. Registered as one observer
        // among several; the scheduler is the one that acts on these.
        Notifications.shared.observe { [weak self] action in
            self?.handle(action)
        }
        observe()
    }

    // MARK: - Pushed states

    /// A meeting has been armed and is about to record itself.
    func announceArmed(_ event: MeetingEvent) {
        // Up until the meeting starts, or for a notice's normal life — whichever is
        // longer. An event armed with a lead time of zero still deserves to be seen.
        push(.meetingArmed(event), for: max(DS.Motion.islandNotice, event.start.timeIntervalSinceNow))
    }

    /// Takes the armed card down, whichever way the question was answered.
    func clearArmed(_ event: MeetingEvent) {
        guard case .meetingArmed(let shown) = notice?.kind, shown.id == event.id else { return }
        clearNotice()
    }

    /// Takes the armed card down for a meeting the app has already answered for itself —
    /// it started recording, or it was written off as missed.
    ///
    /// The card asks a question that has stopped being open, and a "Record now" pressed on
    /// it afterwards would claim the same event a second time. Matched through the
    /// scheduler because the card holds the calendar event and the caller holds the meeting
    /// that event produced.
    func clearArmed(meetingID: UUID) {
        guard case .meetingArmed(let shown) = notice?.kind else { return }
        guard MeetingScheduler.shared.meeting(for: shown)?.id == meetingID else { return }
        clearNotice()
    }

    /// Notes have just been written for a meeting nobody is looking at.
    ///
    /// Called from the same branch of `NotesService` that posts the notification rather than
    /// from `revision`, because `revision` also moves when the user presses Regenerate with
    /// the meeting open in front of them — and announcing that in the corner of the screen
    /// tells them something they can already see.
    func announceNotesReady(_ meeting: Meeting) {
        push(.notesReady(meetingID: meeting.id, title: meeting.title), for: DS.Motion.islandNotice)
    }

    /// Phase 7's entry point: an agent wants permission to do something.
    func propose(_ proposal: IslandProposal) {
        push(.agentProposal(proposal), for: DS.Motion.islandNotice)
    }

    func dismissNotice() {
        clearNotice()
    }

    // MARK: - Buttons

    func recordNow(_ event: MeetingEvent) {
        clearNotice()
        Task { await MeetingScheduler.shared.recordNow(event) }
    }

    func skip(_ event: MeetingEvent) {
        clearNotice()
        MeetingScheduler.shared.skip(event)
    }

    func openNotes(meetingID: UUID) {
        clearNotice()
        NavigationState.shared.show(meeting: meetingID)
        AppDelegate.showMainWindow()
    }

    func decide(_ proposal: IslandProposal, approved: Bool) {
        clearNotice()
        onProposalDecision?(proposal, approved)
    }

    /// Sends the user to the meeting instead of answering here, for the proposals that can
    /// only be answered where the whole message is on screen.
    func review(_ proposal: IslandProposal) {
        clearNotice()
        guard let meetingID = proposal.meetingID else { return }
        NavigationState.shared.show(meeting: meetingID)
        AppDelegate.showMainWindow()
    }

    // MARK: - Recomputing

    /// Derives the live half of the state, and lets a notice win over it.
    ///
    /// Exposed for `--selftest-island`, which drives it against pushed notices to prove the
    /// priority order without a microphone.
    func refresh() {
        let next = notice?.kind ?? liveKind()
        guard next != kind else { return }
        kind = next
    }

    private func liveKind() -> Kind {
        // Dictation first among the live states: it lasts as long as a key is held, and its
        // whole job is to prove the app heard the words being said right now. A meeting
        // counter losing three seconds to it costs nothing.
        if let dictation, dictation.state.shouldShowHUD,
           Settings.shared.hudPlacement == .notch {
            return .dictating(transcript: dictation.transcript, level: dictation.level)
        }
        if let session = meetings.session, session.isRecording {
            return .meetingRecording(
                elapsed: session.elapsed,
                micLevel: session.micLevel,
                systemLevel: session.systemLevel
            )
        }
        if meetings.isFinishing { return .transcribing }
        if let fraction = diarization.progress.values.first { return .diarizing(progress: fraction) }
        if let step = notes.steps.values.first { return .summarizing(progress: step.fraction) }
        return .hidden
    }

    /// Re-arms after every change to anything the live state reads.
    ///
    /// `withObservationTracking` fires once and has to be re-registered, and it cannot be
    /// re-registered from inside its own callback — the callback runs while the change is
    /// still being applied. Hence the hop, which is also what keeps this on the main actor
    /// without `assumeIsolated`.
    private func observe() {
        withObservationTracking {
            _ = dictation?.state
            _ = dictation?.transcript
            _ = dictation?.level
            _ = Settings.shared.hudPlacement
            _ = meetings.session
            _ = meetings.session?.meeting.status
            _ = meetings.session?.elapsed
            _ = meetings.session?.micLevel
            _ = meetings.session?.systemLevel
            _ = notes.steps
            _ = diarization.progress
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
        refresh()
    }

    // MARK: - Notice plumbing

    private func push(_ kind: Kind, for duration: TimeInterval) {
        notice = Notice(
            kind: kind,
            expires: duration.isFinite ? Date().addingTimeInterval(duration) : nil
        )
        refresh()
        rearmNotice()
        Log.island.info("island notice: \(String(describing: kind), privacy: .public)")
    }

    private func clearNotice() {
        expiry?.cancel()
        expiry = nil
        notice = nil
        refresh()
    }

    /// (Re)schedules the countdown that takes an unanswered notice down.
    ///
    /// Nothing counts down under the pointer, and what starts again when the pointer leaves
    /// is a fresh full life. The deadline itself is pushed forward rather than only the
    /// pending sleep, because a card read for longer than its life would otherwise be
    /// resumed already expired and vanish the instant the pointer slid off it — including
    /// on the way to its own button.
    private func rearmNotice() {
        expiry?.cancel()
        expiry = nil
        guard !isHovered, let expires = notice?.expires else { return }
        // Floored at what was already promised: an armed meeting's card is alive until the
        // meeting starts, and a hover must not cut that short.
        let deadline = max(expires, Date().addingTimeInterval(DS.Motion.islandNotice))
        notice?.expires = deadline
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            guard let self, !self.isHovered else { return }
            self.clearNotice()
        }
    }

    private func handle(_ action: Notifications.Action) {
        switch notice?.kind {
        case .meetingArmed(let event):
            // The armed card and the armed notification ask the same question. Answering
            // either one answers both.
            switch action {
            case .recordNow(let id), .skip(let id), .open(let id):
                if MeetingScheduler.shared.meeting(for: event)?.id == id { clearNotice() }
            default:
                break
            }
        case .notesReady(let shownID, _):
            if case .open(let id) = action, id == shownID { clearNotice() }
        case .agentProposal(let proposal):
            switch action {
            case .approveProposal(let id), .dismissProposal(let id):
                if id == proposal.id { clearNotice() }
            default:
                break
            }
        default:
            break
        }
    }
}
