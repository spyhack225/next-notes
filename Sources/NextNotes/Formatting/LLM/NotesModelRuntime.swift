import Foundation
import llama

/// A general llama.cpp text-generation runtime, sized for whole meeting transcripts.
///
/// Generalised from `S1MiniRuntime`, which stays as it is: that one is a hot-path
/// normalizer with a fixed 2K context that must never leave the CPU, and this one is a
/// background summarizer that wants the GPU and a context sized to the transcript in hand.
/// The three things they genuinely share — tokenizing, detokenizing, filling a batch — live
/// in `LlamaHelpers`.
///
/// Two properties matter on a 16 GB machine:
/// - **The context is sized per prompt.** A 32K context on this architecture reserves
///   several gigabytes of KV cache whether or not the transcript needs it, so the context is
///   built to fit the prompt and rebuilt when the next one doesn't fit.
/// - **The model unloads when idle.** 2.7 GB of resident weights for a meeting that ended
///   half an hour ago is 2.7 GB the rest of the Mac could be using.
actor NotesModelRuntime {
    /// The notes model. Other instances exist only in `--selftest-llm-metal`, which loads a
    /// second, smaller GGUF on the GPU to prove Metal and CPU runtimes coexist.
    static let shared = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: NotesModelRuntime.allGPULayers)

    /// Offload everything. 4B at Q4_K_M is ~2.7 GB against 16 GB of unified memory, so
    /// there is no layer-splitting decision to make — either Metal is on or it isn't.
    static let allGPULayers: Int32 = 99

    /// Qwen3.5 trains to 256K, but a context that size would reserve more memory than this
    /// machine has. 32K is roughly four hours of speech, which is longer than any meeting
    /// the app will be asked to summarise in one pass.
    static let maxContextTokens = 32_768
    /// Below this, sizing the context to the prompt costs more rebuilds than it saves memory.
    private static let minContextTokens = 2_048
    /// Room for the chat template's own tokens and for a sampler that runs slightly past
    /// the budget before it hits a stop token.
    private static let contextHeadroom = 256
    private static let contextGranularity = 512
    private static let batchTokens: Int32 = 512

    /// How long the weights stay resident with nothing to do.
    static let idleUnload: TimeInterval = 10 * 60

    let spec: ModelSpec
    private let gpuLayers: Int32

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocabulary: OpaquePointer?
    private var contextSize = 0
    private var trainedContext = 0

    private var lastUse = Date()
    private var idleTask: Task<Void, Never>?
    /// The load in flight, so two callers share one.
    private var loadTask: Task<Void, Error>?

    init(spec: ModelSpec, gpuLayers: Int32) {
        self.spec = spec
        self.gpuLayers = gpuLayers
    }

    var isLoaded: Bool { model != nil }

    /// The usable prompt budget, once the model is loaded and its trained context is known.
    var contextTokens: Int {
        trainedContext > 0 ? min(trainedContext, Self.maxContextTokens) : Self.maxContextTokens
    }

    /// Loads the weights without generating, so the first meeting to finish doesn't pay the
    /// cold start on top of transcription.
    func prepare() async throws {
        try await loadIfNeeded()
    }

    func countTokens(_ text: String) async throws -> Int {
        try await loadIfNeeded()
        guard let vocabulary else { throw LlamaError.notLoaded }
        return try LlamaHelpers.tokenize(text, vocabulary: vocabulary).count
    }

    /// One ChatML turn, generated greedily-but-not-quite (see the sampler below).
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        try await loadIfNeeded()
        // On every exit, not just the successful one: a transcript that was too long, a
        // failed decode or a cancelled generation leaves the weights just as resident as a
        // generation that worked, and without this they would stay that way until quit.
        defer {
            lastUse = Date()
            scheduleIdleUnload()
        }
        guard let vocabulary else { throw LlamaError.notLoaded }

        let prompt = Self.chatMLPrompt(system: system, user: user)
        let promptTokens = try LlamaHelpers.tokenize(prompt, vocabulary: vocabulary)
        guard promptTokens.count + maxTokens + Self.contextHeadroom <= contextTokens else {
            throw LlamaError.inputTooLong
        }

        let context = try ensureContext(promptTokens: promptTokens.count, maxTokens: maxTokens)
        llama_memory_clear(llama_get_memory(context), true)
        try LlamaHelpers.decodePrompt(promptTokens, context: context, chunk: Int(Self.batchTokens))

        guard let sampler = makeSampler(vocabulary: vocabulary) else {
            throw LlamaError.samplerFailed
        }
        defer { llama_sampler_free(sampler) }

        let began = Date()
        var output = ""
        var generated = 0
        var position = llama_pos(promptTokens.count)

        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }

        while generated < maxTokens {
            // Cancellation matters here in a way it doesn't for dictation cleanup: this loop
            // can run for minutes, and a user who deleted the meeting shouldn't have to wait
            // for the notes to finish being written for it.
            try Task.checkCancellation()

            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            output += LlamaHelpers.piece(token, vocabulary: vocabulary)
            generated += 1
            // Some Qwen GGUF conversions emit the turn terminator as text rather than as an
            // end-of-generation token; without this the model keeps writing a second turn.
            if output.hasSuffix(Self.turnEnd) {
                output.removeLast(Self.turnEnd.count)
                break
            }

            batch.n_tokens = 0
            LlamaHelpers.add(token, position: position, logits: true, to: &batch)
            guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }
            position += 1
        }

        return LLMCompletion(
            text: output.trimmingCharacters(in: .whitespacesAndNewlines),
            generatedTokens: generated,
            duration: Date().timeIntervalSince(began)
        )
    }

    /// Frees the weights and the context if nothing has used them for `interval`.
    func unloadIfIdle(after interval: TimeInterval = NotesModelRuntime.idleUnload) {
        guard model != nil, Date().timeIntervalSince(lastUse) >= interval else { return }
        shutdown()
        Log.llm.info("\(self.spec.displayName, privacy: .public) unloaded after idling")
    }

    /// Releases model and context. The process-wide backend belongs to `LlamaBackend`.
    func shutdown() {
        idleTask?.cancel()
        idleTask = nil
        if let context {
            llama_free(context)
            self.context = nil
            contextSize = 0
        }
        if let model {
            llama_model_free(model)
            self.model = nil
            vocabulary = nil
            trainedContext = 0
        }
    }

    // MARK: - Prompt

    /// ChatML with the thinking block pre-closed.
    ///
    /// Qwen3.5 is a hybrid reasoning model: left to itself it opens `<think>` and spends
    /// hundreds of tokens deliberating before writing anything. Notes are an extraction
    /// task, not a reasoning one, and on a 4B model the deliberation mostly costs minutes.
    /// Supplying an already-closed, empty think block is the documented way to start the
    /// answer immediately.
    static func chatMLPrompt(system: String, user: String) -> String {
        """
        <|im_start|>system
        \(system)<|im_end|>
        <|im_start|>user
        \(user)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        """
    }

    private static let turnEnd = "<|im_end|>"

    // MARK: - Sampling

    /// Slightly stochastic on purpose. Pure greedy decoding on a 4B model loops on list
    /// items — "Action items" repeating one bullet until the token budget runs out — and the
    /// repetition penalty alone doesn't break the loop. The seed is fixed so that pressing
    /// Regenerate twice on an unchanged transcript is a diagnosis, not a dice roll.
    private func makeSampler(vocabulary: OpaquePointer) -> UnsafeMutablePointer<llama_sampler>? {
        var parameters = llama_sampler_chain_default_params()
        parameters.no_perf = true
        guard let chain = llama_sampler_chain_init(parameters) else { return nil }
        llama_sampler_chain_add(
            chain,
            llama_sampler_init_penalties(
                llama_vocab_n_tokens(vocabulary),
                Self.penaltyWindow,
                Self.repeatPenalty,
                0,
                0
            )
        )
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(Self.minP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(Self.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Self.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(Self.seed))
        return chain
    }

    private static let temperature: Float = 0.6
    private static let topP: Float = 0.9
    private static let minP: Float = 0.05
    private static let repeatPenalty: Float = 1.05
    private static let penaltyWindow: Int32 = 256
    private static let seed: UInt32 = 0x5EED

    // MARK: - Loading

    /// Loads once, however many callers ask at once.
    ///
    /// The load suspends twice — on the backend, and then for as long as a dictation cleanup
    /// takes to release its context — and an actor is re-entrant across both. Without one
    /// shared task, a Regenerate that arrives while an automatic summary is waiting on that
    /// gate loads a second 2.7 GB copy of the weights and leaks the first, which is exactly
    /// the swapping the gate exists to prevent.
    private func loadIfNeeded() async throws {
        if model != nil, vocabulary != nil { return }
        if let loadTask { return try await loadTask.value }

        let task = Task<Void, Error> {
            defer { self.loadTask = nil }
            try await self.load()
        }
        loadTask = task
        try await task.value
    }

    private func load() async throws {
        guard spec.isDownloaded else { throw LlamaError.modelMissing }

        await LlamaBackend.shared.initialize()
        // Both models are gigabytes and both are resident at once if this waits for nothing.
        // The dictation path is the one with a person waiting on it, so notes generation
        // yields: it loads only once the cleanup pass in flight has released its context.
        await LlamaBackend.shared.awaitCleanupIdle()

        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = gpuLayers
        // mmap rather than a read into anonymous memory: the weights stay file-backed, so
        // the kernel can evict them under pressure instead of the app being killed.
        modelParameters.load_mode = LLAMA_LOAD_MODE_MMAP
        // Repacking quantized weights doubles peak memory during load, which is exactly the
        // moment this process is least able to afford it.
        modelParameters.use_extra_bufts = false

        guard let loadedModel = llama_model_load_from_file(spec.fileURL.path, modelParameters) else {
            throw LlamaError.modelLoadFailed
        }
        guard let loadedVocabulary = llama_model_get_vocab(loadedModel) else {
            llama_model_free(loadedModel)
            throw LlamaError.modelLoadFailed
        }

        model = loadedModel
        vocabulary = loadedVocabulary
        trainedContext = Int(llama_model_n_ctx_train(loadedModel))
        // The timer starts at the load, not at the first generation: weights loaded by the
        // Models tab, or by a generation that then failed, are as resident as weights that
        // wrote notes, and would otherwise stay loaded until the app quits.
        lastUse = Date()
        scheduleIdleUnload()
        let metal = await LlamaBackend.shared.isMetalAvailable && gpuLayers > 0
        Log.llm.info("""
            \(self.spec.displayName, privacy: .public) loaded on \
            \(metal ? "GPU" : "CPU", privacy: .public)
            """)
    }

    /// Returns a context large enough for this prompt, building a new one when the current
    /// one is the wrong size.
    private func ensureContext(promptTokens: Int, maxTokens: Int) throws -> OpaquePointer {
        guard let model else { throw LlamaError.notLoaded }

        let wanted = promptTokens + maxTokens + Self.contextHeadroom
        let rounded = ((wanted + Self.contextGranularity - 1) / Self.contextGranularity)
            * Self.contextGranularity
        let size = min(max(rounded, Self.minContextTokens), contextTokens)

        if let context, contextSize == size { return context }
        if let context {
            llama_free(context)
            self.context = nil
            contextSize = 0
        }

        var parameters = llama_context_default_params()
        parameters.n_ctx = UInt32(size)
        parameters.n_batch = UInt32(Self.batchTokens)
        // Two cores are left for the audio threads and the UI. Summarization runs while a
        // meeting may still be transcribing, and a runtime that takes every core makes the
        // live transcript stutter.
        let threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        parameters.n_threads = Int32(threads)
        parameters.n_threads_batch = Int32(threads)

        guard let created = llama_init_from_model(model, parameters) else {
            throw LlamaError.contextLoadFailed
        }
        context = created
        contextSize = size
        return created
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnload))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }
}
