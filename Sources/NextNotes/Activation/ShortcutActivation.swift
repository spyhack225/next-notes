import AppKit
import Carbon.HIToolbox
import Foundation

/// A dedicated global shortcut, separate from push-to-talk. Default ⇧⌘Space — a real key
/// combination, so `NSEvent` monitors see it (unlike a bare modifier, which needs a tap).
@MainActor
final class ShortcutActivation {
    static let shared = ShortcutActivation()

    private var local: Any?
    private var global: Any?

    var onTrigger: (() -> Void)?

    func start() {
        stop()
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self, self.matches(event) else { return event }
            self.onTrigger?()
            return nil
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event) else { return }
            self.onTrigger?()
        }
    }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard Settings.shared.agentShortcutEnabled else { return false }
        let wanted = Settings.shared.agentShortcut
        return event.keyCode == wanted.keyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == wanted.flags
    }
}

/// Configurable chord. Stored as a small enum so Settings does not have to persist Carbon
/// constants by hand.
enum AgentShortcut: String, CaseIterable, Sendable, Identifiable {
    case shiftCommandSpace
    case controlCommandSpace
    case optionCommandSpace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shiftCommandSpace: "⇧⌘ Space"
        case .controlCommandSpace: "⌃⌘ Space"
        case .optionCommandSpace: "⌥⌘ Space"
        }
    }

    var keyCode: UInt16 { UInt16(kVK_Space) }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shiftCommandSpace: [.shift, .command]
        case .controlCommandSpace: [.control, .command]
        case .optionCommandSpace: [.option, .command]
        }
    }
}
