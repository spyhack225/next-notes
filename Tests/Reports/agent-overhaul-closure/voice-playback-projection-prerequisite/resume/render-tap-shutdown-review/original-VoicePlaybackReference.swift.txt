import AVFoundation

/// Observe actual output-mixer PCM rather than a synthesized or merely queued
/// voice buffer. Each backing owns its output engine and installs this tap once.
/// The tap copies borrowed Core Audio storage and dispatches conversion and
/// Speex input to a serial utility lane, never executing DSP on the render IO.
enum VoicePlaybackReference {
    static func install(on engine: AVAudioEngine) {
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 480, format: mixer.outputFormat(forBus: 0)) {
            buffer, time in
            guard let copy = AudioConversion.copy(buffer) else { return }
            let owned = OwnedReference(buffer: copy)
            let hostTime = time.isHostTimeValid ? time.hostTime : nil
            let tapArrivalHostTime = mach_absolute_time()
            let presentationLatency = engine.outputNode.outputPresentationLatency
            let generation = currentEpoch()
            lane.async {
                guard generation == currentEpoch() else { return }
                AcousticEchoProcessor.shared.feedRendered(owned.buffer,
                    renderHostTime: hostTime, tapArrivalHostTime: tapArrivalHostTime,
                    outputPresentationLatency: presentationLatency)
            }
        }
    }

    static func stopped() {
        epochLock.lock()
        epoch &+= 1
        epochLock.unlock()
        // Serialize the clear behind any callback that passed its epoch check
        // immediately before the interruption; stale queued callbacks skip.
        lane.sync { AcousticEchoProcessor.shared.stopPlayback() }
    }

    private static let epochLock = NSLock()
    private nonisolated(unsafe) static var epoch: UInt64 = 0

    private static func currentEpoch() -> UInt64 {
        epochLock.lock()
        defer { epochLock.unlock() }
        return epoch
    }

    private static let lane = DispatchQueue(
        label: "ai.pivotstudio.nextnotes.echo-reference", qos: .userInitiated
    )

    /// The tap has made a deep copy before crossing the dispatch boundary.
    private struct OwnedReference: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }
}
