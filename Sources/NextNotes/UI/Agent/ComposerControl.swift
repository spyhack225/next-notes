import Foundation

/// The one trailing control in the Agent's composer, as a value.
///
/// It was two buttons: a **Stop** that appeared while a turn ran and a **Send** that was always
/// there, so the row changed width at the start and end of every single turn. OpenMuse's composer
/// is the reference (`docs/EXPERIENCE.md`): the send arrow becomes a stop square **in the same
/// place**, stopping keeps what you typed, and nothing typed is lost.
///
/// The rule is one sentence: **an empty box while the Agent is busy offers Stop; anything typed
/// offers Send, busy or not.** That is what makes a follow-up possible at all — the old row could
/// only stop you, and the way to send during a turn was to press Return, which worked and was
/// invisible.
enum ComposerControl: Equatable, Sendable {
    case send(enabled: Bool)
    case stop

    static func state(draftIsEmpty: Bool, isThinking: Bool) -> ComposerControl {
        draftIsEmpty && isThinking ? .stop : .send(enabled: !draftIsEmpty)
    }

    var isStop: Bool { self == .stop }

    /// The accessibility label, in the app's own words. A square with no name is a mystery to a
    /// screen reader, and "Stop" beside "Send" was ambiguous about which stopped what.
    var label: String {
        switch self {
        case .send: return "Send"
        case .stop: return "Stop"
        }
    }
}

/// The one notice the composer can raise, and the only text it may add to the conversation.
///
/// Sending while a turn runs interrupts it — that is real and P3-11 owns its semantics — and
/// until now it was silent. A person watching a request work sees it stop and has no way to know
/// whether they did that, whether it failed, or whether the app gave up.
///
/// **It is a view row and nothing else.** It never becomes an `AgentSession.Message`, so it
/// cannot reach the model's history, the knowledge index or `usage.jsonl` — a notice about the
/// interface is not something the Agent said, and putting it in the history would teach the next
/// turn that it had interrupted something. That is the whole reason this is a type with one case
/// rather than a string appended to the transcript.
enum ComposerNotice: Equatable, Sendable, Identifiable {
    /// A send arrived while a turn was running, so that turn was stopped to answer this one.
    case interruptedEarlierRequest(Date)

    var id: Date { at }

    /// When it was raised. Public so the view's timeline orders rows by one value rather than
    /// re-deriving the date from the case — a second copy of that switch is a second place for
    /// the two to disagree.
    var at: Date {
        switch self { case .interruptedEarlierRequest(let at): return at }
    }

    /// What a person reads. One sentence, no jargon, and it says what happened rather than
    /// apologising for it.
    var text: String {
        switch self {
        case .interruptedEarlierRequest: return "Stopped the earlier request to answer this."
        }
    }
}
