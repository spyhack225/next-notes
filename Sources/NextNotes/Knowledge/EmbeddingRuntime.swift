import Foundation
import llama
import os

/// EmbeddingGemma through llama.cpp: `llama_set_embeddings` plus mean pooling.
///
/// A sibling of `NotesModelRuntime` rather than a use of it. That runtime is a decode loop
/// around one generation context; an embedding context is created with `embeddings = true`
/// and a pooling type, and returns one pooled vector per sequence instead of logits. The
/// lifecycle is the same shape: lazy load, idle unload, and `LlamaBackend` for the
/// process-wide state.
///
/// **Never beside the notes model.** The contended resource on a 16 GB Mac is not this
/// model's 265 MB — it is the moment Qwen's 2.7 GB and anything else load together. So:
///
/// - this runtime refuses to load while the notes model is loaded, loading or working
///   (`KnowledgeEmbeddingError.notesModelResident`), and the indexer waits;
/// - `NotesModelRuntime` shuts this runtime down before it maps its own weights;
/// - the check is the last suspension before the load, and a shutdown that arrives during
///   that suspension bumps `shutdowns`, which the load sees and backs off from. After the
///   check, loading and embedding run without suspending, so a shutdown request queues
///   behind the batch instead of freeing the context under it — unless the caller sets
///   the stop flag first (`stopNow()`), which the batch checks between passages.
///
/// **Never cold during live work.** The last check before a load asks `mayLoad`: a search
/// or `memory.recall` during a meeting, dictation or voice conversation embeds its query only
/// if the model is already resident; otherwise it refuses (`foregroundBusy`) and the search
/// stays on BM25. A document load (the backfill) is refused for the same reasons and for any
/// Agent reply in progress, so a recording that starts between the indexer's own check and
/// the load still wins. Starting a meeting, a dictation or a voice session stops the runtime
/// outright rather than leaving it to the idle timer.
///
/// **On the CPU.** Rule one of the plan is to put the embedder on a different unit from
/// Qwen: `n_gpu_layers = 0` with `op_offload` and `offload_kqv` off means no Metal buffers and
/// no ops or KV cache sent to the GPU — nothing queued behind notes, nothing for the Metal
/// shader compiler to wedge on — and a
/// 300M Q4_0 model embeds a few hundred tokens in tens of milliseconds on the performance
/// cores. A CoreML/ANE build is the later experiment `--selftest-embed` should compare.
actor EmbeddingRuntime: KnowledgeEmbedder {
    static let shared = EmbeddingRuntime(
        modelURL: EmbeddingModels.embeddingGemma.fileURL,
        displayName: EmbeddingModels.embeddingGemma.displayName,
        tag: "embeddinggemma-300m-qat",
        notesModelBusy: { await NotesModelRuntime.shared.isResidentOrBusy },
        mayLoad: { purpose in await MainActor.run { LiveKnowledgeIndexEnvironment.mayLoadEmbedder(for: purpose) } }
    )

    /// EmbeddingGemma's trained context. Chunks are at most ~300 words, well under it.
    static let contextTokens = 2_048
    /// A backfill releases the model when it ends; a query leaves it this long, so typing
    /// a second search does not pay a second load.
    static let idleUnload: TimeInterval = 60

    nonisolated let model: String
    nonisolated let dimensions: Int
    private let modelURL: URL
    private let displayName: String
    private let gpuLayers: Int32
    private let notesModelBusy: @Sendable () async -> Bool

    private var llamaModel: OpaquePointer?
    private var context: OpaquePointer?
    private var vocabulary: OpaquePointer?
    private var outputWidth = 0
    private var lastUse = Date()
    private var idleTask: Task<Void, Never>?
    /// Whether nothing live forbids a cold load for this purpose.
    private let mayLoad: @Sendable (EmbeddingPurpose) async -> Bool
    /// Bumped by every `shutdown()`, so a load that suspended across one knows.
    private var shutdowns: UInt64 = 0
    /// Set outside the actor by `requestStop()`, so a caller that must not wait behind a whole
    /// batch can stop it between passages. Cleared by the `shutdown()` that follows.
    private nonisolated let stopRequested = OSAllocatedUnfairLock(initialState: false)

    init(
        modelURL: URL, displayName: String, tag: String, dimensions: Int = EmbeddingMath.storedDimensions,
        gpuLayers: Int32 = 0, notesModelBusy: @escaping @Sendable () async -> Bool,
        mayLoad: @escaping @Sendable (EmbeddingPurpose) async -> Bool = { _ in true }
    ) {
        self.modelURL = modelURL
        self.displayName = displayName
        self.dimensions = dimensions
        self.gpuLayers = gpuLayers
        self.notesModelBusy = notesModelBusy
        self.mayLoad = mayLoad
        model = "\(tag)@\(dimensions)"
    }

    var isLoaded: Bool { llamaModel != nil }

    /// Uncalibrated: EmbeddingGemma's cosine between unrelated passages still has to be measured
    /// on a real library (pending, like its recall numbers). Conservative until then.
    nonisolated var minimumSimilarity: Float { 0.3 }

    /// The prompts EmbeddingGemma was trained with for retrieval.
    static func prompt(_ text: String, purpose: EmbeddingPurpose) -> String {
        switch purpose {
        case .query: "task: search result | query: \(text)"
        case .document: "title: none | text: \(text)"
        }
    }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        try await loadIfNeeded(purpose: purpose)
        // No suspension from here to the return: see the type's comment.
        guard let context, let vocabulary, let llamaModel else { throw LlamaError.notLoaded }
        defer {
            lastUse = Date()
            scheduleIdleUnload()
        }
        let encoderOnly = llama_model_has_encoder(llamaModel) && !llama_model_has_decoder(llamaModel)
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            if stopRequested.withLock({ $0 }) { throw KnowledgeEmbeddingError.notesModelResident }
            var tokens = try LlamaHelpers.tokenize(Self.prompt(text, purpose: purpose), vocabulary: vocabulary)
            if tokens.count > Self.contextTokens { tokens = Array(tokens.prefix(Self.contextTokens)) }
            if let memory = llama_get_memory(context) { llama_memory_clear(memory, true) }
            var batch = llama_batch_init(Int32(tokens.count), 0, 1)
            defer { llama_batch_free(batch) }
            for (position, token) in tokens.enumerated() {
                // Pooled embeddings read every position, so every token is an output.
                LlamaHelpers.add(token, position: llama_pos(position), logits: true, to: &batch)
            }
            let status = encoderOnly ? llama_encode(context, batch) : llama_decode(context, batch)
            guard status == 0, let pooled = llama_get_embeddings_seq(context, 0) else { throw LlamaError.decodeFailed }
            let full = Array(UnsafeBufferPointer(start: pooled, count: outputWidth))
            vectors.append(EmbeddingMath.matryoshka(full, dimensions: dimensions))
        }
        return vectors
    }

    func release() async {
        shutdown()
    }

    /// Asks a batch in progress to stop at the next passage. Nonisolated, so it lands while
    /// the actor is busy embedding.
    nonisolated func requestStop() {
        stopRequested.withLock { $0 = true }
    }

    /// `requestStop()` then `shutdown()`: for the notes model's load, memory pressure, and
    /// a meeting or dictation starting — none of which should wait behind a batch.
    nonisolated func stopNow() async {
        requestStop()
        await shutdown()
    }

    /// Frees the context and weights. Safe to call at any time; a batch in progress
    /// finishes first, because it never suspends.
    func shutdown() {
        shutdowns &+= 1
        stopRequested.withLock { $0 = false }
        idleTask?.cancel()
        idleTask = nil
        if let context {
            llama_free(context)
            self.context = nil
        }
        if let llamaModel {
            llama_model_free(llamaModel)
            self.llamaModel = nil
            vocabulary = nil
            outputWidth = 0
            Log.llm.info("\(self.displayName, privacy: .public) unloaded")
        }
    }

    private func loadIfNeeded(purpose: EmbeddingPurpose) async throws {
        if llamaModel != nil, context != nil {
            // Loaded already; the notes model cannot have loaded since, because its load
            // shuts this runtime down first.
            return
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw KnowledgeEmbeddingError.modelMissing(displayName)
        }
        await LlamaBackend.shared.initialize()
        await LlamaBackend.shared.awaitCleanupIdle()
        let epoch = shutdowns
        // Nothing cold-loads during a meeting, dictation or voice conversation: a query falls
        // back to BM25, the backfill waits for its next pass.
        if await !mayLoad(purpose) { throw KnowledgeEmbeddingError.foregroundBusy }
        // The last suspension before the load.
        if await notesModelBusy() { throw KnowledgeEmbeddingError.notesModelResident }
        guard epoch == shutdowns else { throw KnowledgeEmbeddingError.notesModelResident }
        if llamaModel != nil, context != nil { return }

        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = gpuLayers
        modelParameters.load_mode = LLAMA_LOAD_MODE_MMAP
        modelParameters.use_extra_bufts = false
        guard let loaded = llama_model_load_from_file(modelURL.path, modelParameters) else {
            throw LlamaError.modelLoadFailed
        }
        guard let loadedVocabulary = llama_model_get_vocab(loaded) else {
            llama_model_free(loaded)
            throw LlamaError.modelLoadFailed
        }
        let width = Int(llama_model_n_embd_out(loaded))
        guard width >= dimensions else {
            llama_model_free(loaded)
            throw KnowledgeEmbeddingError.wrongDimensions(expected: dimensions, actual: width)
        }

        var parameters = llama_context_default_params()
        parameters.n_ctx = UInt32(Self.contextTokens)
        // Non-causal attention needs the whole sequence in one physical batch.
        parameters.n_batch = UInt32(Self.contextTokens)
        parameters.n_ubatch = UInt32(Self.contextTokens)
        parameters.n_seq_max = 1
        parameters.embeddings = true
        parameters.pooling_type = LLAMA_POOLING_TYPE_MEAN
        if gpuLayers == 0 {
            // No layers on Metal is not enough: by default llama.cpp still offloads large
            // host ops and the KV ops to any GPU device it has.
            parameters.op_offload = false
            parameters.offload_kqv = false
        }
        let threads = max(1, min(4, ProcessInfo.processInfo.processorCount - 2))
        parameters.n_threads = Int32(threads)
        parameters.n_threads_batch = Int32(threads)
        guard let created = llama_init_from_model(loaded, parameters) else {
            llama_model_free(loaded)
            throw LlamaError.contextLoadFailed
        }
        llama_set_embeddings(created, true)

        llamaModel = loaded
        vocabulary = loadedVocabulary
        context = created
        outputWidth = width
        lastUse = Date()
        scheduleIdleUnload()
        Log.llm.info("\(self.displayName, privacy: .public) loaded on CPU for embeddings (\(width) dims)")
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnload))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard llamaModel != nil, Date().timeIntervalSince(lastUse) >= Self.idleUnload else { return }
        shutdown()
    }
}
