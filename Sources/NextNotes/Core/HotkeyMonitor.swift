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

    /// The same key in words, for a sentence somebody reads.
    ///
    /// `displayName` is a glyph, and a glyph is a label on a picker row, not a sentence. A
    /// person who has never met ⌥ cannot be told to "hold ⌥" in a heads-up display and be
    /// expected to find it on the keyboard.
    var spokenName: String {
        switch self {
        case .rightOption: "the right Option key"
        case .fn: "the fn key"
        case .rightCommand: "the right Command key"
        }
    }

    /// Swallowing `fn` would break fn+arrow, fn+delete and the emoji picker, so we let it
    /// through. Dedicated right-hand modifiers are safe to consume.
    var shouldConsumeEvent: Bool { self != .fn }
}

/// Whether a held modifier is a deliberate hold or just part of an ordinary shortcut.
///
/// Push-to-talk answers that question by fiat: the key is a dedicated one, and the instant
/// it goes down the microphone opens. Command Mode cannot, because the key it is usually
/// bound to is ⌘ — the modifier every shortcut on the machine is built out of. Firing on
/// key-down meant that pressing ⌘C started a recording against the very selection the user
/// was copying, and that a bare tap of ⌘ raised a wordless animation and then nothing.
///
/// So the decision is made here instead of in the tap, as pure state with no AppKit in it:
/// a hold counts only once it has lasted past a threshold *and* nothing else was struck,
/// clicked or scrolled while it was down. That makes it something `--selftest-commandkey`
/// can drive without a keyboard, which is the only way any of this is checkable on a build
/// machine.
struct ModifierHoldGate {
    /// What the caller should do about the fact just fed in.
    enum Action: Equatable {
        case nothing
        case press
        case release
        /// A hold that had already started turned out to be a shortcut after all.
        case cancel
    }

    /// `false` restores push-to-talk's behaviour exactly: press on key-down, release on
    /// key-up, and no interest in anything else on the keyboard.
    let requiresHold: Bool

    /// Everything that says "this ⌘ is part of a shortcut, not a hold".
    ///
    /// The keyboard is only half of it, and the half that was missed is the one the key
    /// Command Mode is usually bound to actually sits under. ⌘ is the right thumb's
    /// modifier: ⌘-click to multi-select in Finder, ⌘-click to open a link in a new tab,
    /// ⌘-scroll to zoom. Each of those holds ⌘ for as long as it takes to aim a pointer,
    /// which is comfortably longer than the hold threshold — so while only `.keyDown` was
    /// watched, an ordinary ⌘-click opened the microphone and, on release, replaced the
    /// user's selection in another app with whatever the room had been saying.
    ///
    /// A drag is covered by the mouse-down that begins it. Scrolling has no such opening
    /// event, so it is listed in its own right.
    ///
    /// Lives on the gate rather than on `HotkeyMonitor` because the event tap's C callback
    /// is not on the main actor and cannot read anything that is.
    static let spoilers: [CGEventType] = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    /// Whether this event type is one of `spoilers`. Called for every event the chord tap
    /// receives, so it is a bit test rather than a search.
    ///
    /// The shift is safe for the out-of-range raw values the tap also delivers
    /// (`tapDisabledByTimeout` is `0xFFFF_FFFE`): Swift's `<<` yields zero rather than
    /// trapping when the shift exceeds the width.
    static func spoils(_ type: CGEventType) -> Bool {
        spoilerMask & (UInt64(1) << UInt64(type.rawValue)) != 0
    }

    private static let spoilerMask: UInt64 = spoilers.reduce(into: UInt64(0)) {
        $0 |= UInt64(1) << UInt64($1.rawValue)
    }

    private var isDown = false
    private var spoiled = false
    private var fired = false

    init(requiresHold: Bool) {
        self.requiresHold = requiresHold
    }

    /// Whether the watched modifier is down right now. The tap reads this to decide whether
    /// other keystrokes are worth looking at at all.
    var isHeld: Bool { isDown }

    /// Whether `press` has been reported and not yet withdrawn.
    var hasFired: Bool { fired }

    mutating func modifierDown() -> Action {
        guard !isDown else { return .nothing }
        isDown = true
        spoiled = false
        fired = false
        guard !requiresHold else { return .nothing }
        fired = true
        return .press
    }

    /// The threshold passed with the key still down.
    mutating func holdElapsed() -> Action {
        guard isDown, !spoiled, !fired else { return .nothing }
        fired = true
        return .press
    }

    /// Some other input arrived while the modifier was held — another key went down, or the
    /// mouse was clicked, or the wheel was turned. So this is ⌘C or ⌘-click, not a hold.
    mutating func otherInput() -> Action {
        // Push-to-talk never hears about other input — its tap does not even ask for it —
        // and must not start doing so by accident: holding the key and typing is a thing
        // people do, and cancelling the dictation for it would be a new bug.
        guard requiresHold, isDown, !spoiled else { return .nothing }
        spoiled = true
        guard fired else { return .nothing }
        fired = false
        return .cancel
    }

    mutating func modifierUp() -> Action {
        guard isDown else { return .nothing }
        isDown = false
        spoiled = false
        guard fired else { return .nothing }
        fired = false
        return .release
    }
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

        /// Set from the main actor, read synchronously inside the C callback — which is why
        /// it is behind a lock rather than being actor state. It exists so the callback can
        /// drop every keystroke in the system in a handful of instructions while no hold is
        /// in progress, instead of spawning a `Task` per key the user types.
        private let lock = NSLock()
        private var held = false

        var isHeld: Bool {
            get { lock.lock(); defer { lock.unlock() }; return held }
            set { lock.lock(); held = newValue; lock.unlock() }
        }

        init(monitor: HotkeyMonitor, key: PushToTalkKey, watchesChords: Bool) {
            self.monitor = monitor
            keyCode = key.keyCode
            // Never swallowed while we are only waiting to see whether a hold develops.
            // The key that gets a hold threshold is ⌘, and deleting its down/up transitions
            // from the session stream would be editing the modifier every other app on the
            // machine reads its shortcuts out of, in exchange for nothing — a lone modifier
            // press types no character to suppress.
            shouldConsume = key.shouldConsumeEvent && !watchesChords
        }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapContext: TapContext?
    /// Whether the current run of tap failures has already been reported.
    private var didLogTapFailure = false
    private var gate = ModifierHoldGate(requiresHold: false)
    private var holdTask: Task<Void, Never>?

    var key: PushToTalkKey = .rightOption
    /// How long the key must be held before it counts as a hold at all.
    ///
    /// `nil` — the push-to-talk default — fires the instant the key goes down, because
    /// dictation is latency-bound and the key is a dedicated one. Set it for a key that is
    /// also a shortcut modifier: a tap shorter than this, and any hold with another key
    /// struck or the mouse used inside it, then produce nothing at all.
    var holdThreshold: Duration?
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// A hold that had already fired `onPress` turned out to be a shortcut. Nothing follows
    /// it — `onRelease` is not called for a cancelled hold.
    var onCancel: (() -> Void)?

    /// Whether this monitor has to tell a hold from a shortcut at all.
    var watchesChords: Bool { holdThreshold != nil }

    /// The event types this monitor asks the system for.
    ///
    /// A value rather than a literal buried in `start()` so `--selftest-commandkey` can
    /// assert the wiring without a keyboard, an Accessibility grant or a screen: the whole
    /// protection against ⌘C and ⌘-click rests on these types being in the mask, and a
    /// missing one fails silently and dangerously.
    var eventMask: CGEventMask {
        // Ordinary keystrokes and clicks are only ever in the mask for a key that needs to
        // tell a hold from a shortcut. Push-to-talk's tap still sees modifier changes and
        // nothing else.
        var mask = UInt64(1) << UInt64(CGEventType.flagsChanged.rawValue)
        if watchesChords {
            for type in ModifierHoldGate.spoilers { mask |= UInt64(1) << UInt64(type.rawValue) }
        }
        return CGEventMask(mask)
    }

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        let watchesChords = self.watchesChords
        gate = ModifierHoldGate(requiresHold: watchesChords)
        let mask = eventMask
        let context = TapContext(monitor: self, key: key, watchesChords: watchesChords)
        tapContext = context
        let refcon = Unmanaged.passUnretained(context).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // A chord-watching tap never swallows anything — `shouldConsume` is false for it
            // by construction, and the spoiler branch below always hands the event straight
            // back. A `.defaultTap` would nevertheless put this app's main run loop in the
            // synchronous delivery path of every keystroke and click on the Mac, so a stall
            // here would stall the user's typing until the system timed the tap out. Listen
            // only: the gate needs to *see* these events, never to edit them.
            options: watchesChords ? .listenOnly : .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue()

                // Every keystroke, click and scroll in the session reaches this branch while
                // the tap is armed for chords, so it has to be cheap and it has to stay
                // incurious: it reads no key code, keeps nothing, and only matters at all
                // while our own modifier is already down.
                //
                // `tapDisabledByTimeout` is deliberately *not* caught here — it falls
                // through to `handle`, which re-arms the tap. Swallowing it would leave a
                // silently dead hotkey.
                if ModifierHoldGate.spoils(type) {
                    if context.isHeld {
                        Task { @MainActor [weak context] in context?.monitor?.spoilHold() }
                    }
                    return Unmanaged.passUnretained(event)
                }

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
        holdTask?.cancel()
        holdTask = nil
        tap = nil
        runLoopSource = nil
        tapContext = nil
        gate = ModifierHoldGate(requiresHold: holdThreshold != nil)
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
        guard nowPressed != gate.isHeld else { return }

        if nowPressed {
            apply(gate.modifierDown())
            tapContext?.isHeld = true
            armHoldTimer()
        } else {
            holdTask?.cancel()
            holdTask = nil
            tapContext?.isHeld = false
            apply(gate.modifierUp())
        }
    }

    /// Starts the clock that turns a held key into a hold. No-op without a threshold, where
    /// the press has already been reported by `modifierDown`.
    private func armHoldTimer() {
        guard let holdThreshold else { return }
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: holdThreshold)
            guard !Task.isCancelled, let self else { return }
            self.holdTask = nil
            self.apply(self.gate.holdElapsed())
        }
    }

    /// Another key or a click landed while ours was held, so this was a shortcut all along.
    private func spoilHold() {
        holdTask?.cancel()
        holdTask = nil
        apply(gate.otherInput())
    }

    private func apply(_ action: ModifierHoldGate.Action) {
        switch action {
        case .nothing: break
        case .press: onPress?()
        case .release: onRelease?()
        case .cancel: onCancel?()
        }
    }
}
