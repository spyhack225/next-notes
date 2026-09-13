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
        let format: AVAudioFormat
        let onBuffer: @Sendable (AudioChunk) -> Void
        let onLevel: @Sendable (Float) -> Void
        /// Built on subscribe from the current native format. Audio-thread only.
        let converter: AVAudioConverter?
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
        onLevel: @escaping @Sendable (Float) -> Void = { _ in }
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

        lock.lock()
        slots[consumer] = Slot(
            format: outputFormat,
            onBuffer: onBuffer,
            onLevel: onLevel,
            converter: converter
        )
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
        slots[consumer] = nil
        let shouldStop = slots.isEmpty && isRunning
        lock.unlock()
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
        input.installTap(onBus: 0, bufferSize: 2048, format: native) { [weak self] buffer, _ in
            self?.fanOut(buffer)
        }
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

    /// Copy the tap buffer, then convert/copy once per consumer. Model work stays
    /// off this thread — callbacks only enqueue.
    nonisolated private func fanOut(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let snapshot = Array(slots.values)
        lock.unlock()
        guard !snapshot.isEmpty else { return }

        // AVAudioEngine reuses the tap buffer as soon as this returns.
        guard let source = AudioConversion.copy(buffer) else { return }
        let level = AudioConversion.level(of: source)

        for slot in snapshot {
            slot.onLevel(level)
            let delivered: AVAudioPCMBuffer?
            if let converter = slot.converter {
                delivered = AudioConversion.convert(source, to: slot.format, using: converter)
            } else if source.format == slot.format {
                // Separate copy per consumer — they may retain the buffer past this call.
                delivered = AudioConversion.copy(source)
            } else {
                // Probe slots skip converters; still deliver a copy of the source.
                delivered = AudioConversion.copy(source)
            }
            if let delivered {
                slot.onBuffer(AudioChunk(buffer: delivered))
            }
        }
    }
}

extension AudioCaptureHub {
    /// Structural probe of the fan-out owner. Never calls `RunLog.record`.
    ///
    /// Wire with `--selftest-capture` in `NextNotesApp.runRequestedSelfTest` when
    /// that file is free:
    /// ```
    /// if arguments.contains("--selftest-capture") {
    ///     Task { @MainActor in
    ///         await AudioCaptureHub.runSelfTest()
    ///         NSApp.terminate(nil)
    ///     }
    ///     return true
    /// }
    /// ```
    static func runSelfTest() async {
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
            return
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
    }
}
