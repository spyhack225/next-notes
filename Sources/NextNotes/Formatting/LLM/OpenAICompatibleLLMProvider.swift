import Foundation

/// Talks to any server that speaks the OpenAI chat API — Ollama, LM Studio, llama.cpp's
/// own server, vLLM, LocalAI. Loopback only: `LocalRuntimeDiscovery` refuses to record an
/// address that is not on this Mac, so nothing here can quietly become a network call.
///
/// Two things make this more than a URL swap.
///
/// First, **tool calls**. Next Notes asks for Hermes-style `<tool_call>` tags in the prompt
/// and reads them back with `AgentToolCallParser`, because that is what the built-in model
/// was tuned on. A server running a model with its own chat template will often intercept
/// those and hand back a structured `tool_calls` array with an *empty* message content —
/// the call is there, but in the wrong shape, and the loop would see silence. So every
/// structured call this provider receives is rendered back into the tag form the rest of
/// the app already understands. One parser, one shape, whichever end produced it.
///
/// Second, **streaming**. Arguments arrive a few characters at a time across many chunks,
/// so a call is only emitted once the stream ends and its JSON is whole.
struct OpenAICompatibleLLMProvider: LLMProvider {
    let id = LLMProviderID.localServer
    let baseURL: URL
    let modelID: String
    /// "Ollama", "LM Studio", "127.0.0.1:8080" — what to call it on screen.
    let serverName: String
    let contextTokens: Int

    init(baseURL: URL, modelID: String, serverName: String, contextTokens: Int = 0) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.serverName = serverName
        // Local servers rarely publish a window. 8k is the safe assumption for a small
        // instruct model, and the notes generator only uses this to decide whether a
        // transcript has to be split.
        let window = contextTokens > 0 ? contextTokens : 8_192
        self.contextTokens = max(2_048, min(window - 1_024, 128_000))
    }

    var displayModelName: String {
        modelID.isEmpty ? serverName : "\(modelID) · \(serverName)"
    }

    var unavailableReason: String? {
        get async {
            guard !modelID.isEmpty else {
                return "Choose a model for \(serverName) in Settings ▸ Agent."
            }
            guard LocalRuntimeDiscovery.isLoopback(baseURL) else {
                return "\(serverName) isn’t running on this Mac."
            }
            var request = URLRequest(url: baseURL.appendingPathComponent("models"))
            request.timeoutInterval = LocalRuntimeDiscovery.probeTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    return "\(serverName) isn’t answering right now."
                }
                return nil
            } catch {
                return "\(serverName) isn’t running right now."
            }
        }
    }

    func countTokens(_ text: String) async throws -> Int {
        // No tokenizer over HTTP. The same conservative estimate OpenRouter uses; it is
        // only ever used to decide how much transcript fits in one prompt.
        max(1, text.utf8.count / 3)
    }

    // MARK: - Completion

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let began = Date()
        let request = try makeRequest(
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            maxTokens: maxTokens,
            stream: false
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data, serverName: serverName)
        let text = try Self.text(fromCompletion: data)
        guard !text.isEmpty else { throw LocalServerError.emptyAnswer(serverName) }
        let usage = try? JSONDecoder().decode(CompletionResponse.self, from: data).usage
        return LLMCompletion(
            text: text,
            generatedTokens: usage?.completion_tokens ?? max(1, text.utf8.count / 3),
            duration: Date().timeIntervalSince(began)
        )
    }

    /// The message body plus any structured tool calls, rendered as `<tool_call>` tags.
    static func text(fromCompletion data: Data) throws -> String {
        guard let decoded = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              let choice = decoded.choices.first else {
            throw LocalServerError.unreadable
        }
        var parts: [String] = []
        let content = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !content.isEmpty { parts.append(content) }
        for call in choice.message.tool_calls ?? [] {
            guard let name = call.function.name, !name.isEmpty else { continue }
            parts.append(toolCallTag(name: name, argumentsJSON: call.function.arguments ?? "{}"))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Streaming

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        await streamConversation(
            system: system, messages: [.init(role: .user, content: user)], maxTokens: maxTokens
        )
    }

    func streamConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        var wire = [Message(role: "system", content: system)]
        wire.append(contentsOf: messages.map { Message(role: $0.role.rawValue, content: $0.content) })
        let body = wire
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(messages: body, maxTokens: maxTokens, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw LocalServerError.unreadable }
                    guard (200..<300).contains(http.statusCode) else {
                        throw LocalServerError.http(serverName, http.statusCode)
                    }
                    var calls = ToolCallAccumulator()
                    var emitted = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let chunk = try Self.parseStreamLine(line) else { continue }
                        if !chunk.text.isEmpty {
                            continuation.yield(chunk.text)
                            emitted = true
                        }
                        // A server may put content and a call in the same delta, so both
                        // are read before the end-of-stream marker is acted on.
                        for delta in chunk.toolCalls { calls.apply(delta) }
                        if chunk.isDone { break }
                    }
                    // Arguments arrive in fragments, so a call can only be handed on once
                    // the stream has finished and its JSON is complete.
                    let tags = calls.tags()
                    if !tags.isEmpty {
                        continuation.yield(emitted ? "\n" + tags : tags)
                        emitted = true
                    }
                    guard emitted else { throw LocalServerError.emptyAnswer(serverName) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// One server-sent-event line. `nil` for the keep-alive comments and blank lines every
    /// implementation sprinkles in.
    static func parseStreamLine(_ line: String) throws -> StreamChunk? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" { return StreamChunk(isDone: true) }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else { return nil }
        if let error = event.error {
            throw LocalServerError.server(error.message)
        }
        guard let choice = event.choices?.first else { return nil }
        var chunk = StreamChunk()
        chunk.text = choice.delta.content ?? ""
        // Several calls can share one delta when a model asks for two things at once.
        for (offset, call) in (choice.delta.tool_calls ?? []).enumerated() {
            chunk.toolCalls.append(
                ToolCallDelta(
                    index: call.index ?? offset,
                    name: call.function?.name,
                    argumentsFragment: call.function?.arguments
                )
            )
        }
        // `finish_reason` without content is the other way servers end a stream.
        if choice.finish_reason != nil { chunk.isDone = true }
        return chunk.isEmpty ? nil : chunk
    }

    /// A structured call in the tag form `AgentToolCallParser` reads.
    static func toolCallTag(name: String, argumentsJSON: String) -> String {
        var object: [String: Any] = ["name": name]
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object["arguments"] = parsed
        } else {
            // A half-finished or non-object argument blob is passed through as the string
            // form, which the parser also accepts, rather than dropping the call.
            object["arguments"] = trimmed.isEmpty ? [:] : trimmed
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "<tool_call>\(json)</tool_call>"
    }

    /// One fragment of one tool call, as the server numbered it.
    struct ToolCallDelta: Equatable, Sendable {
        let index: Int
        let name: String?
        let argumentsFragment: String?
    }

    /// One server-sent event: text, calls, an end marker, or any combination — servers
    /// differ about which of them may share a chunk, so all three are carried together
    /// rather than made to compete for one slot.
    struct StreamChunk: Equatable, Sendable {
        var text: String = ""
        var toolCalls: [ToolCallDelta] = []
        var isDone: Bool = false

        var isEmpty: Bool { text.isEmpty && toolCalls.isEmpty && !isDone }
    }

    /// Reassembles `tool_calls` deltas. The index is the server's, and both the name and
    /// the arguments can be split across chunks.
    struct ToolCallAccumulator: Sendable {
        private var order: [Int] = []
        private var names: [Int: String] = [:]
        private var arguments: [Int: String] = [:]

        mutating func apply(_ delta: ToolCallDelta) {
            if !order.contains(delta.index) { order.append(delta.index) }
            if let name = delta.name, !name.isEmpty { names[delta.index, default: ""] += name }
            if let fragment = delta.argumentsFragment {
                arguments[delta.index, default: ""] += fragment
            }
        }

        func tags() -> String {
            order.compactMap { index -> String? in
                guard let name = names[index], !name.isEmpty else { return nil }
                let tag = OpenAICompatibleLLMProvider.toolCallTag(
                    name: name, argumentsJSON: arguments[index] ?? "{}"
                )
                return tag.isEmpty ? nil : tag
            }.joined(separator: "\n")
        }

        var isEmpty: Bool { order.isEmpty }
    }

    // MARK: - Wire

    private func makeRequest(messages: [Message], maxTokens: Int, stream: Bool) throws -> URLRequest {
        guard !modelID.isEmpty else { throw LocalServerError.noModel(serverName) }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        // A small model on a busy Mac is slow, not broken. These are generous on purpose.
        request.timeoutInterval = stream ? 300 : 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: modelID, messages: messages, max_tokens: maxTokens, stream: stream)
        )
        return request
    }

    static func validate(_ response: URLResponse, data: Data, serverName: String) throws {
        guard let http = response as? HTTPURLResponse else { throw LocalServerError.unreadable }
        guard (200..<300).contains(http.statusCode) else {
            if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw LocalServerError.server(decoded.error.message)
            }
            throw LocalServerError.http(serverName, http.statusCode)
        }
    }

    struct Message: Codable, Sendable { let role: String; let content: String }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let max_tokens: Int
        let stream: Bool
    }

    struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct ToolCall: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let function: Function
                }
                let content: String?
                let tool_calls: [ToolCall]?
            }
            let message: Message
        }
        struct Usage: Decodable { let completion_tokens: Int? }
        let choices: [Choice]
        let usage: Usage?
    }

    private struct StreamEvent: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCall: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int?
                    let function: Function?
                }
                let content: String?
                let tool_calls: [ToolCall]?
            }
            let delta: Delta
            let finish_reason: String?
        }
        struct ServerError: Decodable { let message: String }
        let choices: [Choice]?
        let error: ServerError?
    }

    private struct ErrorResponse: Decodable {
        struct ServerError: Decodable { let message: String }
        let error: ServerError
    }
}

/// What can go wrong talking to a model-running app on this Mac, said plainly.
enum LocalServerError: LocalizedError, Equatable {
    case noModel(String)
    case emptyAnswer(String)
    case http(String, Int)
    case server(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .noModel(let name):
            "Choose which of \(name)’s models Next Notes should use."
        case .emptyAnswer(let name):
            "\(name) answered with nothing. Try a different model."
        case .http(let name, let status):
            "\(name) refused the request (\(status))."
        case .server(let message):
            message
        case .unreadable:
            "That app sent back something Next Notes couldn’t read."
        }
    }
}
