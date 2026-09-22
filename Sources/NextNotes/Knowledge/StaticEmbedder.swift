import Foundation

/// potion-retrieval-32M: a Model2Vec static embedding, on the CPU, with no forward pass.
///
/// A Model2Vec model is a table — one row per WordPiece token — and embedding a passage is
/// tokenizing it and averaging its rows. That is the whole model, which is why it is the
/// instant-on tier: no GPU, no load time worth the name, and it never queues behind the on-device model.
///
/// What Model2Vec's own `encode` does, and this repeats:
///
/// - the BERT normalizer (`BertNormalizer`: clean control characters, space out CJK, strip
///   accents, lowercase) and pre-tokenizer (split on whitespace and on every punctuation mark);
/// - greedy longest-match WordPiece with the `##` continuation prefix, a word longer than
///   `max_input_chars_per_word` or with no full segmentation becoming `[UNK]`;
/// - no `[CLS]`/`[SEP]`, `[UNK]` dropped rather than averaged, at most 512 tokens;
/// - the mean of the rows, L2-normalised (`normalize: true` in the model's config).
///
/// Then the index's own step: the first 256 of 512 dimensions, normalised again.
///
/// The weights are memory-mapped, so the table is file-backed: the kernel can page it out
/// under pressure instead of the process holding 129 MB of anonymous memory.
final class StaticEmbedder: SynchronousKnowledgeEmbedder, @unchecked Sendable {
    static let shared = StaticEmbedder(
        modelURL: EmbeddingModels.potionModel.fileURL,
        tokenizerURL: EmbeddingModels.potionTokenizer.fileURL,
        tag: "potion-retrieval-32m"
    )

    static let maxTokens = 512

    let model: String
    let dimensions: Int
    /// Uncalibrated: potion's unrelated-passage cosine is still to be measured on a real
    /// library (pending). Static embeddings sit higher than a transformer's, hence this level.
    var minimumSimilarity: Float { 0.25 }
    private let modelURL: URL
    private let tokenizerURL: URL

    private let lock = NSLock()
    private var loaded: Loaded?

    init(modelURL: URL, tokenizerURL: URL, tag: String, dimensions: Int = EmbeddingMath.storedDimensions) {
        self.modelURL = modelURL
        self.tokenizerURL = tokenizerURL
        self.dimensions = dimensions
        model = "\(tag)@\(dimensions)"
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded != nil
    }

    func embedNow(_ texts: [String], purpose: EmbeddingPurpose) throws -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        let table = try loadLocked()
        return texts.map { text in
            let ids = table.tokenizer.ids(text).prefix(Self.maxTokens)
            var sum = [Float](repeating: 0, count: table.width)
            for id in ids { table.addRow(id, to: &sum) }
            if !ids.isEmpty {
                let count = Float(ids.count)
                for index in sum.indices { sum[index] /= count }
            }
            return EmbeddingMath.matryoshka(EmbeddingMath.normalized(sum), dimensions: dimensions)
        }
    }

    /// Unmaps the table. The next embed maps it again, which costs milliseconds.
    func release() async {
        unload()
    }

    func unload() {
        lock.lock()
        defer { lock.unlock() }
        loaded = nil
    }

    /// The token ids a text becomes, for the self-test.
    func tokenIDs(_ text: String) throws -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked().tokenizer.ids(text)
    }

    private func loadLocked() throws -> Loaded {
        if let loaded { return loaded }
        guard FileManager.default.fileExists(atPath: modelURL.path),
              FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            throw KnowledgeEmbeddingError.modelMissing("potion-retrieval-32M")
        }
        let tokenizer = try WordPieceTokenizer(contentsOf: tokenizerURL)
        let table = try Loaded(modelURL: modelURL, tokenizer: tokenizer)
        guard table.width >= dimensions else {
            throw KnowledgeEmbeddingError.wrongDimensions(expected: dimensions, actual: table.width)
        }
        loaded = table
        Log.app.info("potion embedder mapped: \(table.rows) tokens × \(table.width) dims")
        return table
    }

    /// The mapped safetensors file and where its one tensor starts.
    private struct Loaded {
        let data: Data
        let offset: Int
        let rows: Int
        let width: Int
        let tokenizer: WordPieceTokenizer

        init(modelURL: URL, tokenizer: WordPieceTokenizer) throws {
            let data = try Data(contentsOf: modelURL, options: .alwaysMapped)
            guard data.count >= 8 else { throw KnowledgeEmbeddingError.invalidModelFile("too short") }
            let headerLength = Int(data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) })
            guard headerLength > 0, 8 + headerLength <= data.count,
                  let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + headerLength))) as? [String: Any]
            else { throw KnowledgeEmbeddingError.invalidModelFile("no safetensors header") }
            // Model2Vec names its table `embeddings`; accept the only 2-D tensor otherwise.
            let tensors = header.filter { $0.key != "__metadata__" }
            guard let entry = (tensors["embeddings"] ?? (tensors.count == 1 ? tensors.first?.value : nil)) as? [String: Any],
                  entry["dtype"] as? String == "F32",
                  let shape = entry["shape"] as? [Int], shape.count == 2,
                  let offsets = entry["data_offsets"] as? [Int], offsets.count == 2
            else { throw KnowledgeEmbeddingError.invalidModelFile("no float32 embeddings tensor") }
            let start = 8 + headerLength + offsets[0]
            guard offsets[1] - offsets[0] == shape[0] * shape[1] * 4, 8 + headerLength + offsets[1] <= data.count else {
                throw KnowledgeEmbeddingError.invalidModelFile("tensor size does not match its shape")
            }
            guard tokenizer.vocabularySize <= shape[0] else {
                throw KnowledgeEmbeddingError.invalidModelFile("the tokenizer has more tokens than the table")
            }
            self.data = data
            offset = start
            rows = shape[0]
            width = shape[1]
            self.tokenizer = tokenizer
        }

        func addRow(_ id: Int, to sum: inout [Float]) {
            guard id >= 0, id < rows else { return }
            let base = offset + id * width * 4
            data.withUnsafeBytes { raw in
                for column in 0..<width {
                    let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + column * 4, as: UInt32.self))
                    sum[column] += Float(bitPattern: bits)
                }
            }
        }
    }
}

/// BERT-style WordPiece, read from a Hugging Face `tokenizer.json`.
struct WordPieceTokenizer: Sendable {
    let vocabulary: [String: Int]
    let unknownID: Int?
    let prefix: String
    let maxCharactersPerWord: Int
    let lowercase: Bool
    let stripAccents: Bool

    var vocabularySize: Int { (vocabulary.values.max() ?? -1) + 1 }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              model["type"] as? String == "WordPiece",
              let vocabulary = model["vocab"] as? [String: Int]
        else { throw KnowledgeEmbeddingError.invalidModelFile("tokenizer.json is not a WordPiece tokenizer") }
        self.vocabulary = vocabulary
        let unknown = model["unk_token"] as? String ?? "[UNK]"
        unknownID = vocabulary[unknown]
        prefix = model["continuing_subword_prefix"] as? String ?? "##"
        maxCharactersPerWord = model["max_input_chars_per_word"] as? Int ?? 100
        let normalizer = root["normalizer"] as? [String: Any]
        lowercase = normalizer?["lowercase"] as? Bool ?? true
        // BertNormalizer: `strip_accents: null` follows `lowercase`.
        stripAccents = (normalizer?["strip_accents"] as? Bool) ?? lowercase
    }

    /// Token ids without special tokens and without `[UNK]`.
    func ids(_ text: String) -> [Int] {
        var result: [Int] = []
        for word in words(normalize(text)) {
            let pieces = wordPieces(word)
            result.append(contentsOf: pieces.filter { $0 != unknownID })
        }
        return result
    }

    func normalize(_ text: String) -> String {
        var output = ""
        output.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD { continue }
            let properties = scalar.properties
            if scalar == "\t" || scalar == "\n" || scalar == "\r" || properties.isWhitespace {
                output.unicodeScalars.append(" ")
                continue
            }
            if properties.generalCategory == .control || properties.generalCategory == .format { continue }
            if Self.isCJK(scalar) {
                output.unicodeScalars.append(" ")
                output.unicodeScalars.append(scalar)
                output.unicodeScalars.append(" ")
                continue
            }
            output.unicodeScalars.append(scalar)
        }
        if stripAccents {
            output = String(String.UnicodeScalarView(
                output.decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark }))
        }
        return lowercase ? output.lowercased() : output
    }

    /// Whitespace-separated, with every punctuation mark its own word.
    func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty { words.append(String(current)) }
            current = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                flush()
            } else if Self.isPunctuation(scalar) {
                flush()
                words.append(String(scalar))
            } else {
                current.append(scalar)
            }
        }
        flush()
        return words
    }

    /// Greedy longest match. A word that cannot be segmented completely is one `[UNK]`.
    func wordPieces(_ word: String) -> [Int] {
        let characters = Array(word)
        guard characters.count <= maxCharactersPerWord else { return unknownID.map { [$0] } ?? [] }
        var pieces: [Int] = []
        var start = 0
        while start < characters.count {
            var end = characters.count
            var match: Int?
            while start < end {
                let piece = (start > 0 ? prefix : "") + String(characters[start..<end])
                if let id = vocabulary[piece] {
                    match = id
                    break
                }
                end -= 1
            }
            guard let match else { return unknownID.map { [$0] } ?? [] }
            pieces.append(match)
            start = end
        }
        return pieces
    }

    /// BERT's definition: ASCII non-alphanumeric symbols count, as does any Unicode `P*`.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
            || (0x20000...0x2A6DF).contains(value) || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value) || (0x2B820...0x2CEAF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x2F800...0x2FA1F).contains(value)
    }
}
