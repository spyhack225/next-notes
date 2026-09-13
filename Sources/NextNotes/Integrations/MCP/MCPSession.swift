import Foundation

struct MCPToolListing: Sendable {
    var name: String
    var description: String
}

/// One MCP server connection: `initialize` + session id, then list/call on the same
/// session. Annotations are stored as metadata and never grant permission.
actor MCPSession {
    private(set) var sessionID = ""
    private(set) var didInitialize = false
    private(set) var annotations: [String: [String: String]] = [:]

    private var client: JSONRPCStdioClient?
    private var http: MCPHTTPSession?

    func connect(_ server: MCPServerConfig) async throws {
        switch server.transport {
        case .stdio:
            try await connectStdio(server)
        case .http:
            try await connectHTTP(server)
        }
    }

    func listTools(allowlist: [String]) async throws -> [MCPToolListing] {
        let raw: [[String: Any]]
        if let client {
            let data = try await client.request(method: "tools/list")
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            raw = object?["tools"] as? [[String: Any]] ?? []
        } else if let http {
            raw = try await http.listTools()
        } else {
            throw AgentError.backendUnavailable("MCP session never initialized.")
        }
        var listed: [MCPToolListing] = []
        for tool in raw {
            guard let name = tool["name"] as? String else { continue }
            rememberAnnotations(name: name, raw: tool)
            if !allowlist.isEmpty, !allowlist.contains(name) { continue }
            listed.append(MCPToolListing(
                name: name,
                description: tool["description"] as? String ?? name
            ))
        }
        return listed
    }

    func call(name: String, arguments: [String: String], allowlist: [String]) async throws -> String {
        if !allowlist.isEmpty, !allowlist.contains(name) {
            throw AgentError.permissionDenied("\(name) is not on this server's allowlist.")
        }
        let params: [String: Any] = ["name": name, "arguments": arguments]
        if let client {
            let data = try await client.request(method: "tools/call", params: params)
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let content = result["content"] as? [[String: Any]] {
                return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            return String(decoding: data, as: UTF8.self)
        }
        if let http {
            let result = try await http.call(name: name, arguments: arguments)
            if let content = result["content"] as? [[String: Any]] {
                return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            return String(describing: result)
        }
        throw AgentError.backendUnavailable("MCP session never initialized.")
    }

    func close() async {
        client?.close()
        client = nil
        http = nil
    }

    private func connectStdio(_ server: MCPServerConfig) async throws {
        guard !server.command.isEmpty else {
            throw AgentError.backendUnavailable("\(server.name) has no command.")
        }
        let client = try JSONRPCStdioClient(command: server.command, arguments: server.arguments)
        self.client = client
        let data = try await client.request(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Next Notes", "version": "2"],
        ], timeout: 15)
        try client.notify(method: "notifications/initialized")
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        sessionID = (result?["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "stdio-\(UUID().uuidString)"
        didInitialize = true
    }

    private func connectHTTP(_ server: MCPServerConfig) async throws {
        let http = MCPHTTPSession(server: server)
        let id = try await http.initialize()
        self.http = http
        sessionID = id
        didInitialize = !id.isEmpty
        if !didInitialize {
            throw AgentError.backendUnavailable("\(server.name) initialized without a session id.")
        }
    }

    private func rememberAnnotations(name: String, raw: [String: Any]) {
        guard let rawAnnotations = raw["annotations"] as? [String: Any] else { return }
        var mapped: [String: String] = [:]
        for (key, value) in rawAnnotations {
            mapped[key] = String(describing: value)
        }
        annotations[name] = mapped
    }
}

/// Streamable HTTP: initialize, then every later call carries `Mcp-Session-Id`.
final class MCPHTTPSession: @unchecked Sendable {
    let server: MCPServerConfig
    private(set) var sessionID = ""

    init(server: MCPServerConfig) {
        self.server = server
    }

    func initialize() async throws -> String {
        let (data, headers) = try await post(
            MCPJSONRPC.request(
                id: 1,
                method: "initialize",
                params: [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "Next Notes", "version": "2"],
                ]
            )
        )
        guard MCPJSONRPC.parseResult(data) != nil else {
            throw AgentError.backendUnavailable("\(server.name) initialize failed.")
        }
        let headerID = headers["Mcp-Session-Id"] ?? headers["mcp-session-id"] ?? ""
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let bodyID = (body?["result"] as? [String: Any])?["sessionId"] as? String ?? ""
        sessionID = headerID.isEmpty ? bodyID : headerID
        if sessionID.isEmpty {
            throw AgentError.backendUnavailable("\(server.name) returned no Mcp-Session-Id.")
        }
        _ = try await post(
            MCPJSONRPC.request(id: 2, method: "notifications/initialized"),
            sessionID: sessionID
        )
        return sessionID
    }

    func listTools() async throws -> [[String: Any]] {
        let (data, _) = try await post(
            MCPJSONRPC.request(id: 3, method: "tools/list"),
            sessionID: sessionID
        )
        return (MCPJSONRPC.parseResult(data)?["tools"] as? [[String: Any]]) ?? []
    }

    func call(name: String, arguments: [String: String]) async throws -> [String: Any] {
        let (data, _) = try await post(
            MCPJSONRPC.request(
                id: 4,
                method: "tools/call",
                params: ["name": name, "arguments": arguments]
            ),
            sessionID: sessionID
        )
        guard let result = MCPJSONRPC.parseResult(data) else {
            throw AgentError.backendUnavailable("\(server.name) returned no result.")
        }
        return result
    }

    private func post(_ body: Data, sessionID: String = "") async throws -> (Data, [String: String]) {
        guard let url = URL(string: server.url) else {
            throw AgentError.backendUnavailable("\(server.name) has no URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in server.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) {
                throw AgentError.backendUnavailable("\(server.name) HTTP \(http.statusCode)")
            }
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
        }
        return (data, headers)
    }
}
