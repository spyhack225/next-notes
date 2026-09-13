import Foundation

/// Resolves a capability the model asked for to the implementation that should run it.
///
/// Precedence is the v2 contract: native first, then a user-configured MCP server, then
/// Composio, then "ask the user to connect something". A native Gmail send must never fall
/// through to Composio just because that gateway also exposes Gmail.
enum ToolRouter {
    enum Resolution: Sendable, Equatable {
        case tool(String)
        case connect(String)
        case unknown(String)
    }

    @MainActor
    static func resolve(_ name: String, registry: AgentToolRegistry = .shared) -> Resolution {
        if let tool = registry.tool(named: name) {
            return .tool(tool.id)
        }

        let lowered = name.lowercased()
        if looksLikeWorkspace(lowered),
           let native = registry.tools(upTo: .privileged, namespace: .workspace)
            .first(where: { lowered.contains($0.name.lowercased()) }) {
            return .tool(native.id)
        }

        if MCPClientStore.shared.hasServer(for: name) {
            return .connect("An MCP server advertised \(name) but it is not registered yet.")
        }
        if ComposioProvider.isConfigured {
            return .connect("Connect \(name) through Composio in Settings ▸ Integrations.")
        }
        return .unknown(name)
    }

    /// Native Workspace wins over any MCP/Composio alias for the same capability.
    @MainActor
    static func preferNative(among candidates: [AgentTool]) -> AgentTool? {
        let native = candidates.first { $0.source == .native }
        return native ?? candidates.first
    }

    private static func looksLikeWorkspace(_ name: String) -> Bool {
        name.contains("gmail") || name.contains("email") || name.contains("calendar")
            || name.contains("drive") || name.contains("doc") || name.contains("agenda")
    }
}
