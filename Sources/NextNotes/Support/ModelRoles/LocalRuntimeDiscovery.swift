import Foundation
import Observation

/// Model-running apps a person may already have on this Mac.
///
/// Ollama and LM Studio both expose an OpenAI-compatible HTTP API on the loopback
/// interface, which is the only thing Next Notes needs from them. `custom` is any other
/// address the user typed in — a llama.cpp server, vLLM, LocalAI, anything that answers
/// `GET /models` and `POST /chat/completions`.
enum LocalRuntimeKind: String, Codable, Sendable, CaseIterable {
    case ollama
    case lmStudio
    case custom

    var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "Another app on this Mac"
        }
    }

    /// Where the app listens when it is installed with its default settings.
    var defaultBaseURL: URL? {
        switch self {
        case .ollama: URL(string: "http://127.0.0.1:11434/v1")
        case .lmStudio: URL(string: "http://127.0.0.1:1234/v1")
        case .custom: nil
        }
    }

    /// Ollama's own `/api/tags` carries the size and quantisation of each model, which the
    /// OpenAI-compatible `/models` list does not. Preferring it makes the picker rows
    /// readable ("3B · Q4_K_M · 2 GB") instead of a bare identifier.
    var nativeListingURL: URL? {
        switch self {
        case .ollama: URL(string: "http://127.0.0.1:11434/api/tags")
        case .lmStudio, .custom: nil
        }
    }
}

/// One OpenAI-compatible server Next Notes knows how to talk to.
struct LocalRuntimeEndpoint: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let kind: LocalRuntimeKind
    /// The OpenAI-compatible root — the thing `/models` and `/chat/completions` hang off.
    let baseURL: URL
    let displayName: String

    /// Loopback means the traffic never leaves this Mac. Anything else is a network
    /// service, and Next Notes does not add one on its own.
    var isLoopback: Bool { LocalRuntimeDiscovery.isLoopback(baseURL) }
}

/// One model a local server said it can run.
struct LocalRuntimeModel: Identifiable, Codable, Sendable, Hashable {
    let endpointID: String
    let modelID: String
    let displayName: String
    /// "3B · Q4_K_M · 2 GB", when the server told us. Nil when it only gave a name.
    let detail: String?

    var id: String { "\(endpointID)|\(modelID)" }
}

/// Why a server could not be used, in the words a person would use.
enum LocalRuntimeProblem: Error, Equatable, Sendable {
    case notRunning(String)
    case noModels(String)
    case badAddress(String)
    case notLoopback

    var message: String {
        switch self {
        case .notRunning(let name): "\(name) isn’t running right now."
        case .noModels(let name): "\(name) is running but hasn’t got any models yet."
        case .badAddress(let text): "“\(text)” isn’t an address Next Notes can use."
        case .notLoopback:
            "That address is on the network rather than on this Mac. "
                + "Next Notes only talks to apps running here."
        }
    }
}

/// Finds the model-running apps already installed on this Mac and lists what they hold.
///
/// Everything here is best-effort and short-lived: a person who has never heard of Ollama
/// should never see an error because it isn't installed, and a probe must not make the
/// Settings window wait. Timeouts are deliberately about a second — a local server either
/// answers immediately or is not there.
enum LocalRuntimeDiscovery {
    /// A loopback server answers in milliseconds. Anything slower is not running.
    static let probeTimeout: TimeInterval = 1.5

    // MARK: - Presence on disk

    /// Whether the app itself is on this Mac, regardless of whether it is running now.
    ///
    /// Used only to word the UI: "Ollama is installed but not running" is a useful thing
    /// to say, and "Ollama isn't installed" should not be said to someone who has it.
    static func isInstalled(_ kind: LocalRuntimeKind) -> Bool {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.path
        switch kind {
        case .ollama:
            if manager.fileExists(atPath: "/Applications/Ollama.app") { return true }
            if manager.fileExists(atPath: "\(home)/.ollama") { return true }
            return ACPAgentBackend.resolvedCLIPath("ollama") != nil
        case .lmStudio:
            if manager.fileExists(atPath: "/Applications/LM Studio.app") { return true }
            if manager.fileExists(atPath: "\(home)/.lmstudio") { return true }
            if manager.fileExists(atPath: "\(home)/.cache/lm-studio") { return true }
            return ACPAgentBackend.resolvedCLIPath("lms") != nil
        case .custom:
            return false
        }
    }

    // MARK: - Addresses

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// Turns whatever the user typed into an OpenAI-compatible root.
    ///
    /// People paste "localhost:8080", "http://127.0.0.1:1234", and the full
    /// ".../v1/chat/completions" they found in a README. All three mean the same server,
    /// so all three are accepted and normalised to the `/v1` root.
    static func normalizeAddress(_ text: String) -> Result<URL, LocalRuntimeProblem> {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.badAddress(text)) }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard var components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty,
              components.scheme == "http" || components.scheme == "https"
        else { return .failure(.badAddress(text)) }

        var path = components.path
        for suffix in ["/chat/completions", "/completions", "/models"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
            break
        }
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        if path.isEmpty { path = "/v1" }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return .failure(.badAddress(text)) }
        guard isLoopback(url) else { return .failure(.notLoopback) }
        return .success(url)
    }

    // MARK: - Probing

    struct ProbeResult: Sendable {
        let models: [LocalRuntimeModel]
        let problem: LocalRuntimeProblem?
    }

    /// Asks one server what it can run. Never throws: an absent server is a normal answer.
    static func probe(_ endpoint: LocalRuntimeEndpoint) async -> ProbeResult {
        guard endpoint.isLoopback else {
            return ProbeResult(models: [], problem: .notLoopback)
        }
        if let native = endpoint.kind.nativeListingURL,
           let data = await fetch(native) {
            let models = parseOllamaTags(data, endpointID: endpoint.id)
            if !models.isEmpty { return ProbeResult(models: models, problem: nil) }
            return ProbeResult(models: [], problem: .noModels(endpoint.displayName))
        }
        guard let data = await fetch(endpoint.baseURL.appendingPathComponent("models")) else {
            return ProbeResult(models: [], problem: .notRunning(endpoint.displayName))
        }
        let models = parseOpenAIModels(data, endpointID: endpoint.id)
        if models.isEmpty { return ProbeResult(models: [], problem: .noModels(endpoint.displayName)) }
        return ProbeResult(models: models, problem: nil)
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.httpMethod = "GET"
        // A stale answer would claim a stopped server is still running.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Parsing

    /// `GET /api/tags` — Ollama's own listing.
    static func parseOllamaTags(_ data: Data, endpointID: String) -> [LocalRuntimeModel] {
        guard let decoded = try? JSONDecoder().decode(OllamaTags.self, from: data) else { return [] }
        return decoded.models.compactMap { entry in
            let name = entry.model ?? entry.name
            guard let name, !name.isEmpty else { return nil }
            var parts: [String] = []
            if let size = entry.details?.parameter_size, !size.isEmpty { parts.append(size) }
            if let quantization = entry.details?.quantization_level, !quantization.isEmpty {
                parts.append(quantization)
            }
            if let bytes = entry.size, bytes > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            return LocalRuntimeModel(
                endpointID: endpointID,
                modelID: name,
                displayName: entry.name ?? name,
                detail: parts.isEmpty ? nil : parts.joined(separator: " · ")
            )
        }
    }

    /// `GET /v1/models` — the OpenAI-compatible listing every other server speaks.
    static func parseOpenAIModels(_ data: Data, endpointID: String) -> [LocalRuntimeModel] {
        guard let decoded = try? JSONDecoder().decode(OpenAIModelList.self, from: data) else { return [] }
        return decoded.data.compactMap { entry in
            guard !entry.id.isEmpty else { return nil }
            // LM Studio lists embedding models next to chat ones; they cannot answer a
            // conversation and would only be a confusing row in the picker.
            guard !entry.id.lowercased().contains("embed") else { return nil }
            return LocalRuntimeModel(
                endpointID: endpointID,
                modelID: entry.id,
                displayName: entry.id,
                detail: nil
            )
        }
    }

    private struct OllamaTags: Decodable {
        struct Entry: Decodable {
            struct Details: Decodable {
                let parameter_size: String?
                let quantization_level: String?
            }
            let name: String?
            let model: String?
            let size: Int64?
            let details: Details?
        }
        let models: [Entry]
    }

    private struct OpenAIModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }
}

/// The live list of local servers and what they hold, for the Settings rows and for
/// resolving a role at call time.
@MainActor
@Observable
final class LocalRuntimeCatalog {
    static let shared = LocalRuntimeCatalog()

    private static let customDefaultsKey = "modelRoles.customLocalServers"

    private(set) var models: [LocalRuntimeModel] = []
    private(set) var problems: [String: LocalRuntimeProblem] = [:]
    private(set) var isChecking = false
    private(set) var lastChecked: Date?

    /// Addresses the user added by hand, as typed-then-normalised absolute strings.
    private(set) var customAddresses: [String]

    init(customAddresses: [String]? = nil) {
        self.customAddresses = customAddresses
            ?? UserDefaults.standard.stringArray(forKey: Self.customDefaultsKey)
            ?? []
    }

    /// Ollama and LM Studio at their default ports, plus anything the user added.
    var endpoints: [LocalRuntimeEndpoint] {
        var result: [LocalRuntimeEndpoint] = []
        for kind in [LocalRuntimeKind.ollama, .lmStudio] {
            guard let url = kind.defaultBaseURL else { continue }
            result.append(
                LocalRuntimeEndpoint(
                    id: kind.rawValue, kind: kind, baseURL: url, displayName: kind.displayName
                )
            )
        }
        for address in customAddresses {
            guard let url = URL(string: address) else { continue }
            result.append(
                LocalRuntimeEndpoint(
                    id: address,
                    kind: .custom,
                    baseURL: url,
                    displayName: url.host.map { host in
                        url.port.map { "\(host):\($0)" } ?? host
                    } ?? address
                )
            )
        }
        return result
    }

    func endpoint(id: String) -> LocalRuntimeEndpoint? {
        endpoints.first { $0.id == id }
    }

    func models(forEndpoint id: String) -> [LocalRuntimeModel] {
        models.filter { $0.endpointID == id }
    }

    func hasModel(endpointID: String, modelID: String) -> Bool {
        models.contains { $0.endpointID == endpointID && $0.modelID == modelID }
    }

    /// Every endpoint's model ids, keyed by endpoint — the shape role resolution wants.
    var modelIDsByEndpoint: [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for model in models { result[model.endpointID, default: []].insert(model.modelID) }
        return result
    }

    var displayNamesByEndpoint: [String: String] {
        var result: [String: String] = [:]
        for endpoint in endpoints { result[endpoint.id] = endpoint.displayName }
        return result
    }

    /// Re-asks every server. Cheap enough to call when the Settings tab opens and when the
    /// user presses "Check again"; it is never on a turn's critical path.
    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var found: [LocalRuntimeModel] = []
        var trouble: [String: LocalRuntimeProblem] = [:]
        for endpoint in endpoints {
            let result = await LocalRuntimeDiscovery.probe(endpoint)
            found.append(contentsOf: result.models)
            if let problem = result.problem { trouble[endpoint.id] = problem }
        }
        models = found
        problems = trouble
        lastChecked = Date()
    }

    /// Adds an address the user typed. Returns a plain-language problem, or nil on success.
    @discardableResult
    func addCustomAddress(_ text: String) -> String? {
        switch LocalRuntimeDiscovery.normalizeAddress(text) {
        case .failure(let problem):
            return problem.message
        case .success(let url):
            let address = url.absoluteString
            if customAddresses.contains(address) { return nil }
            if LocalRuntimeKind.allCases.contains(where: { $0.defaultBaseURL == url }) { return nil }
            customAddresses.append(address)
            UserDefaults.standard.set(customAddresses, forKey: Self.customDefaultsKey)
            return nil
        }
    }

    func removeCustomAddress(_ address: String) {
        customAddresses.removeAll { $0 == address }
        UserDefaults.standard.set(customAddresses, forKey: Self.customDefaultsKey)
        models.removeAll { $0.endpointID == address }
        problems[address] = nil
    }
}
