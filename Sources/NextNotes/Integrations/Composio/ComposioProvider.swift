import Foundation

/// Optional Composio MCP gateway, borrowed from Eveclaw's integration strategy.
/// Native Google Workspace stays first-class; Composio is how GitHub, Slack, Notion and
/// Linear appear without bloating the Swift app.
enum ComposioProvider {
    static let serverName = "Composio"
    static let defaultURL = "https://connect.composio.dev/mcp"

    @MainActor
    static var isConfigured: Bool {
        Settings.shared.composioEnabled && !Settings.shared.composioAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    static func serverConfig() -> MCPServerConfig {
        MCPServerConfig(
            id: "composio",
            name: serverName,
            transport: .http,
            url: Settings.shared.composioURL.isEmpty ? defaultURL : Settings.shared.composioURL,
            headers: ["x-consumer-api-key": Settings.shared.composioAPIKey],
            allowlist: Settings.shared.composioAllowlist,
            enabled: Settings.shared.composioEnabled
        )
    }

    @MainActor
    static func connect() {
        var config = serverConfig()
        config.enabled = true
        MCPClientStore.shared.add(config)
    }
}
