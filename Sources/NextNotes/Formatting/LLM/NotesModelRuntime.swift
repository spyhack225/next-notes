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
///
/// Compute residency (S4):
/// - Meeting load/generation use `background`; interactive conversation uses
///   `realtimeAgent`. The one native context is reserved for a whole generation,
///   so a queued voice turn runs next but cannot corrupt an in-flight notes pass.
/// - Before loading, this runtime still waits on `LlamaBackend.awaitCleanupIdle()`.
///   It must **never** call `beginCleanup()` — that closes the gate and deadlocks
///   Qwen cleanup (`QwenCleanupFormatter`).
/// - Under memory pressure, `ModelResidencyPolicy` may call `shutdown()` before it
///   unloads diarization. Wake/KWS and Parakeet stay warm.
actor NotesModelRuntime {
    /// The shared notes and voice model. Other instances exist only in `--selftest-llm-metal`, which loads a
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
    private var conversationLeases: Set<UUID> = []
    /// The load in flight, so two callers share one.
    private var loadTask: Task<Void, Error>?
    /// Token for the current load in `ModelRuntimeManager`.
    private var runtimeGeneration: UInt64?
    /// Actor methods re-enter while a generation awaits a scheduler checkpoint.
    /// A pressure callback must not free the native context during that gap.
    private var activeOperations = 0
    private var deferredShutdown = false
    private var nativeOwner = false
    private var nativeWaiters: [(id: UUID, workClass: WorkClass, continuation: CheckedContinuation<Bool, Never>)] = []
    /// Test-only signal after a real native prefill chunk has decoded.
    private var prefillChunkObserverForTesting: (@Sendable () -> Void)?

    func setPrefillChunkObserverForTesting(_ observer: (@Sendable () -> Void)?) {
        prefillChunkObserverForTesting = observer
    }

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
        try await withBackgroundLane { jobID in
            try await loadIfNeeded(schedulerJobID: jobID)
        }
        // A prewarm can be the only use of this model. Give it the same idle
        // eviction as a completed answer instead of pinning the weights.
        lastUse = Date()
        scheduleIdleUnload()
    }

    /// Warm the inference context and its first decode, not only the weight file.
    /// The first reply otherwise still pays Metal/context initialization after
    /// `prepare()` has reported success. Discard this synthetic token entirely.
    func prepareForConversation(workClass: WorkClass = .realtimeAgent) async throws {
        try await withLane(workClass) { jobID in
            try await loadIfNeeded(schedulerJobID: jobID)
            guard context == nil else { return }
            try await streamWhileScheduled(
                jobID: jobID,
                prompt: Self.chatMLPrompt(
                    system: RealtimeAgent.voiceRoutingSystem(voice: true), user: "Hello."),
                maxTokens: 1, yield: { _ in })
        }
        lastUse = Date()
        scheduleIdleUnload()
    }

    /// Keep the already selected on-device model resident while a voice session is open.
    /// Memory-pressure shutdown can still unload it; a later turn reloads normally.
    func beginConversationSession(_ sessionID: UUID) {
        conversationLeases.insert(sessionID)
        idleTask?.cancel()
        idleTask = nil
        // Conversation uses the independent frontend. Opening its microphone
        // must not load and prefill a 4B worker before there is any work. The
        // first real worker request owns loadIfNeeded; the lease then keeps it.
    }

    func endConversationSession(_ sessionID: UUID) {
        conversationLeases.remove(sessionID)
        lastUse = Date()
        scheduleIdleUnload()
    }

    /// Destroy and reload the notes owner after an unrecoverable runtime error.
    /// The owner performs both operations; the registry observes the unload and
    /// the fresh generation created by the subsequent load.
    func recover() async throws {
        try await withBackgroundLane { jobID in
            // The lane waits for any generation using these pointers to finish.
            // Calling shutdown() before the wait could free its sampler/context.
            shutdownNow()
            try await loadIfNeeded(schedulerJobID: jobID)
        }
    }

    func countTokens(_ text: String) async throws -> Int {
        try await withBackgroundLane { jobID in
            try await loadIfNeeded(schedulerJobID: jobID)
            guard let vocabulary else { throw LlamaError.notLoaded }
            return try LlamaHelpers.tokenize(text, vocabulary: vocabulary).count
        }
    }

    /// One ChatML turn, generated greedily-but-not-quite (see the sampler below).
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        try await withBackgroundLane { jobID in
            try await completeWhileScheduled(jobID: jobID, system: system, user: user, maxTokens: maxTokens)
        }
    }

    /// Native token stream for interactive agent answers. The task is owned by the
    /// returned sequence, so cancelling a consumer reaches the llama loop between tokens.
    func stream(
        system: String,
        user: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        streamPrompt(Self.chatMLPrompt(system: system, user: user), maxTokens: maxTokens)
    }

    func streamConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        streamPrompt(Self.chatMLPrompt(system: system, messages: messages), maxTokens: maxTokens)
    }

    func streamInteractiveConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        streamPrompt(
            Self.chatMLPrompt(system: system, messages: messages),
            maxTokens: maxTokens,
            workClass: .realtimeAgent
        )
    }

    private func streamPrompt(
        _ prompt: String,
        maxTokens: Int,
        workClass: WorkClass = .background
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.withLane(workClass) { jobID in
                        try await self.streamWhileScheduled(
                            jobID: jobID,
                            prompt: prompt,
                            maxTokens: maxTokens,
                            yield: { piece in continuation.yield(piece) }
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Prefill must yield too: a long tool prompt used to monopolize the GPU before
    /// the first token checkpoint. The native-context reservation remains held across
    /// these awaits, so another Qwen request cannot clear the in-flight KV cache.
    private func decodePromptWhileScheduled(
        _ tokens: [llama_token], context: OpaquePointer, jobID: UUID
    ) async throws {
        guard !tokens.isEmpty else { throw LlamaError.decodeFailed }
        let chunk = min(128, Int(Self.batchTokens))
        var batch = llama_batch_init(Int32(min(chunk, tokens.count)), 0, 1)
        defer { llama_batch_free(batch) }
        var index = 0
        while index < tokens.count {
            await ComputeScheduler.shared.checkpoint(jobID)
            try Task.checkCancellation()
            let end = min(index + chunk, tokens.count)
            batch.n_tokens = 0
            for position in index..<end {
                LlamaHelpers.add(tokens[position], position: llama_pos(position),
                    logits: position == tokens.count - 1, to: &batch)
            }
            guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }
            index = end
            prefillChunkObserverForTesting?()
        }
    }

    /// Generation body that already holds the background lane.
    private func completeWhileScheduled(
        jobID: UUID,
        system: String,
        user: String,
        maxTokens: Int
    ) async throws -> LLMCompletion {
        try await loadIfNeeded(schedulerJobID: jobID)
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
        try await decodePromptWhileScheduled(promptTokens, context: context, jobID: jobID)

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
            // Let a queued realtimeASR job take the lane between tokens.
            await ComputeScheduler.shared.checkpoint(jobID)

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

    /// The streaming twin of `completeWhileScheduled`. Keep token sampling in this actor:
    /// the context is shared with notes generation and must never be touched concurrently.
    private func streamWhileScheduled(
        jobID: UUID,
        prompt: String,
        maxTokens: Int,
        yield: @escaping @Sendable (String) -> Void
    ) async throws {
        let firstTokenTrace = LatencyTrace.start(.modelFirstToken)
        try await loadIfNeeded(schedulerJobID: jobID)
        defer {
            lastUse = Date()
            scheduleIdleUnload()
        }
        guard let vocabulary else { throw LlamaError.notLoaded }

        let promptTokens = try LlamaHelpers.tokenize(prompt, vocabulary: vocabulary)
        guard promptTokens.count + maxTokens + Self.contextHeadroom <= contextTokens else {
            throw LlamaError.inputTooLong
        }

        let contextTrace = LatencyTrace.start(.modelContext)
        let hadContext = context != nil
        let context = try ensureContext(promptTokens: promptTokens.count, maxTokens: maxTokens)
        contextTrace.end(note: "qwen35_4b had_context=\(hadContext) tokens=\(contextSize)")
        let prefillTrace = LatencyTrace.start(.modelPrefill)
        llama_memory_clear(llama_get_memory(context), true)
        try await decodePromptWhileScheduled(promptTokens, context: context, jobID: jobID)
        prefillTrace.end(note: "qwen35_4b prompt_tokens=\(promptTokens.count)")

        guard let sampler = makeSampler(vocabulary: vocabulary) else {
            throw LlamaError.samplerFailed
        }
        defer { llama_sampler_free(sampler) }

        var output = ""
        var pending = ""
        var generated = 0
        var reportedFirstToken = false
        var position = llama_pos(promptTokens.count)
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }

        while generated < maxTokens {
            try Task.checkCancellation()
            await ComputeScheduler.shared.checkpoint(jobID)

            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            let piece = LlamaHelpers.piece(token, vocabulary: vocabulary)
            if !reportedFirstToken {
                reportedFirstToken = true
                firstTokenTrace.end(note: "qwen35_4b")
            }
            output += piece
            generated += 1
            pending += piece
            // Hold a suffix that could still become the ChatML terminator. This avoids
            // sending `<|im_end|>` fragments into the spoken-reply bridge.
            let maxHeld = min(Self.turnEnd.count, pending.count)
            let held: Int
            if maxHeld == 0 {
                held = 0
            } else {
                held = (1...maxHeld).reversed().first {
                    String(pending.suffix($0)) == String(Self.turnEnd.prefix($0))
                } ?? 0
            }
            let safeCount = pending.count - held
            if safeCount > 0 {
                yield(String(pending.prefix(safeCount)))
                pending.removeFirst(safeCount)
            }
            if pending == Self.turnEnd {
                pending = ""
                break
            }

            batch.n_tokens = 0
            LlamaHelpers.add(token, position: position, logits: true, to: &batch)
            guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }
            position += 1
        }
        if !pending.isEmpty, !pending.hasPrefix(Self.turnEnd) { yield(pending) }
    }

    /// Acquires the shared background lane for the duration of `body`.
    private func withBackgroundLane<T>(
        _ body: (UUID) async throws -> T
    ) async throws -> T {
        try await withLane(.background, body)
    }

    private func withLane<T>(
        _ workClass: WorkClass,
        _ body: (UUID) async throws -> T
    ) async throws -> T {
        let queueTrace = LatencyTrace.start(.modelQueue)
        guard await reserveNativeContext(for: workClass) else {
            queueTrace.end(note: "qwen35_4b class=\(workClass.rawValue) canceled")
            throw CancellationError()
        }
        defer { releaseNativeContext() }
        try Task.checkCancellation()
        activeOperations += 1
        defer {
            activeOperations -= 1
            if activeOperations == 0 && deferredShutdown { shutdownNow() }
        }
        let jobID = await ComputeScheduler.shared.acquire(workClass)
        queueTrace.end(note: "qwen35_4b class=\(workClass.rawValue)")
        do {
            let result = try await body(jobID)
            await ComputeScheduler.shared.release(jobID)
            return result
        } catch {
            await ComputeScheduler.shared.release(jobID)
            throw error
        }
    }

    /// One llama context and sampler must have one owner even when the actor re-enters
    /// at a scheduler checkpoint. Voice wins the next reservation after current work ends.
    private func reserveNativeContext(for workClass: WorkClass) async -> Bool {
        if !nativeOwner {
            nativeOwner = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    nativeWaiters.append((waiterID, workClass, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelNativeWaiter(waiterID) }
        }
    }

    private func cancelNativeWaiter(_ id: UUID) {
        guard let index = nativeWaiters.firstIndex(where: { $0.id == id }) else { return }
        nativeWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private var queuedNativeWaiters: Int { nativeWaiters.count }

    /// Deterministic reservation probe; no GGUF, permissions, or user history.
    static func conversationSchedulingSelfTest() async -> Bool {
        let runtime = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
        let lease = UUID()
        await runtime.beginConversationSession(lease)
        let cold = await !runtime.isLoaded
        let active = await runtime.activeOperations
        let ownsNativeContext = await runtime.nativeOwner
        let retained = await runtime.conversationLeases.contains(lease)
        await runtime.endConversationSession(lease)
        let released = await runtime.conversationLeases.isEmpty
        guard cold, active == 0, !ownsNativeContext, retained, released else { return false }
        let gate = NotesShutdownProbeGate()
        let order = NativeReservationProbe()
        let current = Task {
            try? await runtime.withLane(.background) { _ in
                await gate.park()
            }
        }
        for _ in 0..<50 {
            if await gate.started { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard await gate.started else {
            current.cancel()
            await gate.release()
            return false
        }
        let background = Task {
            try? await runtime.withLane(.background) { _ in
                await order.append("background")
            }
        }
        let canceled = Task {
            try? await runtime.withLane(.background) { _ in
                await order.append("canceled")
            }
        }
        let voice = Task {
            try? await runtime.withLane(.realtimeAgent) { _ in
                await order.append("voice")
            }
        }
        for _ in 0..<50 {
            if await runtime.queuedNativeWaiters == 3 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let allQueued = await runtime.queuedNativeWaiters == 3
        canceled.cancel()
        _ = await canceled.result
        let canceledRemoved = await runtime.queuedNativeWaiters == 2
        await gate.release()
        _ = await current.result
        _ = await voice.result
        _ = await background.result
        let observed = await order.values
        return allQueued && canceledRemoved && observed == ["voice", "background"]
    }

    private func releaseNativeContext() {
        guard !nativeWaiters.isEmpty else {
            nativeOwner = false
            return
        }
        let next = nativeWaiters.indices.min {
            nativeWaiters[$0].workClass.priority < nativeWaiters[$1].workClass.priority
        }!
        nativeWaiters.remove(at: next).continuation.resume(returning: true)
    }

    /// Frees the weights and the context if nothing has used them for `interval`.
    func unloadIfIdle(after interval: TimeInterval = NotesModelRuntime.idleUnload) {
        guard conversationLeases.isEmpty, activeOperations == 0, model != nil,
              Date().timeIntervalSince(lastUse) >= interval else { return }
        shutdown()
        Log.llm.info("\(self.spec.displayName, privacy: .public) unloaded after idling")
    }

    /// Releases model and context. The process-wide backend belongs to `LlamaBackend`.
    @discardableResult
    func shutdown() -> Bool {
        guard activeOperations == 0 else {
            deferredShutdown = true
            return false
        }
        let wasLoaded = model != nil
        shutdownNow()
        return wasLoaded
    }

    private func shutdownNow() {
        deferredShutdown = false
        idleTask?.cancel()
        idleTask = nil
        if let runtimeGeneration {
            // The pointer teardown is synchronous, but the registry is an actor.
            // The generation check makes this safe if a replacement load starts
            // before this update runs.
            Task {
                _ = await ModelRuntimeManager.shared.markUnloaded(
                    .notes,
                    generation: runtimeGeneration
                )
            }
            self.runtimeGeneration = nil
        }
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

    /// Exercise the actor re-entrancy seam without loading a GGUF. The same
    /// background lane and public shutdown path are used by real generation
    /// and the memory-pressure guardian.
    static func shutdownDeferralSelfTest() async -> Bool {
        let runtime = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
        let gate = NotesShutdownProbeGate()
        let work = Task {
            try? await runtime.withBackgroundLane { _ in await gate.park() }
        }
        for _ in 0..<50 {
            if await gate.started { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let started = await gate.started
        var refused = false
        if started { refused = !(await runtime.shutdown()) }
        let deferred = await runtime.deferredShutdown
        await gate.release()
        _ = await work.result
        let stillDeferred = await runtime.deferredShutdown
        return started && refused && deferred && !stillDeferred
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
        chatMLPrompt(system: system, messages: [.init(role: .user, content: user)])
    }

    static func chatMLPrompt(system: String, messages: [LLMChatMessage]) -> String {
        func safe(_ text: String) -> String {
            text.replacingOccurrences(of: "<|", with: "< |")
                .replacingOccurrences(of: "|>", with: "| >")
        }
        var prompt = "<|im_start|>system\n\(safe(system))<|im_end|>\n"
        for message in messages {
            prompt += "<|im_start|>\(message.role.rawValue)\n"
                + safe(message.content) + "<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        return prompt
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
    ///
    /// When `schedulerJobID` is set (outer `withBackgroundLane`), the load checkpoints
    /// before the heavy mmap so a queued `realtimeASR` job can take the lane first.
    private func loadIfNeeded(schedulerJobID: UUID? = nil) async throws {
        if model != nil, vocabulary != nil { return }
        if let loadTask { return try await loadTask.value }

        let jobID = schedulerJobID
        let task = Task<Void, Error> {
            defer { self.loadTask = nil }
            let loadTrace = LatencyTrace.start(.modelLoad)
            let generation = await ModelRuntimeManager.shared.beginLoading(.notes)
            self.setRuntimeGeneration(generation)
            do {
                try await self.load(schedulerJobID: jobID)
                loadTrace.end(note: "qwen35_4b")
                _ = await ModelRuntimeManager.shared.markReady(
                    .notes,
                    generation: generation
                )
            } catch {
                loadTrace.end(note: "qwen35_4b failed")
                if let llamaError = error as? LlamaError,
                   case .modelMissing = llamaError {
                    // A missing download is an expected configuration state,
                    // not a wedged GPU/runtime. Leave the owner retryable.
                    _ = await ModelRuntimeManager.shared.markUnloaded(
                        .notes,
                        generation: generation
                    )
                } else {
                    _ = await ModelRuntimeManager.shared.markWedged(
                        .notes,
                        generation: generation,
                        error: error.localizedDescription
                    )
                }
                throw error
            }
        }
        loadTask = task
        try await task.value
    }

    private func setRuntimeGeneration(_ generation: UInt64) {
        runtimeGeneration = generation
    }

    private func load(schedulerJobID: UUID? = nil) async throws {
        guard spec.isDownloaded else { throw LlamaError.modelMissing }

        ModelResidencyPolicy.installPressureObserver()

        await LlamaBackend.shared.initialize()
        // Both models are gigabytes and both are resident at once if this waits for nothing.
        // The dictation path is the one with a person waiting on it, so notes generation
        // yields: it loads only once the cleanup pass in flight has released its context.
        //
        // One-directional only. Do not call beginCleanup() here — Qwen cleanup is this
        // same runtime, and closing the cycle deadlocks (AGENTS.md).
        await LlamaBackend.shared.awaitCleanupIdle()

        if let schedulerJobID {
            await ComputeScheduler.shared.checkpoint(schedulerJobID)
        }

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

private actor NotesShutdownProbeGate {
    private(set) var started = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func park() async {
        started = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor NativeReservationProbe {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
