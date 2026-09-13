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
        arguments: [String: String]
    ) async throws -> AgentToolResult {
        if await BrowserCDPClient.isReachable() {
            do {
                return try await BrowserCDPClient.run(tool, arguments: arguments)
            } catch {
                Log.agent.info(
                    "browser CDP failed, falling back to Accessibility: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return try BrowserToolExecutor.run(tool, arguments: arguments)
    }
}
