import Foundation

/// `--selftest-meeting-resume` (M-08): interrupted meetings resume at their stage,
/// temporary audio survives repair, the stall watchdog fires, and a resume either
/// finishes a meeting or parks it — never re-resumes it next launch. M-16c added the
/// debounced `transcript.json` write to the same flag, because a throttle that can lose
/// a crash-recoverable transcript is a resume that cannot be trusted.
///
/// No model, no microphone. Every seeded meeting lives in `MeetingStore.isolated()`,
/// never the user's `Meetings/`; every stage runner is a fake.
@MainActor
enum MeetingResumeSelfTest {
    static func run(log: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: - a. The pure planner over the Target 1 table.

        let t = true, f = false
        let plannerCases: [(String, MeetingStatus, Bool, Bool, ResumeAction)] = [
            ("rec+segs+audio=finalPass", .recording, t, t, .finalPass),
            ("rec+empty+audio=finalPass", .recording, f, t, .finalPass),
            ("rec+segs+noAudio=pipeline", .recording, t, f, .pipelineAfterTranscript),
            ("rec+empty+noAudio=fail", .recording, f, f,
             .fail("Next Notes quit before anything was transcribed.")),
            ("tra+segs+audio=finalPass", .transcribing, t, t, .finalPass),
            ("tra+empty+noAudio=fail", .transcribing, f, f,
             .fail("Next Notes quit before anything was transcribed.")),
            ("diarizing+audio=diarize", .diarizing, t, t, .diarize),
            ("diarizing+noAudio=notes", .diarizing, t, f, .notes),
            ("summarizing=notes", .summarizing, t, f, .notes),
            ("extracting=extractAgain", .extracting, t, f, .extractAgain),
            ("done=none", .done, t, f, .none),
            ("failed=none", .failed("old"), t, f, .none),
        ]
        for (name, status, hasTranscript, hasAudio, expected) in plannerCases {
            let got = MeetingStore.resumeAction(
                for: status, hasTranscript: hasTranscript, hasAudio: hasAudio
            )
            check("planner \(name) got \(got)", got == expected)
        }

        // MARK: - b. Three seeded interruptions reach .done with notes.

        do {
            let store = MeetingStore.isolated()
            let fm = FileManager.default

            func seed(
                status: MeetingStatus, segments: [TranscriptSegment],
                audio: Bool, temporary: Bool
            ) async -> Meeting {
                var meeting = Meeting(title: "Resume seed", start: Date(), status: status)
                if audio {
                    meeting.audioFileName = MeetingStore.audioFile
                    meeting.audioIsTemporary = temporary
                }
                store.save(meeting)
                store.saveTranscript(segments, for: meeting.id)
                if audio {
                    let dir = store.directory(for: meeting.id)
                    let url = dir.appendingPathComponent(MeetingStore.audioFile)
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    // 1 s of stereo silence through the real writer, so the seeded
                    // file is what production reads back: present with content.
                    do {
                        let writer = try MeetingAudioWriter(url: url)
                        let silence = [Float](repeating: 0, count: 16_000)
                        await writer.append(silence, from: .mic)
                        await writer.append(silence, from: .system)
                        await writer.finish()
                    } catch {
                        failures.append("seed writer failed: \(error)")
                    }
                }
                return store.meeting(id: meeting.id) ?? meeting
            }

            func threeSegments() -> [TranscriptSegment] {
                (0 ..< 3).map { i in
                    TranscriptSegment(
                        start: Double(i * 2), end: Double(i * 2 + 2),
                        text: "seed line \(i)", source: .mic
                    )
                }
            }

            let a = await seed(status: .recording, segments: threeSegments(), audio: true, temporary: true)
            let b = await seed(status: .diarizing, segments: threeSegments(), audio: true, temporary: true)
            let c = await seed(status: .summarizing, segments: threeSegments(), audio: false, temporary: false)
            let d = await seed(status: .recording, segments: [], audio: false, temporary: false)
            var orphan = await seed(status: .recording, segments: threeSegments(), audio: true, temporary: true)
            orphan.audioFileName = nil
            orphan.audioIsTemporary = nil
            orphan.end = orphan.start.addingTimeInterval(1_800)
            store.save(orphan)

            let plan = store.repairInterruptedMeetings()
            let actionOf = Dictionary(uniqueKeysWithValues: plan)
            let recoveringIDs = Set(plan.map { $0.0 })

            check("repair waits on its own active status",
                  !LiveKnowledgeIndexEnvironment.isForegroundBusy(
                      excludingMeetingIDs: recoveringIDs, store: store))
            check("repair still waits on another active status",
                  LiveKnowledgeIndexEnvironment.isForegroundBusy(
                      excludingMeetingIDs: recoveringIDs.subtracting([a.id]), store: store))
            let recoveredOrphan = store.meeting(id: orphan.id)
            check("orphan audio was linked", recoveredOrphan?.audioFileName == MeetingStore.audioFile)
            check("orphan audio keeps its unknown choice", recoveredOrphan?.audioIsTemporary == nil)
            check("orphan audio is readable by final pass",
                  recoveredOrphan.flatMap { store.audioURL(for: $0) } != nil)
            check("recovery replaced the calendar's planned end",
                  recoveredOrphan.map { ($0.end ?? .distantFuture) < orphan.start.addingTimeInterval(60) }
                      ?? false)

            // Repair advances the statuses but releases no audio: the stage that
            // finishes owns the unchanged `releaseAudio` rule.
            check("A repaired to transcribing", store.meeting(id: a.id)?.status == .transcribing)
            check("B repaired to diarizing", store.meeting(id: b.id)?.status == .diarizing)
            check("C repaired to summarizing", store.meeting(id: c.id)?.status == .summarizing)
            check("D repaired to failed", store.meeting(id: d.id)?.status.isFailure == true)
            for (id, label) in [(a.id, "A"), (b.id, "B")] {
                let url = store.directory(for: id).appendingPathComponent(MeetingStore.audioFile)
                check("\(label) audio survives repair", fm.fileExists(atPath: url.path))
            }
            check("A plans finalPass", actionOf[a.id] == .finalPass)
            check("orphan plans finalPass", actionOf[orphan.id] == .finalPass)
            check("B plans diarize", actionOf[b.id] == .diarize)
            check("C plans notes", actionOf[c.id] == .notes)

            var order: [(String, String)] = []
            func afterTranscriptFake(_ meeting: Meeting) {
                order.append(("afterTranscript", meeting.id.uuidString))
                diarizeFake(store.meeting(id: meeting.id) ?? meeting)
            }
            func diarizeFake(_ meeting: Meeting) {
                order.append(("diarize", meeting.id.uuidString))
                var labelled = meeting
                labelled.speakerNames = ["Speaker 1": "Seed Speaker"]
                store.save(labelled)
                var segments = store.transcript(for: meeting.id)
                for i in segments.indices { segments[i].speaker = "Speaker 1" }
                store.saveTranscript(segments, for: meeting.id)
                notesFake(store.meeting(id: meeting.id) ?? meeting)
            }
            func notesFake(_ meeting: Meeting) {
                order.append(("notes", meeting.id.uuidString))
                store.saveNotes("fake notes", for: meeting.id)
                var done = meeting
                done.status = .done
                store.save(done)
                // Exactly where `NotesService.summarize(announce: true)` releases it.
                // Force the setting that exposed the installed-app failure, without
                // changing the owner's preference or relying on its current value.
                store.releaseAudio(for: meeting.id, notesWritten: true,
                                   deleteKeptAfterNotes: true)
            }
            func finalPassFake(_ meeting: Meeting) {
                order.append(("finalPass", meeting.id.uuidString))
                afterTranscriptFake(meeting)
            }

            let resumer = MeetingResumer(
                store: store,
                finalPass: { finalPassFake($0) },
                afterTranscript: { afterTranscriptFake($0) },
                diarize: { diarizeFake($0) },
                notes: { notesFake($0) },
                isBusy: { false },
                busyPoll: .milliseconds(50),
                settlePoll: .milliseconds(50)
            )
            await resumer.resume(plan)

            for (meeting, label) in [(a, "A"), (b, "B"), (c, "C"), (orphan, "orphan")] {
                let current = store.meeting(id: meeting.id)
                check("\(label) reached done", current?.status == .done)
                check("\(label) has notes.md", store.notes(for: meeting.id) == "fake notes")
                check("\(label) residually inactive", current?.status.isActive == false)
            }
            check("D stayed failed", store.meeting(id: d.id)?.status.isFailure == true)
            for (id, label) in [(a.id, "A"), (b.id, "B")] {
                let url = store.directory(for: id).appendingPathComponent(MeetingStore.audioFile)
                check("\(label) temp audio released after notes", !fm.fileExists(atPath: url.path))
            }
            check("recovered orphan audio stays available after notes",
                  fm.fileExists(atPath: store.directory(for: orphan.id)
                      .appendingPathComponent(MeetingStore.audioFile).path))
            let stagesOf = { (id: UUID) in order.filter { $0.1 == id.uuidString }.map(\.0) }
            let expectedA = ["finalPass", "afterTranscript", "diarize", "notes"]
            check("A order \(stagesOf(a.id))", stagesOf(a.id) == expectedA)
            check("B order \(stagesOf(b.id))", stagesOf(b.id) == ["diarize", "notes"])
            check("C order \(stagesOf(c.id))", stagesOf(c.id) == ["notes"])
            check("D ran nothing", stagesOf(d.id).isEmpty)
            check("orphan order \(stagesOf(orphan.id))", stagesOf(orphan.id) == expectedA)
        }

        // MARK: - c. The pure stall rule.

        check("diarize 301s idle stalled",
              StageWatchdog.isStalled(sinceProgress: 301, busySeconds: 0, limit: 300))
        check("diarize 301s with 60s busy not stalled",
              !StageWatchdog.isStalled(sinceProgress: 301, busySeconds: 60, limit: 300))
        check("notes 599s not stalled",
              !StageWatchdog.isStalled(sinceProgress: 599, busySeconds: 0, limit: 600))
        check("notes 600s stalled",
              StageWatchdog.isStalled(sinceProgress: 600, busySeconds: 0, limit: 600))

        // A failed disk write must not put unsaved text in the store's cache and
        // claim it is recoverable after a crash. A directory at the target path
        // forces the real atomic writer to fail without relying on this Mac's disk.
        do {
            let store = MeetingStore.isolated()
            let meeting = Meeting(title: "Unwritable transcript", start: Date(), status: .recording)
            store.save(meeting)
            let target = store.directory(for: meeting.id)
                .appendingPathComponent(MeetingStore.transcriptFile)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let segment = TranscriptSegment(start: 0, end: 1, text: "saved?", source: .mic)
            check("failed transcript write returned success",
                  !store.saveTranscript([segment], for: meeting.id))
            check("failed transcript write entered the cache",
                  store.transcript(for: meeting.id).isEmpty)
        }

        // MARK: - d. A stage that never reports a step is stopped with its audio kept.

        do {
            let store = MeetingStore.isolated()
            let fm = FileManager.default
            var meeting = Meeting(title: "Stall seed", start: Date(), status: .summarizing)
            meeting.audioFileName = MeetingStore.audioFile
            meeting.audioIsTemporary = true
            store.save(meeting)
            store.saveTranscript(
                [TranscriptSegment(start: 0, end: 2, text: "stall line", source: .mic)],
                for: meeting.id
            )
            let audioURL = store.directory(for: meeting.id)
                .appendingPathComponent(MeetingStore.audioFile)
            try? fm.createDirectory(at: store.directory(for: meeting.id),
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: audioURL.path, contents: Data(count: 64))
            let notesService = NotesService(store: store)

            StageWatchdog.setLimitsForTesting(diarize: 0.5, notes: 0.5)
            defer { StageWatchdog.resetLimitsForTesting() }
            let stuckSince = Date().addingTimeInterval(-60)
            let id = meeting.id
            // A fake notes runner that never reports a step: progress stays old.
            let watch = StageWatch(
                limit: StageWatchdog.notesLimit,
                pollInterval: 0.1,
                lastProgress: { stuckSince },
                isLaneBusy: { false },
                onStall: {
                    notesService.setProblemForTesting(StageWatchdog.stallMessage, for: id)
                    if var finished = store.meeting(id: id) {
                        finished.status = .done
                        store.save(finished)
                    }
                }
            )
            watch.start()
            try? await Task.sleep(for: .seconds(2))
            watch.cancel()
            check("stalled notes has a problem",
                  notesService.problem(for: id) == StageWatchdog.stallMessage)
            check("stalled notes left summarizing",
                  store.meeting(id: id)?.status != .summarizing)
            check("stalled notes kept its audio", fm.fileExists(atPath: audioURL.path))
        }

        // MARK: - e. Debounced `transcript.json` writes (M-16c).

        var throttleReport = "not run"
        // The rule itself, as a table. The interval is the number the task fixes and
        // caps: a crash may not cost more than one interval of unwritten speech.
        check("the transcript throttle interval is 5s, not \(TranscriptSaveThrottle.interval)s",
              TranscriptSaveThrottle.interval == 5)
        let t0 = 1_000.0
        let ruleCases: [(String, TimeInterval, TimeInterval?, Bool, Bool)] = [
            ("nothing pending never writes", t0 + 100, t0, false, false),
            ("the first segment writes at once", t0, nil, true, true),
            ("a second segment inside the interval waits", t0 + 4.99, t0, true, false),
            ("a segment at the interval is due", t0 + 5, t0, true, true),
            ("a segment after the interval is due", t0 + 900, t0, true, true),
        ]
        for (name, now, lastWrite, pending, expected) in ruleCases {
            let got = TranscriptSaveThrottle.shouldWrite(
                now: now, lastWrite: lastWrite, pending: pending)
            check("rule: \(name) got \(got)", got == expected)
        }
        check("a trailing write waits out the rest of the interval "
              + "(\(TranscriptSaveThrottle.secondsUntilDue(now: t0 + 2, lastWrite: t0)))",
              TranscriptSaveThrottle.secondsUntilDue(now: t0 + 2, lastWrite: t0) == 3)
        check("a trailing write past its due time waits 0s",
              TranscriptSaveThrottle.secondsUntilDue(now: t0 + 9, lastWrite: t0) == 0)

        do {
            let store = MeetingStore.isolated()
            // The file is the crash record, so the assertions read it from disk rather
            // than through `store.transcript(for:)`, which answers from the cache the
            // write just filled.
            func onDisk(_ id: UUID) -> [TranscriptSegment] {
                let url = store.directory(for: id)
                    .appendingPathComponent(MeetingStore.transcriptFile)
                guard let data = try? Data(contentsOf: url) else { return [] }
                return (try? JSONDecoder().decode([TranscriptSegment].self, from: data)) ?? []
            }
            // One row per write is what production records, so the rows are the count.
            func writes() -> Int {
                // LatencyTrace queues its row off the recording path. Read only after the
                // queue has caught up, or a fast replay counts zero writes for a file
                // already on disk and later attributes them to the trailing-write case.
                MetricsStore.shared.flushForTesting()
                return MetricsStore.shared.spans(named: .meetingTranscriptWrite).count
            }

            // 100 segments over 20 s of meeting clock: five 5-second writes at most,
            // then the flush every exit path owes. A crash may cost one interval of
            // speech, so the file has to be whole by the time the meeting is over.
            let meeting = Meeting(title: "Throttle seed", start: Date(), status: .recording)
            store.save(meeting)
            let session = MeetingSession(meeting: meeting, store: store)
            let clock = SimulatedClock(Date())
            session.setTranscriptClockForTesting { clock.now }
            let before = writes()
            for index in 0 ..< 100 {
                clock.now = clock.now.addingTimeInterval(0.2)
                session.insertSegmentForTesting(
                    TranscriptSegment(
                        start: Double(index) * 0.2,
                        end: Double(index) * 0.2 + 0.2,
                        text: "throttled line \(index)",
                        source: index.isMultiple(of: 2) ? .mic : .system
                    )
                )
            }
            let throttled = writes() - before
            check("100 segments over 20s made \(throttled) write(s), expected at most 5",
                  throttled >= 1 && throttled <= 5)
            check("the throttle wrote nothing at all", throttled >= 1)
            // A throttle must never cost a crash-recoverable transcript: `endAbruptly` is
            // what a SIGTERM (`make install` sends one many times a day) reaches.
            session.endAbruptly()
            let flushed = onDisk(meeting.id)
            check("endAbruptly left \(flushed.count)/100 segment(s) on disk", flushed.count == 100)
            check("the flushed transcript is ordered",
                  flushed == flushed.sorted { $0.start < $1.start })
            check("endAbruptly left the meeting resumable",
                  store.meeting(id: meeting.id)?.status == .transcribing)
            throttleReport = "\(throttled) write(s) for 100 segments, flushed to \(flushed.count)"

            // The trailing write, then the exit path that cancels it. One session, the
            // real clock, the real interval — nothing here is shortened.
            let quiet = Meeting(title: "Trailing write", start: Date(), status: .recording)
            store.save(quiet)
            let quietSession = MeetingSession(meeting: quiet, store: store)
            let quietBefore = writes()
            quietSession.insertSegmentForTesting(
                TranscriptSegment(start: 0, end: 2, text: "first", source: .mic))
            let afterFirst = writes() - quietBefore
            quietSession.insertSegmentForTesting(
                TranscriptSegment(start: 2, end: 4, text: "second", source: .mic))
            let whileThrottled = writes() - quietBefore
            check("a segment inside the interval wrote anyway (\(afterFirst) → \(whileThrottled))",
                  afterFirst == 1 && whileThrottled == 1)
            // A meeting that goes quiet must still reach disk inside the interval: that
            // is the trailing write, and it is the only thing standing between a
            // throttled segment and an hour-long crash.
            try? await Task.sleep(for: .milliseconds(5_600))
            let afterTrailing = writes() - quietBefore
            check("no trailing write after 5.6s (\(afterTrailing) write(s), expected 2)",
                  afterTrailing == 2)
            check("the trailing write did not reach the file", onDisk(quiet.id).count == 2)
            quietSession.insertSegmentForTesting(
                TranscriptSegment(start: 4, end: 6, text: "third", source: .mic))
            let beforeExit = writes() - quietBefore
            check("a segment inside the interval wrote anyway (\(afterTrailing) → \(beforeExit))",
                  beforeExit == 2)
            quietSession.endAbruptly()
            let afterExit = writes() - quietBefore
            check("endAbruptly wrote the pending segment (\(afterExit) write(s), expected 3)",
                  afterExit == 3)
            check("endAbruptly put every segment on disk", onDisk(quiet.id).count == 3)
            // The final pass overwrites this file with long-window finals, so a trailing
            // write that outlived the exit would put the shorter live tier back.
            try? await Task.sleep(for: .milliseconds(5_600))
            check("the file was written again after the meeting was over "
                  + "(\(writes() - quietBefore) write(s), expected 3)",
                  writes() - quietBefore == 3)
            check("the file was rewritten after the meeting was over", onDisk(quiet.id).count == 3)
            throttleReport += "; a trailing write inside the interval, cancelled by the exit"
        }
        log("MEETING_RESUME_THROTTLE: \(throttleReport)")

        for failure in failures { log("MEETING_RESUME_WRONG: \(failure)") }
        log(failures.isEmpty
            ? "MEETING_RESUME_OK: 4/4 resumable meetings reached .done with notes; no temp audio released early; \(throttleReport)"
            : "MEETING_RESUME_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }
}

/// A clock the throttle reads, so twenty seconds of segments cost a millisecond.
/// Production reads `Date()`; only the self-test installs one of these.
private final class SimulatedClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}
