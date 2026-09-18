import Foundation

/// `--selftest-embed [text] [--model potion|embeddinggemma]`: does an embedder return a unit
/// vector of the right dimension, and does the indexer write vectors only when it may.
///
/// Without `--model` nothing real loads: the fake embedder, a potion-format table and
/// tokenizer written to a temporary directory, the Matryoshka truncation and blob format, the
/// llama runtime's refusals (missing file, notes model busy, a file that is not a model), the
/// pinned download descriptors, and the indexer's embedding pass over the fixture library —
/// waiting for recording and the notes model, batching, cascade on delete, switching models,
/// releasing the embedder. With `--model`, the downloaded model embeds `text` and the result
/// is printed; when it is not downloaded that is reported as pending, not as a failure.
@MainActor
enum KnowledgeEmbedSelfTest {
    static func run(text: String?) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-embed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // MARK: Defaults and isolation
        check("the embedder is not off by default", KnowledgeIndexSettings().embedder == .none)
        check("a self-test would load the user's downloaded embedder",
              KnowledgeEmbedders.live(.potion) == nil && KnowledgeEmbedders.live(.embeddinggemma) == nil)
        check("the shared indexer has an embedder under a self-test", KnowledgeIndexer.shared.embedder == nil)

        failures += mathFailures()
        failures += fakeFailures()
        failures += staticFailures(root: root.appendingPathComponent("potion", isDirectory: true))
        failures += await runtimeFailures(root: root.appendingPathComponent("gguf", isDirectory: true))
        failures += descriptorFailures()
        failures += await indexerFailures(root: root.appendingPathComponent("index", isDirectory: true))

        if let name = SelfTest.value(after: "--model") {
            await real(model: name, text: text ?? "We decided to ship the pricing page on Friday.")
        } else {
            print("EMBED_REAL pending: pass --model potion|embeddinggemma once a model is downloaded")
        }

        for failure in failures { print("EMBED_WRONG: \(failure)") }
        print(failures.isEmpty ? "EMBED_OK" : "EMBED_FAILED")
        return failures.isEmpty
    }

    // MARK: - Math

    private static func mathFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let truncated = EmbeddingMath.matryoshka([3, 4, 12, 84], dimensions: 2)
        check("matryoshka did not keep the prefix and normalise it",
              truncated.count == 2 && abs(truncated[0] - 0.6) < 1e-6 && abs(truncated[1] - 0.8) < 1e-6)
        check("a zero vector did not stay zero", EmbeddingMath.normalized([0, 0, 0]) == [0, 0, 0])
        let blob = EmbeddingMath.blob([1, -2.5, .leastNonzeroMagnitude])
        check("the blob is not little-endian float32", blob.count == 12 && Array(blob.prefix(4)) == [0x00, 0x00, 0x80, 0x3F])
        check("the blob did not round-trip",
              EmbeddingMath.vector(from: blob, dimensions: 3) == [1, -2.5, .leastNonzeroMagnitude])
        check("a blob of the wrong length decoded", EmbeddingMath.vector(from: blob, dimensions: 4) == nil)
        return failures
    }

    private static func fakeFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let fake = FakeKnowledgeEmbedder()
        guard let vectors = try? fake.embedNow([
            "We decided to ship the pricing page on Friday.",
            "The price page launches Friday.",
            "Open a second backend engineer role.",
            "We decided to ship the pricing page on Friday.",
        ], purpose: .document) else {
            return ["the fake embedder threw"]
        }
        check("the fake is not \(EmbeddingMath.storedDimensions) dimensions",
              fake.dimensions == EmbeddingMath.storedDimensions && vectors.allSatisfy { $0.count == fake.dimensions })
        check("the fake is not unit length", vectors.allSatisfy { abs(EmbeddingMath.norm($0) - 1) < 1e-4 })
        check("the fake is not deterministic", vectors[0] == vectors[3])
        let paraphrase = EmbeddingMath.dot(vectors[0], vectors[1])
        let unrelated = EmbeddingMath.dot(vectors[0], vectors[2])
        print(String(format: "EMBED_FAKE paraphrase=%.3f unrelated=%.3f", paraphrase, unrelated))
        check("the fake does not place a paraphrase nearer than an unrelated passage", paraphrase > unrelated + 0.2)
        check("the fake tag does not carry its dimension", fake.model == "fake-hash@256")
        return failures
    }

    // MARK: - potion format

    /// A four-word table in potion's format: `tokenizer.json` and a safetensors file whose
    /// rows are one-hot, so every mean is predictable. `[UNK]`'s row is huge, so averaging it
    /// by mistake shows.
    static func writeStaticFixture(directory: URL, width: Int = 8) throws -> (model: URL, tokenizer: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vocabulary = ["[PAD]": 0, "[UNK]": 1, "[CLS]": 2, "[SEP]": 3, "price": 4, "##s": 5, "page": 6,
                          "ship": 7, "cafe": 8, "un": 9, "##related": 10]
        let tokenizer: [String: Any] = [
            "normalizer": ["type": "BertNormalizer", "clean_text": true, "handle_chinese_chars": true,
                           "strip_accents": NSNull(), "lowercase": true],
            "pre_tokenizer": ["type": "BertPreTokenizer"],
            "model": ["type": "WordPiece", "unk_token": "[UNK]", "continuing_subword_prefix": "##",
                      "max_input_chars_per_word": 12, "vocab": vocabulary],
        ]
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        try JSONSerialization.data(withJSONObject: tokenizer).write(to: tokenizerURL)

        let rows = vocabulary.count
        var table = [Float](repeating: 0, count: rows * width)
        for (_, id) in vocabulary where id >= 4 { table[id * width + (id - 4) % width] = 1 }
        table[1 * width + width - 1] = 100
        var payload = Data()
        for value in table {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        var header = "{\"embeddings\":{\"dtype\":\"F32\",\"shape\":[\(rows),\(width)],\"data_offsets\":[0,\(payload.count)]}}"
        while (8 + header.utf8.count) % 8 != 0 { header += " " }
        var file = Data()
        var length = UInt64(header.utf8.count).littleEndian
        withUnsafeBytes(of: &length) { file.append(contentsOf: $0) }
        file.append(Data(header.utf8))
        file.append(payload)
        let modelURL = directory.appendingPathComponent("model.safetensors")
        try file.write(to: modelURL)
        return (modelURL, tokenizerURL)
    }

    private static func staticFailures(root: URL) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let files: (model: URL, tokenizer: URL)
        do {
            files = try writeStaticFixture(directory: root)
        } catch {
            return ["the potion fixture could not be written: \(error.localizedDescription)"]
        }
        let embedder = StaticEmbedder(modelURL: files.model, tokenizerURL: files.tokenizer, tag: "fixture-potion", dimensions: 4)
        do {
            check("the table loaded before the first embed", !embedder.isLoaded)
            check("WordPiece split or [UNK] was not dropped: \(try embedder.tokenIDs("Prices page!"))",
                  try embedder.tokenIDs("Prices page!") == [4, 5, 6])
            check("accents were not stripped", try embedder.tokenIDs("CAFÉ") == [8])
            check("a word with no full segmentation was not one [UNK]", try embedder.tokenIDs("pricey ship") == [7])
            check("continuation pieces were not matched", try embedder.tokenIDs("unrelated") == [9, 10])
            check("an over-long word was not [UNK]", try embedder.tokenIDs("unrelatedunrelated") == [])

            let vectors = try embedder.embedNow(["price page", "prices", "cafe", "xyz"], purpose: .document)
            let half = Float(0.5).squareRoot()
            check("the mean of two rows is wrong: \(vectors[0])",
                  zip(vectors[0], [half, 0, half, 0]).allSatisfy { abs($0 - $1) < 1e-5 })
            check("a subword mean is wrong: \(vectors[1])",
                  zip(vectors[1], [half, half, 0, 0]).allSatisfy { abs($0 - $1) < 1e-5 })
            check("a row outside the truncated prefix did not come back zero", vectors[2] == [0, 0, 0, 0])
            check("text with only unknown words averaged [UNK]", vectors[3] == [0, 0, 0, 0])
            check("the static embedder is not the requested width", vectors.allSatisfy { $0.count == 4 })
            check("the static tag does not carry its dimension", embedder.model == "fixture-potion@4")
            check("the table did not load", embedder.isLoaded)
            embedder.unload()
            check("unload kept the table", !embedder.isLoaded)
        } catch {
            failures.append("the static embedder threw: \(error.localizedDescription)")
        }

        let missing = StaticEmbedder(modelURL: root.appendingPathComponent("none.safetensors"),
                                     tokenizerURL: files.tokenizer, tag: "missing", dimensions: 4)
        do {
            _ = try missing.embedNow(["price"], purpose: .query)
            failures.append("a missing table embedded")
        } catch let error as KnowledgeEmbeddingError {
            check("a missing table is not modelMissing", error == .modelMissing("potion-retrieval-32M"))
        } catch {
            failures.append("a missing table threw the wrong error: \(error)")
        }

        let corrupt = root.appendingPathComponent("corrupt.safetensors")
        try? Data([0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0, 1, 2, 3]).write(to: corrupt)
        let broken = StaticEmbedder(modelURL: corrupt, tokenizerURL: files.tokenizer, tag: "corrupt", dimensions: 4)
        do {
            _ = try broken.embedNow(["price"], purpose: .query)
            failures.append("a corrupt table embedded")
        } catch let error as KnowledgeEmbeddingError {
            if case .invalidModelFile = error {} else { failures.append("a corrupt table threw \(error)") }
        } catch {
            failures.append("a corrupt table threw the wrong error: \(error)")
        }
        return failures
    }

    // MARK: - llama runtime

    private static func runtimeFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        check("the document prompt is not EmbeddingGemma's",
              EmbeddingRuntime.prompt("x", purpose: .document) == "title: none | text: x")
        check("the query prompt is not EmbeddingGemma's",
              EmbeddingRuntime.prompt("x", purpose: .query) == "task: search result | query: x")

        let missing = EmbeddingRuntime(modelURL: root.appendingPathComponent("absent.gguf"), displayName: "Fixture",
                                       tag: "fixture", notesModelBusy: { false })
        do {
            _ = try await missing.embed(["hello"], purpose: .document)
            failures.append("a missing GGUF embedded")
        } catch {
            check("a missing GGUF is not modelMissing: \(error)",
                  (error as? KnowledgeEmbeddingError) == .modelMissing("Fixture"))
        }

        // Not a model. With the notes model busy it must refuse before trying to load it;
        // without, the load must fail cleanly.
        let bogus = root.appendingPathComponent("bogus.gguf")
        try? Data("this is not a gguf file".utf8).write(to: bogus)
        let busy = NotesBusyProbe(busy: true)
        let runtime = EmbeddingRuntime(modelURL: bogus, displayName: "Fixture", tag: "fixture",
                                       notesModelBusy: { await busy.isBusy() })
        do {
            _ = try await runtime.embed(["hello"], purpose: .document)
            failures.append("the runtime loaded beside a busy notes model")
        } catch {
            check("a busy notes model did not refuse the load: \(error)",
                  (error as? KnowledgeEmbeddingError) == .notesModelResident)
        }
        check("the runtime asked about the notes model more than once per call", await busy.asked == 1)
        await busy.set(false)
        do {
            _ = try await runtime.embed(["hello"], purpose: .document)
            failures.append("a file that is not a model embedded")
        } catch {
            check("a bad model file did not fail as a load failure: \(error)",
                  (error as? LlamaError).map { if case .modelLoadFailed = $0 { true } else { false } } ?? false)
        }
        check("a failed load left the runtime loaded", await !runtime.isLoaded)

        // Live work: neither a query nor a document cold-loads — a recording that began after
        // the indexer's own blocker check still stops the load.
        let live = NotesBusyProbe(busy: true)
        let gated = EmbeddingRuntime(modelURL: bogus, displayName: "Fixture", tag: "fixture", notesModelBusy: { false },
                                     mayLoad: { _ in await !live.isBusy() })
        do {
            _ = try await gated.embed(["hello"], purpose: .query)
            failures.append("a query loaded the model during a meeting")
        } catch {
            check("a query during a meeting did not refuse as foregroundBusy: \(error)",
                  (error as? KnowledgeEmbeddingError) == .foregroundBusy)
        }
        do {
            _ = try await gated.embed(["hello"], purpose: .document)
            failures.append("a document loaded the model during a meeting")
        } catch {
            check("a document during a meeting did not refuse as foregroundBusy: \(error)",
                  (error as? KnowledgeEmbeddingError) == .foregroundBusy)
        }
        await live.set(false)
        do {
            _ = try await gated.embed(["hello"], purpose: .query)
        } catch {
            check("an idle query was refused by the live gate: \(error)", (error as? KnowledgeEmbeddingError) != .foregroundBusy)
        }

        // A shutdown that lands while the load awaits the notes-model check wins: the load
        // backs off rather than loading after the notes model asked it to go.
        let racing = RuntimeHolder()
        let raced = EmbeddingRuntime(modelURL: bogus, displayName: "Fixture", tag: "fixture",
                                     notesModelBusy: { await racing.runtime?.shutdown(); return false })
        await racing.set(raced)
        do {
            _ = try await raced.embed(["hello"], purpose: .document)
            failures.append("a load went ahead after a shutdown during its notes-model check")
        } catch {
            check("a shutdown during the notes-model check did not refuse the load: \(error)",
                  (error as? KnowledgeEmbeddingError) == .notesModelResident)
        }
        // A stop request with nothing loaded is cleared by the shutdown it precedes.
        await raced.stopNow()
        check("stopNow left the runtime loaded", await !raced.isLoaded)
        check("an empty batch loaded anything", (try? await missing.embed([], purpose: .query))?.isEmpty == true)
        check("the runtime tag does not carry its dimension",
              EmbeddingRuntime.shared.model == "embeddinggemma-300m-qat@\(EmbeddingMath.storedDimensions)")
        return failures
    }

    // MARK: - Download descriptors

    private static func descriptorFailures() -> [String] {
        var failures: [String] = []
        for choice in [KnowledgeEmbedderChoice.potion, .embeddinggemma] {
            let specs = EmbeddingModels.specs(choice)
            if specs.isEmpty { failures.append("\(choice) has no files") }
            for spec in specs {
                let pinned = spec.url.path.firstMatch(of: /\/resolve\/[0-9a-f]{40}\//) != nil
                if !pinned || spec.url.host() != "huggingface.co" {
                    failures.append("\(spec.fileName) is not pinned to a commit")
                }
                if spec.expectedSHA256?.firstMatch(of: /^[0-9a-f]{64}$/) == nil {
                    failures.append("\(spec.fileName) has no pinned SHA-256")
                }
                if spec.expectedBytes <= 0 { failures.append("\(spec.fileName) has no size") }
            }
            if EmbeddingModels.licence(choice) == nil { failures.append("\(choice) shows no licence") }
        }
        if !EmbeddingModels.specs(.none).isEmpty { failures.append("none downloads something") }
        return failures
    }

    // MARK: - The indexer's embedding pass

    private static func indexerFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        do {
            try KnowledgeFixtures.writeLibrary(meetingsRoot: meetingsRoot)
        } catch {
            return ["the fixture library could not be written: \(error)"]
        }
        let sources = FixtureKnowledgeSources(meetingsRoot: meetingsRoot)
        sources.sessions = [KnowledgeFixtures.conversation()]
        let environment = FixedKnowledgeIndexEnvironment(settings: KnowledgeIndexSettings(enabled: true, embedder: .potion))
        let first = CountingEmbedder(FakeKnowledgeEmbedder(tag: "fake-a"))
        let second = CountingEmbedder(FakeKnowledgeEmbedder(tag: "fake-b"))
        let store = KnowledgeStore(directory: root.appendingPathComponent("db", isDirectory: true))
        let indexer = KnowledgeIndexer(store: store, sources: sources, environment: environment, drainsOnChange: false,
                                       embedders: { choice in
                                           switch choice {
                                           case .none: nil
                                           case .potion: first
                                           case .embeddinggemma: second
                                           }
                                       })
        do {
            // The notes model is loaded: chunks are written, vectors are not.
            environment.notesModelBusy = true
            await indexer.backfill()
            let blocked = await indexer.drain()
            let chunks = try store.chunkCount()
            check("the fixture library produced no chunks", chunks > 0)
            if case .finished(let pass) = blocked {
                check("the pass did not say it waited for the notes model", pass.embeddingWaiting != nil && pass.embedded == 0)
            } else {
                failures.append("a drain with the notes model loaded did not finish its chunk jobs: \(blocked)")
            }
            check("vectors were written while the notes model was loaded", try store.embeddingCount() == 0)
            check("the embedder ran while the notes model was loaded", first.embedCalls == 0)

            // Recording: the same.
            environment.notesModelBusy = false
            environment.isRecording = true
            _ = await indexer.drain()
            check("vectors were written while recording", try store.embeddingCount() == 0)
            environment.isRecording = false

            // A voice conversation open or the Agent speaking: the same.
            environment.voiceSessionActive = true
            let voice = await indexer.drain()
            if case .finished(let pass) = voice {
                check("the pass did not say it waited for the voice conversation",
                      pass.embeddingWaiting != nil && pass.embedded == 0)
            }
            check("vectors were written during a voice conversation", try store.embeddingCount() == 0)
            check("the embedder ran during a voice conversation", first.embedCalls == 0)
            environment.voiceSessionActive = false

            // One batch at a time.
            let partial = await indexer.embedPending(maxBatches: 1)
            check("one batch wrote \(partial.embedded), expected \(min(chunks, KnowledgeIndexer.embeddingBatch))",
                  partial.embedded == min(chunks, KnowledgeIndexer.embeddingBatch))
            check("the embedder was not released after its pass", first.releaseCalls >= 1)

            // Idle: every chunk gets a vector.
            let finished = await indexer.drain()
            if case .finished(let pass) = finished {
                check("the pass did not report its vectors", pass.embeddingWaiting == nil && pass.failures.isEmpty)
            }
            check("not every chunk has a vector", try store.embeddingCount(model: first.model) == chunks)
            check("index_state.embedded is not set on every source",
                  try store.embeddedSourceCount() == store.stats().sources)
            check("the stats do not count vectors", try store.stats().embedded == chunks)
            let pending = try store.chunksNeedingEmbedding(model: first.model, limit: 100)
            check("chunks still need vectors after the pass", pending.isEmpty)

            // The stored vector is the embedder's, byte for byte.
            let sample = try KeywordKnowledgeSearch(store: store).search(KnowledgeQuery(text: "decided pricing page", limit: 1))
            if let hit = sample.first, let stored = try store.vector(chunkID: hit.chunkID) {
                let expected = try FakeKnowledgeEmbedder(tag: "fake-a").embedNow([hit.text], purpose: .document)[0]
                check("the stored vector is not the embedder's", stored.model == first.model && stored.vector == expected)
                check("the stored vector is not unit length", abs(EmbeddingMath.norm(stored.vector) - 1) < 1e-4)
            } else {
                failures.append("no stored vector for a known passage")
            }

            // Deleting a meeting takes its vectors with it (foreign keys + cascade).
            indexer.removeMeeting(KnowledgeFixtures.pricingID)
            check("a deleted meeting's vectors outlived its chunks", try store.embeddingCount() == store.chunkCount())

            // A second pass has nothing to do.
            let calls = first.embedCalls
            _ = await indexer.drain()
            check("a pass with nothing new embedded again", first.embedCalls == calls)

            // Switching models replaces every vector; none leaves them alone.
            environment.settings.embedder = .embeddinggemma
            _ = await indexer.drain()
            check("switching models kept the old model's vectors", try store.embeddingCount(model: first.model) == 0)
            check("switching models did not embed every chunk again",
                  try store.embeddingCount(model: second.model) == store.chunkCount())
            environment.settings.embedder = .none
            let none = await indexer.embedPending()
            check("embedder none wrote or removed vectors",
                  try none.embedded == 0 && store.embeddingCount(model: second.model) == store.chunkCount())
            check("embedder none did not fall back to BM25", indexer.searcher is KeywordKnowledgeSearch)
            environment.settings.embedder = .embeddinggemma
            check("an embedder did not switch search to hybrid", indexer.searcher is HybridKnowledgeSearch)

            check("the index is inconsistent after embedding", try store.integrityProblems().isEmpty)
        } catch {
            failures.append("the indexer pass threw: \(error.localizedDescription)")
        }
        return failures
    }

    // MARK: - A real model

    private static func real(model name: String, text: String) async {
        guard let choice = KnowledgeEmbedderChoice(rawValue: name), choice != .none else {
            print("EMBED_REAL unknown model \(name)")
            return
        }
        guard EmbeddingModels.isDownloaded(choice) else {
            print("EMBED_REAL pending: \(name) is not downloaded")
            return
        }
        let embedder: any KnowledgeEmbedder = choice == .potion ? StaticEmbedder.shared : EmbeddingRuntime.shared
        let started = Date()
        do {
            let vectors = try await embedder.embed([text], purpose: .document)
            let elapsed = Date().timeIntervalSince(started) * 1_000
            let vector = vectors.first ?? []
            print(String(format: "EMBED_REAL %@ dims=%d norm=%.4f ms=%.1f head=%@", embedder.model, vector.count,
                         EmbeddingMath.norm(vector), elapsed,
                         vector.prefix(4).map { String(format: "%.4f", $0) }.joined(separator: ",")))
        } catch {
            print("EMBED_REAL \(name) failed: \(error.localizedDescription)")
        }
        await embedder.release()
    }
}

/// Counts embed and release calls around another embedder.
final class CountingEmbedder: SynchronousKnowledgeEmbedder, @unchecked Sendable {
    private let base: FakeKnowledgeEmbedder
    private let lock = NSLock()
    private var embeds = 0
    private var releases = 0

    init(_ base: FakeKnowledgeEmbedder) {
        self.base = base
    }

    var model: String { base.model }
    var dimensions: Int { base.dimensions }
    var minimumSimilarity: Float { base.minimumSimilarity }

    var embedCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return embeds
    }

    var releaseCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return releases
    }

    func embedNow(_ texts: [String], purpose: EmbeddingPurpose) throws -> [[Float]] {
        lock.lock()
        embeds += 1
        lock.unlock()
        return try base.embedNow(texts, purpose: purpose)
    }

    func release() async {
        lock.withLock { releases += 1 }
    }
}

private actor RuntimeHolder {
    private(set) var runtime: EmbeddingRuntime?

    func set(_ runtime: EmbeddingRuntime) {
        self.runtime = runtime
    }
}

private actor NotesBusyProbe {
    private var busy: Bool
    private(set) var asked = 0

    init(busy: Bool) {
        self.busy = busy
    }

    func isBusy() -> Bool {
        asked += 1
        return busy
    }

    func set(_ value: Bool) {
        busy = value
    }
}
