import AppKit
import Foundation

/// Local file operations, bounded so a "find the latest STEP file" cannot walk the whole disk.
enum FilesystemExecutor {
    private static let searchCap = 80
    private static let readCap = 8_000
    private static let deniedNames: Set<String> = [
        "Library", "node_modules", ".git", ".Trash", "Caches", "Containers"
    ]

    @MainActor
    static func run(_ tool: AgentTool, arguments: [String: String]) throws -> AgentToolResult {
        switch tool.name {
        case "search":
            return try search(query: arguments["query"] ?? "", folder: arguments["folder"])
        case "read":
            return try read(path: arguments["path"] ?? "")
        case "write":
            return try write(path: arguments["path"] ?? "", text: arguments["text"] ?? "")
        case "move":
            return try move(from: arguments["from"] ?? "", to: arguments["to"] ?? "")
        case "copy":
            return try copy(from: arguments["from"] ?? "", to: arguments["to"] ?? "")
        case "delete":
            return try trash(path: arguments["path"] ?? "")
        case "reveal":
            return try reveal(path: arguments["path"] ?? "")
        default:
            throw AgentError.unknownTool(tool.id)
        }
    }

    private static func search(query: String, folder: String?) throws -> AgentToolResult {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            throw AgentError.missingArgument(name: "query", tool: "filesystem.search")
        }
        let root = resolved(folder) ?? FileManager.default.homeDirectoryForCurrentUser
        var hits: [String] = []
        var stack = [root]
        let fileManager = FileManager.default

        while let directory = stack.popLast(), hits.count < searchCap {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in children {
                if deniedNames.contains(url.lastPathComponent) { continue }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    stack.append(url)
                    continue
                }
                guard url.lastPathComponent.lowercased().contains(needle) else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
                let modified = values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
                hits.append("- \(url.path)  \(size)  \(modified)")
            }
        }
        return AgentToolResult(
            summary: hits.isEmpty ? "No file matching \(query) under \(root.path)." : hits.joined(separator: "\n")
        )
    }

    private static func read(path: String) throws -> AgentToolResult {
        let url = resolved(path)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw AgentError.missingArgument(name: "path", tool: "filesystem.read")
        }
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000 else {
            throw AgentError.permissionDenied("The file is missing or too large to read.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentError.permissionDenied("That file is not text.")
        }
        let clipped = text.count > readCap ? String(text.prefix(readCap)) + "\n…" : text
        return AgentToolResult(summary: clipped, reference: url.path)
    }

    private static func write(path: String, text: String) throws -> AgentToolResult {
        let url = resolved(path)
        guard let url else { throw AgentError.missingArgument(name: "path", tool: "filesystem.write") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return AgentToolResult(summary: "Wrote \(url.lastPathComponent).", reference: url.path)
    }

    private static func move(from: String, to: String) throws -> AgentToolResult {
        let source = resolved(from)
        let destination = resolved(to)
        guard let source, let destination else {
            throw AgentError.missingArgument(name: "from", tool: "filesystem.move")
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return AgentToolResult(summary: "Moved \(source.lastPathComponent) to \(destination.path).")
    }

    private static func copy(from: String, to: String) throws -> AgentToolResult {
        let source = resolved(from)
        let destination = resolved(to)
        guard let source, let destination else {
            throw AgentError.missingArgument(name: "from", tool: "filesystem.copy")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return AgentToolResult(summary: "Copied \(source.lastPathComponent) to \(destination.path).")
    }

    private static func trash(path: String) throws -> AgentToolResult {
        let url = resolved(path)
        guard let url else { throw AgentError.missingArgument(name: "path", tool: "filesystem.delete") }
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return AgentToolResult(summary: "Moved \(url.lastPathComponent) to the Trash.")
    }

    @MainActor
    private static func reveal(path: String) throws -> AgentToolResult {
        let url = resolved(path)
        guard let url else { throw AgentError.missingArgument(name: "path", tool: "filesystem.reveal") }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return AgentToolResult(summary: "Revealed \(url.lastPathComponent) in Finder.")
    }

    private static func resolved(_ path: String?) -> URL? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}
