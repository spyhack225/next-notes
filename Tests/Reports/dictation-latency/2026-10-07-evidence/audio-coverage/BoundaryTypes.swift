import Foundation
import AVFoundation
import OSLog

enum Log { static let speech = Logger(subsystem: "DictationPCMFixture", category: "isolated") }
enum StreamingASR {
    static let dictationPartialIntervalSeconds = 1.0
    static let dictationFirstPartialSeconds = 0.4
}
enum AudioConversion {
    static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}
enum ChunkedTranscriber {
    static func frameIsSilent(rms: Float) -> Bool { rms < 0.01 }
}
struct AudioConverter {
    func resampleBuffer(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        precondition(buffer.format.sampleRate == 16_000 && buffer.format.channelCount == 1)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
struct TdtDecoderState { init() throws {} }
struct ASRResult: Sendable { let text: String }
enum FixtureFailure: Error { case injected }
actor ASRBoundary {
    static let shared = ASRBoundary()
    private var calls: [[Float]] = []
    private var failNext = false
    private var held = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    func reset() { precondition(pending.isEmpty); calls = []; failNext = false; held = false }
    func failOne() { failNext = true }
    func hold() { held = true }
    func release() { held = false; let old = pending; pending = []; for c in old { c.resume() } }
    var count: Int { calls.count }
    var waiting: Int { pending.count }
    func snapshot() -> [[Float]] { calls }
    func transcribe(_ audio: [Float]) async throws -> ASRResult {
        calls.append(audio)
        let shouldFail = failNext; failNext = false
        if held { await withCheckedContinuation { pending.append($0) } }
        if shouldFail { throw FixtureFailure.injected }
        let loud = audio.contains(0.04)
        let quietOpening = audio.contains(0.002)
        let quietEnding = audio.contains(0.003)
        return ASRResult(text: [loud ? "Hello." : "", quietOpening ? "I will send the" : "", quietEnding ? "summary tonight." : ""].filter { !$0.isEmpty }.joined(separator: " "))
    }
}
actor AsrManager {
    func transcribe(_ audio: [Float], decoderState: inout TdtDecoderState) async throws -> ASRResult {
        try await ASRBoundary.shared.transcribe(audio)
    }
}
actor ParakeetModels {
    static let shared = ParakeetModels()
    private let primary = AsrManager()
    private let secondary = AsrManager()
    var isLoaded: Bool { true }
    func manager() -> AsrManager { primary }
    func keyUpManager() -> AsrManager { secondary }
}
actor ComputeScheduler {
    static let shared = ComputeScheduler()
    enum Kind { case realtimeASR }
    func acquire(_ kind: Kind) -> UUID { UUID() }
    func release(_ id: UUID) {}
}
actor ModelRuntimeManager {
    static let shared = ModelRuntimeManager()
    enum Kind { case parakeetASR }
    func beginLoading(_ kind: Kind) -> UInt64 { 1 }
    func markReady(_ kind: Kind, generation: UInt64) -> Bool { true }
    func markBusy(_ kind: Kind, generation: UInt64) -> Bool { true }
    func markWedged(_ kind: Kind, generation: UInt64, error: String) -> Bool { true }
}
