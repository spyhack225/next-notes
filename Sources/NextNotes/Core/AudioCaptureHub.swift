import AVFoundation
import Foundation

/// Single owner of the microphone input node.
///
/// Dictation, meetings, wake KWS and the agent all subscribe here. Each consumer
/// receives its own **copy** of every buffer — never the tap's borrowed storage —
/// so wake can stay alive while a meeting records without a second
/// `AVAudioEngine` fighting for the input node.
///
/// System audio stays on `SystemAudioCapture`. Meetings remain two tracks.
@MainActor
final class AudioCaptureHub {
    static let shared = AudioCaptureHub()

    enum Consumer: Hashable, Sendable {
        case wake
        case dictation
        case meeting
        case agent
        /// Anonymous clients that still construct `AudioCapture` (calibrator, probes).
        case client(UUID)
    }

    /// True while the shared input engine is running.
    private(set) var isRunning = false
    /// How many times the input engine has been started. Overlapping subscribers
    /// must not increment this above one until a full stop.
    private(set) var inputEngineStarts = 0

    private var engine = AVAudioEngine()
    private var sinkNode: AVAudioSinkNode?
    private var sinkRing: AudioSinkCaptureRing?
    private var configurationObserver: NSObjectProtocol?
    private var configurationGeneration = 0
    private let lock = NSLock()
    /// Read from the audio thread under `lock`; mutated only from MainActor under `lock`.
    private nonisolated(unsafe) var slots: [Consumer: Slot] = [:]
    /// When true, engine start/stop is bookkeeping only — used by `runSelfTest`.
    private let probe: Bool
    /// Opt-in hardware-sized microphone callbacks. The existing input tap
    /// remains the default until microphone, dictation, and rapid-turn probes
    /// validate this graph on the machine's actual input route.
    private var sinkSelected: Bool {
        !probe && (CommandLine.arguments.contains("--capture-sink")
            || CommandLine.arguments.contains("--selftest-microphone-sink"))
    }

    private struct Slot {
        let outputFormat: AVAudioFormat
        let onBuffer: @Sendable (AudioChunk) -> Void
        let onLevel: @Sendable (Float) -> Void
        let onOverflow: @Sendable (Int) -> Void
        var worker: AudioCaptureDeliveryWorker
    }

    init(probe: Bool = false) {
        self.probe = probe
        if !probe { observeEngineConfiguration() }
    }

    private func observeEngineConfiguration() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationGeneration &+= 1
        let generation = configurationGeneration
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // The notification can arrive on an internal audio queue. Apple warns not
            // to destroy the engine synchronously in this callback.
            Task { @MainActor [weak self] in
                guard let self, self.configurationGeneration == generation else { return }
                self.recoverAfterConfigurationChange()
            }
        }
    }

    private func recoverAfterConfigurationChange() {
        let subscribers = activeConsumers.count
        Log.audio.info("capture hub configuration changed — rebuilding for \(subscribers) consumer(s)")
        if !probe {
            engine.inputNode.removeTap(onBus: 0)
            sinkRing?.stop()
            engine.stop()
            sinkRing = nil
            sinkNode = nil
        }
        isRunning = false
        engine = AVAudioEngine()
        if !probe { observeEngineConfiguration() }
        guard subscribers > 0 else { return }
        restartSubscribers()
    }

    private func restartSubscribers() {
        do {
            try rebuildWorkers()
            try startEngine()
        } catch {
            Log.audio.error("capture hub restart failed: \(error.localizedDescription, privacy: .public)")
            let generation = configurationGeneration
            Task { @MainActor [weak self] in
                for delay in [0.5, 2.0, 5.0] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, self.configurationGeneration == generation,
                          !self.activeConsumers.isEmpty, !self.isRunning else { return }
                    do {
                        try self.rebuildWorkers()
                        try self.startEngine()
                        return
                    } catch {
                        Log.audio.error("capture hub retry failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    private func makeWorker(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onOverflow: @escaping @Sendable (Int) -> Void
    ) throws -> AudioCaptureDeliveryWorker {
        let converter: AVAudioConverter?
        if probe {
            converter = nil
        } else {
            let native = engine.inputNode.outputFormat(forBus: 0)
            guard native.sampleRate > 0, native.channelCount > 0 else {
                throw TranscriptionError.noAudioFormat
            }
            if native == outputFormat {
                converter = nil
            } else {
                guard let created = AVAudioConverter(from: native, to: outputFormat) else {
                    throw TranscriptionError.noAudioFormat
                }
                converter = created
            }
        }
        return AudioCaptureDeliveryWorker(
            outputFormat: outputFormat,
            converter: converter,
            onBuffer: onBuffer,
            onLevel: onLevel,
            onOverflow: onOverflow
        )
    }

    private func rebuildWorkers() throws {
        lock.lock()
        let previous = slots
        lock.unlock()
        var replacements: [Consumer: Slot] = [:]
        for (consumer, slot) in previous {
            let worker = try makeWorker(
                outputFormat: slot.outputFormat,
                onBuffer: slot.onBuffer,
                onLevel: slot.onLevel,
                onOverflow: slot.onOverflow
            )
            replacements[consumer] = Slot(
                outputFormat: slot.outputFormat,
                onBuffer: slot.onBuffer,
                onLevel: slot.onLevel,
                onOverflow: slot.onOverflow,
                worker: worker
            )
        }
        lock.lock()
        for slot in slots.values { slot.worker.stop() }
        slots = replacements
        lock.unlock()
    }

    func isSubscribed(_ consumer: Consumer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return slots[consumer] != nil
    }

    var activeConsumers: Set<Consumer> {
        lock.lock()
        defer { lock.unlock() }
        return Set(slots.keys)
    }

    /// Register a consumer. Starts the shared input engine on the first subscriber.
    func subscribe(
        _ consumer: Consumer,
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void = { _ in },
        onOverflow: (@Sendable (Int) -> Void)? = nil
    ) throws {
        // A device change can stop AVAudioEngine before its notification is handled.
        // Rebuild every existing converter before adding this new subscriber.
        if !probe && !activeConsumers.isEmpty && !engine.isRunning {
            recoverAfterConfigurationChange()
        }
        let overflow = onOverflow ?? { _ in
            Log.audio.error("capture delivery backlog full — dropped audio buffer")
        }
        let worker = try makeWorker(
            outputFormat: outputFormat,
            onBuffer: onBuffer,
            onLevel: onLevel,
            onOverflow: overflow
        )

        lock.lock()
        slots[consumer]?.worker.stop()
        slots[consumer] = Slot(
            outputFormat: outputFormat,
            onBuffer: onBuffer,
            onLevel: onLevel,
            onOverflow: overflow,
            worker: worker
        )
        let needsStart = !isRunning || (!probe && !engine.isRunning)
        lock.unlock()

        if needsStart {
            do {
                try startEngine()
            } catch {
                lock.lock()
                slots[consumer] = nil
                lock.unlock()
                throw error
            }
        }
    }

    /// Drop a consumer. Stops the shared input engine when the last one leaves.
    func unsubscribe(_ consumer: Consumer) {
        lock.lock()
        let slot = slots.removeValue(forKey: consumer)
        let shouldStop = slots.isEmpty && isRunning
        lock.unlock()
        slot?.worker.stop()
        if shouldStop {
            stopEngine()
        }
    }

    // MARK: - Engine

    private func startEngine() throws {
        guard !isRunning || (!probe && !engine.isRunning) else { return }
        inputEngineStarts += 1
        if probe {
            isRunning = true
            return
        }

        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        if sinkSelected {
            guard let ring = AudioSinkCaptureRing(format: native,
                deliver: Self.makeSinkDelivery(for: self),
                overflow: Self.makeSinkOverflow(for: self)) else {
                throw TranscriptionError.noAudioFormat
            }
            let sink = AVAudioSinkNode(receiverBlock: Self.makeSinkCallback(for: ring))
            engine.attach(sink)
            engine.connect(input, to: sink, format: native)
            sinkRing = ring
            sinkNode = sink
        } else {
            input.installTap(
                onBus: 0,
                bufferSize: 2048,
                format: native,
                block: Self.makeTapCallback(for: self)
            )
        }
        engine.prepare()
        do { try engine.start() }
        catch {
            sinkRing?.stop()
            engine.stop()
            if let sinkNode { engine.detach(sinkNode) }
            sinkRing = nil
            sinkNode = nil
            throw error
        }
        isRunning = true
        Log.audio.info("capture hub started — native \(native.sampleRate)Hz · \(self.sinkSelected ? "sink" : "tap") shared input")
    }

    private func stopEngine() {
        guard isRunning else { return }
        if !probe {
            engine.inputNode.removeTap(onBus: 0)
            sinkRing?.stop()
            engine.stop()
            if let sinkNode { engine.detach(sinkNode) }
            sinkRing = nil
            sinkNode = nil
        }
        isRunning = false
        Log.audio.info("capture hub stopped")
    }

    // MARK: - Audio thread

    /// Construct the callback outside MainActor isolation. `installTap` invokes it on
    /// Core Audio's realtime queue; a closure formed in `startEngine()` inherits
    /// MainActor and traps there in release builds before `fanOut` can run.
    nonisolated private static func makeTapCallback(
        for hub: AudioCaptureHub
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [weak hub] buffer, time in
            hub?.fanOut(buffer, captureHostTime: time.isHostTimeValid ? time.hostTime : nil)
        }
    }

    /// AVAudioSinkNode calls this on Core Audio's realtime queue. Forming the
    /// closure in startEngine() would inherit MainActor isolation and trap.
    nonisolated private static func makeSinkCallback(
        for ring: AudioSinkCaptureRing
    ) -> AVAudioSinkNodeReceiverBlock {
        { timestamp, frames, inputData in
            ring.receive(timestamp, frames: frames, input: inputData)
            return noErr
        }
    }

    nonisolated private static func makeSinkDelivery(
        for hub: AudioCaptureHub
    ) -> @Sendable (AVAudioPCMBuffer, UInt64?) -> Void {
        { [weak hub] buffer, hostTime in
            hub?.fanOut(buffer, captureHostTime: hostTime)
        }
    }

    nonisolated private static func makeSinkOverflow(
        for hub: AudioCaptureHub
    ) -> @Sendable (Int) -> Void {
        { [weak hub] count in hub?.reportSourceOverflow(count) }
    }

    /// Copy the tap buffer, then convert/copy once per consumer. Model work stays
    /// off this thread — callbacks only enqueue.
    nonisolated private func fanOut(_ buffer: AVAudioPCMBuffer, captureHostTime: UInt64? = nil) {
        lock.lock()
        let snapshot = Array(slots.values)
        lock.unlock()
        guard !snapshot.isEmpty else { return }

        // AVAudioEngine reuses the tap buffer as soon as this returns.
        guard let ownedSource = AudioConversion.copy(buffer) else { return }
        let level = AudioConversion.level(of: ownedSource)

        for slot in snapshot {
            // Conversion and consumer work are deliberately outside the tap callback. The
            // callback only makes one owned copy and performs a bounded, non-blocking enqueue.
            _ = slot.worker.enqueue(source: ownedSource, level: level, captureHostTime: captureHostTime)
        }
    }

    nonisolated private func reportSourceOverflow(_ count: Int) {
        lock.lock()
        let callbacks = slots.values.map(\.onOverflow)
        lock.unlock()
        for callback in callbacks { callback(count) }
    }
}

/// Ordered, bounded delivery lane for one microphone consumer.
///
/// `AVAudioEngine` invokes the tap on a real-time thread. Allocating a converted buffer,
/// running a KWS model, or calling an arbitrary consumer on that thread can make the engine
/// miss its deadline. A serial DispatchQueue keeps each consumer's buffers ordered while the
/// small pending count puts a hard ceiling on memory when a model falls behind. Overflow is
/// coalesced and reported on a utility queue; the expensive work remains on the lane.
private final class AudioCaptureDeliveryWorker: @unchecked Sendable {
    /// Eight 2048-frame buffers is about one second at 16 kHz: enough to absorb a short model
    /// hiccup while making sustained overload visible instead of growing without bound.
    static let maxPending = 8

    private struct Item: @unchecked Sendable {
        let source: AVAudioPCMBuffer
        let level: Float
        let captureHostTime: UInt64?
    }

    private let queue = DispatchQueue(
        label: "ai.pivotstudio.nextnotes.audio-delivery",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let onBuffer: @Sendable (AudioChunk) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let onOverflow: @Sendable (Int) -> Void
    private var pending = 0
    private var isActive = true
    private var dropped = 0
    private var overflowReportScheduled = false

    init(
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter?,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onOverflow: @escaping @Sendable (Int) -> Void
    ) {
        self.outputFormat = outputFormat
        self.converter = converter
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onOverflow = onOverflow
    }

    /// Non-blocking from the audio callback. Returns false when this item was dropped.
    func enqueue(source: AVAudioPCMBuffer, level: Float, captureHostTime: UInt64? = nil) -> Bool {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return false
        }
        guard pending < Self.maxPending else {
            dropped += 1
            let count = dropped
            let report = !overflowReportScheduled
            overflowReportScheduled = true
            lock.unlock()
            if report {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let total = self.dropped
                    self.overflowReportScheduled = false
                    self.lock.unlock()
                    self.onOverflow(max(count, total))
                }
            }
            return false
        }
        pending += 1
        lock.unlock()

        let item = Item(source: source, level: level, captureHostTime: captureHostTime)
        queue.async { [weak self] in
            self?.deliver(item)
        }
        return true
    }

    func stop() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    private func deliver(_ item: Item) {
        defer {
            lock.lock()
            pending = max(0, pending - 1)
            lock.unlock()
        }

        lock.lock()
        let active = isActive
        lock.unlock()
        guard active else { return }

        let delivered: AVAudioPCMBuffer?
        if let converter {
            delivered = AudioConversion.convert(item.source, to: outputFormat, using: converter)
        } else {
            // A separate copy per consumer lets the callback retain its chunk safely and
            // preserves the old fan-out ownership guarantee.
            delivered = AudioConversion.copy(item.source)
        }
        guard let delivered else { return }

        lock.lock()
        let stillActive = isActive
        lock.unlock()
        guard stillActive else { return }
        onLevel(item.level)
        onBuffer(AudioChunk(buffer: delivered, captureHostTime: item.captureHostTime))
    }
}

extension AudioCaptureHub {
    /// Checks the real input tap and its 16 kHz delivery independently. A model-only
    /// capture probe cannot detect a microphone that stopped delivering after an OS or
    /// default-input change. Run as an app through LaunchServices for the real TCC grant.
    static func runLiveMicrophoneSelfTest() async -> (Bool, String) {
        guard await Permissions.requestMicrophone() else {
            return (false, "MICROPHONE_FAILED: microphone permission denied")
        }
        let native = shared.engine.inputNode.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0,
              let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
              ) else {
            return (false, "MICROPHONE_FAILED: input format unavailable")
        }

        let raw = LiveCaptureRecorder()
        let converted = LiveCaptureRecorder()
        let rawID = Consumer.client(UUID())
        let convertedID = Consumer.client(UUID())
        do {
            try shared.subscribe(rawID, outputFormat: native, onBuffer: { raw.record($0) })
            try shared.subscribe(convertedID, outputFormat: target, onBuffer: { converted.record($0) })
        } catch {
            shared.unsubscribe(rawID)
            shared.unsubscribe(convertedID)
            return (false, "MICROPHONE_FAILED: capture start: \(error.localizedDescription)")
        }
        try? await Task.sleep(for: .seconds(1))
        let beforeRestart = (raw.snapshot(), converted.snapshot())
        raw.reset()
        converted.reset()
        shared.recoverAfterConfigurationChange()
        try? await Task.sleep(for: .seconds(2))
        shared.unsubscribe(rawID)
        shared.unsubscribe(convertedID)
        let source = raw.snapshot()
        let output = converted.snapshot()
        let detail = "native \(Int(native.sampleRate))Hz \(source.buffers) buffers/\(source.samples) samples peak \(source.peak); 16kHz \(output.buffers) buffers/\(output.samples) samples peak \(output.peak)"
        let passed = beforeRestart.0.samples > 0 && beforeRestart.1.samples > 0
            && beforeRestart.0.peak > 0 && beforeRestart.1.peak > 0
            && source.samples > 0 && output.samples > 0
            && source.peak > 0 && output.peak > 0
        return (passed, "MICROPHONE_\(passed ? "OK" : "FAILED"): \(detail)")
    }

    /// Structural probe of the fan-out owner. Never calls `RunLog.record`.
    ///
    /// Exposed by `--selftest-capture` in `NextNotesApp.runRequestedSelfTest`.
    /// ```
    @discardableResult
    static func runSelfTest() async -> Bool {
        var failures = AudioSinkCaptureRing.selfTestFailures()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
        guard let format else {
            print("CAPTURE_WRONG: no 16 kHz format for probe")
            print("CAPTURE_FAILED")
            return false
        }

        let hub = AudioCaptureHub(probe: true)
        let sink: @Sendable (AudioChunk) -> Void = { _ in }
        let level: @Sendable (Float) -> Void = { _ in }

        do {
            try hub.subscribe(.wake, outputFormat: format, onBuffer: sink, onLevel: level)
            try hub.subscribe(.meeting, outputFormat: format, onBuffer: sink, onLevel: level)
        } catch {
            failures.append("subscribe failed: \(error.localizedDescription)")
        }

        if hub.inputEngineStarts != 1 {
            failures.append(
                "two input engines would start (engine starts=\(hub.inputEngineStarts))"
            )
        }

        // Exercise the actual asynchronous delivery lane. The handler deliberately runs
        // slowly while the tap submits more work than the bounded queue can hold: callbacks
        // must stay ordered and at least one item must be reported as dropped.
        let delivered = CaptureSelfTestRecorder()
        let consumer = Consumer.client(UUID())
        do {
            try hub.subscribe(
                consumer,
                outputFormat: format,
                onBuffer: { chunk in
                    delivered.append(AudioConversion.samples(of: chunk.buffer).first ?? -1,
                                     hostTime: chunk.captureHostTime)
                    Thread.sleep(forTimeInterval: 0.01)
                },
                onOverflow: { count in delivered.overflow(count) }
            )
            for index in 0..<32 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32) else { break }
                buffer.frameLength = 32
                buffer.floatChannelData?[0].initialize(repeating: Float(index), count: 32)
                hub.fanOut(buffer, captureHostTime: UInt64(index + 1000))
            }
            try? await Task.sleep(for: .milliseconds(250))
            let report = delivered.snapshot()
            if report.values.isEmpty {
                failures.append("delivery worker produced no callback")
            }
            if report.values != report.values.sorted() {
                failures.append("delivery worker reordered buffers")
            }
            if report.hostTimes != report.values.map({ UInt64($0) + 1000 }) {
                failures.append("delivery worker lost or reassigned microphone timestamps")
            }
            if report.overflow == 0 {
                failures.append("delivery worker accepted an unbounded backlog")
            }
        } catch {
            failures.append("delivery worker subscribe failed: \(error.localizedDescription)")
        }
        hub.unsubscribe(consumer)
        if !hub.isSubscribed(.wake) {
            failures.append("wake consumer disabled while meeting consumer is on")
        }
        if !hub.isSubscribed(.meeting) {
            failures.append("meeting consumer missing after subscribe")
        }

        // Dictation path must not leave the old hold latch set without a hub seat.
        WakeWordAudioMonitor.shared.beginHold()
        do {
            try hub.subscribe(.dictation, outputFormat: format, onBuffer: sink, onLevel: level)
        } catch {
            failures.append("dictation subscribe failed: \(error.localizedDescription)")
        }
        let holders = WakeWordAudioMonitor.shared.holders
        let wakeOnHub = hub.isSubscribed(.wake)
        if holders > 0 && !wakeOnHub {
            failures.append(
                "dictation start left wake holders=\(holders) with no hub subscription"
            )
        }
        // beginHold is a no-op now; holders must stay zero.
        if holders > 0 {
            failures.append("beginHold still increments holders (=\(holders))")
        }
        if hub.inputEngineStarts != 1 {
            failures.append(
                "dictation subscribe started a second input engine (starts=\(hub.inputEngineStarts))"
            )
        }

        // A route change must preserve all active subscribers while opening a fresh
        // engine. A cached isRunning flag used to leave wake alive on paper and dead
        // on the microphone after macOS stopped AVAudioEngine.
        hub.recoverAfterConfigurationChange()
        if hub.inputEngineStarts != 2 {
            failures.append("configuration change did not restart input engine")
        }
        if !hub.isSubscribed(.wake) || !hub.isSubscribed(.meeting)
            || !hub.isSubscribed(.dictation) {
            failures.append("configuration change lost a microphone subscriber")
        }

        hub.unsubscribe(.dictation)
        hub.unsubscribe(.meeting)
        hub.unsubscribe(.wake)
        WakeWordAudioMonitor.shared.endHold()

        for failure in failures {
            print("CAPTURE_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "CAPTURE_OK" : "CAPTURE_FAILED")
        return failures.isEmpty
    }
}

private final class LiveCaptureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var samples = 0
    private var peak: Float = 0

    func record(_ chunk: AudioChunk) {
        let values = AudioConversion.samples(of: chunk.buffer)
        lock.lock()
        buffers += 1
        samples += values.count
        for value in values { peak = max(peak, abs(value)) }
        lock.unlock()
    }

    func snapshot() -> (buffers: Int, samples: Int, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (buffers, samples, peak)
    }

    func reset() {
        lock.lock()
        buffers = 0
        samples = 0
        peak = 0
        lock.unlock()
    }
}

private final class CaptureSelfTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []
    private var hostTimes: [UInt64] = []
    private var overflowCount = 0
    private var latestOverflow = 0

    func append(_ value: Float, hostTime: UInt64? = nil) {
        lock.lock()
        values.append(value)
        hostTimes.append(hostTime ?? 0)
        lock.unlock()
    }

    func overflow(_ count: Int) {
        lock.lock()
        overflowCount += 1
        latestOverflow = max(latestOverflow, count)
        lock.unlock()
    }

    func snapshot() -> (values: [Float], overflow: Int, hostTimes: [UInt64]) {
        lock.lock()
        defer { lock.unlock() }
        return (values, max(overflowCount, latestOverflow), hostTimes)
    }
}
