import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// MR-03a's one controlled producer comparison. Run former/removed separately in
/// fresh signed harness processes with the same binary, fixtures and local model.
/// Only the native microphone/tap boundaries are generated; the meeting session,
/// hub worker, streams, ASR windows, transcript persistence and writer are real.
@MainActor
enum MeetingResourceNormalComparison {
    static func run(arm: String, log: (String) -> Void) async -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-meeting-resources-live",
              ["former", "removed"].contains(arm), Settings.shared.usesHarnessPreferencesForTesting else {
            log("MEETING_RESOURCES_LIVE_FAILED: isolated former/removed comparison required")
            return false
        }
        ModelResidencyPolicy.installPressureObserver()
        guard safeToLoad(), ParakeetModels.isDownloaded else {
            log("MEETING_RESOURCES_LIVE_ABSENT: installed speech model and normal pressure with 8 GB immediate storage required")
            return false
        }
        guard let fixtures = FixturePaths.meetings(argument: SelfTest.value(after: "--meeting-resource-fixtures")) else {
            log("MEETING_RESOURCES_LIVE_ABSENT: generated meeting fixtures required")
            return false
        }
        let ownerBefore = SelfTestStoreGuard.take()
        let settings = Settings.shared
        let roles = ModelRoleStore.shared
        let oldChoices = roles.snapshotChoicesForTesting()
        let ownerRoleWasLocal = roles.resolution(for: .meetingNotes).effective == .builtIn
        let oldKeep = settings.meetingsKeepAudio
        let oldFinal = settings.meetingsFinalPass
        let oldDiarize = settings.meetingsDiarize
        let oldNotes = settings.notesAutoGenerate
        let oldUnderstanding = settings.meetingLiveUnderstanding
        let oldPermission = MeetingSession.microphonePermissionOverrideForTesting
        let oldTranscribe = MeetingSession.transcribeOverrideForTesting
        let oldTap = SystemAudioCapture.startCallOverrideForTesting
        let oldPost = Notifications.shared.meetingProblemPostForTesting
        defer {
            settings.meetingsKeepAudio = oldKeep
            settings.meetingsFinalPass = oldFinal
            settings.chooseDiarization(oldDiarize)
            settings.notesAutoGenerate = oldNotes
            settings.meetingLiveUnderstanding = oldUnderstanding
            roles.restoreChoicesForTesting(oldChoices)
            MeetingSession.microphonePermissionOverrideForTesting = oldPermission
            MeetingSession.transcribeOverrideForTesting = oldTranscribe
            SystemAudioCapture.startCallOverrideForTesting = oldTap
            Notifications.shared.meetingProblemPostForTesting = oldPost
        }
        // Both arms exercise the local-role fixture without rewriting the saved
        // owner role or the independent agent model/file selection.
        roles.setChoiceForTesting(.builtIn, for: .meetingNotes)
        settings.meetingsKeepAudio = true
        settings.meetingsFinalPass = false
        settings.chooseDiarization(false)
        settings.notesAutoGenerate = true
        // The live context feature independently performs real model work after
        // enough speech. Disable its existing preference only in BOTH disposable
        // arms so this comparison isolates recording-start prewarm. Production
        // choices and the separate overlap acceptance remain unchanged.
        settings.meetingLiveUnderstanding = false
        MeetingSession.microphonePermissionOverrideForTesting = { true }
        Notifications.shared.meetingProblemPostForTesting = { _, _, _ in }
        let spec = await NotesModelRuntime.shared.activeSpec()
        guard spec.isDownloaded, InstalledModelLibrary.shared.hasUsableModel,
              roles.resolution(for: .meetingNotes).effective == .builtIn else {
            log("MEETING_RESOURCES_LIVE_ABSENT: selected installed local notes model required; no download or selection change performed")
            return false
        }
        let stageLog: (String) -> Void = { log($0 + " comparison_arm=\(arm)") }
        func requireOwnerUnchanged(_ stage: String) throws {
            let changes = SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take())
            guard changes.isEmpty else {
                // Only store basenames/preference keys and change kinds are emitted;
                // never their contents. Keep the original isolation gate strict.
                for change in changes {
                    log("MEETING_RESOURCES_NORMAL_ISOLATION arm=\(arm) stage=\(stage) change=\(change)")
                }
                throw Failure.ownerChanged
            }
        }
        do {
            try requireOwnerUnchanged("setup")
            guard await !ParakeetModels.shared.isLoaded, await !NotesModelRuntime.shared.isLoaded else {
                throw Failure.notFresh
            }
            let fixture = try Fixture.load(in: fixtures)
            let notesID = InstalledModelLibrary.shared.activeModel.flatMap {
                $0.fileURL.standardizedFileURL == spec.fileURL.standardizedFileURL ? $0.id : nil
            } ?? InstalledModelLibrary.builtInID
            // Content identities are computed once, before measurement and away
            // from capture. This warms filesystem pages equally in both arms.
            let identities = try await Task.detached(priority: .utility) {
                let notes = try ModelDownloader.sha256(of: spec.fileURL)
                let speech = try speechArtifactDigest()
                let executable = try Bundle.main.executableURL.map { try ModelDownloader.sha256(of: $0) }
                return (notes, speech, executable ?? "unknown")
            }.value
            try requireOwnerUnchanged("identities")
            log("MEETING_RESOURCES_NORMAL_CONFIG scope=MR03a_targeted_prewarm arm=\(arm) fixture=en-dialogue.wav fixture_sha256=\(fixture.digest) manifest_sha256=\(fixture.manifestDigest) cycles=3 frames_per_track=\(fixture.mic.count * 3) keep=true final_pass=false diarize=false auto_notes_during_capture=true live_understanding=false configured_fixture_role=local copied_saved_role_effective_in_harness_was_local=\(ownerRoleWasLocal) notes_model_id=\(notesID) notes_sha256=\(identities.0) speech_model_id=parakeet-tdt-0.6b-v3 speech_artifact_sha256=\(identities.1) speech_encoder_precision=int8 speech_configured_units=cpuAndNeuralEngine cpu_fallback_possible=true executable_sha256=\(identities.2) physical_memory_bytes=\(ProcessInfo.processInfo.physicalMemory) native_device_allocations=unavailable physical_capture=false digest_io_warms_filesystem=true")
            _ = try await MeetingResourceLiveProbe.measure("comparison_asr_fresh_process_load", log: stageLog) {
                guard safeToLoad(), ParakeetModels.isDownloaded else { throw Failure.resources }
                try await TranscriptionQueue.shared.warmUp()
                guard await ParakeetModels.shared.isLoaded else { throw Failure.inference }
                return 1
            }
            try requireOwnerUnchanged("asr_load")
            let result = try await MeetingResourceLiveProbe.measure("comparison_recording", log: stageLog) {
                try await capture(fixture: fixture, arm: arm)
            }
            try requireOwnerUnchanged("capture")
            log("MEETING_RESOURCES_NORMAL_CAPTURE arm=\(arm) delivered_frames_per_track=\(result.frames) audio_disk_bytes=\(result.diskBytes) missing_frames=\(result.missingFrames) native_calls=\(result.calls) native_input_seconds=\(number(result.nativeInputSeconds)) native_compute_seconds=\(number(result.computeSeconds)) lane_wait_seconds=\(number(result.laneWaitSeconds)) steady_footprint_p50=\(result.steadyFootprint.map(String.init) ?? "unknown") final_30s_samples=\(result.steadySamples) final_30s_notes_loaded_samples=\(result.steadyNotesSamples) sampled_queued_asr_logical_peak_bytes=\(result.queuedPeak.map(String.init) ?? "unknown") sampled_active_asr_logical_peak_bytes=\(result.activePeak.map(String.init) ?? "unknown") total_upstream_audio_capacity_bytes=unknown mic_recall=\(number(result.micRecall)) system_recall=\(number(result.systemRecall)) transcript_sha256=\(result.transcriptDigest) live_final_segment_lag_p50_seconds=\(result.lagP50.map(number) ?? "unknown") live_final_segment_lag_p95_seconds=\(result.lagP95.map(number) ?? "unknown") replay_lateness_max_seconds=\(number(result.replayLateness)) stop_seconds=\(number(result.stopSeconds)) concurrent_prewarm_seconds=\(result.prewarmSeconds.map(number) ?? "not-requested") notes_loaded_at_recording_end=\(result.notesLoadedAtEnd)")
            _ = try await MeetingResourceLiveProbe.measure("comparison_notes_prepare_after_stop", log: stageLog) {
                guard safeToLoad() else { throw Failure.resources }
                try await NotesModelRuntime.shared.prepare()
                guard await NotesModelRuntime.shared.isLoaded else { throw Failure.inference }
                return 1
            }
            for stage in ["comparison_notes_first_completion", "comparison_notes_warm_completion"] {
                _ = try await MeetingResourceLiveProbe.measure(stage, log: stageLog) {
                    guard safeToLoad() else { throw Failure.resources }
                    let answer = try await NotesModelRuntime.shared.complete(
                        system: "Write a short factual meeting summary.",
                        user: fixture.reference.joined(separator: " "), maxTokens: 128)
                    guard !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw Failure.inference
                    }
                    return answer.text.count
                }
            }
            _ = await NotesModelRuntime.shared.shutdown()
            try requireOwnerUnchanged("notes_shutdown")
            log("MEETING_RESOURCES_LIVE_OK: equal local-role generated-speech arm=\(arm); paired comparison and physical full-duplex/long-duration acceptance remain separate")
            return true
        } catch {
            let pressure = ModelResidencyPolicy.pressureSnapshot
            let capacity = MeetingDiskCapacity.current(at: FileManager.default.temporaryDirectory).immediateBytes
            log("MEETING_RESOURCES_NORMAL_ABORT arm=\(arm) pressure=\(pressure.level.rawValue) pressure_generation=\(pressure.generation) immediate_capacity_bytes=\(capacity.map(String.init) ?? "unknown") cancelled=\(Task.isCancelled)")
            _ = await NotesModelRuntime.shared.shutdown()
            log("MEETING_RESOURCES_LIVE_FAILED: normal comparison arm=\(arm) reason=\((error as? Failure)?.rawValue ?? "native-or-fixture-error")")
            return false
        }
    }

    private static func capture(fixture: Fixture, arm: String) async throws -> CaptureResult {
        let store = MeetingStore.isolated()
        let hub = AudioCaptureHub(probe: true)
        let tap = SyntheticTap()
        let calls = NativeCalls()
        SystemAudioCapture.startCallOverrideForTesting = { _, callback, _ in tap.install(callback) }
        MeetingSession.transcribeOverrideForTesting = { input in
            await calls.enter(input.count)
            let value = try await TranscriptionQueue.shared.transcribeWithLaneWait(input)
            await calls.complete(compute: value.compute, laneWait: value.laneWait)
            return value
        }
        var writer: MeetingAudioWriter?
        let meeting = Meeting(title: "Generated normal-operation comparison", status: .scheduled)
        let directory = store.directory(for: meeting.id)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let session = MeetingSession(meeting: meeting, store: store, captureHub: hub,
            writerFactory: { url, callback in
                let value = try MeetingAudioWriter(url: url, onWriteError: callback)
                writer = value
                return value
            })
        try await session.start()
        var warmup: Task<TimeInterval, Error>?
        defer { session.endAbruptly(); warmup?.cancel() }
        guard let writer, let hostOrigin = session.captureHostOriginForTesting else { throw Failure.coverage }
        if arm == "former" {
            // Exact former recording-start producer: concurrent background task,
            // same existing prepare/background-lane operation and eligibility.
            guard Settings.shared.notesAutoGenerate,
                  ModelRoleStore.shared.resolution(for: .meetingNotes).effective == .builtIn,
                  InstalledModelLibrary.shared.hasUsableModel else { throw Failure.notEligible }
            warmup = Task.detached(priority: .background) {
                let began = ContinuousClock.now
                guard safeToLoad() else { throw Failure.resources }
                try await NotesModelRuntime.shared.prepare()
                guard await NotesModelRuntime.shared.isLoaded else { throw Failure.inference }
                return ChunkedTranscriber.seconds(began.duration(to: .now))
            }
        }
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
            let frames = fixture.mic.count * 3
            let began = ContinuousClock.now
            let totalSeconds = Double(frames) / 16_000
            var steady: [UInt64] = []
            var steadySamples = 0
            var steadyNotes = 0
            var queuedPeak: Int?
            var activePeak: Int?
            var seen: Set<UUID> = []
            var lags: [Double] = []
            var lateness = 0.0
            for start in stride(from: 0, to: frames, by: 1_600) {
                guard ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork, !Task.isCancelled else {
                    throw Failure.resources
                }
                let targetSeconds = Double(start) / 16_000
                let target = began.advanced(by: .seconds(targetSeconds))
                try await Task.sleep(until: target, clock: .continuous)
                lateness = max(lateness, ChunkedTranscriber.seconds(target.duration(to: .now)))
                let count = min(1_600, frames - start)
                let mic = try pcm(fixture.mic, start: start, count: count, format: format)
                let system = try pcm(fixture.system, start: start, count: count, format: format)
                let host = hostOrigin + AVAudioTime.hostTime(forSeconds: targetSeconds)
                hub.feedForTesting(mic, captureHostTime: host)
                tap.feed(AudioChunk(buffer: system, captureHostTime: host))
                for segment in session.segments where seen.insert(segment.id).inserted {
                    lags.append(max(0, Date().timeIntervalSince(session.meeting.start) - segment.end))
                }
                if start % 16_000 == 0 {
                    if targetSeconds >= totalSeconds - 30 {
                        steadySamples += 1
                        if let bytes = ProcessSnapshot.current().physicalFootprintBytes { steady.append(bytes) }
                        if await NotesModelRuntime.shared.isLoaded { steadyNotes += 1 }
                    }
                    if let note = MetricsStore.shared.spans(named: .meetingResources).last?.note {
                        if let bytes = numeric("queuedBytes", in: note) { queuedPeak = max(queuedPeak ?? 0, bytes) }
                        if let bytes = numeric("activeBytes", in: note) { activePeak = max(activePeak ?? 0, bytes) }
                    }
                    if start % 160_000 == 0, !safeToLoad() { throw Failure.resources }
                    if writer.resourceSnapshot().writeFailed { throw Failure.coverage }
                }
            }
            let notesAtEnd = await NotesModelRuntime.shared.isLoaded
            if arm == "removed", notesAtEnd || steadyNotes > 0 { throw Failure.unexpectedNotesLoad }
            // Prevent unrelated automatic postprocessing. These equal harness
            // settings govern both arms; native notes timing is measured below
            // with identical public fixture text rather than varying ASR text.
            Settings.shared.notesAutoGenerate = false
            let stopBegan = ContinuousClock.now
            await session.stop()
            let stopSeconds = ChunkedTranscriber.seconds(stopBegan.duration(to: .now))
            let prewarmSeconds = try await warmup?.value
            guard safeToLoad(), await calls.allSucceeded else { throw Failure.inference }
            let saved = writer.resourceSnapshot()
            let audio = directory.appendingPathComponent(MeetingStore.audioFile)
            let mic = try AudioConversion.samples(fromFileAt: audio, sampleRate: 16_000, channel: 0)
            let system = try AudioConversion.samples(fromFileAt: audio, sampleRate: 16_000, channel: 1)
            SelfTest.diagnostic("MEETING_RESOURCES_NORMAL_COVERAGE arm=\(arm) expected_frames=\(frames) written_frames=\(saved.writtenFrames) mic_readback_frames=\(mic.count) system_readback_frames=\(system.count) writer_failed=\(saved.writeFailed) missing_saved_mic_frames=\(saved.missingSavedMicFrames) missing_saved_system_frames=\(saved.missingSavedSystemFrames)")
            guard saved.writtenFrames == frames, !saved.writeFailed,
                  saved.missingSavedMicFrames == 0, saved.missingSavedSystemFrames == 0,
                  mic.count == frames, system.count == frames else { throw Failure.coverage }
            for index in 0..<frames {
                let micMatches = abs(mic[index] - fixture.mic[index % fixture.mic.count]) < 0.00004
                let systemMatches = abs(system[index] - fixture.system[index % fixture.system.count]) < 0.00004
                guard micMatches, systemMatches else {
                    SelfTest.diagnostic("MEETING_RESOURCES_NORMAL_COVERAGE_MISMATCH arm=\(arm) first_frame=\(index) mic_mismatch=\(!micMatches) system_mismatch=\(!systemMatches)")
                    throw Failure.coverage
                }
            }
            guard let fresh = store.freshReaderForTesting().meeting(id: meeting.id),
                  !fresh.hasPartialCapture else { throw Failure.coverage }
            let transcript = store.freshReaderForTesting().transcript(for: meeting.id)
            guard transcript.contains(where: { $0.source == .mic }),
                  transcript.contains(where: { $0.source == .system }) else { throw Failure.inference }
            let stats = await calls.snapshot
            let fileBytes = (try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?.intValue ?? 0
            return CaptureResult(frames: frames, diskBytes: fileBytes, missingFrames: fresh.captureIntegrity?.missingCaptureFrames ?? 0,
                calls: stats.calls, nativeInputSeconds: Double(stats.samples) / 16_000,
                computeSeconds: stats.compute, laneWaitSeconds: stats.laneWait,
                steadyFootprint: percentile(steady, 0.5), steadySamples: steadySamples, steadyNotesSamples: steadyNotes,
                queuedPeak: queuedPeak, activePeak: activePeak,
                micRecall: recall(transcript.filter { $0.source == .mic }, against: fixture.micReference),
                systemRecall: recall(transcript.filter { $0.source == .system }, against: fixture.systemReference),
                transcriptDigest: digest(Data(transcript.map { "\($0.source.rawValue):\($0.text)" }.joined(separator: "\n").utf8)),
                lagP50: percentile(lags, 0.5), lagP95: percentile(lags, 0.95),
                replayLateness: lateness, stopSeconds: stopSeconds, prewarmSeconds: prewarmSeconds, notesLoadedAtEnd: notesAtEnd)
        } catch {
            session.endAbruptly()
            warmup?.cancel()
            _ = try? await warmup?.value
            await writer.finish()
            throw error
        }
    }

    private struct CaptureResult: Sendable {
        let frames: Int; let diskBytes: Int; let missingFrames: Int64
        let calls: Int; let nativeInputSeconds: Double; let computeSeconds: Double; let laneWaitSeconds: Double
        let steadyFootprint: UInt64?; let steadySamples: Int; let steadyNotesSamples: Int
        let queuedPeak: Int?; let activePeak: Int?; let micRecall: Double; let systemRecall: Double
        let transcriptDigest: String; let lagP50: Double?; let lagP95: Double?; let replayLateness: Double
        let stopSeconds: Double; let prewarmSeconds: Double?; let notesLoadedAtEnd: Bool
    }

    private struct Fixture: Sendable {
        let mic: [Float]; let system: [Float]; let micReference: [String]; let systemReference: [String]
        let reference: [String]; let digest: String; let manifestDigest: String
        private struct Manifest: Decodable {
            let files: [String: Entry]
            struct Entry: Decodable { let turns: [Turn] }
            struct Turn: Decodable { let speaker: String; let start: Double; let end: Double; let text: String }
        }
        static func load(in directory: URL) throws -> Fixture {
            let audio = directory.appendingPathComponent("en-dialogue.wav")
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard let entry = manifest.files["en-dialogue.wav"], !entry.turns.isEmpty else { throw Failure.fixture }
            let samples = try AudioConversion.samples(fromFileAt: audio, sampleRate: 16_000, channel: nil)
            guard samples.count > 16_000, samples.count < 2_000_000 else { throw Failure.fixture }
            var mic = [Float](repeating: 0, count: samples.count)
            var system = mic
            for turn in entry.turns {
                guard ["A", "B"].contains(turn.speaker), turn.start >= 0, turn.end > turn.start else { throw Failure.fixture }
                let start = min(samples.count, Int((turn.start * 16_000).rounded()))
                let end = min(samples.count, Int((turn.end * 16_000).rounded()))
                if turn.speaker == "A" { mic.replaceSubrange(start..<end, with: samples[start..<end]) }
                else { system.replaceSubrange(start..<end, with: samples[start..<end]) }
            }
            return Fixture(mic: mic, system: system,
                micReference: Array(repeating: entry.turns.filter { $0.speaker == "A" }.map(\.text), count: 3).flatMap { $0 },
                systemReference: Array(repeating: entry.turns.filter { $0.speaker == "B" }.map(\.text), count: 3).flatMap { $0 },
                reference: entry.turns.map(\.text), digest: try ModelDownloader.sha256(of: audio),
                manifestDigest: try ModelDownloader.sha256(of: manifestURL))
        }
    }

    private final class SyntheticTap: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable (AudioChunk) -> Void)?
        func install(_ callback: @escaping @Sendable (AudioChunk) -> Void) {
            lock.lock(); self.callback = callback; lock.unlock()
        }
        func feed(_ chunk: AudioChunk) {
            lock.lock(); let callback = callback; lock.unlock()
            callback?(chunk)
        }
    }

    private actor NativeCalls {
        private var calls = 0; private var completed = 0; private var samples = 0
        private var compute = 0.0; private var laneWait = 0.0
        var allSucceeded: Bool { calls > 0 && calls == completed }
        var snapshot: (calls: Int, samples: Int, compute: Double, laneWait: Double) { (calls, samples, compute, laneWait) }
        func enter(_ count: Int) { calls += 1; samples += count }
        func complete(compute: Double, laneWait: Double) {
            completed += 1; self.compute += compute; self.laneWait += laneWait
        }
    }

    private static func pcm(_ samples: [Float], start: Int, count: Int, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { throw Failure.fixture }
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count { channel[index] = samples[(start + index) % samples.count] }
        return buffer
    }

    private nonisolated static func safeToLoad() -> Bool {
        ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork
            && (MeetingDiskCapacity.current(at: FileManager.default.temporaryDirectory).immediateBytes ?? 0) >= 8_000_000_000
    }

    private nonisolated static func speechArtifactDigest() throws -> String {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw Failure.fixture
        }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && $0.lastPathComponent != ".DS_Store"
        }.sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw Failure.fixture }
        var hash = SHA256()
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            hash.update(data: Data((relative + "\u{0}" + (try ModelDownloader.sha256(of: file)) + "\n").utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func numeric(_ key: String, in note: String) -> Int? {
        note.split(separator: " ").first { $0.hasPrefix(key + "=") }
            .flatMap { Int($0.dropFirst(key.count + 1)) }
    }
    private static func recall(_ segments: [TranscriptSegment], against reference: [String]) -> Double {
        func tokens(_ text: String) -> [String] {
            text.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        }
        let expected = tokens(reference.joined(separator: " "))
        var remaining = Dictionary(expected.map { ($0, 1) }, uniquingKeysWith: +)
        var matches = 0
        for word in tokens(segments.map(\.text).joined(separator: " ")) where (remaining[word] ?? 0) > 0 {
            remaining[word, default: 0] -= 1; matches += 1
        }
        return expected.isEmpty ? 0 : Double(matches) / Double(expected.count)
    }
    private static func percentile<T: Comparable>(_ values: [T], _ fraction: Double) -> T? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[Int(Double(sorted.count - 1) * fraction)]
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func number(_ value: Double) -> String { String(format: "%.4f", value) }
    private enum Failure: String, Error { case notFresh, notEligible, resources, inference, fixture, coverage, ownerChanged, unexpectedNotesLoad }
}
