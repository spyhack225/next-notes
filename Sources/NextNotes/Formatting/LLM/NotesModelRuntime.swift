import Foundation
import llama

/// What trying one installed file for real found.
///
/// The difference between `.opensButCannotAnswer` and `.answered` is the whole point of
/// P0-02: a GGUF can open — llama.cpp reads its metadata and vocabulary happily — and
/// then fail to build a context, which is exactly what an MTP draft head does. Opening
/// is not answering, and only `.answered` with a generated token may switch the active
/// model or delete anything.
enum ModelTrialResult: Codable, Sendable, Equatable, Hashable {
    case answered(tokens: Int, seconds: Double)
    case opensButCannotAnswer(String)
    case cannotOpen(String)

    /// The token count when the file actually answered, and nil otherwise.
    ///
    /// The one question the post-download policy, the Models tab and the metal self-test
    /// ask of a trial: a file that opens but produced no token has not answered, and only
    /// an answer may switch the active model or delete anything.
    var answeredTokens: Int? {
        guard case .answered(let tokens, _) = self else { return nil }
        return tokens
    }
}

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
/// - **The model unloads when idle.** Gigabytes of resident weights for a meeting that ended
///   half an hour ago are gigabytes the rest of the Mac could be using.
///
/// Compute residency (S4):
/// - Meeting load/generation use `background`; interactive conversation uses
///   `realtimeAgent`. The one native context is reserved for a whole generation,
///   so a queued voice turn runs next but cannot corrupt an in-flight notes pass.
/// - Before loading, this runtime still waits on `LlamaBackend.awaitCleanupIdle()`.
///   It must **never** call `beginCleanup()` — that closes the gate and deadlocks
///   on-device cleanup (`AppLLMCleanupFormatter`).
/// - Under memory pressure, `ModelResidencyPolicy` may call `shutdown()` before it
///   unloads diarization. Wake/KWS and Parakeet stay warm.
actor NotesModelRuntime {
    /// The shared notes and voice model. Other instances exist only in `--selftest-llm-metal`, which loads a
    /// second, smaller GGUF on the GPU to prove Metal and CPU runtimes coexist.
    ///
    /// A file that fails a real full-weight open is recorded here, through the store the
    /// library and the role store read, so the same file is never selected again on this
    /// build. The record is read-only for a self-test: under the harness the store is a
    /// per-run suite.
    static let shared = NotesModelRuntime(
        spec: NotesModels.spec,
        gpuLayers: NotesModelRuntime.allGPULayers,
        openFailureSink: { spec, reason in
            await MainActor.run {
                ModelOpenFailureStore.shared.record(
                    path: spec.fileURL.path, bytes: spec.expectedBytes, reason: reason)
            }
        }
    )

    /// Offload everything. The built-in model file is a few GB against 16 GB of unified
    /// memory, so there is no layer-splitting decision to make — either Metal is on or it isn't.
    static let allGPULayers: Int32 = 99

    /// The built-in model trains to a much longer window, but a runtime context that size
    /// would reserve more memory than this machine has. 32K is roughly four hours of
    /// speech, which is longer than any meeting the app will be asked to summarise in one pass.
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

    /// The model file currently loaded, or the one the next load will use.
    ///
    /// A `var` since the Models tab can hand the app a different GGUF. It only ever changes
    /// while nothing is loaded: a swap while a generation is in flight would free the
    /// weights its sampler is reading from.
    private(set) var spec: ModelSpec
    /// A model the user chose that has not been switched to yet, because work was running.
    private var pendingSpec: ModelSpec?
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
    /// How many times `load(schedulerJobID:)` has begun since this runtime was created.
    /// The P0-14 self-test proves a prewarm after a failed file attempts no further load.
    private(set) var loadAttemptCount = 0
    /// Where a full-weight open failure is recorded. The shared runtime's is the production
    /// store; a self-test injects its own so the record lands in an isolated suite.
    var openFailureSink: (@Sendable (ModelSpec, String) async -> Void)?

    func setOpenFailureSinkForTesting(_ sink: (@Sendable (ModelSpec, String) async -> Void)?) {
        openFailureSink = sink
    }

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

    /// The warm-up in flight, so two signals share one and a caller can cancel it.
    private var prewarmInFlight = false
    /// Test-only replacement for the questions a prewarm asks. Nil in production.
    private var prewarmProbeForTesting: PrewarmProbeForTesting?

    /// What a prewarm asks, answerable without a model file so a self-test can drive the
    /// contract on a Mac whose model is downloaded and one whose is not, the same way.
    struct PrewarmProbeForTesting: Sendable {
        var isModelAvailable: @Sendable () -> Bool
        var isLocalRoute: @Sendable (Bool) async -> Bool
        var onPrewarm: @Sendable () async -> Void
    }

    func setPrewarmProbeForTesting(_ probe: PrewarmProbeForTesting?) {
        prewarmProbeForTesting = probe
    }

    init(
        spec: ModelSpec,
        gpuLayers: Int32,
        openFailureSink: (@Sendable (ModelSpec, String) async -> Void)? = nil
    ) {
        self.spec = spec
        self.gpuLayers = gpuLayers
        self.openFailureSink = openFailureSink
    }

    var isLoaded: Bool { model != nil }

    // MARK: - Choosing a model

    /// A model the user installed from the library, as a `ModelSpec` this runtime can load.
    ///
    /// `expectedSHA256` is nil rather than the Hub's hash: the download already verified it
    /// byte for byte before the file was allowed into Application Support, and re-hashing
    /// four gigabytes on every load would add a minute to a cold start.
    ///
    /// **`ModelSpec.fileURL` is `ModelSpec.directory` plus the file name**, not the `url`
    /// field — so this is only correct for a model that lives in Application Support's
    /// Models folder. Every installed model does: `ModelLibraryStore` downloads into that
    /// folder and `InstalledModelLibrary` records the same path.
    nonisolated static func spec(for model: InstalledLocalModel) -> ModelSpec {
        ModelSpec(
            displayName: model.displayName,
            fileName: model.fileURL.lastPathComponent,
            url: model.fileURL,
            expectedBytes: model.bytes,
            expectedSHA256: nil
        )
    }

    /// Point the runtime at the model the user picked in the Models tab.
    ///
    /// One model is resident at a time, so this is a swap rather than an addition. It never
    /// frees anything that is in use: while a generation, a queued request or a voice
    /// conversation holds the runtime, the choice is recorded and the swap happens at the
    /// moment the last of them lets go — which is also when `deferredShutdown` runs, and for
    /// the same reason.
    func useInstalledModel(_ model: InstalledLocalModel?) {
        let next = model.map(Self.spec(for:)) ?? NotesModels.spec
        guard next.fileURL != spec.fileURL else {
            pendingSpec = nil
            return
        }
        pendingSpec = next
        if Self.swapMustWait(
            activeOperations: activeOperations,
            loadInFlight: loadTask != nil,
            nativeOwner: nativeOwner,
            nativeWaiters: nativeWaiters.count,
            conversationLeases: conversationLeases.count
        ) {
            // Same gate as a pressure shutdown: the weights go when nothing is reading them.
            deferredShutdown = true
        } else {
            // Idle — including "loaded but idle", which is the ordinary case a second after
            // the last answer. Freeing the weights here is what makes the *next* answer come
            // from the model the person just picked; waiting for a generation that has not
            // started yet would let that generation run on the old one.
            applyPendingSpec()
        }
    }

    /// The awaited form of `useInstalledModel`, for a caller that needs the swap decided
    /// before it asks which model will answer.
    ///
    /// `useInstalledModel` is synchronous inside the actor, so awaiting *this* is what
    /// removes the race the old fire-and-forget `Task` created: by the time it returns,
    /// `(pendingSpec ?? spec).fileURL` is the chosen model's — applied when nothing was
    /// running, recorded as pending behind the work in flight otherwise.
    func select(_ model: InstalledLocalModel?) async {
        useInstalledModel(model)
    }

    /// Whether a model chosen right now has to wait for work already in flight.
    ///
    /// Resident weights alone are **not** a reason to wait — nothing is reading them, and
    /// `applyPendingSpec` frees them before it swaps. Only work that is running, queued,
    /// loading, or held open by a voice session is, because each of those either owns the
    /// native context or is about to.
    static func swapMustWait(
        activeOperations: Int,
        loadInFlight: Bool,
        nativeOwner: Bool,
        nativeWaiters: Int,
        conversationLeases: Int
    ) -> Bool {
        activeOperations > 0 || loadInFlight || nativeOwner || nativeWaiters > 0 || conversationLeases > 0
    }

    /// True while this runtime is on the model that ships with the app.
    var isUsingBuiltInModel: Bool { spec.fileURL == NotesModels.spec.fileURL }

    private var didAdoptSavedSelection = false

    /// The model file the next answer will come from, with the saved choice adopted first.
    ///
    /// Availability is asked before anything is generated, and the answer has to be about the
    /// model the app is actually going to use. Reading `spec` alone reported on the built-in
    /// model until the first load — so a person whose only model came from Hugging Face was
    /// told the built-in one was missing, generation never started, the load that adopts the
    /// saved choice never ran, and the same thing happened on every launch.
    func activeSpec() async -> ModelSpec {
        await adoptSavedSelectionIfNeeded()
        return pendingSpec ?? spec
    }

    /// Reads the saved choice once per process.
    private func adoptSavedSelectionIfNeeded() async {
        guard !didAdoptSavedSelection else { return }
        didAdoptSavedSelection = true
        // Self-tests must not have their model swapped out from under them by whatever the
        // person who owns this Mac happened to choose in the UI — except the two flags that
        // exist to answer a question about the real model this Mac has selected (P0-14b,
        // the Metal probe), which read it and write nothing.
        guard !SelfTest.isRunning || SelfTest.allowsSavedModelSelection else { return }
        let chosen = await MainActor.run { InstalledModelLibrary.shared.activeModel }
        // Records the choice, and applies it straight away unless work is in flight — in
        // which case `load` below applies it, since nothing is loaded by then either.
        useInstalledModel(chosen)
    }

    /// Opens a GGUF, or returns nil. Never traps, never leaks a half-opened model.
    private static func openNative(
        _ candidate: ModelSpec, parameters: llama_model_params
    ) -> (OpaquePointer, OpaquePointer)? {
        guard FileManager.default.fileExists(atPath: candidate.fileURL.path) else { return nil }
        // P0-13's unopenable-model probe counts every full-weight open.
        LlamaLoadProbe.noteFullWeightLoad()
        guard let loaded = llama_model_load_from_file(candidate.fileURL.path, parameters) else { return nil }
        guard let vocabulary = llama_model_get_vocab(loaded) else {
            llama_model_free(loaded)
            return nil
        }
        return (loaded, vocabulary)
    }

    /// Swaps in the chosen model. Only safe with nothing loaded and nothing running.
    private func applyPendingSpec() {
        guard let pendingSpec else { return }
        if model != nil { shutdownNow() }
        spec = pendingSpec
        self.pendingSpec = nil
        Log.llm.info("model library: now using \(self.spec.displayName, privacy: .public)")
    }

    /// Seconds since the model last generated, or nil while it is generating, queued, or
    /// held by a voice conversation. The memory review waits for a minute of this, so a
    /// background review never makes the next voice reply slow.
    var idleSeconds: TimeInterval? {
        guard activeOperations == 0, conversationLeases.isEmpty, nativeWaiters.isEmpty, !nativeOwner else {
            return nil
        }
        return Date().timeIntervalSince(lastUse)
    }

    /// Loaded, loading, generating, queued or leased. The embedding runtime never loads
    /// while this is true, so the notes model and the embedder are never resident together.
    var isResidentOrBusy: Bool {
        model != nil || loadTask != nil || activeOperations > 0 || nativeOwner || !nativeWaiters.isEmpty
            || !conversationLeases.isEmpty
    }

    /// The usable prompt budget, once the model is loaded and its trained context is known.
    var contextTokens: Int {
        trainedContext > 0 ? min(trainedContext, Self.maxContextTokens) : Self.maxContextTokens
    }

    /// The lane a prewarm holds.
    ///
    /// Voice asks as a voice turn, but the warm-up must never hold the class the
    /// live frontend acquires: equal priority does not preempt, so a cold 4B load at
    /// `.realtimeAgent` queues the next spoken turn behind 11–25 s of weights and
    /// prefill. A prewarm at `.background` is parked at the load's checkpoint the
    /// moment the frontend asks for `.realtimeAgent`.
    ///
    /// `voice` stays in the signature for the log line; both routes warm at
    /// `.background`.
    nonisolated static func prewarmWorkClass(voice: Bool) -> WorkClass {
        .background
    }

    /// Warm the weights ahead of an agent turn, without generating and without UI.
    ///
    /// Called when someone signals they are about to use the agent — the Agent pane opens,
    /// a wake word or the shortcut opens a voice session, a voice turn routes to work —
    /// and **never at launch**. The weights are gigabytes and this runtime releases them
    /// after ten quiet minutes (`idleUnload`), so a launch-time load would hold them all day
    /// for a feature used in bursts, and would usually have let them go again before the
    /// first turn arrived. Prewarming on intent spends the same seconds while the person is
    /// still typing or speaking, and the ten-minute timer reclaims them when the signal
    /// never becomes a turn.
    ///
    /// A no-op when the weights are resident or a load is already in flight; when the
    /// agent's own routing would not use this runtime — voice always prefers the built-in
    /// model whatever the assistant role says, a typed turn asks the role, and a person on
    /// OpenRouter or Apple's model never pays for a local load; and when the model file is
    /// not on this Mac. Fire-and-forget: the caller gets the task and may cancel it, and a
    /// turn that arrives meanwhile shares the same `loadTask` rather than starting a second.
    @discardableResult
    nonisolated func prewarm(voice: Bool = false) -> Task<Void, Never> {
        Task { await self.prewarmIfNeeded(voice: voice) }
    }

    private func prewarmIfNeeded(voice: Bool) async {
        // A self-test must never pull gigabytes into memory as a side effect of driving
        // the UI or a voice session; the probe is how the contract is exercised instead.
        guard !SelfTest.isRunning || prewarmProbeForTesting != nil else { return }
        guard model == nil, loadTask == nil, !prewarmInFlight else { return }
        prewarmInFlight = true
        defer { prewarmInFlight = false }

        let available: Bool
        if let probe = prewarmProbeForTesting {
            available = probe.isModelAvailable()
        } else {
            available = await activeSpec().isDownloaded
        }
        guard available else { return }

        let isLocal: Bool
        if let probe = prewarmProbeForTesting {
            isLocal = await probe.isLocalRoute(voice)
        } else {
            isLocal = await AgentModelRouting.resolvesToLocalModel(voice: voice)
        }
        guard isLocal else { return }

        // The actor re-entered across the awaits above: a real turn may have loaded or
        // started loading the weights in that window, and a cancelled caller no longer
        // wants them.
        guard !Task.isCancelled, model == nil, loadTask == nil else { return }

        if let probe = prewarmProbeForTesting {
            await probe.onPrewarm()
            return
        }
        let workClass = Self.prewarmWorkClass(voice: voice)
        let route = voice ? "voice" : "typed"
        Log.llm.info(
            "model prewarm lane=\(workClass.rawValue, privacy: .public) route=\(route, privacy: .public)")
        do {
            try await prepareForConversation(workClass: workClass)
        } catch {
            Log.llm.info("model prewarm skipped: \(error.localizedDescription, privacy: .public)")
        }
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

    /// Try one installed file for real and report what it did.
    ///
    /// Opening is not answering. A GGUF can open — llama.cpp reads its metadata and
    /// vocabulary happily — and then fail to build a context, which is exactly what an MTP
    /// draft head does. So the trial loads **this exact file**, builds a context, decodes a
    /// fixed prompt and samples up to eight tokens; only a generated token becomes
    /// `.answered(tokens:seconds:)`. A context or decode failure is
    /// `.opensButCannotAnswer`, and a file that will not open at all is `.cannotOpen`.
    ///
    /// It never touches `InstalledModelLibrary` — the caller records the verdict on the row
    /// — and it restores the previous spec and frees the weights before it returns, so a
    /// trial on a scratch file cannot leave a model resident. While it holds the native
    /// context, `useInstalledModel` records a model choice as pending rather than applying
    /// it, which is what keeps a trial from racing the switch it exists to guard.
    func trial(_ model: InstalledLocalModel) async -> ModelTrialResult {
        // A voice session's lease is a deliberate hold on the resident weights, and a
        // session can last minutes. The trial must not free them out from under it, so the
        // caller is told to retry rather than made to wait.
        guard conversationLeases.isEmpty else { return .cannotOpen("busy") }
        do {
            return try await withLane(.background) { jobID in
                await self.trialWhileScheduled(jobID: jobID, installed: model)
            }
        } catch is CancellationError {
            return .cannotOpen("busy")
        } catch {
            return .opensButCannotAnswer(error.localizedDescription)
        }
    }

    /// The body of `trial`, already holding the background lane and the native context.
    private func trialWhileScheduled(
        jobID: UUID, installed: InstalledLocalModel
    ) async -> ModelTrialResult {
        // The actor re-entered while the lane was being acquired; a session that opened in
        // that window still owns the weights.
        guard conversationLeases.isEmpty else { return .cannotOpen("busy") }

        let candidate = Self.spec(for: installed)
        let previous = spec
        let wasDeferred = deferredShutdown
        let pendingBefore = pendingSpec
        defer {
            // A model chosen while the trial held the lane — or one already waiting for
            // it — is a pending switch, not something this trial may drop. Put the
            // deferral back so `withLane` applies it the moment the lane is free, and
            // leave `spec` where it was.
            let deferred = wasDeferred || deferredShutdown
            shutdownNow()
            spec = previous
            if pendingSpec == nil { pendingSpec = pendingBefore }
            deferredShutdown = deferred
        }
        shutdownNow()
        spec = candidate
        pendingSpec = nil

        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = gpuLayers
        parameters.load_mode = LLAMA_LOAD_MODE_MMAP
        parameters.use_extra_bufts = false
        await LlamaBackend.shared.initialize()
        guard let (loaded, loadedVocabulary) = Self.openNative(candidate, parameters: parameters) else {
            return .cannotOpen("the file would not open")
        }
        model = loaded
        vocabulary = loadedVocabulary
        trainedContext = Int(llama_model_n_ctx_train(loaded))

        do {
            return try await decodeTrialToken(jobID: jobID, vocabulary: loadedVocabulary)
        } catch {
            return .opensButCannotAnswer(error.localizedDescription)
        }
    }

    /// Up to this many sampled tokens. Enough that a model which opens but cannot answer
    /// (an MTP head, a context llama.cpp cannot run) fails at the context or the decode,
    /// few enough that a trial on a real model costs a second.
    private static let trialMaxTokens = 8

    /// Builds a context, decodes the fixed trial prompt and samples until EOG or the cap.
    private func decodeTrialToken(
        jobID: UUID, vocabulary: OpaquePointer
    ) async throws -> ModelTrialResult {
        // The system line is deliberately neutral. Measured on this Mac: S1-mini — a
        // normalizer, not an assistant — ends its turn on the first token when the system
        // line itself reads as the instruction ("Answer with the single word OK."), and a
        // trial that reports a working file as unable to answer is the bug this guards.
        // "You are a helpful assistant." answers on S1-mini (1 token) and on Qwen3 (1).
        let prompt = Self.chatMLPrompt(
            system: "You are a helpful assistant.",
            user: "Reply with the single word OK.")
        let tokens = try LlamaHelpers.tokenize(prompt, vocabulary: vocabulary)
        let context = try ensureContext(promptTokens: tokens.count, maxTokens: Self.trialMaxTokens)
        llama_memory_clear(llama_get_memory(context), true)
        try await decodePromptWhileScheduled(tokens, context: context, jobID: jobID)

        guard let sampler = try makeSampler(vocabulary: vocabulary, grammar: nil) else {
            throw LlamaError.samplerFailed
        }
        defer { llama_sampler_free(sampler) }

        let began = Date()
        var generated = 0
        var position = llama_pos(tokens.count)
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }
        while generated < Self.trialMaxTokens {
            try Task.checkCancellation()
            await ComputeScheduler.shared.checkpoint(jobID)
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            generated += 1
            batch.n_tokens = 0
            LlamaHelpers.add(token, position: position, logits: true, to: &batch)
            guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }
            position += 1
        }
        let seconds = Date().timeIntervalSince(began)
        guard generated > 0 else {
            return .opensButCannotAnswer("the model ended its turn without a token")
        }
        return .answered(tokens: generated, seconds: seconds)
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
        try await complete(system: system, user: user, maxTokens: maxTokens, grammar: nil)
    }

    /// One ChatML turn whose output is constrained to `grammar`: every sampled token must keep
    /// the text a prefix of a sentence the grammar accepts, and end-of-generation is only
    /// allowed once it is a whole one. A grammar llama.cpp cannot parse throws
    /// `LlamaError.grammarInvalid` before anything is decoded.
    func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar?) async throws -> LLMCompletion {
        try await withBackgroundLane { jobID in
            try await completeWhileScheduled(
                jobID: jobID, system: system, user: user, maxTokens: maxTokens, grammar: grammar)
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
    /// these awaits, so another request cannot clear the in-flight KV cache.
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
        maxTokens: Int,
        grammar: GBNFGrammar? = nil
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
        // Built before the prefill, so a grammar the native parser refuses costs nothing.
        guard let sampler = try makeSampler(vocabulary: vocabulary, grammar: grammar) else {
            throw LlamaError.samplerFailed
        }
        defer { llama_sampler_free(sampler) }

        try await decodePromptWhileScheduled(promptTokens, context: context, jobID: jobID)

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
            // Some GGUF conversions emit the turn terminator as text rather than as an
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
        contextTrace.end(note: "app_llm had_context=\(hadContext) tokens=\(contextSize)")
        let prefillTrace = LatencyTrace.start(.modelPrefill)
        llama_memory_clear(llama_get_memory(context), true)
        try await decodePromptWhileScheduled(promptTokens, context: context, jobID: jobID)
        prefillTrace.end(note: "app_llm prompt_tokens=\(promptTokens.count)")

        guard let sampler = try makeSampler(vocabulary: vocabulary, grammar: nil) else {
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
                firstTokenTrace.end(note: "app_llm")
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
            queueTrace.end(note: "app_llm class=\(workClass.rawValue) canceled")
            throw CancellationError()
        }
        defer { releaseNativeContext() }
        try Task.checkCancellation()
        activeOperations += 1
        defer {
            activeOperations -= 1
            lastUse = Date()
            if activeOperations == 0 && deferredShutdown {
                shutdownNow()
                // A model chosen while this operation was running swaps in here, now that
                // nothing is reading the weights that were just freed.
                applyPendingSpec()
            }
        }
        let jobID = await ComputeScheduler.shared.acquireCancellable(workClass)
        guard let jobID else {
            queueTrace.end(note: "app_llm class=\(workClass.rawValue) canceled")
            throw CancellationError()
        }
        queueTrace.end(note: "app_llm class=\(workClass.rawValue)")
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
        guard allQueued && canceledRemoved && observed == ["voice", "background"] else { return false }
        var failures: [String] = []

        // Case 1 — the prewarm lane does not block the frontend. A prewarm held at
        // `prewarmWorkClass(voice: true)` must not delay an acquire of the class the
        // live frontend takes (`.realtimeAgent`): the prewarm has to be preemptible.
        let prewarmClass = NotesModelRuntime.prewarmWorkClass(voice: true)
        let holder = await ComputeScheduler.shared.acquire(prewarmClass)
        let frontendWaiter = Task { await ComputeScheduler.shared.acquire(.realtimeAgent) }
        let acquired = await withBoundedWait(.milliseconds(200)) { await frontendWaiter.value }
        await ComputeScheduler.shared.release(holder)
        let frontendJob = await frontendWaiter.value
        await ComputeScheduler.shared.release(frontendJob)
        if acquired == nil {
            failures.append(
                "prewarm lane: a prewarm at \(prewarmClass.rawValue) blocked a realtimeAgent acquire past 200 ms")
        }

        // Case 2 — a cancelled acquire leaves the queue. The waiter returns nil and
        // stops occupying a place behind the lane holder.
        let lane = await ComputeScheduler.shared.acquire(.realtimeAgent)
        let cancelledWaiter = Task { await ComputeScheduler.shared.acquireCancellable(.background) }
        try? await Task.sleep(for: .milliseconds(50))
        cancelledWaiter.cancel()
        let cancellationResult = await withBoundedWait(.milliseconds(100)) { await cancelledWaiter.value }
        let backgroundStillQueued = await ComputeScheduler.shared.isBusy(.background)
        await ComputeScheduler.shared.release(lane)
        if let leaked = await cancelledWaiter.value {
            await ComputeScheduler.shared.release(leaked)
        }
        if cancellationResult == nil {
            failures.append("cancellable acquire: a cancelled waiter did not return within 100 ms")
        } else if cancellationResult! != nil {
            failures.append("cancellable acquire: a cancelled waiter returned a job id instead of nil")
        }
        if backgroundStillQueued {
            failures.append("cancellable acquire: a cancelled waiter stayed in the scheduler queue")
        }

        // Case 3 — a drain-barrier timeout detaches. The first generation stays open
        // past the 2 s barrier, so the next committed turn must continue on a fresh
        // session instead of failing with `FrontendError.unavailable`.
        let frontend = LocalVoiceFrontend.shared
        let generatorCalls = VoiceDrainProbeCounter()
        await frontend.setGenerationForTesting { _, _, _ in
            if generatorCalls.next() == 1 {
                return AsyncThrowingStream { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        continuation.finish()
                    }
                }
            }
            return AsyncThrowingStream { continuation in
                continuation.yield("Second.")
                continuation.finish()
            }
        }
        let system = "Voice scheduling probe."
        let firstRequest: [LLMChatMessage] = [
            .init(role: .user, content: "Latest user speech:\nFirst turn.")
        ]
        let secondRequest: [LLMChatMessage] = [
            .init(role: .user, content: "Latest user speech:\nSecond turn.")
        ]
        // Turn 1: a speculation whose producer stays open past the barrier.
        await frontend.speculate(system: system, messages: firstRequest, maxTokens: 64, revision: 1)
        var speculationStarted = false
        for _ in 0..<100 {
            if generatorCalls.count >= 1 { speculationStarted = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !speculationStarted {
            failures.append("drain detach: the probe speculation never reached the generator")
        }
        // Turn 2: commit the same request, which records the drain barrier. The
        // returned buffer is consumed by a task nothing cancels, so the old
        // producer is not torn down before the next turn's drain.
        let committed = await frontend.stream(
            system: system, messages: firstRequest, maxTokens: 64, commitRevision: 2)
        Task {
            for try await _ in committed {}
        }
        try? await Task.sleep(for: .milliseconds(100))
        // Turn 3: the next committed turn must detach from the stuck producer.
        let next = await frontend.stream(
            system: system, messages: secondRequest, maxTokens: 64, commitRevision: 3)
        let outcome = await withBoundedWait(.milliseconds(2_500)) { () -> VoiceDrainOutcome in
            var text = ""
            do {
                for try await delta in next { text += delta }
                return VoiceDrainOutcome(text: text, error: nil)
            } catch {
                return VoiceDrainOutcome(text: text, error: error.localizedDescription)
            }
        }
        await frontend.setGenerationForTesting(nil)
        if let outcome {
            if let error = outcome.error {
                failures.append("drain detach: the next turn failed instead of detaching: \(error)")
            } else if outcome.text != "Second." {
                failures.append(
                    "drain detach: the next turn answered '\(outcome.text)' instead of detaching to a fresh session")
            }
        } else {
            failures.append("drain detach: the next turn did not answer within 2.5 s")
        }

        for failure in failures {
            await MainActor.run { SelfTest.diagnostic("VOICE_SCHEDULING_WRONG: \(failure)") }
        }
        if !failures.isEmpty { return false }
        return await prewarmSelfTest()
    }

    /// The prewarm contract, driven through the entry point with no GGUF: each gate
    /// suppresses the warm-up, and two signals while one is in flight share it. The probe
    /// stands in for the file and the routing question, so this is the same test on a Mac
    /// with a model downloaded and one without. Runs under `--selftest-voice-scheduling`.
    static func prewarmSelfTest() async -> Bool {
        let runtime = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
        var failures: [String] = []

        // 1. A role on another model — OpenRouter, Apple's, a local server — never warms
        //    this runtime, whatever the file situation is.
        let blocked = PrewarmProbeCounter()
        await runtime.setPrewarmProbeForTesting(PrewarmProbeForTesting(
            isModelAvailable: { true },
            isLocalRoute: { _ in false },
            onPrewarm: { await blocked.increment() }
        ))
        await runtime.prewarm().value
        if await blocked.count != 0 {
            failures.append("a non-local assistant role warmed the local model")
        }

        // 2. A model that is not on this Mac is not a load to start.
        let missing = PrewarmProbeCounter()
        await runtime.setPrewarmProbeForTesting(PrewarmProbeForTesting(
            isModelAvailable: { false },
            isLocalRoute: { _ in true },
            onPrewarm: { await missing.increment() }
        ))
        await runtime.prewarm().value
        if await missing.count != 0 {
            failures.append("a missing model file started a prewarm")
        }

        // 3. A second signal while the first warm-up is still running shares it. The
        //    parked probe holds the first one open; the second must not start its own.
        let gate = NotesShutdownProbeGate()
        let coalesced = PrewarmProbeCounter()
        await runtime.setPrewarmProbeForTesting(PrewarmProbeForTesting(
            isModelAvailable: { true },
            isLocalRoute: { _ in true },
            onPrewarm: {
                await coalesced.increment()
                await gate.park()
            }
        ))
        let first = runtime.prewarm()
        for _ in 0..<100 {
            if await gate.started { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard await gate.started else {
            await runtime.setPrewarmProbeForTesting(nil)
            return false
        }
        let second = runtime.prewarm()
        _ = await second.value
        await gate.release()
        _ = await first.value
        let starts = await coalesced.count
        if starts != 1 {
            failures.append("concurrent prewarms started \(starts) warm-ups")
        }

        await runtime.setPrewarmProbeForTesting(nil)
        let wiring = await prewarmWiringSelfTest()
        if !wiring {
            failures.append("opening a voice session did not ask the entry point for a warm-up")
        }
        return failures.isEmpty
    }

    /// The activation path's half of the contract: opening a voice session asks the entry
    /// point for a warm-up. The typed half is the same one-line call from the Agent pane and
    /// has no seam a headless test can drive; this at least pins that the seam a person
    /// reaches first — the shortcut or the wake word — is wired, not just the runtime.
    @MainActor
    static func prewarmWiringSelfTest() async -> Bool {
        let probe = PrewarmProbeCounter()
        await NotesModelRuntime.shared.setPrewarmProbeForTesting(PrewarmProbeForTesting(
            isModelAvailable: { true },
            isLocalRoute: { _ in true },
            onPrewarm: { await probe.increment() }
        ))
        ActivationController.shared.beginAgent(source: "selftest-prewarm")
        var asked = false
        for _ in 0..<100 {
            if await probe.count > 0 { asked = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await NotesModelRuntime.shared.setPrewarmProbeForTesting(nil)
        // `beginAgent` opens the capture session on its own task; close the one it opened
        // before returning so this test leaves no session behind.
        for _ in 0..<100 {
            if AgentCaptureController.shared.isSessionActive { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await AgentCaptureController.shared.endSession(source: .done)
        return asked
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

    /// The Models tab can hand this runtime a different GGUF at any moment.
    ///
    /// Two things have to hold and neither needs a model file: while the runtime is idle the
    /// swap happens immediately, and while a generation holds the lane it does not — the
    /// choice is recorded and applied the instant the work lets go. A swap that landed
    /// mid-generation would free the weights the sampler is reading from, which is a crash
    /// rather than a wrong answer.
    static func modelSwapSelfTest() async -> Bool {
        let runtime = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
        // The same folder every installed model lives in. No file is created: the swap is a
        // bookkeeping change, and the load that would open it never runs here.
        let probeName = "nextnotes-swap-probe-\(UUID().uuidString).gguf"
        let chosen = InstalledLocalModel(
            id: "probe/model",
            displayName: "Probe",
            fileURL: ModelSpec.directory.appendingPathComponent(probeName),
            parameterBillions: 4,
            quantization: "Q4_K_M",
            bytes: 1,
            isBuiltIn: false
        )

        // Idle: immediate.
        await runtime.useInstalledModel(chosen)
        guard await runtime.spec.fileName == probeName else { return false }
        await runtime.useInstalledModel(nil)
        guard await runtime.isUsingBuiltInModel else { return false }

        // Busy: deferred until the lane is free.
        let gate = NotesShutdownProbeGate()
        let work = Task {
            try? await runtime.withLane(.background) { _ in await gate.park() }
        }
        for _ in 0..<50 {
            if await gate.started { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard await gate.started else {
            work.cancel()
            await gate.release()
            return false
        }
        await runtime.useInstalledModel(chosen)
        let heldOff = await runtime.isUsingBuiltInModel
        await gate.release()
        _ = await work.result
        let swappedAfterwards = await runtime.spec.fileName == probeName
        return heldOff && swappedAfterwards
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
    /// The on-device model is a hybrid reasoning model: left to itself it opens `<think>` and
    /// spends hundreds of tokens deliberating before writing anything. Notes are an extraction
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
    ///
    /// A grammar goes first in the chain: it masks every token that would leave the grammar,
    /// and the samplers after it choose among what is left. The chain accepts each sampled
    /// token into the grammar's state, so no separate bookkeeping is needed here.
    private func makeSampler(
        vocabulary: OpaquePointer, grammar: GBNFGrammar?
    ) throws -> UnsafeMutablePointer<llama_sampler>? {
        var parameters = llama_sampler_chain_default_params()
        parameters.no_perf = true
        guard let chain = llama_sampler_chain_init(parameters) else { return nil }
        if let grammar {
            guard let constrained = llama_sampler_init_grammar(vocabulary, grammar.text, grammar.root) else {
                llama_sampler_free(chain)
                throw LlamaError.grammarInvalid
            }
            llama_sampler_chain_add(chain, constrained)
        }
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
    /// gate loads a second full copy of the weights and leaks the first, which is exactly
    /// the swapping the gate exists to prevent.
    ///
    /// When `schedulerJobID` is set (outer `withBackgroundLane`), the load checkpoints
    /// before the heavy mmap so a queued `realtimeASR` job can take the lane first.
    private func loadIfNeeded(schedulerJobID: UUID? = nil) async throws {
        if model != nil, vocabulary != nil { return }
        if let loadTask { return try await loadTask.value }
        // Nothing is loaded and nothing is loading, which is the only safe moment to adopt a
        // model the user chose while the previous one was busy.
        applyPendingSpec()

        let jobID = schedulerJobID
        let task = Task<Void, Error> {
            defer { self.loadTask = nil }
            let loadTrace = LatencyTrace.start(.modelLoad)
            let generation = await ModelRuntimeManager.shared.beginLoading(.notes)
            self.setRuntimeGeneration(generation)
            do {
                try await self.load(schedulerJobID: jobID)
                loadTrace.end(note: "app_llm")
                _ = await ModelRuntimeManager.shared.markReady(
                    .notes,
                    generation: generation
                )
            } catch {
                loadTrace.end(note: "app_llm failed")
                // A missing download and a file this build cannot open are expected
                // configuration states, not a wedged GPU/runtime. Leave the owner
                // retryable, so a later turn can resolve to another provider.
                let retryable: Bool
                if let llamaError = error as? LlamaError {
                    switch llamaError {
                    case .modelMissing, .modelUnopenable: retryable = true
                    default: retryable = false
                    }
                } else {
                    retryable = false
                }
                if retryable {
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
        loadAttemptCount += 1
        // The first load of the process adopts whatever the user picked last time, unless
        // something read `activeSpec` earlier and adopted it already.
        await adoptSavedSelectionIfNeeded()
        // Nothing is loaded at this point — this is the load — so a choice that was recorded
        // while a generation held the lane can be taken up now, before the file is opened.
        if model == nil { applyPendingSpec() }

        // A chosen model whose file has gone — deleted in Finder, or on a volume that is no
        // longer mounted — is a configuration problem, not a failure. The runtime goes back
        // to the built-in spec and reports `.modelMissing`; the call path names what will
        // answer, because the runtime never touches the library and never opens a
        // replacement file on its own.
        if !spec.isDownloaded {
            // The built-in model simply hasn't been downloaded yet — the caller handles that.
            guard !isUsingBuiltInModel else { throw LlamaError.modelMissing }
            spec = NotesModels.spec
            pendingSpec = nil
            throw LlamaError.modelMissing
        }

        ModelResidencyPolicy.installPressureObserver()

        await LlamaBackend.shared.initialize()
        // Both models are gigabytes and both are resident at once if this waits for nothing.
        // The dictation path is the one with a person waiting on it, so notes generation
        // yields: it loads only once the cleanup pass in flight has released its context.
        //
        // One-directional only. Do not call beginCleanup() here — on-device cleanup is this
        // same runtime, and closing the cycle deadlocks (AGENTS.md).
        await LlamaBackend.shared.awaitCleanupIdle()

        if let schedulerJobID {
            await ComputeScheduler.shared.checkpoint(schedulerJobID)
        }

        // Peak is never the sum: the embedder and the notes model are never loaded
        // together. `loadTask` is already set, so the embedder refuses to load again
        // until this model is gone.
        await EmbeddingRuntime.shared.stopNow()

        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = gpuLayers
        // mmap rather than a read into anonymous memory: the weights stay file-backed, so
        // the kernel can evict them under pressure instead of the app being killed.
        modelParameters.load_mode = LLAMA_LOAD_MODE_MMAP
        // Repacking quantized weights doubles peak memory during load, which is exactly the
        // moment this process is least able to afford it.
        modelParameters.use_extra_bufts = false

        // A GGUF built for an architecture this llama.cpp does not implement returns null
        // here rather than crashing — but only because the load is guarded. The user chose
        // this file from a list of thousands, so "unsupported" is an ordinary outcome, and
        // the app has to keep working through it rather than refusing to write notes.
        //
        // The failure is remembered so no resolution path selects this file again on this
        // build, and the runtime returns to the built-in spec **without opening it**: a
        // silent replacement file is how the notice ended up claiming Gemma on a Mac where
        // Gemma had never been downloaded.
        guard let (loadedModel, loadedVocabulary) = Self.openNative(spec, parameters: modelParameters) else {
            let failed = spec
            if !isUsingBuiltInModel {
                await openFailureSink?(failed, "open failed")
                spec = NotesModels.spec
                pendingSpec = nil
                throw LlamaError.modelUnopenable(failed.displayName)
            }
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

private actor PrewarmProbeCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// The result of one `--selftest-voice-scheduling` drain probe: the text a committed
/// turn produced, or the error it threw, whichever came first.
private struct VoiceDrainOutcome: Sendable {
    let text: String
    let error: String?
}

/// Counts `setGenerationForTesting` calls. The generator is synchronous, so the count
/// cannot live in an actor.
private final class VoiceDrainProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int { lock.withLock { value } }
}
