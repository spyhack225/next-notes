import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A bounded, pass-through experiment for roadmap v4 section 37.
///
/// This is intentionally separate from `HotkeyMonitor`: it never consumes an event and
/// never changes the production hotkey path. Run it from Terminal while exercising the
/// requested physical keys. The result is only `_OK` when every requested key produced a
/// complete press/release pair through both CGEventTap and at least one NSEvent monitor.
/// A run with no physical input (or without the required Accessibility/Input Monitoring
/// capability) is therefore a failure rather than a misleading green self-test.
///
/// Usage:
///
///     xcrun swiftc -parse-as-library -O Tools/HotkeyExperiment.swift \
///       -framework AppKit -framework Carbon -framework CoreGraphics \
///       -o /tmp/nextnotes-hotkey-experiment
///     /tmp/nextnotes-hotkey-experiment --key right-option --seconds 20
///
/// Use `--key all` to exercise Right Option, Right Command, and fn in one bounded run.
/// The process does not activate itself, consume keys, or install/replace the app.

private enum ExperimentKey: String, CaseIterable {
    case rightOption = "right-option"
    case rightCommand = "right-command"
    case fn

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)
        case .rightCommand: Int64(kVK_RightCommand)
        case .fn: Int64(kVK_Function)
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .fn: "fn"
        }
    }

    /// NX device-dependent bits. AppKit exposes these in the low half of modifierFlags,
    /// while its named modifier flags occupy the high half. fn has no left/right variant.
    var deviceBit: UInt64? {
        switch self {
        case .rightOption: 0x40 // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x10 // NX_DEVICERCMDKEYMASK
        case .fn: nil
        }
    }

    static func parse(_ value: String) -> [ExperimentKey]? {
        if value == "all" { return allCases }
        guard let key = ExperimentKey(rawValue: value) else { return nil }
        return [key]
    }
}

private enum EventSource: String {
    case nseventGlobal = "nsevent-global"
    case nseventLocal = "nsevent-local"
    case cgEventTap = "cg-event-tap"
}

private enum EventPhase: String {
    case press
    case release
    case unchanged
}

private struct RunConfiguration {
    let keys: [ExperimentKey]
    let seconds: Double
    let outputPath: String?
}

private struct KeySourceStats {
    var presses = 0
    var releases = 0
    var open = false
    var events = 0

    var complete: Bool { presses > 0 && releases > 0 && !open }
}

@MainActor
private final class HotkeyExperiment {
    private final class TapContext: @unchecked Sendable {
        weak var owner: HotkeyExperiment?

        init(owner: HotkeyExperiment) {
            self.owner = owner
        }
    }

    private let configuration: RunConfiguration
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapContext: TapContext?
    private var stats: [EventSource: [ExperimentKey: KeySourceStats]] = [:]
    private var lines: [String] = []
    private var didFinish = false
    private var eventCount = 0
    private let startedAt = Date()
    private(set) var passed = false

    init(configuration: RunConfiguration) {
        self.configuration = configuration
        for source in [EventSource.nseventGlobal, .nseventLocal, .cgEventTap] {
            stats[source] = Dictionary(uniqueKeysWithValues: configuration.keys.map { ($0, KeySourceStats()) })
        }
    }

    func start() {
        write("HOTKEY_EXPERIMENT_START seconds=\(configuration.seconds) keys=\(configuration.keys.map(\.rawValue).joined(separator: ","))")
        write("CAPABILITY launch process=\(ProcessInfo.processInfo.processName) bundle=\(Bundle.main.bundleIdentifier ?? "(none)") activationPolicy=prohibited appActive=\(NSApp.isActive) frontmost=\(frontmostBundle)")
        write("CAPABILITY semantics cgEventTap=defaultTap with pass-through callback; events are never consumed")

        installNSEventMonitors()
        installCGEventTap()

        write("INSTRUCTIONS Hold and release each requested physical key (\(configuration.keys.map(\.displayName).joined(separator: ", "))); left keys are intentionally not scored.")
        write("INSTRUCTIONS Keep this process running until the final result line.")

    }

    private func installNSEventMonitors() {
        let mask = NSEvent.EventTypeMask.flagsChanged

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.record(source: .nseventGlobal, keyCode: Int64(event.keyCode), flags: UInt64(event.modifierFlags.rawValue))
            }
        }
        write("CAPABILITY nsevent-global=\(globalMonitor == nil ? "unavailable" : "registered") note=global monitor observes other applications only")

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.record(source: .nseventLocal, keyCode: Int64(event.keyCode), flags: UInt64(event.modifierFlags.rawValue))
            }
            return event
        }
        write("CAPABILITY nsevent-local=\(localMonitor == nil ? "unavailable" : "registered") note=local monitor observes this process only")
    }

    private func installCGEventTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let context = TapContext(owner: self)
        tapContext = context
        let refcon = Unmanaged.passUnretained(context).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Match production HotkeyMonitor's `.defaultTap` so the permission result is
            // comparable. The callback always returns the event, so this diagnostic still
            // cannot swallow or rewrite input.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue()
                guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = UInt64(event.flags.rawValue)
                Task { @MainActor [weak context] in
                    context?.owner?.record(source: .cgEventTap, keyCode: keyCode, flags: flags)
                }
                // Pass-through is deliberate: this experiment cannot change keyboard input.
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            write("CAPABILITY cg-event-tap=unavailable reason=CGEvent.tapCreate returned nil (Accessibility permission required by current HotkeyMonitor)")
            return
        }

        self.tap = tap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let tapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        write("CAPABILITY cg-event-tap=registered mode=defaultTap-pass-through")
    }

    private func record(source: EventSource, keyCode: Int64, flags: UInt64) {
        guard !didFinish, let key = configuration.keys.first(where: { $0.keyCode == keyCode }) else { return }
        let phase = phase(for: key, flags: flags, source: source)
        let deviceIndependentMask = UInt64(NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)
        let deviceIndependent = flags & deviceIndependentMask
        let deviceDependent = flags & ~deviceIndependentMask
        let focus = "frontmost=\(frontmostBundle) appActive=\(NSApp.isActive)"
        eventCount += 1

        guard phase != .unchanged else {
            write("EVENT source=\(source.rawValue) key=\(key.rawValue) phase=unchanged keycode=\(keyCode) flagsRaw=0x\(String(flags, radix: 16)) deviceIndependent=0x\(String(deviceIndependent, radix: 16)) deviceDependent=0x\(String(deviceDependent, radix: 16)) \(focus)")
            return
        }

        var sourceStats = stats[source]?[key] ?? KeySourceStats()
        sourceStats.events += 1
        switch phase {
        case .press:
            sourceStats.presses += 1
            sourceStats.open = true
        case .release:
            sourceStats.releases += 1
            sourceStats.open = false
        case .unchanged:
            break
        }
        stats[source]?[key] = sourceStats

        write("EVENT source=\(source.rawValue) key=\(key.rawValue) phase=\(phase.rawValue) keycode=\(keyCode) flagsRaw=0x\(String(flags, radix: 16)) deviceIndependent=0x\(String(deviceIndependent, radix: 16)) deviceDependent=0x\(String(deviceDependent, radix: 16)) \(focus)")
    }

    private func phase(for key: ExperimentKey, flags: UInt64, source: EventSource) -> EventPhase {
        if let deviceBit = key.deviceBit {
            // Report device-dependent state for right-hand modifiers. The high-level Option
            // and Command bits are intentionally not used for this decision: they are unions
            // and cannot see a right-key release while the left key remains held.
            return flags & deviceBit == deviceBit ? .press : .release
        }

        // fn has no left/right device bit. Both NSEvent and CGEvent expose its physical
        // state through their function/secondary-fn modifier flag for keycode 63.
        switch source {
        case .nseventGlobal, .nseventLocal:
            let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(flags))
            return nsFlags.contains(.function) ? .press : .release
        case .cgEventTap:
            return flags & UInt64(CGEventFlags.maskSecondaryFn.rawValue) != 0 ? .press : .release
        }
    }

    func finish(reason: String) {
        guard !didFinish else { return }
        didFinish = true
        removeMonitors()

        write("SUMMARY reason=\(reason) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(startedAt))) events=\(eventCount)")
        for key in configuration.keys {
            let global = stats[.nseventGlobal]?[key] ?? KeySourceStats()
            let local = stats[.nseventLocal]?[key] ?? KeySourceStats()
            let cg = stats[.cgEventTap]?[key] ?? KeySourceStats()
            write("RESULT key=\(key.rawValue) nseventGlobal=press:\(global.presses),release:\(global.releases),open:\(global.open) nseventLocal=press:\(local.presses),release:\(local.releases),open:\(local.open) cgEventTap=press:\(cg.presses),release:\(cg.releases),open:\(cg.open)")
        }

        let tapComplete = stats[.cgEventTap] != nil && configuration.keys.allSatisfy { stats[.cgEventTap]?[$0]?.complete == true }
        let nseventComplete = configuration.keys.allSatisfy { key in
            [EventSource.nseventGlobal, .nseventLocal].contains { stats[$0]?[key]?.complete == true }
        }
        let hasPhysicalEvents = eventCount > 0
        let verdict: String
        if hasPhysicalEvents && tapComplete && nseventComplete {
            verdict = "HOTKEY_EXPERIMENT_OK reason=complete-press-release-observed-through-both-APIs"
            passed = true
        } else if !hasPhysicalEvents {
            verdict = "HOTKEY_EXPERIMENT_FAILED reason=NO_PHYSICAL_EVENTS; no requested key event was observed"
        } else if !tapComplete {
            verdict = "HOTKEY_EXPERIMENT_FAILED reason=CG_EVENT_TAP_INCOMPLETE; check Accessibility permission and repeat the physical cycles"
        } else {
            verdict = "HOTKEY_EXPERIMENT_FAILED reason=NSEVENT_INCOMPLETE; NSEvent did not observe a complete cycle for every requested key"
        }
        write("LIMITS missed releases are reported as open=true; a release that never reaches either observer cannot be distinguished from a key still held")
        write("LIMITS focus is a snapshot of NSWorkspace.frontmostApplication at delivery time; launch behavior and permissions still require a person to repeat this from the intended app context")
        write(verdict)

        if let outputPath = configuration.outputPath {
            do {
                try lines.joined(separator: "\n").appending("\n").write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
            } catch {
                fputs("HOTKEY_EXPERIMENT_OUTPUT_FAILED \(error)\n", stderr)
            }
        }

        NSApp.stop(nil)
        CFRunLoopStop(CFRunLoopGetMain())
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        tap = nil
        tapSource = nil
        tapContext = nil
    }

    private var frontmostBundle: String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "(unknown)"
    }

    private func write(_ line: String) {
        lines.append(line)
        print(line)
    }
}

private enum ArgumentError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): message
        }
    }
}

private func parseArguments(_ arguments: [String]) throws -> RunConfiguration {
    var keyValue = "all"
    var seconds = 30.0
    var outputPath: String?
    var index = 1

    while index < arguments.count {
        switch arguments[index] {
        case "--key":
            index += 1
            guard index < arguments.count else { throw ArgumentError.usage("--key requires right-option, right-command, fn, or all") }
            keyValue = arguments[index]
        case "--seconds":
            index += 1
            guard index < arguments.count, let value = Double(arguments[index]), value.isFinite, value > 0, value <= 300 else {
                throw ArgumentError.usage("--seconds requires a number greater than 0 and no greater than 300")
            }
            seconds = value
        case "--output":
            index += 1
            guard index < arguments.count, !arguments[index].isEmpty else { throw ArgumentError.usage("--output requires a file path") }
            outputPath = arguments[index]
        case "--help", "-h":
            throw ArgumentError.usage("usage: hotkey-experiment [--key all|right-option|right-command|fn] [--seconds 30] [--output path]")
        default:
            throw ArgumentError.usage("unknown argument \(arguments[index]); use --help")
        }
        index += 1
    }

    guard let keys = ExperimentKey.parse(keyValue) else {
        throw ArgumentError.usage("--key requires right-option, right-command, fn, or all")
    }
    return RunConfiguration(keys: keys, seconds: seconds, outputPath: outputPath)
}

@main
private struct HotkeyExperimentCLI {
    static func main() {
        do {
            let configuration = try parseArguments(CommandLine.arguments)
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            let experiment = HotkeyExperiment(configuration: configuration)
            experiment.start()
            let deadline = Date().addingTimeInterval(configuration.seconds)
            // Run the main loop in short bounded slices. NSApplication.run() can block in
            // WindowServer's event fetch and ignore a timer in a no-input CLI process; these
            // slices provide a hard wall clock bound while still servicing AppKit monitors.
            while Date() < deadline {
                let sliceEnd = min(deadline, Date().addingTimeInterval(0.05))
                RunLoop.main.run(until: sliceEnd)
            }
            experiment.finish(reason: "duration-expired")
            exit(experiment.passed ? 0 : 1)
        } catch {
            fputs("HOTKEY_EXPERIMENT_FAILED reason=ARGUMENTS \(error)\n", stderr)
            exit(2)
        }
    }
}
