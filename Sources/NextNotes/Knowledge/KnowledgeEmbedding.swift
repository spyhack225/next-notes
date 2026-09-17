import Accelerate
import Foundation

/// `knowledgeEmbedder`: which model gives the index its dense vectors.
///
/// Two tiers, the same shape as Qwen vs Apple Foundation Models for notes: potion is a
/// lookup table on the CPU with no forward pass, so hybrid search works minutes after a
/// small download; EmbeddingGemma is the quality tier. `none` — the default — keeps search
/// on BM25 alone and never loads anything.
enum KnowledgeEmbedderChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    case none
    case potion
    case embeddinggemma

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Keywords only"
        case .potion: "potion-retrieval-32M (fast, CPU)"
        case .embeddinggemma: "EmbeddingGemma-300M (best)"
        }
    }
}

/// What the text is for. EmbeddingGemma was trained with a different prompt on each side;
/// potion and the fake ignore it.
enum EmbeddingPurpose: Sendable {
    case query
    case document
}

/// Something that turns passages into unit vectors of `dimensions`.
///
/// `model` is written into `embedding.model` beside each vector. Search only compares
/// vectors carrying the embedder's own tag: a vector from another model — or the same model
/// at another truncation — is a different space, and cosine across spaces is noise.
protocol KnowledgeEmbedder: Sendable {
    var model: String { get }
    var dimensions: Int { get }
    /// Cosine at or below this is not a match: without a floor every query gets 50 vector
    /// "hits", and a query that matches nothing returns unrelated passages. Per model, because
    /// each model's unrelated-passage cosine sits at a different level. Never below 0.
    var minimumSimilarity: Float { get }
    /// One L2-normalised vector of `dimensions` per text, in order.
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]]
    /// Frees whatever the embedder holds. The indexer calls it when a backfill pass ends:
    /// embedding is a batch job, and weights resident after it are memory the notes model
    /// may need.
    func release() async
}

/// An embedder cheap enough to call inline — a table lookup, not a forward pass — so the
/// synchronous search path (`memory.recall`) can use it without a model load on the caller.
protocol SynchronousKnowledgeEmbedder: KnowledgeEmbedder {
    func embedNow(_ texts: [String], purpose: EmbeddingPurpose) throws -> [[Float]]
}

extension SynchronousKnowledgeEmbedder {
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        try embedNow(texts, purpose: purpose)
    }

    func release() async {}
}

enum KnowledgeEmbeddingError: LocalizedError, Equatable {
    case modelMissing(String)
    /// The notes model is loaded or working. The embedder never loads beside it.
    case notesModelResident
    /// A meeting, dictation, voice conversation or Agent reply is live: the model does not
    /// cold-load.
    case foregroundBusy
    case wrongDimensions(expected: Int, actual: Int)
    case invalidModelFile(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name): "\(name) is not downloaded."
        case .notesModelResident: "The notes model is in use; embedding waits until it is idle."
        case .foregroundBusy: "A meeting, dictation or voice conversation is in progress; search uses keywords until it ends."
        case .wrongDimensions(let expected, let actual): "The embedder returned \(actual) dimensions, expected \(expected)."
        case .invalidModelFile(let reason): "The embedding model file could not be read: \(reason)"
        }
    }
}

/// Vector arithmetic shared by every embedder, the store and search.
enum EmbeddingMath {
    /// Every stored vector is this long. EmbeddingGemma is Matryoshka-trained, so its first
    /// 256 of 768 dimensions are a usable embedding on their own and the index is a third of
    /// the size; potion's 512 are PCA components in order of variance, so the same prefix
    /// keeps the most of it. 37,000 chunks × 256 × 4 bytes is 38 MB resident.
    static let storedDimensions = 256

    /// The first `dimensions` components, L2-normalised. A vector shorter than that is an
    /// error the caller reports, not something to pad.
    static func matryoshka(_ vector: [Float], dimensions: Int) -> [Float] {
        normalized(Array(vector.prefix(dimensions)))
    }

    /// Unit length; an all-zero vector (a passage with no known tokens) stays zero, which
    /// scores zero against everything rather than NaN.
    static func normalized(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let norm = sumOfSquares.squareRoot()
        guard norm > 0, norm.isFinite else { return [Float](repeating: 0, count: vector.count) }
        var divisor = norm
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    static func norm(_ vector: [Float]) -> Float {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        return sumOfSquares.squareRoot()
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// `dims × 4` bytes, little-endian float32 — the `embedding.vector` format.
    static func blob(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func vector(from data: Data, dimensions: Int) -> [Float]? {
        guard data.count == dimensions * 4 else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<dimensions).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }
}

// MARK: - Fake embedder

/// A deterministic stand-in for a model, for self-tests: no download, no GPU, the same
/// vector for the same text on every machine.
///
/// Feature hashing of crude word stems plus their character trigrams, signed so unrelated
/// words cancel rather than pile up. A small table of concepts maps a few paraphrases onto one
/// feature ("ship" and "launch", "cost" and "price") — standing in for what a real model
/// knows about meaning, so the gold set can show vectors finding passages BM25 cannot.
/// Numbers measured with it describe the retrieval pipeline, never a model's quality.
struct FakeKnowledgeEmbedder: SynchronousKnowledgeEmbedder {
    let model: String
    let dimensions: Int

    init(dimensions: Int = EmbeddingMath.storedDimensions, tag: String = "fake-hash") {
        self.dimensions = dimensions
        model = "\(tag)@\(dimensions)"
    }

    /// Unrelated fixture passages score within ±0.06 of each other under the hash; 0.1 keeps
    /// them out while a shared concept still clears it.
    var minimumSimilarity: Float { 0.1 }

    func embedNow(_ texts: [String], purpose: EmbeddingPurpose) throws -> [[Float]] {
        texts.map(vector)
    }

    private func vector(_ text: String) -> [Float] {
        var values = [Float](repeating: 0, count: dimensions)
        for word in Self.words(text) {
            let concept = Self.concept(word)
            add(concept, weight: 1, to: &values)
            let padded = Array(" \(concept) ")
            if padded.count >= 5 {
                for index in 0...(padded.count - 3) {
                    add("#" + String(padded[index..<(index + 3)]), weight: 0.25, to: &values)
                }
            }
        }
        return EmbeddingMath.normalized(values)
    }

    private func add(_ feature: String, weight: Float, to values: inout [Float]) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in feature.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let index = Int(hash % UInt64(dimensions))
        let sign: Float = (hash >> 63) == 0 ? 1 : -1
        values[index] += sign * weight
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { !stopWords.contains($0) }
            .map(stem)
    }

    /// Plural, tense and adverb endings only; enough that "decided" meets "decide".
    static func stem(_ word: String) -> String {
        for suffix in ["ation", "ing", "ies", "ed", "es", "ly", "s"] where word.count > suffix.count + 3 {
            if word.hasSuffix(suffix) { return String(word.dropLast(suffix.count)) }
        }
        return word
    }

    static func concept(_ stem: String) -> String {
        concepts[stem] ?? stem
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "at", "by", "with", "is", "are", "was",
        "were", "be", "it", "this", "that", "we", "our", "us", "you", "i", "what", "when", "who", "which",
        "how", "did", "do", "does", "will", "should", "about", "from", "as", "there", "any", "have", "has",
    ]

    /// stem → concept. Hand-written for the gold fixture's paraphrases, deliberately small.
    static let concepts: [String: String] = [
        "launch": "ship", "releas": "ship", "release": "ship", "go-live": "ship", "rollout": "ship",
        "cost": "price", "pric": "price", "pricing": "price", "fee": "price", "expensive": "price",
        "hire": "recruit", "hir": "recruit", "hiring": "recruit", "recruit": "recruit", "role": "recruit",
        "headcount": "recruit", "candidate": "recruit",
        "bug": "defect", "crash": "defect", "outage": "defect", "incident": "defect", "broke": "defect",
        "custom": "client", "customer": "client", "client": "client", "account": "client",
        "money": "budget", "spend": "budget", "fund": "budget", "funding": "budget",
        "deadline": "due", "due": "due", "late": "delay", "slip": "delay", "postpon": "delay", "delay": "delay",
        "boss": "manager", "lead": "manager", "manager": "manager", "owner": "manager", "own": "manager",
        "vacation": "leave", "holiday": "leave", "time-off": "leave", "leave": "leave",
        "office": "workplace", "workspace": "workplace", "desk": "workplace",
        "security": "secure", "secur": "secure", "breach": "secure", "password": "secure",
        "cancel": "churn", "cancellation": "churn", "churn": "churn", "quit": "churn", "quitt": "churn",
        "contract": "agreement", "agreement": "agreement", "deal": "agreement",
        "car": "vehicle", "van": "vehicle", "vans": "vehicle", "vehicle": "vehicle", "truck": "vehicle",
        "laptop": "computer", "computer": "computer", "machine": "computer", "machin": "computer",
        "sale": "revenue", "revenue": "revenue", "income": "revenue",
    ]
}

// MARK: - Production embedders

/// Which embedder a choice means right now, or nil when its files are not downloaded — the
/// search then stays on BM25 and the indexer writes no vectors.
@MainActor
enum KnowledgeEmbedders {
    static func live(_ choice: KnowledgeEmbedderChoice) -> (any KnowledgeEmbedder)? {
        // A self-test never loads the user's downloaded models; it hands in a fake.
        guard !SelfTest.isRunning else { return nil }
        switch choice {
        case .none:
            return nil
        case .potion:
            return EmbeddingModels.isDownloaded(.potion) ? StaticEmbedder.shared : nil
        case .embeddinggemma:
            return EmbeddingModels.isDownloaded(.embeddinggemma) ? EmbeddingRuntime.shared : nil
        }
    }
}
