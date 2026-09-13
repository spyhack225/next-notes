import Foundation

struct BrowserSnapshotNode: Sendable, Equatable {
    var id: String
    var tag: String
    var text: String
}

/// A page the local Chromium debugger advertised.
struct BrowserCDPTarget: Sendable, Equatable {
    var id: String
    var title: String
    var url: String
    var webSocketDebuggerURL: String
    /// Some browser wrappers expose their active target in `/json/list`; Chromium
    /// itself does not, so the resolver falls back to `document.hasFocus()`.
    var isActive: Bool? = nil
}

/// Chrome DevTools Protocol over a local debugging port. Chrome, Edge and Brave
/// expose `/json/list` when launched with `--remote-debugging-port`. Nothing here
/// talks to a cloud vision service.
enum BrowserCDPClient {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 9222
    private static let snapshotSelector = "a,button,input,textarea,select,[role=button],[role=link],[role=textbox]"
    private static let snapshotExpression = """
        JSON.stringify((() => {
          const nodes = [...document.querySelectorAll('\(snapshotSelector)')];
          return nodes.slice(0, 80).map((el, i) => ({
            id: String(i + 1),
            tag: el.tagName.toLowerCase(),
            text: (el.innerText || el.value || el.getAttribute('aria-label') || '')
              .trim().slice(0, 80)
          }));
        })())
        """

    struct Probe: Sendable, Equatable {
        var browser: String
        var webSocketDebuggerURL: String
        var targets: [BrowserCDPTarget]
    }

    /// Encode one CDP command. Self-tests pin the shape; the live client sends it
    /// over the page's debugger WebSocket.
    static func encode(method: String, params: [String: Any] = [:], id: Int) -> Data {
        var envelope: [String: Any] = [
            "id": id,
            "method": method,
        ]
        if !params.isEmpty { envelope["params"] = params }
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }

    static func parseTargets(_ data: Data) -> [BrowserCDPTarget] {
        let raw: [[String: Any]]
        if let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            raw = array
        } else if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let array = object["targets"] as? [[String: Any]] {
            raw = array
        } else {
            return []
        }
        return raw.compactMap { item in
            let type = (item["type"] as? String ?? "page").lowercased()
            guard type == "page" || type == "tab" else { return nil }
            let url = item["url"] as? String ?? ""
            let socket = item["webSocketDebuggerUrl"] as? String ?? ""
            guard !socket.isEmpty else { return nil }
            // CDP ids are stable within a browser session. If a wrapper omits one,
            // use its socket URL so two same-URL tabs cannot share a cache slot.
            let advertisedID = (item["id"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let id = advertisedID.isEmpty ? socket : advertisedID
            return BrowserCDPTarget(
                id: id,
                title: item["title"] as? String ?? url,
                url: url,
                webSocketDebuggerURL: socket,
                isActive: item["active"] as? Bool
            )
        }
    }

    static func parseVersion(_ data: Data) -> (browser: String, webSocketDebuggerURL: String)? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let browser = object["Browser"] as? String ?? object["browser"] as? String ?? ""
        let socket = object["webSocketDebuggerUrl"] as? String ?? ""
        guard !browser.isEmpty || !socket.isEmpty else { return nil }
        return (browser, socket)
    }

    static func probe(host: String = defaultHost, port: Int = defaultPort) async -> Probe? {
        guard let versionURL = URL(string: "http://\(host):\(port)/json/version"),
              let listURL = URL(string: "http://\(host):\(port)/json/list")
                ?? URL(string: "http://\(host):\(port)/json")
        else {
            return nil
        }
        do {
            let versionData = try await get(versionURL)
            guard let version = parseVersion(versionData) else { return nil }
            let listData = (try? await get(listURL)) ?? Data()
            let targets = parseTargets(listData)
            return Probe(
                browser: version.browser,
                webSocketDebuggerURL: version.webSocketDebuggerURL,
                targets: targets
            )
        } catch {
            return nil
        }
    }

    static func listTargets(baseURL: URL) async throws -> [BrowserCDPTarget] {
        let list = baseURL.appending(path: "json/list")
        let data = try await get(list)
        let parsed = parseTargets(data)
        if !parsed.isEmpty { return parsed }
        let fallback = try await get(baseURL.appending(path: "json"))
        return parseTargets(fallback)
    }

    static func isReachable(host: String = defaultHost, port: Int = defaultPort) async -> Bool {
        await probe(host: host, port: port) != nil
    }

    /// Snapshot / click / fill against the active page target. Throws when the port
    /// is closed so the caller can fall through to Accessibility.
    static func run(
        _ tool: AgentTool,
        arguments: [String: String],
        host: String = defaultHost,
        port: Int = defaultPort
    ) async throws -> AgentToolResult {
        guard let probe = await probe(host: host, port: port) else {
            throw AgentError.backendUnavailable("No local browser debugger on port \(port).")
        }
        let target = try await resolveTarget(for: tool, arguments: arguments, from: probe.targets)
        switch tool.name {
        case "navigate", "download":
            let url = arguments["url"] ?? ""
            let reply = try await command(
                "Page.navigate",
                params: ["url": url],
                webSocketURL: target.webSocketDebuggerURL
            )
            return AgentToolResult(summary: "CDP navigated \(target.title) → \(url). \(reply)")
        case "snapshot":
            let raw = try await evaluate(snapshotExpression, webSocketURL: target.webSocketDebuggerURL)
            SnapshotCache.shared.replace(
                target,
                with: snapshotNodes(in: raw)
            )
            return AgentToolResult(
                summary: "CDP targetId: \(target.id) \(target.title) \(target.url)\n\(raw)"
            )
        case "click":
            return try await act(
                arguments: arguments,
                target: target
            ) { id, socket in
                try await evaluate(
                    "document.querySelectorAll('a,button,input,textarea,select,[role=button],[role=link],[role=textbox]')[\(max(0, id - 1))]?.click()",
                    webSocketURL: socket
                )
            }
        case "fill", "select":
            let text = arguments["text"] ?? arguments["value"] ?? ""
            let encoded = jsonStringLiteral(text)
            return try await act(arguments: arguments, target: target) { id, socket in
                try await evaluate(
                    """
                    (() => {
                      const el = document.querySelectorAll(
                        '\(snapshotSelector)'
                      )[\(max(0, id - 1))];
                      if (!el) return 'missing';
                      el.focus();
                      el.value = \(encoded);
                      el.dispatchEvent(new Event('input', { bubbles: true }));
                      el.dispatchEvent(new Event('change', { bubbles: true }));
                      return 'filled';
                    })()
                    """,
                    webSocketURL: socket
                )
            }
        default:
            throw AgentError.unknownTool(tool.id)
        }
    }

    // MARK: - Session

    final class SnapshotCache: @unchecked Sendable {
        static let shared = SnapshotCache()
        struct SnapshotState: Sendable {
            var url: String
            var webSocketDebuggerURL: String = ""
            var nodes: [String: BrowserSnapshotNode]
        }
        private let lock = NSLock()
        private var states: [String: SnapshotState] = [:]

        func replace(_ target: BrowserCDPTarget, with nodes: [BrowserSnapshotNode]) {
            lock.lock()
            states[target.id] = SnapshotState(
                url: target.url,
                webSocketDebuggerURL: target.webSocketDebuggerURL,
                nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            )
            lock.unlock()
        }

        func snapshot(for target: BrowserCDPTarget) -> SnapshotState? {
            lock.lock()
            defer { lock.unlock() }
            return states[target.id]
        }

        func node(for id: String, in target: BrowserCDPTarget) -> BrowserSnapshotNode? {
            lock.lock()
            defer { lock.unlock() }
            return states[target.id]?.nodes[id]
        }

        func remove(_ target: BrowserCDPTarget) {
            lock.lock()
            states.removeValue(forKey: target.id)
            lock.unlock()
        }

        func isEmpty(for target: BrowserCDPTarget) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return states[target.id]?.nodes.isEmpty ?? true
        }

        func contains(_ id: String, in target: BrowserCDPTarget) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return states[target.id]?.nodes.keys.contains(id) ?? false
        }

        func url(for target: BrowserCDPTarget) -> String {
            lock.lock()
            defer { lock.unlock() }
            return states[target.id]?.url ?? ""
        }
    }

    /// Returns the URL of the page that this browser tool would act on. Permission
    /// authorization calls this before execution so a standing domain grant is tied to
    /// the actual tab rather than the frontmost application or an arbitrary list item.
    static func targetURL(
        for tool: AgentTool,
        arguments: [String: String],
        host: String = defaultHost,
        port: Int = defaultPort
    ) async -> String? {
        guard let probe = await probe(host: host, port: port) else { return nil }
        return try? await resolveTarget(for: tool, arguments: arguments, from: probe.targets).url
    }

    /// Resolves the target identity once so authorization and execution can carry the
    /// same tab through a focus change between those two steps.
    static func targetID(
        for tool: AgentTool,
        arguments: [String: String],
        host: String = defaultHost,
        port: Int = defaultPort
    ) async -> String? {
        guard let probe = await probe(host: host, port: port) else { return nil }
        return try? await resolveTarget(for: tool, arguments: arguments, from: probe.targets).id
    }

    private static func resolveTarget(
        for tool: AgentTool,
        arguments: [String: String],
        from targets: [BrowserCDPTarget]
    ) async throws -> BrowserCDPTarget {
        if let explicit = first(arguments, keys: ["targetId", "target_id", "browserTargetId", "cdpTargetId"]) {
            if let target = targets.first(where: { $0.id == explicit }) {
                return target
            }
            throw AgentError.backendUnavailable("CDP target id “\(explicit)” was not found. Snapshot again and use that id.")
        }

        guard targets.count == 1, let target = targets.first else {
            let advertised = targets.filter { $0.isActive == true }
            if advertised.count == 1 { return advertised[0] }

            // `/json/list` has no active-tab field. Ask every page directly; only a
            // unique focused/visible page is safe to select. List order is not a
            // focus signal and must never decide where a click or fill goes.
            let states = await withTaskGroup(of: (Int, String?).self, returning: [(Int, String?)].self) { group in
                for (index, target) in targets.enumerated() {
                    group.addTask {
                        let state = try? await evaluate(
                            "document.hasFocus() ? 'focused' : (document.visibilityState === 'visible' ? 'visible' : 'background')",
                            webSocketURL: target.webSocketDebuggerURL
                        )
                        return (index, state?.lowercased())
                    }
                }
                var result: [(Int, String?)] = []
                for await item in group { result.append(item) }
                return result.sorted { $0.0 < $1.0 }
            }
            let focused = states.compactMap { index, state in
                state == "focused" ? targets[index] : nil
            }
            if focused.count == 1 { return focused[0] }

            let visible = states.compactMap { index, state in
                state == "visible" ? targets[index] : nil
            }
            if visible.count == 1 { return visible[0] }

            let choices = targets.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")
            throw AgentError.backendUnavailable(
                focused.isEmpty
                    ? "CDP target could not identify the active browser tab. Choose targetId from: \(choices)."
                    : "CDP target is ambiguous (multiple focused browser tabs are open). Choose targetId from: \(choices)."
            )
        }
        return target
    }

    private static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let absolute = url.absoluteString.removingPercentEncoding {
            return absolute.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        }
        return trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    private static func first(_ arguments: [String: String], keys: [String]) -> String? {
        for key in keys {
            let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func jsonStringLiteral(_ raw: String) -> String {
        if let data = try? JSONEncoder().encode(raw),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\"\""
    }

    static func replaceSnapshotCache(for target: BrowserCDPTarget, with nodes: [BrowserSnapshotNode]) {
        SnapshotCache.shared.replace(target, with: nodes)
    }

    static func removeSnapshotCache(for target: BrowserCDPTarget) {
        SnapshotCache.shared.remove(target)
    }

    private static func act(
        arguments: [String: String],
        target: BrowserCDPTarget,
        body: (Int, String) async throws -> String
    ) async throws -> AgentToolResult {
        let rawID = arguments["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let id = Int(rawID), id > 0 else {
            return AgentToolResult(summary: "No snapshot id \(rawID.isEmpty ? "(missing)" : rawID). Snapshot first.")
        }
        guard let snapshot = SnapshotCache.shared.snapshot(for: target), !snapshot.nodes.isEmpty else {
            return AgentToolResult(summary: "No snapshot for target id \(target.id). Snapshot first.")
        }
        if normalize(snapshot.url) != normalize(target.url) {
            return AgentToolResult(summary: "Snapshot no longer matches this tab. Snapshot first.")
        }
        if !snapshot.webSocketDebuggerURL.isEmpty,
           snapshot.webSocketDebuggerURL != target.webSocketDebuggerURL {
            return AgentToolResult(summary: "Snapshot no longer matches this tab. Snapshot first.")
        }
        if !SnapshotCache.shared.contains(rawID, in: target) {
            return AgentToolResult(summary: "No snapshot id \(rawID). Snapshot first.")
        }
        guard let cached = SnapshotCache.shared.node(for: rawID, in: target) else {
            return AgentToolResult(summary: "No snapshot id \(rawID). Snapshot first.")
        }

        let currentRaw = try await evaluate(snapshotExpression, webSocketURL: target.webSocketDebuggerURL)
        let currentNodes = snapshotNodes(in: currentRaw)
        guard let current = currentNodes.first(where: { $0.id == rawID }) else {
            return AgentToolResult(summary: "Snapshot id \(rawID) is stale for this tab. Snapshot first.")
        }
        if current != cached {
            return AgentToolResult(summary: "Snapshot id \(rawID) is stale for this tab. Snapshot first.")
        }
        let reply = try await body(id, target.webSocketDebuggerURL)
        return AgentToolResult(summary: "CDP \(reply)")
    }

    private static func snapshotNodes(in raw: String) -> [BrowserSnapshotNode] {
        guard let data = raw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return items.compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return BrowserSnapshotNode(
                id: id,
                tag: ($0["tag"] as? String ?? "").lowercased(),
                text: ($0["text"] as? String ?? "")
            )
        }
    }

    private static func evaluate(_ expression: String, webSocketURL: String) async throws -> String {
        let raw = try await command(
            "Runtime.evaluate",
            params: ["expression": expression, "returnByValue": true],
            webSocketURL: webSocketURL
        )
        return raw
    }

    private static func command(
        _ method: String,
        params: [String: Any],
        webSocketURL: String
    ) async throws -> String {
        guard let url = URL(string: webSocketURL) else {
            throw AgentError.backendUnavailable("Browser debugger URL was empty.")
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let id = Int.random(in: 1...10_000)
        let payload = encode(method: method, params: params, id: id)
        let didSend = await withBoundedWait(.seconds(4)) { () -> Bool in
            do {
                try await task.send(.data(payload))
                return true
            } catch {
                return false
            }
        }
        guard didSend == true else {
            throw AgentError.backendUnavailable("Browser debugger did not accept \(method).")
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            // `receive()` itself has no deadline. A debugger that accepts the
            // socket but never replies must not park authorization forever.
            let received = await withBoundedWait(.seconds(4)) { () -> URLSessionWebSocketTask.Message? in
                try? await task.receive()
            }
            guard let message = received ?? nil else {
                throw AgentError.backendUnavailable("Browser debugger did not answer \(method).")
            }
            let data: Data
            switch message {
            case .data(let value):
                data = value
            case .string(let value):
                data = Data(value.utf8)
            @unknown default:
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["id"] as? Int) == id
            else {
                continue
            }
            if let error = object["error"] as? [String: Any] {
                throw AgentError.backendUnavailable(String(describing: error))
            }
            if let result = object["result"] as? [String: Any] {
                if let inner = result["result"] as? [String: Any],
                   let value = inner["value"] {
                    return String(describing: value)
                }
                if let text = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                   let string = String(data: text, encoding: .utf8) {
                    return string
                }
            }
            return String(decoding: data, as: UTF8.self)
        }
        throw AgentError.backendUnavailable("Browser debugger did not answer \(method).")
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AgentError.backendUnavailable("Browser debugger HTTP \(http.statusCode)")
        }
        return data
    }
}
