import Foundation

/// Local browser automation, in the order that actually works on a Mac:
///
/// 1. Chrome DevTools Protocol, when Chrome / Edge / Brave is listening on the
///    local debugging port.
/// 2. Accessibility, for Safari and for Chromium that was not launched with
///    `--remote-debugging-port`.
/// 3. Vision is reserved and is not implemented — it is a last resort, not the
///    default.
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
