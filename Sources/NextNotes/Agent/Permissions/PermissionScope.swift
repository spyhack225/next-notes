import AppKit
import Foundation

/// What a standing "yes" is allowed to cover. A grant for `computer.click` in Chrome
/// must not also click in Mail.
enum PermissionScopeKind: String, Codable, Sendable, CaseIterable {
    case any
    /// Internal sentinel used while a browser's active tab could not be resolved.
    /// It intentionally cannot be covered by an `.any` standing grant.
    case unresolved
    case application
    case domain
    case path
    case project
}

struct PermissionScope: Codable, Equatable, Sendable {
    var kind: PermissionScopeKind
    var value: String

    static let any = PermissionScope(kind: .any, value: "")

    var displayName: String {
        switch kind {
        case .any:
            return "Anywhere"
        case .unresolved:
            return "Unknown browser target"
        case .application:
            return value
        case .domain:
            return value
        case .path:
            return value
        case .project:
            return value
        }
    }

    var alwaysLabel: String {
        switch kind {
        case .any:
            return "Always allow this action"
        case .unresolved:
            return "Allow this action for the identified browser target"
        case .application:
            return "Always allow for \(value)"
        case .domain:
            return "Always allow on \(value)"
        case .path:
            return "Always allow in this folder"
        case .project:
            return "Always allow in \(value)"
        }
    }

    /// A stored grant covers a request when it is unrestricted, or when it names the
    /// same (or a parent) place.
    func covers(_ request: PermissionScope) -> Bool {
        switch kind {
        case .any:
            // Even a broad saved grant cannot authorize an action whose browser
            // target was never identified.
            return request.kind != .unresolved
        case .unresolved:
            return false
        case .application:
            return request.kind == .application
                && value.caseInsensitiveCompare(request.value) == .orderedSame
        case .domain:
            guard request.kind == .domain else { return false }
            let haystack = request.value.lowercased()
            let needle = value.lowercased()
            return haystack == needle || haystack.hasSuffix("." + needle)
        case .path:
            guard request.kind == .path else { return false }
            let prefix = value.hasSuffix("/") ? value : value + "/"
            return request.value == value || request.value.hasPrefix(prefix)
        case .project:
            return request.kind == .project
                && value.caseInsensitiveCompare(request.value) == .orderedSame
        }
    }
}

/// Pulls a scope out of the tool arguments, then the app argument for computer/browser.
enum PermissionScopeResolver {
    @MainActor
    static func inferred(tool: AgentTool, arguments: [String: String]) -> PermissionScope {
        if let path = first(arguments, keys: ["path", "folder", "file", "directory"]) {
            return PermissionScope(kind: .path, value: path)
        }
        if (tool.namespace != .browser || tool.name == "navigate" || tool.name == "download"),
           let raw = first(arguments, keys: ["url", "targetUrl", "target_url"]),
           let host = host(of: raw) {
            return PermissionScope(kind: .domain, value: host)
        }
        if let app = first(arguments, keys: ["app", "bundle", "bundleID", "application"]) {
            return PermissionScope(kind: .application, value: app)
        }
        if let project = arguments["project"], !project.isEmpty {
            return PermissionScope(kind: .project, value: project)
        }
        if tool.namespace == .browser {
            return PermissionScope(kind: .unresolved, value: "browser-target")
        }
        return .any
    }

    /// Browser element actions do not carry a URL in their arguments. Resolve the
    /// active CDP target (or the focused browser document on the Accessibility path)
    /// before checking persistent grants. Returning `.unresolved` prevents an
    /// accidentally broad grant from authorizing an unidentified tab.
    @MainActor
    static func inferredAsync(tool: AgentTool, arguments: [String: String]) async -> PermissionScope {
        guard tool.namespace == .browser else { return inferred(tool: tool, arguments: arguments) }
        // A destination URL is the requested scope for navigation/download. For
        // element actions, a caller supplied URL is untrusted metadata and must not
        // widen or redirect the permission check.
        if tool.name == "navigate" || tool.name == "download",
           let raw = first(arguments, keys: ["url"]),
           let host = host(of: raw) {
            return PermissionScope(kind: .domain, value: host)
        }
        if arguments["_browserBackend"] != nil,
           let raw = arguments["_authorizedPageURL"],
           let host = host(of: raw) {
            return PermissionScope(kind: .domain, value: host)
        }
        if arguments["_browserBackend"] == "cdp",
           let raw = await BrowserCDPClient.targetURL(for: tool, arguments: arguments),
           let host = host(of: raw) {
            return PermissionScope(kind: .domain, value: host)
        }
        if arguments["_browserBackend"] != nil {
            return PermissionScope(kind: .unresolved, value: "browser-target")
        }
        if let raw = await BrowserExecutor.targetURL(for: tool, arguments: arguments),
           let host = host(of: raw) {
            return PermissionScope(kind: .domain, value: host)
        }
        return PermissionScope(kind: .unresolved, value: "browser-target")
    }

    private static func first(_ arguments: [String: String], keys: [String]) -> String? {
        for key in keys {
            let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func host(of raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        if let url = URL(string: "https://\(trimmed)"), let host = url.host, !host.isEmpty {
            return host
        }
        return nil
    }
}
