import Foundation

/// What the character is doing — the agent avatar's animation vocabulary.
///
/// One state, one meaning, everywhere: the same rule as `OrbGeometry`'s nine states, and
/// for the same reason. The avatar is a *character*, so a state also carries body language
/// an orb cannot — where the eyes are, whether the head is attending — but choosing a state
/// for variety rather than for what the machine is doing is a lie about the machine.
/// `--selftest-avatar` pins the table; `AGENTS.md` is where a person reads it.
///
/// The mapping is deliberately two-layered: a *tool* decides its own state from the
/// namespace and the risk it runs at (`forTool`), and anything that is not a tool call is
/// reduced from the activity kind the projector already produced (`init(activity:)`). No
/// state is inferred from the English of a progress title — the titles are rewritten for
/// the user, and a mapping that reads them would break the day one is reworded.
enum AgentAvatarState: String, CaseIterable, Sendable, Equatable, Codable {
    /// Nothing is running. Breathing and blinking — the pose a still portrait is in.
    case idle
    /// The microphone is open for the agent. Not dictation: that is the HUD's job, and it
    /// keeps its own orb.
    case listening
    /// The model is deciding what to do. No tool has run yet.
    case thinking
    /// Reading something it did not write — mail, calendar, a page, a file listing.
    case browsing
    /// Producing text: a file, a draft, a command at the keyboard.
    case writing
    /// Running something with an effect: a click, a form, an install.
    case tool
    /// Saying something in the user's name. The one state that leaves the Mac.
    case sending
    /// Held up on a person — an approval, an answer, a scheduled time.
    case waiting
    /// Nothing has happened for a long while and the avatar has stopped attending.
    case sleeping
    /// The run just finished. A single nod, not a loop.
    case done
}

// MARK: - Reading the app

extension AgentAvatarState {
    /// The state a step of a run is in, from the kind the projector already decided.
    ///
    /// `searching` and `reading` are one state because they are one thing to a person
    /// watching: the character is looking something up. `executing` is the tool state for
    /// the same reason it is named that — something with an effect is running.
    init(activity: AgentActivityKind) {
        switch activity {
        case .thinking: self = .thinking
        case .searching, .reading: self = .browsing
        case .writing: self = .writing
        case .executing: self = .tool
        case .waiting: self = .waiting
        case .completed: self = .done
        }
    }

    /// The state a tool puts the character in.
    ///
    /// Risk decides first, because it says what the call will *do* rather than where it
    /// happens: anything in the user's name is a send wherever it is aimed, and a read is
    /// browsing whether it reaches a browser, a mailbox or a folder. Deletions, installs
    /// and purchases keep the wrench — they are changes with an effect, not writing.
    /// Only then does the namespace pick between writing and working, and the two that
    /// write where the user can read it (a file, a command) are the closest thing this app
    /// has to code, which is what the `writing` art is drawn for.
    static func forTool(
        namespace: AgentToolNamespace,
        name: String,
        risk: AgentRisk
    ) -> AgentAvatarState {
        if risk == .send { return .sending }
        if risk <= .read { return .browsing }
        if risk == .destructive || risk == .privileged { return .tool }
        switch namespace {
        case .filesystem, .shell: return .writing
        case .workspace: return .writing
        case .schedule: return .waiting
        default: return .tool
        }
    }

    /// What an avatar shows after `quietFor` seconds without work.
    ///
    /// Sleep is a *long* quiet — ten minutes by default, the token the app passes — and it
    /// is deliberately not reachable by a paused run: waiting is attention, sleeping is the
    /// end of it. Pure, with both ends passed in, so a self-test can walk the threshold
    /// without waiting for it.
    static func resting(quietFor seconds: TimeInterval, asleepAfter: TimeInterval) -> AgentAvatarState {
        seconds >= asleepAfter ? .sleeping : .idle
    }
}
