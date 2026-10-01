import Foundation

/// A digest checked against the actual bytes during download/adoption, never on a turn.
/// The file stamp invalidates proof when the file changes; names and model families are
/// deliberately absent from identity. Legacy library rows have no proof until verified.
struct VerifiedModelArtifact: Codable, Sendable, Hashable {
    let sha256: String
    let bytes: Int64
    let stamp: FileStamp

    struct FileStamp: Codable, Sendable, Hashable {
        let bytes: Int64
        let modified: Date
        let created: Date
        let fileNumber: UInt64
        let systemNumber: UInt64

        static func read(_ url: URL) throws -> FileStamp {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  let bytes = values[.size] as? NSNumber,
                  let modified = values[.modificationDate] as? Date,
                  let created = values[.creationDate] as? Date,
                  let number = values[.systemFileNumber] as? NSNumber,
                  let system = values[.systemNumber] as? NSNumber else {
                throw ModelDownloadError.invalidChecksum(url.lastPathComponent)
            }
            return FileStamp(bytes: bytes.int64Value, modified: modified, created: created,
                             fileNumber: number.uint64Value, systemNumber: system.uint64Value)
        }
    }

    static func normalizedDigest(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let value = digest.lowercased()
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return value
    }

    /// nil means no trusted digest was provided, not successful integrity verification.
    /// A changing file cannot acquire proof based on a hash of its earlier contents.
    static func verify(_ url: URL, bytes: Int64, expectedSHA256: String?) throws -> Self? {
        guard let expectedSHA256, !expectedSHA256.isEmpty else { return nil }
        guard let expected = normalizedDigest(expectedSHA256) else {
            throw ModelDownloadError.invalidChecksum(url.lastPathComponent)
        }
        let before = try FileStamp.read(url)
        guard before.bytes == bytes else {
            throw ModelDownloadError.invalidSize(url.lastPathComponent, actual: before.bytes)
        }
        let actual = try ModelDownloader.sha256(of: url)
        let after = try FileStamp.read(url)
        guard before == after, actual == expected else {
            throw ModelDownloadError.invalidChecksum(url.lastPathComponent)
        }
        return Self(sha256: actual, bytes: bytes, stamp: after)
    }

    func isCurrent(at url: URL) -> Bool {
        (try? FileStamp.read(url)) == stamp
    }

    func matches(sha256 expected: String?, bytes expectedBytes: Int64, at url: URL) -> Bool {
        guard let expected = Self.normalizedDigest(expected) else { return false }
        return sha256 == expected && bytes == expectedBytes && isCurrent(at: url)
    }
}
