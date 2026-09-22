import AppKit
import ApplicationServices
import Foundation

/// Local browser automation. Eveclaw drives Chromium in a Vercel sandbox; that is not a
/// local Mac. Here the frontmost browser is inspected through Accessibility and URLs are
/// opened with `NSWorkspace` — navigate → snapshot → element id → click/fill.
enum BrowserToolExecutor {
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
    ]

    @MainActor
    static func run(_ tool: AgentTool, arguments: [String: String]) throws -> AgentToolResult {
        switch tool.name {
        case "navigate", "download":
            return try ComputerToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "computer.open_url")
                    ?? AgentTool.native(
                        namespace: .computer,
                        name: "open_url",
                        description: "",
                        risk: .modify
                    ),
                arguments: ["url": arguments["url"] ?? ""]
            )
        case "snapshot":
            return AgentToolResult(summary: snapshot())
        case "screenshot":
            return try runScreenshot(reason: arguments["reason"])
        case "purchase":
            return try purchase(arguments: arguments)
        case "click":
            return try refLoop(arguments: arguments) { args in
                try ComputerToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "computer.click")
                        ?? AgentTool.native(namespace: .computer, name: "click", description: "", risk: .modify),
                    arguments: args
                )
            }
        case "fill":
            return try refLoop(arguments: arguments) { args in
                try ComputerToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "computer.set_text")
                        ?? AgentTool.native(namespace: .computer, name: "set_text", description: "", risk: .modify),
                    arguments: ["id": args["id"] ?? "", "text": args["text"] ?? ""]
                )
            }
        case "select":
            return try refLoop(arguments: arguments) { args in
                try ComputerToolExecutor.run(
                    AgentToolRegistry.shared.tool(named: "computer.set_text")
                        ?? AgentTool.native(namespace: .computer, name: "set_text", description: "", risk: .modify),
                    arguments: ["id": args["id"] ?? "", "text": args["value"] ?? ""]
                )
            }
        default:
            throw AgentError.unknownTool(tool.id)
        }
    }

    /// Eve loop: snapshot → act on an id from that snapshot → snapshot. A stub tree
    /// never invents ids to click.
    @MainActor
    static func refLoop(
        arguments: [String: String],
        act: ([String: String]) throws -> AgentToolResult
    ) throws -> AgentToolResult {
        // Re-capturing here would invalidate the element ids returned to the model by
        // the preceding snapshot call. Compare against that frozen snapshot instead.
        let before = AccessibilitySnapshot.lastSnapshot
        if AccessibilitySnapshot.isStub(before) || before.contains("not a browser") {
            return AgentToolResult(summary: before)
        }
        let id = arguments["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, before.contains(id) else {
            return AgentToolResult(summary: "No snapshot id \(id.isEmpty ? "(missing)" : id). Snapshot first. \(before)")
        }
        let acted = try act(arguments)
        let observedValue = AccessibilitySnapshot.value(of: id)
        let after = snapshot()
        let requestedValue = arguments["text"] ?? arguments["value"]
        let verified: String?
        if let requestedValue {
            verified = observedValue == requestedValue
                ? "Browser field value matches requested text" : nil
        } else {
            let changed = !AccessibilitySnapshot.isStub(after)
                && AccessibilitySnapshot.stableContent(before) != AccessibilitySnapshot.stableContent(after)
            let expectedText = arguments["expectedText"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedURL = arguments["expectedURL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatches = expectedText.flatMap { $0.isEmpty ? nil : $0 }.map {
                after.localizedCaseInsensitiveContains($0)
            } ?? true
            let urlMatches = expectedURL.flatMap { $0.isEmpty ? nil : $0 }.map {
                currentURL() == $0
            } ?? true
            verified = changed
                && (expectedText?.isEmpty == false || expectedURL?.isEmpty == false)
                && textMatches && urlMatches
                ? "Browser page reached the expected post-click state" : nil
        }
        return AgentToolResult(
            summary: "\(acted.summary)\n---\n\(after)", verification: verified
        )
    }

    @MainActor
    private static func snapshot() -> String {
        guard Permissions.hasAccessibility else {
            return "Accessibility is not granted, so the browser cannot be inspected."
        }
        let app = NSWorkspace.shared.frontmostApplication
        guard let app, let bundle = app.bundleIdentifier, browserBundleIDs.contains(bundle) else {
            let name = app?.localizedName ?? "The frontmost app"
            return "\(name) is not a browser. stub tree, 0 names. No elements were invented."
        }
        let body = AccessibilitySnapshot.capture(processID: app.processIdentifier, limit: 80)
        if AccessibilitySnapshot.isStub(body) {
            return "\(app.localizedName ?? "The browser"): \(body)"
        }
        return body
    }

    // MARK: - Screenshot (P1-2, AX fallback)

    /// Focused-window capture when no CDP debugger is reachable. The frontmost app
    /// must be a browser; anything else refuses rather than screenshotting the
    /// wrong window. Memory only, parked in `ScreenshotStore` for a vision call.
    @MainActor
    static func runScreenshot(reason: String?) throws -> AgentToolResult {
        guard Permissions.hasAccessibility else {
            return AgentToolResult(
                summary: "Accessibility is not granted, so the browser cannot be inspected."
            )
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier, browserBundleIDs.contains(bundle)
        else {
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "The frontmost app"
            return AgentToolResult(
                summary: "\(name) is not a browser. stub tree, 0 names. No screenshot was taken."
            )
        }
        let tree = AccessibilitySnapshot.capture(processID: app.processIdentifier, limit: 80)
        guard ScreenshotPolicy.isNeeded(snapshotSummary: tree, reason: reason) else {
            return AgentToolResult(
                summary: "The snapshot already describes this tab, so no screenshot was taken. "
                    + "Pass a reason if pixels are still needed."
            )
        }
        let image = try ScreenCapture.captureFocusedWindowSync()
        ScreenshotStore.store(image, for: "browser.screenshot:ax")
        return AgentToolResult(
            summary: "Screenshot of \(app.localizedName ?? "the browser") "
                + "(\(image.pixelWidth)x\(image.pixelHeight), memory-only, never stored). "
                + "Parked for a vision call; uploading it needs per-run consent."
        )
    }

    // MARK: - Purchase (D5 cap gate + receipt)

    /// The `browser.purchase` gate. The cap is checked before anything runs: above it
    /// the call throws a denial and nothing is bought. At or under it, the authorized
    /// page is re-checked and a receipt is returned as the run's artifact — the
    /// approved click performs the buy, this is the precondition and the record.
    @MainActor
    private static func purchase(arguments: [String: String]) throws -> AgentToolResult {
        if let problem = BrowserPurchase.problem(arguments: arguments) {
            throw AgentError.permissionDenied(problem)
        }
        if let expected = arguments["_authorizedPageURL"], currentURL() != expected {
            throw AgentError.backendUnavailable("The authorized browser page changed. Snapshot again.")
        }
        let amountCents = BrowserPurchase.cents(arguments["amountCents"]) ?? 0
        let capCents = BrowserPurchase.cents(arguments["capCents"]) ?? 0
        let rawMethod = arguments["paymentRef"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let method = rawMethod.isEmpty ? "the saved payment method" : rawMethod
        let where_ = currentURL() ?? "the browser tab"
        let receipt = "purchase-receipt-\(UUID().uuidString.prefix(8).lowercased())"
        return AgentToolResult(
            summary: "Receipt \(receipt): \(BrowserPurchase.dollars(amountCents)) with \(method), "
                + "inside the \(BrowserPurchase.dollars(capCents)) cap, on \(where_).",
            reference: receipt,
            verification: "Purchase of \(BrowserPurchase.dollars(amountCents)) against a "
                + "\(BrowserPurchase.dollars(capCents)) cap confirmed on \(where_)"
        )
    }

    /// Returns the focused browser document URL for permission scoping when CDP is
    /// unavailable. Accessibility trees expose this on the web area/document node;
    /// the walk is deliberately bounded because it runs before every browser action.
    @MainActor
    static func currentURL() -> String? {
        guard Permissions.hasAccessibility,
              let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier,
              browserBundleIDs.contains(bundle)
        else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success,
              let windowRef
        else { return nil }
        let window = windowRef as! AXUIElement
        return documentURL(in: window, depth: 0)
    }

    private static func documentURL(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        var roleRef: CFTypeRef?
        let hasRole = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRef
        ) == .success
        let role = hasRole ? roleRef as? String : nil
        if role == "AXWebArea" || role == "AXDocument" {
            // Links also expose AXURL. Only a web document's own URL is the
            // domain of the page we are about to inspect or change.
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef) == .success,
               let url = urlRef as? URL, !url.absoluteString.isEmpty {
                return url.absoluteString
            }
            if let url = urlRef as? String, !url.isEmpty { return url }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }
        for child in children.prefix(80) {
            if let url = documentURL(in: child, depth: depth + 1) { return url }
        }
        return nil
    }
}

// MARK: - Purchase cap (shared by the gate and validation)

/// The D5 budget cap as a checkable precondition, not a prompt instruction: amounts in
/// whole cents, `amount > cap` denied in words. Used by the `browser.purchase`
/// executor and by `ToolCallValidation`, so the card and the runtime refuse together.
enum BrowserPurchase {
    static func cents(_ raw: String?) -> Int? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, let value = Int(text), value >= 0
        else { return nil }
        return value
    }

    static func dollars(_ cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100.0)
    }

    /// Nil when the purchase may run. Otherwise the denial sentence, naming the cap.
    static func problem(arguments: [String: String]) -> String? {
        guard let amount = cents(arguments["amountCents"]) else {
            return "\u{201c}Amount\u{201d} is empty or not a number of cents, so nothing was bought."
        }
        guard let cap = cents(arguments["capCents"]) else {
            return "\u{201c}Budget cap\u{201d} is empty or not a number of cents, so nothing was bought."
        }
        if amount > cap {
            return "\(dollars(amount)) is over your \(dollars(cap)) cap. Nothing was bought."
        }
        return nil
    }
}

/// The approval card line for `browser.purchase`: amount, payment method and cap on
/// one line, so the person sees all three before pressing Yes. Referenced from the
/// tool catalogue in `ShellTools.swift`.
enum BrowserPurchaseCard {
    static func preview(for arguments: [String: String]) -> String? {
        let amount = BrowserPurchase.cents(arguments["amountCents"]).map(BrowserPurchase.dollars) ?? "?"
        let cap = BrowserPurchase.cents(arguments["capCents"]).map(BrowserPurchase.dollars) ?? "?"
        let method = arguments["paymentRef"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let methodText = (method?.isEmpty == false) ? method! : "the saved payment method"
        return "Pay \(amount) with \(methodText) (cap \(cap))"
    }
}

// MARK: - D5 scripted flow (owned; wired by the integrator)

/// The flagship demo as a headless script: navigate → snapshot → screenshot →
/// click → verify → cap-check → blocked-without-consent → receipt.
///
/// Pure except for the receipt leg, which runs the real `browser.purchase` gate
/// (it needs no window: only a pinned page URL would require one). The live CDP and
/// window legs stay in `--selftest-browser` / `--selftest-computer` (integration
/// later); what is pinned here is the policy chain that makes those runs meaningful.
enum SeatGridSelfTest {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // Navigate: the fixture is a local file, never a live cinema site.
        guard let fixture = fixtureURL(),
              let html = try? String(contentsOf: fixture, encoding: .utf8)
        else {
            Log.agent.error("seat-grid selftest: fixture Tests/Fixtures/seat-grid.html was not found")
            return false
        }
        // Snapshot: the seat grid exposes stable hooks the snapshot can name.
        check("fixture has no seat grid", html.contains("seat-grid") && html.contains("C1") && html.contains("C2"))
        check("fixture lost its price", html.contains("$33.50"))
        check("fixture lost its cap label", html.contains("$40"))
        check("fixture lost its fake Pay", html.contains("Pay") && html.contains("never charges"))
        check("fixture reaches the network", !html.lowercased().contains("http"))

        // Screenshot: only after a stub tree.
        check("screenshot not licensed after a stub tree",
              ScreenshotPolicy.isNeeded(
                snapshotSummary: "stub tree, 0 names. No elements were invented.", reason: nil))

        // Click → verify: first miss, then success — exactly two attempts, one success.
        var calls = 0
        let retry = try? VerifyRetry.run(
            risk: .modify, title: "C2", expected: "C2 selected",
            observed: { "C1 selected" }, reinspect: {},
            act: {
                calls += 1
                return VerifyRetry.Attempt(
                    summary: "attempt \(calls)",
                    verification: calls >= 2 ? "Browser page reached the expected post-click state" : nil
                )
            }
        )
        check("D5 click did not take exactly 2 attempts",
              calls == 2 && retry?.attempts.count == 2 && retry?.attempts.last?.verification != nil)

        // Cap-check: $33.50 inside the $40 cap passes; $45.00 does not.
        check("in-cap purchase refused",
              BrowserPurchase.problem(arguments: ["amountCents": "3350", "capCents": "4000"]) == nil)
        let over = BrowserPurchase.problem(arguments: ["amountCents": "4500", "capCents": "4000"]) ?? ""
        check("over-cap purchase not denied in words",
              over.contains("over your $40") && over.contains("Nothing was bought"))

        // Blocked without consent: no thumbnail leaves the Mac.
        let blocked = VisionScope.$reader.withValue(nil as LLMProviderID?) {
            VisionScope.maySend(
                LLMImage(data: Data([0x01]), mimeType: "image/jpeg",
                         thumbnail: Data([0x01]), pixelWidth: 1, pixelHeight: 1),
                consent: false
            )
        }
        check("screenshot sent without consent", !blocked)

        // Receipt: the real gate returns a receipt artifact with verification.
        do {
            let receipt = try BrowserToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "browser.purchase")!,
                arguments: ["amountCents": "3350", "capCents": "4000",
                            "paymentRef": "Visa on file"]
            )
            check("receipt has no artifact", receipt.reference?.hasPrefix("purchase-receipt-") == true)
            check("receipt is unverified", receipt.verification != nil)
            check("receipt lost the amount", receipt.summary.contains("$33.50"))
        } catch {
            check("in-cap purchase threw: \(error.localizedDescription)", false)
        }
        do {
            _ = try BrowserToolExecutor.run(
                AgentToolRegistry.shared.tool(named: "browser.purchase")!,
                arguments: ["amountCents": "4500", "capCents": "4000"]
            )
            check("over-cap purchase ran", false)
        } catch let error as AgentError {
            check("over-cap denial lost the cap",
                  error.localizedDescription.contains("over your $40"))
        } catch {
            check("over-cap purchase failed for the wrong reason", false)
        }

        for failure in failures {
            Log.agent.error("seat-grid selftest: \(failure, privacy: .public)")
        }
        return failures.isEmpty
    }

    /// The repo's `Tests/Fixtures/seat-grid.html`, found from this file's own path so
    /// the test runs wherever the checkout lives.
    static func fixtureURL() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("Tests").appendingPathComponent("Fixtures")
                .appendingPathComponent("seat-grid.html")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}
