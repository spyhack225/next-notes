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
    private(set) static var lastProcessID: pid_t?
    private(set) static var lastSnapshot = ""

    static func stableContent(_ snapshot: String) -> String {
        snapshot.replacingOccurrences(
            of: #"id: \d+\.\d+"#, with: "id:", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Honest report: a stub or empty tree says so and invents no controls.
    static func capture(processID: pid_t, limit: Int) -> String {
        last = [:]
        lastProcessID = processID
        lastGeneration += 1
        let prefix = "\(lastGeneration)."
        let app = AXUIElementCreateApplication(processID)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else {
            lastSnapshot = "no focused window. stub tree, 0 names. No elements were invented."
            return lastSnapshot
        }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? "Window"
        var lines = ["Window: \(title)"]
        walk(window as! AXUIElement, depth: 0, remaining: limit, prefix: prefix, into: &lines)
        if last.isEmpty {
            lastSnapshot = "Window: \(title)\nstub tree, 0 names. No elements were invented."
            return lastSnapshot
        }
        lastSnapshot = lines.joined(separator: "\n")
        return lastSnapshot
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

    // MARK: - Frames and pointer events (P1.1–P1.2)

    /// Which physical button a synthetic press is for, and where a wheel is to run. Kept
    /// here rather than leaking `CGMouseButton` into the executor: the executor describes
    /// intent, this file owns the event mechanics.
    enum ScrollDirection: String {
        case up, down, left, right
    }

    enum MouseButton {
        case left
        case right
    }

    /// An element's screen frame, in AppKit screen points, read from the AX position and
    /// size attributes. The pointer tools need a real point to post an event at, and a
    /// pixel guess is the one thing this file will not hand out.
    static func bounds(of id: String) -> CGRect? {
        guard let element = last[id] else { return nil }
        return frame(of: element)
    }

    /// The focused window's screen frame, for a scroll with no element id and for the
    /// visible-remainder check the pointer tools make before they press.
    static func focusedWindowBounds(processID: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(processID)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        return frame(of: window as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let position = positionRef, let size = sizeRef
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Posts `clicks` wheel events at a point given in AppKit screen coordinates, one per
    /// click, the way a real wheel delivers notches. Sign convention: a positive vertical
    /// delta reveals the top of the view (scroll up) and a positive horizontal delta
    /// reveals the right edge (scroll right), which is why down and left post negatives —
    /// the same sign a physical wheel reports. `--selftest-computer-actions` checks both
    /// vertical directions against a real scroll view; the horizontal sign is checked the
    /// same way and would fail loudly there if the convention were wrong.
    static func postScroll(at point: CGPoint, direction: ScrollDirection, clicks: Int) throws {
        let vertical: Int
        let horizontal: Int
        switch direction {
        case .up: (vertical, horizontal) = (clicks, 0)
        case .down: (vertical, horizontal) = (-clicks, 0)
        case .right: (vertical, horizontal) = (0, clicks)
        case .left: (vertical, horizontal) = (0, -clicks)
        }
        for _ in 0..<clicks {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: Int32(vertical),
                wheel2: Int32(horizontal),
                wheel3: 0
            ) else {
                throw AgentError.permissionDenied("Could not post a scroll event.")
            }
            event.location = cgPoint(fromAppKit: point)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Posts a synthetic mouse press — single, double or right — at a point given in
    /// AppKit screen coordinates. The pointer is moved first so hover state matches where
    /// the press lands, and each press carries its own click state: that field, not the
    /// wall clock, is what AppKit reads to tell a double-click from two single ones.
    static func postMouseClick(at point: CGPoint, button: MouseButton, clickCount: Int) throws {
        let target = cgPoint(fromAppKit: point)
        let cgButton: CGMouseButton = button == .right ? .right : .left
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        if let move = CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: target, mouseButton: cgButton
        ) {
            move.post(tap: .cghidEventTap)
        }
        let counted = max(1, clickCount)
        for count in 1...counted {
            guard let down = CGEvent(
                    mouseEventSource: nil, mouseType: downType,
                    mouseCursorPosition: target, mouseButton: cgButton
                 ),
                 let up = CGEvent(
                    mouseEventSource: nil, mouseType: upType,
                    mouseCursorPosition: target, mouseButton: cgButton
                 )
            else {
                throw AgentError.permissionDenied("Could not post a mouse click.")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Posts a left-button drag between two points given in AppKit screen coordinates:
    /// down at the first, a short run of dragged events across, up at the second. The
    /// intermediate steps exist so a destination sees a drag and not a flick; they are
    /// posted back-to-back because the events carry their own order, and spacing them
    /// with sleeps would freeze the main thread this file always runs on.
    static func postMouseDrag(from startPoint: CGPoint, to endPoint: CGPoint) throws {
        let from = cgPoint(fromAppKit: startPoint)
        let to = cgPoint(fromAppKit: endPoint)
        guard let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: from, mouseButton: .left
        ) else {
            throw AgentError.permissionDenied("Could not post the start of a drag.")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        let steps = 8
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let mid = CGPoint(
                x: from.x + (to.x - from.x) * fraction,
                y: from.y + (to.y - from.y) * fraction
            )
            guard let drag = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDragged,
                mouseCursorPosition: mid, mouseButton: .left
            ) else {
                throw AgentError.permissionDenied("Could not post a drag step.")
            }
            drag.post(tap: .cghidEventTap)
        }
        guard let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: to, mouseButton: .left
        ) else {
            throw AgentError.permissionDenied("Could not post the end of a drag.")
        }
        up.post(tap: .cghidEventTap)
    }

    /// AppKit screen coordinates (origin at the bottom-left) to CGEvent coordinates
    /// (origin at the top-left of the main display). The flip is taken from the
    /// origin-zero screen's height and nothing else — a display above the main one has
    /// negative CG y, and whichever screen holds the point must not define the fold.
    private static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        let mainScreen = NSScreen.screens.first { $0.frame.origin == CGPoint.zero } ?? NSScreen.screens.first
        guard let mainScreen else { return point }
        return CGPoint(x: point.x, y: mainScreen.frame.maxY - point.y)
    }

    /// Walk one named window of `processID` instead of its focused window.
    ///
    /// `capture(processID:limit:)` reads `kAXFocusedWindowAttribute`, which answers for
    /// the window that is key *in the active application*. A self-test that owns its
    /// window cannot depend on that: a process launched by an agent tool is refused
    /// activation outright (measured 2026-09-22 — `isActive false, keyWindow false` even
    /// after `activate()` and the `kAXFrontmostAttribute` raise), while the window it
    /// created is still visible at a floating level and its subtree is still readable.
    /// Finding the window by title keeps such a test honest: it walks the tree it owns
    /// rather than describing whatever application happened to be frontmost, and every
    /// posted pointer event still lands by screen coordinates on a topmost window.
    static func capture(windowTitled wantedTitle: String, processID: pid_t, limit: Int) -> String {
        last = [:]
        lastProcessID = processID
        lastGeneration += 1
        let prefix = "\(lastGeneration)."
        let app = AXUIElementCreateApplication(processID)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            lastSnapshot = "no windows visible to accessibility. stub tree, 0 names. No elements were invented."
            return lastSnapshot
        }
        var chosen: AXUIElement?
        for candidate in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &titleRef)
            if titleRef as? String == wantedTitle { chosen = candidate; break }
        }
        guard let window = chosen else {
            // The titles that *were* visible, so a red run names the mismatch instead of
            // leaving a title typo undiagnosable.
            var seen: [String] = []
            for candidate in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &titleRef)
                var positionRef: CFTypeRef?
                AXUIElementCopyAttributeValue(candidate, kAXPositionAttribute as CFString, &positionRef)
                var position = "position ?"
                if let value = positionRef {
                    var point = CGPoint.zero
                    AXValueGetValue(value as! AXValue, .cgPoint, &point)
                    position = "position (\(Int(point.x)), \(Int(point.y)))"
                }
                seen.append("\(titleRef as? String ?? "(untitled)") \(position)")
            }
            lastSnapshot = "no window titled \(wantedTitle); windows: \(seen.joined(separator: " | ")). "
                + "stub tree, 0 names. No elements were invented."
            return lastSnapshot
        }
        var lines = ["Window: \(wantedTitle)"]
        walk(window, depth: 0, remaining: limit, prefix: prefix, into: &lines)
        if last.isEmpty {
            lastSnapshot = "Window: \(wantedTitle)\nstub tree, 0 names. No elements were invented."
            return lastSnapshot
        }
        lastSnapshot = lines.joined(separator: "\n")
        return lastSnapshot
    }

    // MARK: - Compact inspect_ui (P1.3)

    /// How long a label or value runs on a compact line before it is cut. The tool's
    /// contract says "about forty characters": long enough to recognize a control, short
    /// enough that the list stays a list.
    private static let compactFieldLimit = 40
    private static let compactEllipsis = "…"

    /// The same walk as `capture(processID:limit:)`, printed one short line per control:
    /// `Button 7.2 Send`. The window title heads the list, a cut label or value follows
    /// the id, and window chrome — scroll bars, group boxes with no label — appears
    /// nowhere, because the useful-element filter that decides the id map already
    /// excludes it in both modes.
    ///
    /// The bookkeeping is deliberately not compact's to change: `last`, the generation
    /// prefix and `lastProcessID` advance exactly as the full capture advances them, so
    /// an id the compact list prints is the id `click` and `set_text` resolve, whether
    /// the last inspect ran compact or full.
    ///
    /// `lastSnapshot` keeps the *full* rendering rather than the compact one. It is what
    /// the click and scroll verifications compare against a fresh capture, and a compact
    /// string recorded there would read as changed against every later full capture —
    /// different ink, same window.
    static func captureCompact(processID: pid_t, limit: Int) -> String {
        last = [:]
        lastProcessID = processID
        lastGeneration += 1
        let prefix = "\(lastGeneration)."
        let app = AXUIElementCreateApplication(processID)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else {
            lastSnapshot = "no focused window. stub tree, 0 names. No elements were invented."
            return lastSnapshot
        }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? "Window"
        var full = ["Window: \(title)"]
        var compact = ["Window: \(title)"]
        walkRecording(
            window as! AXUIElement, depth: 0, remaining: limit, prefix: prefix,
            into: &full, and: &compact
        )
        if last.isEmpty {
            lastSnapshot = "Window: \(title)\nstub tree, 0 names. No elements were invented."
            return lastSnapshot
        }
        lastSnapshot = full.joined(separator: "\n")
        return compact.joined(separator: "\n")
    }

    /// The walk both captures share, appending the full line to one list and the compact
    /// line to the other. The traversal, the useful-element test and the id numbering
    /// must stay identical to `walk(_:depth:remaining:prefix:into:)` — the two modes
    /// describe one tree, and an id that resolved in one and not the other would be a
    /// bug the self-test could not see.
    private static func walkRecording(
        _ element: AXUIElement,
        depth: Int,
        remaining: Int,
        prefix: String,
        into lines: inout [String],
        and compactLines: inout [String]
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
            compactLines.append(compactLine(role: role, id: id, title: title, value: value))
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return }
        for child in children.prefix(40) {
            walkRecording(child, depth: depth + 1, remaining: remaining, prefix: prefix, into: &lines, and: &compactLines)
            if last.count >= remaining { return }
        }
    }

    /// One compact line: short role, the id, then the label cut to size, then the value
    /// when it says something the label does not. A button labelled "Send" is
    /// `Button 7.2 Send`; a field whose only words are its value keeps them as its label.
    private static func compactLine(role: String, id: String, title: String?, value: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var line = "\(shortRole(role)) \(id)"
        if !trimmedTitle.isEmpty {
            line += " \(compactText(trimmedTitle))"
            if !trimmedValue.isEmpty, trimmedValue != trimmedTitle {
                line += " \(compactText(trimmedValue))"
            }
        } else if !trimmedValue.isEmpty {
            line += " \(compactText(trimmedValue))"
        }
        return line
    }

    private static func compactText(_ raw: String) -> String {
        guard raw.count > compactFieldLimit else { return raw }
        return String(raw.prefix(compactFieldLimit)) + compactEllipsis
    }

    /// What sits under a screen point, read the way the coordinate click verifies
    /// itself: one system-wide element query, answered from whatever is topmost there.
    ///
    /// This is the read-out half of grounding a click in pixels. It reports the role and
    /// title only — never an element's value or any text beyond a short label — because
    /// the caller's job is to say what it landed on, not to harvest the screen. A point
    /// over empty chrome or a pixel-only surface comes back nil, and the caller is
    /// required to say exactly that rather than guess.
    static func roleAndTitle(at appKitPoint: CGPoint) -> (role: String, title: String)? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let target = cgPoint(fromAppKit: appKitPoint)
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(target.x), Float(target.y), &elementRef
        ) == .success, let element = elementRef else {
            return nil
        }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let role = roleRef as? String ?? ""
        let title = titleRef as? String ?? ""
        if role.isEmpty { return nil }
        return (role, title)
    }

    /// Puts the captured state where the coordinate click's "the tree is a stub" gate
    /// reads it, for the one self-test that must reach the posting path without a real
    /// capture to name. A test-only seam, named as such so no production caller can
    /// mistake it for a capture.
    static func markStubForTesting() {
        lastSnapshot = "stub tree, 0 names. No elements were invented. Set by a self-test."
    }

    /// Asks a Chromium-family browser to build its accessibility tree now.
    ///
    /// Chromium builds its UI tree lazily — a walk that arrives before an assistive
    /// client has ever asked reads back as a stub (measured, and the reason the
    /// browser tools fall back to pixels). `AXManualAccessibility` on the application
    /// element is Chromium's own switch for that: set it and the tree populates at
    /// once, which turns snapshot → click → fill into working control of the user's
    /// real browser with no relaunch and no debugging port. WebKit builds eagerly and
    /// ignores the attribute, so callers may hand over any browser's pid. The attribute
    /// is read-enabling only — it changes what this process may *see*, never what runs —
    /// and a refused set is indistinguishable from a refusal to populate, so the caller
    /// re-walks and answers from what it reads back.
    static func enableManualAccessibility(processID: pid_t) {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
