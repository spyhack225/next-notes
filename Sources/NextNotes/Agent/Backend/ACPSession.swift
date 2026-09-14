import Foundation

struct AgentBackendEvent: Sendable, Equatable {
    var taskID: String
    var kind: String
    var title: String
    var detail: String
}

/// One ACP stdio session: initialize → session/new → session/prompt, with
/// session/update subscribe and session/request_permission relay.
///
/// Copied from Qwen's `AcpBackendAdapter` / `backend-port.mjs` contract, not its
/// Electron installer. A process that never answers `initialize` is not ACP.
actor ACPSession {
    private(set) var sessionID: String?
    private(set) var didInitialize = false
    private(set) var lastPublicTitle = ""
    private(set) var lastReply = ""
    private(set) var permissionRelayed = false

    private var client: JSONRPCStdioClient?
    private var listeners: [UUID: @Sendable (AgentBackendEvent) -> Void] = [:]
    private var taskID = ""
    private var approvePermissions = false

    func start(
        command: String,
        arguments: [String] = [],
        directory: String? = nil,
        taskID: String,
        approvePermissions: Bool
    ) async throws {
        self.taskID = taskID
        self.approvePermissions = approvePermissions
        let client = try JSONRPCStdioClient(command: command, arguments: arguments, directory: directory)
        self.client = client
        client.onIncoming { [weak self] message in
            await self?.handleIncoming(message) ?? [:]
        }
        client.onNotification { [weak self] message in
            await self?.handleNotification(message)
        }

        _ = try await client.request(method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
            ],
            "clientInfo": ["name": "Next Notes", "version": "2"],
        ], timeout: 15)
        didInitialize = true

        let created = try await client.request(method: "session/new", params: [
            "cwd": directory ?? FileManager.default.currentDirectoryPath,
            "mcpServers": [],
        ])
        let createdMap = (try? JSONSerialization.jsonObject(with: created)) as? [String: Any]
        guard let id = createdMap?["sessionId"] as? String, !id.isEmpty else {
            throw JSONRPCError(message: "ACP session/new returned no sessionId.")
        }
        sessionID = id
    }

    func prompt(_ text: String) async throws -> String {
        guard let client, let sessionID, didInitialize else {
            throw JSONRPCError(message: "ACP session never started.")
        }
        let result = try await client.request(
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": text]],
            ],
            timeout: 90
        )
        let resultMap = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any]
        let stop = resultMap?["stopReason"] as? String ?? ""
        if stop == "cancelled" {
            throw CancellationError()
        }
        return lastReply.isEmpty ? (stop.isEmpty ? "ACP session finished." : stop) : lastReply
    }

    func cancel() async {
        let cancelledTaskID = taskID
        await MainActor.run {
            PermissionGate.shared.cancelPending(taskID: cancelledTaskID)
        }
        guard let client, let sessionID else { return }
        _ = try? await client.request(method: "session/cancel", params: ["sessionId": sessionID])
    }

    func subscribe(_ listener: @escaping @Sendable (AgentBackendEvent) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = listener
        return token
    }

    func unsubscribe(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    func close() async {
        let closedTaskID = taskID
        await MainActor.run {
            PermissionGate.shared.cancelPending(taskID: closedTaskID)
        }
        client?.close()
        client = nil
    }

    private func handleIncoming(_ message: [String: String]) async -> [String: String] {
        let method = message["method"] ?? ""
        if method == "session/request_permission" || method.hasSuffix("request_permission") {
            permissionRelayed = true
            let params = (message["paramsJSON"].flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
            let options = params["options"] as? [[String: Any]] ?? []
            let allow = options.first {
                let kind = ($0["kind"] as? String ?? "").lowercased()
                return kind == "allow_once" || kind == "allow-once"
            }?["optionId"] as? String ?? "allow-once"
            let reject = options.first {
                let kind = ($0["kind"] as? String ?? "").lowercased()
                return kind.contains("reject") || kind.contains("deny")
            }?["optionId"] as? String ?? "reject-once"
            let toolCall = params["toolCall"] as? [String: Any] ?? [:]
            let title = (toolCall["title"] as? String ?? "ACP tool action")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detailData = try? JSONSerialization.data(withJSONObject: toolCall, options: .sortedKeys)
            let detail = detailData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            publish(kind: "permission", title: "Permission required", detail: title)
            if approvePermissions { return ["optionId": allow] }
            // A very large or unparseable request cannot be reviewed faithfully in the
            // Agent pane. Reject it instead of approving an abbreviated operation.
            guard !toolCall.isEmpty, detail.utf8.count <= 8192 else {
                return ["optionId": reject]
            }
            let tool = AgentTool.native(
                namespace: .mcp,
                name: "acp_nested_tool",
                description: "ACP coding agent requested an operation",
                risk: .privileged,
                title: "ACP: \(String(title.prefix(120)))",
                preview: { _ in detail }
            )
            let arguments = ["taskID": taskID, "toolCall": detail]
            let policy = await MainActor.run { PermissionPolicy.fromSettings() }
            let decision = await PermissionBroker.shared.authorize(
                tool, arguments: arguments, policy: policy,
                scope: .any, taskID: taskID
            )
            switch decision {
            case .deny:
                return ["optionId": reject]
            case .allow:
                return ["optionId": allow]
            case .ask(let request):
                let approved = await PermissionGate.shared.ask(request)
                return ["optionId": approved ? allow : reject]
            }
        }
        return [:]
    }

    private func handleNotification(_ message: [String: String]) async {
        let method = message["method"] ?? ""
        guard method == "session/update" || method.hasSuffix("/update") else { return }
        let kind = (message["sessionUpdate"] ?? "").lowercased()
        if kind.contains("thought") {
            return
        }
        var title = message["title"] ?? message["text"] ?? ""
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if kind.contains("message") {
            lastReply += title
        } else {
            lastPublicTitle = title
            publish(kind: "activity", title: title, detail: kind)
        }
    }

    private func publish(kind: String, title: String, detail: String) {
        let event = AgentBackendEvent(taskID: taskID, kind: kind, title: title, detail: detail)
        for listener in listeners.values {
            listener(event)
        }
    }
}
