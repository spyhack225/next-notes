import Foundation
import LocalAuthentication
import Observation
import Security

enum OpenRouterError: LocalizedError {
    case missingKey
    case missingModel
    case invalidResponse
    case keychain(Int)
    case http(Int, String)
    case speedProbe(String)
    /// The model hit the answer limit. `visibleText` says whether any of its answer was
    /// already shown: a cut-off with text keeps it, one without says why nothing came.
    case cutOff(visibleText: Bool)
    /// The vision call refused to build: consent is off, so no `image_url` part
    /// exists and nothing left the Mac.
    case visionBlocked

    var errorDescription: String? {
        return switch self {
        case .missingKey: "Add or re-enter your OpenRouter API key in Models settings."
        case .missingModel: "Choose an OpenRouter model in Models settings."
        case .invalidResponse: "OpenRouter returned an unreadable response."
        case .keychain(let status): "Keychain error \(status). The API key was not saved."
        case .http(429, _): "OpenRouter rate-limited this model. Choose another Agent model or try again later."
        case .http(let status, let message): "OpenRouter HTTP \(status): \(message)"
        case .speedProbe(let message): "OpenRouter speed check: \(message)"
        case .cutOff(let visibleText):
            visibleText
                ? "The answer was cut off."
                : "The model spent its whole answer thinking and wrote nothing. Try again, or pick a model without the Reasoning label in Settings ▸ Agent."
        case .visionBlocked: "The screenshot was not sent: vision consent is off. Nothing left this Mac."
        }
    }
}

/// P0-7 error mapping only: every OpenRouter failure gets a voice code.
extension OpenRouterError: VoiceCodedError {
    var voiceCode: VoiceProviderErrorCode {
        switch self {
        case .missingKey: .notConfigured
        case .missingModel: .modelMissing
        case .invalidResponse: .unavailable
        case .keychain: .notConfigured
        case .http(let status, let message):
            Self.voiceCode(status: status, message: message)
        case .speedProbe: .unavailable
        case .cutOff: .unavailable
        case .visionBlocked: .unavailable
        }
    }

    /// A single expression so the caller can stay a switch expression.
    private static func voiceCode(status: Int, message: String) -> VoiceProviderErrorCode {
        let lower = message.lowercased()
        if lower.contains("quota") || lower.contains("credit") || lower.contains("balance")
            || lower.contains("usage limit") {
            return .quotaExceeded
        }
        switch status {
        case 429: return .rateLimited
        case 401, 403: return .notConfigured
        case 408, 504: return .timeout
        case 500...599: return .unavailable
        default: return .unknown
        }
    }
}

enum OpenRouterKeyStore {
    private static let service = "ai.pivotstudio.nextnotes.openrouter"
    private static let account = "api-key"
    private static var legacyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The data-protection keychain grants the same signed app access after an
    /// update. Older builds stored this item in the legacy macOS keychain,
    /// whose access prompt can block SecItemCopyMatching indefinitely.
    private static var query: [String: Any] {
        var request = legacyQuery
        request[kSecUseDataProtectionKeychain as String] = true
        return request
    }

    private static func read(_ base: [String: Any]) -> String? {
        var request = base
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var key: String? {
        if let current = read(query) { return current }
        guard let legacy = read(legacyQuery) else { return nil }
        // Migrate silently only when this build is already allowed to read the
        // old item. A denied legacy lookup never displays a Keychain prompt.
        try? save(legacy)
        return legacy
    }

    /// Security framework lookups can wait for keychain authorization even
    /// when prompts are disabled. Run one off the UI actor and share its result
    /// across catalog, speed and completion requests in this process.
    @MainActor private static var cachedKey: String?
    @MainActor private static var didReadKey = false
    @MainActor private static var keyWaiters: [CheckedContinuation<String?, Never>] = []
    @MainActor private static var keyGeneration = 0

    @MainActor static func invalidateCache() {
        keyGeneration &+= 1
        cachedKey = nil
        didReadKey = false
        let waiters = keyWaiters
        keyWaiters = []
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    @MainActor
    static func keyAsync() async -> String? {
        if didReadKey { return cachedKey }
        return await withCheckedContinuation { waiter in
            keyWaiters.append(waiter)
            guard keyWaiters.count == 1 else { return }
            let generation = keyGeneration
            DispatchQueue.global(qos: .userInitiated).async {
                let result = key
                Task { @MainActor in
                    guard keyGeneration == generation else { return }
                    cachedKey = result
                    didReadKey = true
                    let waiters = keyWaiters
                    keyWaiters = []
                    for waiter in waiters { waiter.resume(returning: result) }
                }
            }
        }
    }

    @MainActor
    static func hasKeyAsync() async -> Bool {
        await keyAsync() != nil
    }

    static func saveAsync(_ value: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try save(value)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func clearAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try clear()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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

    static func clear() throws {
        let current = SecItemDelete(query as CFDictionary)
        guard current == errSecSuccess || current == errSecItemNotFound else {
            throw OpenRouterError.keychain(Int(current))
        }
        var legacy = legacyQuery
        let context = LAContext()
        context.interactionNotAllowed = true
        legacy[kSecUseAuthenticationContext as String] = context
        let previous = SecItemDelete(legacy as CFDictionary)
        guard previous == errSecSuccess || previous == errSecItemNotFound else {
            throw OpenRouterError.keychain(Int(previous))
        }
    }
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

struct OpenRouterModelSpeed: Equatable, Sendable {
    let tokensPerSecond: Double
    let provider: String
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
    private(set) var speeds: [String: OpenRouterModelSpeed] = [:]
    private(set) var checkedSpeedIDs: Set<String> = []
    private(set) var failedSpeedIDs: Set<String> = []
    private(set) var speedFailure: String?
    private var loadingSpeedIDs: Set<String> = []
    private var speedGeneration: UInt64 = 0

    func model(id: String) -> OpenRouterModel? { models.first { $0.id == id } }

    func clear() {
        speedGeneration &+= 1
        models = []
        problem = nil
        speeds = [:]
        checkedSpeedIDs = []
        failedSpeedIDs = []
        speedFailure = nil
        loadingSpeedIDs = []
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let key = await OpenRouterKeyStore.keyAsync() else { throw OpenRouterError.missingKey }
            // OpenRouter ranks by recent p50 throughput. Its list response does
            // not include the numeric rate, which comes from endpoint details.
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text&sort=throughput-high-to-low")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, response) = try await PrivateURLSession.shared.data(for: request)
            try OpenRouterLLMProvider.validate(response, data: data)
            guard await OpenRouterKeyStore.keyAsync() == key else { return }
            let decoded = try JSONDecoder().decode(ModelResponse.self, from: data)
            speedGeneration &+= 1
            models = decoded.data.filter(\.isTextModel)
            speeds = [:]
            checkedSpeedIDs = []
            failedSpeedIDs = []
            speedFailure = nil
            loadingSpeedIDs = []
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Fetch rates only for rows currently visible in the picker. The catalog
    /// may contain hundreds of models; loading every endpoint on open would
    /// create hundreds of requests and delay the Settings screen.
    func loadSpeeds(for ids: [String]) async {
        guard let key = await OpenRouterKeyStore.keyAsync() else { return }
        let generation = speedGeneration
        var seen = Set<String>()
        let wanted = ids.filter {
            seen.insert($0).inserted && !checkedSpeedIDs.contains($0)
                && !loadingSpeedIDs.contains($0)
        }
        loadingSpeedIDs.formUnion(wanted)
        for id in wanted {
            if Task.isCancelled || speedGeneration != generation { break }
            do {
                let speed = try await Self.fetchSpeed(for: id, key: key)
                guard speedGeneration == generation else { break }
                failedSpeedIDs.remove(id)
                checkedSpeedIDs.insert(id)
                if let speed { speeds[id] = speed }
            } catch {
                guard speedGeneration == generation else { break }
                failedSpeedIDs.insert(id)
                if speedFailure == nil { speedFailure = error.localizedDescription }
            }
            loadingSpeedIDs.remove(id)
        }
        if speedGeneration == generation { loadingSpeedIDs.subtract(wanted) }
    }

    private nonisolated static func fetchSpeed(for id: String, key: String) async throws -> OpenRouterModelSpeed? {
        var components = URLComponents(string: "https://openrouter.ai")!
        components.path = "/api/v1/models/\(id)/endpoints"
        guard let url = components.url else { throw OpenRouterError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await PrivateURLSession.shared.data(for: request)
        try OpenRouterLLMProvider.validate(response, data: data)
        return try parseSpeed(data)
    }

    nonisolated static func parseSpeed(_ data: Data) throws -> OpenRouterModelSpeed? {
        let response = try JSONDecoder().decode(EndpointResponse.self, from: data)
        return response.data.endpoints.compactMap { endpoint in
            guard let rate = endpoint.throughput_last_30m?.p50,
                  rate.isFinite, rate > 0 else { return nil }
            return OpenRouterModelSpeed(tokensPerSecond: rate, provider: endpoint.provider_name)
        }.max { $0.tokensPerSecond < $1.tokensPerSecond }
    }

    private struct EndpointResponse: Decodable {
        let data: ModelEndpoints
    }
    private struct ModelEndpoints: Decodable {
        let endpoints: [ModelEndpoint]
    }
    private struct ModelEndpoint: Decodable {
        struct Throughput: Decodable { let p50: Double? }
        let provider_name: String
        let throughput_last_30m: Throughput?
    }

    private struct ModelResponse: Decodable { let data: [OpenRouterModel] }
}

struct OpenRouterLLMProvider: LLMProvider {
    let id = LLMProviderID.openRouter
    let modelID: String
    let contextTokens: Int
    /// How a request treats this model's reasoning pass (P0-17). `.off` is the body the
    /// provider sent before reasoning control existed.
    let reasoning: OpenRouterReasoningPolicy
    var displayModelName: String { modelID }

    init(
        modelID: String,
        contextTokens: Int,
        reasoning: OpenRouterReasoningPolicy = .off
    ) {
        self.modelID = modelID
        self.reasoning = reasoning
        // The catalog provides the real context window; leave a safety margin for
        // approximate token counting and provider-specific chat templates.
        let publishedWindow = contextTokens > 0 ? contextTokens : 8_192
        self.contextTokens = max(2_048, min(publishedWindow - 2_048, 200_000))
    }

    var unavailableReason: String? {
        get async {
            if await OpenRouterKeyStore.keyAsync() == nil { return OpenRouterError.missingKey.localizedDescription }
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
        let messages = [
            LLMChatMessage(role: .system, content: system),
            LLMChatMessage(role: .user, content: user),
        ]
        // Two one-shot recoveries: a provider that refuses the reasoning field gets the
        // same request without it, and a pass that hit the limit before writing anything
        // gets a doubled allowance. Anything else is the answer.
        var policy = reasoning
        var attempt = 0
        while true {
            attempt += 1
            do {
                let request = try await makeRequest(
                    messages: messages, maxTokens: maxTokens, stream: false, policy: policy)
                let (data, response) = try await PrivateURLSession.shared.data(for: request)
                try Self.validate(response, data: data)
                let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)
                let text = decoded.choices.first?.message.content ?? ""
                if decoded.choices.first?.finish_reason == "length" {
                    if text.isEmpty, attempt == 1, case .capped = policy {
                        policy = policy.doubled(contextTokens: contextTokens)
                        continue
                    }
                    guard !text.isEmpty else { throw OpenRouterError.cutOff(visibleText: false) }
                    Log.agent.info(
                        "openrouter completion finish=length visible=\(text.count, privacy: .public)")
                }
                guard !text.isEmpty else { throw OpenRouterError.invalidResponse }
                // P0-20a: the non-streamed response carries a full usage object.
                ModelPassRecorder.current?.report(
                    promptTokens: decoded.usage?.prompt_tokens,
                    cachedTokens: nil,
                    completionTokens: decoded.usage?.completion_tokens,
                    reasoningTokens: nil,
                    finishReason: decoded.choices.first?.finish_reason,
                    estimated: decoded.usage == nil)
                return LLMCompletion(text: text,
                                     generatedTokens: decoded.usage?.completion_tokens ?? max(1, text.utf8.count / 3),
                                     duration: Date().timeIntervalSince(began))
            } catch let error as OpenRouterError {
                guard attempt == 1, policy != .off, Self.rejectsReasoning(error) else { throw error }
                await Self.rememberNoReasoning(modelID: modelID)
                policy = .off
            }
        }
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        await streamConversation(
            system: system,
            messages: [.init(role: .user, content: user)],
            maxTokens: maxTokens
        )
    }

    func streamConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        let requestMessages = [LLMChatMessage(role: .system, content: system)] + messages
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await performStream(messages: requestMessages, maxTokens: maxTokens) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// One streamed pass with the provider's two one-shot recoveries: a provider that
    /// refuses the reasoning field gets the same request without it, and a pass cut off
    /// before any visible text gets one retry with a doubled allowance. The summary is what
    /// the stream itself reported — visible text, reasoning characters, `finish_reason`
    /// and usage — and the live diagnostic reads it.
    func performStream(
        messages: [LLMChatMessage],
        maxTokens: Int,
        yield: @Sendable (String) -> Void
    ) async throws -> OpenRouterStreamSummary {
        var policy = reasoning
        do {
            return try await performStream(
                messages: messages, maxTokens: maxTokens, policy: policy, yield: yield)
        } catch let error as OpenRouterError {
            guard policy != .off, Self.rejectsReasoning(error) else { throw error }
            await Self.rememberNoReasoning(modelID: modelID)
            policy = .off
            return try await performStream(
                messages: messages, maxTokens: maxTokens, policy: policy, yield: yield)
        }
    }

    private func performStream(
        messages: [LLMChatMessage],
        maxTokens: Int,
        policy: OpenRouterReasoningPolicy,
        yield: @Sendable (String) -> Void
    ) async throws -> OpenRouterStreamSummary {
        let request = try await makeRequest(
            messages: messages, maxTokens: maxTokens, stream: true, policy: policy)
        let (bytes, response) = try await PrivateURLSession.shared.bytes(for: request)
        let lines = try await Self.validatedLines(response, bytes: bytes)
        // The retry is built only where another attempt is allowed: a reasoning pass that
        // wrote nothing visible and still has an allowance to grow.
        var retry: (@Sendable () async throws -> AsyncLineSequence<URLSession.AsyncBytes>)?
        if case .capped(let allowance) = policy, allowance > 0 {
            let retryPolicy = policy.doubled(contextTokens: contextTokens)
            retry = {
                let request = try await makeRequest(
                    messages: messages, maxTokens: maxTokens, stream: true, policy: retryPolicy)
                let (more, moreResponse) = try await PrivateURLSession.shared.bytes(for: request)
                return try await Self.validatedLines(moreResponse, bytes: more)
            }
        }
        let summary = try await Self.drain(lines: lines, retry: retry, yield: yield)
        // P0-20a: the stream's own usage object (P0-17's decoder), reported after the
        // stream ended so counting never holds up a token.
        ModelPassRecorder.current?.report(openRouter: summary.usage)
        return summary
    }

    /// One SSE line's events. One line can carry content, a finish reason and usage at
    /// once, so this is a list; a line that carries none is empty. Reasoning text is
    /// counted as characters and never returned as content.
    static func parseStreamEvents(_ line: String) throws -> [OpenRouterStreamEvent] {
        guard line.hasPrefix("data: ") else { return [] }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return [] }
        let event = try JSONDecoder().decode(StreamEvent.self, from: data)
        if let error = event.error {
            throw OpenRouterError.http(error.code ?? 500, error.message)
        }
        var events: [OpenRouterStreamEvent] = []
        if let choice = event.choices?.first {
            if let reasoning = choice.delta.reasoning, !reasoning.isEmpty {
                events.append(.reasoning(characters: reasoning.count))
            }
            if let content = choice.delta.content, !content.isEmpty {
                events.append(.content(content))
            }
            if let finish = choice.finish_reason, !finish.isEmpty {
                events.append(.finish(finish))
            }
        }
        if let usage = event.usage {
            events.append(.usage(usage.openRouterUsage))
        }
        return events
    }

    /// The pre-P0-17 view of one line: the content it carried, or nil. Kept because the
    /// older contract cases and callers read a line this way.
    static func parseStreamLine(_ line: String) throws -> String? {
        let content = try parseStreamEvents(line).compactMap { event -> String? in
            if case .content(let text) = event { return text }
            return nil
        }
        return content.isEmpty ? nil : content.joined()
    }

    /// Drains one streamed pass and reports what it produced.
    ///
    /// A pass that hits the answer limit is a cut-off, not an unreadable response: with
    /// visible text it yields that text and then throws `cutOff(visibleText: true)`; with
    /// none it throws `cutOff(visibleText: false)`. `retry` is the one second attempt such
    /// a pass is allowed — the caller builds it only when the reasoning allowance permits
    /// another try — and `[DONE]` ends a pass normally.
    static func drain<S: AsyncSequence & Sendable>(
        lines: S,
        retry: (@Sendable () async throws -> S)? = nil,
        yield: @Sendable (String) -> Void
    ) async throws -> OpenRouterStreamSummary where S.Element == String {
        var summary = try await drainOnce(lines: lines, yield: yield)
        if summary.finishReason == "length" {
            guard summary.visibleCharacters == 0, let retry else {
                throw OpenRouterError.cutOff(visibleText: summary.visibleCharacters > 0)
            }
            summary = try await drainOnce(lines: try await retry(), yield: yield)
            if summary.finishReason == "length" {
                throw OpenRouterError.cutOff(visibleText: summary.visibleCharacters > 0)
            }
        }
        guard summary.visibleCharacters > 0 else { throw OpenRouterError.invalidResponse }
        return summary
    }

    private static func drainOnce<S: AsyncSequence & Sendable>(
        lines: S,
        yield: @Sendable (String) -> Void
    ) async throws -> OpenRouterStreamSummary where S.Element == String {
        var summary = OpenRouterStreamSummary()
        for try await line in lines {
            try Task.checkCancellation()
            if line == "data: [DONE]" { break }
            for event in try Self.parseStreamEvents(line) {
                switch event {
                case .content(let text):
                    yield(text)
                    summary.visibleCharacters += text.count
                case .reasoning(let characters):
                    summary.reasoningCharacters += characters
                case .finish(let reason):
                    summary.finishReason = reason
                case .usage(let usage):
                    summary.usage = usage
                }
            }
        }
        return summary
    }

    /// The lines of a 2xx streaming response. A non-2xx one is read as an error body, so
    /// the message can name what the provider refused — the reasoning fallback reads it.
    private static func validatedLines(
        _ response: URLResponse, bytes: URLSession.AsyncBytes
    ) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: body).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw OpenRouterError.http(http.statusCode, String(message.prefix(300)))
        }
        return bytes.lines
    }

    /// A provider that answers HTTP 400 and names `reasoning` means the model's recorded
    /// status was wrong. The one recovery is the same request without the field.
    static func rejectsReasoning(_ error: OpenRouterError) -> Bool {
        guard case .http(400, let message) = error else { return false }
        return message.lowercased().contains("reasoning")
    }

    /// Remember that this model refused the reasoning field, so the next request never
    /// sends it. On the main actor because `Settings` is; the API key is never logged.
    static func rememberNoReasoning(modelID: String) async {
        await MainActor.run {
            Settings.shared.openRouterModelReasons[modelID] = false
        }
    }

    /// The one place a chat request body is built. `visibleMaxTokens` is the caller's
    /// visible budget; the reasoning policy adds its allowance on top and, for a model that
    /// reasons, asks the provider to keep the reasoning text out of the visible answer.
    /// `.off` leaves the body identical to the one the provider sent before reasoning
    /// control existed.
    static func requestBody(
        model: String,
        messages: [LLMChatMessage],
        visibleMaxTokens: Int,
        stream: Bool,
        policy: OpenRouterReasoningPolicy
    ) throws -> Data {
        try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: messages.map { ChatRequest.Message(role: $0.role.rawValue, content: $0.content) },
            max_tokens: visibleMaxTokens + policy.allowance,
            stream: stream,
            reasoning: reasoningField(policy)
        ))
    }

    /// What the body asks for: nothing for `.off`, the cheap capped pass otherwise.
    private static func reasoningField(
        _ policy: OpenRouterReasoningPolicy
    ) -> ChatRequest.Reasoning? {
        switch policy {
        case .off: nil
        case .capped: ChatRequest.Reasoning(effort: "low", exclude: true)
        }
    }

    private func makeRequest(
        messages: [LLMChatMessage], maxTokens: Int, stream: Bool,
        policy: OpenRouterReasoningPolicy? = nil
    ) async throws -> URLRequest {
        guard !modelID.isEmpty else { throw OpenRouterError.missingModel }
        guard let key = await OpenRouterKeyStore.keyAsync() else { throw OpenRouterError.missingKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 120 : 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(
            model: modelID,
            messages: messages,
            visibleMaxTokens: maxTokens,
            stream: stream,
            policy: await boundedPolicy(
                policy ?? reasoning, messages: messages, visible: maxTokens)
        )
        return request
    }

    /// The allowance is added to the caller's visible budget, never allowed to overrun the
    /// room left in the reader's window.
    private func boundedPolicy(
        _ policy: OpenRouterReasoningPolicy, messages: [LLMChatMessage], visible: Int
    ) async -> OpenRouterReasoningPolicy {
        guard case .capped = policy else { return policy }
        let promptTokens = (try? await countTokens(
            messages.map(\.content).joined(separator: "\n"))) ?? 0
        return policy.bounded(
            room: contextTokens - promptTokens - AgentAnswerBudget.safetyTokens, visible: visible)
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
        struct Message: Encodable, Sendable { let role: String; let content: String }
        struct Reasoning: Encodable, Sendable { let effort: String; let exclude: Bool }
        let model: String
        let messages: [Message]
        let max_tokens: Int
        let stream: Bool
        /// Nil for `.off`; the synthesized encoder omits it, so that body is unchanged.
        let reasoning: Reasoning?
    }
    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
        let choices: [Choice]
        let usage: Usage?
    }
    private struct StreamEvent: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let reasoning: String?
            }
            let delta: Delta
            let finish_reason: String?
        }
        struct APIError: Decodable { let code: Int?; let message: String }
        struct Usage: Decodable {
            struct PromptDetails: Decodable { let cached_tokens: Int? }
            struct CompletionDetails: Decodable { let reasoning_tokens: Int? }
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let prompt_tokens_details: PromptDetails?
            let completion_tokens_details: CompletionDetails?

            var openRouterUsage: OpenRouterUsage {
                OpenRouterUsage(
                    promptTokens: prompt_tokens,
                    cachedTokens: prompt_tokens_details?.cached_tokens,
                    completionTokens: completion_tokens,
                    reasoningTokens: completion_tokens_details?.reasoning_tokens)
            }
        }
        let choices: [Choice]?
        let error: APIError?
        let usage: Usage?
    }
    private struct ErrorResponse: Decodable {
        struct APIError: Decodable { let message: String }
        let error: APIError
    }
}

// MARK: - Vision (P1-2, image part only)

///
/// The chat protocol (`LLMProvider`) is untouched: vision enters through
/// `completeWithImages`, which the tool loop calls only after `VisionScope` and the
/// per-run consent sheet both approved. Text requests are byte-identical to before.
extension OpenRouterLLMProvider {
    /// `image_url` data-URL parts for `images` — or nothing. Fail-closed: consent off
    /// (or a cloud reader without it, via `VisionScope`) means no part is ever built,
    /// which `--selftest-openrouter-contract` pins.
    static func imageParts(_ images: [LLMImage], consent: Bool) -> [[String: Any]] {
        images.compactMap { $0.contentPart(consent: consent) }
    }

    /// Chat request body with an optional vision turn. With no consented images the
    /// user message is the same plain string `makeRequest` sends.
    static func chatBody(
        model: String, system: String, user: String,
        images: [LLMImage], consent: Bool, maxTokens: Int, stream: Bool,
        policy: OpenRouterReasoningPolicy = .off
    ) throws -> Data {
        let parts = imageParts(images, consent: consent)
        let userMessage: [String: Any]
        if parts.isEmpty {
            userMessage = ["role": "user", "content": user]
        } else {
            userMessage = ["role": "user", "content": [["type": "text", "text": user]] + parts]
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], userMessage],
            "max_tokens": maxTokens + policy.allowance,
            "stream": stream,
        ]
        if case .capped = policy {
            body["reasoning"] = ["effort": "low", "exclude": true]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// One vision completion. Throws `visionBlocked` — sending nothing — unless every
    /// image survived the consent gate.
    func completeWithImages(
        system: String, user: String, images: [LLMImage], consent: Bool, maxTokens: Int
    ) async throws -> LLMCompletion {
        guard !images.isEmpty, Self.imageParts(images, consent: consent).count == images.count else {
            throw OpenRouterError.visionBlocked
        }
        // The per-run sheet cannot be forgotten at a call site: ask here, where the
        // bytes would leave. One question for the run, the first thumbnail as the
        // preview; a denial sends nothing.
        if let preview = images.first,
           !(await VisionConsentGate.requestApproval(
               thumbnail: preview.thumbnail, reason: "send a screenshot to the online model"
           )) {
            throw OpenRouterError.visionBlocked
        }
        guard let key = await OpenRouterKeyStore.keyAsync() else { throw OpenRouterError.missingKey }
        let began = Date()
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let visionPolicy: OpenRouterReasoningPolicy
        switch reasoning {
        case .off:
            visionPolicy = .off
        case .capped:
            let promptTokens = (try? await countTokens(system + "\n" + user)) ?? 0
            visionPolicy = reasoning.bounded(
                room: contextTokens - promptTokens - AgentAnswerBudget.safetyTokens,
                visible: maxTokens)
        }
        request.httpBody = try Self.chatBody(
            model: modelID, system: system, user: user,
            images: images, consent: consent, maxTokens: maxTokens, stream: false,
            policy: visionPolicy
        )
        let (data, response) = try await PrivateURLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw OpenRouterError.invalidResponse
        }
        return LLMCompletion(text: text,
                             generatedTokens: decoded.usage?.completion_tokens ?? max(1, text.utf8.count / 3),
                             duration: Date().timeIntervalSince(began))
    }
}

@MainActor
enum OpenRouterSelfTest {
    /// Collects streamed visible text for the diagnostic. `performStream`'s yield seam is
    /// `@Sendable`, so the collector is a locked box rather than a captured local.
    private final class StreamProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func note(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }

        var collected: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    static func run() async throws -> String {
        guard let key = await OpenRouterKeyStore.keyAsync() else { throw OpenRouterError.missingKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await PrivateURLSession.shared.data(for: request)
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
        let policy = OpenRouterReasoningPolicy.policy(for: model.id)
        let provider = OpenRouterLLMProvider(
            modelID: model.id,
            contextTokens: model.context_length ?? 8_192,
            reasoning: policy)
        let completion = try await provider.complete(
            system: "Reply with one word.", user: "Say OK.", maxTokens: 16
        )
        guard !completion.text.isEmpty else { throw OpenRouterError.invalidResponse }
        let probe = StreamProbe()
        let summary = try await provider.performStream(
            messages: [.init(role: .user, content: "Say OK.")], maxTokens: 64
        ) { probe.note($0) }
        guard !probe.collected.isEmpty else { throw OpenRouterError.invalidResponse }
        let policyLabel = switch policy {
        case .off: "off"
        case .capped(let allowance): "capped(\(allowance))"
        }
        let streamedReasoningTokens = summary.usage?.reasoningTokens
        let reasoningLabel = streamedReasoningTokens.map { String($0) } ?? "none"
        print("OPENROUTER_REASONING: policy=\(policyLabel) finish=\(summary.finishReason ?? "none") "
            + "reasoning_tokens=\(reasoningLabel) visible=\(summary.visibleCharacters)")
        return "\(model.id) · catalog, key, completion and stream verified"
    }
}

@MainActor
enum OpenRouterSpeedSelfTest {
    static func run() async throws -> String {
        guard await OpenRouterKeyStore.keyAsync() != nil else { throw OpenRouterError.missingKey }
        let catalog = OpenRouterCatalog.shared
        await catalog.refresh()
        if let problem = catalog.problem { throw OpenRouterError.http(0, problem) }
        let ids = Array(catalog.models.prefix(12).map(\.id))
        guard !ids.isEmpty else { throw OpenRouterError.invalidResponse }
        await catalog.loadSpeeds(for: ids)
        // A visible model picker may already be fetching these same IDs.
        // loadSpeeds skips in-flight IDs, so wait for that shared work before
        // judging the result instead of reporting a false failure.
        for _ in 0..<60 {
            if ids.allSatisfy({ catalog.checkedSpeedIDs.contains($0)
                || catalog.failedSpeedIDs.contains($0) }) { break }
            try await Task.sleep(for: .seconds(1))
        }
        guard ids.allSatisfy({ catalog.checkedSpeedIDs.contains($0) }),
              ids.contains(where: { catalog.speeds[$0] != nil }) else {
            throw OpenRouterError.speedProbe(
                "checked \(catalog.checkedSpeedIDs.count)/\(ids.count), "
                    + "rates \(catalog.speeds.count), failed \(catalog.failedSpeedIDs.count). "
                    + (catalog.speedFailure ?? "No endpoint error reported."))
        }
        return "checked \(ids.count) ranked models; \(catalog.speeds.count) reported recent tok/s"
    }
}

enum OpenRouterContractSelfTest {
    /// One canned pass through `drain`, filled in by its own task and read after the
    /// bounded wait. `@unchecked Sendable`: every access goes through `lock`.
    private final class DrainProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var summary: OpenRouterStreamSummary?
        private var failure: Error?
        private var retries = 0
        private var visible = ""

        func noteRetry() { lock.lock(); retries += 1; lock.unlock() }
        func noteYield(_ text: String) { lock.lock(); visible += text; lock.unlock() }
        func note(summary: OpenRouterStreamSummary) { lock.lock(); self.summary = summary; lock.unlock() }
        func note(failure: Error) { lock.lock(); self.failure = failure; lock.unlock() }

        var readSummary: OpenRouterStreamSummary? {
            lock.lock(); defer { lock.unlock() }; return summary
        }
        var readFailure: Error? {
            lock.lock(); defer { lock.unlock() }; return failure
        }
        var retryCalls: Int {
            lock.lock(); defer { lock.unlock() }; return retries
        }
        var visibleText: String {
            lock.lock(); defer { lock.unlock() }; return visible
        }
    }

    private static func cannedStream(_ lines: [String]) -> AsyncStream<String> {
        AsyncStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    /// The flag runs before the run loop, synchronously, so the one case that needs an
    /// async sequence is bridged on its own task with a bounded wait. `drain` is nonisolated
    /// and touches no actor, so the wait cannot deadlock it.
    private static func drainProbe(_ lines: [String], retry: Bool) -> DrainProbe {
        let probe = DrainProbe()
        let semaphore = DispatchSemaphore(value: 0)
        let retryFactory: (@Sendable () async throws -> AsyncStream<String>)?
        if retry {
            retryFactory = {
                probe.noteRetry()
                return cannedStream(lines)
            }
        } else {
            retryFactory = nil
        }
        Task.detached {
            do {
                let summary = try await OpenRouterLLMProvider.drain(
                    lines: cannedStream(lines),
                    retry: retryFactory,
                    yield: { probe.noteYield($0) }
                )
                probe.note(summary: summary)
            } catch {
                probe.note(failure: error)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return probe
    }

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let fixture = """
        {"id":"example/agent:free","name":"Example Agent","context_length":32768,
         "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
         "supported_parameters":["tools","reasoning"],
         "pricing":{"prompt":"0","completion":"0"}}
        """
        let decoded = fixture.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(OpenRouterModel.self, from: $0) }
        check("the model fixture did not decode", decoded != nil)
        if let model = decoded {
            check("the model fixture lost text-ness", model.isTextModel)
            check("the model fixture lost Agent tools", model.supportsTools)
            check("the model fixture lost the Reasoning label", model.supportsReasoning)
            check("the model fixture lost Free", model.isFree)
            check("the Agent filter dropped the fixture", OpenRouterModelFilter.agent.includes(model))
            check("the Free filter dropped the fixture", OpenRouterModelFilter.free.includes(model))
            check("the model fixture lost its $0.00 price", model.priceLabel.contains("$0.00"))
        }

        let endpointData = """
            {"data":{"endpoints":[
              {"provider_name":"Slow","throughput_last_30m":{"p50":34.5}},
              {"provider_name":"Fast","throughput_last_30m":{"p50":102.3}},
              {"provider_name":"Unknown","throughput_last_30m":null}
            ]}}
            """.data(using: .utf8)
        let speed = endpointData.flatMap { try? OpenRouterCatalog.parseSpeed($0) }
        check("the endpoint fixture picked \(speed?.provider ?? "nothing"), expected Fast",
              speed?.provider == "Fast" && speed?.tokensPerSecond == 102.3)

        check("a content line did not decode",
              (try? OpenRouterLLMProvider.parseStreamLine(
                  "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}")) == "OK")
        check("a provider comment line decoded as content",
              (try? OpenRouterLLMProvider.parseStreamLine(": OPENROUTER PROCESSING")) == nil)
        check("the DONE line decoded as content",
              (try? OpenRouterLLMProvider.parseStreamLine("data: [DONE]")) == nil)
        do {
            _ = try OpenRouterLLMProvider.parseStreamLine(
                "data: {\"error\":{\"code\":429,\"message\":\"Rate limited\"}}"
            )
            failures.append("an error line did not throw")
        } catch OpenRouterError.http(let status, _) {
            check("an error line lost its 429", status == 429)
        } catch {
            failures.append("an error line threw a different error")
        }

        // P1-2: no image_url part is ever built when consent is off — the vision
        // gate, pinned without a network or a window. The contract reader is nil
        // (no TaskLocal set), so consent alone decides, exactly as in production.
        let visionImage = LLMImage(
            data: Data([0xFF, 0xD8]), mimeType: "image/jpeg",
            thumbnail: Data([0xFF, 0xD8]), pixelWidth: 2, pixelHeight: 1
        )
        check("vision consent off still built an image part",
              OpenRouterLLMProvider.imageParts([visionImage], consent: false).isEmpty)
        let consented = OpenRouterLLMProvider.imageParts([visionImage], consent: true)
        check("vision consent on did not build the data URL",
              consented.count == 1
                  && (consented[0]["image_url"] as? [String: String])?["url"]?
                      .hasPrefix("data:image/jpeg;base64,") == true)

        // P0-17 a. The request body pays the reasoning allowance on top of the visible
        // budget, and only when the policy says the model reasons.
        let userMessage = LLMChatMessage(role: .user, content: "Say OK.")
        let cappedData = try? OpenRouterLLMProvider.requestBody(
            model: "example/agent:free", messages: [userMessage],
            visibleMaxTokens: 112, stream: true,
            policy: .capped(allowance: OpenRouterReasoningPolicy.defaultAllowance)
        )
        if let cappedData,
           let body = try? JSONSerialization.jsonObject(with: cappedData) as? [String: Any] {
            let reasoning = body["reasoning"] as? [String: Any]
            check("a capped body lost its reasoning effort", reasoning?["effort"] as? String == "low")
            check("a capped body did not exclude the reasoning text", reasoning?["exclude"] as? Bool == true)
            check("a capped body asked for \(body["max_tokens"] ?? "no max_tokens"), expected 1136",
                  body["max_tokens"] as? Int == 1_136)
        } else {
            failures.append("a capped request body did not encode as JSON")
        }
        let offData = try? OpenRouterLLMProvider.requestBody(
            model: "example/agent:free", messages: [userMessage],
            visibleMaxTokens: 112, stream: true, policy: .off
        )
        if let offData,
           let body = try? JSONSerialization.jsonObject(with: offData) as? [String: Any] {
            check("a non-reasoning body carried a reasoning key", body["reasoning"] == nil)
            check("a non-reasoning body asked for \(body["max_tokens"] ?? "no max_tokens"), expected 112",
                  body["max_tokens"] as? Int == 112)
        } else {
            failures.append("a non-reasoning request body did not encode as JSON")
        }

        // P0-17 b. The stream decoder reads content, reasoning, finish_reason and usage.
        let reasoningLine = "data: {\"choices\":[{\"delta\":{\"reasoning\":\"Thinking…\"}}]}"
        check("a content line decoded to the wrong events",
              (try? OpenRouterLLMProvider.parseStreamEvents(
                  "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}")) == [.content("OK")])
        check("a reasoning delta was not counted exactly once",
              (try? OpenRouterLLMProvider.parseStreamEvents(reasoningLine)) == [.reasoning(characters: 9)])
        // The one line on disk from G turn O5: prompt 1,726 (512 cached), completion 112,
        // reasoning 105, finish_reason "length".
        let lengthLine = """
        data: {"choices":[{"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":1726,"completion_tokens":112,"prompt_tokens_details":{"cached_tokens":512},"completion_tokens_details":{"reasoning_tokens":105}}}
        """
        let lengthEvents = (try? OpenRouterLLMProvider.parseStreamEvents(lengthLine)) ?? []
        let o5 = OpenRouterUsage(
            promptTokens: 1_726, cachedTokens: 512, completionTokens: 112, reasoningTokens: 105)
        check("the finish_reason was dropped from the stream", lengthEvents.contains(.finish("length")))
        check("the O5 usage numbers were dropped", lengthEvents.contains(.usage(o5)))
        check("the finish line decoded as \(lengthEvents.count) event(s), expected 2",
              lengthEvents.count == 2)

        // P0-17 c. An all-reasoning stream that ends at the limit retries once and then
        // reports the cut-off honestly — never silently, never as an invalid response.
        var thinkingOnly = Array(repeating: reasoningLine, count: 105)
        thinkingOnly.append(lengthLine)
        let thinking = drainProbe(thinkingOnly, retry: true)
        if let summary = thinking.readSummary {
            failures.append("an all-reasoning stream finished silently "
                + "(visible \(summary.visibleCharacters), finish \(summary.finishReason ?? "none"))")
        }
        switch thinking.readFailure as? OpenRouterError {
        case .some(.cutOff(let visibleText)):
            check("an all-reasoning cut-off claimed visible text", visibleText == false)
        case .some(let other):
            failures.append("an all-reasoning stream threw \(other), expected cutOff(false)")
        case .none:
            failures.append("an all-reasoning stream ended without a verdict")
        }
        check("an all-reasoning stream retried \(thinking.retryCalls) time(s), expected exactly 1",
              thinking.retryCalls == 1)

        // P0-17 d. A cut-off that already showed text keeps it and says so.
        let truncated = drainProbe([
            "data: {\"choices\":[{\"delta\":{\"content\":\"I have \"}}]}",
            lengthLine,
        ], retry: false)
        check("the visible text before a cut-off was not yielded",
              truncated.visibleText == "I have ")
        switch truncated.readFailure as? OpenRouterError {
        case .some(.cutOff(let visibleText)):
            check("a cut-off after visible text claimed no visible text", visibleText == true)
        case .some(let other):
            failures.append("a truncated answer threw \(other), expected cutOff(true)")
        case .none:
            failures.append("a truncated answer did not report the cut-off")
        }
        check("a cut-off after visible text retried \(truncated.retryCalls) time(s), expected 0",
              truncated.retryCalls == 0)

        for failure in failures { print("OPENROUTER_CONTRACT_WRONG: \(failure)") }
        return failures.isEmpty
    }
}
