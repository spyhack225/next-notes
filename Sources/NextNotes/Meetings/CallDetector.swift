import AppKit
import CoreAudio
import Foundation
import Observation

/// Notices that the Mac is on a call, so a meeting can be armed for something nobody put on
/// a calendar.
///
/// The signal is Core Audio's process list — the same state behind the orange microphone dot
/// in the menu bar. `kAudioHardwarePropertyProcessObjectList` enumerates every process with
/// audio, and each answers `kAudioProcessPropertyIsRunningInput`, `…IsRunningOutput`,
/// `…PID` and `…BundleID`. Measured on this machine on 2026-09-09: enumeration needs **no**
/// TCC grant — an unsigned ad-hoc CLI with no permissions read all 36 processes — and the
/// flags are live per process, with `afplay` appearing and disappearing around one sound.
///
/// What it means is `CallPolicy`'s business, not this file's. Everything here is the part a
/// self-test cannot reach: the subscription, the property reads and the name resolution.
@MainActor
@Observable
final class CallDetector {
    static let shared = CallDetector()

    /// A call the app is prepared to act on — settled, not a flicker.
    struct CallActivity: Sendable, Hashable {
        var bundleID: String?
        var pid: pid_t
        var displayName: String
        var since: Date
        var hasInput: Bool
        var hasOutput: Bool
    }

    /// What the rest of the app observes. `nil` means nothing is on a call.
    private(set) var current: CallActivity?

    /// Called when a settled call begins, ends, or turns out to be a different app.
    ///
    /// A closure rather than the scheduler observing `current`, for two reasons: `current`
    /// is rewritten on every pass to carry the live flags, so an observer would wake on
    /// changes that are not events, and this file has no business importing the meeting
    /// machinery. `MeetingScheduler` sets it. It fires on the main actor.
    var onChange: ((CallActivity?) -> Void)?

    /// The backstop interval. Slow on purpose — see `start()`.
    static let pollInterval: TimeInterval = 5

    @ObservationIgnored private var debounce: CallPolicy.DebounceState = .quiet
    @ObservationIgnored private var lastEvaluation = Date()
    @ObservationIgnored private var poll: Task<Void, Never>?

    /// Listener blocks have to be handed back to Core Audio to be removed, so each one is
    /// kept against the object it was installed on.
    @ObservationIgnored private var listListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var flagListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Subscribes to the process list and starts the backstop poll.
    ///
    /// Both, not one or the other. A property listener is what makes detection feel
    /// immediate: polling fast enough to notice a ringing call within a second or two would
    /// wake the CPU sixty times a minute for a value that changes a handful of times a day,
    /// on a laptop. But the flags are also the *only* thing that changes when a call starts
    /// inside a process that already had audio — no process is added or removed — and a
    /// per-process listener can only be installed on processes that exist at the time. So a
    /// 5 s poll runs underneath, which bounds how long a missed notification can hide a call
    /// and costs one pass over an array of about forty object ids.
    func start() {
        guard poll == nil else { return }

        subscribeToProcessList()
        refreshFlagListeners()
        evaluate()

        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                self?.refreshFlagListeners()
                self?.evaluate()
            }
        }
        Log.calls.info("call detector running")
    }

    func stop() {
        poll?.cancel()
        poll = nil
        unsubscribeFromProcessList()
        for (object, _) in flagListeners { removeFlagListener(on: object) }
        flagListeners = [:]
        debounce = .quiet
        // Through the same door a real ending uses. Switching detection off while a call is
        // being recorded has to retire that recording, and the scheduler only hears about
        // endings here.
        if current != nil {
            current = nil
            onChange?(nil)
        }
    }

    // MARK: - Reading the world

    /// Every process Core Audio knows about that is currently holding input or output.
    ///
    /// Also the self-test's table, which is why it is not private and returns everything
    /// rather than only what passes `CallPolicy`.
    static func audioProcesses() -> [CallPolicy.AudioProcess] {
        processObjects().compactMap { object in
            let input = flag(kAudioProcessPropertyIsRunningInput, on: object)
            let output = flag(kAudioProcessPropertyIsRunningOutput, on: object)
            guard input || output else { return nil }
            guard let pid = processPID(of: object) else { return nil }
            let bundleID = processBundleID(of: object)
            return CallPolicy.AudioProcess(
                pid: pid,
                bundleID: bundleID,
                name: displayName(pid: pid, bundleID: bundleID),
                isRunningInput: input,
                isRunningOutput: output
            )
        }
    }

    /// One evaluation pass. Not private so a self-test — and, in Phase 2, the scheduler —
    /// can drive it without waiting for the poll.
    func evaluate(now: Date = Date()) {
        let elapsed = now.timeIntervalSince(lastEvaluation)
        lastEvaluation = now

        let ownPID = getpid()
        let processes = Self.audioProcesses()
        remember(processes, ownPID: ownPID)
        let candidate = CallPolicy.candidate(
            in: processes,
            ownPID: ownPID,
            preferring: debounce.subject?.pid
        )
        apply(CallPolicy.next(debounce, observing: candidate, elapsed: elapsed), now: now)
    }

    /// Notes every app seen holding the microphone, which is what the Meetings settings tab
    /// lists.
    ///
    /// The list has to come from what has actually happened on this Mac. The alternative is
    /// a table of bundle identifiers written here — which would be wrong the day someone
    /// installs a conferencing app nobody here has heard of, and would make the user type
    /// `us.zoom.xos` to fix it.
    ///
    /// The microphone alone, not a settled call: `CallPolicy.isMicrophoneApp` says why, and
    /// holds every filter this rule needs.
    private func remember(_ processes: [CallPolicy.AudioProcess], ownPID: pid_t) {
        for process in processes where CallPolicy.isMicrophoneApp(process, ownPID: ownPID) {
            guard let bundleID = process.bundleID else { continue }
            // Settings writes through to defaults on every assignment, and this runs on
            // every pass of a 5 s poll, so only an actual change is worth making.
            guard Settings.shared.callAppsSeen[bundleID] != process.name else { continue }
            Settings.shared.rememberCallApp(bundleID: bundleID, name: process.name)
            Log.calls.info("""
                remembering \(process.name, privacy: .public) \
                (\(bundleID, privacy: .public)) as an app that uses the microphone
                """)
        }
    }

    private func apply(_ state: CallPolicy.DebounceState, now: Date) {
        debounce = state
        let previous = current?.pid

        defer { if previous != current?.pid { onChange?(current) } }

        guard let call = state.call else {
            if let ended = current {
                Log.calls.info("call ended — \(ended.displayName, privacy: .public)")
                current = nil
            }
            return
        }

        // `since` is when the call started, not when this pass ran, so a flicker that
        // dropped through `.fading` and came back must not reset it.
        if let existing = current, existing.pid == call.pid {
            current = CallActivity(
                bundleID: call.bundleID,
                pid: call.pid,
                displayName: call.name,
                since: existing.since,
                hasInput: call.isRunningInput,
                hasOutput: call.isRunningOutput
            )
            return
        }

        current = CallActivity(
            bundleID: call.bundleID,
            pid: call.pid,
            displayName: call.name,
            since: now,
            hasInput: call.isRunningInput,
            hasOutput: call.isRunningOutput
        )
        let identity = call.bundleID ?? "no bundle id"
        Log.calls.info(
            "call detected — \(call.name, privacy: .public) (\(identity, privacy: .public), pid \(call.pid))"
        )
    }

    // MARK: - Subscription

    private func subscribeToProcessList() {
        var address = Self.listAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Hop rather than `MainActor.assumeIsolated`: the listener runs on whatever
            // queue Core Audio was given, and assuming isolation asserts rather than checks.
            Task { @MainActor in
                self?.refreshFlagListeners()
                self?.evaluate()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.listenerQueue,
            block
        )
        guard status == noErr else {
            Log.calls.error("could not watch the audio process list — OSStatus \(status)")
            return
        }
        listListener = block
    }

    private func unsubscribeFromProcessList() {
        guard let listListener else { return }
        var address = Self.listAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.listenerQueue,
            listListener
        )
        self.listListener = nil
    }

    /// Installs a flag listener on every process that has appeared and removes the ones
    /// whose process has gone. A process object that no longer exists cannot be unsubscribed
    /// from, so the removal is best-effort and the dictionary is the record.
    private func refreshFlagListeners() {
        let live = Set(Self.processObjects())

        for object in flagListeners.keys where !live.contains(object) {
            removeFlagListener(on: object)
        }

        for object in live where flagListeners[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.evaluate() }
            }
            var installed = false
            for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                var address = Self.processAddress(selector)
                let status = AudioObjectAddPropertyListenerBlock(
                    object, &address, Self.listenerQueue, block
                )
                if status == noErr { installed = true }
            }
            if installed { flagListeners[object] = block }
        }
    }

    private func removeFlagListener(on object: AudioObjectID) {
        guard let block = flagListeners.removeValue(forKey: object) else { return }
        for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
            var address = Self.processAddress(selector)
            AudioObjectRemovePropertyListenerBlock(object, &address, Self.listenerQueue, block)
        }
    }

    /// Core Audio calls listeners on this queue; each one immediately hops to the main actor,
    /// so nothing but the hop happens here.
    private static let listenerQueue = DispatchQueue(
        label: "ai.pivotstudio.nextnotes.calls",
        qos: .utility
    )

    // MARK: - Core Audio property reads

    private static let listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func processAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func processObjects() -> [AudioObjectID] {
        var address = listAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown),
                                      count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        )
        guard status == noErr else { return [] }
        return objects.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private static func flag(_ selector: AudioObjectPropertySelector, on object: AudioObjectID) -> Bool {
        var address = processAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func processPID(of object: AudioObjectID) -> pid_t? {
        var address = processAddress(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        guard status == noErr, pid > 0 else { return nil }
        return pid
    }

    /// The bundle identifier, if the process has one. `afplay` does not.
    ///
    /// Read through an untyped buffer and an `Unmanaged` rather than straight into a
    /// `CFString` variable, which is how `SystemAudioCapture` reads a device UID. That
    /// shortcut relies on ARC's release of the variable happening to balance the +1 Core
    /// Audio hands back, and it is read once per capture; this one is read for every process
    /// on every pass, so the ownership transfer is spelled out instead of assumed.
    private static func processBundleID(of object: AudioObjectID) -> String? {
        var address = processAddress(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<Unmanaged<CFString>?>.alignment
        )
        defer { buffer.deallocate() }

        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer)
        guard status == noErr,
              let reference = buffer.load(as: Unmanaged<CFString>?.self) else { return nil }
        let value = reference.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    // MARK: - Standing in for a calendar entry

    /// The `MeetingEvent` a detected call is armed as.
    ///
    /// Synthesised rather than given a parallel path of its own, which is what the plan
    /// settled on: `IslandState.Kind.meetingArmed`, `MeetingScheduler.arm`, `recordNow`,
    /// `skip`, the per-occurrence override and both notification buttons all take a
    /// `MeetingEvent`, and every one of them works on a call unchanged because of this.
    ///
    /// `end` is the start, not a guess. Nothing knows how long a call will run, and a
    /// plausible-looking hour would be read by the auto-stop rule as a real schedule and cut
    /// the call off at it. The scheduler excludes detected calls from that rule instead, and
    /// `MeetingSession` writes the true end when the recording stops.
    static func event(for call: CallActivity) -> MeetingEvent {
        MeetingEvent(
            id: identity(of: call),
            providerID: .detectedCall,
            title: "\(call.displayName) call",
            start: call.since,
            end: call.since,
            attendees: [],
            // Nobody invited anybody. True because the alternative reads as "declined", and
            // `MeetingScheduler.shouldAutoRecord` refuses those — a rule about invitations
            // that would silently veto every call.
            isOrganizerOrSelfAccepted: true,
            conferenceURL: nil,
            calendarName: call.displayName,
            isAllDay: false
        )
    }

    /// Unique per call, not per app.
    ///
    /// A key that named only the app would make this morning's Zoom call and this
    /// afternoon's the same event: `MeetingScheduler.meeting(for:)` would hand the second
    /// one the first one's finished recording, and "a meeting is armed once" would refuse to
    /// arm it at all. `since` survives a flicker — `apply` preserves it — so it stays
    /// constant for the length of one call and changes for the next.
    private static func identity(of call: CallActivity) -> String {
        let app = call.bundleID ?? "pid-\(call.pid)"
        return "\(app)@\(Int(call.since.timeIntervalSince1970))"
    }

    /// A name a person would recognise. `NSRunningApplication` first, because it gives the
    /// localised name the user sees in the Dock; the probe proved the fallbacks are needed —
    /// `afplay` is neither a running application nor a bundle.
    static func displayName(pid: pid_t, bundleID: String?) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            // Trimmed, because some bundles prefix their name with a bidirectional control
            // character. WhatsApp ships a left-to-right mark, which is invisible in the app
            // list and turned the first real detected call into a meeting titled
            // "\u{200E}WhatsApp call".
            let clean = name.trimmingCharacters(
                in: .whitespacesAndNewlines
                    .union(.controlCharacters)
                    .union(CharacterSet(charactersIn: "\u{200E}\u{200F}"))
            )
            if !clean.isEmpty { return clean }
        }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 {
            let name = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
            if !name.isEmpty { return name }
        }
        return bundleID ?? "pid \(pid)"
    }
}
