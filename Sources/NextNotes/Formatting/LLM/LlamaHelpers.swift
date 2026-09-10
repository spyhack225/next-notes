import Foundation
import llama

/// The three llama.cpp calls every runtime in this app has to write, written once.
///
/// Tokenizing, turning a token back into text, and filling a batch are pure C-interop
/// plumbing with pointer lifetimes that are easy to get subtly wrong — a `[CChar]` that is
/// one byte short, a `seq_id` left unset — and getting them wrong produces garbled output
/// rather than a crash. S1-mini and the notes model share this file so there is one copy to
/// be right.
enum LlamaHelpers {
    /// UTF-8 bytes plus room for the special tokens the template adds.
    private static let tokenizeHeadroom = 8

    static func tokenize(
        _ text: String,
        vocabulary: OpaquePointer,
        addSpecial: Bool = true
    ) throws -> [llama_token] {
        let capacity = text.utf8.count + tokenizeHeadroom
        let pointer = UnsafeMutablePointer<llama_token>.allocate(capacity: capacity)
        defer { pointer.deallocate() }
        let count = llama_tokenize(
            vocabulary,
            text,
            Int32(text.utf8.count),
            pointer,
            Int32(capacity),
            addSpecial,
            true
        )
        guard count >= 0 else { throw LlamaError.tokenizationFailed }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(count)))
    }

    /// The text a token stands for.
    ///
    /// The two-pass shape is load-bearing: `llama_token_to_piece` returns a *negative*
    /// required length when the buffer is too small, and a single-pass version silently
    /// drops any piece longer than the guess — which in practice means emoji and CJK.
    static func piece(_ token: llama_token, vocabulary: OpaquePointer) -> String {
        var storage = [CChar](repeating: 0, count: 16)
        var count = llama_token_to_piece(vocabulary, token, &storage, Int32(storage.count), 0, false)
        if count < 0 {
            storage = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocabulary, token, &storage, Int32(storage.count), 0, false)
        }
        guard count > 0 else { return "" }
        return String(decoding: storage.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// Appends one token to a batch. `n_seq_id` and `seq_id[0]` have no sensible defaults
    /// in `llama_batch_init`, and leaving them zero makes `llama_decode` reject the batch.
    static func add(
        _ token: llama_token,
        position: llama_pos,
        logits: Bool,
        to batch: inout llama_batch
    ) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    /// Feeds a prompt in `chunk`-sized batches and asks for logits on its last token.
    ///
    /// A 20-minute transcript tokenizes to tens of thousands of tokens, and a single batch
    /// that large exceeds `n_batch` and is refused. Splitting here rather than at each call
    /// site is what lets the notes model take a whole meeting as one prompt.
    static func decodePrompt(
        _ tokens: [llama_token],
        context: OpaquePointer,
        chunk: Int
    ) throws {
        guard !tokens.isEmpty else { throw LlamaError.decodeFailed }
        var batch = llama_batch_init(Int32(max(1, min(chunk, tokens.count))), 0, 1)
        defer { llama_batch_free(batch) }

        var index = 0
        while index < tokens.count {
            let end = min(index + chunk, tokens.count)
            batch.n_tokens = 0
            for position in index..<end {
                add(
                    tokens[position],
                    position: llama_pos(position),
                    // Only the very last token of the whole prompt needs logits; asking for
                    // them on every chunk boundary allocates an output row per chunk.
                    logits: position == tokens.count - 1,
                    to: &batch
                )
            }
            guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }
            index = end
        }
    }
}

/// Failures that come out of llama.cpp itself rather than out of a particular model's
/// policy. Each runtime translates these into its own user-facing message.
enum LlamaError: LocalizedError {
    case modelMissing
    case modelLoadFailed
    case contextLoadFailed
    case notLoaded
    case tokenizationFailed
    case inputTooLong
    case decodeFailed
    case samplerFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing: "The model is not downloaded."
        case .modelLoadFailed: "The model could not be loaded."
        case .contextLoadFailed: "Inference could not start."
        case .notLoaded: "The model is unavailable."
        case .tokenizationFailed: "The text could not be tokenized."
        case .inputTooLong: "The text is longer than the model's context."
        case .decodeFailed: "Inference failed."
        case .samplerFailed: "Decoding could not start."
        }
    }
}
