import AVFoundation
import Foundation
import Synchronization

/// Retained existing player/echo-reference graph, with text synthesis removed.
/// Needed by the parallel acknowledgement work; it only accepts prepared PCM.
@MainActor
final class PreparedPCMSpeechBacking: NSObject, AgentReceiptSpeechBacking {
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var pendingBuffers = 0
    private var synthesisFinished = false
    private var didBegin = false
    private var volumeForReply: Float = 1
    private var speaking = false
    private var pausedForListening = false
    private var activeToken: UInt64?
    /// One atomic stamp crosses the real callback thread; no PCM queue is added.
    private final class TimelinePhase: @unchecked Sendable {
        let value = Atomic<UInt64>(0)
    }
    private let timelinePhase = TimelinePhase()
    private var timelineEnd: Int64 = 0
    private var timelineOrdinal = 0
    private var timelineRate: Double?
    private var timelineResumeHost: UInt64?
    private var timelineCheckpoint: Int64?
    private var resumeEarlierCursor: PCMPlaybackCursorObservation?
    private var resumeLaterCursor: PCMPlaybackCursorObservation?
    private var resumeStrongCut: Int64?
    private var resumeCheckpointBuffer: PCMPlaybackBufferObservation?
    private var resumeReceiptDelivered = false
    var onResumePlaybackAcknowledged: ((PCMResumePlaybackReceipt) -> Void)?
    var resumeProofObserverForTesting: (@MainActor (PCMResumePlaybackReceipt) -> Void)?
    var rawCompletionDeferralForTesting:
        (@Sendable (RawPCMPlayedNotice, @escaping @Sendable () -> Void) -> Void)?
    private var timelineEnabled: Bool {
        onResumePlaybackAcknowledged != nil || (SelfTest.isRunning && timelineObserverForTesting != nil)
    }
    var currentResumePhase: UInt64? {
        let phase = timelinePhase.value.load(ordering: .acquiring)
        return speaking && !pausedForListening && phase != 0 && phase % 2 == 0
            && timelineResumeHost != nil ? phase : nil
    }
    private func clearResumeProof() {
        resumeEarlierCursor = nil; resumeLaterCursor = nil; resumeStrongCut = nil
        resumeCheckpointBuffer = nil; resumeReceiptDelivered = false
    }
    var timelineObserverForTesting: (@MainActor (PCMPlaybackTimelineObservation) -> Void)?
    var nativeCompletionInterceptorForTesting:
        (@Sendable (PCMPlaybackNativeObservation, @escaping @Sendable () -> Void) -> Void)?
    /// Wired by `AgentSpeechSynthesizer` to pump the next clause (or finish).
    var onUtteranceFinished: ((UInt64) -> Void)?
    /// Wired by `AgentSpeechSynthesizer` for truthful first-audio timing.
    var onUtteranceStarted: ((UInt64) -> Void)?

    override init() {
        super.init()
        playbackEngine.attach(player)
        playbackEngine.connect(player, to: playbackEngine.mainMixerNode,
                               format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)
        VoicePlaybackReference.install(on: playbackEngine)
    }

    var isSpeaking: Bool { speaking }
    var outputGain: Float { player.volume }
    func setOutputGain(_ gain: Float) { player.volume = max(0, min(1, gain)) }

    private(set) var forbiddenTextCallsForTesting = 0
    func prewarmPreparedPlayback() throws {
        guard !speaking, !playbackEngine.isRunning else { return }
        playbackEngine.connect(player, to: playbackEngine.mainMixerNode,
                               format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)
        playbackEngine.prepare()
        try playbackEngine.start()
    }
    func playPrepared(_ buffers: [AVAudioPCMBuffer], volume: Float, token: UInt64) {
        guard !buffers.isEmpty else { onFailure?("", volume, token); return }
        volumeForReply = volume
        speaking = true; pausedForListening = false; activeToken = token
        clearResumeProof()
        if timelineEnabled {
            timelinePhase.value.store(2, ordering: .releasing)
            timelineEnd = 0; timelineOrdinal = 0; timelineRate = nil
            timelineResumeHost = nil; timelineCheckpoint = nil
        }
        pendingBuffers = 0; synthesisFinished = false; didBegin = false
        playbackEngine.mainMixerNode.outputVolume = max(0, min(1, volume))
        for buffer in buffers { play(buffer, token: token) }
        synthesisEnded(token: token)
    }

    /// This transport accepts prepared allowed-voice PCM only. Text cannot
    /// reach synthesis through it, even if a caller violates the route contract.
    func speak(_ text: String, volume: Float, token: UInt64) {
        if SelfTest.isRunning { forbiddenTextCallsForTesting += 1 }
        onFailure?(text, volume, token)
    }
    var onFailure: ((String, Float, UInt64) -> Void)?

    private func play(_ buffer: AVAudioPCMBuffer, token: UInt64) {
        guard activeToken == token else { return }
        do {
            if !playbackEngine.isRunning {
                playbackEngine.connect(player, to: playbackEngine.mainMixerNode,
                                       format: buffer.format)
                try playbackEngine.start()
            }
            pendingBuffers += 1
            if timelineEnabled {
                let lower = timelineEnd
                let addition = lower.addingReportingOverflow(Int64(buffer.frameLength))
                guard !addition.overflow, buffer.frameLength > 0,
                      buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
                      timelineRate == nil || timelineRate == buffer.format.sampleRate else {
                    throw NSError(domain: "PCMPlaybackTimelineDiagnostic", code: 1)
                }
                timelineRate = buffer.format.sampleRate
                timelineEnd = addition.partialValue
                timelineOrdinal += 1
                let observation = PCMPlaybackBufferObservation(token: token,
                    ordinal: timelineOrdinal, lowerFrame: lower, upperFrame: timelineEnd,
                    sampleRate: buffer.format.sampleRate)
                timelineObserverForTesting?(.scheduled(observation))
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
                    completionHandler: Self.makeTimelineCompletion(for: self,
                        buffer: observation, phase: timelinePhase,
                        interceptor: nativeCompletionInterceptorForTesting,
                        rawDeferral: SelfTest.isRunning ? rawCompletionDeferralForTesting : nil))
            } else {
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
                    [weak self] _ in
                    Task { @MainActor in self?.bufferPlayed(token: token) }
                }
            }
            if !pausedForListening && !player.isPlaying { player.play() }
        } catch {
            Log.agent.error("Prepared voice PCM playback failed: \(error.localizedDescription, privacy: .public)")
            stop()
            onFailure?("", volumeForReply, token)
        }
    }

    /// Captures immutable provenance BEFORE either the hook or MainActor hop.
    nonisolated private static func makeTimelineCompletion(
        for backing: PreparedPCMSpeechBacking, buffer: PCMPlaybackBufferObservation,
        phase: TimelinePhase,
        interceptor: (@Sendable (PCMPlaybackNativeObservation,
            @escaping @Sendable () -> Void) -> Void)?,
        rawDeferral: (@Sendable (RawPCMPlayedNotice,
            @escaping @Sendable () -> Void) -> Void)?
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak backing] kind in
            let raw = RawPCMPlayedNotice(buffer: buffer,
                callbackKind: Int(kind.rawValue), nativeEntryHostTime: mach_absolute_time())
            let observe: @Sendable () -> Void = { [weak backing] in
                let packet = PCMPlaybackNativeObservation(buffer: buffer,
                    originPhase: phase.value.load(ordering: .acquiring),
                    callbackKind: Int(kind.rawValue), originHostTime: mach_absolute_time(),
                    originWasMainThread: Thread.isMainThread)
                let forward: @Sendable () -> Void = { [weak backing] in
                    Task { @MainActor in backing?.receiveTimelineCompletion(packet) }
                }
                if let interceptor { interceptor(packet, forward) }
                else { forward() }
            }
            if let rawDeferral { rawDeferral(raw, observe) }
            else { observe() }
        }
    }

    private func timelineCursor() -> PCMPlaybackCursorObservation? {
        guard player.isPlaying, let node = player.lastRenderTime,
              node.isHostTimeValid, let position = player.playerTime(forNodeTime: node),
              position.isSampleTimeValid, position.sampleTime >= 0, position.sampleTime <= timelineEnd,
              let rate = timelineRate, rate == position.sampleRate,
              rate.isFinite, rate > 0 else { return nil }
        return .init(frame: position.sampleTime, sampleRate: rate,
            nodeHostTime: node.hostTime, observedHostTime: mach_absolute_time())
    }

    private func diagnosticCheckpoint(cursor: PCMPlaybackCursorObservation?,
        completedEnd: Int64?) -> Int64? {
        guard let host = timelineResumeHost, let cursor,
              cursor.nodeHostTime >= host else { return nil }
        // This is a POST-resume cursor, never a purported pre-pause cut.
        // First callback checkpoint excludes that entire completed buffer too.
        return max(cursor.frame, completedEnd ?? cursor.frame)
    }

    private func qualifiedResumeReceipt(_ packet: PCMPlaybackNativeObservation,
        cursor: PCMPlaybackCursorObservation?) -> PCMResumePlaybackReceipt? {
        let phase = timelinePhase.value.load(ordering: .acquiring)
        guard !resumeReceiptDelivered, let requestedHost = timelineResumeHost,
              activeToken == packet.buffer.token, speaking, !pausedForListening,
              phase != 0, phase % 2 == 0, packet.originPhase == phase,
              packet.callbackKind == Int(AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack.rawValue),
              packet.originHostTime >= requestedHost,
              packet.buffer.upperFrame > packet.buffer.lowerFrame,
              packet.buffer.sampleRate == timelineRate else { return nil }
        if let cut = resumeStrongCut, let earlier = resumeEarlierCursor,
           let later = resumeLaterCursor, let checkpointBuffer = resumeCheckpointBuffer {
            guard packet.buffer.upperFrame > cut,
                  packet.originHostTime >= later.observedHostTime else { return nil }
            resumeReceiptDelivered = true
            return .init(packet: packet, earlier: earlier, later: later, checkpoint: cut, checkpointBuffer: checkpointBuffer)
        }
        guard let cursor, cursor.sampleRate == packet.buffer.sampleRate,
              cursor.frame >= 0, cursor.frame <= timelineEnd,
              cursor.observedHostTime >= requestedHost,
              cursor.nodeHostTime >= requestedHost else { return nil }
        guard let earlier = resumeEarlierCursor else {
            resumeEarlierCursor = cursor
            return nil
        }
        // Future-dated node timestamps are NOT equated with wall-clock completion.
        // Require actual successive node/player observations to advance together.
        guard cursor.frame > earlier.frame,
              cursor.nodeHostTime > earlier.nodeHostTime,
              cursor.observedHostTime > earlier.observedHostTime,
              cursor.sampleRate == earlier.sampleRate else { return nil }
        resumeLaterCursor = cursor
        resumeStrongCut = max(cursor.frame, packet.buffer.upperFrame)
        resumeCheckpointBuffer = packet.buffer
        // The checkpoint-building packet itself never establishes fresh speaking.
        return nil
    }

    private func receiveTimelineCompletion(_ packet: PCMPlaybackNativeObservation) {
        let phase = timelinePhase.value.load(ordering: .acquiring)
        let current = activeToken == packet.buffer.token && speaking && !pausedForListening
            && phase != 0 && phase % 2 == 0 && packet.originPhase == phase
            && packet.callbackKind == Int(AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack.rawValue)
            && (timelineResumeHost.map { packet.originHostTime >= $0 } ?? true)
        // Existing initial onset keeps its fast path: player query only for a
        // pending resume or an explicitly installed SelfTest observer.
        let cursor = timelineObserverForTesting != nil || (timelineResumeHost != nil && !resumeReceiptDelivered)
            ? timelineCursor() : nil
        let before = timelineCheckpoint
        if current, timelineResumeHost != nil, before == nil {
            timelineCheckpoint = diagnosticCheckpoint(cursor: cursor,
                completedEnd: packet.buffer.upperFrame)
        }
        // Observation candidate only; does not restore any status or publish UI.
        let candidate: Bool
        if let before {
            candidate = current && timelineResumeHost != nil
                && packet.buffer.upperFrame > before
                && packet.buffer.upperFrame > packet.buffer.lowerFrame
        } else { candidate = false }
        timelineObserverForTesting?(.handled(packet, currentPhase: phase,
            cursor: cursor, checkpointBefore: before, checkpointAfter: timelineCheckpoint,
            currentOwner: current, candidate: candidate))
        if let receipt = qualifiedResumeReceipt(packet, cursor: cursor) {
            if SelfTest.isRunning { resumeProofObserverForTesting?(receipt) }
            onResumePlaybackAcknowledged?(receipt)
        }
        // Never suppress the existing drain bookkeeping for an unusable packet.
        bufferPlayed(token: packet.buffer.token)
    }

    private func synthesisEnded(token: UInt64) {
        guard activeToken == token else { return }
        synthesisFinished = true
        finishIfDrained(token: token)
    }

    private func bufferPlayed(token: UInt64) {
        guard activeToken == token, pendingBuffers > 0 else { return }
        if !didBegin {
            didBegin = true
            onUtteranceStarted?(token)
        }
        pendingBuffers -= 1
        finishIfDrained(token: token)
    }

    private func finishIfDrained(token: UInt64) {
        guard activeToken == token, synthesisFinished, pendingBuffers == 0 else { return }
        speaking = false
        pausedForListening = false
        clearResumeProof()
        if timelineEnabled {
            let phase = timelinePhase.value.load(ordering: .acquiring)
            timelinePhase.value.store(0, ordering: .releasing)
            timelineObserverForTesting?(.stopped(token: activeToken, phaseBefore: phase))
        }
        activeToken = nil
        player.stop()
        playbackEngine.stop()
        VoicePlaybackReference.stopped()
        onUtteranceFinished?(token)
    }

    func stop() {
        speaking = false
        pausedForListening = false
        clearResumeProof()
        if timelineEnabled {
            let phase = timelinePhase.value.load(ordering: .acquiring)
            timelinePhase.value.store(0, ordering: .releasing)
            timelineObserverForTesting?(.stopped(token: activeToken, phaseBefore: phase))
        }
        activeToken = nil
        player.stop()
        playbackEngine.stop()
        VoicePlaybackReference.stopped()
        pendingBuffers = 0
    }

    func pauseForListening() {
        guard speaking, !pausedForListening else { return }
        pausedForListening = true
        clearResumeProof()
        if timelineEnabled, let token = activeToken {
            let phase = timelinePhase.value.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
            timelineResumeHost = nil
            timelineCheckpoint = nil
            timelineObserverForTesting?(.paused(token: token, phase: phase))
        }
        if player.isPlaying { player.pause() }
    }

    func resumeAfterListening() {
        guard speaking, pausedForListening else { return }
        pausedForListening = false
        clearResumeProof()
        if timelineEnabled {
            _ = timelinePhase.value.wrappingAdd(1, ordering: .acquiringAndReleasing)
            timelineResumeHost = mach_absolute_time()
            timelineCheckpoint = nil
        }
        if pendingBuffers > 0 && !player.isPlaying { player.play() }
        if timelineEnabled, let token = activeToken {
            let cursor = timelineCursor()
            if let cursor, let host = timelineResumeHost,
               cursor.sampleRate == timelineRate, cursor.frame >= 0, cursor.frame <= timelineEnd,
               cursor.observedHostTime >= host, cursor.nodeHostTime >= host {
                resumeEarlierCursor = cursor
            }
            timelineCheckpoint = diagnosticCheckpoint(cursor: cursor, completedEnd: nil)
            timelineObserverForTesting?(.resumed(token: token,
                phase: timelinePhase.value.load(ordering: .acquiring),
                requestedHostTime: timelineResumeHost ?? 0, cursor: cursor,
                checkpoint: timelineCheckpoint))
        }
    }

}
