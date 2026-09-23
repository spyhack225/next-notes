import Foundation

/// The morning podcast — Option B of the long-form audio decision in
/// `roadmap/AGENT-COMPETITOR-GAP-2026-09-20.md` §8.3.
///
/// A routine like the morning digest, with one difference: its answer is a file, not
/// only text. The model reads the same three read-only tools, writes a two-host script
/// about yesterday, and `LongFormRenderer` turns that script into one audio file in the
/// app's Library. The notification says it is ready; the audio is never played into a
/// call, never published, and never leaves the Mac unless the user moves it.
///
/// Reuse, not new logic:
/// - The run path is `ScheduledRunner`: the prompt below is the schedule's `prompt`, the
///   ceiling is `allowedTools`, and silence is `ScheduledRunner.silenceToken`.
/// - The render step is the runner's `ScheduledAnswerTransform` seam. It runs inside the
///   run, so the same `AgentTask` that records the run also carries the file, which is
///   what the Library reads.
/// - Delivery is the scheduler's: `.notifyAndSpeak` means "notification, and speak only
///   when the user is present and not in a call". What is spoken is the one-line
///   announcement, never the script and never the file.
/// - Setup is the existing R2 flow through `schedule.create`, in consumer words.
///
/// Known tension, documented not patched: the render happens inside the scheduler's
/// serial pass, so a five-minute briefing occupies the pass chain for as long as the
/// voice takes. The 4–8 minute script cap bounds it. Moving renders off the pass chain
/// belongs to the scheduler, not this template. The runner's system prompt also caps a
/// final answer at three sentences, which a script cannot meet; the prompt below tells
/// the model its final answer *is* the script, the same override the digest makes in
/// words the model reads. Changing the runner belongs to another epic.
///
/// User-visible strings use consumer words only — "your morning podcast", "Library",
/// "calendar", "notes", "mail", "Settings". No cron, routine, schedule, artifact, tool
/// id or schema key reaches the user. The `tools` argument of `schedule.create` still
/// carries the three ids, because the ceiling needs them; the restatement names the
/// sources, not the ids.
enum PodcastTemplate {
    /// What the user sees everywhere: notifications, lists, the Library item.
    static let title = "Your morning podcast"

    /// The whole ceiling. Reads only — nothing here can draft, send or change anything,
    /// so a run never holds a draft for approval.
    static let allowedTools = ["get_agenda", "search_knowledge", "search_email"]

    /// Weekday mornings at six, like the digest: ready before the day starts. No end
    /// date; the user pauses or deletes it.
    static let defaultRepeat = "weekdays"
    static let defaultTime = "06:00"

    static let delivery = AgentSchedule.Delivery.notifyAndSpeak
    static let model = AgentSchedule.ModelChoice.auto

    /// The Library item's stable name. One edition per day; a re-run replaces it.
    static func libraryKey(edition: String) -> String {
        "\(title) · \(edition)"
    }

    /// The sentence the Agent says before calling `schedule.create`. Sources are named
    /// as sources; the local, private, deletable nature is stated up front because it is
    /// the whole reason this artifact is allowed to exist.
    static func restatement() -> String {
        "Every weekday at 6:00 in the morning, I'll put together your morning podcast "
            + "from your calendar, notes, and mail: a short two-host briefing on yesterday — "
            + "what happened, what was decided, and what's next. It's made on your Mac, "
            + "saved in your Library, and never published anywhere. It only reads — it never "
            + "sends or changes anything. Shall I set it?"
    }

    /// The exact arguments for the existing `schedule.create` path. No `endsOn` key, so
    /// `endsAt` stays unset; no `speak` key, so delivery stays `.notifyAndSpeak` and the
    /// presence rule keeps the announcement out of calls.
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

    /// The fixed routine prompt: what to read, and the shape of the script. The model
    /// plans its own calls inside the ceiling; this fixes the sections, the two hosts,
    /// the length, and the silence rule.
    static func routinePrompt() -> String {
        """
        You prepare a short two-host audio briefing about yesterday and today. It only reads — it never sends, changes, or approves anything.

        Read, in this order:
        1. get_agenda for yesterday and for today, one call per day.
        2. search_knowledge for decisions, open commitments, and deadlines from the last day.
        3. search_email for messages since yesterday that need the user.

        Use only these three tools. Never browse the web, fetch a page, or invent anything. Every line traces to what a tool returned.

        Then write the script exactly in this shape, with these section headings:
        ## What happened
        Host A: ...
        Host B: ...
        ## Decisions
        Host A: ...
        Host B: ...
        ## What's next
        Host A: ...
        Host B: ...

        Rules:
        - Host A frames and asks; Host B answers and adds detail. Keep each turn to one to three spoken sentences.
        - Four to eight minutes when read aloud, about 600 to 900 words in total. Shorter is fine; never pad.
        - Plain spoken language. No URLs, no file paths, no bullet points, no markdown emphasis, no stage directions.
        - Two voices read this script and it is saved as audio on the user's Mac. It stays private and is never published; the user deletes it whenever they like.
        - Your final answer is the script itself, in the sections above — nothing else.

        If yesterday and today hold nothing worth telling the user, answer exactly \(ScheduledRunner.silenceToken) and nothing else.
        """
    }

    // MARK: - The render step

    /// The runner transform that turns a finished script into a file.
    ///
    /// Only this template's schedules are touched: any other routine's answer passes
    /// through unchanged. Silence never reaches here at all — `ScheduledRunner` turns
    /// the token into `.nothingToReport` before a transform would run — and the guard
    /// below keeps that true if the seam is ever called directly.
    @MainActor
    static func resultTransform(renderer: LongFormRenderer) -> ScheduledAnswerTransform {
        { schedule, answer, _, now in
            guard schedule.title == title else { return ScheduledAnswer(text: answer) }
            guard answer != ScheduledRunner.silenceToken else { return ScheduledAnswer(text: answer) }

            let script = LongFormScript.parse(answer)
            guard !script.isEmpty else {
                return ScheduledAnswer(text: "There was nothing to say today, so I didn't make a recording.")
            }
            let zone = schedule.when.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
            let edition = editionStamp(now, zone: zone)
            do {
                let rendered = try await renderer.render(script, title: title, edition: edition)
                let result = PodcastResult(rendered: rendered, edition: edition)
                let detail = "morning podcast rendered \(rendered.byteCount) bytes, "
                    + "\(Int(rendered.duration.rounded())) s at \(rendered.url.path)"
                Log.agent.info("\(detail, privacy: .public)")
                return ScheduledAnswer(text: result.text, artifacts: [rendered.url.absoluteString])
            } catch is CancellationError {
                // Only reached when the run itself is cancelled — quitting, or a caller
                // stopping the task. The renderer has already removed its staging file.
                return ScheduledAnswer(text: "I stopped before today's recording was finished. Nothing was saved.")
            } catch {
                let mapped = LongFormRenderer.classify(error)
                Log.agent.error("morning podcast render failed: \(mapped.localizedDescription, privacy: .public)")
                return ScheduledAnswer(text: failureText(for: mapped))
            }
        }
    }

    /// `2026-09-22` in the schedule's own zone. The same day always names the same file.
    static func editionStamp(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The one line the notification carries and the voice may speak. It never contains
    /// a path or a URL: `AgentSpeechPolicy` silences those, and a file path read aloud
    /// is noise. The file rides on the run's `AgentTask`, which is what the Library reads.
    static func announce(duration: TimeInterval) -> String {
        "Ready — \(spokenDuration(duration)), saved in your Library."
    }

    /// "48 seconds", "4 minutes 12 seconds", "5 minutes". Integer seconds; no clock.
    static func spokenDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        if minutes == 0 {
            return "\(seconds) second\(seconds == 1 ? "" : "s")"
        }
        if seconds == 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s") \(seconds) second\(seconds == 1 ? "" : "s")"
    }

    /// What the user reads when the audio could not be made. Every branch says what did
    /// and did not happen; none of them mentions internals.
    static func failureText(for error: Error) -> String {
        switch LongFormRenderer.classify(error) as? LongFormRenderError {
        case .voiceUnavailable:
            return "The voice for your podcast isn't set up, so I didn't make today's recording. "
                + "Choose the Pocket or Kokoro voice in Settings, then run it again. Nothing was saved."
        case .busy:
            return "Your Mac was busy recording, so I skipped today's recording. Nothing was saved."
        case .diskFull:
            return "There wasn't room on the disk, so I didn't save today's recording. "
                + "Nothing was left half-written."
        case .emptyScript, .noAudio:
            return "There was nothing to say today, so I didn't make a recording."
        case .tooLong:
            return "Today's recording would have run too long, so I didn't save one."
        case .writeFailed, .encodeFailed, .inconsistentSampleRate:
            return "I couldn't make today's recording. Nothing was saved."
        case nil:
            return "I couldn't make today's recording. Nothing was saved."
        }
    }
}

/// What one podcast run produced: the announcement plus everything a Library item
/// shows — the file, how long it runs, and its chapters. `text` is what the run
/// reports; `artifactURL` is what `AgentTask.artifacts` carries.
struct PodcastResult: Sendable, Equatable {
    var title: String
    var text: String
    var artifactURL: URL?
    var duration: TimeInterval
    var chapters: [LongFormRenderer.Chapter]
    var libraryKey: String

    init(rendered: LongFormRenderer.RenderedFile, edition: String) {
        title = PodcastTemplate.title
        text = PodcastTemplate.announce(duration: rendered.duration)
        artifactURL = rendered.url
        duration = rendered.duration
        chapters = rendered.chapters
        libraryKey = PodcastTemplate.libraryKey(edition: edition)
    }
}
