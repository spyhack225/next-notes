import Foundation

/// One model repository, as the browse list shows it.
struct HuggingFaceModel: Identifiable, Sendable, Equatable, Hashable {
    /// "unsloth/Qwen3-4B-Instruct-2507-GGUF".
    let id: String
    let author: String
    /// The part after the slash, with the "-GGUF" suffix removed.
    let name: String
    let downloads: Int
    let likes: Int
    /// The makers require you to accept their terms on the model's page first.
    let isGated: Bool
    /// "apache-2.0", "llama3.1", "mit" — nil when the repo does not say.
    let licenseID: String?
    let lastModified: Date?
    /// Parsed from the name when the repo metadata has not been fetched yet.
    let parameterBillions: Double?

    var pageURL: URL {
        URL(string: "https://huggingface.co/\(id)") ?? URL(string: "https://huggingface.co")!
    }

    /// "Made by unsloth" — the one thing about provenance a non-technical person can use.
    var makerSentence: String { "Published by \(author)" }

    /// "Used 12.7 million times" reads as popularity; "12729626 downloads" reads as noise.
    var popularitySentence: String {
        switch downloads {
        case 1_000_000...: "Used \(String(format: "%.1f", Double(downloads) / 1_000_000)) million times"
        case 1_000...: "Used \(downloads / 1_000) thousand times"
        case 1...: "Used \(downloads) times"
        default: "New"
        }
    }

    /// Plain-language licence line. Unknown licences are named rather than hidden.
    var licenseSentence: String {
        guard let licenseID else { return "The makers have not stated a licence." }
        switch licenseID.lowercased() {
        case "apache-2.0", "mit", "bsd-3-clause", "bsd", "cc-by-4.0":
            return "Free to use, including at work."
        case let value where value.hasPrefix("llama"):
            return "Meta's licence — free for most uses, with conditions."
        case let value where value.hasPrefix("gemma"):
            return "Google's Gemma terms apply."
        case let value where value.contains("nc"):
            return "Personal and research use only — not for commercial work."
        default:
            return "Licence: \(licenseID)."
        }
    }
}

/// One file inside a repository.
struct HuggingFaceRepoFile: Identifiable, Sendable, Equatable, Hashable {
    /// The path inside the repo, which is also its identity.
    var id: String { path }
    let path: String
    let sizeBytes: Int64
    /// The SHA-256 the Hub publishes as the LFS object id. Present for every large file,
    /// which is every file this feature cares about, and is what `ModelDownloader` verifies.
    let sha256: String?

    var fileName: String { (path as NSString).lastPathComponent }
    var quantization: String? { ModelFitEstimator.quantization(fromFileName: fileName) }

    /// A GGUF split across several files. llama.cpp can load these, but only from the first
    /// part and only with every part present, so the library skips them rather than
    /// downloading four gigabytes that will not open.
    var isSplitPart: Bool {
        fileName.range(of: #"-\d{5}-of-\d{5}\."#, options: .regularExpression) != nil
    }
}

/// What the Hub knows about one repository once it has been opened.
struct HuggingFaceModelDetails: Sendable, Equatable {
    let id: String
    let isGated: Bool
    let licenseID: String?
    /// Total parameter count from the GGUF header — the real number, not a guess at the name.
    let parameterCount: Int64?
    /// "qwen3", "llama", "gemma3". Used to warn before a download that llama.cpp may refuse.
    let architecture: String?
    let trainedContextLength: Int?
    let files: [HuggingFaceRepoFile]

    var parameterBillions: Double? {
        parameterCount.map { Double($0) / 1e9 }
    }

    /// The file the app should download without asking: Q4_K_M when it exists, then its
    /// neighbours. Split archives and non-GGUF files never win.
    var recommendedFile: HuggingFaceRepoFile? {
        files
            .filter { $0.fileName.lowercased().hasSuffix(".gguf") && !$0.isSplitPart }
            .min { lhs, rhs in
                let left = ModelFitEstimator.quantizationPreferenceRank(lhs.quantization)
                let right = ModelFitEstimator.quantizationPreferenceRank(rhs.quantization)
                if left != right { return left < right }
                return lhs.sizeBytes < rhs.sizeBytes
            }
    }

    /// Every GGUF a person could sensibly choose, best first.
    var selectableFiles: [HuggingFaceRepoFile] {
        files
            .filter { $0.fileName.lowercased().hasSuffix(".gguf") && !$0.isSplitPart }
            .sorted { lhs, rhs in
                let left = ModelFitEstimator.quantizationPreferenceRank(lhs.quantization)
                let right = ModelFitEstimator.quantizationPreferenceRank(rhs.quantization)
                if left != right { return left < right }
                return lhs.sizeBytes < rhs.sizeBytes
            }
    }
}

enum HuggingFaceError: LocalizedError, Equatable {
    /// The makers require their terms to be accepted on the model's page.
    case gated(repoID: String)
    /// The Hub asked for a signed-in account.
    case needsAccessKey
    /// A key is present but the Hub refused it.
    case accessKeyRejected
    case offline
    case http(Int)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .gated(let repoID):
            "The makers of \(repoID) ask you to agree to their terms before downloading."
        case .needsAccessKey:
            "This model needs a Hugging Face access key."
        case .accessKeyRejected:
            "That Hugging Face access key was not accepted."
        case .offline:
            "No internet connection."
        case .http(let status):
            "Hugging Face returned an error (\(status)). Try again in a moment."
        case .unreadableResponse:
            "Hugging Face sent something this app could not read."
        }
    }
}

/// Everything this app asks of huggingface.co.
///
/// Read-only and unauthenticated by default: browsing and downloading open models needs no
/// account at all, and the token is attached only when there is one. A `nonisolated enum`
/// rather than an actor because nothing here holds state — the key lives in the Keychain and
/// the results belong to whoever asked.
enum HuggingFaceClient {
    static let apiRoot = URL(string: "https://huggingface.co/api")!

    /// How a shelf is ordered.
    enum Sort: String, Sendable {
        /// Most downloaded of all time. The safest default for a first visit.
        case downloads
        /// What people are pulling this week.
        case trending = "trendingScore"
        case recent = "lastModified"
    }

    /// One page of results plus the cursor for the next.
    struct Page: Sendable {
        let models: [HuggingFaceModel]
        /// Opaque; pass it straight back to `search`. nil at the end of the list.
        let nextPageURL: URL?
    }

    // MARK: - Search

    /// GGUF text-generation repositories, newest page first.
    ///
    /// `filter=gguf` is the only reliable way to ask for files llama.cpp can open: the
    /// `pipeline_tag` is missing on most quantizer repos (unsloth, bartowski, TheBloke all
    /// leave it off), so filtering on it as well returns almost nothing.
    static func search(
        query: String? = nil,
        sort: Sort = .downloads,
        limit: Int = 30,
        token: String? = nil
    ) async throws -> Page {
        var components = URLComponents(
            url: apiRoot.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(max(1, min(100, limit)))),
        ]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "search", value: query))
        }
        components.queryItems = items
        return try await page(at: components.url!, token: token)
    }

    /// Continues a previous `Page`.
    static func page(at url: URL, token: String? = nil) async throws -> Page {
        let (data, response) = try await get(url, token: token)
        guard let summaries = try? JSONDecoder().decode([SearchEntry].self, from: data) else {
            throw HuggingFaceError.unreadableResponse
        }
        return Page(
            models: summaries.compactMap(\.model),
            nextPageURL: nextLink(in: response)
        )
    }

    /// The `Link: <…>; rel="next"` header the Hub uses instead of a page number.
    private static func nextLink(in response: HTTPURLResponse?) -> URL? {
        guard let header = response?.value(forHTTPHeaderField: "Link") else { return nil }
        for part in header.split(separator: ",") {
            guard part.contains("rel=\"next\""),
                  let open = part.firstIndex(of: "<"),
                  let close = part.firstIndex(of: ">"), open < close else { continue }
            return URL(string: String(part[part.index(after: open)..<close]))
        }
        return nil
    }

    // MARK: - One repository

    /// Metadata and file listing for one repository, in two requests.
    static func details(repoID: String, token: String? = nil) async throws -> HuggingFaceModelDetails {
        async let metadataTask = get(
            apiRoot.appendingPathComponent("models").appendingPathComponent(repoID), token: token)
        async let treeTask = files(repoID: repoID, token: token)

        let (data, _) = try await metadataTask
        guard let entry = try? JSONDecoder().decode(DetailEntry.self, from: data) else {
            throw HuggingFaceError.unreadableResponse
        }
        return HuggingFaceModelDetails(
            id: entry.id ?? repoID,
            isGated: entry.gatedFlag,
            licenseID: entry.cardData?.license ?? entry.licenseTag,
            parameterCount: entry.gguf?.total,
            architecture: entry.gguf?.architecture,
            trainedContextLength: entry.gguf?.context_length,
            files: try await treeTask
        )
    }

    /// Every file in the repository, with its size and its SHA-256.
    static func files(repoID: String, token: String? = nil) async throws -> [HuggingFaceRepoFile] {
        var components = URLComponents(
            url: apiRoot.appendingPathComponent("models")
                .appendingPathComponent(repoID)
                .appendingPathComponent("tree")
                .appendingPathComponent("main"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]

        let (data, _) = try await get(components.url!, token: token)
        guard let entries = try? JSONDecoder().decode([TreeEntry].self, from: data) else {
            throw HuggingFaceError.unreadableResponse
        }
        return entries.compactMap { entry in
            guard entry.type == "file" else { return nil }
            return HuggingFaceRepoFile(
                path: entry.path,
                // The LFS record is the authority: `size` on the outer entry is the pointer's
                // size for a file that has not been resolved.
                sizeBytes: entry.lfs?.size ?? entry.size ?? 0,
                sha256: entry.lfs?.oid
            )
        }
    }

    /// Where a file is actually fetched from.
    static func downloadURL(repoID: String, path: String) -> URL {
        let escaped = path
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(escaped)?download=true")!
    }

    // MARK: - Access

    /// Confirms a key works and returns the account name it belongs to.
    ///
    /// `whoami-v2` is the only endpoint that answers for a key alone, which makes it the
    /// right one for the "Paste your access key" step: the user finds out immediately rather
    /// than four gigabytes into a download.
    static func validate(token: String) async throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HuggingFaceError.needsAccessKey }
        let (data, _) = try await get(apiRoot.appendingPathComponent("whoami-v2"), token: trimmed)
        guard let account = try? JSONDecoder().decode(WhoAmI.self, from: data) else {
            throw HuggingFaceError.unreadableResponse
        }
        return account.fullname ?? account.name ?? "your account"
    }

    /// Asks the Hub whether this exact file can be fetched right now, without fetching it.
    ///
    /// A HEAD is the difference between finding out about a licence gate in a second and
    /// finding out after a person has watched a progress bar. 401 and 403 are the two the
    /// download path must also handle, and they mean different things: 401 is "sign in",
    /// 403 is "you are signed in, but you have not accepted the terms".
    static func checkAccess(repoID: String, path: String, token: String?) async -> HuggingFaceError? {
        var request = URLRequest(url: downloadURL(repoID: repoID, path: path))
        request.httpMethod = "HEAD"
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreadableResponse }
            switch http.statusCode {
            case 200..<400: return nil
            case 401: return token == nil ? .needsAccessKey : .accessKeyRejected
            case 403: return .gated(repoID: repoID)
            default: return .http(http.statusCode)
            }
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .offline
        } catch {
            return .http(0)
        }
    }

    // MARK: - Transport

    private static func get(_ url: URL, token: String?) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 200 {
            case 200..<300: return (data, http)
            case 401: throw token == nil ? HuggingFaceError.needsAccessKey : .accessKeyRejected
            case 403: throw HuggingFaceError.gated(repoID: url.lastPathComponent)
            case let status: throw HuggingFaceError.http(status)
            }
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .networkConnectionLost, .timedOut,
                 .dataNotAllowed, .cannotConnectToHost:
                throw HuggingFaceError.offline
            default:
                throw HuggingFaceError.http(0)
            }
        }
    }

    // MARK: - Wire shapes

    /// The Hub's `gated` field is `false`, `"auto"` or `"manual"` — a Bool in one case and a
    /// String in two, which is why it needs its own decoding.
    private struct GatedFlag: Decodable {
        let isGated: Bool
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                isGated = flag
            } else if let text = try? container.decode(String.self) {
                isGated = text.lowercased() != "false"
            } else {
                isGated = false
            }
        }
    }

    private struct SearchEntry: Decodable {
        let id: String?
        let modelId: String?
        let author: String?
        let downloads: Int?
        let likes: Int?
        let gated: GatedFlag?
        let tags: [String]?
        let lastModified: String?
        let pipeline_tag: String?

        /// Tasks that ship as GGUF but cannot hold a conversation. `pipeline_tag` is missing
        /// on most quantizer repos, so a chat model cannot be *required* to carry
        /// "text-generation" — but a repo that names one of these is never the assistant.
        private static let nonChatTasks: Set<String> = [
            "automatic-speech-recognition", "text-to-speech", "text-to-audio", "audio-to-audio",
            "audio-classification", "voice-activity-detection", "feature-extraction",
            "sentence-similarity", "text-ranking", "text-classification", "token-classification",
            "fill-mask", "translation", "text-to-image", "image-to-image", "text-to-video",
            "image-classification", "object-detection", "image-segmentation", "depth-estimation",
        ]

        private var isChatCapable: Bool {
            if let pipeline_tag, Self.nonChatTasks.contains(pipeline_tag) { return false }
            let named = Set(tags ?? [])
            guard named.isDisjoint(with: Self.nonChatTasks) else {
                // A repo may carry a second task tag alongside a chat one; trust the chat tag.
                return !named.isDisjoint(with: ["text-generation", "conversational", "image-text-to-text"])
            }
            return true
        }

        var model: HuggingFaceModel? {
            guard let repoID = id ?? modelId, repoID.contains("/"), isChatCapable else { return nil }
            let pieces = repoID.split(separator: "/", maxSplits: 1)
            let owner = author ?? String(pieces[0])
            var display = String(pieces[1])
            for suffix in ["-GGUF", "-gguf", ".GGUF", "_GGUF"] where display.hasSuffix(suffix) {
                display = String(display.dropLast(suffix.count))
            }
            let license = tags?
                .first { $0.hasPrefix("license:") }
                .map { String($0.dropFirst("license:".count)) }
            return HuggingFaceModel(
                id: repoID,
                author: owner,
                name: display.replacingOccurrences(of: "_", with: " "),
                downloads: downloads ?? 0,
                likes: likes ?? 0,
                isGated: gated?.isGated ?? false,
                licenseID: license,
                lastModified: lastModified.flatMap { ISO8601DateFormatter().date(from: $0) },
                parameterBillions: ModelFitEstimator.parameterBillions(fromName: display)
            )
        }
    }

    private struct DetailEntry: Decodable {
        struct CardData: Decodable { let license: String? }
        struct GGUF: Decodable {
            let total: Int64?
            let architecture: String?
            let context_length: Int?
        }
        let id: String?
        let gated: GatedFlag?
        let cardData: CardData?
        let tags: [String]?
        let gguf: GGUF?

        var gatedFlag: Bool { gated?.isGated ?? false }
        var licenseTag: String? {
            tags?.first { $0.hasPrefix("license:") }.map { String($0.dropFirst("license:".count)) }
        }
    }

    private struct TreeEntry: Decodable {
        struct LFS: Decodable {
            let oid: String?
            let size: Int64?
        }
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
    }

    private struct WhoAmI: Decodable {
        let name: String?
        let fullname: String?
    }
}
