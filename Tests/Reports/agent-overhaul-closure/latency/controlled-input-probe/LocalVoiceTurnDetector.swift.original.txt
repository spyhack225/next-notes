import AVFoundation
import FluidAudio
import Foundation

/// Parakeet's locally decoded EOU token is independent of Apple SpeechAnalyzer's
/// volatile text. Audio never leaves the machine. One instance owns one mic session.
actor LocalVoiceTurnDetector {
    private let manager = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 320)
    private var ready = false
    // FluidAudio's actor awaits Core ML during process and can reenter reset
    // while its encoder cache is live. Serialize whole operations, not just
    // their actor-isolated sections.
    private var operationBusy = false
    private var operationWaiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    private func acquireOperation(cancellable: Bool = true) async -> Bool {
        if cancellable && Task.isCancelled { return false }
        if !operationBusy {
            operationBusy = true
            return true
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancellable && Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    operationWaiters.append((id, continuation))
                }
            }
        } onCancel: {
            if cancellable { Task { await self.cancelOperationWaiter(id) } }
        }
        if granted && cancellable && Task.isCancelled {
            releaseOperation()
            return false
        }
        return granted
    }

    private func cancelOperationWaiter(_ id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.0 == id }) else { return }
        operationWaiters.remove(at: index).1.resume(returning: false)
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationBusy = false
        } else {
            operationWaiters.removeFirst().1.resume(returning: true)
        }
    }

    private func queuedOperationCount() -> Int { operationWaiters.count }

    /// A reset queued behind model inference must not enter until that process
    /// releases the gate. This proves the serialization contract without
    /// loading Core ML or relying on scheduler timing from a WAV probe.
    static func operationGateSelfTestFailures() async -> [String] {
        let detector = LocalVoiceTurnDetector()
        guard await detector.acquireOperation() else {
            return ["EOU process could not acquire its operation gate"]
        }
        let resetWaiter = Task { await detector.acquireOperation() }
        var queued = false
        for _ in 0..<1_000 {
            if await detector.queuedOperationCount() == 1 {
                queued = true
                break
            }
            await Task.yield()
        }
        if !queued {
            await detector.releaseOperation()
            _ = await resetWaiter.value
            await detector.releaseOperation()
            return ["EOU reset did not queue behind in-flight process"]
        }
        await detector.releaseOperation()
        let granted = await resetWaiter.value
        await detector.releaseOperation()
        return granted ? [] : ["EOU queued reset did not acquire after process completion"]
    }

    func prepare(
        onEndOfUtterance: @escaping @Sendable (String) -> Void,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        guard await acquireOperation() else { throw CancellationError() }
        defer { releaseOperation() }
        try await manager.loadModels()
        // Core ML can defer its first encoder/decoder compilation until
        // process(), after loadModels returns. Prime that path before capture
        // announces readiness, then discard the silent decoder state.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false),
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_560),
            let samples = silence.floatChannelData?[0] else {
            throw TranscriptionError.noAudioFormat
        }
        silence.frameLength = 2_560
        for index in 0..<2_560 { samples[index] = 0 }
        _ = try await manager.process(audioBuffer: silence)
        await manager.reset()
        await setCallbacks(onEndOfUtterance, onPartial: onPartial)
        ready = true
    }

    func process(_ chunk: AudioChunk) async throws {
        guard await acquireOperation() else { throw CancellationError() }
        defer { releaseOperation() }
        guard ready else { return }
        _ = try await manager.process(audioBuffer: chunk.buffer)
    }

    func close() async {
        guard await acquireOperation(cancellable: false) else { return }
        defer { releaseOperation() }
        ready = false
        await manager.cleanup()
    }

    func resetForNextTurn(
        onEndOfUtterance: @escaping @Sendable (String) -> Void,
        onPartial: @escaping @Sendable (String) -> Void
    ) async {
        guard await acquireOperation() else { return }
        defer { releaseOperation() }
        guard ready else { return }
        await manager.reset()
        await setCallbacks(onEndOfUtterance, onPartial: onPartial)
    }

    func resetForDiscontinuity() async {
        guard await acquireOperation() else { return }
        defer { releaseOperation() }
        guard ready else { return }
        await manager.reset()
    }

    private func setCallbacks(_ callback: @escaping @Sendable (String) -> Void,
        onPartial: @escaping @Sendable (String) -> Void) async {
        await manager.setEouCallback { transcript in
            // This is a confirmed endpoint, not a text update. A decoder can
            // confirm EOU without lexical tokens; capture decides whether it
            // settles an existing provisional input or is idle silence.
            callback(transcript)
        }
        await manager.setPartialCallback { transcript in
            onPartial(transcript)
        }
    }

    /// Model-backed probe. A silent input must never be counted as EOU, and a
    /// speech fixture must produce an EOU callback from the actual Core ML head.
    static func selfTest(wav: URL) async -> [String] {
        actor Probe {
            var endings: [String] = []
            var partials: [String] = []
            func record(_ text: String) { endings.append(text) }
            func recordPartial(_ text: String) { partials.append(text) }
            func count() -> Int { endings.count }
            func wordEndingCount() -> Int {
                endings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            }
            func partialCount() -> Int { partials.count }
        }
        let probe = Probe()
        let detector = LocalVoiceTurnDetector()
        do {
            try await detector.prepare(onEndOfUtterance: {
                text in Task { await probe.record(text) }
            }, onPartial: { text in Task { await probe.recordPartial(text) } })
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000, channels: 1, interleaved: false),
                let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_560),
                let channel = silence.floatChannelData?[0] else {
                return ["could not construct silent input"]
            }
            silence.frameLength = silence.frameCapacity
            channel.initialize(repeating: 0, count: Int(silence.frameLength))
            for _ in 0..<20 { try await detector.process(AudioChunk(buffer: silence)) }
            try await Task.sleep(for: .milliseconds(100))
            let silentCallbacks = await probe.count()
            let silentPartials = await probe.partialCount()
            let silentModelSignal = await detector.manager.eouDetected
            if silentCallbacks != 0 || silentPartials != 0 || silentModelSignal {
                return ["silence produced model speech or EOU"]
            }

            await detector.manager.reset()

            let file = try AVAudioFile(forReading: wav)
            let frames = AVAudioFrameCount(max(1, Int(file.processingFormat.sampleRate * 0.16)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                frameCapacity: frames) else { return ["could not construct speech buffer"] }
            while file.framePosition < file.length {
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try await detector.process(AudioChunk(buffer: buffer))
            }
            // A recording may stop immediately after a spoken word. Advance
            // the streaming decoder with real silence so its EOU head can fire.
            for _ in 0..<20 { try await detector.process(AudioChunk(buffer: silence)) }
            try await Task.sleep(for: .milliseconds(100))
            let count = await probe.wordEndingCount()
            let partialCount = await probe.partialCount()
            await detector.close()
            var failures: [String] = []
            if count == 0 { failures.append("speech produced no model EOU") }
            if partialCount == 0 { failures.append("speech produced no local partial words") }
            return failures
        } catch {
            await detector.close()
            return ["local EOU failed: \(error.localizedDescription)"]
        }
    }
}
