import Foundation

/// A file search, local or Drive, parsed from the utterance. “Find the latest”
/// used to be delegated to a background coding agent and then forgotten.
enum FileIntent: Equatable {
    case home(query: String)
    case drive(query: String)

    static func parse(_ raw: String) -> FileIntent? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        if isDrive(lowered) {
            return .drive(query: query(from: lowered, dropping: driveMarks + filler))
        }
        guard isFiles(lowered) else { return nil }
        return .home(query: query(from: lowered, dropping: fileMarks + filler))
    }

    private static func isDrive(_ lowered: String) -> Bool {
        driveMarks.contains { lowered.contains($0) }
    }

    private static func isFiles(_ lowered: String) -> Bool {
        if fileMarks.contains(where: { lowered.contains($0) }) { return true }
        return lowered.contains("find") && lowered.contains("file")
    }

    private static func query(from lowered: String, dropping marks: [String]) -> String {
        var remainder = lowered
        for mark in marks.sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: mark, with: " ")
        }
        return remainder
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !stop.contains($0) }
            .joined(separator: " ")
    }

    private static let driveMarks = [
        "google drive", "on drive", "in drive", "drive file", "in my drive", "on my drive",
    ]

    private static let fileMarks = [
        "find the latest", "search files", "search for files", "look for files",
        "search my files", "find files", "find a file", "find the file",
        "search for a file",
    ]

    private static let filler = ["called", "named", "called the", "named the"]

    private static let stop: Set<String> = [
        "a", "an", "the", "for", "my", "me", "please", "can", "you", "find",
        "search", "look", "latest", "file", "files",
    ]
}
