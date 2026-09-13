import Foundation

struct JSONRPCError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Newline-delimited JSON-RPC 2.0 over a child process. Also accepts LSP-style
/// `Content-Length` frames. Used by ACP and MCP — one session, one process.
final class JSONRPCStdioClient: @unchecked Sendable {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var incomingHandler: (@Sendable ([String: String]) async -> [String: String])?
    private var notificationHandler: (@Sendable ([String: String]) async -> Void)?
    private var closed = false

    init(command: String, arguments: [String], directory: String? = nil) throws {
        guard !command.isEmpty else {
            throw JSONRPCError(message: "No command.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        if let directory, !directory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }
    }

    func onIncoming(_ handler: @escaping @Sendable ([String: String]) async -> [String: String]) {
        lock.lock()
        incomingHandler = handler
        lock.unlock()
    }

    func onNotification(_ handler: @escaping @Sendable ([String: String]) async -> Void) {
        lock.lock()
        notificationHandler = handler
        lock.unlock()
    }

    func request(
        method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = 20
    ) async throws -> Data {
        let id: Int = lock.withLock {
            let value = nextID
            nextID += 1
            return value
        }
        try write([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.fail(id, JSONRPCError(message: "JSON-RPC \(method) timed out."))
            }
        }
    }

    func notify(method: String, params: [String: Any] = [:]) throws {
        try write([
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    func reply(id: Any, result: [String: String]) throws {
        try write([
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ])
    }

    func close() {
        lock.lock()
        let already = closed
        closed = true
        let leftover = pending
        pending.removeAll()
        lock.unlock()
        guard !already else { return }
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        process.terminate()
        for (_, continuation) in leftover {
            continuation.resume(throwing: JSONRPCError(message: "Session closed."))
        }
    }

    deinit {
        process.terminate()
    }

    private func write(_ object: [String: Any]) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw JSONRPCError(message: "Could not encode JSON-RPC.")
        }
        var line = data
        line.append(contentsOf: [UInt8(10)])
        try stdin.fileHandleForWriting.write(contentsOf: line)
    }

    private func ingest(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var messages: [[String: Any]] = []
        while let message = popMessageLocked() {
            messages.append(message)
        }
        lock.unlock()
        for message in messages {
            dispatch(message)
        }
    }

    private func popMessageLocked() -> [String: Any]? {
        if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound), as: UTF8.self)
            let length = header.split(separator: "\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                    return nil
                }
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }.first
            if let length {
                let start = headerRange.upperBound
                guard buffer.distance(from: start, to: buffer.endIndex) >= length else { return nil }
                let end = buffer.index(start, offsetBy: length)
                let payload = buffer.subdata(in: start..<end)
                buffer.removeSubrange(buffer.startIndex..<end)
                return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            }
        }
        guard let newline = buffer.firstIndex(of: 10) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        if line.isEmpty { return popMessageLocked() }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = Self.intID(message["id"]), message["method"] == nil {
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            if let error = message["error"] as? [String: Any] {
                continuation?.resume(throwing: JSONRPCError(message: String(describing: error["message"] ?? error)))
            } else if let result = message["result"] {
                let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
                continuation?.resume(returning: data)
            } else {
                continuation?.resume(returning: Data("{}".utf8))
            }
            return
        }

        if let method = message["method"] as? String, message["id"] != nil {
            let handler = lock.withLock { incomingHandler }
            let replyID = Self.intID(message["id"]) ?? 0
            let flat = Self.flat(message)
            Task { [weak self] in
                let result = await handler?(flat) ?? [:]
                try? self?.reply(id: replyID, result: result)
            }
            _ = method
            return
        }

        if message["method"] != nil {
            let handler = lock.withLock { notificationHandler }
            let flat = Self.flat(message)
            Task { await handler?(flat) }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(throwing: error)
    }

    private static func intID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    /// Flatten one JSON-RPC object so handlers stay Sendable.
    private static func flat(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else {
            if let value { return ["value": String(describing: value)] }
            return [:]
        }
        var result: [String: String] = [:]
        for (key, item) in object {
            if let text = item as? String {
                result[key] = text
            } else if let nested = item as? [String: Any] {
                let update = (nested["update"] as? [String: Any]) ?? nested
                if let title = update["title"] as? String { result["title"] = title }
                if let text = (update["content"] as? [String: Any])?["text"] as? String {
                    result["text"] = text
                }
                if let kind = update["sessionUpdate"] as? String { result["sessionUpdate"] = kind }
                result[key] = String(describing: nested)
            } else {
                result[key] = String(describing: item)
            }
        }
        return result
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
