import Foundation
import Network

/// `--selftest-private-network` (P0-19).
///
/// Three things are checked, and each of them can fail:
///
/// 1. **The private session is private.** `PrivateURLSession.shared` is built from a
///    configuration with no `urlCache` and a policy of `.reloadIgnoringLocalCacheData`,
///    and no listed call site still reaches for `URLSession.shared`. The source scan is
///    what keeps a new call site from quietly going back to the shared session: changing
///    `PrivateURLSession` alone leaves every provider on the old one, and a finished
///    feature with no call site looks exactly like a working one.
/// 2. **A real request leaves nothing on disk.** A loopback fixture answers a
///    non-streaming and a streaming completion with `Cache-Control: public, max-age=3600`
///    — a response a caching session keeps for an hour — while `URLCache.shared` points
///    at a temp directory for the duration. Nothing may appear in it. G found a full
///    OpenRouter SSE stream, the model's reasoning included, in exactly such a directory
///    (N4). If the unmodified code does not reproduce a cache entry here, that is a
///    finding to record, not a case to drop: cases a and the source scan are the red
///    evidence.
/// 3. **The one-time purge.** A fake cached response is stored in an isolated cache, the
///    purge removes it and records `privacy.urlCachePurged.v1`, and a second call does
///    nothing at all.
///
/// The final line is `PRIVATE_NETWORK_OK` or
/// `PRIVATE_NETWORK_FAILED: <n> problem(s)`.
enum PrivateNetworkingSelfTest {
    static func run() async -> Bool {
        var problems: [String] = []
        // The loopback case runs first on purpose: `URLSession.shared` is created on its
        // first use, and that use is the provider below — after `URLCache.shared` has been
        // pointed at the temp directory. A shared session created earlier would hold the
        // real cache, and this case could not see today's behaviour at all.
        let loopbackProblems = await loopback()
        problems += loopbackProblems
        problems += configuration()
        problems += callSites()
        problems += purge()
        for problem in problems { print("PRIVATE_NETWORK_WRONG: \(problem)") }
        print(problems.isEmpty
              ? "PRIVATE_NETWORK_OK"
              : "PRIVATE_NETWORK_FAILED: \(problems.count) problem(s)")
        return problems.isEmpty
    }

    // MARK: - a. The session's own configuration

    private static func configuration() -> [String] {
        var problems: [String] = []
        let configuration = PrivateURLSession.shared.configuration
        if configuration.urlCache != nil {
            problems.append("PrivateURLSession.shared still carries a URLCache")
        }
        if configuration.requestCachePolicy != .reloadIgnoringLocalCacheData {
            problems.append(
                "PrivateURLSession.shared does not ask for .reloadIgnoringLocalCacheData"
            )
        }
        return problems
    }

    // MARK: - a, second half. The call sites

    /// The listed call sites, read from the checkout this test was built from.
    ///
    /// `#filePath` is how `UIStringsLint` finds `UI/`: a call site is introduced by editing
    /// a file, and a test that asked the running providers would need each one to expose
    /// its session.
    private static func callSites() -> [String] {
        guard FileManager.default.fileExists(atPath: sourceRoot.path) else {
            return [
                "the source tree was not found at \(sourceRoot.path); "
                    + "the call-site check cannot run"
            ]
        }
        var problems: [String] = []
        for relative in scannedCallSites {
            let target = sourceRoot.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
            else {
                problems.append(
                    "\(relative) is missing from the checkout; the call-site check cannot run"
                )
                continue
            }
            let files = isDirectory.boolValue ? swiftFiles(in: target) : [target]
            for file in files.sorted(by: { $0.path < $1.path }) {
                guard let source = try? String(contentsOf: file, encoding: .utf8),
                      let line = firstSharedSessionLine(in: source) else { continue }
                let shown = file.path.hasPrefix(sourceRoot.path + "/")
                    ? String(file.path.dropFirst(sourceRoot.path.count + 1))
                    : file.lastPathComponent
                problems.append("\(shown):\(line) still reaches for URLSession.shared")
            }
        }
        return problems
    }

    /// The checkout this build was compiled from.
    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Support
        .deletingLastPathComponent()   // NextNotes
        .deletingLastPathComponent()   // Sources

    /// The files P0-19 owns. Everything else is excluded on purpose: public responses,
    /// loopback metadata, or a downloader that needs its own resumable session.
    private static let scannedCallSites = [
        "NextNotes/Formatting/LLM/OpenRouterLLMProvider.swift",
        "NextNotes/Formatting/LLM/OpenAICompatibleLLMProvider.swift",
        "NextNotes/Calendar/Google",
        "NextNotes/Integrations/MCP/MCPSession.swift",
        "NextNotes/Integrations/Composio",
    ]

    /// The line of the first real `URLSession.shared` use, comments and string literals
    /// excluded, or nil. `PrivateURLSession.shared` is deliberately not a match: the
    /// lookbehind requires the name to start at a word boundary.
    private static func firstSharedSessionLine(in source: String) -> Int? {
        let pattern = "(?<![A-Za-z0-9_])URLSession\\.shared"
        let lines = codeOnly(source).components(separatedBy: "\n")
        for (index, line) in lines.enumerated()
        where line.range(of: pattern, options: .regularExpression) != nil {
            return index + 1
        }
        return nil
    }

    /// `source` with comments and string literals blanked out, newlines kept, so a match
    /// is a real use of the API rather than a mention in prose or a log message.
    private static func codeOnly(_ source: String) -> String {
        let characters = Array(source)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        var inBlockComment = false
        var inLineComment = false
        var inString = false
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    output.append(character)
                } else {
                    output.append(" ")
                }
                index += 1
                continue
            }
            if inBlockComment {
                if character == "*", next == "/" {
                    inBlockComment = false
                    output.append(contentsOf: [" ", " "])
                    index += 2
                    continue
                }
                output.append(character == "\n" ? "\n" : " ")
                index += 1
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                    // A line continuation (`\` before a newline) must keep its newline,
                    // or every line number after it would be reported one too low.
                    output.append(character == "\n" ? "\n" : " ")
                    index += 1
                    continue
                }
                if character == "\\" {
                    escaped = true
                    output.append(" ")
                    index += 1
                    continue
                }
                if character == "\"" {
                    inString = false
                    output.append(" ")
                    index += 1
                    continue
                }
                output.append(character == "\n" ? "\n" : " ")
                index += 1
                continue
            }
            if character == "/", next == "/" {
                inLineComment = true
                output.append(" ")
                index += 1
                continue
            }
            if character == "/", next == "*" {
                inBlockComment = true
                output.append(" ")
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                output.append(" ")
                index += 1
                continue
            }
            output.append(character)
            index += 1
        }
        return String(output)
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    // MARK: - b. Loopback

    private static func loopback() async -> [String] {
        guard let server = FixtureServer(), let port = await server.start() else {
            return ["the loopback fixture server did not start"]
        }
        guard let base = URL(string: "http://127.0.0.1:\(port)/v1") else {
            await server.stop()
            return ["the fixture server's address could not be built"]
        }
        let chatURL = base.appendingPathComponent("chat/completions")

        // Point the process's shared cache at a temp directory for the duration, so a
        // request that is cached leaves a trace this test can see.
        let savedCache = URLCache.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-private-network-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryCache = URLCache(
            memoryCapacity: 0, diskCapacity: 50_000_000, directory: directory
        )
        URLCache.shared = temporaryCache
        defer {
            URLCache.shared = savedCache
            try? FileManager.default.removeItem(at: directory)
        }

        var problems: [String] = []
        let provider = OpenAICompatibleLLMProvider(
            baseURL: base, modelID: "fixture-model", serverName: "Fixture"
        )
        if provider.session !== PrivateURLSession.shared {
            problems.append("the local provider is not using PrivateURLSession by default")
        }

        do {
            let completion = try await provider.complete(
                system: "System", user: "Hello", maxTokens: 64
            )
            if completion.text != FixtureServer.answer {
                problems.append("the non-streaming fixture answer was “\(completion.text)”")
            }
        } catch {
            problems.append("the non-streaming fixture request failed: \(error.localizedDescription)")
        }

        do {
            let stream = await provider.streamConversation(
                system: "System",
                messages: [.init(role: .user, content: "Hello")],
                maxTokens: 64
            )
            var text = ""
            for try await chunk in stream { text += chunk }
            if text != FixtureServer.answer {
                problems.append("the streaming fixture answer was “\(text)”")
            }
        } catch {
            problems.append("the streaming fixture request failed: \(error.localizedDescription)")
        }

        await server.stop()

        var cachedRequest = URLRequest(url: chatURL)
        cachedRequest.httpMethod = "POST"
        if temporaryCache.cachedResponse(for: cachedRequest) != nil {
            problems.append("the loopback chat request was written to the on-disk URL cache")
        }
        let blobs = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("fsCachedData").path
        )) ?? []
        if !blobs.isEmpty {
            problems.append("the temp cache holds \(blobs.count) cached response body file(s)")
        }
        return problems
    }

    // MARK: - c. The one-time purge

    private static func purge() -> [String] {
        var problems: [String] = []
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-private-purge-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "ai.pivotstudio.nextnotes.selftest.private-network.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return ["the isolated defaults suite could not be created"]
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "privacy.urlCachePurged.v1"
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 5_000_000,
                             directory: directory)
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions"),
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Cache-Control": "public, max-age=3600"]
              ) else {
            return ["the fake cached response could not be built"]
        }

        // A fake cached response, the shape a cached chat reply leaves behind.
        let request = URLRequest(url: url)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: Data("private reply".utf8)),
            for: request
        )
        guard cache.cachedResponse(for: request) != nil else {
            return ["the isolated cache did not keep the fake response; the purge case cannot run"]
        }

        if !PrivateURLSession.purgeLegacyCache(cache: cache, defaults: defaults) {
            problems.append("the first purge did not report that it removed the legacy cache")
        }
        if cache.cachedResponse(for: request) != nil {
            problems.append("the legacy cache still answers after the purge")
        }
        if !defaults.bool(forKey: key) {
            problems.append("the purge did not record \(key)")
        }

        // The second call must do nothing at all: the flag is already set.
        guard let laterURL = URL(string: "https://openrouter.ai/api/v1/models"),
              let laterResponse = HTTPURLResponse(
                  url: laterURL, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Cache-Control": "public, max-age=3600"]
              ) else {
            return problems + ["the second fake cached response could not be built"]
        }
        let laterRequest = URLRequest(url: laterURL)
        cache.storeCachedResponse(
            CachedURLResponse(response: laterResponse, data: Data("later".utf8)),
            for: laterRequest
        )
        if PrivateURLSession.purgeLegacyCache(cache: cache, defaults: defaults) {
            problems.append("the purge reported work a second time")
        }
        if cache.cachedResponse(for: laterRequest) == nil {
            problems.append("the second purge cleared the cache although the flag was already set")
        }
        return problems
    }

    // MARK: - The fixture server

    /// A one-request-at-a-time HTTP server on an OS-assigned loopback port.
    ///
    /// It answers `POST /v1/chat/completions` the way a chat server does — JSON for a
    /// non-streaming request, an SSE stream for a streaming one — with a `Cache-Control`
    /// header that makes the response fresh for an hour, which is what would let a
    /// caching session write it to disk.
    private actor FixtureServer {
        private let listener: NWListener
        private var connections: [NWConnection] = []

        init?() {
            guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
            self.listener = listener
        }

        func start() async -> UInt16? {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.accept(connection) }
            }
            return await withCheckedContinuation { continuation in
                let box = ContinuationBox(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: box.finish(self.listener.port?.rawValue)
                    case .failed, .cancelled: box.finish(nil)
                    default: break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
        }

        func stop() {
            for connection in connections { connection.cancel() }
            connections = []
            listener.cancel()
        }

        private func accept(_ connection: NWConnection) {
            connections.append(connection)
            connection.start(queue: .global(qos: .userInitiated))
            Self.read(on: connection, buffer: Data())
        }

        /// Reads until the whole request body is present, then answers. A POST body can
        /// arrive across several segments, and answering the headers alone would misread
        /// `stream` and send the wrong shape.
        private static func read(on connection: NWConnection, buffer: Data) {
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 65_536
            ) { data, _, isComplete, error in
                var accumulated = buffer
                if let data { accumulated.append(data) }
                if let request = completeRequest(accumulated) {
                    respond(connection, request: request)
                    return
                }
                if isComplete || error != nil || accumulated.count > 1_048_576 {
                    respond(connection, request: String(decoding: accumulated, as: UTF8.self))
                    return
                }
                read(on: connection, buffer: accumulated)
            }
        }

        /// The request once its body is whole, or nil while more bytes are needed.
        private static func completeRequest(_ data: Data) -> String? {
            guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
                  let headers = String(
                      data: Data(data[..<separator.lowerBound]), encoding: .utf8
                  )
            else { return nil }
            let length = headers
                .components(separatedBy: "\r\n")
                .compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                    guard name == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
                .first
            guard let length, data.count - separator.upperBound >= length else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        private static func isStreaming(_ request: String) -> Bool {
            guard let separator = request.range(of: "\r\n\r\n") else { return false }
            let body = String(request[separator.upperBound...])
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stream = object["stream"] as? Bool else { return false }
            return stream
        }

        private static func respond(_ connection: NWConnection, request: String) {
            let streaming = isStreaming(request)
            let body = streaming ? sseBody : jsonBody
            let contentType = streaming ? "text/event-stream" : "application/json"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n"
                + "Cache-Control: public, max-age=3600\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }

        static let answer = "Fixture answer."

        private static var jsonBody: String {
            #"{"choices":[{"message":{"content":"\#(answer)"}}],"usage":{"completion_tokens":3}}"#
        }

        /// Two content chunks and the end marker, so the provider's reassembly is part of
        /// what the fixture exercises.
        private static var sseBody: String {
            let first = String(answer.prefix(7))
            let rest = String(answer.dropFirst(7))
            return """
                data: {"choices":[{"delta":{"content":"\(first)"}}]}

                data: {"choices":[{"delta":{"content":"\(rest)"}}]}

                data: [DONE]

                """
        }
    }

    /// `NWListener` can report `.ready` more than once; a continuation may only be resumed
    /// once, and resuming it twice is a crash rather than a failed test.
    private final class ContinuationBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<UInt16?, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<UInt16?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: UInt16?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
