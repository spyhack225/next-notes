import Foundation

struct MCPToolListing: Sendable {
    var name: String
    var description: String
    var inputSchemaJSON: String
    var annotations: [String: String]
}

/// One MCP server connection: `initialize` + session id, then list/call on the same
/// session. Annotations are stored as metadata and never grant permission.
actor MCPSession {
    private(set) var sessionID = ""
    private(set) var didInitialize = false
    private(set) var annotations: [String: [String: String]] = [:]

    private var client: JSONRPCStdioClient?
    private var http: MCPHTTPSession?
    /// JSON Schema types are retained so the string based argument editor can still
    /// produce the JSON values an external server validates (for example, numbers for
    /// `get-sum` in the official Everything server).
    private var argumentTypes: [String: [String: String]] = [:]

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
            rememberArgumentTypes(name: name, raw: tool["inputSchema"] as? [String: Any])
            if !allowlist.isEmpty, !allowlist.contains(name) { continue }
            let schema = tool["inputSchema"] as? [String: Any]
            listed.append(MCPToolListing(
                name: name,
                description: tool["description"] as? String ?? name,
                inputSchemaJSON: MCPInputSchema.jsonString(from: schema),
                annotations: annotations[name] ?? [:]
            ))
        }
        return listed
    }

    func call(name: String, arguments: [String: String], allowlist: [String]) async throws -> String {
        if !allowlist.isEmpty, !allowlist.contains(name) {
            throw AgentError.permissionDenied("\(name) is not on this server's allowlist.")
        }
        let convertedArguments = try typedArguments(arguments, for: argumentTypes[name] ?? [:])
        let convertedArgumentsJSON = try JSONSerialization.data(withJSONObject: convertedArguments)
        let params: [String: Any] = [
            "name": name,
            "arguments": convertedArguments,
        ]
        if let client {
            let data = try await client.request(method: "tools/call", params: params)
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let content = result["content"] as? [[String: Any]] {
                return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            return String(decoding: data, as: UTF8.self)
        }
        if let http {
            let result = try await http.call(name: name, argumentsJSON: convertedArgumentsJSON)
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

    private func rememberArgumentTypes(name: String, raw: [String: Any]?) {
        guard let properties = raw?["properties"] as? [String: Any] else { return }
        var types: [String: String] = [:]
        for (parameter, value) in properties {
            guard let spec = value as? [String: Any] else { continue }
            if let type = spec["type"] as? String {
                types[parameter] = type.lowercased()
            } else if let alternatives = spec["type"] as? [String],
                      let type = alternatives.first(where: { $0.lowercased() != "null" }) {
                types[parameter] = type.lowercased()
            }
        }
        argumentTypes[name] = types
    }

    private func typedArguments(
        _ arguments: [String: String],
        for types: [String: String]
    ) throws -> [String: Any] {
        var converted: [String: Any] = [:]
        for (name, value) in arguments {
            switch types[name] {
            case "integer":
                guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw JSONRPCError(message: "MCP argument \(name) must be an integer.")
                }
                converted[name] = number
            case "number":
                guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw JSONRPCError(message: "MCP argument \(name) must be a number.")
                }
                converted[name] = number
            case "boolean":
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes": converted[name] = true
                case "false", "0", "no": converted[name] = false
                default:
                    throw JSONRPCError(message: "MCP argument \(name) must be true or false.")
                }
            case "array":
                guard let data = value.data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data),
                      let array = decoded as? [Any] else {
                    throw JSONRPCError(message: "MCP argument \(name) must be a JSON array.")
                }
                converted[name] = array
            case "object":
                guard let data = value.data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data),
                      let object = decoded as? [String: Any] else {
                    throw JSONRPCError(message: "MCP argument \(name) must be a JSON object.")
                }
                converted[name] = object
            default:
                converted[name] = value
            }
        }
        return converted
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
        let headerID = headers.first {
            $0.key.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame
        }?.value ?? ""
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let bodyID = (body?["result"] as? [String: Any])?["sessionId"] as? String ?? ""
        sessionID = headerID.isEmpty ? bodyID : headerID
        if sessionID.isEmpty {
            throw AgentError.backendUnavailable("\(server.name) returned no Mcp-Session-Id.")
        }
        _ = try await post(
            MCPJSONRPC.notification(method: "notifications/initialized"),
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

    func call(name: String, argumentsJSON: Data) async throws -> [String: Any] {
        guard let arguments = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            throw AgentError.backendUnavailable("MCP arguments were not a JSON object.")
        }
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
        // Streamable HTTP servers may answer with JSON or an SSE event stream. The
        // protocol requires advertising both; omitting text/event-stream makes the
        // official reference server reject the request with 406.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
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
        let requestID = (try? JSONSerialization.jsonObject(with: body))
            .flatMap { $0 as? [String: Any] }?["id"] as? Int
        return (Self.responseEnvelope(from: data, matching: requestID), headers)
    }

    /// Streamable HTTP commonly wraps a JSON-RPC response in one `message` SSE event.
    /// Keep the JSON path untouched for servers that answer directly with application/json.
    private static func responseEnvelope(from data: Data, matching requestID: Int?) -> Data {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("data:") else {
            return data
        }
        var payloads: [String] = []
        var dataLines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                if !dataLines.isEmpty {
                    payloads.append(dataLines.joined(separator: "\n"))
                    dataLines.removeAll(keepingCapacity: true)
                }
                continue
            }
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("data:") {
                dataLines.append(String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !dataLines.isEmpty { payloads.append(dataLines.joined(separator: "\n")) }
        for payload in payloads {
            guard let payloadData = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData),
                  let envelope = object as? [String: Any] else { continue }
            if let requestID,
               let responseID = envelope["id"] as? Int,
               responseID != requestID {
                continue
            }
            return payloadData
        }
        return data
    }
}
