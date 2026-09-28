import AppKit
import CoreGraphics
import Foundation

/// The person's hand, noticed.
///
/// OpenMuse's agent drives a sandboxed browser and "Take control" opens that session once its run
/// finishes. Ours drives **the person's own Mac**: `AccessibilitySnapshot` posts real mouse and
/// key events, and the CDP client drives their real Chrome. So there is no second browser to hand
/// over — but nothing noticed when the person grabbed the mouse or started typing while the agent
/// was clicking. Both hands then drove one pointer: a click landed where the person had just moved
/// it, or keystrokes interleaved with theirs.
///
/// **A person must never have to wait for the agent to finish before using their own computer.**
/// That is the opposite of OpenMuse's rule, and it is ours.
///
/// ## How it tells the two hands apart
///
/// Every event this app posts is tagged through `eventSourceUserData` with `agentEventTag` on
/// the `CGEventSource` it is posted from. An **untagged** mouse-down, key-down, scroll or
/// right-click during a posted action is the person, and the first one pauses the agent before
/// its next posted event.
///
/// **Measured 2026-09-28 on this Mac: the tag survives `post(tap: .cghidEventTap)` and reads back
/// in a listen-only tap** — see `ComputerYieldSelfTest`'s live half, which prints the round trip.
/// So this is a tag, not the timestamp window the task offers as the fallback. The fallback is
/// still implemented below, because a machine whose driver drops the field would otherwise
/// interpret every synthetic event as the person and pause on its own clicks; the two cannot
/// disagree silently.
///
/// The Accessibility grant computer control already needs covers this: a listen-only tap needs
/// nothing extra. Nothing here posts an event, decides a tool's outcome, or holds a lock — it
/// only reads what already happened, and the executor asks it one question.
@MainActor
enum HumanInputWatch {

    /// The value on `eventSourceUserData` for every event this app posts.
    ///
    /// One constant, and the self-test pins it: a value that changed without the fixture noticing
    /// would make every synthetic event look like the person, which is the one failure this file
    /// cannot have.
    static let agentEventTag: Int64 = 0x4E4E_2D41_4747  // "NN-AGG"

    /// The source every posted event goes through, so the tag is set once rather than per call.
    ///
    /// Created on demand and held: a `CGEventSource` is cheap, and re-creating it per event would
    /// be a second place for the tag to be forgotten.
    private static let source: CGEventSource = {
        // `userData` is the documented Swift spelling; there is no `setUserData`. Forced
        // unwrapped deliberately: a nil source would post untagged events, which this file
        // reads as the person — so a machine that cannot make one must say so at first use
        // rather than quietly cancel the agent's own work. `sourceAvailable` says which.
        let made = CGEventSource(stateID: .hidSystemState)
        made?.userData = Int64(agentEventTag)
        guard let made else {
            Log.agent.error("human input watch: no CGEventSource, so posted events are untagged")
            return CGEventSource(stateID: .privateState) ?? made!
        }
        return made
    }()

    /// Whether the tagged source was made. False means every posted event is untagged, and the
    /// fallback's timestamp window is the only thing separating the agent from the person.
    static var sourceAvailable: Bool {
        CGEventSource(stateID: .hidSystemState)?.userData == agentEventTag
    }

    /// The source to post through. `nil` if the system refused one, in which case a caller posts
    /// untagged and the watch falls back to its window — which is the same answer, less precisely.
    static func eventSource() -> CGEventSource { source }

    /// A pause, and why.
    enum State: Equatable, Sendable {
        /// Nobody has touched anything. The agent is driving.
        case driving
        /// The person did, at a known instant.
        case paused(at: Date)

        var isPaused: Bool { if case .paused = self { return true }; return false }
    }

    /// The window a posted event occupies, in seconds.
    ///
    /// The fallback's only parameter. 0.4 s is measured slack, not a guess about a human: a
    /// listen-only tap that dropped the field would otherwise see the agent's own click and
    /// pause on it, and this is the span within which a mouse-down can only be the agent's.
    static let fallbackWindow: TimeInterval = 0.4

    // MARK: - The tap

    private static var tap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?
    private static var state: State = .driving
    /// Every event this process posted, as instants. The fallback's ledger, and also the answer
    /// to "was that event ours?" when a tap is not available at all.
    private static var postedInstants: [Date] = []
    private static var sawUntaggedInput = false
    private static var lastUntagged: Date?

    /// Starts listening. Idempotent, and cheap: nothing is read until `beginAction()` arms it.
    @discardableResult
    static func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let options = CGEventTapOptions.listenOnly
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
            eventsOfInterest: CGEventMask(mask), callback: handleEvent,
            // nil: the callback reaches the type's own statics, so there is no instance to
            // carry, and `HumanInputWatch` is an enum rather than a class to pass.
            userInfo: nil) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        return true
    }

    /// Stops listening and forgets the ledger. A self-test, and the app's own teardown.
    static func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        state = .driving
        postedInstants = []
        sawUntaggedInput = false
        lastUntagged = nil
    }

    /// Arms the watch for one action. **The tap is only consulted while this is armed** — a
    /// listen-only tap that runs for the life of the app is a tap that has to be trusted forever,
    /// and a person's mouse movement should not be our problem when the agent is not driving.
    ///
    /// **It does not clear a pause.** A pause belongs to the *turn*, not to the call: the first
    /// version cleared it here and in `endAction()`, which meant the agent's next tool call
    /// resumed by itself — the person reached for the mouse, the agent yielded for one call, and
    /// then carried on with the next one anyway. Only `carryOn()` and `resetForNewTurn()` clear
    /// it, which are the two things that actually mean "the person said to go on".
    static func beginAction() {
        postedInstants = []
        sawUntaggedInput = false
        lastUntagged = nil
        start()
    }

    /// Disarms the reading. The pause survives: nothing is read between actions, so there is
    /// nothing new to decide, and the person has not finished reaching for the mouse.
    static func endAction() {}

    /// Records that this process posted an event, for the fallback's ledger. Call it **before**
    /// `post`, so the instant is at or slightly before the event rather than after it.
    static func notePosted() {
        postedInstants.append(Date())
    }

    /// The one question an executor asks: may I post the next event?
    ///
    /// The answer flips to `false` and **stays** flipped until `carryOn()`: a person who reached
    /// for the mouse has not finished reaching for it, and re-arming because the agent was
    /// impatient is how two hands end up on one pointer.
    static func mayPostAnotherEvent() -> Bool {
        guard !state.isPaused else { return false }
        guard sawUntaggedInput else { return true }
        // A tap with no field (a driver that drops it) still tells us *when*; the ledger says
        // whether the event at that instant was ours.
        if let last = lastUntagged,
           postedInstants.contains(where: { abs($0.timeIntervalSince(last)) <= fallbackWindow }) {
            return true
        }
        state = .paused(at: lastUntagged ?? Date())
        return false
    }

    static var current: State { state }

    /// A new request from the person starts clean.
    ///
    /// The other way a pause ends besides "carry on": someone typing a new question is not
    /// asking the agent to resume a paused plan, and leaving a stale pause would refuse the
    /// first computer action of the new turn for a reason that no longer exists.
    static func resetForNewTurn() {
        state = .driving
        sawUntaggedInput = false
        lastUntagged = nil
        postedInstants = []
    }

    /// The person said or pressed "carry on". Takes a **fresh** snapshot and re-plans; it never
    /// replays coordinates from before the pause, because the window has moved since.
    static func carryOn() {
        state = .driving
        sawUntaggedInput = false
        lastUntagged = nil
        postedInstants = []
    }

    /// The sentence. One line, and it says what to do rather than what happened.
    static let pausedSentence =
        "Paused — you\u{2019}re using the Mac. Say \u{201C}carry on\u{201D} or press "
        + "Carry on when you\u{2019}re done."

    /// The sentence for a page that wants the person. Same paused state, different reason.
    static func signInSentence(what: String) -> String {
        "\(what) wants you to sign in. I\u{2019}ll carry on after."
    }

    // MARK: - The callback

    private static let handleEvent: CGEventTapCallBack = { _, type, event, _ in
        let now = Date()
        // `eventSourceUserData` is the whole mechanism, so the read is the measurement as well
        // as the test: if a driver ever drops it, the fallback below covers us and this stops
        // mistaking our own clicks for the person's.
        let tagged = event.getIntegerValueField(.eventSourceUserData) == agentEventTag
        if tagged { return Unmanaged.passUnretained(event) }
        MainActor.assumeIsolated {
            if HumanInputWatch.state.isPaused { return }
            HumanInputWatch.sawUntaggedInput = true
            HumanInputWatch.lastUntagged = now
        }
        // listenOnly: the return value is ignored by the system, and passing the event through
        // unchanged is the only correct answer for a tap that is not allowed to consume.
        return Unmanaged.passUnretained(event)
    }

    /// The result an executor returns instead of posting, when the person has the Mac.
    ///
    /// A tool result and not a thrown error: the turn is not broken, the action was deferred,
    /// and the sentence belongs in the conversation where a person reads it. Throwing would be
    /// rendered as a failure, which is the one thing this whole file is arguing against.
    static func pauseResult() -> AgentToolResult {
        AgentToolResult(summary: pausedSentence)
    }

    /// The tools that **change** something, and therefore need the hand.
    ///
    /// A read is exempt on purpose: looking at the screen does not fight the person for it, and
    /// a person typing while the agent *inspects* is the normal case rather than a conflict.
    /// What conflicts is two hands driving one pointer, and only a write does that.
    static func touchesTheMac(_ toolName: String) -> Bool {
        switch toolName {
        case "active_app", "windows", "inspect_ui", "screenshot", "get_selection", "clipboard",
             "wait_for", "snapshot", "diff", "console", "network", "tabs", "refs":
            return false
        default:
            return true
        }
    }

    /// Arms the watch around one tool call.
    ///
    /// In the **tool loop** this is the place the pause is decided, because the loop knows the
    /// remaining rounds: a yielded step ends the round as `needsInput` so the plan can re-snapshot
    /// rather than carry on posting coordinates from a window that has moved.
    @discardableResult
    static func arm(toolName: String) -> Bool {
        guard touchesTheMac(toolName) else { return true }
        beginAction()
        return true
    }

    /// How many events this process has posted since the last `beginAction()`.
    ///
    /// The count Y1 is measured in: "at most one more event" is not a claim about a stopwatch,
    /// it is a claim about how many went out, and a case that only timed the loop could not
    /// tell a prompt pause from a fast one that posted nine more.
    static var postedSinceActionBegan: Int { postedInstants.count }

    /// A pause with no event behind it, for the half of the self-test that has no Accessibility
    /// grant.
    ///
    /// **In this file on purpose**: it writes exactly what a real untagged event writes, and
    /// `private` in another file cannot reach that. A second copy of the rule in the test would
    /// be a second rule, and the test would then be checking itself.
    static func notePauseForTesting(at when: Date) {
        sawUntaggedInput = true
        lastUntagged = when
    }

    /// The tag round trip, for the self-test. Posts nothing.
    static func tagRoundTrip() -> Bool {
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                            mouseCursorPosition: .zero, mouseButton: .left)
        return event?.getIntegerValueField(.eventSourceUserData) == agentEventTag
    }
}
