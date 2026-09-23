import AppKit
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
        // `wait` is exempt from the pinned-page check on purpose: the page moving is what it
        // exists to observe, and its authorized URL is captured before the navigation it is
        // waiting for — pinning it there would turn the tool's own subject into a rejection.
        if tool.name != "navigate" && tool.name != "download" && tool.name != "wait",
           let authorizedURL = arguments["_authorizedPageURL"],
           target.url != authorizedURL {
            throw AgentError.backendUnavailable(
                "The authorized browser page changed. Snapshot again before acting."
            )
        }
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
            let accessibility = try? await command(
                "Accessibility.getFullAXTree",
                params: [:],
                webSocketURL: target.webSocketDebuggerURL
            )
            let accessibilityText = accessibilitySummary(accessibility)
            return AgentToolResult(
                summary: "CDP targetId: \(target.id) \(target.title) \(target.url)\nDOM:\n\(raw)\nAccessibility:\n\(accessibilityText)"
            )
        case "click":
            return try await act(
                arguments: arguments,
                target: target,
                retryAllowed: tool.risk <= .modify
            ) { id, socket in
                try await evaluate(
                    "document.querySelectorAll('a,button,input,textarea,select,[role=button],[role=link],[role=textbox]')[\(max(0, id - 1))]?.click()",
                    webSocketURL: socket
                )
            }
        case "screenshot":
            return try await captureScreenshot(arguments: arguments, target: target)
        case "cdp_status":
            return AgentToolResult(
                summary: "A CDP debugger is listening on \(host):\(port) — "
                    + "\(probe.browser.isEmpty ? "a Chromium-family browser" : probe.browser), "
                    + "\(probe.targets.count) page target(s). Nothing needs relaunching."
            )
        case "read_page":
            let raw = try await evaluate(readPageExpression, webSocketURL: target.webSocketDebuggerURL)
            guard let page = parsePageRead(raw) else {
                throw AgentError.backendUnavailable(
                    "The debugger answered but the page read came back unreadable. Snapshot again."
                )
            }
            let body = page.text.isEmpty ? "(the page has no visible text)" : page.text
            return AgentToolResult(
                summary: "CDP read \(target.id) \(page.title) \(page.url)\n\(body)"
            )
        case "wait":
            return try await waitForURL(
                substring: arguments["expectedURL"] ?? "",
                timeoutSeconds: arguments["timeoutSeconds"],
                targetId: first(arguments, keys: ["targetId", "target_id", "browserTargetId", "cdpTargetId"]),
                host: host,
                port: port
            )
        case "relaunch_debug":
            return AgentToolResult(
                summary: "A debugger is already listening on \(host):\(port) — "
                    + "\(probe.browser.isEmpty ? "a Chromium-family browser" : probe.browser). "
                    + "Nothing was launched."
            )
        case "fill", "select":
            let text = arguments["text"] ?? arguments["value"] ?? ""
            let encoded = jsonStringLiteral(text)
            return try await act(arguments: arguments, target: target, expectedValue: text) { id, socket in
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

    // MARK: - Page read, URL wait and status (P2-A)

    /// One page as `read_page` reports it: what it is called, where it sits and what a
    /// person reading the tab would see.
    struct PageRead: Sendable, Equatable {
        var title: String
        var url: String
        var text: String
    }

    /// Evaluated on the page target with `returnByValue`. `innerText` rather than
    /// `textContent`: textContent returns the raw source of hidden nodes, and what the
    /// model needs is what a person reading the tab would see. The slice keeps one
    /// runaway page from filling a model's context.
    static let readPageExpression = """
        JSON.stringify((() => ({
          title: document.title || '',
          url: location.href || '',
          text: (document.body ? document.body.innerText : '').slice(0, 8192)
        }))())
        """

    /// `command()` unwraps to the value string on the normal path; the whole-result
    /// serialisation is accepted here too, for the same reason `screenshotData` does.
    static func parsePageRead(_ raw: String) -> PageRead? {
        func decode(_ text: String) -> PageRead? {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let title = (object["title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (object["url"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = object["text"] as? String ?? ""
            guard !title.isEmpty || !url.isEmpty || !text.isEmpty else { return nil }
            return PageRead(title: title, url: url, text: text)
        }
        if let page = decode(raw) { return page }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = object["result"] as? [String: Any],
              let value = inner["value"] as? String
        else { return nil }
        return decode(value)
    }

    /// Polls `/json/list` instead of holding one debugger socket open: a page that is
    /// mid-navigation tears its websocket down anyway, and re-reading the target list is
    /// the same place the live URL comes from everywhere else here. With no `targetId`,
    /// any page target may satisfy the wait — a wait is a liveness check on where a
    /// navigation has reached, not an element action pinned to one tab.
    static func waitForURL(
        substring raw: String,
        timeoutSeconds rawTimeout: String?,
        targetId: String?,
        host: String = defaultHost,
        port: Int = defaultPort
    ) async throws -> AgentToolResult {
        let substring = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !substring.isEmpty else {
            throw AgentError.missingArgument(name: "expectedURL", tool: "browser.wait")
        }
        var timeout = 5.0
        let trimmedTimeout = rawTimeout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTimeout.isEmpty {
            guard let parsed = Double(trimmedTimeout), parsed > 0 else {
                throw AgentError.permissionDenied("timeoutSeconds must be a number of seconds, like 5.")
            }
            timeout = min(parsed, 30)
        }
        guard let listURL = URL(string: "http://\(host):\(port)/json/list")
            ?? URL(string: "http://\(host):\(port)/json")
        else {
            throw AgentError.backendUnavailable("The debugger URL for port \(port) could not be built.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var lastURL: String?
        var debuggerAnswered = false
        while true {
            if let data = try? await get(listURL) {
                debuggerAnswered = true
                let targets = parseTargets(data)
                let pinned = targetId.flatMap { id in targets.first { $0.id == id } }
                for target in pinned.map({ [$0] }) ?? targets {
                    lastURL = target.url
                    if target.url.localizedCaseInsensitiveContains(substring) {
                        return AgentToolResult(
                            summary: "CDP target \(target.id) is at \(target.url).",
                            verification: "Browser page URL contains “\(substring)” "
                                + "after waiting up to \(String(format: "%g", timeout))s"
                        )
                    }
                }
            }
            guard Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if debuggerAnswered {
            return AgentToolResult(
                summary: "Waited \(String(format: "%g", timeout))s for a browser page whose URL "
                    + "contains “\(substring)” and none did (last seen: \(lastURL ?? "no page")). "
                    + "Snapshot again or take a different approach; do not retry this wait."
            )
        }
        return AgentToolResult(
            summary: "No browser debugger answered on \(host):\(port) during a "
                + "\(String(format: "%g", timeout))s wait for a page URL containing "
                + "“\(substring)”. Run browser.cdp_status to see what is missing."
        )
    }

    /// The synchronous twin of `probe`, for the Accessibility executor's switch, which is
    /// deliberately synchronous and cannot await. Only the localhost HTTP round trips
    /// happen inside the semaphore — they run on the session's own queue and never on the
    /// main actor — so a port that refuses answers in milliseconds and a debugger that
    /// stalls is bounded by the same 1.5 s request timeout `probe` uses.
    static func probeSync(host: String = defaultHost, port: Int = defaultPort) -> Probe? {
        guard let versionURL = URL(string: "http://\(host):\(port)/json/version"),
              let listURL = URL(string: "http://\(host):\(port)/json/list")
                ?? URL(string: "http://\(host):\(port)/json")
        else {
            return nil
        }
        guard let versionData = getSync(versionURL),
              let version = parseVersion(versionData)
        else { return nil }
        let listData = getSync(listURL)
        return Probe(
            browser: version.browser,
            webSocketDebuggerURL: version.webSocketDebuggerURL,
            targets: listData.map { parseTargets($0) } ?? []
        )
    }

    /// One blocking GET. The completion handler runs on the session's own queue, so a
    /// caller that blocks waiting for the semaphore cannot deadlock it; the box is locked
    /// rather than trusting that ordering to be obvious.
    private static func getSync(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        final class Answer: @unchecked Sendable {
            let lock = NSLock()
            var data: Data? = nil
        }
        let answer = Answer()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            if let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode), let data {
                answer.lock.lock()
                answer.data = data
                answer.lock.unlock()
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2.5)
        answer.lock.lock()
        defer { answer.lock.unlock() }
        return answer.data
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

    static func verifiesClick(
        beforeDOM: String, afterDOM: String?,
        beforeURL: String, afterURL: String?,
        expectedText: String?, expectedURL: String?
    ) -> Bool {
        let expectedText = expectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedURL = expectedURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expectedText?.isEmpty == false || expectedURL?.isEmpty == false else { return false }
        let changed = (afterDOM != nil && afterDOM != beforeDOM)
            || (afterURL != nil && afterURL != beforeURL)
        let textMatches = expectedText.flatMap { expected in
            expected.isEmpty ? nil : expected
        }.map { expected in
            afterDOM?.localizedCaseInsensitiveContains(expected) == true
        } ?? true
        let urlMatches = expectedURL.flatMap { expected in
            expected.isEmpty ? nil : expected
        }.map { expected in
            afterURL.map(normalize) == normalize(expected)
        } ?? true
        return changed && textMatches && urlMatches
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
        expectedValue: String? = nil,
        retryAllowed: Bool = false,
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
        guard reply != "missing" else {
            return AgentToolResult(summary: "Snapshot id \(rawID) disappeared before the action. Snapshot first.")
        }
        if let expectedValue {
            let value = try? await evaluate(
                "document.querySelectorAll('\(snapshotSelector)')[\(id - 1)]?.value ?? ''",
                webSocketURL: target.webSocketDebuggerURL
            )
            return AgentToolResult(
                summary: "CDP \(reply)",
                verification: value == expectedValue ? "Browser field value matches requested text" : nil
            )
        }
        // A click/submit acknowledgement says only that JavaScript ran. Read the same
        // target again and require a changed page or destination; otherwise the receipt
        // stays unverified so it is not blindly retried.
        let expectation = [arguments["expectedText"], arguments["expectedURL"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        func readState(after beforeDOM: String) async -> (afterURL: String?, verified: Bool) {
            var lastURL: String?
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
                let afterRaw = try? await evaluate(
                    snapshotExpression, webSocketURL: target.webSocketDebuggerURL
                )
                lastURL = await probe(host: defaultHost, port: defaultPort)?
                    .targets.first(where: { $0.id == target.id })?.url
                if verifiesClick(
                    beforeDOM: beforeDOM, afterDOM: afterRaw,
                    beforeURL: target.url, afterURL: lastURL,
                    expectedText: arguments["expectedText"],
                    expectedURL: arguments["expectedURL"]
                ) {
                    return (lastURL, true)
                }
            }
            return (lastURL, false)
        }

        var replies = [reply]
        var state = await readState(after: currentRaw)
        // P1-4: one re-inspect and one retry on an unverified click — only with a
        // stated postcondition to check the second attempt against, and only for
        // risks at or below `.modify`. Without an expectation there is nothing a
        // retry could verify, and re-clicking blindly can undo the first press.
        if !state.verified, expectation != nil, retryAllowed {
            _ = try? await evaluate(snapshotExpression, webSocketURL: target.webSocketDebuggerURL)
            replies.append(try await body(id, target.webSocketDebuggerURL))
            state = await readState(after: currentRaw)
        }
        if state.verified {
            let lines = replies.enumerated().map { pair in
                pair.offset == 0 ? "CDP \(pair.element)" : "CDP \(pair.element) (after re-inspecting)"
            }
            return AgentToolResult(
                summary: lines.joined(separator: "\n"),
                verification: "Browser page reached the expected post-click state"
            )
        }
        if replies.count > 1, let expectation {
            let seen = state.afterURL ?? "an unchanged page"
            let lines = replies.enumerated().map { pair in
                pair.offset == 0 ? "CDP \(pair.element)" : "CDP \(pair.element) (after re-inspecting)"
            }
            return AgentToolResult(
                summary: (lines + [
                    "I clicked \(target.title) expecting \(expectation) but saw \(seen). "
                        + "Re-checked and tried once more — still off."
                ]).joined(separator: "\n")
            )
        }
        return AgentToolResult(summary: "CDP \(reply)")
    }

    // MARK: - Screenshot (P1-2)

    /// `Page.captureScreenshot` through the existing command path. Memory only: the
    /// JPEG is downscaled to the shared budget and parked in `ScreenshotStore` for a
    /// vision call; uploading it needs per-run consent.
    private static func captureScreenshot(
        arguments: [String: String], target: BrowserCDPTarget
    ) async throws -> AgentToolResult {
        let reason = arguments["reason"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reason.isEmpty {
            // Screenshots are a last resort: license one when the cached tree is
            // missing or empty, not when the snapshot already describes the tab.
            let cached = SnapshotCache.shared.snapshot(for: target)
            if let cached, !cached.nodes.isEmpty {
                return AgentToolResult(
                    summary: "The snapshot already describes this tab, so no screenshot was taken. "
                        + "Pass a reason if pixels are still needed."
                )
            }
        }
        let raw = try await command(
            "Page.captureScreenshot",
            params: ["format": "jpeg", "quality": 80],
            webSocketURL: target.webSocketDebuggerURL
        )
        guard let data = screenshotData(from: raw),
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw AgentError.backendUnavailable("Browser debugger returned an unreadable screenshot.")
        }
        let screenshot = try ScreenCapture.encode(cgImage: cgImage)
        ScreenshotStore.store(screenshot, for: "browser.screenshot:\(target.id)")
        return AgentToolResult(
            summary: "CDP screenshot \(target.title) "
                + "(\(screenshot.pixelWidth)x\(screenshot.pixelHeight), memory-only, never stored). "
                + "Parked for a vision call; uploading it needs per-run consent."
        )
    }

    /// `command()` returns the `value` of `result.result` when there is one; for
    /// `Page.captureScreenshot` the result is `{"data": "<base64>"}`, which arrives
    /// as that JSON string. Accept both shapes.
    private static func screenshotData(from raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let base64 = object["data"] as? String,
           let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
            return decoded
        }
        return Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters)
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

    /// CDP exposes accessibility data as a large graph with backend node ids. Keep the
    /// model-facing output compact and read-only while preserving roles and names that the
    /// DOM selector snapshot cannot see (for example a custom combobox or menu item).
    private static func accessibilitySummary(_ raw: String?) -> String {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = object["nodes"] as? [[String: Any]]
        else { return "unavailable" }
        let lines = nodes.prefix(80).compactMap { node -> String? in
            let role = ((node["role"] as? [String: Any])?["value"] as? String) ?? ""
            let name = ((node["name"] as? [String: Any])?["value"] as? String) ?? ""
            let cleanRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanName = name
                .split(whereSeparator: { $0.isNewline })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanRole.isEmpty || !cleanName.isEmpty else { return nil }
            return [cleanRole, cleanName].filter { !$0.isEmpty }.joined(separator: ": ")
        }
        return lines.isEmpty ? "empty" : lines.joined(separator: "\n")
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
        // CDP is a text-frame protocol. Measured against real Chrome 153 on 2026-09-22:
        // the same envelope sent as a binary `.data` frame makes the DevTools server tear
        // the TCP socket down without a CLOSE frame, so the command reads as "did not
        // answer"; sent as a text frame it replies in milliseconds. The python CDP
        // fixture accepted binary frames, which is why `--selftest-browser` never saw
        // this and a real browser did.
        let didSend = await withBoundedWait(.seconds(4)) { () -> Bool in
            do {
                try await task.send(.string(String(decoding: payload, as: UTF8.self)))
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
            let remaining = Duration.milliseconds(
                Int64(max(1, deadline.timeIntervalSinceNow * 1_000))
            )
            let received = await withBoundedWait(remaining) { () -> URLSessionWebSocketTask.Message? in
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
