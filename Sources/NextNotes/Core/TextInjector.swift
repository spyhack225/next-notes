import AppKit
import ApplicationServices
import Foundation

/// Puts text into a text field — by default whatever currently has keyboard focus, or,
/// when an `Origin` is supplied, back into the app the dictation started in.
///
/// Two strategies, in order:
/// 1. **Accessibility** — set `kAXSelectedTextAttribute` on the focused element. Clean and
///    instant, and it leaves the pasteboard untouched.
/// 2. **Pasteboard + ⌘V** — works in Electron apps and anything else with a half-hearted
///    AX implementation. The previous pasteboard contents are restored afterwards.
///
/// The catch that makes this non-obvious: **many apps return `.success` from the AX write
/// and then do nothing.** Electron (Cursor, VS Code, Slack, Discord), Chrome, and most
/// terminal emulators all report `kAXSelectedTextAttribute` as settable, accept the write,
/// and silently drop it. So the return value is not evidence of anything — strategy 1 is
/// only trusted when the insertion point can be *observed* to have moved.
///
/// This all works because the HUD is a non-activating panel: focus never leaves the user's
/// target app, so "the focused element" is still their text field.
@MainActor
enum TextInjector {
    /// The app a dictation started in, so its text can be put back there.
    ///
    /// Dictation is not instant: draining, transcribing and cleaning up take seconds, and
    /// the user is free to switch away in the middle. Resolving the target at *insertion*
    /// time — which is all `insert(_:)` can do on its own — then means the text lands
    /// wherever they happen to be looking, or nowhere at all if that is not a text field.
    /// Capturing the app at key-down is what makes "put it where I started" possible.
    struct Origin {
        let app: NSRunningApplication
        let displayName: String

        var isFrontmost: Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        }
    }

    /// The frontmost app, or nil when that is Next Notes itself.
    ///
    /// Nil is not a failure. The HUD is a non-activating panel, so during a normal dictation
    /// the user's app stays frontmost and this returns it; nil means they really were in
    /// Next Notes, and inserting into whatever is focused then is exactly right.
    static func captureOrigin() -> Origin? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != AppIdentity.bundleIdentifier
        else { return nil }
        return Origin(app: app, displayName: app.localizedName ?? app.bundleIdentifier ?? "that app")
    }

    /// Why an insertion did not land where it was meant to.
    enum Outcome: Equatable {
        case inserted
        /// The origin app could not be brought back. The text is on the clipboard — the
        /// previous contents are deliberately *not* restored in this case, because a
        /// clipboard the user can paste is the difference between recoverable and lost.
        case leftOnClipboard(appName: String)
    }

    /// Inserts `text`, first returning to the app the dictation started in.
    ///
    /// The common case costs nothing: if the user never left, `origin.isFrontmost` is true
    /// and this is the same code path as before.
    @discardableResult
    static func insert(_ text: String, returningTo origin: Origin?) async -> Outcome {
        guard !text.isEmpty else { return .inserted }

        if let origin, !origin.isFrontmost {
            Log.inject.info("user switched away — returning to \(origin.displayName, privacy: .public)")
            guard await restoreFocus(to: origin) else {
                Log.inject.error("could not return to \(origin.displayName, privacy: .public) — leaving the text on the clipboard")
                leaveOnClipboard(text)
                return .leftOnClipboard(appName: origin.displayName)
            }
        }

        insert(text)
        return .inserted
    }

    /// Brings `origin` back to the front, and waits until it actually is.
    ///
    /// Two mechanisms, because one is not enough. `NSRunningApplication.activate()` is the
    /// polite one, but under macOS's cooperative activation a *background* app often cannot
    /// raise another — and Next Notes is always background here, by design: the HUD is a
    /// non-activating panel precisely so focus never leaves the user's field. So when that
    /// is refused, ask the accessibility API instead, which answers to the Accessibility
    /// grant this app already requires in order to see the hotkey at all.
    ///
    /// Polling rather than trusting the return value: activation is asynchronous, and
    /// pasting into an app that has not finished coming forward puts ⌘V somewhere else.
    private static func restoreFocus(to origin: Origin) async -> Bool {
        guard !origin.app.isTerminated else { return false }

        origin.app.activate()
        if await waitUntilFrontmost(origin, within: .milliseconds(600)) { return true }

        let element = AXUIElementCreateApplication(origin.app.processIdentifier)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return await waitUntilFrontmost(origin, within: .milliseconds(400))
    }

    private static func waitUntilFrontmost(_ origin: Origin, within budget: Duration) async -> Bool {
        let step = Duration.milliseconds(25)
        var waited = Duration.zero
        while waited < budget {
            if origin.isFrontmost {
                // Frontmost is not the same as ready for keystrokes: the app still has to
                // restore its own key window and caret. Without this the ⌘V of the
                // pasteboard fallback can arrive before there is anywhere to put it.
                try? await Task.sleep(for: .milliseconds(60))
                return true
            }
            try? await Task.sleep(for: step)
            waited += step
        }
        return false
    }

    /// The last resort: make the text recoverable rather than lost.
    private static func leaveOnClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// A snapshot of the editable selection that was focused when Command Mode began.
    /// Keeping the AX element and range lets us refuse to edit if focus or selection moved
    /// while speech recognition and the model were running.
    struct Selection {
        fileprivate let element: AXUIElement
        fileprivate let range: CFRange
        let text: String
    }

    static func captureSelection() -> Selection? {
        guard let element = focusedElement(),
              let range = selectedRange(of: element),
              range.length > 0,
              let text = selectedText(of: element),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return Selection(element: element, range: range, text: text)
    }

    /// Replaces only the selection captured at command-key down.
    ///
    /// The user may change focus while the model is working. In that case inserting into the
    /// new target would be surprising and destructive, so the edit is abandoned.
    @discardableResult
    static func replace(_ selection: Selection, with text: String) -> Bool {
        guard !text.isEmpty,
              let focused = focusedElement(),
              CFEqual(focused, selection.element),
              let currentRange = selectedRange(of: focused),
              currentRange.location == selection.range.location,
              currentRange.length == selection.range.length,
              selectedText(of: focused) == selection.text
        else { return false }

        insert(text)
        return true
    }

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        switch insertViaAccessibility(text) {
        case .inserted:
            Log.inject.info("inserted via AX (\(text.count) chars)")
        case .unverified(let reason):
            Log.inject.info("AX insert not verified (\(reason, privacy: .public)) — pasting")
            insertViaPasteboard(text)
        }
    }

    private enum AXOutcome {
        case inserted
        case unverified(String)
    }

    // MARK: - Strategy 1: Accessibility, verified

    private static func insertViaAccessibility(_ text: String) -> AXOutcome {
        guard let element = focusedElement() else {
            return .unverified("no focused element")
        }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return .unverified("selected text not settable")
        }

        // Without a readable insertion point there's no way to tell a real insert from a
        // silently-dropped one, so don't gamble — go straight to the fallback.
        guard let before = selectedRange(of: element) else {
            return .unverified("no readable selection range")
        }

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            return .unverified("set attribute failed")
        }

        guard let after = selectedRange(of: element) else {
            return .unverified("selection range unreadable after write")
        }

        // Deliberately a *movement* check, not an exact-length check. Falling back after a
        // write that actually landed would paste the text a second time, and a duplicated
        // paragraph is far worse than a missing one. Some apps normalize newlines or run
        // autocorrect, so the caret can legitimately advance by something other than the
        // UTF-16 count — only a completely unmoved selection proves nothing happened.
        let unchanged = after.location == before.location && after.length == before.length
        guard !unchanged else {
            return .unverified("selection unmoved at \(before.location)")
        }

        return .inserted
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value else { return nil }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    private static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success, let value else { return nil }

        let axValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Strategy 2: Pasteboard + ⌘V

    private static func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        Task { @MainActor in
            // Give the target app a moment to observe the new pasteboard generation before
            // ⌘V arrives, or a fast paste can grab the *previous* contents.
            try? await Task.sleep(for: .milliseconds(40))
            postCommandV()
            Log.inject.info("pasted (\(text.count) chars)")

            // The paste is asynchronous in the target app; restore only once it's had time
            // to read the pasteboard.
            try? await Task.sleep(for: .milliseconds(500))
            restore(saved, to: pasteboard)
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let vKey: CGKeyCode = 9 // kVK_ANSI_V

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        // Set explicitly rather than inheriting live hardware modifier state — the user may
        // still be resting a finger on something.
        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func restore(
        _ saved: [[NSPasteboard.PasteboardType: Data]]?,
        to pasteboard: NSPasteboard
    ) {
        guard let saved, !saved.isEmpty else { return }
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
