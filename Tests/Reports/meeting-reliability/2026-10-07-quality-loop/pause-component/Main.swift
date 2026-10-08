import CryptoKit
import Foundation

private struct Manifest: Decodable {
    struct Row: Decodable, Sendable { let id: String; let file: String; let SHA256: String; let speech: Bool; let samples: Int }
    let cases: [Row]
}
private actor TransportRecorder {
    var calls: [[Float]] = []
    var segments: [TranscriptSegment] = []
    func note(_ samples: [Float]) { calls.append(samples) }
    func segment(_ value: TranscriptSegment) { segments.append(value) }
    func snapshot() -> ([[Float]], [TranscriptSegment]) { (calls, segments) }
}
@main
private enum ComponentMain {
    @MainActor static func main() async {
        let boundariesOK = await MeetingPauseBoundarySelfTest.run(write: { print($0) })
        let corpusOK: Bool
        do { corpusOK = try await corpus() }
        catch { print("PAUSE_COMPONENT_CORPUS_FAILED: \(error)"); corpusOK = false }
        print(boundariesOK && corpusOK ? "PAUSE_COMPONENT_OK" : "PAUSE_COMPONENT_FAILED")
        exit(boundariesOK && corpusOK ? 0 : 1)
    }

    @MainActor private static func corpus() async throws -> Bool {
        // Match the actual Session fixture policy: Foundation can normalize the
        // /private/tmp alias to /tmp, so compare resolved roots/parents consistently.
        let expectedRootName = "NextNotesMeetingQuietInput-0E30FA0E-4BA7-4DBD-A732-602B5E35949E"
        let root = URL(fileURLWithPath: "/private/tmp/" + expectedRootName, isDirectory: true)
            .resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        let prefix = "NextNotesMeetingQuietInput-"
        guard root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent == expectedRootName,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil
        else { throw CocoaError(.fileReadNoPermission) }
        let manifestData = try Data(contentsOf: root.appendingPathComponent("session-cases.json"))
        guard digest(manifestData) == "b61361547cea3f22a11f6f6ddf4796640458f2245f97a6aa18e0ccb1f06b62e1" else { throw CocoaError(.fileReadCorruptFile) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.cases.map(\.id) == ["quiet", "loud", "mixed", "digital-zero", "dc", "noise"] else { throw CocoaError(.fileReadCorruptFile) }
        let candidate = CommandLine.arguments.contains("--meeting-quiet-pause-experiment")
        let admission = CommandLine.arguments.contains("--meeting-quiet-conservative-admission")
        var failures = 0
        func check(_ id: String, _ name: String, _ pass: Bool) {
            if !pass { failures += 1 }
            print("PAUSE_COMPONENT_CHECK case=\(id) check=\(name) pass=\(pass)")
        }
        for row in manifest.cases {
            guard row.file == "session-\(row.id).wav" else { throw CocoaError(.fileReadCorruptFile) }
            let file = root.appendingPathComponent(row.file)
            guard file.resolvingSymlinksInPath().path == file.path else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf: file)
            guard digest(data) == row.SHA256 else { throw CocoaError(.fileReadCorruptFile) }
            let samples = try decodePCM16(data)
            guard samples.count == row.samples, row.samples == 52_566 else { throw CocoaError(.fileReadCorruptFile) }
            let expectedEnds = row.id == "digital-zero" ? [32_000] : []
            let expectedStatic = expectedEnds + [52_566]
            check(row.id, "candidate-static-boundary", ChunkedTranscriber.cutPoints(in: samples, config: .default) == expectedStatic)
            let expectedAdmission = admission ? row.id != "digital-zero" : ["loud", "mixed"].contains(row.id)
            check(row.id, "inherited-or-explicit-admission", ChunkedTranscriber.containsSpeech(samples) == expectedAdmission)
            print("PAUSE_COMPONENT_CLASSIFICATION case=\(row.id) admission=\(ChunkedTranscriber.containsSpeech(samples)) scope=signal-forwarding-not-speech-proof")
            for step in [52_566, 16_000, 319] {
                let recorder = TransportRecorder()
                let transcriber = ChunkedTranscriber(source: .system,
                    transcribe: { input in
                        await recorder.note(input)
                        return (result: ASRResult(text: row.speech ? "Transport fixture." : "", confidence: 1,
                            duration: Double(input.count) / 16_000, processingTime: 0, tokenTimings: nil), laneWait: 0, compute: 0)
                    }, onSegment: { await recorder.segment($0) })
                let chunks = stride(from: 0, to: samples.count, by: step).map {
                    Array(samples[$0..<min($0 + step, samples.count)])
                }
                let ends = await transcriber.appendAndObserveCutsForTesting(chunks)
                check(row.id, "actual-queued-boundary-step-\(step)", ends == expectedEnds)
                await transcriber.flush() // SAME queued windows, actual merge/drain/consumer path.
                let (calls, segments) = await recorder.snapshot()
                let flattened = calls.flatMap { $0 }
                check(row.id, "actual-forwarded-sample-order-step-\(step)", expectedAdmission ? flattened == samples : calls.isEmpty)
                check(row.id, "source-domain-segment-bounds-step-\(step)", segments.allSatisfy {
                    $0.source == .system && $0.start >= 0 && $0.end <= Double(samples.count) / 16_000 + 0.000000001
                        && $0.end >= $0.start && $0.text == "Transport fixture."
                })
                check(row.id, "no-native-word-claim-step-\(step)", !row.speech ? segments.isEmpty : true)
                check(row.id, "no-backlog-drop-step-\(step)", await transcriber.droppedAudioSeconds == 0)
                print("PAUSE_COMPONENT_TRANSPORT case=\(row.id) step=\(step) queuedEnds=\(ends ?? []) calls=\(calls.map(\.count)) consumerSegments=\(segments.count) native=false")
                await transcriber.cancel()
                await transcriber.flush()
            }
        }
        print("PAUSE_COMPONENT_CORPUS mode=\(candidate ? "digital-zero-experiment" : "legacy") conservativeAdmission=\(admission) failures=\(failures) nativeWordsVerified=false pcmAdapter=RIFF-int16-div32768")
        return failures == 0
    }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func decodePCM16(_ data: Data) throws -> [Float] {
        func u16(_ p: Int) -> UInt16 { UInt16(data[p]) | (UInt16(data[p + 1]) << 8) }
        func u32(_ p: Int) -> Int { Int(u16(p)) | (Int(u16(p + 2)) << 16) }
        guard data.count >= 12, String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else { throw CocoaError(.fileReadCorruptFile) }
        var offset = 12
        var correctFormat = false
        var pcm: Range<Int>?
        while offset + 8 <= data.count {
            let id = String(data: data[offset..<offset + 4], encoding: .ascii)
            let size = u32(offset + 4)
            let start = offset + 8
            guard size >= 0, start + size <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            if id == "fmt " {
                guard size >= 16 else { throw CocoaError(.fileReadCorruptFile) }
                correctFormat = u16(start) == 1 && u16(start + 2) == 1 && u32(start + 4) == 16_000
                    && u16(start + 12) == 2 && u16(start + 14) == 16
            } else if id == "data" {
                guard pcm == nil, size % 2 == 0 else { throw CocoaError(.fileReadCorruptFile) }
                pcm = start..<start + size
            }
            offset = start + size + size % 2
        }
        guard correctFormat, let pcm else { throw CocoaError(.fileReadCorruptFile) }
        return stride(from: pcm.lowerBound, to: pcm.upperBound, by: 2).map {
            Float(Int16(bitPattern: u16($0))) / 32_768
        }
    }
}
