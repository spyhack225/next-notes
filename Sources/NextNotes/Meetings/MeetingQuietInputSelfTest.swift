import CryptoKit
import FluidAudio
import Foundation

/// Diagnostic-only forwarding hypothesis: approved quiet cases may report RED before
/// native words are established. Constant DC is observation-only, never required speech.
/// Scripted ASR proves forwarding/emission/readback only, not a product-quality regression.
@MainActor
enum MeetingQuietInputSelfTest {
    private struct Case: Sendable {
        var id: String
        var samples: [Float]
        var quietStart: Int
        var tailExpectation: Bool?
        var expectationScope: String
    }
    private struct Bounds: Sendable, Codable {
        var startSample: Int
        var endSample: Int
    }
    private struct Call: Sendable, Codable {
        var samples: Int
        var float32SHA256: String
        var matched: Bounds?
    }
    private struct Classification: Codable {
        var startSample: Int
        var endSample: Int
        var containsSpeech: Bool
        var remainderSamples: Int
        var quietTailIntersectionSamples: Int
    }
    static func run(directory: URL?, native: Bool, write: (String) -> Void) async -> Bool {
        guard SelfTest.isRunning, Settings.shared.usesHarnessPreferencesForTesting else {
            write("MEETING_QUIET_INPUT_FAILED: isolated settings required"); return false
        }
        if CommandLine.arguments.contains("--meeting-quiet-session") {
            return await MeetingQuietSessionSelfTest.run(directory: directory, native: native, write: write)
        }
        var cases = [
            Case(id: "digital-zero", samples: [Float](repeating: 0, count: 44_886), quietStart: 0, tailExpectation: false, expectationScope: "existing-digital-zero-control"),
            Case(id: "dc-below-floor-observation", samples: [Float](repeating: 0.005, count: 44_886), quietStart: 0, tailExpectation: nil, expectationScope: "dc-not-demonstrated-speech-proposed-conservative-admission-observation"),
            Case(id: "above-floor", samples: [Float](repeating: 0.1, count: 44_886), quietStart: 0, tailExpectation: true, expectationScope: "existing-above-floor-forwarding-control"),
            Case(id: "loud-with-quiet-suffix", samples: [Float](repeating: 0.1, count: 16_000)
                 + [Float](repeating: 0.005, count: 16_000), quietStart: 16_000, tailExpectation: true, expectationScope: "existing-mixed-amplitude-forwarding-control")
        ]
        do {
            if let directory {
                let resolved = directory.resolvingSymlinksInPath()
                let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
                let prefix = "NextNotesMeetingQuietInput-"
                guard resolved.deletingLastPathComponent().path == temporary.path,
                      resolved.lastPathComponent.hasPrefix(prefix),
                      UUID(uuidString: String(resolved.lastPathComponent.dropFirst(prefix.count))) != nil
                else { throw CocoaError(.fileReadNoPermission) }
                for (id, name, sha, quietStart, count) in [
                    ("approved-full", "quiet-final-clause.wav", "76c16c4ffd310a9e9b1b87841a8211a7ae738e92868b02b8141c578a1f726dc4", 924_480, 969_366),
                    ("approved-alone", "quiet-final-clause-alone.wav", "6b33012b8141c80f3244d32e238b0dfb5dcd6c79434791fbf0302f18c2b80378", 0, 44_886)
                ] {
                    let file = resolved.appendingPathComponent(name)
                    guard file.resolvingSymlinksInPath().path == file.path,
                          digest(try Data(contentsOf: file)) == sha else { throw CocoaError(.fileReadCorruptFile) }
                    let samples = try AudioConversion.monoSamples(fromFileAt: file, sampleRate: ChunkedTranscriber.sampleRate)
                    guard samples.count == count else { throw CocoaError(.fileReadCorruptFile) }
                    cases.append(Case(id: id, samples: samples, quietStart: quietStart, tailExpectation: true, expectationScope: "forwarding-hypothesis-native-words-unverified"))
                }
            }
        } catch { write("MEETING_QUIET_INPUT_FAILED: explicit copied pinned fixture unavailable"); return false }
        var failures = 0
        var checks = 0
        func check(_ id: String, _ label: String, _ pass: Bool) {
            checks += 1
            if !pass { failures += 1 }
            write("MEETING_QUIET_CHECK case=\(id) check=\(label) pass=\(pass)")
        }
        for fixture in cases {
            for tier in ["live", "final"] {
                let config: ChunkedTranscriber.WindowConfig = tier == "live" ? .default : .finals
                let cuts = ChunkedTranscriber.cutPoints(in: fixture.samples, config: config)
                var start = 0
                var classifications: [Classification] = []
                for end in cuts {
                    classifications.append(Classification(startSample: start, endSample: end,
                        containsSpeech: ChunkedTranscriber.containsSpeech(Array(fixture.samples[start..<end])),
                        remainderSamples: (end - start) % 320,
                        quietTailIntersectionSamples: max(0, end - max(start, fixture.quietStart))))
                    start = end
                }
                write("MEETING_QUIET_CLASSIFICATION case=\(fixture.id) tier=\(tier) inputSHA256=\(sampleDigest(fixture.samples)) windows=\(json(classifications))")
                let recorder = Recorder(domain: fixture.samples, cuts: cuts, padded: tier == "final")
                let collector = Collector()
                let segments: [TranscriptSegment]
                if tier == "live" {
                    let transcriber = ChunkedTranscriber(source: .system, meetingID: UUID(), transcribe: { samples in
                        await recorder.note(samples)
                        return (result: synthetic(samples), laneWait: 0, compute: 0)
                    }, onSegment: { await collector.add($0) })
                    // Actual append/queue/merge/flush. No sleeps or forced per-window flush;
                    // actual captured hashes disclose whichever adjacent batches merged.
                    var index = 0
                    while index < fixture.samples.count {
                        let end = min(index + 16_000, fixture.samples.count)
                        await transcriber.append(Array(fixture.samples[index..<end]))
                        index = end
                        await Task.yield()
                    }
                    await transcriber.flush()
                    segments = await collector.all()
                    check(fixture.id + ".live", "no-backlog-drop", await transcriber.droppedAudioSeconds == 0)
                } else {
                    do {
                        segments = try await MeetingFinalPass.transcribeTrack(fixture.samples, source: .system) { samples in
                            await recorder.note(samples)
                            return synthetic(samples)
                        }.segments
                    } catch { write("MEETING_QUIET_INPUT_FAILED: final seam threw"); return false }
                }
                let calls = await recorder.calls()
                write("MEETING_QUIET_CALLS case=\(fixture.id) tier=\(tier) calls=\(json(calls)) segments=\(segments.count)")
                check(fixture.id + "." + tier, "exact-input-domain", calls.allSatisfy { $0.matched != nil })
                let tailReached = calls.contains { $0.matched?.endSample == fixture.samples.count }
                let consumerTail = segments.contains {
                    $0.source == .system && $0.text == "Quiet forwarding marker."
                        && abs($0.end - Double(fixture.samples.count) / 16_000) < 0.000001
                }
                write("MEETING_QUIET_OBSERVATION case=\(fixture.id) tier=\(tier) scope=\(fixture.expectationScope) tailReached=\(tailReached) consumerTail=\(consumerTail) demonstratedSpeech=false")
                if let expected = fixture.tailExpectation {
                    let proposed = fixture.expectationScope == "forwarding-hypothesis-native-words-unverified"
                    check(fixture.id + "." + tier, proposed ? "proposed-tail-forwarding" : "control-tail-forwarding", tailReached == expected)
                    check(fixture.id + "." + tier, proposed ? "proposed-consumer-tail" : "control-consumer-tail", consumerTail == expected)
                }
                do {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesMeetingQuietReadback-\(UUID().uuidString).json")
                    defer { try? FileManager.default.removeItem(at: file) }
                    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(segments).write(to: file, options: .atomic)
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let saved = try decoder.decode([TranscriptSegment].self, from: Data(contentsOf: file))
                    check(fixture.id + "." + tier, "emitted-json-readback", saved == segments)
                } catch { write("MEETING_QUIET_INPUT_FAILED: isolated consumer readback unavailable"); return false }
            }
        }
        if native {
            guard let quiet = cases.first(where: { $0.id == "approved-alone" }), ParakeetModels.isDownloaded else {
                write("MEETING_QUIET_NATIVE_ABSENT: copied approved quiet crop and local ASR required"); return false
            }
            // Single cropped direct recognition control plus SAME actual final producer.
            // Raw text remains in the private writer. Nonempty text is not a word-accuracy verdict.
            do {
                let began = ContinuousClock.now
                let direct = try await TranscriptionQueue.shared.transcribe(quiet.samples, lane: .background)
                write("MEETING_QUIET_NATIVE_DIRECT text=\(json(direct.text)) elapsed=\(ChunkedTranscriber.seconds(began.duration(to: .now)))")
                let recorder = Recorder(domain: quiet.samples, cuts: [quiet.samples.count], padded: true)
                let final = try await MeetingFinalPass.transcribeTrack(quiet.samples, source: .system) { samples in
                    await recorder.note(samples)
                    return try await TranscriptionQueue.shared.transcribe(samples, lane: .background)
                }
                write("MEETING_QUIET_NATIVE_FINAL calls=\(json(await recorder.calls())) text=\(json(final.segments.map(\.text)))")
                write("MEETING_QUIET_NATIVE_SCOPE crop_has_no_independent_word_alignment semanticAccuracy=false noiseWorkloadAcceptance=false")
            } catch { write("MEETING_QUIET_NATIVE_FAILED: recognition control failed"); return false }
        }
        write("MEETING_QUIET_INPUT_SCOPE scriptedForwarding=true nativeQualityPass=false provenProductRegression=false dcAdmissionRequirement=false ownerCapture=false nativeRun=\(native)")
        write("MEETING_QUIET_INPUT_\(failures == 0 ? "OK" : "FAILED"): \(failures)/\(checks) checks failed")
        return failures == 0
    }
    private nonisolated static func synthetic(_ samples: [Float]) -> ASRResult {
        ASRResult(text: "Quiet forwarding marker.", confidence: 1, duration: Double(samples.count) / 16_000,
                  processingTime: 0, tokenTimings: nil)
    }
    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func sampleDigest(_ samples: [Float]) -> String {
        samples.withUnsafeBytes { digest(Data($0)) }
    }
    private nonisolated static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
    private actor Collector {
        private var rows: [TranscriptSegment] = []
        func add(_ value: TranscriptSegment) { rows.append(value) }
        func all() -> [TranscriptSegment] { rows }
    }
    private actor Recorder {
        private var rows: [Call] = []
        private let domain: [Float]
        private let cuts: [Int]
        private let padded: Bool
        init(domain: [Float], cuts: [Int], padded: Bool) { self.domain = domain; self.cuts = cuts; self.padded = padded }
        func note(_ samples: [Float]) {
            let hash = sampleDigest(samples)
            var matched: Bounds?
            // Matching is diagnostic-only and bounded to the <=60.6s approved corpus.
            let starts = [0] + Array(cuts.dropLast())
            outer: for start in starts {
                for end in cuts where end > start && end - start <= Int(ChunkedTranscriber.maxMergedWindowSeconds * 16_000) {
                    let raw = Array(domain[start..<end])
                    let expected = padded ? ParakeetInput.padded(raw) : raw
                    guard expected.count == samples.count else { continue }
                    if sampleDigest(expected) == hash { matched = Bounds(startSample: start, endSample: end); break outer }
                }
            }
            rows.append(Call(samples: samples.count, float32SHA256: hash, matched: matched))
        }
        func calls() -> [Call] { rows }
    }
}
