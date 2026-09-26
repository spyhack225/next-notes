import Foundation

/// A speaker-count constraint for one diarization pass, read from the meeting itself.
///
/// The diarizer otherwise clusters blind: a 1:1 WhatsApp call and a six-person standup
/// get the same treatment, and the over-split case is what a person then renames by hand
/// (I2 #3: three of six meetings). A hint binds only the upper bound — the model may
/// still find fewer voices — and only `numSpeakers`, set by a person from the speaker
/// sheet, forces an exact count. Nothing here guesses a browser's call: Chrome might be
/// holding a one-to-one or a webinar, and nothing cheap tells them apart.
struct SpeakerCountHint: Equatable, Sendable {
    /// Never more far-end clusters than this.
    var maxSpeakers: Int?
    /// An exact count, set only by a person ("Identify again with N speakers").
    /// Overrides `maxSpeakers` — FluidAudio treats it as a target, not a bound.
    var numSpeakers: Int?

    /// Apps whose call is, by the shape of the app, one far voice plus slack.
    ///
    /// A messaging or FaceTime-class app holds one audio call per window; a second voice
    /// on its system track is a group call, which `maxSpeakers = 2` still admits and
    /// "Identify again" fixes by hand. Slack huddles are deliberately not here — a huddle
    /// and a multi-person channel share the app, so the count says nothing. Browsers and
    /// unknown apps get no hint at all.
    static let messagingBundleIDs: Set<String> = [
        "net.whatsapp.WhatsApp",
        "com.apple.FaceTime",
        "com.apple.avconferenced",
        "com.apple.MobileSMS",
        "ru.keepcoder.Telegram",
    ]

    /// The hint one meeting's own shape supports, or nil for none.
    ///
    /// A detected call from a messaging/FaceTime-class app with no attendee list gets
    /// `maxSpeakers = 2`: one far voice plus slack for a second. A calendar meeting with
    /// attendees gets `maxSpeakers = max(2, attendees.count)` — the microphone track
    /// already holds "You", so the attendees bound the far end. Everything else — a
    /// browser call, an unknown app, a hand-started recording — clusters blind.
    static func `for`(_ meeting: Meeting) -> SpeakerCountHint? {
        if meeting.isDetectedCall {
            // `CallDetector.event(for:)` mints these with an empty attendee list; a
            // meeting that somehow carries attendees is not that shape, and the
            // attendee branch below is the more informed bound.
            guard meeting.attendees.isEmpty else { return nil }
            guard let bundle = detectedCallBundleID(of: meeting),
                  messagingBundleIDs.contains(bundle) else { return nil }
            return SpeakerCountHint(maxSpeakers: 2)
        }
        guard !meeting.attendees.isEmpty else { return nil }
        return SpeakerCountHint(maxSpeakers: max(2, meeting.attendees.count))
    }

    /// The bundle id inside a detected call's `calendarEventID`.
    ///
    /// `CallDetector.identity(of:)` writes `"<bundleID>@<unix seconds>"` (or
    /// `"pid-<pid>@…"` when the process had no bundle). The id never contains a second
    /// `@`, and a pid-prefixed id is deliberately not an app, so it reads back nil.
    static func detectedCallBundleID(of meeting: Meeting) -> String? {
        guard let id = meeting.calendarEventID, let at = id.lastIndex(of: "@") else { return nil }
        let bundle = String(id[id.startIndex..<at])
        return bundle.isEmpty ? nil : bundle
    }
}
