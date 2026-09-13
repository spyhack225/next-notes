import Foundation

enum FilesystemToolCatalogue {
    static let all: [AgentTool] = [
        .native(
            namespace: .filesystem,
            name: "search",
            description: "Search the user's home folder for files whose name matches a query. "
                + "Returns paths, sizes and modification dates. Does not search hidden or "
                + "Library folders.",
            risk: .read,
            parameters: [
                .init(name: "query", description: "Words from the file name."),
                .init(name: "folder", description: "Optional folder to search in.", isRequired: false),
            ]
        ),
        .native(
            namespace: .filesystem,
            name: "read",
            description: "Read a local text file. Binary files are refused.",
            risk: .read,
            parameters: [
                .init(name: "path", description: "Absolute path of the file.")
            ]
        ),
        .native(
            namespace: .filesystem,
            name: "write",
            description: "Write text to a local file, creating it if needed.",
            risk: .modify,
            parameters: [
                .init(name: "path", description: "Absolute path of the file."),
                .init(name: "text", description: "The contents to write.", kind: .multiline),
            ]
        ),
        .native(
            namespace: .filesystem,
            name: "move",
            description: "Move a local file to a new path.",
            risk: .modify,
            parameters: [
                .init(name: "from", description: "The current path."),
                .init(name: "to", description: "The destination path."),
            ]
        ),
        .native(
            namespace: .filesystem,
            name: "copy",
            description: "Copy a local file.",
            risk: .modify,
            parameters: [
                .init(name: "from", description: "The source path."),
                .init(name: "to", description: "The destination path."),
            ]
        ),
        .native(
            namespace: .filesystem,
            name: "delete",
            description: "Move a local file to the Trash.",
            risk: .destructive,
            parameters: [
                .init(name: "path", description: "Absolute path of the file.")
            ]
        ),
        .native(
            namespace: .filesystem,
            name: "reveal",
            description: "Reveal a file in Finder.",
            risk: .observe,
            parameters: [
                .init(name: "path", description: "Absolute path of the file.")
            ]
        ),
    ]
}
