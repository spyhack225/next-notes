import Foundation

/// Local browser automation, in the order that actually works on a Mac:
///
/// 1. Chrome DevTools Protocol, when Chrome / Edge / Brave is listening on the
///    local debugging port.
/// 2. Accessibility, for Safari and for Chromium that was not launched with
///    `--remote-debugging-port`.
/// 3. Vision (P1-2): a focused-tab screenshot, only after a stub snapshot or with an
///    explicit reason, uploaded to a vision model only with per-run consent. A last
///    resort for pixels AX cannot see — a canvas, a seat-picker — not the default.
enum BrowserBackend: String, Sendable {
    case cdp
    case accessibility
}

enum BrowserExecutor {
    /// Resolve the URL used for browser permission scope before the tool runs.
    /// CDP is authoritative when available; Accessibility is only used when the
    /// debugger is unavailable and BrowserToolExecutor will be the execution path.
    @MainActor
    static func targetURL(for tool: AgentTool, arguments: [String: String]) async -> String? {
        if await BrowserCDPClient.isReachable() {
            return await BrowserCDPClient.targetURL(for: tool, arguments: arguments)
        }
        return BrowserToolExecutor.currentURL()
    }

    static func preferredBackend(
        host: String = BrowserCDPClient.defaultHost,
        port: Int = BrowserCDPClient.defaultPort
    ) async -> BrowserBackend {
        if await BrowserCDPClient.isReachable(host: host, port: port) {
            return .cdp
        }
        return .accessibility
    }

    @MainActor
    static func run(
        _ tool: AgentTool,
        arguments: [String: String],
        host: String = BrowserCDPClient.defaultHost,
        port: Int = BrowserCDPClient.defaultPort
    ) async throws -> AgentToolResult {
        // The purchase gate is backend-independent: the cap is checked before any
        // backend is touched, and nothing runs above it. It sits ahead of the
        // backend pins because a pinned `_browserBackend` must not route a purchase
        // into a backend that knows nothing about the cap.
        if tool.name == "purchase" {
            return try BrowserToolExecutor.run(tool, arguments: arguments)
        }
        if arguments["_browserBackend"] == "accessibility" {
            guard arguments["targetId"] == nil else {
                throw AgentError.backendUnavailable("The authorized browser backend changed. Snapshot again.")
            }
            if let expected = arguments["_authorizedPageURL"] {
                guard BrowserToolExecutor.currentURL() == expected else {
                    throw AgentError.backendUnavailable("The authorized browser page changed. Snapshot again.")
                }
            }
            return try BrowserToolExecutor.run(tool, arguments: arguments)
        }
        if arguments["_browserBackend"] == "cdp" {
            guard await BrowserCDPClient.isReachable(host: host, port: port) else {
                throw AgentError.backendUnavailable("The authorized browser target is no longer available. Snapshot again.")
            }
            return try await BrowserCDPClient.run(tool, arguments: arguments, host: host, port: port)
        }
        // Screenshots prefer CDP's own capture; without a debugger the AX path
        // captures the focused window after checking it is a browser.
        if tool.name == "screenshot" {
            if await BrowserCDPClient.isReachable(host: host, port: port) {
                return try await BrowserCDPClient.run(tool, arguments: arguments, host: host, port: port)
            }
            return try BrowserToolExecutor.runScreenshot(reason: arguments["reason"])
        }
        if await BrowserCDPClient.isReachable(host: host, port: port) {
            // A stale snapshot, ambiguous target, or changed tab is a safety
            // rejection. Falling through to AX after CDP rejects one would turn
            // that rejection into an action on whichever window is now frontmost.
            return try await BrowserCDPClient.run(tool, arguments: arguments, host: host, port: port)
        }
        if ["targetId", "target_id", "browserTargetId", "cdpTargetId"].contains(where: {
            arguments[$0] != nil
        }) {
            // Authorization pinned a CDP tab. If its debugger vanished, AX would
            // act on a different frontmost window while retaining the old grant.
            throw AgentError.backendUnavailable("The authorized browser target is no longer available. Snapshot again.")
        }
        return try BrowserToolExecutor.run(tool, arguments: arguments)
    }
}
