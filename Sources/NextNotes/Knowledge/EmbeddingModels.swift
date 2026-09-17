import Foundation

/// The two embedding models, pinned.
///
/// Each URL resolves a fixed commit rather than `main`, and each hash is the SHA-256 Hugging
/// Face reports for that commit's file (the LFS object id for the weights), read from the
/// Hub's file metadata on 2026-09-17 — not from a download. `ModelDownloader` refuses any
/// file whose size or hash differs, so a repository that changes upstream fails loudly
/// instead of swapping the vectors' meaning under an existing index.
///
/// The tokenizer is a plain git file, which the Hub lists by git blob id rather than
/// SHA-256; its hash was computed from the 1.5 MB file at the same commit.
///
/// Weights never enter the repository, and nothing downloads until the user asks in
/// Settings (`LocalModelStore.prepareEmbeddingModel`).
enum EmbeddingModels {
    struct Licence: Sendable {
        let name: String
        let url: URL
        let source: URL
    }

    /// minishlab/potion-retrieval-32M — a Model2Vec static embedding table: 63,091 WordPiece
    /// tokens × 512 float32 dimensions. 129 MB on disk, memory-mapped rather than read.
    static let potionModel = ModelSpec(
        displayName: "potion-retrieval-32M",
        fileName: "potion-retrieval-32M.safetensors",
        url: URL(string: "https://huggingface.co/minishlab/potion-retrieval-32M/resolve/6fc8051fab2a1e0ee76689cf08c853792ac285e7/model.safetensors")!,
        expectedBytes: 129_210_456,
        expectedSHA256: "07609e5bd33aad37900b3fd62f4ec96f6daec88ca4d46b9d8b928bfababf6ea0"
    )

    static let potionTokenizer = ModelSpec(
        displayName: "potion-retrieval-32M tokenizer",
        fileName: "potion-retrieval-32M.tokenizer.json",
        url: URL(string: "https://huggingface.co/minishlab/potion-retrieval-32M/resolve/6fc8051fab2a1e0ee76689cf08c853792ac285e7/tokenizer.json")!,
        expectedBytes: 1_493_150,
        expectedSHA256: "7d75cbc54318138807c401b0f0c9721117c628b39de8e8e0edb6cb17e0ee7d18"
    )

    /// ggml-org/embeddinggemma-300M-qat-q4_0-GGUF — Google's quantization-aware checkpoint,
    /// 768 dimensions before truncation, mean pooling. 265 MiB.
    static let embeddingGemma = ModelSpec(
        displayName: "EmbeddingGemma-300M",
        fileName: "embeddinggemma-300M-qat-Q4_0.gguf",
        url: URL(string: "https://huggingface.co/ggml-org/embeddinggemma-300M-qat-q4_0-GGUF/resolve/8dd0ca2a66a8f14470acb0e2a71f801afbc5fb73/embeddinggemma-300M-qat-Q4_0.gguf")!,
        expectedBytes: 277_852_192,
        expectedSHA256: "50d28e22432a148f6f8a86eab3700f92add5d1f54baf7790675a2a4dadbccf26"
    )

    /// Every file a choice needs, in download order.
    static func specs(_ choice: KnowledgeEmbedderChoice) -> [ModelSpec] {
        switch choice {
        case .none: []
        case .potion: [potionTokenizer, potionModel]
        case .embeddinggemma: [embeddingGemma]
        }
    }

    static func isDownloaded(_ choice: KnowledgeEmbedderChoice) -> Bool {
        specs(choice).allSatisfy(\.isDownloaded)
    }

    static func totalBytes(_ choice: KnowledgeEmbedderChoice) -> Int64 {
        specs(choice).reduce(0) { $0 + $1.expectedBytes }
    }

    static func displaySize(_ choice: KnowledgeEmbedderChoice) -> String {
        ByteCountFormatter.string(fromByteCount: totalBytes(choice), countStyle: .binary)
    }

    /// Shown beside the download button, before anything is fetched.
    static func licence(_ choice: KnowledgeEmbedderChoice) -> Licence? {
        switch choice {
        case .none:
            nil
        case .potion:
            Licence(name: "MIT",
                    url: URL(string: "https://opensource.org/license/mit")!,
                    source: URL(string: "https://huggingface.co/minishlab/potion-retrieval-32M")!)
        case .embeddinggemma:
            Licence(name: "Gemma Terms of Use",
                    url: URL(string: "https://ai.google.dev/gemma/terms")!,
                    source: URL(string: "https://huggingface.co/ggml-org/embeddinggemma-300M-qat-q4_0-GGUF")!)
        }
    }
}
