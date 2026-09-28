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
        // Pinned 2026-09-28 from a real download on this machine, computed by
        // `ModelDownloader.sha256(of:)` and reported by `--download-notes-model`:
        //   NOTES_MODEL_DOWNLOAD_OK: Gemma 4 E4B … bytes=4977171584
        //     sha256=85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87
        // This is the "next agent to get it pins it" step AGENTS.md describes, and it is the
        // S1MiniModels convention. The byte count was already pinned from the Hub's LFS
        // record; the digest now makes a truncated or substituted file fail at the door
        // rather than at the first generation.
        expectedSHA256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87"
    )

    static var fileURL: URL { spec.fileURL }
    static var isDownloaded: Bool { spec.isDownloaded }

    static func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await ModelDownloader.download(spec, progress: progress)
    }
}
