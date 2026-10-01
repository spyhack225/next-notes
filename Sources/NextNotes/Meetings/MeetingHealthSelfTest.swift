import AVFoundation
import FluidAudio
import Foundation

/// Actual isolated session start/capture/writer/error/warning producers. Only
/// external capture, permission, inference and notification delivery are injected.
@MainActor
enum MeetingHealthSelfTest {
    static func run(log: (String) -> Void) async -> Bool {
        var failures: [String] = []
        var checks = 0
        func check(_ label: String, _ value: Bool) {
            checks += 1
            if !value { failures.append(label) }
        }
        let safe = MeetingDiskCapacity(immediateBytes: 10_000_000_000,
                                       importantBytes: 10_000_000_000)
        let began = Date(timeIntervalSince1970: 1_700_000_000)
        let now = began.addingTimeInterval(MeetingResourceHealth.stallInterval + 1)
        let normal = MeetingHealthInput(now: now, beganAt: began, disk: safe,
            memoryIsTight: false, lastMicAt: now, lastSystemAt: now,
            expectsSystem: true, writerPresent: true, writerFailed: false,
            lastWriteProgressAt: now)
        check("delivered silence must stay healthy", MeetingResourceHealth.issues(normal).isEmpty)
        var input = normal
        input.lastMicAt = began
        check("stopped delivery must be identified", MeetingResourceHealth.issues(input).contains(.microphoneStalled))
        input = normal
        input.lastSystemAt = nil
        check("missing expected system track must be identified", MeetingResourceHealth.issues(input).contains(.systemStalled))
        input.expectsSystem = false
        check("unavailable system tap must not claim stopped delivery", !MeetingResourceHealth.issues(input).contains(.systemStalled))
        input = normal
        input.lastWriteProgressAt = began
        check("healthy delivery and stopped saving must be distinguished", MeetingResourceHealth.issues(input).contains(.savingStalled))
        check("saving lag must not claim confirmed capture loss", !MeetingHealthIssue.savingStalled.isCaptureFailure)
        input.writerFailed = true
        let rejected = MeetingResourceHealth.issues(input)
        check("writer rejection is not just slow saving", rejected.contains(.audioWriteFailure) && !rejected.contains(.savingStalled))
        input = normal
        input.disk = .init(immediateBytes: nil, importantBytes: nil)
        check("unknown capacity must stay unknown", MeetingResourceHealth.issues(input).contains(.storageUnknown))
        input.disk = .init(immediateBytes: 100_000_000, importantBytes: 10_000_000_000)
        check("reclaimable capacity must not hide low immediately writable space", MeetingResourceHealth.issues(input).contains(.storageLow))
        input = normal
        input.memoryIsTight = true
        check("memory pressure warning remains separate", MeetingResourceHealth.issues(input).contains(.memoryPressure))

        let oldPermission = MeetingSession.microphonePermissionOverrideForTesting
        let oldTranscribe = MeetingSession.transcribeOverrideForTesting
        let oldTap = SystemAudioCapture.startCallOverrideForTesting
        let oldPost = Notifications.shared.meetingProblemPostForTesting
        let settings = Settings.shared
        guard settings.usesHarnessPreferencesForTesting else {
            log("MEETING_HEALTH_FAILED: isolated settings unavailable; no fixture preference written")
            return false
        }
        let preferenceFailures = settings.harnessPreferenceFailures()
        guard preferenceFailures.isEmpty else {
            for failure in preferenceFailures { log("MEETING_HEALTH_WRONG: \(failure)") }
            log("MEETING_HEALTH_FAILED: settings isolation producer checks failed")
            return false
        }
        check("actual preference writers and fresh reader stay isolated", preferenceFailures.isEmpty)
        let oldKeep = settings.meetingsKeepAudio
        let oldFinalPass = settings.meetingsFinalPass
        let oldNotes = settings.notesAutoGenerate
        defer {
            MeetingSession.microphonePermissionOverrideForTesting = oldPermission
            MeetingSession.transcribeOverrideForTesting = oldTranscribe
            SystemAudioCapture.startCallOverrideForTesting = oldTap
            Notifications.shared.meetingProblemPostForTesting = oldPost
            settings.meetingsKeepAudio = oldKeep
            settings.meetingsFinalPass = oldFinalPass
            settings.notesAutoGenerate = oldNotes
        }
        settings.meetingsKeepAudio = true
        settings.meetingsFinalPass = false
        settings.notesAutoGenerate = false
        MeetingSession.microphonePermissionOverrideForTesting = { true }
        let model = ModelCounter()
        MeetingSession.transcribeOverrideForTesting = { await model.transcribe($0) }
        SystemAudioCapture.startCallOverrideForTesting = { format, onBuffer, onLevel in
            let buffer = try pcm(format: format, frames: 16_000, value: 0)
            onBuffer(AudioChunk(buffer: buffer))
            onLevel(0)
        }

        // Silence through the real hub still provides progress. Denied notification
        // transport cannot remove a later durable capture gap or the in-app warning.
        do {
            let store = MeetingStore.isolated()
            let hub = AudioCaptureHub(probe: true)
            var actualWriter: MeetingAudioWriter?
            let meeting = Meeting(title: "Silent health fixture", start: Date(), status: .scheduled)
            let session = MeetingSession(meeting: meeting, store: store, captureHub: hub,
                writerFactory: { url, error in
                    let writer = try MeetingAudioWriter(url: url, onWriteError: error)
                    actualWriter = writer
                    return writer
                }, diskCapacityForTesting: safe)
            defer { session.endAbruptly() }
            try await session.start()
            check("start persisted requested keep choice", store.freshReaderForTesting().meeting(id: meeting.id)?.audioIsTemporary == false)
            settings.meetingsKeepAudio = false
            check("later setting change rewrote start-time keep choice", store.freshReaderForTesting().meeting(id: meeting.id)?.audioIsTemporary == false)
            settings.meetingsKeepAudio = true
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false),
                  let writer = actualWriter else { throw MeetingAudioWriterError.unsupportedFormat }
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: true)
            check("unproven capture falsely claimed safe paused transcription", !session.liveTranscriptPaused)
            hub.feedForTesting(try pcm(format: format, frames: 16_000, value: 0))
            let saved = await waitUntil { await writer.resourceSnapshot().writtenFrames > 0 }
            check("real silent capture reaches the actual writer", saved)
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: false)
            check("real silent capture incorrectly marked stalled", !session.healthWarnings.contains(where: \.isCaptureFailure))
            check("silent microphone meter remains silent", session.micLevel == 0)
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: true)
            check("healthy saved audio did not admit pressure fallback", session.liveTranscriptPaused)
            hub.feedForTesting(try pcm(format: format, frames: 8_000, value: 0))
            check("paused transcript stopped accepting recovery audio", await waitUntil {
                await writer.resourceSnapshot().queuedBytes >= 8_000 * MemoryLayout<Float>.stride
            })
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: false)
            check("normal conditions did not resume live transcript", !session.liveTranscriptPaused)
            Notifications.shared.meetingProblemPostForTesting = nil // transport denied/absent
            await session.checkResourceHealth(now: Date().addingTimeInterval(MeetingResourceHealth.stallInterval + 1),
                                             capacityForTesting: safe, criticalForTesting: false)
            check("absent notification erased in-app microphone warning", session.healthWarnings.contains(.microphoneStalled))
            check("absent notification erased in-app system warning", session.healthWarnings.contains(.systemStalled))
            check("absent notification erased durable capture gap", store.freshReaderForTesting().meeting(id: meeting.id)?.captureIntegrity?.captureGap == true)
            let content = Notifications.meetingProblemContent(meeting: session.meeting, issue: .captureGap)
            check("capture gap routed to a storage-only notification", content.body == MeetingHealthIssue.captureGap.message && !content.body.lowercased().contains("storage"))
            session.endAbruptly()
            check("shutdown erased durable gap", store.freshReaderForTesting().meeting(id: meeting.id)?.captureIntegrity?.captureGap == true)
        } catch { failures.append("actual silent/stalled session: \(error.localizedDescription)") }

        // Real writer failure traverses the session callback, persistence and
        // notification producer. Live ASR continues after file acceptance fails.
        do {
            let store = MeetingStore.isolated()
            let hub = AudioCaptureHub(probe: true)
            var actualWriter: MeetingAudioWriter?
            var failurePosts = 0
            var wrongBody = false
            Notifications.shared.meetingProblemPostForTesting = { _, issue, content in
                if issue == .audioWriteFailure {
                    failurePosts += 1
                    wrongBody = wrongBody || content.body != MeetingHealthIssue.audioWriteFailure.message
                }
            }
            let meeting = Meeting(title: "Writer health fixture", start: Date(), status: .scheduled)
            let session = MeetingSession(meeting: meeting, store: store, captureHub: hub,
                writerFactory: { url, error in
                    let writer = try MeetingAudioWriter(url: url, onWriteError: error,
                        write: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
                    actualWriter = writer
                    return writer
                }, diskCapacityForTesting: safe)
            defer { session.endAbruptly() }
            try await session.start()
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false),
                  let writer = actualWriter else { throw MeetingAudioWriterError.unsupportedFormat }
            hub.feedForTesting(try pcm(format: format, frames: 6 * 16_000, value: 0.1))
            check("injected ENOSPC never reached actual writer", await waitUntil { await writer.didFail })
            check("writer failure never reached session", await waitUntil { @MainActor in session.healthWarnings.contains(.audioWriteFailure) })
            check("file rejection stopped live ASR", await waitUntil { await model.calls > 0 })
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: true)
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: true)
            check("failed writer falsely claimed safe paused transcription", !session.liveTranscriptPaused)
            check("writer warning transport repeated or changed cause", failurePosts == 1 && !wrongBody)
            check("writer failure did not persist through fresh reader", store.freshReaderForTesting().meeting(id: meeting.id)?.captureIntegrity?.audioWriteFailed == true)
            let refused = await writer.resourceSnapshot()
            check("session's failed writer retained abandoned capacity", refused.queueCapacityBytes == 0)
            Notifications.shared.meetingProblemPostForTesting = nil
            session.endAbruptly()
            let fresh = store.freshReaderForTesting().meeting(id: meeting.id)
            check("abrupt recovery row erased writer failure", fresh?.captureIntegrity?.audioWriteFailed == true && fresh?.hasPartialCapture == true)
        } catch { failures.append("actual writer failure session: \(error.localizedDescription)") }

        // Reject the real metadata producer with a directory at its file destination.
        // Audio and transcript destinations remain writable; no full disk is needed.
        do {
            let store = MeetingStore.isolated()
            let hub = AudioCaptureHub(probe: true)
            let meeting = Meeting(title: "Metadata rejection fixture", status: .scheduled)
            let obstructed = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.recordFile)
            try FileManager.default.createDirectory(at: obstructed, withIntermediateDirectories: true)
            var metadataPosts = 0
            var otherFailurePosts = 0
            Notifications.shared.meetingProblemPostForTesting = { _, issue, content in
                if issue == .metadataWriteFailure {
                    metadataPosts += 1
                    if content.body != MeetingHealthIssue.metadataWriteFailure.message { otherFailurePosts += 1 }
                } else if issue == .audioWriteFailure || issue == .transcriptWriteFailure {
                    otherFailurePosts += 1
                }
            }
            let session = MeetingSession(meeting: meeting, store: store, captureHub: hub,
                                         diskCapacityForTesting: safe)
            defer {
                try? FileManager.default.removeItem(at: obstructed)
                session.endAbruptly()
            }
            try await session.start()
            check("metadata rejection falsely published a committed row", store.meeting(id: meeting.id) == nil)
            check("metadata rejection was not surfaced in-app", session.healthWarnings.contains(.metadataWriteFailure))
            check("metadata warning was repeated or misrouted", metadataPosts == 1 && otherFailurePosts == 0)
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: false)
            check("repeated failed metadata save repeated its notification", metadataPosts == 1)
            check("metadata rejection falsely claimed captured speech was lost", session.meeting.captureIntegrity?.captureGap != true)
            try FileManager.default.removeItem(at: obstructed)
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: false)
            check("metadata producer did not resume saving after obstruction cleared", store.freshReaderForTesting().meeting(id: meeting.id) != nil)
        } catch { failures.append("actual metadata rejection session: \(error.localizedDescription)") }

        // The actual tap start producer fails once, then succeeds through its existing
        // retry seam. Success cannot reconstruct the missing initial system track.
        do {
            let store = MeetingStore.isolated()
            let hub = AudioCaptureHub(probe: true)
            let tap = RetryTap()
            SystemAudioCapture.startCallOverrideForTesting = { format, onBuffer, onLevel in
                try await tap.start(format: format, onBuffer: onBuffer, onLevel: onLevel)
            }
            var unavailablePosts = 0
            Notifications.shared.meetingProblemPostForTesting = { _, issue, _ in
                if issue == .systemUnavailable { unavailablePosts += 1 }
            }
            let meeting = Meeting(title: "Unavailable system retry fixture", status: .scheduled)
            let session = MeetingSession(meeting: meeting, store: store, captureHub: hub,
                                         diskCapacityForTesting: safe)
            session.setTapRetryIntervalForTesting(.milliseconds(50))
            defer { session.endAbruptly() }
            try await session.start()
            check("failed tap did not retain its in-app warning", session.healthWarnings.contains(.systemUnavailable))
            check("failed tap did not persist its missing initial track", store.freshReaderForTesting().meeting(id: meeting.id)?.captureIntegrity?.captureGap == true)
            check("failed tap warning repeated or absent", unavailablePosts == 1)
            let joined = await waitUntil {
                let calls = await tap.calls
                return session.systemAudioProblem == nil && calls >= 2
            }
            check("failed tap never recovered through actual retry", joined)
            check("successful tap retry erased durable capture gap", store.freshReaderForTesting().meeting(id: meeting.id)?.captureIntegrity?.captureGap == true)
            check("successful retry erased missing-track warning", session.healthWarnings.contains(.systemUnavailable))
            session.endAbruptly()
            check("shutdown erased failed-tap capture gap", store.freshReaderForTesting().meeting(id: meeting.id)?.captureIntegrity?.captureGap == true)
        } catch { failures.append("actual failed tap retry session: \(error.localizedDescription)") }

        // Hold the actual native file boundary while the real system-capture
        // callback fills the existing 1,024-packet stream. No synthetic gap is
        // injected: AsyncStream.yield must reject actual captured packets.
        do {
            let store = MeetingStore.isolated()
            let hub = AudioCaptureHub(probe: true)
            let gate = WriteGate()
            let tap = OverflowTap()
            SystemAudioCapture.startCallOverrideForTesting = { format, onBuffer, onLevel in
                try await tap.start(format: format, onBuffer: onBuffer, onLevel: onLevel)
            }
            var gapPosts = 0
            var gapBodyWasWrong = false
            Notifications.shared.meetingProblemPostForTesting = { _, issue, content in
                if issue == .captureGap {
                    gapPosts += 1
                    gapBodyWasWrong = gapBodyWasWrong || content.body != MeetingHealthIssue.captureGap.message
                }
            }
            let meeting = Meeting(title: "Actual capture overflow fixture", status: .scheduled)
            let session = MeetingSession(meeting: meeting, store: store, captureHub: hub,
                writerFactory: { url, error in
                    try MeetingAudioWriter(url: url, onWriteError: error, write: { file, buffer in
                        gate.holdFirstWrite()
                        try file.write(from: buffer)
                    })
                }, diskCapacityForTesting: safe)
            defer {
                gate.release()
                session.endAbruptly()
            }
            try await session.start()
            let held = await waitUntil { gate.entered }
            check("capture overflow never held its actual writer", held)
            if held {
                let burstPackets = 1_500
                let packetFrames = 32
                try await tap.emit(packets: burstPackets, frames: packetFrames)
                // The first warning can run before the burst ends. Sample the
                // producer's final cumulative count through the real health tick.
                await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: false)
                let overflow = await waitUntil {
                    (store.meeting(id: meeting.id)?.captureIntegrity?.missingCaptureFrames ?? 0) > 0
                }
                check("actual bounded capture stream never reported dropped frames", overflow)
                let dropped = store.freshReaderForTesting().meeting(id: meeting.id)?.captureIntegrity?.missingCaptureFrames ?? 0
                let expected = Int64((burstPackets - 1_024) * packetFrames)
                check("actual yield rejection lost or invented dropped-frame counts", dropped == expected)
                check("actual capture overflow lost its visible warning", session.healthWarnings.contains(.captureGap))
                check("actual capture overflow spammed or misrouted notifications", gapPosts == 1 && !gapBodyWasWrong)
                gate.release()
                await session.stop()
                let fresh = store.freshReaderForTesting().meeting(id: meeting.id)
                check("normal stop erased actual captured drop counts", fresh?.captureIntegrity?.missingCaptureFrames == expected)
                check("normal stop falsely completed capture overflow", fresh?.status.isFailure == true && fresh?.hasPartialCapture == true)
                log("MEETING_HEALTH_OVERFLOW packets=\(burstPackets) packet_frames=\(packetFrames) missed_frames=\(dropped)")
            }
        } catch { failures.append("actual capture overflow session: \(error.localizedDescription)") }

        // Exercise the real healthy Stop, not a seeded normal-end record. Both
        // captured tracks reach the live window consumer and actual audio file.
        do {
            let store = MeetingStore.isolated()
            let hub = AudioCaptureHub(probe: true)
            let oldDiarize = settings.meetingsDiarize
            settings.chooseDiarization(false)
            // Only this disposable harness domain is changed. Restore its effective
            // answer; the owner's optional choice/domain never enters this fixture.
            defer { settings.chooseDiarization(oldDiarize) }
            MeetingSession.transcribeOverrideForTesting = { samples in
                (ASRResult(text: "Synthetic captured speech.", confidence: 1,
                           duration: Double(samples.count) / 16_000,
                           processingTime: 0, tokenTimings: nil), 0, 0)
            }
            SystemAudioCapture.startCallOverrideForTesting = { format, onBuffer, onLevel in
                onBuffer(AudioChunk(buffer: try pcm(format: format, frames: 3 * 16_000, value: 0.1)))
                onLevel(0.1)
            }
            Notifications.shared.meetingProblemPostForTesting = nil
            var actualWriter: MeetingAudioWriter?
            let meeting = Meeting(title: "Actual normal stop fixture", status: .scheduled)
            let session = MeetingSession(meeting: meeting, store: store, captureHub: hub,
                writerFactory: { url, error in
                    let writer = try MeetingAudioWriter(url: url, onWriteError: error)
                    actualWriter = writer
                    return writer
                }, diskCapacityForTesting: safe)
            defer { session.endAbruptly() }
            try await session.start()
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false),
                  let writer = actualWriter else { throw MeetingAudioWriterError.unsupportedFormat }
            hub.feedForTesting(try pcm(format: format, frames: 3 * 16_000, value: 0.1))
            check("normal stop fixture never received saved capture", await waitUntil { await writer.resourceSnapshot().writtenFrames >= 3 * 16_000 })
            settings.meetingsKeepAudio = false
            await session.stop()
            settings.meetingsKeepAudio = true
            let fresh = store.freshReaderForTesting()
            let saved = fresh.meeting(id: meeting.id)
            let progress = await writer.resourceSnapshot()
            let sources = Set(fresh.transcript(for: meeting.id).map(\.source))
            check("healthy Stop did not reach actual done pipeline", saved?.status == .done)
            check("healthy Stop did not persist its end fact", saved?.captureIntegrity?.normalEndAt == saved?.end && saved?.end != nil)
            check("healthy Stop became a capture interruption", saved?.captureIntegrity?.interruptedAt == nil && saved?.hasPartialCapture == false)
            check("healthy Stop lost its written sample boundary", saved?.captureBoundary == saved?.start.addingTimeInterval(Double(progress.writtenFrames) / 16_000))
            check("healthy Stop did not preserve both live captured tracks", sources == Set([AudioSource.mic, .system]))
            check("mid-meeting keep toggle rewrote actual Stop snapshot", saved?.audioIsTemporary == false)
        } catch { failures.append("actual healthy stop session: \(error.localizedDescription)") }

        // The writer can replace a late track's position with silence before its
        // original samples arrive. That actual source omission must reach the
        // session warning and durable record, independently of stream overflow.
        do {
            let store = MeetingStore.isolated()
            let hub = AudioCaptureHub(probe: true)
            let meeting = Meeting(title: "Saved source coverage fixture", status: .scheduled)
            let directory = store.directory(for: meeting.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let writerURL = directory.appendingPathComponent(MeetingStore.audioFile)
            let writer = try MeetingAudioWriter(url: writerURL)
            await writer.append(Array(repeating: Float(0.1), count: 6 * 16_000),
                                from: .mic, startFrame: 0)
            check("saved source fixture never wrote its padding prefix", writer.resourceSnapshot().writtenFrames == 16_000)
            SystemAudioCapture.startCallOverrideForTesting = { format, onBuffer, onLevel in
                // A known earlier capture time places this generated packet at
                // frame zero through the real session timestamp conversion.
                onBuffer(AudioChunk(buffer: try pcm(format: format, frames: 16_000, value: 0.2),
                                    captureHostTime: 1))
                onLevel(0.2)
            }
            var savedGapPosts = 0
            var savedGapBodyWasWrong = false
            Notifications.shared.meetingProblemPostForTesting = { _, issue, content in
                if issue == .savedAudioGap {
                    savedGapPosts += 1
                    savedGapBodyWasWrong = savedGapBodyWasWrong
                        || content.body != MeetingHealthIssue.savedAudioGap.message
                        || content.body.lowercased().contains("storage")
                }
            }
            let session = MeetingSession(meeting: meeting, store: store, captureHub: hub,
                writerFactory: { url, _ in
                    guard url == writerURL else { throw MeetingAudioWriterError.unsupportedFormat }
                    return writer
                }, diskCapacityForTesting: safe)
            defer { session.endAbruptly() }
            try await session.start()
            check("actual late track never produced saved-source omission", await waitUntil {
                writer.resourceSnapshot().missingSavedSystemFrames == 16_000
            })
            let producer = writer.resourceSnapshot()
            check("late system source omission falsely changed mic count", producer.missingSavedMicFrames == 0)
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: false)
            let saved = store.freshReaderForTesting().meeting(id: meeting.id)
            check("session health did not persist actual system source omission", saved?.captureIntegrity?.missingSavedSystemFrames == 16_000)
            check("session health misattributed saved source omission", saved?.captureIntegrity?.missingSavedMicFrames == 0)
            check("session health hid saved source omission", session.healthWarnings.contains(.savedAudioGap) && saved?.hasPartialCapture == true)
            await session.checkResourceHealth(capacityForTesting: safe, criticalForTesting: false)
            check("saved source warning spammed or became storage-only", savedGapPosts == 1 && !savedGapBodyWasWrong)
            var stale = session.meeting
            stale.captureIntegrity = MeetingCaptureIntegrity()
            check("stale metadata save was rejected unexpectedly", store.save(stale))
            let fresh = store.freshReaderForTesting().meeting(id: meeting.id)
            check("stale whole-record save erased actual source omission", fresh?.captureIntegrity?.missingSavedSystemFrames == 16_000
                  && fresh?.captureIntegrity?.missingSavedMicFrames == 0 && fresh?.hasPartialCapture == true)
            session.endAbruptly()
            check("shutdown erased saved-source omission", store.freshReaderForTesting().meeting(id: meeting.id)?.captureIntegrity?.missingSavedSystemFrames == 16_000)
        } catch { failures.append("actual saved source coverage session: \(error.localizedDescription)") }

        for failure in failures { log("MEETING_HEALTH_WRONG: \(failure)") }
        log(failures.isEmpty ? "MEETING_HEALTH_OK: \(checks) checks; actual capture, writer, durable warning and notification producers"
            : "MEETING_HEALTH_FAILED: \(failures.count) checks wrong")
        return failures.isEmpty
    }

    private nonisolated static func pcm(format: AVAudioFormat, frames: Int, value: Float) throws -> AVAudioPCMBuffer {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = pcm.floatChannelData?[0] else { throw MeetingAudioWriterError.unsupportedFormat }
        pcm.frameLength = AVAudioFrameCount(frames)
        channel.initialize(repeating: value, count: frames)
        return pcm
    }

    private static func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            // Fixture scheduling only: no capture/interactive production delay.
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private actor ModelCounter {
        private(set) var calls = 0
        func transcribe(_ samples: [Float]) -> (result: ASRResult, laneWait: TimeInterval, compute: TimeInterval) {
            calls += 1
            return (ASRResult(text: "", confidence: 1, duration: Double(samples.count) / 16_000,
                              processingTime: 0, tokenTimings: nil), 0, 0)
        }
    }

    private actor RetryTap {
        private(set) var calls = 0
        func start(format: AVAudioFormat, onBuffer: @Sendable (AudioChunk) -> Void,
                   onLevel: @Sendable (Float) -> Void) throws {
            calls += 1
            guard calls >= 2 else { throw SystemAudioError.deviceStartTimedOut }
            onBuffer(AudioChunk(buffer: try MeetingHealthSelfTest.pcm(format: format, frames: 16_000, value: 0)))
            onLevel(0)
        }
    }

    private actor OverflowTap {
        private var format: AVAudioFormat?
        private var onBuffer: (@Sendable (AudioChunk) -> Void)?
        func start(format: AVAudioFormat, onBuffer: @escaping @Sendable (AudioChunk) -> Void,
                   onLevel: @Sendable (Float) -> Void) throws {
            self.format = format
            self.onBuffer = onBuffer
            // A one-sided lead beyond five seconds reaches the real writer before
            // any microphone packet, which deterministically parks its drain.
            onBuffer(AudioChunk(buffer: try MeetingHealthSelfTest.pcm(format: format, frames: 6 * 16_000, value: 0)))
            onLevel(0)
        }
        func emit(packets: Int, frames: Int) throws {
            guard let format, let onBuffer else { throw MeetingAudioWriterError.unsupportedFormat }
            for _ in 0..<packets {
                onBuffer(AudioChunk(buffer: try MeetingHealthSelfTest.pcm(format: format, frames: frames, value: 0)))
            }
        }
    }

    private final class WriteGate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var didEnter = false
        var entered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didEnter
        }
        func holdFirstWrite() {
            lock.lock()
            let first = !didEnter
            didEnter = true
            lock.unlock()
            // A failed fixture cannot leave a native actor blocked indefinitely.
            if first { _ = semaphore.wait(timeout: .now() + 10) }
        }
        func release() { semaphore.signal() }
    }
}
