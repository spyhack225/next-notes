import Foundation

/// A page the local Chromium debugger advertised.
struct BrowserCDPTarget: Sendable, Equatable {
    var id: String
    var title: String
    var url: String
    var webSocketDebuggerURL: String
}

/// Chrome DevTools Protocol over a local debugging port. Chrome, Edge and Brave
/// expose `/json/list` when launched with `--remote-debugging-port`. Nothing here
/// talks to a cloud vision service.
enum BrowserCDPClient {
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 9222

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
            return BrowserCDPTarget(
                id: item["id"] as? String ?? url,
                title: item["title"] as? String ?? url,
                url: url,
                webSocketDebuggerURL: socket
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

    /// Snapshot / click / fill against the first page target. Throws when the port
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
        let target = probe.targets.first
        switch tool.name {
        case "navigate", "download":
            let url = arguments["url"] ?? ""
            guard let target else {
                return AgentToolResult(summary: "CDP: \(probe.browser). No page target to navigate.")
            }
            let reply = try await command(
                "Page.navigate",
                params: ["url": url],
                webSocketURL: target.webSocketDebuggerURL
            )
            return AgentToolResult(summary: "CDP navigated \(target.title) → \(url). \(reply)")
        case "snapshot":
            guard let target else {
                return AgentToolResult(summary: "CDP: \(probe.browser). No page target.")
            }
            let expression = """
                JSON.stringify((() => {
                  const nodes = [...document.querySelectorAll(
                    'a,button,input,textarea,select,[role=button],[role=link],[role=textbox]'
                  )];
                  return nodes.slice(0, 80).map((el, i) => ({
                    id: String(i + 1),
                    tag: el.tagName.toLowerCase(),
                    text: (el.innerText || el.value || el.getAttribute('aria-label') || '')
                      .trim().slice(0, 80)
                  }));
                })())
                """
            let raw = try await evaluate(expression, webSocketURL: target.webSocketDebuggerURL)
            SnapshotCache.shared.replace(snapshotIDs(in: raw))
            return AgentToolResult(
                summary: "CDP \(target.title) \(target.url)\n\(raw)"
            )
        case "click":
            return try await act(arguments: arguments, target: target, probe: probe) { id, socket in
                try await evaluate(
                    "document.querySelectorAll('a,button,input,textarea,select,[role=button],[role=link],[role=textbox]')[\(max(0, id - 1))]?.click()",
                    webSocketURL: socket
                )
            }
        case "fill", "select":
            let text = arguments["text"] ?? arguments["value"] ?? ""
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return try await act(arguments: arguments, target: target, probe: probe) { id, socket in
                try await evaluate(
                    """
                    (() => {
                      const el = document.querySelectorAll(
                        'a,button,input,textarea,select,[role=button],[role=link],[role=textbox]'
                      )[\(max(0, id - 1))];
                      if (!el) return 'missing';
                      el.focus();
                      el.value = '\(escaped)';
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

    private final class SnapshotCache: @unchecked Sendable {
        static let shared = SnapshotCache()
        private let lock = NSLock()
        private var ids: Set<String> = []

        func replace(_ new: Set<String>) {
            lock.lock()
            ids = new
            lock.unlock()
        }

        func contains(_ id: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.contains(id)
        }

        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.isEmpty
        }
    }

    private static func act(
        arguments: [String: String],
        target: BrowserCDPTarget?,
        probe: Probe,
        body: (Int, String) async throws -> String
    ) async throws -> AgentToolResult {
        guard let target else {
            return AgentToolResult(summary: "CDP: \(probe.browser). No page target.")
        }
        let rawID = arguments["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let id = Int(rawID), id > 0 else {
            return AgentToolResult(summary: "No snapshot id \(rawID.isEmpty ? "(missing)" : rawID). Snapshot first.")
        }
        if !SnapshotCache.shared.isEmpty, !SnapshotCache.shared.contains(rawID) {
            return AgentToolResult(summary: "No snapshot id \(rawID). Snapshot first.")
        }
        let reply = try await body(id, target.webSocketDebuggerURL)
        return AgentToolResult(summary: "CDP \(reply)")
    }

    private static func snapshotIDs(in raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return Set(items.compactMap { $0["id"] as? String })
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
        try await task.send(.data(payload))
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let message = try await task.receive()
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
