import Foundation

/// IM-14 — an inbound file, copied out safely or refused with the reason.
///
/// Five rules, in the order they run:
///
/// 1. **The paired chat first.** Nothing is read — not the bytes, not the size —
///    before the chat matches the pairing. A message claiming an attachment from
///    another conversation is refused on the guids alone.
/// 2. **Never mutate Apple's original.** The source is opened read-only and the
///    bytes land in the working directory: atomic write plus `chmod 0600`, the
///    `NextMemory.persist` convention.
/// 3. **Paths are resolved with `realpath(3)`.** `URL.resolvingSymlinksInPath`
///    strips `/private` where the filesystem reports it, so a prefix test
///    between the two spellings matches nothing — the same trap the file index
///    and the skill scanner hit. A resolved path outside the attachments tree
///    (a symlink pointing out counts) is refused.
/// 4. **Bounds before bytes.** The file's size is read from its attributes and
///    checked against the policy limit before a single byte is copied; an
///    over-limit file is refused with the limit named. Video never copies bytes
///    without an explicit user action — the row's own metadata is the answer.
/// 5. **Never execute.** The copy is bytes in a working directory. Nothing here
///    opens, renders, indexes or follows it.
enum MessagesAttachmentCopier {
    /// Why a copy did not happen. Every case names what the person can do about
    /// it, in words rather than numbers where a number is not the point.
    enum Refusal: Equatable, Sendable {
        /// Another conversation's file. Nothing was read.
        case wrongChat
        /// The row names no file.
        case missingFile
        /// The resolved path is outside the attachments tree.
        case outsideTree
        /// Bigger than the kind's limit, which travels with the refusal.
        case overLimit(limitBytes: Int64, actualBytes: Int64)
        /// Video: the row metadata answers, the bytes stay put.
        case metadataOnly
        /// The file could not be read.
        case unreadable(String)
    }

    /// What a copy produced. Hashes, not contents: the digest proves the bytes
    /// without carrying them.
    struct Copy: Equatable, Sendable {
        var url: URL
        var bytes: Int64
        var sha256Hex: String
    }

    enum Outcome: Equatable, Sendable {
        case copied(Copy)
        case refused(Refusal)
    }

    /// Copies one attachment row's file into `workingRoot`.
    ///
    /// - Parameters:
    ///   - attachment: the row. Only its filename, UTI and MIME type are read.
    ///   - chatGUID: the chat the claiming message arrived in.
    ///   - pairedChatGUID: the pairing. Nil, or any other chat, refuses.
    ///   - attachmentsRoot: `~/Library/Messages/Attachments`, or a temp stand-in.
    ///     Relative filenames resolve against it; absolute ones must still land
    ///     inside it after `realpath`.
    ///   - workingRoot: where the copy lands. Created as needed.
    static func copy(attachment: MessagesAttachment,
                     chatGUID: String,
                     pairedChatGUID: String?,
                     attachmentsRoot: URL,
                     workingRoot: URL) -> Outcome {
        guard let paired = pairedChatGUID, !paired.isEmpty, chatGUID == paired else {
            return .refused(.wrongChat)
        }
        guard let filename = attachment.filename, !filename.isEmpty else {
            return .refused(.missingFile)
        }
        let candidate: URL = (filename as NSString).isAbsolutePath
            ? URL(fileURLWithPath: filename)
            : attachmentsRoot.appendingPathComponent(filename)
        let resolved = canonical(candidate)
        guard isInside(resolved, root: canonical(attachmentsRoot)) else {
            return .refused(.outsideTree)
        }
        let kind = MessagesAttachmentPolicy.kind(
            uti: attachment.uti, mimeType: attachment.mimeType, filename: filename)
        guard let limit = MessagesAttachmentPolicy.byteLimit(for: kind) else {
            return .refused(.metadataOnly)
        }
        let size: Int64
        do {
            let values = try FileManager.default.attributesOfItem(atPath: resolved)
            guard let number = values[.size] as? NSNumber else {
                return .refused(.unreadable("the file has no size"))
            }
            size = number.int64Value
        } catch {
            return .refused(.unreadable("the file could not be read"))
        }
        guard size <= limit else {
            return .refused(.overLimit(limitBytes: limit, actualBytes: size))
        }
        do {
            try FileManager.default.createDirectory(at: workingRoot, withIntermediateDirectories: true)
            let leaf = (resolved as NSString).lastPathComponent
            let name = attachment.guid.isEmpty ? leaf : "\(attachment.guid)-\(leaf)"
            let destination = workingRoot.appendingPathComponent(name.isEmpty ? attachment.guid : name)
            let staging = workingRoot.appendingPathComponent(".\(destination.lastPathComponent).part")
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: resolved), to: staging)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: staging.path)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)
            let bytes = try Data(contentsOf: destination)
            return .copied(Copy(url: destination, bytes: Int64(bytes.count),
                                sha256Hex: IMessageActionVerifier.hex(OutboundDigest.sha256(bytes))))
        } catch {
            return .refused(.unreadable("the copy failed"))
        }
    }

    /// `realpath(3)`, not `URL.resolvingSymlinksInPath()`: the URL version keeps
    /// `/var` where the enumerator — and the filesystem — reports `/private/var`.
    static func canonical(_ url: URL) -> String {
        MessagesDatabase.canonicalPath(of: url)
    }

    /// Whether a resolved path sits inside a resolved root. A string prefix with
    /// a separator boundary, so `/Attachments-evil` is not inside `/Attachments`.
    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
