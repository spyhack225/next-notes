import AVFoundation
import CryptoKit
import FluidAudio
import Foundation

/// Actual isolated start -> capture -> writer -> Stop -> SAME final task -> save/readback.
/// Scripted mode proves transport only. Native mode grades independently authored words.
@MainActor
enum MeetingQuietSessionSelfTest {
    private struct Manifest: Decodable {
        struct Row: Decodable { var id: String; var file: String; var SHA256: String; var speech: Bool; var samples: Int }
        var cases: [Row]; var gold: String; var goldSHA256: String
    }
    private struct Fixture: Sendable { var id: String; var samples: [Float]; var speech: Bool }
    private struct Call: Codable, Sendable {
        var stage: String; var samples: Int; var SHA256: String; var sourceMatches: Bool
        var native: Bool; var succeeded: Bool?; var elapsed: Double?
        var laneWait: Double?; var compute: Double?; var processingTime: Double?
    }
    private static let manifestSHA = "b61361547cea3f22a11f6f6ddf4796640458f2245f97a6aa18e0ccb1f06b62e1"
    static func run(directory: URL?, native: Bool, write: (String) -> Void) async -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-meeting-quiet-input",
              CommandLine.arguments.contains("--meeting-quiet-session"),
              Settings.shared.usesHarnessPreferencesForTesting, let directory else {
            write("MEETING_QUIET_SESSION_FAILED: explicit isolated inputs/settings required"); return false
        }
        let root = directory.resolvingSymlinksInPath()
        // Match the existing copied-input diagnostic policy. The launcher gives each
        // app a separate TMPDIR, while the pinned retained corpus lives in /private/tmp.
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        let prefix = "NextNotesMeetingQuietInput-"
        guard root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
            write("MEETING_QUIET_SESSION_FAILED: copied UUID root required"); return false
        }
        let experimental = CommandLine.arguments.contains("--meeting-quiet-conservative-admission")
        let fixtures: [Fixture]
        let gold: [String]
        do {
            func read(_ name: String) throws -> Data {
                guard !name.contains("/"), !name.contains("..") else { throw CocoaError(.fileReadNoPermission) }
                let file = root.appendingPathComponent(name)
                guard file.resolvingSymlinksInPath().path == file.path else { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: file)
            }
            let data = try read("session-cases.json")
            guard digest(data) == manifestSHA else { throw CocoaError(.fileReadCorruptFile) }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.cases.count == 6, Set(manifest.cases.map(\.id)).count == 6 else { throw CocoaError(.fileReadCorruptFile) }
            let words = try read(manifest.gold)
            guard digest(words) == manifest.goldSHA256, let text = String(data: words, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            gold = tokens(text)
            guard gold.count == 7 else { throw CocoaError(.fileReadCorruptFile) }
            var loaded: [Fixture] = []
            for row in manifest.cases {
                guard row.samples == 52_566, digest(try read(row.file)) == row.SHA256 else { throw CocoaError(.fileReadCorruptFile) }
                let samples = try AudioConversion.monoSamples(fromFileAt: root.appendingPathComponent(row.file), sampleRate: 16_000)
                guard samples.count == row.samples, samples.allSatisfy({ $0.isFinite }) else { throw CocoaError(.fileReadCorruptFile) }
                loaded.append(Fixture(id: row.id, samples: samples, speech: row.speech))
            }
            if let selected = SelfTest.value(after: "--meeting-quiet-session-only") {
                let ids = selected.split(separator: ",").map(String.init)
                guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy({ id in loaded.contains { $0.id == id } }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                fixtures = loaded.filter { ids.contains($0.id) }
            } else {
                // Native default is one quiet actual-session case; root opts into bounded
                // negative controls explicitly. Scripted default observes all six.
                fixtures = native ? loaded.filter { $0.id == "quiet" } : loaded
            }
        } catch { write("MEETING_QUIET_SESSION_FAILED: pinned inputs unavailable"); return false }
        if native, !ParakeetModels.isDownloaded {
            write("MEETING_QUIET_SESSION_ABSENT: local speech model unavailable"); return false
        }
        let settings = Settings.shared
        let oldKeep = settings.meetingsKeepAudio
        let oldFinal = settings.meetingsFinalPass
        let oldDiarize = settings.meetingsDiarize
        let oldNotes = settings.notesAutoGenerate
        let oldLive = settings.meetingLiveUnderstanding
        let oldWake = settings.voiceWakeEnabled
        let oldAgent = settings.agentEnabled
        let oldPermission = MeetingSession.microphonePermissionOverrideForTesting
        let oldTranscribe = MeetingSession.transcribeOverrideForTesting
        let oldTap = SystemAudioCapture.startCallOverrideForTesting
        let previousContext = MeetingContextStore.shared.current
        defer {
            MeetingSession.microphonePermissionOverrideForTesting = oldPermission
            MeetingSession.transcribeOverrideForTesting = oldTranscribe
            SystemAudioCapture.startCallOverrideForTesting = oldTap
            settings.meetingsKeepAudio = oldKeep
            settings.meetingsFinalPass = oldFinal
            settings.chooseDiarization(oldDiarize)
            settings.notesAutoGenerate = oldNotes
            settings.meetingLiveUnderstanding = oldLive
            settings.voiceWakeEnabled = oldWake
            settings.agentEnabled = oldAgent
            MeetingContextStore.shared.replace(previousContext)
        }
        settings.meetingsKeepAudio = true
        settings.meetingsFinalPass = true
        settings.chooseDiarization(false)
        settings.notesAutoGenerate = false
        settings.meetingLiveUnderstanding = false
        settings.voiceWakeEnabled = false
        settings.agentEnabled = false
        MeetingSession.microphonePermissionOverrideForTesting = { true }
        var failures = 0
        var checks = 0
        var originalQuietMissingStages = 0
        func check(_ id: String, _ label: String, _ value: Bool) {
            checks += 1; if !value { failures += 1 }
            write("MEETING_QUIET_SESSION_CHECK case=\(id) check=\(label) pass=\(value)")
        }
        for fixture in fixtures {
            let store = MeetingStore.isolated()
            let meeting = Meeting(title: "Public quiet session fixture", status: .scheduled)
            let ownedRoot = store.directory(for: meeting.id).deletingLastPathComponent()
            let hub = AudioCaptureHub(probe: true)
            let tap = Tap()
            let recorder = Recorder(domain: fixture.samples)
            let localFinal = FinalTranscriptService(transcribe: { samples in
                try await recordedTranscribe(samples, stage: "final", recorder: recorder,
                                             native: native, speech: fixture.speech).result
            })
            var writer: MeetingAudioWriter?
            let session = MeetingSession(meeting: meeting, store: store, captureHub: hub,
                writerFactory: { url, error in
                    let created = try MeetingAudioWriter(url: url, onWriteError: error)
                    writer = created; return created
                }, diskCapacityForTesting: MeetingDiskCapacity(immediateBytes: 10_000_000_000, importantBytes: 10_000_000_000),
                finalTranscriptServiceForTesting: localFinal)
            MeetingSession.transcribeOverrideForTesting = { samples in
                try await recordedTranscribe(samples, stage: "live", recorder: recorder,
                                             native: native, speech: fixture.speech)
            }
            SystemAudioCapture.startCallOverrideForTesting = { format, buffer, level in
                await tap.configure(format: format, buffer: buffer, level: level)
            }
            do {
                try localFinal.configureQuietSessionFixture(id: meeting.id, store: store)
                try await session.start()
                guard let origin = session.captureHostOriginForTesting, let writer,
                      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
                else { throw CocoaError(.fileWriteUnknown) }
                // Both source clocks use the actual captured origin. No wall-clock delay,
                // zero-padding offset, seeded transcript or borrowed PCM buffer.
                try await tap.emit(samples: fixture.samples, hostTime: origin)
                hub.feedForTesting(try pcm(fixture.samples, format: format), captureHostTime: origin)
                await session.stop()
                // Real Stop assigned the SAME injected service/map handle synchronously.
                // Capture/join it, never create a duplicate explicit final pass or cancel
                // a successful task via the termination path.
                let task = localFinal.finalTerminationTaskForTesting(id: meeting.id)
                check(fixture.id, "actual-stop-assigned-final-handle", task != nil)
                if let task { await task.value }
                check(fixture.id, "same-final-task-joined", !localFinal.isRunning(meeting.id))
                let fresh = store.freshReaderForTesting()
                guard let saved = fresh.meeting(id: meeting.id), let audio = fresh.audioURL(for: saved) else { throw CocoaError(.fileReadNoSuchFile) }
                let live = fresh.liveTranscript(for: meeting.id)
                let final = fresh.transcript(for: meeting.id)
                let progress = writer.resourceSnapshot()
                check(fixture.id, "saved-stop-done", saved.status == .done)
                check(fixture.id, "saved-capture-complete", !saved.hasPartialCapture && saved.captureIntegrity?.interruptedAt == nil)
                check(fixture.id, "saved-frame-domain", progress.writtenFrames == fixture.samples.count)
                for (source, channel) in [(AudioSource.mic, MeetingAudioWriter.micChannel), (.system, MeetingAudioWriter.systemChannel)] {
                    let samples = try AudioConversion.samples(fromFileAt: audio, sampleRate: 16_000, channel: channel)
                    check(fixture.id, "saved-\(source.rawValue)-pcm", sampleDigest(samples) == sampleDigest(fixture.samples))
                    for (stage, rows) in [("live", live), ("final", final)] {
                        let own = rows.filter { $0.source == source }
                        check(fixture.id, "\(stage)-\(source.rawValue)-time-domain", own.allSatisfy {
                            $0.start >= 0 && $0.end >= $0.start && $0.end <= Double(fixture.samples.count) / 16_000 + 0.001
                        })
                        let rawWords = own.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
                        write("MEETING_QUIET_SESSION_WORDS case=\(fixture.id) stage=\(stage) source=\(source.rawValue) native=\(native) text=\(json(rawWords)) wordCount=\(tokens(rawWords).count)")
                        let originalQuiet = fixture.id == "quiet" && !experimental
                        if originalQuiet {
                            // Observe the original producer loss; diagnostic OK is not
                            // a product word-quality PASS. Same complete independent
                            // clause is required from the explicit experiment below.
                            check(fixture.id, "original-\(stage)-\(source.rawValue)-quiet-omitted", own.isEmpty)
                            if own.isEmpty { originalQuietMissingStages += 1 }
                        } else if native {
                            check(fixture.id, "native-\(stage)-\(source.rawValue)-independent-words", fixture.speech ? tokens(rawWords) == gold : tokens(rawWords).isEmpty)
                        } else {
                            // Explicit substitution proves consumer forwarding, never the
                            // independently referenced seven words or noise accuracy.
                            check(fixture.id, "scripted-\(stage)-\(source.rawValue)-transport", fixture.speech ? !own.isEmpty : own.isEmpty)
                        }
                    }
                }
                let calls = await recorder.calls()
                check(fixture.id, "bounded-existing-calls", calls.count <= 6)
                check(fixture.id, "exact-native-input-domain", calls.allSatisfy(\.sourceMatches))
                check(fixture.id, "all-admitted-calls-completed", calls.allSatisfy { $0.succeeded == true })
                check(fixture.id, "all-admitted-call-costs-recorded", calls.allSatisfy {
                    guard let elapsed = $0.elapsed, let laneWait = $0.laneWait, let compute = $0.compute else { return false }
                    return elapsed.isFinite && elapsed >= 0 && laneWait.isFinite && laneWait >= 0
                        && compute.isFinite && compute >= 0
                })
                if experimental, fixture.id != "digital-zero" {
                    check(fixture.id, "experiment-live-and-final-admitted", calls.contains { $0.stage == "live" }
                          && calls.contains { $0.stage == "final" })
                }
                if fixture.id == "quiet", !experimental {
                    check(fixture.id, "original-quiet-pre-recognition-refusal", calls.isEmpty)
                }
                if fixture.id == "digital-zero" { check(fixture.id, "digital-zero-skip", calls.isEmpty) }
                write("MEETING_QUIET_SESSION_CALLS case=\(fixture.id) native=\(native) experimental=\(experimental) calls=\(json(calls)) savedAudioSHA256=\(digest(try Data(contentsOf: audio)))")
                check(fixture.id, "fresh-reader-transcript-parity", fresh.transcript(for: meeting.id) == store.transcript(for: meeting.id))
            } catch {
                failures += 1
                write("MEETING_QUIET_SESSION_WRONG case=\(fixture.id) actual_session_boundary_unavailable")
                // Every capture/Stop/final handle is joined before exact owned cleanup.
                if session.isRecording { await session.stop() }
                if let task = localFinal.finalTerminationTaskForTesting(id: meeting.id) { await task.value }
            }
            session.endAbruptly()
            check(fixture.id, "owned-tasks-finished", !session.isRecording && !localFinal.isRunning(meeting.id))
            check(fixture.id, "joined-reference-released", localFinal.releaseQuietSessionFixture(id: meeting.id))
            await tap.release()
            // Root input corpus is retained. Only this joined fixture store is removed.
            if ownedRoot.lastPathComponent.hasPrefix("NextNotesMeetingResumeTest-") {
                try? FileManager.default.removeItem(at: ownedRoot)
            }
        }
        write("MEETING_QUIET_SESSION_SCOPE native=\(native) substitutedASR=\(!native) experimental=\(experimental) selectedCases=\(json(fixtures.map(\.id))) originalQuietMissingStages=\(originalQuietMissingStages) originalQuietAllFourStagesMissing=\(originalQuietMissingStages == 4) independentClauseWords=7 productQualityPass=false productNoiseWorkloadAcceptance=false permissionAuthority=false")
        write("MEETING_QUIET_SESSION_\(failures == 0 ? "OK" : "FAILED"): \(failures)/\(checks) checks failed")
        return failures == 0
    }
    /// Diagnostic observation wraps the same existing call; errors remain errors.
    /// Empty noise is evidence only when every admitted recognition completed.
    private nonisolated static func recordedTranscribe(
        _ samples: [Float], stage: String, recorder: Recorder, native: Bool, speech: Bool
    ) async throws -> (result: ASRResult, laneWait: TimeInterval, compute: TimeInterval) {
        let call = await recorder.note(stage: stage, samples: samples, native: native)
        let began = ContinuousClock.now
        do {
            let output: (result: ASRResult, laneWait: TimeInterval, compute: TimeInterval)
            if native {
                output = try await TranscriptionQueue.shared.transcribeWithLaneWait(
                    samples, lane: stage == "final" ? .background : .realtimeASR)
            } else {
                output = (scripted(samples, speech: speech), 0, 0)
            }
            await recorder.completed(call, elapsed: ChunkedTranscriber.seconds(began.duration(to: .now)),
                                     laneWait: output.laneWait, compute: output.compute,
                                     processingTime: output.result.processingTime)
            return output
        } catch {
            await recorder.failed(call, elapsed: ChunkedTranscriber.seconds(began.duration(to: .now)))
            throw error
        }
    }
    private nonisolated static func scripted(_ samples: [Float], speech: Bool) -> ASRResult {
        ASRResult(text: speech ? "Transport fixture." : "", confidence: 1, duration: Double(samples.count) / 16_000, processingTime: 0, tokenTimings: nil)
    }
    private nonisolated static func tokens(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }
    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func sampleDigest(_ samples: [Float]) -> String { samples.withUnsafeBytes { digest(Data($0)) } }
    private nonisolated static func json<T: Encodable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "null"
    }
    private nonisolated static func pcm(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let channel = buffer.floatChannelData?[0] else {
            throw MeetingAudioWriterError.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.initialize(from: base, count: samples.count) }
        }
        return buffer
    }
    private actor Tap {
        private var format: AVAudioFormat?
        private var buffer: (@Sendable (AudioChunk) -> Void)?
        private var level: (@Sendable (Float) -> Void)?
        func configure(format: AVAudioFormat, buffer: @escaping @Sendable (AudioChunk) -> Void, level: @escaping @Sendable (Float) -> Void) {
            self.format = format; self.buffer = buffer; self.level = level
        }
        func emit(samples: [Float], hostTime: UInt64) throws {
            guard let format, let buffer else { throw CocoaError(.fileReadUnknown) }
            buffer(AudioChunk(buffer: try pcm(samples, format: format), captureHostTime: hostTime)); level?(0)
        }
        func release() { format = nil; buffer = nil; level = nil }
    }
    private actor Recorder {
        private var rows: [Call] = []
        private let domain: [Float]
        private let possible: [Int: Set<String>]
        init(domain: [Float]) {
            self.domain = domain
            let cuts = Set(ChunkedTranscriber.cutPoints(in: domain, config: .default)
                + ChunkedTranscriber.cutPoints(in: domain, config: .finals) + [0, domain.count]).sorted()
            var matches: [Int: Set<String>] = [:]
            for start in cuts {
                for end in cuts where end > start {
                    let raw = Array(domain[start..<end]); let padded = ParakeetInput.padded(raw)
                    matches[raw.count, default: []].insert(sampleDigest(raw))
                    matches[padded.count, default: []].insert(sampleDigest(padded))
                }
            }
            possible = matches
        }
        func note(stage: String, samples: [Float], native: Bool) -> Int {
            let hash = sampleDigest(samples)
            let index = rows.count
            rows.append(Call(stage: stage, samples: samples.count, SHA256: hash,
                             sourceMatches: possible[samples.count]?.contains(hash) == true, native: native))
            return index
        }
        func completed(_ index: Int, elapsed: Double, laneWait: Double, compute: Double, processingTime: Double) {
            rows[index].succeeded = true; rows[index].elapsed = elapsed
            rows[index].laneWait = laneWait; rows[index].compute = compute
            rows[index].processingTime = processingTime
        }
        func failed(_ index: Int, elapsed: Double) {
            rows[index].succeeded = false; rows[index].elapsed = elapsed
        }
        func calls() -> [Call] { rows }
    }
}
