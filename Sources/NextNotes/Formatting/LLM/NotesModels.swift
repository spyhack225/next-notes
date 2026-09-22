import Foundation

/// The local model that writes meeting notes.
///
/// Gemma 4 E4B at Q4_K_M was chosen for its strong reasoning capabilities and 128K context
/// window, which keeps the KV cache small enough that a two-hour transcript still fits in
/// one prompt — which is what makes single-pass notes, rather than a lossy map-reduce,
/// the normal case. At 4.98 GB it leaves room for Parakeet and S1-mini on a 16 GB Mac.
enum NotesModels {
    static let spec = ModelSpec(
        displayName: "Gemma 4 E4B",
        fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf")!,
        // Measured 2026-09-22 via the Hub resolve redirect (final Content-Length).
        expectedBytes: 4_977_171_584,
        // Unpinned until a verified download lands on this machine: the downloader logs
        // the computed digest and the next run pins it, per the S1MiniModels convention.
        expectedSHA256: nil
    )

    static var fileURL: URL { spec.fileURL }
    static var isDownloaded: Bool { spec.isDownloaded }

    static func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await ModelDownloader.download(spec, progress: progress)
    }
}
