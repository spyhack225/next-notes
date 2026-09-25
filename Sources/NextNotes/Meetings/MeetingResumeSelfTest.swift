import Foundation

/// `--selftest-meeting-resume` (M-08): interrupted meetings resume at their stage,
/// temporary audio survives repair, the stall watchdog fires, and a resume either
/// finishes a meeting or parks it — never re-resumes it next launch.
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
        let plannerCases: [(String, MeetingStatus, Bool, Bool, Bool, ResumeAction)] = [
            ("rec+segs+audio+pass=finalPass", .recording, t, t, t, .finalPass),
            ("rec+empty+audio+pass=finalPass", .recording, f, t, t, .finalPass),
            ("rec+segs+noAudio+pass=pipeline", .recording, t, f, t, .pipelineAfterTranscript),
            ("rec+empty+noAudio+pass=fail", .recording, f, f, t,
             .fail("Next Notes quit before anything was transcribed.")),
            ("tra+segs+audio+pass=finalPass", .transcribing, t, t, t, .finalPass),
            ("tra+empty+noAudio=fail", .transcribing, f, f, t,
             .fail("Next Notes quit before anything was transcribed.")),
            ("rec+segs+audio+passOff=pipeline", .recording, t, t, f, .pipelineAfterTranscript),
            ("rec+empty+audio+passOff=fail", .recording, f, t, f,
             .fail("Next Notes quit before anything was transcribed.")),
            ("diarizing+audio=diarize", .diarizing, t, t, t, .diarize),
            ("diarizing+noAudio=notes", .diarizing, t, f, t, .notes),
            ("summarizing=notes", .summarizing, t, f, t, .notes),
            ("extracting=extractAgain", .extracting, t, f, t, .extractAgain),
            ("done=none", .done, t, f, t, .none),
            ("failed=none", .failed("old"), t, f, t, .none),
        ]
        for (name, status, hasTranscript, hasAudio, finalPassOn, expected) in plannerCases {
            let got = MeetingStore.resumeAction(
                for: status, hasTranscript: hasTranscript,
                hasAudio: hasAudio, finalPassOn: finalPassOn
            )
            check("planner \(name) got \(got)", got == expected)
        }

        // MARK: - b. Three seeded interruptions reach .done with notes.

        do {
            let store = MeetingStore.isolated()
            let passOn = Settings.shared.meetingsFinalPass
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

            let plan = store.repairInterruptedMeetings()
            let actionOf = Dictionary(uniqueKeysWithValues: plan)

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
            if passOn {
                check("A plans finalPass", actionOf[a.id] == .finalPass)
            } else {
                check("A plans pipeline (pass off)", actionOf[a.id] == .pipelineAfterTranscript)
            }
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
                store.releaseAudio(for: meeting.id, notesWritten: true)
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

            for (meeting, label) in [(a, "A"), (b, "B"), (c, "C")] {
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
            let stagesOf = { (id: UUID) in order.filter { $0.1 == id.uuidString }.map(\.0) }
            let expectedA = passOn
                ? ["finalPass", "afterTranscript", "diarize", "notes"]
                : ["afterTranscript", "diarize", "notes"]
            check("A order \(stagesOf(a.id))", stagesOf(a.id) == expectedA)
            check("B order \(stagesOf(b.id))", stagesOf(b.id) == ["diarize", "notes"])
            check("C order \(stagesOf(c.id))", stagesOf(c.id) == ["notes"])
            check("D ran nothing", stagesOf(d.id).isEmpty)
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

        for failure in failures { log("MEETING_RESUME_WRONG: \(failure)") }
        log(failures.isEmpty
            ? "MEETING_RESUME_OK: 3/3 resumable meetings reached .done with notes; no temp audio released early"
            : "MEETING_RESUME_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }
}
