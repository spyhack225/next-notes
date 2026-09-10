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

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false

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
    ) throws {
        guard !isRunning else { return }

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.outputFormat = outputFormat

        do {
            try createTap()
            try createAggregate()
            try startIO()
        } catch {
            // A half-built stack leaks a tap and an aggregate device that outlive the app's
            // interest in them, so unwind everything before rethrowing.
            teardown()
            throw error
        }

        isRunning = true
        let rate = tapFormat?.sampleRate ?? 0
        Log.systemAudio.info("system audio started — tap \(rate)Hz → engine \(outputFormat.sampleRate)Hz")
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
        Log.systemAudio.info("system audio stopped")
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

        onLevel?(AudioConversion.level(of: buffer))

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
enum SystemAudioError: LocalizedError {
    case ownProcessLookupFailed(OSStatus)
    case tapCreationFailed(OSStatus)
    case tapFormatUnavailable(OSStatus)
    case noOutputDevice(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

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
        }
    }
}
