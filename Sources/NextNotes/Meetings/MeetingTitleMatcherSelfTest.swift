import Foundation

/// `--selftest-meeting-title-match`: a settled call takes its meeting's real title only
/// where the evidence is exact (MR-01), and a calendar-fetch failure is traceable as a
/// provider-and-stage fact with no content in it (MR-06).
///
/// `MeetingTitleMatcher` is the pure rule behind two production wirings: the settle path
/// in `MeetingScheduler.answer`, and the tick that catches a detected-call meeting up
/// with a calendar that answered late. Every rule is driven here from fixtures — no
/// store, no calendar, no account, nothing written — because the evidence the rule reads
/// (a call's join link, a fetch that failed) is exactly what this repo cannot hand a
/// self-test.
///
/// Every case is capable of failing: the fixtures pin the event id the match must name,
/// the reason it must give, and the title a save must apply. The fetch-failure half runs
/// the real `CalendarService.fetchFailureStage` classifier and the fact the service
/// stores, never the human `lastError` sentence.
enum MeetingTitleMatcherSelfTest {
    static func run(write: (String) -> Void) -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append(name) }
        }

        let start = Date(timeIntervalSince1970: 1_760_000_000)
        func event(
            id: String,
            title: String,
            from offset: TimeInterval = -5 * 60,
            for duration: TimeInterval = 60 * 60,
            link: String? = nil,
            endingBefore: TimeInterval? = nil
        ) -> MeetingEvent {
            let end = endingBefore.map { start.addingTimeInterval(-$0) }
                ?? start.addingTimeInterval(offset + duration)
            return MeetingEvent(
                id: id,
                providerID: .google,
                title: title,
                start: start.addingTimeInterval(offset),
                end: end,
                attendees: ["Fixture Person <fixture@example.com>"],
                isOrganizerOrSelfAccepted: true,
                conferenceURL: link.flatMap { URL(string: $0) },
                calendarName: "Fixture",
                isAllDay: false
            )
        }

        // a. A join link names the event outright, and a fragment that is only the
        // meeting id matches the same way a full path does.
        do {
            let meet = event(
                id: "meet-a",
                title: "Weekly stand-up",
                link: "https://meet.google.com/abc-defg-hij?usp=sharing"
            )
            let match = MeetingTitleMatcher.match(
                candidates: [meet], callStart: start, joinURLFragment: "abc-defg-hij"
            )
            check("join URL did not name the event (kind \(match.kind), reason \(match.reason))",
                  match.kind == .exactEvent && match.event?.id == "meet-a"
                    && match.reason == .joinURLMatch)
            // The fragment is a room, and a room is a path or a query value —
            // not a host. A fragment that includes the host does not match the
            // same link, and saying so is the point.
            let path = MeetingTitleMatcher.match(
                candidates: [meet], callStart: start, joinURLFragment: "abc-defg-hij"
            )
            check("the room id did not match the same link",
                  path.kind == .exactEvent && path.event?.id == "meet-a")
            let hostFragment = MeetingTitleMatcher.match(
                candidates: [meet], callStart: start, joinURLFragment: "meet.google.com/abc"
            )
            check("a fragment naming the host matched the link",
                  hostFragment.kind != .exactEvent)
            write("TITLE_MATCH_CASE join-url pass=\(match.kind == .exactEvent && path.kind == .exactEvent)")
        }

        // b. One event in the window is exact; nothing in the window, or nothing at all,
        // answers none with the reason that says which.
        do {
            let solo = event(id: "solo", title: "Design review")
            let match = MeetingTitleMatcher.match(candidates: [solo], callStart: start)
            check("unique window match was not exact (reason \(match.reason))",
                  match.kind == .exactEvent && match.event?.id == "solo"
                    && match.reason == .singleWindowMatch)
            let far = MeetingTitleMatcher.match(
                candidates: [event(id: "far", title: "Much later", from: 60 * 60)],
                callStart: start
            )
            check("an event outside the window was matched",
                  far.kind == .none && far.reason == .noWindowMatch)
            let empty = MeetingTitleMatcher.match(candidates: [], callStart: start)
            check("no candidates did not report noCandidates",
                  empty.kind == .none && empty.reason == .noCandidates)
            // A meeting that ended five minutes before the call began is not
            // the meeting this call was about, however near the two are.
            let ended = MeetingTitleMatcher.match(
                candidates: [event(
                    id: "ended", title: "Just ended",
                    from: -60 * 60, endingBefore: 5 * 60)],
                callStart: start)
            check("a meeting that had already ended lent its name to a later call",
                  ended.kind == .none && ended.reason == .noWindowMatch)
            write("TITLE_MATCH_CASE window pass=\(match.kind == .exactEvent && far.kind == .none && empty.reason == .noCandidates)")
        }

        // b2. The evidence the title came with travels with it: the people who
        // were invited and the room the meeting was in.
        do {
            var meeting = Meeting(
                id: UUID(), title: "Zoom call", start: start, status: .recording)
            meeting.providerID = CalendarProviderID.detectedCall.rawValue
            // A detected-call row carries the call's identity, which is what
            // makes its title provisional rather than typed.
            meeting.calendarEventID = "com.example.zoom@1760000000"
            let invited = event(
                id: "invited", title: "Quarterly review",
                link: "https://meet.google.com/abc-defg-hij")
            let match = MeetingTitleMatcher.match(candidates: [invited], callStart: start)
            if let updated = MeetingTitleMatcher.titleUpdate(for: meeting, match: match) {
                check("the matched title was not applied", updated.title == "Quarterly review")
                check("the title's source was not stamped", updated.titleSource == .auto)
                check("the invited people did not travel with the title",
                      updated.attendees == invited.attendees)
                check("the calendar's name did not travel with the title",
                      updated.calendarName == invited.calendarName)
            } else {
                check("the title update was refused for a matched event", false)
            }
        }

        // c. Two events that both fit the clock are ambiguous — never the first, never
        // the calendar's own order — and a link breaks the tie only when it is unique.
        do {
            let a = event(id: "tie-a", title: "Ops sync")
            let b = event(id: "tie-b", title: "Design sync")
            let ambiguous = MeetingTitleMatcher.match(candidates: [a, b], callStart: start)
            check("two simultaneous events were not ambiguous",
                  ambiguous.kind == .none && ambiguous.reason == .ambiguousEvents)
            let linked = event(
                id: "tie-b", title: "Design sync", link: "https://meet.google.com/xyz-abcd-wxy"
            )
            let broken = MeetingTitleMatcher.match(
                candidates: [a, linked], callStart: start, joinURLFragment: "xyz-abcd-wxy"
            )
            check("a unique link did not break the tie (reason \(broken.reason))",
                  broken.kind == .exactEvent && broken.event?.id == "tie-b"
                    && broken.reason == .joinURLMatch)
            let shared = event(
                id: "tie-a", title: "Ops sync", link: "https://meet.google.com/same-room"
            )
            let twin = event(
                id: "tie-a-twin", title: "Ops sync", link: "https://meet.google.com/same-room"
            )
            let sharedMatch = MeetingTitleMatcher.match(
                candidates: [shared, twin], callStart: start, joinURLFragment: "same-room"
            )
            check("two events carrying one link were not ambiguous",
                  sharedMatch.kind == .none && sharedMatch.reason == .ambiguousEvents)
            write("TITLE_MATCH_CASE ambiguous pass=\(ambiguous.kind == .none && broken.event?.id == "tie-b" && sharedMatch.kind == .none)")
        }

        // d. Unicode titles: composed and decomposed are one name, and a long composed
        // title passes through the match byte-for-byte.
        do {
            let composed = "Café planning — Ünïcödé rëview, session deux"
            let decomposed = composed.decomposedStringWithCanonicalMapping
            check("composed and decomposed titles are not the same name",
                  MeetingTitleMatcher.sameTitle(composed, decomposed))
            check("distinct titles counted as equal",
                  !MeetingTitleMatcher.sameTitle(composed, composed + " v2"))
            let uni = event(id: "uni", title: composed)
            let match = MeetingTitleMatcher.match(candidates: [uni], callStart: start)
            check("Unicode title did not pass through unchanged",
                  match.event?.title == composed)
            var already = Meeting(
                title: decomposed,
                start: start,
                calendarEventID: "call-identity@1729000000",
                providerID: CalendarProviderID.detectedCall.rawValue
            )
            // The row carries the evidence too, so the only thing this case can
            // be about is the composed/decomposed comparison.
            already.attendees = uni.attendees
            already.calendarName = uni.calendarName
            check("an NFC-equal title was offered an update anyway",
                  MeetingTitleMatcher.titleUpdate(for: already, match: match) == nil)
            // The other half, which the evidence rule owns: a row with the same
            // title and no evidence is offered the evidence.
            var withoutEvidence = already
            withoutEvidence.attendees = []
            withoutEvidence.calendarName = nil
            check("a row missing the evidence was offered no update",
                  MeetingTitleMatcher.titleUpdate(for: withoutEvidence, match: match) != nil)
            write("TITLE_MATCH_CASE unicode pass=\(MeetingTitleMatcher.sameTitle(composed, decomposed) && match.event?.title == composed)")
        }

        // e. A link that names no candidate over the window: probable, never exact, and
        // a probable match never titles a recording.
        do {
            let renamed = event(
                id: "renamed", title: "Q4 planning", link: "https://meet.google.com/other-room"
            )
            let match = MeetingTitleMatcher.match(
                candidates: [renamed], callStart: start, joinURLFragment: "gone-meeting"
            )
            check("unmatched link over one window was not probable (reason \(match.reason))",
                  match.kind == .probableEvent && match.event?.id == "renamed"
                    && match.reason == .renamedCall)
            let adHoc = Meeting(
                title: "Zoom call",
                start: start,
                calendarEventID: "call-identity@1729000001",
                providerID: CalendarProviderID.detectedCall.rawValue
            )
            check("a probable match titled a recording",
                  MeetingTitleMatcher.titleUpdate(for: adHoc, match: match) == nil)
            write("TITLE_MATCH_CASE renamed pass=\(match.kind == .probableEvent && MeetingTitleMatcher.titleUpdate(for: adHoc, match: match) == nil)")
        }

        // f. The fetch-failure fact: the classifier reads the error's case only, stages
        // each kind correctly, and the stored fact reflects no content strings.
        do {
            check("HTTP refusal did not stage as api",
                  CalendarService.fetchFailureStage(
                    for: GoogleCalendarError.requestFailed(
                        status: 403, reason: "fixture-secret@example.com"
                    )
                ) == .api)
            check("a revoked grant did not stage as auth",
                  CalendarService.fetchFailureStage(for: GoogleCalendarError.accessRevoked) == .auth)
            check("a token failure did not stage as auth",
                  CalendarService.fetchFailureStage(
                    for: GoogleCalendarError.tokenRequestFailed(
                        status: 400, reason: "fixture-secret@example.com"
                    )
                ) == .auth)
            check("a network error did not stage as network",
                  CalendarService.fetchFailureStage(for: URLError(.notConnectedToInternet)) == .network)
            let failure = CalendarFetchFailure(
                providerID: .google,
                stage: .api,
                occurredAt: start
            )
            let reflected = String(reflecting: failure)
            check("fetch-failure fact reflects content",
                  !reflected.contains("fixture-secret") && !reflected.contains("@")
                    && !reflected.contains("http"))
            check("fetch-failure fact names the wrong provider",
                  failure.providerID == .google && failure.stage == .api)
            write("TITLE_MATCH_CASE fetch-failure pass=\(failure.stage == .api && !reflected.contains("@"))")
        }

        // g. The store's title-source contract: an exact match applies the full title as
        // `.auto`, and a name typed by hand is never replaced in either direction.
        do {
            let meet = event(id: "source-contract", title: "Budget review")
            let exact = MeetingTitleMatcher.match(candidates: [meet], callStart: start)
            var detected = Meeting(
                title: "Zoom call",
                start: start,
                calendarEventID: "call-identity@1729000002",
                providerID: CalendarProviderID.detectedCall.rawValue
            )
            let updated = MeetingTitleMatcher.titleUpdate(for: detected, match: exact)
            check("exact match did not apply the full title",
                  updated?.title == "Budget review" && updated?.titleSource == .auto)
            check("title update changed an unrelated field",
                  updated?.calendarEventID == detected.calendarEventID
                    && updated?.status == detected.status)
            detected.title = "My own name for this"
            detected.titleSource = .user
            check("a manual title was replaced by the event's",
                  MeetingTitleMatcher.titleUpdate(for: detected, match: exact) == nil)
            let none = MeetingTitleMatcher.Match(kind: .none, event: nil, reason: .noWindowMatch)
            var other = Meeting(
                title: "Something else",
                start: start,
                calendarEventID: "call-identity@1729000003",
                providerID: CalendarProviderID.detectedCall.rawValue
            )
            check("a non-exact match was applied",
                  MeetingTitleMatcher.titleUpdate(for: other, match: none) == nil)
            other.title = "Budget review"
            other.titleSource = nil
            // The row has the title but not the people who were invited, so
            // the update still has something to add.
            check("a row missing the evidence was offered no update",
                  MeetingTitleMatcher.titleUpdate(for: other, match: exact) != nil)
            other.attendees = exact.event?.attendees ?? []
            other.calendarName = exact.event?.calendarName
            check("a row that already has the title and the evidence was offered an update",
                  MeetingTitleMatcher.titleUpdate(for: other, match: exact) == nil)
            write("TITLE_MATCH_CASE title-source pass=\(updated?.titleSource == .auto && MeetingTitleMatcher.titleUpdate(for: detected, match: exact) == nil)")
        }

        // h. The same inputs answer the same way every time — the calendar's own order
        // is not promised, so determinism is the rule, not luck.
        do {
            let a = event(id: "det-a", title: "One")
            let b = event(id: "det-b", title: "Two")
            let first = MeetingTitleMatcher.match(
                candidates: [a, b], callStart: start, joinURLFragment: nil
            )
            let second = MeetingTitleMatcher.match(
                candidates: [b, a], callStart: start, joinURLFragment: nil
            )
            check("the same candidates answered differently when reordered",
                  first == second)
            write("TITLE_MATCH_CASE deterministic pass=\(first == second)")
        }

        // The app prints the failures; printing them here as well would show
        // every one of them twice.

        write("TITLE_MATCH_CASE_RESULT checks=\(checks) wrong=\(failures.count)")
        return failures
    }
}
