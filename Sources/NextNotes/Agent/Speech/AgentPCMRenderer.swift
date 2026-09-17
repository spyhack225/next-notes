import AVFoundation
import Foundation
import Synchronization

/// Agent-only output graph. An AVAudioSourceNode pulls the exact PCM sent to
/// the speaker and publishes that PCM to a bounded reverse-stream FIFO in the
/// same render callback. The real-time callback performs only copies, atomic
/// operations and zero filling; AEC, conversion and callbacks run elsewhere.
@MainActor
final class AgentPCMRenderer {
    static let shared = AgentPCMRenderer()
    static let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000, channels: 1, interleaved: false)!

    private final class Core: @unchecked Sendable {
        let output = RealtimePCMFloatRing(capacity: 16_000 * 8)
        let reference = RealtimePCMReferenceRing(capacity: 16_000 * 4)
        let requestedToken = Atomic<UInt64>(0)
        let renderedToken = Atomic<UInt64>(0)
        let paused = Atomic<Bool>(false)
        let firstSampleHostTime = Atomic<UInt64>(0)
        let lastSampleHostTime = Atomic<UInt64>(0)
        let referenceDropped = Atomic<Int>(0)
        let outputLatencyNanoseconds = Atomic<Int64>(0)
        let renderedSamples = Atomic<Int>(0)
        let failureCode = Atomic<UInt8>(0)
        let hostTicksPerSecond = Double(AVAudioTime.hostTime(forSeconds: 1))

        func render(_ count: Int, into outputBuffer: UnsafeMutablePointer<Float>,
                    timestamp: UnsafePointer<AudioTimeStamp>) {
            let token = requestedToken.load(ordering: .acquiring)
            if token != renderedToken.load(ordering: .relaxed) {
                output.discardUnreadFromConsumer()
                firstSampleHostTime.store(0, ordering: .releasing)
                lastSampleHostTime.store(0, ordering: .releasing)
                renderedSamples.store(0, ordering: .releasing)
                renderedToken.store(token, ordering: .releasing)
            }
            let copied = token != 0 && !paused.load(ordering: .acquiring)
                ? output.read(into: outputBuffer, maxCount: count) : 0
            if copied < count {
                outputBuffer.advanced(by: copied).update(repeating: 0, count: count - copied)
            }
            // Include silence. AEC's reverse stream must remain continuous
            // across turn boundaries and while a suspended output is quiet.
            let host = timestamp.pointee.mFlags.contains(.hostTimeValid)
                ? timestamp.pointee.mHostTime : 0
            let accepted = reference.write(outputBuffer, count: count,
                firstHostTime: host, ticksPerSample: hostTicksPerSecond / 16_000)
            if accepted < count {
                _ = referenceDropped.wrappingAdd(count - accepted, ordering: .relaxed)
            }
            guard copied > 0 else { return }
            let playedHost = host != 0 ? host : mach_absolute_time()
            if firstSampleHostTime.load(ordering: .relaxed) == 0 {
                firstSampleHostTime.store(playedHost, ordering: .releasing)
            }
            let end = playedHost &+ UInt64(Double(copied) / 16_000 * hostTicksPerSecond)
            lastSampleHostTime.store(end, ordering: .releasing)
            _ = renderedSamples.wrappingAdd(copied, ordering: .relaxed)
        }
    }

    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var core: Core?
    private var reverseTimer: DispatchSourceTimer?
    private var receiptTask: Task<Void, Never>?
    private var reverseLane: DispatchQueue?
    private var token: UInt64 = 0
    private var finished = false
    private var firstDelivered = false
    private var drainDelivered = false
    private var outputLatency: TimeInterval = 0
    private var converterFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?
    private var graphGeneration: UInt64 = 0
    private var sessionFailure: RendererError?
    var onFirstSample: ((UInt64) -> Void)?
    var onDrained: ((UInt64) -> Void)?
    var onFailure: ((UInt64, String) -> Void)?

    var isRunning: Bool { engine?.isRunning == true }
    var referenceOverflowSamples: Int { core?.referenceDropped.load(ordering: .acquiring) ?? 0 }
    var renderedSampleCount: Int { core?.renderedSamples.load(ordering: .acquiring) ?? 0 }

    /// Exercises ownership of the source graph without changing the machine's
    /// input device.  A zero PCM buffer is valid here: the render receipt is
    /// the assertion, rather than an acoustic measurement.
    @MainActor
    static func runConfigurationRecoverySelfTest() async -> Bool {
        let renderer = AgentPCMRenderer()
        var firstSamples: [UInt64] = []
        var failures: [(UInt64, String)] = []
        var drained: [UInt64] = []
        renderer.onFirstSample = { firstSamples.append($0) }
        renderer.onFailure = { failures.append(($0, $1)) }
        renderer.onDrained = { drained.append($0) }
        defer {
            SelfTest.diagnostic("PCM_RECONFIGURATION_RECEIPTS first=\(firstSamples) failures=\(failures) drained=\(drained)")
            renderer.endSession()
        }

        do { try renderer.startSession() }
        catch { return false }

        guard let first = Self.makeSelfTestBuffer() else { return false }
        do {
            try await renderer.enqueue(first, token: 1, volume: 1)
            renderer.finish(token: 1)
        } catch {
            return false
        }
        guard await Self.waitForSelfTest({ firstSamples.contains(1) }) else { return false }
        guard let oldEngine = renderer.engine else { return false }
        let oldGeneration = renderer.graphGeneration

        // The payload is an explicitly unchecked Sendable box because the
        // notification is intentionally posted off the MainActor. The
        // renderer's observer is the only code allowed to consume the engine.
        let notice = ConfigurationNotice(engine: oldEngine)
        DispatchQueue.global(qos: .userInitiated).async {
            notice.engine.stop()
            NotificationCenter.default.post(
                name: .AVAudioEngineConfigurationChange,
                object: notice.engine
            )
        }

        guard await Self.waitForSelfTest({ failures.count == 1
            && renderer.engine !== oldEngine && renderer.engine?.isRunning == true }) else { return false }
        guard failures.first?.0 == 1, !drained.contains(1) else { return false }
        guard let rebuiltEngine = renderer.engine, rebuiltEngine !== oldEngine,
              rebuiltEngine.isRunning else { return false }

        // This old-generation event must not tear down the rebuilt graph or
        // affect the next token.
        let lateNotice = ConfigurationNotice(engine: oldEngine)
        DispatchQueue.global(qos: .userInitiated).async {
            NotificationCenter.default.post(
                name: .AVAudioEngineConfigurationChange,
                object: lateNotice.engine
            )
        }

        guard let second = Self.makeSelfTestBuffer() else { return false }
        do {
            try await renderer.enqueue(second, token: 2, volume: 1)
            renderer.finish(token: 2)
        } catch {
            return false
        }
        guard await Self.waitForSelfTest({ firstSamples.contains(2) }) else { return false }
        // Also deliver an already-queued old observer callback, which removing
        // its NotificationCenter observer cannot revoke.
        renderer.configurationChanged(graphGeneration: oldGeneration)
        guard await Self.waitForSelfTest({ firstSamples.contains(2) && drained.contains(2) }) else {
            return false
        }
        let completedEngine = renderer.engine
        renderer.configurationChanged(graphGeneration: renderer.graphGeneration)
        guard renderer.engine !== completedEngine, renderer.isRunning else { return false }
        return failures.count == 1 && failures.first?.0 == 1
            && drained == [2] && firstSamples == [1, 2]
    }

    @MainActor
    private static func waitForSelfTest(_ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private static func makeSelfTestBuffer() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 8_000),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = 8_000
        samples.update(repeating: 0, count: 8_000)
        return buffer
    }

    private final class ConfigurationNotice: @unchecked Sendable {
        let engine: AVAudioEngine
        init(engine: AVAudioEngine) { self.engine = engine }
    }

    nonisolated static func runReverseCallbackIsolationSelfTest() async -> Bool {
        let core = Core()
        let zeros = [Float](repeating: 0, count: 160)
        zeros.withUnsafeBufferPointer {
            _ = core.reference.write($0.baseAddress!, count: 160,
                firstHostTime: 0, ticksPerSample: core.hostTicksPerSecond / 16_000)
        }
        let callback = makeReverseHandler(for: core)
        // sync may execute inline on the calling thread. An asynchronous queue
        // hop proves this callback can run on an actual non-main thread.
        return await withCheckedContinuation { continuation in
            DispatchQueue(label: "ai.pivotstudio.nextnotes.reverse-isolation-test")
                .async {
                    let offMain = !Thread.isMainThread
                    callback()
                    continuation.resume(returning: offMain && core.reference.availableToRead == 0)
                }
        }
    }

    // AVAudioEngine calls this block on its realtime render queue. Building it
    // outside actor isolation avoids inheriting MainActor from startSession().
    nonisolated private static func makeRenderBlock(for core: Core)
        -> AVAudioSourceNodeRenderBlock {
        { _, timestamp, frames, buffers in
            guard let data = buffers.pointee.mBuffers.mData else { return -1 }
            core.render(Int(frames), into: data.assumingMemoryBound(to: Float.self),
                        timestamp: timestamp)
            return noErr
        }
    }

    // A DispatchSource handler formed in startSession() would inherit
    // MainActor isolation and assert on its utility queue. Construct it here
    // instead; the handler uses only the Sendable ring and lock-protected DSP.
    nonisolated private static func makeReverseHandler(for core: Core)
        -> @Sendable () -> Void {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false)!
        return { [core] in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: 160),
                  let samples = buffer.floatChannelData?[0] else { return }
            for _ in 0..<32 {
                guard core.reference.availableToRead >= 160 else { break }
                buffer.frameLength = 160
                let frame = core.reference.read(into: samples, count: 160)
                guard frame.frames == 160 else { break }
                AcousticEchoProcessor.shared.feedRendered(buffer,
                    renderHostTime: frame.firstHostTime == 0 ? nil : frame.firstHostTime,
                    outputPresentationLatency: Double(core.outputLatencyNanoseconds.load(
                        ordering: .acquiring)) / 1_000_000_000)
            }
        }
    }

    func startSession() throws {
        if let engine, engine.isRunning { return }
        if engine != nil { teardownGraph() }
        sessionFailure = nil
        let core = Core()
        let engine = AVAudioEngine()
        let node = AVAudioSourceNode(format: Self.sourceFormat,
                                     renderBlock: Self.makeRenderBlock(for: core))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.sourceFormat)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.source = node
        self.core = core
        graphGeneration &+= 1
        let generation = graphGeneration
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configurationChanged(graphGeneration: generation)
            }
        }
        outputLatency = engine.outputNode.outputPresentationLatency
        core.outputLatencyNanoseconds.store(Int64(outputLatency * 1_000_000_000),
                                            ordering: .releasing)
        let lane = DispatchQueue(label: "ai.pivotstudio.nextnotes.pcm-reverse",
                                 qos: .userInitiated)
        reverseLane = lane
        let timer = DispatchSource.makeTimerSource(queue: lane)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(2))
        timer.setEventHandler(handler: Self.makeReverseHandler(for: core))
        reverseTimer = timer
        timer.resume()
        receiptTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollReceipts()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func endSession() {
        teardownGraph()
        token = 0
        finished = false
        firstDelivered = false
        drainDelivered = false
        sessionFailure = nil
        AcousticEchoProcessor.shared.stopPlayback()
    }

    private func teardownGraph() {
        graphGeneration &+= 1
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        receiptTask?.cancel()
        receiptTask = nil
        reverseTimer?.cancel()
        reverseTimer = nil
        core?.requestedToken.store(0, ordering: .releasing)
        engine?.stop()
        // A cancelled DispatchSource can already be executing its handler.
        // Drain its serial lane before reset/new-session reference changes.
        reverseLane?.sync {}
        reverseLane = nil
        engine = nil
        source = nil
        core = nil
    }

    /// Lossless bounded backpressure. The producer suspends while the render
    /// FIFO is full; stop invalidates the token and wakes it with cancellation.
    func enqueue(_ buffer: AVAudioPCMBuffer, token requested: UInt64,
                 volume: Float) async throws {
        guard requested != 0 else { throw CancellationError() }
        // Recover an idle graph for the next clause. An active clause whose
        // graph stopped is failed instead of replaying any acknowledged PCM.
        if engine?.isRunning != true {
            if token == requested {
                let failure = failActivePlayback(.graphStopped)
                if let failure { onFailure?(failure.token, failure.reason) }
                throw RendererError.graphStopped
            }
            do { try startSession() }
            catch { throw RendererError.graphStartFailed(Self.bounded(error.localizedDescription)) }
        }
        guard let core else { throw sessionFailure ?? RendererError.graphStopped }
        if let failure = failure(for: core) { throw failure }
        if token != requested {
            token = requested
            finished = false
            firstDelivered = false
            drainDelivered = false
            core.requestedToken.store(requested, ordering: .releasing)
            let deadline = Date().addingTimeInterval(2)
            while core.renderedToken.load(ordering: .acquiring) != requested {
                try Task.checkCancellation()
                guard token == requested else { throw CancellationError() }
                if let failure = failure(for: core) { throw failure }
                guard engine?.isRunning == true else { throw RendererError.graphStopped }
                guard Date() < deadline else { throw RendererError.renderTimeout }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        if converterFormat != buffer.format {
            converterFormat = buffer.format
            converter = buffer.format == Self.sourceFormat ? nil
                : AVAudioConverter(from: buffer.format, to: Self.sourceFormat)
        }
        guard buffer.format == Self.sourceFormat || converter != nil else {
            throw RendererError.conversionFailed
        }
        let normalized = converter.map {
            AudioConversion.convert(buffer, to: Self.sourceFormat, using: $0)
        } ?? AudioConversion.copy(buffer)
        guard let input = normalized,
              let samples = input.floatChannelData?[0] else {
            throw RendererError.conversionFailed
        }
        let gain = max(0, min(1, volume))
        let count = Int(input.frameLength)
        var offset = 0
        let writeDeadline = Date().addingTimeInterval(2)
        // Scaling occurs off the render thread. Only the actual pulled,
        // already-scaled samples enter the reference FIFO.
        for index in 0..<count { samples[index] *= gain }
        while offset < count {
            try Task.checkCancellation()
            guard token == requested,
                  core.requestedToken.load(ordering: .acquiring) == requested else {
                throw CancellationError()
            }
            if let failure = failure(for: core) { throw failure }
            if !core.paused.load(ordering: .acquiring) {
                guard engine?.isRunning == true else { throw RendererError.graphStopped }
                guard Date() < writeDeadline else { throw RendererError.renderTimeout }
            }
            let accepted = core.output.write(samples.advanced(by: offset), count: count - offset)
            offset += accepted
            if offset < count { try await Task.sleep(for: .milliseconds(5)) }
        }
    }

    func finish(token requested: UInt64) {
        guard token == requested else { return }
        finished = true
        pollReceipts()
    }

    func pause(token requested: UInt64) {
        guard token == requested else { return }
        core?.paused.store(true, ordering: .releasing)
    }

    func resume(token requested: UInt64) {
        guard token == requested else { return }
        core?.paused.store(false, ordering: .releasing)
    }

    func stop(token requested: UInt64) {
        guard token == requested, let core else { return }
        token = 0
        finished = false
        core.paused.store(false, ordering: .releasing)
        core.requestedToken.store(0, ordering: .releasing)
        AcousticEchoProcessor.shared.stopPlayback()
    }

    private func pollReceipts() {
        guard token != 0, let core else { return }
        // A graph can stop after the producer called finish but before the
        // final render receipt. Do not leave the clause waiting forever.
        guard engine?.isRunning == true else {
            let failure = failActivePlayback(.graphStopped)
            if let failure { onFailure?(failure.token, failure.reason) }
            return
        }
        guard core.renderedToken.load(ordering: .acquiring) == token else { return }
        let now = mach_absolute_time()
        let latencyTicks = UInt64(outputLatency * core.hostTicksPerSecond)
        let first = core.firstSampleHostTime.load(ordering: .acquiring)
        if !firstDelivered, first > 0, now >= first &+ latencyTicks {
            firstDelivered = true
            onFirstSample?(token)
        }
        let last = core.lastSampleHostTime.load(ordering: .acquiring)
        if finished, !drainDelivered, core.output.availableToRead == 0,
           (last == 0 || now >= last &+ latencyTicks) {
            drainDelivered = true
            onDrained?(token)
        }
    }

    private struct PlaybackFailure {
        let token: UInt64
        let reason: String
    }

    private func failActivePlayback(_ error: RendererError) -> PlaybackFailure? {
        guard token != 0 else { return nil }
        let failedToken = token
        let alreadyDrained = drainDelivered
        let reason = Self.bounded(error.localizedDescription)
        core?.failureCode.store(error.failureCode, ordering: .releasing)
        core?.requestedToken.store(0, ordering: .releasing)
        token = 0
        finished = false
        firstDelivered = false
        drainDelivered = false
        sessionFailure = error
        // A completed clause no longer owns output. Rebuilding an idle graph
        // must not retrospectively turn its completion into an interruption.
        return alreadyDrained ? nil : PlaybackFailure(token: failedToken, reason: reason)
    }

    private func configurationChanged(graphGeneration: UInt64) {
        guard graphGeneration == self.graphGeneration, engine != nil else { return }
        let failure = failActivePlayback(.graphConfigurationChanged)
        teardownGraph()
        do {
            try startSession()
        } catch {
            let reason = Self.bounded(error.localizedDescription)
            sessionFailure = .graphStartFailed(reason)
            Log.agent.error("Pocket sourceFailure graph restart failed: \(reason, privacy: .public)")
        }
        if let failure { onFailure?(failure.token, failure.reason) }
    }

    private func failure(for core: Core) -> RendererError? {
        switch core.failureCode.load(ordering: .acquiring) {
        case RendererError.FailureCode.graphStopped.rawValue: return .graphStopped
        case RendererError.FailureCode.graphConfigurationChanged.rawValue: return .graphConfigurationChanged
        case RendererError.FailureCode.renderTimeout.rawValue: return .renderTimeout
        default: return nil
        }
    }

    private static func bounded(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return String(String.UnicodeScalarView(scalars.prefix(160)))
    }

    private enum RendererError: LocalizedError {
        enum FailureCode: UInt8 {
            case graphStopped = 1
            case graphConfigurationChanged = 2
            case renderTimeout = 3
        }

        case conversionFailed
        case graphStopped
        case graphConfigurationChanged
        case renderTimeout
        case graphStartFailed(String)

        var failureCode: UInt8 {
            switch self {
            case .graphStopped, .graphStartFailed: return FailureCode.graphStopped.rawValue
            case .graphConfigurationChanged: return FailureCode.graphConfigurationChanged.rawValue
            case .renderTimeout: return FailureCode.renderTimeout.rawValue
            case .conversionFailed: return 0
            }
        }

        var errorDescription: String? {
            switch self {
            case .conversionFailed: return "Unable to convert voice PCM to the speaker format."
            case .graphStopped: return "The voice output graph stopped before playback completed."
            case .graphConfigurationChanged: return "The voice output graph changed configuration during playback."
            case .renderTimeout: return "Voice PCM remained queued after the output graph stopped making progress."
            case .graphStartFailed(let reason): return "Unable to restart the voice output graph: \(reason)"
            }
        }
    }
}
