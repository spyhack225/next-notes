import Foundation

/// The local model that writes meeting notes.
///
/// Qwen3.5-4B at Q4_K_M was chosen against Qwen3.5-9B, Gemma 4 E4B and Gemma 4 12B on the
/// one constraint that actually binds here: a 16 GB M3 with under 10 GB of free disk, which
/// also has to hold Parakeet and S1-mini. At 2.74 GB it is the only candidate that leaves
/// room, and its Gated-DeltaNet hybrid attention keeps the KV cache small enough that a
/// two-hour transcript still fits in one prompt — which is what makes single-pass notes,
/// rather than a lossy map-reduce, the normal case.
enum NotesModels {
    static let spec = ModelSpec(
        displayName: "Qwen3.5-4B",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!,
        expectedBytes: 2_740_937_888,
        // Pinned from a verified download on 2026-09-09, the same way
        // `S1MiniModels.expectedSHA256` was: fetch, check the size, hash the bytes, and
        // only then let the file into Application Support. Size alone would accept a
        // same-length substitution; this rejects any byte that differs.
        expectedSHA256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"
    )

    static var fileURL: URL { spec.fileURL }
    static var isDownloaded: Bool { spec.isDownloaded }

    static func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await ModelDownloader.download(spec, progress: progress)
    }
}
