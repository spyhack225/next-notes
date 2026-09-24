import Foundation
import llama

/// The header facts the app needs before it asks llama.cpp to open a file.
///
/// Read through the linked `gguf_*` C API, which parses metadata and tensor descriptors
/// only — tensor data is never touched, so this is cheap even for a multi-gigabyte file and
/// safe to run off the main actor.
struct GGUFMetadata: Sendable, Equatable {
    /// `general.architecture`, e.g. "qwen3", "llama", "k2-horizon".
    let architecture: String?
    /// `tokenizer.ggml.pre` — llama.cpp refuses a pre-tokenizer it does not know.
    let preTokenizer: String?
    /// `tokenizer.chat_template`, which names the turn markers the model was trained with.
    let chatTemplate: String?
    /// `general.name`, the publisher's own name for the checkpoint.
    let name: String?

    /// nil when the file is not a readable GGUF.
    static func read(_ url: URL) -> GGUFMetadata? {
        let params = gguf_init_params(no_alloc: true, ctx: nil)
        guard let context = gguf_init_from_file(url.path, params) else { return nil }
        defer { gguf_free(context) }

        func string(_ key: String) -> String? {
            let id = gguf_find_key(context, key)
            guard id >= 0 else { return nil }
            // The value getters abort on the wrong type for the key, so the type is checked
            // first rather than trusted.
            guard gguf_get_kv_type(context, id) == GGUF_TYPE_STRING else { return nil }
            guard let value = gguf_get_val_str(context, id) else { return nil }
            return String(cString: value)
        }

        return GGUFMetadata(
            architecture: string("general.architecture"),
            preTokenizer: string("tokenizer.ggml.pre"),
            chatTemplate: string("tokenizer.chat_template"),
            name: string("general.name")
        )
    }
}
