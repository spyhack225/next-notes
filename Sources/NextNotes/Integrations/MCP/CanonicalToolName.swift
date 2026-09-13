import Foundation

/// Turns a server-prefixed MCP name into the capability the model should see.
///
/// `mcp.Composio.GITHUB_CREATE_ISSUE` and `GITHUB_CREATE_ISSUE` both resolve to
/// `github.create_issue`. The router still picks which implementation runs.
enum CanonicalToolName {
    struct Resolution: Equatable, Sendable {
        var id: String
        var namespace: AgentToolNamespace
        var aliases: [String]
    }

    private static let known: [String: AgentToolNamespace] = [
        "github": .github,
        "slack": .slack,
        "notion": .notion,
        "gmail": .workspace,
        "calendar": .workspace,
        "drive": .workspace,
        "docs": .workspace,
        "filesystem": .filesystem,
        "files": .filesystem,
        "browser": .browser,
        "computer": .computer,
        "shell": .shell,
    ]

    static func resolve(raw: String, server: String) -> Resolution {
        let prefixed = "mcp.\(server).\(raw)"
        let stripped = strip(raw, server: server)
        if let mapped = map(stripped) {
            return Resolution(
                id: mapped.id,
                namespace: mapped.namespace,
                aliases: unique([raw, stripped, prefixed, mapped.id])
            )
        }
        return Resolution(
            id: prefixed,
            namespace: .mcp,
            aliases: unique([raw, prefixed])
        )
    }

    private static func strip(_ raw: String, server: String) -> String {
        var name = raw
        let prefixes = ["mcp.\(server).", "mcp.\(server.lowercased())."]
        for prefix in prefixes where name.lowercased().hasPrefix(prefix.lowercased()) {
            name = String(name.dropFirst(prefix.count))
        }
        return name
    }

    private static func map(_ raw: String) -> (id: String, namespace: AgentToolNamespace)? {
        let normalized = raw
            .replacingOccurrences(of: "-", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let dotted = dotted(normalized) {
            return dotted
        }
        if let underscored = underscored(normalized) {
            return underscored
        }
        return nil
    }

    private static func dotted(_ raw: String) -> (id: String, namespace: AgentToolNamespace)? {
        let parts = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let head = parts[0].lowercased()
        guard let namespace = known[head] else { return nil }
        let tail = parts[1].lowercased()
        return ("\(namespaceKey(namespace)).\(tail)", namespace)
    }

    private static func underscored(_ raw: String) -> (id: String, namespace: AgentToolNamespace)? {
        let parts = raw.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let head = parts[0].lowercased()
        guard let namespace = known[head] else { return nil }
        let tail = parts[1].lowercased()
        return ("\(namespaceKey(namespace)).\(tail)", namespace)
    }

    private static func namespaceKey(_ namespace: AgentToolNamespace) -> String {
        switch namespace {
        case .filesystem: return "filesystem"
        default: return namespace.rawValue
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
