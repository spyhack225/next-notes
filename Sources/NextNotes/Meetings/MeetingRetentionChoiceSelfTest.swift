import AVFoundation
import FluidAudio
import Foundation
import SwiftUI

/// MR-05: actual start-time recording choices, later preference changes, Quit,
/// and a fresh JSON reader's restart plan. Capture and inference are scripted;
/// the session, writer, persistence and repair planner are production code.
@MainActor
enum MeetingRetentionChoiceSelfTest {
    static func run(log: (String) -> Void) async -> Bool {
        let settings = Settings.shared
        guard SelfTest.isRunning, settings.usesHarnessPreferencesForTesting else {
            log("MEETING_RETENTION_CHOICES_FAILED: isolated preferences unavailable")
            return false
        }
        let isolationFailures = settings.harnessPreferenceFailures()
        guard isolationFailures.isEmpty else {
            for failure in isolationFailures { log("MEETING_RETENTION_CHOICES_WRONG: \(failure)") }
            log("MEETING_RETENTION_CHOICES_FAILED: preference isolation checks failed")
            return false
        }

        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ passed: Bool) {
            checks += 1
            if !passed { failures.append(name) }
        }
        let ownerBefore = SelfTestStoreGuard.take()
        let oldKeep = settings.meetingsKeepAudio
        let oldFinal = settings.meetingsFinalPass
        let oldDiarize = settings.meetingsDiarize
        let oldNotes = settings.notesAutoGenerate
        let oldDelete = settings.meetingsDeleteAudioAfterNotes
        let oldPermission = MeetingSession.microphonePermissionOverrideForTesting
        let oldTranscribe = MeetingSession.transcribeOverrideForTesting
        let oldTap = SystemAudioCapture.startCallOverrideForTesting
        defer {
            settings.meetingsKeepAudio = oldKeep
            settings.meetingsFinalPass = oldFinal
            settings.chooseDiarization(oldDiarize)
            settings.notesAutoGenerate = oldNotes
            settings.meetingsDeleteAudioAfterNotes = oldDelete
            MeetingSession.microphonePermissionOverrideForTesting = oldPermission
            MeetingSession.transcribeOverrideForTesting = oldTranscribe
            SystemAudioCapture.startCallOverrideForTesting = oldTap
        }
        // The diarization answer is explicit only in this disposable process suite.
        // No speaker/model stage runs: this fixture ends through Quit, not Stop.
        settings.notesAutoGenerate = false
        settings.meetingsDeleteAudioAfterNotes = false
        MeetingSession.microphonePermissionOverrideForTesting = { true }
        MeetingSession.transcribeOverrideForTesting = { samples in
            (ASRResult(text: "Generated retention fixture speech.", confidence: 1,
                       duration: Double(samples.count) / 16_000,
                       processingTime: 0, tokenTimings: nil), 0, 0)
        }
        let capacity = MeetingDiskCapacity(immediateBytes: 10_000_000_000,
                                           importantBytes: 10_000_000_000)
        SystemAudioCapture.startCallOverrideForTesting = { format, onBuffer, onLevel in
            // Exactly the writer's five-second lead allowance: no forced padding
            // occurs before the microphone's real drain joins this track.
            onBuffer(AudioChunk(buffer: try pcm(format: format, frames: 5 * 16_000)))
            onLevel(0.1)
        }

        for keep in [false, true] {
            for finalPass in [false, true] {
                for diarize in [false, true] {
                    let label = "keep=\(keep) final=\(finalPass) diarize=\(diarize)"
                    settings.meetingsKeepAudio = keep
                    settings.meetingsFinalPass = finalPass
                    settings.chooseDiarization(diarize)
                    let wantsAudio = keep || finalPass || diarize
                    let store = MeetingStore.isolated()
                    let hub = AudioCaptureHub(probe: true)
                    var writer: MeetingAudioWriter?
                    var writerCreations = 0
                    let original = Meeting(title: "Generated retention choices", status: .scheduled)
                    let session = MeetingSession(meeting: original, store: store, captureHub: hub,
                        writerFactory: { url, error in
                            writerCreations += 1
                            let created = try MeetingAudioWriter(url: url, onWriteError: error)
                            writer = created
                            return created
                        }, diskCapacityForTesting: capacity)
                    do {
                        try await session.start()
                        let started = store.freshReaderForTesting().meeting(id: original.id)
                        check("\(label): start created the expected writer", writerCreations == (wantsAudio ? 1 : 0))
                        check("\(label): start persisted recording status", started?.status == .recording)
                        check("\(label): start persisted the expected audio link",
                              started?.audioFileName == (wantsAudio ? MeetingStore.audioFile : nil))
                        check("\(label): start persisted the keep choice",
                              started?.audioIsTemporary == (wantsAudio ? !keep : nil))
                        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                            sampleRate: 16_000, channels: 1, interleaved: false) else {
                            throw MeetingAudioWriterError.unsupportedFormat
                        }
                        hub.feedForTesting(try pcm(format: format, frames: 6 * 16_000))
                        let captured = await waitUntil {
                            let live = session.segments.contains { $0.source == .mic && !$0.text.isEmpty }
                            return live && (!wantsAudio || (writer?.resourceSnapshot().writtenFrames ?? 0) >= 5 * 16_000)
                        }
                        check("\(label): actual capture reached live ASR and required disk write", captured)
                        settings.meetingsKeepAudio = !keep
                        settings.meetingsFinalPass = !finalPass
                        settings.chooseDiarization(!diarize)
                        let changed = store.freshReaderForTesting().meeting(id: original.id)
                        check("\(label): later toggles preserved start-time audio facts",
                              changed?.audioFileName == started?.audioFileName
                                && changed?.audioIsTemporary == started?.audioIsTemporary)

                        session.endAbruptly()
                        let restarted = store.freshReaderForTesting()
                        let quit = restarted.meeting(id: original.id)
                        check("\(label): Quit persisted a resumable status", quit?.status == .transcribing)
                        check("\(label): Quit persisted actual live speech", !restarted.transcript(for: original.id).isEmpty)
                        check("\(label): Quit persisted the interruption", quit?.hasPartialCapture == true)
                        check("\(label): Quit kept the start-time keep choice", quit?.audioIsTemporary == started?.audioIsTemporary)
                        let audioURL = store.directory(for: original.id).appendingPathComponent(MeetingStore.audioFile)
                        if wantsAudio {
                            let readable = try AVAudioFile(forReading: audioURL)
                            let acceptedFrames = writer?.resourceSnapshot().writtenFrames ?? 0
                            let survivingFrames = Int(readable.length)
                            check("\(label): restart has readable surviving audio within writer acceptance",
                                  survivingFrames > 0 && survivingFrames <= acceptedFrames)
                            // Quit never waits for the file's buffered tail to close.
                            // Prove surviving captured samples, not complete-tail
                            // coverage; interruption metadata remains unchanged.
                            if survivingFrames > 0, survivingFrames <= acceptedFrames,
                               survivingFrames <= 6 * 16_000,
                               let buffer = AVAudioPCMBuffer(pcmFormat: readable.processingFormat,
                                   frameCapacity: AVAudioFrameCount(survivingFrames)) {
                                try readable.read(into: buffer)
                                for channel in [MeetingAudioWriter.micChannel, MeetingAudioWriter.systemChannel] {
                                    let samples = buffer.floatChannelData.map {
                                        UnsafeBufferPointer(start: $0[channel], count: Int(buffer.frameLength))
                                    }
                                    check("\(label): surviving channel \(channel) contains actual generated capture",
                                          samples?.contains { abs($0 - 0.1) < 0.001 } == true)
                                }
                            } else {
                                check("\(label): surviving captured samples can be read back", false)
                            }
                        } else {
                            check("\(label): all disabled wrote no recording", !FileManager.default.fileExists(atPath: audioURL.path))
                        }
                        let plan = restarted.repairInterruptedMeetings()
                        check("\(label): fresh restart plans from surviving facts",
                              plan.count == 1 && plan.first?.0 == original.id
                                && plan.first?.1 == (wantsAudio ? .finalPass : .pipelineAfterTranscript))
                        let repaired = restarted.freshReaderForTesting().meeting(id: original.id)
                        check("\(label): restart preserved the start-time audio facts",
                              repaired?.audioFileName == started?.audioFileName
                                && repaired?.audioIsTemporary == started?.audioIsTemporary
                                && repaired?.hasPartialCapture == true)
                        if wantsAudio {
                            check("\(label): restart repair retained the recording", restarted.audioURL(for: repaired ?? original) != nil)
                            if keep {
                                restarted.releaseAudio(for: original.id, notesWritten: false,
                                                       deleteKeptAfterNotes: true)
                                check("\(label): kept recording cannot release before notes",
                                      restarted.audioURL(for: repaired ?? original) != nil)
                            }
                        }
                        log("MEETING_RETENTION_CHOICE: \(label) writer=\(writerCreations) restart=\(wantsAudio ? "finalPass" : "pipelineAfterTranscript")")
                    } catch {
                        failures.append("\(label): \(error.localizedDescription)")
                    }
                    session.endAbruptly()
                    // Close the injected writer only after checking Quit's real
                    // committed bytes. This is harness cleanup, not a Quit await.
                    await writer?.finish()
                }
            }
        }

        // An older recording can have a file whose original keep answer is unknown.
        // Exercise the existing release/sweep producers with a readable generated
        // file, independently of the current delete-after-notes preference.
        do {
            let legacyStore = MeetingStore.isolated()
            var legacy = Meeting(title: "Generated unknown retention", status: .done)
            legacy.audioFileName = MeetingStore.audioFile
            legacy.audioIsTemporary = nil
            legacy.audioReleaseAfter = Date().addingTimeInterval(-3_600)
            legacyStore.save(legacy)
            let url = legacyStore.directory(for: legacy.id).appendingPathComponent(MeetingStore.audioFile)
            let writer = try MeetingAudioWriter(url: url)
            await writer.append([Float](repeating: 0.1, count: 16_000), from: .mic)
            await writer.append([Float](repeating: 0.1, count: 16_000), from: .system)
            await writer.finish()
            settings.meetingsDeleteAudioAfterNotes = true
            let fresh = legacyStore.freshReaderForTesting()
            fresh.releaseAudioWhenDue(for: legacy.id, notesWritten: true, freeBytes: 0)
            fresh.sweepExpiredAudio(freeBytes: 0, hasDiarizationProblem: { _ in false })
            let retained = fresh.freshReaderForTesting().meeting(id: legacy.id)
            let readableFrames = try AVAudioFile(forReading: url).length
            check("unknown keep answer survives release and sweep under disk pressure",
                  retained?.audioIsTemporary == nil && retained?.audioFileName == MeetingStore.audioFile
                    && readableFrames == 16_000)
        } catch { failures.append("unknown retention producer: \(error.localizedDescription)") }

        if let directory = SelfTest.value(after: "--meeting-reliability-sheet") {
            check("complete actual meeting settings form rendered",
                  MeetingConsolePreview.writeReliabilitySheet(
                    SettingsPane(tab: .meetings) { MeetingsSettingsTab() },
                    named: "meeting-settings-retention", to: directory,
                    size: CGSize(width: 720, height: 1_800)))
        }
        check("fixture flows left owner stores and preferences untouched",
              SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty)
        for failure in failures { log("MEETING_RETENTION_CHOICES_WRONG: \(failure)") }
        log(failures.isEmpty
            ? "MEETING_RETENTION_CHOICES_OK: 8 actual start/toggle/Quit/fresh-reader cases; \(checks) checks"
            : "MEETING_RETENTION_CHOICES_FAILED: \(failures.count) checks wrong")
        return failures.isEmpty
    }

    private nonisolated static func pcm(format: AVAudioFormat, frames: Int) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { throw MeetingAudioWriterError.unsupportedFormat }
        buffer.frameLength = AVAudioFrameCount(frames)
        samples.initialize(repeating: 0.1, count: frames)
        return buffer
    }

    private static func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}
