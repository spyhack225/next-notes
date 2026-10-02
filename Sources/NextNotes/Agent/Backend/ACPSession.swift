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
/// Copied from the local model's `AcpBackendAdapter` / `backend-port.mjs` contract, not its
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
    // Captured by the normal typed backend; transport callbacks have no task-local owner.
    // This is live admission, never authority derived from a LAST diagnostic cache.
    private var taskContext: TaskJournalContext?
    // Gate's Bool conflates decline and cancellation. This existing Session owns
    // the current prompt cancellation before the MainActor hop releases its waiter.
    private var promptCancellationRequested = false

    func start(
        command: String,
        arguments: [String] = [],
        directory: String? = nil,
        taskID: String,
        approvePermissions: Bool,
        taskContext: TaskJournalContext? = nil
    ) async throws {
        self.taskID = taskID
        self.approvePermissions = approvePermissions
        self.taskContext = taskContext
        let client = try JSONRPCStdioClient(command: command, arguments: arguments, directory: directory)
        self.client = client
        client.onIncoming { [weak self] message in
            await self?.handleIncoming(message) ?? Data("{}".utf8)
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
        promptCancellationRequested = false
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
        promptCancellationRequested = true
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
        promptCancellationRequested = true
        let closedTaskID = taskID
        await MainActor.run {
            PermissionGate.shared.cancelPending(taskID: closedTaskID)
        }
        client?.close()
        client = nil
    }

    private func handleIncoming(_ message: [String: String]) async -> Data {
        let method = message["method"] ?? ""
        if method == "session/request_permission" || method.hasSuffix("request_permission") {
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
            guard let sessionID, !sessionID.isEmpty,
                  let incomingID = params["sessionId"] as? String,
                  incomingID == sessionID else { return Self.selectedPermissionResult(reject) }
            guard !promptCancellationRequested else { return Self.cancelledPermissionResult }
            let boundPolicy: PermissionPolicy?
            if let context = taskContext {
                guard context.taskID == taskID, context.attempt > 0,
                      context.leaseOwner == String(ProcessInfo.processInfo.processIdentifier),
                      context.isStillValid != nil else { return Self.selectedPermissionResult(reject) }
                // Reuse the existing policy hop to check the exact live handle and
                // current primary attempt before any relay or fast permission reply.
                boundPolicy = await MainActor.run {
                    guard context.isStillValid?() == true else { return nil }
                    return PermissionPolicy.fromSettings()
                }
                guard boundPolicy != nil else { return Self.selectedPermissionResult(reject) }
                guard !promptCancellationRequested else { return Self.cancelledPermissionResult }
            } else { boundPolicy = nil }
            permissionRelayed = true
            let toolCall = params["toolCall"] as? [String: Any] ?? [:]
            let title = (toolCall["title"] as? String ?? "ACP tool action")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detailData = try? JSONSerialization.data(withJSONObject: toolCall, options: .sortedKeys)
            let detail = detailData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            publish(kind: "permission", title: "Permission required", detail: title)
            if approvePermissions { return Self.selectedPermissionResult(allow) }
            // A very large or unparseable request cannot be reviewed faithfully in the
            // Agent pane. Reject it instead of approving an abbreviated operation.
            guard !toolCall.isEmpty, detail.utf8.count <= 8192 else {
                return Self.selectedPermissionResult(reject)
            }
            let tool = AgentTool.native(
                namespace: .mcp,
                name: "acp_nested_tool",
                description: "ACP coding agent requested an operation",
                risk: .privileged,
                title: "ACP: \(String(title.prefix(120)))",
                preview: { _ in detail }
            )
            let arguments = ["toolCall": detail]
            let policy: PermissionPolicy
            if let boundPolicy { policy = boundPolicy }
            else { policy = await MainActor.run { PermissionPolicy.fromSettings() } }
            guard !promptCancellationRequested else { return Self.cancelledPermissionResult }
            let decision = await PermissionBroker.shared.authorize(
                tool, arguments: arguments, policy: policy,
                scope: .any, taskID: taskID
            )
            guard !promptCancellationRequested else { return Self.cancelledPermissionResult }
            switch decision {
            case .deny:
                return Self.selectedPermissionResult(reject)
            case .allow:
                return Self.selectedPermissionResult(allow)
            case .ask(let request), .askLocal(let request):
                // This callback runs outside the parent task. Rebind only its exact
                // captured normal typed context at the existing approval boundary.
                let context = taskContext
                let approved = await TaskEventJournal.$current.withValue(context) { @MainActor in
                    let approved = await PermissionGate.shared.ask(request)
                    guard approved else { return false }
                    // A committed approval is historical once its worker is held.
                    // Reuse this existing Gate await to check the live primary owner
                    // before passing authorization back to the protocol consumer.
                    guard let context else { return true }
                    return context.isStillValid?() == true
                }
                guard !promptCancellationRequested else { return Self.cancelledPermissionResult }
                return Self.selectedPermissionResult(approved ? allow : reject)
            }
        }
        return Data("{}".utf8)
    }

    private static let cancelledPermissionResult = Data(
        #"{"outcome":{"outcome":"cancelled"}}"#.utf8)

    private static func selectedPermissionResult(_ optionID: String) -> Data {
        // JSON encoding preserves the actual offered ID, including escaping.
        (try? JSONSerialization.data(withJSONObject:
            ["outcome": ["outcome": "selected", "optionId": optionID]]))
            ?? cancelledPermissionResult
    }

    private func handleNotification(_ message: [String: String]) async {
        let method = message["method"] ?? ""
        guard method == "session/update" || method.hasSuffix("/update") else { return }
        let params = (message["paramsJSON"].flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        guard let sessionID, !sessionID.isEmpty,
              let incomingID = params["sessionId"] as? String,
              incomingID == sessionID else { return }
        let kind = (message["sessionUpdate"] ?? "").lowercased()
        if kind.contains("thought") {
            return
        }
        let raw = message["text"] ?? message["title"] ?? ""
        if kind.contains("message") {
            // ACP message chunks are deltas; their whitespace belongs to the
            // sentence. Trimming each delta produced "Gotit…Whatwouldyou…".
            lastReply += raw
        } else {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
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
