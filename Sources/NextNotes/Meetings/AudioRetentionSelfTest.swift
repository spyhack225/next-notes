import Foundation

/// `--selftest-audio-retention` (M-10): temporary meeting audio is kept 72 hours
/// past the pipeline end (or until the speakers are confirmed), the disk guards
/// hold at 5 GB for retention and 1 GB for writing, the sweeper never touches a
/// kept recording, an active meeting, or one with a diarization problem, and the
/// start decision under 1 GB free writes no file at all.
///
/// No model, no microphone, no real store. Every seeded meeting lives in
/// `MeetingStore.isolated()`; free space and the clock are injected, so the
/// result never depends on this Mac's disk.
@MainActor
enum AudioRetentionSelfTest {
    static func run(log: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let fm = FileManager.default
        let gigabyte: Int64 = 1_000_000_000
        let retention = MeetingStore.temporaryAudioRetention
        let now = Date()
        let audioFile = MeetingStore.audioFile

        func exists(_ store: MeetingStore, _ id: UUID) -> Bool {
            fm.fileExists(atPath: store.directory(for: id)
                .appendingPathComponent(audioFile).path)
        }

        /// Seeds one meeting with an audio file that has content — the real
        /// writer, so the seeded file is what production reads back.
        func seed(
            _ store: MeetingStore,
            title: String,
            status: MeetingStatus,
            temporary: Bool,
            releaseAfter: Date? = nil,
            start: Date = Date()
        ) async -> Meeting {
            var meeting = Meeting(title: title, start: start, status: status)
            meeting.audioFileName = audioFile
            meeting.audioIsTemporary = temporary
            meeting.audioReleaseAfter = releaseAfter
            store.save(meeting)
            let dir = store.directory(for: meeting.id)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                // 1 s of stereo silence through the real writer, so the seeded
                // file is what production reads back: present with content.
                let writer = try MeetingAudioWriter(url: dir.appendingPathComponent(audioFile))
                let silence = [Float](repeating: 0, count: 16_000)
                await writer.append(silence, from: .mic)
                await writer.append(silence, from: .system)
                await writer.finish()
            } catch {
                failures.append("seed writer failed: \(error)")
            }
            return store.meeting(id: meeting.id) ?? meeting
        }

        // MARK: - a. The pipeline end schedules 72 h instead of deleting.

        do {
            let store = MeetingStore.isolated()
            let meeting = await seed(store, title: "Retention seed", status: .done, temporary: true)
            store.releaseAudioWhenDue(
                for: meeting.id, notesWritten: true,
                now: now, freeBytes: 50 * gigabyte
            )
            check("a file kept at 50 GB free", exists(store, meeting.id))
            let due = store.meeting(id: meeting.id)?.audioReleaseAfter
            check("a audioReleaseAfter set", due != nil)
            if let due {
                let target = now.addingTimeInterval(retention)
                check("a release ≈ now + 72 h (\(Int(due.timeIntervalSince(now)))s vs \(Int(retention))s)",
                      abs(due.timeIntervalSince(target)) < 60)
            }
        }

        // MARK: - b. The sweeper deletes a temporary recording past its window.

        do {
            let store = MeetingStore.isolated()
            // The window case a stamped: 72 h past the pipeline end. The sweeper
            // runs an hour past it.
            let meeting = await seed(
                store, title: "Expired seed", status: .done, temporary: true,
                releaseAfter: now.addingTimeInterval(retention)
            )
            let released = store.sweepExpiredAudio(
                now: now.addingTimeInterval(retention + 3600), freeBytes: 50 * gigabyte,
                hasDiarizationProblem: { _ in false }
            )
            check("b sweep reported a release (\(released))", released == 1)
            check("b sweeper deleted the expired file", !exists(store, meeting.id))
        }

        // MARK: - c. Under 5 GB free the pipeline end releases immediately.

        do {
            let store = MeetingStore.isolated()
            let meeting = await seed(store, title: "Tight disk seed", status: .done, temporary: true)
            store.releaseAudioWhenDue(
                for: meeting.id, notesWritten: true,
                now: now, freeBytes: 4 * gigabyte
            )
            check("c released at 4 GB free", !exists(store, meeting.id))
            check("c no window recorded",
                  store.meeting(id: meeting.id)?.audioReleaseAfter == nil)
        }

        // MARK: - d. Kept recordings are untouched by the sweeper.

        do {
            let store = MeetingStore.isolated()
            let kept = await seed(store, title: "Kept seed", status: .done, temporary: false)
            store.sweepExpiredAudio(
                now: now.addingTimeInterval(retention * 2), freeBytes: 50 * gigabyte,
                hasDiarizationProblem: { _ in false }
            )
            check("d kept file survives the sweep", exists(store, kept.id))
            // The disk guard reclaims only temporary recordings.
            store.sweepExpiredAudio(
                now: now, freeBytes: 4 * gigabyte,
                hasDiarizationProblem: { _ in false }
            )
            check("d kept file survives the disk guard", exists(store, kept.id))
        }

        // MARK: - e. An active meeting is never swept.

        do {
            let store = MeetingStore.isolated()
            let active = await seed(
                store, title: "Active seed", status: .transcribing, temporary: true,
                releaseAfter: now.addingTimeInterval(-3600)
            )
            store.sweepExpiredAudio(
                now: now, freeBytes: 50 * gigabyte,
                hasDiarizationProblem: { _ in false }
            )
            check("e active meeting's audio untouched", exists(store, active.id))
        }

        // MARK: - f. A meeting with a diarization problem is never swept.

        do {
            let store = MeetingStore.isolated()
            let meeting = await seed(
                store, title: "Problem seed", status: .done, temporary: true,
                releaseAfter: now.addingTimeInterval(-3600)
            )
            store.sweepExpiredAudio(
                now: now, freeBytes: 50 * gigabyte,
                hasDiarizationProblem: { _ in true }
            )
            check("f problem meeting's audio untouched", exists(store, meeting.id))
        }

        // MARK: - g. The start decision under 1 GB free writes no file.

        let writeCases: [(String, Bool, Bool, Bool, Int64, Bool)] = [
            ("keep on, 0.5 GB → no file", true, false, false, 500_000_000, false),
            ("diarize only, 0.5 GB → no file", false, true, false, 500_000_000, false),
            ("final pass only, 0.5 GB → no file", false, false, true, 500_000_000, false),
            ("keep on, 2 GB → file", true, false, false, 2 * gigabyte, true),
            ("diarize only, 2 GB → file", false, true, false, 2 * gigabyte, true),
            ("nothing wants audio → no file", false, false, false, 50 * gigabyte, false),
        ]
        for (name, keep, diarize, finalPass, free, expected) in writeCases {
            let got = MeetingSession.shouldWriteAudio(
                keep: keep, diarize: diarize, finalPass: finalPass, freeBytes: free
            )
            check("g \(name) got \(got)", got == expected)
        }

        for failure in failures { log("AUDIO_RETENTION_WRONG: \(failure)") }
        log(failures.isEmpty
            ? "AUDIO_RETENTION_OK: temporary audio keeps 72 h, the disk guards hold, the sweeper spares kept, active and problem meetings"
            : "AUDIO_RETENTION_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }
}