import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac is playing — the other half of a meeting.
///
/// Deliberately not an extension of `AudioCapture`. `AVAudioEngine` cannot sit on a
/// private aggregate device built around a process tap, so this is the raw Core Audio
/// path: translate our own PID to a process object, describe a global stereo tap that
/// **excludes** us (otherwise the tap hears our own alert sounds and, once notes are
/// spoken back, itself), wrap the tap in a private aggregate device, and run an IOProc
/// on it. Teardown is the same list in reverse.
///
/// The grant is `NSAudioCaptureUsageDescription`, not Screen Recording, and there is no
/// query API for it — nor, it turns out, a usable failure. Without the grant every call
/// here still succeeds and the IOProc still runs at the right rate; the samples are simply
/// all zero, and the only trace is `Client is not granted access to the tap` from
/// `coreaudiod` in the unified log. That is why nothing in the app claims to know whether
/// system audio is permitted: the honest signal is the "Others" meter never moving, and
/// `--selftest-systemaudio` reports silence as its own result rather than as success.
final class SystemAudioCapture: @unchecked Sendable {
    /// The IO queue keeps the aggregate device's callback off the main thread; Core Audio
    /// still treats it as real-time, so the same copy-before-return rule applies.
    private let ioQueue = DispatchQueue(label: "ai.pivotstudio.nextnotes.systemaudio", qos: .userInitiated)
    /// HAL startup can synchronously wait on a device. Keep lifecycle calls away from the
    /// main actor so an unavailable or contended tap cannot freeze the app UI.
    private let lifecycleQueue = DispatchQueue(
        label: "ai.pivotstudio.nextnotes.systemaudio-lifecycle",
        qos: .userInitiated
    )
    private let stateLock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false
    private var isStarting = false
    private var isStopping = false
    private var cancelStart = false

    private enum StartOutcome: Sendable {
        case started
        case failed(SystemAudioError)
        case timedOut
    }

    /// One-shot completion shared by the bounded caller and lifecycle queue. HAL may outlive
    /// the timeout; only the first outcome resumes the waiting task.
    private final class StartCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<StartOutcome, Never>?
        private var completed = false

        init(_ continuation: CheckedContinuation<StartOutcome, Never>) {
            self.continuation = continuation
        }

        func finish(_ outcome: StartOutcome) -> Bool {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return false
            }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: outcome)
            return true
        }
    }

    private static let startTimeout: Duration = .seconds(5)
    /// Test-only seam for proving timeout/cancellation without touching Core Audio.
    nonisolated(unsafe) private static var startStackOverrideForTesting: (() throws -> Void)?
    nonisolated(unsafe) private static var startTimeoutOverrideForTesting: Duration?

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private nonisolated(unsafe) var tapFormat: AVAudioFormat?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?

    /// The format the tap produces, once started. Reported by the self-test.
    var currentTapFormat: AVAudioFormat? { tapFormat }

    // MARK: - Lifecycle

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        let startState = withStateLock { () -> Int in
            if isRunning { return 1 }
            if isStarting { return 2 }
            if isStopping { return 3 }
            isStarting = true
            cancelStart = false
            return 0
        }
        if startState == 1 { return }
        if startState == 2 {
            throw SystemAudioError.startAlreadyInFlight
        }
        if startState == 3 {
            throw SystemAudioError.startStopInFlight
        }

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.outputFormat = outputFormat

        let outcome = await withCheckedContinuation { continuation in
            let completion = StartCompletion(continuation)
            lifecycleQueue.async { [self] in
                performStart(completion)
            }
            // A task group would await a blocked HAL child before returning. The lifecycle
            // operation owns cleanup when AudioDeviceStart eventually returns instead.
            Task { [self] in
                try? await Task.sleep(for: Self.startTimeoutOverrideForTesting ?? Self.startTimeout)
                let shouldTimeout = withStateLock { () -> Bool in
                    guard isStarting else { return false }
                    cancelStart = true
                    return true
                }
                guard shouldTimeout else { return }
                _ = completion.finish(.timedOut)
                Log.systemAudio.error("system audio start timed out; awaiting HAL return for cleanup")
            }
        }

        switch outcome {
        case .started:
            let rate = tapFormat?.sampleRate ?? 0
            Log.systemAudio.info("system audio started — tap \(rate)Hz → engine \(outputFormat.sampleRate)Hz")
        case .failed(let error):
            throw error
        case .timedOut:
            throw SystemAudioError.deviceStartTimedOut
        }
    }

    func stop() {
        stateLock.lock()
        if isStarting {
            cancelStart = true
            stateLock.unlock()
            return
        }
        guard isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = false
        isStopping = true
        stateLock.unlock()
        lifecycleQueue.async { [self] in
            teardown()
            withStateLock { isStopping = false }
            Log.systemAudio.info("system audio stopped")
        }
    }

    /// Runs blocking HAL setup on `lifecycleQueue` and cleans up after timeout/cancellation.
    private func performStart(_ completion: StartCompletion) {
        do {
            if let override = Self.startStackOverrideForTesting {
                try override()
            } else {
                try createTap()
                try createAggregate()
                try startIO()
            }

            stateLock.lock()
            let cancelled = cancelStart
            if !cancelled { isRunning = true }
            isStarting = false
            stateLock.unlock()

            if cancelled {
                teardown()
                _ = completion.finish(.failed(.cancelled))
            } else {
                _ = completion.finish(.started)
            }
        } catch let error as SystemAudioError {
            teardown()
            stateLock.lock()
            isStarting = false
            stateLock.unlock()
            _ = completion.finish(.failed(error))
        } catch {
            teardown()
            stateLock.lock()
            isStarting = false
            stateLock.unlock()
            _ = completion.finish(.failed(.unknown(error.localizedDescription)))
        }
    }

    // MARK: - Core Audio stack

    private func createTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [try Self.ownProcessObject()])
        description.name = "Next Notes meeting tap"
        description.uuid = UUID()
        // Private: visible only to this process, so it never appears in Audio MIDI Setup.
        description.isPrivate = true
        // Unmuted: the user must keep hearing the meeting they are in.
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw SystemAudioError.tapCreationFailed(status)
        }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard formatStatus == noErr, let tapFormat = AVAudioFormat(streamDescription: &format) else {
            throw SystemAudioError.tapFormatUnavailable(formatStatus)
        }
        self.tapFormat = tapFormat

        if let outputFormat, tapFormat != outputFormat {
            converter = AVAudioConverter(from: tapFormat, to: outputFormat)
        }
    }

    private func createAggregate() throws {
        // The tap has no clock of its own. The current default output device provides one,
        // which is also the device whose mix we want, so it is both the main sub-device and
        // the only member of the sub-device list.
        let outputUID = try Self.defaultOutputDeviceUID()
        let uid = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Next Notes Meeting Capture",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID(),
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw SystemAudioError.aggregateCreationFailed(status)
        }
        aggregateID = device
    }

    private func startIO() throws {
        var created: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&created, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard status == noErr, let created else {
            throw SystemAudioError.ioProcCreationFailed(status)
        }
        procID = created

        let startStatus = AudioDeviceStart(aggregateID, created)
        guard startStatus == noErr else {
            throw SystemAudioError.deviceStartFailed(startStatus)
        }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        converter = nil
        tapFormat = nil
        outputFormat = nil
        onBuffer = nil
        onLevel = nil
    }

    // MARK: - Audio thread

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData)
        else { return }

        let level = AudioConversion.level(of: buffer)
        // Without the grant every sample is zero, so any level at all is proof of it.
        if level > 0 { Permissions.noteSystemAudioHeard() }
        onLevel?(level)

        guard let outputFormat else { return }

        // `bufferListNoCopy` borrows Core Audio's storage, which is recycled the moment
        // this callback returns — so nothing downstream may ever see this buffer directly.
        guard let converter else {
            if let copy = AudioConversion.copy(buffer) {
                onBuffer?(AudioChunk(buffer: copy))
            }
            return
        }

        guard let converted = AudioConversion.convert(buffer, to: outputFormat, using: converter) else {
            return
        }
        onBuffer?(AudioChunk(buffer: converted))
    }

    // MARK: - Core Audio lookups

    private func tapUID() -> String {
        var uid = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? uid as String : ""
    }

    /// Our own process object, so the tap can exclude it.
    private static func ownProcessObject() throws -> AudioObjectID {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object
        )
        guard status == noErr, object != kAudioObjectUnknown else {
            throw SystemAudioError.ownProcessLookupFailed(status)
        }
        return object
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            0,
            nil,
            &size,
            &device
        )
        guard deviceStatus == noErr, device != kAudioObjectUnknown else {
            throw SystemAudioError.noOutputDevice(deviceStatus)
        }

        var uid = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard uidStatus == noErr else {
            throw SystemAudioError.noOutputDevice(uidStatus)
        }
        return uid as String
    }
}

/// Why system audio couldn't be captured.
///
/// Every case carries the raw `OSStatus`: the TCC refusal is not a distinct error code,
/// so the number is the only thing that distinguishes "you said no" from "the audio
/// hardware is busy" when a user reports this.
enum SystemAudioError: LocalizedError, Sendable, Equatable {
    case ownProcessLookupFailed(OSStatus)
    case tapCreationFailed(OSStatus)
    case tapFormatUnavailable(OSStatus)
    case noOutputDevice(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case startAlreadyInFlight
    case startStopInFlight
    case deviceStartTimedOut
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .ownProcessLookupFailed(let status):
            return "Core Audio didn't recognise this process (\(status))."
        case .tapCreationFailed(let status):
            return "Couldn't listen to system audio (\(status)). Allow Next Notes in "
                + "System Settings ▸ Privacy & Security ▸ Audio Recording."
        case .tapFormatUnavailable(let status):
            return "The system-audio tap didn't report a format (\(status))."
        case .noOutputDevice(let status):
            return "No audio output device to record from (\(status))."
        case .aggregateCreationFailed(let status):
            return "Couldn't create the recording device (\(status))."
        case .ioProcCreationFailed(let status):
            return "Couldn't attach to the recording device (\(status))."
        case .deviceStartFailed(let status):
            return "Couldn't start the recording device (\(status))."
        case .startAlreadyInFlight:
            return "A system-audio recording start is already in progress."
        case .startStopInFlight:
            return "A system-audio recording stop is still in progress."
        case .deviceStartTimedOut:
            return "The system-audio recording device did not start within 5 seconds."
        case .cancelled:
            return "System-audio recording start was cancelled."
        case .unknown(let message):
            return message
        }
    }
}

extension SystemAudioCapture {
    /// Deterministically proves the startup timeout and late cleanup contract without
    /// touching the machine's audio devices. The blocked lifecycle operation is released
    /// only after the caller has already observed the timeout.
    @discardableResult
    static func runStartTimeoutSelfTest() async -> Bool {
        var failures: [String] = []
        let release = DispatchSemaphore(value: 0)
        let previousOverride = startStackOverrideForTesting
        let previousTimeout = startTimeoutOverrideForTesting
        startStackOverrideForTesting = {
            release.wait()
        }
        startTimeoutOverrideForTesting = .milliseconds(100)
        defer {
            startStackOverrideForTesting = previousOverride
            startTimeoutOverrideForTesting = previousTimeout
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            print("SYSTEM_AUDIO_TIMEOUT_FAILED: no 16 kHz format")
            return false
        }

        let capture = SystemAudioCapture()
        let started = ContinuousClock.now
        let startTask = Task {
            do {
                try await capture.start(
                    outputFormat: format,
                    onBuffer: { _ in },
                    onLevel: { _ in }
                )
                return false
            } catch let error as SystemAudioError {
                return error == .deviceStartTimedOut
            } catch {
                return false
            }
        }
        let timedOut = await startTask.value
        let elapsed = started.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        if !timedOut {
            failures.append("startup did not return the expected timeout")
        }
        if elapsedSeconds > 1.0 {
            failures.append(String(format: "timeout returned after %.3fs", elapsedSeconds))
        }

        // Stop must only set the cancellation marker while the lifecycle operation is
        // blocked. Once released, that operation must tear down and clear every resource.
        capture.stop()
        release.signal()
        await capture.waitForLifecycleIdle()
        if capture.isRunning {
            failures.append("late startup left system-audio capture running")
        }
        if capture.tapID != kAudioObjectUnknown
            || capture.aggregateID != kAudioObjectUnknown
            || capture.procID != nil {
            failures.append("late startup left a tap, aggregate device, or IOProc alive")
        }

        for failure in failures {
            print("SYSTEM_AUDIO_TIMEOUT_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "SYSTEM_AUDIO_TIMEOUT_OK" : "SYSTEM_AUDIO_TIMEOUT_FAILED")
        return failures.isEmpty
    }

    private func waitForLifecycleIdle() async {
        await withCheckedContinuation { continuation in
            lifecycleQueue.async {
                continuation.resume()
            }
        }
    }
}
