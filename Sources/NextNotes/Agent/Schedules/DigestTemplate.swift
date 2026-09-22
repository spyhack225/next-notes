import Foundation

/// P2-3 Morning digest — Option A: digest-first, no web.
///
/// A routine with a fixed prompt over three read tools — `get_agenda`,
/// `search_knowledge`, `search_email` — and nothing else. There are no `news.*`
/// tools, no web fetch, and no Feed surface: the weather block renders only when
/// a tool already returned one, "Around Town" only from calendar or mail items
/// that name a place, and the mail/notes section only from the user's own mail
/// and notes, each item carrying its source and date. Anything the tools did
/// not return is left out, never invented.
///
/// The render shape follows the newsletter anatomy in
/// `roadmap/AGENT-COMPETITOR-GAP-2026-09-20.md` §8.2: masthead with edition +
/// date + city, weather-if-known, "The Week Ahead" day grid, per-person desks,
/// dated watch items, per-item source + date, and "Talk at the Table"
/// questions — plus calendar-overlap callouts.
///
/// Reuse, not new logic:
/// - The run path is the existing routine path (`ScheduledRunner`): the digest
///   prompt is the schedule's `prompt`, its ceiling is `allowedTools` below.
/// - Quiet hours, the presence rule and delivery are the scheduler's
///   (`AgentScheduler`): the default `delivery` is `.notifyAndSpeak`, so a
///   06:00 result waits for quiet hours to end and is spoken only when the
///   user is present.
/// - Silence is `ScheduledRunner.silenceToken`: an empty morning answers
///   exactly that, and the scheduler delivers nothing.
/// - Setup is the existing R2 flow through `schedule.create`
///   (`ScheduleToolExecutor`): restate in consumer words, wait for a yes,
///   create (which test-runs once, visibly, before saving).
///
/// Known tension, documented not patched: `ScheduledRunner`'s system prompt
/// caps a final answer at three sentences, which a sectioned digest cannot
/// meet. The digest prompt below tells the model its final answer *is* the
/// digest in the sections given; changing the runner belongs to another epic,
/// so the override lives here, in words the model reads.
///
/// User-visible strings use consumer words only: "morning digest", "calendar",
/// "notes", "mail", "Library". No cron, routine, schedule, artifact, tool id
/// or schema key reaches the user. The `tools` argument of `schedule.create`
/// still carries the three ids — the ceiling needs them — but the restated
/// sentence names the sources, not the ids.
enum DigestTemplate {
    /// What the user sees everywhere: notifications, lists, the Library key.
    static let title = "Morning digest"

    /// The whole ceiling. Reads only, so a digest run can never draft, send
    /// or change anything — there is nothing above `.read` to hold for
    /// approval.
    static let allowedTools = ["get_agenda", "search_knowledge", "search_email"]

    /// Weekday mornings at six, local wall-clock time. `endsAt` stays unset:
    /// a digest runs until the user pauses or deletes it.
    static let defaultRepeat = "weekdays"
    static let defaultTime = "06:00"

    static let delivery = AgentSchedule.Delivery.notifyAndSpeak
    static let model = AgentSchedule.ModelChoice.auto

    /// The sentence the Agent says before calling `schedule.create`, in
    /// consumer words. The tools the digest uses are named as sources, never
    /// as ids.
    static func restatement() -> String {
        "Every weekday at 6:00 in the morning, I'll put together your morning digest "
            + "from your calendar, notes, and mail: what's on today, the week ahead, "
            + "and anything that needs you. It only reads — it never sends or changes "
            + "anything. Shall I set it?"
    }

    /// The exact arguments for the existing `schedule.create` path. No
    /// `endsOn` key, so `endsAt` stays unset; no `speak` key, so delivery
    /// stays `.notifyAndSpeak` and the presence rule applies.
    static func createArguments() -> [String: String] {
        [
            "kind": "routine",
            "title": title,
            "text": routinePrompt(),
            "tools": allowedTools.joined(separator: ","),
            "model": "auto",
            "repeat": defaultRepeat,
            "time": defaultTime,
        ]
    }

    /// The fixed routine prompt: assembly order plus the render spec. The
    /// model plans its own calls inside the ceiling; this fixes what it reads
    /// and the shape it answers in.
    static func routinePrompt() -> String {
        """
        You prepare the morning digest. It only reads — it never sends, changes, or approves anything.

        Read, in this order:
        1. get_agenda for today and for each of the next 6 days, one call per day.
        2. search_knowledge for open commitments, deadlines, and promises from recent notes.
        3. search_email for messages from the last day that need the user.

        Use only these three tools. Never browse the web, fetch a page, or invent news, weather, places, or events. Every line traces to something a tool returned; each mail or notes item ends with its source and date.

        Write the digest in plain text with these sections, leaving out any section that has nothing in it:
        Morning digest
        Edition: <weekday, day month year>[ · <city from the time zone when it names one>]
        [If a tool returned today's weather, one line: Weather: ... Otherwise leave it out entirely.]
        Today
        - HH:MM title (with people and place when known). Call out overlaps on one line: Overlap: A and B overlap from X to Y.
        The Week Ahead
        - One line per day for the next 7 days: what is on, or nothing.
        For <name> (one block per person who has something; no empty blocks)
        - ...
        Watch these
        - Dated commitments and deadlines, soonest first.
        Around Town (only when a calendar or mail item names a place: reservations, tickets, bookings)
        - ...
        From your mail and notes (each item ends with its source and date: [mail · sender · date] or [notes · title · date])
        - ...
        Talk at the Table
        - Two or three questions the day raises.

        Keep it skimmable: short lines, no filler. Your final answer is the digest itself, in the sections above.
        If the calendar is empty for all 7 days, no mail needs the user, and knowledge has nothing open, answer exactly \(ScheduledRunner.silenceToken) and nothing else.
        """
    }

    /// A display city from an IANA zone id (`America/New_York` → `New York`),
    /// or nil when the id names no city. Local string work, no lookup.
    static func city(forZoneID identifier: String) -> String? {
        let tail = identifier.split(separator: "/").last.map(String.init) ?? ""
        guard !tail.isEmpty, tail != "UTC", tail != "localtime" else { return nil }
        let city = tail.replacingOccurrences(of: "_", with: " ")
        return city.isEmpty ? nil : city
    }
}

// MARK: - Fixture assembly

/// Hand-written morning inputs. Codable so the same corpus doubles as
/// `Tests/Fixtures/digest-corpus.json`; synthetic people and places only.
struct DigestFixture: Codable, Sendable, Equatable {
    struct Day: Codable, Sendable, Equatable {
        var date: String
        var events: [Event]
        /// Stated overlap callout for the day, if any.
        var overlap: String? = nil
    }
    struct Event: Codable, Sendable, Equatable {
        var time: String
        var title: String
        var people: [String] = []
        var place: String? = nil
    }
    struct Desk: Codable, Sendable, Equatable {
        var person: String
        var lines: [String]
    }
    struct MailItem: Codable, Sendable, Equatable {
        var from: String
        var subject: String
        var date: String
        var snippet: String
    }
    struct NoteItem: Codable, Sendable, Equatable {
        var title: String
        var date: String
        var text: String
    }

    /// The morning the digest is for, `YYYY-MM-DD`.
    var edition: String
    /// IANA zone the digest runs in.
    var timeZone: String
    /// Today's weather as a tool returned it, if any. Nil omits the block.
    var weather: String?
    /// Seven days starting with the edition date.
    var days: [Day]
    var desks: [Desk]
    var watch: [String]
    var mail: [MailItem]
    var knowledge: [NoteItem]
    var aroundTown: [String]
    var questions: [String]

    var isEmpty: Bool {
        days.allSatisfy(\.events.isEmpty) && desks.isEmpty && watch.isEmpty
            && mail.isEmpty && knowledge.isEmpty && aroundTown.isEmpty && questions.isEmpty
    }
}

/// Deterministic digest renderer over a fixture: what the anatomy looks like
/// when every section has something, and the silence rule when nothing does.
/// The live run's wording comes from the model via `routinePrompt()`; this
/// proves the sections, the conditionals, and the silence token.
enum DigestAssembler {
    /// Renders the fixture, or exactly the silence token when it is empty.
    static func assemble(_ fixture: DigestFixture) -> String {
        guard !fixture.isEmpty else { return ScheduledRunner.silenceToken }
        var lines: [String] = []
        lines.append(DigestTemplate.title)
        lines.append("Edition: \(editionLine(fixture))")
        if let weather = fixture.weather, !weather.isEmpty {
            lines.append("Weather: \(weather)")
        }
        lines.append("")
        lines.append("Today")
        if let today = fixture.days.first {
            if today.events.isEmpty {
                lines.append("- Nothing on.")
            } else {
                for event in today.events { lines.append("- \(render(event))") }
                if let overlap = today.overlap, !overlap.isEmpty {
                    lines.append("Overlap: \(overlap)")
                }
            }
        }
        lines.append("")
        lines.append("The Week Ahead")
        for day in fixture.days {
            if day.events.isEmpty {
                lines.append("- \(day.date): nothing.")
            } else {
                lines.append("- \(day.date): \(day.events.map(\.title).joined(separator: "; ")).")
            }
        }
        lines.append("")
        for desk in fixture.desks where !desk.lines.isEmpty {
            lines.append("For \(desk.person)")
            for line in desk.lines { lines.append("- \(line)") }
            lines.append("")
        }
        if !fixture.watch.isEmpty {
            lines.append("Watch these")
            for item in fixture.watch { lines.append("- \(item)") }
            lines.append("")
        }
        if !fixture.aroundTown.isEmpty {
            lines.append("Around Town")
            for item in fixture.aroundTown { lines.append("- \(item)") }
            lines.append("")
        }
        if !fixture.mail.isEmpty || !fixture.knowledge.isEmpty {
            lines.append("From your mail and notes")
            for item in fixture.mail {
                lines.append("- \(item.subject) — \(item.snippet) [mail · \(item.from) · \(item.date)]")
            }
            for item in fixture.knowledge {
                lines.append("- \(item.title) — \(item.text) [notes · \(item.title) · \(item.date)]")
            }
            lines.append("")
        }
        if !fixture.questions.isEmpty {
            lines.append("Talk at the Table")
            for question in fixture.questions {
                let marked = question.hasSuffix("?") ? question : question + "?"
                lines.append("- \(marked)")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func editionLine(_ fixture: DigestFixture) -> String {
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: fixture.timeZone) ?? .current
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        var text = fixture.edition
        if let date = formatter.date(from: fixture.edition) {
            formatter.dateFormat = "EEEE, d MMMM yyyy"
            text = formatter.string(from: date)
        }
        if let city = DigestTemplate.city(forZoneID: fixture.timeZone) {
            text += " · \(city)"
        }
        return text
    }

    private static func render(_ event: DigestFixture.Event) -> String {
        var text = "\(event.time) \(event.title)"
        if !event.people.isEmpty { text += " (\(event.people.joined(separator: ", ")))" }
        if let place = event.place, !place.isEmpty { text += " at \(place)" }
        return text
    }
}

// MARK: - Result envelope

/// What one digest run hands on: plain result text plus a title. The existing
/// pipeline already carries both — `ScheduleDelivery` (`title`, `body`) for
/// the notification and `AgentTask` (`objective`, `result`, source
/// `"scheduled"`) for Activity and, later, the Library.
///
/// The Library convention (`AgentTask.artifacts: [String]`) consumes path or
/// URL strings plus a title. A reads-only digest writes no file, so
/// `artifactReference` is nil and the Library keys the item by `libraryKey`
/// (title + edition date). When a file-backed digest lands, its path goes in
/// `artifactReference` — and as a `Saved: <path>` line the card renders —
/// without changing this shape.
struct DigestResult: Sendable, Equatable {
    var title: String
    var text: String
    var artifactReference: String?
    var libraryKey: String

    static func make(edition: String, text: String, artifactReference: String? = nil) -> DigestResult {
        DigestResult(
            title: "\(DigestTemplate.title) · \(edition)",
            text: text,
            artifactReference: artifactReference,
            libraryKey: "\(DigestTemplate.title) · \(edition)")
    }
}
