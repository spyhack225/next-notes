import Foundation

/// The session's own capture facts, read by the pure coverage evaluator
/// (MR-02 / MR-04).
///
/// The evaluator is a function over facts; the session is where the facts live.
/// The conformance is one line because the session already holds both of them —
/// the persisted capture integrity on the meeting, and the frame-shape verdict
/// the capture path produces — and inventing a second copy of either would be
/// a second ledger.
/// The coverage message the live meeting pane can show, when the recording is
/// known to be short.
extension MeetingSession {
    /// The plain-words coverage sentence, or nil when nothing is known to be
    /// missing. A meeting that is still recording with no loss has no message:
    /// "we don't know yet" is not a warning, and a warning that fires on every
    /// healthy meeting is a warning nobody reads.
    var coverageWarningMessage: String? { coverageMessage }
}
