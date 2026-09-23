import AppKit
import ApplicationServices
import Foundation

/// Structured computer control. Accessibility first, screenshots as a last resort —
/// the model clicks an id `inspect_ui` already returned, not a pixel it guessed at,
/// and `screenshot` runs only after a stub tree or with an explicit reason.
enum ComputerToolExecutor {
    private static let inspectLimit = 80

    @MainActor
    static func run(_ tool: AgentTool, arguments: [String: String]) throws -> AgentToolResult {
        switch tool.name {
        case "active_app":
            return AgentToolResult(summary: ComputerContext.current.activeSummary)
        case "windows":
            return AgentToolResult(summary: ComputerContext.current.windowSummary)
        case "inspect_ui":
            return AgentToolResult(summary: inspectUI(verbose: arguments["verbose"]))
        case "screenshot":
            return try screenshot(reason: arguments["reason"])
        case "get_selection":
            return AgentToolResult(summary: ComputerContext.current.selectedText ?? "Nothing is selected.")
        case "clipboard":
            let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AgentToolResult(summary: text.isEmpty ? "The clipboard is empty." : String(text.prefix(2_000)))
        case "open_app":
            return try openApp(arguments["name"] ?? "")
        case "open_url":
            return try openURL(arguments["url"] ?? "")
        case "focus":
            return try focusApp(arguments["name"] ?? "")
        case "click":
            return try click(
                id: arguments["id"] ?? "",
                expectedText: arguments["expectedText"],
                expectedURL: arguments["expectedURL"],
                x: arguments["x"],
                y: arguments["y"],
                reason: arguments["reason"]
            )
        case "press_key":
            return try pressKey(arguments["key"] ?? "", modifiers: arguments["modifiers"])
        case "set_text":
            return try setText(id: arguments["id"] ?? "", text: arguments["text"] ?? "")
        case "type":
            return try type(text: arguments["text"] ?? "", id: arguments["id"])
        case "scroll":
            return try scroll(direction: arguments["direction"] ?? "", amount: arguments["amount"], id: arguments["id"])
        case "drag":
            return try drag(fromId: arguments["fromId"] ?? "", toId: arguments["toId"] ?? "")
        case "double_click":
            return try postedClick(
                id: arguments["id"] ?? "", button: .left, clickCount: 2,
                tool: "computer.double_click", verb: "Double-clicked"
            )
        case "right_click":
            return try postedClick(
                id: arguments["id"] ?? "", button: .right, clickCount: 1,
                tool: "computer.right_click", verb: "Right-clicked"
            )
        case "wait_for":
            return try waitFor(expectedText: arguments["expectedText"] ?? "", timeoutSeconds: arguments["timeoutSeconds"])
        default:
            throw AgentError.unknownTool(tool.id)
        }
    }

    @MainActor
    private static func openApp(_ name: String) throws -> AgentToolResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentError.missingArgument(name: "name", tool: "computer.open_app")
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed)
            ?? Self.applicationURL(named: trimmed)
        guard let url else {
            throw AgentError.noIntegration("No application named \(trimmed) is installed.")
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return AgentToolResult(summary: "Opened \(url.deletingPathExtension().lastPathComponent).")
    }

    @MainActor
    private static func focusApp(_ name: String) throws -> AgentToolResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.localizedCaseInsensitiveContains(trimmed) == true
                || $0.bundleIdentifier?.localizedCaseInsensitiveContains(trimmed) == true
        }
        guard let app = apps.first else {
            return try openApp(trimmed)
        }
        app.activate()
        return AgentToolResult(summary: "Focused \(app.localizedName ?? trimmed).")
    }

    @MainActor
    private static func openURL(_ raw: String) throws -> AgentToolResult {
        guard let url = URL(string: raw), url.scheme != nil else {
            throw AgentError.missingArgument(name: "url", tool: "computer.open_url")
        }
        NSWorkspace.shared.open(url)
        return AgentToolResult(summary: "Opened \(url.absoluteString).")
    }

    @MainActor
    private static func applicationURL(named name: String) -> URL? {
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        for directory in directories {
            let exact = directory.appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: exact.path) { return exact }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            if let match = children.first(where: {
                $0.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private static func type(text: String, id: String?) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        let target = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if target.isEmpty, AccessibilitySnapshot.firstTextFieldID() == nil {
            _ = inspectUI()
        }
        let resolved = target.isEmpty ? AccessibilitySnapshot.firstTextFieldID() : target
        guard let resolved, !resolved.isEmpty else {
            throw AgentError.missingArgument(name: "id", tool: "computer.type")
        }
        return try setText(id: resolved, text: text)
    }

    /// Compact by default, the full tree only when `verbose` asks. Both captures walk
    /// the same tree into the same id map, so an id the compact list prints is the id
    /// click and set_text resolve; only the printed lines differ.
    @MainActor
    private static func inspectUI(verbose rawVerbose: String? = nil) -> String {
        if !Permissions.hasAccessibility {
            _ = Permissions.promptForAccessibility()
        }
        guard Permissions.hasAccessibility else {
            return "Accessibility is not granted, so the window cannot be inspected."
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "No frontmost application."
        }
        let wantsFull = ["true", "1"].contains(
            rawVerbose?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        )
        let snapshot = wantsFull
            ? AccessibilitySnapshot.capture(processID: app.processIdentifier, limit: inspectLimit)
            : AccessibilitySnapshot.captureCompact(processID: app.processIdentifier, limit: inspectLimit)
        if AccessibilitySnapshot.isStub(snapshot) {
            return "\(app.localizedName ?? "The app"): \(snapshot)"
        }
        return snapshot
    }

    @MainActor
    private static func screenshot(reason: String?) throws -> AgentToolResult {
        // Screenshots are a last resort: a stub tree or an explicit reason licenses one,
        // a healthy tree does not. The capture itself is memory-only and needs no
        // consent; uploading it does, and that gate lives with the vision caller.
        guard ScreenshotPolicy.isNeeded(
            snapshotSummary: AccessibilitySnapshot.lastSnapshot, reason: reason
        ) else {
            return AgentToolResult(
                summary: "The accessibility tree already describes this window, so no screenshot was taken. "
                    + "Inspect_ui is enough; pass a reason if pixels are still needed."
            )
        }
        let image = try ScreenCapture.captureFocusedWindowSync()
        ScreenshotStore.store(image, for: "computer.screenshot")
        return AgentToolResult(
            summary: "Screenshot of the focused window "
                + "(\(image.pixelWidth)x\(image.pixelHeight), memory-only, never stored). "
                + "Parked for a vision call; uploading it needs per-run consent."
        )
    }

    @MainActor
    private static func click(
        id: String,
        expectedText: String?,
        expectedURL: String? = nil,
        x: String? = nil,
        y: String? = nil,
        reason: String? = nil
    ) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        // The id wins when both arrive: a stable element reference is the better
        // contract, and a coordinate is the fallback for the UIs the tree cannot
        // describe. Only when there is no id at all does the fraction path run.
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedID.isEmpty, x != nil || y != nil {
            return try clickAtCoordinate(x: x, y: y, reason: reason)
        }
        return try clickElement(
            id: trimmedID, expectedText: expectedText, expectedURL: expectedURL
        )
    }

    /// The pixel fallback: one click at a position a vision model read out of a
    /// consented screenshot.
    ///
    /// The coordinate is a normalized fraction of the image, not a pixel — the parked
    /// capture carries no scale record, and fractions survive any downscale — and it is
    /// mapped onto the focused window's bounds at click time. The screenshot itself may
    /// be seconds old, so this path is honoured only where the element map could not
    /// have answered: the last capture was a stub, or the call carries a reason naming
    /// pixels. AX-first stays the rule; the coordinate is what remains when it is not.
    ///
    /// The click is honest about what it hit: the system-wide element under the point is
    /// read back and named, and a point over nothing resolvable is reported as exactly
    /// that — never as a verified effect.
    @MainActor
    private static func clickAtCoordinate(x: String?, y: String?, reason: String?) throws -> AgentToolResult {
        let fraction = try parseFractions(x: x, y: y)
        let stated = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !AccessibilitySnapshot.isStub(AccessibilitySnapshot.lastSnapshot), stated.isEmpty {
            return AgentToolResult(
                summary: "Coordinates were not used: the accessibility tree already describes "
                    + "this window, so inspect_ui's element ids are the reliable target. "
                    + "Pass an id, or a reason naming why pixels are needed."
            )
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let window = AccessibilitySnapshot.focusedWindowBounds(processID: app.processIdentifier) else {
            throw AgentError.backendUnavailable(
                "The focused window has no position to click at. Inspect the window again."
            )
        }
        // The fraction's origin is the image's top-left; AppKit's origin is the
        // window's bottom-left, so the vertical fraction folds there.
        let point = CGPoint(
            x: window.origin.x + fraction.x * window.width,
            y: window.origin.y + (1 - fraction.y) * window.height
        )
        try AccessibilitySnapshot.postMouseClick(at: point, button: .left, clickCount: 1)
        deliverPostedEvents(within: 0.3)
        let hit = AccessibilitySnapshot.roleAndTitle(at: point)
        let where_ = hit.map { "\(shortName($0.role)) \( $0.title.isEmpty ? "" : "“\(compactLabel($0.title))”" )".trimmingCharacters(in: .whitespaces) }
            ?? "nothing resolvable"
        if let hit {
            return AgentToolResult(
                summary: "Clicked at \(percent(fraction.x)), \(percent(fraction.y)) — on \(where_). "
                    + "Whether that had the wanted effect is for inspect_ui to say.",
                verification: "Coordinate click landed on \(shortName(hit.role))"
            )
        }
        return AgentToolResult(
            summary: "Clicked at \(percent(fraction.x)), \(percent(fraction.y)) — but there is "
                + "nothing resolvable under that point. Re-inspect or take a different approach; "
                + "do not repeat the same coordinates."
        )
    }

    /// Two fractions of the image, both required and both in range. The clamped values a
    /// vision model may hand down are refused here rather than silently moved to the
    /// edge: an out-of-range coordinate is a model error a person should see, not an
    /// edge the executor politely rounds.
    @MainActor
    private static func parseFractions(x: String?, y: String?) throws -> (x: Double, y: Double) {
        func fraction(_ raw: String?, named name: String) throws -> Double {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                throw AgentError.missingArgument(name: name, tool: "computer.click")
            }
            guard let value = Double(trimmed) else {
                throw AgentError.permissionDenied("\(name) must be a number between 0 and 1, like 0.37.")
            }
            guard value >= 0, value <= 1 else {
                throw AgentError.permissionDenied("\(name) must be between 0 and 1 — it is a "
                    + "fraction of the screenshot, not a pixel.")
            }
            return value
        }
        let fx = try fraction(x, named: "x")
        let fy = try fraction(y, named: "y")
        return (fx, fy)
    }

    /// "37%" — coordinate readouts people can check against what the model was shown.
    private static func percent(_ fraction: Double) -> String {
        String(format: "%d%%", Int((fraction * 100).rounded()))
    }

    /// The short role word the snapshot uses, so a coordinate hit is named the way the
    /// tree names it.
    private static func shortName(_ role: String) -> String {
        switch role {
        case "AXButton": "Button"
        case "AXTextArea": "Text area"
        case "AXTextField": "Text field"
        case "AXStaticText": "Text"
        case "AXImage": "Image"
        case "AXCheckBox": "Checkbox"
        case "AXPopUpButton": "Pop-up"
        case "AXLink": "Link"
        default: role
        }
    }

    private static func compactLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    @MainActor
    private static func clickElement(
        id: String,
        expectedText: String?,
        expectedURL: String?
    ) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        let expectation = [expectedText, expectedURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        var lastAfter = ""
        func attempt() throws -> VerifyRetry.Attempt {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  AccessibilitySnapshot.lastProcessID == app.processIdentifier else {
                throw AgentError.backendUnavailable("The inspected window is no longer frontmost. Inspect again.")
            }
            let before = AccessibilitySnapshot.lastSnapshot
            try AccessibilitySnapshot.perform(id: id, action: kAXPressAction as String)
            let afterApp = NSWorkspace.shared.frontmostApplication ?? app
            let after = AccessibilitySnapshot.capture(processID: afterApp.processIdentifier, limit: inspectLimit)
            lastAfter = after
            let changed = !AccessibilitySnapshot.isStub(before)
                && !AccessibilitySnapshot.isStub(after)
                && AccessibilitySnapshot.stableContent(before) != AccessibilitySnapshot.stableContent(after)
            let expectedObserved = expectation.map {
                after.localizedCaseInsensitiveContains($0)
            } ?? false
            return VerifyRetry.Attempt(
                summary: "Clicked element \(id).",
                verification: changed && expectedObserved
                    ? "Computer window reached the expected post-click state" : nil
            )
        }
        // No stated postcondition, no retry: there is nothing to check a second attempt
        // against, and re-pressing a control (a toggle, a submit) can undo the first
        // press. The single attempt keeps the previous contract exactly.
        guard let expectation else {
            let single = try attempt()
            return AgentToolResult(summary: single.summary, verification: single.verification)
        }
        let (attempts, mismatch) = try VerifyRetry.run(
            risk: .modify,
            title: "element \(id)",
            expected: expectation,
            observed: { windowTitle(in: lastAfter) ?? "an unchanged window" },
            reinspect: { _ = inspectUI() },
            act: attempt
        )
        var lines = attempts.map(\.summary)
        if attempts.count > 1, lines.count > 1 {
            lines[1] = lines[1] + " (after re-inspecting)"
        }
        if let mismatch { lines.append(mismatch) }
        return AgentToolResult(
            summary: lines.joined(separator: "\n"),
            verification: attempts.last?.verification
        )
    }

    /// The `Window: …` first line of a snapshot, for the mismatch sentence.
    private static func windowTitle(in snapshot: String) -> String? {
        let first = snapshot.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let prefix = "Window: "
        guard first.hasPrefix(prefix) else { return nil }
        let title = first.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    @MainActor
    private static func setText(id: String, text: String) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              AccessibilitySnapshot.lastProcessID == app.processIdentifier else {
            throw AgentError.backendUnavailable("The inspected window is no longer frontmost. Inspect again.")
        }
        try AccessibilitySnapshot.setValue(id: id, text: text)
        let observed = AccessibilitySnapshot.value(of: id)
        return AgentToolResult(
            summary: "Set the text of element \(id).",
            verification: observed == text ? "Computer field value matches requested text" : nil
        )
    }

    @MainActor
    private static func pressKey(_ key: String, modifiers: String?) throws -> AgentToolResult {
        guard Permissions.hasAccessibility else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        try AccessibilitySnapshot.postKey(key, modifiers: WorkspaceTools.list(modifiers))
        return AgentToolResult(summary: "Pressed \(key).")
    }

    // MARK: - Scroll, drag, pointer variants and waiting (P1.1–P1.2)

    /// Scroll is the first computer action the AX press path cannot express: a scroll
    /// view has no press action to perform. It therefore goes out as real wheel events at
    /// the element's visible centre — the same `CGEvent … post(tap:)` route `postKey`
    /// already uses, with the point taken from the AX position and size attributes rather
    /// than from a guessed pixel. Whether anything actually moved is answered from the
    /// snapshot, never assumed: a scroll whose visible text did not change comes back as
    /// unverified, so the model knows to look rather than to assume it worked.
    @MainActor
    private static func scroll(direction: String, amount: String?, id: String?) throws -> AgentToolResult {
        let app = try guardInspectedFrontmost()
        let scrollDirection = try parseScrollDirection(direction)
        let clicks = try scrollClicks(amount)
        let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetName: String
        let point: CGPoint
        if trimmedID.isEmpty {
            guard let window = AccessibilitySnapshot.focusedWindowBounds(processID: app.processIdentifier) else {
                throw AgentError.backendUnavailable(
                    "The focused window has no position to scroll at. Inspect the window again."
                )
            }
            targetName = "the window centre"
            point = CGPoint(x: window.midX, y: window.midY)
        } else {
            point = try visibleCenter(of: trimmedID)
            targetName = "element \(trimmedID)"
        }
        let before = AccessibilitySnapshot.lastSnapshot
        try AccessibilitySnapshot.postScroll(at: point, direction: scrollDirection, clicks: clicks)
        deliverPostedEvents(within: 0.3)
        let after = AccessibilitySnapshot.capture(processID: app.processIdentifier, limit: inspectLimit)
        let moved = !AccessibilitySnapshot.isStub(before) && !AccessibilitySnapshot.isStub(after)
            && AccessibilitySnapshot.stableContent(before) != AccessibilitySnapshot.stableContent(after)
        if moved {
            return AgentToolResult(
                summary: "Scrolled \(scrollDirection.rawValue) \(clicks) click(s) at \(targetName); the visible text changed.",
                verification: "Computer window's visible content changed after scrolling"
            )
        }
        return AgentToolResult(
            summary: "Scrolled \(scrollDirection.rawValue) \(clicks) click(s) at \(targetName); "
                + "the visible text did not change, so the scroll's effect could not be verified."
        )
    }

    @MainActor
    private static func parseScrollDirection(_ raw: String) throws -> AccessibilitySnapshot.ScrollDirection {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        default:
            throw AgentError.permissionDenied("direction must be up, down, left or right.")
        }
    }

    @MainActor
    private static func scrollClicks(_ raw: String?) throws -> Int {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return 3 }
        guard let amount = Int(trimmed) else {
            throw AgentError.permissionDenied("amount must be a number of wheel clicks, like 3.")
        }
        guard amount >= 1 else {
            throw AgentError.permissionDenied("amount must be at least one wheel click.")
        }
        return min(amount, 30)
    }

    /// A drag between two elements: down at one visible centre, a run of dragged events
    /// across to the other, up there. Posted through the same pointer path as the clicks;
    /// the one thing it cannot do is prove a drop happened, so the result says exactly
    /// what was posted and stops short of a claim — a live drag session has no
    /// accessibility trace this file could check against.
    @MainActor
    private static func drag(fromId rawFrom: String, toId rawTo: String) throws -> AgentToolResult {
        _ = try guardInspectedFrontmost()
        let fromID = try requireElementID(rawFrom, name: "fromId", tool: "computer.drag")
        let toID = try requireElementID(rawTo, name: "toId", tool: "computer.drag")
        let from = try visibleCenter(of: fromID)
        let to = try visibleCenter(of: toID)
        try AccessibilitySnapshot.postMouseDrag(from: from, to: to)
        deliverPostedEvents(within: 0.4)
        return AgentToolResult(
            summary: "Dragged from element \(fromID) to element \(toID) (events posted; "
                + "the effect could not be verified through accessibility)."
        )
    }

    /// Double and right click are the press variants the AX `press` action cannot spell:
    /// it has no click count and no button. They go out as real mouse events at the
    /// element's visible centre, through the same posting route as `press_key`, and the
    /// result does not claim a verified effect — inspect_ui answers whether it did
    /// anything, the way it does for a model's own next move.
    @MainActor
    private static func postedClick(
        id rawID: String,
        button: AccessibilitySnapshot.MouseButton,
        clickCount: Int,
        tool: String,
        verb: String
    ) throws -> AgentToolResult {
        _ = try guardInspectedFrontmost()
        let id = try requireElementID(rawID, name: "id", tool: tool)
        let point = try visibleCenter(of: id)
        try AccessibilitySnapshot.postMouseClick(at: point, button: button, clickCount: clickCount)
        deliverPostedEvents(within: 0.3)
        return AgentToolResult(
            summary: "\(verb) element \(id) at its visible centre; whether that had the wanted "
                + "effect could not be verified through accessibility — inspect_ui to check."
        )
    }

    /// The model's alternative to re-inspecting blindly: poll the focused window until
    /// the text it is waiting for appears, and on timeout say so in words. A timeout is
    /// returned as a failure sentence, never as a verified success, so the loop that
    /// called it is told to change approach rather than to retry the same wait.
    ///
    /// The poll is synchronous inside a main-actor tool call, so the wait pumps the main
    /// run loop between checks — the app, its windows and the accessibility tree stay
    /// alive while it waits, instead of the process freezing for the whole timeout.
    @MainActor
    private static func waitFor(expectedText raw: String, timeoutSeconds rawTimeout: String?) throws -> AgentToolResult {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        let expected = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else {
            throw AgentError.missingArgument(name: "expectedText", tool: "computer.wait_for")
        }
        var timeout = 5.0
        let trimmedTimeout = rawTimeout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTimeout.isEmpty {
            guard let parsed = Double(trimmedTimeout), parsed > 0 else {
                throw AgentError.permissionDenied("timeoutSeconds must be a number of seconds, like 5.")
            }
            timeout = min(parsed, 30)
        }
        let pollInterval = 0.25
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let app = NSWorkspace.shared.frontmostApplication {
                let snapshot = AccessibilitySnapshot.capture(processID: app.processIdentifier, limit: inspectLimit)
                if !AccessibilitySnapshot.isStub(snapshot),
                   snapshot.localizedCaseInsensitiveContains(expected) {
                    return AgentToolResult(
                        summary: "Found “\(expected)” in the focused window.",
                        verification: "Computer window contains the awaited text"
                    )
                }
            }
            guard Date() < deadline else { break }
            deliverPostedEvents(within: min(pollInterval, deadline.timeIntervalSinceNow))
        }
        return AgentToolResult(
            summary: "Waited \(String(format: "%g", timeout))s for “\(expected)” in the focused "
                + "window and it never appeared. Inspect again or take a different approach; "
                + "do not retry this wait."
        )
    }

    /// Every tool that moves something shares one contract, checked here instead of
    /// copied five times: accessibility granted, and the window the ids were read from
    /// still frontmost — otherwise a posted event would land in an app the ids were
    /// never read from, which is the exact failure `click` and `set_text` refuse inline.
    @MainActor
    private static func guardInspectedFrontmost() throws -> NSRunningApplication {
        guard Permissions.hasAccessibility || Permissions.promptForAccessibility() else {
            throw AgentError.permissionDenied("Accessibility is not granted.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              AccessibilitySnapshot.lastProcessID == app.processIdentifier else {
            throw AgentError.backendUnavailable("The inspected window is no longer frontmost. Inspect again.")
        }
        return app
    }

    @MainActor
    private static func requireElementID(_ raw: String, name: String, tool: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw AgentError.missingArgument(name: name, tool: tool)
        }
        return id
    }

    /// A screen point to post a pointer event at, from an element's AX frame. The frame
    /// of a scrollable element can reach far past the window — a text area's frame is as
    /// tall as its content, not as tall as the clip — so the frame is intersected with the
    /// focused window first and the centre taken from the visible remainder. A press at
    /// the unclipped centre would land in whatever app happens to sit below the window.
    @MainActor
    private static func visibleCenter(of id: String) throws -> CGPoint {
        guard let bounds = AccessibilitySnapshot.bounds(of: id) else {
            throw AgentError.backendUnavailable(
                "Element \(id) no longer exposes its position. Inspect the window again."
            )
        }
        let window = NSWorkspace.shared.frontmostApplication.flatMap {
            AccessibilitySnapshot.focusedWindowBounds(processID: $0.processIdentifier)
        }
        let visible = window.map(bounds.intersection) ?? bounds
        guard !visible.isEmpty else {
            throw AgentError.backendUnavailable(
                "Element \(id) is not visible in the focused window. Inspect the window again."
            )
        }
        return CGPoint(x: visible.midX, y: visible.midY)
    }

    /// CGEvents posted at the HID tap reach the app's windows through the main run loop,
    /// and a synchronous tool call blocks exactly that loop. A short pump lets the posted
    /// events arrive before the result is built, so a verification reads the effect and
    /// not the event queue — and the app keeps running while it waits, because the pump
    /// services the ordinary run loop rather than sleeping through it.
    @MainActor
    private static func deliverPostedEvents(within seconds: Double) {
        guard seconds > 0 else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
