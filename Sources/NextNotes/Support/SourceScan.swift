import Foundation

/// Reading the app's own source from a self-test.
///
/// Three cases need it, and all three need it for the same reason: the thing they are checking
/// is a **constant in code**, and a constant is invisible to a test that only calls a function.
/// A hard-coded `true` where a setting belongs, a `@State` where a draft belongs, a `draft = ""`
/// in the wrong branch — each of those ships a green suite.
///
/// This is one copy on purpose. Three self-tests each grew their own `source(of:)`, each counting
/// levels up to the package root, and each would have needed the comment-stripping that followed:
/// a scan that cannot tell code from prose fails on the comment explaining what it is looking
/// for, and a self-test that fails on its own documentation gets deleted rather than fixed.
enum SourceScan {
    /// The file at `relativePath`, or nil when the tree is not where it was.
    ///
    /// Walks up to the package root rather than counting levels, so a moved file cannot make a
    /// check pass by finding nothing. **A caller must treat nil as a failure and say so** — a
    /// scan that read no file must never read as a scan that found no literal.
    static func file(_ relativePath: String,
                     from sourceFile: StaticString = #filePath) -> String? {
        var root = URL(fileURLWithPath: String(describing: sourceFile)).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Package.swift").path) {
                return try? String(contentsOf: root.appendingPathComponent(relativePath),
                                   encoding: .utf8)
            }
            let parent = root.deletingLastPathComponent()
            if parent.path == root.path { break }
            root = parent
        }
        return nil
    }

    /// The lines that are code: comments and their contents removed, each keeping its real
    /// number so a failure can be pointed at.
    static func codeLines(of text: String) -> [(number: Int, text: String)] {
        var result: [(Int, String)] = []
        var inBlock = false
        for (index, raw) in text
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if trimmed.contains("*/") { inBlock = false }
                continue
            }
            if trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("/*") {
                if !trimmed.contains("*/") { inBlock = true }
                continue
            }
            result.append((index + 1, line))
        }
        return result
    }

    /// The code lines of one file, or nil when it could not be read.
    static func codeLines(of relativePath: String,
                          from sourceFile: StaticString = #filePath)
        -> [(number: Int, text: String)]? {
        file(relativePath, from: sourceFile).map { codeLines(of: $0) }
    }
}
