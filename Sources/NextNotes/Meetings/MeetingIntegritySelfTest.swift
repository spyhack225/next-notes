import Darwin
import Foundation
import FluidAudio

/// MR-02: actual isolated stores and production recovery consumers, with only model
/// inference substituted. No owner meeting, microphone, grant, account or network.
@MainActor
enum MeetingIntegritySelfTest {
    static func run(log: (String) -> Void) async -> Bool {
        var failures: [String] = []
        var checks = 0
        func check(_ label: String, _ value: Bool) {
            checks += 1
            if !value { failures.append(label) }
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let restart = start.addingTimeInterval(3_300)
        let boundary = start.addingTimeInterval(261)

        // Old rows remain visible and absent metadata remains unknown.
        do {
            let legacy = """
                {"id":"\(UUID().uuidString)","title":"Legacy fixture",
                 "start":"2023-11-14T22:13:20Z","status":{"state":"done"}}
                """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let meeting = try decoder.decode(Meeting.self, from: Data(legacy.utf8))
            check("old row lost", meeting.status == .done)
            check("unknown old capture claimed complete", meeting.captureIntegrity == nil)
            check("old done row incorrectly partial", !meeting.hasPartialCapture)
        } catch { failures.append("legacy decode: \(error)") }

        // A processing restart cannot invent a capture interruption or replace the
        // real Stop time with the last spoken word. Silence at the end is allowed.
        do {
            let store = MeetingStore.isolated()
            for status in [MeetingStatus.transcribing, .diarizing, .summarizing] {
                let meeting = Meeting(title: "Processing fixture", start: start,
                                      end: start.addingTimeInterval(1_800), status: status)
                store.save(meeting)
                store.saveTranscript([TranscriptSegment(start: 0, end: 1,
                    text: "fixture speech", source: .mic)], for: meeting.id)
            }
            let reader = store.freshReaderForTesting()
            let plan = reader.repairInterruptedMeetings(now: restart)
            check("processing rows did not plan", plan.count == 3)
            for meeting in reader.freshReaderForTesting().meetings {
                check("processing restart marked interrupted", !meeting.hasPartialCapture)
                check("processing restart changed stopped duration",
                      meeting.end == start.addingTimeInterval(1_800))
                check("processing restart invented integrity", meeting.captureIntegrity == nil)
            }
        }

        // No audio link, then an unrelated/new mtime: neither is capture evidence.
        do {
            let store = MeetingStore.isolated()
            let missing = Meeting(title: "Missing audio fixture", start: start,
                end: start.addingTimeInterval(1_800), status: .recording)
            store.save(missing)
            store.saveTranscript([TranscriptSegment(start: 0, end: 261,
                text: "fixture speech", source: .mic)], for: missing.id)
            let empty = Meeting(title: "Empty capture fixture", start: start, status: .recording)
            store.save(empty)
            let reader = store.freshReaderForTesting()
            let plan = reader.repairInterruptedMeetings(now: restart)
            check("missing audio plan", Dictionary(uniqueKeysWithValues: plan)[missing.id] == .pipelineAfterTranscript)
            let saved = reader.freshReaderForTesting().meeting(id: missing.id)
            check("missing audio interruption lost", saved?.hasPartialCapture == true)
            check("last supported transcript boundary wrong", saved?.captureBoundary == boundary)
            check("unknown cause was attributed", saved?.captureIntegrity?.interruptionReason == .unknown)
            let noEvidence = reader.freshReaderForTesting().meeting(id: empty.id)
            check("no-evidence recording not partial", noEvidence?.hasPartialCapture == true)
            check("no-evidence boundary invented", noEvidence?.captureBoundary == nil && noEvidence?.end == nil)
            check("no-evidence recording falsely done", noEvidence?.status.isFailure == true)
        }

        // Known gaps and write failures survive stale whole-row producers and fresh
        // disk readers. A later normal Stop and long-window finals cannot erase loss.
        do {
            let store = MeetingStore.isolated()
            let stale = Meeting(title: "Stale save fixture", start: start, status: .recording)
            store.save(stale)
            var current = stale
            var integrity = MeetingCaptureIntegrity()
            integrity.recordCaptured(until: boundary)
            integrity.markGap() // unknown packet size must not become a frame count
            integrity.markGap(missingFrames: 400)
            integrity.markAudioWriteFailure()
            integrity.markInterrupted(at: boundary, reason: .audioWriteFailure)
            current.captureIntegrity = integrity
            store.save(current)
            var finishing = stale
            finishing.status = .done
            finishing.transcriptPass = "long-window"
            finishing.captureIntegrity = MeetingCaptureIntegrity(normalEndAt: boundary)
            store.save(finishing)
            let fresh = store.freshReaderForTesting().meeting(id: stale.id)
            check("stale save erased partial capture", fresh?.hasPartialCapture == true)
            check("stale save erased measured frames", fresh?.captureIntegrity?.missingCaptureFrames == 400)
            check("stale save erased unknown gap", fresh?.captureIntegrity?.captureGap == true)
            check("stale save erased writer failure", fresh?.captureIntegrity?.audioWriteFailed == true)
            check("stale save erased specific cause", fresh?.captureIntegrity?.interruptionReason == .audioWriteFailure)
            check("stale save erased boundary", fresh?.captureBoundary == boundary)
            var overflow = MeetingCaptureIntegrity()
            overflow.markGap(missingFrames: .max)
            overflow.markGap(missingFrames: 1)
            check("frame aggregation overflowed", overflow.missingCaptureFrames == .max)
            let normal = Meeting(title: "Normal fixture", start: start, end: boundary,
                status: .done, captureIntegrity: MeetingCaptureIntegrity(
                    lastCapturedAt: boundary, normalEndAt: boundary))
            store.save(normal)
            check("normal stop falsely partial", store.freshReaderForTesting().meeting(id: normal.id)?.hasPartialCapture == false)
        }

        // The real atomic metadata writer fails. Unsaved repair is not admission
        // to workers and not an in-memory claim that would vanish at another restart.
        do {
            let store = MeetingStore.isolated()
            let meeting = Meeting(title: "Unwritable fixture", start: start, status: .recording)
            store.save(meeting)
            store.saveTranscript([TranscriptSegment(start: 0, end: 1,
                text: "fixture speech", source: .mic)], for: meeting.id)
            let target = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.recordFile)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            check("unsaved repair dispatched", store.repairInterruptedMeetings(now: restart).isEmpty)
            check("unsaved repair published", store.meeting(id: meeting.id)?.status == .recording)
            check("unsaved repair invented saved fact", store.meeting(id: meeting.id)?.captureIntegrity == nil)
        } catch { failures.append("write-failure fixture: \(error)") }

        // The incident-shaped production recovery flow is added below, not credited
        // by a pure metadata helper or fake notes writer.
        failures.append(contentsOf: await recoveryFlow(start: start, restart: restart, check: check))
        failures.append(contentsOf: await savedTrackCoverageFlow(start: start, check: check))

        for failure in failures { log("MEETING_INTEGRITY_WRONG: \(failure)") }
        log(failures.isEmpty
            ? "MEETING_INTEGRITY_OK: \(checks) checks; recording restart through final pass, notes, done and fresh reader"
            : "MEETING_INTEGRITY_FAILED: \(failures.count) checks wrong")
        return failures.isEmpty
    }

    /// The wrapper starts seed and verify as two separate signed app processes.
    /// Verify only reads the surviving fixture; it never creates another meeting.
    static func runProcessStage(_ stage: String, root: URL, log: (String) -> Void) async -> Bool {
        var failures: [String] = []
        var checks = 0
        func check(_ label: String, _ value: Bool) {
            checks += 1
            if !value { failures.append(label) }
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let restart = start.addingTimeInterval(3_300)
        do {
            let store = try MeetingStore.isolated(at: root)
            switch stage {
            case "seed":
                guard store.meetings.isEmpty else {
                    log("MEETING_INTEGRITY_PROCESS_FAILED: seed directory was not empty")
                    return false
                }
                _ = try await seedRecovery(store: store, start: start, restart: restart, check: check)
                guard failures.isEmpty else { break }
                log("MEETING_INTEGRITY_PROCESS_SEEDED: \(checks) checks; deliberate exit 73")
                fflush(nil)
                Darwin._exit(73)
            case "verify":
                guard store.meetings.count == 1, let meeting = store.meetings.first else {
                    log("MEETING_INTEGRITY_PROCESS_FAILED: surviving seed was missing or ambiguous")
                    return false
                }
                check("seed did not survive as recording", meeting.status == .recording)
                check("verify received previously repaired seed", meeting.captureIntegrity?.interruptedAt == nil)
                check("surviving audio missing", store.audioURL(for: meeting) != nil)
                failures.append(contentsOf: await consumeRecovery(store: store, meeting: meeting,
                    start: start, restart: restart, check: check))
            default:
                failures.append("unknown process stage")
            }
        } catch { failures.append("process fixture: \(error)") }
        for failure in failures { log("MEETING_INTEGRITY_PROCESS_WRONG: \(failure)") }
        log(failures.isEmpty
            ? "MEETING_INTEGRITY_PROCESS_OK: \(checks) checks; separate-process recording restart through notes and regeneration"
            : "MEETING_INTEGRITY_PROCESS_FAILED: \(failures.count) checks wrong")
        return failures.isEmpty
    }

    private static func seedRecovery(
        store: MeetingStore, start: Date, restart: Date,
        check: @escaping (String, Bool) -> Void
    ) async throws -> Meeting {
        let capturedSeconds = 261
        let boundary = start.addingTimeInterval(Double(capturedSeconds))
        let meeting = Meeting(title: "Abrupt recording fixture", start: start,
            end: start.addingTimeInterval(1_800), status: .recording,
            captureIntegrity: MeetingCaptureIntegrity(lastCapturedAt: boundary),
            audioFileName: MeetingStore.audioFile, audioIsTemporary: nil)
        // A killed process leaves exactly recording on disk, plus its surviving audio.
        check("original recording metadata did not save", store.save(meeting))
        check("original recording transcript did not save", store.saveTranscript([
            TranscriptSegment(start: 0, end: Double(capturedSeconds),
                text: "fixture speech", source: .mic)
        ], for: meeting.id))
        let audio = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.audioFile)
        let writer = try MeetingAudioWriter(url: audio)
        let oneSecond = (0 ..< 16_000).map { Float(0.1 * sin(Double($0) * 0.08)) }
        for _ in 0 ..< capturedSeconds {
            await writer.append(oneSecond, from: .mic)
            await writer.append(oneSecond, from: .system)
        }
        await writer.finish()
        let snapshot = writer.resourceSnapshot()
        check("fixture did not save two-track audio", snapshot.writtenFrames == capturedSeconds * 16_000)
        let savedMic = try AudioConversion.samples(fromFileAt: audio,
            sampleRate: ChunkedTranscriber.sampleRate, channel: MeetingAudioWriter.micChannel)
        check("fresh audio reader missed surviving frames", savedMic.count == capturedSeconds * 16_000)
        // Deliberately unrelated mtime pins why it cannot be a capture boundary.
        try FileManager.default.setAttributes([.modificationDate: restart], ofItemAtPath: audio.path)
        let fresh = store.freshReaderForTesting()
        check("seed recording did not reach a fresh disk reader", fresh.meeting(id: meeting.id)?.status == .recording)
        check("seed transcript did not reach a fresh disk reader", fresh.transcript(for: meeting.id).last?.end == Double(capturedSeconds))
        return meeting
    }

    private static func recoveryFlow(
        start: Date, restart: Date, check: @escaping (String, Bool) -> Void
    ) async -> [String] {
        let store = MeetingStore.isolated()
        do {
            let meeting = try await seedRecovery(store: store, start: start, restart: restart, check: check)
            return await consumeRecovery(store: store, meeting: meeting,
                start: start, restart: restart, check: check)
        } catch { return ["production fixture writer: \(error)"] }
    }

    private static func consumeRecovery(
        store: MeetingStore, meeting original: Meeting, start: Date, restart: Date,
        check: @escaping (String, Bool) -> Void
    ) async -> [String] {
        var failures: [String] = []
        var meeting = original
        let boundary = start.addingTimeInterval(261)
        let fresh = store.freshReaderForTesting()
        let plan = fresh.repairInterruptedMeetings(now: restart)
        check("original recording did not plan final pass", Dictionary(uniqueKeysWithValues: plan)[meeting.id] == .finalPass)
        check("repair did not persist original interruption", fresh.freshReaderForTesting().meeting(id: meeting.id)?.hasPartialCapture == true)
        check("audio mtime extended capture", fresh.meeting(id: meeting.id)?.captureBoundary == boundary)
        check("repair replaced unknown keep choice", fresh.meeting(id: meeting.id)?.audioIsTemporary == nil)

        let provider = LongformNotesProvider(contextTokens: 8_192)
        let notes = NotesService(store: fresh, providerResolver: { _ in provider })
        var finalCompleted = false
        let finals = FinalTranscriptService(transcribe: { samples in
            ASRResult(text: "fixture speech", confidence: 1,
                duration: Double(samples.count) / 16_000,
                processingTime: 0, tokenTimings: nil)
        }, afterFinalPass: { row, store in
            finalCompleted = true
            check("final producer erased interruption", store.meeting(id: row.id)?.hasPartialCapture == true)
            // Both the production skip-diarization path and its optional stage runner
            // hand off through the real pipeline into the real notes service.
            _ = MeetingPipeline.afterFinalPass(row, store: store, notesService: notes,
                diarize: { labelled in
                    _ = MeetingPipeline.afterDiarizing(labelled, store: store, notesService: notes)
                })
        })
        let resumer = MeetingResumer(store: fresh,
            finalPass: { finals.process($0, store: fresh) },
            afterTranscript: { _ in failures.append("wrong recovery stage") },
            diarize: { _ in failures.append("wrong recovery stage") },
            notes: { _ in failures.append("wrong recovery stage") },
            isBusy: { false }, busyPoll: .milliseconds(5), settlePoll: .milliseconds(5))
        let worker = Task { await resumer.resume(plan) }
        let deadline = Date().addingTimeInterval(10)
        while fresh.meeting(id: meeting.id)?.status.isActive == true, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        worker.cancel()
        await worker.value
        finals.cancel(meeting.id)
        let completed = fresh.freshReaderForTesting()
        meeting = completed.meeting(id: meeting.id) ?? meeting
        check("actual final pass never completed", finalCompleted)
        check("actual final inference/save did not replace live tier", meeting.transcriptPass == "long-window")
        check("original flow never reached done", meeting.status == .done)
        check("actual model/notes service never ran", !provider.calls.isEmpty && completed.notes(for: meeting.id) != nil)
        check("original false-complete regression", meeting.hasPartialCapture && meeting.captureSummary != nil)
        check("notes producer erased capture boundary", meeting.captureBoundary == boundary)
        check("notes producer erased unknown cause", meeting.captureIntegrity?.interruptionReason == .unknown)
        check("notes producer changed keep intent", meeting.audioIsTemporary == nil)
        fresh.releaseAudio(for: meeting.id, notesWritten: true, deleteKeptAfterNotes: true)
        check("unknown-choice recovered audio deleted", fresh.audioURL(for: meeting) != nil)

        // Regenerate is the same producer, with a second real note pass.
        let before = provider.calls.count
        notes.summarize(meeting)
        await Task.yield()
        let regenerationDeadline = Date().addingTimeInterval(10)
        while fresh.meeting(id: meeting.id)?.status.isActive == true, Date() < regenerationDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        notes.cancel(meeting.id)
        check("regeneration never ran", provider.calls.count > before)
        check("regeneration erased partial marker", fresh.freshReaderForTesting().meeting(id: meeting.id)?.hasPartialCapture == true)
        return failures
    }

    /// The writer can save a padded stereo timeline while omitting originals from
    /// one delayed track. Word counts alone may accept that shorter saved speech.
    private static func savedTrackCoverageFlow(
        start: Date, check: @escaping (String, Bool) -> Void
    ) async -> [String] {
        let store = MeetingStore.isolated()
        let stale = Meeting(title: "Delayed saved track fixture", start: start,
            end: start.addingTimeInterval(30), status: .transcribing,
            audioFileName: MeetingStore.audioFile, audioIsTemporary: false)
        guard store.save(stale) else { return ["coverage fixture metadata was not saved"] }
        let live = [
            TranscriptSegment(start: 0, end: 30, text: "original microphone speech before improvement", source: .mic),
            TranscriptSegment(start: 0, end: 25, text: "original system beginning has six words", source: .system),
            TranscriptSegment(start: 25, end: 30, text: "original system tail survives", source: .system),
        ]
        check("coverage live originals did not save", store.saveTranscript(live, for: stale.id))
        let audio = store.directory(for: stale.id).appendingPathComponent(MeetingStore.audioFile)
        do {
            let writer = try MeetingAudioWriter(url: audio)
            let speech = (0 ..< 30 * 16_000).map { Float(0.1 * sin(Double($0) * 0.08)) }
            await writer.append(speech, from: .mic, startFrame: 0)
            await writer.append(speech, from: .system, startFrame: 0)
            await writer.finish()
            let snapshot = writer.resourceSnapshot()
            check("actual delayed track did not omit saved originals", snapshot.missingSavedSystemFrames == 25 * 16_000)
            check("healthy microphone falsely marked omitted", snapshot.missingSavedMicFrames == 0)
            check("coverage fixture saved duration changed", snapshot.writtenFrames == 30 * 16_000)
            var current = stale
            var integrity = MeetingCaptureIntegrity(lastCapturedAt: start.addingTimeInterval(30))
            integrity.missingSavedMicFrames = Int64(snapshot.missingSavedMicFrames)
            integrity.missingSavedSystemFrames = Int64(snapshot.missingSavedSystemFrames)
            current.captureIntegrity = integrity
            check("producer counters were not persisted", store.save(current))

            let infer: @Sendable ([Float]) async throws -> ASRResult = { samples in
                ASRResult(text: "final improvement replaces earlier wording with detailed correct microphone text",
                    confidence: 1, duration: Double(samples.count) / 16_000,
                    processingTime: 0, tokenTimings: nil)
            }
            // Exercise the original competing candidate on the actual partial file.
            let system = try AudioConversion.samples(fromFileAt: audio,
                sampleRate: ChunkedTranscriber.sampleRate, channel: MeetingAudioWriter.systemChannel)
            let candidate = try await MeetingFinalPass.transcribeTrack(system, source: .system, transcribe: infer)
            check("original partial candidate did not pass old word gate",
                  MeetingFinalPass.accept(final: candidate.segments, live: live, source: .system))
            check("original candidate unexpectedly retained system tail",
                  !candidate.segments.contains(where: { $0.text == live.last?.text }))
            check("original candidate never transcribed saved speech", !candidate.windows.isEmpty)

            var completed = false
            let finals = FinalTranscriptService(transcribe: infer, afterFinalPass: { _, target in
                // A stale producer remains realistic: its entire old row has no loss
                // facts. The store must preserve the original writer measurement.
                var old = stale
                old.status = .done
                target.save(old)
                completed = true
            })
            finals.process(stale, store: store)
            let deadline = Date().addingTimeInterval(10)
            while finals.isRunning(stale.id), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            finals.cancel(stale.id)
            let reader = store.freshReaderForTesting()
            let transcript = reader.transcript(for: stale.id)
            check("coverage final service never completed", completed)
            check("healthy microphone never improved", transcript.contains(where: {
                $0.source == .mic && $0.text.hasPrefix("final improvement")
            }))
            check("damaged saved track erased original live segments",
                  transcript.filter { $0.source == .system } == live.filter { $0.source == .system })
            check("stale final producer erased measured saved loss",
                  reader.meeting(id: stale.id)?.captureIntegrity?.missingSavedSystemFrames == 25 * 16_000)
            check("stale final producer erased partial warning", reader.meeting(id: stale.id)?.hasPartialCapture == true)
            check("final service changed kept audio choice", reader.meeting(id: stale.id)?.audioIsTemporary == false)
        } catch { return ["saved-track coverage fixture: \(error)"] }
        return []
    }

}
