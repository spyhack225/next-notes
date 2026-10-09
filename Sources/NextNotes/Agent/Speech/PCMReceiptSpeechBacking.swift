import Foundation

/// Deterministic diagnostic only. Never opens an audio graph or synthesizes a voice.
/// Enqueue, played notices and completion are independently advanced by the fixture.
@MainActor
final class PCMReceiptSpeechBacking: AgentReceiptSpeechBacking {
    enum Event: Equatable {
        case enqueued(UInt64), played(PCMPlaybackNativeObservation), completed(UInt64)
        case paused(UInt64, UInt64), resumed(UInt64, UInt64), interrupted(UInt64)
    }
    struct Submission { let text: String; let token: UInt64 }
    var onUtteranceStarted: ((UInt64) -> Void)?
    var onUtteranceFinished: ((UInt64) -> Void)?
    var onFailure: ((String, Float, UInt64) -> Void)?
    var onResumePlaybackAcknowledged: ((PCMResumePlaybackReceipt) -> Void)?
    private(set) var submissions: [Submission] = []
    private(set) var events: [Event] = []
    private(set) var outputGain: Float = 1
    private var active: [UInt64] = []
    private var started: Set<UInt64> = []
    private var paused = false
    private var phase: UInt64 = 2
    private var host: UInt64 = 100
    private var resumeHost: UInt64?
    private var deliveredResume = false
    // Explicit fixed PCM samples supply a frame domain; they never reach a speaker.
    let pcm: [Float] = (0..<1920).map { $0.isMultiple(of: 2) ? 0.02 : -0.02 }
    var isSpeaking: Bool { !active.isEmpty }
    var currentResumePhase: UInt64? { resumeHost == nil ? nil : phase }
    func setOutputGain(_ gain: Float) { outputGain = max(0, min(1, gain)) }
    func beginReply(volume: Float) { phase = 2; resumeHost = nil; deliveredResume = false }
    func finishReply() {}
    func speak(_ text: String, volume: Float, token: UInt64) {
        beginReply(volume: volume); enqueue(text, token: token); finishReply()
    }
    func enqueue(_ text: String, token: UInt64) {
        guard SelfTest.isRunning else { return }
        submissions.append(.init(text: text, token: token)); active.append(token)
        events.append(.enqueued(token))
    }
    func pauseForListening() {
        guard let token = active.first, !paused else { return }
        paused = true; phase &+= 1
        events.append(.paused(token, phase))
    }
    func resumeAfterListening() {
        guard let token = active.first, paused else { return }
        paused = false; phase &+= 1; host &+= 10
        resumeHost = host; deliveredResume = false
        events.append(.resumed(token, phase))
    }
    func stop() {
        for token in active { events.append(.interrupted(token)) }
        active.removeAll(); paused = false; phase = 0; resumeHost = nil
    }
    func packet(token: UInt64, ordinal: Int = 0) -> PCMPlaybackNativeObservation {
        host &+= 10
        return .init(buffer: buffer(token: token, ordinal: ordinal), originPhase: phase,
                     callbackKind: 2, originHostTime: host, originWasMainThread: true)
    }
    private func buffer(token: UInt64, ordinal: Int) -> PCMPlaybackBufferObservation {
        .init(token: token, ordinal: ordinal, lowerFrame: Int64(ordinal * pcm.count),
              upperFrame: Int64((ordinal + 1) * pcm.count), sampleRate: 24_000)
    }
    func deliverPlayed(_ packet: PCMPlaybackNativeObservation) {
        events.append(.played(packet))
        guard active.first == packet.buffer.token, !paused,
              packet.originPhase == phase,
              resumeHost.map({ packet.originHostTime > $0 }) ?? true else { return }
        if started.insert(packet.buffer.token).inserted { onUtteranceStarted?(packet.buffer.token) }
    }
    /// Qualified simulated metadata, deliberately separate from a played notice.
    /// The production synth and audio consumer still check exact token/phase ownership.
    func resumeReceipt(token: UInt64) -> PCMResumePlaybackReceipt {
        host &+= 10
        let earlier = PCMPlaybackCursorObservation(frame: 1920, sampleRate: 24_000,
                                                   nodeHostTime: host, observedHostTime: host)
        host &+= 10
        let later = PCMPlaybackCursorObservation(frame: 2880, sampleRate: 24_000,
                                                 nodeHostTime: host, observedHostTime: host)
        return .init(packet: packet(token: token, ordinal: 2), earlier: earlier, later: later,
                     checkpoint: 3840, checkpointBuffer: buffer(token: token, ordinal: 1))
    }
    func deliverResume(_ receipt: PCMResumePlaybackReceipt) {
        let packet = receipt.packet
        guard active.first == packet.buffer.token, !paused, !deliveredResume,
              let resumeHost, packet.originPhase == phase,
              receipt.earlier.nodeHostTime >= resumeHost,
              receipt.later.frame > receipt.earlier.frame,
              receipt.later.nodeHostTime > receipt.earlier.nodeHostTime,
              packet.originHostTime > receipt.later.observedHostTime,
              packet.buffer.upperFrame > receipt.checkpoint else { return }
        deliveredResume = true
        onResumePlaybackAcknowledged?(receipt)
    }
    func complete(_ token: UInt64) {
        guard active.first == token, !paused else { return }
        active.removeFirst(); events.append(.completed(token)); onUtteranceFinished?(token)
    }
    func fail(_ token: UInt64) { onFailure?("", 1, token) }
}
