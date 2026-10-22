import CryptoKit
import Foundation

enum HashBefore {
static func sha256(of url: URL) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        try Task.checkCancellation()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

