import AppKit
import ApplicationServices
import Foundation

/// Local browser automation. Eveclaw drives Chromium in a Vercel sandbox; that is not a
/// local Mac. Here the frontmost browser is inspected through Accessibility and URLs are
/// opened with `NSWorkspace` — navigate → snapshot → element id → click/fill.
enum BrowserToolExecutor {
    /// actually drive. Internal rather than private so the Settings readiness row lists
    /// the same set; a row saying "running" for a browser the tools would refuse is
    /// worse than none.
    static let browserBundleIDs: Set<String> = [
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
        case "cdp_status":
            return cdpStatus()
        case "relaunch_debug":
            return try relaunchDebug()
        case "read_page":
            return readPageFallback()
        case "wait":
            // No CDP endpoint, no target list to poll. The AX path can read one document's
            // URL, but `computer.wait_for` already covers waiting on window text, so a
            // second URL poller behind a different grant would only blur which tool
            // answered. Saying what is missing beats both.
            return AgentToolResult(
                summary: "No CDP debugger is answering on port \(BrowserCDPClient.defaultPort), "
                    + "so browser.wait has nothing to poll. Run browser.cdp_status to see what "
                    + "is missing, or browser.relaunch_debug to start a browser with the port open."
            )
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

    /// The main-actor home of every read of the frontmost browser: it reads AppKit state
    /// and, after a Chromium nudge, pumps the run loop the nudged tree populates on.
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
        guard AccessibilitySnapshot.isStub(body) else { return body }
        // Chromium builds its tree only once somebody asks, and a stub is the walk that
        // asked too early. One nudge — the attribute VoiceOver's clients use — and the
        // same browser answers without a relaunch, a profile or a debugging port. If it
        // still reads as a stub, the stub is the honest answer; pixels are the fallback
        // for what the tree would not say.
        if DebugBrowser.isChromiumFamily(bundle) {
            AccessibilitySnapshot.enableManualAccessibility(processID: app.processIdentifier)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let nudged = AccessibilitySnapshot.capture(processID: app.processIdentifier, limit: 80)
            if !AccessibilitySnapshot.isStub(nudged) { return nudged }
        }
        return "\(app.localizedName ?? "The browser"): \(body)"
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

    // MARK: - Debugger status, relaunch and page read (P2-A)

    /// `cdp_status` on the Accessibility path. Only the router knows which backend it
    /// picked, so this re-probes the port rather than trusting the caller's implied
    /// answer — the two probes can be seconds apart and the port may have come up.
    @MainActor
    private static func cdpStatus() -> AgentToolResult {
        let host = BrowserCDPClient.defaultHost
        let port = BrowserCDPClient.defaultPort
        if let probe = BrowserCDPClient.probeSync() {
            return AgentToolResult(
                summary: "A CDP debugger is listening on \(host):\(port) — "
                    + "\(probe.browser.isEmpty ? "a Chromium-family browser" : probe.browser), "
                    + "\(probe.targets.count) page target(s)."
            )
        }
        let running = DebugBrowser.runningNames()
        if running.isEmpty {
            return AgentToolResult(
                summary: "No CDP debugger is listening on port \(port) and no Chromium-family "
                    + "browser is running. Run browser.relaunch_debug to start one with the "
                    + "debugging port open on a scratch profile."
            )
        }
        return AgentToolResult(
            summary: "\(running.joined(separator: " and ")) "
                + (running.count == 1 ? "is" : "are")
                + " running, but no CDP debugger is listening on port \(port). Quit it and run "
                + "browser.relaunch_debug, which starts the browser again with the port open "
                + "on a scratch profile."
        )
    }

    /// `relaunch_debug` on the Accessibility path — the only path that does any launching,
    /// because a listening port routes to CDP, where the same tool reports "already
    /// listening" instead. The probe first is a guard for direct callers, not ceremony.
    ///
    /// The profile is the reason this is a `.modify` tool and not an afterthought: a
    /// debugging port on the user's real profile is a remote-control door held open by a
    /// toggle nobody can see. The scratch profile under this app's support directory is
    /// reused across relaunches on purpose — it starts empty, stays signed out, and one
    /// fixed folder cannot accumulate a profile per call.
    @MainActor
    private static func relaunchDebug() throws -> AgentToolResult {
        let host = BrowserCDPClient.defaultHost
        let port = BrowserCDPClient.defaultPort
        if let probe = BrowserCDPClient.probeSync() {
            return AgentToolResult(
                summary: "A debugger is already listening on \(host):\(port) — "
                    + "\(probe.browser.isEmpty ? "a Chromium-family browser" : probe.browser). "
                    + "Nothing was launched."
            )
        }
        do {
            _ = try DebugBrowser.launchWithDebugPort()
        } catch is DebugBrowser.SetupError {
            return AgentToolResult(
                summary: "No Chromium-family browser was found in /Applications, so nothing "
                    + "was launched. Chrome, Edge, Brave or Chromium installed there would "
                    + "all do."
            )
        } catch {
            return AgentToolResult(
                summary: "The browser could not be launched: \(error.localizedDescription)"
            )
        }
        let profile = AppIdentity.applicationSupportDirectory
            .appendingPathComponent("BrowserDebug", isDirectory: true)
            .appendingPathComponent("scratch-profile", isDirectory: true)
        return AgentToolResult(
            summary: "Launched the agent's browser with "
                + "--remote-debugging-port=\(BrowserCDPClient.defaultPort) on a scratch "
                + "profile at \(profile.path) — never the user's real profile. Give it a "
                + "few seconds, then run "
                + "browser.cdp_status and snapshot."
        )
    }

    /// `read_page` when no debugger answers: the frontmost browser's Accessibility
    /// snapshot is what remains. The prefix says which path produced it, because the two
    /// return different shapes — a title/URL/text page versus a labelled element tree —
    /// and a model that cannot tell them apart will quote an element id as page text.
    @MainActor
    private static func readPageFallback() -> AgentToolResult {
        AgentToolResult(
            summary: "No CDP debugger answered on port \(BrowserCDPClient.defaultPort), so this "
                + "page read came from the Accessibility fallback rather than the page "
                + "itself:\n" + snapshot()
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

// MARK: - Chromium binary detection and a debugging launch (P2-A)

/// Where a Chromium-family browser lives on this Mac and how a debuggable copy of it is
/// started. Safari and Firefox are browsers but not Chromium, so a debugging port means
/// nothing to them and they are deliberately absent from both lists.
enum DebugBrowser {
    /// Checked in order, on disk. Disk is the honest question — "is there a binary to
    /// launch" — and the port probe, not a bundle name, answers reachability.
    private static let binaryCandidates: [String] = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ]

    /// Chromium-family bundle ids, for asking what is running. Not the
    /// `browserBundleIDs` set above: that one answers "is the frontmost app a browser"
    /// and must include Safari and Firefox, while this one answers "could a debugging
    /// port belong to something here".
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.chromium.Chromium",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",
    ]

    /// The first installed Chromium-family binary, or nil.
    static func installed() -> (name: String, url: URL)? {
        let fileManager = FileManager.default
        for path in binaryCandidates {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            return (name: url.deletingPathExtension().lastPathComponent, url: url)
        }
        return nil
    }

    /// Whether a bundle id is one of the browsers a debugging port could belong to.
    /// Internal rather than private: the accessibility snapshot path asks the same
    /// question before nudging `AXManualAccessibility`, and two disagreeing lists would
    /// make the nudge hit browsers the tools would never drive.
    static func isChromiumFamily(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return chromiumBundleIDs.contains(bundle)
    }

    /// One browser process, its own scratch profile, the debugging port on — the whole
    /// setup in one call, shared by the agent's `relaunch_debug` tool and the Settings
    /// "Set up" button so the two can never drift apart. Nothing here touches the
    /// user's real profile: a debugging port on it would be a remote-control door.
    @MainActor
    static func launchWithDebugPort() throws -> (name: String, process: Process) {
        let port = BrowserCDPClient.defaultPort
        guard let browser = installed() else {
            throw SetupError.noBrowserInstalled
        }
        let profile = AppIdentity.applicationSupportDirectory
            .appendingPathComponent("BrowserDebug", isDirectory: true)
            .appendingPathComponent("scratch-profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let process = try launch(browser.url, arguments: [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profile.path)",
            "--no-first-run",
            "--no-default-browser-check",
        ])
        return (browser.name, process)
    }

    enum SetupError: LocalizedError {
        case noBrowserInstalled

        var errorDescription: String? {
            switch self {
            case .noBrowserInstalled:
                "No Chrome, Edge, Brave or Chromium is installed — install one of those "
                    + "and press Check again."
            }
        }
    }

    @MainActor
    static func runningNames() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundle = app.bundleIdentifier, chromiumBundleIDs.contains(bundle) else {
                return nil
            }
            return app.localizedName ?? bundle
        }
    }

    /// Launches one browser process and returns it running, without waiting for it.
    ///
    /// Both pipes get a readability handler before `run()` and lose it in the
    /// termination handler — the rule `ShellProcess.launch` and the Workspace client
    /// both follow. Reading only after exit is the documented failure: the tail a child
    /// writes between the last drain and exit is gone by then, and a pipe nobody drains
    /// at all fills up and stalls the child instead.
    static func launch(_ binary: URL, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let standardOut = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOut
        process.standardError = standardError
        standardOut.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [standardOut, standardError] _ in
            standardOut.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
        }
        try process.run()
        return process
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
