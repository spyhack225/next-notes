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
        let atNanos = DispatchTime.now().uptimeNanoseconds
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
    func replayInput(sequence: Int, frames: Range<Int>) -> Input {
        lock.lock(); defer { lock.unlock() }
        let input = Input(sequence: sequence, frames: frames,
            second: inputs[sequence]?.second ?? secondInput)
        history.append(Event(kind: "capture.replay", input: input,
            epoch: nil, capturedEnd: max(nextFrame, frames.upperBound)))
        return input
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
    typealias Callback = @Sendable (String, VoiceDecoderProgress.Stamp) -> Void
    struct Progress: Sendable {
        let processedEnd: Int64
        let scope: VoiceDecoderProgress.Scope
    }
    nonisolated let progress = VoiceDecoderProgress()
    private var endCallback: Callback = { _, _ in }
    private var partialCallback: Callback = { _, _ in }
    private var nativeScope: VoiceDecoderProgress.Scope?
    private var bufferedFrames = 0
    private var processedSampleEnd: Int64 = 0
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

    /// Optional preparation reads complete installed files only, never the SDK downloader.
    nonisolated static func cachedModelDirectory(root: URL? = nil) -> URL? {
        guard let support = root ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let models = support.appendingPathComponent("FluidAudio/Models/parakeet-eou-streaming")
        let candidates = [models.appendingPathComponent(Repo.parakeetEou160.folderName),
                          models.appendingPathComponent("parakeet-eou-streaming/160ms")]
        return candidates.first { directory in
            ModelNames.ParakeetEOU.requiredModels.allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        }
    }

    /// Called only by the capture-owned background handle. No session/callback reset
    /// when ready: live attachment continues to belong to prepare().
    func prepareCachedModels(from directory: URL,
        producerProbeForTesting probe: VoiceInputProducerProbe? = nil) async throws {
        guard await acquireOperation() else { throw CancellationError() }
        defer { releaseOperation() }
        guard !ready else { return }
        guard ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork else { return }
        if SelfTest.isRunning, let probe { producerProbeForTesting = probe }
        await setCallbacks({ _, _ in }, onPartial: { _, _ in })
        try await loadAndPrime(from: directory)
        try Task.checkCancellation()
        ready = true
        producerProbeForTesting?.record("prepare.ready")
    }

    func prepare(
        onEndOfUtterance: @escaping Callback,
        onPartial: @escaping Callback,
        sessionID: UUID? = nil,
        epoch: Int = 0,
        admission supplied: VoiceDecoderProgress.Scope? = nil,
        producerProbeForTesting probe: VoiceInputProducerProbe? = nil
    ) async throws {
        guard await acquireOperation() else { throw CancellationError() }
        defer { releaseOperation() }
        if SelfTest.isRunning, let probe { producerProbeForTesting = probe }
        preparedSessionID = sessionID
        let admission = supplied ?? progress.invalidate(sessionID: sessionID, epoch: epoch)
        if ready {
            await manager.reset()
            bufferedFrames = 0; processedSampleEnd = 0
            if let producerProbeForTesting {
                await producerProbeForTesting.holdPreparedDecoder()
            }
            await setCallbacks(onEndOfUtterance, onPartial: onPartial, scope: admission)
            producerProbeForTesting?.record("prepare.reused")
            producerProbeForTesting?.record("prepare.ready")
            return
        }
        try await loadAndPrime()
        await setCallbacks(onEndOfUtterance, onPartial: onPartial, scope: admission)
        ready = true
        producerProbeForTesting?.record("prepare.ready")
    }

    private func loadAndPrime(from directory: URL? = nil) async throws {
        producerProbeForTesting?.record("prepare.load")
        if let directory { try await manager.loadModels(from: directory) }
        else { try await manager.loadModels() }
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
        bufferedFrames = 0; processedSampleEnd = 0
        if let producerProbeForTesting {
            // Keep the real preparation operation held after native load/prime.
            // This is the cold-backlog/reset ordering, without variable load time.
            await producerProbeForTesting.holdPreparedDecoder()
        }
    }

    @discardableResult
    func process(_ chunk: AudioChunk,
        producerInputForTesting: VoiceInputProducerProbe.Input? = nil,
        capturedEnd: Int64? = nil) async throws -> Progress {
        guard await acquireOperation() else { throw CancellationError() }
        defer { releaseOperation() }
        let scope = nativeScope ?? progress.snapshot().scope
        guard ready, progress.isCurrent(scope) else { return Progress(processedEnd: 0, scope: scope) }
        producerProbeForTesting?.processBegan(producerInputForTesting)
        var completed = false
        defer { producerProbeForTesting?.processEnded(success: completed) }
        _ = try await manager.process(audioBuffer: chunk.buffer)
        // SDK process() can merely buffer a 10ms input. Its pinned 160ms graph
        // decodes only complete windows, shifting80ms. Count native-covered PCM,
        // never claim that feed/admission alone processed the latest sample.
        bufferedFrames += Int(chunk.buffer.frameLength)
        let size = StreamingChunkSize.ms160.chunkSamples
        let shift = StreamingChunkSize.ms160.shiftSamples
        var decoded = false
        while bufferedFrames >= size { bufferedFrames -= shift; decoded = true }
        if decoded, let capturedEnd {
            processedSampleEnd = capturedEnd - Int64(bufferedFrames)
        }
        completed = true
        progress.processed(through: processedSampleEnd, in: scope)
        return Progress(processedEnd: processedSampleEnd, scope: scope)
    }

    func close(keepingPrepared: Bool = false) async {
        guard await acquireOperation(cancellable: false) else { return }
        defer { releaseOperation() }
        // Retain only healthy, fully prepared weights after the owned session drains.
        guard !keepingPrepared || !ready else { return }
        ready = false
        let retiringID = preparedSessionID
        preparedSessionID = nil
        let retiring = progress.snapshot().scope
        if retiring.sessionID == retiringID {
            progress.invalidate(sessionID: retiring.sessionID, epoch: retiring.epoch)
        }
        nativeScope = nil
        await manager.cleanup()
        producerProbeForTesting?.record("models.closed")
    }

    func modelsPreparedForTesting() -> Bool { ready }

    @discardableResult
    func resetForNextTurn(
        onEndOfUtterance: @escaping Callback,
        onPartial: @escaping Callback,
        sessionID: UUID? = nil,
        epoch: Int = 0
    ) async -> Bool {
        producerProbeForTesting?.record("reset.requested")
        let requested = progress.snapshot()
        guard requested.scope.sessionID == sessionID, requested.scope.epoch == epoch else { return false }
        guard await acquireOperation() else { return false }
        defer { releaseOperation() }
        guard ready, preparedSessionID == sessionID else { return false }
        guard progress.isCurrent(requested.scope) else { return false }
        let active = progress.invalidate(sessionID: sessionID, epoch: epoch, through: requested.resetBoundary)
        producerProbeForTesting?.record("reset.granted")
        await manager.reset()
        bufferedFrames = 0; processedSampleEnd = 0
        guard progress.isCurrent(active) else { return false }
        await setCallbacks(onEndOfUtterance, onPartial: onPartial, scope: active)
        guard progress.isCurrent(active) else { return false }
        producerProbeForTesting?.record("reset.completed")
        return true
    }

    func resetForDiscontinuity() async {
        guard await acquireOperation() else { return }
        defer { releaseOperation() }
        guard ready else { return }
        let scope = progress.snapshot().scope
        guard let nativeScope, scope.sessionID == nativeScope.sessionID,
              scope.epoch == nativeScope.epoch else { return }
        let active = progress.invalidate(sessionID: scope.sessionID, epoch: scope.epoch)
        await manager.reset()
        bufferedFrames = 0; processedSampleEnd = 0
        guard progress.isCurrent(active) else { return }
        await setCallbacks(endCallback, onPartial: partialCallback, scope: active)
    }

    private func setCallbacks(_ callback: @escaping Callback,
        onPartial: @escaping Callback, scope supplied: VoiceDecoderProgress.Scope? = nil) async {
        let scope = supplied ?? progress.snapshot().scope
        guard progress.isCurrent(scope) else { return }
        endCallback = callback; partialCallback = onPartial
        let producerProbeForTesting = self.producerProbeForTesting
        let progress = self.progress
        nativeScope = scope
        await manager.setEouCallback { transcript in
            guard let stamp = progress.produced(in: scope) else { return }
            producerProbeForTesting?.record("native.eou")
            // This is a confirmed endpoint, not a text update. A decoder can
            // confirm EOU without lexical tokens; capture decides whether it
            // settles an existing provisional input or is idle silence.
            callback(transcript, stamp)
        }
        await manager.setPartialCallback { transcript in
            guard let stamp = progress.produced(in: scope) else { return }
            producerProbeForTesting?.record("native.partial")
            onPartial(transcript, stamp)
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
                text, _ in Task { await probe.record(text) }
            }, onPartial: { text, _ in Task { await probe.recordPartial(text) } })
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
