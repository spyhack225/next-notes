import Foundation

/// MCP `inputSchema` → the parameter list the model and the argument editor already use.
/// Annotations stay metadata; this is only the shape of the call.
enum MCPInputSchema {
    static func parameters(fromJSON json: String) -> [WorkspaceTool.Parameter] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        return parameters(from: object)
    }

    static func parameters(from object: [String: Any]) -> [WorkspaceTool.Parameter] {
        let properties = object["properties"] as? [String: Any] ?? [:]
        let required = Set((object["required"] as? [String]) ?? [])
        return properties.keys.sorted().map { name in
            let spec = properties[name] as? [String: Any] ?? [:]
            let type = (spec["type"] as? String ?? "string").lowercased()
            let description = spec["description"] as? String ?? name
            let format = (spec["format"] as? String ?? "").lowercased()
            let kind: WorkspaceTool.Parameter.Kind
            if type == "array" {
                kind = .list
            } else if type == "string", format == "date" || format == "date-time"
                || name.localizedCaseInsensitiveContains("date")
                || name.localizedCaseInsensitiveContains("time") {
                kind = .date
            } else if type == "string", format == "textarea"
                || name.localizedCaseInsensitiveContains("body")
                || name.localizedCaseInsensitiveContains("content")
                || name.localizedCaseInsensitiveContains("message") {
                kind = .multiline
            } else {
                kind = .text
            }
            return WorkspaceTool.Parameter(
                name: name,
                description: description,
                isRequired: required.contains(name),
                kind: kind
            )
        }
    }

    static func jsonString(from object: [String: Any]?) -> String {
        guard let object,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return text
    }
}
