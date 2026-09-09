import Foundation
import llama

/// S1-mini by Superwhisper, a local 0.6B post-ASR text normalizer.
///
/// The GGUF is downloaded once into Application Support and inference runs in-process through
/// llama.cpp on the CPU. The model's control prompt is intentionally exact: S1-mini was trained on
/// this protocol and its authors warn that rewording it produces degraded or garbled output.
struct S1MiniFormatter: TextFormatter {
    private let preferences: CleanupPreferences
    private let fallback = RuleBasedFormatter()

    init(preferences: CleanupPreferences) {
        self.preferences = preferences
    }

    func format(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard S1MiniModels.isDownloaded else {
            Log.speech.info("S1-mini model unavailable — using rule-based cleanup")
            return await fallback.format(trimmed)
        }

        do {
            let result = try await S1MiniRuntime.shared.normalize(
                trimmed,
                preferences: preferences
            )
            // Empty is a documented, valid result for filler-only/noise-only transcripts.
            if result.isEmpty, Self.hasSubstantiveContent(trimmed) {
                Log.speech.info("S1-mini returned empty substantive text — using rule-based cleanup")
                return await fallback.format(trimmed)
            }
            return result
        } catch {
            Log.speech.error("S1-mini cleanup failed: \(error.localizedDescription, privacy: .public)")
            return await fallback.format(trimmed)
        }
    }

    private static func hasSubstantiveContent(_ text: String) -> Bool {
        let fillers: Set<String> = ["um", "uh", "erm", "hmm", "like", "okay", "ok", "you", "know"]
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { !fillers.contains(String($0)) }
    }
}

enum S1MiniModels {
    static let spec = ModelSpec(
        displayName: "S1-mini",
        fileName: "s1-mini-q4_k_m.gguf",
        url: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf")!,
        expectedBytes: 484_219_808,
        expectedSHA256: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
    )

    static var fileURL: URL { spec.fileURL }
    static var isDownloaded: Bool { spec.isDownloaded }

    static func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await ModelDownloader.download(spec, progress: progress)
    }
}

/// Serializes access to llama.cpp's context and keeps the model resident between dictations.
actor S1MiniRuntime {
    static let shared = S1MiniRuntime()

    private static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocabulary: OpaquePointer?

    /// Loads the runtime without generating text so selecting S1-mini never makes the next
    /// dictation pay the model's cold-start cost.
    func prepare() async throws {
        try await loadIfNeeded()
    }

    /// Runs one cleanup pass, announcing it to `LlamaBackend` for the duration.
    ///
    /// The announcement is what keeps the notes model from loading its 2.7 GB of weights
    /// into the middle of a dictation the user is waiting on. Written out rather than as a
    /// `defer`, because `defer` can't await and the release must happen before the caller
    /// resumes — a `Task { }` in a `defer` would let the notes model start loading first.
    func normalize(_ transcript: String, preferences: CleanupPreferences) async throws -> String {
        await LlamaBackend.shared.beginCleanup()
        do {
            let result = try await performNormalize(transcript, preferences: preferences)
            await LlamaBackend.shared.endCleanup()
            return result
        } catch {
            await LlamaBackend.shared.endCleanup()
            throw error
        }
    }

    private func performNormalize(
        _ transcript: String,
        preferences: CleanupPreferences
    ) async throws -> String {
        try await loadIfNeeded()
        guard let context, let vocabulary else { throw RuntimeError.notLoaded }

        let structure = preferences.formatsLists ? "lists" : "prose"
        let control = "[Styling: \(preferences.tone.s1MiniValue)] [Structure: \(structure)] [Context: \(preferences.context.rawValue)]"
        let prompt = """
            <|im_start|>system
            \(Self.systemPrompt)<|im_end|>
            <|im_start|>user
            \(control)
            \(transcript)<|im_end|>
            <|im_start|>assistant
            <think>

            </think>

            """

        let promptTokens: [llama_token]
        do {
            promptTokens = try LlamaHelpers.tokenize(prompt, vocabulary: vocabulary)
        } catch {
            throw RuntimeError.tokenizationFailed
        }
        guard promptTokens.count < 1_600 else { throw RuntimeError.inputTooLong }
        llama_memory_clear(llama_get_memory(context), true)

        var promptBatch = llama_batch_init(Int32(max(1, promptTokens.count)), 0, 1)
        defer { llama_batch_free(promptBatch) }
        for (index, token) in promptTokens.enumerated() {
            LlamaHelpers.add(token, position: Int32(index), logits: false, to: &promptBatch)
        }
        promptBatch.logits[Int(promptBatch.n_tokens) - 1] = 1
        guard llama_decode(context, promptBatch) == 0 else { throw RuntimeError.decodeFailed }

        guard let sampler = llama_sampler_init_greedy() else { throw RuntimeError.samplerFailed }
        defer { llama_sampler_free(sampler) }

        var output = ""
        var position = Int32(promptTokens.count)
        let maximumResponseTokens = 1_200
        for _ in 0..<maximumResponseTokens {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            output += LlamaHelpers.piece(token, vocabulary: vocabulary)

            var tokenBatch = llama_batch_init(1, 0, 1)
            LlamaHelpers.add(token, position: position, logits: true, to: &tokenBatch)
            let result = llama_decode(context, tokenBatch)
            llama_batch_free(tokenBatch)
            guard result == 0 else { throw RuntimeError.decodeFailed }
            position += 1
        }

        return output
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Releases the model and context. The process-wide backend belongs to `LlamaBackend`
    /// and is torn down after every runtime has released its objects.
    func shutdown() {
        if let context {
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
            vocabulary = nil
        }
    }

    private func loadIfNeeded() async throws {
        if model != nil, context != nil, vocabulary != nil { return }
        guard S1MiniModels.isDownloaded else { throw RuntimeError.modelMissing }

        await LlamaBackend.shared.initialize()

        var modelParameters = llama_model_default_params()
        // S1-mini's own model card targets laptop CPU inference, and at 0.6B it is fast
        // enough there. Keeping it off the GPU also means dictation cleanup never competes
        // with the notes model for Metal while a meeting is being summarized.
        modelParameters.n_gpu_layers = 0
        // Repacking Q4 weights doubles first-load memory and can take minutes under load.
        // The 0.6B model is fast enough without that one-time transformation.
        modelParameters.use_extra_bufts = false
        guard let loadedModel = llama_model_load_from_file(S1MiniModels.fileURL.path, modelParameters) else {
            throw RuntimeError.modelLoadFailed
        }

        var contextParameters = llama_context_default_params()
        // Dictation cleanup is short. An 8K context allocated nearly 900 MiB of KV cache
        // for this architecture; 2K leaves ample room while keeping the resident footprint
        // appropriate for an always-on utility.
        contextParameters.n_ctx = 2_048
        contextParameters.n_batch = 512
        let threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        contextParameters.n_threads = Int32(threads)
        contextParameters.n_threads_batch = Int32(threads)

        guard let loadedContext = llama_init_from_model(loadedModel, contextParameters) else {
            llama_model_free(loadedModel)
            throw RuntimeError.contextLoadFailed
        }
        guard let loadedVocabulary = llama_model_get_vocab(loadedModel) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            throw RuntimeError.modelLoadFailed
        }

        model = loadedModel
        context = loadedContext
        vocabulary = loadedVocabulary
        Log.speech.info("S1-mini by Superwhisper loaded for local cleanup")
    }

    private enum RuntimeError: LocalizedError {
        case modelMissing, modelLoadFailed, contextLoadFailed, notLoaded
        case tokenizationFailed, inputTooLong, decodeFailed, samplerFailed

        var errorDescription: String? {
            switch self {
            case .modelMissing: "S1-mini is not downloaded."
            case .modelLoadFailed: "S1-mini could not be loaded."
            case .contextLoadFailed: "S1-mini inference could not start."
            case .notLoaded: "S1-mini is unavailable."
            case .tokenizationFailed: "S1-mini could not read the transcript."
            case .inputTooLong: "The transcript is too long for S1-mini."
            case .decodeFailed: "S1-mini inference failed."
            case .samplerFailed: "S1-mini decoding could not start."
            }
        }
    }
}
