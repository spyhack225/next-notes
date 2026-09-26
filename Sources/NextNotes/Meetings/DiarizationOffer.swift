import Foundation

/// M-15: the one-time offer that turns speaker identification on.
///
/// Two things live here and nothing else does. The **when** — a pure predicate, because
/// "does this meeting earn the offer" is a rule and a rule is testable, while a card's
/// appearance in a view hierarchy is not. And the **words**, because the copy is the part
/// that decides whether this reads as an offer or as a diagnostic: a person who has just
/// finished a meeting with three voices in it is not being told about a clustering pass,
/// they are being asked whether they want to know who said what.
///
/// What it is not: a download. Nothing is fetched until somebody presses "Turn On", and
/// that button also records an explicit answer, so this notice is asked once per Mac and
/// never again — the effective default in `Settings` takes over from there.
enum DiarizationOffer {
    /// The offer as it reads. One sentence of what turning it on costs, because that is
    /// the only reason somebody would want to say no: a download and a temporary
    /// recording, which is what they are trading a couple of gigabytes and some disk for.
    struct Offer: Equatable, Sendable {
        let title: String
        let message: String
        let turnOnTitle: String
        let notNowTitle: String
    }

    static let offer = Offer(
        title: "Tell the other speakers apart?",
        message: "This downloads a model and keeps a temporary recording until the notes are written.",
        turnOnTitle: "Turn On",
        notNowTitle: "Not Now"
    )

    /// Whether this meeting earns the offer.
    ///
    /// Four conditions, and each one is a case of somebody being interrupted for nothing:
    /// a meeting that is still running has not been had yet; a meeting with nothing but
    /// the Mac's own microphone has nobody to tell apart; a machine that is already
    /// identifying speakers has nothing to offer; and an answer of "Not Now" is an answer.
    ///
    /// Pure, so `--selftest-onboarding` can ask it about a transcript it built itself.
    static func shouldOffer(
        segments: [TranscriptSegment],
        isFinished: Bool,
        diarizationEnabled: Bool,
        dismissed: Bool
    ) -> Bool {
        isFinished && !diarizationEnabled && !dismissed && hasOtherVoices(segments)
    }

    /// Whether anyone other than the person holding the Mac spoke.
    ///
    /// The system channel is the only place another voice can be, so a transcript with no
    /// system segment is a conversation with nobody in it — the two-track attribution
    /// already has it right, and the offer would be asking for work to answer nothing.
    /// An agent command is the user's own voice speaking to the app, so it does not count
    /// either.
    static func hasOtherVoices(_ segments: [TranscriptSegment]) -> Bool {
        segments.contains { segment in
            guard segment.source == .system, segment.kind != .agentCommand else { return false }
            return !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
