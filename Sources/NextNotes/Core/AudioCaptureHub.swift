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

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    /// Read from the audio thread under `lock`; mutated only from MainActor under `lock`.
    private nonisolated(unsafe) var slots: [Consumer: Slot] = [:]
    /// When true, engine start/stop is bookkeeping only — used by `runSelfTest`.
    private let probe: Bool

    private struct Slot {
        let worker: AudioCaptureDeliveryWorker
    }

    init(probe: Bool = false) {
        self.probe = probe
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
        let converter: AVAudioConverter?
        if probe {
            converter = nil
        } else {
            let native = engine.inputNode.outputFormat(forBus: 0)
            converter = native == outputFormat
                ? nil
                : AVAudioConverter(from: native, to: outputFormat)
        }

        let worker = AudioCaptureDeliveryWorker(
            outputFormat: outputFormat,
            converter: converter,
            onBuffer: onBuffer,
            onLevel: onLevel,
            onOverflow: onOverflow ?? { _ in
                Log.audio.error("capture delivery backlog full — dropped audio buffer")
            }
        )

        lock.lock()
        slots[consumer]?.worker.stop()
        slots[consumer] = Slot(worker: worker)
        let needsStart = !isRunning
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
        guard !isRunning else { return }
        inputEngineStarts += 1
        if probe {
            isRunning = true
            return
        }

        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: native,
            block: Self.makeTapCallback(for: self)
        )
        engine.prepare()
        try engine.start()
        isRunning = true
        Log.audio.info("capture hub started — native \(native.sampleRate)Hz · shared input")
    }

    private func stopEngine() {
        guard isRunning else { return }
        if !probe {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
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
        { [weak hub] buffer, _ in hub?.fanOut(buffer) }
    }

    /// Copy the tap buffer, then convert/copy once per consumer. Model work stays
    /// off this thread — callbacks only enqueue.
    nonisolated private func fanOut(_ buffer: AVAudioPCMBuffer) {
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
            _ = slot.worker.enqueue(source: ownedSource, level: level)
        }
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
    func enqueue(source: AVAudioPCMBuffer, level: Float) -> Bool {
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

        let item = Item(source: source, level: level)
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
        onBuffer(AudioChunk(buffer: delivered))
    }
}

extension AudioCaptureHub {
    /// Structural probe of the fan-out owner. Never calls `RunLog.record`.
    ///
    /// Exposed by `--selftest-capture` in `NextNotesApp.runRequestedSelfTest`.
    /// ```
    @discardableResult
    static func runSelfTest() async -> Bool {
        var failures: [String] = []

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
                    delivered.append(AudioConversion.samples(of: chunk.buffer).first ?? -1)
                    Thread.sleep(forTimeInterval: 0.01)
                },
                onOverflow: { count in delivered.overflow(count) }
            )
            for index in 0..<32 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32) else { break }
                buffer.frameLength = 32
                buffer.floatChannelData?[0].initialize(repeating: Float(index), count: 32)
                hub.fanOut(buffer)
            }
            try? await Task.sleep(for: .milliseconds(250))
            let report = delivered.snapshot()
            if report.values.isEmpty {
                failures.append("delivery worker produced no callback")
            }
            if report.values != report.values.sorted() {
                failures.append("delivery worker reordered buffers")
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

private final class CaptureSelfTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []
    private var overflowCount = 0
    private var latestOverflow = 0

    func append(_ value: Float) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func overflow(_ count: Int) {
        lock.lock()
        overflowCount += 1
        latestOverflow = max(latestOverflow, count)
        lock.unlock()
    }

    func snapshot() -> (values: [Float], overflow: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (values, max(overflowCount, latestOverflow))
    }
}
