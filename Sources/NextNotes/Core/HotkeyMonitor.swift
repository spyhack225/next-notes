import AppKit
import Carbon.HIToolbox
import Foundation

/// Which modifier key holds the mic open.
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption
    case fn
    case rightCommand

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)   // 61
        case .fn: Int64(kVK_Function)               // 63
        case .rightCommand: Int64(kVK_RightCommand) // 54
        }
    }

    /// Device-*dependent* bit for this specific physical key.
    ///
    /// `CGEventFlags.maskAlternate` is the union mask — it's set whenever *either* Option
    /// key is down. Using it means: hold Left ⌥, tap Right ⌥, and the release is invisible
    /// (the union bit is still set by the left key), so `onRelease` never fires. The mic
    /// stays open, the HUD stays up, and the next press is swallowed too.
    ///
    /// These raw values are the NX_DEVICE* masks from IOKit's event system; they carry the
    /// left/right distinction that the public `CGEventFlags` constants discard.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x40)   // NX_DEVICERALTKEYMASK
        case .rightCommand: CGEventFlags(rawValue: 0x10)  // NX_DEVICERCMDKEYMASK
        case .fn: .maskSecondaryFn                        // no left/right variant exists
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .fn: "fn"
        case .rightCommand: "Right ⌘"
        }
    }

    /// Swallowing `fn` would break fn+arrow, fn+delete and the emoji picker, so we let it
    /// through. Dedicated right-hand modifiers are safe to consume.
    var shouldConsumeEvent: Bool { self != .fn }
}

/// Watches for a held modifier key using a `CGEventTap`.
///
/// A tap is required rather than `NSEvent.addGlobalMonitor` because `fn` and left/right
/// modifier discrimination don't surface through the higher-level APIs. This needs
/// Accessibility permission; without it `CGEvent.tapCreate` returns nil.
@MainActor
final class HotkeyMonitor {
    /// Immutable values used synchronously by the C event-tap callback. The callback then
    /// hands state mutation to the main actor instead of asserting actor isolation.
    private final class TapContext: @unchecked Sendable {
        weak var monitor: HotkeyMonitor?
        let keyCode: Int64
        let shouldConsume: Bool

        init(monitor: HotkeyMonitor, key: PushToTalkKey) {
            self.monitor = monitor
            keyCode = key.keyCode
            shouldConsume = key.shouldConsumeEvent
        }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapContext: TapContext?
    /// Whether the current run of tap failures has already been reported.
    private var didLogTapFailure = false
    private var isPressed = false

    var key: PushToTalkKey = .rightOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let context = TapContext(monitor: self, key: key)
        tapContext = context
        let refcon = Unmanaged.passUnretained(context).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue()

                // CGEvent isn't Sendable, so pull out the plain values before crossing into
                // actor-isolated code. Returning whether to consume must remain synchronous,
                // but state changes do not need to happen inside the C callback itself.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let matchesConfiguredKey = keyCode == context.keyCode
                Task { @MainActor [weak context] in
                    context?.monitor?.handle(type: type, keyCode: keyCode, flags: flags)
                }
                return matchesConfiguredKey && context.shouldConsume
                    ? nil
                    : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            // Once per run of failures, not once per attempt. `DictationController`
            // retries this every second for as long as the grant is missing — which is
            // forever, on a build whose ad-hoc signature no longer matches what TCC
            // stored — and an error a second buries every other subsystem's logs.
            if !didLogTapFailure {
                didLogTapFailure = true
                Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            }
            return false
        }
        didLogTapFailure = false

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(self.key.displayName)")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        tapContext = nil
        isPressed = false
    }

    // MARK: - Tap callback

    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        // The system disables a tap that runs too slowly or is interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard type == .flagsChanged, keyCode == key.keyCode else { return }

        let nowPressed = flags.contains(key.flag)
        guard nowPressed != isPressed else { return }
        isPressed = nowPressed

        if nowPressed { onPress?() } else { onRelease?() }

    }
}
