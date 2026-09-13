import Foundation

/// One configured MCP server: stdio or Streamable HTTP, with an explicit tool allowlist.
/// Qwen's frontend MCP treats annotations as metadata; Next Notes still runs every
/// discovered tool through `PermissionBroker`.
struct MCPServerConfig: Identifiable, Sendable, Equatable, Codable {
    enum Transport: String, Codable, Sendable {
        case stdio
        case http
    }

    var id: String
    var name: String
    var transport: Transport
    var command: String
    var arguments: [String]
    var url: String
    var headers: [String: String]
    var allowlist: [String]
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        transport: Transport,
        command: String = "",
        arguments: [String] = [],
        url: String = "",
        headers: [String: String] = [:],
        allowlist: [String] = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.headers = headers
        self.allowlist = allowlist
        self.enabled = enabled
    }
}

enum MCPJSONRPC {
    static func request(id: Int, method: String, params: [String: Any] = [:]) -> Data {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if !params.isEmpty { envelope["params"] = params }
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }

    static func parseResult(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any] {
            Log.agent.error("MCP error: \(String(describing: error), privacy: .public)")
            return nil
        }
        return object["result"] as? [String: Any]
    }
}

@MainActor
final class MCPClientStore {
    static let shared = MCPClientStore()

    private(set) var servers: [MCPServerConfig] = []
    private var discovered: [String: (server: MCPServerConfig, tool: AgentTool)] = [:]
    private var sessions: [String: MCPSession] = [:]
    private(set) var lastSessionID = ""
    private(set) var lastDidInitialize = false
    private(set) var lastAnnotations: [String: [String: String]] = [:]

    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("mcp-servers.json")
    }

    private init() {
        servers = Self.load()
    }

    func hasServer(for toolName: String) -> Bool {
        discovered[toolName] != nil || servers.contains { server in
            server.enabled && server.allowlist.contains(where: { $0.localizedCaseInsensitiveCompare(toolName) == .orderedSame })
        }
    }

    func replace(_ servers: [MCPServerConfig]) {
        self.servers = servers
        save()
    }

    func add(_ server: MCPServerConfig) {
        servers.removeAll { $0.id == server.id }
        servers.append(server)
        save()
    }

    func annotations(for toolName: String) -> [String: String] {
        lastAnnotations[toolName] ?? [:]
    }

    func call(tool: AgentTool, arguments: [String: String]) async throws -> AgentToolResult {
        guard let match = discovered[tool.id] ?? discovered[tool.name] else {
            throw AgentError.noIntegration(tool.id)
        }
        if !match.server.allowlist.isEmpty, !match.server.allowlist.contains(tool.name) {
            throw AgentError.permissionDenied("\(tool.name) is not on this server's allowlist.")
        }
        let session = try await session(for: match.server)
        let text = try await session.call(
            name: tool.name,
            arguments: arguments,
            allowlist: match.server.allowlist
        )
        return AgentToolResult(summary: text)
    }

    /// Discover tools on an enabled server and register them. Fails if `initialize`
    /// never completed — encode/decode alone is not a connection.
    func refresh(_ server: MCPServerConfig) async throws -> [AgentTool] {
        let session = try await session(for: server)
        lastDidInitialize = await session.didInitialize
        lastSessionID = await session.sessionID
        lastAnnotations = await session.annotations
        guard lastDidInitialize, !lastSessionID.isEmpty else {
            throw AgentError.backendUnavailable("\(server.name) never initialized an MCP session.")
        }
        let listed = try await session.listTools(allowlist: server.allowlist)
        lastAnnotations = await session.annotations
        var tools: [AgentTool] = []
        for raw in listed {
            let name = raw.name
            let description = raw.description
            let tool = AgentTool(
                id: "mcp.\(server.name).\(name)",
                namespace: .mcp,
                name: name,
                description: description,
                parameters: [],
                risk: .send,
                source: server.name == ComposioProvider.serverName ? .composio : .mcp,
                executionMode: .task,
                titleBuilder: { _ in name },
                previewBuilder: nil
            )
            tools.append(tool)
            discovered[tool.id] = (server, tool)
            discovered[name] = (server, tool)
            AgentToolRegistry.shared.register(tool, aliases: [name])
        }
        return tools
    }

    func close(_ serverID: String) async {
        await sessions[serverID]?.close()
        sessions[serverID] = nil
    }

    private func session(for server: MCPServerConfig) async throws -> MCPSession {
        if let existing = sessions[server.id] {
            if await existing.didInitialize { return existing }
            await existing.close()
        }
        let session = MCPSession()
        try await session.connect(server)
        sessions[server.id] = session
        return session
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(servers) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        Settings.shared.mcpServersJSON = String(data: data, encoding: .utf8) ?? ""
    }

    private static func load() -> [MCPServerConfig] {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: fileURL),
           let servers = try? decoder.decode([MCPServerConfig].self, from: data) {
            return servers
        }
        if let raw = Settings.shared.mcpServersJSON.data(using: .utf8),
           let servers = try? decoder.decode([MCPServerConfig].self, from: raw) {
            return servers
        }
        return []
    }
}
