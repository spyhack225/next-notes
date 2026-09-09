import AppKit
import Carbon.HIToolbox

/// Holds and releases Wispr Flow's push-to-talk key by posting synthetic modifier events.
///
/// Wispr is a closed app with no API — the only way to make it record on demand is to press
/// its hotkey. That lets one Record button in the comparison window drive all three engines
/// off the same utterance, instead of asking the user to hold two keys at once and then go
/// looking for the results somewhere else.
///
/// This is inherently coupled to Wispr's hotkey setting. `key` must match whatever is bound
/// to `ptt` in Wispr's own config; if the user rebinds it there, this stops working until
/// it's updated here.
@MainActor
enum WisprTrigger {
    /// Left Command — Wispr's `ptt` binding.
    ///
    /// Wispr stores its shortcuts by keycode in
    /// `~/Library/Application Support/Wispr Flow/config.json` under `prefs.user.shortcuts`,
    /// so that file is the source of truth if this ever needs re-checking.
    static let keyCode = CGKeyCode(kVK_Command) // 55, left Command

    /// The device-specific left-Command bit. macOS reports plain `.maskCommand` for either
    /// side, so an app that distinguishes left from right — as Wispr does, since it binds
    /// left Command separately — needs this set too.
    private static let leftCommandDeviceBit = CGEventFlags(rawValue: 0x0000_0008)

    private static var isHeld = false

    static func press() {
        guard !isHeld else { return }
        isHeld = true
        post(flags: [.maskCommand, leftCommandDeviceBit])
    }

    static func release() {
        guard isHeld else { return }
        isHeld = false
        post(flags: [])
    }

    /// Builds the event from a *null* source rather than `CGEvent(keyboardEventSource:)`.
    ///
    /// A keyboard event whose `type` is reassigned to `.flagsChanged` silently loses its
    /// keycode, and the resulting event does nothing at all — it looks like it posted fine.
    /// Creating a bare event and setting the keycode field explicitly is the only shape that
    /// actually works.
    private static func post(flags: CGEventFlags) {
        guard let event = CGEvent(source: nil) else {
            Log.speech.error("WisprTrigger: could not create event")
            return
        }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
