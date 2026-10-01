import Darwin
import Foundation

/// Input to the existing session's health tick. No additional owner, timer or store.
struct MeetingDiskCapacity: Sendable {
    var immediateBytes: Int64?
    var importantBytes: Int64?

    static func current(at url: URL) -> Self {
        var filesystem = statfs()
        let available = url.withUnsafeFileSystemRepresentation { path -> Int64? in
            guard let path else { return nil }
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            guard fstatfs(descriptor, &filesystem) == 0 else { return nil }
            return Int64(clamping: filesystem.f_bavail) * Int64(filesystem.f_bsize)
        }
        return Self(immediateBytes: available, importantBytes: nil)
    }
}

enum MeetingHealthIssue: String, Sendable, Equatable {
    case storageLow, storageUnknown, memoryPressure, microphoneStalled, systemStalled, systemUnavailable
    case savingStalled, captureGap, savedAudioGap, audioWriteFailure, transcriptWriteFailure, metadataWriteFailure

    var message: String {
        switch self {
        case .storageLow: "Your Mac is low on storage. This meeting may stop saving."
        case .storageUnknown: "Available storage could not be checked. Check that this meeting is saving."
        case .memoryPressure: "Your Mac is running low on memory. Some meeting features may pause."
        case .microphoneStalled: "Your microphone stopped reaching this meeting. Some speech may be missing."
        case .systemStalled: "Other voices stopped reaching this meeting. Some speech may be missing."
        case .systemUnavailable: "Other voices could not be recorded. This meeting may be missing part of the conversation."
        case .savingStalled: "This meeting's recording is falling behind. Some speech may be missing."
        case .captureGap: "Some speech was missed. This meeting's transcript may have gaps."
        case .savedAudioGap: "Some speech is missing from this recording. The live transcript may still contain it."
        case .audioWriteFailure: "This meeting's recording stopped saving. Check your Mac's storage."
        case .transcriptWriteFailure: "This meeting's transcript stopped saving. Check your Mac's storage."
        case .metadataWriteFailure: "This meeting's progress stopped saving. Some changes may be lost if the app closes."
        }
    }

    var isCaptureFailure: Bool {
        switch self {
        case .microphoneStalled, .systemStalled, .systemUnavailable, .captureGap: true
        default: false
        }
    }
}

struct MeetingHealthInput: Sendable {
    var now: Date
    var beganAt: Date
    var disk: MeetingDiskCapacity
    var memoryIsTight: Bool
    var lastMicAt: Date?
    var lastSystemAt: Date?
    var expectsSystem: Bool
    var writerPresent: Bool
    var writerFailed: Bool
    var lastWriteProgressAt: Date?
}

enum MeetingResourceHealth {
    /// Reuses the five-second transcript persistence cadence. Checks are detached
    /// from capture; this is neither a startup delay nor an audio callback wait.
    static let interval = TranscriptSaveThrottle.interval
    /// Three observations cover the writer's existing five-second track allowance
    /// and delivery jitter. Silence still supplies buffers and never triggers this.
    static let stallInterval = interval * 3

    static func issues(_ input: MeetingHealthInput) -> [MeetingHealthIssue] {
        var result: [MeetingHealthIssue] = []
        let free = input.disk.immediateBytes
        if let free {
            // The existing temporary-retention guard supplies headroom, not a claim
            // that a given amount of disk guarantees system paging will succeed.
            if free < MeetingStore.minimumFreeBytesForRetention { result.append(.storageLow) }
        } else { result.append(.storageUnknown) }
        if input.memoryIsTight { result.append(.memoryPressure) }
        if input.writerFailed { result.append(.audioWriteFailure) }
        guard input.now.timeIntervalSince(input.beganAt) >= stallInterval else { return result }
        if input.now.timeIntervalSince(input.lastMicAt ?? input.beganAt) >= stallInterval {
            result.append(.microphoneStalled)
        }
        if input.expectsSystem,
           input.now.timeIntervalSince(input.lastSystemAt ?? input.beganAt) >= stallInterval {
            result.append(.systemStalled)
        }
        if input.writerPresent, !input.writerFailed,
           let mic = input.lastMicAt, input.now.timeIntervalSince(mic) < interval * 2,
           input.now.timeIntervalSince(input.lastWriteProgressAt ?? input.beganAt) >= stallInterval {
            result.append(.savingStalled)
        }
        return result
    }

    /// Counts only. A failed system query remains absent.
    static func swapBytes() -> (used: UInt64?, available: UInt64?) {
        var value = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &value, &size, nil, 0) == 0 else { return (nil, nil) }
        return (value.xsu_used, value.xsu_avail)
    }
}
