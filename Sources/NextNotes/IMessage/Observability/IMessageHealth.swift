import Foundation

/// IM-17e — the canary: a macOS update can make every inbound message
/// undecodable, and the only signal is a count of undecodable messages.
///
/// A count is a metric, and a metric is not observability for a person — so
/// this is a count plus a threshold plus a destination plus a sentence. The
/// threshold has two halves because each exists for a specific false alarm: a
/// minimum of 10 (an effect bubble and a handful of MMS rows can never trigger
/// it — a canary that fires on ordinary use gets muted, and a muted canary is
/// worse than none) and a fraction of 0.20 (ten failures spread over a year
/// are not a break; a decoder break is nearly total). One notification per 24
/// hours, because a break would otherwise flood on the one day the person most
/// needs to read it.
///
/// Only `MessageDecodeFailure` cases that mean *the format changed* count.
/// Everything else a row can be — a photo, a tapback, an SMS with no body, our
/// own bounds, a stream that parsed but holds no string — is ordinary use or
/// our own doing, and counting any of it fires the canary on a normal day.
struct IMessageCanary: Equatable, Sendable {
    /// How far back the window looks, in hours.
    var windowHours = 24
    /// Messages considered from the paired chat.
    var seen = 0
    /// The §4.1 three cases only.
    var unreadable = 0
    var lastNotifiedAt: Date?
    /// At least this many unreadable before anything can fire.
    var breakMinimum = 10
    /// At least this fraction unreadable: a break is nearly total.
    var breakFraction = 0.20
    /// One notification per window.
    var notifyCooldownHours = 24

    var isBroken: Bool {
        unreadable >= breakMinimum && seen > 0
            && Double(unreadable) / Double(seen) >= breakFraction
    }

    /// Records one row's outcome. Readable and non-text rows move `seen` only;
    /// failures move both counters only when they mean a format change.
    mutating func note(_ outcome: RowOutcome) {
        switch outcome {
        case .readable, .nonText:
            seen += 1
        case .unreadable(let failure):
            seen += 1
            if Self.counts(failure) { unreadable += 1 }
        }
    }

    /// Whether the format changed, for one decode failure. `notAString` does not
    /// count: the stream parsed and holds no string, which is a successful read
    /// of a non-text balloon — closer to `.notText` than to a new header.
    /// `truncated` and `tooLarge` are our own bounds, not Apple's format.
    static func counts(_ failure: MessageDecodeFailure) -> Bool {
        switch failure {
        case .unsupportedStreamVersion, .notATypedStream, .structureUnreadable:
            true
        case .truncated, .tooLarge, .notAString:
            false
        }
    }

    /// Whether to notify now: broken, and no notification inside the cooldown.
    func shouldNotify(now: Date) -> Bool {
        guard isBroken else { return false }
        guard let last = lastNotifiedAt else { return true }
        return now.timeIntervalSince(last) >= Double(notifyCooldownHours) * 3600
    }

    mutating func markNotified(at date: Date) {
        lastNotifiedAt = date
    }

    /// One row, as the canary sees it. Text never enters: the question is only
    /// whether the row could be read.
    enum RowOutcome: Equatable, Sendable {
        case readable
        case unreadable(MessageDecodeFailure)
        /// `.notText`, `.absent`, an SMS, an ordinary body — anything successfully
        /// classified that is not words.
        case nonText
    }
}

/// Every sentence the canary shows, in one place. §4.3 verbatim: the fear is
/// answered before it is raised (nothing was lost — the read path is
/// read-only), the cause is named honestly, blame is removed, and the scope is
/// bounded. No button: there is no action that helps until the app is updated.
enum IMessageCanaryCopy {
    static let notificationTitle = "Next Notes can't read your messages"
    static let notificationBody =
        "Your messages are still in Messages and nothing was lost. This can happen after a macOS update — "
        + "it isn't something you did, and the rest of Next Notes keeps working."
    static let settingsRow = "Messages it couldn't read"
    static let settingsNote =
        "Nothing was lost and nothing was deleted — Next Notes only reads. This usually follows a macOS update."
}
