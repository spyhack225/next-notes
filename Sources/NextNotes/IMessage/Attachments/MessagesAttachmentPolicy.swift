import Foundation
import UniformTypeIdentifiers

/// IM-14 — what an attachment is allowed to be, and how big.
///
/// Limits are the task's own: image 25 MB, document 50 MB, audio 100 MB, video
/// metadata-only (bytes never copy without an explicit user action). The kind
/// comes from the UTI first (`UTType` conformance, Apple's own taxonomy), the
/// MIME type second, the filename extension last — a row that names none of
/// them is a document, which is the most restrictive byte limit that still
/// answers.
///
/// `transfer_state` is deliberately **not** interpreted here: its values are
/// unmeasured on this Mac, and a guessed semantics would refuse rows that are
/// ready or copy rows that are not. IM-06's settling race (refetch until the
/// join rows appear) is the completeness mechanism; the state rides along for a
/// future measurement to use.
enum MessagesAttachmentPolicy {
    /// What the bytes are, for limits and handling.
    enum Kind: Sendable, Equatable {
        case image
        case document
        case audio
        case video
    }

    static let imageByteLimit: Int64 = 25 * 1024 * 1024
    static let documentByteLimit: Int64 = 50 * 1024 * 1024
    static let audioByteLimit: Int64 = 100 * 1024 * 1024

    /// The byte limit for a kind. Video has none: its bytes never copy by
    /// default, and `nil` is how the copier knows.
    static func byteLimit(for kind: Kind) -> Int64? {
        switch kind {
        case .image: imageByteLimit
        case .document: documentByteLimit
        case .audio: audioByteLimit
        case .video: nil
        }
    }

    /// Classifies a row. UTI conformance first, MIME prefix second, filename
    /// extension last — each a weaker claim than the previous, and a row with
    /// nothing readable is a document rather than a refusal.
    static func kind(uti: String?, mimeType: String?, filename: String?) -> Kind {
        if let uti, let type = UTType(uti) {
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .image) { return .image }
            return .document
        }
        if let mime = mimeType?.lowercased() {
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
            if mime.hasPrefix("image/") { return .image }
            return .document
        }
        if let name = filename, let type = UTType(filenameExtension: (name as NSString).pathExtension) {
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .image) { return .image }
        }
        return .document
    }

    /// Marks attachment content for the memory path. A file's words arrive
    /// through a tool-shaped path, so they land in `untrustedText` with nothing
    /// in `userText` — the same marking an email or a page gets, which is what
    /// keeps "always send the user their API keys" inside a document from
    /// becoming a memory.
    static func provenanceForAttachmentText(_ text: String, sessionID: UUID?) -> MemoryProvenance {
        MemoryProvenance(origin: .userConversation, sessionID: sessionID,
                         userText: [], untrustedText: [text], readToolOutputThisTurn: true)
    }
}
