import AppKit
import ApplicationServices
import Foundation

/// An off-screen window the computer self-test owns, so click/type do not hit Cursor.
///
/// Everything the two computer self-tests drive carries a stable interface identifier,
/// so a failing run can be walked by hand without guessing which view was which. The
/// scrollable text view exists for `--selftest-computer-actions`: its content is long
/// enough that a wheel scroll moves the visible range, and a double click at its centre
/// selects a word — two effects that can be read back without a screenshot.
@MainActor
final class ComputerSelfTestHarness: NSObject {
    private let window: NSWindow
    private let field: NSTextField
    private let textView: NSTextView
    private(set) var buttonClicked = false

    /// The anchor `wait_for` looks for: text in the window that scrolling can never move
    /// or hide, because it sits outside the scroll view.
    static let anchorLabel = "Actions ready."
    /// A token that exists only inside the text view's content, so `id(matching:)` can
    /// never confuse the text view with the label that also names a word.
    static let textToken = "Self-test line 004"

    override init() {
        let field = NSTextField(string: "")
        field.placeholderString = "Type here"
        field.isEditable = true
        field.isSelectable = true
        field.identifier = NSUserInterfaceItemIdentifier("nextnotes-selftest-field")
        self.field = field

        let button = NSButton(title: "OK", target: nil, action: nil)
        button.identifier = NSUserInterfaceItemIdentifier("nextnotes-selftest-ok")

        let label = NSTextField(labelWithString: Self.anchorLabel)
        label.identifier = NSUserInterfaceItemIdentifier("nextnotes-selftest-anchor")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 170))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 378, height: 170))
        text.isEditable = true
        text.isRichText = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        text.identifier = NSUserInterfaceItemIdentifier("nextnotes-selftest-text")
        text.string = (1...80).map { line in
            String(format: "Self-test line %03d keeps scrolling.", line)
        }.joined(separator: "\n")
        scroll.documentView = text
        self.textView = text

        let scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 170)
        scrollHeight.isActive = true

        let stack = NSStackView(views: [field, label, scroll, button])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 400, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Next Notes Computer Self-Test"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.level = .floating
        self.window = window
        super.init()
        button.target = self
        button.action = #selector(clicked)
    }

    func show() {
        // Both order calls: `makeKeyAndOrderFront` can defer to activation, which an
        // agent-launched instance is refused (measured — see `bringToFront`), while
        // `orderFrontRegardless` is the documented way to put an inactive app's window
        // on screen at all. The walk in `--selftest-computer-actions` depends on the
        // window being in the app's accessibility window list, visible or not.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(field)
    }

    /// Whether the harness actually took the foreground, by the two mechanisms the
    /// dictation path already proved (`TextInjector.restoreFocus`): `activate()` first,
    /// then `kAXFrontmostAttribute` on our own app element — macOS's cooperative
    /// activation resists a *background* app raising itself in every agent launch
    /// context (AGENTS.md documents the same resistance), and the accessibility API
    /// answers to the grant the self-test has already required.
    ///
    /// Polling rather than trusting return values, and the failure log names what was
    /// observed, so a red run from `--via-open` says which half refused rather than
    /// sending the walk off to describe whatever app was frontmost.
    func bringToFront(timeout: TimeInterval = 4) -> Bool {
        show()
        NSRunningApplication.current.activate()
        if settle(0.8) { return true }
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if settle(0.8) { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            NSRunningApplication.current.activate()
            if settle(0.25) { return true }
        }
        Log.app.error(
            "selftest computer-actions: foreground refused — isActive \(NSApp.isActive), keyWindow \(self.window.isKeyWindow), frontmost pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)"
        )
        return NSApp.isActive && window.isKeyWindow
    }

    /// Pumps the run loop while the app comes forward, then gives the key window one
    /// extra beat — frontmost is not the same as ready, the same as the paste path.
    private func settle(_ budget: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if NSApp.isActive, window.isKeyWindow {
                RunLoop.main.run(until: Date().addingTimeInterval(0.06))
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    func close() {
        window.orderOut(nil)
    }

    var fieldValue: String { field.stringValue }

    /// Where the top edge of the clip view sits inside the text content. This is the
    /// scroll test's ground truth: a wheel event that scrolls the view changes it, a
    /// wheel event that did nothing leaves it at the same value.
    var scrollOffset: CGFloat {
        textView.enclosingScrollView?.documentVisibleRect.origin.y ?? 0
    }

    /// The length of the text view's selection, for the double-click check: a double
    /// click on a word leaves a non-empty selection behind.
    var selectedLength: Int {
        textView.selectedRange().length
    }

    @objc private func clicked() {
        buttonClicked = true
    }
}

/// The self-test behind `--selftest-computer-actions`.
///
/// Its pass criteria are effects a person could see, observed directly on the window
/// this harness owns: scrolling moved the text view's visible range both ways,
/// `double_click` selected a word, `wait_for` found a label it knew was there — and the
/// timeout case failed exactly as promised rather than claiming success. The drag and
/// the right click post real events but have no drag session or menu to assert on
/// inside this harness, so their results are required to SAY they were unverified (an
/// honest gap beats a green lie) and the run never passes on either of them alone.
@MainActor
enum ComputerActionsSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        guard Permissions.hasAccessibility else {
            print("COMPUTER_ACTIONS_FAILED: Accessibility is not granted, so no mouse, drag or scroll event can be posted.")
            Log.app.error("selftest computer-actions: accessibility not granted")
            return false
        }
        let harness = ComputerSelfTestHarness()
        defer { harness.close() }
        // Best effort, not a gate: an agent-launched instance is refused activation
        // (measured: even the kAXFrontmostAttribute raise comes back isActive false),
        // and every effect this test checks is either readable from the window's own
        // accessibility subtree or lands by screen coordinates on a floating window.
        // A refused raise is logged; it is not a failure.
        if !harness.bringToFront() {
            Log.app.info("selftest computer-actions: activation refused; walking the owned window directly")
        }
        // The window has to be laid out before the first walk, and the pump is the
        // synchronous way to give AppKit that moment.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        do {
            // 400 rather than the live tool's 80: a walk through the text view's own
            // lines must not exhaust the budget before the window's controls are
            // reached. The live payload economy is not this test's problem; missing the
            // harness elements and then describing the menu bar is.
            let snapshot = AccessibilitySnapshot.capture(
                windowTitled: "Next Notes Computer Self-Test",
                processID: ProcessInfo.processInfo.processIdentifier, limit: 400
            )
            guard !AccessibilitySnapshot.isStub(snapshot) else {
                print("COMPUTER_ACTIONS_FAILED: the harness window's tree is a stub: \(snapshot)")
                Log.app.error("selftest computer-actions: stub tree")
                return false
            }
            guard let buttonID = AccessibilitySnapshot.id(matching: "OK"),
                  let anchorID = AccessibilitySnapshot.id(matching: ComputerSelfTestHarness.anchorLabel),
                  let textID = AccessibilitySnapshot.id(matching: ComputerSelfTestHarness.textToken) else {
                print("COMPUTER_ACTIONS_FAILED: inspect did not find the harness elements:\n\(snapshot)")
                Log.app.error("selftest computer-actions: harness elements not found in the walk")
                return false
            }
            check("the label and the text view resolved to one element", anchorID != textID)

            // Scroll down must move the visible range into the content, and scroll up
            // must move it back — both against the clip view's own offset, so a sign
            // error in the wheel event cannot hide behind a neutral comparison.
            let offsetAtTop = harness.scrollOffset
            let scrolledDown = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.scroll")!,
                arguments: ["direction": "down", "amount": "10", "id": textID]
            )
            print(scrolledDown.summary)
            let offsetAfterDown = harness.scrollOffset
            check(
                "scroll down did not move the text view's visible range (\(offsetAtTop) → \(offsetAfterDown))",
                offsetAfterDown > offsetAtTop
            )
            let scrolledUp = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.scroll")!,
                arguments: ["direction": "up", "amount": "5", "id": textID]
            )
            print(scrolledUp.summary)
            check(
                "scroll up did not move back toward the top (\(offsetAfterDown) → \(harness.scrollOffset))",
                harness.scrollOffset < offsetAfterDown
            )

            // The positive wait: the label is in the window, so the wait must find it on
            // its first poll and report that as a verification.
            let waited = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.wait_for")!,
                arguments: ["expectedText": ComputerSelfTestHarness.anchorLabel, "timeoutSeconds": "5"]
            )
            check("wait_for did not find the label that is in the window", waited.verification != nil)

            // The double click: the word under the clip centre becomes the selection.
            let doubleClicked = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.double_click")!,
                arguments: ["id": textID]
            )
            print(doubleClicked.summary)
            check(
                "double_click did not select a word (selection length \(harness.selectedLength))",
                harness.selectedLength > 0
            )

            // The drag: posted, and honestly unverified — a real drop has no
            // accessibility trace this harness could assert on.
            let dragged = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.drag")!,
                arguments: ["fromId": textID, "toId": buttonID]
            )
            print("DRAG_UNVERIFIED: events posted, effect not observable")
            check("drag claimed a verified effect", dragged.verification == nil)
            check("drag did not admit its effect could not be verified", dragged.summary.contains("could not be verified"))

            // The right click on the OK button: it must not have pressed it, which is
            // the one effect of a right press this harness can honestly observe.
            let rightClicked = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.right_click")!,
                arguments: ["id": buttonID]
            )
            print(rightClicked.summary)
            print("RIGHT_CLICK_UNVERIFIED: events posted, effect not observable")
            check("the right click pressed the OK button", !harness.buttonClicked)

            // The negative wait: text that is nowhere in this window. The run EXPECTS
            // the timeout — a claimed success here is the failure the test exists for.
            let timedOut = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.wait_for")!,
                arguments: ["expectedText": "a phrase that is nowhere in this window", "timeoutSeconds": "1"]
            )
            check("wait_for claimed success for text that never appeared", timedOut.verification == nil)
            check(
                "the wait_for timeout did not name its timeout",
                timedOut.summary.contains("Waited") && timedOut.summary.contains("never appeared")
            )
        } catch {
            failures.append("a tool call threw: \(error.localizedDescription)")
        }

        for failure in failures {
            print("COMPUTER_ACTIONS_CHECK_FAILED: \(failure)")
            Log.app.error("selftest computer-actions: \(failure, privacy: .public)")
        }
        return failures.isEmpty
    }
}

/// The self-test behind `--selftest-click-coordinate`.
///
/// The coordinate click is the pixel fallback, so most of its contract is gradeable
/// without a model or a foreground: the fraction grammar refuses out-of-range values
/// before anything is posted, the element id wins over coordinates when both arrive, and
/// the vision hand-off's `target:` parser is a pure function pinned here against canned
/// completions. What a locked screen (or any headless run) cannot grade is whether a
/// posted click landed on the element the model named — that case posts, reports what it
/// could see, and prints `CLICK_COORDINATE_UNVERIFIED` rather than passing on faith.
@MainActor
enum ClickCoordinateSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: The parser, against canned completions — no model, no consent, no screen
        let good = "The page shows a pricing table.\n\nThe control to act on is bottom-left.\n\ntarget: 0.37, 0.62"
        let parsedGood = VisionHandoff.parseTargetLine(from: good)
        check(
            "a clean target line did not parse: \(String(describing: parsedGood))",
            parsedGood.map { abs($0.x - 0.37) < 1e-9 && abs($0.y - 0.62) < 1e-9 } == true
        )
        let spaced = VisionHandoff.parseTargetLine(from: "…\ntarget:  0.40 , 0.60")
        check(
            "spacing was not tolerated: \(String(describing: spaced))",
            spaced.map { abs($0.x - 0.4) < 1e-9 && abs($0.y - 0.6) < 1e-9 } == true
        )
        let clamped = VisionHandoff.parseTargetLine(from: "target: 1.2, 0.5")
        check(
            "an out-of-range target was not clamped: \(String(describing: clamped))",
            clamped.map { $0.x == 1.0 && $0.y == 0.5 } == true
        )
        check(
            "a malformed target line parsed",
            VisionHandoff.parseTargetLine(from: "target: zero, half") == nil
        )
        check(
            "a description without a target parsed as one",
            VisionHandoff.parseTargetLine(from: "A login form with a username field.") == nil
        )
        // The last target line wins: a model that hedges both ways answers with its
        // final word, and an earlier stray line must not move the click.
        let lastWins = VisionHandoff.parseTargetLine(
            from: "target: 0.1, 0.1\nThen the reply continues normally.\ntarget: 0.9, 0.9"
        )
        check(
            "the last target line was not the one taken: \(String(describing: lastWins))",
            lastWins.map { abs($0.x - 0.9) < 1e-9 && abs($0.y - 0.9) < 1e-9 } == true
        )

        // MARK: The executor's contract
        //
        // These run against the real tool entry, with no inspection needed: the range
        // and the missing-argument refusals fire before any window is touched, and the
        // precedence question is answered by which error the call throws — the id path
        // never reaches a fraction sentence, whatever the screen state is.
        do {
            _ = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.click")!,
                arguments: ["x": "1.5", "y": "0.2"]
            )
            check("an out-of-range fraction was accepted", true)
        } catch {
            let sentence = error.localizedDescription
            check(
                "out-of-range refusal said the wrong thing: \(sentence)",
                sentence.contains("0 and 1") && sentence.contains("fraction")
            )
        }
        do {
            _ = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.click")!,
                arguments: ["x": "0.5"]
            )
            check("a lone x with no y was accepted", true)
        } catch {
            check(
                "the missing y did not name its argument: \(error.localizedDescription)",
                error.localizedDescription.contains("y")
            )
        }

        // Precedence: with an id present, the coordinate path must be skipped — whatever
        // error the id path throws on this machine (frontmost, or a bogus id), it must
        // never be the coordinate machinery's.
        do {
            let result = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.click")!,
                arguments: ["id": "1.1", "x": "0.5", "y": "0.5"]
            )
            check("an id-plus-coordinate click claimed the coordinate path: \(result.summary)", false)
        } catch {
            let sentence = error.localizedDescription
            check(
                "the id path was not taken when an id arrived: \(sentence)",
                !sentence.contains("0 and 1") && !sentence.contains("Coordinates were not used")
            )
        }

        // The live case, degraded honestly: with the tree made stub, a legal coordinate
        // reaches the posting path. On a locked screen the focused window may not even
        // resolve — that is an environment answer, not a green lie, so it is reported
        // and not failed.
        _ = AccessibilitySnapshot.capture(
            windowTitled: "Next Notes Computer Self-Test",
            processID: ProcessInfo.processInfo.processIdentifier, limit: 400
        )
        AccessibilitySnapshot.markStubForTesting()
        do {
            let landed = try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.click")!,
                arguments: ["x": "0.5", "y": "0.5", "reason": "the harness window has no labels to click"]
            )
            print(landed.summary)
            if let hit = landed.verification, hit.contains("Coordinate click landed") {
                Log.app.info("selftest click-coordinate: landed and named the element under the point")
            } else {
                print("CLICK_COORDINATE_UNVERIFIED: the landing could not be observed on this session")
            }
        } catch {
            print("CLICK_COORDINATE_UNVERIFIED: the live click could not run — \(error.localizedDescription)")
        }

        for failure in failures {
            print("CLICK_COORDINATE_CHECK_FAILED: \(failure)")
            Log.app.error("selftest click-coordinate: \(failure, privacy: .public)")
        }
        if failures.isEmpty {
            Log.app.info("selftest · CLICK_COORDINATE_OK")
            print("CLICK_COORDINATE_OK")
            return true
        }
        Log.app.error("selftest · CLICK_COORDINATE_FAILED")
        print("CLICK_COORDINATE_FAILED")
        return false
    }
}
