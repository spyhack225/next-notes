import Foundation

/// Maps MCP annotations and the tool name into an `AgentRisk` *hint*. The broker still
/// decides; an annotation never grants permission.
enum MCPRiskHint {
    static func risk(name: String, annotations: [String: String]) -> AgentRisk {
        if truthy(annotations["destructiveHint"]) {
            return .destructive
        }
        if truthy(annotations["readOnlyHint"]) {
            return .read
        }

        let lowered = name.lowercased()
        if matches(lowered, ["delete", "remove", "destroy", "trash", "unlink"]) {
            return .destructive
        }
        if matches(lowered, ["send", "message", "email", "mail", "post_message", "tweet", "slack"])
            && matches(lowered, ["send", "message", "post", "email", "tweet"]) {
            return .send
        }
        if matches(lowered, ["create", "write", "update", "edit", "put", "append", "upload", "insert"]) {
            return .write
        }
        if matches(lowered, ["read", "get", "list", "search", "fetch", "find", "lookup", "echo"]) {
            return .read
        }
        return .send
    }

    private static func truthy(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered == "true" || lowered == "1" || lowered == "yes"
    }

    private static func matches(_ name: String, _ tokens: [String]) -> Bool {
        tokens.contains { name.contains($0) }
    }
}
