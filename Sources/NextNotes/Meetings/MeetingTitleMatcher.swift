import Foundation

/// Matches a settled call against the calendar events near it, so the recording it
/// produces can carry the event's own title where the evidence supports it (MR-01).
///
/// `CallPolicy.calendarMatch` answers a different, earlier question — which event should
/// this call attach to, for arming — and is nearest-wins on purpose. This matcher asks a
/// narrower one: is there **one** event this call provably is, on evidence strong enough
/// to title a recording after? It refuses to guess. Two events that fit the clock are
/// ambiguous, and a join link that was offered and matched no candidate beats the clock
/// outright.
///
/// Pure and deterministic — no clock, no store, no account — so
/// `--selftest-meeting-title-match` can drive every rule from a terminal.
enum MeetingTitleMatcher {
    /// How a call and one stretch of calendar were related, if at all.
    struct Match: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// The event is this call's meeting on evidence strong enough to title a
            /// recording with it: a join-URL hit, or exactly one event in the window.
            case exactEvent
            /// The window fits but the evidence is not conclusive — a join link was
            /// offered and matched no candidate. Never a title on its own.
            case probableEvent
            case none
        }

        /// Why the matcher answered the way it did. Logged and printed by diagnostics as
        /// a reason, never as a claim about which meeting the call actually was.
        enum Reason: String, Sendable, Equatable {
            case joinURLMatch
            case singleWindowMatch
            case renamedCall = "renamedOrMovedCall"
            case ambiguousEvents
            case noWindowMatch
            case noCandidates
        }

        var kind: Kind
        var event: MeetingEvent?
        var reason: Reason
    }

    /// Which events the clock says the call could be, and whether any carries its link.
    ///
    /// `callStart` is when the call was detected; the window is the same
    /// `CallPolicy.correlationWindow` arming uses, never widened here. A non-empty
    /// `joinURLFragment` — the meeting id inside a Meet/Teams/Zoom link — outranks the
    /// clock entirely, because it is evidence the arming rule never sees. Callers pass
    /// nil when the call side carries no link; the branch is still the first one asked.
    static func match(
        candidates: [MeetingEvent],
        callStart: Date,
        joinURLFragment: String? = nil
    ) -> Match {
        // A day block is a day, not a meeting; a declined invitation is not one the user
        // is attending. Both filters mirror `calendarMatch`, so the two rules never
        // disagree about which events are shaped like meetings at all.
        let usable = candidates.filter { !$0.isAllDay && $0.isOrganizerOrSelfAccepted }
        guard !usable.isEmpty else {
            return Match(kind: .none, event: nil, reason: .noCandidates)
        }

        // One-sided on purpose. `CallPolicy.covers` is symmetric — it admits an
        // event for a while after it ended, which is right for arming a meeting
        // that is about to start and wrong for naming a recording: a meeting
        // that ended ten minutes ago must not lend its name to a call that
        // began after it.
        let windowed = usable.filter {
            $0.end > callStart && $0.start.addingTimeInterval(-CallPolicy.correlationWindow) <= callStart
        }

        if let fragment = normalized(joinURLFragment) {
            // The link names the meeting outright, so it is looked for among
            // every usable candidate: a link that names an event the clock does
            // not hold is still that event — a renamed or moved one.
            let hits = usable.filter { carries($0, fragment: fragment) }
            if hits.count == 1 {
                return Match(kind: .exactEvent, event: hits[0], reason: .joinURLMatch)
            }
            if hits.count > 1 {
                return Match(kind: .none, event: nil, reason: .ambiguousEvents)
            }
            // The link names a meeting the window does not hold — a renamed or moved
            // event, or one the fetch missed. Time alone is not enough to title a
            // recording with a different event's name, so the best the matcher can say
            // is "probably that one, not provably".
            if windowed.count == 1 {
                return Match(kind: .probableEvent, event: windowed[0], reason: .renamedCall)
            }
            if windowed.count > 1 {
                return Match(kind: .none, event: nil, reason: .ambiguousEvents)
            }
            return Match(kind: .none, event: nil, reason: .noWindowMatch)
        }

        switch windowed.count {
        case 1:
            return Match(kind: .exactEvent, event: windowed[0], reason: .singleWindowMatch)
        case 2...:
            return Match(kind: .none, event: nil, reason: .ambiguousEvents)
        default:
            return Match(kind: .none, event: nil, reason: .noWindowMatch)
        }
    }

    /// The same visible text composed or decomposed is the same text.
    ///
    /// macOS hands strings out decomposed and calendar payloads arrive composed, so an
    /// exact-string compare is how "Café" stopped counting as two different names and the
    /// update below would have applied over a title that already said the same thing.
    static func sameTitle(_ left: String, _ right: String) -> Bool {
        nfc(left) == nfc(right)
    }

    static func nfc(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    /// What saving the matched event's title would actually change on `meeting`.
    ///
    /// Nil when there is nothing to apply, which is the whole safety story: no exact
    /// match; the stored title is the same text already; or the title was typed by hand
    /// (`effectiveTitleSource == .user`) and differs from the event's — a manual name
    /// always wins, in either direction.
    ///
    /// The update keeps every other field and stamps `.auto`, which the list renders
    /// dimmed — provisional, which is honest for a title the app chose for a recording
    /// nobody scheduled. `MeetingStore.save` would stamp `.calendar` instead when
    /// `titleSource` is nil and a calendar link is present, but that stamp is for the
    /// event's *own* meeting; this path runs on the detected-call row, whose
    /// `calendarEventID` names the call rather than the event.
    static func titleUpdate(for meeting: Meeting, match: Match) -> Meeting? {
        guard match.kind == .exactEvent, let event = match.event else { return nil }
        if meeting.effectiveTitleSource == .user { return nil }
        // The evidence counts as a difference only when the row is MISSING it.
        // Filling in what is missing is idempotent; overwriting what the row
        // already carries would rewrite it on every tick, and the row's own
        // evidence is not the event's to take.
        let missingAttendees = !event.attendees.isEmpty && meeting.attendees.isEmpty
        let missingCalendarName = meeting.calendarName == nil && event.calendarName != nil
        let evidenceDiffers = missingAttendees || missingCalendarName
        if sameTitle(meeting.title, event.title) && !evidenceDiffers { return nil }
        var updated = meeting
        updated.title = event.title
        // The source says where the title came from. A row armed FOR this
        // event keeps the calendar's own source; a detected call that matched
        // the event takes the app's own, because the call was not armed for it.
        updated.titleSource = meeting.calendarEventID == event.id ? .calendar : .auto
        // The evidence the title came with: the people who were invited, and
        // the calendar it was on. A title alone leaves the notes unable to
        // resolve "Ana said" against a transcript that only knows "Others".
        // The room is not copied: it is the event's link, and the detail page
        // would render a link to a meeting that has already happened as this
        // recording's own join link.
        if missingAttendees { updated.attendees = event.attendees }
        if missingCalendarName { updated.calendarName = event.calendarName }
        return updated
    }

    /// A fragment worth testing: trimmed of surrounding space, empty treated as absent.
    private static func normalized(_ fragment: String?) -> String? {
        guard let fragment else { return nil }
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the event's conference link carries the fragment in its path or
    /// query, which is how a Meet id (`meet.google.com/abc-defg-hij`), a Teams
    /// join link and a Zoom room number all answer with one rule. Case-sensitive:
    /// link paths are.
    ///
    /// The path and the query, not the whole URL: a fragment is a room, and a
    /// room is not a scheme or a host. Matching the whole string would let one
    /// provider's fragment answer for another's link.
    private static func carries(_ event: MeetingEvent, fragment: String) -> Bool {
        guard let url = event.conferenceURL else { return false }
        let path = url.path
        let query = url.query ?? ""
        return path.contains(fragment) || query.contains(fragment)
    }
}
