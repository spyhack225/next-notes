import SwiftUI

/// What Command Mode is doing, in the words it says on screen.
///
/// Command Mode is the one feature in the app with nothing on screen to point at. Dictation
/// has a key you hold and text that appears where you were typing; the agent has a card with
/// its name on it. This has a bare modifier, a selection in somebody else's window, and a
/// model that rewrites it — and until now it said none of that. A hold that could not start
/// went through the ordinary dictation failure path, which sets `.error`, and at the notch
/// an errored dictation is a wordless orb: an animation with no message attached to it and
/// nothing following it. That is exactly what it was reported as.
///
/// So the status is a value of its own rather than a string smuggled through the transcript.
/// It decides what the heads-up display says, how long it stays, and — because the island
/// reads the same value to stand down — that only one surface ever describes the hold.
enum CommandModeStatus: Equatable, Sendable {
    /// The microphone is open and an instruction is expected.
    case listening
    /// The instruction has been heard and the model is rewriting the selection.
    case rewriting
    /// The key was held properly, but nothing was selected to act on.
    case needsSelection
    /// It could not be done, said plainly.
    case problem(String)

    /// The headline. Short enough to be read at a glance from across a desk.
    var title: String {
        switch self {
        case .listening: "Editing your selection"
        case .rewriting: "Making that change\u{2026}"
        case .needsSelection: "Select some text first"
        case .problem: "That didn\u{2019}t work"
        }
    }

    /// The line under the headline. `key` is named in words rather than as a glyph, because
    /// somebody who does not recognise ⌘ is precisely the person this sentence is for.
    func detail(key: PushToTalkKey) -> String {
        switch self {
        case .listening:
            "Say what to change, then let go of \(key.spokenName)."
        case .rewriting:
            "Your selected text will be replaced in a moment."
        case .needsSelection:
            "Highlight the words you want changed, then hold \(key.spokenName) again."
        case .problem(let message):
            message
        }
    }

    /// The glyph beside the words. Deliberately not an orb: an orb is what dictation, the
    /// meeting recorder and the agent all wear, and the report this fixes was somebody
    /// watching one of those and not knowing which.
    var symbol: String {
        switch self {
        case .listening: "text.cursor"
        case .rewriting: "wand.and.stars"
        case .needsSelection: "character.cursor.ibeam"
        case .problem: "exclamationmark.triangle"
        }
    }

    /// Whether the microphone is open in this state, and so whether a level meter would be
    /// telling the truth.
    var isCapturing: Bool { self == .listening }

    /// How long this stays up on its own, or `nil` for a state the hold itself ends.
    ///
    /// A message nobody is going to answer has to take itself down; `.listening` and
    /// `.rewriting` are ended by the key coming up and the model coming back.
    var lifetime: Duration? {
        switch self {
        case .listening, .rewriting: nil
        case .needsSelection, .problem: .seconds(4)
        }
    }

    /// Whether this state is one the user has to do something about. Used for the tint.
    var isProblem: Bool {
        switch self {
        case .needsSelection, .problem: true
        case .listening, .rewriting: false
        }
    }
}

/// The heads-up display Command Mode gets to itself.
///
/// Distinct from the dictation capsule on purpose, and distinct in the two ways that matter
/// at a glance: it leads with a glyph rather than an orb, and it leads with a *sentence*
/// rather than with a transcript. Dictation's capsule answers "is it hearing me"; this one
/// has to answer "what is this, and what do I do now", which the old build never did.
struct CommandModeCard: View {
    let status: CommandModeStatus
    let key: PushToTalkKey
    let level: Float
    /// What has been heard so far. Replaces the explanatory line once there is any, because
    /// by then the explanation has done its job.
    let transcript: String

    private var tint: Color {
        status.isProblem ? DS.Color.warning : DS.Color.accent
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: status.symbol)
                .font(DS.Font.title3)
                .foregroundStyle(tint)
                .frame(width: DS.Size.orbInline)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(status.title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Color.text)
                    .lineLimit(1)
                Text(line)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .animation(DS.Motion.standard, value: line)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if status.isCapturing {
                LevelBar(level: level, isActive: true)
                    .frame(width: DS.Size.hudBarWidth)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .frame(width: DS.Size.hud.width, height: DS.Size.hud.height)
        .glassEffect(DS.Material.hudGlass, in: .rect(cornerRadius: DS.Radius.hud))
        // The one thing that separates this from the dictation capsule at a distance, in a
        // colour that already means what it means here: accent for work, warning for a
        // question the user has to answer.
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.hud, style: .continuous)
                .strokeBorder(tint.opacity(DS.Opacity.secondaryFill), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.title). \(line)")
    }

    private var line: String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == .listening, !spoken.isEmpty { return spoken }
        return status.detail(key: key)
    }
}
