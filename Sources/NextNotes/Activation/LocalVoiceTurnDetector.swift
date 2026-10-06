import AVFoundation
import FluidAudio
import Foundation

/// Parakeet's locally decoded EOU token is independent of Apple SpeechAnalyzer's
/// volatile text. Audio never leaves the machine. One instance owns one mic session.

/// Harness-only metadata and suspension points. Stores no PCM and produces no
/// decoder words/endpoints. Every observed callback still comes from FluidAudio.
final class VoiceInputProducerProbe: @unchecked Sendable {
    struct Input: Sendable {
        let sequence: Int
        let frames: Range<Int>
        let second: Bool
    }
    struct Event: Sendable {
        let kind: String
        let input: Input?
        let epoch: Int?
        let capturedEnd: Int
    }
    private let lock = NSLock()
    private var nextFrame = 0
    private var inputs: [Int: Input] = [:]
    private var history: [Event] = []
    private var activeInput: Input?
    private var secondInput = false
    private var prepareReleased: Bool
    private var commitReleased: Bool
    private var firstCommitSelected = false
    private var prepareWaiter: CheckedContinuation<Void, Never>?
    private var commitWaiter: CheckedContinuation<Void, Never>?

    init(holdPrepare: Bool, holdFirstCommit: Bool) {
        prepareReleased = !holdPrepare
        commitReleased = !holdFirstCommit
    }
    func beginSecondInput() {
        lock.lock()
        secondInput = true
        lock.unlock()
    }
    func captured(sequence: Int, frames: Int) {
        lock.lock()
        let input = Input(sequence: sequence,
            frames: nextFrame..<(nextFrame + frames), second: secondInput)
        nextFrame += frames
        inputs[sequence] = input
        history.append(Event(kind: "captured", input: input,
            epoch: nil, capturedEnd: nextFrame))
        lock.unlock()
    }
    func input(sequence: Int) -> Input? {
        lock.lock()
        defer { lock.unlock() }
        return inputs[sequence]
    }
    func processBegan(_ input: Input?) {
        lock.lock()
        activeInput = input
        history.append(Event(kind: "process.begin", input: input,
            epoch: nil, capturedEnd: nextFrame))
        lock.unlock()
    }
    func processEnded(success: Bool) {
        lock.lock()
        history.append(Event(kind: success ? "process.end" : "process.failed", input: activeInput,
            epoch: nil, capturedEnd: nextFrame))
        activeInput = nil
        lock.unlock()
    }
    func record(_ kind: String, epoch: Int? = nil) {
        lock.lock()
        history.append(Event(kind: kind, input: activeInput,
            epoch: epoch, capturedEnd: nextFrame))
        lock.unlock()
    }
    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }
    func holdPreparedDecoder() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            history.append(Event(kind: "prepare.checkpoint", input: nil,
                epoch: nil, capturedEnd: nextFrame))
            if prepareReleased {
                lock.unlock()
                continuation.resume()
            } else {
                history.append(Event(kind: "prepare.held", input: nil,
                    epoch: nil, capturedEnd: nextFrame))
                prepareWaiter = continuation
                lock.unlock()
            }
        }
    }
    func holdFirstCommit(epoch: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if firstCommitSelected {
                lock.unlock()
                continuation.resume()
                return
            }
            firstCommitSelected = true
            history.append(Event(kind: "commit.selected", input: nil,
                epoch: epoch, capturedEnd: nextFrame))
            if commitReleased {
                lock.unlock()
                continuation.resume()
            } else {
                commitWaiter = continuation
                lock.unlock()
            }
        }
    }
    func releasePrepare() {
        lock.lock()
        prepareReleased = true
        let waiter = prepareWaiter
        prepareWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
    func releaseCommit() {
        lock.lock()
        commitReleased = true
        let waiter = commitWaiter
        commitWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
    func releaseAll() {
        releasePrepare()
        releaseCommit()
    }
}

actor LocalVoiceTurnDetector {
    private let manager = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 320)
    private var ready = false
    private var preparedSessionID: UUID?
    private var producerProbeForTesting: VoiceInputProducerProbe?

    init(producerProbeForTesting: VoiceInputProducerProbe? = nil) {
        // An ordinary app invocation cannot suspend production operations.
        self.producerProbeForTesting = SelfTest.isRunning ? producerProbeForTesting : nil
    }
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
        onPartial: @escaping @Sendable (String) -> Void,
        sessionID: UUID? = nil,
        producerProbeForTesting probe: VoiceInputProducerProbe? = nil
    ) async throws {
        guard await acquireOperation() else { throw CancellationError() }
        defer { releaseOperation() }
        if SelfTest.isRunning, let probe { producerProbeForTesting = probe }
        preparedSessionID = sessionID
        if ready {
            await manager.reset()
            if let producerProbeForTesting {
                await producerProbeForTesting.holdPreparedDecoder()
            }
            await setCallbacks(onEndOfUtterance, onPartial: onPartial)
            producerProbeForTesting?.record("prepare.reused")
            producerProbeForTesting?.record("prepare.ready")
            return
        }
        producerProbeForTesting?.record("prepare.load")
        try await manager.loadModels()
        producerProbeForTesting?.record("prepare.loaded")
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
        if let producerProbeForTesting {
            // Keep the real preparation operation held after native load/prime.
            // This is the cold-backlog/reset ordering, without variable load time.
            await producerProbeForTesting.holdPreparedDecoder()
        }
        await setCallbacks(onEndOfUtterance, onPartial: onPartial)
        ready = true
        producerProbeForTesting?.record("prepare.ready")
    }

    func process(_ chunk: AudioChunk,
        producerInputForTesting: VoiceInputProducerProbe.Input? = nil) async throws {
        guard await acquireOperation() else { throw CancellationError() }
        defer { releaseOperation() }
        guard ready else { return }
        producerProbeForTesting?.processBegan(producerInputForTesting)
        var completed = false
        defer { producerProbeForTesting?.processEnded(success: completed) }
        _ = try await manager.process(audioBuffer: chunk.buffer)
        completed = true
    }

    func close(keepingPrepared: Bool = false) async {
        guard await acquireOperation(cancellable: false) else { return }
        defer { releaseOperation() }
        // Retain only healthy, fully prepared weights after the owned session drains.
        guard !keepingPrepared || !ready else { return }
        ready = false
        preparedSessionID = nil
        await manager.cleanup()
        producerProbeForTesting?.record("models.closed")
    }

    func modelsPreparedForTesting() -> Bool { ready }

    @discardableResult
    func resetForNextTurn(
        onEndOfUtterance: @escaping @Sendable (String) -> Void,
        onPartial: @escaping @Sendable (String) -> Void,
        sessionID: UUID? = nil
    ) async -> Bool {
        producerProbeForTesting?.record("reset.requested")
        guard await acquireOperation() else { return false }
        defer { releaseOperation() }
        guard ready, preparedSessionID == sessionID else { return false }
        producerProbeForTesting?.record("reset.granted")
        await manager.reset()
        await setCallbacks(onEndOfUtterance, onPartial: onPartial)
        producerProbeForTesting?.record("reset.completed")
        return true
    }

    func resetForDiscontinuity() async {
        guard await acquireOperation() else { return }
        defer { releaseOperation() }
        guard ready else { return }
        await manager.reset()
    }

    private func setCallbacks(_ callback: @escaping @Sendable (String) -> Void,
        onPartial: @escaping @Sendable (String) -> Void) async {
        let producerProbeForTesting = self.producerProbeForTesting
        await manager.setEouCallback { transcript in
            producerProbeForTesting?.record("native.eou")
            // This is a confirmed endpoint, not a text update. A decoder can
            // confirm EOU without lexical tokens; capture decides whether it
            // settles an existing provisional input or is idle silence.
            callback(transcript)
        }
        await manager.setPartialCallback { transcript in
            producerProbeForTesting?.record("native.partial")
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
