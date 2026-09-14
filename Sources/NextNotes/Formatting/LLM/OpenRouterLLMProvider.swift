import Foundation
import Observation
import Security

enum OpenRouterError: LocalizedError {
    case missingKey
    case missingModel
    case invalidResponse
    case keychain(Int)
    case http(Int, String)

    var errorDescription: String? {
        return switch self {
        case .missingKey: "Add an OpenRouter API key in Models settings."
        case .missingModel: "Choose an OpenRouter model in Models settings."
        case .invalidResponse: "OpenRouter returned an unreadable response."
        case .keychain(let status): "Keychain error \(status). The API key was not saved."
        case .http(let status, let message): "OpenRouter HTTP \(status): \(message)"
        }
    }
}

enum OpenRouterKeyStore {
    private static let service = "ai.pivotstudio.nextnotes.openrouter"
    private static let account = "api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var key: String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenRouterError.missingKey }
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: Data(trimmed.utf8)]
            let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw OpenRouterError.keychain(Int(updated)) }
        } else if status != errSecSuccess {
            throw OpenRouterError.keychain(Int(status))
        }
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}

struct OpenRouterModel: Decodable, Identifiable, Sendable {
    struct Architecture: Decodable, Sendable {
        let input_modalities: [String]?
        let output_modalities: [String]?
    }
    struct Pricing: Decodable, Sendable {
        let prompt: String?
        let completion: String?
    }

    let id: String
    let name: String
    let description: String?
    let context_length: Int?
    let supported_parameters: [String]?
    let architecture: Architecture?
    let pricing: Pricing?

    var isTextModel: Bool {
        (architecture?.input_modalities?.contains("text") ?? true)
            && (architecture?.output_modalities?.contains("text") ?? true)
    }
    var supportsTools: Bool { supported_parameters?.contains("tools") ?? false }
    var supportsReasoning: Bool { supported_parameters?.contains("reasoning") ?? false }
    var isFree: Bool { id.hasSuffix(":free") }
    var providerName: String { String(id.split(separator: "/").first ?? "") }
    var tags: [String] {
        var result = ["Text"]
        if supportsTools { result.append("Agent tools") }
        if supportsReasoning { result.append("Reasoning") }
        if architecture?.input_modalities?.contains("image") == true { result.append("Vision") }
        if isFree { result.append("Free") }
        return result
    }
    var priceLabel: String {
        guard let prompt = pricing?.prompt.flatMap(Double.init),
              let completion = pricing?.completion.flatMap(Double.init) else { return "Price unavailable" }
        return String(format: "$%.2f / $%.2f per 1M in/out", prompt * 1_000_000, completion * 1_000_000)
    }
}

enum OpenRouterModelFilter: String, CaseIterable, Identifiable {
    case all = "All text"
    case agent = "Agent tools"
    case reasoning = "Reasoning"
    case vision = "Vision"
    case free = "Free"
    var id: String { rawValue }

    func includes(_ model: OpenRouterModel) -> Bool {
        guard model.isTextModel else { return false }
        return switch self {
        case .all: true
        case .agent: model.supportsTools
        case .reasoning: model.supportsReasoning
        case .vision: model.architecture?.input_modalities?.contains("image") == true
        case .free: model.isFree
        }
    }
}

@MainActor @Observable
final class OpenRouterCatalog {
    static let shared = OpenRouterCatalog()
    private(set) var models: [OpenRouterModel] = []
    private(set) var isLoading = false
    private(set) var problem: String?

    func model(id: String) -> OpenRouterModel? { models.first { $0.id == id } }

    func clear() {
        models = []
        problem = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let key = OpenRouterKeyStore.key else { throw OpenRouterError.missingKey }
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            try OpenRouterLLMProvider.validate(response, data: data)
            guard OpenRouterKeyStore.key == key else { return }
            let decoded = try JSONDecoder().decode(ModelResponse.self, from: data)
            models = decoded.data.filter(\.isTextModel).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private struct ModelResponse: Decodable { let data: [OpenRouterModel] }
}

struct OpenRouterLLMProvider: LLMProvider {
    let id = LLMProviderID.openRouter
    let modelID: String
    let contextTokens: Int
    var displayModelName: String { modelID }

    init(modelID: String, contextTokens: Int) {
        self.modelID = modelID
        // The catalog provides the real context window; leave a safety margin for
        // approximate token counting and provider-specific chat templates.
        let publishedWindow = contextTokens > 0 ? contextTokens : 8_192
        self.contextTokens = max(2_048, min(publishedWindow - 2_048, 200_000))
    }

    var unavailableReason: String? {
        get async {
            if OpenRouterKeyStore.key == nil { return OpenRouterError.missingKey.localizedDescription }
            if modelID.isEmpty { return OpenRouterError.missingModel.localizedDescription }
            return nil
        }
    }

    func countTokens(_ text: String) async throws -> Int {
        // Conservative estimate. The server bills using the chosen model's tokenizer;
        // this number is only for splitting long meeting transcripts.
        max(1, text.utf8.count / 3)
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let began = Date()
        let request = try makeRequest(system: system, user: user, maxTokens: maxTokens, stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw OpenRouterError.invalidResponse
        }
        return LLMCompletion(text: text,
                             generatedTokens: decoded.usage?.completion_tokens ?? max(1, text.utf8.count / 3),
                             duration: Date().timeIntervalSince(began))
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(system: system, user: user, maxTokens: maxTokens, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        throw OpenRouterError.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
                    }
                    var emitted = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line == "data: [DONE]" { break }
                        if let chunk = try Self.parseStreamLine(line) {
                            continuation.yield(chunk)
                            emitted = true
                        }
                    }
                    guard emitted else { throw OpenRouterError.invalidResponse }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    static func parseStreamLine(_ line: String) throws -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        let event = try JSONDecoder().decode(StreamEvent.self, from: data)
        if let error = event.error {
            throw OpenRouterError.http(error.code ?? 500, error.message)
        }
        return event.choices?.first?.delta.content
    }

    private func makeRequest(system: String, user: String, maxTokens: Int, stream: Bool) throws -> URLRequest {
        guard !modelID.isEmpty else { throw OpenRouterError.missingModel }
        guard let key = OpenRouterKeyStore.key else { throw OpenRouterError.missingKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: modelID,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            max_tokens: maxTokens,
            stream: stream
        ))
        return request
    }

    static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw OpenRouterError.http(http.statusCode, String(message.prefix(300)))
        }
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let max_tokens: Int
        let stream: Bool
    }
    private struct CompletionResponse: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
        struct Usage: Decodable { let completion_tokens: Int? }
        let choices: [Choice]
        let usage: Usage?
    }
    private struct StreamEvent: Decodable {
        struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta }
        struct APIError: Decodable { let code: Int?; let message: String }
        let choices: [Choice]?
        let error: APIError?
    }
    private struct ErrorResponse: Decodable {
        struct APIError: Decodable { let message: String }
        let error: APIError
    }
}

@MainActor
enum OpenRouterSelfTest {
    static func run() async throws -> String {
        guard let key = OpenRouterKeyStore.key else { throw OpenRouterError.missingKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try OpenRouterLLMProvider.validate(response, data: data)
        await OpenRouterCatalog.shared.refresh()
        if let problem = OpenRouterCatalog.shared.problem {
            throw OpenRouterError.http(0, problem)
        }
        let selected = Settings.shared.openRouterAgentModelID.isEmpty
            ? Settings.shared.openRouterNotesModelID : Settings.shared.openRouterAgentModelID
        guard let model = OpenRouterCatalog.shared.model(id: selected) else {
            throw OpenRouterError.missingModel
        }
        let provider = OpenRouterLLMProvider(modelID: model.id,
                                             contextTokens: model.context_length ?? 8_192)
        let completion = try await provider.complete(
            system: "Reply with one word.", user: "Say OK.", maxTokens: 16
        )
        guard !completion.text.isEmpty else { throw OpenRouterError.invalidResponse }
        let chunks = await provider.stream(system: "Reply with one word.", user: "Say OK.", maxTokens: 16)
        var streamed = ""
        for try await chunk in chunks { streamed += chunk }
        guard !streamed.isEmpty else { throw OpenRouterError.invalidResponse }
        return "\(model.id) · catalog, key, completion and stream verified"
    }
}

enum OpenRouterContractSelfTest {
    static func run() -> Bool {
        let fixture = """
        {"id":"example/agent:free","name":"Example Agent","context_length":32768,
         "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
         "supported_parameters":["tools","reasoning"],
         "pricing":{"prompt":"0","completion":"0"}}
        """
        guard let data = fixture.data(using: .utf8),
              let model = try? JSONDecoder().decode(OpenRouterModel.self, from: data),
              model.isTextModel, model.supportsTools, model.supportsReasoning, model.isFree,
              OpenRouterModelFilter.agent.includes(model),
              OpenRouterModelFilter.free.includes(model),
              model.priceLabel.contains("$0.00"),
              let chunk = try? OpenRouterLLMProvider.parseStreamLine(
                  "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}"
              ), chunk == "OK",
              (try? OpenRouterLLMProvider.parseStreamLine(": OPENROUTER PROCESSING")) == nil,
              (try? OpenRouterLLMProvider.parseStreamLine("data: [DONE]")) == nil
        else { return false }
        do {
            _ = try OpenRouterLLMProvider.parseStreamLine(
                "data: {\"error\":{\"code\":429,\"message\":\"Rate limited\"}}"
            )
            return false
        } catch OpenRouterError.http(let status, _) {
            return status == 429
        } catch {
            return false
        }
    }
}
