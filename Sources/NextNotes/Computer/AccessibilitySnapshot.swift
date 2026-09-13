import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// A cheap structured walk of the focused window, with ids the click/set_text tools reuse.
///
/// Not the harvest: that one is budgeted for names at key-down. This one is asked for on
/// purpose, so it may take a little longer and return fewer, labelled controls.
@MainActor
enum AccessibilitySnapshot {
    private static var last: [String: AXUIElement] = [:]
    private static var lastGeneration = 0

    /// Honest report: a stub or empty tree says so and invents no controls.
    static func capture(processID: pid_t, limit: Int) -> String {
        last = [:]
        lastGeneration += 1
        let prefix = "\(lastGeneration)."
        let app = AXUIElementCreateApplication(processID)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else {
            return "no focused window. stub tree, 0 names. No elements were invented."
        }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? "Window"
        var lines = ["Window: \(title)"]
        walk(window as! AXUIElement, depth: 0, remaining: limit, prefix: prefix, into: &lines)
        if last.isEmpty {
            return "Window: \(title)\nstub tree, 0 names. No elements were invented."
        }
        return lines.joined(separator: "\n")
    }

    static func isStub(_ snapshot: String) -> Bool {
        snapshot.contains("stub tree, 0 names") || snapshot.contains("no focused window")
    }

    /// The inspect_ui id whose label or role text contains `query`, preferring buttons.
    static func id(matching query: String) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        var fallback: String?
        for (id, element) in last {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            let title = (titleRef as? String ?? "").lowercased()
            let role = roleRef as? String ?? ""
            let value = (valueRef as? String ?? "").lowercased()
            let haystack = title + " " + value + " " + shortRole(role).lowercased()
            guard haystack.contains(needle) else { continue }
            if role == "AXButton" || role == "AXLink" || role == "AXMenuItem" {
                return id
            }
            fallback = fallback ?? id
        }
        return fallback
    }

    static func value(of id: String) -> String? {
        guard let element = last[id] else { return nil }
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        return valueRef as? String
    }

    static func firstTextFieldID() -> String? {
        for (id, element) in last {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if roleRef as? String == "AXTextField" || roleRef as? String == "AXTextArea" {
                return id
            }
        }
        return last.keys.sorted().first
    }

    static func perform(id: String, action: String) throws {
        guard let element = last[id] else {
            throw AgentError.unknownTool("No UI element \(id). Inspect the window first.")
        }
        let error = AXUIElementPerformAction(element, action as CFString)
        guard error == .success else {
            throw AgentError.permissionDenied("The element did not accept \(action).")
        }
    }

    static func setValue(id: String, text: String) throws {
        guard let element = last[id] else {
            throw AgentError.unknownTool("No UI element \(id). Inspect the window first.")
        }
        let error = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        guard error == .success else {
            throw AgentError.permissionDenied("The field did not accept new text.")
        }
    }

    static func postKey(_ key: String, modifiers: [String]) throws {
        let keyCode = code(for: key)
        var flags = CGEventFlags(rawValue: 0)
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            throw AgentError.permissionDenied("Could not post a key event.")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        remaining: Int,
        prefix: String,
        into lines: inout [String]
    ) {
        guard remaining > last.count, depth < 8 else { return }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "Unknown"
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let title = titleRef as? String
        let value = valueRef as? String
        if isUseful(role: role, title: title, value: value) {
            let id = "\(prefix)\(last.count + 1)"
            last[id] = element
            var line = "\(shortRole(role)) id: \(id)"
            if let title, !title.isEmpty { line += "  label: \(title)" }
            if let value, !value.isEmpty, value.count < 80 { line += "  value: \(value)" }
            lines.append(line)
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return }
        for child in children.prefix(40) {
            walk(child, depth: depth + 1, remaining: remaining, prefix: prefix, into: &lines)
            if last.count >= remaining { return }
        }
    }

    private static func isUseful(role: String, title: String?, value: String?) -> Bool {
        switch role {
        case "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
             "AXTab", "AXLink", "AXPopUpButton", "AXComboBox", "AXMenuItem", "AXStaticText":
            return !(title ?? "").isEmpty || !(value ?? "").isEmpty || role != "AXStaticText"
        default:
            return false
        }
    }

    private static func shortRole(_ role: String) -> String {
        String(role.dropFirst(2))
    }

    private static func code(for key: String) -> CGKeyCode {
        switch key.lowercased() {
        case "return", "enter": return CGKeyCode(kVK_Return)
        case "escape", "esc": return CGKeyCode(kVK_Escape)
        case "tab": return CGKeyCode(kVK_Tab)
        case "space": return CGKeyCode(kVK_Space)
        case "delete", "backspace": return CGKeyCode(kVK_Delete)
        case "up": return CGKeyCode(kVK_UpArrow)
        case "down": return CGKeyCode(kVK_DownArrow)
        case "left": return CGKeyCode(kVK_LeftArrow)
        case "right": return CGKeyCode(kVK_RightArrow)
        default:
            guard let scalar = key.lowercased().unicodeScalars.first else {
                return CGKeyCode(kVK_Space)
            }
            return CGKeyCode(UInt16(scalar.value) - 97 + UInt16(kVK_ANSI_A))
        }
    }
}
