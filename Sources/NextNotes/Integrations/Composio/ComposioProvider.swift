import Foundation

/// Optional Composio MCP gateway, borrowed from Eveclaw's integration strategy.
/// Native Google Workspace stays first-class; Composio is how GitHub, Slack, Notion and
/// Linear appear without bloating the Swift app.
///
/// This is Composio For You / Connect MCP — not Platform sessions. Sign-in is a browser
/// Authorize link (same device-flow as the CLI). The resulting consumer key is stored in
/// the Keychain and sent as `x-consumer-api-key`. A Platform project key (`ak_…`) will
/// 401 against `connect.composio.dev`.
enum ComposioProvider {
    static let serverName = "Composio"
    static let serverID = "composio"
    static let defaultURL = "https://connect.composio.dev/mcp"

    /// Meta-tools Connect MCP exposes instead of every upstream tool slug.
    static let metaTools: Set<String> = [
        "COMPOSIO_SEARCH_TOOLS",
        "COMPOSIO_GET_TOOL_SCHEMAS",
        "COMPOSIO_MULTI_EXECUTE_TOOL",
        "COMPOSIO_MANAGE_CONNECTIONS",
        "COMPOSIO_WAIT_FOR_CONNECTIONS",
        "COMPOSIO_REMOTE_WORKBENCH",
        "COMPOSIO_REMOTE_BASH_TOOL",
    ]

    @MainActor
    static var consumerKey: String {
        migrateLegacyKeyIfNeeded()
        if let stored = ComposioCredentialStore.apiKey { return stored }
        return Settings.shared.composioAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    static var isSignedIn: Bool { !consumerKey.isEmpty }

    @MainActor
    static var isConfigured: Bool {
        Settings.shared.composioEnabled && isSignedIn
    }

    /// Platform project keys look similar in Settings but are rejected by Connect MCP.
    @MainActor
    static var looksLikePlatformProjectKey: Bool {
        consumerKey.lowercased().hasPrefix("ak_")
    }

    @MainActor
    static func serverConfig() -> MCPServerConfig {
        MCPServerConfig(
            id: serverID,
            name: serverName,
            transport: .http,
            url: Settings.shared.composioURL.isEmpty ? defaultURL : Settings.shared.composioURL,
            headers: ["x-consumer-api-key": consumerKey],
            allowlist: Settings.shared.composioAllowlist,
            enabled: Settings.shared.composioEnabled
        )
    }

    /// Persist the server row. Prefer `connectAndRefresh()` so tools actually register.
    @MainActor
    static func connect() {
        var config = serverConfig()
        config.enabled = true
        MCPClientStore.shared.add(config)
    }

    /// Browser Authorize → Keychain → discover meta-tools.
    @MainActor
    @discardableResult
    static func signInAndRefresh() async throws -> [AgentTool] {
        _ = try await ComposioBrowserAuth.signIn()
        return try await connectAndRefresh()
    }

    @MainActor
    static func signOut() async {
        ComposioCredentialStore.clear()
        Settings.shared.composioAPIKey = ""
        Settings.shared.composioEnabled = false
        await MCPClientStore.shared.close(serverID)
        var servers = MCPClientStore.shared.servers
        servers.removeAll { $0.id == serverID }
        MCPClientStore.shared.replace(servers)
    }

    /// Save the Connect MCP server and discover its meta-tools into the agent registry.
    /// Saving alone used to leave a row in Settings and zero callable tools.
    @MainActor
    @discardableResult
    static func connectAndRefresh() async throws -> [AgentTool] {
        guard isConfigured else { return [] }
        if looksLikePlatformProjectKey {
            throw AgentError.backendUnavailable(
                "Composio Connect needs a consumer key (ck_…), not a Platform project key (ak_…). "
                + "Use Sign in with Composio, or paste a For You key from Sessions & API Key."
            )
        }
        connect()
        let tools = try await MCPClientStore.shared.refresh(serverConfig())
        Log.agent.info("Composio: registered \(tools.count, privacy: .public) tool(s)")
        return tools
    }

    /// Older builds kept the key in UserDefaults. Move it once so MCP never reads
    /// a long-lived secret out of a plist.
    @MainActor
    private static func migrateLegacyKeyIfNeeded() {
        let legacy = Settings.shared.composioAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty, ComposioCredentialStore.apiKey == nil else { return }
        do {
            try ComposioCredentialStore.save(apiKey: legacy)
            Settings.shared.composioAPIKey = ""
        } catch {
            Log.agent.error("Composio Keychain migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
